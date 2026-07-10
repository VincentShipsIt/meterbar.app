import Darwin
import Foundation
@testable import MeterBar
import XCTest

final class ProcessRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes an executable shell script and returns its URL.
    private func makeScript(_ body: String, name: String = "fake") throws -> URL {
        let url = scratch.appendingPathComponent("\(name)-\(UUID().uuidString).sh")
        try "#!/bin/bash\nset -u\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeWorkingDirectory(_ name: String = "cwd") throws -> URL {
        let url = scratch.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Exact argv / environment / cwd (fake executable)

    func testPassesExactArgumentsEnvironmentAndWorkingDirectory() async throws {
        let outFile = scratch.appendingPathComponent("capture.txt")
        let script = try makeScript(
            """
            {
              echo "CWD=$(pwd)"
              echo "MARKER=$MB_MARKER"
              echo "ARGC=$#"
              for a in "$@"; do echo "ARG=$a"; done
            } > "$MB_OUT"
            """
        )
        let cwd = try makeWorkingDirectory()

        let launch = ProcessLaunch(
            executableURL: script,
            arguments: ["--resume", "session id with spaces", "--print"],
            environment: ["MB_MARKER": "meterbar-account-42", "MB_OUT": outFile.path],
            workingDirectory: cwd
        )
        let result = await ProcessRunner.shared.run(launch)

        XCTAssertEqual(result.outcome, .completed(exitCode: 0))
        let captured = try String(contentsOf: outFile, encoding: .utf8)
        // cwd is honoured. The `cwd-<UUID>` leaf is globally unique, so a pwd
        // ending in it proves the child ran in our directory (independent of the
        // /var -> /private/var symlink normalization macOS applies to temp dirs).
        XCTAssertTrue(captured.contains("CWD=/") && captured.contains("/\(cwd.lastPathComponent)\n"), captured)
        XCTAssertTrue(captured.contains("MARKER=meterbar-account-42"), captured)
        XCTAssertTrue(captured.contains("ARGC=3"), captured)
        XCTAssertTrue(captured.contains("ARG=--resume"), captured)
        XCTAssertTrue(captured.contains("ARG=session id with spaces"), captured)
        XCTAssertTrue(captured.contains("ARG=--print"), captured)
    }

    func testEnvironmentIsExactlyWhatWasProvided() async throws {
        // A variable present in the parent environment must NOT leak in unless the
        // caller included it: the runner passes the provided environment verbatim.
        setenv("MB_SHOULD_NOT_LEAK", "leaked", 1)
        defer { unsetenv("MB_SHOULD_NOT_LEAK") }

        let outFile = scratch.appendingPathComponent("env.txt")
        let script = try makeScript(#"printf '%s' "${MB_SHOULD_NOT_LEAK:-ABSENT}" > "$MB_OUT""#)
        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: ["MB_OUT": outFile.path],
            workingDirectory: try makeWorkingDirectory()
        )

        let result = await ProcessRunner.shared.run(launch)
        XCTAssertEqual(result.outcome, .completed(exitCode: 0))
        XCTAssertEqual(try String(contentsOf: outFile, encoding: .utf8), "ABSENT")
    }

    // MARK: - Exit status + capture

    func testCapturesStdoutAndStderrAndExitCode() async throws {
        let script = try makeScript(
            """
            echo "hello-out"
            echo "hello-err" 1>&2
            exit 7
            """
        )
        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: [:],
            workingDirectory: try makeWorkingDirectory()
        )
        let result = await ProcessRunner.shared.run(launch)

        XCTAssertEqual(result.outcome, .completed(exitCode: 7))
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "hello-out\n")
        XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "hello-err\n")
        XCTAssertFalse(result.standardOutputTruncated)
    }

    // MARK: - Dead cwd is skipped, not failed

    func testDeadWorkingDirectoryIsSkippedWithoutSpawning() async throws {
        let marker = scratch.appendingPathComponent("did-run.txt")
        let script = try makeScript(#"touch "$MB_OUT""#)
        let deletedCwd = scratch.appendingPathComponent("gone-\(UUID().uuidString)")

        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: ["MB_OUT": marker.path],
            workingDirectory: deletedCwd
        )
        let result = await ProcessRunner.shared.run(launch)

        XCTAssertEqual(result.outcome, .skipped(.workingDirectoryMissing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "process must not have spawned")
    }

    func testMissingExecutableIsSkipped() async throws {
        let launch = ProcessLaunch(
            executableURL: scratch.appendingPathComponent("no-such-binary"),
            arguments: [],
            environment: [:],
            workingDirectory: try makeWorkingDirectory()
        )
        let result = await ProcessRunner.shared.run(launch)
        XCTAssertEqual(result.outcome, .skipped(.executableMissing))
    }

    // MARK: - Large output cannot deadlock

    func testLargeOutputDrainsWithoutDeadlockAndTruncates() async throws {
        // ~4 MiB to stdout — far past any single pipe buffer. If draining were not
        // concurrent, the child would block forever on a full pipe.
        let script = try makeScript(
            """
            for i in $(seq 1 65536); do
              printf '%s\\n' "0123456789012345678901234567890123456789012345678901234567890123"
            done
            """
        )
        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: [:],
            workingDirectory: try makeWorkingDirectory(),
            maximumCapturedBytes: 64 * 1024
        )
        let result = await ProcessRunner.shared.run(launch)

        XCTAssertEqual(result.outcome, .completed(exitCode: 0))
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertEqual(result.standardOutput.count, 64 * 1024, "capture is bounded")
        XCTAssertGreaterThan(result.standardOutputByteCount, 4_000_000, "full stream was still drained")
    }

    // MARK: - Timeout cleans up the process tree

    func testTimeoutTerminatesProcessTreeAndReportsTimedOut() async throws {
        let childPidFile = scratch.appendingPathComponent("grandchild.pid")
        let script = try makeScript(
            """
            sleep 120 &
            echo $! > "$MB_OUT"
            wait
            """
        )
        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: ["MB_OUT": childPidFile.path],
            workingDirectory: try makeWorkingDirectory()
        )

        let started = Date()
        let result = await ProcessRunner.shared.run(launch, timeout: 1)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "timeout must not wait for the full sleep")

        let grandchild = try await readPID(from: childPidFile)
        try await assertProcessDies(grandchild)
    }

    // MARK: - Cancellation cleans up the process tree

    func testCancellationTerminatesProcessTreeAndReportsCancelled() async throws {
        let childPidFile = scratch.appendingPathComponent("grandchild.pid")
        let script = try makeScript(
            """
            sleep 120 &
            echo $! > "$MB_OUT"
            wait
            """
        )
        let launch = ProcessLaunch(
            executableURL: script,
            arguments: [],
            environment: ["MB_OUT": childPidFile.path],
            workingDirectory: try makeWorkingDirectory()
        )

        let task = Task { await ProcessRunner.shared.run(launch, timeout: 60) }
        // Give the child time to spawn its grandchild and record the pid.
        try await waitForFile(childPidFile)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.outcome, .cancelled)
        let grandchild = try await readPID(from: childPidFile)
        try await assertProcessDies(grandchild)
    }

    // MARK: - PID helpers

    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("child never recorded its grandchild pid")
    }

    private func readPID(from url: URL) async throws -> pid_t {
        try await waitForFile(url)
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = pid_t(text) else {
            throw XCTSkip("unparseable grandchild pid: \(text)")
        }
        return value
    }

    /// Polls until `kill(pid, 0)` reports the process no longer exists.
    private func assertProcessDies(_ pid: pid_t, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("process \(pid) in the tree survived cleanup")
    }
}
