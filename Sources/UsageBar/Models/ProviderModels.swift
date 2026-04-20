import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable {
    case bailian
    case zaiGlobal
    case openAIPlus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bailian: "Bailian"
        case .zaiGlobal: "Z.ai Global"
        case .openAIPlus: "OpenAI Codex"
        }
    }

    var shortLabel: String {
        switch self {
        case .bailian: "B"
        case .zaiGlobal: "Z"
        case .openAIPlus: "O"
        }
    }

    var supportsAPIKey: Bool {
        switch self {
        case .openAIPlus: false
        case .bailian, .zaiGlobal: true
        }
    }

    var supportsWebSession: Bool { true }

    var loginURL: URL {
        switch self {
        case .bailian:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=coding-plan#/efm/coding-plan-detail")!
        case .zaiGlobal:
            URL(string: "https://z.ai")!
        case .openAIPlus:
            URL(string: "https://chatgpt.com")!
        }
    }
}

enum ProviderStatus: String, Codable {
    case ok
    case degraded
    case authRequired
    case unsupported
    case supportedLimited
    case error

    var badgeText: String {
        switch self {
        case .ok: "Connected"
        case .degraded: "Delayed"
        case .authRequired: "Auth Required"
        case .unsupported: "Unsupported"
        case .supportedLimited: "Limited"
        case .error: "Error"
        }
    }
}

enum CredentialKind: String, Codable {
    case apiKey
    case cookieJar
    case sessionToken
}

enum ProviderAuthMode: String, Codable, CaseIterable, Identifiable {
    case apiKey
    case webSession

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiKey: "API Key / Token"
        case .webSession: "Web Session"
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

struct ProviderBalanceSnapshot: Equatable, Codable, Identifiable {
    var provider: ProviderKind
    var status: ProviderStatus
    var remainingValue: String?
    var remainingUnit: String?
    var usedValue: String?
    var resetAt: Date?
    var fetchedAt: Date
    var summaryText: String
    var detailText: String
    var providerMetadata: ProviderSnapshotMetadata?

    var id: ProviderKind { provider }

    static func authRequired(provider: ProviderKind, fetchedAt: Date = .now) -> Self {
        .init(
            provider: provider,
            status: .authRequired,
            remainingValue: nil,
            remainingUnit: nil,
            usedValue: nil,
            resetAt: nil,
            fetchedAt: fetchedAt,
            summaryText: "Not connected",
            detailText: "Add credentials in Settings to enable balance checks.",
            providerMetadata: nil
        )
    }
}

struct ProviderConnectionDiagnostics: Equatable {
    var lastCheckedAt: Date?
    var lastSuccessfulRefreshAt: Date?
    var lastErrorMessage: String?
    var lastDiagnosticReport: String?
    var isTestingConnection: Bool

    static let empty = ProviderConnectionDiagnostics(
        lastCheckedAt: nil,
        lastSuccessfulRefreshAt: nil,
        lastErrorMessage: nil,
        lastDiagnosticReport: nil,
        isTestingConnection: false
    )
}

struct ProviderSnapshotMetadata: Equatable, Codable {
    var bailian: BailianProviderMetadata?
    var zai: ZAIProviderMetadata?
    var codex: CodexProviderMetadata?

    init(
        bailian: BailianProviderMetadata? = nil,
        zai: ZAIProviderMetadata? = nil,
        codex: CodexProviderMetadata? = nil
    ) {
        self.bailian = bailian
        self.zai = zai
        self.codex = codex
    }

    var diagnosticReport: String? {
        bailian?.diagnosticReport ?? zai?.diagnosticReport ?? codex?.diagnosticReport
    }
}

struct CodexProviderMetadata: Equatable, Codable {
    var sourceLabel: String
    var planName: String?
    var accountEmail: String?
    var windows: [CodexUsageWindow]
    var creditsRemaining: Double?
    var diagnosticReport: String

    var primaryWindow: CodexUsageWindow? {
        windows.first { $0.bucket != .unmatched }
    }
}

enum CodexUsageBucket: String, Equatable, Codable {
    case fiveHour
    case weekly
    case unmatched

    var displayName: String {
        switch self {
        case .fiveHour: "5 Hours"
        case .weekly: "Weekly"
        case .unmatched: "Other Limits"
        }
    }

    var menuBarLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "week"
        case .unmatched: "other"
        }
    }
}

struct CodexUsageWindow: Equatable, Codable, Identifiable {
    var bucket: CodexUsageBucket
    var percentage: Double
    var resetAt: Date?
    var resetDescription: String?
    var rawLabel: String

    var id: String {
        "\(bucket.rawValue)-\(rawLabel)"
    }
}

struct BailianProviderMetadata: Equatable, Codable {
    var host: String
    var planName: String?
    var statusText: String?
    var windows: [BailianUsageWindow]
    var diagnostics: [ProviderEndpointDiagnostic]
    var unmatchedWindowCount: Int
    var diagnosticReport: String

    var primaryWindow: BailianUsageWindow? {
        windows.first { $0.bucket != .unmatched }
    }
}

enum BailianUsageBucket: String, Equatable, Codable {
    case fiveHour
    case weekly
    case monthly
    case unmatched

    var displayName: String {
        switch self {
        case .fiveHour: "5 Hours"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .unmatched: "Other Limits"
        }
    }

    var menuBarLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "week"
        case .monthly: "month"
        case .unmatched: "other"
        }
    }
}

struct BailianUsageWindow: Equatable, Codable, Identifiable {
    var bucket: BailianUsageBucket
    var limit: Double
    var used: Double
    var remaining: Double
    var percentage: Double
    var resetAt: Date?
    var rawLabel: String
    var rawType: String?

    var id: String {
        "\(bucket.rawValue)-\(rawLabel)-\(rawType ?? "none")"
    }
}

struct ZAIProviderMetadata: Equatable, Codable {
    var host: String
    var planName: String?
    var subscriptionStatusText: String?
    var windows: [ZAIQuotaWindow]
    var diagnostics: [ProviderEndpointDiagnostic]
    var unmatchedWindowCount: Int
    var diagnosticReport: String

    var primaryWindow: ZAIQuotaWindow? {
        windows.first { $0.bucket != .unmatched }
    }
}

enum ZAIQuotaBucket: String, Equatable, Codable {
    case fiveHour
    case weekly
    case mcpMonthly
    case unmatched

    var displayName: String {
        switch self {
        case .fiveHour: "5 Hours"
        case .weekly: "Weekly"
        case .mcpMonthly: "MCP tokens"
        case .unmatched: "Other Limits"
        }
    }

    var menuBarLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "week"
        case .mcpMonthly: "month"
        case .unmatched: "other"
        }
    }
}

struct ZAIQuotaWindow: Equatable, Codable, Identifiable {
    var bucket: ZAIQuotaBucket
    var limit: Double
    var used: Double
    var remaining: Double
    var percentage: Double
    var resetAt: Date?
    var resetDescription: String?
    var rawType: String
    var rawUnit: Int
    var rawNumber: Int

    var id: String {
        "\(bucket.rawValue)-\(rawType)-\(rawUnit)-\(rawNumber)"
    }
}

struct ProviderEndpointDiagnostic: Equatable, Codable, Identifiable {
    var name: String
    var path: String
    var statusText: String
    var detail: String

    var id: String { name }
}

struct ProviderConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var authMode: ProviderAuthMode
    var compactDisplay: Bool

    static func `default`(for provider: ProviderKind) -> Self {
        .init(
            isEnabled: true,
            authMode: defaultAuthMode(for: provider),
            compactDisplay: true
        )
    }

    private static func defaultAuthMode(for provider: ProviderKind) -> ProviderAuthMode {
        switch provider {
        case .bailian:
            return .webSession
        case .zaiGlobal:
            return .apiKey
        case .openAIPlus:
            return .webSession
        }
    }
}

enum DashboardHeightMode: String, Codable, CaseIterable, Identifiable {
    case max
    case medium
    case low

    var id: String { rawValue }
}

struct SettingsSnapshot: Codable, Equatable {
    var compactMenuBar: Bool
    var launchAtLogin: Bool
    var providerConfigurations: [ProviderKind: ProviderConfiguration]
    var didDismissOnboarding: Bool
    var language: AppLanguage
    var dashboardHeightMode: DashboardHeightMode

    init(
        compactMenuBar: Bool,
        launchAtLogin: Bool,
        providerConfigurations: [ProviderKind: ProviderConfiguration],
        didDismissOnboarding: Bool,
        language: AppLanguage,
        dashboardHeightMode: DashboardHeightMode
    ) {
        self.compactMenuBar = compactMenuBar
        self.launchAtLogin = launchAtLogin
        self.providerConfigurations = providerConfigurations
        self.didDismissOnboarding = didDismissOnboarding
        self.language = language
        self.dashboardHeightMode = dashboardHeightMode
    }

    enum CodingKeys: String, CodingKey {
        case compactMenuBar
        case launchAtLogin
        case providerConfigurations
        case didDismissOnboarding
        case language
        case dashboardHeightMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compactMenuBar = try container.decodeIfPresent(Bool.self, forKey: .compactMenuBar) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        providerConfigurations = try container.decodeIfPresent([ProviderKind: ProviderConfiguration].self, forKey: .providerConfigurations)
            ?? Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .default(for: $0)) })
        didDismissOnboarding = try container.decodeIfPresent(Bool.self, forKey: .didDismissOnboarding) ?? false
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .english
        dashboardHeightMode = try container.decodeIfPresent(DashboardHeightMode.self, forKey: .dashboardHeightMode) ?? .max
    }

    static let `default` = SettingsSnapshot(
        compactMenuBar: true,
        launchAtLogin: false,
        providerConfigurations: Dictionary(
            uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .default(for: $0)) }
        ),
        didDismissOnboarding: false,
        language: .english,
        dashboardHeightMode: .max
    )
}

struct RefreshPolicy {
    static let automaticInterval: TimeInterval = 300
    static let automaticCheckInterval: TimeInterval = 15
}
