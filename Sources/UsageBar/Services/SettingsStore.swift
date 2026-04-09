import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var snapshot: SettingsSnapshot

    private let defaults: UserDefaults
    private let key = "UsageBar.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
