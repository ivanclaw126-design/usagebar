import Foundation
import XCTest
import WebKit
@testable import UsageBar

@MainActor
final class ProviderStoreTests: XCTestCase {
    func testRefreshProviderPrefersLatestBailianCookiesFromWebKitStore() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let staleState = BailianSessionState(
            cookies: "old-cookie=1",
            renderedText: "",
            html: "",
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let credentialStore = InMemoryCredentialStore(
            values: [.bailian: StoredCredential(kind: .sessionToken, value: try XCTUnwrap(Self.encode(staleState)))]
        )
        let sessionCapture = MockSessionCapture(currentCookies: [.bailian: "new-cookie=2"])
        let adapter = RecordingProviderAdapter(provider: .bailian, snapshot: Self.okSnapshot(for: .bailian))
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionCapture: sessionCapture,
            adapters: [adapter],
            autoRefreshEnabled: false
        )

        await store.testConnection(for: .bailian)

        let usedCredential = await adapter.lastCredential
        let usedState = try XCTUnwrap(Self.decode(try XCTUnwrap(usedCredential?.value)))
        XCTAssertEqual(usedState.cookies, "new-cookie=2")

        let savedState = try XCTUnwrap(Self.decode(try XCTUnwrap(credentialStore.load(for: .bailian)?.value)))
        XCTAssertEqual(savedState.cookies, "new-cookie=2")
    }

    func testRefreshProviderPrefersFreshBailianSessionStateWhenAvailable() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let staleState = BailianSessionState(
            cookies: "old-cookie=1",
            renderedText: "old",
            html: "old",
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let freshState = BailianSessionState(
            cookies: "new-cookie=2",
            renderedText: "fresh",
            html: "fresh",
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        let credentialStore = InMemoryCredentialStore(
            values: [.bailian: StoredCredential(kind: .sessionToken, value: try XCTUnwrap(Self.encode(staleState)))]
        )
        let sessionCapture = MockSessionCapture(refreshedBailianState: try XCTUnwrap(Self.encode(freshState)))
        let adapter = RecordingProviderAdapter(provider: .bailian, snapshot: Self.okSnapshot(for: .bailian))
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionCapture: sessionCapture,
            adapters: [adapter],
            autoRefreshEnabled: false
        )

        await store.testConnection(for: .bailian)

        let usedCredential = await adapter.lastCredential
        let usedState = try XCTUnwrap(Self.decode(try XCTUnwrap(usedCredential?.value)))
        XCTAssertEqual(usedState.cookies, freshState.cookies)
        XCTAssertEqual(usedState.renderedText, freshState.renderedText)
        XCTAssertEqual(usedState.html, freshState.html)

        let savedState = try XCTUnwrap(Self.decode(try XCTUnwrap(credentialStore.load(for: .bailian)?.value)))
        XCTAssertEqual(savedState.cookies, freshState.cookies)
        XCTAssertEqual(savedState.renderedText, freshState.renderedText)
        XCTAssertEqual(savedState.html, freshState.html)
    }

    func testSaveSessionTriggersImmediateConnectionTest() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let credentialStore = InMemoryCredentialStore()
        let sessionCapture = MockSessionCapture(exportedCookies: "cookie=value")
        let adapter = CountingProviderAdapter(provider: .zaiGlobal, snapshot: Self.okSnapshot(for: .zaiGlobal))
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionCapture: sessionCapture,
            adapters: [adapter],
            autoRefreshEnabled: false
        )

        let webView = WKWebView(frame: .zero)
        await store.saveSession(from: webView, for: .zaiGlobal)

        let count = await adapter.callCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(credentialStore.load(for: .zaiGlobal)?.value, "cookie=value")
        XCTAssertNil(store.activeSessionProvider)
    }

    func testTestConnectionStoresLastSuccessForSuccessfulProvider() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let credentialStore = InMemoryCredentialStore(
            values: [.bailian: StoredCredential(kind: .apiKey, value: "token")]
        )
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionCapture: SessionCapture(),
            adapters: [MockProviderAdapter(provider: .bailian, result: .success(Self.okSnapshot(for: .bailian)))],
            autoRefreshEnabled: false
        )

        await store.testConnection(for: .bailian)

        XCTAssertEqual(store.snapshots[.bailian]?.status, .ok)
        XCTAssertEqual(store.connectionStateText(for: .bailian), "Connected")
        XCTAssertNotNil(store.diagnostics(for: .bailian).lastCheckedAt)
        XCTAssertNotNil(store.diagnostics(for: .bailian).lastSuccessfulRefreshAt)
        XCTAssertNil(store.diagnostics(for: .bailian).lastErrorMessage)
        XCTAssertFalse(store.diagnostics(for: .bailian).isTestingConnection)
    }

    func testTestConnectionMarksUnauthorizedCredentialAsAuthRequired() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let credentialStore = InMemoryCredentialStore(
            values: [.zaiGlobal: StoredCredential(kind: .apiKey, value: "expired")]
        )
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionCapture: SessionCapture(),
            adapters: [MockProviderAdapter(provider: .zaiGlobal, result: .failure(.unauthorized))],
            autoRefreshEnabled: false
        )

        await store.testConnection(for: .zaiGlobal)

        XCTAssertEqual(store.snapshots[.zaiGlobal]?.status, .authRequired)
        XCTAssertEqual(
            store.diagnostics(for: .zaiGlobal).lastErrorMessage,
            ProviderError.unauthorized.localizedDescription
        )
        XCTAssertNil(store.diagnostics(for: .zaiGlobal).lastSuccessfulRefreshAt)
        XCTAssertEqual(store.connectionStateText(for: .zaiGlobal), "Saved credential needs attention")
    }

    func testStoreBootstrapsFromCachedSnapshots() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let cacheStore = SnapshotCacheStore(defaults: defaults)
        let cachedSnapshot = Self.okSnapshot(for: .bailian)
        cacheStore.save(snapshots: [.bailian: cachedSnapshot], lastRefreshAt: cachedSnapshot.fetchedAt)

        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: InMemoryCredentialStore(),
            cacheStore: cacheStore,
            sessionCapture: SessionCapture(),
            adapters: [],
            autoRefreshEnabled: false
        )

        XCTAssertEqual(store.snapshots[.bailian]?.summaryText, cachedSnapshot.summaryText)
        XCTAssertEqual(store.snapshots[.bailian]?.fetchedAt, cachedSnapshot.fetchedAt)
        XCTAssertEqual(store.lastRefreshAt, cachedSnapshot.fetchedAt)
    }

    func testRefreshIfNeededSkipsWhenWithinAutomaticInterval() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let cacheStore = SnapshotCacheStore(defaults: defaults)
        let fetchedAt = Date()
        cacheStore.save(snapshots: [.bailian: Self.okSnapshot(for: .bailian)], lastRefreshAt: fetchedAt)
        let adapter = CountingProviderAdapter(provider: .bailian, snapshot: Self.okSnapshot(for: .bailian))
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: InMemoryCredentialStore(values: [.bailian: StoredCredential(kind: .apiKey, value: "token")]),
            cacheStore: cacheStore,
            sessionCapture: SessionCapture(),
            adapters: [adapter],
            autoRefreshEnabled: false
        )

        await store.refreshIfNeeded(force: false)

        let count = await adapter.callCount
        XCTAssertEqual(count, 0)
    }

    func testRefreshIfNeededRunsWhenAutomaticIntervalHasElapsed() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settingsStore = SettingsStore(defaults: defaults)
        let cacheStore = SnapshotCacheStore(defaults: defaults)
        let staleDate = Date().addingTimeInterval(-(RefreshPolicy.automaticInterval + 5))
        cacheStore.save(snapshots: [.bailian: Self.okSnapshot(for: .bailian)], lastRefreshAt: staleDate)
        let adapter = CountingProviderAdapter(provider: .bailian, snapshot: Self.okSnapshot(for: .bailian))
        let store = ProviderStore(
            settingsStore: settingsStore,
            credentialStore: InMemoryCredentialStore(values: [.bailian: StoredCredential(kind: .apiKey, value: "token")]),
            cacheStore: cacheStore,
            sessionCapture: SessionCapture(),
            adapters: [adapter],
            autoRefreshEnabled: false
        )

        await store.refreshIfNeeded(force: false)

        let count = await adapter.callCount
        XCTAssertEqual(count, 1)
    }

    private static func okSnapshot(for provider: ProviderKind) -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            provider: provider,
            status: .ok,
            remainingValue: "80",
            remainingUnit: "%",
            usedValue: "20",
            resetAt: Date().addingTimeInterval(3_600),
            fetchedAt: Date(),
            summaryText: "Healthy",
            detailText: "Fetched from test adapter.",
            providerMetadata: nil
        )
    }

    private static func encode(_ state: BailianSessionState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ value: String) -> BailianSessionState? {
        try? JSONDecoder().decode(BailianSessionState.self, from: Data(value.utf8))
    }
}

private final class InMemoryCredentialStore: CredentialStoreType {
    private var values: [ProviderKind: StoredCredential]

    init(values: [ProviderKind: StoredCredential] = [:]) {
        self.values = values
    }

    func save(_ credential: StoredCredential, for provider: ProviderKind) throws {
        values[provider] = credential
    }

    func load(for provider: ProviderKind) -> StoredCredential? {
        values[provider]
    }

    func delete(for provider: ProviderKind) {
        values[provider] = nil
    }
}

@MainActor
private final class MockSessionCapture: SessionCaptureType {
    var currentCookies: [ProviderKind: String]
    var exportedCookies: String
    var exportedBailianState: String?
    var refreshedBailianState: String?

    init(
        currentCookies: [ProviderKind: String] = [:],
        exportedCookies: String = "",
        exportedBailianState: String? = nil,
        refreshedBailianState: String? = nil
    ) {
        self.currentCookies = currentCookies
        self.exportedCookies = exportedCookies
        self.exportedBailianState = exportedBailianState
        self.refreshedBailianState = refreshedBailianState
    }

    func makeWebView(for provider: ProviderKind) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func exportCookies(from webView: WKWebView) async throws -> String {
        exportedCookies
    }

    func exportBailianSessionState(from webView: WKWebView) async throws -> String {
        exportedBailianState ?? ""
    }

    func currentCookieJar(for provider: ProviderKind) async -> String? {
        currentCookies[provider]
    }

    func refreshBailianSessionState() async -> String? {
        refreshedBailianState
    }
}

private struct MockProviderAdapter: ProviderAdapter {
    let provider: ProviderKind
    let result: Result<ProviderBalanceSnapshot, ProviderError>

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

private actor CountingProviderAdapter: ProviderAdapter {
    let provider: ProviderKind
    let snapshot: ProviderBalanceSnapshot
    private(set) var callCount = 0

    init(provider: ProviderKind, snapshot: ProviderBalanceSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        callCount += 1
        return snapshot
    }
}

private actor RecordingProviderAdapter: ProviderAdapter {
    let provider: ProviderKind
    let snapshot: ProviderBalanceSnapshot
    private(set) var lastCredential: StoredCredential?

    init(provider: ProviderKind, snapshot: ProviderBalanceSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        lastCredential = credential
        return snapshot
    }
}
