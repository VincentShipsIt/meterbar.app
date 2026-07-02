import AppKit
import SwiftUI

struct DashboardProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let logoKind: ProviderLogoKind
    let lastUpdated: Date
    let limits: [DashboardLimit]

    init(title: String, service: ServiceType, metrics: UsageMetrics) {
        self.id = "\(service.rawValue)-\(title)"
        self.title = title
        self.service = service
        self.logoKind = providerLogoKind(for: service)
        self.lastUpdated = metrics.lastUpdated
        self.limits = [
            DashboardLimit(title: "Session", limit: metrics.sessionLimit),
            DashboardLimit(title: "Weekly", limit: metrics.weeklyLimit),
            DashboardLimit(title: service == .codexCli ? "Code Review" : "Sonnet", limit: metrics.codeReviewLimit)
        ].compactMap { $0 }
    }
}

struct DashboardLimit: Identifiable {
    let id = UUID()
    let title: String
    let usageLimit: UsageLimit

    init?(title: String, limit: UsageLimit?) {
        guard let limit else { return nil }
        self.title = title
        self.usageLimit = limit
    }

    var usedPercent: Double {
        usageLimit.rawPercentage
    }

    var percentLeft: Int {
        let remainingPercent = max(0, 100 - usedPercent)
        return remainingPercent == 0 ? 0 : max(1, Int(ceil(remainingPercent)))
    }
}

let overviewTileMinHeight: CGFloat = 220

struct DailyUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let segments: [DailyUsageProviderSegment]
    let cost: Double

    var totalTokens: Int {
        segments.reduce(0) { $0 + $1.tokens }
    }
}

struct DailyUsageProviderSegment: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let tokens: Int
    let cost: Double
}

struct DailyProviderUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let providers: [DailyProviderUsageSummary]

    var totalTokens: Int {
        providers.reduce(0) { $0 + $1.totalTokens }
    }

    var estimatedCostUSD: Double {
        providers.reduce(0) { $0 + $1.estimatedCostUSD }
    }
}

struct DailyProviderUsageSummary: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }
}

/// Cached date formatters for the dashboard. `DateFormatter` is expensive to
/// allocate, so the daily chart/labels (30+ per render) share these instances.
enum DashboardDateFormat {
    private static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let weekdayMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    static func medium(_ date: Date) -> String { mediumDate.string(from: date) }
    static func month(_ date: Date) -> String { month.string(from: date) }
    static func weekdayMonthDay(_ date: Date) -> String { weekdayMonthDay.string(from: date) }
}
