import Foundation
@testable import MeterBar
import XCTest

final class ClaudeSessionRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A fake `claude` that records argv/cwd/CLAUDE_CONFIG_DIR to `MB_OUT` and can
    /// emit configurable stdout/stderr and exit code (via `MB_STDOUT`,
    /// `MB_STDERR`, `MB_EXIT`).
    private func makeFakeClaude() throws -> URL {
        let url = scratch.appendingPathComponent("claude-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        set -u
        {
          echo "CWD=$(pwd)"
          echo "CONFIG=${CLAUDE_CONFIG_DIR:-NONE}"
          echo "ARGC=$#"
          for a in "$@"; do echo "ARG=$a"; done
        } > "$MB_OUT"
        if [ -n "${MB_STDOUT:-}" ]; then echo "$MB_STDOUT"; fi
        if [ -n "${MB_STDERR:-}" ]; then echo "$MB_STDERR" 1>&2; fi
        exit "${MB_EXIT:-0}"
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeWorkingDirectory() throws -> URL {
        let url = scratch.appendingPathComponent("cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConfigDirectory() throws -> URL {
        let url = scratch.appendingPathComponent("config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRunner(
        fakeClaude: URL,
        environment: [String: String],
        lockURL: URL? = nil,
        diagnostics: SessionWakeDiagnostics? = nil
    ) -> ClaudeSessionRunner {
        ClaudeSessionRunner(
            lock: ExecutionLock(
                lockFileURL: lockURL ?? scratch.appendingPathComponent("execution.lock"),
                legacyProbe: nil
            ),
            diagnostics: diagnostics ?? SessionWakeDiagnostics(directory: scratch.appendingPathComponent("logs")),
            resolveBinary: { _ in fakeClaude },
            baseEnvironment: environment
        )
    }

    private func account(configDirectory: URL) -> ClaudeCodeAccount {
        ClaudeCodeAccount(id: UUID(), name: "Test", configDirectory: configDirectory.path)
    }

    // MARK: - Argv contract

    func testSafeArgumentsContract() {
        let arguments = ClaudeWakeCommand.arguments(
            sessionID: "sess-1",
            prompt: "continue",
            outputFormat: "text",
            permission: .safe
        )
        XCTAssertEqual(
            arguments,
            ["--resume", "sess-1", "--print", "continue", "--output-format", "text", "--permission-mode", "default"]
        )
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
    }

    func testBypassArgumentsContract() throws {
        let ack = try XCTUnwrap(PermissionBypassAcknowledgement(confirmed: true, reason: "trusted"))
        let arguments = ClaudeWakeCommand.arguments(
            sessionID: "sess-1",
            prompt: "continue",
            outputFormat: "text",
            permission: .bypass(ack)
        )
        XCTAssertTrue(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(arguments.contains("--permission-mode"))
    }

    // MARK: - Exact argv / env / cwd via fake executable

    func testWakePassesAccountConfigDirectoryAndArgvAndCwd() async throws {
        let fake = try makeFakeClaude()
        let outFile = scratch.appendingPathComponent("capture.txt")
        let cwd = try makeWorkingDirectory()
        let config = try makeConfigDirectory()
        let runner = makeRunner(fakeClaude: fake, environment: ["MB_OUT": outFile.path])

        let target = WakeTarget(sessionID: "SID-42", workingDirectory: cwd, account: account(configDirectory: config))
        let outcome = await runner.runWake(target)

        XCTAssertEqual(outcome, .completed(exitCode: 0))
        let captured = try String(contentsOf: outFile, encoding: .utf8)
        XCTAssertTrue(captured.contains("CONFIG=\(config.path)"), captured)
        XCTAssertTrue(captured.contains("ARG=--resume"), captured)
        XCTAssertTrue(captured.contains("ARG=SID-42"), captured)
        XCTAssertTrue(captured.contains("ARG=--permission-mode"), captured)
        XCTAssertTrue(captured.contains("/\(cwd.lastPathComponent)\n"), captured)
    }

    // MARK: - Dead worktree skipped, queue continues

    func testDeadWorktreeIsSkippedAndQueueContinues() async throws {
        let fake = try makeFakeClaude()
        let outFile = scratch.appendingPathComponent("capture.txt")
        let runner = makeRunner(fakeClaude: fake, environment: ["MB_OUT": outFile.path])

        let deadTarget = WakeTarget(
            sessionID: "dead",
            workingDirectory: scratch.appendingPathComponent("gone-\(UUID().uuidString)"),
            account: account(configDirectory: try makeConfigDirectory())
        )
        let liveTarget = WakeTarget(
            sessionID: "live",
            workingDirectory: try makeWorkingDirectory(),
            account: account(configDirectory: try makeConfigDirectory())
        )

        let results = await runner.runQueue([deadTarget, liveTarget])

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].outcome, .skipped(.workingDirectoryMissing))
        XCTAssertEqual(results[1].outcome, .completed(exitCode: 0))
        // The live target actually ran after the dead one was skipped.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outFile.path))
        let captured = try String(contentsOf: outFile, encoding: .utf8)
        XCTAssertTrue(captured.contains("ARG=live"), captured)
    }

    // MARK: - Permission denial is structured, never bypassed

    func testPermissionDenialIsStructuredAndNeverAddsBypassFlag() async throws {
        let fake = try makeFakeClaude()
        let outFile = scratch.appendingPathComponent("capture.txt")
        let runner = makeRunner(
            fakeClaude: fake,
            environment: [
                "MB_OUT": outFile.path,
                "MB_STDERR": "Error: permission denied for Bash(rm)",
                "MB_EXIT": "1"
            ]
        )

        let target = WakeTarget(
            sessionID: "sid",
            workingDirectory: try makeWorkingDirectory(),
            account: account(configDirectory: try makeConfigDirectory())
        )
        // Explicitly run in the default SAFE mode.
        let outcome = await runner.runWake(target, config: WakeExecutionConfig(permissionMode: .safe))

        XCTAssertEqual(outcome, .permissionDenied)
        // The argv the fake saw must never contain the bypass flag — no auto-upgrade.
        let captured = try String(contentsOf: outFile, encoding: .utf8)
        XCTAssertFalse(captured.contains("--dangerously-skip-permissions"), captured)
    }

    // MARK: - Lock contention

    func testWakeIsRejectedWhenLockAlreadyHeld() async throws {
        let fake = try makeFakeClaude()
        let outFile = scratch.appendingPathComponent("capture.txt")
        let lockURL = scratch.appendingPathComponent("execution.lock")

        // An external holder (simulating another app/CLI instance) takes the lock.
        let external = ExecutionLock(lockFileURL: lockURL, legacyProbe: nil)
        guard case let .acquired(held) = external.acquire(kind: .cli) else {
            return XCTFail("external acquisition should succeed")
        }
        defer { held.release() }

        let runner = makeRunner(fakeClaude: fake, environment: ["MB_OUT": outFile.path], lockURL: lockURL)
        let target = WakeTarget(
            sessionID: "sid",
            workingDirectory: try makeWorkingDirectory(),
            account: account(configDirectory: try makeConfigDirectory())
        )
        let outcome = await runner.runWake(target)

        guard case let .lockContended(holder) = outcome else {
            return XCTFail("expected lock contention, got \(outcome)")
        }
        XCTAssertEqual(holder?.kind, .cli)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outFile.path), "no process should have spawned")
    }

    // MARK: - Diagnostics contain no output

    func testDiagnosticsRecordOutcomeButNotProcessOutput() async throws {
        let fake = try makeFakeClaude()
        let outFile = scratch.appendingPathComponent("capture.txt")
        let secret = "sk-ant-DO-NOT-LOG-THIS"
        let diagnostics = SessionWakeDiagnostics(directory: scratch.appendingPathComponent("logs"))
        let runner = makeRunner(
            fakeClaude: fake,
            environment: ["MB_OUT": outFile.path, "MB_STDOUT": secret],
            diagnostics: diagnostics
        )

        let target = WakeTarget(
            sessionID: "sid-log",
            workingDirectory: try makeWorkingDirectory(),
            account: account(configDirectory: try makeConfigDirectory())
        )
        let outcome = await runner.runWake(target)
        XCTAssertEqual(outcome, .completed(exitCode: 0))

        let log = try String(contentsOf: diagnostics.currentLogURL, encoding: .utf8)
        XCTAssertFalse(log.contains(secret), "raw process output must never reach the diagnostic log")
        XCTAssertTrue(log.contains("wake-attempt"))
        XCTAssertTrue(log.contains("completed"))
        XCTAssertTrue(log.contains("sid-log"))
    }
}
