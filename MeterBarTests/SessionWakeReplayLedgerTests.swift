import XCTest
@testable import MeterBar

final class SessionWakeReplayLedgerTests: XCTestCase {
    private var tempDir: URL!
    private var ledgerURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeReplayLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ledgerURL = tempDir.appendingPathComponent("ledger.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fingerprint

    func testFingerprintIsDeterministic() {
        let blockedAt = Date(timeIntervalSince1970: 1_752_120_855)
        let first = SessionBlockFingerprint.make(
            sessionID: "abc", blockedAt: blockedAt, reason: .sessionLimit
        )
        let second = SessionBlockFingerprint.make(
            sessionID: "abc", blockedAt: blockedAt, reason: .sessionLimit
        )
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testFingerprintDiscriminatesSessionTimeAndReason() {
        let blockedAt = Date(timeIntervalSince1970: 1_752_120_855)
        let base = SessionBlockFingerprint.make(sessionID: "abc", blockedAt: blockedAt, reason: .sessionLimit)

        XCTAssertNotEqual(
            base,
            SessionBlockFingerprint.make(sessionID: "abd", blockedAt: blockedAt, reason: .sessionLimit)
        )
        XCTAssertNotEqual(
            base,
            SessionBlockFingerprint.make(
                sessionID: "abc",
                blockedAt: blockedAt.addingTimeInterval(1),
                reason: .sessionLimit
            )
        )
        XCTAssertNotEqual(
            base,
            SessionBlockFingerprint.make(sessionID: "abc", blockedAt: blockedAt, reason: .weeklyLimit)
        )
    }

    // MARK: - Ledger persistence

    func testMarkHandledPersistsAcrossInstances() {
        let fingerprint = "deadbeef"
        let ledger = SessionWakeReplayLedger(storageURL: ledgerURL)
        XCTAssertFalse(ledger.containsHandled(fingerprint))

        ledger.markHandled(fingerprint, at: Date(timeIntervalSince1970: 1_752_120_855))
        XCTAssertTrue(ledger.containsHandled(fingerprint))

        // Simulates app relaunch: a fresh instance reads the same file.
        let relaunched = SessionWakeReplayLedger(storageURL: ledgerURL)
        XCTAssertTrue(relaunched.containsHandled(fingerprint))
    }

    func testCorruptLedgerFileIsToleratedAsEmpty() throws {
        try Data("not json{{{".utf8).write(to: ledgerURL)
        let ledger = SessionWakeReplayLedger(storageURL: ledgerURL)
        XCTAssertFalse(ledger.containsHandled("anything"))

        // And it can still record new entries afterwards.
        ledger.markHandled("abc", at: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(SessionWakeReplayLedger(storageURL: ledgerURL).containsHandled("abc"))
    }

    func testLedgerPrunesOldestBeyondCapacity() {
        let ledger = SessionWakeReplayLedger(storageURL: ledgerURL, maxEntries: 3)
        for index in 0..<5 {
            ledger.markHandled("fp-\(index)", at: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        let relaunched = SessionWakeReplayLedger(storageURL: ledgerURL, maxEntries: 3)
        XCTAssertFalse(relaunched.containsHandled("fp-0"))
        XCTAssertFalse(relaunched.containsHandled("fp-1"))
        XCTAssertTrue(relaunched.containsHandled("fp-2"))
        XCTAssertTrue(relaunched.containsHandled("fp-3"))
        XCTAssertTrue(relaunched.containsHandled("fp-4"))
    }

    func testContainsHandledDoesNotCreateStorageFile() {
        let ledger = SessionWakeReplayLedger(storageURL: ledgerURL)
        _ = ledger.containsHandled("abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                       "read-only queries must not touch disk")
    }
}
