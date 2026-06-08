import Foundation

/// Best-effort classification of a received binary payload so the UI can label
/// frames and suggest a sensible file extension when saving.
enum PayloadKind: String {
    case stlAscii   = "STL (ASCII)"
    case stlBinary  = "STL (binary)"
    case ply        = "PLY"
    case obj        = "OBJ"
    case png        = "PNG image"
    case jpeg       = "JPEG image"
    case json       = "JSON"
    case text       = "Text"
    case binary     = "Binary"

    var fileExtension: String {
        switch self {
        case .stlAscii, .stlBinary: return "stl"
        case .ply:    return "ply"
        case .obj:    return "obj"
        case .png:    return "png"
        case .jpeg:   return "jpg"
        case .json:   return "json"
        case .text:   return "txt"
        case .binary: return "bin"
        }
    }

    static func classify(_ data: Data) -> PayloadKind {
        guard !data.isEmpty else { return .binary }
        let n = data.count
        let head = data.prefix(16)

        // Image magic numbers
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }

        // ASCII-ish prefixes
        if let s = String(data: data.prefix(80), encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.hasPrefix("solid ") { return .stlAscii }
            if t.hasPrefix("ply") { return .ply }
            if t.hasPrefix("v ") || t.hasPrefix("# ") || t.hasPrefix("o ") || t.hasPrefix("mtllib") { return .obj }
            if t.hasPrefix("{") || t.hasPrefix("[") { return .json }
        }

        // Binary STL: 80-byte header + UInt32 triangle count, then count*50 bytes.
        if n >= 84 {
            let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
            if Int(count) > 0 && n == 84 + Int(count) * 50 { return .stlBinary }
        }

        // Mostly-printable -> text
        let sample = data.prefix(256)
        let printable = sample.filter { $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }.count
        if !sample.isEmpty && Double(printable) / Double(sample.count) > 0.9 { return .text }

        return .binary
    }
}

extension Data {
    /// Compact hex preview, capped to `limit` bytes.
    func hexPreview(limit: Int = 64) -> String {
        prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    func asciiPreview(limit: Int = 64) -> String {
        String(prefix(limit).map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}
