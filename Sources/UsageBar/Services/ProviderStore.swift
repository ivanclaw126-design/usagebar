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
    private let sessionCapture: SessionCaptureType
    private let adapters: [ProviderKind: ProviderAdapter]
    private var refreshTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        credentialStore: CredentialStoreType,
        cacheStore: SnapshotCacheStore = SnapshotCacheStore(),
        sessionCapture: SessionCaptureType,
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

    var menuBarSegments: [MenuBarTextSegment] {
        let visibleProviders = ProviderKind.allCases.filter { settingsStore.configuration(for: $0).isEnabled }
        let items = visibleProviders.compactMap { provider -> MenuBarSummaryItem? in
            let snapshot = snapshots[provider] ?? .authRequired(provider: provider)
            return settingsStore.snapshot.compactMenuBar
                ? compactSummary(for: snapshot)
                : expandedSummary(for: snapshot)
        }

        guard items.isEmpty == false else {
            return [.init(text: "UsageBar", isEmphasized: false)]
        }

        var segments: [MenuBarTextSegment] = []
        for (index, item) in items.enumerated() {
            if index > 0 {
                segments.append(.init(text: " | ", isEmphasized: false))
            }
            segments.append(.init(text: item.leadingText, isEmphasized: false))
            if let emphasizedText = item.emphasizedText {
                segments.append(.init(text: emphasizedText, isEmphasized: true))
            }
            if let trailingText = item.trailingText {
                segments.append(.init(text: trailingText, isEmphasized: false))
            }
        }
        return segments
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

    var menuBarGlyphSnapshot: MenuBarGlyphSnapshot {
        let visibleSnapshots = ProviderKind.allCases
            .filter { settingsStore.configuration(for: $0).isEnabled }
            .compactMap { snapshots[$0] }

        if let codex = visibleSnapshots.first(where: { $0.providerMetadata?.codex != nil }),
           let primary = codex.providerMetadata?.codex?.windows.first(where: { $0.bucket == .fiveHour })?.percentage
        {
            let secondary = codex.providerMetadata?.codex?.windows.first(where: { $0.bucket == .weekly })?.percentage ?? 0
            return MenuBarGlyphSnapshot(
                primaryPercent: primary,
                secondaryPercent: secondary,
                hasIncident: codex.status == .error || codex.status == .authRequired
            )
        }

        if let bailian = visibleSnapshots.first(where: { $0.providerMetadata?.bailian != nil }),
           let primary = bailian.providerMetadata?.bailian?.windows.first(where: { $0.bucket == .fiveHour })?.percentage
        {
            let secondary = bailian.providerMetadata?.bailian?.windows.first(where: { $0.bucket == .weekly })?.percentage ?? 0
            return MenuBarGlyphSnapshot(
                primaryPercent: primary,
                secondaryPercent: secondary,
                hasIncident: bailian.status == .error || bailian.status == .authRequired
            )
        }

        if let zai = visibleSnapshots.first(where: { $0.providerMetadata?.zai != nil }),
           let primary = zai.providerMetadata?.zai?.windows.first(where: { $0.bucket == .fiveHour })?.percentage
        {
            let secondary = zai.providerMetadata?.zai?.windows.first(where: { $0.bucket == .weekly })?.percentage ?? 0
            return MenuBarGlyphSnapshot(
                primaryPercent: primary,
                secondaryPercent: secondary,
                hasIncident: zai.status == .error || zai.status == .authRequired
            )
        }

        return MenuBarGlyphSnapshot(primaryPercent: 100, secondaryPercent: 60, hasIncident: false)
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
            return settingsStore.text("Testing connection...", "正在测试连接...")
        }

        let snapshot = snapshots[provider] ?? .authRequired(provider: provider)
        switch snapshot.status {
        case .ok:
            return settingsStore.text("Connected", "已连接")
        case .degraded:
            if provider == .zaiGlobal {
                return settingsStore.text("Connected with partial quota data", "已连接，但配额数据不完整")
            }
            if provider == .openAIPlus {
                return settingsStore.text("Connected with fallback Codex data", "已连接，但使用了回退的 Codex 数据")
            }
            return settingsStore.text("Connected with fallback data", "已连接，但使用了回退数据")
        case .authRequired:
            return hasCredential(for: provider)
                ? settingsStore.text("Saved credential needs attention", "已保存的凭据需要处理")
                : settingsStore.text("Not connected", "未连接")
        case .unsupported:
            return settingsStore.text("Partially supported", "部分支持")
        case .supportedLimited:
            return settingsStore.text("Connected with limited visibility", "已连接，但可见数据有限")
        case .error:
            return settingsStore.text("Connection failed", "连接失败")
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
        lastRefreshAt = Date()
        persistCache()
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
            toastMessage = nil
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    func clearCredential(for provider: ProviderKind) {
        credentialStore.delete(for: provider)
        snapshots[provider] = .authRequired(provider: provider)
        diagnostics[provider] = .empty
        persistCache()
        toastMessage = nil
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
            await testConnection(for: provider)
        } catch {
            sessionCaptureErrorMessage = provider == .bailian
                ? "Could not capture the current Bailian session state from the web page."
                : "Could not capture cookies from the current browser session."
        }
    }

    private func refreshProvider(_ provider: ProviderKind) async {
        let checkedAt = Date()
        let credential = await refreshedCredential(for: provider, stored: credentialStore.load(for: provider))

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
            snapshots[provider] = .init(
                provider: provider,
                status: .authRequired,
                remainingValue: nil,
                remainingUnit: nil,
                usedValue: nil,
                resetAt: nil,
                fetchedAt: checkedAt,
                summaryText: "Authentication failed",
                detailText: "Your session may have expired. Please reconnect to refresh usage data.",
                providerMetadata: nil
            )
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

    private func refreshedCredential(
        for provider: ProviderKind,
        stored: StoredCredential?
    ) async -> StoredCredential? {
        guard let stored else { return nil }

        switch stored.kind {
        case .apiKey:
            return stored
        case .cookieJar:
            guard let liveCookieJar = await sessionCapture.currentCookieJar(for: provider),
                  liveCookieJar.isEmpty == false,
                  liveCookieJar != stored.value else {
                return stored
            }

            let refreshed = StoredCredential(kind: .cookieJar, value: liveCookieJar)
            try? credentialStore.save(refreshed, for: provider)
            return refreshed
        case .sessionToken:
            if provider == .bailian {
                if let refreshedState = await sessionCapture.refreshBailianSessionState() {
                    let refreshed = StoredCredential(kind: .sessionToken, value: refreshedState)
                    try? credentialStore.save(refreshed, for: provider)
                    return refreshed
                }
            }

            guard provider == .bailian,
                  let liveCookieJar = await sessionCapture.currentCookieJar(for: provider),
                  liveCookieJar.isEmpty == false,
                  var sessionState = try? decodedBailianSessionState(from: stored.value),
                  sessionState.cookies != liveCookieJar else {
                return stored
            }

            sessionState.cookies = liveCookieJar
            guard let encodedState = encodedBailianSessionState(sessionState) else {
                return stored
            }

            let refreshed = StoredCredential(kind: .sessionToken, value: encodedState)
            try? credentialStore.save(refreshed, for: provider)
            return refreshed
        }
    }

    private func decodedBailianSessionState(from value: String) throws -> BailianSessionState {
        let data = Data(value.utf8)
        return try JSONDecoder().decode(BailianSessionState.self, from: data)
    }

    private func encodedBailianSessionState(_ state: BailianSessionState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func compactLabel(for snapshot: ProviderBalanceSnapshot) -> String {
        compactSummary(for: snapshot)?.joinedText ?? snapshot.provider.shortLabel
    }

    private func compactSummary(for snapshot: ProviderBalanceSnapshot) -> MenuBarSummaryItem? {
        switch snapshot.status {
        case .authRequired:
            return .init(leadingText: "\(snapshot.provider.shortLabel) ", emphasizedText: "!", trailingText: nil)
        case .supportedLimited:
            if let resetAt = snapshot.resetAt {
                return .init(leadingText: "\(snapshot.provider.shortLabel) Reset \(resetAt.veryShortRelativeLabel)", emphasizedText: nil, trailingText: nil)
            } else {
                return .init(leadingText: "\(snapshot.provider.shortLabel) Limited", emphasizedText: nil, trailingText: nil)
            }
        case .ok, .degraded, .error, .unsupported:
            if let window = snapshot.providerMetadata?.bailian?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let window = snapshot.providerMetadata?.zai?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let window = snapshot.providerMetadata?.codex?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.shortLabel) \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let credits = snapshot.providerMetadata?.codex?.creditsRemaining, credits > 0 {
                return .init(leadingText: "\(snapshot.provider.shortLabel) \(formattedCredits(credits)) cr", emphasizedText: nil, trailingText: nil)
            }
            if let remaining = snapshot.remainingValue {
                return .init(
                    leadingText: "\(snapshot.provider.shortLabel) \(remaining)\(snapshot.remainingUnit.map { " \($0)" } ?? "")",
                    emphasizedText: nil,
                    trailingText: nil
                )
            } else if let resetAt = snapshot.resetAt {
                return .init(leadingText: "\(snapshot.provider.shortLabel) Reset \(resetAt.veryShortRelativeLabel)", emphasizedText: nil, trailingText: nil)
            } else {
                return .init(leadingText: "\(snapshot.provider.shortLabel) \(snapshot.status.badgeText)", emphasizedText: nil, trailingText: nil)
            }
        }
    }

    private func expandedLabel(for snapshot: ProviderBalanceSnapshot) -> String {
        expandedSummary(for: snapshot)?.joinedText ?? snapshot.provider.displayName
    }

    private func expandedSummary(for snapshot: ProviderBalanceSnapshot) -> MenuBarSummaryItem? {
        switch snapshot.status {
        case .authRequired:
            return .init(leadingText: "\(snapshot.provider.displayName): auth", emphasizedText: nil, trailingText: nil)
        case .supportedLimited:
            if let resetAt = snapshot.resetAt {
                return .init(leadingText: "\(snapshot.provider.displayName): resets \(resetAt.veryShortRelativeLabel)", emphasizedText: nil, trailingText: nil)
            } else {
                return .init(leadingText: "\(snapshot.provider.displayName): limited", emphasizedText: nil, trailingText: nil)
            }
        case .ok, .degraded, .error, .unsupported:
            if let window = snapshot.providerMetadata?.bailian?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let window = snapshot.providerMetadata?.zai?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let window = snapshot.providerMetadata?.codex?.primaryWindow {
                return percentageSummary(
                    prefix: "\(snapshot.provider.displayName): \(window.bucket.menuBarLabel) ",
                    percentage: Int(window.percentage.rounded())
                )
            }
            if let credits = snapshot.providerMetadata?.codex?.creditsRemaining, credits > 0 {
                return .init(leadingText: "\(snapshot.provider.displayName): \(formattedCredits(credits)) credits", emphasizedText: nil, trailingText: nil)
            }
            if let remaining = snapshot.remainingValue {
                return .init(
                    leadingText: "\(snapshot.provider.displayName): \(remaining)\(snapshot.remainingUnit.map { " \($0)" } ?? "")",
                    emphasizedText: nil,
                    trailingText: nil
                )
            }
            if let resetAt = snapshot.resetAt {
                return .init(leadingText: "\(snapshot.provider.displayName): resets \(resetAt.veryShortRelativeLabel)", emphasizedText: nil, trailingText: nil)
            }
            return .init(leadingText: "\(snapshot.provider.displayName): \(snapshot.status.badgeText)", emphasizedText: nil, trailingText: nil)
        }
    }

    private func percentageSummary(prefix: String, percentage: Int) -> MenuBarSummaryItem {
        .init(leadingText: prefix, emphasizedText: "\(percentage)%", trailingText: nil)
    }

    private func scheduleAutomaticRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                let delay = await MainActor.run {
                    self?.secondsUntilNextAutomaticRefresh() ?? RefreshPolicy.automaticCheckInterval
                }
                try? await Task.sleep(for: .seconds(delay))
                await self?.refreshIfNeeded(force: false)
            }
        }
    }

    private func secondsUntilNextAutomaticRefresh() -> TimeInterval {
        let remaining: TimeInterval
        if let lastRefreshAt {
            remaining = RefreshPolicy.automaticInterval - Date().timeIntervalSince(lastRefreshAt)
        } else {
            remaining = 0
        }
        return min(max(remaining, 1), RefreshPolicy.automaticCheckInterval)
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

struct MenuBarGlyphSnapshot {
    var primaryPercent: Double
    var secondaryPercent: Double
    var hasIncident: Bool
}

struct MenuBarSummaryItem {
    var leadingText: String
    var emphasizedText: String?
    var trailingText: String?

    var joinedText: String {
        leadingText + (emphasizedText ?? "") + (trailingText ?? "")
    }
}

struct MenuBarTextSegment: Identifiable {
    let id = UUID()
    let text: String
    let isEmphasized: Bool
}
