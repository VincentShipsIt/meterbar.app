import Foundation

/// Validated numeric bounds for the Session Wake watcher (issue #96).
///
/// Every value is clamped into a conservative, documented range at
/// initialization, so an out-of-range or non-finite preference can never widen a
/// safety window. Two invariants are enforced structurally rather than by
/// convention:
///
/// - **Unlimited sessions are never representable.** `sessionCap` always
///   resolves to a finite value in `sessionCapRange`. The PRD's historical
///   "0 = all" default is deliberately *not* honored — epic #94 requires that
///   unlimited never be the default (see ``default``).
/// - **Every guard is finite and positive.** `maxTurns`, `sessionTimeout`, and
///   `pollInterval` cannot be zero or negative, so a session can neither run
///   turn-unbounded nor spin the poll loop with a zero delay.
struct WakeBounds: Equatable, Sendable {
    /// How often the watcher re-scans and re-polls quota while idle or waiting.
    let pollInterval: TimeInterval
    /// Extra delay added *after* a quota reset before re-fetching, so the
    /// watcher never launches on the exact reset boundary while the server is
    /// still settling. Matches the PRD's 90 s default buffer.
    let resetBuffer: TimeInterval
    /// Minimum gap enforced between two consecutive session launches.
    let interSessionGap: TimeInterval
    /// Hard wall-clock timeout for a single session run, handed to the runner.
    let sessionTimeout: TimeInterval
    /// Per-session max-turns guard handed to the runner, in addition to the
    /// timeout. Bounds runaway agent loops that stay under the wall-clock limit.
    let maxTurns: Int
    /// Maximum number of sessions the watcher will launch in one armed run.
    /// Finite by construction — this is the "conservative bounded default"
    /// required by #96, replacing the PRD's unbounded "resume all".
    let sessionCap: Int

    // MARK: Documented, enforced ranges

    static let pollIntervalRange: ClosedRange<TimeInterval> = 15...3_600
    static let resetBufferRange: ClosedRange<TimeInterval> = 0...900
    static let interSessionGapRange: ClosedRange<TimeInterval> = 0...3_600
    static let sessionTimeoutRange: ClosedRange<TimeInterval> = 30...14_400
    static let maxTurnsRange: ClosedRange<Int> = 1...500
    static let sessionCapRange: ClosedRange<Int> = 1...200

    /// Conservative defaults. Values mirror the PRD (poll 60 s, buffer 90 s,
    /// gap 20 s, timeout 7200 s) except `sessionCap`, which is a finite ceiling
    /// (25) rather than the PRD's unlimited default, and `maxTurns` (40), which
    /// the PRD did not specify but #96 requires.
    static let `default` = WakeBounds(
        pollInterval: 60,
        resetBuffer: 90,
        interSessionGap: 20,
        sessionTimeout: 7_200,
        maxTurns: 40,
        sessionCap: 25
    )

    init(
        pollInterval: TimeInterval,
        resetBuffer: TimeInterval,
        interSessionGap: TimeInterval,
        sessionTimeout: TimeInterval,
        maxTurns: Int,
        sessionCap: Int
    ) {
        self.pollInterval = Self.pollIntervalRange.clamping(pollInterval)
        self.resetBuffer = Self.resetBufferRange.clamping(resetBuffer)
        self.interSessionGap = Self.interSessionGapRange.clamping(interSessionGap)
        self.sessionTimeout = Self.sessionTimeoutRange.clamping(sessionTimeout)
        self.maxTurns = Self.maxTurnsRange.clamping(maxTurns)
        self.sessionCap = Self.sessionCapRange.clamping(sessionCap)
    }
}

extension ClosedRange where Bound == TimeInterval {
    /// Clamps `value` into the range. Non-finite input (NaN / ±∞) resolves to
    /// the lower bound so a corrupt preference always fails to the safe side.
    func clamping(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
