import Foundation

/// Result of the device handshake (envelope 0x01 reply).
public struct RigilHandshake: Sendable {
    public let deviceName: String
    public let serialNumber: String
    public let protocolVersion: String
    public let clientAddr: String
}

/// Subset of the `deviceInfo` RPC result.
public struct RigilDeviceInfo: Sendable {
    public let deviceName: String
    public let serialNumber: String
    public let productName: String
    public let appVersion: String
    public let batteryValue: Double
    public let charging: Bool
    /// e.g. "494.4/495" (GB used/total).
    public let storageState: String
    public let raw: CBOR

    init(_ c: CBOR) {
        deviceName   = c["devName"]?.stringValue ?? ""
        serialNumber = c["devSerialNum"]?.stringValue ?? ""
        productName  = c["productName"]?.stringValue ?? ""
        appVersion   = c["appVersion"]?.stringValue ?? ""
        batteryValue = c["batteryValue"]?.doubleValue ?? 0
        charging     = c["bCharge"]?.boolValue ?? false
        storageState = c["devStorageState"]?.stringValue ?? ""
        raw = c
    }
}

/// One stored scan/object from the `projectsInfo` RPC.
public struct RigilProject: Sendable, Identifiable {
    public var id: String { uuid.isEmpty ? "\(group)/\(name)" : uuid }
    public let group: String
    public let name: String
    public let path: String
    public let uuid: String
    public let size: Int
    public let hasMesh: Bool
    public let hasTexture: Bool
    public let scanMode: Int
    public let dateTime: String

    init(group: String, _ c: CBOR) {
        self.group = group
        name       = c["Name"]?.stringValue ?? ""
        path       = c["Path"]?.stringValue ?? ""
        uuid       = c["Uuid"]?.stringValue ?? ""
        size       = c["Size"]?.intValue ?? 0
        hasMesh    = c["HasMesh"]?.boolValue ?? false
        hasTexture = c["Texture"]?.boolValue ?? false
        scanMode   = c["ScanMode"]?.intValue ?? 0
        dateTime   = c["DateTime"]?.stringValue ?? ""
    }

    /// Flatten a `projectsInfo` result (`{ group: [project, …] }`) into a list.
    public static func list(from result: CBOR) -> [RigilProject] {
        guard let pairs = result.mapPairs else { return [] }
        var out: [RigilProject] = []
        for (groupKey, value) in pairs {
            guard let group = groupKey.stringValue, let arr = value.arrayValue else { continue }
            for proj in arr { out.append(RigilProject(group: group, proj)) }
        }
        return out
    }
}
