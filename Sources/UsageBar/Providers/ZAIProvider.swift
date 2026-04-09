import Foundation

struct ZAIProvider: ProviderAdapter {
    let provider: ProviderKind = .zaiGlobal
    private let client = ProviderHTTPClient()
    private let host = "https://api.z.ai"
    private let subscriptionPath = "/api/biz/subscription/list"
    private let quotaPath = "/api/monitor/usage/quota/limit"
    private let consoleEndpoints = [
        URL(string: "https://z.ai/api/billing/usage")!,
        URL(string: "https://z.ai/api/account/billing/usage")!
    ]

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        guard let credential else {
            throw ProviderError.missingCredential
        }

        if credential.kind == .apiKey {
            return try await fetchWithAPIKey(credential.value)
        }

        return try await fetchWithCookie(credential.value)
    }

    private func fetchWithAPIKey(_ apiKey: String) async throws -> ProviderBalanceSnapshot {
        var endpointDiagnostics: [ProviderEndpointDiagnostic] = []

        let subscriptionResult = await fetchSubscription(apiKey: apiKey)
        endpointDiagnostics.append(subscriptionResult.diagnostic)

        if let error = subscriptionResult.failure, error.isAuthorizationFailure {
            throw ProviderError.unauthorized
        }

        let quotaResult = await fetchQuotaLimits(apiKey: apiKey)
        endpointDiagnostics.append(quotaResult.diagnostic)

        if let error = quotaResult.failure, error.isAuthorizationFailure {
            throw ProviderError.unauthorized
        }

        let subscription = subscriptionResult.value
        let quotaResponse = quotaResult.value
        let diagnosticReport = Self.makeDiagnosticReport(
            host: host,
            diagnostics: endpointDiagnostics,
            windows: quotaResponse?.windows ?? []
        )

        switch (subscription, quotaResponse) {
        case let (.some(subscription), .some(quota)):
            return Self.makeSnapshot(
                subscription: subscription,
                quota: quota,
                diagnostics: endpointDiagnostics,
                host: host,
                diagnosticReport: diagnosticReport
            )
        case let (.some(subscription), .none):
            let message = quotaResult.failure?.userFacingMessage ?? "Quota endpoint unavailable."
            return Self.makeDegradedSnapshot(
                planName: subscription.planName,
                subscriptionStatusText: subscription.statusText,
                diagnostics: endpointDiagnostics,
                host: host,
                diagnosticReport: diagnosticReport,
                detailText: "Subscription OK, quota failed: \(message)"
            )
        case let (.none, .some(quota)):
            return Self.makeQuotaOnlySnapshot(
                quota: quota,
                diagnostics: endpointDiagnostics,
                host: host,
                diagnosticReport: diagnosticReport,
                detailText: "Quota OK, subscription lookup failed."
            )
        case (.none, .none):
            let quotaError = quotaResult.failure
            let subscriptionError = subscriptionResult.failure
            throw ZAIProviderError(
                message: quotaError?.userFacingMessage
                    ?? subscriptionError?.userFacingMessage
                    ?? "Z.ai connection failed.",
                diagnosticReport: diagnosticReport
            )
        }
    }

    private func fetchWithCookie(_ cookie: String) async throws -> ProviderBalanceSnapshot {
        let json = try await firstSuccessfulPayload(
            endpoints: consoleEndpoints,
            headers: [
                "Cookie": cookie,
                "Accept": "application/json"
            ]
        )
        var snapshot = try Self.makeSnapshot(from: json, sourceHint: "Console")
        snapshot.status = .degraded
        snapshot.detailText += " Console parsing may break if the web schema changes."
        return snapshot
    }

    static func makeSnapshot(from json: Any, sourceHint: String) throws -> ProviderBalanceSnapshot {
        let fetchedAt = Date()
        let reader = ProviderPayloadReader(root: json)
        let usage = reader.number(forKeyPaths: [
            ["data", "usage"],
            ["data", "used"],
            ["usage"],
            ["used"]
        ])
        let quota = reader.number(forKeyPaths: [
            ["data", "quota"],
            ["data", "limit"],
            ["quota"],
            ["limit"]
        ])
        let remaining = numericString(computeRemaining(quota: quota, usage: usage), fallback: reader.string(forKeyPaths: [
            ["data", "remaining"],
            ["remaining"]
        ]))
        let unit = reader.string(forKeyPaths: [
            ["data", "unit"],
            ["data", "usageUnit"],
            ["unit"],
            ["usageUnit"]
        ])
        let resetAt = reader.date(forKeyPaths: [
            ["data", "resetAt"],
            ["data", "nextResetAt"],
            ["resetAt"],
            ["nextResetAt"]
        ])

        guard remaining != nil || usage != nil || resetAt != nil else {
            throw ProviderError.invalidResponse
        }

        return ProviderBalanceSnapshot(
            provider: .zaiGlobal,
            status: .ok,
            remainingValue: remaining,
            remainingUnit: unit,
            usedValue: numericString(usage, fallback: nil),
            resetAt: resetAt,
            fetchedAt: fetchedAt,
            summaryText: remaining.map { "Remaining \($0)\(unit.map { " \($0)" } ?? "")" } ?? "Connected",
            detailText: "\(sourceHint) quota loaded successfully.",
            providerMetadata: nil
        )
    }

    private func firstSuccessfulPayload(endpoints: [URL], headers: [String: String]) async throws -> Any {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                return try await client.jsonRequest(url: endpoint, headers: headers)
            } catch ProviderError.unauthorized {
                throw ProviderError.unauthorized
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProviderError.invalidResponse
    }

    private static func computeRemaining(quota: Double?, usage: Double?) -> Double? {
        guard let quota, let usage else {
            return nil
        }
        return max(quota - usage, 0)
    }

    private static func numericString(_ value: Double?, fallback: String?) -> String? {
        if let value {
            return ProviderNumberFormatter.string(from: value)
        }
        return fallback
    }

    private func fetchSubscription(apiKey: String) async -> ZAIEndpointResult<ZAISubscriptionInfo> {
        await fetchEndpoint(
            path: subscriptionPath,
            apiKey: apiKey,
            endpointName: "Subscription"
        ) { json in
            try Self.parseSubscription(from: json)
        }
    }

    private func fetchQuotaLimits(apiKey: String) async -> ZAIEndpointResult<ZAIQuotaResponse> {
        await fetchEndpoint(
            path: quotaPath,
            apiKey: apiKey,
            endpointName: "Quota"
        ) { json in
            try Self.parseQuotaResponse(from: json)
        }
    }

    private func fetchEndpoint<Value>(
        path: String,
        apiKey: String,
        endpointName: String,
        parser: (Any) throws -> Value
    ) async -> ZAIEndpointResult<Value> {
        let url = URL(string: host + path)!
        do {
            let json = try await client.jsonRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(apiKey)",
                    "Accept": "application/json"
                ]
            )
            do {
                let value = try parser(json)
                return ZAIEndpointResult(
                    value: value,
                    failure: nil,
                    diagnostic: ProviderEndpointDiagnostic(
                        name: endpointName,
                        path: path,
                        statusText: "OK",
                        detail: "Parsed successfully."
                    )
                )
            } catch {
                let failure = ZAIFetchFailure.schemaChanged(endpointName: endpointName)
                return ZAIEndpointResult(
                    value: nil,
                    failure: failure,
                    diagnostic: ProviderEndpointDiagnostic(
                        name: endpointName,
                        path: path,
                        statusText: failure.statusText,
                        detail: error.localizedDescription
                    )
                )
            }
        } catch ProviderError.unauthorized {
            let failure = ZAIFetchFailure.authFailed(endpointName: endpointName)
            return ZAIEndpointResult(
                value: nil,
                failure: failure,
                diagnostic: ProviderEndpointDiagnostic(
                    name: endpointName,
                    path: path,
                    statusText: failure.statusText,
                    detail: failure.userFacingMessage
                )
            )
        } catch ProviderError.serverError(let code) {
            let failure: ZAIFetchFailure = code == 404
                ? .endpointUnavailable(endpointName: endpointName, path: path, statusCode: code)
                : .httpFailure(endpointName: endpointName, path: path, statusCode: code)
            return ZAIEndpointResult(
                value: nil,
                failure: failure,
                diagnostic: ProviderEndpointDiagnostic(
                    name: endpointName,
                    path: path,
                    statusText: failure.statusText,
                    detail: failure.userFacingMessage
                )
            )
        } catch ProviderError.rateLimited {
            let failure = ZAIFetchFailure.rateLimited(endpointName: endpointName)
            return ZAIEndpointResult(
                value: nil,
                failure: failure,
                diagnostic: ProviderEndpointDiagnostic(
                    name: endpointName,
                    path: path,
                    statusText: failure.statusText,
                    detail: failure.userFacingMessage
                )
            )
        } catch let error as ProviderError {
            let failure = ZAIFetchFailure.other(endpointName: endpointName, description: error.localizedDescription)
            return ZAIEndpointResult(
                value: nil,
                failure: failure,
                diagnostic: ProviderEndpointDiagnostic(
                    name: endpointName,
                    path: path,
                    statusText: failure.statusText,
                    detail: failure.userFacingMessage
                )
            )
        } catch {
            let failure = ZAIFetchFailure.other(endpointName: endpointName, description: error.localizedDescription)
            return ZAIEndpointResult(
                value: nil,
                failure: failure,
                diagnostic: ProviderEndpointDiagnostic(
                    name: endpointName,
                    path: path,
                    statusText: failure.statusText,
                    detail: failure.userFacingMessage
                )
            )
        }
    }

    static func parseSubscription(from json: Any) throws -> ZAISubscriptionInfo {
        let reader = ProviderPayloadReader(root: json)
        let rawItems = reader.array(forKeyPaths: [["data"]]) ?? reader.array(forKeyPaths: [["items"]]) ?? []
        let items = rawItems.compactMap { $0 as? [String: Any] }
        let selected = items.first ?? reader.dictionary(forKeyPaths: [["data"], ["subscription"]])
        guard let selected else {
            throw ProviderError.invalidResponse
        }

        let itemReader = ProviderPayloadReader(root: selected)
        let planName = itemReader.string(forKeyPaths: [
            ["planName"], ["subscriptionName"], ["name"], ["productName"], ["title"]
        ]) ?? "Z.ai Plan"
        let statusText = itemReader.string(forKeyPaths: [
            ["status"], ["state"], ["subscriptionStatus"], ["displayStatus"]
        ]) ?? "active"

        return ZAISubscriptionInfo(planName: planName, statusText: statusText)
    }

    static func parseQuotaResponse(from json: Any) throws -> ZAIQuotaResponse {
        let reader = ProviderPayloadReader(root: json)
        let rawLimits = reader.array(forKeyPaths: [["data", "limits"], ["limits"]]) ?? []
        let limits = rawLimits.compactMap { $0 as? [String: Any] }
        guard limits.isEmpty == false else {
            throw ProviderError.invalidResponse
        }

        let windows = try limits.map { limit in
            try parseQuotaWindow(from: limit)
        }
        return ZAIQuotaResponse(windows: windows)
    }

    static func parseQuotaWindow(from json: [String: Any]) throws -> ZAIQuotaWindow {
        let reader = ProviderPayloadReader(root: json)
        let rawType = reader.string(forKeyPaths: [["type"]]) ?? "UNKNOWN"
        let rawUnit = Int(reader.number(forKeyPaths: [["unit"]]) ?? -1)
        let rawNumber = Int(reader.number(forKeyPaths: [["number"]]) ?? -1)
        let limit = reader.number(forKeyPaths: [["limit"]]) ?? 0
        let used = reader.number(forKeyPaths: [["used"]]) ?? 0
        let remaining = max(reader.number(forKeyPaths: [["remaining"]]) ?? (limit - used), 0)
        let percentage = reader.number(forKeyPaths: [["percentage"]]) ?? {
            guard limit > 0 else { return 0 }
            return min(max((used / limit) * 100, 0), 100)
        }()
        let resetAt = reader.date(forKeyPaths: [["nextResetTime"], ["resetAt"], ["next_reset_time"]])

        return ZAIQuotaWindow(
            bucket: classifyBucket(type: rawType, unit: rawUnit, number: rawNumber),
            limit: limit,
            used: used,
            remaining: remaining,
            percentage: percentage,
            resetAt: resetAt,
            rawType: rawType,
            rawUnit: rawUnit,
            rawNumber: rawNumber
        )
    }

    static func classifyBucket(type: String, unit: Int, number: Int) -> ZAIQuotaBucket {
        switch (type, unit, number) {
        case ("TOKENS_LIMIT", 3, 5):
            return .fiveHour
        case ("TOKENS_LIMIT", 6, 1), ("TOKENS_LIMIT", 6, 7):
            return .weekly
        case ("TIME_LIMIT", 5, 1):
            return .mcpMonthly
        default:
            return .unmatched
        }
    }

    private static func makeSnapshot(
        subscription: ZAISubscriptionInfo,
        quota: ZAIQuotaResponse,
        diagnostics: [ProviderEndpointDiagnostic],
        host: String,
        diagnosticReport: String
    ) -> ProviderBalanceSnapshot {
        let primary = quota.windows.first { $0.bucket != .unmatched } ?? quota.windows.first
        let metadata = ZAIProviderMetadata(
            host: host,
            planName: subscription.planName,
            subscriptionStatusText: subscription.statusText,
            windows: quota.windows,
            diagnostics: diagnostics,
            unmatchedWindowCount: quota.windows.filter { $0.bucket == .unmatched }.count,
            diagnosticReport: diagnosticReport
        )
        return ProviderBalanceSnapshot(
            provider: .zaiGlobal,
            status: metadata.windows.allSatisfy { $0.bucket == .unmatched } ? .degraded : .ok,
            remainingValue: primary.map { ProviderNumberFormatter.string(from: $0.remaining) },
            remainingUnit: primary.map { $0.bucket.displayName },
            usedValue: primary.map { ProviderNumberFormatter.string(from: $0.used) },
            resetAt: primary?.resetAt,
            fetchedAt: Date(),
            summaryText: "5-hour, weekly, and monthly quota windows",
            detailText: "Loaded from Z.ai subscription and quota endpoints.",
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: metadata)
        )
    }

    private static func makeDegradedSnapshot(
        planName: String?,
        subscriptionStatusText: String?,
        diagnostics: [ProviderEndpointDiagnostic],
        host: String,
        diagnosticReport: String,
        detailText: String
    ) -> ProviderBalanceSnapshot {
        let metadata = ZAIProviderMetadata(
            host: host,
            planName: planName,
            subscriptionStatusText: subscriptionStatusText,
            windows: [],
            diagnostics: diagnostics,
            unmatchedWindowCount: 0,
            diagnosticReport: diagnosticReport
        )
        return ProviderBalanceSnapshot(
            provider: .zaiGlobal,
            status: .degraded,
            remainingValue: nil,
            remainingUnit: nil,
            usedValue: nil,
            resetAt: nil,
            fetchedAt: Date(),
            summaryText: planName ?? "Z.ai connected",
            detailText: detailText,
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: metadata)
        )
    }

    private static func makeQuotaOnlySnapshot(
        quota: ZAIQuotaResponse,
        diagnostics: [ProviderEndpointDiagnostic],
        host: String,
        diagnosticReport: String,
        detailText: String
    ) -> ProviderBalanceSnapshot {
        let primary = quota.windows.first { $0.bucket != .unmatched } ?? quota.windows.first
        let metadata = ZAIProviderMetadata(
            host: host,
            planName: nil,
            subscriptionStatusText: nil,
            windows: quota.windows,
            diagnostics: diagnostics,
            unmatchedWindowCount: quota.windows.filter { $0.bucket == .unmatched }.count,
            diagnosticReport: diagnosticReport
        )
        return ProviderBalanceSnapshot(
            provider: .zaiGlobal,
            status: .degraded,
            remainingValue: primary.map { ProviderNumberFormatter.string(from: $0.remaining) },
            remainingUnit: primary.map { $0.bucket.displayName },
            usedValue: primary.map { ProviderNumberFormatter.string(from: $0.used) },
            resetAt: primary?.resetAt,
            fetchedAt: Date(),
            summaryText: "Quota windows available",
            detailText: detailText,
            providerMetadata: ProviderSnapshotMetadata(bailian: nil, zai: metadata)
        )
    }

    private static func makeDiagnosticReport(
        host: String,
        diagnostics: [ProviderEndpointDiagnostic],
        windows: [ZAIQuotaWindow]
    ) -> String {
        let windowSummary = windows.isEmpty
            ? "parsedBuckets: none"
            : "parsedBuckets: " + windows.map {
                "\($0.bucket.rawValue)(\($0.rawType)|unit=\($0.rawUnit)|number=\($0.rawNumber))"
            }.joined(separator: ", ")
        let endpointSummary = diagnostics.map {
            "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)"
        }.joined(separator: "\n")
        return [
            "host: \(host)",
            endpointSummary,
            windowSummary
        ]
        .filter { $0.isEmpty == false }
        .joined(separator: "\n")
    }
}

private struct ZAIEndpointResult<Value> {
    var value: Value?
    var failure: ZAIFetchFailure?
    var diagnostic: ProviderEndpointDiagnostic
}

struct ZAISubscriptionInfo {
    var planName: String
    var statusText: String
}

struct ZAIQuotaResponse {
    var windows: [ZAIQuotaWindow]
}

private enum ZAIFetchFailure {
    case authFailed(endpointName: String)
    case endpointUnavailable(endpointName: String, path: String, statusCode: Int)
    case httpFailure(endpointName: String, path: String, statusCode: Int)
    case rateLimited(endpointName: String)
    case schemaChanged(endpointName: String)
    case other(endpointName: String, description: String)

    var statusText: String {
        switch self {
        case .authFailed:
            return "Auth Failed"
        case .endpointUnavailable:
            return "Endpoint Unavailable"
        case .httpFailure(_, _, let statusCode):
            return "HTTP \(statusCode)"
        case .rateLimited:
            return "Rate Limited"
        case .schemaChanged:
            return "Schema Changed"
        case .other:
            return "Failed"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .authFailed(let endpointName):
            return "\(endpointName) request failed authentication."
        case .endpointUnavailable(let endpointName, let path, let statusCode):
            return "\(endpointName) endpoint unavailable (\(path), HTTP \(statusCode))."
        case .httpFailure(let endpointName, let path, let statusCode):
            return "\(endpointName) request failed (\(path), HTTP \(statusCode))."
        case .rateLimited(let endpointName):
            return "\(endpointName) request was rate limited."
        case .schemaChanged(let endpointName):
            return "\(endpointName) response schema changed."
        case .other(let endpointName, let description):
            return "\(endpointName) request failed: \(description)"
        }
    }

    var isAuthorizationFailure: Bool {
        if case .authFailed = self {
            return true
        }
        return false
    }
}

struct ZAIProviderError: LocalizedError {
    var message: String
    var diagnosticReport: String

    var errorDescription: String? { message }
}
