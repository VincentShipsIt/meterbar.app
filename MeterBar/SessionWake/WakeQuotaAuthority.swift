import Foundation
import MeterBarShared

/// Outcome of a single fresh, account-scoped quota fetch. Deliberately distinct
/// from `UsageMetrics` so the authority can distinguish "no auth" from "fetch
/// failed" from "got data" and fail closed in every non-success case.
enum WakeQuotaFetch: Sendable {
    /// Fresh metrics plus the wall-clock instant they were fetched.
    case success(UsageMetrics, fetchedAt: Date)
    /// The account is not authenticated (missing/invalid OAuth login).
    case unauthorized
    /// The fetch itself failed (CLI not found, timeout, non-zero exit, parse).
    case failure(String)
}

/// Fetches fresh quota for one account. The seam over the concrete CLI service,
/// so the authority and coordinator are testable without spawning `claude`.
protocol WakeQuotaFetching: Sendable {
    func fetchFreshQuota(accountID: UUID) async -> WakeQuotaFetch
}

/// Pure decision logic mapping a fetch outcome to a ``WakeQuotaState``.
///
/// Fail-closed by construction: only a fresh, unambiguous `success` with at
/// least one usable window and no exhausted hard window yields `.available`.
struct WakeQuotaEvaluator: Sendable {
    /// Fetched metrics older than this (relative to `now`) are treated as stale
    /// and yield `unknown`. Also rejects fetches dated in the future by the same
    /// magnitude (a clock that jumped backwards).
    let freshnessWindow: TimeInterval

    init(freshnessWindow: TimeInterval = 90) {
        self.freshnessWindow = Swift.max(1, freshnessWindow)
    }

    func evaluate(_ fetch: WakeQuotaFetch, now: Date) -> WakeQuotaState {
        switch fetch {
        case .unauthorized:
            return .unknown(reason: .missingAuthorization)
        case let .failure(message):
            return .unknown(reason: .fetchFailed(message))
        case let .success(metrics, fetchedAt):
            let age = now.timeIntervalSince(fetchedAt)
            guard abs(age) <= freshnessWindow else {
                return .unknown(reason: .stale(age: age))
            }
            guard metrics.hasData else {
                return .unknown(reason: .ambiguous("No quota windows present"))
            }
            return classify(metrics)
        }
    }

    /// Gates every hard blocking window. If any window is at-limit the gate is
    /// closed; the reported `until`/`reason` come from the exhausted window with
    /// the farthest reset (an unknown reset counts as farthest — most
    /// conservative), so an exhausted weekly/model cap blocks a launch even when
    /// the 5-hour session window is open.
    private func classify(_ metrics: UsageMetrics) -> WakeQuotaState {
        let windows: [(limit: UsageLimit?, reason: WakeBlockReason)] = [
            (metrics.sessionLimit, .sessionLimit),
            (metrics.weeklyLimit, .weeklyLimit),
            (metrics.codeReviewLimit, .modelWeeklyLimit)
        ]

        let exhausted = windows.compactMap { window -> (until: Date?, reason: WakeBlockReason)? in
            guard let limit = window.limit, limit.isAtLimit else { return nil }
            return (limit.resetTime, window.reason)
        }

        guard let farthest = exhausted.max(by: { lhs, rhs in
            (lhs.until ?? .distantFuture) < (rhs.until ?? .distantFuture)
        }) else {
            return .available
        }
        return .blocked(until: farthest.until, reason: farthest.reason)
    }
}

/// The account-scoped quota authority. Combines a fresh fetch with the pure
/// evaluator. Every call performs a *new* fetch — callers must invoke it
/// immediately before each launch and after each completed attempt so cached UI
/// metrics are never used as execution authority.
struct WakeQuotaAuthority: Sendable {
    let fetcher: WakeQuotaFetching
    let evaluator: WakeQuotaEvaluator
    let now: @Sendable () -> Date

    init(
        fetcher: WakeQuotaFetching,
        evaluator: WakeQuotaEvaluator = WakeQuotaEvaluator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.evaluator = evaluator
        self.now = now
    }

    func currentState(accountID: UUID) async -> WakeQuotaState {
        let fetch = await fetcher.fetchFreshQuota(accountID: accountID)
        return evaluator.evaluate(fetch, now: now())
    }
}

/// Concrete fetcher backed by `ClaudeCodeCLIUsageService`. Runs the CLI fresh
/// against the selected account's `CLAUDE_CONFIG_DIR` and stamps the fetch time.
struct ClaudeCLIQuotaFetcher: WakeQuotaFetching {
    let service: ClaudeCodeCLIUsageService
    /// Resolves a wake account id to its profile. Injected so the fetcher stays
    /// account-scoped and never reads another account.
    let accountLookup: @Sendable (UUID) -> ClaudeCodeAccount?

    init(
        service: ClaudeCodeCLIUsageService = .shared,
        accountLookup: @escaping @Sendable (UUID) -> ClaudeCodeAccount?
    ) {
        self.service = service
        self.accountLookup = accountLookup
    }

    func fetchFreshQuota(accountID: UUID) async -> WakeQuotaFetch {
        guard let account = accountLookup(accountID) else {
            return .failure("No wake account resolved for \(accountID.uuidString)")
        }
        do {
            let metrics = try await service.fetchUsageMetrics(account: account)
            return .success(metrics, fetchedAt: Date())
        } catch {
            if Self.looksLikeAuthorizationFailure(error) {
                return .unauthorized
            }
            return .failure(error.localizedDescription)
        }
    }

    /// Heuristic mapping of a CLI failure to "not logged in". Precision is not
    /// safety-critical: both `.unauthorized` and `.failure` fail closed to
    /// `unknown`. This only sharpens the surfaced reason for the UI.
    static func looksLikeAuthorizationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let markers = [
            "log in", "login", "logged out", "not authenticated",
            "unauthorized", "authenticate", "/login", "oauth"
        ]
        return markers.contains { message.contains($0) }
    }
}
