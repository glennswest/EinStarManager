import Foundation

/// A minimal CBOR (RFC 8949) value model — just enough for the Rigil control
/// plane (maps, arrays, text/byte strings, ints, bools, floats).
public indirect enum CBOR: Equatable, Sendable {
    case uint(UInt64)
    case nint(Int64)          // negative integer
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case double(Double)
    case null

    public static func == (l: CBOR, r: CBOR) -> Bool {
        switch (l, r) {
        case let (.uint(a), .uint(b)):   return a == b
        case let (.nint(a), .nint(b)):   return a == b
        case let (.bytes(a), .bytes(b)): return a == b
        case let (.text(a), .text(b)):   return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.bool(a), .bool(b)):   return a == b
        case let (.double(a), .double(b)): return a == b
        case (.null, .null):             return true
        case let (.map(a), .map(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

// MARK: - Ergonomic literals (for building requests)

extension CBOR: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
                ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral v: String)  { self = .text(v) }
    public init(integerLiteral v: Int)    { self = v >= 0 ? .uint(UInt64(v)) : .nint(Int64(v)) }
    public init(booleanLiteral v: Bool)   { self = .bool(v) }
    public init(floatLiteral v: Double)   { self = .double(v) }
    public init(arrayLiteral els: CBOR...) { self = .array(els) }
    public init(dictionaryLiteral pairs: (CBOR, CBOR)...) { self = .map(pairs) }
}

// MARK: - Accessors

public extension CBOR {
    subscript(_ key: String) -> CBOR? {
        if case let .map(pairs) = self {
            for (k, v) in pairs where k == .text(key) { return v }
        }
        return nil
    }
    var stringValue: String? { if case let .text(s) = self { return s }; return nil }
    var intValue: Int? {
        switch self {
        case let .uint(u): return Int(u)
        case let .nint(n): return Int(n)
        case let .double(d): return Int(d)
        default: return nil
        }
    }
    var int64Value: Int64? {
        switch self {
        case let .uint(u): return Int64(u)
        case let .nint(n): return n
        default: return nil
        }
    }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .uint(u): return Double(u)
        case let .nint(n): return Double(n)
        default: return nil
        }
    }
    var arrayValue: [CBOR]? { if case let .array(a) = self { return a }; return nil }
    /// Map as an ordered list of (key, value) pairs.
    var mapPairs: [(CBOR, CBOR)]? { if case let .map(p) = self { return p }; return nil }
}

// MARK: - Encoding

public extension CBOR {
    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func head(_ major: UInt8, _ n: UInt64, into out: inout Data) {
        let mt = major << 5
        switch n {
        case ..<24:            out.append(mt | UInt8(n))
        case ..<0x100:         out.append(mt | 24); out.append(UInt8(n))
        case ..<0x1_0000:      out.append(mt | 25); appendBE(UInt16(n), &out)
        case ..<0x1_0000_0000: out.append(mt | 26); appendBE(UInt32(n), &out)
        default:               out.append(mt | 27); appendBE(n, &out)
        }
    }

    private func encode(into out: inout Data) {
        switch self {
        case let .uint(u): head(0, u, into: &out)
        case let .nint(n): head(1, UInt64(-1 - n), into: &out)
        case let .bytes(d): head(2, UInt64(d.count), into: &out); out.append(d)
        case let .text(s):
            let d = Data(s.utf8); head(3, UInt64(d.count), into: &out); out.append(d)
        case let .array(a):
            head(4, UInt64(a.count), into: &out); a.forEach { $0.encode(into: &out) }
        case let .map(pairs):
            head(5, UInt64(pairs.count), into: &out)
            for (k, v) in pairs { k.encode(into: &out); v.encode(into: &out) }
        case let .bool(b): out.append(b ? 0xf5 : 0xf4)
        case .null:        out.append(0xf6)
        case let .double(d):
            out.append(0xfb); appendBE(d.bitPattern, &out)
        }
    }
}

private func appendBE<T: FixedWidthInteger>(_ v: T, _ out: inout Data) {
    var be = v.bigEndian
    withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
}

// MARK: - Decoding

public enum CBORError: Error { case truncated, malformed }

public extension CBOR {
    static func decode(_ data: Data) throws -> CBOR {
        var i = data.startIndex
        return try decode(data, &i)
    }

    private static func readBE<T: FixedWidthInteger>(_ data: Data, _ i: inout Data.Index, _ type: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard data.distance(from: i, to: data.endIndex) >= n else { throw CBORError.truncated }
        var v: T = 0
        for _ in 0..<n { v = (v << 8) | T(data[i]); i = data.index(after: i) }
        return v
    }

    private static func length(_ ai: UInt8, _ data: Data, _ i: inout Data.Index) throws -> UInt64 {
        switch ai {
        case ..<24: return UInt64(ai)
        case 24: guard i < data.endIndex else { throw CBORError.truncated }
                 let b = data[i]; i = data.index(after: i); return UInt64(b)
        case 25: return UInt64(try readBE(data, &i, UInt16.self))
        case 26: return UInt64(try readBE(data, &i, UInt32.self))
        case 27: return try readBE(data, &i, UInt64.self)
        default: throw CBORError.malformed
        }
    }

    private static func decode(_ data: Data, _ i: inout Data.Index) throws -> CBOR {
        guard i < data.endIndex else { throw CBORError.truncated }
        let initial = data[i]; i = data.index(after: i)
        let major = initial >> 5, ai = initial & 0x1f

        switch major {
        case 0: return .uint(try length(ai, data, &i))
        case 1: return .nint(-1 - Int64(try length(ai, data, &i)))
        case 2:
            let n = Int(try length(ai, data, &i))
            guard data.distance(from: i, to: data.endIndex) >= n else { throw CBORError.truncated }
            let d = data.subdata(in: i..<data.index(i, offsetBy: n))
            i = data.index(i, offsetBy: n); return .bytes(d)
        case 3:
            let n = Int(try length(ai, data, &i))
            guard data.distance(from: i, to: data.endIndex) >= n else { throw CBORError.truncated }
            let d = data.subdata(in: i..<data.index(i, offsetBy: n))
            i = data.index(i, offsetBy: n)
            return .text(String(decoding: d, as: UTF8.self))
        case 4:
            let n = Int(try length(ai, data, &i))
            var arr: [CBOR] = []; arr.reserveCapacity(n)
            for _ in 0..<n { arr.append(try decode(data, &i)) }
            return .array(arr)
        case 5:
            let n = Int(try length(ai, data, &i))
            var pairs: [(CBOR, CBOR)] = []; pairs.reserveCapacity(n)
            for _ in 0..<n { let k = try decode(data, &i); let v = try decode(data, &i); pairs.append((k, v)) }
            return .map(pairs)
        case 7:
            switch ai {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            case 25: _ = try readBE(data, &i, UInt16.self); return .double(0)   // half — rarely used here
            case 26: return .double(Double(Float(bitPattern: try readBE(data, &i, UInt32.self))))
            case 27: return .double(Double(bitPattern: try readBE(data, &i, UInt64.self)))
            default: throw CBORError.malformed
            }
        default: throw CBORError.malformed
        }
    }
}
