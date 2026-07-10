import Foundation
import os

// MARK: - SessionWakeDiagnosticRecord

/// One structured diagnostic line. The type deliberately contains **only**
/// metadata — outcome, timings, and byte counts. There is no field for a prompt,
/// a transcript, a resume source, a credential, or a tail of the child's output,
/// so a raw response can never reach the default log by construction.
struct SessionWakeDiagnosticRecord: Codable, Equatable {
    /// When the event was recorded.
    let timestampEpoch: Double
    /// The event kind, e.g. `wake-attempt`, `lock-contended`, `legacy-blocked`.
    let event: String
    /// A stable, non-sensitive outcome label, e.g. `completed`, `timed-out`, `skipped`.
    let outcome: String
    /// An opaque session identifier/fingerprint — never transcript content.
    let sessionFingerprint: String?
    /// The selected wake account id.
    let accountID: String?
    /// The working directory path (metadata only).
    let workingDirectory: String?
    /// `safe` or `bypass`.
    let permissionMode: String?
    let exitCode: Int32?
    let durationMs: Int?
    let stdoutByteCount: Int?
    let stderrByteCount: Int?
    let stdoutTruncated: Bool?
    let stderrTruncated: Bool?
    /// The lock result, e.g. `acquired`, `contended`, `legacy-active`.
    let lockOutcome: String?

    init(
        timestampEpoch: Double,
        event: String,
        outcome: String,
        sessionFingerprint: String? = nil,
        accountID: String? = nil,
        workingDirectory: String? = nil,
        permissionMode: String? = nil,
        exitCode: Int32? = nil,
        durationMs: Int? = nil,
        stdoutByteCount: Int? = nil,
        stderrByteCount: Int? = nil,
        stdoutTruncated: Bool? = nil,
        stderrTruncated: Bool? = nil,
        lockOutcome: String? = nil
    ) {
        self.timestampEpoch = timestampEpoch
        self.event = event
        self.outcome = outcome
        self.sessionFingerprint = sessionFingerprint
        self.accountID = accountID
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stdoutByteCount = stdoutByteCount
        self.stderrByteCount = stderrByteCount
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.lockOutcome = lockOutcome
    }
}

// MARK: - SessionWakeDiagnostics

/// Append-only JSON-lines logger for Session Wake, with private permissions,
/// size-based rotation, and bounded retention.
///
/// - The log directory is `0700` and every log file is `0600`.
/// - Each record is one JSON line of metadata; output bodies are never written.
/// - When the current file would exceed `maximumFileBytes` it is rotated to
///   `session-wake.log.1`, older archives shift up, and anything beyond
///   `maximumFiles` total is deleted.
final class SessionWakeDiagnostics: @unchecked Sendable {
    static let shared = SessionWakeDiagnostics()

    let directory: URL
    let baseName: String
    let maximumFileBytes: Int
    let maximumFiles: Int

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "dev.meterbar.app.SessionWake.Diagnostics")
    private let encoder: JSONEncoder

    init(
        directory: URL = SessionWakeSupport.logDirectory(),
        baseName: String = "session-wake.log",
        maximumFileBytes: Int = 512 * 1024,
        maximumFiles: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.baseName = baseName
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumFiles = max(1, maximumFiles)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        // Sorted keys keep lines stable and greppable; still one line per record.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    var currentLogURL: URL {
        directory.appendingPathComponent(baseName, isDirectory: false)
    }

    /// Records one diagnostic line to the private log file and emits a redacted
    /// summary to the unified log. Failures are swallowed — diagnostics must never
    /// break a wake run.
    func record(_ record: SessionWakeDiagnosticRecord) {
        queue.sync {
            do {
                try writeLine(for: record)
            } catch {
                AppLog.sessionWake.error("Failed to write session-wake diagnostic: \(error.localizedDescription)")
            }
        }
        // Only non-sensitive fields are surfaced to os_log; paths and identifiers
        // stay in the private file.
        let summary = [
            "event=\(record.event)",
            "outcome=\(record.outcome)",
            "exit=\(record.exitCode ?? -999)",
            "durationMs=\(record.durationMs ?? 0)",
            "stdout=\(record.stdoutByteCount ?? 0)",
            "stderr=\(record.stderrByteCount ?? 0)"
        ].joined(separator: " ")
        AppLog.sessionWake.info("wake \(summary, privacy: .public)")
    }

    private func writeLine(for record: SessionWakeDiagnosticRecord) throws {
        try SessionWakeSupport.ensurePrivateDirectory(directory, fileManager: fileManager)

        var line = try encoder.encode(record)
        line.append(0x0A) // newline

        rotateIfNeeded(incomingBytes: line.count)

        if !fileManager.fileExists(atPath: currentLogURL.path) {
            fileManager.createFile(
                atPath: currentLogURL.path,
                contents: nil,
                attributes: [.posixPermissions: SessionWakeSupport.filePermissions]
            )
        }

        let handle = try FileHandle(forWritingTo: currentLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // Enforce private permissions even if the file predated us.
        try? fileManager.setAttributes(
            [.posixPermissions: SessionWakeSupport.filePermissions],
            ofItemAtPath: currentLogURL.path
        )
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        guard let size = currentFileSize(), size + incomingBytes > maximumFileBytes else { return }

        // Only the current file is retained when no archives are allowed.
        guard maximumFiles > 1 else {
            try? fileManager.removeItem(at: currentLogURL)
            return
        }

        // Drop the oldest permitted archive, then shift the rest up by one.
        let oldest = archiveURL(index: maximumFiles - 1)
        try? fileManager.removeItem(at: oldest)
        if maximumFiles >= 3 {
            for index in stride(from: maximumFiles - 2, through: 1, by: -1) {
                let source = archiveURL(index: index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: archiveURL(index: index + 1))
            }
        }
        try? fileManager.moveItem(at: currentLogURL, to: archiveURL(index: 1))
    }

    private func archiveURL(index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index)", isDirectory: false)
    }

    private func currentFileSize() -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogURL.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
