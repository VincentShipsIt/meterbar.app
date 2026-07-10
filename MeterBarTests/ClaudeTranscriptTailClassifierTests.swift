import XCTest
@testable import MeterBar

final class ClaudeTranscriptTailClassifierTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        guard let parsed = FlexibleISO8601.date(from: iso) else {
            XCTFail("bad fixture date \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return parsed
    }

    // MARK: - Shape A (structured rate_limit)

    func testStructuredRateLimitIsClassifiedBlocked() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.assistantProgressLine(timestamp: "2026-07-10T04:00:00.000Z"),
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z")
        ])

        let summary = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl)

        guard case .blocked(let event) = summary.terminalState else {
            return XCTFail("expected blocked, got \(summary.terminalState)")
        }
        XCTAssertEqual(event.reason, .sessionLimit)
        XCTAssertEqual(event.blockedAt, date("2026-07-10T04:14:15.397Z"))
        XCTAssertEqual(summary.sessionID, SessionWakeFixtures.defaultSessionID)
        XCTAssertEqual(summary.workingDirectory, "/tmp/project")
        XCTAssertEqual(summary.gitBranch, "claude/test-branch")
        XCTAssertFalse(summary.isSubagentTranscript)
    }

    func testStructuredRateLimitCasingVariantsAreRecognized() {
        for errorField in ["rate_limit", "RATE_LIMIT", "Rate_Limit"] {
            let jsonl = SessionWakeFixtures.jsonl([
                SessionWakeFixtures.rateLimitLine(errorField: errorField)
            ])
            let summary = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl)
            guard case .blocked = summary.terminalState else {
                return XCTFail("expected blocked for error field '\(errorField)'")
            }
        }
    }

    func testStatus429WithoutErrorFieldIsBlocked() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(errorField: "", apiErrorStatus: 429)
        ])
        guard case .blocked = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("expected blocked for 429 status")
        }
    }

    func testWeeklyAndOpusReasonsAreTyped() {
        let weekly = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(text: "You've hit your weekly limit · resets Jul 15 at 7am (Europe/Malta)")
        ])
        guard case .blocked(let weeklyEvent) = ClaudeTranscriptTailClassifier.classify(jsonl: weekly).terminalState else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(weeklyEvent.reason, .weeklyLimit)

        let opus = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(text: "You've hit your Opus weekly limit · resets Jul 15 at 7am")
        ])
        guard case .blocked(let opusEvent) = ClaudeTranscriptTailClassifier.classify(jsonl: opus).terminalState else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(opusEvent.reason, .opusWeeklyLimit)
    }

    // MARK: - Shape B (legacy pipe-epoch)

    func testLegacyPipeEpochIsBlockedWithExactReset() {
        let epoch = 1_752_130_800
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.legacyLimitLine(resetEpoch: epoch)
        ])

        guard case .blocked(let event) = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(event.resetAt, Date(timeIntervalSince1970: TimeInterval(epoch)))
        XCTAssertFalse(event.resetIsApproximate, "epoch markers are exact")
    }

    func testLegacyMarkerCasingVariantsAreRecognized() {
        for marker in [
            "Claude AI usage limit reached",
            "Claude usage limit reached",
            "CLAUDE AI USAGE LIMIT REACHED",
            "claude ai usage limit reached"
        ] {
            let jsonl = SessionWakeFixtures.jsonl([
                SessionWakeFixtures.legacyLimitLine(marker: marker)
            ])
            guard case .blocked = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
                return XCTFail("expected blocked for marker '\(marker)'")
            }
        }
    }

    // MARK: - Latest-decisive-event semantics

    func testHistoricalBlockFollowedByAssistantProgressIsNotBlocked() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z"),
            SessionWakeFixtures.assistantProgressLine(timestamp: "2026-07-10T09:00:00.000Z")
        ])

        guard case .progressed = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("later assistant activity must clear the block")
        }
    }

    func testHistoricalBlockFollowedByToolResultIsNotBlocked() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z"),
            SessionWakeFixtures.userToolResultLine(timestamp: "2026-07-10T09:01:00.000Z")
        ])

        guard case .progressed = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("later tool activity must clear the block")
        }
    }

    func testPlainUserTextAfterBlockIsNotDecisive() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z"),
            SessionWakeFixtures.userTextLine(timestamp: "2026-07-10T04:20:00.000Z"),
            SessionWakeFixtures.summaryLine()
        ])

        guard case .blocked = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("plain user text must not clear the block")
        }
    }

    func testSecondBlockAfterRecoveryUsesLatestBlockEvent() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-09T20:00:00.000Z"),
            SessionWakeFixtures.assistantProgressLine(timestamp: "2026-07-10T01:00:00.000Z"),
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z")
        ])

        guard case .blocked(let event) = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(event.blockedAt, date("2026-07-10T04:14:15.397Z"))
    }

    // MARK: - Subagents

    func testSidechainLinesAreIgnoredForClassification() {
        // Sidechain block after mainline progress must not mark the session blocked.
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.assistantProgressLine(timestamp: "2026-07-10T04:00:00.000Z"),
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:30:00.000Z", isSidechain: true)
        ])

        guard case .progressed = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("sidechain events must not classify the session")
        }
    }

    func testAllSidechainTranscriptIsFlaggedSubagent() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.assistantProgressLine(isSidechain: true),
            SessionWakeFixtures.rateLimitLine(isSidechain: true)
        ])

        let summary = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl)
        XCTAssertTrue(summary.isSubagentTranscript)
        guard case .indeterminate = summary.terminalState else {
            return XCTFail("subagent transcripts have no mainline terminal state")
        }
    }

    // MARK: - Robustness

    func testMalformedAndTruncatedLinesDoNotCrashOrPoison() {
        let jsonl = [
            "sionId\":\"partial-head-from-tail-read\"}",
            "not json at all",
            "{\"type\":\"assistant\",\"timestamp\":12345}",
            "{}",
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z"),
            "{\"truncated\":\"line with no closing brace"
        ].joined(separator: "\n")

        guard case .blocked = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("malformed neighbors must not poison the decisive event")
        }
    }

    func testEmptyTranscriptIsIndeterminate() {
        let summary = ClaudeTranscriptTailClassifier.classify(jsonl: "")
        guard case .indeterminate = summary.terminalState else {
            return XCTFail("expected indeterminate")
        }
        XCTAssertNil(summary.sessionID)
    }

    // MARK: - Reset parsing

    func testTimeOnlyResetIsAnchoredToEventDayInZone() {
        // Event 04:14Z; Malta is UTC+2 in July, so 7:30am Malta == 05:30Z same day.
        let event = date("2026-07-10T04:14:15Z")
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "You've hit your session limit · resets 7:30am (Europe/Malta)",
            anchoredTo: event
        )

        XCTAssertEqual(parsed?.date, date("2026-07-10T05:30:00Z"))
        XCTAssertEqual(parsed?.isApproximate, true, "text fallbacks can never prove quota")
    }

    func testResetTimeEarlierThanEventRollsToNextDay() {
        // Block at 8pm Malta, "resets 7:30am" means tomorrow morning.
        let event = date("2026-07-10T18:00:00Z")
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "resets 7:30am (Europe/Malta)",
            anchoredTo: event
        )

        XCTAssertEqual(parsed?.date, date("2026-07-11T05:30:00Z"))
    }

    func testResetJustPassedAtScanTimeIsNotRolledToTomorrow() {
        // Anchoring is to the EVENT timestamp: the event (04:14Z) precedes
        // 7:30am Malta (05:30Z), so the reset stays on the event's day even
        // when "now" is minutes past it.
        let event = date("2026-07-10T04:14:15Z")
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "resets 7:30am (Europe/Malta)",
            anchoredTo: event
        )

        guard let resetDate = parsed?.date else { return XCTFail("expected a reset date") }
        XCTAssertEqual(resetDate, date("2026-07-10T05:30:00Z"))
        let scanTime = date("2026-07-10T05:35:00Z")
        XCTAssertLessThan(resetDate, scanTime, "a just-passed reset stays in the past")
    }

    func testMonthDayResetForm() {
        let event = date("2026-07-10T04:14:15Z")
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "You've hit your weekly limit · resets Jul 15 at 10pm (Europe/Malta)",
            anchoredTo: event
        )

        // 10pm Malta on Jul 15 == 20:00Z.
        XCTAssertEqual(parsed?.date, date("2026-07-15T20:00:00Z"))
    }

    func testTwentyFourHourClockResetForm() {
        let event = date("2026-07-10T04:14:15Z")
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "resets 19:00 (Europe/Malta)",
            anchoredTo: event
        )

        XCTAssertEqual(parsed?.date, date("2026-07-10T17:00:00Z"))
    }

    func testUnparseableResetTextYieldsNil() {
        let parsed = ClaudeTranscriptTailClassifier.resetDate(
            fromMessageText: "You've hit your session limit",
            anchoredTo: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertNil(parsed)
    }

    func testBlockedEventCarriesParsedResetFromText() {
        let jsonl = SessionWakeFixtures.jsonl([
            SessionWakeFixtures.rateLimitLine(timestamp: "2026-07-10T04:14:15.397Z")
        ])

        guard case .blocked(let event) = ClaudeTranscriptTailClassifier.classify(jsonl: jsonl).terminalState else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(event.resetAt, date("2026-07-10T05:30:00Z"))
        XCTAssertEqual(event.resetIsApproximate, true)
    }
}
