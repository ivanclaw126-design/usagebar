import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var snapshot: SettingsSnapshot
    @Published private(set) var launchAtLoginErrorMessage: String?

    private let defaults: UserDefaults
    private let launchAtLoginManager: LaunchAtLoginManaging
    private let key = "UsageBar.settings"

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginManager: LaunchAtLoginManaging = SystemLaunchAtLoginManager()
    ) {
        self.defaults = defaults
        self.launchAtLoginManager = launchAtLoginManager
        if
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(SettingsSnapshot.self, from: data)
        {
            snapshot = decoded
        } else {
            snapshot = .default
        }
    }

    func configuration(for provider: ProviderKind) -> ProviderConfiguration {
        snapshot.providerConfigurations[provider] ?? .default(for: provider)
    }

    func setCompactMenuBar(_ isCompact: Bool) {
        snapshot.compactMenuBar = isCompact
        persist()
    }

    func setLaunchAtLogin(_ isEnabled: Bool) {
        snapshot.launchAtLogin = isEnabled
        persist()

        do {
            try launchAtLoginManager.setEnabled(isEnabled)
            launchAtLoginErrorMessage = nil
        } catch {
            snapshot.launchAtLogin = isEnabled == false
            persist()
            launchAtLoginErrorMessage = error.localizedDescription
        }
    }

    func setLanguage(_ language: AppLanguage) {
        snapshot.language = language
        persist()
    }

    func setDashboardHeightMode(_ mode: DashboardHeightMode) {
        snapshot.dashboardHeightMode = mode
        persist()
    }

    func dismissOnboarding() {
        snapshot.didDismissOnboarding = true
        persist()
    }

    func resetOnboarding() {
        snapshot.didDismissOnboarding = false
        persist()
    }

    func shouldShowOnboarding(hasAnyCredential: Bool) -> Bool {
        hasAnyCredential == false && snapshot.didDismissOnboarding == false
    }

    func syncLaunchAtLoginPreference() {
        do {
            try launchAtLoginManager.setEnabled(snapshot.launchAtLogin)
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = error.localizedDescription
        }
    }

    func launchAtLoginStatusText() -> String {
        if let launchAtLoginErrorMessage {
            return launchAtLoginErrorMessage
        }

        switch launchAtLoginManager.status {
        case .enabled:
            return text("Enabled", "已启用")
        case .requiresApproval:
            return text("Waiting for approval", "等待系统批准")
        case .notRegistered:
            return text("Disabled", "已禁用")
        case .notFound:
            return text("Unavailable", "不可用")
        @unknown default:
            return text("Unknown", "未知")
        }
    }

    func updateConfiguration(for provider: ProviderKind, mutate: (inout ProviderConfiguration) -> Void) {
        var config = configuration(for: provider)
        mutate(&config)
        snapshot.providerConfigurations[provider] = config
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

extension SettingsStore {
    func text(_ english: String, _ chinese: String) -> String {
        snapshot.language == .chinese ? chinese : english
    }
}
