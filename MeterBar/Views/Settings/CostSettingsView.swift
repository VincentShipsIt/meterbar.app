import MeterBarShared
import SwiftUI

/// The "Cost" settings tab: local session cost scan results and the 30-day
/// scan control. Extracted from the SettingsView monolith.
struct CostSettingsView: View {
    // MARK: Internal

    var body: some View {
        costTrackingSection
    }

    // MARK: Private

    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var canScanCosts: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
    }

    private var costTrackingSection: some View {
        SettingsPanelSection(title: "Cost Tracking", systemImage: "chart.bar.xaxis", color: MeterBarTheme.success) {
            if costTracker.isScanning {
                SettingsRowView(title: "Status") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning sessions...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let summary = visibleCostSummary, !summary.costs.isEmpty {
                SettingsRowView(title: "Total cost") {
                    Text(summary.formattedTotalCost)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                SettingsRowView(title: "Daily average") {
                    Text(summary.formattedDailyCost)
                        .foregroundColor(.secondary)
                }

                ForEach(summary.costs) { cost in
                    SettingsRowView(title: cost.provider.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cost.formattedCost)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("\(cost.formattedTokens) tokens")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let lastScan = costTracker.lastScanDate {
                    SettingsNotice(text: "Last scanned \(formatDate(lastScan)) ago.", color: .secondary)
                }
            } else if costTracker.costSummary != nil {
                // Scanned, but nothing landed for the providers that are enabled.
                EmptyStateCard(
                    systemImage: "tray",
                    title: "No cost data",
                    message: "Enabled providers logged no local tokens in the last 30 days."
                )
            } else {
                // Never scanned this session — the button below kicks off the first scan.
                EmptyStateCard(
                    systemImage: "magnifyingglass",
                    title: "No scan yet",
                    message: "Scan 30 days to estimate local token cost."
                )
            }

            if !canScanCosts {
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Nothing to scan",
                    message: "Enable Claude Code or OpenAI Codex to scan local token logs.",
                    tone: .warning
                )
            }

            SettingsRowView(title: "Local sessions") {
                Button {
                    Task {
                        await costTracker.scanCosts(days: 30)
                    }
                } label: {
                    HStack(spacing: 7) {
                        if costTracker.isRefreshInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                            Text(costTracker.isRefreshingMissingDays ? "Updating..." : "Scanning...")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("Scan 30 Days")
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(costTracker.isRefreshInProgress || !canScanCosts)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }
}
