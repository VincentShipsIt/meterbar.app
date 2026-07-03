import Foundation
import MeterBarShared
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared data store using App Groups for Widget extension access.
/// Public so the meterbar CLI reads the same file through the same code path
/// instead of maintaining its own copy of the location and decode logic.
public class SharedDataStore {
    public static let shared = SharedDataStore()

    private let appGroupIdentifier = "group.dev.shipshit.meterbar"
    private let metricsKey = StorageKeys.cachedUsageMetrics

    /// Serial queue for off-main disk writes so callers on the MainActor don't
    /// block on file I/O, while still serializing writes to the shared file.
    private let ioQueue = DispatchQueue(label: "dev.shipshit.meterbar.SharedDataStore.io", qos: .utility)

    /// Overrides the App Group container location. `nil` in production (the
    /// container is resolved from the app-group identifier); tests inject a
    /// temp directory so the encode → atomic-write → decode round-trip can run
    /// without the App Group entitlement (unavailable to `swift test`).
    private let directoryOverride: URL?

    /// Invoked after a successful write. Defaults to reloading the widget
    /// timelines; tests inject a spy to assert the write completed.
    private let didWrite: () -> Void

    private var containerURL: URL? {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Defaults reproduce the production singleton exactly; tests inject a
    /// directory + write spy.
    init(directoryOverride: URL? = nil, didWrite: (() -> Void)? = nil) {
        self.directoryOverride = directoryOverride
        self.didWrite = didWrite ?? SharedDataStore.reloadWidgetTimelines
    }

    func saveMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        guard let containerURL = containerURL else {
            AppLog.storage.error("App Group container unavailable; enable App Groups for the app and widget targets.")
            return
        }

        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")

        guard let data = MetricsCodec.encode(metrics) else {
            AppLog.storage.error("Failed to encode shared metrics")
            return
        }

        // Write off the main thread (callers run on the MainActor). Atomic write
        // avoids a torn file if two saves race.
        ioQueue.async { [weak self] in
            do {
                try data.write(to: fileURL, options: [.atomic])
                self?.didWrite()
            } catch {
                AppLog.storage.error("Failed to save shared metrics: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard let containerURL = containerURL else { return [:] }

        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")

        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return MetricsCodec.decode(data)
    }

    /// Blocks until any in-flight async write has completed. Test-only: lets a
    /// test observe the on-disk result of `saveMetrics` deterministically.
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    private static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        }
        #endif
    }
}
