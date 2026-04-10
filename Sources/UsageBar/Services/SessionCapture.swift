import Foundation
import WebKit

@MainActor
final class SessionCapture {
    func makeWebView(for provider: ProviderKind) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: provider.loginURL))
        return webView
    }

    func exportCookies(from webView: WKWebView) async throws -> String {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await cookies(from: store)
        guard cookies.isEmpty == false else {
            throw SessionCaptureError.noCookiesFound
        }
        return cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func exportBailianSessionState(from webView: WKWebView) async throws -> String {
        let cookieJar = try await exportCookies(from: webView)
        let bodyText = try await evaluate(script: "document.body ? document.body.innerText : ''", in: webView)
        let html = try await evaluate(script: "document.documentElement ? document.documentElement.outerHTML : ''", in: webView)
        let payload = BailianSessionState(
            cookies: cookieJar,
            renderedText: bodyText,
            html: html,
            capturedAt: Date()
        )
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SessionCaptureError.sessionSnapshotEncodingFailed
        }
        return string
    }

    private func cookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func evaluate(script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result as? String ?? "")
            }
        }
    }
}

enum SessionCaptureError: Error {
    case noCookiesFound
    case sessionSnapshotEncodingFailed
}

struct BailianSessionState: Codable, Equatable {
    var cookies: String
    var renderedText: String
    var html: String
    var capturedAt: Date
}
