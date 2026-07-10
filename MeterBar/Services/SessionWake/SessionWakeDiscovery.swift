import Foundation
import os

// MARK: - Configuration

struct SessionWakeDiscoveryConfiguration: Sendable {
    /// Bytes read from the end of each transcript (latest-decisive-event
    /// classification only needs the tail).
    var tailByteLimit = 262_144
    /// Newest-first cap on transcripts classified per scan.
    var maxTranscripts = 400
    /// Transcripts whose file wasn't modified within this window are skipped.
    var maxTranscriptAge: TimeInterval = 14 * 24 * 3600
    /// A block with no parseable reset stays "current" this long after the
    /// blocking event; afterwards it is preview-only (`.staleBlock`).
    var fallbackBlockWindow: TimeInterval = 8 * 3600
    /// A block with a known reset stays "current" until reset + this grace.
    var resetGracePeriod: TimeInterval = 3600

    static let `default` = SessionWakeDiscoveryConfiguration()
}

// MARK: - Discovery

/// Account-scoped, read-only discovery of blocked Claude Code sessions
/// (issue #95). All file I/O happens on this actor, off the main actor, with
/// bounded tail reads and a newest-first transcript cap.
///
/// Discovery is strictly a preview: it never spawns a process, writes a file,
/// touches the replay ledger storage, or mutates any account state.
actor SessionWakeDiscovery {
    private let ledger: SessionWakeReplayLedger
    private let configuration: SessionWakeDiscoveryConfiguration
    private let homeDirectoryPath: String

    init(
        ledger: SessionWakeReplayLedger = .shared,
        configuration: SessionWakeDiscoveryConfiguration = .default,
        homeDirectoryPath: String = ServiceSupport.realHomeDirectory()
    ) {
        self.ledger = ledger
        self.configuration = configuration
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// Scans only the selected account's projects directory — never another
    /// configured account's — and returns deduplicated blocked-session
    /// candidates, newest block first.
    func discoverBlockedSessions(for account: ClaudeCodeAccount, now: Date = Date()) -> [BlockedSessionCandidate] {
        let transcripts = transcriptURLs(in: projectsDirectory(for: account), now: now)

        var bySessionID: [String: BlockedSessionCandidate] = [:]
        for url in transcripts {
            guard let candidate = candidate(forTranscriptAt: url, now: now) else { continue }
            if let existing = bySessionID[candidate.sessionID], !supersedes(candidate, existing) {
                continue
            }
            bySessionID[candidate.sessionID] = candidate
        }

        return bySessionID.values.sorted {
            if $0.blockEvent.blockedAt != $1.blockEvent.blockedAt {
                return $0.blockEvent.blockedAt > $1.blockEvent.blockedAt
            }
            return $0.transcriptURL.path < $1.transcriptURL.path
        }
    }

    // MARK: - Directory resolution

    /// `<configDirectory>/projects`, defaulting to `~/.claude/projects` for
    /// the default CLI profile. Exactly one root per account.
    private func projectsDirectory(for account: ClaudeCodeAccount) -> URL {
        let trimmed = account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
                .appendingPathComponent(".claude/projects", isDirectory: true)
        }
        let base = URL(fileURLWithPath: (trimmed as NSString).standardizingPath, isDirectory: true)
        if base.lastPathComponent == "projects" {
            return base
        }
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    // MARK: - Enumeration (bounded)

    private func transcriptURLs(in projectsRoot: URL, now: Date) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: projectsRoot,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var found: [(url: URL, modified: Date)] = []
        let oldestAllowed = now.addingTimeInterval(-configuration.maxTranscriptAge)
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  !url.pathComponents.contains("subagents"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= oldestAllowed else {
                continue
            }
            found.append((url, modified))
        }

        return found
            .sorted {
                if $0.modified != $1.modified {
                    return $0.modified > $1.modified
                }
                return $0.url.path < $1.url.path
            }
            .prefix(configuration.maxTranscripts)
            .map(\.url)
    }

    // MARK: - Candidate construction

    private func candidate(forTranscriptAt url: URL, now: Date) -> BlockedSessionCandidate? {
        guard let tail = readTail(of: url) else { return nil }
        let summary = ClaudeTranscriptTailClassifier.classify(jsonl: tail)

        guard !summary.isSubagentTranscript,
              case .blocked(let event) = summary.terminalState else {
            return nil
        }

        let sessionID = summary.sessionID ?? url.deletingPathExtension().lastPathComponent
        let fingerprint = SessionBlockFingerprint.make(
            sessionID: sessionID,
            blockedAt: event.blockedAt,
            reason: event.reason
        )
        // Handled blocks are never rediscovered, including after relaunch.
        guard !ledger.containsHandled(fingerprint) else { return nil }

        let (projectDirectory, eligibility) = resolveEligibility(for: summary, event: event, now: now)
        return BlockedSessionCandidate(
            sessionID: sessionID,
            transcriptURL: url,
            projectDirectory: projectDirectory,
            gitBranch: summary.gitBranch,
            blockEvent: event,
            fingerprint: fingerprint,
            eligibility: eligibility
        )
    }

    private func resolveEligibility(
        for summary: ClaudeTranscriptTailSummary,
        event: SessionBlockEvent,
        now: Date
    ) -> (projectDirectory: String?, eligibility: SessionWakeEligibility) {
        guard let rawWorkingDirectory = summary.workingDirectory else {
            return (nil, .previewOnly(.missingMetadata))
        }

        let standardized = (rawWorkingDirectory as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Structured skip, never an executable target.
            return (nil, .previewOnly(.missingWorkingDirectory(rawWorkingDirectory)))
        }
        let canonical = URL(fileURLWithPath: standardized, isDirectory: true).resolvingSymlinksInPath().path

        guard isCurrentWindow(event: event, now: now) else {
            return (canonical, .previewOnly(.staleBlock))
        }
        return (canonical, .eligible)
    }

    /// Automatic eligibility is limited to the current blocking event/window;
    /// anything older is historical and stays preview-only.
    private func isCurrentWindow(event: SessionBlockEvent, now: Date) -> Bool {
        if let resetAt = event.resetAt {
            return now <= resetAt.addingTimeInterval(configuration.resetGracePeriod)
        }
        return now.timeIntervalSince(event.blockedAt) <= configuration.fallbackBlockWindow
    }

    /// Deterministic dedupe: latest block wins; equal timestamps tie-break on
    /// the lexicographically first transcript path.
    private func supersedes(_ candidate: BlockedSessionCandidate, _ existing: BlockedSessionCandidate) -> Bool {
        if candidate.blockEvent.blockedAt != existing.blockEvent.blockedAt {
            return candidate.blockEvent.blockedAt > existing.blockEvent.blockedAt
        }
        return candidate.transcriptURL.path < existing.transcriptURL.path
    }

    /// Reads at most `tailByteLimit` bytes from the end of the file. A tail
    /// that starts mid-line is fine: the classifier skips the partial line.
    private func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let limit = UInt64(configuration.tailByteLimit)
            let offset = size > limit ? size - limit : 0
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return "" }
            // Lossy decoding on purpose: a bounded tail read can split a
            // multi-byte UTF-8 character, and a failable init would then drop
            // the whole transcript — including its decisive event.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data, as: UTF8.self)
        } catch {
            AppLog.usage.error(
                "Session wake tail read failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
