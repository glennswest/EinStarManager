# EinScan Rigil — WiFi Protocol (reverse-engineered)

Reverse-engineered from a live `EinScan Rigil Lite` (serial `EinScanRigilMMB-BF031C20B`,
appVersion `1.3.1-alpha.19`, protocolVersion `1.8`) and a 1.18 GB Wireshark capture of
the Windows **EXStar** client talking to it.

> Status: **control plane fully working & verified live** (handshake, deviceInfo,
> projectsInfo, ping/pong). **Data plane (file download) format decoded** from capture,
> but the live session-gating for a standalone download is still being confirmed — the
> reference capture is a *scanning* session, which only reads project thumbnails.

## Transport overview

The scanner exposes several services. The one EXStar uses is **TCP port 5678**.

| Port | Proto | Role |
|------|-------|------|
| **5678** | custom framed CBOR / binary | **EXStar control + data plane** (this doc) |
| 8081 | WebSocket (`Server: webserver`) | web/mobile control channel (pings, closes on bad cmd) |
| 8080 | HTTP | resource server; bare GETs → `404 application/x-empty` (used as the discovery signature) |
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

## 4. Data / file channel (envelope `0x02`)

Used to read files out of a project directory. The body is **not** CBOR — it is a small
Qt-`QDataStream`-style structure, **little-endian**, with **UTF-16LE** strings:

```
+--------+----------+-----------------------------+--------------------+
| opcode | innerLen | QString path                | trailing params    |
| u32 LE | u32 LE   | u32 LE byteLen + UTF-16LE    | (u32 id, flags...) |
+--------+----------+-----------------------------+--------------------+
```

- `opcode` observed: `0x33` (51) and `0x34` (52) — request variants (e.g. stat vs read).
- `path` is the absolute device path, e.g.
  `/storage/<uuid>/TX3App/projectgroup/Group_1/preview.png`.

The scanner streams the file back on envelope `0x02`. A project directory contains, among
others:

| file | contents |
|------|----------|
| `preview.png` | thumbnail image |
| `LeftCCF.txt` / `RightCCF.txt` | camera calibration (focal length, principal point, distortion `kc`, `T`, `R`, std error) |
| `left25.bin`, `*.bin` | binary scan/frame data |
| `calibTime`, … | metadata |

The bulk of a project download is the scanner streaming these files back-to-back (the
523 MB `part1` project is mostly `*.bin` scan data).

> **Open item:** on a fresh connection the scanner accepts the handshake but does not yet
> answer `0x02` file requests in isolation — EXStar issues them while a project is "open"
> in an active session. A dedicated capture of EXStar **transferring/exporting a saved
> project** (rather than live-scanning) is needed to pin the exact precondition.

## Object → STL

The Rigil stores raw scan data + (optionally) a fused mesh (`HasMesh: true`). STL/OBJ/PLY
are produced by the **host** post-processing pipeline (EXStar/EinStudio) from the project's
`*.bin` data, not stored as STL on-device. To get an STL you either (a) pull the project
files and run the meshing pipeline, or (b) trigger an on-device export (command TBD).

## Quick reference — minimal client flow

```
connect(scanner:5678)
send   env 0x01  {cmd:openDeviceRet, connectType:2, protocolVersion:"1.8", ...}
recv   env 0x01  {deviceName, deviceSerialNumber, ...}
loop:  on recv {type:ping}  -> send {type:pong, ...}     # keepalive
send   env 0x07  {funcName:"projectsInfo", id:1, params:{QString:"Hello"}}
recv   env 0x08  {id:1, ErrorCode:0, result:{ <groups...> }}   # the object list
```
