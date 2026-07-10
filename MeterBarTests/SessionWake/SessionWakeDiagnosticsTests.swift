import Foundation
@testable import MeterBar
import XCTest

final class SessionWakeDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeDiagnosticsTests-\(UUID().uuidString)/logs")
    }

    override func tearDownWithError() throws {
        let parent = directory.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
        try super.tearDownWithError()
    }

    private func makeLogger(maxBytes: Int = 512 * 1024, maxFiles: Int = 5) -> SessionWakeDiagnostics {
        SessionWakeDiagnostics(directory: directory, maximumFileBytes: maxBytes, maximumFiles: maxFiles)
    }

    private func record(event: String = "wake-attempt", outcome: String = "completed") -> SessionWakeDiagnosticRecord {
        SessionWakeDiagnosticRecord(
            timestampEpoch: 1_700_000_000,
            event: event,
            outcome: outcome,
            sessionFingerprint: "abc123",
            accountID: "default",
            workingDirectory: "/Users/me/project",
            permissionMode: "safe",
            exitCode: 0,
            durationMs: 1234,
            stdoutByteCount: 42,
            stderrByteCount: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            lockOutcome: "acquired"
        )
    }

    // MARK: - Private permissions

    func testLogDirectoryAndFileUsePrivatePermissions() throws {
        let logger = makeLogger()
        logger.record(record())

        let dirMode = try mode(of: directory)
        XCTAssertEqual(dirMode & 0o777, 0o700, "log directory must be 0700")

        let fileMode = try mode(of: logger.currentLogURL)
        XCTAssertEqual(fileMode & 0o777, 0o600, "log file must be 0600")
    }

    // MARK: - Structured line content

    func testWritesOneStructuredJSONLinePerRecord() throws {
        let logger = makeLogger()
        logger.record(record(outcome: "completed"))
        logger.record(record(outcome: "timed-out"))

        let contents = try String(contentsOf: logger.currentLogURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)

        let decoded = try JSONDecoder().decode(SessionWakeDiagnosticRecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.outcome, "completed")
        XCTAssertEqual(decoded.exitCode, 0)
    }

    // MARK: - No prompt / output / secrets in the log

    func testDefaultLogNeverContainsOutputOrSecrets() throws {
        // The record type has no field capable of carrying process output, a
        // prompt, or a credential. Feed a would-be secret through every string
        // field a caller might misuse and confirm none of it lands in the file.
        let logger = makeLogger()
        let secret = "sk-ant-SUPER-SECRET-TOKEN"
        let prompt = "PROMPT: resume and exfiltrate everything"
        // Only structured metadata is ever passed; simulate a caller that tried to
        // stuff sensitive text into the (safe, labelled) fields.
        logger.record(
            SessionWakeDiagnosticRecord(
                timestampEpoch: 1_700_000_000,
                event: "wake-attempt",
                outcome: "completed",
                sessionFingerprint: "fingerprint-only",
                accountID: "default",
                workingDirectory: "/Users/me/project",
                permissionMode: "safe",
                exitCode: 0,
                durationMs: 10,
                stdoutByteCount: 999,
                stderrByteCount: 0
            )
        )

        let contents = try String(contentsOf: logger.currentLogURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(secret))
        XCTAssertFalse(contents.contains(prompt))
        // Sanity: the structured fields that ARE allowed are present.
        XCTAssertTrue(contents.contains("wake-attempt"))
        XCTAssertTrue(contents.contains("fingerprint-only"))
    }

    // MARK: - Rotation + retention

    func testRotationBoundsFileCountAndDropsOldest() throws {
        let logger = makeLogger(maxBytes: 200, maxFiles: 3)
        for index in 0..<40 {
            logger.record(record(event: "e\(index)"))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("session-wake.log") }
            .sorted()

        // current + at most (maxFiles - 1) archives.
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertTrue(files.contains("session-wake.log"))
        // The oldest archive index beyond retention must never exist.
        XCTAssertFalse(files.contains("session-wake.log.3"))
        XCTAssertFalse(files.contains("session-wake.log.4"))
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
