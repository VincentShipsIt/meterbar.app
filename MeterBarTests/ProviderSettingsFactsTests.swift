@testable import MeterBar
import MeterBarShared
import XCTest

/// Unit coverage for the `ProviderSettingsFacts` derivation extracted from the
/// SettingsView monolith. The whole point of the value type is that every
/// displayed string/color is derived from plain primitives, so it is testable
/// without live provider services. Every case must cover `.grok`, which the
/// original (pre-Grok) split omitted.
final class ProviderSettingsFactsTests: XCTestCase {
    // MARK: - Helpers

    private func facts(
        service: ServiceType,
        isEnabled: Bool = true,
        hasAccess: Bool = true,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        errorText: String? = nil,
        worstBand: QuotaBand? = nil
    ) -> ProviderSettingsFacts {
        ProviderSettingsFacts(
            service: service,
            isEnabled: isEnabled,
            hasAccess: hasAccess,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            errorText: errorText,
            updatedText: "Updated just now",
            worstBand: worstBand,
            codexAuthFileDisplayPath: "~/.codex/auth.json"
        )
    }

    // MARK: - sourceText (one branch per service, including Grok)

    func testSourceTextCoversEveryService() {
        XCTAssertEqual(facts(service: .claudeCode).sourceText, "Claude CLI /usage")
        XCTAssertEqual(facts(service: .codexCli).sourceText, "~/.codex/auth.json + ChatGPT usage API")
        XCTAssertEqual(facts(service: .cursor).sourceText, "Cursor local state + usage API")
        XCTAssertEqual(facts(service: .openRouter).sourceText, "OpenRouter credits + key APIs")
        XCTAssertEqual(facts(service: .grok).sourceText, "Grok Build ACP billing")
    }

    // MARK: - planText

    func testClaudePlanJoinsSubscriptionAndTier() {
        let derived = facts(
            service: .claudeCode,
            subscriptionType: "max",
            rateLimitTier: "default_max_20x"
        )
        XCTAssertEqual(derived.planText, "Max · Default Max 20X")
    }

    func testClaudePlanIsNilWhenNothingReported() {
        XCTAssertNil(facts(service: .claudeCode).planText)
    }

    func testCodexAndCursorCapitalizePlan() {
        XCTAssertEqual(facts(service: .codexCli, subscriptionType: "plus").planText, "Plus")
        XCTAssertEqual(facts(service: .cursor, subscriptionType: "pro").planText, "Pro")
    }

    func testOpenRouterHasNoPlan() {
        XCTAssertNil(facts(service: .openRouter, subscriptionType: "ignored").planText)
    }

    func testGrokPlanIsShownVerbatim() {
        // Grok's token is already human-facing, so it is not title-cased.
        XCTAssertEqual(facts(service: .grok, subscriptionType: "SuperGrok").planText, "SuperGrok")
        XCTAssertNil(facts(service: .grok, subscriptionType: "").planText)
    }

    // MARK: - statusText

    func testStatusTextDisabledBeatsEverything() {
        let derived = facts(service: .grok, isEnabled: false, hasAccess: true, worstBand: .critical)
        XCTAssertEqual(derived.statusText, "Disabled")
    }

    func testStatusTextNotConnectedWhenNoAccess() {
        XCTAssertEqual(facts(service: .cursor, hasAccess: false).statusText, "Not connected")
    }

    func testStatusTextRefreshFailedOnError() {
        let derived = facts(service: .codexCli, errorText: "boom", worstBand: .healthy)
        XCTAssertEqual(derived.statusText, "Refresh failed")
    }

    func testStatusTextUsesWorstBandLabel() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .exhausted).statusText, "Out")
    }

    func testStatusTextWaitingWhenConnectedButNoBand() {
        XCTAssertEqual(facts(service: .claudeCode).statusText, "Waiting for refresh")
    }

    // MARK: - statusColor

    func testStatusColorSecondaryUntilEnabledAndConnected() {
        XCTAssertEqual(facts(service: .grok, isEnabled: false).statusColor, .secondary)
        XCTAssertEqual(facts(service: .grok, hasAccess: false).statusColor, .secondary)
    }

    func testStatusColorWarningOnError() {
        XCTAssertEqual(facts(service: .grok, errorText: "boom").statusColor, MeterBarTheme.warning)
    }

    func testStatusColorFollowsWorstBand() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .critical).statusColor, QuotaBand.critical.color)
    }
}
