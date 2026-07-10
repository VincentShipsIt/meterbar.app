import XCTest
import MeterBarShared
@testable import MeterBar

/// Quota-authority behavior (#96): missing/stale/failed/ambiguous quota fails
/// closed; every hard window is gated; cached metrics are never authority.
final class WakeQuotaAuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private lazy var evaluator = WakeQuotaEvaluator(freshnessWindow: 90)

    private func metrics(
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        model: UsageLimit? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: model
        )
    }

    // MARK: - Fail-closed cases

    func testUnauthorizedIsUnknownMissingAuthorization() {
        XCTAssertEqual(
            evaluator.evaluate(.unauthorized, now: now),
            .unknown(reason: .missingAuthorization)
        )
    }

    func testFailureIsUnknownFetchFailed() {
        XCTAssertEqual(
            evaluator.evaluate(.failure("boom"), now: now),
            .unknown(reason: .fetchFailed("boom"))
        )
    }

    func testStaleSuccessIsUnknown() {
        let stale = metrics(session: UsageLimit(used: 10, total: 100, resetTime: nil))
        let state = evaluator.evaluate(.success(stale, fetchedAt: now.addingTimeInterval(-200)), now: now)
        guard case .unknown(.stale) = state else {
            return XCTFail("Expected .unknown(.stale), got \(state)")
        }
    }

    func testFutureDatedSuccessIsUnknownStale() {
        let future = metrics(session: UsageLimit(used: 10, total: 100, resetTime: nil))
        let state = evaluator.evaluate(.success(future, fetchedAt: now.addingTimeInterval(200)), now: now)
        guard case .unknown(.stale) = state else {
            return XCTFail("Expected .unknown(.stale) for a backwards clock, got \(state)")
        }
    }

    func testAmbiguousEmptyMetricsIsUnknown() {
        let state = evaluator.evaluate(.success(metrics(), fetchedAt: now), now: now)
        guard case .unknown(.ambiguous) = state else {
            return XCTFail("Expected .unknown(.ambiguous), got \(state)")
        }
    }

    // MARK: - Available / blocked

    func testFreshOpenSessionIsAvailable() {
        let open = metrics(session: UsageLimit(used: 10, total: 100, resetTime: nil))
        XCTAssertEqual(evaluator.evaluate(.success(open, fetchedAt: now), now: now), .available)
    }

    func testExhaustedSessionIsBlocked() {
        let reset = now.addingTimeInterval(3_600)
        let exhausted = metrics(session: UsageLimit(used: 100, total: 100, resetTime: reset))
        XCTAssertEqual(
            evaluator.evaluate(.success(exhausted, fetchedAt: now), now: now),
            .blocked(until: reset, reason: .sessionLimit)
        )
    }

    /// An exhausted weekly window blocks a launch even when the 5-hour session
    /// window is open.
    func testExhaustedWeeklyBlocksEvenWhenSessionOpen() {
        let reset = now.addingTimeInterval(86_400)
        let combined = metrics(
            session: UsageLimit(used: 10, total: 100, resetTime: nil),
            weekly: UsageLimit(used: 100, total: 100, resetTime: reset)
        )
        XCTAssertEqual(
            evaluator.evaluate(.success(combined, fetchedAt: now), now: now),
            .blocked(until: reset, reason: .weeklyLimit)
        )
    }

    /// A model-specific weekly window also blocks with session + weekly open.
    func testExhaustedModelWeeklyBlocks() {
        let reset = now.addingTimeInterval(86_400)
        let combined = metrics(
            session: UsageLimit(used: 10, total: 100, resetTime: nil),
            weekly: UsageLimit(used: 20, total: 100, resetTime: nil),
            model: UsageLimit(used: 100, total: 100, resetTime: reset)
        )
        XCTAssertEqual(
            evaluator.evaluate(.success(combined, fetchedAt: now), now: now),
            .blocked(until: reset, reason: .modelWeeklyLimit)
        )
    }

    /// When multiple windows are exhausted, the farthest reset is reported (most
    /// conservative wait).
    func testBlockedReportsFarthestReset() {
        let soon = now.addingTimeInterval(3_600)
        let later = now.addingTimeInterval(86_400)
        let both = metrics(
            session: UsageLimit(used: 100, total: 100, resetTime: soon),
            weekly: UsageLimit(used: 100, total: 100, resetTime: later)
        )
        XCTAssertEqual(
            evaluator.evaluate(.success(both, fetchedAt: now), now: now),
            .blocked(until: later, reason: .weeklyLimit)
        )
    }

    /// An unknown reset counts as the farthest — a blocked window with no known
    /// reset dominates, so the watcher never launches on optimistic timing.
    func testUnknownResetDominatesAsFarthest() {
        let soon = now.addingTimeInterval(3_600)
        let both = metrics(
            session: UsageLimit(used: 100, total: 100, resetTime: nil),
            weekly: UsageLimit(used: 100, total: 100, resetTime: soon)
        )
        let state = evaluator.evaluate(.success(both, fetchedAt: now), now: now)
        guard case let .blocked(until, _) = state else {
            return XCTFail("Expected .blocked, got \(state)")
        }
        XCTAssertNil(until)
    }

    func testPermitsLaunchOnlyWhenAvailable() {
        XCTAssertTrue(WakeQuotaState.available.permitsLaunch)
        XCTAssertFalse(WakeQuotaState.blocked(until: now, reason: .sessionLimit).permitsLaunch)
        XCTAssertFalse(WakeQuotaState.unknown(reason: .notFetched).permitsLaunch)
    }

    // MARK: - Authority wiring

    func testAuthorityFetchesFreshAndEvaluates() async {
        let fetcher = ScriptedQuotaFetcher([WakeMetricsFixture.available(fetchedAt: now)])
        let authority = WakeQuotaAuthority(
            fetcher: fetcher,
            evaluator: evaluator,
            now: { self.now }
        )
        let state = await authority.currentState(accountID: UUID())
        XCTAssertEqual(state, .available)
        XCTAssertEqual(fetcher.callCount, 1, "Authority must perform a fresh fetch")
    }

    func testAuthorityFailsClosedOnFetchError() async {
        let fetcher = ScriptedQuotaFetcher([.failure("cli exploded")])
        let authority = WakeQuotaAuthority(fetcher: fetcher, evaluator: evaluator, now: { self.now })
        let state = await authority.currentState(accountID: UUID())
        XCTAssertEqual(state, .unknown(reason: .fetchFailed("cli exploded")))
    }
}
