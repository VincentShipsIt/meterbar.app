import Foundation

/// The observable states of the single native wake watcher (#96).
///
/// There is exactly one state machine and one cancellable structured task
/// (owned by ``WakeCoordinator``). Every listed state maps to a concrete point
/// in the run loop, so the UI (#98) can render an unambiguous status chip.
enum WakeWatcherState: Equatable, Sendable {
    /// Watcher disabled. No task running, no pending sleep/poll work.
    case off
    /// Enabled and idle — armed, waiting for the next poll to re-scan.
    case armed
    /// Scanning the account for eligible candidates.
    case scanning
    /// A hard quota window is exhausted; waiting until `until` (or re-polling on
    /// the poll interval when the reset instant is unknown).
    case waiting(until: Date?)
    /// Quota freshness could not be proven; nothing launches and the watcher
    /// re-polls. Distinct from `waiting` so the UI can flag a soft failure.
    case quotaUnknown(WakeQuotaUnknownReason)
    /// A session is actively running.
    case running(candidateID: String)
    /// Stopping in response to a user turning the watcher off; the in-flight
    /// task is being cancelled and unwound deterministically.
    case stopping
    /// The armed run finished all eligible work (or hit the session cap).
    case completed
    /// The run loop failed unrecoverably.
    case failed(String)

    /// Whether the watcher currently owns a live structured task. `off` and the
    /// terminal `completed`/`failed` states do not.
    var isActive: Bool {
        switch self {
        case .off, .completed, .failed:
            return false
        case .armed, .scanning, .waiting, .quotaUnknown, .running, .stopping:
            return true
        }
    }
}
