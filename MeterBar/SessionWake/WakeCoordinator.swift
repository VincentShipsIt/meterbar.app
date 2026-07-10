import Foundation

/// The single native wake watcher state machine (#96).
///
/// Owns exactly one cancellable structured `Task`. Every timing-sensitive step —
/// scan, quota gate, session run, sleep — happens inside that task, and turning
/// the watcher off cancels it deterministically: ``stop()`` awaits the loop's
/// full unwind before reporting `.off`.
///
/// This is the "real coordinator" that #95's discovery/ledger and #98's
/// `SessionWakeCoordinator` UI seam are built to plug into. It consumes #95's
/// `WakeSessionCandidate`/`ReplayLedger` via the ``WakeCandidateSource`` /
/// ``WakeBlockLedger`` seams and #97's runner via ``WakeSessionRunning``.
///
/// ## Quota is fetched fresh on every cycle
/// The loop re-gates quota (a fresh account-scoped fetch) at the top of every
/// tick, so quota is proven fresh immediately before each launch and, because a
/// completed attempt falls through to the next tick, immediately after each
/// completed attempt as well. Cached UI metrics are never consulted, and a reset
/// instant that has already passed never proves availability — it just lets the
/// loop fall through to a fresh re-fetch.
///
/// ## Queue preservation
/// `queue` persists across ticks. A block, an `unknown` gate, or a session that
/// re-maxes quota all return the watcher to a wait/poll state with the remaining
/// queue intact — no work is dropped.
///
/// ## Active-child cancellation (v1 decision — see DECISIONS ADR-010)
/// When the watcher is turned off while a child session is running, the runner
/// receives cooperative cancellation and returns `.interrupted`. The in-flight
/// candidate is **not** consumed: it stays at the front of the preserved queue
/// and its fingerprint is not recorded, so a later armed run can retry it.
actor WakeCoordinator {
    private var state: WakeWatcherState = .off
    private var task: Task<Void, Never>?
    private var isStopping = false

    private var queue: [WakeSessionCandidate] = []
    private var launchedCount = 0

    private let account: ClaudeCodeAccount
    private let bounds: WakeBounds
    private let authority: WakeQuotaAuthority
    private let candidateSource: WakeCandidateSource
    private let ledger: WakeBlockLedger
    private let runner: WakeSessionRunning
    private let sleeper: WakeSleeper
    private let now: @Sendable () -> Date
    private var observer: (@Sendable (WakeWatcherState) -> Void)?

    init(
        account: ClaudeCodeAccount,
        bounds: WakeBounds = .default,
        authority: WakeQuotaAuthority,
        candidateSource: WakeCandidateSource,
        ledger: WakeBlockLedger,
        runner: WakeSessionRunning,
        sleeper: WakeSleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() },
        observer: (@Sendable (WakeWatcherState) -> Void)? = nil
    ) {
        self.account = account
        self.bounds = bounds
        self.authority = authority
        self.candidateSource = candidateSource
        self.ledger = ledger
        self.runner = runner
        self.sleeper = sleeper
        self.now = now
        self.observer = observer
    }

    // MARK: - Introspection (test + UI seams)

    var currentState: WakeWatcherState { state }
    var pendingQueueIDs: [String] { queue.map(\.id) }
    var launchedSessionCount: Int { launchedCount }

    func setObserver(_ observer: @escaping @Sendable (WakeWatcherState) -> Void) {
        self.observer = observer
    }

    // MARK: - Lifecycle

    /// Arms the watcher. No-op if a task is already running (single-task invariant).
    func start() {
        guard task == nil else { return }
        isStopping = false
        queue.removeAll()
        launchedCount = 0
        transition(.armed)
        AppLog.wake.info("Wake watcher armed for account \(self.account.id.uuidString, privacy: .public)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
            await self.loopDidExit()
        }
    }

    /// Turns the watcher off, cancelling all pending sleep/poll/run work and
    /// awaiting the loop's deterministic unwind before returning `.off`.
    func stop() async {
        guard let task else {
            transition(.off)
            return
        }
        isStopping = true
        transition(.stopping)
        task.cancel()
        await task.value
        self.task = nil
        isStopping = false
        transition(.off)
        AppLog.wake.info("Wake watcher stopped")
    }

    private func loopDidExit() {
        task = nil
        // If we exited for any reason other than an explicit stop() (which sets
        // .off itself), settle a non-terminal state back to off so a spurious
        // interruption can never leave the watcher wedged mid-cycle.
        if !isStopping, state.isActive {
            transition(.off)
        }
    }

    // MARK: - Run loop

    private func runLoop() async {
        while !Task.isCancelled {
            transition(.scanning)
            let discovered = await candidateSource.candidates(configDirectory: account.configDirectory)
            if Task.isCancelled { return }
            mergeIntoQueue(discovered)

            if queue.isEmpty {
                transition(.armed)
                if await sleeper.sleep(bounds.pollInterval) == false { return }
                continue
            }

            // Fresh quota gate — runs before every launch and (via the next
            // tick) after every completed attempt.
            let quota = await authority.currentState(accountID: account.id)
            if Task.isCancelled { return }

            switch quota {
            case .available:
                break
            case let .blocked(until, reason):
                AppLog.wake.info("Quota blocked (\(String(describing: reason), privacy: .public)); waiting")
                transition(.waiting(until: until))
                if await waitForReset(until: until) == false { return }
                continue
            case let .unknown(reason):
                AppLog.wake.info("Quota unknown (\(String(describing: reason), privacy: .public)); re-polling")
                transition(.quotaUnknown(reason))
                if await sleeper.sleep(bounds.pollInterval) == false { return }
                continue
            }

            guard let candidate = queue.first else { continue }

            if await runCandidate(candidate) == .stopLoop { return }
            if Task.isCancelled { return }

            if launchedCount >= bounds.sessionCap {
                AppLog.wake.info("Session cap reached (\(self.bounds.sessionCap)); run complete")
                transition(.completed)
                return
            }

            if await sleeper.sleep(bounds.interSessionGap) == false { return }
        }
    }

    private enum LoopStep { case stopLoop, keepGoing }

    private func runCandidate(_ candidate: WakeSessionCandidate) async -> LoopStep {
        transition(.running(candidateID: candidate.id))
        let outcome = await runner.run(
            candidate,
            maxTurns: bounds.maxTurns,
            timeout: bounds.sessionTimeout
        )

        switch outcome {
        case .interrupted:
            // Preserve the candidate at the front of the queue; do not consume
            // it or record its fingerprint. stop()/loopDidExit finalizes state.
            AppLog.wake.info("Session interrupted; candidate preserved for retry")
            return .stopLoop
        case .completed:
            await ledger.record(candidate.fingerprint)
            dequeueFront()
            launchedCount += 1
            transition(.completed)
            return .keepGoing
        case let .failed(message):
            // Consume so the queue does not spin on a persistently failing
            // candidate, but surface the failure and keep the watcher running.
            await ledger.record(candidate.fingerprint)
            dequeueFront()
            launchedCount += 1
            transition(.failed(message))
            return .keepGoing
        }
    }

    // MARK: - Helpers

    private func waitForReset(until: Date?) async -> Bool {
        guard let until else {
            return await sleeper.sleep(bounds.pollInterval)
        }
        let target = until.addingTimeInterval(bounds.resetBuffer)
        let remaining = target.timeIntervalSince(now())
        // Cap each wait at one poll interval so a system sleep/wake that pauses
        // the timer only costs one extra cycle before quota is re-proven fresh,
        // and a reset that has already passed (remaining <= 0) falls straight
        // through to a fresh re-fetch rather than proving availability.
        let chunk = Swift.min(Swift.max(remaining, 0), bounds.pollInterval)
        return await sleeper.sleep(chunk)
    }

    private func mergeIntoQueue(_ discovered: [WakeSessionCandidate]) {
        let existing = Set(queue.map(\.id))
        for candidate in discovered where !existing.contains(candidate.id) {
            queue.append(candidate)
        }
    }

    private func dequeueFront() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
    }

    private func transition(_ next: WakeWatcherState) {
        guard next != state else { return }
        state = next
        observer?(next)
    }
}
