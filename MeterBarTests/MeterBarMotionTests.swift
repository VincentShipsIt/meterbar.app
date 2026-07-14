import SwiftUI
import XCTest
@testable import MeterBar

/// Foundation invariants for the shared motion vocabulary
/// (`MeterBarTheme.Motion`). Later motion chips extend this suite.
final class MeterBarMotionTests: XCTestCase {
    // MARK: Tokens exist and keep their calibrated feel

    func testMotionTokensMatchCalibratedCurves() {
        // `quick` preserves the existing row expand/collapse snappy feel.
        XCTAssertEqual(MeterBarTheme.Motion.quick, .snappy(duration: 0.18))
        // `standard` is the content-swap curve (~0.25s smooth).
        XCTAssertEqual(MeterBarTheme.Motion.standard, .smooth(duration: 0.25))
        // `panel` drives window resize / fade (~0.22s smooth).
        XCTAssertEqual(MeterBarTheme.Motion.panel, .smooth(duration: 0.22))
    }

    // MARK: Reduce Motion suppression

    func testResolveSuppressesAnimationWhenReduceMotionOn() {
        XCTAssertNil(MeterBarTheme.Motion.resolve(.quick, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.resolve(.standard, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.resolve(.panel, reduceMotion: true))
    }

    func testResolvePassesThroughWhenReduceMotionOff() {
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(.quick, reduceMotion: false),
            MeterBarTheme.Motion.quick
        )
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(.standard, reduceMotion: false),
            MeterBarTheme.Motion.standard
        )
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(.panel, reduceMotion: false),
            MeterBarTheme.Motion.panel
        )
    }

    /// `resolve` returning `Animation?` must drop straight into `withAnimation`,
    /// whose `nil` overload runs the mutation without animating.
    func testResolveIsUsableAsWithAnimationArgument() {
        var animatedValue = 0
        withAnimation(MeterBarTheme.Motion.resolve(.quick, reduceMotion: true)) {
            animatedValue = 1
        }
        XCTAssertEqual(animatedValue, 1)
    }
}
