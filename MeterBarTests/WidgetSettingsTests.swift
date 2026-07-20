import AppKit
import MeterBarShared
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class WidgetSettingsTests: XCTestCase {
    func testWidgetRouteIsBetweenProvidersAndAPIUsage() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .providers, .widget, .apiUsage, .cost, .automation, .about]
        )
        XCTAssertEqual(SettingsSection.widget.iconName, "rectangle.3.group")
    }

    func testAccountProjectionIncludesOnlyEnabledProvidersAndAccounts() {
        let enabledClaude = ClaudeCodeAccount(
            id: UUID(),
            name: "Claude Work",
            configDirectory: nil
        )
        let disabledClaude = ClaudeCodeAccount(
            id: UUID(),
            name: "Claude Disabled",
            configDirectory: nil,
            isEnabled: false
        )
        let enabledCodex = CodexAccount(
            id: UUID(),
            name: "Codex Work",
            homeDirectory: nil
        )
        let options = WidgetSettingsAccountProjection.options(
            enabledServices: [.claudeCode, .codexCli, .cursor],
            claudeAccounts: [enabledClaude, disabledClaude],
            codexAccounts: [enabledCodex]
        )

        XCTAssertEqual(options.map(\.name), ["Claude Work", "Codex Work", "Cursor"])
        XCTAssertEqual(options.map(\.service), [.claudeCode, .codexCli, .cursor])
        XCTAssertFalse(options.contains { $0.name == disabledClaude.name })
    }

    func testAccountProjectionHandlesEmptyEnabledAccountLists() {
        let options = WidgetSettingsAccountProjection.options(
            enabledServices: [.claudeCode, .codexCli],
            claudeAccounts: [],
            codexAccounts: []
        )

        XCTAssertTrue(options.isEmpty)
    }

    func testSelectionTransitionsBetweenSelectAllAndExplicit() {
        let claude = WidgetAccountIdentifier.provider(.claudeCode)
        let codex = WidgetAccountIdentifier.provider(.codexCli)
        let available: Set<WidgetAccountIdentifier> = [claude, codex]

        let explicit = WidgetSettingsSelection.toggling(
            claude,
            isSelected: false,
            selection: .all,
            availableIdentifiers: available
        )
        XCTAssertEqual(explicit.mode, .explicit)
        XCTAssertEqual(explicit.explicitIdentifiers, [codex])

        let all = WidgetSettingsSelection.toggling(
            claude,
            isSelected: true,
            selection: explicit,
            availableIdentifiers: available
        )
        XCTAssertEqual(all, .all)
        XCTAssertTrue(WidgetSettingsSelection.contains(claude, selection: all))
        XCTAssertTrue(WidgetSettingsSelection.contains(codex, selection: all))
    }

    func testPlaceholderPreviewUsesEverySupportedFamilyAndCurrentPreferences() {
        let options = [
            WidgetSettingsAccountOption(
                id: .provider(.cursor),
                service: .cursor,
                name: "Cursor"
            )
        ]
        let data = WidgetSettingsPreviewData.make(
            options: options,
            metrics: [:],
            claudeAccountMetrics: [:],
            codexAccountMetrics: [:],
            now: Date(timeIntervalSinceReferenceDate: 1_000_000)
        )
        var preferences = WidgetPreferences.defaults
        preferences.displayMode = .remaining

        XCTAssertTrue(data.usesPlaceholders)
        for family in WidgetPresentationFamily.allCases {
            let presentation = WidgetPresentationPlanner.makePresentation(
                metrics: data.metrics,
                accountMetrics: data.accountMetrics,
                preferences: preferences,
                family: family,
                now: Date(timeIntervalSinceReferenceDate: 1_000_000)
            )
            XCTAssertNil(presentation.emptyState, "\(family)")
            XCTAssertEqual(presentation.rows.first?.displayMode, .remaining, "\(family)")
        }
    }

    func testWidgetSettingsAndAllPreviewAppearancesRender() throws {
        let settingsView = NSHostingView(rootView: WidgetSettingsView().frame(width: 720))
        settingsView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(settingsView.fittingSize.height, 0)

        let data = WidgetSettingsPreviewData.make(
            options: [
                WidgetSettingsAccountOption(
                    id: .provider(.cursor),
                    service: .cursor,
                    name: "Cursor"
                )
            ],
            metrics: [:],
            claudeAccountMetrics: [:],
            codexAccountMetrics: [:]
        )
        for appearance in WidgetSettingsPreviewAppearance.allCases {
            let gallery = NSHostingView(
                rootView: WidgetSettingsPreviewGallery(
                    data: data,
                    preferences: .defaults,
                    appearance: appearance
                )
            )
            gallery.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(gallery.fittingSize.height, 0, appearance.title)
        }

        try captureReviewScreenshots(data: data)
    }

    private func captureReviewScreenshots(
        data: WidgetSettingsPreviewData
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSettingsReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try writeScreenshot(
            WidgetSettingsView()
                .frame(width: 720)
                .padding(24)
                .background(Color.white)
                .environment(\.colorScheme, .light),
            size: CGSize(width: 768, height: 1_650),
            to: directory.appendingPathComponent("widget-settings.png")
        )

        for family in WidgetPresentationFamily.allCases {
            let presentation = WidgetPresentationPlanner.makePresentation(
                metrics: data.metrics,
                accountMetrics: data.accountMetrics,
                preferences: .defaults,
                family: family,
                now: Date()
            )
            let preview = WidgetSettingsPreviewSurface(
                family: family,
                presentation: presentation,
                appearance: .light
            )
            try writeScreenshot(
                preview,
                size: family.reviewScreenshotSize,
                to: directory.appendingPathComponent("\(family.reviewFilename).png")
            )
        }
    }

    private func writeScreenshot<Content: View>(
        _ content: Content,
        size: CGSize,
        to url: URL
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            XCTFail("Could not create screenshot bitmap for \(url.lastPathComponent)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode screenshot \(url.lastPathComponent)")
            return
        }
        try png.write(to: url, options: .atomic)
        let base64 = png.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithLineFeed]
        )
        let payload = """
        METERBAR_SCREENSHOT_BEGIN \(url.lastPathComponent)
        \(base64)
        METERBAR_SCREENSHOT_END \(url.lastPathComponent)
        """
        FileHandle.standardOutput.write(Data(payload.utf8))
    }
}

private extension WidgetPresentationFamily {
    var reviewFilename: String {
        switch self {
        case .small: return "widget-small"
        case .medium: return "widget-medium"
        case .large: return "widget-large"
        }
    }

    var reviewScreenshotSize: CGSize {
        switch self {
        case .small: return CGSize(width: 150, height: 150)
        case .medium: return CGSize(width: 310, height: 150)
        case .large: return CGSize(width: 310, height: 300)
        }
    }
}
