import Foundation
import CoreWLAN
import CoreLocation
import Darwin

/// In-app WiFi control for the Rigil hotspot, using CoreWLAN — no shell, no root.
///
/// Strategy for "connect without messing up the network": we never touch the
/// routing table. Instead the scanner's sockets are pinned to the Wi-Fi interface
/// (see `ScannerClient`/RigilKit `requiredInterfaceType = .wifi`), so scanner traffic
/// rides Wi-Fi while the default route (internet) stays on Ethernet. We also refuse
/// to hijack a Wi-Fi adapter that's already on a non-scanner network.
@MainActor
final class RigilWiFi: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var interfaceName: String = ""
    @Published private(set) var currentSSID: String? = nil
    @Published private(set) var status: String = ""
    @Published private(set) var wifiIPv4: String? = nil

    private let client = CWWiFiClient.shared()
    private let loc = CLLocationManager()

    override init() {
        super.init()
        loc.delegate = self
        refresh()
    }

    /// SSIDs starting with this are treated as Rigil hotspots.
    static let hotspotPrefix = "EinScanRigil"

    var iface: CWInterface? { client.interface() }

    /// Surface a status/error line to the UI.
    func note(_ message: String) { status = message }

    func refresh() {
        interfaceName = iface?.interfaceName ?? "(no Wi-Fi adapter)"
        currentSSID = iface?.ssid()
        wifiIPv4 = interfaceName.hasPrefix("(") ? nil : Self.ipv4(of: interfaceName)
    }

    /// True if the adapter exists and is free to use (off, or already on a Rigil hotspot).
    var adapterIsFree: Bool {
        guard iface != nil else { return false }
        guard let ssid = currentSSID else { return true }            // not associated => free
        return ssid.hasPrefix(Self.hotspotPrefix)                    // already on the scanner => fine
    }

    /// macOS requires Location permission to read scan results / SSIDs.
    func requestLocationIfNeeded() {
        if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}

    /// Find the scanner's hotspot by scanning for an `EinScanRigil…` SSID.
    func findScannerHotspot() throws -> CWNetwork? {
        guard let iface else { throw Err.noAdapter }
        let nets = try iface.scanForNetworks(withSSID: nil)
        return nets.first { ($0.ssid ?? "").hasPrefix(Self.hotspotPrefix) }
    }

    /// Join the scanner hotspot (open/saved network — no password). Refuses to take
    /// over an adapter that's on some other network.
    func joinScanner() async throws {
        guard let iface else { throw Err.noAdapter }
        // Power the adapter on if it's off (CoreWLAN can't scan/associate while off).
        if !iface.powerOn() {
            status = "Turning Wi-Fi on…"
            try iface.setPower(true)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if iface.powerOn() { break }
            }
            refresh()
        }
        guard iface.powerOn() else { throw Err.powerFailed }
        if let ssid = currentSSID, ssid.hasPrefix(Self.hotspotPrefix) {
            status = "Already on \(ssid)"; refresh(); return
        }
        guard adapterIsFree else { throw Err.adapterBusy(currentSSID ?? "?") }
        status = "Scanning for \(Self.hotspotPrefix)…"
        guard let net = try findScannerHotspot() else { throw Err.notFound }
        status = "Joining \(net.ssid ?? "?")…"
        try iface.associate(to: net, password: nil)
        // wait for a 192.168.76.x lease
        for _ in 0..<20 {
            refresh()
            if (wifiIPv4 ?? "").hasPrefix("192.168.76.") { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        refresh()
        if (wifiIPv4 ?? "").hasPrefix("192.168.76.") {
            status = "Joined \(net.ssid ?? "") — \(wifiIPv4!)"
        } else {
            status = "Associated but no scanner-subnet address yet (\(wifiIPv4 ?? "none"))"
        }
    }

    enum Err: LocalizedError {
        case noAdapter, adapterBusy(String), notFound, powerFailed
        var errorDescription: String? {
            switch self {
            case .noAdapter: return "No Wi-Fi adapter found."
            case .adapterBusy(let s): return "Wi-Fi is on '\(s)' — not hijacking it. Disconnect it first."
            case .notFound: return "No EinScanRigil hotspot found in range (is the scanner in hotspot mode? is Location permission granted?)."
            case .powerFailed: return "Couldn't power on the Wi-Fi adapter."
            }
        }
    }

    /// IPv4 address currently assigned to a named interface.
    static func ipv4(of ifname: String) -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
        defer { freeifaddrs(ptr) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cur {
            if String(cString: c.pointee.ifa_name) == ifname,
               let addr = c.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cur = c.pointee.ifa_next
        }
        return nil
    }
}
