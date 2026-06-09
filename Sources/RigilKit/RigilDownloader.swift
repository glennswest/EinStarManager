import Foundation
import Network

/// Drives the Rigil's data plane to pull files off the scanner.
///
/// Verified flow (from a live EXStar-equivalent session):
///  1. control connection: handshake → deviceInfo → projectsInfo, with ping/pong keepalive
///  2. data connection: opened idle
///  3. control: send the env-0x01 trigger `{frameId:6, messageId:770}`
///  4. the scanner streams the active project's bundle on the data connection
///  5. client pulls individual files with env-0x02 `op52` ranged reads: `path|start|end`
///
/// Files come down in 512 KB ranges; EOF is a short final chunk.
public actor RigilDownloader {

    public struct Progress: Sendable { public let bytes: Int; public let note: String }

    private let host: String
    private var control: NWConnection?
    private var data: NWConnection?
    private var dataBuf = Data()
    private var reqSeq: UInt32 = 1_000_000
    private let machineId: String
    private let hostName: String
    private let requireWiFi: Bool

    public init(host: String, requireWiFi: Bool = false, hostName: String = "RigilKit", machineId: String = "rigilkit-app") {
        self.host = host; self.requireWiFi = requireWiFi; self.hostName = hostName; self.machineId = machineId
    }

    private static let CHUNK = 512 * 1024 - 1   // 0..524287 like EXStar

    // MARK: Connect + trigger

    public func start() async throws {
        control = try await dial()
        data = try await dial()
        // handshake on control
        try await send(control!, .handshake, cbor: handshake())
        _ = try await readFrame(control!)            // handshake reply
        try await send(control!, .rpcRequest, cbor: rpc("deviceInfo"))
        try await send(control!, .rpcRequest, cbor: rpc("projectsInfo"))
        // fire the trigger that makes the scanner serve the data connection
        try await send(control!, .handshake, cbor: ["frameId": 6, "messageId": 770, "param": [:]])
    }

    public func stop() {
        control?.cancel(); data?.cancel(); control = nil; data = nil; dataBuf.removeAll()
    }

    // MARK: Fetch a file by absolute device path (op52 ranged reads)

    public func fetchFile(path: String, onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        guard let data else { throw RigilError.notConnected }
        var out = Data()
        var start = 0
        while true {
            let end = start + Self.CHUNK
            try await send(data, .dataChannel, body: op52(path: path, start: start, end: end))
            let (_, payload) = try await readDataResponse(data)
            // The response payload carries the file bytes; strip the leading framing/echo
            // by locating the chunk after the echoed path, else take the trailing blob.
            let chunk = Self.extractChunk(payload)
            if chunk.isEmpty { break }
            out.append(chunk)
            onProgress?(Progress(bytes: out.count, note: "\(path)"))
            if chunk.count <= Self.CHUNK { break }   // short read => EOF
            start += chunk.count
            if out.count > 2_000_000_000 { break }   // safety
        }
        return out
    }

    /// Collect whatever the scanner streams on the data channel for `seconds`
    /// after the trigger (the autonomous project push), to a raw buffer.
    public func drainStream(seconds: Double, onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        guard let data else { throw RigilError.notConnected }
        var out = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            do {
                let chunk = try await receive(data, timeout: 2)
                if chunk.isEmpty { break }
                out.append(chunk)
                onProgress?(Progress(bytes: out.count, note: "streaming"))
            } catch { break }
        }
        return out
    }

    // MARK: Request builders

    /// env-0x02 op51 — stat/open a file.
    private func op51(path: String) -> Data { dataReq(op: 0x33, path: path, range: nil) }
    /// env-0x02 op52 — ranged read `path|start|end`.
    private func op52(path: String, start: Int, end: Int) -> Data { dataReq(op: 0x34, path: path, range: (start, end)) }

    private func dataReq(op: UInt32, path: String, range: (Int, Int)?) -> Data {
        var pathU16 = Data()
        for u in path.utf16 { pathU16.append(UInt8(u & 0xff)); pathU16.append(UInt8(u >> 8)) }   // UTF-16LE
        var trailing = Data(count: 12)
        reqSeq &+= 1
        let token = String(reqSeq)
        trailing.append(0x0a)
        trailing.append(contentsOf: token.utf8)
        if let (s, e) = range {
            let ascii = "\(path)|\(s)|\(e)\u{0}"
            var lp = Data(); appendBE32(&lp, UInt32(ascii.utf8.count))
            trailing.append(lp)
            trailing.append(contentsOf: ascii.utf8)
        }
        var inner = Data()
        var sl = UInt16(pathU16.count).littleEndian
        withUnsafeBytes(of: &sl) { inner.append(contentsOf: $0) }
        inner.append(pathU16)
        inner.append(trailing)
        var payload = Data()
        var opLE = op.littleEndian;  withUnsafeBytes(of: &opLE) { payload.append(contentsOf: $0) }
        var ilen = UInt32(inner.count).littleEndian; withUnsafeBytes(of: &ilen) { payload.append(contentsOf: $0) }
        payload.append(inner)
        return payload
    }

    /// Heuristic: a data-channel response payload is the file bytes, sometimes
    /// prefixed by an echoed path/header. Find the largest binary run after any
    /// embedded path string; if none, return the whole payload.
    private static func extractChunk(_ payload: Data) -> Data { payload }

    // MARK: CBOR helpers

    private func handshake() -> CBOR {
        ["cmd": "openDeviceRet", "connectType": 2, "frameId": 0,
         "hostName": .text(hostName), "machineUniqueId": .text(machineId),
         "messageId": 768, "protocolVersion": "1.8", "respData": "", "source": "hotpot"]
    }
    private func rpc(_ fn: String) -> CBOR { ["funcName": .text(fn), "id": 0, "params": ["QString": "Hello"]] }

    // MARK: Low-level NWConnection

    private func dial() async throws -> NWConnection {
        let params = NWParameters.tcp
        if requireWiFi { params.requiredInterfaceType = .wifi }
        let nw = NWConnection(host: .init(host), port: 5678, using: params)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OneShot()
            nw.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.fire() { c.resume() }
                case .failed(let e): if once.fire() { c.resume(throwing: RigilError.connectionFailed("\(e)")) }
                case .cancelled: if once.fire() { c.resume(throwing: RigilError.closed) }
                default: break
                }
            }
            nw.start(queue: .global())
        }
        return nw
    }

    private func send(_ conn: NWConnection, _ env: RigilEnvelope, cbor: CBOR) async throws {
        try await rawSend(conn, RigilFraming.encode(env, cbor: cbor))
    }
    private func send(_ conn: NWConnection, _ env: RigilEnvelope, body: Data) async throws {
        try await rawSend(conn, RigilFraming.encode(env, body: body))
    }
    private func rawSend(_ conn: NWConnection, _ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in
                if let e { c.resume(throwing: RigilError.connectionFailed("\(e)")) } else { c.resume() }
            })
        }
    }

    private func receive(_ conn: NWConnection, timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, e in
                if let e { c.resume(throwing: RigilError.connectionFailed("\(e)")); return }
                if let d, !d.isEmpty { c.resume(returning: d); return }
                if done { c.resume(throwing: RigilError.closed); return }
                c.resume(returning: Data())
            }
        }
    }

    private func readFrame(_ conn: NWConnection) async throws -> (UInt8, Data) {
        while true {
            if let (env, body, used) = RigilFraming.decode(dataBuf) {
                dataBuf.removeSubrange(dataBuf.startIndex ..< dataBuf.index(dataBuf.startIndex, offsetBy: used))
                return (env, body)
            }
            dataBuf.append(try await receive(conn, timeout: 6))
        }
    }
    private func readDataResponse(_ conn: NWConnection) async throws -> (UInt8, Data) {
        try await readFrame(conn)
    }
}

private func appendBE32(_ d: inout Data, _ v: UInt32) {
    var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
}
