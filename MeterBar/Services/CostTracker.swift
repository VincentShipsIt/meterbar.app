import Combine
import Foundation
import SQLite3

@MainActor
class CostTracker: ObservableObject {
    static let shared = CostTracker()

    @Published var costSummary: CostSummary?
    @Published var isScanning: Bool = false
    @Published var lastScanDate: Date?

    // API-rate estimates per million tokens for local log usage.
    private let pricing: [String: TokenPricing] = [
        "claude-sonnet": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-opus": TokenPricing(input: 15.0, output: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-haiku": TokenPricing(input: 0.25, output: 1.25, cacheCreation: 0.30, cacheRead: 0.03),
        "claude-fable-5": TokenPricing(input: 10.0, output: 50.0, cacheCreation: 12.5, cacheRead: 1.0, cacheCreationOneHour: 20.0),
        "claude-opus-4-8": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-7": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-6": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-sonnet-4-6": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4-5": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-haiku-4-5": TokenPricing(input: 1.0, output: 5.0, cacheCreation: 1.25, cacheRead: 0.10, cacheCreationOneHour: 2.0),
        "codex": TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
        "default": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
    ]

    private init() {}

    func scanCosts(days: Int = 30) async {
        isScanning = true
        defer { isScanning = false }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var allCosts: [TokenCost] = []
        var dailyUsage: [DailyTokenUsage] = []

        // Scan Claude Code sessions
        if let (claudeCost, claudeDailyUsage) = scanClaudeCodeSessions(since: cutoffDate) {
            allCosts.append(claudeCost)
            dailyUsage.append(contentsOf: claudeDailyUsage)
        }

        if let (codexCost, codexDailyUsage) = scanCodexSessions(since: cutoffDate) {
            allCosts.append(codexCost)
            dailyUsage.append(contentsOf: codexDailyUsage)
        }

        // Calculate summary
        let totalCost = allCosts.reduce(0) { $0 + $1.estimatedCostUSD }
        let totalTokens = allCosts.reduce(0) { $0 + $1.totalTokens }

        costSummary = CostSummary(
            costs: allCosts,
            totalCostUSD: totalCost,
            totalTokens: totalTokens,
            periodDays: days,
            dailyUsage: dailyUsage.sorted { $0.date < $1.date }
        )
        lastScanDate = Date()
    }

    private func scanClaudeCodeSessions(since cutoffDate: Date) -> (TokenCost, [DailyTokenUsage])? {
        let projectRoots = claudeProjectRoots()
        guard !projectRoots.isEmpty else { return nil }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var totalEstimatedCost = 0.0
        var sessionCount = 0
        var earliestDate = Date()
        var latestDate = cutoffDate
        var dailyTotals: [Date: TokenAccumulator] = [:]

        for root in projectRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                if url.lastPathComponent == "subagents" {
                    enumerator.skipDescendants()
                    continue
                }

                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modificationDate = values.contentModificationDate,
                      modificationDate >= cutoffDate else {
                    continue
                }

                let (input, output, cacheCreate, cacheReadTokens, estimatedCost, dates, daily) = parseSessionFile(
                    at: url,
                    since: cutoffDate
                )

                if input > 0 || output > 0 || cacheCreate > 0 || cacheReadTokens > 0 {
                    totalInput += input
                    totalOutput += output
                    totalCacheCreation += cacheCreate
                    totalCacheRead += cacheReadTokens
                    totalEstimatedCost += estimatedCost
                    sessionCount += 1
                    mergeDailyTotals(&dailyTotals, with: daily)

                    if let minDate = dates.min(), minDate < earliestDate {
                        earliestDate = minDate
                    }
                    if let maxDate = dates.max(), maxDate > latestDate {
                        latestDate = maxDate
                    }
                }
            }
        }

        guard totalInput > 0 || totalOutput > 0 || totalCacheCreation > 0 || totalCacheRead > 0 else { return nil }

        let pricing = self.pricing["claude-sonnet"] ?? self.pricing["default"]!
        let fallbackCost = calculateCost(
            input: totalInput,
            output: totalOutput,
            cacheCreation: totalCacheCreation,
            cacheRead: totalCacheRead,
            pricing: pricing
        )
        let cost = totalEstimatedCost > 0 ? totalEstimatedCost : fallbackCost

        return (TokenCost(
            provider: .claudeCode,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead,
            estimatedCostUSD: cost,
            sessionCount: sessionCount,
            periodStart: earliestDate,
            periodEnd: latestDate
        ), makeDailyUsage(from: dailyTotals, provider: .claudeCode, pricing: pricing))
    }

    private func claudeProjectRoots() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            roots.append(contentsOf: env.split(separator: ",").map { part in
                claudeProjectsURL(forConfigPath: String(part))
            })
        }

        roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))

        for account in ClaudeCodeAccountStore.shared.accounts {
            guard let configDirectory = account.configDirectory else { continue }
            roots.append(claudeProjectsURL(forConfigPath: configDirectory))
        }

        if let homeEntries = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for entry in homeEntries where entry.lastPathComponent.hasPrefix(".claude-") {
                roots.append(entry.appendingPathComponent("projects", isDirectory: true))
            }
        }

        var seen = Set<String>()
        return roots.compactMap { url in
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    private func claudeProjectsURL(forConfigPath rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: (trimmed as NSString).standardizingPath)
        if url.lastPathComponent == "projects" {
            return url
        }
        return url.appendingPathComponent("projects", isDirectory: true)
    }

    private func parseSessionFile(
        at url: URL,
        since cutoffDate: Date
    ) -> (
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        estimatedCost: Double,
        dates: [Date],
        daily: [Date: TokenAccumulator]
    ) {
        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var totalEstimatedCost = 0.0
        var dates: [Date] = []
        var dailyTotals: [Date: TokenAccumulator] = [:]
        var keyedEvents: [String: ClaudeUsageEvent] = [:]
        var unkeyedEvents: [ClaudeUsageEvent] = []

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return (0, 0, 0, 0, 0, [], [:])
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let timestampStr = json["timestamp"] as? String,
                  let timestamp = parseISO8601(timestampStr),
                  timestamp >= cutoffDate else {
                continue
            }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let event = ClaudeUsageEvent(
                    timestamp: timestamp,
                    model: message["model"] as? String,
                    messageID: message["id"] as? String,
                    requestID: json["requestId"] as? String,
                    input: intValue(usage["input_tokens"]),
                    output: intValue(usage["output_tokens"]),
                    cacheCreation: intValue(usage["cache_creation_input_tokens"]),
                    cacheCreationOneHour: claudeOneHourCacheCreationTokens(in: usage),
                    cacheRead: intValue(usage["cache_read_input_tokens"])
                )

                guard event.hasUsage else { continue }

                if let key = event.deduplicationKey {
                    keyedEvents[key] = event
                } else {
                    unkeyedEvents.append(event)
                }
            }
        }

        let events = keyedEvents.keys.sorted().compactMap { keyedEvents[$0] } + unkeyedEvents
        for event in events {
            let pricing = claudePricing(for: event.model)
            let eventCost = calculateClaudeCost(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheCreationOneHour: event.cacheCreationOneHour,
                cacheRead: event.cacheRead,
                pricing: pricing
            )
            let day = Calendar.current.startOfDay(for: event.timestamp)

            totalInput += event.input
            totalOutput += event.output
            totalCacheCreation += event.cacheCreation
            totalCacheRead += event.cacheRead
            totalEstimatedCost += eventCost
            dates.append(event.timestamp)
            dailyTotals[day, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
        }

        return (totalInput, totalOutput, totalCacheCreation, totalCacheRead, totalEstimatedCost, dates, dailyTotals)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func claudeOneHourCacheCreationTokens(in usage: [String: Any]) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
        let total = intValue(usage["cache_creation_input_tokens"])
        let oneHour = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        return min(total, max(0, oneHour))
    }

    private func claudePricing(for model: String?) -> TokenPricing {
        guard let model else {
            return pricing["claude-sonnet"] ?? pricing["default"]!
        }

        let normalized = normalizeClaudeModel(model)
        if let exact = pricing[normalized] {
            return exact
        }

        if normalized.contains("fable") {
            return pricing["claude-fable-5"] ?? pricing["default"]!
        }
        if normalized.contains("opus") {
            if normalized.contains("4-8") { return pricing["claude-opus-4-8"] ?? pricing["claude-opus"]! }
            if normalized.contains("4-7") { return pricing["claude-opus-4-7"] ?? pricing["claude-opus"]! }
            if normalized.contains("4-6") { return pricing["claude-opus-4-6"] ?? pricing["claude-opus"]! }
            return pricing["claude-opus"] ?? pricing["default"]!
        }
        if normalized.contains("haiku") {
            return normalized.contains("4-5")
                ? pricing["claude-haiku-4-5"] ?? pricing["claude-haiku"]!
                : pricing["claude-haiku"] ?? pricing["default"]!
        }
        if normalized.contains("sonnet") {
            if normalized.contains("4-6") { return pricing["claude-sonnet-4-6"] ?? pricing["claude-sonnet"]! }
            if normalized.contains("4-5") { return pricing["claude-sonnet-4-5"] ?? pricing["claude-sonnet"]! }
            if normalized.contains("4") { return pricing["claude-sonnet-4"] ?? pricing["claude-sonnet"]! }
            return pricing["claude-sonnet"] ?? pricing["default"]!
        }

        return pricing["default"]!
    }

    private func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }
        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-") {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }
        if let versionRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(versionRange)
        }
        if let dateRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<dateRange.lowerBound])
            if pricing[base] != nil {
                return base
            }
        }
        return trimmed
    }

    private func scanCodexSessions(since cutoffDate: Date) -> (TokenCost, [DailyTokenUsage])? {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let archivedDir = codexDir.appendingPathComponent("archived_sessions")
        let logsDatabase = codexDir.appendingPathComponent("logs_2.sqlite")
        var totals = TokenAccumulator()
        var dailyTotals: [Date: TokenAccumulator] = [:]
        var eventKeys = Set<String>()
        var sessionIDs = Set<String>()
        var earliestDate = Date()
        var latestDate = cutoffDate

        scanCodexArchivedSessions(
            directory: archivedDir,
            since: cutoffDate,
            totals: &totals,
            dailyTotals: &dailyTotals,
            eventKeys: &eventKeys,
            sessionIDs: &sessionIDs,
            earliestDate: &earliestDate,
            latestDate: &latestDate
        )
        scanCodexSQLiteLogs(
            database: logsDatabase,
            since: cutoffDate,
            totals: &totals,
            dailyTotals: &dailyTotals,
            eventKeys: &eventKeys,
            sessionIDs: &sessionIDs,
            earliestDate: &earliestDate,
            latestDate: &latestDate
        )

        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        let pricing = self.pricing["codex"] ?? self.pricing["default"]!
        let billableInput = max(0, totals.input - totals.cacheRead)
        let output = totals.output + totals.reasoning
        let cost = calculateCost(
            input: billableInput,
            output: output,
            cacheCreation: 0,
            cacheRead: totals.cacheRead,
            pricing: pricing
        )

        return (TokenCost(
            provider: .codexCli,
            inputTokens: billableInput,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: totals.cacheRead,
            estimatedCostUSD: cost,
            sessionCount: sessionIDs.count,
            periodStart: earliestDate,
            periodEnd: latestDate
        ), makeDailyUsage(from: dailyTotals, provider: .codexCli, pricing: pricing))
    }

    private func scanCodexArchivedSessions(
        directory: URL,
        since cutoffDate: Date,
        totals: inout TokenAccumulator,
        dailyTotals: inout [Date: TokenAccumulator],
        eventKeys: inout Set<String>,
        sessionIDs: inout Set<String>,
        earliestDate: inout Date,
        latestDate: inout Date
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoffDate,
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            for line in content.split(separator: "\n") {
                guard line.contains("\"token_count\""),
                      let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampText = json["timestamp"] as? String,
                      let timestamp = formatter.date(from: timestampText),
                      timestamp >= cutoffDate,
                      let payload = json["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = (info["last_token_usage"] ?? info["total_token_usage"]) as? [String: Any] else {
                    continue
                }

                let sessionID = (((payload["rate_limits"] as? [String: Any])?["conversation_id"] as? String)
                    ?? fileURL.deletingPathExtension().lastPathComponent)
                addCodexUsage(
                    usage,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    totals: &totals,
                    dailyTotals: &dailyTotals,
                    eventKeys: &eventKeys,
                    sessionIDs: &sessionIDs,
                    earliestDate: &earliestDate,
                    latestDate: &latestDate
                )
            }
        }
    }

    private func scanCodexSQLiteLogs(
        database: URL,
        since cutoffDate: Date,
        totals: inout TokenAccumulator,
        dailyTotals: inout [Date: TokenAccumulator],
        eventKeys: inout Set<String>,
        sessionIDs: inout Set<String>,
        earliestDate: inout Date,
        latestDate: inout Date
    ) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT feedback_log_body
            FROM logs
            WHERE feedback_log_body LIKE '%input_token_count=%'
              AND feedback_log_body LIKE '%event.timestamp=%'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bodyPointer = sqlite3_column_text(statement, 0) else { continue }
            let body = String(cString: bodyPointer)
            guard let timestamp = codexLogDate(in: body), timestamp >= cutoffDate else { continue }

            let usage: [String: Any] = [
                "input_tokens": codexLogInt("input_token_count", in: body),
                "output_tokens": codexLogInt("output_token_count", in: body),
                "cached_input_tokens": codexLogInt("cached_token_count", in: body),
                "reasoning_output_tokens": codexLogInt("reasoning_token_count", in: body)
            ]
            let sessionID = codexLogValue("conversation.id", in: body) ?? codexLogValue("thread.id", in: body) ?? "codex"
            addCodexUsage(
                usage,
                timestamp: timestamp,
                sessionID: sessionID,
                totals: &totals,
                dailyTotals: &dailyTotals,
                eventKeys: &eventKeys,
                sessionIDs: &sessionIDs,
                earliestDate: &earliestDate,
                latestDate: &latestDate
            )
        }
    }

    private func addCodexUsage(
        _ usage: [String: Any],
        timestamp: Date,
        sessionID: String,
        totals: inout TokenAccumulator,
        dailyTotals: inout [Date: TokenAccumulator],
        eventKeys: inout Set<String>,
        sessionIDs: inout Set<String>,
        earliestDate: inout Date,
        latestDate: inout Date
    ) {
        let input = intValue(usage["input_tokens"])
        let cached = intValue(usage["cached_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let reasoning = intValue(usage["reasoning_output_tokens"])
        guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { return }

        let key = "\(timestamp.timeIntervalSince1970)-\(sessionID)-\(input)-\(cached)-\(output)-\(reasoning)"
        guard eventKeys.insert(key).inserted else { return }

        sessionIDs.insert(sessionID)
        totals.add(input: input, output: output, cacheCreation: 0, cacheRead: cached, reasoning: reasoning)
        let day = Calendar.current.startOfDay(for: timestamp)
        dailyTotals[day, default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        if timestamp < earliestDate { earliestDate = timestamp }
        if timestamp > latestDate { latestDate = timestamp }
    }

    private func makeDailyUsage(
        from dailyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [DailyTokenUsage] {
        dailyTotals.map { day, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : calculateCost(
                    input: billableInput,
                    output: tokens.output + tokens.reasoning,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: pricing
                )
            return DailyTokenUsage(
                date: day,
                provider: provider,
                inputTokens: billableInput,
                outputTokens: tokens.output + tokens.reasoning,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost
            )
        }
    }

    private func mergeDailyTotals(_ target: inout [Date: TokenAccumulator], with source: [Date: TokenAccumulator]) {
        for (day, tokens) in source {
            target[day, default: TokenAccumulator()].merge(tokens)
        }
    }

    private func calculateCost(input: Int, output: Int, cacheCreation: Int, cacheRead: Int, pricing: TokenPricing) -> Double {
        let inputCost = Double(input) / 1_000_000 * pricing.input
        let outputCost = Double(output) / 1_000_000 * pricing.output
        let cacheCreationCost = Double(cacheCreation) / 1_000_000 * pricing.cacheCreation
        let cacheReadCost = Double(cacheRead) / 1_000_000 * pricing.cacheRead
        return inputCost + outputCost + cacheCreationCost + cacheReadCost
    }

    private func calculateClaudeCost(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheCreationOneHour: Int,
        cacheRead: Int,
        pricing: TokenPricing
    ) -> Double {
        let oneHourCacheCreation = min(max(0, cacheCreationOneHour), max(0, cacheCreation))
        let fiveMinuteCacheCreation = max(0, cacheCreation - oneHourCacheCreation)
        let oneHourRate = pricing.cacheCreationOneHour ?? pricing.cacheCreation

        let inputCost = Double(max(0, input)) / 1_000_000 * pricing.input
        let outputCost = Double(max(0, output)) / 1_000_000 * pricing.output
        let cacheCreationCost = Double(fiveMinuteCacheCreation) / 1_000_000 * pricing.cacheCreation
        let oneHourCacheCreationCost = Double(oneHourCacheCreation) / 1_000_000 * oneHourRate
        let cacheReadCost = Double(max(0, cacheRead)) / 1_000_000 * pricing.cacheRead
        return inputCost + outputCost + cacheCreationCost + oneHourCacheCreationCost + cacheReadCost
    }

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func codexLogDate(in text: String) -> Date? {
        guard let value = codexLogValue("event.timestamp", in: text) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func codexLogInt(_ key: String, in text: String) -> Int {
        guard let value = codexLogValue(key, in: text) else { return 0 }
        return Int(value) ?? 0
    }

    private func codexLogValue(_ key: String, in text: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + #"=([^\s}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

private struct TokenPricing {
    let input: Double      // per million tokens
    let output: Double     // per million tokens
    let cacheCreation: Double
    let cacheRead: Double
    let cacheCreationOneHour: Double?

    init(
        input: Double,
        output: Double,
        cacheCreation: Double,
        cacheRead: Double,
        cacheCreationOneHour: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreationOneHour = cacheCreationOneHour
    }
}

private struct TokenAccumulator {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var estimatedCostUSD = 0.0

    mutating func add(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int = 0,
        estimatedCostUSD: Double = 0
    ) {
        self.input += input
        self.output += output
        self.cacheCreation += cacheCreation
        self.cacheRead += cacheRead
        self.reasoning += reasoning
        self.estimatedCostUSD += estimatedCostUSD
    }

    mutating func merge(_ other: TokenAccumulator) {
        add(
            input: other.input,
            output: other.output,
            cacheCreation: other.cacheCreation,
            cacheRead: other.cacheRead,
            reasoning: other.reasoning,
            estimatedCostUSD: other.estimatedCostUSD
        )
    }
}

private struct ClaudeUsageEvent {
    let timestamp: Date
    let model: String?
    let messageID: String?
    let requestID: String?
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheCreationOneHour: Int
    let cacheRead: Int

    var hasUsage: Bool {
        input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0
    }

    var deduplicationKey: String? {
        guard let messageID, let requestID else { return nil }
        return "\(messageID):\(requestID)"
    }
}
