import XCTest
@testable import MeterBar

final class SessionWakeDiscoveryTests: XCTestCase {
    private var tempDir: URL!
    private var configDir: URL!
    private var projectsDir: URL!
    private var workDir: URL!
    private var ledgerURL: URL!
    private var ledger: SessionWakeReplayLedger!

    /// Scan time shortly after the fixtures' 04:14Z block, before its 05:30Z reset.
    private let now = FlexibleISO8601.date(from: "2026-07-10T05:00:00Z") ?? Date()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeDiscoveryTests-\(UUID().uuidString)")
        configDir = tempDir.appendingPathComponent("claude-config")
        projectsDir = configDir.appendingPathComponent("projects")
        workDir = tempDir.appendingPathComponent("workdir")
        ledgerURL = tempDir.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        ledger = SessionWakeReplayLedger(storageURL: ledgerURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeAccount(configDirectory: URL? = nil) -> ClaudeCodeAccount {
        ClaudeCodeAccount(
            id: UUID(),
            name: "Test Account",
            configDirectory: (configDirectory ?? configDir).path
        )
    }

    private func makeDiscovery(
        configuration: SessionWakeDiscoveryConfiguration = .default
    ) -> SessionWakeDiscovery {
        SessionWakeDiscovery(ledger: ledger, configuration: configuration)
    }

    private func projectDir(_ name: String = "-tmp-project") -> URL {
        projectsDir.appendingPathComponent(name)
    }

    // MARK: - Happy path

    func testBlockedSessionIsDiscoveredEligible() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.sessionID, SessionWakeFixtures.defaultSessionID)
        XCTAssertEqual(candidate.eligibility, .eligible)
        XCTAssertEqual(candidate.blockEvent.reason, .sessionLimit)
        XCTAssertEqual(
            candidate.projectDirectory,
            URL(fileURLWithPath: workDir.path).resolvingSymlinksInPath().path
        )
        XCTAssertFalse(candidate.fingerprint.isEmpty)
        XCTAssertEqual(candidate.id, candidate.fingerprint, "Identifiable id is the fingerprint")
    }

    func testWorkingDirectoryIsCanonicalized() async throws {
        let messyPath = workDir.path + "/./"
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: messyPath)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        XCTAssertEqual(
            candidates.first?.projectDirectory,
            URL(fileURLWithPath: workDir.path).resolvingSymlinksInPath().path
        )
    }

    // MARK: - Later recovery

    func testBlockFollowedByLaterProgressIsNotACandidate() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [
                SessionWakeFixtures.rateLimitLine(cwd: workDir.path, timestamp: "2026-07-10T04:14:15.397Z"),
                SessionWakeFixtures.assistantProgressLine(cwd: workDir.path, timestamp: "2026-07-10T04:50:00.000Z")
            ],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertTrue(candidates.isEmpty, "recovered sessions must not be candidates")
    }

    // MARK: - Replay ledger

    func testHandledFingerprintIsNotRediscoveredAfterRelaunch() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let first = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        let fingerprint = try XCTUnwrap(first.first?.fingerprint)
        ledger.markHandled(fingerprint, at: now)

        // Fresh ledger + discovery instances simulate an app relaunch.
        ledger = SessionWakeReplayLedger(storageURL: ledgerURL)
        let second = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertTrue(second.isEmpty, "handled blocks must not be rediscovered")
    }

    // MARK: - Skip reasons

    func testMissingWorkingDirectoryYieldsStructuredSkip() async throws {
        let deadPath = tempDir.appendingPathComponent("deleted-worktree").path
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: deadPath)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.eligibility, .previewOnly(.missingWorkingDirectory(deadPath)))
        XCTAssertNil(candidate.projectDirectory, "a dead cwd must not produce an executable target")
    }

    func testStaleBlockIsPreviewOnly() async throws {
        // Reset (05:30Z on Jul 10) long past by scan time two days later.
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let later = now.addingTimeInterval(48 * 3600)
        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: later)

        XCTAssertEqual(candidates.first?.eligibility, .previewOnly(.staleBlock))
    }

    func testBlockWithoutResetUsesFallbackWindow() async throws {
        let text = "You've hit your session limit"
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path, text: text)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        var configuration = SessionWakeDiscoveryConfiguration.default
        configuration.fallbackBlockWindow = 8 * 3600

        let fresh = await makeDiscovery(configuration: configuration)
            .discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertEqual(fresh.first?.eligibility, .eligible)

        let stale = await makeDiscovery(configuration: configuration)
            .discoverBlockedSessions(for: makeAccount(), now: now.addingTimeInterval(9 * 3600))
        XCTAssertEqual(stale.first?.eligibility, .previewOnly(.staleBlock))
    }

    func testMissingMetadataYieldsStructuredSkip() async throws {
        // A rate-limit line with no cwd at all.
        let line = """
        {"isSidechain":false,"type":"assistant","timestamp":"2026-07-10T04:14:15.397Z",\
        "message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit \
        · resets 7:30am (Europe/Malta)"}]},"error":"rate_limit","isApiErrorMessage":true,\
        "sessionId":"\(SessionWakeFixtures.defaultSessionID)"}
        """
        try SessionWakeFixtures.writeTranscript(
            lines: [line],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertEqual(candidates.first?.eligibility, .previewOnly(.missingMetadata))
    }

    // MARK: - Deduplication

    func testDuplicateSessionIDsAreDeduplicatedDeterministically() async throws {
        // Same session appears in two project directories; the newer block wins.
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path, timestamp: "2026-07-10T03:00:00.000Z")],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir("-tmp-project-a")
        )
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path, timestamp: "2026-07-10T04:14:15.397Z")],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir("-tmp-project-b")
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(
            candidates.first?.blockEvent.blockedAt,
            FlexibleISO8601.date(from: "2026-07-10T04:14:15.397Z")
        )
    }

    func testDuplicateTieBreaksOnTranscriptPath() async throws {
        for name in ["-tmp-project-b", "-tmp-project-a"] {
            try SessionWakeFixtures.writeTranscript(
                lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
                named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
                in: projectDir(name)
            )
        }

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(
            candidates.first?.transcriptURL.path.contains("-tmp-project-a") == true,
            "equal-timestamp duplicates must tie-break on the lexicographically first path"
        )
    }

    // MARK: - Subagents

    func testAllSidechainTranscriptsAreExcluded() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path, isSidechain: true)],
            named: "\(UUID().uuidString).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertTrue(candidates.isEmpty, "subagent transcripts must be excluded")
    }

    func testSubagentsDirectoryIsExcluded() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(UUID().uuidString).jsonl",
            in: projectDir().appendingPathComponent("subagents")
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Account scoping

    func testDiscoveryIsScopedToTheSelectedAccount() async throws {
        let otherConfig = tempDir.appendingPathComponent("other-claude-config")
        let otherProjects = otherConfig.appendingPathComponent("projects/-tmp-other")
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(sessionID: UUID().uuidString, cwd: workDir.path)],
            named: "other-session.jsonl",
            in: otherProjects
        )
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.sessionID, SessionWakeFixtures.defaultSessionID)
        XCTAssertFalse(candidates.first?.transcriptURL.path.contains("other-claude-config") ?? true)
    }

    func testMissingProjectsDirectoryYieldsNoCandidates() async {
        let account = makeAccount(configDirectory: tempDir.appendingPathComponent("nonexistent"))
        let candidates = await makeDiscovery().discoverBlockedSessions(for: account, now: now)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Robustness & bounds

    func testMalformedTranscriptFilesCannotPoisonTheScan() async throws {
        let project = projectDir()
        try SessionWakeFixtures.writeTranscript(
            lines: ["garbage {{{", "\u{0000}\u{0001}binary-ish"],
            named: "\(UUID().uuidString).jsonl",
            in: project
        )
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: project
        )

        let candidates = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertEqual(candidates.count, 1)
    }

    func testOnlyTailBytesAreReadFromLargeTranscripts() async throws {
        // A huge prefix of noise; the decisive block event sits at the tail.
        var lines = (0..<50).map { _ in SessionWakeFixtures.userTextLine(cwd: workDir.path) }
        lines.append(SessionWakeFixtures.rateLimitLine(cwd: workDir.path))

        var configuration = SessionWakeDiscoveryConfiguration.default
        configuration.tailByteLimit = 4096

        try SessionWakeFixtures.writeTranscript(
            lines: lines,
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let candidates = await makeDiscovery(configuration: configuration)
            .discoverBlockedSessions(for: makeAccount(), now: now)
        XCTAssertEqual(candidates.count, 1)
    }

    // MARK: - Read-only preview

    func testDiscoveryPerformsZeroFilesystemMutations() async throws {
        try SessionWakeFixtures.writeTranscript(
            lines: [SessionWakeFixtures.rateLimitLine(cwd: workDir.path)],
            named: "\(SessionWakeFixtures.defaultSessionID).jsonl",
            in: projectDir()
        )

        let before = try snapshot(of: tempDir)
        _ = await makeDiscovery().discoverBlockedSessions(for: makeAccount(), now: now)
        let after = try snapshot(of: tempDir)

        XCTAssertEqual(before, after, "preview must not create, modify, or delete any file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                       "discovery must not write the replay ledger")
    }

    /// Recursive path -> (size, modification date) map used to prove read-only behavior.
    private func snapshot(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = values.contentModificationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            result[url.path] = "\(values.fileSize ?? -1)|\(stamp)"
        }
        return result
    }
}
