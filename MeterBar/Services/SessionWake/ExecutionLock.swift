import Darwin
import Foundation

// MARK: - LockHolderKind

/// Who is holding (or contending for) the single execution lock. One protocol is
/// shared across the app, the bundled CLI, and — during migration — the legacy
/// watcher, so the three can never run a wake pass at the same time.
enum LockHolderKind: String, Codable, Equatable {
    case app
    case cli
    case legacyWatcher
}

// MARK: - LockHolder

/// The descriptor the current holder writes into the lock file so a contender can
/// report *who* holds it and offer actionable guidance.
struct LockHolder: Codable, Equatable {
    let kind: LockHolderKind
    let pid: Int32
    let host: String
    let startedAtEpoch: Double
    let executablePath: String?

    var startedAt: Date { Date(timeIntervalSince1970: startedAtEpoch) }
}

// MARK: - LockAcquisition

/// The outcome of trying to take the execution lock.
enum LockAcquisition: Equatable {
    /// The lock is held for this run. Call `release()` when finished.
    case acquired(AcquiredLock)
    /// Another app/CLI instance holds the lock. `holder` is present when its
    /// descriptor could be read.
    case contended(LockHolder?)
    /// The legacy Python/launchd watcher is still running. It predates the flock
    /// protocol, so it is detected out-of-band and reported with guidance.
    case legacyWatcherActive(pid: Int32, guidance: String)
    /// The lock file could not be opened at all.
    case failed(String)

    static func == (lhs: LockAcquisition, rhs: LockAcquisition) -> Bool {
        switch (lhs, rhs) {
        case let (.acquired(a), .acquired(b)):
            return a === b
        case let (.contended(a), .contended(b)):
            return a == b
        case let (.legacyWatcherActive(pidA, guidanceA), .legacyWatcherActive(pidB, guidanceB)):
            return pidA == pidB && guidanceA == guidanceB
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - AcquiredLock

/// A held advisory lock. The `flock` is bound to this file descriptor: closing it
/// (via `release()` or deinit, or the OS on process death) frees the lock, so a
/// crashed holder never wedges the next run.
final class AcquiredLock {
    private let descriptor: Int32
    private let lockFileURL: URL
    let holder: LockHolder
    private var released = false

    init(descriptor: Int32, lockFileURL: URL, holder: LockHolder) {
        self.descriptor = descriptor
        self.lockFileURL = lockFileURL
        self.holder = holder
    }

    /// Releases the advisory lock and clears the stale descriptor so a later
    /// reader does not attribute the (now free) lock to us.
    func release() {
        guard !released else { return }
        released = true
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}

// MARK: - LegacyWatcherProbe

/// Detects the legacy Python/launchd watcher during the migration window.
///
/// The legacy watcher does not participate in the `flock` protocol, so its
/// presence is detected via the pid file it maintains. A live pid means the two
/// systems would fight over the same sessions, so the wake run is refused with
/// guidance to stop the legacy job first.
struct LegacyWatcherProbe {
    let pidFileURL: URL
    let isProcessAlive: (Int32) -> Bool

    init(
        pidFileURL: URL,
        isProcessAlive: @escaping (Int32) -> Bool = LegacyWatcherProbe.processIsAlive
    ) {
        self.pidFileURL = pidFileURL
        self.isProcessAlive = isProcessAlive
    }

    /// The documented migration handshake path the legacy watcher writes its pid
    /// to. Present only while the legacy job has not yet been removed (#99).
    static func standard(home: String = ServiceSupport.realHomeDirectory()) -> LegacyWatcherProbe {
        LegacyWatcherProbe(
            pidFileURL: SessionWakeSupport.baseDirectory(home: home)
                .appendingPathComponent("legacy-watcher.pid", isDirectory: false)
        )
    }

    /// The pid of the running legacy watcher, or `nil` if none is active. A pid
    /// file naming a dead process is treated as absent (stale).
    func activePID() -> Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0, isProcessAlive(pid) else { return nil }
        return pid
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        // `kill(pid, 0)` succeeds for a live process we own; EPERM means it exists
        // but is owned by someone else; ESRCH means it is gone.
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - ExecutionLock

/// The single mutual-exclusion gate for Session Wake execution.
///
/// Backed by an advisory `flock` on one shared file. The lock is taken only when
/// a run is actually ready to launch — never held across the long quota waits the
/// watcher performs — so an idle waiting watcher never blocks a manual "Resume
/// Now" or the CLI.
final class ExecutionLock {
    let lockFileURL: URL
    private let legacyProbe: LegacyWatcherProbe?
    private let fileManager: FileManager

    init(
        lockFileURL: URL = SessionWakeSupport.lockFileURL(),
        legacyProbe: LegacyWatcherProbe? = LegacyWatcherProbe.standard(),
        fileManager: FileManager = .default
    ) {
        self.lockFileURL = lockFileURL
        self.legacyProbe = legacyProbe
        self.fileManager = fileManager
    }

    /// Attempts to take the lock for `kind`. Non-blocking: a held lock is reported
    /// immediately rather than waited on.
    func acquire(kind: LockHolderKind, now: Date = Date()) -> LockAcquisition {
        // 1. Refuse if the legacy watcher is still running (migration guard).
        if let pid = legacyProbe?.activePID() {
            return .legacyWatcherActive(pid: pid, guidance: Self.legacyGuidance(pid: pid))
        }

        // 2. Ensure the private lock directory exists.
        do {
            try SessionWakeSupport.ensurePrivateDirectory(
                lockFileURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
        } catch {
            return .failed("lock directory: \(error.localizedDescription)")
        }

        // 3. Open (or create) the shared lock file with private permissions.
        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT, mode_t(SessionWakeSupport.filePermissions))
        guard descriptor >= 0 else {
            return .failed("open lock: \(String(cString: strerror(errno)))")
        }
        fchmod(descriptor, mode_t(SessionWakeSupport.filePermissions))

        // 4. Non-blocking exclusive advisory lock.
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let blocked = errno == EWOULDBLOCK
            close(descriptor)
            return blocked ? .contended(readHolder()) : .failed("flock: \(String(cString: strerror(errno)))")
        }

        // 5. Record our descriptor for contenders to read.
        let holder = LockHolder(
            kind: kind,
            pid: getpid(),
            host: ProcessInfo.processInfo.hostName,
            startedAtEpoch: now.timeIntervalSince1970,
            executablePath: Bundle.main.executablePath
        )
        writeHolder(holder, to: descriptor)
        return .acquired(AcquiredLock(descriptor: descriptor, lockFileURL: lockFileURL, holder: holder))
    }

    /// Reads the current holder descriptor without taking the lock. Returns `nil`
    /// when the file is empty (a holder that has not written yet, or a released lock).
    func readHolder() -> LockHolder? {
        guard let data = try? Data(contentsOf: lockFileURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(LockHolder.self, from: data)
    }

    private func writeHolder(_ holder: LockHolder, to descriptor: Int32) {
        guard let data = try? JSONEncoder().encode(holder) else { return }
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = write(descriptor, base + written, raw.count - written)
                if count > 0 {
                    written += count
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        fsync(descriptor)
    }

    private static func legacyGuidance(pid: Int32) -> String {
        "The legacy Session Wake watcher (pid \(pid)) is still running. "
            + "Stop it (unload its launchd job) before using the native watcher so the two "
            + "do not resume the same sessions."
    }
}
