import SwiftUI
import WebKit
import AppKit

struct SessionCaptureSheet: NSViewRepresentable {
    let webView: WKWebView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.uiDelegate = context.coordinator
        nsView.navigationDelegate = context.coordinator
        context.coordinator.webView = nsView
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.uiDelegate = self
            popupWebView.navigationDelegate = self

            let frame = NSRect(x: 0, y: 0, width: 760, height: 680)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = navigationAction.request.url?.host ?? "Login"
            window.contentView = popupWebView
            window.minSize = NSSize(width: 520, height: 480)
            window.center()
            window.makeKeyAndOrderFront(nil)
            popupWindows[ObjectIdentifier(popupWebView)] = window
            return popupWebView
        }

        func webViewDidClose(_ webView: WKWebView) {
            let key = ObjectIdentifier(webView)
            popupWindows[key]?.close()
            popupWindows[key] = nil
        }
    }
}

struct SessionCaptureWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .normal
                window.isMovableByWindowBackground = true
                window.setFrameAutosaveName("SessionCaptureWindow")
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class SessionCaptureWindowManager: NSObject, NSWindowDelegate {
    static let shared = SessionCaptureWindowManager()

    private weak var window: NSWindow?
    private var activeProvider: ProviderKind?
    private weak var providerStore: ProviderStore?

    func present(
        provider: ProviderKind,
        providerStore: ProviderStore,
        settingsStore: SettingsStore
    ) {
        self.providerStore = providerStore

        if let window, activeProvider == provider {
            AppDelegate.bringAppToFront()
            window.makeKeyAndOrderFront(nil)
            return
        }

        window?.close()

        let contentView = SessionCaptureContainer(provider: provider)
            .environmentObject(providerStore)
            .environmentObject(settingsStore)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = settingsStore.text("Connect \(provider.displayName)", "连接 \(provider.displayName)")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.setFrameAutosaveName("SessionCaptureWindow")
        window.delegate = self
        window.center()

        self.window = window
        self.activeProvider = provider

        AppDelegate.bringAppToFront()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
        activeProvider = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        activeProvider = nil
        providerStore?.endSessionCapture()
    }
}
