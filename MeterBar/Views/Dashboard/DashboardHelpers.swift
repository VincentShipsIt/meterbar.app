import AppKit
import SwiftUI

func providerLogoKind(for provider: ServiceType) -> ProviderLogoKind {
    switch provider {
    case .codexCli, .openai:
        return .codex
    case .claude, .claudeCode:
        return .claude
    case .cursor:
        return .cursor
    }
}

func color(for provider: ServiceType) -> Color {
    MeterBarTheme.accent(for: provider)
}

extension View {
    /// Dashboard content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the dashboard and popover cards stay visually identical.
    func dashboardCardBackground() -> some View {
        meterBarCardSurface()
    }
}
