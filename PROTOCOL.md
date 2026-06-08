# EinScan Rigil — WiFi Protocol (reverse-engineered)

Reverse-engineered from a live `EinScan Rigil Lite` (serial `EinScanRigilMMB-BF031C20B`,
appVersion `1.3.1-alpha.19`, protocolVersion `1.8`) and a 1.18 GB Wireshark capture of
the Windows **EXStar** client talking to it.

> Status: **control plane verified live** (handshake, `deviceInfo`, `projectsInfo` object
> listing, ping/pong). **Three-channel architecture mapped** (control + data + ZeroMQ event
> bus). **Download/file format fully decoded** and files (previews, calibration) extracted
> straight from the capture; the live trigger to start a standalone download is identified
> but still gated by a project-selection step.

## Transport overview

EXStar uses **three** concurrent TCP connections, opened back-to-back at session start:

| Port | Conn | Proto | Role |
|------|------|-------|------|
| **5678** | #1 control | framed CBOR | handshake, RPC (`deviceInfo`, `projectsInfo`), ping/pong, telemetry |
| **5678** | #2 data | framed Qt-serialized | **file/download stream** — opens idle, the scanner pushes a project here once triggered on the control conn |
| **6789** | #3 events | **ZeroMQ ZMTP 3.0 PUB/SUB** | scanner=PUB, client=SUB to topic **`TXCommData`** (event/notification bus) |

Other services (not used by EXStar):

| Port | Proto | Role |
|------|-------|------|
| 8081 | WebSocket (`Server: webserver`) | web/mobile control channel (pings, closes on bad cmd) |
| 8080 | HTTP | resource server; bare GETs → `404 application/x-empty` (the discovery signature) |
| 21 / 22 / 443 | FTP / SSH / HTTPS | present, unexplored |

The Rigil runs either as its **own WiFi-6 AP** (`192.168.76.1`, gateway/DHCP/DNS) or
**joined to a LAN** via DHCP (routable). It **firewalls ICMP** — discover it by TCP-probing
`:5678`/`:8081`, never by ping.

## Frame format (port 5678)

Every message — both directions — is length-prefixed:

```
+----------+------+----------+-----------+-------------------+
| totalLen | 0x01 | envelope | bodyLen   | body (bodyLen B)  |
|  u32 BE  | u8   |   u8     |  u32 BE   |                   |
+----------+------+----------+-----------+-------------------+
   4 bytes   1      1          4           bodyLen

totalLen = 1 + 1 + 4 + bodyLen   (everything after the first 4 bytes)
```

The 5th byte is always `0x01`. The 6th byte (**envelope**) selects the sub-protocol:

| envelope | direction | body encoding | meaning |
|----------|-----------|---------------|---------|
| `0x01` | both | CBOR map | device open / handshake |
| `0x07` | client→scanner | CBOR map | RPC **request** |
| `0x08` | scanner→client | CBOR map | RPC **response** |
| `0x02` | both | custom (Qt-style, UTF-16LE) | **data/file channel** |

Body for `0x01`/`0x07`/`0x08` is **CBOR** (RFC 8949). Keys are sorted text strings.

## 1. Handshake (envelope `0x01`)

Client opens the TCP connection and sends a CBOR map:

```jsonc
{
  "cmd": "openDeviceRet",
  "connectType": 2,
  "frameId": 0,
  "hostName": "gw17",                 // client host name
  "machineUniqueId": "19db525d-200d-4c69-bd72-3ed24ad76aff",
  "messageId": 768,
  "protocolVersion": "1.8",
  "respData": "",
  "source": "hotpot"
}
```

Scanner replies (envelope `0x01`) with the same shape plus:

```jsonc
{
  "addr": "192.168.8.100",            // echoes the client's IP
  "cmd": "openDeviceRet",
  "deviceName": "EinScan Rigil Lite",
  "deviceSerialNumber": "EinScanRigilMMB-BF031C20B",
  "error": <float>, "result": true, ...
}
```

## 2. Keepalive (ping/pong)

The scanner periodically sends, on whatever envelope the channel uses, a CBOR map:

```jsonc
{ "type": "ping", "timeout": <int>, "timestamp": <int> }
```

The client must reply with the same map but `"type": "pong"` (echo `timeout`/`timestamp`),
or the scanner drops the connection. (URLSession-style libraries that auto-pong WebSocket
control frames do **not** help here — these are application-level CBOR messages.)

## 3. RPC (request `0x07` → response `0x08`)

Request body:

```jsonc
{ "funcName": "<name>", "id": <int>, "params": { "QString": "Hello" } }
```

Response body:

```jsonc
{ "id": <int>, "ErrorCode": 0, "result": <value> }
```

### `funcName: "deviceInfo"`  → device + storage state

```jsonc
{
  "devName": "EinScan Rigil Lite",
  "devSerialNum": "EinScanRigilMMB-BF031C20B",
  "productName": "EinScan Rigil",
  "appVersion": "1.3.1-alpha.19",
  "protocolVersion": "1.8",
  "batteryValue": 0.69, "bCharge": false,
  "devStorageState": "494.4/495",     // GB used/total
  "ssdPath": "/storage/fd2a1ec0-29bc-44b6-86f6-766e2c5f31c7/...",
  "boardInfo": { "boardNumber": "CP-260048C21-ER", "boardVersion": "v1" },
  "deviceParams": "Hardware Version:3.0_FPGA Version:...",
  "active": true, "idle": false, ...
}
```

### `funcName: "projectsInfo"`  → **list of stored scans/objects**

`result` is a map of **groups**; each group is an array of projects:

```jsonc
{
  "Group_1": [
    {
      "Name": "Project_1",
      "Path": "/storage/<uuid>/TX3App/projectgroup/Group_1/Project_1",
      "Uuid": "{0dc3ebe7-402d-4a3b-b4f2-1a355e1306bd}",
      "Size": 16177678,
      "HasMesh": false, "Texture": false, "Merged": false,
      "ScanMode": 2, "ScanResolutionGrade": 1, "ScanTagType": 1, "AlignType": 1,
      "DateTime": "2026-06-07T16:55:02Z",
      "ModifyTime": "2026-06-07 16:55:02",
      "RtInMerge": [1,0,0,0, 0,1,0,0, 0,0,1,0],   // 3x4 transform
      "Version": "6.0.15"
    }
  ],
  "part1": [ { "Name": "Project_1", "HasMesh": true, "Size": 523798071, ... } ]
}
```

This call is **verified working live** — it is how you enumerate objects to download.

## 4. Download trigger (control channel)

The data connection (#2) is opened idle at session start and sends nothing. The scanner
begins streaming a project onto it ~35 ms after the client sends this **env-`0x01`** message
on the **control** connection (right after `deviceInfo`):

```jsonc
{ "frameId": 6, "messageId": 770, "param": {} }
```

`param` is empty — the scanner streams the **currently-selected/active project** (in the
reference capture, the most recent one, `part1`). Replaying this verbatim against a freshly
connected scanner does **not** start a stream, so an additional selection/state step
(likely set via the device UI or an earlier session message) is still required to fully
reproduce a standalone download. Listing (`projectsInfo`) is unaffected and works live.

## 5. Data / file channel (envelope `0x02`)

The body is a Qt-`QDataStream`-style structure, **little-endian**, with **UTF-16LE** path
strings. Two request opcodes:

```
+--------+----------+--------------------------+--------------------+
| opcode | innerLen | QString path (UTF-16LE)  | trailing params    |
| u32 LE | u32 LE   | u32 LE byteLen + chars   | (offset, length…)  |
+--------+----------+--------------------------+--------------------+
```

- `op 0x33` (51) — open/stat a file (get size).
- `op 0x34` (52) — **ranged read**: trailing params carry a byte offset + length, so large
  files come down in many chunks (e.g. the 523 MB `FrameCloud_0.dat`).

### Response payload — Qt `QVariantMap`

Small files arrive bundled as a serialized `QVariantMap`: **keys are filenames**, values are
the file bytes (`QByteArray`) or metadata (`QString`), each as `u32 byteLen (BE)` + data.
One observed bundle contained `calibTime`, `laser`, `LeftCCF.txt`, `RightCCF.txt`,
`left25.bin`, `parallel7.bin`, `right25.bin`. A project directory holds:

| file | contents |
|------|----------|
| `preview.png` | 1440×1080 RGBA thumbnail |
| `LeftCCF.txt` / `RightCCF.txt` / `TexCCF.txt` / `*Long*.txt` | camera calibration (focal length, principal point, distortion `kc`, `T`, `R`, std error) |
| `left25.bin` / `right25.bin` / `parallel7.bin` | structured-light pattern / frame data |
| `cloud.bin`, `frameN/cloud.bin` | per-frame point clouds |
| `FrameCloud_0.dat` | fused point cloud (the bulk of the data) |

### Extracting files from a capture

Because the download is plaintext, a full project can be carved straight out of a pcap —
no live scanner needed. `Scripts/extract-capture.py` reassembles the data stream, carves
`preview.png`s, and writes out every `QVariantMap`-bundled file. (The ranged `op 0x34`
`FrameCloud_0.dat` chunks still need offset-reassembly to rebuild the full point cloud.)

### Object → STL

The Rigil stores raw scan/point-cloud data, not STL. STL/OBJ/PLY are produced by the host
(EXStar/EinStudio) meshing pipeline from this data.

## Object → STL

The Rigil stores raw scan data + (optionally) a fused mesh (`HasMesh: true`). STL/OBJ/PLY
are produced by the **host** post-processing pipeline (EXStar/EinStudio) from the project's
`*.bin` data, not stored as STL on-device. To get an STL you either (a) pull the project
files and run the meshing pipeline, or (b) trigger an on-device export (command TBD).

## Quick reference — minimal client flow

```
# Listing objects (verified live):
connect(scanner:5678)                                    # control connection
send   env 0x01  {cmd:openDeviceRet, connectType:2, protocolVersion:"1.8", ...}
recv   env 0x01  {deviceName, deviceSerialNumber, ...}
loop:  on recv {type:ping}  -> send {type:pong, ...}     # keepalive
send   env 0x07  {funcName:"projectsInfo", id:1, params:{QString:"Hello"}}
recv   env 0x08  {id:1, ErrorCode:0, result:{ <groups...> }}   # the object list

# Download (observed; trigger gated by project selection):
connect(scanner:5678)  #2 data conn — leave idle, just read
connect(scanner:6789)  #3 ZMTP: greeting + READY(Socket-Type=SUB) + SUBSCRIBE "TXCommData"
send (on control) env 0x07 deviceInfo
send (on control) env 0x01 {frameId:6, messageId:770, param:{}}   # trigger
recv (on data conn) env 0x02 framed QVariantMap{ filename: bytes, ... } + ranged chunks
```
