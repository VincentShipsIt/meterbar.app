import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

@MainActor
final class LiquidGlassP1RegressionTests: XCTestCase {
    func testMenuBarActionBarKeepsDashboardRefreshAndSettingsReachable() {
        XCTAssertEqual(MenuBarActionBar.Action.allCases, [.dashboard, .refresh, .settings])
    }

    func testMenuBarActionBarFitsTheCompanionPopover() {
        let actionBar = MenuBarActionBar(
            isRefreshing: false,
            openDashboard: {},
            refreshUsage: {},
            openSettings: {}
        )
        let hostingView = NSHostingView(rootView: actionBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 390, height: 46)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, 390)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 40)
    }

    func testMenuPanelCanBecomeKey() {
        let panel = KeyableMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.canBecomeKey)
    }

    func testDailyUsageDayExposesAccessibleChartSummary() {
        let day = DailyUsageDay(
            date: Date(timeIntervalSinceReferenceDate: 0),
            segments: [
                DailyUsageProviderSegment(provider: .claudeCode, tokens: 1_200, cost: 1.25),
                DailyUsageProviderSegment(provider: .codexCli, tokens: 800, cost: 0.75),
            ],
            cost: 2
        )

        XCTAssertFalse(day.chartAccessibilityLabel.isEmpty)
        XCTAssertEqual(
            day.chartAccessibilityValue,
            "2.0K tokens, $2.00, Claude Code 1.2K tokens, $1.25, OpenAI Codex 800 tokens, $0.75"
        )
    }
}
