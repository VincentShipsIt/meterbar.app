import SwiftUI
import XCTest
@testable import MeterBar

/// Covers the micro-motion tokens that drive refresh-driven animation across the
/// UI (numeric-text rolls, bar sweeps, icon/state swaps). The view modifiers
/// themselves aren't inspectable without ViewInspector (not a dependency here),
/// so the testable seam is `MeterBarTheme.Motion`: every animated surface routes
/// through it, and the Reduce-Motion contract lives entirely in these accessors.
final class MeterBarMotionTests: XCTestCase {
    // MARK: - Reduce Motion collapses to an instant (nil) animation

    func testStandardIsNilUnderReduceMotion() {
        XCTAssertNil(MeterBarTheme.Motion.standard(reduceMotion: true))
    }

    func testSnappyIsNilUnderReduceMotion() {
        XCTAssertNil(MeterBarTheme.Motion.snappy(reduceMotion: true))
    }

    // MARK: - Motion on: the token resolves to its curve

    func testStandardResolvesToCurveWhenMotionAllowed() {
        XCTAssertEqual(
            MeterBarTheme.Motion.standard(reduceMotion: false),
            MeterBarTheme.Motion.standardCurve
        )
    }

    func testSnappyResolvesToCurveWhenMotionAllowed() {
        XCTAssertEqual(
            MeterBarTheme.Motion.snappy(reduceMotion: false),
            MeterBarTheme.Motion.snappyCurve
        )
    }

    // MARK: - The two curves are distinct so numeric rolls and icon swaps differ

    func testStandardAndSnappyAreDistinctCurves() {
        XCTAssertNotEqual(
            MeterBarTheme.Motion.standardCurve,
            MeterBarTheme.Motion.snappyCurve
        )
    }
}
