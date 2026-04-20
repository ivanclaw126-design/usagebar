import AppKit
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
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let capturedCookies = await cookies(from: store, matching: BailianSessionCookieCodec.domainSuffixes)
        let cookieJar = BailianSessionCookieCodec.serializedCookieJar(from: capturedCookies)
        guard cookieJar.isEmpty == false else {
            throw SessionCaptureError.noCookiesFound
        }

        let bodyText = try await evaluate(script: "document.body ? document.body.innerText : ''", in: webView)
        let html = try await evaluate(script: "document.documentElement ? document.documentElement.outerHTML : ''", in: webView)
        let payload = BailianSessionState(
            cookies: cookieJar,
            cookieRecords: capturedCookies.map(BailianSessionCookie.init(cookie:)),
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
        let relevantCookies = await cookies(from: store, matching: domainSuffixes)
        return serializedCookieJar(from: relevantCookies)
    }

    private func cookies(
        from store: WKHTTPCookieStore,
        matching domainSuffixes: [String]? = nil
    ) async -> [HTTPCookie] {
        let allCookies = await cookies(from: store)
        guard let domainSuffixes else { return allCookies }
        return allCookies.filter { cookie in
            BailianSessionCookieCodec.domain(cookie.domain, matchesAnySuffixIn: domainSuffixes)
        }
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
    var cookieRecords: [BailianSessionCookie]?
    var renderedText: String
    var html: String
    var capturedAt: Date

    init(
        cookies: String,
        cookieRecords: [BailianSessionCookie]? = nil,
        renderedText: String,
        html: String,
        capturedAt: Date
    ) {
        self.cookies = cookies
        self.cookieRecords = cookieRecords
        self.renderedText = renderedText
        self.html = html
        self.capturedAt = capturedAt
    }
}

struct BailianSessionCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresDate: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool

    init(cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
    }

    var headerPair: String {
        "\(name)=\(value)"
    }

    var isExpired: Bool {
        guard let expiresDate else { return false }
        return expiresDate <= Date()
    }

    func matches(url: URL) -> Bool {
        guard isExpired == false,
              let host = url.host?.lowercased() else {
            return false
        }

        let normalizedDomain = BailianSessionCookieCodec.normalizedDomain(domain)
        let domainMatches = host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
        guard domainMatches else { return false }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        return requestPath.hasPrefix(cookiePath)
    }

    func makeHTTPCookie(fallbackDomain: String? = nil) -> HTTPCookie? {
        guard isExpired == false else { return nil }
        let cookieDomain = domain.isEmpty ? (fallbackDomain ?? "bailian.console.aliyun.com") : domain
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: cookieDomain,
            .path: path.isEmpty ? "/" : path,
            .name: name,
            .value: value
        ]
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        if isSecure {
            properties[.secure] = true
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = true
        }
        return HTTPCookie(properties: properties)
    }
}

enum BailianSessionCookieCodec {
    static let domainSuffixes = ["aliyun.com", "aliyuncs.com"]

    static func domain(_ domain: String, matchesAnySuffixIn suffixes: [String]) -> Bool {
        let cookieDomain = normalizedDomain(domain)
        return suffixes.contains { suffix in
            let normalizedSuffix = normalizedDomain(suffix)
            return cookieDomain == normalizedSuffix || cookieDomain.hasSuffix(".\(normalizedSuffix)")
        }
    }

    static func normalizedDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    static func serializedCookieJar(from cookies: [HTTPCookie]) -> String {
        serializedPairs(cookies.map { ($0.name, $0.value) })
    }

    static func serializedCookieJar(from records: [BailianSessionCookie], for url: URL? = nil) -> String {
        let filteredRecords: [BailianSessionCookie]
        if let url {
            filteredRecords = records.filter { $0.matches(url: url) }
        } else {
            filteredRecords = records.filter { $0.isExpired == false }
        }
        return serializedPairs(filteredRecords.map { ($0.name, $0.value) })
    }

    private static func serializedPairs(_ pairs: [(String, String)]) -> String {
        guard pairs.isEmpty == false else { return "" }

        var seenNames = Set<String>()
        var orderedPairs: [String] = []
        for pair in pairs.reversed() {
            guard seenNames.insert(pair.0).inserted else { continue }
            orderedPairs.append("\(pair.0)=\(pair.1)")
        }
        return orderedPairs.reversed().joined(separator: "; ")
    }
}

@MainActor
final class BackgroundWebViewWindowHost {
    private let window: NSWindow

    init(webView: WKWebView) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))

        self.window = window
        show()
    }

    func show() {
        window.orderFrontRegardless()
    }

    deinit {
        let window = self.window
        Task { @MainActor in
            window.orderOut(nil)
        }
    }
}

@MainActor
private final class BailianSessionStateRefresher: NSObject, WKNavigationDelegate {
    private let url: URL
    private let webView: WKWebView
    private let windowHost: BackgroundWebViewWindowHost
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private let maxRefreshWaitSeconds = 30

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.windowHost = BackgroundWebViewWindowHost(webView: webView)
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
            windowHost.show()
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
        for _ in 0..<maxRefreshWaitSeconds {
            if let state = try await currentSessionState() {
                return state
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProviderError.invalidResponse
    }

    private func currentSessionState() async throws -> BailianSessionState? {
        let readyState = try await evaluate(script: "document.readyState")
        let bodyText = try await evaluate(script: "document.body ? document.body.innerText : ''")
        let html = try await evaluate(script: "document.documentElement ? document.documentElement.outerHTML : ''")

        if (try? BailianProvider.parseUsageResponse(fromRenderedText: bodyText)) != nil ||
            (try? BailianProvider.parseUsageResponse(fromHTML: html)) != nil {
            let (cookieJar, cookieRecords) = try await exportBailianCookies(from: webView)
            return BailianSessionState(
                cookies: cookieJar,
                cookieRecords: cookieRecords,
                renderedText: bodyText,
                html: html,
                capturedAt: Date()
            )
        }

        if readyState == "complete" && requiresLogin(bodyText) {
            throw ProviderError.unauthorized
        }

        return nil
    }

    private func requiresLogin(_ bodyText: String) -> Bool {
        (bodyText.contains("登录") && bodyText.contains("阿里云")) ||
        bodyText.contains("请登录") ||
        bodyText.contains("立即登录") ||
        bodyText.contains("登录以使用")
    }

    private func exportBailianCookies(from webView: WKWebView) async throws -> (String, [BailianSessionCookie]) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let relevantCookies = cookies.filter {
            BailianSessionCookieCodec.domain($0.domain, matchesAnySuffixIn: BailianSessionCookieCodec.domainSuffixes)
        }
        let cookieJar = BailianSessionCookieCodec.serializedCookieJar(from: relevantCookies)
        guard cookieJar.isEmpty == false else {
            throw SessionCaptureError.noCookiesFound
        }
        return (cookieJar, relevantCookies.map(BailianSessionCookie.init(cookie:)))
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
