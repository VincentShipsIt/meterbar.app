import AppKit
import SwiftUI

struct MenuBarView: View {
    private let popoverWidth: CGFloat = 390
    private let maxPopoverHeight: CGFloat = 560
    private let minPopoverHeight: CGFloat = 180
    private let chromeHeight: CGFloat = 56

    let onContentSizeChange: (NSSize) -> Void

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared

    @State private var contentHeight: CGFloat = 320

    init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
        self.onContentSizeChange = onContentSizeChange
    }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader

            Divider()

            ScrollView {
                PopoverOverviewPanel(
                    metrics: dataManager.metrics,
                    claudeAccounts: claudeAccountStore.accounts,
                    claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                    claudeCodeHasAccess: claudeCodeService.hasAccess,
                    codexCliHasAccess: codexCliService.hasAccess,
                    cursorHasAccess: cursorService.hasAccess,
                    enabledServices: providerVisibility.enabledServices,
                    openDashboard: openDashboard
                )
                    .padding(10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MenuContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: scrollHeight)
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .onAppear {
            notifyContentSize()
        }
        .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - contentHeight) > 1 else { return }
            contentHeight = height
            notifyContentSize(height: height)
        }
    }

    private var scrollHeight: CGFloat {
        min(max(80, contentHeight), maxPopoverHeight - chromeHeight)
    }

    private var popoverHeight: CGFloat {
        min(max(chromeHeight + scrollHeight, minPopoverHeight), maxPopoverHeight)
    }

    private func notifyContentSize(height: CGFloat? = nil) {
        let measuredHeight = height ?? contentHeight
        let targetScrollHeight = min(max(80, measuredHeight), maxPopoverHeight - chromeHeight)
        let targetHeight = min(max(chromeHeight + targetScrollHeight, minPopoverHeight), maxPopoverHeight)
        onContentSizeChange(NSSize(width: popoverWidth, height: targetHeight))
    }

    private var popoverHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MeterBarTheme.appAccent)
                Text("MeterBar")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Spacer()

            Button(action: openDashboard) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Open Usage Dashboard")

            Button {
                Task { await dataManager.refreshAll() }
            } label: {
                RefreshingIcon(isRefreshing: dataManager.isLoading)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(dataManager.isLoading ? "Refreshing usage" : "Refresh usage")

            optionsMenu
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show in Dock", isOn: Binding(
                get: { dockVisibility.showInDock },
                set: { dockVisibility.setShowInDock($0) }
            ))
            Button("Open Usage Dashboard", action: openDashboard)
            Divider()
            Button("Quit MeterBar") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
    }

    private func openDashboard() {
        UsageDashboardWindowController.shared.show()
    }
}

// MARK: - Reusable Components

struct PopoverOverviewPanel: View {
    let metrics: [ServiceType: UsageMetrics]
    let claudeAccounts: [ClaudeCodeAccount]
    let claudeAccountMetrics: [UUID: UsageMetrics]
    let claudeCodeHasAccess: Bool
    let codexCliHasAccess: Bool
    let cursorHasAccess: Bool
    let enabledServices: Set<ServiceType>
    let openDashboard: () -> Void

    private var snapshots: [ProviderQuotaSnapshot] {
        var result: [ProviderQuotaSnapshot] = []

        if isEnabled(.codexCli) {
            result.append(ProviderQuotaSnapshot(
                title: "Codex",
                service: .codexCli,
                metrics: metrics[.codexCli],
                emptyDetail: codexCliHasAccess ? "Waiting for refresh" : "Run codex login"
            ))
        }

        if isEnabled(.claudeCode) {
            let accountMetrics = claudeAccountMetrics
            if !accountMetrics.isEmpty {
                for account in claudeAccounts {
                    let title = account.isDefault && claudeAccounts.count == 1 ? "Claude" : account.name
                    result.append(ProviderQuotaSnapshot(
                        title: title,
                        service: .claudeCode,
                        metrics: accountMetrics[account.id],
                        emptyDetail: account.isDefault ? "Waiting for refresh" : "Run claude login",
                        accountID: account.id
                    ))
                }
            } else {
                result.append(ProviderQuotaSnapshot(
                    title: "Claude",
                    service: .claudeCode,
                    metrics: metrics[.claudeCode],
                    emptyDetail: claudeCodeHasAccess ? "Waiting for refresh" : "Run claude login"
                ))
            }
        }

        if isEnabled(.cursor) {
            result.append(ProviderQuotaSnapshot(
                title: "Cursor",
                service: .cursor,
                metrics: metrics[.cursor],
                emptyDetail: cursorHasAccess ? "Waiting for refresh" : "Log in to Cursor"
            ))
        }

        return result
    }

    private func isEnabled(_ service: ServiceType) -> Bool {
        enabledServices.contains(service)
    }

    private var tightestLimit: ProviderQuotaLimit? {
        snapshots.compactMap(\.primaryLimit).min { $0.percentLeft < $1.percentLeft }
    }

    private var statusColor: Color {
        guard let tightestLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: tightestLimit.percentLeft)
    }

    private var statusTitle: String {
        guard !snapshots.isEmpty else { return "No sources enabled" }
        guard let tightestLimit else { return "Waiting for usage" }
        if tightestLimit.percentLeft <= 0 { return "Quota exhausted" }
        if tightestLimit.percentLeft <= 10 { return "Quota needs attention" }
        if tightestLimit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
    }

    private var statusDetail: String {
        guard !snapshots.isEmpty else {
            return "Enable a provider in Settings."
        }
        guard let tightestLimit else {
            return "Refresh to load enabled providers."
        }
        if tightestLimit.percentLeft <= 0 {
            return "\(tightestLimit.title) is out until reset across \(sourcesLabel)."
        }
        return "\(tightestLimit.title) has \(tightestLimit.percentLeft)% left across \(sourcesLabel)."
    }

    private var sourcesLabel: String {
        snapshots.count == 1 ? "1 source" : "\(snapshots.count) sources"
    }

    private var statusIconName: String {
        guard let tightestLimit else { return "clock.fill" }
        // Align icon severity with the status color/title bands: the <= 10 "needs
        // attention" band is red (danger), so it gets the strong octagon icon
        // rather than the same triangle used for the orange "tight" band.
        if tightestLimit.percentLeft <= 10 { return "exclamationmark.octagon.fill" }
        if tightestLimit.percentLeft <= 25 { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 34, height: 34)
                    Image(systemName: statusIconName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .cardSurface()

            VStack(spacing: 8) {
                ForEach(snapshots) { snapshot in
                    ProviderQuotaCard(snapshot: snapshot, variant: .popover)
                }
            }

            Button(action: openDashboard) {
                HStack {
                    Label("Open Usage Dashboard", systemImage: "rectangle.split.2x1")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardSurface()
        }
    }
}

private extension View {
    /// Popover content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the popover and dashboard cards stay visually identical.
    func cardSurface() -> some View {
        meterBarCardSurface()
    }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
