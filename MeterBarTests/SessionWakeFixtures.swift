import Foundation
@testable import MeterBar

/// JSONL fixture builders for Session Wake tests.
///
/// Shapes mirror real Claude Code transcripts:
/// - Shape A: the current structured synthetic assistant error
///   (`"error":"rate_limit"`, `"isApiErrorMessage":true`, `apiErrorStatus:429`)
///   with a human text like "You've hit your session limit · resets 7:30am (Europe/Malta)".
/// - Shape B: the legacy synthetic text marker
///   "Claude AI usage limit reached|<unix-epoch>".
enum SessionWakeFixtures {
    static let defaultSessionID = "a8e1387f-3594-41c1-b1f1-cc7b94c6ef63"

    // MARK: - Line builders

    /// Shape A: current structured rate-limit synthetic assistant message.
    static func rateLimitLine(
        sessionID: String = defaultSessionID,
        cwd: String = "/tmp/project",
        timestamp: String = "2026-07-10T04:14:15.397Z",
        text: String = "You've hit your session limit · resets 7:30am (Europe/Malta)",
        errorField: String = "rate_limit",
        apiErrorStatus: Int = 429,
        isSidechain: Bool = false,
        gitBranch: String = "claude/test-branch"
    ) -> String {
        """
        {"parentUuid":"81c537f3-8b44-464b-825f-ede3788782b8","isSidechain":\(isSidechain),\
        "type":"assistant","uuid":"4f946454-65d3-4d7a-9108-707a53694db9","timestamp":"\(timestamp)",\
        "message":{"id":"msg_1","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence",\
        "type":"message","content":[{"type":"text","text":"\(text)"}]},\
        "requestId":"req_011Ccsj8dFKF9qszdbmxG7Ft","error":"\(errorField)","isApiErrorMessage":true,\
        "apiErrorStatus":\(apiErrorStatus),"userType":"external","cwd":"\(cwd)",\
        "sessionId":"\(sessionID)","version":"2.1.202","gitBranch":"\(gitBranch)"}
        """
    }

    /// Shape B: legacy pipe-epoch text marker. No structured error fields.
    static func legacyLimitLine(
        sessionID: String = defaultSessionID,
        cwd: String = "/tmp/project",
        timestamp: String = "2026-07-10T04:14:15Z",
        marker: String = "Claude AI usage limit reached",
        resetEpoch: Int = 1_752_130_800
    ) -> String {
        """
        {"isSidechain":false,"type":"assistant","uuid":"11946454-65d3-41c1-9108-707a53694db9",\
        "timestamp":"\(timestamp)","message":{"id":"msg_2","model":"<synthetic>","role":"assistant",\
        "type":"message","content":[{"type":"text","text":"\(marker)|\(resetEpoch)"}]},\
        "isApiErrorMessage":true,"cwd":"\(cwd)","sessionId":"\(sessionID)"}
        """
    }

    /// A successful (non-error) assistant message — decisive progress.
    static func assistantProgressLine(
        sessionID: String = defaultSessionID,
        cwd: String = "/tmp/project",
        timestamp: String = "2026-07-10T05:00:00.000Z",
        isSidechain: Bool = false,
        text: String = "Done. All tests pass."
    ) -> String {
        """
        {"isSidechain":\(isSidechain),"type":"assistant","uuid":"22946454-65d3-41c1-9108-707a53694db9",\
        "timestamp":"\(timestamp)","message":{"id":"msg_3","model":"claude-fable-5","role":"assistant",\
        "type":"message","content":[{"type":"text","text":"\(text)"}],\
        "usage":{"input_tokens":10,"output_tokens":25}},\
        "cwd":"\(cwd)","sessionId":"\(sessionID)"}
        """
    }

    /// A user line carrying a tool_result — decisive progress.
    static func userToolResultLine(
        sessionID: String = defaultSessionID,
        cwd: String = "/tmp/project",
        timestamp: String = "2026-07-10T05:01:00.000Z",
        isSidechain: Bool = false
    ) -> String {
        """
        {"isSidechain":\(isSidechain),"type":"user","uuid":"33946454-65d3-41c1-9108-707a53694db9",\
        "timestamp":"\(timestamp)","message":{"role":"user",\
        "content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]},\
        "cwd":"\(cwd)","sessionId":"\(sessionID)"}
        """
    }

    /// A plain user text message — NOT decisive (typing after a block proves nothing).
    static func userTextLine(
        sessionID: String = defaultSessionID,
        cwd: String = "/tmp/project",
        timestamp: String = "2026-07-10T05:02:00.000Z"
    ) -> String {
        """
        {"isSidechain":false,"type":"user","uuid":"44946454-65d3-41c1-9108-707a53694db9",\
        "timestamp":"\(timestamp)","message":{"role":"user","content":"are you back?"},\
        "cwd":"\(cwd)","sessionId":"\(sessionID)"}
        """
    }

    static func summaryLine() -> String {
        """
        {"type":"summary","summary":"Fixing the widget","leafUuid":"55946454-65d3-41c1-9108-707a53694db9"}
        """
    }

    // MARK: - File helpers

    static func jsonl(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func writeTranscript(
        lines: [String],
        named fileName: String,
        in projectDirectory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let url = projectDirectory.appendingPathComponent(fileName)
        try jsonl(lines).data(using: .utf8)?.write(to: url)
        return url
    }
}
