import XCTest
@testable import UsageBar

final class UsageBarTests: XCTestCase {
    func testAuthRequiredSnapshotDefaults() {
        let snapshot = ProviderBalanceSnapshot.authRequired(provider: .bailian)

        XCTAssertEqual(snapshot.status, .authRequired)
        XCTAssertEqual(snapshot.summaryText, "Not connected")
        XCTAssertNil(snapshot.remainingValue)
    }

    func testDefaultAuthModesMatchProviderCapabilities() {
        XCTAssertEqual(ProviderConfiguration.default(for: .bailian).authMode, .webSession)
        XCTAssertEqual(ProviderConfiguration.default(for: .zaiGlobal).authMode, .apiKey)
        XCTAssertEqual(ProviderConfiguration.default(for: .openAIPlus).authMode, .webSession)
    }

    func testRelativeDateFormattingProducesReadableLabel() {
        let label = Date().addingTimeInterval(3_600).veryShortRelativeLabel
        XCTAssertFalse(label.isEmpty)
    }

    func testDataAgeTintThresholds() {
        XCTAssertEqual(Date().addingTimeInterval(-60).ageTint, .fresh)
        XCTAssertEqual(Date().addingTimeInterval(-3_600).ageTint, .aging)
        XCTAssertEqual(Date().addingTimeInterval(-90_000).ageTint, .stale)
    }

    func testLegacySettingsSnapshotDecodesWithOnboardingDefault() throws {
        let current = SettingsSnapshot.default
        let encoded = try JSONEncoder().encode(current)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "didDismissOnboarding")
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyObject)

        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: legacyJSON)

        XCTAssertFalse(snapshot.didDismissOnboarding)
        XCTAssertEqual(snapshot.providerConfigurations[.openAIPlus]?.authMode, .webSession)
    }

    @MainActor
    func testSettingsStoreShowsOnboardingOnlyWithoutCredentialsAndDismissal() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.shouldShowOnboarding(hasAnyCredential: false))
        XCTAssertFalse(store.shouldShowOnboarding(hasAnyCredential: true))

        store.dismissOnboarding()

        XCTAssertFalse(store.shouldShowOnboarding(hasAnyCredential: false))
    }
}
