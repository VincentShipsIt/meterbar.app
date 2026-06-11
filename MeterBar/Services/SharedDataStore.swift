import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared data store using App Groups for Widget extension access
class SharedDataStore {
    static let shared = SharedDataStore()
    
    private let appGroupIdentifier = "group.dev.shipshit.meterbar"
    private let metricsKey = "cached_usage_metrics"
    
    private var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    private init() {}
    
    func saveMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        guard let containerURL = containerURL else {
            print("[SharedDataStore] App Group container not available. Enable App Groups for both app and widget targets.")
            return
        }

        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")
        
        let encoded = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        
        do {
            let data = try JSONEncoder().encode(encoded)
            try data.write(to: fileURL)
            reloadWidgetTimelines()
        } catch {
            print("[SharedDataStore] Failed to save metrics: \(error)")
        }
    }
    
    func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard let containerURL = containerURL else { return [:] }
        
        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")
        
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return [:]
        }
        
        return decoded.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            if let service = ServiceType(rawValue: pair.key) {
                result[service] = pair.value
            }
        }
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        }
        #endif
    }
}
