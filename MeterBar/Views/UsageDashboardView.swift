import AppKit
import Combine
import SwiftUI
import MeterBarShared
import UniformTypeIdentifiers

private final class MeterBarFullSizeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaRect: NSRect { bounds }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?

    private init() {}

    func show(section: DashboardSection? = nil, focusedProviderID: String? = nil) {
        if let section {
            DashboardNavigationStore.shared.navigate(to: section, focusedProviderID: focusedProviderID)
        } else if let focusedProviderID {
            DashboardNavigationStore.shared.navigate(to: .limits, focusedProviderID: focusedProviderID)
        }

        if window == nil {
            let hostingView = MeterBarFullSizeHostingView(rootView: UsageDashboardView())
            hostingView.autoresizingMask = [.width, .height]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MeterBar Usage"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar = nil
            window.isOpaque = false
            window.backgroundColor = MeterBarWindowChrome.backgroundColor
            window.isMovableByWindowBackground = true
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentView = hostingView
            applyCompanionWindowRadius(to: window)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func applyCompanionWindowRadius(to window: NSWindow) {
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = MeterBarWindowChrome.dashboardCornerRadius
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case limits = "Limits"
    case costs = "Costs"
    case apiUsage = "API Usage"
    case optimize = "Optimize"
    case diagnostics = "Diagnostics"
    case share = "Share"
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
        case .apiUsage:
            return "server.rack"
        case .optimize:
            return "leaf.fill"
        case .diagnostics:
            return "stethoscope"
        case .share:
            return "square.and.arrow.up.fill"
        case .settings:
            return "gearshape.fill"
        }
    }

    var titlebarSubtitle: String {
        switch self {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .costs:
            return "Local 30-day token spend"
        case .apiUsage:
            return "Provider API usage and spend"
        case .optimize:
            return "Where tokens go and how to trim them"
        case .diagnostics:
            return "Provider setup health"
        case .share:
            return "Social card export"
        case .settings:
            return "Accounts, refresh, and local sources"
        }
    }
}

@MainActor
final class DashboardNavigationStore: ObservableObject {
    static let shared = DashboardNavigationStore()

    @Published var selectedSection: DashboardSection = .overview
    @Published var focusedProviderID: ProviderSnapshot.ID?

    private init() {}

    func navigate(to section: DashboardSection, focusedProviderID: ProviderSnapshot.ID? = nil) {
        selectedSection = section
        self.focusedProviderID = focusedProviderID
    }
}

struct UsageDashboardView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared
    @StateObject private var navigation = DashboardNavigationStore.shared

    @State private var readinessReports: [ProviderReadiness] = []
    @State private var isRunningDiagnostics = false
    @State private var socialCardGeneratedAt = Date()
    @State private var socialShareStatus: String?
    @State private var isSidebarCollapsed = false

    private var activeSection: DashboardSection { navigation.selectedSection }

    private var sidebarWidth: CGFloat {
        isSidebarCollapsed
            ? MeterBarWindowChrome.collapsedSidebarWidth
            : MeterBarWindowChrome.sidebarTitlebarWidth
    }

    private var overviewGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
            count: 2
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MeterBarDetailBackground()
                .ignoresSafeArea()

            appShell
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: MeterBarWindowChrome.dashboardCornerRadius,
                style: .continuous
            )
        )
        .task {
            await refreshCostsIfMissingDays()
        }
        .onChange(of: navigation.selectedSection) {
            Task { await refreshCostsIfMissingDays() }
            if navigation.selectedSection == .diagnostics {
                Task { await runDiagnostics() }
            }
            if navigation.selectedSection != .limits {
                navigation.focusedProviderID = nil
            }
        }
    }

    private var appShell: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .zIndex(2)
                .animation(.easeInOut(duration: 0.18), value: isSidebarCollapsed)

            ZStack(alignment: .top) {
                detailContent

                dashboardTitlebar
                    .zIndex(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dashboardTitlebar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(activeSection.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(activeSection.titlebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Button {
                Task { await refreshDashboard() }
            } label: {
                RefreshingIcon(isRefreshing: isRefreshButtonAnimating)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(MeterBarTheme.glassCardTint, in: Circle())
            .overlay(Circle().stroke(MeterBarTheme.glassCardStroke, lineWidth: 0.5))
            .help(isRefreshButtonAnimating ? "Refreshing usage" : "Refresh usage")
            .disabled(isRefreshButtonDisabled)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: MeterBarWindowChrome.titlebarContentInset)
        .frame(maxWidth: .infinity)
        .background {
            MeterBarTitlebarGlass()
        }
        .allowsHitTesting(true)
    }

    private var sidebar: some View {
        ZStack(alignment: .topTrailing) {
            MeterBarSidebarSurface()
                .padding(.leading, 10)
                .padding(.trailing, isSidebarCollapsed ? 10 : 8)
                .padding(.vertical, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(DashboardSection.allCases) { section in
                        DashboardSidebarRow(
                            section: section,
                            isSelected: section == activeSection,
                            isCollapsed: isSidebarCollapsed
                        ) {
                            navigation.selectedSection = section
                        }
                    }
                }
                .padding(.horizontal, isSidebarCollapsed ? 20 : 22)
                .padding(.top, MeterBarWindowChrome.titlebarContentInset + 10)
                .padding(.bottom, 22)
            }

            sidebarCollapseButton
        }
        .background(Color.clear)
    }

    private var sidebarCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isSidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: isSidebarCollapsed ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            MeterBarTheme.glassCardTint,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MeterBarTheme.glassCardStroke, lineWidth: 0.5)
        }
        .padding(.top, 17)
        .padding(.trailing, isSidebarCollapsed ? 21 : 18)
        .help(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
        .accessibilityLabel(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
        .zIndex(10)
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
                case .apiUsage:
                    apiUsageContent
                case .optimize:
                    OptimizeInsightsView()
                case .diagnostics:
                    diagnosticsContent
                case .share:
                    shareContent
                case .settings:
                    settingsContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, MeterBarWindowChrome.titlebarContentInset + 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                iconName: overviewStatusIconName,
                color: overviewBand?.color ?? .secondary
            )

            LazyVGrid(columns: overviewGridColumns, alignment: .leading, spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot) {
                        navigation.navigate(to: .limits, focusedProviderID: snapshot.id)
                    }
                }
            }
            .frame(maxWidth: .infinity)
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
                ForEach(orderedProviderSnapshotsForLimits) { snapshot in
                    ProviderLimitsCard(snapshot: snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            CostOverviewStatusCard(
                summary: visibleCostSummary,
                isScanning: costTracker.isScanning,
                isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                formattedTokens: UsageFormat.tokens(visibleCostSummary?.totalTokens ?? 0)
            )
            .frame(maxWidth: 420, alignment: .leading)

            costTrendCard

            if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                DashboardCard(title: "Daily Details", trailing: "Last 30 days") {
                    DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                }
            }

            if let summary = visibleCostSummary, !summary.costs.isEmpty {
                ForEach(summary.costs) { cost in
                    ProviderCostBreakdown(
                        cost: cost,
                        quotaSnapshot: providerSnapshot(for: cost.provider)
                    )
                }
            } else {
                DashboardCard(title: "No Local Logs Found") {
                    Text("Run a local scan to load 30-day token history.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var costTrendCard: some View {
        DashboardCard(title: "30 Day Token Spend", trailing: costRefreshStatusText) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Local subscription logs are estimated using API token rates "
                        + "so Codex and Claude can be compared."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)

                if costTracker.isScanning {
                    costScanChart(height: 220, compact: false, showsProgressBadge: true)
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
            }
        }
    }

    private var apiUsageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if apiUsageStore.hasAnyAuthenticated {
                ApiUsageSection(store: apiUsageStore)
            } else {
                DashboardCard(title: "No API Admin Keys") {
                    Text("Add an organization admin key in Settings to show OpenAI or Anthropic API usage.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await apiUsageStore.refresh()
        }
    }

    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SocialShareCardPreview(content: socialShareCardContent)
                .frame(maxWidth: 860)
                .accessibilityLabel("MeterBar social share card preview")

            HStack(spacing: 10) {
                Button {
                    copySocialCardImage()
                } label: {
                    Label("Copy PNG", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    saveSocialCardImage()
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    copyTweetText()
                } label: {
                    Label("Copy Text", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)

                if visibleCostSummary?.dailyUsage.isEmpty ?? true {
                    Button {
                        Task {
                            await costTracker.scanCosts(days: 30)
                            socialCardGeneratedAt = Date()
                        }
                    } label: {
                        Label("Scan 30 Days", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(costTracker.isRefreshInProgress)
                }

                Spacer()

                if let socialShareStatus {
                    Text(socialShareStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }

            DashboardCard(title: "Tweet Text") {
                Text(socialShareCardContent.tweetText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makeSocialShareCardContent(generatedAt: Date) -> SocialShareCardContent {
        // Reuse the canonical tightest-quota window the overview already derives
        // (`providerSnapshots.tightestLimit`) instead of re-deriving it locally.
        let tightest = tightestLimit
        return SocialShareCardContent(
            tokenTotal: visibleCostSummary?.totalTokens,
            estimatedCostUSD: visibleCostSummary?.totalCostUSD,
            sourceCount: socialSourceCount,
            providerNames: socialProviderNames,
            tightestLimitTitle: tightest?.title,
            tightestPercentLeft: tightest?.percentLeft,
            dailyTokenTotals: socialDailyTokenTotals(generatedAt: generatedAt),
            generatedAt: generatedAt
        )
    }

    private func socialDailyTokenTotals(generatedAt: Date) -> [Int] {
        guard let visibleCostSummary else { return [] }
        return SocialShareCardContent.dailyTokenTotals(
            from: visibleCostSummary.dailyUsage,
            now: generatedAt
        )
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

    private var providerSnapshots: [ProviderSnapshot] {
        // Same builder the popover uses; the dashboard only renders providers
        // that have reported metrics.
        ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: dataManager.metrics,
            claudeAccounts: claudeAccountStore.accounts,
            claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
            enabledServices: providerVisibility.enabledServices,
            claudeCodeHasAccess: claudeCodeService.hasAccess,
            codexCliHasAccess: codexCliService.hasAccess,
            cursorHasAccess: cursorService.hasAccess
        ))
        .filter(\.hasMetrics)
    }

    private var orderedProviderSnapshotsForLimits: [ProviderSnapshot] {
        guard let focusedProviderID = navigation.focusedProviderID else {
            return providerSnapshots
        }
        let focused = providerSnapshots.filter { $0.id == focusedProviderID }
        guard !focused.isEmpty else { return providerSnapshots }
        return focused + providerSnapshots.filter { $0.id != focusedProviderID }
    }

    /// The snapshot for a provider in the Costs panel — prefers an exhausted
    /// one so the cost card can surface when that provider's quota resets.
    private func providerSnapshot(for service: ServiceType) -> ProviderSnapshot? {
        let matches = providerSnapshots.filter { $0.service == service }
        return matches.first(where: \.hasExhaustedLimit) ?? matches.first
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var socialShareCardContent: SocialShareCardContent {
        makeSocialShareCardContent(generatedAt: socialCardGeneratedAt)
    }

    private var socialSourceCount: Int {
        max(providerSnapshots.count, visibleCostSummary?.costs.count ?? 0)
    }

    private var socialProviderNames: [String] {
        if let costs = visibleCostSummary?.costs, !costs.isEmpty {
            return costs.map(\.provider.displayName)
        }

        let snapshotTitles = providerSnapshots.map(\.title)
        if !snapshotTitles.isEmpty {
            return snapshotTitles
        }

        return enabledSourceLabels
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
        return labels
    }

    private var tightestLimit: SnapshotLimit? {
        providerSnapshots.tightestLimit
    }

    private var overviewBand: QuotaBand? {
        tightestLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    private var overviewStatusTitle: String {
        guard !providerSnapshots.isEmpty else { return "No sources enabled" }
        guard let overviewBand else { return "Waiting for usage" }
        return overviewBand.overviewTitle
    }

    private var overviewStatusIconName: String {
        // Neutral states (no providers enabled / no usage yet) should not show
        // the healthy green shield, which falsely implies tracked quotas look good.
        overviewBand?.iconName ?? "circle.dashed"
    }

    private var overviewStatusDetail: String {
        guard !providerSnapshots.isEmpty else {
            return "Enable providers in Settings to show quota status."
        }
        guard let tightestLimit else {
            return "Refresh to load enabled provider status."
        }
        if tightestLimit.percentLeft <= 0 {
            return "\(tightestLimit.title) is out until reset. "
                + "Tracking \(providerSnapshots.count) local provider sources."
        }
        return "\(tightestLimit.title) has \(tightestLimit.percentLeft)% left. "
            + "Tracking \(providerSnapshots.count) local provider sources."
    }

    private var diagnosticsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "Provider Diagnostics", trailing: diagnosticsSummary) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These checks run locally. Every line is redacted — safe to paste into a GitHub issue.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("Re-run checks", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRunningDiagnostics)

                        Button {
                            copyDiagnosticsToClipboard()
                        } label: {
                            Label("Copy report", systemImage: "doc.on.doc")
                        }
                        .disabled(readinessReports.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if readinessReports.isEmpty {
                DashboardCard(title: "Running checks…") {
                    Text("Gathering provider setup status.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ReadinessChecklist(reports: readinessReports)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if readinessReports.isEmpty {
                await runDiagnostics()
            }
        }
    }

    private var diagnosticsSummary: String? {
        guard !readinessReports.isEmpty else { return nil }
        let ready = readinessReports.filter(\.isHealthy).count
        let attention = readinessReports.filter { $0.overall == .fail }.count
        return "\(ready) ready · \(attention) need attention"
    }

    /// Runs the readiness inspector off the main actor (it does keychain / file /
    /// SQLite I/O) and publishes the reports back on the main actor.
    private func runDiagnostics() async {
        isRunningDiagnostics = true
        let errors = currentRefreshErrors()
        let reports = await Task.detached(priority: .userInitiated) {
            ProviderReadinessInspector.reports(refreshErrors: errors)
        }.value
        readinessReports = reports
        isRunningDiagnostics = false
    }

    /// Each provider's live last-refresh error, fed into the readiness core so the
    /// "Last refresh" check reflects the app's actual runtime state.
    private func currentRefreshErrors() -> [ServiceType: ServiceError] {
        var result: [ServiceType: ServiceError] = [:]
        if let error = claudeCodeService.lastError { result[.claudeCode] = error }
        if let error = codexCliService.lastError { result[.codexCli] = error }
        if let error = cursorService.lastError { result[.cursor] = error }
        return result
    }

    private func copyDiagnosticsToClipboard() {
        let text = DiagnosticsReportText.plainText(readinessReports)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        case .costs, .share, .optimize:
            return costTracker.isRefreshInProgress
        case .apiUsage:
            return apiUsageStore.isLoading
        case .overview, .limits, .diagnostics, .settings:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        if activeSection == .apiUsage {
            await apiUsageStore.refresh()
        } else if activeSection == .costs || activeSection == .share || activeSection == .optimize {
            await costTracker.scanCosts(days: 30)
            socialCardGeneratedAt = Date()
        } else {
            await dataManager.refreshAll()
        }
    }

    private func refreshCostsIfMissingDays() async {
        let costBackedSections: Set<DashboardSection> = [.costs, .share, .optimize]
        guard costBackedSections.contains(activeSection) else { return }
        await costTracker.refreshMissingDaysInBackground(days: 30)
    }

    private func copySocialCardImage() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        guard let image = renderSocialCardImage(content: content) else {
            setSocialShareStatus("PNG render failed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            setSocialShareStatus("PNG copied")
        } else {
            setSocialShareStatus("Copy failed")
        }
    }

    private func saveSocialCardImage() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        guard let pngData = renderSocialCardPNGData(content: content) else {
            setSocialShareStatus("PNG render failed")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = content.defaultFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
                setSocialShareStatus("PNG saved")
            } catch {
                setSocialShareStatus("Save failed")
            }
        }
    }

    private func copyTweetText() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.tweetText, forType: .string)
        setSocialShareStatus("Text copied")
    }

    private func renderSocialCardImage(content: SocialShareCardContent) -> NSImage? {
        let exportSize = SocialShareCardLayout.exportSize
        let renderer = ImageRenderer(
            content: SocialShareCard(content: content)
                .frame(width: exportSize.width, height: exportSize.height)
        )
        renderer.proposedSize = ProposedViewSize(width: exportSize.width, height: exportSize.height)
        renderer.scale = 1
        return renderer.nsImage
    }

    private func renderSocialCardPNGData(content: SocialShareCardContent) -> Data? {
        guard
            let image = renderSocialCardImage(content: content),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func setSocialShareStatus(_ status: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            socialShareStatus = status
        }
    }
}

private struct DashboardSidebarRow: View {
    let section: DashboardSection
    let isSelected: Bool
    let isCollapsed: Bool
    let action: () -> Void

    @State private var isHovering = false

    private let rowHeight: CGFloat = 32
    private let rowRadius: CGFloat = 8

    var body: some View {
        Button(action: action) {
            rowContent
                .foregroundStyle(.primary)
                .opacity(isSelected ? 1 : (isHovering ? 0.96 : 0.88))
                .frame(
                    maxWidth: .infinity,
                    minHeight: rowHeight,
                    maxHeight: rowHeight,
                    alignment: isCollapsed ? .center : .leading
                )
                .padding(.horizontal, isCollapsed ? 0 : 10)
                .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .background {
            sidebarSelectionSurface
        }
        .onHover { isHovering = $0 }
        .help(section.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var rowContent: some View {
        if isCollapsed {
            Image(systemName: section.iconName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        } else {
            Label(section.rawValue, systemImage: section.iconName)
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
    }

    @ViewBuilder
    private var sidebarSelectionSurface: some View {
        if isSelected || isHovering {
            rowShape
                .fill(Color.white.opacity(isSelected ? 0.13 : 0.065))
                .overlay {
                    rowShape.stroke(
                        Color.white.opacity(isSelected ? 0.18 : 0.10),
                        lineWidth: 0.6
                    )
                }
                .shadow(
                    color: .black.opacity(isSelected ? 0.10 : 0),
                    radius: isSelected ? 5 : 0,
                    y: isSelected ? 2 : 0
                )
        }
    }
}
