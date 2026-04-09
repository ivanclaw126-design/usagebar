import SwiftUI
import WebKit
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var providerStore: ProviderStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var draftSecrets: [ProviderKind: String] = [:]

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(text("UsageBar Settings", "UsageBar 设置"))
                        .font(.largeTitle.weight(.bold))

                    if settingsStore.shouldShowOnboarding(hasAnyCredential: providerStore.hasAnyCredentialConfigured) {
                        onboardingGuide
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(text("Display Language", "显示语言"))
                            .font(.headline)
                        Picker(text("Language", "语言"), selection: Binding(
                            get: { settingsStore.snapshot.language },
                            set: { settingsStore.setLanguage($0) }
                        )) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle(text("Use compact menu bar summary", "使用紧凑菜单栏摘要"), isOn: Binding(
                        get: { settingsStore.snapshot.compactMenuBar },
                        set: { settingsStore.setCompactMenuBar($0) }
                    ))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(text("Launch at login", "开机自动启动"), isOn: Binding(
                            get: { settingsStore.snapshot.launchAtLogin },
                            set: { settingsStore.setLaunchAtLogin($0) }
                        ))
                        if settingsStore.launchAtLoginErrorMessage == nil {
                            Text(settingsStore.launchAtLoginStatusText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(settingsStore.launchAtLoginStatusText())
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }

                    ForEach(ProviderKind.allCases) { provider in
                        providerSection(for: provider)
                    }
                }
                .padding(24)
            }
        }
        .sheet(item: Binding(
            get: { providerStore.activeSessionProvider },
            set: { _ in providerStore.endSessionCapture() }
        )) { provider in
            SessionCaptureContainer(provider: provider)
                .environmentObject(providerStore)
                .environmentObject(settingsStore)
        }
        .onAppear {
            AppDelegate.bringAppToFront()
        }
    }

    private var onboardingGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("Getting Started", "开始使用"))
                        .font(.title3.weight(.semibold))
                    Text(text("UsageBar works best when you connect at least one provider first. Start with the service you use most often.", "UsageBar 最适合先连接至少一个供应商。建议从你最常用的服务开始。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(text("Hide Guide", "隐藏指引")) {
                    settingsStore.dismissOnboarding()
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 10) {
                guideRow(
                    title: text("1. Choose a provider", "1. 选择供应商"),
                    detail: text("Bailian works best with Web Session for real Coding Plan usage. Z.ai Global supports API keys, and Codex works best from a local `codex` CLI login.", "百炼建议使用网页登录来读取真实 Coding Plan 用量。Z.ai Global 支持 API Key，Codex 最适合使用本地 `codex` CLI 登录。")
                )
                guideRow(
                    title: text("2. Save credentials", "2. 保存凭据"),
                    detail: text("Paste an API key or open the embedded browser login flow. Credentials are stored in your macOS Keychain.", "粘贴 API Key，或者打开内嵌浏览器完成登录。凭据会存储到 macOS Keychain。")
                )
                guideRow(
                    title: text("3. Verify before closing", "3. 关闭前先验证"),
                    detail: text("Press Test Connection. A successful check will fill in Last success and the menu bar will start showing live status.", "点击测试连接。验证成功后会写入最近成功时间，菜单栏也会开始显示实时状态。")
                )
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func providerSection(for provider: ProviderKind) -> some View {
        let configuration = settingsStore.configuration(for: provider)
        let diagnostics = providerStore.diagnostics(for: provider)
        let hasCredential = providerStore.hasCredential(for: provider)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.displayName)
                    .font(.title3.weight(.semibold))
                Spacer()
                connectionBadge(for: provider)
                Toggle(text("Enabled", "启用"), isOn: Binding(
                    get: { configuration.isEnabled },
                    set: { value in
                        settingsStore.updateConfiguration(for: provider) { $0.isEnabled = value }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Picker(text("Connection", "连接方式"), selection: Binding(
                get: { configuration.authMode },
                set: { newValue in
                    settingsStore.updateConfiguration(for: provider) { $0.authMode = newValue }
                }
            )) {
                if provider.supportsAPIKey {
                    Text(localizedAuthMode(.apiKey)).tag(ProviderAuthMode.apiKey)
                }
                Text(localizedAuthMode(.webSession)).tag(ProviderAuthMode.webSession)
            }
            .pickerStyle(.segmented)
            .opacity(provider == .openAIPlus ? 0.55 : 1)
            .disabled(provider == .openAIPlus)

            if provider == .openAIPlus {
                HStack {
                    Button(text("Test Codex CLI", "测试 Codex CLI")) {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.isTestingConnection)

                    Button(text("Optional: Connect Web Session", "可选：连接网页登录")) {
                        providerStore.beginSessionCapture(for: provider)
                    }
                    .buttonStyle(.bordered)

                    if hasCredential {
                        Button(text("Clear Web Session", "清除网页登录")) {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }

                Text(text("UsageBar checks your local `codex` login first by probing the Codex CLI. A saved web session is only used as a limited fallback.", "UsageBar 会优先探测你本机的 `codex` 登录状态。保存的网页登录仅作为有限兜底。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(text("Make sure `codex` is installed and already signed in on this Mac before testing.", "测试前请确认这台 Mac 已安装 `codex`，并且已经登录。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if configuration.authMode == .apiKey, provider.supportsAPIKey {
                SecureField(text("Paste API key or token", "粘贴 API Key 或令牌"), text: Binding(
                    get: { draftSecrets[provider, default: ""] },
                    set: { draftSecrets[provider] = $0 }
                ))
                HStack {
                    Button(text("Save API Key", "保存 API Key")) {
                        let value = draftSecrets[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.isEmpty == false else { return }
                        providerStore.saveCredential(kind: .apiKey, value: value, for: provider)
                        draftSecrets[provider] = ""
                    }
                    .buttonStyle(.borderedProminent)

                    Button(text("Test Connection", "测试连接")) {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(hasCredential == false || diagnostics.isTestingConnection)

                    if hasCredential {
                        Button(text("Clear", "清除")) {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }

                if provider == .bailian || provider == .zaiGlobal {
                    let helperText = provider == .zaiGlobal
                        ? text("Z.ai checks subscription and quota endpoints with your API key, then maps the response into 5h, weekly, and monthly windows.", "Z.ai 会使用你的 API Key 检查订阅和配额接口，再把返回结果映射成 5h、周和月窗口。")
                        : text("Bailian API key mode only verifies that your sk-sp key is active. Real Coding Plan usage still comes from the Web Session path.", "百炼 API Key 模式只验证你的 sk-sp key 是否可用。真实 Coding Plan 用量仍然来自网页登录路径。")
                    Text(helperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if provider == .zaiGlobal || provider == .bailian {
                    let testText = provider == .zaiGlobal
                        ? text("Test Connection runs the subscription list and quota limits endpoints separately, then stores a diagnostic report you can copy below.", "测试连接会分别调用 subscription list 和 quota limits 接口，然后保存一份可复制的诊断报告。")
                        : text("Test Connection verifies the API key with a minimal DashScope request. For real usage windows, switch to Web Session and test again.", "测试连接会用最小化的 DashScope 请求验证 API Key。若要查看真实用量窗口，请切换到网页登录后再测试。")
                    Text(testText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Button(text("Connect via Web Login", "通过网页登录")) {
                        providerStore.beginSessionCapture(for: provider)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(text("Test Connection", "测试连接")) {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(hasCredential == false || diagnostics.isTestingConnection)

                    if hasCredential {
                        Button(text("Clear Session", "清除会话")) {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }
                Text(text("A secure embedded browser will open so you can sign in and save the current session cookies to Keychain.", "会打开一个安全的内嵌浏览器，供你登录并把当前会话 Cookie 保存到 Keychain。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if provider == .bailian {
                    Text(text("For Bailian, Web Session is the recommended mode because Coding Plan usage is shown in the console rather than a stable public quota API.", "对于百炼，推荐使用网页登录，因为 Coding Plan 用量显示在控制台中，而不是稳定的公开配额 API。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let toast = providerStore.toastMessage {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                let isChinese = settingsStore.snapshot.language == .chinese
                let statusText = providerStore.connectionStateText(for: provider)
                let lastCheckedText = diagnostics.lastCheckedAt?.dashboardLabel(isChinese: isChinese) ?? text("Never", "从未")
                let lastSuccessText = diagnostics.lastSuccessfulRefreshAt?.dashboardLabel(isChinese: isChinese) ?? text("Never", "从未")

                Text(providerStore.currentCredentialKind(for: provider)?.rawValue ?? text("No credential saved", "尚未保存凭据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(text("Status", "状态")): \(statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(text("Last checked", "最近检查")): \(lastCheckedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(text("Last success", "最近成功")): \(lastSuccessText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = diagnostics.lastErrorMessage {
                    Text(text("Last error", "最近错误") + ": \(error)")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if (provider == .zaiGlobal || provider == .bailian || provider == .openAIPlus), let report = diagnostics.lastDiagnosticReport {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(text("Diagnostics", "诊断信息"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(text("Copy Diagnostics", "复制诊断")) {
                                copyToPasteboard(report)
                                providerStore.toastMessage = text("\(provider.displayName) diagnostics copied.", "\(provider.displayName) 诊断信息已复制。")
                            }
                            .buttonStyle(.borderless)
                        }

                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }

    private func connectionBadge(for provider: ProviderKind) -> some View {
        Text(providerStore.connectionStateText(for: provider))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badgeColor(for: provider).opacity(0.18))
            .foregroundStyle(badgeColor(for: provider))
            .clipShape(Capsule())
    }

    private func badgeColor(for provider: ProviderKind) -> Color {
        switch providerStore.diagnostics(for: provider).isTestingConnection {
        case true:
            return .yellow
        case false:
            break
        }

        let snapshot = providerStore.snapshots[provider] ?? .authRequired(provider: provider)
        switch snapshot.status {
        case .ok:
            return .green
        case .degraded:
            return .yellow
        case .authRequired, .error:
            return .red
        case .supportedLimited:
            return .blue
        case .unsupported:
            return .secondary
        }
    }

    private func guideRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func text(_ english: String, _ chinese: String) -> String {
        settingsStore.text(english, chinese)
    }

    private func localizedAuthMode(_ mode: ProviderAuthMode) -> String {
        switch mode {
        case .apiKey:
            return text("API Key / Token", "API Key / 令牌")
        case .webSession:
            return text("Web Session", "网页登录")
        }
    }
}

struct SessionCaptureContainer: View {
    @EnvironmentObject private var providerStore: ProviderStore
    @EnvironmentObject private var settingsStore: SettingsStore
    let provider: ProviderKind
    private let webView: WKWebView

    init(provider: ProviderKind) {
        self.provider = provider
        self.webView = SessionCapture().makeWebView(for: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(settingsStore.text("Connect \(provider.displayName)", "连接 \(provider.displayName)"))
                    .font(.headline)
                Spacer()
                Button(settingsStore.text("Save Session", "保存会话")) {
                    Task {
                        await providerStore.saveSession(from: webView, for: provider)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(settingsStore.text("Cancel", "取消")) {
                    providerStore.endSessionCapture()
                }
            }
            .padding()

            if let error = providerStore.sessionCaptureErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            SessionCaptureSheet(webView: webView)
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear {
            AppDelegate.bringAppToFront()
        }
    }
}
