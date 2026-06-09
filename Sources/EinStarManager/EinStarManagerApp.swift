import SwiftUI
import AppKit

// AppDelegate is needed because we run as an unbundled SPM executable via
// `swift run`. Setting the activation policy to .regular gives us a real
// foreground window with a Dock icon instead of a background process.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct EinStarManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var client = ScannerClient()
    @StateObject private var wifi = RigilWiFi()

    var body: some Scene {
        WindowGroup("EinStarManager — Einstar Rigil over WiFi") {
            ContentView()
                .environmentObject(client)
                .environmentObject(wifi)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}
