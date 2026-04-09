import Foundation

struct OpenAIPlusProvider: ProviderAdapter {
    let provider: ProviderKind = .openAIPlus
    private let client = ProviderHTTPClient()
    private let accountEndpoints = [
        URL(string: "https://chatgpt.com/backend-api/accounts/check")!,
        URL(string: "https://chatgpt.com/backend-api/accounts/status")!
    ]

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        var diagnostics: [ProviderEndpointDiagnostic] = []

        do {
            return try await fetchFromLocalCodex(diagnostics: &diagnostics)
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

    private func fetchFromLocalCodex(diagnostics: inout [ProviderEndpointDiagnostic]) async throws -> ProviderBalanceSnapshot {
        let account = Self.loadAuthBackedCodexAccount()
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
        let plan = reader.string(forKeyPaths: [
            ["account", "plan_type"],
            ["account", "planType"],
            ["plan_type"],
            ["planType"]
        ]) ?? "Plus"
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
            planName: account.plan,
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
        if let plan = account.plan {
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
            planName: account.plan,
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
        if let plan = account.plan {
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
            let plan = normalizedField(auth?["chatgpt_plan_type"] as? String ?? payload?["chatgpt_plan_type"] as? String)
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
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    init() throws {
        let env = ProcessInfo.processInfo.environment
        let binary = Self.resolveBinaryPath(environment: env)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var childEnvironment = env
        childEnvironment["PATH"] = Self.effectivePATH(environment: env)
        process.environment = childEnvironment
        try process.run()
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    func fetchSnapshot() throws -> CodexRPCSnapshot {
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        _ = try request(id: 1, method: "initialize", params: [
            "clientInfo": [
                "name": "usagebar",
                "version": "0.1"
            ]
        ])
        try sendNotification(method: "initialized")
        let rateLimits = try request(id: 2, method: "account/rateLimits/read", params: [:])
        let account = try? request(id: 3, method: "account/read", params: [:])

        let rateResult = rateLimits["result"] as? [String: Any]
        let ratePayload = rateResult?["rateLimits"] as? [String: Any] ?? rateResult ?? [:]
        let primary = Self.parseWindow(ratePayload["primary"] as? [String: Any])
        let secondary = Self.parseWindow(ratePayload["secondary"] as? [String: Any])
        let credits = Self.parseCredits(ratePayload["credits"] as? [String: Any])
        _ = account
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

    private func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try sendPayload([
            "id": id,
            "method": method,
            "params": params
        ])

        while true {
            let message = try readNextMessage()
            if message["method"] != nil && message["id"] == nil {
                continue
            }
            let messageID = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue
            guard messageID == id else { continue }
            if let error = message["error"] as? [String: Any],
               let errorMessage = error["message"] as? String
            {
                throw ProviderError.unsupportedFeature("Codex RPC failed: \(errorMessage)")
            }
            return message
        }
    }

    private func sendNotification(method: String) throws {
        try sendPayload([
            "method": method,
            "params": [:]
        ])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() throws -> [String: Any] {
        while true {
            guard let line = try stdoutPipe.fileHandleForReading.read(upToCount: 16_384),
                  line.isEmpty == false
            else {
                let stderrData = stderrPipe.fileHandleForReading.availableData
                let stderrText = String(data: stderrData, encoding: .utf8) ?? "app-server closed stdout"
                throw ProviderError.unsupportedFeature("Codex RPC closed early: \(stderrText)")
            }

            for candidate in String(decoding: line, as: UTF8.self).split(separator: "\n") {
                guard let data = String(candidate).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                return json
            }
        }
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
}

struct CodexStatusProbe {
    func fetch() throws -> CodexStatusSnapshot {
        let env = ProcessInfo.processInfo.environment
        let binary = CodexRPCClient.resolveBinaryPath(environment: env)
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary, "-s", "read-only", "-a", "untrusted"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var childEnvironment = env
        childEnvironment["PATH"] = CodexRPCClient.effectivePATH(environment: env)
        childEnvironment["TERM"] = "xterm-256color"
        process.environment = childEnvironment

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data("/status\n/exit\n".utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 || text.isEmpty == false else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "status probe failed"
            throw ProviderError.unsupportedFeature("Codex status probe failed: \(stderrText)")
        }

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
