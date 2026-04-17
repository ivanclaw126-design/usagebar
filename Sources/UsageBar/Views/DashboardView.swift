import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var providerStore: ProviderStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var currentTime = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .opacity(0.94)
                .ignoresSafeArea()

            if usesScrollableLayout {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
            } else {
                content
            }
        }
        .onReceive(countdownTimer) { value in
            currentTime = value
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if settingsStore.shouldShowOnboarding(hasAnyCredential: providerStore.hasAnyCredentialConfigured) {
                onboardingCard
            }
            ForEach(providerStore.orderedSnapshots.filter { settingsStore.configuration(for: $0.provider).isEnabled }) { snapshot in
                ProviderCardView(
                    snapshot: snapshot,
                    hasCredential: providerStore.hasCredential(for: snapshot.provider),
                    reconnectAction: {
                        openSettingsWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            providerStore.beginSessionCapture(for: snapshot.provider)
                        }
                    }
                )
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var usesScrollableLayout: Bool {
        settingsStore.snapshot.dashboardHeightMode != .max
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("UsageBar")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(text("Coding plan balances across your active subscriptions.", "聚合展示你当前订阅的 coding plan 余额。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(text("Refresh", "刷新")) {
                        Task {
                            await providerStore.refresh(force: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button(text("Settings", "设置")) {
                        openSettingsWindow()
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Label(
                    providerStore.lastRefreshAt?.dashboardLabel(isChinese: settingsStore.snapshot.language == .chinese)
                        ?? text("Not refreshed yet", "尚未刷新"),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if providerStore.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("First Run Guide", "首次使用指引"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(text("Connect one provider first, then come back here to test refresh and watch the menu bar update.", "先连接至少一个供应商，再回来测试刷新并观察菜单栏更新。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(text("Dismiss", "隐藏")) {
                    settingsStore.dismissOnboarding()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                onboardingStep(number: 1, text: text("Open Settings and choose Bailian, Z.ai Global, or Codex.", "打开设置，选择百炼、Z.ai Global 或 Codex。"))
                onboardingStep(number: 2, text: text("Use Web Session for Bailian, API key for Z.ai, or test your local `codex` CLI login for Codex.", "百炼建议使用网页登录，Z.ai 建议使用 API Key，Codex 建议测试本地 `codex` CLI 登录。"))
                onboardingStep(number: 3, text: text("Press Test Connection after saving credentials. Once one provider succeeds, the menu bar title will switch from warning markers to live balance info.", "保存凭据后点击测试连接。任一供应商成功后，菜单栏标题就会切换为实时状态。"))
            }

            HStack {
                Button(text("Open Settings", "打开设置")) {
                    openSettingsWindow()
                }
                .buttonStyle(.borderedProminent)

                Text(text("You can reopen this guide later from Settings.", "你之后也可以在设置中重新打开这份指引。"))
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(text("Quit", "退出")) {
                    AppDelegate.terminateApp()
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(text("Auto refresh in", "自动刷新倒计时") + " " + refreshCountdownText)
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

    private var refreshCountdownText: String {
        let remaining: TimeInterval
        if let lastRefreshAt = providerStore.lastRefreshAt {
            remaining = max(0, RefreshPolicy.automaticInterval - currentTime.timeIntervalSince(lastRefreshAt))
        } else {
            remaining = RefreshPolicy.automaticInterval
        }
        let totalSeconds = Int(remaining.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)min\(String(format: "%02d", seconds))s"
    }

    private func text(_ english: String, _ chinese: String) -> String {
        settingsStore.text(english, chinese)
    }

    private func openSettingsWindow() {
        SettingsWindowManager.shared.present(
            providerStore: providerStore,
            settingsStore: settingsStore
        )
    }
}
