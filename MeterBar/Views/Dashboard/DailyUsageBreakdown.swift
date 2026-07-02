import SwiftUI

struct DailyUsageBreakdownList: View {
    let dailyUsage: [DailyTokenUsage]

    @State private var expandedDayIDs: Set<Date> = []

    private var days: [DailyProviderUsageDay] {
        let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, rows in
            DailyProviderUsageDay(date: day, providers: providerSummaries(from: rows))
        }
        .filter { $0.totalTokens > 0 }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily Details")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Last 30 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(days) { day in
                    DailyUsageDetailRow(
                        day: day,
                        isExpanded: expandedDayIDs.contains(day.id),
                        toggle: { toggleExpansion(for: day.id) }
                    )
                }
            }
        }
    }

    private func toggleExpansion(for dayID: Date) {
        withAnimation(.snappy(duration: 0.18)) {
            if expandedDayIDs.contains(dayID) {
                expandedDayIDs.remove(dayID)
            } else {
                expandedDayIDs.insert(dayID)
            }
        }
    }

    private func providerSummaries(from rows: [DailyTokenUsage]) -> [DailyProviderUsageSummary] {
        let grouped = Dictionary(grouping: rows, by: \.provider)
        return grouped.map { provider, providerRows in
            DailyProviderUsageSummary(
                provider: provider,
                inputTokens: providerRows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: providerRows.reduce(0) { $0 + $1.outputTokens },
                cacheReadTokens: providerRows.reduce(0) { $0 + $1.cacheReadTokens },
                estimatedCostUSD: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
        .sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }
}

private struct DailyProviderUsageDay: Identifiable {
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

private struct DailyProviderUsageSummary: Identifiable {
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

private struct DailyUsageDetailRow: View {
    let day: DailyProviderUsageDay
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(dateLabel(day.date))
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(providerCountLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(UsageFormat.tokens(day.totalTokens)) tokens")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(UsageFormat.cost(day.estimatedCostUSD))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(isExpanded ? "Collapse day details" : "Show day details")

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(day.providers) { provider in
                        DailyProviderUsageSummaryRow(provider: provider)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var providerCountLabel: String {
        let count = day.providers.count
        return count == 1 ? "1 source" : "\(count) sources"
    }

    private var accessibilitySummary: String {
        "\(dateLabel(day.date)), \(UsageFormat.tokens(day.totalTokens)) tokens, \(UsageFormat.cost(day.estimatedCostUSD))"
    }

    private func dateLabel(_ date: Date) -> String {
        DashboardDateFormat.weekdayMonthDay(date)
    }
}

private struct DailyProviderUsageSummaryRow: View {
    let provider: DailyProviderUsageSummary

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogoView(
                kind: providerLogoKind(for: provider.provider),
                size: 14,
                foregroundColor: color(for: provider.provider)
            )
            Text(provider.provider.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .frame(width: 110, alignment: .leading)
            UsageDetailMetric(label: "Input", value: UsageFormat.tokens(provider.inputTokens))
            UsageDetailMetric(label: "Output", value: UsageFormat.tokens(provider.outputTokens))
            UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(provider.cacheReadTokens))
            Spacer()
            Text(UsageFormat.cost(provider.estimatedCostUSD))
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
}

private func color(for provider: ServiceType) -> Color {
    MeterBarTheme.accent(for: provider)
}
