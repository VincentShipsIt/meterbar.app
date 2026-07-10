import XCTest
import MeterBarShared
@testable import MeterBar

/// State-machine behavior for the single native wake watcher (#96).
final class WakeCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func makeAuthority(_ fetches: [WakeQuotaFetch]) -> (WakeQuotaAuthority, ScriptedQuotaFetcher) {
        let fetcher = ScriptedQuotaFetcher(fetches)
        let authority = WakeQuotaAuthority(
            fetcher: fetcher,
            evaluator: WakeQuotaEvaluator(freshnessWindow: 90),
            now: { self.now }
        )
        return (authority, fetcher)
    }

    private func boundsWithCap(_ cap: Int) -> WakeBounds {
        WakeBounds(
            pollInterval: 60, resetBuffer: 90, interSessionGap: 20,
            sessionTimeout: 7_200, maxTurns: 40, sessionCap: cap
        )
    }

    private func makeCoordinator(
        bounds: WakeBounds = .default,
        authority: WakeQuotaAuthority,
        candidates: WakeCandidateSource,
        runner: WakeSessionRunning,
        ledger: InMemoryLedger,
        sleeper: WakeSleeper
    ) -> WakeCoordinator {
        WakeCoordinator(
            account: wakeTestAccount(),
            bounds: bounds,
            authority: authority,
            candidateSource: candidates,
            ledger: ledger,
            runner: runner,
            sleeper: sleeper,
            now: { self.now }
        )
    }

    // MARK: - Fail-closed: unknown quota launches nothing

    private func assertFailsClosed(
        _ fetch: WakeQuotaFetch,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (authority, fetcher) = makeAuthority([fetch])
        let runner = StubRunner(mode: .outcome(.completed))
        let coordinator = makeCoordinator(
            authority: authority,
            candidates: StubCandidateSource(constant: [wakeCandidate("c1")]),
            runner: runner,
            ledger: InMemoryLedger(),
            sleeper: BlockingSleeper()
        )

        await coordinator.start()
        let reached = await wakeWaitUntil {
            if case .quotaUnknown = await coordinator.currentState { return true }
            return false
        }
        XCTAssertTrue(reached, "Expected the gate to reach quotaUnknown", file: file, line: line)
        XCTAssertTrue(runner.runs.isEmpty, "Unknown quota must launch nothing", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fetcher.callCount, 1, "Quota must be checked", file: file, line: line)

        await coordinator.stop()
        let final = await coordinator.currentState
        XCTAssertEqual(final, .off, file: file, line: line)
    }

    func testMissingAuthorizationLaunchesNothing() async {
        await assertFailsClosed(.unauthorized)
    }

    func testFetchFailureLaunchesNothing() async {
        await assertFailsClosed(.failure("cli error"))
    }

    func testStaleQuotaLaunchesNothing() async {
        await assertFailsClosed(WakeMetricsFixture.available(fetchedAt: now.addingTimeInterval(-1_000)))
    }

    func testAmbiguousQuotaLaunchesNothing() async {
        await assertFailsClosed(.success(UsageMetrics(service: .claudeCode), fetchedAt: now))
    }

    // MARK: - Fresh gate before first launch, then runs when available

    func testFreshQuotaCheckedBeforeFirstLaunchThenRuns() async {
        let candidate = wakeCandidate("c1")
        let (authority, fetcher) = makeAuthority([WakeMetricsFixture.available(fetchedAt: now)])
        let runner = StubRunner(mode: .outcome(.completed))
        let ledger = InMemoryLedger()
        let coordinator = makeCoordinator(
            bounds: boundsWithCap(1),
            authority: authority,
            candidates: StubCandidateSource(constant: [candidate]),
            runner: runner,
            ledger: ledger,
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        let done = await wakeWaitUntil { await coordinator.currentState == .completed }
        XCTAssertTrue(done, "Watcher should complete after the single capped run")
        XCTAssertEqual(runner.runs, [candidate.id])
        XCTAssertGreaterThanOrEqual(fetcher.callCount, 1, "Fresh quota must be checked before launch")
        XCTAssertTrue(ledger.recorded.contains(candidate.fingerprint.value),
                      "Completed session must be recorded in the ledger")
    }

    // MARK: - Past reset never proves availability

    func testPastResetNeverProvesAvailability() async {
        // A blocked window whose reset already elapsed must not itself authorize
        // a launch — only a subsequent *fresh* available fetch may.
        let runner = StubRunner(mode: .outcome(.completed))
        let (authority, fetcher) = makeAuthority([
            WakeMetricsFixture.blocked(fetchedAt: now, until: now.addingTimeInterval(-3_600))
        ])
        let coordinator = makeCoordinator(
            authority: authority,
            candidates: StubCandidateSource(constant: [wakeCandidate("c1")]),
            runner: runner,
            ledger: InMemoryLedger(),
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        let waited = await wakeWaitUntil {
            guard case .waiting = await coordinator.currentState else { return false }
            return fetcher.callCount >= 2   // proves it re-fetches rather than launching
        }
        XCTAssertTrue(waited, "A passed reset must drive a fresh re-fetch, not a launch")
        XCTAssertTrue(runner.runs.isEmpty, "A passed reset alone must never launch a session")

        await coordinator.stop()
        let offState = await coordinator.currentState
        XCTAssertEqual(offState, .off)
    }

    // MARK: - Re-maxed quota stops the queue and preserves remaining work

    func testSessionThatRemaxesQuotaStopsQueueAndPreservesRemaining() async {
        let c1 = wakeCandidate("c1")
        let c2 = wakeCandidate("c2")
        // First gate available (runs c1), second gate (after c1 completes)
        // reports the quota re-exhausted, so c2 must never launch.
        let (authority, _) = makeAuthority([
            WakeMetricsFixture.available(fetchedAt: now),
            WakeMetricsFixture.blocked(fetchedAt: now, until: now.addingTimeInterval(3_600))
        ])
        let runner = StubRunner(mode: .outcome(.completed))
        let coordinator = makeCoordinator(
            authority: authority,
            candidates: StubCandidateSource(constant: [c1, c2]),
            runner: runner,
            ledger: InMemoryLedger(),
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        let stopped = await wakeWaitUntil {
            guard case .waiting = await coordinator.currentState else { return false }
            return runner.runs == [c1.id]
        }
        XCTAssertTrue(stopped, "Watcher must return to waiting after quota re-exhausts")
        XCTAssertEqual(runner.runs, [c1.id], "The second candidate must not launch while blocked")

        let pending = await coordinator.pendingQueueIDs
        XCTAssertTrue(pending.contains(c2.id), "Remaining queue work must be preserved")

        await coordinator.stop()
        let offState = await coordinator.currentState
        XCTAssertEqual(offState, .off)
    }

    // MARK: - Watcher-off cancels pending sleep/poll deterministically

    func testWatcherOffCancelsPendingSleepDeterministically() async {
        let (authority, _) = makeAuthority([
            WakeMetricsFixture.blocked(fetchedAt: now, until: now.addingTimeInterval(3_600))
        ])
        let runner = StubRunner(mode: .outcome(.completed))
        let sleeper = BlockingSleeper()
        let coordinator = makeCoordinator(
            authority: authority,
            candidates: StubCandidateSource(constant: [wakeCandidate("c1")]),
            runner: runner,
            ledger: InMemoryLedger(),
            sleeper: sleeper
        )

        await coordinator.start()
        let waiting = await wakeWaitUntil {
            if case .waiting = await coordinator.currentState { return true }
            return false
        }
        XCTAssertTrue(waiting, "Watcher should be waiting on the blocked reset")

        await coordinator.stop()
        XCTAssertTrue(sleeper.wasCancelled, "The pending sleep must be cancelled by stop()")
        XCTAssertTrue(runner.runs.isEmpty, "No session should run while blocked")
        let offState = await coordinator.currentState
        XCTAssertEqual(offState, .off)
    }

    // MARK: - Active-child cancellation semantics

    func testActiveChildCancellationPreservesCandidateAndDoesNotRecord() async {
        let candidate = wakeCandidate("c1")
        let (authority, _) = makeAuthority([WakeMetricsFixture.available(fetchedAt: now)])
        let runner = StubRunner(mode: .blockUntilCancelled)
        let ledger = InMemoryLedger()
        let coordinator = makeCoordinator(
            authority: authority,
            candidates: StubCandidateSource(constant: [candidate]),
            runner: runner,
            ledger: ledger,
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        let running = await wakeWaitUntil {
            if case .running = await coordinator.currentState { return true }
            return false
        }
        XCTAssertTrue(running, "A session should be running before we cancel")

        await coordinator.stop()

        XCTAssertEqual(runner.runs, [candidate.id], "The candidate should have been attempted once")
        XCTAssertFalse(ledger.recorded.contains(candidate.fingerprint.value),
                       "Interrupted work must not be recorded as handled")
        let pending = await coordinator.pendingQueueIDs
        XCTAssertTrue(pending.contains(candidate.id), "Interrupted candidate must be preserved for retry")
        let offState = await coordinator.currentState
        XCTAssertEqual(offState, .off)
    }

    // MARK: - Session cap is a hard finite bound

    func testSessionCapBoundsLaunchesAndPreservesRemainder() async {
        let c1 = wakeCandidate("c1")
        let c2 = wakeCandidate("c2")
        let c3 = wakeCandidate("c3")
        let (authority, _) = makeAuthority([WakeMetricsFixture.available(fetchedAt: now)])
        let runner = StubRunner(mode: .outcome(.completed))
        let coordinator = makeCoordinator(
            bounds: boundsWithCap(2),
            authority: authority,
            candidates: StubCandidateSource(constant: [c1, c2, c3]),
            runner: runner,
            ledger: InMemoryLedger(),
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        let completed = await wakeWaitUntil { await coordinator.currentState == .completed }
        XCTAssertTrue(completed, "Watcher should complete once the cap is reached")
        XCTAssertEqual(runner.runs, [c1.id, c2.id], "Only up to the session cap may launch")
        let pending = await coordinator.pendingQueueIDs
        XCTAssertTrue(pending.contains(c3.id), "Candidates beyond the cap must be preserved")
    }

    // MARK: - Re-arm / idempotent start

    func testStartIsIdempotentAndReArmsAfterCompletion() async {
        let (authority, _) = makeAuthority([WakeMetricsFixture.available(fetchedAt: now)])
        let coordinator = makeCoordinator(
            bounds: boundsWithCap(1),
            authority: authority,
            candidates: StubCandidateSource(constant: [wakeCandidate("c1")]),
            runner: StubRunner(mode: .outcome(.completed)),
            ledger: InMemoryLedger(),
            sleeper: ImmediateSleeper()
        )

        await coordinator.start()
        await coordinator.start()   // no-op while active (single-task invariant)
        _ = await wakeWaitUntil { await coordinator.currentState == .completed }
        await coordinator.stop()
        let offState = await coordinator.currentState
        XCTAssertEqual(offState, .off)
    }
}

/// Direct coverage of the watcher-state helpers.
final class WakeWatcherStateTests: XCTestCase {
    func testIsActiveMapping() {
        XCTAssertFalse(WakeWatcherState.off.isActive)
        XCTAssertFalse(WakeWatcherState.completed.isActive)
        XCTAssertFalse(WakeWatcherState.failed("x").isActive)
        XCTAssertTrue(WakeWatcherState.armed.isActive)
        XCTAssertTrue(WakeWatcherState.scanning.isActive)
        XCTAssertTrue(WakeWatcherState.waiting(until: nil).isActive)
        XCTAssertTrue(WakeWatcherState.quotaUnknown(.notFetched).isActive)
        XCTAssertTrue(WakeWatcherState.running(candidateID: "x").isActive)
        XCTAssertTrue(WakeWatcherState.stopping.isActive)
    }
}
