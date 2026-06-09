import Foundation
import Network

public enum RigilError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    case closed
    case rpc(code: Int)
    case badResponse
}

/// Async client for the Rigil control plane (TCP 5678).
///
/// Verified working live: `connect` → `handshake` → `deviceInfo` / `projectsInfo`,
/// with automatic ping→pong keepalive. The data/download plane is documented in
/// PROTOCOL.md but not yet driven from here (its live trigger is project-selection gated).
public actor RigilControlClient {

    private var conn: NWConnection?
    private var buffer = Data()
    private var nextId = 0

    public let hostName: String
    public let machineId: String

    public init(hostName: String = "RigilKit", machineId: String = "rigilkit-0000") {
        self.hostName = hostName
        self.machineId = machineId
    }

    // MARK: Connect

    public func connect(host: String, port: UInt16 = 5678, requireWiFi: Bool = false) async throws {
        let params = NWParameters.tcp
        if requireWiFi { params.requiredInterfaceType = .wifi }   // pin to Wi-Fi, ignore default route
        let nw = NWConnection(host: .init(host),
                              port: .init(rawValue: port)!,
                              using: params)
        self.conn = nw
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let guarded = OneShot()
            nw.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guarded.fire() { cont.resume() }
                case .failed(let e):
                    if guarded.fire() { cont.resume(throwing: RigilError.connectionFailed("\(e)")) }
                case .cancelled:
                    if guarded.fire() { cont.resume(throwing: RigilError.closed) }
                default: break
                }
            }
            nw.start(queue: .global())
        }
    }

    public func disconnect() {
        conn?.cancel()
        conn = nil
        buffer.removeAll()
    }

    // MARK: Handshake & RPC

    @discardableResult
    public func handshake() async throws -> RigilHandshake {
        let hs: CBOR = [
            "cmd": "openDeviceRet", "connectType": 2, "frameId": 0,
            "hostName": .text(hostName), "machineUniqueId": .text(machineId),
            "messageId": 768, "protocolVersion": "1.8", "respData": "", "source": "hotpot",
        ]
        try await send(.handshake, hs)
        let reply = try await readMatching { env, _ in env == RigilEnvelope.handshake.rawValue }
        return RigilHandshake(
            deviceName: reply["deviceName"]?.stringValue ?? "",
            serialNumber: reply["deviceSerialNumber"]?.stringValue ?? "",
            protocolVersion: reply["protocolVersion"]?.stringValue ?? "",
            clientAddr: reply["addr"]?.stringValue ?? "")
    }

    /// Issue an RPC and return its `result` value.
    public func call(_ funcName: String, params: CBOR = ["QString": "Hello"]) async throws -> CBOR {
        let id = nextId; nextId += 1
        let req: CBOR = ["funcName": .text(funcName), "id": .uint(UInt64(id)), "params": params]
        try await send(.rpcRequest, req)
        let resp = try await readMatching { env, body in
            env == RigilEnvelope.rpcResponse.rawValue
                && (try? CBOR.decode(body))?["id"]?.intValue == id
        }
        if let code = resp["ErrorCode"]?.intValue, code != 0 { throw RigilError.rpc(code: code) }
        guard let result = resp["result"] else { throw RigilError.badResponse }
        return result
    }

    public func deviceInfo() async throws -> RigilDeviceInfo {
        RigilDeviceInfo(try await call("deviceInfo"))
    }

    /// List the stored scans/objects on the device.
    public func projects() async throws -> [RigilProject] {
        RigilProject.list(from: try await call("projectsInfo"))
    }

    // MARK: Frame I/O

    private func send(_ env: RigilEnvelope, _ cbor: CBOR) async throws {
        guard let conn else { throw RigilError.notConnected }
        let data = RigilFraming.encode(env, cbor: cbor)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: RigilError.connectionFailed("\(err)")) }
                else { cont.resume() }
            })
        }
    }

    /// Read frames until `predicate` matches, transparently answering pings.
    private func readMatching(_ predicate: (UInt8, Data) -> Bool) async throws -> CBOR {
        while true {
            let (env, body) = try await readFrame()
            // keepalive: reply to pings on the same envelope
            if let obj = try? CBOR.decode(body), obj["type"]?.stringValue == "ping" {
                let pong: CBOR = ["type": "pong",
                                  "timeout": .uint(UInt64(obj["timeout"]?.intValue ?? 6000)),
                                  "timestamp": .uint(UInt64(obj["timestamp"]?.int64Value ?? 0))]
                if let e = RigilEnvelope(rawValue: env) { try? await send(e, pong) }
                continue
            }
            if predicate(env, body) {
                return (try? CBOR.decode(body)) ?? .null
            }
            // otherwise ignore (telemetry, unrelated pushes) and keep reading
        }
    }

    private func readFrame() async throws -> (UInt8, Data) {
        while true {
            if let (env, body, consumed) = RigilFraming.decode(buffer) {
                buffer.removeSubrange(buffer.startIndex ..< buffer.index(buffer.startIndex, offsetBy: consumed))
                return (env, body)
            }
            try await fill()
        }
    }

    private func fill() async throws {
        guard let conn else { throw RigilError.notConnected }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, err in
                if let err { cont.resume(throwing: RigilError.connectionFailed("\(err)")); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: RigilError.closed); return }
                cont.resume(returning: Data())
            }
        }
        buffer.append(chunk)
    }
}

/// Resume-exactly-once guard for bridging callbacks to a continuation.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
