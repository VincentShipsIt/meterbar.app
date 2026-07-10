import Foundation

/// Terminal outcome of a single session run.
enum WakeRunOutcome: Equatable, Sendable {
    /// The session ran to completion; record its block fingerprint in the ledger.
    case completed
    /// The session failed; it is consumed (its fingerprint recorded) so the
    /// queue does not spin on it, and the watcher continues to the next.
    case failed(String)
    /// The run was cancelled mid-flight (watcher turned off). The candidate is
    /// **not** consumed — it stays at the front of the preserved queue and its
    /// fingerprint is not recorded, so a later armed run can retry it.
    case interrupted
}

/// Runs one session with the per-session guards. Implemented by #97's safe
/// process runner. Implementations MUST observe task cancellation and terminate
/// the child cooperatively, returning `.interrupted`.
protocol WakeSessionRunning: Sendable {
    func run(_ candidate: WakeSessionCandidate, maxTurns: Int, timeout: TimeInterval) async -> WakeRunOutcome
}

/// Account-scoped source of currently-eligible resume candidates. The seam over
/// #95's `SessionDiscovery`; implementations MUST be read-only (Preview/dry-run
/// performs zero mutation) and return only executable candidates.
protocol WakeCandidateSource: Sendable {
    func candidates(configDirectory: String?) async -> [WakeSessionCandidate]
}

/// Records a handled block so it is never resumed again. The seam over #95's
/// `ReplayLedger`.
protocol WakeBlockLedger: Sendable {
    func record(_ fingerprint: BlockFingerprint) async
}

/// Cancellable delay primitive. Injected so the coordinator's timing is
/// deterministic under test and its sleeps are provably cancellable.
protocol WakeSleeper: Sendable {
    /// Sleeps for `seconds`. Returns `false` if the surrounding task was
    /// cancelled (before or during the wait), `true` if it elapsed normally.
    func sleep(_ seconds: TimeInterval) async -> Bool
}

/// Production sleeper. Uses `Task.sleep`, which throws `CancellationError` on
/// cancellation — mapped to a `false` return. Waits are driven in
/// poll-interval-bounded chunks by the coordinator, so a system sleep/wake that
/// pauses the timer only delays the next fresh re-fetch by at most one chunk
/// rather than silently over-trusting a long timer.
struct TaskSleeper: WakeSleeper {
    func sleep(_ seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Adapters over #95's concrete discovery/ledger

/// Adapts #95's `SessionDiscovery` actor to the ``WakeCandidateSource`` seam,
/// keeping only executable candidates (skipped/preview-only ones never launch).
struct DiscoveryCandidateSource: WakeCandidateSource {
    let discovery: SessionDiscovery
    let ledger: ReplayLedger

    func candidates(configDirectory: String?) async -> [WakeSessionCandidate] {
        await discovery
            .discover(configDirectory: configDirectory, ledger: ledger)
            .filter(\.isExecutable)
    }
}

/// Adapts #95's `ReplayLedger` actor to the ``WakeBlockLedger`` seam.
struct ReplayLedgerRecorder: WakeBlockLedger {
    let ledger: ReplayLedger

    func record(_ fingerprint: BlockFingerprint) async {
        await ledger.record(fingerprint)
    }
}
