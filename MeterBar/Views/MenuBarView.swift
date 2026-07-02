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

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
