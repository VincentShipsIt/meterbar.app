import AppKit
import SwiftUI

struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let color: Color

    private var iconName: String {
        if title.localizedCaseInsensitiveContains("exhausted") {
            return "exclamationmark.octagon.fill"
        }
        if title.localizedCaseInsensitiveContains("attention")
            || title.localizedCaseInsensitiveContains("tight") {
            return "exclamationmark.triangle.fill"
        }
        // Neutral states (no providers enabled / no usage yet) should not show the
        // healthy green shield, which falsely implies tracked quotas look good.
        if title.localizedCaseInsensitiveContains("no sources")
            || title.localizedCaseInsensitiveContains("waiting") {
            return "circle.dashed"
        }
        return "checkmark.shield.fill"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 46, height: 46)
                Image(systemName: iconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

struct ProviderOverviewStatusCard: View {
    let snapshot: DashboardProviderSnapshot

    private var accentColor: Color {
        MeterBarTheme.accent(for: snapshot.service)
    }

    private var primaryLimit: DashboardLimit? {
        snapshot.limits.min { $0.percentLeft < $1.percentLeft }
    }

    private var statusText: String {
        guard let primaryLimit else { return "No data" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("Updated \(relativeDate(snapshot.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.limits) { limit in
                        DashboardLimitRow(limit: limit, accentColor: accentColor)
                    }
                }
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: overviewTileMinHeight,
            alignment: .topLeading
        )
        .dashboardCardBackground()
    }

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: primaryLimit.percentLeft)
    }

    private func relativeDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }
}

struct CostOverviewStatusCard: View {
    let summary: CostSummary?
    let isScanning: Bool
    let isRefreshingMissingDays: Bool
    let formattedTokens: String

    private var subtitle: String {
        if isScanning { return "Scanning local logs" }
        if isRefreshingMissingDays { return "Updating…" }
        return "Last 30 days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MeterBarTheme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API-Rate Estimate")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let formattedTotalCost = summary?.formattedTotalCost {
                Text(formattedTotalCost)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                Text("Scan needed")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 7) {
                HStack {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedTokens)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Providers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(summary?.costs.count ?? 0)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: overviewTileMinHeight,
            alignment: .topLeading
        )
        .dashboardCardBackground()
    }
}

struct ProviderLimitsCard: View {
    let snapshot: DashboardProviderSnapshot
    let accentColor: Color
    let updatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderTitle(
                    title: snapshot.title,
                    logoKind: snapshot.logoKind,
                    color: accentColor,
                    font: .title3
                )
                Spacer()
                Text(updatedText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(snapshot.limits) { limit in
                    DashboardLimitRow(limit: limit, accentColor: accentColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3)
                    .bold()
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }
}

struct ProviderTitle: View {
    let title: String
    let logoKind: ProviderLogoKind
    let color: Color
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: logoKind, size: 18, foregroundColor: color)
            Text(title)
                .font(font)
                .fontWeight(.semibold)
        }
    }
}

struct DashboardLimitRow: View {
    let limit: DashboardLimit
    let accentColor: Color

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: paceContext
            )

            HStack {
                Text("\(Int(limit.usedPercent.rounded()))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let pace = limit.usageLimit.pace() {
                    Text(pace.leftLabel)
                        .font(.caption)
                        .foregroundColor(paceLabelColor(pace))
                }
                Spacer()
                if limit.usageLimit.resetTime != nil {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: .caption,
                        foregroundColor: .secondary,
                        iconSize: 10
                    )
                }
            }
        }
    }

    private func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return MeterBarTheme.danger
        }
        switch pace.stage {
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }
}
