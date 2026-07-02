import SwiftUI

struct ProviderCostBreakdown: View {
    let cost: TokenCost

    private var logoKind: ProviderLogoKind {
        providerLogoKind(for: cost.provider)
    }

    private var logoColor: Color {
        MeterBarTheme.accent(for: cost.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProviderTitle(
                    title: cost.provider.displayName,
                    logoKind: logoKind,
                    color: logoColor,
                    font: .headline
                )
                Spacer()
                Text(cost.formattedCost)
                    .font(.title3)
                    .bold()
            }

            HStack(spacing: 14) {
                CostMetric(label: "Tokens", value: cost.formattedTokens)
                CostMetric(label: "Input", value: UsageFormat.tokens(cost.inputTokens))
                CostMetric(label: "Output", value: UsageFormat.tokens(cost.outputTokens))
                CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
            }

            if !cost.modelBreakdowns.isEmpty {
                CostBreakdownSection(title: "Models", items: cost.modelBreakdowns.prefix(6).map { $0 })
            }

            if !cost.originBreakdowns.isEmpty {
                CostBreakdownSection(title: "Usage Origin", items: cost.originBreakdowns.prefix(6).map { $0 })
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CostBreakdownSection: View {
    let title: String
    let items: [TokenUsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)

                    UsageDetailMetric(label: "Tokens", value: UsageFormat.tokens(item.totalTokens))
                    UsageDetailMetric(label: "Input", value: UsageFormat.tokens(item.inputTokens))
                    UsageDetailMetric(label: "Output", value: UsageFormat.tokens(item.outputTokens))
                    UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(item.cacheReadTokens))

                    Spacer()

                    Text(item.formattedCost)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}

private struct CostMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageDetailMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 58, alignment: .leading)
    }
}
