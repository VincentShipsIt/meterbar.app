import SwiftUI

struct PopoverProviderStatusCard: View {
    let snapshot: PopoverProviderSnapshot

    private var primaryLimit: PopoverLimit? {
        snapshot.primaryLimit
    }

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: primaryLimit.percentLeft)
    }

    private var statusText: String {
        guard let primaryLimit else { return "Offline" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    private var isOut: Bool {
        guard let primaryLimit else { return false }
        return primaryLimit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(updatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if snapshot.limits.isEmpty {
                Text(snapshot.emptyDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            } else if snapshot.hasExhaustedLimit {
                BlockingLimitResetCounter(
                    windows: snapshot.resetWindows,
                    accentColor: snapshot.accentColor
                )
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.limits) { limit in
                        PopoverLimitRow(limit: limit, accentColor: snapshot.accentColor)
                    }
                }
            }

            if let resetCount = snapshot.resetCreditsAvailable, resetCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(snapshot.accentColor)
                    Text(Self.resetCreditsLabel(resetCount))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer(minLength: 4)
                }
                .help(
                    "\(Self.resetCreditsLabel(resetCount)) - banked quota resets you can trigger " +
                    "when you hit a rate limit."
                )
            }

            if let extraUsage = snapshot.extraUsage {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Extra usage")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    ExtraUsageStatusPill(status: extraUsage)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .opacity(isOut ? 0.72 : 1)
        .cardSurface()
    }

    /// "1 reset available" / "N resets available" — the count of banked rate-limit resets.
    static func resetCreditsLabel(_ count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") available"
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

private struct PopoverLimitRow: View {
    let limit: PopoverLimit
    let accentColor: Color

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
                    .lineLimit(1)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: paceContext
            )

            if limit.usageLimit.resetTime != nil {
                ResetCountdownLabel(
                    title: limit.title,
                    limit: limit.usageLimit,
                    font: .caption2,
                    foregroundColor: .secondary,
                    iconSize: 9
                )
            }
        }
    }
}
