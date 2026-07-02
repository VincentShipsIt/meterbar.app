import AppKit
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case limits = "Limits"
    case costs = "Costs"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .limits:
            return "chart.bar.fill"
        case .costs:
            return "dollarsign.circle.fill"
        case .settings:
            return "gearshape.fill"
        }
    }
}

struct UsageDashboardView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared

    @State private var selectedSection: DashboardSection = .overview
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var activeSection: DashboardSection { selectedSection }

    private var overviewGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
            count: 2
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack {
                // Keep the detail fill out of the titlebar area so the native
                // toolbar glass shows there instead of a flat content background.
                MeterBarDetailBackground()
                    .ignoresSafeArea(edges: [.horizontal, .bottom])

                detailContent
            }
            .navigationTitle(activeSection.rawValue)
            .navigationSubtitle(sectionSubtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await refreshDashboard() }
                    } label: {
                        RefreshingIcon(isRefreshing: isRefreshButtonAnimating)
                    }
                    .help(isRefreshButtonAnimating ? "Refreshing usage" : "Refresh usage")
                    .disabled(isRefreshButtonDisabled)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await refreshCostsIfMissingDays()
        }
        .onChange(of: selectedSection) {
            Task { await refreshCostsIfMissingDays() }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            ForEach(DashboardSection.allCases) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section)
            }

            Section("Local Sources") {
                if enabledSourceLabels.isEmpty {
                    Label("No sources enabled", systemImage: "circle")
                } else {
                    ForEach(enabledSourceLabels, id: \.self) { label in
                        Label(label, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
        // No background overrides: the native sidebar owns its glass material,
        // section rendering, and selected-row highlight. Stacking a custom
        // `.glassEffect` here would double up on the system material.
    }

    private var detailContent: some View {
        // Keep a real scroll backing in the detail column while the sidebar
        // remains a plain native List.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch activeSection {
                case .overview:
                    overviewContent
                case .limits:
                    limitsContent
                case .costs:
                    costsContent
                case .settings:
                    settingsContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                color: tightestWindowColor
            )

            LazyVGrid(columns: overviewGridColumns, alignment: .leading, spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot)
                }

                CostOverviewStatusCard(
                    summary: visibleCostSummary,
                    isScanning: costTracker.isScanning,
                    isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                    formattedTokens: UsageFormat.tokens(visibleCostSummary?.totalTokens ?? 0)
                )
            }
            .frame(maxWidth: .infinity)

            DashboardCard(title: "Last 30 Days", trailing: costRefreshStatusText) {
                costScanChart(height: 180, compact: true)
            }
        }
    }

    private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All Quota Windows")
                    .font(.title3)
                    .bold()
                Spacer()
                if dataManager.isLoading {
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if providerSnapshots.isEmpty {
                DashboardCard(title: "No Quota Windows") {
                    Text("Enable providers in Settings to show quota windows.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(providerSnapshots) { snapshot in
                    ProviderLimitsCard(
                        snapshot: snapshot,
                        accentColor: color(for: snapshot.service),
                        updatedText: "Updated \(relativeDate(snapshot.lastUpdated))"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "30 Day API-Rate Token Spend", trailing: costRefreshStatusText) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Local subscription logs are estimated using API token rates "
                        + "so Codex and Claude can be compared.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if costTracker.isScanning {
                        costScanChart(height: 220, compact: false, showsProgressBadge: false)
                    } else if let summary = visibleCostSummary {
                        DailyUsageChart(dailyUsage: summary.dailyUsage)
                            .frame(height: 220)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Run a local scan to load 30-day token history.")
                                .foregroundColor(.secondary)
                            Button {
                                Task {
                                    await costTracker.scanCosts(days: 30)
                                }
                            } label: {
                                Label("Scan 30 Days", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                            .disabled(costTracker.isRefreshInProgress)
                        }
                        .frame(height: 220, alignment: .center)
                    }

                    Divider()

                    if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                        DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                        Divider()
                    }

                    if let summary = visibleCostSummary, !summary.costs.isEmpty {
                        ForEach(summary.costs) { cost in
                            ProviderCostBreakdown(cost: cost)
                        }
                    } else {
                        Text("No enabled provider token logs found yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .overlay {
                if costTracker.isScanning, visibleCostSummary != nil {
                    CostRefreshLockOverlay()
                }
            }
        }
    }

    private func costScanChart(height: CGFloat, compact: Bool, showsProgressBadge: Bool = true) -> some View {
        ZStack {
            if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                DailyUsageChart(dailyUsage: summary.dailyUsage)
                    .opacity(costTracker.isScanning ? 0.42 : 1)
            } else if costTracker.isScanning {
                CostScanLoadingChart(compact: compact)
            } else {
                DailyUsageChart(dailyUsage: [])
            }

            if showsProgressBadge, costTracker.isScanning, visibleCostSummary?.dailyUsage.isEmpty == false {
                CostScanProgressBadge(compact: compact)
            }
        }
        .frame(height: height)
    }

    private var settingsContent: some View {
        SettingsView(embeddedInDashboard: true)
            .frame(maxWidth: .infinity, minHeight: 520, alignment: .leading)
    }

    private var providerSnapshots: [DashboardProviderSnapshot] {
        var snapshots: [DashboardProviderSnapshot] = []

        if providerVisibility.isEnabled(.codexCli), let codex = dataManager.metrics[.codexCli] {
            snapshots.append(DashboardProviderSnapshot(title: "Codex", service: .codexCli, metrics: codex))
        }

        if providerVisibility.isEnabled(.claudeCode) {
            let claudeAccountMetrics = dataManager.claudeCodeAccountMetrics
            if !claudeAccountMetrics.isEmpty {
                for account in claudeAccountStore.accounts {
                    if let metrics = claudeAccountMetrics[account.id] {
                        let isOnlyDefaultAccount = account.isDefault && claudeAccountStore.accounts.count == 1
                        snapshots.append(DashboardProviderSnapshot(
                            title: isOnlyDefaultAccount ? "Claude" : account.name,
                            service: .claudeCode,
                            metrics: metrics
                        ))
                    }
                }
            } else if let claude = dataManager.metrics[.claudeCode] {
                snapshots.append(DashboardProviderSnapshot(title: "Claude", service: .claudeCode, metrics: claude))
            }
        }

        if providerVisibility.isEnabled(.cursor), let cursor = dataManager.metrics[.cursor] {
            snapshots.append(DashboardProviderSnapshot(title: "Cursor", service: .cursor, metrics: cursor))
        }

        return snapshots
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var enabledSourceLabels: [String] {
        var labels: [String] = []
        if providerVisibility.isEnabled(.codexCli) {
            labels.append("Codex logs")
        }
        if providerVisibility.isEnabled(.claudeCode) {
            labels.append("Claude JSONL")
        }
        if providerVisibility.isEnabled(.cursor) {
            labels.append("Cursor local state")
        }
        if providerVisibility.isEnabled(.claude) || providerVisibility.isEnabled(.openai) {
            labels.append("Quota APIs")
        }
        return labels
    }

    private var tightestWindowColor: Color {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return .secondary
        }
        return MeterBarTheme.quotaStatusColor(percentLeft: limit.percentLeft)
    }

    private var overviewStatusTitle: String {
        guard !providerSnapshots.isEmpty else { return "No sources enabled" }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Waiting for usage"
        }
        if limit.percentLeft <= 0 { return "Quota exhausted" }
        if limit.percentLeft <= 10 { return "Quota needs attention" }
        if limit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
    }

    private var overviewStatusDetail: String {
        guard !providerSnapshots.isEmpty else {
            return "Enable providers in Settings to show quota status."
        }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Refresh to load enabled provider status."
        }
        if limit.percentLeft <= 0 {
            return "\(limit.title) is out until reset. Tracking \(providerSnapshots.count) local provider sources."
        }
        return "\(limit.title) has \(limit.percentLeft)% left. "
            + "Tracking \(providerSnapshots.count) local provider sources."
    }

    private var sectionSubtitle: String {
        switch activeSection {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .costs:
            return "Local 30-day token spend"
        case .settings:
            return "Accounts, refresh, and local sources"
        }
    }

    private var costRefreshStatusText: String? {
        if costTracker.isScanning {
            return "Scanning..."
        }
        if costTracker.isRefreshingMissingDays {
            return "Updating..."
        }
        return nil
    }

    private var isRefreshButtonDisabled: Bool {
        isRefreshButtonAnimating
    }

    private var isRefreshButtonAnimating: Bool {
        switch activeSection {
        case .costs:
            return costTracker.isRefreshInProgress
        case .overview, .limits, .settings:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        if activeSection == .costs {
            await costTracker.scanCosts(days: 30)
        } else {
            await dataManager.refreshAll()
        }
    }

    private func refreshCostsIfMissingDays() async {
        guard activeSection == .overview || activeSection == .costs else { return }
        await costTracker.refreshMissingDaysInBackground(days: 30)
    }

    private func color(for service: ServiceType) -> Color {
        MeterBarTheme.accent(for: service)
    }

    private func relativeDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }
}
