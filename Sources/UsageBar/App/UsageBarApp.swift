import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var providerStore: ProviderStore

    init() {
        let settingsStore = SettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        settingsStore.syncLaunchAtLoginPreference()
        _providerStore = StateObject(
            wrappedValue: ProviderStore(
                settingsStore: settingsStore,
                credentialStore: CredentialStore(),
                sessionCapture: SessionCapture()
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(providerStore)
                .environmentObject(settingsStore)
                .frame(width: 420)
                .task {
                    await providerStore.refreshIfNeeded(force: false)
                }
        } label: {
            HStack(spacing: 6) {
                MenuBarUsageGlyph(snapshot: providerStore.menuBarGlyphSnapshot)
                MenuBarTitleView(segments: providerStore.menuBarSegments)
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

private struct MenuBarTitleView: View {
    let segments: [MenuBarTextSegment]

    var body: some View {
        segments.reduce(Text("")) { partial, segment in
            partial + Text(segment.text).fontWeight(segment.isEmphasized ? .bold : .regular)
        }
    }
}

private struct MenuBarUsageGlyph: View {
    let snapshot: MenuBarGlyphSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Capsule()
                .fill(topColor)
                .frame(width: max(6, 14 * CGFloat(snapshot.primaryPercent / 100)), height: 5)
            Capsule()
                .fill(bottomColor)
                .frame(width: max(4, 14 * CGFloat(snapshot.secondaryPercent / 100)), height: 3)
        }
        .frame(width: 14, height: 10, alignment: .leading)
    }

    private var topColor: Color {
        snapshot.hasIncident ? .red : .primary
    }

    private var bottomColor: Color {
        snapshot.hasIncident ? .red.opacity(0.8) : .primary.opacity(0.72)
    }
}
