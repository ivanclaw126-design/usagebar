import SwiftUI
import AppKit

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
            dashboardContent
        } label: {
            HStack(spacing: 6) {
                MenuBarUsageGlyph(snapshot: providerStore.menuBarGlyphSnapshot)
                MenuBarTitleView(segments: providerStore.menuBarSegments)
            }
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        let content = DashboardView()
            .environmentObject(providerStore)
            .environmentObject(settingsStore)
            .frame(width: 420)
            .task {
                await providerStore.refreshIfNeeded(force: false)
            }

        if settingsStore.snapshot.dashboardHeightMode == .max {
            content
        } else {
            content.frame(
                minHeight: DashboardWindowSizing.minimumHeight(for: settingsStore.snapshot.dashboardHeightMode),
                idealHeight: DashboardWindowSizing.idealHeight(for: settingsStore.snapshot.dashboardHeightMode),
                maxHeight: DashboardWindowSizing.maximumHeight(for: settingsStore.snapshot.dashboardHeightMode)
            )
        }
    }
}

private enum DashboardWindowSizing {
    static func minimumHeight(for mode: DashboardHeightMode) -> CGFloat {
        switch mode {
        case .max:
            return min(620, availableMaximumHeight)
        case .medium:
            return min(620, maximumHeight(for: mode))
        case .low:
            return min(520, maximumHeight(for: mode))
        }
    }

    static func idealHeight(for mode: DashboardHeightMode) -> CGFloat {
        switch mode {
        case .max:
            return min(760, availableMaximumHeight)
        case .medium:
            return min(620, maximumHeight(for: mode))
        case .low:
            return min(520, maximumHeight(for: mode))
        }
    }

    static func maximumHeight(for mode: DashboardHeightMode) -> CGFloat {
        switch mode {
        case .max:
            return availableMaximumHeight
        case .medium:
            return min(620, availableMaximumHeight)
        case .low:
            return min(520, availableMaximumHeight)
        }
    }

    private static var availableMaximumHeight: CGFloat {
        let visibleHeight = activeScreenVisibleHeight
        return max(560, visibleHeight - 160)
    }

    private static var activeScreenVisibleHeight: CGFloat {
        let mouseLocation = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return hoveredScreen.visibleFrame.height
        }
        return NSScreen.main?.visibleFrame.height ?? 820
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
