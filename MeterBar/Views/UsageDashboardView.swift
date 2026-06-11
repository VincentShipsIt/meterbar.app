import AppKit
import SwiftUI

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: UsageDashboardView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MeterBar Usage"
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
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

    @State private var selectedSection: DashboardSection = .overview

    var body: some View {
        HStack(spacing: 10) {
            sidebar

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch selectedSection {
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
                .padding(22)
            }
            .background(Color.white.opacity(0.018))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            }
        }
        .padding(10)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.080, blue: 0.080)
                Rectangle().fill(.ultraThinMaterial).opacity(0.42)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.cyan)
                Text("MeterBar")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.iconName)
                                .frame(width: 22)
                            Text(section.rawValue)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundColor(selectedSection == section ? .white : .secondary)
                        .background(selectedSection == section ? Color.white.opacity(0.10) : Color.clear)
                        .overlay(alignment: .leading) {
                            if selectedSection == section {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.cyan)
                                    .frame(width: 3)
                                    .padding(.vertical, 7)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("Local Sources")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("Codex logs", systemImage: "checkmark.circle.fill")
                Label("Claude JSONL", systemImage: "checkmark.circle.fill")
                Label("Quota APIs", systemImage: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 188)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.rawValue)
                    .font(.title)
                    .fontWeight(.semibold)
                Text(sectionSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            RefreshIconButton(
                title: "Refresh",
                help: "Refresh usage",
                isDisabled: dataManager.isLoading || costTracker.isScanning
            ) {
                Task {
                    await refreshDashboard()
                }
            }
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                color: tightestWindowColor
            )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot)
                }

                CostOverviewStatusCard(
                    summary: costTracker.costSummary,
                    isScanning: costTracker.isScanning,
                    formattedTokens: formattedTokenCount(costTracker.costSummary?.totalTokens ?? 0)
                )
            }

            DashboardCard(title: "Last 30 Days", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                DailyUsageChart(dailyUsage: costTracker.costSummary?.dailyUsage ?? [])
                    .frame(height: 180)
            }
        }
    }

    private var limitsContent: some View {
        DashboardCard(title: "All Quota Windows", trailing: dataManager.isLoading ? "Refreshing..." : nil) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(providerSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProviderTitle(
                                title: snapshot.title,
                                logoKind: snapshot.logoKind,
                                color: color(for: snapshot.service),
                                font: .title3
                            )
                            Spacer()
                            Text("Updated \(relativeDate(snapshot.lastUpdated))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(snapshot.limits) { limit in
                            DashboardLimitRow(limit: limit, accentColor: color(for: snapshot.service))
                        }
                    }

                    if snapshot.id != providerSnapshots.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "30 Day API-Rate Token Spend", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Local subscription logs are estimated using API token rates so Codex and Claude can be compared.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let summary = costTracker.costSummary {
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
                            .disabled(costTracker.isScanning)
                        }
                        .frame(height: 220, alignment: .center)
                    }

                    Divider()

                    if let summary = costTracker.costSummary, !summary.costs.isEmpty {
                        ForEach(summary.costs) { cost in
                            ProviderCostBreakdown(cost: cost)
                        }
                    } else {
                        Text("No local token logs found yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var settingsContent: some View {
        SettingsView(embeddedInDashboard: true)
            .frame(maxWidth: 760, minHeight: 520, alignment: .leading)
    }

    private var providerSnapshots: [DashboardProviderSnapshot] {
        var snapshots: [DashboardProviderSnapshot] = []

        if let codex = dataManager.metrics[.codexCli] {
            snapshots.append(DashboardProviderSnapshot(title: "Codex", service: .codexCli, metrics: codex))
        }

        let claudeAccountMetrics = dataManager.claudeCodeAccountMetrics
        if !claudeAccountMetrics.isEmpty {
            for account in claudeAccountStore.accounts {
                if let metrics = claudeAccountMetrics[account.id] {
                    snapshots.append(DashboardProviderSnapshot(
                        title: account.isDefault && claudeAccountStore.accounts.count == 1 ? "Claude" : account.name,
                        service: .claudeCode,
                        metrics: metrics
                    ))
                }
            }
        } else if let claude = dataManager.metrics[.claudeCode] {
            snapshots.append(DashboardProviderSnapshot(title: "Claude", service: .claudeCode, metrics: claude))
        }

        if let cursor = dataManager.metrics[.cursor] {
            snapshots.append(DashboardProviderSnapshot(title: "Cursor", service: .cursor, metrics: cursor))
        }

        return snapshots
    }

    private var tightestWindowColor: Color {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return .secondary
        }
        if limit.percentLeft <= 10 { return .red }
        if limit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
    }

    private var overviewStatusTitle: String {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Waiting for usage"
        }
        if limit.percentLeft <= 10 { return "Quota needs attention" }
        if limit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
    }

    private var overviewStatusDetail: String {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Refresh to load Codex, Claude, and Cursor status."
        }
        return "\(limit.title) has \(limit.percentLeft)% left. Tracking \(providerSnapshots.count) local provider sources."
    }

    private var sectionSubtitle: String {
        switch selectedSection {
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

    private func refreshDashboard() async {
        if selectedSection == .costs {
            await costTracker.scanCosts(days: 30)
        } else {
            await dataManager.refreshAll()
        }
    }

    private func color(for service: ServiceType) -> Color {
        switch service {
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .codexCli, .openai:
            return .cyan
        case .cursor:
            return .green
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct DashboardProviderSnapshot: Identifiable {
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
        self.logoKind = Self.logoKind(for: service)
        self.lastUpdated = metrics.lastUpdated
        self.limits = [
            DashboardLimit(title: "Session", limit: metrics.sessionLimit),
            DashboardLimit(title: "Weekly", limit: metrics.weeklyLimit),
            DashboardLimit(title: service == .codexCli ? "Code Review" : "Sonnet", limit: metrics.codeReviewLimit)
        ].compactMap { $0 }
    }

    private static func logoKind(for service: ServiceType) -> ProviderLogoKind {
        switch service {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
    }
}

private struct DashboardLimit: Identifiable {
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
        Int(max(0, 100 - usedPercent).rounded())
    }
}

private struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 46, height: 46)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundColor(color)
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

private struct ProviderOverviewStatusCard: View {
    let snapshot: DashboardProviderSnapshot

    private var accentColor: Color {
        switch snapshot.service {
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .codexCli, .openai:
            return .cyan
        case .cursor:
            return .green
        }
    }

    private var primaryLimit: DashboardLimit? {
        snapshot.limits.min { $0.percentLeft < $1.percentLeft }
    }

    private var statusText: String {
        guard let primaryLimit else { return "No data" }
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

            if let primaryLimit {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(primaryLimit.percentLeft)%")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(statusColor)
                    Text("left")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(primaryLimit.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                UsageBar(
                    usedPercentage: primaryLimit.usedPercent,
                    accentColor: accentColor,
                    pace: primaryLimit.usageLimit.pace(),
                    paceContext: primaryLimit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
                )
            }

            VStack(spacing: 7) {
                ForEach(snapshot.limits.prefix(3)) { limit in
                    HStack {
                        Text(limit.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(limit.percentLeft)% left")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .padding(14)
        .dashboardCardBackground()
    }

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        if primaryLimit.percentLeft <= 10 { return .red }
        if primaryLimit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CostOverviewStatusCard: View {
    let summary: CostSummary?
    let isScanning: Bool
    let formattedTokens: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API-Rate Estimate")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(isScanning ? "Scanning local logs" : "Last 30 days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(summary?.formattedTotalCost ?? "Scan needed")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

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
        .dashboardCardBackground()
    }
}

private struct DashboardCard<Content: View>: View {
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
        .dashboardCardBackground()
    }
}

private struct ProviderTitle: View {
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

private struct DashboardLimitRow: View {
    let limit: DashboardLimit
    let accentColor: Color

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text("\(limit.percentLeft)% left")
                    .font(.subheadline)
                    .bold()
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
                        .foregroundColor(pace.stage == .reserve ? .green : pace.stage == .deficit ? MeterBarTheme.warning : .secondary)
                }
                Spacer()
                if let resetTime = limit.usageLimit.resetTime {
                    Text("Resets \(relativeDate(resetTime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct DailyUsageChart: View {
    let dailyUsage: [DailyTokenUsage]

    private var totals: [DailyUsageTotal] {
        let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, rows in
            DailyUsageTotal(
                date: day,
                tokens: rows.reduce(0) { $0 + $1.totalTokens },
                cost: rows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if totals.isEmpty {
                Text("No token history found for the last 30 days.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(totals) { day in
                            DailyUsageBar(
                                day: day,
                                width: barWidth(totalWidth: proxy.size.width),
                                height: barHeight(totalHeight: proxy.size.height, tokens: day.tokens),
                                isAboveAverageCost: day.cost > averageCost,
                                helpText: helpText(for: day)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
    }

    private var maxTokens: Int {
        max(totals.map(\.tokens).max() ?? 1, 1)
    }

    private var averageCost: Double {
        guard !totals.isEmpty else { return 0 }
        return totals.reduce(0) { $0 + $1.cost } / Double(totals.count)
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        let gapsWidth = CGFloat(max(0, totals.count - 1)) * 5
        return max(4, (totalWidth - gapsWidth) / CGFloat(max(1, totals.count)))
    }

    private func barHeight(totalHeight: CGFloat, tokens: Int) -> CGFloat {
        max(4, totalHeight * CGFloat(tokens) / CGFloat(maxTokens))
    }

    private func helpText(for day: DailyUsageTotal) -> String {
        "\(dayLabel(day.date))\n\(formatTokens(day.tokens)) tokens\n\(String(format: "$%.2f", day.cost))"
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct DailyUsageTotal: Identifiable {
    var id: Date { date }
    let date: Date
    let tokens: Int
    let cost: Double
}

private struct DailyUsageBar: View {
    let day: DailyUsageTotal
    let width: CGFloat
    let height: CGFloat
    let isAboveAverageCost: Bool
    let helpText: String

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(isAboveAverageCost ? Color.green.opacity(0.9) : Color.cyan.opacity(0.8))
            .frame(width: width, height: height)
            .help(helpText)
    }
}

private struct ProviderCostBreakdown: View {
    let cost: TokenCost

    private var logoKind: ProviderLogoKind {
        switch cost.provider {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
    }

    private var logoColor: Color {
        switch cost.provider {
        case .codexCli, .openai:
            return .cyan
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .cursor:
            return .green
        }
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
                CostMetric(label: "Input", value: compact(cost.inputTokens))
                CostMetric(label: "Output", value: compact(cost.outputTokens))
                CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
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

private extension View {
    func dashboardCardBackground() -> some View {
        self
            .background(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
