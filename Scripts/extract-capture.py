#!/usr/bin/env python3
"""
extract-capture.py — carve EinScan Rigil project files out of a Wireshark capture
of an EXStar <-> scanner download session.

The Rigil's download is plaintext (framed Qt-serialized data on the TCP 5678 "data"
connection), so a full project can be reconstructed offline from a pcap — no live
scanner needed. See PROTOCOL.md for the wire format.

Usage:
    # 1) find the data stream (the high-byte-count TCP conversation to the scanner:5678)
    tshark -r capture.pcapng -q -z conv,tcp | sort -k3 -h | tail

    # 2) extract that stream's server->client bytes to a binary blob
    tshark -r capture.pcapng -o tcp.desegment_tcp_streams:FALSE \
        -Y "tcp.stream==<N> && ip.src==<SCANNER_IP> && tcp.len>0" \
        -T fields -e tcp.payload | tr -d ':\n' | xxd -r -p > data.bin

    # 3) carve files
    python3 Scripts/extract-capture.py data.bin out/

Produces: preview_*.png (carved by PNG magic) and every QVariantMap-bundled file
(LeftCCF.txt, *.bin, ...). Ranged FrameCloud_0.dat chunks are not yet reassembled.
"""
import struct, sys, os

def carve_pngs(data, out):
    SIG = b'\x89PNG\r\n\x1a\n'; END = b'IEND\xaeB\x60\x82'
    n = pos = 0
    while True:
        s = data.find(SIG, pos)
        if s < 0: break
        e = data.find(END, s)
        if e < 0: break
        e += len(END)
        open(os.path.join(out, f"preview_{n}.png"), "wb").write(data[s:e])
        n += 1; pos = e
    return n

def utf16be_name(b, j):
    if j + 4 > len(b): return None
    ln = struct.unpack(">I", b[j:j+4])[0]
    if ln == 0 or ln > 512 or ln % 2 or j + 4 + ln > len(b): return None
    try: s = b[j+4:j+4+ln].decode("utf-16-be")
    except Exception: return None
    if not s.isprintable() or not all(32 <= ord(c) < 127 for c in s): return None
    return s, j + 4 + ln

def extract_files(data, out):
    """Walk env-0x02 frames; pull QVariantMap entries whose value is a QString/QByteArray."""
    files = {}; i = frames = 0
    while i + 10 <= len(data):
        total = struct.unpack(">I", data[i:i+4])[0]
        if data[i+4] != 1 or total < 6 or total > 200_000_000:
            i += 1; continue
        plen = struct.unpack(">I", data[i+6:i+10])[0]
        if plen != total - 6 or i + 10 + plen > len(data):
            i += 1; continue
        p = data[i+10:i+10+plen]; frames += 1
        j = 0
        while j + 4 < len(p):
            r = utf16be_name(p, j)
            if not r:
                j += 1; continue
            name, k = r
            if k + 5 <= len(p):
                t = struct.unpack(">I", p[k:k+4])[0]      # QVariant type tag
                off = k + 4
                if t in (10, 12) and off + 5 <= len(p):   # 10=QString, 12=QByteArray
                    off += 1                              # isNull byte
                    dlen = struct.unpack(">I", p[off:off+4])[0]; off += 4
                    if dlen != 0xffffffff and 0 <= dlen <= len(p) - off:
                        if '.' in name and name not in files:
                            files[name] = p[off:off+dlen]
                        j = off + dlen; continue
            j = k
        i += total
    for name, blob in files.items():
        open(os.path.join(out, name.replace("/", "_")), "wb").write(blob)
    return frames, files

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    data = open(sys.argv[1], "rb").read()
    out = sys.argv[2]; os.makedirs(out, exist_ok=True)
    pngs = carve_pngs(data, out)
    frames, files = extract_files(data, out)
    print(f"loaded {len(data)} bytes, {frames} data frames")
    print(f"carved {pngs} PNG(s)")
    for name, blob in files.items():
        print(f"  {name:28s} {len(blob):>10} bytes")
    print(f"-> {out}")

if __name__ == "__main__":
    main()
