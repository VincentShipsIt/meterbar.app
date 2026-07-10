import Foundation
import MeterBarShared
@testable import MeterBar

// MARK: - Cancellation helper

/// Resumes when the surrounding task is cancelled. Used by the blocking sleeper
/// and the block-until-cancelled runner to model a genuinely pending suspension
/// that `WakeCoordinator.stop()` must cancel deterministically.
final class WakeCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        continuation?.resume()
        continuation = nil
    }
}

func suspendUntilCancelled() async {
    let box = WakeCancellationBox()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            box.park(continuation)
        }
    } onCancel: {
        box.cancel()
    }
}

// MARK: - Quota fetcher

/// Returns a scripted sequence of fetch outcomes, repeating the last element.
final class ScriptedQuotaFetcher: WakeQuotaFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [WakeQuotaFetch]
    private(set) var callCount = 0

    init(_ outcomes: [WakeQuotaFetch]) {
        self.outcomes = outcomes
    }

    func fetchFreshQuota(accountID: UUID) async -> WakeQuotaFetch {
        await Task.yield()
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if outcomes.count > 1 {
            return outcomes.removeFirst()
        }
        return outcomes.first ?? .failure("no scripted outcome")
    }
}

enum WakeMetricsFixture {
    static func available(fetchedAt: Date) -> WakeQuotaFetch {
        .success(
            UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil)
            ),
            fetchedAt: fetchedAt
        )
    }

    static func blocked(fetchedAt: Date, until: Date?) -> WakeQuotaFetch {
        .success(
            UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 100, total: 100, resetTime: until)
            ),
            fetchedAt: fetchedAt
        )
    }
}

// MARK: - Candidate source (adapts #95 discovery seam)

final class StubCandidateSource: WakeCandidateSource, @unchecked Sendable {
    private let lock = NSLock()
    private var perCall: [[WakeSessionCandidate]]
    private(set) var callCount = 0

    init(_ perCall: [[WakeSessionCandidate]]) {
        self.perCall = perCall
    }

    convenience init(constant candidates: [WakeSessionCandidate]) {
        self.init([candidates])
    }

    func candidates(configDirectory: String?) async -> [WakeSessionCandidate] {
        await Task.yield()
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if perCall.count > 1 {
            return perCall.removeFirst()
        }
        return perCall.first ?? []
    }
}

// MARK: - Runner

final class StubRunner: WakeSessionRunning, @unchecked Sendable {
    enum Mode {
        case outcome(WakeRunOutcome)
        case blockUntilCancelled
    }

    private let lock = NSLock()
    private let mode: Mode
    private var recorded: [String] = []
    private let onStarted: (@Sendable () -> Void)?

    init(mode: Mode, onStarted: (@Sendable () -> Void)? = nil) {
        self.mode = mode
        self.onStarted = onStarted
    }

    var runs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ candidate: WakeSessionCandidate, maxTurns: Int, timeout: TimeInterval) async -> WakeRunOutcome {
        lock.lock()
        recorded.append(candidate.id)
        lock.unlock()
        onStarted?()

        switch mode {
        case let .outcome(outcome):
            await Task.yield()
            return outcome
        case .blockUntilCancelled:
            await suspendUntilCancelled()
            return .interrupted
        }
    }
}

// MARK: - Ledger

final class InMemoryLedger: WakeBlockLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: Set<String> = []

    var recorded: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ fingerprint: BlockFingerprint) async {
        lock.lock()
        defer { lock.unlock() }
        recordedValues.insert(fingerprint.value)
    }
}

// MARK: - Sleepers

/// Returns immediately, recording each requested duration. Honors cancellation.
final class ImmediateSleeper: WakeSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var durations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sleep(_ seconds: TimeInterval) async -> Bool {
        lock.lock()
        recorded.append(seconds)
        lock.unlock()
        await Task.yield()
        return !Task.isCancelled
    }
}

/// Suspends until the surrounding task is cancelled, then returns `false`.
/// Models a genuinely pending sleep so cancellation can be asserted.
final class BlockingSleeper: WakeSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func sleep(_ seconds: TimeInterval) async -> Bool {
        await suspendUntilCancelled()
        lock.lock()
        cancelledFlag = true
        lock.unlock()
        return false
    }
}

// MARK: - Observer

final class WakeStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [WakeWatcherState] = []

    var observer: @Sendable (WakeWatcherState) -> Void {
        { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.states.append(state)
            self.lock.unlock()
        }
    }

    var recorded: [WakeWatcherState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

// MARK: - Async polling helper

/// Polls `condition` until it holds or `timeout` elapses. Uses wall-clock
/// `Date()` (test-only) rather than any injected clock.
func wakeWaitUntil(
    timeout: TimeInterval = 3,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

// MARK: - Candidate factory (builds a real #95 candidate)

func wakeCandidate(
    _ session: String,
    reason: WakeBlockReason = .sessionLimit,
    blockedAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000)
) -> WakeSessionCandidate {
    WakeSessionCandidate(
        sessionID: session,
        transcriptPath: "/tmp/\(session).jsonl",
        workingDirectory: "/tmp/\(session)",
        gitBranch: nil,
        reason: reason,
        blockedAt: blockedAt,
        resetHint: nil,
        fingerprint: BlockFingerprint(sessionID: session, blockedAt: blockedAt, reason: reason),
        skipReason: nil
    )
}

func wakeTestAccount() -> ClaudeCodeAccount {
    ClaudeCodeAccount(id: UUID(), name: "Wake Test", configDirectory: nil)
}
