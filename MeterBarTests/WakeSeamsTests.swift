import XCTest
@testable import MeterBar

/// Coverage for the #96 automation seams and the concrete CLI quota fetcher's
/// pure/injectable paths (the process-spawning path is exercised by #97).
final class WakeSeamsTests: XCTestCase {
    // MARK: - TaskSleeper

    func testTaskSleeperZeroDurationReturnsTrue() async {
        let elapsed = await TaskSleeper().sleep(0)
        XCTAssertTrue(elapsed)
    }

    func testTaskSleeperReturnsFalseWhenCancelled() async {
        let task = Task { await TaskSleeper().sleep(60) }
        task.cancel()
        let elapsed = await task.value
        XCTAssertFalse(elapsed, "A cancelled sleep must report it did not elapse")
    }

    // MARK: - ReplayLedgerRecorder (adapter over #95 ledger)

    func testReplayLedgerRecorderPersistsFingerprint() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wake-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ledger = ReplayLedger(fileURL: tmp)
        let recorder = ReplayLedgerRecorder(ledger: ledger)
        let fingerprint = BlockFingerprint(
            sessionID: "session-a",
            blockedAt: Date(timeIntervalSinceReferenceDate: 1),
            reason: .sessionLimit
        )

        await recorder.record(fingerprint)

        let contains = await ledger.contains(fingerprint)
        XCTAssertTrue(contains, "Recorded fingerprint must be persisted in the ledger")
    }

    // MARK: - DiscoveryCandidateSource (adapter over #95 discovery)

    func testDiscoveryCandidateSourceReturnsEmptyForMissingProjects() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wake-account-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = DiscoveryCandidateSource(
            discovery: SessionDiscovery(),
            ledger: ReplayLedger(fileURL: tmp.appendingPathComponent("ledger.json"))
        )

        let candidates = await source.candidates(configDirectory: tmp.path)
        XCTAssertTrue(candidates.isEmpty, "An account with no transcripts yields no candidates")
    }

    // MARK: - ClaudeCLIQuotaFetcher pure paths

    func testQuotaFetcherFailsClosedWhenAccountUnresolved() async {
        let fetcher = ClaudeCLIQuotaFetcher(accountLookup: { _ in nil })
        let result = await fetcher.fetchFreshQuota(accountID: UUID())
        guard case .failure = result else {
            return XCTFail("Unresolved account must fail (fails closed), got \(result)")
        }
    }

    func testAuthorizationHeuristicClassifiesLoginPrompts() {
        XCTAssertTrue(ClaudeCLIQuotaFetcher.looksLikeAuthorizationFailure(
            ClaudeCodeCLIUsageError.commandFailed("Please run /login to authenticate")))
        XCTAssertTrue(ClaudeCLIQuotaFetcher.looksLikeAuthorizationFailure(
            ClaudeCodeCLIUsageError.commandFailed("You are logged out")))
        XCTAssertFalse(ClaudeCLIQuotaFetcher.looksLikeAuthorizationFailure(
            ClaudeCodeCLIUsageError.timedOut))
        XCTAssertFalse(ClaudeCLIQuotaFetcher.looksLikeAuthorizationFailure(
            ClaudeCodeCLIUsageError.cliNotFound))
    }
}
