import Foundation

// MARK: - Block reason

/// Typed reason a Claude Code session stopped on a rate limit (issue #95).
enum SessionBlockReason: String, Codable, Sendable {
    case sessionLimit
    case weeklyLimit
    case opusWeeklyLimit
    case unknownRateLimit
}

// MARK: - Block event

/// A single blocking rate-limit event with absolute timestamps.
///
/// `resetIsApproximate` is true when `resetAt` was derived from human-facing
/// transcript text (a time-of-day fallback). Per the Session Wake epic, such a
/// fallback may schedule a refresh but can never prove quota is available —
/// downstream consumers (#96) must re-fetch fresh quota before acting.
struct SessionBlockEvent: Equatable, Sendable {
    let reason: SessionBlockReason
    let blockedAt: Date
    let resetAt: Date?
    let resetIsApproximate: Bool
}

// MARK: - Terminal state

/// Latest-decisive-event classification of a transcript tail. A historical
/// rate limit followed by later successful assistant/tool activity classifies
/// as `.progressed`, never `.blocked`.
enum SessionTerminalState: Equatable, Sendable {
    case blocked(SessionBlockEvent)
    case progressed(lastActivityAt: Date?)
    case indeterminate
}

/// Everything the classifier could extract from a transcript tail.
struct ClaudeTranscriptTailSummary: Equatable, Sendable {
    var terminalState: SessionTerminalState = .indeterminate
    var sessionID: String?
    var workingDirectory: String?
    var gitBranch: String?
    var isSubagentTranscript = false
    var lastEventAt: Date?
}

// MARK: - Eligibility

/// Structured reason a discovered block is preview-only instead of eligible
/// for automatic wake.
enum SessionWakeSkipReason: Equatable, Sendable {
    /// The blocking event/window is historical; only the current window is
    /// automatically eligible.
    case staleBlock
    /// The session's original cwd (project/worktree) no longer exists. The
    /// associated value is the raw path recorded in the transcript.
    case missingWorkingDirectory(String)
    /// The transcript lacks the metadata needed to act on it (e.g. no cwd).
    case missingMetadata
}

enum SessionWakeEligibility: Equatable, Sendable {
    case eligible
    case previewOnly(SessionWakeSkipReason)
}

// MARK: - Candidate

/// A discovered blocked session. Strictly a description — discovery never
/// mutates anything; acting on a candidate is later work (#96/#97).
struct BlockedSessionCandidate: Equatable, Identifiable, Sendable {
    var id: String { fingerprint }

    let sessionID: String
    let transcriptURL: URL
    /// Canonicalized (standardized, symlink-resolved) original project or
    /// worktree directory. Nil when the directory is missing — a dead cwd
    /// must never surface as an executable target.
    let projectDirectory: String?
    let gitBranch: String?
    let blockEvent: SessionBlockEvent
    let fingerprint: String
    let eligibility: SessionWakeEligibility
}
