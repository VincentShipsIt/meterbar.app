import Foundation
@testable import MeterBar
import XCTest

final class SessionWakePermissionTests: XCTestCase {
    // MARK: - Acknowledgement gating

    func testBypassAcknowledgementRequiresExplicitConfirmationAndReason() {
        XCTAssertNil(PermissionBypassAcknowledgement(confirmed: false, reason: "overnight batch"))
        XCTAssertNil(PermissionBypassAcknowledgement(confirmed: true, reason: "   "))
        XCTAssertNotNil(PermissionBypassAcknowledgement(confirmed: true, reason: "overnight batch"))
    }

    func testAcknowledgementTrimsReason() {
        let ack = PermissionBypassAcknowledgement(confirmed: true, reason: "  trusted repo  ")
        XCTAssertEqual(ack?.reason, "trusted repo")
    }

    // MARK: - Default is safe

    func testDefaultModeIsSafe() {
        XCTAssertEqual(WakePermissionMode.default, .safe)
        XCTAssertFalse(WakePermissionMode.default.isBypass)
    }

    func testSafeModeDoesNotEmitBypassFlag() {
        let arguments = WakePermissionMode.safe.claudeArguments
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(arguments, ["--permission-mode", "default"])
    }

    func testBypassModeEmitsDangerousFlagOnlyWithAcknowledgement() throws {
        let ack = try XCTUnwrap(PermissionBypassAcknowledgement(confirmed: true, reason: "trusted"))
        let mode = WakePermissionMode.bypass(ack)
        XCTAssertTrue(mode.isBypass)
        XCTAssertEqual(mode.claudeArguments, ["--dangerously-skip-permissions"])
    }

    // MARK: - Denial is structured, never auto-bypassed

    func testPermissionDenialIsDetectedFromOutput() {
        XCTAssertTrue(PermissionDenialDetector.indicatesDenial(in: "Error: permission denied for Bash"))
        XCTAssertTrue(PermissionDenialDetector.indicatesDenial(in: "This action REQUIRES APPROVAL to continue"))
        XCTAssertFalse(PermissionDenialDetector.indicatesDenial(in: "rate limit reached; resets at 3pm"))
        XCTAssertFalse(PermissionDenialDetector.indicatesDenial(in: ""))
    }

    func testNoApiConvertsSafeModeToBypass() {
        // Structural guarantee: safe mode never yields the dangerous flag, no
        // matter the "denial" signal. There is no auto-upgrade path.
        let deniedOutput = "permission denied"
        XCTAssertTrue(PermissionDenialDetector.indicatesDenial(in: deniedOutput))
        XCTAssertFalse(WakePermissionMode.safe.claudeArguments.contains("--dangerously-skip-permissions"))
    }
}
