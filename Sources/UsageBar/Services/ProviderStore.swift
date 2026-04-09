import Foundation
import SwiftUI
import WebKit

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderKind: ProviderBalanceSnapshot]
    @Published private(set) var diagnostics: [ProviderKind: ProviderConnectionDiagnostics]
    @Published private(set) var lastRefreshAt: Date?
    @Published var isRefreshing = false
    @Published var activeSessionProvider: ProviderKind?
    @Published var sessionCaptureErrorMessage: String?
    @Published var toastMessage: String?

    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStoreType
    private let cacheStore: SnapshotCacheStore
    private let sessionCapture: SessionCapture
    private let adapters: [ProviderKind: ProviderAdapter]
    private var refreshTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        credentialStore: CredentialStoreType,
        cacheStore: SnapshotCacheStore = SnapshotCacheStore(),
        sessionCapture: SessionCapture,
        adapters: [ProviderAdapter] = [BailianProvider(), ZAIProvider(), OpenAIPlusProvider()],
        autoRefreshEnabled: Bool = true
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.cacheStore = cacheStore
        self.sessionCapture = sessionCapture
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        let defaultSnapshots = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map {
            ($0, ProviderBalanceSnapshot.authRequired(provider: $0))
        })
        if let cached = cacheStore.load() {
            var merged = defaultSnapshots
            for (provider, snapshot) in cached.snapshots {
                merged[provider] = snapshot
            }
            self.snapshots = merged
            self.lastRefreshAt = cached.lastRefreshAt
        } else {
            self.snapshots = defaultSnapshots
            self.lastRefreshAt = nil
        }
        self.diagnostics = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map {
            ($0, .empty)
        })
        if autoRefreshEnabled {
            scheduleAutomaticRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var menuBarTitle: String {
        let visibleProviders = ProviderKind.allCases.filter { settingsStore.configuration(for: $0).isEnabled }
        let pieces = visibleProviders.map { provider -> String in
            let snapshot = snapshots[provider] ?? .authRequired(provider: provider)
            return settingsStore.snapshot.compactMenuBar
                ? compactLabel(for: snapshot)
                : expandedLabel(for: snapshot)
        }
        return pieces.isEmpty ? "UsageBar" : pieces.joined(separator: " | ")
    }

    var menuBarSymbolName: String {
        snapshots.values.contains(where: { $0.status == .error || $0.status == .authRequired }) ? "exclamationmark.circle" : "chart.bar.xaxis"
    }

    var orderedSnapshots: [ProviderBalanceSnapshot] {
        ProviderKind.allCases.compactMap { snapshots[$0] }
    }

    var hasAnyCredentialConfigured: Bool {
        ProviderKind.allCases.contains(where: hasCredential(for:))
    }

    func diagnostics(for provider: ProviderKind) -> ProviderConnectionDiagnostics {
        diagnostics[provider] ?? .empty
    }

    func connectionStateText(for provider: ProviderKind) -> String {
        let diagnostics = diagnostics(for: provider)
        if diagnostics.isTestingConnection {
            return "Testing connection..."
        }

        let snapshot = snapshots[provider] ?? .authRequired(provider: provider)
        switch snapshot.status {
        case .ok:
            return "Connected"
        case .degraded:
            if provider == .zaiGlobal {
                return "Connected with partial quota data"
            }
            if provider == .openAIPlus {
                return "Connected with fallback Codex data"
            }
            return "Connected with fallback data"
        case .authRequired:
            return hasCredential(for: provider) ? "Saved credential needs attention" : "Not connected"
        case .unsupported:
            return "Partially supported"
        case .supportedLimited:
            return "Connected with limited visibility"
        case .error:
            return "Connection failed"
        }
    }

    func refreshIfNeeded(force: Bool) async {
        let shouldRefresh = force || lastRefreshAt.map { Date().timeIntervalSince($0) >= RefreshPolicy.automaticInterval } ?? true
        guard shouldRefresh else { return }
        await refresh(force: force)
    }

    func refresh(force: Bool) async {
        guard isRefreshing == false || force else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for provider in ProviderKind.allCases {
            guard settingsStore.configuration(for: provider).isEnabled else { continue }
            await refreshProvider(provider)
        }

        lastRefreshAt = Date()
        persistCache()
    }

    func testConnection(for provider: ProviderKind) async {
        var current = diagnostics(for: provider)
        current.isTestingConnection = true
        current.lastCheckedAt = Date()
        diagnostics[provider] = current
        defer {
            var updated = diagnostics(for: provider)
            updated.isTestingConnection = false
            diagnostics[provider] = updated
        }

        await refreshProvider(provider)
    }

    func saveCredential(kind: CredentialKind, value: String, for provider: ProviderKind) {
        do {
            try credentialStore.save(.init(kind: kind, value: value), for: provider)
            var current = diagnostics(for: provider)
            current.lastErrorMessage = nil
            current.lastCheckedAt = nil
            current.lastDiagnosticReport = nil
            diagnostics[provider] = current
            snapshots[provider] = .authRequired(provider: provider)
            persistCache()
            toastMessage = "\(provider.displayName) credential saved to Keychain. Press Test Connection to verify it."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    func clearCredential(for provider: ProviderKind) {
        credentialStore.delete(for: provider)
        snapshots[provider] = .authRequired(provider: provider)
        diagnostics[provider] = .empty
        persistCache()
        toastMessage = "\(provider.displayName) credential removed."
    }

    func hasCredential(for provider: ProviderKind) -> Bool {
        credentialStore.load(for: provider) != nil
    }

    func currentCredentialKind(for provider: ProviderKind) -> CredentialKind? {
        credentialStore.load(for: provider)?.kind
    }

    func beginSessionCapture(for provider: ProviderKind) {
        activeSessionProvider = provider
        sessionCaptureErrorMessage = nil
    }

    func endSessionCapture() {
        activeSessionProvider = nil
        sessionCaptureErrorMessage = nil
    }

    func saveSession(from webView: WKWebView, for provider: ProviderKind) async {
        do {
            if provider == .bailian {
                let state = try await sessionCapture.exportBailianSessionState(from: webView)
                saveCredential(kind: .sessionToken, value: state, for: provider)
            } else {
                let cookieJar = try await sessionCapture.exportCookies(from: webView)
                saveCredential(kind: .cookieJar, value: cookieJar, for: provider)
            }
            activeSessionProvider = nil
        } catch {
            sessionCaptureErrorMessage = provider == .bailian
                ? "Could not capture the current Bailian session state from the web page."
                : "Could not capture cookies from the current browser session."
        }
    }

    private func refreshProvider(_ provider: ProviderKind) async {
        let checkedAt = Date()
        let credential = credentialStore.load(for: provider)

        do {
            guard let adapter = adapters[provider] else { return }
            let snapshot = try await adapter.fetchBalance(using: credential)
            snapshots[provider] = snapshot
            persistCache()
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastSuccessfulRefreshAt = snapshot.fetchedAt
            current.lastErrorMessage = nil
            current.lastDiagnosticReport = snapshot.providerMetadata?.diagnosticReport
            diagnostics[provider] = current
        } catch ProviderError.missingCredential {
            snapshots[provider] = .authRequired(provider: provider, fetchedAt: checkedAt)
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = ProviderError.missingCredential.localizedDescription
            current.lastDiagnosticReport = nil
            diagnostics[provider] = current
        } catch ProviderError.unauthorized {
            snapshots[provider] = .authRequired(provider: provider, fetchedAt: checkedAt)
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = ProviderError.unauthorized.localizedDescription
            current.lastDiagnosticReport = nil
            diagnostics[provider] = current
        } catch ProviderError.unsupportedFeature(let message) {
            snapshots[provider] = ProviderBalanceSnapshot(
                provider: provider,
                status: .unsupported,
                remainingValue: nil,
                remainingUnit: nil,
                usedValue: nil,
                resetAt: nil,
                fetchedAt: checkedAt,
                summaryText: "Unsupported",
                detailText: message,
                providerMetadata: nil
            )
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = nil
            current.lastDiagnosticReport = message
            diagnostics[provider] = current
        } catch let error as ZAIProviderError {
            let fallback = snapshots[provider]
            snapshots[provider] = ProviderBalanceSnapshot(
                provider: provider,
                status: fallback?.status == .ok || fallback?.status == .degraded ? .degraded : .error,
                remainingValue: fallback?.remainingValue,
                remainingUnit: fallback?.remainingUnit,
                usedValue: fallback?.usedValue,
                resetAt: fallback?.resetAt,
                fetchedAt: checkedAt,
                summaryText: fallback?.summaryText ?? "Unavailable",
                detailText: error.localizedDescription,
                providerMetadata: fallback?.providerMetadata
            )
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = error.localizedDescription
            current.lastDiagnosticReport = error.diagnosticReport
            diagnostics[provider] = current
        } catch let error as BailianProviderError {
            let fallback = snapshots[provider]
            snapshots[provider] = ProviderBalanceSnapshot(
                provider: provider,
                status: fallback?.status == .ok || fallback?.status == .degraded ? .degraded : .error,
                remainingValue: fallback?.remainingValue,
                remainingUnit: fallback?.remainingUnit,
                usedValue: fallback?.usedValue,
                resetAt: fallback?.resetAt,
                fetchedAt: checkedAt,
                summaryText: fallback?.summaryText ?? "Unavailable",
                detailText: error.localizedDescription,
                providerMetadata: fallback?.providerMetadata
            )
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = error.localizedDescription
            current.lastDiagnosticReport = error.diagnosticReport
            diagnostics[provider] = current
        } catch {
            let fallback = snapshots[provider]
            snapshots[provider] = ProviderBalanceSnapshot(
                provider: provider,
                status: fallback?.status == .ok || fallback?.status == .degraded ? .degraded : .error,
                remainingValue: fallback?.remainingValue,
                remainingUnit: fallback?.remainingUnit,
                usedValue: fallback?.usedValue,
                resetAt: fallback?.resetAt,
                fetchedAt: checkedAt,
                summaryText: fallback?.summaryText ?? "Unavailable",
                detailText: error.localizedDescription,
                providerMetadata: fallback?.providerMetadata
            )
            var current = diagnostics(for: provider)
            current.lastCheckedAt = checkedAt
            current.lastErrorMessage = error.localizedDescription
            current.lastDiagnosticReport = fallback?.providerMetadata?.diagnosticReport
            diagnostics[provider] = current
        }
    }

    private func compactLabel(for snapshot: ProviderBalanceSnapshot) -> String {
        switch snapshot.status {
        case .authRequired:
            return "\(snapshot.provider.shortLabel) !"
        case .supportedLimited:
            if let resetAt = snapshot.resetAt {
                return "\(snapshot.provider.shortLabel) Reset \(resetAt.veryShortRelativeLabel)"
            } else {
                return "\(snapshot.provider.shortLabel) Limited"
            }
        case .ok, .degraded, .error, .unsupported:
            if let window = snapshot.providerMetadata?.bailian?.primaryWindow {
                return "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let window = snapshot.providerMetadata?.zai?.primaryWindow {
                return "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let window = snapshot.providerMetadata?.codex?.primaryWindow {
                return "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let credits = snapshot.providerMetadata?.codex?.creditsRemaining {
                return "\(snapshot.provider.shortLabel) \(formattedCredits(credits)) cr"
            }
            if let remaining = snapshot.remainingValue {
                return "\(snapshot.provider.shortLabel) \(remaining)\(snapshot.remainingUnit.map { " \($0)" } ?? "")"
            } else if let resetAt = snapshot.resetAt {
                return "\(snapshot.provider.shortLabel) Reset \(resetAt.veryShortRelativeLabel)"
            } else {
                return "\(snapshot.provider.shortLabel) \(snapshot.status.badgeText)"
            }
        }
    }

    private func expandedLabel(for snapshot: ProviderBalanceSnapshot) -> String {
        switch snapshot.status {
        case .authRequired:
            return "\(snapshot.provider.displayName): auth"
        case .supportedLimited:
            if let resetAt = snapshot.resetAt {
                return "\(snapshot.provider.displayName): resets \(resetAt.veryShortRelativeLabel)"
            } else {
                return "\(snapshot.provider.displayName): limited"
            }
        case .ok, .degraded, .error, .unsupported:
            if let window = snapshot.providerMetadata?.bailian?.primaryWindow {
                return "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let window = snapshot.providerMetadata?.zai?.primaryWindow {
                return "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let window = snapshot.providerMetadata?.codex?.primaryWindow {
                return "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) \(Int(window.percentage.rounded()))%"
            }
            if let credits = snapshot.providerMetadata?.codex?.creditsRemaining {
                return "\(snapshot.provider.displayName): \(formattedCredits(credits)) credits"
            }
            if let remaining = snapshot.remainingValue {
                return "\(snapshot.provider.displayName): \(remaining)\(snapshot.remainingUnit.map { " \($0)" } ?? "")"
            }
            if let resetAt = snapshot.resetAt {
                return "\(snapshot.provider.displayName): resets \(resetAt.veryShortRelativeLabel)"
            }
            return "\(snapshot.provider.displayName): \(snapshot.status.badgeText)"
        }
    }

    private func scheduleAutomaticRefresh() {
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(RefreshPolicy.automaticInterval))
                await self?.refresh(force: true)
            }
        }
    }

    private func persistCache() {
        cacheStore.save(snapshots: snapshots, lastRefreshAt: lastRefreshAt)
    }

    private func formattedCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }
}
