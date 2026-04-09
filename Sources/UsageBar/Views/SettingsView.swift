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
                    Text("UsageBar Settings")
                        .font(.largeTitle.weight(.bold))

                    if settingsStore.shouldShowOnboarding(hasAnyCredential: providerStore.hasAnyCredentialConfigured) {
                        onboardingGuide
                    }

                    Toggle("Use compact menu bar summary", isOn: Binding(
                        get: { settingsStore.snapshot.compactMenuBar },
                        set: { settingsStore.setCompactMenuBar($0) }
                    ))

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
        }
    }

    private var onboardingGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Getting Started")
                        .font(.title3.weight(.semibold))
                    Text("UsageBar works best when you connect at least one provider first. Start with the service you use most often.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Hide Guide") {
                    settingsStore.dismissOnboarding()
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 10) {
                guideRow(
                    title: "1. Choose a provider",
                    detail: "Bailian works best with Web Session for real Coding Plan usage. Z.ai Global supports API keys, and Codex works best from a local `codex` CLI login."
                )
                guideRow(
                    title: "2. Save credentials",
                    detail: "Paste an API key or open the embedded browser login flow. Credentials are stored in your macOS Keychain."
                )
                guideRow(
                    title: "3. Verify before closing",
                    detail: "Press Test Connection. A successful check will fill in Last success and the menu bar will start showing live status."
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
                Toggle("Enabled", isOn: Binding(
                    get: { configuration.isEnabled },
                    set: { value in
                        settingsStore.updateConfiguration(for: provider) { $0.isEnabled = value }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Picker("Connection", selection: Binding(
                get: { configuration.authMode },
                set: { newValue in
                    settingsStore.updateConfiguration(for: provider) { $0.authMode = newValue }
                }
            )) {
                if provider.supportsAPIKey {
                    Text(ProviderAuthMode.apiKey.displayName).tag(ProviderAuthMode.apiKey)
                }
                Text(ProviderAuthMode.webSession.displayName).tag(ProviderAuthMode.webSession)
            }
            .pickerStyle(.segmented)
            .opacity(provider == .openAIPlus ? 0.55 : 1)
            .disabled(provider == .openAIPlus)

            if provider == .openAIPlus {
                HStack {
                    Button("Test Codex CLI") {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.isTestingConnection)

                    Button("Optional: Connect Web Session") {
                        providerStore.beginSessionCapture(for: provider)
                    }
                    .buttonStyle(.bordered)

                    if hasCredential {
                        Button("Clear Web Session") {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }

                Text("UsageBar checks your local `codex` login first by probing the Codex CLI. A saved web session is only used as a limited fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Make sure `codex` is installed and already signed in on this Mac before testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if configuration.authMode == .apiKey, provider.supportsAPIKey {
                SecureField("Paste API key or token", text: Binding(
                    get: { draftSecrets[provider, default: ""] },
                    set: { draftSecrets[provider] = $0 }
                ))
                HStack {
                    Button("Save API Key") {
                        let value = draftSecrets[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.isEmpty == false else { return }
                        providerStore.saveCredential(kind: .apiKey, value: value, for: provider)
                        draftSecrets[provider] = ""
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Connection") {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(hasCredential == false || diagnostics.isTestingConnection)

                    if hasCredential {
                        Button("Clear") {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }

                if provider == .bailian || provider == .zaiGlobal {
                    let helperText = provider == .zaiGlobal
                        ? "Z.ai checks subscription and quota endpoints with your API key, then maps the response into 5h, weekly, and monthly windows."
                        : "Bailian API key mode only verifies that your sk-sp key is active. Real Coding Plan usage still comes from the Web Session path."
                    Text(helperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if provider == .zaiGlobal || provider == .bailian {
                    let testText = provider == .zaiGlobal
                        ? "Test Connection runs the subscription list and quota limits endpoints separately, then stores a diagnostic report you can copy below."
                        : "Test Connection verifies the API key with a minimal DashScope request. For real usage windows, switch to Web Session and test again."
                    Text(testText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Button("Connect via Web Login") {
                        providerStore.beginSessionCapture(for: provider)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Connection") {
                        Task {
                            await providerStore.testConnection(for: provider)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(hasCredential == false || diagnostics.isTestingConnection)

                    if hasCredential {
                        Button("Clear Session") {
                            providerStore.clearCredential(for: provider)
                        }
                    }
                }
                Text("A secure embedded browser will open so you can sign in and save the current session cookies to Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if provider == .bailian {
                    Text("For Bailian, Web Session is the recommended mode because Coding Plan usage is shown in the console rather than a stable public quota API.")
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
                Text(providerStore.currentCredentialKind(for: provider)?.rawValue ?? "No credential saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Status: \(providerStore.connectionStateText(for: provider))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Last checked: \(diagnostics.lastCheckedAt?.dashboardLabel ?? "Never")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Last success: \(diagnostics.lastSuccessfulRefreshAt?.dashboardLabel ?? "Never")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = diagnostics.lastErrorMessage {
                    Text("Last error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if (provider == .zaiGlobal || provider == .bailian || provider == .openAIPlus), let report = diagnostics.lastDiagnosticReport {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Diagnostics")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy Diagnostics") {
                                copyToPasteboard(report)
                                providerStore.toastMessage = "\(provider.displayName) diagnostics copied."
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
}

struct SessionCaptureContainer: View {
    @EnvironmentObject private var providerStore: ProviderStore
    let provider: ProviderKind
    private let webView: WKWebView

    init(provider: ProviderKind) {
        self.provider = provider
        self.webView = SessionCapture().makeWebView(for: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect \(provider.displayName)")
                    .font(.headline)
                Spacer()
                Button("Save Session") {
                    Task {
                        await providerStore.saveSession(from: webView, for: provider)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
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
    }
}
