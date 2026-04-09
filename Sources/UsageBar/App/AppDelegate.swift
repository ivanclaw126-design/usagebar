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
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)
        app.windows.forEach { window in
            window.orderFrontRegardless()
            if window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
