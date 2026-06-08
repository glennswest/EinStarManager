import Foundation
import Combine
import Network
import Darwin

/// A single message observed on the link (sent or received).
struct FrameRecord: Identifiable {
    enum Direction { case incoming, outgoing }
    let id = UUID()
    let time: Date
    let direction: Direction
    let isText: Bool
    let kind: PayloadKind
    let size: Int
    let data: Data
    var textPreview: String {
        if isText, let s = String(data: data, encoding: .utf8) { return s }
        return data.asciiPreview(limit: 96)
    }
}

/// Connection state + transport for the Einstar Rigil.
///
/// Transport facts established by probing the device (192.168.76.1):
///  - :8081 is a WebSocket control/data channel. It PINGs the client and will
///    CLOSE (code 1000) if the client sends an unrecognized command. URLSession
///    auto-responds to pings with pongs, so the socket stays alive on its own.
///  - :8080 is an HTTP server for specific resource paths (file downloads).
///
/// The application-level command vocabulary on :8081 is proprietary; this client
/// exposes a raw send box + frame log so it can be discovered/driven live, and an
/// HTTP fetcher for :8080 paths.
@MainActor
final class ScannerClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: Published state
    // Default to the scanner on the routable LAN. Auto-discovery overwrites this;
    // use 192.168.76.1 when connected directly to the Rigil's own WiFi AP.
    @Published var host: String = "192.168.9.129"
    @Published var wsPort: String = "8081"
    @Published var httpPort: String = "8080"

    @Published private(set) var connected = false
    @Published var status = "Idle"
    @Published private(set) var frames: [FrameRecord] = []

    @Published var httpPath: String = "/"
    @Published private(set) var httpStatus = ""
    @Published private(set) var httpBody: Data? = nil

    // MARK: Discovery state
    /// Comma-separated /24 prefixes to sweep, in addition to the Mac's own subnets.
    @Published var scanPrefixes: String = "192.168.8, 192.168.9"
    @Published var discovering = false
    @Published var discoveryProgress = ""
    @Published var discovered: [DiscoveredScanner] = []

    // MARK: Private
    var session: URLSession!   // internal so the discovery extension can reuse it
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: WebSocket lifecycle

    func connect() {
        disconnect()
        guard let url = URL(string: "ws://\(host):\(wsPort)/") else {
            status = "Bad URL"; return
        }
        status = "Connecting to \(url.absoluteString)…"
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
        startHeartbeat()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if connected { status = "Disconnected" }
        connected = false
    }

    /// We send our own pings too; the server also pings us and URLSession pongs
    /// automatically. Either way the link is kept warm.
    private func startHeartbeat() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.task?.sendPing { _ in } }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.status = "Closed: \(error.localizedDescription)"
                    self.connected = false
                    self.pingTimer?.invalidate()
                case .success(let message):
                    switch message {
                    case .string(let s):
                        let d = Data(s.utf8)
                        self.record(FrameRecord(time: Date(), direction: .incoming,
                                                isText: true, kind: PayloadKind.classify(d),
                                                size: d.count, data: d))
                    case .data(let d):
                        self.record(FrameRecord(time: Date(), direction: .incoming,
                                                isText: false, kind: PayloadKind.classify(d),
                                                size: d.count, data: d))
                    @unknown default: break
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    // MARK: Sending

    func send(text: String) {
        guard let t = task else { status = "Not connected"; return }
        let d = Data(text.utf8)
        record(FrameRecord(time: Date(), direction: .outgoing, isText: true,
                           kind: PayloadKind.classify(d), size: d.count, data: d))
        t.send(.string(text)) { [weak self] err in
            if let err { Task { @MainActor in self?.status = "Send failed: \(err.localizedDescription)" } }
        }
    }

    func send(binary: Data) {
        guard let t = task else { status = "Not connected"; return }
        record(FrameRecord(time: Date(), direction: .outgoing, isText: false,
                           kind: PayloadKind.classify(binary), size: binary.count, data: binary))
        t.send(.data(binary)) { [weak self] err in
            if let err { Task { @MainActor in self?.status = "Send failed: \(err.localizedDescription)" } }
        }
    }

    private func record(_ f: FrameRecord) {
        frames.append(f)
        // keep memory bounded for long live sessions
        if frames.count > 5000 { frames.removeFirst(frames.count - 5000) }
    }

    func clearFrames() { frames.removeAll() }

    // MARK: HTTP fetch (:8080)

    func httpGet() {
        let path = httpPath.hasPrefix("/") ? httpPath : "/" + httpPath
        guard let url = URL(string: "http://\(host):\(httpPort)\(path)") else {
            httpStatus = "Bad URL"; return
        }
        httpStatus = "GET \(url.absoluteString) …"
        httpBody = nil
        session.dataTask(with: url) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.httpStatus = "Error: \(err.localizedDescription)"; return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let len = data?.count ?? 0
                let kind = data.map { PayloadKind.classify($0) } ?? .binary
                self.httpStatus = "HTTP \(code) · \(len) bytes · \(kind.rawValue)"
                self.httpBody = data
            }
        }.resume()
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol proto: String?) {
        Task { @MainActor in
            self.connected = true
            self.status = "Connected to \(self.host):\(self.wsPort)"
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor in
            self.connected = false
            self.status = "Server closed (code \(closeCode.rawValue))\(r.isEmpty ? "" : ": \(r)")"
            self.pingTimer?.invalidate()
        }
    }
}
