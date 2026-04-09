import XCTest
@testable import UsageBar

final class ProviderParsingTests: XCTestCase {
    func testBailianSnapshotParsesNestedFields() throws {
        let payload: [String: Any] = [
            "data": [
                "remainingQuota": 1280,
                "consumed": 320,
                "unit": "calls",
                "expireAt": "2026-04-15T00:00:00Z"
            ]
        ]

        let snapshot = try BailianProvider.makeSnapshot(from: payload, sourceHint: "API")

        XCTAssertEqual(snapshot.provider, .bailian)
        XCTAssertEqual(snapshot.remainingValue, "1280")
        XCTAssertEqual(snapshot.usedValue, "320")
        XCTAssertEqual(snapshot.remainingUnit, "calls")
        XCTAssertNotNil(snapshot.resetAt)
    }

    func testBailianUsageResponseClassifiesPrimaryWindows() throws {
        let payload: [String: Any] = [
            "data": [
                "planName": "Coding Plan Lite",
                "windows": [
                    [
                        "label": "5 Hours",
                        "limit": 1000,
                        "used": 420,
                        "remaining": 580,
                        "percentage": 42,
                        "resetAt": "2026-04-10T02:00:00Z"
                    ],
                    [
                        "label": "Weekly",
                        "limit": 3000,
                        "used": 900,
                        "remaining": 2100
                    ]
                ]
            ]
        ]

        let response = try BailianProvider.parseUsageResponse(from: payload)

        XCTAssertEqual(response.planName, "Coding Plan Lite")
        XCTAssertEqual(response.windows.count, 2)
        XCTAssertEqual(response.windows[0].bucket, .fiveHour)
        XCTAssertEqual(response.windows[1].bucket, .weekly)
    }

    func testBailianUsageResponseParsesEmbeddedHTMLJSON() throws {
        let html = """
        <html>
        <head></head>
        <body>
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"data":{"windows":[{"label":"Monthly","limit":5000,"used":1000}]}}}}
        </script>
        </body>
        </html>
        """

        let response = try BailianProvider.parseUsageResponse(fromHTML: html)

        XCTAssertEqual(response.windows.count, 1)
        XCTAssertEqual(response.windows[0].bucket, .monthly)
        XCTAssertEqual(Int(response.windows[0].remaining), 4000)
    }

    func testBailianUsageResponseParsesScriptAssignedJSON() throws {
        let html = """
        <html>
        <body>
        <script>
        window.__PRELOADED_STATE__ = {"state":{"codingPlan":{"windows":[{"label":"Weekly","limit":800,"used":200}]}}};
        </script>
        </body>
        </html>
        """

        let response = try BailianProvider.parseUsageResponse(fromHTML: html)

        XCTAssertEqual(response.windows.count, 1)
        XCTAssertEqual(response.windows[0].bucket, .weekly)
        XCTAssertEqual(Int(response.windows[0].remaining), 600)
    }

    func testBailianUsageResponseParsesTextWrappedJSONData() throws {
        let payload = """
        {"state":{"codingPlan":{"windows":[{"label":"5 Hours","limit":100,"used":25}]}}}
        """

        let response = try BailianProvider.parseUsageResponse(fromData: Data(payload.utf8))

        XCTAssertEqual(response.windows.count, 1)
        XCTAssertEqual(response.windows[0].bucket, .fiveHour)
        XCTAssertEqual(Int(response.windows[0].percentage.rounded()), 25)
    }

    func testBailianUsageResponseParsesRenderedUsageText() throws {
        let text = """
        用量消耗
        近5小时用量
        3%
        2026-04-09 15:08:03 重置
        近一周用量
        5%
        2026-04-13 00:00:00 重置
        近一月用量
        12%
        2026-04-28 00:00:00 重置
        """

        let response = try BailianProvider.parseUsageResponse(fromRenderedText: text)

        XCTAssertEqual(response.windows.count, 3)
        XCTAssertEqual(response.windows[0].bucket, .fiveHour)
        XCTAssertEqual(Int(response.windows[0].percentage.rounded()), 3)
        XCTAssertEqual(response.windows[1].bucket, .weekly)
        XCTAssertEqual(response.windows[2].bucket, .monthly)
        XCTAssertNotNil(response.windows[2].resetAt)
    }

    func testZAISnapshotComputesRemainingFromQuotaAndUsage() throws {
        let payload: [String: Any] = [
            "data": [
                "quota": 5000,
                "usage": 1200,
                "unit": "req",
                "resetAt": "2026-04-10T00:00:00Z"
            ]
        ]

        let snapshot = try ZAIProvider.makeSnapshot(from: payload, sourceHint: "API")

        XCTAssertEqual(snapshot.provider, .zaiGlobal)
        XCTAssertEqual(snapshot.remainingValue, "3800")
        XCTAssertEqual(snapshot.usedValue, "1200")
        XCTAssertEqual(snapshot.remainingUnit, "req")
        XCTAssertNotNil(snapshot.resetAt)
    }

    func testZAIQuotaResponseClassifiesPrimaryWindows() throws {
        let payload: [String: Any] = [
            "data": [
                "limits": [
                    [
                        "type": "TOKENS_LIMIT",
                        "unit": 3,
                        "number": 5,
                        "limit": 1000,
                        "used": 680,
                        "remaining": 320,
                        "percentage": 68,
                        "nextResetTime": "2026-04-10T02:00:00Z"
                    ],
                    [
                        "type": "TOKENS_LIMIT",
                        "unit": 6,
                        "number": 7,
                        "limit": 5000,
                        "used": 2100,
                        "remaining": 2900,
                        "percentage": 42
                    ]
                ]
            ]
        ]

        let response = try ZAIProvider.parseQuotaResponse(from: payload)

        XCTAssertEqual(response.windows.count, 2)
        XCTAssertEqual(response.windows[0].bucket, .fiveHour)
        XCTAssertEqual(response.windows[1].bucket, .weekly)
        XCTAssertEqual(Int(response.windows[0].percentage), 68)
    }

    func testZAIQuotaResponseParsesNestedFiveHourResetTime() throws {
        let payload: [String: Any] = [
            "data": [
                "limits": [
                    [
                        "type": "TOKENS_LIMIT",
                        "unit": 3,
                        "number": 5,
                        "limit": 1000,
                        "used": 140,
                        "percentage": 14,
                        "window": [
                            "resetAt": "2026-04-10T05:13:24Z"
                        ]
                    ]
                ]
            ]
        ]

        let response = try ZAIProvider.parseQuotaResponse(from: payload)

        XCTAssertEqual(response.windows.first?.bucket, .fiveHour)
        XCTAssertNotNil(response.windows.first?.resetAt)
    }

    func testZAIQuotaResponseKeepsUnmatchedWindows() throws {
        let payload: [String: Any] = [
            "limits": [
                [
                    "type": "CUSTOM_LIMIT",
                    "unit": 99,
                    "number": 2,
                    "limit": 12,
                    "used": 4
                ]
            ]
        ]

        let response = try ZAIProvider.parseQuotaResponse(from: payload)

        XCTAssertEqual(response.windows.count, 1)
        XCTAssertEqual(response.windows[0].bucket, .unmatched)
        XCTAssertEqual(response.windows[0].rawType, "CUSTOM_LIMIT")
    }

    func testOpenAIWebSnapshotStaysLimitedAndUsesResetDate() throws {
        let payload: [String: Any] = [
            "account": [
                "plan_type": "plus",
                "has_active_subscription": true,
                "message_cap_reset_at": "2026-04-11T00:00:00Z"
            ]
        ]

        let snapshot = try OpenAIPlusProvider.makeWebSnapshot(from: payload)

        XCTAssertEqual(snapshot.provider, .openAIPlus)
        XCTAssertEqual(snapshot.status, .supportedLimited)
        XCTAssertEqual(snapshot.summaryText, "Plus active")
        XCTAssertNotNil(snapshot.resetAt)
        XCTAssertNil(snapshot.remainingValue)
    }

    func testCodexStatusParsesFiveHourAndWeeklyWindows() throws {
        let text = """
        Credits: 24.5
        5h limit 72% left resets at 18:45
        Weekly limit 41% left resets at 13 Apr 00:00
        """

        let snapshot = try CodexStatusProbe.parse(text: text, now: ISO8601DateFormatter().date(from: "2026-04-09T15:00:00Z")!)

        XCTAssertEqual(snapshot.credits, 24.5)
        XCTAssertEqual(snapshot.fiveHourPercentLeft, 72)
        XCTAssertEqual(snapshot.weeklyPercentLeft, 41)
        XCTAssertNotNil(snapshot.fiveHourResetsAt)
        XCTAssertNotNil(snapshot.weeklyResetsAt)
    }

    func testCodexRPCSnapshotBuildsPrimaryAndSecondaryWindows() {
        let snapshot = OpenAIPlusProvider.makeSnapshot(
            from: CodexRPCSnapshot(
                primary: CodexRPCWindow(
                    usedPercent: 28,
                    resetsAt: ISO8601DateFormatter().date(from: "2026-04-09T18:45:00Z")
                ),
                secondary: CodexRPCWindow(
                    usedPercent: 59,
                    resetsAt: ISO8601DateFormatter().date(from: "2026-04-13T00:00:00Z")
                ),
                creditsRemaining: 19.5
            ),
            account: CodexAccountInfo(accountID: nil, email: "me@example.com", plan: "plus"),
            sourceLabel: "Local RPC",
            diagnostics: []
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.windows.count, 2)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.windows.first?.bucket, .fiveHour)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.creditsRemaining, 19.5)
        XCTAssertEqual(snapshot.summaryText, "5 Hours 28%")
    }

    func testCodexOAuthSnapshotBuildsUsageWindows() throws {
        let payload: [String: Any] = [
            "plan_type": "plus",
            "email": "me@example.com",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 31,
                    "reset_at": 1775750700
                ],
                "secondary_window": [
                    "used_percent": 57,
                    "reset_at": 1776038400
                ]
            ],
            "credits": [
                "balance": 12.5
            ]
        ]

        let snapshot = try OpenAIPlusProvider.makeOAuthSnapshot(
            from: payload,
            account: CodexAccountInfo(accountID: nil, email: "me@example.com", plan: "plus"),
            diagnostics: []
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.sourceLabel, "OAuth API")
        XCTAssertEqual(snapshot.providerMetadata?.codex?.windows.count, 2)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.windows.first?.bucket, .fiveHour)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.creditsRemaining, 12.5)
        XCTAssertEqual(snapshot.providerMetadata?.codex?.planName, "Plus")
        XCTAssertEqual(snapshot.providerMetadata?.codex?.accountEmail, "me@example.com")
    }
}
