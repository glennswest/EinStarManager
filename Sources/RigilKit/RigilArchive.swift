import Foundation

/// Pulls individual files out of a raw Rigil data-channel stream (the bytes the
/// scanner sends on the env-0x02 connection during a download). Two payload shapes:
///  - a Qt `QVariantMap` bundle: keys are filenames, values are `QByteArray`/`QString`.
///  - PNG blobs (previews), carved by signature.
///
/// This is the Swift port of the proven `Scripts/extract-capture.py` logic.
public enum RigilArchive {

    public struct File: Sendable {
        public let name: String
        public let data: Data
    }

    /// Carve every PNG (preview thumbnails) from a stream by magic bytes.
    public static func carvePNGs(_ data: Data) -> [Data] {
        let sig = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let end = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        var out: [Data] = []
        var pos = data.startIndex
        while let s = data.range(of: sig, in: pos..<data.endIndex) {
            guard let e = data.range(of: end, in: s.lowerBound..<data.endIndex) else { break }
            out.append(data.subdata(in: s.lowerBound..<e.upperBound))
            pos = e.upperBound
        }
        return out
    }

    /// Extract named files from `QVariantMap`-bundled env-0x02 frames.
    public static func extractFiles(_ data: Data) -> [File] {
        var files: [String: Data] = [:]
        var order: [String] = []
        var i = data.startIndex
        let n = data.count

        func u32be(_ idx: Int) -> Int {
            Int(data[data.index(data.startIndex, offsetBy: idx)]) << 24
              | Int(data[data.index(data.startIndex, offsetBy: idx + 1)]) << 16
              | Int(data[data.index(data.startIndex, offsetBy: idx + 2)]) << 8
              | Int(data[data.index(data.startIndex, offsetBy: idx + 3)])
        }

        var off = 0
        while off + 10 <= n {
            let total = u32be(off)
            let marker = data[data.index(data.startIndex, offsetBy: off + 4)]
            if marker != 1 || total < 6 || off + 4 + total > n { off += 1; continue }
            let plen = u32be(off + 6)
            if plen != total - 6 { off += 1; continue }
            let pStart = off + 10
            let payload = data.subdata(in: data.index(data.startIndex, offsetBy: pStart)
                                        ..< data.index(data.startIndex, offsetBy: pStart + plen))
            scanQVariantMap(payload, into: &files, order: &order)
            off += 4 + total
        }
        _ = i
        return order.map { File(name: $0, data: files[$0]!) }
    }

    /// Within one frame payload, find `[u32 nameLen BE][UTF16BE name][u32 type][isNull][u32 len][data]`
    /// entries whose value is a QString(10)/QByteArray(12) and whose name looks like a filename.
    private static func scanQVariantMap(_ p: Data, into files: inout [String: Data], order: inout [String]) {
        let bytes = [UInt8](p)
        let n = bytes.count
        func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3]) }
        var j = 0
        while j + 4 < n {
            let ln = u32(j)
            // candidate UTF-16BE name?
            if ln > 0, ln <= 512, ln % 2 == 0, j + 4 + ln <= n {
                let nameBytes = Array(bytes[(j+4)..<(j+4+ln)])
                if let name = utf16beString(nameBytes), name.allSatisfy({ $0.isASCII && !$0.isNewline }), name.contains(".") {
                    let k = j + 4 + ln
                    if k + 5 <= n {
                        let t = u32(k)
                        var o = k + 4
                        if (t == 10 || t == 12), o + 5 <= n {
                            o += 1 // isNull
                            let dlen = u32(o); o += 4
                            if dlen != 0xFFFF_FFFF, dlen >= 0, o + dlen <= n {
                                if files[name] == nil {
                                    files[name] = Data(bytes[o..<(o+dlen)]); order.append(name)
                                }
                                j = o + dlen; continue
                            }
                        }
                    }
                    j = k; continue
                }
            }
            j += 1
        }
    }

    private static func utf16beString(_ b: [UInt8]) -> String? {
        var scalars = ""
        var i = 0
        while i + 1 < b.count {
            let u = UInt16(b[i]) << 8 | UInt16(b[i+1])
            guard let s = Unicode.Scalar(u) else { return nil }
            scalars.unicodeScalars.append(s)
            i += 2
        }
        return scalars
    }
}
