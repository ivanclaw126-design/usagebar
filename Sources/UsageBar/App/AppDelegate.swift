import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    @MainActor
    static func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    static func bringAppToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
