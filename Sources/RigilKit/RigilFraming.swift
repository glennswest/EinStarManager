import Foundation

/// The 6th byte of every port-5678 frame selects the sub-protocol.
public enum RigilEnvelope: UInt8, Sendable {
    case handshake   = 0x01   // CBOR openDeviceRet
    case dataChannel = 0x02   // Qt-serialized file channel
    case rpcRequest  = 0x07   // CBOR { funcName, id, params }
    case rpcResponse = 0x08   // CBOR { id, ErrorCode, result }
}

/// Wire framing for the Rigil control protocol:
/// `[u32 total BE][0x01][envelope][u32 bodyLen BE][body]`, where
/// `total = 1 + 1 + 4 + bodyLen`.
public enum RigilFraming {

    public static func encode(_ envelope: RigilEnvelope, body: Data) -> Data {
        var out = Data()
        let total = UInt32(2 + 4 + body.count)
        out.append(bigEndian: total)
        out.append(0x01)
        out.append(envelope.rawValue)
        out.append(bigEndian: UInt32(body.count))
        out.append(body)
        return out
    }

    public static func encode(_ envelope: RigilEnvelope, cbor: CBOR) -> Data {
        encode(envelope, body: cbor.encoded())
    }

    /// Parse one frame from the front of `buffer`. Returns the envelope byte, the
    /// body, and the number of bytes consumed — or nil if `buffer` is short.
    public static func decode(_ buffer: Data) -> (envelope: UInt8, body: Data, consumed: Int)? {
        guard buffer.count >= 10 else { return nil }
        let base = buffer.startIndex
        let total = Int(buffer.readBE(at: base, UInt32.self))
        guard buffer.count >= 4 + total else { return nil }
        let envelope = buffer[base + 5]
        let bodyLen = Int(buffer.readBE(at: base + 6, UInt32.self))
        let start = base + 10
        let body = buffer.subdata(in: start ..< start + bodyLen)
        return (envelope, body, 4 + total)
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    func readBE<T: FixedWidthInteger>(at index: Index, _ type: T.Type) -> T {
        var v: T = 0
        for k in 0..<MemoryLayout<T>.size { v = (v << 8) | T(self[index + k]) }
        return v
    }
}
