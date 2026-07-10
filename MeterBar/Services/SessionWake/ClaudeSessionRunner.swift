import Foundation
import MeterBarShared

// MARK: - WakeTarget

/// One blocked session to resume. Discovery (#95) will produce these; the runner
/// only needs the session id, the canonical working directory, and the account
/// whose `CLAUDE_CONFIG_DIR` the resume must run under.
struct WakeTarget: Equatable {
    let sessionID: String
    let workingDirectory: URL
    let account: ClaudeCodeAccount
}

// MARK: - WakeExecutionConfig

/// Bounded, conservative execution parameters. Unlimited runs are never the
/// default: there is always a timeout, and bypass is opt-in.
struct WakeExecutionConfig {
    var prompt: String
    var permissionMode: WakePermissionMode
    var timeout: TimeInterval
    var outputFormat: String
    var maximumCapturedBytes: Int

    init(
        prompt: String = "continue",
        permissionMode: WakePermissionMode = .default,
        timeout: TimeInterval = 7200,
        outputFormat: String = "text",
        maximumCapturedBytes: Int = 64 * 1024
    ) {
        self.prompt = prompt
        self.permissionMode = permissionMode
        self.timeout = timeout
        self.outputFormat = outputFormat
        self.maximumCapturedBytes = maximumCapturedBytes
    }
}

// MARK: - WakeAttemptOutcome

/// The structured result of one resume attempt. Every terminal condition is a
/// named case — a permission denial is `permissionDenied`, never a silent
/// fallthrough to bypass.
enum WakeAttemptOutcome: Equatable {
    case completed(exitCode: Int32)
    case permissionDenied
    case timedOut
    case cancelled
    case skipped(ProcessSkipReason)
    case lockContended(LockHolder?)
    case legacyWatcherActive(pid: Int32, guidance: String)
    case failed(String)

    var isSuccess: Bool { self == .completed(exitCode: 0) }
}

// MARK: - ClaudeWakeCommand

/// Builds the exact Claude CLI argument vector for a headless resume. Pure and
/// separately tested so the flag contract can be validated against the real CLI
/// in #99 without touching process management.
enum ClaudeWakeCommand {
    static func arguments(
        sessionID: String,
        prompt: String,
        outputFormat: String,
        permission: WakePermissionMode
    ) -> [String] {
        ["--resume", sessionID, "--print", prompt, "--output-format", outputFormat] + permission.claudeArguments
    }
}

// MARK: - ClaudeSessionRunner

/// The one native runner that resumes blocked Claude sessions for both the app
/// and the bundled CLI.
///
/// Responsibilities:
/// - Take the shared execution lock only when a run is actually starting.
/// - Build an argv-only launch (no shell) with the account's `CLAUDE_CONFIG_DIR`.
/// - Delegate cwd revalidation, draining, timeout, and tree cleanup to
///   `ProcessRunner`.
/// - Classify the result — including permission denial — and record structured,
///   output-free diagnostics.
/// - Continue a queue past a skipped (dead-worktree) target.
final class ClaudeSessionRunner {
    private let processRunner: ProcessRunner
    private let lock: ExecutionLock
    private let diagnostics: SessionWakeDiagnostics
    private let resolveBinary: (ClaudeCodeAccount) -> URL?
    private let baseEnvironment: [String: String]
    private let dateProvider: () -> Date

    init(
        processRunner: ProcessRunner = .shared,
        lock: ExecutionLock = ExecutionLock(),
        diagnostics: SessionWakeDiagnostics = .shared,
        resolveBinary: @escaping (ClaudeCodeAccount) -> URL? = ClaudeSessionRunner.defaultBinaryResolver,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.lock = lock
        self.diagnostics = diagnostics
        self.resolveBinary = resolveBinary
        self.baseEnvironment = baseEnvironment
        self.dateProvider = dateProvider
    }

    static let defaultBinaryResolver: (ClaudeCodeAccount) -> URL? = { _ in
        CLIBinaryLocator.resolve(command: "claude", overrideEnvVar: "CLAUDE_CLI_PATH")
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Single attempt

    /// Resumes a single session under the shared lock.
    func runWake(
        _ target: WakeTarget,
        config: WakeExecutionConfig = WakeExecutionConfig(),
        lockKind: LockHolderKind = .app
    ) async -> WakeAttemptOutcome {
        switch lock.acquire(kind: lockKind, now: dateProvider()) {
        case let .acquired(held):
            defer { held.release() }
            return await execute(target, config: config)
        case let .contended(holder):
            recordLockEvent("lock-contended", target: target, lockOutcome: "contended")
            return .lockContended(holder)
        case let .legacyWatcherActive(pid, guidance):
            recordLockEvent("legacy-blocked", target: target, lockOutcome: "legacy-active")
            return .legacyWatcherActive(pid: pid, guidance: guidance)
        case let .failed(message):
            recordLockEvent("lock-failed", target: target, lockOutcome: "failed")
            return .failed(message)
        }
    }

    // MARK: Queue

    /// Resumes each target in order under a single lock. A skipped (dead-worktree)
    /// target is recorded and the queue continues; cancellation stops cleanly.
    func runQueue(
        _ targets: [WakeTarget],
        config: WakeExecutionConfig = WakeExecutionConfig(),
        lockKind: LockHolderKind = .app
    ) async -> [(target: WakeTarget, outcome: WakeAttemptOutcome)] {
        switch lock.acquire(kind: lockKind, now: dateProvider()) {
        case let .acquired(held):
            defer { held.release() }
            var results: [(target: WakeTarget, outcome: WakeAttemptOutcome)] = []
            for target in targets {
                if Task.isCancelled {
                    results.append((target, .cancelled))
                    continue
                }
                let outcome = await execute(target, config: config)
                results.append((target, outcome))
            }
            return results
        case let .contended(holder):
            return targets.map { ($0, .lockContended(holder)) }
        case let .legacyWatcherActive(pid, guidance):
            return targets.map { ($0, .legacyWatcherActive(pid: pid, guidance: guidance)) }
        case let .failed(message):
            return targets.map { ($0, .failed(message)) }
        }
    }

    // MARK: Execution (assumes the lock is held)

    private func execute(_ target: WakeTarget, config: WakeExecutionConfig) async -> WakeAttemptOutcome {
        guard let executableURL = resolveBinary(target.account) else {
            let outcome = WakeAttemptOutcome.failed("Claude CLI not found")
            record(outcome, target: target, config: config, result: nil)
            return outcome
        }

        let launch = ProcessLaunch(
            executableURL: executableURL,
            arguments: ClaudeWakeCommand.arguments(
                sessionID: target.sessionID,
                prompt: config.prompt,
                outputFormat: config.outputFormat,
                permission: config.permissionMode
            ),
            environment: environment(for: target.account),
            workingDirectory: target.workingDirectory,
            maximumCapturedBytes: config.maximumCapturedBytes
        )

        let result = await processRunner.run(launch, timeout: config.timeout)
        let outcome = Self.outcome(from: result)
        record(outcome, target: target, config: config, result: result)
        return outcome
    }

    /// The environment for a resume: the caller's environment plus deterministic,
    /// color-free output settings and the account's `CLAUDE_CONFIG_DIR`.
    private func environment(for account: ClaudeCodeAccount) -> [String: String] {
        var environment = baseEnvironment
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        if let configDirectory = account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDirectory.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        return environment
    }

    // MARK: Result classification

    static func outcome(from result: ProcessRunResult) -> WakeAttemptOutcome {
        switch result.outcome {
        case let .completed(exitCode):
            if exitCode != 0, indicatesPermissionDenial(result) {
                return .permissionDenied
            }
            return .completed(exitCode: exitCode)
        case let .terminatedBySignal(signal):
            return .failed("terminated by signal \(signal)")
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case let .skipped(reason):
            return .skipped(reason)
        case let .launchFailed(message):
            return .failed(message)
        }
    }

    private static func indicatesPermissionDenial(_ result: ProcessRunResult) -> Bool {
        // Inspect the captured (never-logged) output for an approval-gate signal.
        let combined = (String(data: result.standardOutput, encoding: .utf8) ?? "")
            + "\n"
            + (String(data: result.standardError, encoding: .utf8) ?? "")
        return PermissionDenialDetector.indicatesDenial(in: combined)
    }

    // MARK: Diagnostics

    private func record(
        _ outcome: WakeAttemptOutcome,
        target: WakeTarget,
        config: WakeExecutionConfig,
        result: ProcessRunResult?
    ) {
        let record = SessionWakeDiagnosticRecord(
            timestampEpoch: dateProvider().timeIntervalSince1970,
            event: "wake-attempt",
            outcome: Self.label(for: outcome),
            sessionFingerprint: target.sessionID,
            accountID: target.account.id.uuidString,
            workingDirectory: target.workingDirectory.path,
            permissionMode: config.permissionMode.isBypass ? "bypass" : "safe",
            exitCode: Self.exitCode(for: outcome),
            durationMs: result.map { Int($0.duration * 1000) },
            stdoutByteCount: result?.standardOutputByteCount,
            stderrByteCount: result?.standardErrorByteCount,
            stdoutTruncated: result?.standardOutputTruncated,
            stderrTruncated: result?.standardErrorTruncated,
            lockOutcome: "acquired"
        )
        diagnostics.record(record)
    }

    private func recordLockEvent(_ event: String, target: WakeTarget, lockOutcome: String) {
        diagnostics.record(
            SessionWakeDiagnosticRecord(
                timestampEpoch: dateProvider().timeIntervalSince1970,
                event: event,
                outcome: lockOutcome,
                sessionFingerprint: target.sessionID,
                accountID: target.account.id.uuidString,
                workingDirectory: target.workingDirectory.path,
                lockOutcome: lockOutcome
            )
        )
    }

    static func label(for outcome: WakeAttemptOutcome) -> String {
        switch outcome {
        case let .completed(exitCode):
            return exitCode == 0 ? "completed" : "exit-\(exitCode)"
        case .permissionDenied:
            return "permission-denied"
        case .timedOut:
            return "timed-out"
        case .cancelled:
            return "cancelled"
        case let .skipped(reason):
            switch reason {
            case .workingDirectoryMissing:
                return "skipped-dead-cwd"
            case .executableMissing:
                return "skipped-missing-exe"
            }
        case .lockContended:
            return "lock-contended"
        case .legacyWatcherActive:
            return "legacy-active"
        case .failed:
            return "failed"
        }
    }

    private static func exitCode(for outcome: WakeAttemptOutcome) -> Int32? {
        if case let .completed(exitCode) = outcome { return exitCode }
        return nil
    }
}
