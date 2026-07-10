import Foundation

/// Classifies the tail of a Claude Code transcript (JSONL) into a terminal
/// state using latest-decisive-event semantics — not "contains rate limit".
///
/// Decisive events, newest wins:
/// - A rate-limit synthetic assistant message → `.blocked`
///   - Shape A (current): `"isApiErrorMessage":true` with `"error":"rate_limit"`
///     or `"apiErrorStatus":429`
///   - Shape B (legacy): assistant text "… usage limit reached|<unix-epoch>"
/// - Successful assistant output or a user tool_result → `.progressed`
///
/// Sidechain (subagent) lines never classify the session. Malformed or
/// truncated lines are skipped; they can neither crash nor poison the scan.
enum ClaudeTranscriptTailClassifier {
    struct ParsedReset: Equatable {
        let date: Date
        let isApproximate: Bool
    }

    // MARK: - Classification

    static func classify(jsonl: String) -> ClaudeTranscriptTailSummary {
        var summary = ClaudeTranscriptTailSummary()
        var eventCount = 0
        var sidechainCount = 0

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let json = object as? [String: Any],
                  let type = json["type"] as? String,
                  type == "assistant" || type == "user" else {
                continue
            }

            eventCount += 1
            if json["isSidechain"] as? Bool == true {
                sidechainCount += 1
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap(FlexibleISO8601.date(from:))
            updateMetadata(in: &summary, from: json, timestamp: timestamp)

            if let event = blockEvent(from: json, type: type, timestamp: timestamp) {
                summary.terminalState = .blocked(event)
            } else if isDecisiveProgress(json: json, type: type) {
                summary.terminalState = .progressed(lastActivityAt: timestamp)
            }
        }

        if eventCount > 0 && sidechainCount == eventCount {
            summary.isSubagentTranscript = true
            summary.terminalState = .indeterminate
        }
        return summary
    }

    // MARK: - Reset parsing

    /// Parses an absolute reset timestamp out of a rate-limit message text.
    ///
    /// Supported forms:
    /// - Legacy exact epoch: "… usage limit reached|1752130800"
    /// - Time-of-day fallback: "resets 7:30am (Europe/Malta)", "resets 19:00"
    /// - Month-day fallback: "resets Jul 15 at 10pm (Europe/Malta)"
    ///
    /// Fallback forms are anchored to the rate-limit **event** timestamp (never
    /// "now"), so a reset that has just passed at scan time is not rolled to
    /// tomorrow. They are flagged approximate: transcript text may schedule a
    /// refresh but can never prove quota is available.
    static func resetDate(fromMessageText text: String, anchoredTo eventDate: Date) -> ParsedReset? {
        if let epochDate = legacyEpochReset(in: text) {
            return ParsedReset(date: epochDate, isApproximate: false)
        }
        guard let match = Self.resetsClauseRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else {
            return nil
        }

        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }

        guard var hour = group("hour").flatMap({ Int($0) }) else { return nil }
        let minute = group("minute").flatMap { Int($0) } ?? 0
        if let meridiem = group("ampm")?.lowercased() {
            hour %= 12
            if meridiem == "pm" { hour += 12 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        if let zoneName = group("zone"), let zone = TimeZone(identifier: zoneName) {
            calendar.timeZone = zone
        }

        var components = calendar.dateComponents([.year, .month, .day], from: eventDate)
        components.hour = hour
        components.minute = minute
        components.second = 0

        let explicitMonth = group("month").flatMap { monthNumber(fromAbbreviation: $0) }
        if let explicitMonth {
            components.month = explicitMonth
            components.day = group("day").flatMap { Int($0) }
            if let year = group("year").flatMap({ Int($0) }) {
                components.year = year
            }
        }

        guard var resolved = calendar.date(from: components) else { return nil }
        if resolved < eventDate {
            // The block always precedes its reset. A time-of-day earlier than
            // the event means the next day; an explicit month-day earlier than
            // the event means the next year (December → January windows).
            let unit: Calendar.Component = explicitMonth == nil ? .day : .year
            guard let rolled = calendar.date(byAdding: unit, value: 1, to: resolved) else { return nil }
            resolved = rolled
        }
        return ParsedReset(date: resolved, isApproximate: true)
    }

    // MARK: - Private

    private static func updateMetadata(
        in summary: inout ClaudeTranscriptTailSummary,
        from json: [String: Any],
        timestamp: Date?
    ) {
        if let sessionID = nonEmptyString(json["sessionId"]) {
            summary.sessionID = sessionID
        }
        if let cwd = nonEmptyString(json["cwd"]) {
            summary.workingDirectory = cwd
        }
        if let branch = nonEmptyString(json["gitBranch"]) {
            summary.gitBranch = branch
        }
        if let timestamp, summary.lastEventAt.map({ timestamp > $0 }) ?? true {
            summary.lastEventAt = timestamp
        }
    }

    private static func blockEvent(from json: [String: Any], type: String, timestamp: Date?) -> SessionBlockEvent? {
        guard type == "assistant", let blockedAt = timestamp else { return nil }
        let text = messageText(in: json)

        let isStructuredRateLimit = json["isApiErrorMessage"] as? Bool == true
            && ((json["error"] as? String)?.lowercased() == "rate_limit" || json["apiErrorStatus"] as? Int == 429)
        let isLegacyMarker = legacyEpochReset(in: text) != nil
            || text.range(of: #"usage limit reached\|"#, options: [.regularExpression, .caseInsensitive]) != nil

        guard isStructuredRateLimit || isLegacyMarker else { return nil }

        let reset = resetDate(fromMessageText: text, anchoredTo: blockedAt)
        return SessionBlockEvent(
            reason: blockReason(fromMessageText: text),
            blockedAt: blockedAt,
            resetAt: reset?.date,
            resetIsApproximate: reset?.isApproximate ?? false
        )
    }

    private static func isDecisiveProgress(json: [String: Any], type: String) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        if type == "assistant" {
            // Any non-error assistant output is real forward progress. Other
            // API errors (e.g. 500s) are neither progress nor a block.
            return json["isApiErrorMessage"] as? Bool != true
        }
        // A user line only counts when it carries tool results — plain user
        // text after a block proves nothing about quota.
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "tool_result" }
    }

    private static func blockReason(fromMessageText text: String) -> SessionBlockReason {
        let lowercased = text.lowercased()
        if lowercased.contains("opus"), lowercased.contains("weekly") {
            return .opusWeeklyLimit
        }
        if lowercased.contains("weekly limit") {
            return .weeklyLimit
        }
        if lowercased.contains("session limit") {
            return .sessionLimit
        }
        return .unknownRateLimit
    }

    private static func messageText(in json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String {
            return text
        }
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        let texts: [String] = content.compactMap { item in
            item["type"] as? String == "text" ? item["text"] as? String : nil
        }
        return texts.joined(separator: "\n")
    }

    private static func legacyEpochReset(in text: String) -> Date? {
        guard let match = Self.legacyEpochRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let epoch = TimeInterval(text[range]) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    private static func monthNumber(fromAbbreviation value: String) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: String(value.lowercased().prefix(3))) else { return nil }
        return index + 1
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // Compiled once; NSRegularExpression is thread-safe.
    private static let legacyEpochRegex: NSRegularExpression = {
        // "usage limit reached|1752130800" — 9-12 digits covers 2001-2286.
        (try? NSRegularExpression(
            pattern: #"usage limit reached\|(\d{9,12})"#,
            options: [.caseInsensitive]
        )) ?? NSRegularExpression()
    }()

    private static let resetsClauseRegex: NSRegularExpression = {
        let pattern = #"resets\s+"# +
            #"(?:(?<month>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+"# +
            #"(?<day>\d{1,2})(?:,\s*(?<year>\d{4}))?\s+at\s+)?"# +
            #"(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<ampm>am|pm)?"# +
            #"(?:\s*\((?<zone>[^)]+)\))?"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()
    }()
}
