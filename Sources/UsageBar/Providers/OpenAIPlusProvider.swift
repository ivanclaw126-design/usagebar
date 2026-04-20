import Foundation

struct OpenAIPlusProvider: ProviderAdapter {
    let provider: ProviderKind = .openAIPlus
    private let client = ProviderHTTPClient()
    private let oauthUsageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let accountEndpoints = [
        URL(string: "https://chatgpt.com/backend-api/accounts/check")!,
        URL(string: "https://chatgpt.com/backend-api/accounts/status")!
    ]

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        var diagnostics: [ProviderEndpointDiagnostic] = []
        let account = Self.loadAuthBackedCodexAccount()

        if let accessToken = Self.loadOAuthAccessToken() {
            do {
                let oauthSnapshot = try await fetchFromOAuth(accessToken, account: account, diagnostics: &diagnostics)
                return oauthSnapshot
            } catch {
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Codex OAuth",
                        path: "/backend-api/wham/usage",
                        statusText: "Failed",
                        detail: error.localizedDescription
                    )
                )
            }
        } else {
            diagnostics.append(
                ProviderEndpointDiagnostic(
                    name: "Codex OAuth",
                    path: "~/.codex/auth.json",
                    statusText: "Missing",
                    detail: "No access token was found in the local Codex auth.json file."
                )
            )
        }

        do {
            return try await fetchFromLocalCodex(account: account, diagnostics: &diagnostics)
        } catch {
            diagnostics.append(
                ProviderEndpointDiagnostic(
                    name: "Local Codex",
                    path: "~/.codex + codex CLI",
                    statusText: "Failed",
                    detail: error.localizedDescription
                )
            )
        }

        if let credential,
           credential.kind == .cookieJar || credential.kind == .sessionToken
        {
            do {
                return try await fetchFromWebSession(credential, diagnostics: diagnostics)
            } catch {
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "OpenAI Web",
                        path: "/backend-api/accounts/check",
                        statusText: "Failed",
                        detail: error.localizedDescription
                    )
                )
            }
        }

        throw ProviderError.unsupportedFeature(
            diagnostics.isEmpty
                ? "Codex CLI is not ready yet. Install `codex`, sign in, then test again."
                : diagnostics.map { "\($0.name): \($0.detail)" }.joined(separator: "\n")
        )
    }

    private func fetchFromOAuth(
        _ accessToken: String,
        account: CodexAccountInfo,
        diagnostics: inout [ProviderEndpointDiagnostic]
    ) async throws -> ProviderBalanceSnapshot {
        let json = try await client.jsonRequest(
            url: oauthUsageEndpoint,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ]
        )
        diagnostics.append(
            ProviderEndpointDiagnostic(
                name: "Codex OAuth",
                path: "/backend-api/wham/usage",
                statusText: "OK",
                detail: "Loaded usage windows from the OpenAI Codex OAuth endpoint."
            )
        )
        return try Self.makeOAuthSnapshot(from: json, account: account, diagnostics: diagnostics)
    }

    private func fetchFromLocalCodex(
        account: CodexAccountInfo,
        diagnostics: inout [ProviderEndpointDiagnostic]
    ) async throws -> ProviderBalanceSnapshot {
        do {
            let rpcSnapshot = try await Self.fetchViaRPC()
            diagnostics.append(
                ProviderEndpointDiagnostic(
                    name: "Codex RPC",
                    path: "codex app-server",
                    statusText: "OK",
                    detail: "Loaded rate limits from the local Codex RPC server."
                )
            )
            return Self.makeSnapshot(
                from: rpcSnapshot,
                account: account,
                sourceLabel: "Local RPC",
                diagnostics: diagnostics
            )
        } catch {
            diagnostics.append(
                ProviderEndpointDiagnostic(
                    name: "Codex RPC",
                    path: "codex app-server",
                    statusText: "Failed",
                    detail: error.localizedDescription
                )
            )
        }

        let statusSnapshot = try await Self.fetchViaStatus()
        diagnostics.append(
            ProviderEndpointDiagnostic(
                name: "Codex Status",
                path: "codex /status",
                statusText: "OK",
                detail: "Loaded rate limits from the local Codex terminal status output."
            )
        )
        return Self.makeSnapshot(
            from: statusSnapshot,
            account: account,
            sourceLabel: "CLI Status",
            diagnostics: diagnostics
        )
    }

    static func makeOAuthSnapshot(
        from json: Any,
        account: CodexAccountInfo,
        diagnostics: [ProviderEndpointDiagnostic]
    ) throws -> ProviderBalanceSnapshot {
        let reader = ProviderPayloadReader(root: json)
        let fetchedAt = Date()

        let primaryUsed = reader.number(forKeyPaths: [
            ["rate_limit", "primary_window", "used_percent"],
            ["primary", "usedPercent"],
            ["usage", "primary", "usedPercent"],
            ["rateLimits", "primary", "usedPercent"],
            ["data", "primary", "usedPercent"]
        ])
        let primaryReset = reader.date(forKeyPaths: [
            ["rate_limit", "primary_window", "reset_at"],
            ["primary", "resetsAt"],
            ["usage", "primary", "resetsAt"],
            ["rateLimits", "primary", "resetsAt"],
            ["data", "primary", "resetsAt"]
        ])

        let secondaryUsed = reader.number(forKeyPaths: [
            ["rate_limit", "secondary_window", "used_percent"],
            ["secondary", "usedPercent"],
            ["usage", "secondary", "usedPercent"],
            ["rateLimits", "secondary", "usedPercent"],
            ["data", "secondary", "usedPercent"]
        ])
        let secondaryReset = reader.date(forKeyPaths: [
            ["rate_limit", "secondary_window", "reset_at"],
            ["secondary", "resetsAt"],
            ["usage", "secondary", "resetsAt"],
            ["rateLimits", "secondary", "resetsAt"],
            ["data", "secondary", "resetsAt"]
        ])

        let credits = reader.number(forKeyPaths: [
            ["credits", "balance"],
            ["credits", "balance"],
            ["usage", "credits", "balance"],
            ["rateLimits", "credits", "balance"],
            ["data", "credits", "balance"]
        ])

        let windows = [
            primaryUsed.map {
                CodexUsageWindow(
                    bucket: .fiveHour,
                    percentage: $0,
                    resetAt: primaryReset,
                    resetDescription: nil,
                    rawLabel: "primary"
                )
            },
            secondaryUsed.map {
                CodexUsageWindow(
                    bucket: .weekly,
                    percentage: $0,
                    resetAt: secondaryReset,
                    resetDescription: nil,
                    rawLabel: "secondary"
                )
            }
        ].compactMap { $0 }

        guard windows.isEmpty == false || credits != nil else {
            throw ProviderError.invalidResponse
        }

        let diagnosticReport = diagnostics.map { "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)" }.joined(separator: "\n")
        let resolvedPlanName = Self.resolvePlanName(from: reader, fallback: account.plan)
        let metadata = CodexProviderMetadata(
            sourceLabel: "OAuth API",
            planName: resolvedPlanName,
            accountEmail: reader.string(forKeyPaths: [["email"]]) ?? account.email,
            windows: windows,
            creditsRemaining: credits,
            diagnosticReport: diagnosticReport
        )
        let primaryWindow = windows.first { $0.bucket != .unmatched }
        let summary = primaryWindow.map { "\($0.bucket.displayName) \(Int($0.percentage.rounded()))%" }
            ?? credits.map { "Credits \(formatCredits($0))" }
            ?? "Codex connected"

        var detailParts = ["OAuth API"]
        if let plan = resolvedPlanName {
            detailParts.append(plan)
        }
        if let email = account.email {
            detailParts.append(email)
        }
        if let credits, credits > 0 {
            detailParts.append("Credits \(formatCredits(credits))")
        }

        return ProviderBalanceSnapshot(
            provider: .openAIPlus,
            status: .ok,
            remainingValue: (credits ?? 0) > 0 ? credits.map(formatCredits) : nil,
            remainingUnit: (credits ?? 0) > 0 ? "credits" : nil,
            usedValue: nil,
            resetAt: primaryWindow?.resetAt,
            fetchedAt: fetchedAt,
            summaryText: summary,
            detailText: detailParts.joined(separator: " • "),
            providerMetadata: ProviderSnapshotMetadata(codex: metadata)
        )
    }

    private static func normalizePlanName(_ plan: String?) -> String? {
        guard let rawPlan = normalizedField(plan)?.lowercased() else { return nil }

        let canonical = rawPlan
            .replacingOccurrences(of: "chatgpt", with: "")
            .replacingOccurrences(of: "subscription", with: "")
            .replacingOccurrences(of: "plan", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch canonical {
        case "go":
            return "Go"
        case "plus":
            return "Plus"
        case "pro", "prolite":
            return "Pro"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "free":
            return "Free"
        default:
            return rawPlan
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func resolvePlanName(from reader: ProviderPayloadReader, fallback: String? = nil) -> String? {
        let candidates = reader.strings(forKeyPaths: [
            ["account", "plan_type"],
            ["account", "planType"],
            ["account", "plan", "type"],
            ["account", "plan", "name"],
            ["account", "subscription", "plan"],
            ["account", "subscription", "plan_type"],
            ["account", "subscription", "name"],
            ["subscription", "plan"],
            ["subscription", "plan_type"],
            ["subscription", "name"],
            ["plan_type"],
            ["planType"],
            ["plan", "type"],
            ["plan", "name"]
        ]) + [fallback].compactMap { $0 }

        for candidate in candidates {
            if let normalized = normalizePlanName(candidate) {
                return normalized
            }
        }

        return nil
    }

    private func fetchFromWebSession(
        _ credential: StoredCredential,
        diagnostics: [ProviderEndpointDiagnostic]
    ) async throws -> ProviderBalanceSnapshot {
        var lastError: Error?
        for endpoint in accountEndpoints {
            do {
                let json = try await client.jsonRequest(
                    url: endpoint,
                    headers: [
                        "Cookie": credential.value,
                        "Accept": "application/json"
                    ]
                )
                return try Self.makeWebSnapshot(from: json, diagnostics: diagnostics)
            } catch ProviderError.unauthorized {
                throw ProviderError.unauthorized
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProviderError.invalidResponse
    }

    static func makeWebSnapshot(from json: Any, diagnostics: [ProviderEndpointDiagnostic] = []) throws -> ProviderBalanceSnapshot {
        let fetchedAt = Date()
        let reader = ProviderPayloadReader(root: json)
        let plan = Self.resolvePlanName(from: reader) ?? "Plus"
        let resetAt = reader.date(forKeyPaths: [
            ["account", "usage_reset_at"],
            ["account", "message_cap_reset_at"],
            ["account", "next_reset_at"],
            ["usage_reset_at"],
            ["message_cap_reset_at"],
            ["next_reset_at"]
        ])
        let isPaid = reader.bool(forKeyPaths: [
            ["account", "has_active_subscription"],
            ["account", "is_paid_subscription_active"],
            ["has_active_subscription"],
            ["is_paid_subscription_active"]
        ]) ?? true

        let metadata = CodexProviderMetadata(
            sourceLabel: "OpenAI Web",
            planName: plan,
            accountEmail: nil,
            windows: [],
            creditsRemaining: nil,
            diagnosticReport: diagnostics.map { "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)" }.joined(separator: "\n")
        )

        return ProviderBalanceSnapshot(
            provider: .openAIPlus,
            status: isPaid ? .supportedLimited : .authRequired,
            remainingValue: nil,
            remainingUnit: nil,
            usedValue: nil,
            resetAt: resetAt,
            fetchedAt: fetchedAt,
            summaryText: isPaid ? "\(plan) active" : "Subscription unavailable",
            detailText: isPaid
                ? "Fallback web session is active. Precise Codex windows come from the local Codex CLI when available."
                : "The current signed-in session does not show an active paid OpenAI plan.",
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: nil, codex: metadata)
        )
    }

    static func makeSnapshot(
        from rpc: CodexRPCSnapshot,
        account: CodexAccountInfo,
        sourceLabel: String,
        diagnostics: [ProviderEndpointDiagnostic]
    ) -> ProviderBalanceSnapshot {
        let windows = makeWindows(primary: rpc.primary, secondary: rpc.secondary)
        let diagnosticReport = diagnostics.map { "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)" }.joined(separator: "\n")
        let metadata = CodexProviderMetadata(
            sourceLabel: sourceLabel,
            planName: Self.normalizePlanName(account.plan),
            accountEmail: account.email,
            windows: windows,
            creditsRemaining: rpc.creditsRemaining,
            diagnosticReport: diagnosticReport
        )
        let primaryWindow = windows.first { $0.bucket != .unmatched }
        let summary: String
        if let primaryWindow {
            summary = "\(primaryWindow.bucket.displayName) \(Int(primaryWindow.percentage.rounded()))%"
        } else if let credits = rpc.creditsRemaining {
            summary = "Credits \(Self.formatCredits(credits))"
        } else {
            summary = "Codex connected"
        }

        var detailParts: [String] = []
        detailParts.append(sourceLabel)
        if let plan = metadata.planName {
            detailParts.append(plan)
        }
        if let email = account.email {
            detailParts.append(email)
        }
        if let credits = rpc.creditsRemaining {
            detailParts.append("Credits \(Self.formatCredits(credits))")
        }

        return ProviderBalanceSnapshot(
            provider: .openAIPlus,
            status: .ok,
            remainingValue: rpc.creditsRemaining.map(Self.formatCredits),
            remainingUnit: rpc.creditsRemaining != nil ? "credits" : nil,
            usedValue: nil,
            resetAt: primaryWindow?.resetAt,
            fetchedAt: Date(),
            summaryText: summary,
            detailText: detailParts.joined(separator: " • "),
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: nil, codex: metadata)
        )
    }

    static func makeSnapshot(
        from status: CodexStatusSnapshot,
        account: CodexAccountInfo,
        sourceLabel: String,
        diagnostics: [ProviderEndpointDiagnostic]
    ) -> ProviderBalanceSnapshot {
        let windows = [
            status.fiveHourPercentLeft.map {
                CodexUsageWindow(
                    bucket: .fiveHour,
                    percentage: Double(max(0, 100 - $0)),
                    resetAt: status.fiveHourResetsAt,
                    resetDescription: status.fiveHourResetDescription,
                    rawLabel: "5h limit"
                )
            },
            status.weeklyPercentLeft.map {
                CodexUsageWindow(
                    bucket: .weekly,
                    percentage: Double(max(0, 100 - $0)),
                    resetAt: status.weeklyResetsAt,
                    resetDescription: status.weeklyResetDescription,
                    rawLabel: "Weekly limit"
                )
            }
        ].compactMap { $0 }

        let diagnosticReport = diagnostics.map { "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)" }.joined(separator: "\n")
        let metadata = CodexProviderMetadata(
            sourceLabel: sourceLabel,
            planName: Self.normalizePlanName(account.plan),
            accountEmail: account.email,
            windows: windows,
            creditsRemaining: status.credits,
            diagnosticReport: diagnosticReport
        )
        let primaryWindow = windows.first { $0.bucket != .unmatched }
        let summary = primaryWindow.map { "\($0.bucket.displayName) \(Int($0.percentage.rounded()))%" }
            ?? status.credits.map { "Credits \(Self.formatCredits($0))" }
            ?? "Codex connected"

        var detailParts: [String] = [sourceLabel]
        if let plan = metadata.planName {
            detailParts.append(plan)
        }
        if let email = account.email {
            detailParts.append(email)
        }
        if let credits = status.credits {
            detailParts.append("Credits \(Self.formatCredits(credits))")
        }

        return ProviderBalanceSnapshot(
            provider: .openAIPlus,
            status: .ok,
            remainingValue: status.credits.map(Self.formatCredits),
            remainingUnit: status.credits != nil ? "credits" : nil,
            usedValue: nil,
            resetAt: primaryWindow?.resetAt,
            fetchedAt: Date(),
            summaryText: summary,
            detailText: detailParts.joined(separator: " • "),
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: nil, codex: metadata)
        )
    }

    private static func makeWindows(primary: CodexRPCWindow?, secondary: CodexRPCWindow?) -> [CodexUsageWindow] {
        [
            primary.map {
                CodexUsageWindow(
                    bucket: .fiveHour,
                    percentage: $0.usedPercent,
                    resetAt: $0.resetsAt,
                    resetDescription: nil,
                    rawLabel: "primary"
                )
            },
            secondary.map {
                CodexUsageWindow(
                    bucket: .weekly,
                    percentage: $0.usedPercent,
                    resetAt: $0.resetsAt,
                    resetDescription: nil,
                    rawLabel: "secondary"
                )
            }
        ].compactMap { $0 }
    }

    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }

    static func fetchViaRPC() async throws -> CodexRPCSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try CodexRPCClient().fetchSnapshot()
        }.value
    }

    static func fetchViaStatus() async throws -> CodexStatusSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try CodexStatusProbe().fetch()
        }.value
    }

    static func loadAuthBackedCodexAccount() -> CodexAccountInfo {
        let candidates: [URL] = [
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("auth.json") },
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        ].compactMap { $0 }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let tokens = json["tokens"] as? [String: Any]
            let accountID = (json["account_id"] as? String) ?? (tokens?["account_id"] as? String)
            let email = normalizedField(json["email"] as? String)
            let idToken = (json["id_token"] as? String) ?? (tokens?["id_token"] as? String)
            let payload = idToken.flatMap(parseJWT)
            let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
            let profile = payload?["https://api.openai.com/profile"] as? [String: Any]

            let resolvedEmail = normalizedField(email ?? profile?["email"] as? String ?? payload?["email"] as? String)
            let plan = normalizedField(
                auth?["chatgpt_plan_type"] as? String
                    ?? auth?["chatgpt_subscription_plan"] as? String
                    ?? profile?["plan_type"] as? String
                    ?? payload?["chatgpt_plan_type"] as? String
                    ?? payload?["plan_type"] as? String
            )
            return CodexAccountInfo(accountID: accountID, email: resolvedEmail, plan: plan)
        }

        return CodexAccountInfo(accountID: nil, email: nil, plan: nil)
    }

    private static func normalizedField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        return value
    }

    static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func loadOAuthAccessToken() -> String? {
        let candidates: [URL] = [
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("auth.json") },
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        ].compactMap { $0 }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let tokens = json["tokens"] as? [String: Any]
            if let accessToken = (json["access_token"] as? String) ?? (tokens?["access_token"] as? String),
               accessToken.isEmpty == false
            {
                return accessToken
            }
        }

        return nil
    }
}

struct CodexAccountInfo: Equatable {
    var accountID: String?
    var email: String?
    var plan: String?
}

struct CodexRPCSnapshot: Equatable {
    var primary: CodexRPCWindow?
    var secondary: CodexRPCWindow?
    var creditsRemaining: Double?
}

struct CodexRPCWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
}

struct CodexStatusSnapshot: Equatable {
    var credits: Double?
    var fiveHourPercentLeft: Int?
    var weeklyPercentLeft: Int?
    var fiveHourResetDescription: String?
    var weeklyResetDescription: String?
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?
    var rawText: String
}

private final class CodexRPCClient {
    func fetchSnapshot() throws -> CodexRPCSnapshot {
        let env = ProcessInfo.processInfo.environment
        let binary = Self.resolveBinaryPath(environment: env)
        let payload = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"usagebar","version":"0.1"}}}
        {"method":"initialized","params":{}}
        {"id":2,"method":"account/rateLimits/read","params":{}}
        """

        let result = try Self.runProcess(
            executable: "/usr/bin/env",
            arguments: [binary, "-s", "read-only", "-a", "untrusted", "app-server"],
            environment: mergedEnvironment(from: env),
            stdin: Data(payload.utf8),
            timeout: 8
        )

        let messages = result.stdout
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        guard let rateLimits = messages.first(where: {
            (($0["id"] as? Int) ?? ($0["id"] as? NSNumber)?.intValue) == 2
        }) else {
            throw ProviderError.unsupportedFeature(
                "Codex RPC timed out or returned no rate-limit payload.\n\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        let rateResult = rateLimits["result"] as? [String: Any]
        let ratePayload = rateResult?["rateLimits"] as? [String: Any] ?? rateResult ?? [:]
        let primary = Self.parseWindow(ratePayload["primary"] as? [String: Any])
        let secondary = Self.parseWindow(ratePayload["secondary"] as? [String: Any])
        let credits = Self.parseCredits(ratePayload["credits"] as? [String: Any])
        return CodexRPCSnapshot(primary: primary, secondary: secondary, creditsRemaining: credits)
    }

    private static func parseWindow(_ json: [String: Any]?) -> CodexRPCWindow? {
        guard let json else { return nil }
        let usedPercent = (json["usedPercent"] as? Double)
            ?? (json["usedPercent"] as? NSNumber)?.doubleValue
            ?? (json["used_percent"] as? NSNumber)?.doubleValue
        let resetsRaw = (json["resetsAt"] as? Int)
            ?? (json["resetsAt"] as? NSNumber)?.intValue
            ?? (json["resets_at"] as? NSNumber)?.intValue
        guard let usedPercent else { return nil }
        return CodexRPCWindow(
            usedPercent: usedPercent,
            resetsAt: resetsRaw.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func parseCredits(_ json: [String: Any]?) -> Double? {
        guard let json else { return nil }
        if let balance = json["balance"] as? String {
            return Double(balance)
        }
        if let balance = json["balance"] as? NSNumber {
            return balance.doubleValue
        }
        return nil
    }

    static func resolveBinaryPath(environment: [String: String]) -> String {
        if let explicit = environment["CODEX_BINARY"], explicit.isEmpty == false {
            return explicit
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let shellResolved = resolveBinaryPathFromShell(), shellResolved.isEmpty == false {
            return shellResolved
        }

        return "codex"
    }

    static func effectivePATH(environment: [String: String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return Array(NSOrderedSet(array: preferred + existing)).compactMap { $0 as? String }.joined(separator: ":")
    }

    private static func resolveBinaryPathFromShell() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex 2>/dev/null || which codex 2>/dev/null"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let resolved = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return resolved?.isEmpty == false ? resolved : nil
        } catch {
            return nil
        }
    }

    private func mergedEnvironment(from environment: [String: String]) -> [String: String] {
        var childEnvironment = environment
        childEnvironment["PATH"] = Self.effectivePATH(environment: environment)
        return childEnvironment
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> (stdout: String, stderr: String) {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = ProcessDataBuffer()
        let stderrBuffer = ProcessDataBuffer()
        let semaphore = DispatchSemaphore(value: 0)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(stdin)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            throw ProviderError.unsupportedFeature("Codex process timed out after \(Int(timeout))s.")
        }

        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return (
            stdout: String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""
        )
    }
}

private final class ProcessDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

struct CodexStatusProbe {
    func fetch() throws -> CodexStatusSnapshot {
        let env = ProcessInfo.processInfo.environment
        let binary = CodexRPCClient.resolveBinaryPath(environment: env)
        var childEnvironment = env
        childEnvironment["PATH"] = CodexRPCClient.effectivePATH(environment: env)
        childEnvironment["TERM"] = "xterm-256color"
        let result = try CodexRPCClient.runProcess(
            executable: "/usr/bin/script",
            arguments: ["-q", "/dev/null", binary, "-s", "read-only", "-a", "untrusted"],
            environment: childEnvironment,
            stdin: Data("/status\n/exit\n".utf8),
            timeout: 8
        )
        let text = result.stdout

        return try Self.parse(text: text)
    }

    static func parse(text: String, now: Date = .init()) throws -> CodexStatusSnapshot {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let credits = firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: clean)
        let fiveLine = firstLine(matching: #"5h limit[^\n]*"#, text: clean)
        let weekLine = firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)
        let fivePct = fiveLine.flatMap(percentLeft)
        let weekPct = weekLine.flatMap(percentLeft)
        let fiveReset = fiveLine.flatMap(resetString)
        let weekReset = weekLine.flatMap(resetString)

        if credits == nil, fivePct == nil, weekPct == nil {
            throw ProviderError.unsupportedFeature("Codex CLI output could not be parsed.")
        }

        return CodexStatusSnapshot(
            credits: credits,
            fiveHourPercentLeft: fivePct,
            weeklyPercentLeft: weekPct,
            fiveHourResetDescription: fiveReset,
            weeklyResetDescription: weekReset,
            fiveHourResetsAt: parseResetDate(from: fiveReset, now: now),
            weeklyResetsAt: parseResetDate(from: weekReset, now: now),
            rawText: clean
        )
    }

    private static func firstLine(matching pattern: String, text: String) -> String? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex?.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        return String(text[swiftRange])
    }

    private static func firstNumber(pattern: String, text: String) -> Double? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex?.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[swiftRange].replacingOccurrences(of: ",", with: ""))
    }

    private static func percentLeft(from line: String) -> Int? {
        let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3})%"#, options: [])
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex?.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: line)
        else { return nil }
        return Int(line[swiftRange])
    }

    private static func resetString(from line: String) -> String? {
        if let range = line.range(of: #"resets?[^\n]*"#, options: [.regularExpression, .caseInsensitive]) {
            return String(line[range]).replacingOccurrences(of: "resets", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = line.range(of: #"at\s+[0-9]{1,2}:[0-9]{2}.*$"#, options: [.regularExpression, .caseInsensitive]) {
            return String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func parseResetDate(from text: String?, now: Date) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else { return nil }
        raw = raw.replacingOccurrences(of: "at ", with: "")
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.defaultDate = now

        for format in ["d MMM HH:mm", "MMM d HH:mm", "HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                if format == "HH:mm" || format == "H:mm" {
                    let components = calendar.dateComponents([.hour, .minute], from: date)
                    guard let anchored = calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: now) else {
                        return nil
                    }
                    return anchored >= now ? anchored : calendar.date(byAdding: .day, value: 1, to: anchored)
                }
                return date >= now ? date : calendar.date(byAdding: .year, value: 1, to: date)
            }
        }
        return nil
    }
}
