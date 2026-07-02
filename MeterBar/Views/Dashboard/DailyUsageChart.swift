import SwiftUI

struct DailyUsageChart: View {
    let dailyUsage: [DailyTokenUsage]
    let daysToShow: Int

    private let barSpacing: CGFloat = 4
    private let labelHeight: CGFloat = 22
    private let legendHeight: CGFloat = 18

    // Precomputed once at init instead of on every SwiftUI body access. The
    // grouping + 30-day date arithmetic was previously re-run many times per
    // render (from body, visibleProviders, maxTokens, barWidth, barHeight).
    private let days: [DailyUsageDay]

    init(dailyUsage: [DailyTokenUsage], daysToShow: Int = 30) {
        self.dailyUsage = dailyUsage
        self.daysToShow = daysToShow
        self.days = Self.buildDays(from: dailyUsage, daysToShow: daysToShow)
    }

    private static let providerOrder: [ServiceType] = [.claudeCode, .codexCli, .cursor, .claude, .openai]

    private static func buildDays(from dailyUsage: [DailyTokenUsage], daysToShow: Int) -> [DailyUsageDay] {
        let calendar = Calendar.current
        let normalizedDaysToShow = max(1, daysToShow)
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(normalizedDaysToShow - 1), to: endDate) ?? endDate
        let grouped = Dictionary(grouping: dailyUsage) { calendar.startOfDay(for: $0.date) }

        return (0..<normalizedDaysToShow).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }

            let rows = grouped[date] ?? []
            let segments = providerOrder.compactMap { provider -> DailyUsageProviderSegment? in
                let providerRows = rows.filter { $0.provider == provider }
                let tokens = providerRows.reduce(0) { $0 + $1.totalTokens }
                guard tokens > 0 else { return nil }

                return DailyUsageProviderSegment(
                    provider: provider,
                    tokens: tokens,
                    cost: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
                )
            }

            return DailyUsageDay(
                date: date,
                segments: segments,
                cost: rows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
    }

    private var visibleProviders: [ServiceType] {
        Self.providerOrder.filter { provider in
            days.contains { day in
                day.segments.contains { $0.provider == provider }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if days.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No token history found for the last 30 days.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                legend

                GeometryReader { proxy in
                    let width = barWidth(totalWidth: proxy.size.width)
                    let chartHeight = max(40, proxy.size.height - labelHeight)

                    VStack(spacing: 5) {
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(days) { day in
                                StackedDailyUsageColumn(
                                    day: day,
                                    width: width,
                                    height: barHeight(totalHeight: chartHeight, tokens: day.totalTokens),
                                    maxHeight: chartHeight,
                                    helpText: helpText(for: day),
                                    colorForProvider: color(for:)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        HStack(alignment: .top, spacing: barSpacing) {
                            ForEach(days.indices, id: \.self) { index in
                                DailyUsageDateLabel(
                                    date: days[index].date,
                                    width: width,
                                    showsMonth: shouldShowMonth(at: index)
                                )
                            }
                        }
                        .frame(height: labelHeight, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(visibleProviders, id: \.self) { provider in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: provider))
                        .frame(width: 8, height: 8)
                    Text(provider.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: legendHeight, alignment: .leading)
    }

    private var maxTokens: Int {
        max(days.map(\.totalTokens).max() ?? 1, 1)
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        let gapsWidth = CGFloat(max(0, days.count - 1)) * barSpacing
        return max(4, (totalWidth - gapsWidth) / CGFloat(max(1, days.count)))
    }

    private func barHeight(totalHeight: CGFloat, tokens: Int) -> CGFloat {
        guard tokens > 0 else { return 2 }
        return max(4, totalHeight * CGFloat(tokens) / CGFloat(maxTokens))
    }

    private func shouldShowMonth(at index: Int) -> Bool {
        guard days.indices.contains(index) else { return false }
        if index == 0 { return true }

        return Calendar.current.component(.day, from: days[index].date) == 1
    }

    private func helpText(for day: DailyUsageDay) -> String {
        var lines = [
            DashboardDateFormat.medium(day.date),
            "\(UsageFormat.tokens(day.totalTokens)) tokens",
            UsageFormat.cost(day.cost)
        ]

        if day.segments.isEmpty {
            lines.append("No tracked provider usage")
        } else {
            lines.append("")
            for segment in day.segments {
                lines.append("\(segment.provider.displayName): \(UsageFormat.tokens(segment.tokens)) · \(UsageFormat.cost(segment.cost))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func color(for provider: ServiceType) -> Color {
        MeterBarTheme.accent(for: provider)
    }
}

private struct StackedDailyUsageColumn: View {
    let day: DailyUsageDay
    let width: CGFloat
    let height: CGFloat
    let maxHeight: CGFloat
    let helpText: String
    let colorForProvider: (ServiceType) -> Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if day.totalTokens > 0 {
                VStack(spacing: 0) {
                    ForEach(day.segments.reversed()) { segment in
                        Rectangle()
                            .fill(colorForProvider(segment.provider))
                            .frame(height: segmentHeight(segment))
                    }
                }
                .frame(width: width, height: height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: width, height: 2)
            }
        }
        .frame(width: width, height: maxHeight, alignment: .bottom)
        .help(helpText)
    }

    private func segmentHeight(_ segment: DailyUsageProviderSegment) -> CGFloat {
        guard day.totalTokens > 0 else { return 0 }
        return max(1, height * CGFloat(segment.tokens) / CGFloat(day.totalTokens))
    }
}

private struct DailyUsageDateLabel: View {
    let date: Date
    let width: CGFloat
    let showsMonth: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(dayText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(showsMonth ? monthText : "")
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: 20, alignment: .top)
        .help(fullDateText)
    }

    private var dayText: String {
        String(Calendar.current.component(.day, from: date))
    }

    private var monthText: String {
        DashboardDateFormat.month(date)
    }

    private var fullDateText: String {
        DashboardDateFormat.medium(date)
    }
}

private struct DailyUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let segments: [DailyUsageProviderSegment]
    let cost: Double

    var totalTokens: Int {
        segments.reduce(0) { $0 + $1.tokens }
    }
}

private struct DailyUsageProviderSegment: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let tokens: Int
    let cost: Double
}
