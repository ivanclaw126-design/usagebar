import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var providerStore: ProviderStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.97, blue: 0.98),
                    Color(red: 0.92, green: 0.94, blue: 0.97),
                    Color(red: 0.98, green: 0.95, blue: 0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                    .offset(x: -60, y: -90)
            }
            .overlay {
                VisualEffectView(material: .popover, blendingMode: .withinWindow)
                    .opacity(0.94)
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                if settingsStore.shouldShowOnboarding(hasAnyCredential: providerStore.hasAnyCredentialConfigured) {
                    onboardingCard
                }
                ForEach(providerStore.orderedSnapshots.filter { settingsStore.configuration(for: $0.provider).isEnabled }) { snapshot in
                    ProviderCardView(
                        snapshot: snapshot,
                        hasCredential: providerStore.hasCredential(for: snapshot.provider),
                        reconnectAction: { providerStore.beginSessionCapture(for: snapshot.provider) }
                    )
                }
                footer
            }
            .padding(18)
        }
        .sheet(item: Binding(
            get: { providerStore.activeSessionProvider },
            set: { _ in providerStore.endSessionCapture() }
        )) { provider in
            SessionCaptureContainer(provider: provider)
                .environmentObject(providerStore)
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First Run Guide")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Connect one provider first, then come back here to test refresh and watch the menu bar update.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Dismiss") {
                    settingsStore.dismissOnboarding()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                onboardingStep(number: 1, text: "Open Settings and choose Bailian, Z.ai Global, or Codex.")
                onboardingStep(number: 2, text: "Use Web Session for Bailian, API key for Z.ai, or test your local `codex` CLI login for Codex.")
                onboardingStep(number: 3, text: "Press Test Connection after saving credentials. Once one provider succeeds, the menu bar title will switch from warning markers to live balance info.")
            }

            HStack {
                Button("Open Settings") {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)

                Text("You can reopen this guide later from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.58))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.75), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.06), radius: 18, y: 10)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UsageBar")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Coding plan balances across your active subscriptions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Label(providerStore.lastRefreshAt?.dashboardLabel ?? "Not refreshed yet", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if providerStore.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = providerStore.toastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Now") {
                    Task {
                        await providerStore.refresh(force: true)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Settings") {
                    openSettings()
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("Auto refresh every 5 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func onboardingStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.7))
                .clipShape(Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
