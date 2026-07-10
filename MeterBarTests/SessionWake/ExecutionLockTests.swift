import Darwin
import Foundation
@testable import MeterBar
import XCTest

final class ExecutionLockTests: XCTestCase {
    private var scratch: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutionLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        lockURL = scratch.appendingPathComponent("execution.lock")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    private func makeLock() -> ExecutionLock {
        // No legacy probe unless a test opts in.
        ExecutionLock(lockFileURL: lockURL, legacyProbe: nil)
    }

    // MARK: - Mutual exclusion

    func testSecondAcquisitionIsRejectedWhileHeld() throws {
        let app = makeLock()
        let cli = makeLock()

        guard case let .acquired(held) = app.acquire(kind: .app) else {
            return XCTFail("first acquisition should succeed")
        }
        defer { held.release() }

        // App and CLI contend on the SAME lock — the CLI is rejected.
        guard case let .contended(holder) = cli.acquire(kind: .cli) else {
            return XCTFail("second acquisition should be rejected")
        }
        XCTAssertEqual(holder?.kind, .app)
        XCTAssertEqual(holder?.pid, getpid())
    }

    func testLockIsReusableAfterRelease() throws {
        let lock = makeLock()

        guard case let .acquired(first) = lock.acquire(kind: .app) else {
            return XCTFail("first acquisition should succeed")
        }
        first.release()

        guard case let .acquired(second) = lock.acquire(kind: .cli) else {
            return XCTFail("acquisition after release should succeed")
        }
        defer { second.release() }
        // Descriptor now reflects the new holder, not the released one.
        XCTAssertEqual(second.holder.kind, .cli)
    }

    func testReleaseClearsHolderDescriptor() throws {
        let lock = makeLock()
        guard case let .acquired(held) = lock.acquire(kind: .app) else {
            return XCTFail("acquisition should succeed")
        }
        XCTAssertNotNil(lock.readHolder())
        held.release()
        XCTAssertNil(lock.readHolder(), "released lock must not report a stale holder")
    }

    // MARK: - Legacy watcher migration guard

    func testLegacyWatcherContentionIsReportedWithGuidance() throws {
        let pidFile = scratch.appendingPathComponent("legacy-watcher.pid")
        try "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
        let probe = LegacyWatcherProbe(pidFileURL: pidFile)
        let lock = ExecutionLock(lockFileURL: lockURL, legacyProbe: probe)

        guard case let .legacyWatcherActive(pid, guidance) = lock.acquire(kind: .app) else {
            return XCTFail("a live legacy watcher must block the run")
        }
        XCTAssertEqual(pid, getpid())
        XCTAssertTrue(guidance.lowercased().contains("legacy"))
        XCTAssertFalse(guidance.isEmpty)
        // No flock file should have been created — the run never reached step 3.
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testStaleLegacyPidFileDoesNotBlock() throws {
        let pidFile = scratch.appendingPathComponent("legacy-watcher.pid")
        // A pid that is not alive is treated as absent.
        let probe = LegacyWatcherProbe(pidFileURL: pidFile, isProcessAlive: { _ in false })
        try "424242\n".write(to: pidFile, atomically: true, encoding: .utf8)
        let lock = ExecutionLock(lockFileURL: lockURL, legacyProbe: probe)

        guard case let .acquired(held) = lock.acquire(kind: .app) else {
            return XCTFail("a stale legacy pid file must not block acquisition")
        }
        held.release()
    }

    // MARK: - Private permissions

    func testLockFileAndDirectoryUsePrivatePermissions() throws {
        let lock = makeLock()
        guard case let .acquired(held) = lock.acquire(kind: .app) else {
            return XCTFail("acquisition should succeed")
        }
        defer { held.release() }

        let fileMode = try mode(of: lockURL)
        XCTAssertEqual(fileMode & 0o777, 0o600, "lock file must be owner-only rw")

        let dirMode = try mode(of: lockURL.deletingLastPathComponent())
        XCTAssertEqual(dirMode & 0o777, 0o700, "lock directory must be owner-only rwx")
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
