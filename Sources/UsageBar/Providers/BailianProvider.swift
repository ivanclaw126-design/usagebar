import Foundation
import WebKit

struct BailianProvider: ProviderAdapter {
    let provider: ProviderKind = .bailian
    private let client = ProviderHTTPClient()
    private let apiHost = "https://coding.dashscope.aliyuncs.com"
    private let apiProbePath = "/v1/chat/completions"
    private let consoleHost = "https://bailian.console.aliyun.com"
    private let consoleJSONPaths = [
        "/api/model-studio/coding-plan/usage",
        "/api/coding-plan/usage",
        "/api/model-studio/billing/credit",
        "/api/billing/credit"
    ]
    private let consolePagePaths = [
        "/cn-beijing/?tab=coding-plan",
        "/cn-beijing/?tab=coding-plan#/efm/coding-plan-detail",
        "/",
        "/cn-beijing/"
    ]
    private let renderedPageURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=coding-plan#/efm/coding-plan-detail")!

    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot {
        guard let credential else {
            throw ProviderError.missingCredential
        }

        if credential.kind == .apiKey {
            return try await fetchWithAPIKey(credential.value)
        }

        if credential.kind == .sessionToken {
            return try await fetchWithSessionState(credential.value)
        }

        return try await fetchCodingPlanUsageWithSession(cookie: credential.value)
    }

    private func fetchWithAPIKey(_ apiKey: String) async throws -> ProviderBalanceSnapshot {
        let url = URL(string: apiHost + apiProbePath)!
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "qwen3-coder-plus",
            "max_tokens": 1,
            "messages": [
                [
                    "role": "user",
                    "content": "ping"
                ]
            ]
        ])

        do {
            _ = try await client.dataRequest(
                url: url,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(apiKey)",
                    "Content-Type": "application/json",
                    "Accept": "application/json"
                ],
                body: body
            )
            return Self.makeAPIKeyProbeSnapshot(host: apiHost, path: apiProbePath)
        } catch ProviderError.unauthorized {
            throw ProviderError.unauthorized
        } catch ProviderError.rateLimited {
            return Self.makeAPIKeyProbeSnapshot(
                host: apiHost,
                path: apiProbePath,
                detailText: "API key probe was rate limited. The key appears valid, but quota visibility still requires Web Session."
            )
        } catch let error as ProviderError {
            throw BailianProviderError(
                message: "Bailian API key probe failed: \(error.localizedDescription)",
                diagnosticReport: [
                    "host: \(apiHost)",
                    "API Probe: Failed [\(apiProbePath)] - \(error.localizedDescription)"
                ].joined(separator: "\n")
            )
        }
    }

    private func fetchWithSessionState(_ sessionState: String) async throws -> ProviderBalanceSnapshot {
        guard let data = sessionState.data(using: .utf8),
              let state = try? JSONDecoder().decode(BailianSessionState.self, from: data) else {
            throw ProviderError.invalidResponse
        }

        var diagnostics: [ProviderEndpointDiagnostic] = [
            ProviderEndpointDiagnostic(
                name: "Saved Session",
                path: renderedPageURL.absoluteString,
                statusText: "OK",
                detail: "Loaded saved Bailian page state from the active login session."
            )
        ]

        if let payload = try? Self.parseUsageResponse(fromRenderedText: state.renderedText) {
            return Self.makeSessionSnapshot(
                from: payload,
                diagnostics: diagnostics,
                host: consoleHost
            )
        }

        if let payload = try? Self.parseUsageResponse(fromHTML: state.html) {
            return Self.makeSessionSnapshot(
                from: payload,
                diagnostics: diagnostics,
                host: consoleHost
            )
        }

        let liveResult = await fetchCodingPlanUsageResultWithSession(cookie: state.cookies)
        diagnostics.append(contentsOf: liveResult.diagnostics)
        if liveResult.failure?.isAuthorizationFailure == true {
            if let payload = try? Self.parseUsageResponse(fromHTML: state.html) {
                return Self.makeSessionSnapshot(
                    from: payload,
                    diagnostics: diagnostics,
                    host: consoleHost
                )
            }
            throw ProviderError.unauthorized
        }
        if let payload = liveResult.value {
            return Self.makeSessionSnapshot(
                from: payload,
                diagnostics: diagnostics,
                host: consoleHost
            )
        }

        throw BailianProviderError(
            message: liveResult.failure?.userFacingMessage ?? "Bailian session state could not be parsed.",
            diagnosticReport: Self.makeDiagnosticReport(
                host: consoleHost,
                diagnostics: diagnostics,
                windows: []
            )
        )
    }

    private func fetchCodingPlanUsageWithSession(cookie: String) async throws -> ProviderBalanceSnapshot {
        let result = await fetchCodingPlanUsageResultWithSession(cookie: cookie)
        if result.failure?.isAuthorizationFailure == true {
            throw ProviderError.unauthorized
        }
        if let payload = result.value {
            return Self.makeSessionSnapshot(
                from: payload,
                diagnostics: result.diagnostics,
                host: consoleHost
            )
        }

        let message = result.failure?.userFacingMessage
            ?? "Bailian usage page unavailable."
        throw BailianProviderError(
            message: message,
            diagnosticReport: Self.makeDiagnosticReport(
                host: consoleHost,
                diagnostics: result.diagnostics,
                windows: []
            )
        )
    }

    private func fetchCodingPlanUsageResultWithSession(cookie: String) async -> BailianUsageLookupResult {
        var diagnostics: [ProviderEndpointDiagnostic] = []

        let jsonResult = await fetchConsoleJSON(cookie: cookie)
        diagnostics.append(contentsOf: jsonResult.diagnostics)
        if let payload = jsonResult.value {
            return BailianUsageLookupResult(value: payload, diagnostics: diagnostics, failure: nil)
        }
        if jsonResult.failures.contains(where: \.isAuthorizationFailure) {
            return BailianUsageLookupResult(
                value: nil,
                diagnostics: diagnostics,
                failure: jsonResult.failures.first(where: \.isAuthorizationFailure)
            )
        }

        let pageResult = await fetchConsolePage(cookie: cookie)
        diagnostics.append(contentsOf: pageResult.diagnostics)
        if let payload = pageResult.value {
            return BailianUsageLookupResult(value: payload, diagnostics: diagnostics, failure: nil)
        }
        if pageResult.failure?.isAuthorizationFailure == true {
            return BailianUsageLookupResult(value: nil, diagnostics: diagnostics, failure: pageResult.failure)
        }

        let renderedPageResult = await fetchRenderedUsagePage(cookie: cookie)
        diagnostics.append(contentsOf: renderedPageResult.diagnostics)
        if let payload = renderedPageResult.value {
            return BailianUsageLookupResult(value: payload, diagnostics: diagnostics, failure: nil)
        }

        return BailianUsageLookupResult(
            value: nil,
            diagnostics: diagnostics,
            failure: renderedPageResult.failure ?? pageResult.failure ?? jsonResult.failures.last
        )
    }

    private func fetchRenderedUsagePage(cookie: String) async -> BailianPageFetchResult {
        let loader = await MainActor.run {
            BailianRenderedPageLoader(url: renderedPageURL)
        }
        return await loader.load(cookie: cookie)
    }

    private func fetchConsoleJSON(cookie: String) async -> BailianJSONFetchResult {
        var diagnostics: [ProviderEndpointDiagnostic] = []
        var failures: [BailianFetchFailure] = []

        for path in consoleJSONPaths {
            let url = URL(string: consoleHost + path)!
            do {
                let (data, _) = try await client.dataRequest(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "Accept": "application/json, text/plain, */*"
                    ]
                )
                do {
                    let payload = try Self.parseUsageResponse(fromData: data)
                    diagnostics.append(
                        ProviderEndpointDiagnostic(
                            name: "Console API",
                            path: path,
                            statusText: "OK",
                            detail: payload.windows.isEmpty ? "Parsed balance fields." : "Parsed usage windows."
                        )
                    )
                    return BailianJSONFetchResult(
                        value: payload,
                        diagnostics: diagnostics,
                        failures: failures
                    )
                } catch {
                    let failure = BailianFetchFailure.schemaChanged(endpointName: "Console API")
                    diagnostics.append(
                        ProviderEndpointDiagnostic(
                            name: "Console API",
                            path: path,
                            statusText: failure.statusText,
                            detail: error.localizedDescription
                        )
                    )
                    failures.append(failure)
                }
            } catch ProviderError.unauthorized {
                let failure = BailianFetchFailure.authFailed(endpointName: "Console API")
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Console API",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                failures.append(failure)
                break
            } catch ProviderError.serverError(let code) {
                let failure: BailianFetchFailure = code == 404
                    ? .usageUnavailable(endpointName: "Console API", path: path, statusCode: code)
                    : .httpFailure(endpointName: "Console API", path: path, statusCode: code)
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Console API",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                failures.append(failure)
            } catch ProviderError.rateLimited {
                let failure = BailianFetchFailure.rateLimited(endpointName: "Console API")
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Console API",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                failures.append(failure)
            } catch let error as ProviderError {
                let failure = BailianFetchFailure.other(endpointName: "Console API", description: error.localizedDescription)
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Console API",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                failures.append(failure)
            } catch {
                let failure = BailianFetchFailure.other(endpointName: "Console API", description: error.localizedDescription)
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Console API",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                failures.append(failure)
            }
        }

        return BailianJSONFetchResult(value: nil, diagnostics: diagnostics, failures: failures)
    }

    private func fetchConsolePage(cookie: String) async -> BailianPageFetchResult {
        var diagnostics: [ProviderEndpointDiagnostic] = []
        var lastFailure: BailianFetchFailure?

        for path in consolePagePaths {
            let url = URL(string: consoleHost + path)!
            do {
                let html = try await client.textRequest(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "Accept": "text/html,application/xhtml+xml,application/json"
                    ]
                )
                let payload = try Self.parseUsageResponse(fromHTML: html)
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Usage Page",
                        path: path,
                        statusText: "OK",
                        detail: payload.windows.isEmpty ? "Parsed embedded balance data." : "Parsed embedded usage windows."
                    )
                )
                return BailianPageFetchResult(value: payload, diagnostics: diagnostics, failure: nil)
            } catch ProviderError.unauthorized {
                let failure = BailianFetchFailure.authFailed(endpointName: "Usage Page")
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Usage Page",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                return BailianPageFetchResult(value: nil, diagnostics: diagnostics, failure: failure)
            } catch ProviderError.serverError(let code) {
                let failure: BailianFetchFailure = code == 404
                    ? .usageUnavailable(endpointName: "Usage Page", path: path, statusCode: code)
                    : .httpFailure(endpointName: "Usage Page", path: path, statusCode: code)
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Usage Page",
                        path: path,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                )
                lastFailure = failure
            } catch {
                let failure = BailianFetchFailure.schemaChanged(endpointName: "Usage Page")
                diagnostics.append(
                    ProviderEndpointDiagnostic(
                        name: "Usage Page",
                        path: path,
                        statusText: failure.statusText,
                        detail: error.localizedDescription
                    )
                )
                lastFailure = failure
            }
        }

        return BailianPageFetchResult(value: nil, diagnostics: diagnostics, failure: lastFailure)
    }

    static func makeSnapshot(from json: Any, sourceHint: String) throws -> ProviderBalanceSnapshot {
        let payload = try parseUsageResponse(from: json)
        return makeSnapshot(
            from: payload,
            status: .ok,
            summaryText: payload.windows.isEmpty ? "Remaining balance view" : "5-hour, weekly, and monthly usage windows",
            detailText: "\(sourceHint) balance loaded successfully.",
            providerMetadata: nil
        )
    }

    static func parseUsageResponse(from json: Any) throws -> BailianUsageResponse {
        let reader = ProviderPayloadReader(root: json)
        let planName = reader.string(forKeyPaths: [
            ["data", "planName"],
            ["data", "packageName"],
            ["data", "subscriptionName"],
            ["props", "pageProps", "data", "planName"],
            ["props", "pageProps", "data", "packageName"],
            ["planName"],
            ["packageName"],
            ["subscriptionName"]
        ]) ?? deepString(in: json, keys: ["planName", "packageName", "subscriptionName", "productName", "title"])
        let statusText = reader.string(forKeyPaths: [
            ["data", "status"],
            ["data", "state"],
            ["props", "pageProps", "data", "status"],
            ["status"],
            ["state"]
        ]) ?? deepString(in: json, keys: ["status", "state", "subscriptionStatus"])

        let windows = parseWindows(from: reader)
        let remaining = numericString(
            reader.number(forKeyPaths: [
                ["data", "remaining"],
                ["data", "remainingQuota"],
                ["data", "available"],
                ["props", "pageProps", "data", "remaining"],
                ["props", "pageProps", "data", "remainingQuota"],
                ["remaining"],
                ["remainingQuota"],
                ["available"]
            ]) ?? deepNumber(in: json, keys: ["remaining", "remainingQuota", "available", "balance"]),
            fallback: reader.string(forKeyPaths: [
                ["data", "remainingText"],
                ["remainingText"]
            ]) ?? deepString(in: json, keys: ["remainingText"])
        )
        let used = numericString(
            reader.number(forKeyPaths: [
                ["data", "used"],
                ["data", "consumed"],
                ["props", "pageProps", "data", "used"],
                ["used"],
                ["consumed"]
            ]) ?? deepNumber(in: json, keys: ["used", "consumed", "usage", "spent"]),
            fallback: nil
        )
        let unit = reader.string(forKeyPaths: [
            ["data", "unit"],
            ["data", "currencyUnit"],
            ["props", "pageProps", "data", "unit"],
            ["unit"],
            ["currencyUnit"]
        ]) ?? deepString(in: json, keys: ["unit", "currencyUnit", "usageUnit"])
        let resetAt = reader.date(forKeyPaths: [
            ["data", "resetAt"],
            ["data", "expireAt"],
            ["props", "pageProps", "data", "resetAt"],
            ["resetAt"],
            ["expireAt"]
        ]) ?? deepDate(in: json, keys: ["resetAt", "expireAt", "nextResetTime", "next_reset_time", "endTime"])

        guard windows.isEmpty == false || remaining != nil || used != nil || resetAt != nil else {
            throw ProviderError.invalidResponse
        }

        return BailianUsageResponse(
            planName: planName,
            statusText: statusText,
            windows: windows,
            remainingValue: remaining,
            usedValue: used,
            remainingUnit: unit,
            resetAt: resetAt
        )
    }

    static func parseUsageResponse(fromHTML html: String) throws -> BailianUsageResponse {
        for candidate in extractEmbeddedJSONCandidates(fromHTML: html) {
            if let payload = try? parseUsageResponse(from: candidate) {
                return payload
            }
        }
        if let payload = try? parseUsageResponse(fromRenderedText: html) {
            return payload
        }
        throw ProviderError.invalidResponse
    }

    static func parseUsageResponse(fromData data: Data) throws -> BailianUsageResponse {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return try parseUsageResponse(from: json)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse
        }
        if let trimmedJSON = extractJSONStringCandidate(from: text),
           let jsonData = trimmedJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) {
            return try parseUsageResponse(from: object)
        }
        return try parseUsageResponse(fromHTML: text)
    }

    static func parseUsageResponse(fromRenderedText text: String) throws -> BailianUsageResponse {
        let normalized = text
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard normalized.contains("用量消耗") || normalized.contains("近5小时用量") || normalized.contains("近 5 小时用量") else {
            throw ProviderError.invalidResponse
        }

        let windows = [
            parseRenderedWindow(in: normalized, label: "近5小时用量", bucket: .fiveHour),
            parseRenderedWindow(in: normalized, label: "近 5 小时用量", bucket: .fiveHour),
            parseRenderedWindow(in: normalized, label: "近一周用量", bucket: .weekly),
            parseRenderedWindow(in: normalized, label: "近一月用量", bucket: .monthly)
        ]
        .compactMap { $0 }
        .uniqueBy(\.id)

        guard windows.isEmpty == false else {
            throw ProviderError.invalidResponse
        }

        return BailianUsageResponse(
            planName: "Coding Plan",
            statusText: "Rendered Page",
            windows: windows,
            remainingValue: nil,
            usedValue: nil,
            remainingUnit: nil,
            resetAt: windows.first?.resetAt
        )
    }

    static func parseUsageWindow(from json: [String: Any]) throws -> BailianUsageWindow {
        let reader = ProviderPayloadReader(root: json)
        let rawLabel = reader.string(forKeyPaths: [
            ["label"],
            ["title"],
            ["name"],
            ["period"],
            ["windowName"],
            ["cycle"],
            ["cycleText"],
            ["ruleName"],
            ["displayName"],
            ["type"]
        ]) ?? "Unknown"
        let rawType = reader.string(forKeyPaths: [["type"], ["windowType"], ["code"]])
        let limit = reader.number(forKeyPaths: [["limit"], ["quota"], ["total"], ["allowance"], ["capacity"]]) ?? 0
        let used = reader.number(forKeyPaths: [["used"], ["consumed"], ["usage"], ["spent"], ["current"]]) ?? 0
        let remaining = max(reader.number(forKeyPaths: [["remaining"], ["available"], ["balance"], ["leftover"]]) ?? (limit - used), 0)
        let percentage = reader.number(forKeyPaths: [["percentage"], ["percent"], ["usageRate"]]) ?? {
            guard limit > 0 else { return 0 }
            return min(max((used / limit) * 100, 0), 100)
        }()
        let resetAt = reader.date(forKeyPaths: [["nextResetTime"], ["resetAt"], ["expireAt"], ["endTime"], ["next_reset_time"]])

        return BailianUsageWindow(
            bucket: classifyBucket(label: rawLabel, type: rawType),
            limit: limit,
            used: used,
            remaining: remaining,
            percentage: percentage,
            resetAt: resetAt,
            rawLabel: rawLabel,
            rawType: rawType
        )
    }

    static func classifyBucket(label: String, type: String?) -> BailianUsageBucket {
        let combined = [label, type].compactMap { $0?.lowercased() }.joined(separator: " ")
        if combined.contains("5h") || combined.contains("5 hour") || combined.contains("5-hour") || combined.contains("5小时") || combined.contains("5 小时") {
            return .fiveHour
        }
        if combined.contains("week") || combined.contains("weekly") || combined.contains("周") {
            return .weekly
        }
        if combined.contains("month") || combined.contains("monthly") || combined.contains("月") {
            return .monthly
        }
        return .unmatched
    }

    static func extractEmbeddedJSONCandidates(fromHTML html: String) -> [Any] {
        let patterns = [
            #"<script[^>]*id="__NEXT_DATA__"[^>]*>\s*(\{[\s\S]*?\})\s*</script>"#,
            #"window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\});"#,
            #"window\.__APP_DATA__\s*=\s*(\{[\s\S]*?\});"#,
            #"window\.__NUXT__\s*=\s*(\{[\s\S]*?\});"#,
            #"window\.__PRELOADED_STATE__\s*=\s*(\{[\s\S]*?\});"#,
            #"window\.__INITIAL_DATA__\s*=\s*(\{[\s\S]*?\});"#
        ]

        let directMatches = patterns.flatMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return []
            }
            let range = NSRange(html.startIndex..., in: html)
            return regex.matches(in: html, options: [], range: range).compactMap { match in
                guard match.numberOfRanges > 1, let payloadRange = Range(match.range(at: 1), in: html) else {
                    return nil
                }
                let payload = String(html[payloadRange])
                guard let data = payload.data(using: .utf8) else {
                    return nil
                }
                return try? JSONSerialization.jsonObject(with: data)
            }
        }

        let scriptCandidates = extractScriptJSONCandidates(fromHTML: html)
        return directMatches + scriptCandidates
    }

    private static func parseWindows(from reader: ProviderPayloadReader) -> [BailianUsageWindow] {
        let keyPaths = [
            ["data", "windows"],
            ["data", "usageWindows"],
            ["data", "limits"],
            ["data", "periodStats"],
            ["props", "pageProps", "data", "windows"],
            ["props", "pageProps", "data", "usageWindows"],
            ["props", "pageProps", "data", "limits"],
            ["windows"],
            ["usageWindows"],
            ["limits"],
            ["periodStats"]
        ]

        let rawItems = reader.array(forKeyPaths: keyPaths) ?? []
        let directMatches: [BailianUsageWindow] = rawItems.compactMap { item in
            guard let dictionary = item as? [String: Any] else {
                return nil
            }
            return try? parseUsageWindow(from: dictionary)
        }
        if directMatches.isEmpty == false {
            return directMatches
        }

        let deepMatches = deepWindowDictionaries(in: reader.root)
        return deepMatches.compactMap { try? parseUsageWindow(from: $0) }
    }

    private static func extractJSONStringCandidate(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[" {
            return trimmed
        }
        return nil
    }

    private static func extractScriptJSONCandidates(fromHTML html: String) -> [Any] {
        guard let scriptRegex = try? NSRegularExpression(pattern: #"<script[^>]*>([\s\S]*?)</script>"#, options: []) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let contents = scriptRegex.matches(in: html, options: [], range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1, let scriptRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[scriptRange])
        }

        var results: [Any] = []
        for content in contents {
            results.append(contentsOf: balancedJSONObjectCandidates(in: content))
        }
        return results
    }

    private static func balancedJSONObjectCandidates(in text: String) -> [Any] {
        let characters = Array(text)
        var results: [Any] = []
        var startIndex: Int?
        var depth = 0
        var inString = false
        var isEscaped = false

        for index in characters.indices {
            let character = characters[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let startIndex {
                    let candidate = String(characters[startIndex ... index])
                    if candidate.count > 20,
                       let data = candidate.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) {
                        results.append(object)
                    }
                }
            }
        }

        return results
    }

    private static func deepString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key), let string = child as? String, string.isEmpty == false {
                    return string
                }
                if let nested = deepString(in: child, keys: keys) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nested = deepString(in: child, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func deepNumber(in value: Any, keys: Set<String>) -> Double? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key) {
                    if let number = child as? NSNumber {
                        return number.doubleValue
                    }
                    if let string = child as? String, let number = Double(string) {
                        return number
                    }
                }
                if let nested = deepNumber(in: child, keys: keys) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nested = deepNumber(in: child, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func deepDate(in value: Any, keys: Set<String>) -> Date? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key), let string = child as? String, let date = parseDateString(string) {
                    return date
                }
                if let nested = deepDate(in: child, keys: keys) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nested = deepDate(in: child, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func deepWindowDictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            var matches: [[String: Any]] = []
            for (key, child) in dictionary {
                if let array = child as? [[String: Any]],
                   isWindowCollectionKey(key) || array.contains(where: looksLikeUsageWindow) {
                    matches.append(contentsOf: array)
                }
                matches.append(contentsOf: deepWindowDictionaries(in: child))
            }
            return matches
        }
        if let array = value as? [Any] {
            return array.flatMap { deepWindowDictionaries(in: $0) }
        }
        return []
    }

    private static func isWindowCollectionKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("window")
            || lowered.contains("limit")
            || lowered.contains("period")
            || lowered.contains("quota")
            || lowered.contains("usage")
    }

    private static func looksLikeUsageWindow(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        let hasAmount = keys.contains("limit")
            || keys.contains("quota")
            || keys.contains("total")
            || keys.contains("remaining")
        let hasUsage = keys.contains("used")
            || keys.contains("consumed")
            || keys.contains("usage")
        let hasLabel = keys.contains("label")
            || keys.contains("title")
            || keys.contains("name")
            || keys.contains("period")
            || keys.contains("windowname")
        return (hasAmount && hasUsage) || (hasAmount && hasLabel)
    }

    private static func parseDateString(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }

    private static func parseRenderedWindow(
        in text: String,
        label: String,
        bucket: BailianUsageBucket
    ) -> BailianUsageWindow? {
        guard let range = text.range(of: label) else {
            return nil
        }
        let tail = String(text[range.lowerBound...])
        let nextLabels = ["近5小时用量", "近 5 小时用量", "近一周用量", "近一月用量"]
            .filter { $0 != label }
        let endIndex = nextLabels.compactMap { next in
            tail.range(of: next)?.lowerBound
        }.min() ?? tail.endIndex
        let segment = String(tail[..<endIndex])

        let percentages = captureMatches(in: segment, pattern: #"(\d+(?:\.\d+)?)%"#)
            .compactMap(Double.init)
        guard let usedPercent = percentages.first else {
            return nil
        }

        let resetStrings = captureMatches(in: segment, pattern: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#)
        let resetAt = resetStrings.compactMap(parseDateString).first
        let limit = 100.0
        let used = usedPercent
        let remaining = max(limit - used, 0)

        return BailianUsageWindow(
            bucket: bucket,
            limit: limit,
            used: used,
            remaining: remaining,
            percentage: usedPercent,
            resetAt: resetAt,
            rawLabel: label,
            rawType: "rendered-text"
        )
    }

    private static func captureMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[valueRange])
        }
    }

    private static func makeSessionSnapshot(
        from payload: BailianUsageResponse,
        diagnostics: [ProviderEndpointDiagnostic],
        host: String
    ) -> ProviderBalanceSnapshot {
        let metadata = BailianProviderMetadata(
            host: host,
            planName: payload.planName,
            statusText: payload.statusText,
            windows: payload.windows,
            diagnostics: diagnostics,
            unmatchedWindowCount: payload.windows.filter { $0.bucket == .unmatched }.count,
            diagnosticReport: makeDiagnosticReport(host: host, diagnostics: diagnostics, windows: payload.windows)
        )

        let status: ProviderStatus
        if payload.windows.isEmpty {
            status = .degraded
        } else if metadata.windows.allSatisfy({ $0.bucket == .unmatched }) {
            status = .degraded
        } else {
            status = .ok
        }

        return makeSnapshot(
            from: payload,
            status: status,
            summaryText: payload.windows.isEmpty ? "Coding Plan balance view" : "5-hour, weekly, and monthly usage windows",
            detailText: payload.windows.isEmpty
                ? "Loaded from Bailian console data. Console schema may change."
                : "Loaded from Bailian Coding Plan console.",
            providerMetadata: ProviderSnapshotMetadata(bailian: metadata, zai: nil)
        )
    }

    private static func makeSnapshot(
        from payload: BailianUsageResponse,
        status: ProviderStatus,
        summaryText: String,
        detailText: String,
        providerMetadata: ProviderSnapshotMetadata?
    ) -> ProviderBalanceSnapshot {
        let primary = payload.windows.first { $0.bucket != .unmatched } ?? payload.windows.first
        return ProviderBalanceSnapshot(
            provider: .bailian,
            status: status,
            remainingValue: primary.map { ProviderNumberFormatter.string(from: $0.remaining) } ?? payload.remainingValue,
            remainingUnit: primary.map { $0.bucket.displayName } ?? payload.remainingUnit,
            usedValue: primary.map { ProviderNumberFormatter.string(from: $0.used) } ?? payload.usedValue,
            resetAt: primary?.resetAt ?? payload.resetAt,
            fetchedAt: Date(),
            summaryText: summaryText,
            detailText: detailText,
            providerMetadata: providerMetadata
        )
    }

    private static func makeAPIKeyProbeSnapshot(
        host: String,
        path: String,
        detailText: String = "API key verified. Real Coding Plan usage still requires Web Session."
    ) -> ProviderBalanceSnapshot {
        let report = [
            "host: \(host)",
            "API Probe: OK [\(path)] - API key accepted.",
            "parsedBuckets: none"
        ].joined(separator: "\n")

        return ProviderBalanceSnapshot(
            provider: .bailian,
            status: .supportedLimited,
            remainingValue: nil,
            remainingUnit: nil,
            usedValue: nil,
            resetAt: nil,
            fetchedAt: Date(),
            summaryText: "API key active",
            detailText: detailText,
            providerMetadata: ProviderSnapshotMetadata(
                bailian: BailianProviderMetadata(
                    host: host,
                    planName: nil,
                    statusText: "API Key OK",
                    windows: [],
                    diagnostics: [
                        ProviderEndpointDiagnostic(
                            name: "API Probe",
                            path: path,
                            statusText: "OK",
                            detail: "API key accepted."
                        )
                    ],
                    unmatchedWindowCount: 0,
                    diagnosticReport: report
                ),
                zai: nil
            )
        )
    }

    private static func numericString(_ value: Double?, fallback: String?) -> String? {
        if let value {
            return ProviderNumberFormatter.string(from: value)
        }
        return fallback
    }

    private static func makeDiagnosticReport(
        host: String,
        diagnostics: [ProviderEndpointDiagnostic],
        windows: [BailianUsageWindow]
    ) -> String {
        let endpointSummary = diagnostics.map {
            "\($0.name): \($0.statusText) [\($0.path)] - \($0.detail)"
        }.joined(separator: "\n")
        let windowSummary = windows.isEmpty
            ? "parsedBuckets: none"
            : "parsedBuckets: " + windows.map {
                "\($0.bucket.rawValue)(\($0.rawLabel)\($0.rawType.map { "|\($0)" } ?? ""))"
            }.joined(separator: ", ")

        return [
            "host: \(host)",
            endpointSummary,
            windowSummary
        ]
        .filter { $0.isEmpty == false }
        .joined(separator: "\n")
    }
}

private struct BailianJSONFetchResult {
    var value: BailianUsageResponse?
    var diagnostics: [ProviderEndpointDiagnostic]
    var failures: [BailianFetchFailure]
}

private struct BailianUsageLookupResult {
    var value: BailianUsageResponse?
    var diagnostics: [ProviderEndpointDiagnostic]
    var failure: BailianFetchFailure?
}

private struct BailianPageFetchResult {
    var value: BailianUsageResponse?
    var diagnostics: [ProviderEndpointDiagnostic]
    var failure: BailianFetchFailure?
}

struct BailianUsageResponse {
    var planName: String?
    var statusText: String?
    var windows: [BailianUsageWindow]
    var remainingValue: String?
    var usedValue: String?
    var remainingUnit: String?
    var resetAt: Date?
}

private enum BailianFetchFailure {
    case authFailed(endpointName: String)
    case usageUnavailable(endpointName: String, path: String, statusCode: Int)
    case httpFailure(endpointName: String, path: String, statusCode: Int)
    case rateLimited(endpointName: String)
    case schemaChanged(endpointName: String)
    case other(endpointName: String, description: String)

    var statusText: String {
        switch self {
        case .authFailed:
            return "Auth Failed"
        case .usageUnavailable:
            return "Usage Unavailable"
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
        case .usageUnavailable(let endpointName, let path, let statusCode):
            return "\(endpointName) unavailable (\(path), HTTP \(statusCode))."
        case .httpFailure(let endpointName, let path, let statusCode):
            return "\(endpointName) request failed (\(path), HTTP \(statusCode))."
        case .rateLimited(let endpointName):
            return "\(endpointName) request was rate limited."
        case .schemaChanged(let endpointName):
            return "\(endpointName) schema changed."
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

struct BailianProviderError: LocalizedError {
    var message: String
    var diagnosticReport: String

    var errorDescription: String? { message }
}

@MainActor
private final class BailianRenderedPageLoader: NSObject, WKNavigationDelegate {
    private let url: URL
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(cookie: String) async -> BailianPageFetchResult {
        do {
            try await installCookies(cookie)
            try await navigate()
            let payload = try await waitForUsagePayload()
            return BailianPageFetchResult(
                value: payload,
                diagnostics: [
                    ProviderEndpointDiagnostic(
                        name: "Rendered Page",
                        path: url.absoluteString,
                        statusText: "OK",
                        detail: "Parsed rendered Coding Plan usage from the live page."
                    )
                ],
                failure: nil
            )
        } catch ProviderError.unauthorized {
            let failure = BailianFetchFailure.authFailed(endpointName: "Rendered Page")
            return BailianPageFetchResult(
                value: nil,
                diagnostics: [
                    ProviderEndpointDiagnostic(
                        name: "Rendered Page",
                        path: url.absoluteString,
                        statusText: failure.statusText,
                        detail: failure.userFacingMessage
                    )
                ],
                failure: failure
            )
        } catch {
            let failure = BailianFetchFailure.schemaChanged(endpointName: "Rendered Page")
            return BailianPageFetchResult(
                value: nil,
                diagnostics: [
                    ProviderEndpointDiagnostic(
                        name: "Rendered Page",
                        path: url.absoluteString,
                        statusText: failure.statusText,
                        detail: error.localizedDescription
                    )
                ],
                failure: failure
            )
        }
    }

    private func installCookies(_ cookieString: String) async throws {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = cookieString
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { part -> HTTPCookie? in
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return nil }
                return HTTPCookie(properties: [
                    .domain: "bailian.console.aliyun.com",
                    .path: "/",
                    .name: pieces[0],
                    .value: pieces[1],
                    .secure: true
                ])
            }

        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func navigate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func waitForUsagePayload() async throws -> BailianUsageResponse {
        for _ in 0..<8 {
            if let payload = try await currentUsagePayload() {
                return payload
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProviderError.invalidResponse
    }

    private func currentUsagePayload() async throws -> BailianUsageResponse? {
        let bodyText = try await evaluate(script: "document.body ? document.body.innerText : ''")
        if bodyText.contains("登录") && bodyText.contains("阿里云") {
            throw ProviderError.unauthorized
        }
        if let payload = try? BailianProvider.parseUsageResponse(fromRenderedText: bodyText) {
            return payload
        }

        let html = try await evaluate(script: "document.documentElement ? document.documentElement.outerHTML : ''")
        if let payload = try? BailianProvider.parseUsageResponse(fromHTML: html) {
            return payload
        }
        return nil
    }

    private func evaluate(script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result as? String ?? "")
            }
        }
    }
}

private extension Array {
    func uniqueBy<Value: Hashable>(_ keyPath: KeyPath<Element, Value>) -> [Element] {
        var seen: Set<Value> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
