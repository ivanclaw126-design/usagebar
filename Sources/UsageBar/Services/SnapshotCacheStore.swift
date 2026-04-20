import Foundation

struct ProviderCacheSnapshot: Codable {
    var snapshots: [ProviderKind: ProviderBalanceSnapshot]
    var lastRefreshAt: Date?
}

@MainActor
final class SnapshotCacheStore {
    private let defaults: UserDefaults
    private let key = "UsageBar.providerCache"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ProviderCacheSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ProviderCacheSnapshot.self, from: data)
    }

    func save(snapshots: [ProviderKind: ProviderBalanceSnapshot], lastRefreshAt: Date?) {
        let payload = ProviderCacheSnapshot(snapshots: snapshots, lastRefreshAt: lastRefreshAt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }
}
