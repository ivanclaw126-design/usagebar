import Foundation
import WebKit

@MainActor
protocol SessionCaptureType: AnyObject {
    func makeWebView(for provider: ProviderKind) -> WKWebView
    func exportCookies(from webView: WKWebView) async throws -> String
    func exportBailianSessionState(from webView: WKWebView) async throws -> String
    func currentCookieJar(for provider: ProviderKind) async -> String?
    func refreshBailianSessionState() async -> String?
}

@MainActor
class SessionCapture: SessionCaptureType {
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
        let cookieJar = await cookieJar(from: store)
        guard cookieJar.isEmpty == false else {
            throw SessionCaptureError.noCookiesFound
        }
        return cookieJar
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

    func currentCookieJar(for provider: ProviderKind) async -> String? {
        let store = WKWebsiteDataStore.default().httpCookieStore
        return await cookieJar(from: store, matching: cookieDomainSuffixes(for: provider))
    }

    func refreshBailianSessionState() async -> String? {
        let refresher = BailianSessionStateRefresher(url: ProviderKind.bailian.loginURL)
        return try? await refresher.captureState()
    }

    private func cookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func cookieJar(
        from store: WKHTTPCookieStore,
        matching domainSuffixes: [String]? = nil
    ) async -> String {
        let allCookies = await cookies(from: store)
        let relevantCookies = allCookies.filter { cookie in
            guard let domainSuffixes else { return true }
            let domain = cookie.domain.lowercased()
            return domainSuffixes.contains { suffix in
                domain == suffix || domain.hasSuffix(".\(suffix)")
            }
        }

        return serializedCookieJar(from: relevantCookies)
    }

    private func serializedCookieJar(from cookies: [HTTPCookie]) -> String {
        guard cookies.isEmpty == false else { return "" }

        var seenNames = Set<String>()
        var orderedPairs: [String] = []

        for cookie in cookies.reversed() {
            guard seenNames.insert(cookie.name).inserted else { continue }
            orderedPairs.append("\(cookie.name)=\(cookie.value)")
        }

        return orderedPairs.reversed().joined(separator: "; ")
    }

    private func cookieDomainSuffixes(for provider: ProviderKind) -> [String] {
        switch provider {
        case .bailian:
            return ["aliyun.com", "aliyuncs.com"]
        case .zaiGlobal:
            return ["z.ai"]
        case .openAIPlus:
            return ["chatgpt.com", "openai.com"]
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

@MainActor
private final class BailianSessionStateRefresher: NSObject, WKNavigationDelegate {
    private let url: URL
    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func captureState() async throws -> String {
        try await navigate()
        let state = try await waitForSessionState()
        let data = try JSONEncoder().encode(state)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SessionCaptureError.sessionSnapshotEncodingFailed
        }
        return string
    }

    private func navigate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func waitForSessionState() async throws -> BailianSessionState {
        for _ in 0..<10 {
            if let state = try await currentSessionState() {
                return state
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProviderError.unauthorized
    }

    private func currentSessionState() async throws -> BailianSessionState? {
        let bodyText = try await evaluate(script: "document.body ? document.body.innerText : ''")
        if requiresLogin(bodyText) {
            throw ProviderError.unauthorized
        }

        let html = try await evaluate(script: "document.documentElement ? document.documentElement.outerHTML : ''")
        if (try? BailianProvider.parseUsageResponse(fromRenderedText: bodyText)) != nil ||
            (try? BailianProvider.parseUsageResponse(fromHTML: html)) != nil {
            let cookieJar = try await exportCookies(from: webView)
            return BailianSessionState(
                cookies: cookieJar,
                renderedText: bodyText,
                html: html,
                capturedAt: Date()
            )
        }

        return nil
    }

    private func requiresLogin(_ bodyText: String) -> Bool {
        (bodyText.contains("登录") && bodyText.contains("阿里云")) ||
        bodyText.contains("请登录") ||
        bodyText.contains("立即登录") ||
        bodyText.contains("登录以使用")
    }

    private func exportCookies(from webView: WKWebView) async throws -> String {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        let cookieJar = cookies
            .reversed()
            .reduce(into: ([String](), Set<String>())) { result, cookie in
                guard result.1.insert(cookie.name).inserted else { return }
                result.0.append("\(cookie.name)=\(cookie.value)")
            }
            .0
            .reversed()
            .joined(separator: "; ")

        guard cookieJar.isEmpty == false else {
            throw SessionCaptureError.noCookiesFound
        }

        return cookieJar
    }

    private func evaluate(script: String) async throws -> String {
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
