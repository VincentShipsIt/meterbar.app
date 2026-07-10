import Foundation

/// Why the quota authority could not *prove* availability. Every case fails
/// closed: the watcher launches nothing while quota is `unknown` (#96).
enum WakeQuotaUnknownReason: Equatable, Sendable {
    /// No fetch has happened yet this gate cycle.
    case notFetched
    /// A fetch succeeded but is older than the freshness window. `age` is the
    /// measured staleness in seconds (may be negative if the clock moved back).
    case stale(age: TimeInterval)
    /// The fresh fetch failed (CLI error, timeout, parse failure).
    case fetchFailed(String)
    /// The fetch returned but its shape is ambiguous (no usable windows).
    case ambiguous(String)
    /// The account is not authenticated (missing/invalid OAuth). Fails closed
    /// so a missing login can never make quota fail open, and can never keep a
    /// stale transcript permanently "blocked" — it is re-evaluated each cycle.
    case missingAuthorization
}

/// The single source of execution authority for a wake account.
///
/// The block `reason` reuses discovery's `WakeBlockReason` (#95) so the whole
/// pipeline shares one typed vocabulary for *why* a window is closed. Cached UI
/// metrics are never mapped to this type — only a freshly fetched,
/// freshness-checked result is (see ``WakeQuotaAuthority``).
enum WakeQuotaState: Equatable, Sendable {
    /// Fresh quota proves at least one launch is permitted right now.
    case available
    /// A hard window is exhausted. `until` is the absolute reset (nil when the
    /// reset time is itself unknown — the watcher then re-polls conservatively).
    case blocked(until: Date?, reason: WakeBlockReason)
    /// Availability cannot be proven; nothing launches.
    case unknown(reason: WakeQuotaUnknownReason)

    /// The only state that authorizes a launch. `blocked` and `unknown` both
    /// return `false` — the gate is fail-closed.
    var permitsLaunch: Bool {
        if case .available = self { return true }
        return false
    }
}
