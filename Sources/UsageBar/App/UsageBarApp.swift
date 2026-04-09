import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var providerStore: ProviderStore

    init() {
        let settingsStore = SettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _providerStore = StateObject(
            wrappedValue: ProviderStore(
                settingsStore: settingsStore,
                credentialStore: CredentialStore(),
                sessionCapture: SessionCapture()
            )
        )
    }

    var body: some Scene {
        MenuBarExtra(providerStore.menuBarTitle, systemImage: providerStore.menuBarSymbolName) {
            DashboardView()
                .environmentObject(providerStore)
                .environmentObject(settingsStore)
                .frame(width: 420)
                .task {
                    await providerStore.refreshIfNeeded(force: false)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(providerStore)
                .environmentObject(settingsStore)
                .frame(width: 560, height: 680)
        }
    }
}
