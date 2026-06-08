import Foundation
import Network
import Darwin

/// Thread-safe "resume exactly once" guard for bridging callback APIs to a
/// continuation that may be completed from multiple queues (ready/failed/timeout).
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// A host found during a subnet sweep.
struct DiscoveredScanner: Identifiable, Equatable {
    let id = UUID()
    let ip: String
    /// True when the host matches the Einstar Rigil signature
    /// (`:8081` WebSocket + `:8080` returning the telltale `application/x-empty` 404).
    var confirmed: Bool
}

extension ScannerClient {

    /// Background queue for the raw TCP port probes.
    static let probeQueue = DispatchQueue(label: "einstar.discovery", attributes: .concurrent)

    /// Sweep the configured (and locally-attached) /24 subnets for the Einstar.
    /// Stage 1 finds hosts with `:8081` open; stage 2 confirms the Rigil signature
    /// on `:8080`. The first confirmed host is auto-selected as the connection host.
    func discover() async {
        if discovering { return }
        discovering = true
        discovered = []
        defer { discovering = false }

        var prefixes = Set<String>()
        for p in scanPrefixes.split(separator: ",") {
            let t = ScannerClient.normalizePrefix(String(p))
            if !t.isEmpty { prefixes.insert(t) }
        }
        for p in ScannerClient.localIPv4Prefixes() { prefixes.insert(p) }

        guard !prefixes.isEmpty else {
            discoveryProgress = "No subnets to scan."
            return
        }

        let targets = prefixes.sorted().flatMap { pre in (1...254).map { "\(pre).\($0)" } }
        discoveryProgress = "Scanning \(targets.count) addresses on \(prefixes.count) subnet(s)…"

        // Stage 1: which hosts answer on :8081
        let openHosts = await concurrentFilter(targets, limit: 128) { ip in
            await ScannerClient.tcpOpen(ip, port: 8081, timeoutMs: 350)
        }.sorted(by: ScannerClient.ipLess)

        if openHosts.isEmpty {
            discoveryProgress = "No host with :8081 open on \(prefixes.sorted().joined(separator: ", "))."
            return
        }
        discoveryProgress = "Found \(openHosts.count) host(s) on :8081 — verifying…"

        // Stage 2: confirm the Rigil signature on :8080
        var foundConfirmed = false
        for ip in openHosts {
            let ok = await verifyRigil(ip)
            discovered.append(DiscoveredScanner(ip: ip, confirmed: ok))
            if ok && !foundConfirmed {
                foundConfirmed = true
                host = ip
                wsPort = "8081"
                httpPort = "8080"
            }
        }

        let confirmed = discovered.filter { $0.confirmed }
        if let first = confirmed.first {
            let extra = confirmed.count > 1 ? " (+\(confirmed.count - 1) more)" : ""
            discoveryProgress = "Einstar found at \(first.ip)\(extra) — selected."
            status = "Discovered Einstar at \(first.ip)"
        } else {
            discoveryProgress = "\(discovered.count) host(s) had :8081 open, but none matched the Einstar signature."
        }
    }

    /// Confirm a host is the Rigil: its `:8080` returns the distinctive
    /// `application/x-empty` content type (an empty 404).
    func verifyRigil(_ ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):8080/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                return ct.contains("application/x-empty")
            }
        } catch { }
        return false
    }

    // MARK: - Helpers

    /// Run `predicate` over `items` with bounded concurrency; return the matches.
    private func concurrentFilter(_ items: [String], limit: Int,
                                  _ predicate: @escaping @Sendable (String) async -> Bool) async -> [String] {
        var result: [String] = []
        var next = 0
        await withTaskGroup(of: (String, Bool).self) { group in
            func schedule() {
                guard next < items.count else { return }
                let item = items[next]; next += 1
                group.addTask { (item, await predicate(item)) }
            }
            for _ in 0..<min(limit, items.count) { schedule() }
            for await (item, ok) in group {
                if ok { result.append(item) }
                schedule()
            }
        }
        return result
    }

    /// Async TCP connect test using Network framework. Returns true if the port
    /// accepts a connection within `timeoutMs`.
    static func tcpOpen(_ ip: String, port: UInt16, timeoutMs: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
            let guardRef = ResumeGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardRef.fire() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled:
                    if guardRef.fire() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if guardRef.fire() { conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    /// Reduce user input like "192.168.9.0/24", "192.168.9.5", "192.168.9" to the
    /// /24 prefix "192.168.9".
    static func normalizePrefix(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        let parts = t.split(separator: ".")
        guard parts.count >= 3 else { return "" }
        return parts.prefix(3).joined(separator: ".")
    }

    /// /24 prefixes of the Mac's own active, non-loopback IPv4 interfaces.
    static func localIPv4Prefixes() -> [String] {
        var prefixes = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
               let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuf)
                    let p = normalizePrefix(ip)
                    if !p.isEmpty { prefixes.insert(p) }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return Array(prefixes)
    }

    /// Numeric ordering for dotted-quad IPs.
    static func ipLess(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        return key(a).lexicographicallyPrecedes(key(b))
    }
}
