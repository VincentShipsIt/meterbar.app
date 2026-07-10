import XCTest
@testable import MeterBar

/// Numeric-bounds validation for the wake watcher (#96 acceptance:
/// "Numeric bounds for polling, buffer, gap, timeout, max turns, and session
/// cap are validated").
final class WakeBoundsTests: XCTestCase {
    func testDefaultsAreWithinRangeAndConservative() {
        let bounds = WakeBounds.default
        XCTAssertTrue(WakeBounds.pollIntervalRange.contains(bounds.pollInterval))
        XCTAssertTrue(WakeBounds.resetBufferRange.contains(bounds.resetBuffer))
        XCTAssertTrue(WakeBounds.interSessionGapRange.contains(bounds.interSessionGap))
        XCTAssertTrue(WakeBounds.sessionTimeoutRange.contains(bounds.sessionTimeout))
        XCTAssertTrue(WakeBounds.maxTurnsRange.contains(bounds.maxTurns))
        XCTAssertTrue(WakeBounds.sessionCapRange.contains(bounds.sessionCap))
        // PRD-aligned values.
        XCTAssertEqual(bounds.pollInterval, 60)
        XCTAssertEqual(bounds.resetBuffer, 90)
        XCTAssertEqual(bounds.interSessionGap, 20)
        XCTAssertEqual(bounds.sessionTimeout, 7_200)
    }

    func testSessionCapIsNeverUnlimited() {
        // Epic #94: "Unlimited sessions are never the default." The PRD's
        // historical "0 = all" must resolve to a finite floor, not infinity.
        XCTAssertEqual(WakeBounds(
            pollInterval: 60, resetBuffer: 90, interSessionGap: 20,
            sessionTimeout: 7_200, maxTurns: 40, sessionCap: 0
        ).sessionCap, WakeBounds.sessionCapRange.lowerBound)

        XCTAssertEqual(WakeBounds(
            pollInterval: 60, resetBuffer: 90, interSessionGap: 20,
            sessionTimeout: 7_200, maxTurns: 40, sessionCap: -5
        ).sessionCap, WakeBounds.sessionCapRange.lowerBound)

        XCTAssertGreaterThanOrEqual(WakeBounds.default.sessionCap, 1)
        XCTAssertLessThanOrEqual(WakeBounds.default.sessionCap, WakeBounds.sessionCapRange.upperBound)
    }

    func testLowClampToLowerBound() {
        let bounds = WakeBounds(
            pollInterval: 1, resetBuffer: -50, interSessionGap: -1,
            sessionTimeout: 1, maxTurns: 0, sessionCap: 0
        )
        XCTAssertEqual(bounds.pollInterval, WakeBounds.pollIntervalRange.lowerBound)
        XCTAssertEqual(bounds.resetBuffer, WakeBounds.resetBufferRange.lowerBound)
        XCTAssertEqual(bounds.interSessionGap, WakeBounds.interSessionGapRange.lowerBound)
        XCTAssertEqual(bounds.sessionTimeout, WakeBounds.sessionTimeoutRange.lowerBound)
        XCTAssertEqual(bounds.maxTurns, WakeBounds.maxTurnsRange.lowerBound)
        XCTAssertEqual(bounds.sessionCap, WakeBounds.sessionCapRange.lowerBound)
    }

    func testHighClampToUpperBound() {
        let bounds = WakeBounds(
            pollInterval: 999_999, resetBuffer: 999_999, interSessionGap: 999_999,
            sessionTimeout: 999_999, maxTurns: 999_999, sessionCap: 999_999
        )
        XCTAssertEqual(bounds.pollInterval, WakeBounds.pollIntervalRange.upperBound)
        XCTAssertEqual(bounds.resetBuffer, WakeBounds.resetBufferRange.upperBound)
        XCTAssertEqual(bounds.interSessionGap, WakeBounds.interSessionGapRange.upperBound)
        XCTAssertEqual(bounds.sessionTimeout, WakeBounds.sessionTimeoutRange.upperBound)
        XCTAssertEqual(bounds.maxTurns, WakeBounds.maxTurnsRange.upperBound)
        XCTAssertEqual(bounds.sessionCap, WakeBounds.sessionCapRange.upperBound)
    }

    func testNonFiniteInputFailsToLowerBound() {
        let bounds = WakeBounds(
            pollInterval: .nan, resetBuffer: .infinity, interSessionGap: -.infinity,
            sessionTimeout: .nan, maxTurns: 40, sessionCap: 25
        )
        XCTAssertEqual(bounds.pollInterval, WakeBounds.pollIntervalRange.lowerBound)
        XCTAssertEqual(bounds.resetBuffer, WakeBounds.resetBufferRange.lowerBound)
        XCTAssertEqual(bounds.interSessionGap, WakeBounds.interSessionGapRange.lowerBound)
        XCTAssertEqual(bounds.sessionTimeout, WakeBounds.sessionTimeoutRange.lowerBound)
    }

    func testValidValuesPassThroughUnchanged() {
        let bounds = WakeBounds(
            pollInterval: 120, resetBuffer: 45, interSessionGap: 30,
            sessionTimeout: 3_600, maxTurns: 100, sessionCap: 10
        )
        XCTAssertEqual(bounds.pollInterval, 120)
        XCTAssertEqual(bounds.resetBuffer, 45)
        XCTAssertEqual(bounds.interSessionGap, 30)
        XCTAssertEqual(bounds.sessionTimeout, 3_600)
        XCTAssertEqual(bounds.maxTurns, 100)
        XCTAssertEqual(bounds.sessionCap, 10)
    }
}
