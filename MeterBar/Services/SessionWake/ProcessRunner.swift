import Darwin
import Foundation

// MARK: - ProcessLaunch

/// A fully-resolved description of one child process to launch.
///
/// Session Wake never shells out: the executable, every argument, the
/// environment, and the working directory are passed explicitly so no value is
/// ever re-interpreted by `/bin/sh`. Callers build the argument array; the
/// runner spawns it verbatim via `posix_spawn`.
struct ProcessLaunch: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    /// Upper bound on the bytes retained from each of stdout/stderr. Draining
    /// continues past this bound so the child never blocks on a full pipe, but
    /// only the leading `maximumCapturedBytes` are kept for the caller.
    let maximumCapturedBytes: Int

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        maximumCapturedBytes: Int = 1 << 20
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.maximumCapturedBytes = max(0, maximumCapturedBytes)
    }
}

// MARK: - ProcessRunOutcome

/// Why a run ended. The outcome is the only execution fact that reaches the
/// default diagnostic log — never the captured output itself.
enum ProcessRunOutcome: Equatable {
    /// The child exited on its own with this status code.
    case completed(exitCode: Int32)
    /// The child was terminated by a signal it did not ask for.
    case terminatedBySignal(Int32)
    /// The per-run timeout elapsed and the process tree was killed.
    case timedOut
    /// The caller cancelled the run and the process tree was killed.
    case cancelled
    /// The launch was abandoned before spawning; the queue should continue.
    case skipped(ProcessSkipReason)
    /// The child could not be spawned at all.
    case launchFailed(String)
}

/// A structured, non-executable reason a target was skipped rather than run.
enum ProcessSkipReason: Equatable {
    /// The working directory no longer exists or is not a directory (dead worktree).
    case workingDirectoryMissing
    /// The executable is absent or not runnable.
    case executableMissing
}

// MARK: - ProcessRunResult

/// The result of a single `ProcessRunner.run` call.
///
/// `standardOutput`/`standardError` are bounded copies for the *caller* to parse
/// (for example, to detect a permission denial). They are deliberately kept out
/// of the diagnostic log; only the byte counts, truncation flags, and outcome
/// are considered safe to record.
struct ProcessRunResult: Equatable {
    let outcome: ProcessRunOutcome
    let standardOutput: Data
    let standardError: Data
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
    let standardOutputByteCount: Int
    let standardErrorByteCount: Int
    let duration: TimeInterval

    var didSucceed: Bool {
        outcome == .completed(exitCode: 0)
    }
}

// MARK: - ProcessRunner

/// Spawns and supervises one child process safely.
///
/// Guarantees:
/// - **No shell.** The child is launched from an argument vector via
///   `posix_spawn`; nothing is passed through `/bin/sh`.
/// - **Fresh cwd check.** The working directory is revalidated immediately
///   before spawning; a dead directory yields `.skipped` so the caller's queue
///   can continue instead of aborting.
/// - **No deadlock.** stdout and stderr are drained concurrently and kept
///   flowing even after the capture bound is reached, so a chatty child can
///   never fill a pipe and block.
/// - **Tree cleanup.** The child is made a process-group leader; timeout and
///   cancellation kill the whole group, not just the direct child.
final class ProcessRunner: @unchecked Sendable {
    static let shared = ProcessRunner()

    /// Blocking spawns run here so the semaphore/`waitpid` waits never occupy a
    /// Swift concurrency cooperative thread.
    private let queue = DispatchQueue(
        label: "dev.meterbar.app.SessionWake.ProcessRunner",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Runs `launch`, honouring `timeout` and Swift task cancellation.
    ///
    /// Cancelling the surrounding `Task` kills the child's process group and
    /// resolves the call with `.cancelled`.
    func run(_ launch: ProcessLaunch, timeout: TimeInterval? = nil) async -> ProcessRunResult {
        let control = RunControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = self.runBlocking(launch, timeout: timeout, control: control)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            control.requestCancellation()
        }
    }

    // MARK: Blocking core

    private func runBlocking(
        _ launch: ProcessLaunch,
        timeout: TimeInterval?,
        control: RunControl
    ) -> ProcessRunResult {
        let start = DispatchTime.now()

        // Fresh cwd revalidation immediately before execution. A deleted
        // worktree is skipped, never treated as a launch failure, so the
        // caller's queue keeps moving.
        var isDirectory: ObjCBool = false
        let cwdPath = launch.workingDirectory.path
        guard fileManager.fileExists(atPath: cwdPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Self.result(.skipped(.workingDirectoryMissing), start: start)
        }

        guard fileManager.isExecutableFile(atPath: launch.executableURL.path) else {
            return Self.result(.skipped(.executableMissing), start: start)
        }

        // Pipes: parent reads [0], child writes [1].
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else {
            return Self.result(.launchFailed("stdout pipe: \(String(cString: strerror(errno)))"), start: start)
        }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return Self.result(.launchFailed("stderr pipe: \(String(cString: strerror(errno)))"), start: start)
        }

        let spawn = Self.spawn(launch, stdoutWrite: outPipe[1], stderrWrite: errPipe[1])
        // The child owns the write ends now; the parent must close its copies so
        // the read side observes EOF once the child exits.
        close(outPipe[1])
        close(errPipe[1])

        guard case let .success(pid) = spawn else {
            close(outPipe[0]); close(errPipe[0])
            if case let .failure(message) = spawn {
                return Self.result(.launchFailed(message), start: start)
            }
            return Self.result(.launchFailed("spawn failed"), start: start)
        }

        // Register the process group so cancellation can reach the whole tree.
        // If cancellation already arrived while spawning, kill immediately.
        if control.adoptProcessGroup(pid) {
            Self.killTree(pid)
        }

        let outSink = BoundedSink(limit: launch.maximumCapturedBytes)
        let errSink = BoundedSink(limit: launch.maximumCapturedBytes)
        let drains = DispatchGroup()
        drain(fd: outPipe[0], into: outSink, group: drains)
        drain(fd: errPipe[0], into: errSink, group: drains)

        // Reap on a dedicated thread so we can impose a timeout on the wait.
        let reaped = DispatchSemaphore(value: 0)
        let statusBox = StatusBox()
        queue.async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
            statusBox.set(status)
            reaped.signal()
        }

        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            if reaped.wait(timeout: deadline) == .timedOut {
                timedOut = true
                Self.killTree(pid, signal: SIGTERM)
                if reaped.wait(timeout: .now() + 2) == .timedOut {
                    Self.killTree(pid, signal: SIGKILL)
                    reaped.wait()
                }
            }
        } else {
            reaped.wait()
        }

        // The main child is gone. Sweep any stragglers still in the group so a
        // backgrounded grandchild holding a pipe open cannot wedge the drain.
        if drains.wait(timeout: .now() + 2) == .timedOut {
            Self.killTree(pid, signal: SIGKILL)
            drains.wait()
        }

        let outcome = Self.outcome(
            status: statusBox.get(),
            cancelled: control.wasCancellationRequested,
            timedOut: timedOut
        )
        return ProcessRunResult(
            outcome: outcome,
            standardOutput: outSink.capturedData,
            standardError: errSink.capturedData,
            standardOutputTruncated: outSink.truncated,
            standardErrorTruncated: errSink.truncated,
            standardOutputByteCount: outSink.totalByteCount,
            standardErrorByteCount: errSink.totalByteCount,
            duration: Self.elapsed(since: start)
        )
    }

    // MARK: Draining

    private func drain(fd: Int32, into sink: BoundedSink, group: DispatchGroup) {
        group.enter()
        queue.async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    sink.append(buffer, count: count)
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            group.leave()
        }
    }

    // MARK: Spawning

    private enum SpawnResult {
        case success(pid_t)
        case failure(String)
    }

    private static func spawn(_ launch: ProcessLaunch, stdoutWrite: Int32, stderrWrite: Int32) -> SpawnResult {
        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin from /dev/null; stdout/stderr to the write ends of our pipes.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutWrite)
        posix_spawn_file_actions_addclose(&fileActions, stderrWrite)
        // Run in the caller's working directory. cwd was revalidated above; if it
        // vanished in the interim the spawn fails and we report a launch failure.
        _ = launch.workingDirectory.path.withCString { path in
            posix_spawn_file_actions_addchdir(&fileActions, path)
        }

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Put the child in its own process group (leader == child pid) so timeout
        // and cancellation can signal the entire descendant tree with killpg.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))

        let argv = CStringArray([launch.executableURL.path] + launch.arguments)
        let envp = CStringArray(launch.environment.map { "\($0.key)=\($0.value)" })
        defer { argv.deallocate(); envp.deallocate() }

        var pid = pid_t()
        let code = posix_spawn(&pid, launch.executableURL.path, &fileActions, &attributes, argv.pointer, envp.pointer)
        guard code == 0 else {
            return .failure("posix_spawn: \(String(cString: strerror(code)))")
        }
        return .success(pid)
    }

    /// Sends `signal` to the process group led by `pid`. A negative pid targets
    /// the whole group, so a chatty child that forked helpers is fully cleaned up.
    private static func killTree(_ pid: pid_t, signal: Int32 = SIGKILL) {
        kill(-pid, signal)
    }

    // MARK: Outcome mapping

    private static func outcome(status: Int32, cancelled: Bool, timedOut: Bool) -> ProcessRunOutcome {
        // Cancellation and timeout both killed the tree; report intent, not the
        // resulting SIGKILL.
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        if Self.isExited(status) {
            return .completed(exitCode: Self.exitStatus(status))
        }
        if Self.isSignaled(status) {
            return .terminatedBySignal(Self.termSignal(status))
        }
        return .completed(exitCode: -1)
    }

    // `waitpid` status decoding. The `W*` macros are unavailable in Swift, so the
    // bit math is spelled out to match `<sys/wait.h>`.
    private static func isExited(_ status: Int32) -> Bool { (status & 0x7F) == 0 }
    private static func exitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xFF }
    private static func isSignaled(_ status: Int32) -> Bool {
        let low = status & 0x7F
        return low != 0 && low != 0x7F
    }
    private static func termSignal(_ status: Int32) -> Int32 { status & 0x7F }

    private static func elapsed(since start: DispatchTime) -> TimeInterval {
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return TimeInterval(nanos) / 1_000_000_000
    }

    private static func result(_ outcome: ProcessRunOutcome, start: DispatchTime) -> ProcessRunResult {
        ProcessRunResult(
            outcome: outcome,
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            standardOutputByteCount: 0,
            standardErrorByteCount: 0,
            duration: elapsed(since: start)
        )
    }
}

// MARK: - RunControl

/// Thread-safe cancellation bridge between the async task and the blocking core.
///
/// Cancellation may arrive before the child exists; the process group id is
/// recorded once the child spawns, and any cancellation that arrived first is
/// replayed by the spawner.
private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t?
    private var cancellationRequested = false

    /// Records the spawned group. Returns `true` if cancellation already arrived
    /// and the caller must kill the freshly spawned tree.
    func adoptProcessGroup(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        processGroup = pid
        return cancellationRequested
    }

    func requestCancellation() {
        lock.lock()
        let group = processGroup
        cancellationRequested = true
        lock.unlock()
        if let group {
            kill(-group, SIGKILL)
        }
    }

    var wasCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

// MARK: - StatusBox

/// A lock-guarded `waitpid` status shared with the reaper thread.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 0

    func set(_ value: Int32) {
        lock.lock()
        status = value
        lock.unlock()
    }

    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

// MARK: - BoundedSink

/// Collects a child stream up to a byte cap while still counting everything.
///
/// The cap prevents a runaway child from exhausting memory; draining continues
/// past the cap (the excess is discarded, not the child blocked) so pipes never
/// fill. Only the leading `limit` bytes are retained for the caller.
private final class BoundedSink: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var total = 0

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        total += count
        let remaining = limit - storage.count
        guard remaining > 0 else { return }
        let take = min(remaining, count)
        storage.append(contentsOf: bytes[0..<take])
    }

    var capturedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var totalByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return total > storage.count
    }
}

// MARK: - CStringArray

/// A null-terminated C string vector for `posix_spawn` argv/envp, owning its
/// duplicated strings until `deallocate()`.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for (index, value) in values.enumerated() {
            pointer[index] = strdup(value)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
