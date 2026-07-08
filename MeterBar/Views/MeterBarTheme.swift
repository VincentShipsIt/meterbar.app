import AppKit
import MeterBarShared
import SwiftUI

/// Color tokens for MeterBar.
///
/// MeterBar relies on semantic system colors and native containers so the UI
/// adapts to light/dark, the user's accent, Increase Contrast, and Reduce
/// Transparency. The only custom colors are the per-provider brand accents and
/// quota status — and those are kept appearance-adaptive too.
enum MeterBarTheme {
  // MARK: - Brand accents (semantic indicators only; adapt to light/dark)

  static let codexAccent = Color.adaptive(
    light: NSColor(srgbRed: 0 / 255, green: 122 / 255, blue: 168 / 255, alpha: 1),
    dark: NSColor(srgbRed: 100 / 255, green: 210 / 255, blue: 255 / 255, alpha: 1)
  )
  static let claudeAccent = Color.adaptive(
    light: NSColor(srgbRed: 176 / 255, green: 86 / 255, blue: 52 / 255, alpha: 1),
    dark: NSColor(srgbRed: 209 / 255, green: 134 / 255, blue: 101 / 255, alpha: 1)
  )
  static let cursorAccent = Color.adaptive(
    light: NSColor(srgbRed: 34 / 255, green: 150 / 255, blue: 92 / 255, alpha: 1),
    dark: NSColor(srgbRed: 99 / 255, green: 210 / 255, blue: 151 / 255, alpha: 1)
  )
  static let openaiAccent = Color.adaptive(
    light: NSColor(srgbRed: 16 / 255, green: 163 / 255, blue: 127 / 255, alpha: 1),
    dark: NSColor(srgbRed: 106 / 255, green: 216 / 255, blue: 185 / 255, alpha: 1)
  )

  /// The app's own accent. Follows the user's system accent color.
  static let appAccent = Color.accentColor

  // MARK: - Quota status (system colors; adapt to appearance + Increase Contrast)

  static let success = Color(nsColor: .systemGreen)
  // systemOrange (not systemYellow) keeps the amber "Tight" band visually
  // distinct from green/red at caption sizes (PR #33).
  static let warning = Color(nsColor: .systemOrange)
  static let danger = Color(nsColor: .systemRed)

  static let glassCardTint = Color.adaptive(
    light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24),
    dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07),
    lightHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34),
    darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13)
  )

  static let glassCardStroke = Color.adaptive(
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
    dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15),
    lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24),
    darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
  )

  static func accent(for service: ServiceType) -> Color {
    switch service {
    case .claudeCode:
      return claudeAccent
    case .codexCli:
      return codexAccent
    case .cursor:
      return cursorAccent
    }
  }

  static func accent(for provider: ApiProvider) -> Color {
    switch provider {
    case .anthropic:
      return claudeAccent
    case .openai:
      return openaiAccent
    }
  }

  static func quotaStatusColor(percentLeft: Int) -> Color {
    QuotaBand.forPercentLeft(percentLeft).color
  }
}

enum MeterBarWindowChrome {
  private static let red: CGFloat = 0.080
  private static let green: CGFloat = 0.086
  private static let blue: CGFloat = 0.084

  static let dashboardCornerRadius: CGFloat = 14
  static let titlebarContentInset: CGFloat = 48
  static let sidebarTitlebarWidth: CGFloat = 256
  static let collapsedSidebarWidth: CGFloat = 72

  static let color = Color(
    red: Double(red),
    green: Double(green),
    blue: Double(blue)
  )

  static let backgroundColor = NSColor(
    calibratedRed: red,
    green: green,
    blue: blue,
    alpha: 1
  )
}

extension QuotaBand {
  /// Appearance-adaptive color for the band (single place where severity
  /// maps to color, shared by every surface).
  var color: Color {
    switch self {
    case .healthy: return MeterBarTheme.success
    case .tight: return MeterBarTheme.warning
    case .critical, .exhausted: return MeterBarTheme.danger
    }
  }
}

struct MeterBarDetailBackground: View {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  var body: some View {
    ZStack {
      if reduceTransparency {
        MeterBarWindowChrome.color
      } else {
        Color.clear
          .background(.regularMaterial)

        MeterBarWindowChrome.color.opacity(0.78)

        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.15),
            MeterBarTheme.appAccent.opacity(0.08),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    }
  }
}

struct MeterBarDashboardWindowBacking: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      MeterBarDetailBackground()

      HStack(spacing: 0) {
        MeterBarSidebarTitlebarBackground()
          .frame(width: MeterBarWindowChrome.sidebarTitlebarWidth)

        MeterBarDetailBackground()
      }
      .frame(height: MeterBarWindowChrome.titlebarContentInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
    }
  }
}

struct MeterBarSidebarBackground: View {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  var body: some View {
    ZStack {
      if reduceTransparency {
        MeterBarWindowChrome.color
      } else {
        Color.clear
          .background(.regularMaterial)

        MeterBarWindowChrome.color.opacity(0.82)

        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.10),
            MeterBarTheme.appAccent.opacity(0.06),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    }
  }
}

struct MeterBarSidebarSurface: View {
  var radius: CGFloat = MeterBarWindowChrome.dashboardCornerRadius

  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

    ZStack {
      if reduceTransparency {
        shape.fill(MeterBarWindowChrome.color)
      } else {
        shape
          .fill(.ultraThinMaterial)
          .glassEffect(.regular, in: shape)

        shape.fill(MeterBarWindowChrome.color.opacity(0.42))

        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.18),
            MeterBarTheme.appAccent.opacity(0.08),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .clipShape(shape)
      }
    }
    .overlay {
      shape.stroke(MeterBarTheme.glassCardStroke, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.20), radius: 18, y: 10)
  }
}

struct MeterBarTitlebarGlass: View {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  var body: some View {
    ZStack {
      if reduceTransparency {
        MeterBarWindowChrome.color
      } else {
        Color.clear
          .background(.thinMaterial)

        MeterBarWindowChrome.color.opacity(0.58)

        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.10),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    }
  }
}

struct MeterBarSidebarTitlebarBackground: View {
  var body: some View {
    MeterBarTitlebarGlass()
      .overlay {
        MeterBarWindowChrome.color.opacity(0.18)
      }
  }
}

struct MeterBarCompanionSurface: View {
  var radius: CGFloat = 16

  var body: some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(.ultraThinMaterial)
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(MeterBarWindowChrome.color.opacity(0.74))
      }
      .overlay(alignment: .topLeading) {
        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.20),
            MeterBarTheme.appAccent.opacity(0.08),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(MeterBarTheme.glassCardStroke, lineWidth: 1)
      }
  }
}

extension View {
  func meterBarSurfaceStyle(_ style: MeterBarSurfaceStyle) -> some View {
    environment(\.meterBarSurfaceStyle, style)
  }

  func meterBarCardSurface(cornerRadius: CGFloat = 12) -> some View {
    modifier(MeterBarCardSurfaceModifier(cornerRadius: cornerRadius))
  }
}

enum MeterBarSurfaceStyle {
  case dashboard
  case toolbar
}

private struct MeterBarSurfaceStyleKey: EnvironmentKey {
  static let defaultValue: MeterBarSurfaceStyle = .dashboard
}

private extension EnvironmentValues {
  var meterBarSurfaceStyle: MeterBarSurfaceStyle {
    get { self[MeterBarSurfaceStyleKey.self] }
    set { self[MeterBarSurfaceStyleKey.self] = newValue }
  }
}

private struct MeterBarCardSurfaceModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    content
      .background(.ultraThinMaterial, in: shape)
      .overlay {
        shape.fill(MeterBarTheme.glassCardTint)
      }
      .overlay {
        shape.stroke(MeterBarTheme.glassCardStroke, lineWidth: 0.5)
      }
  }
}

extension Color {
  /// An appearance-adaptive color backed by a dynamic `NSColor`, resolving the
  /// correct value for light / dark (and optionally high-contrast) appearances.
  static func adaptive(
    light: NSColor,
    dark: NSColor,
    lightHighContrast: NSColor? = nil,
    darkHighContrast: NSColor? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [
          .aqua, .darkAqua,
          .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua: return dark
        case .accessibilityHighContrastAqua: return lightHighContrast ?? light
        case .accessibilityHighContrastDarkAqua: return darkHighContrast ?? dark
        default: return light
        }
      })
  }
}
