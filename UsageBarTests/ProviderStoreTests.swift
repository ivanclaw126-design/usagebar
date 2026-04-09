import Foundation
import XCTest
@testable import UsageBar

@MainActor
final class ProviderStoreTests: XCTestCase {
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
