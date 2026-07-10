import CryptoKit
import Foundation
import os

// MARK: - Fingerprint

/// Deterministic identity of a single blocking event, used to guarantee a
/// handled block is never rediscovered or resumed twice — including across
/// app relaunches.
enum SessionBlockFingerprint {
    static func make(sessionID: String, blockedAt: Date, reason: SessionBlockReason) -> String {
        let payload = "\(sessionID)|\(Int(blockedAt.timeIntervalSince1970.rounded()))|\(reason.rawValue)"
        return Data(SHA256.hash(data: Data(payload.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Replay ledger

/// Persistent set of handled block fingerprints
/// (`~/Library/Application Support/MeterBar/session-wake-ledger-v1.json`).
///
/// Reads are strictly read-only: `containsHandled` never creates or touches
/// the storage file, so discovery/preview stays mutation-free. Only an
/// explicit `markHandled` (a later, non-preview action) writes.
final class SessionWakeReplayLedger {
    struct Entry: Codable, Equatable {
        let fingerprint: String
        let handledAt: Date
    }

    static let shared = SessionWakeReplayLedger(storageURL: SessionWakeReplayLedger.defaultStorageURL)

    static var defaultStorageURL: URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return supportDirectory
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("session-wake-ledger-v1.json")
    }

    private let storageURL: URL?
    private let maxEntries: Int
    private let lock = NSLock()
    private var cachedEntries: [Entry]?

    init(storageURL: URL?, maxEntries: Int = 500) {
        self.storageURL = storageURL
        self.maxEntries = max(1, maxEntries)
    }

    func containsHandled(_ fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedEntries().contains { $0.fingerprint == fingerprint }
    }

    func markHandled(_ fingerprint: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var entries = loadedEntries().filter { $0.fingerprint != fingerprint }
        entries.append(Entry(fingerprint: fingerprint, handledAt: date))
        entries.sort { $0.handledAt < $1.handledAt }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        cachedEntries = entries
        persist(entries)
    }

    // MARK: - Private (callers hold `lock`)

    private func loadedEntries() -> [Entry] {
        if let cachedEntries {
            return cachedEntries
        }
        var entries: [Entry] = []
        if let storageURL, let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // A corrupt ledger degrades to empty rather than failing the scan.
            entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        }
        cachedEntries = entries
        return entries
    }

    private func persist(_ entries: [Entry]) {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(entries)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            AppLog.storage.error("Session wake ledger save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
