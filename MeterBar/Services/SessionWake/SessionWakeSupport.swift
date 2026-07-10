import Foundation

/// Filesystem conventions shared by the Session Wake runner, lock, and logs.
///
/// Everything Session Wake writes — the advisory lock and the diagnostic logs —
/// lives under one private base directory in the user's real home (the app is
/// un-sandboxed, so this is the same location for the app and the bundled CLI).
/// Directories are created `0700` and files `0600` so no other local user can
/// read a session's metadata.
enum SessionWakeSupport {
    /// Directory permissions: owner-only `rwx`.
    static let directoryPermissions: Int = 0o700
    /// File permissions: owner-only `rw`.
    static let filePermissions: Int = 0o600

    /// `~/Library/Application Support/MeterBar/SessionWake`, resolved against the
    /// real (non-sandbox-container) home directory.
    static func baseDirectory(home: String = ServiceSupport.realHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/MeterBar/SessionWake", isDirectory: true)
    }

    /// The canonical advisory-lock file path shared by the app, `meterbar wake`,
    /// and (post-migration) the legacy watcher.
    static func lockFileURL(home: String = ServiceSupport.realHomeDirectory()) -> URL {
        baseDirectory(home: home).appendingPathComponent("execution.lock", isDirectory: false)
    }

    /// The private directory diagnostic logs are written to.
    static func logDirectory(home: String = ServiceSupport.realHomeDirectory()) -> URL {
        baseDirectory(home: home).appendingPathComponent("logs", isDirectory: true)
    }

    /// Creates `directory` (and intermediates) with private `0700` permissions,
    /// tightening any pre-existing directory that was created more permissively.
    @discardableResult
    static func ensurePrivateDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        }
        // A directory created earlier (or by a different umask) may be too open;
        // enforce the private mode every time.
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directory.path)
        return directory
    }

    /// Writes `data` to `url` and enforces private `0600` permissions.
    static func writePrivateFile(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }
}
