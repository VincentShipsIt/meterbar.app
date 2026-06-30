import AppKit
import SwiftUI

enum ProviderLogoKind: Equatable {
    case overview
    case codex
    case claude
    case cursor

    var resourceName: String? {
        switch self {
        case .overview:
            return nil
        case .codex:
            return "ProviderIcon-codex"
        case .claude:
            return "ProviderIcon-claude"
        case .cursor:
            return "ProviderIcon-cursor"
        }
    }

    var fallbackSystemName: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .codex:
            return ServiceType.codexCli.iconName
        case .claude:
            return ServiceType.claudeCode.iconName
        case .cursor:
            return ServiceType.cursor.iconName
        }
    }
}

struct ProviderQuotaSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let logoKind: ProviderLogoKind
    let accentColor: Color
    let updatedAt: Date?
    let limits: [ProviderQuotaLimit]
    let emptyDetail: String
    let extraUsage: ExtraUsageStatus?
    let resetCreditsAvailable: Int?

    init(
        title: String,
        service: ServiceType,
        metrics: UsageMetrics?,
        emptyDetail: String = "No quota windows reported",
        accountID: UUID? = nil
    ) {
        self.id = "\(service.rawValue)-\(title)-\(accountID?.uuidString ?? "default")"
        self.title = title
        self.service = service
        self.logoKind = providerLogoKind(for: service)
        self.accentColor = MeterBarTheme.accent(for: service)
        self.updatedAt = metrics?.lastUpdated
        self.emptyDetail = emptyDetail
        self.extraUsage = metrics?.extraUsage
        self.resetCreditsAvailable = metrics?.resetCreditsAvailable
        self.limits = [
            ProviderQuotaLimit(title: "Session", limit: metrics?.sessionLimit),
            ProviderQuotaLimit(title: "Weekly", limit: metrics?.weeklyLimit),
            ProviderQuotaLimit(title: Self.tertiaryLimitTitle(for: service), limit: metrics?.codeReviewLimit)
        ].compactMap { $0 }
    }

    var primaryLimit: ProviderQuotaLimit? {
        limits.min { $0.percentLeft < $1.percentLeft }
    }

    var resetWindows: [ResetCountdownWindow] {
        limits.map {
            ResetCountdownWindow(
                id: "\(id)-\($0.title)",
                title: $0.title,
                limit: $0.usageLimit
            )
        }
    }

    var hasExhaustedLimit: Bool {
        limits.contains { $0.usageLimit.isAtLimit }
    }

    var isOut: Bool {
        guard let primaryLimit else { return false }
        return primaryLimit.percentLeft <= 0
    }

    var updatedText: String {
        guard let updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }

    var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: primaryLimit.percentLeft)
    }

    func statusText(empty: String) -> String {
        guard let primaryLimit else { return empty }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    static func resetCreditsLabel(_ count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") available"
    }

    private static func tertiaryLimitTitle(for service: ServiceType) -> String {
        switch service {
        case .claude, .claudeCode:
            return "Sonnet"
        case .codexCli, .cursor, .openai:
            return "Code Review"
        }
    }
}

struct ProviderQuotaLimit: Identifiable {
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
        let remainingPercent = max(0, 100 - usedPercent)
        return remainingPercent == 0 ? 0 : max(1, Int(ceil(remainingPercent)))
    }
}

enum ProviderQuotaCardVariant {
    case popover
    case dashboardOverview(minHeight: CGFloat)
    case dashboardLimits

    var cardSpacing: CGFloat {
        switch self {
        case .popover:
            return 10
        case .dashboardOverview, .dashboardLimits:
            return 12
        }
    }

    var padding: CGFloat {
        switch self {
        case .popover:
            return 11
        case .dashboardOverview, .dashboardLimits:
            return 14
        }
    }

    var minHeight: CGFloat? {
        switch self {
        case .popover:
            return 124
        case .dashboardOverview(let minHeight):
            return minHeight
        case .dashboardLimits:
            return nil
        }
    }

    var headerSpacing: CGFloat {
        switch self {
        case .popover:
            return 7
        case .dashboardOverview, .dashboardLimits:
            return 9
        }
    }

    var logoSize: CGFloat {
        switch self {
        case .popover:
            return 17
        case .dashboardOverview:
            return 20
        case .dashboardLimits:
            return 18
        }
    }

    var titleFont: Font {
        switch self {
        case .popover:
            return .subheadline
        case .dashboardOverview:
            return .headline
        case .dashboardLimits:
            return .title3
        }
    }

    var subtitleFont: Font {
        switch self {
        case .popover:
            return .caption2
        case .dashboardOverview, .dashboardLimits:
            return .caption
        }
    }

    var statusFont: Font {
        switch self {
        case .popover:
            return .caption2
        case .dashboardOverview, .dashboardLimits:
            return .caption
        }
    }

    var emptyFont: Font {
        switch self {
        case .popover, .dashboardOverview:
            return .caption
        case .dashboardLimits:
            return .subheadline
        }
    }

    var limitRowVariant: ProviderQuotaLimitRowVariant {
        switch self {
        case .popover:
            return .popover
        case .dashboardOverview, .dashboardLimits:
            return .dashboard
        }
    }

    var limitSpacing: CGFloat {
        switch self {
        case .popover:
            return 9
        case .dashboardOverview, .dashboardLimits:
            return 12
        }
    }

    var emptyMinHeight: CGFloat? {
        switch self {
        case .popover, .dashboardOverview:
            return 54
        case .dashboardLimits:
            return nil
        }
    }

    var emptyStatusText: String {
        switch self {
        case .popover:
            return "Offline"
        case .dashboardOverview, .dashboardLimits:
            return "No data"
        }
    }

    var showsStatus: Bool {
        switch self {
        case .popover, .dashboardOverview:
            return true
        case .dashboardLimits:
            return false
        }
    }

    var showsSupplementalStatus: Bool {
        switch self {
        case .popover:
            return true
        case .dashboardOverview, .dashboardLimits:
            return false
        }
    }
}

struct ProviderQuotaCard: View {
    let snapshot: ProviderQuotaSnapshot
    let variant: ProviderQuotaCardVariant

    var body: some View {
        VStack(alignment: .leading, spacing: variant.cardSpacing) {
            header
            quotaContent
            supplementalStatus
        }
        .padding(variant.padding)
        .frame(maxWidth: .infinity, minHeight: variant.minHeight, alignment: .topLeading)
        .opacity(variant.showsSupplementalStatus && snapshot.isOut ? 0.72 : 1)
        .meterBarCardSurface()
    }

    @ViewBuilder
    private var header: some View {
        if case .dashboardLimits = variant {
            HStack {
                ProviderTitle(
                    title: snapshot.title,
                    logoKind: snapshot.logoKind,
                    color: snapshot.accentColor,
                    font: variant.titleFont,
                    logoSize: variant.logoSize
                )
                Spacer()
                Text(snapshot.updatedText)
                    .font(variant.subtitleFont)
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(alignment: .center, spacing: variant.headerSpacing) {
                ProviderLogoView(kind: snapshot.logoKind, size: variant.logoSize, foregroundColor: snapshot.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(variant.titleFont)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(snapshot.updatedText)
                        .font(variant.subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if variant.showsStatus {
                    Text(snapshot.statusText(empty: variant.emptyStatusText))
                        .font(variant.statusFont)
                        .fontWeight(.semibold)
                        .foregroundColor(snapshot.statusColor)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if snapshot.limits.isEmpty {
            Text(snapshot.emptyDetail)
                .font(variant.emptyFont)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: variant.emptyMinHeight, alignment: .topLeading)
        } else if snapshot.hasExhaustedLimit {
            BlockingLimitResetCounter(
                windows: snapshot.resetWindows,
                accentColor: snapshot.accentColor
            )
        } else {
            VStack(alignment: .leading, spacing: variant.limitSpacing) {
                ForEach(snapshot.limits) { limit in
                    ProviderQuotaLimitRow(
                        limit: limit,
                        accentColor: snapshot.accentColor,
                        variant: variant.limitRowVariant
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var supplementalStatus: some View {
        if variant.showsSupplementalStatus {
            if let resetCount = snapshot.resetCreditsAvailable, resetCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(snapshot.accentColor)
                    Text(ProviderQuotaSnapshot.resetCreditsLabel(resetCount))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer(minLength: 4)
                }
                .help(
                    "\(ProviderQuotaSnapshot.resetCreditsLabel(resetCount)) - banked quota resets you can trigger " +
                    "when you hit a rate limit."
                )
            }

            if let extraUsage = snapshot.extraUsage {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Extra usage")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    ExtraUsageStatusPill(status: extraUsage)
                }
            }
        }
    }
}

enum ProviderQuotaLimitRowVariant {
    case popover
    case dashboard
}

struct ProviderQuotaLimitRow: View {
    let limit: ProviderQuotaLimit
    let accentColor: Color
    let variant: ProviderQuotaLimitRowVariant

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

    var body: some View {
        switch variant {
        case .popover:
            popoverRow
        case .dashboard:
            dashboardRow
        }
    }

    private var popoverRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(limitValueText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(limitValueColor)
                    .lineLimit(1)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: paceContext
            )

            if limit.usageLimit.resetTime != nil {
                ResetCountdownLabel(
                    title: limit.title,
                    limit: limit.usageLimit,
                    font: .caption2,
                    foregroundColor: .secondary,
                    iconSize: 9
                )
            }
        }
    }

    private var dashboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(limitValueText)
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(limitValueColor)
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
                        .foregroundColor(paceLabelColor(pace))
                }
                Spacer()
                if limit.usageLimit.resetTime != nil {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: .caption,
                        foregroundColor: .secondary,
                        iconSize: 10
                    )
                }
            }
        }
    }

    private var limitValueText: String {
        isOut ? "Out" : "\(limit.percentLeft)% left"
    }

    private var limitValueColor: Color {
        isOut ? MeterBarTheme.danger : .primary
    }

    private func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return MeterBarTheme.danger
        }
        switch pace.stage {
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }
}

struct ResetCountdownWindow: Identifiable {
    let id: String
    let title: String
    let limit: UsageLimit
}

/// Shared tick schedule for all reset-countdown labels. Anchoring to a fixed
/// reference date keeps every label in phase so ticks land on minute boundaries.
private enum ResetCountdownSchedule {
    static let anchor = Date(timeIntervalSinceReferenceDate: 0)
    static let interval: TimeInterval = 60
}

struct ResetCountdownLabel: View {
    let title: String?
    let limit: UsageLimit
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let text = Self.counterText(title: title, limit: limit, now: timeline.date) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    static func counterText(title: String?, limit: UsageLimit, now: Date) -> String? {
        guard let countdown = limit.resetCountdownText(now: now) else { return nil }
        if countdown == "now" {
            return title.map { "\($0) reset due" } ?? "Reset due"
        }
        return title.map { "\($0) reset in \(countdown)" } ?? "Resets in \(countdown)"
    }
}

struct NextResetCountdownLabel: View {
    let windows: [ResetCountdownWindow]
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    /// How long after a window's reset time we keep showing "reset due" before
    /// treating the data as stale and hiding the label.
    static let resetDueGracePeriod: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let window = Self.selectNextWindow(windows, now: timeline.date),
                   let text = ResetCountdownLabel.counterText(
                       title: window.title,
                       limit: window.limit,
                       now: timeline.date
                   ) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    static func selectNextWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let candidates = windows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let next = futureCandidates.min(by: { $0.seconds < $1.seconds }) {
            return next.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }
}

struct BlockingLimitResetCounter: View {
    let windows: [ResetCountdownWindow]
    let accentColor: Color

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = Self.selectBlockingWindow(windows, now: timeline.date)
            let title = Self.titleText(for: blockingWindow, in: windows)
            let counter = Self.counterText(for: blockingWindow, now: timeline.date)
            let detail = Self.detailText(for: blockingWindow, in: windows)

            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(counter)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .help("\(title) \(counter)")
        }
    }

    static func selectBlockingWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = NextResetCountdownLabel.resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let exhaustedWindows = windows.filter { $0.limit.isAtLimit }
        guard !exhaustedWindows.isEmpty else { return nil }

        let candidates = exhaustedWindows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        guard candidates.count == exhaustedWindows.count else { return nil }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let blocking = futureCandidates.max(by: { $0.seconds < $1.seconds }) {
            return blocking.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }

    static func titleText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        if let window {
            return "\(window.title) reset"
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1 ? "Limits exhausted" : "Limit exhausted"
    }

    static func counterText(for window: ResetCountdownWindow?, now: Date) -> String {
        guard let window,
              let countdown = window.limit.resetCountdownText(now: now) else {
            return "Reset time unavailable"
        }

        return countdown == "now" ? "due now" : "in \(countdown)"
    }

    static func detailText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        guard window != nil else {
            return "Usage is unavailable until the reset is reported."
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1
            ? "Usage resumes after exhausted limits reset."
            : "Usage is unavailable until this limit resets."
    }
}

struct ExtraUsageStatusPill: View {
    let status: ExtraUsageStatus

    private var label: String {
        switch status.state {
        case .on: return "On"
        case .off: return "Off"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        switch status.state {
        case .on: return MeterBarTheme.warning
        case .off: return MeterBarTheme.success
        case .unknown: return .secondary
        }
    }

    private var tooltip: String {
        switch status.state {
        case .on:
            let base = "Extra usage is ON - overage can be billed beyond your plan."
            return status.detail.map { "\(base)\n\($0)" } ?? base
        case .off:
            return "Extra usage is OFF - usage is capped at your subscription quota."
        case .unknown:
            return "Extra usage state could not be determined."
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(color.opacity(0.20), lineWidth: 1)
        }
        .help(tooltip)
    }
}

struct ProviderTitle: View {
    let title: String
    let logoKind: ProviderLogoKind
    let color: Color
    let font: Font
    var logoSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: logoKind, size: logoSize, foregroundColor: color)
            Text(title)
                .font(font)
                .fontWeight(.semibold)
        }
    }
}

struct ProviderLogoView: View {
    let kind: ProviderLogoKind
    let size: CGFloat
    let foregroundColor: Color

    var body: some View {
        if let resourceName = kind.resourceName,
           let image = ProviderLogoImageCache.image(named: resourceName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.fallbackSystemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        }
    }
}

enum ProviderLogoImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        if let image = NSImage(named: name) ?? bundledSVGImage(named: name) {
            image.isTemplate = true
            cache[name] = image
            return image
        }

        return nil
    }

    private static func bundledSVGImage(named name: String) -> NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: name, withExtension: "svg") ??
            bundle.url(forResource: name, withExtension: "svg", subdirectory: "Resources")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct UsageBar: View {
    let usedPercentage: Double
    let accentColor: Color
    let pace: UsagePace?
    let paceContext: PaceLabelContext

    private var clampedUsedPercentage: Double {
        min(max(usedPercentage, 0), 100)
    }

    private var clampedRemainingPercentage: Double {
        max(0, 100 - clampedUsedPercentage)
    }

    private var isExhausted: Bool {
        clampedRemainingPercentage <= 0 || pace?.isExhausted == true
    }

    private var tooltipText: String? {
        guard let pace else {
            return isExhausted ? "Out of quota\nActual: 100% used\nLeft: 0%" : nil
        }

        var lines = [
            pace.leftLabel,
            "Actual: \(Int(clampedUsedPercentage.rounded()))% used",
            "Left: \(Int(clampedRemainingPercentage.rounded()))%",
            "Expected by now: \(Int(pace.expectedUsedPercent.rounded()))% used",
            "Expected left: \(Int(max(0, 100 - pace.expectedUsedPercent).rounded()))%",
            "Colored fill is current quota left."
        ]

        if isExhausted {
            lines.append("Quota is exhausted until the reset window opens.")
        } else if pace.stage == .deficit {
            lines.append("Red is quota you should still have at this pace.")
        }

        if let rightLabel = pace.rightLabel(context: paceContext) {
            lines.append(rightLabel)
        }

        return lines.joined(separator: "\n")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 7)
                    .offset(y: 4)

                if isExhausted {
                    Capsule()
                        .fill(MeterBarTheme.danger.opacity(0.16))
                        .frame(width: proxy.size.width, height: 7)
                        .offset(y: 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MeterBarTheme.danger)
                        .frame(width: 2, height: 13)
                        .offset(x: max(0, proxy.size.width - 2), y: 1)
                } else if let pace, pace.stage != .onPace {
                    let expectedRemainingPercent = max(0, 100 - min(max(pace.expectedUsedPercent, 0), 100))
                    let expectedX = proxy.size.width * expectedRemainingPercent / 100
                    let actualX = proxy.size.width * clampedRemainingPercentage / 100

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(accentColor)
                            .frame(width: actualX, height: 7)

                        if pace.stage == .deficit {
                            Rectangle()
                                .fill(MeterBarTheme.danger.opacity(0.86))
                                .frame(width: max(0, expectedX - actualX), height: 7)
                                .offset(x: actualX)
                        }
                    }
                    .clipShape(Capsule())
                    .offset(y: 4)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(markerColor(for: pace))
                        .frame(width: 2, height: 13)
                        .offset(x: min(max(0, expectedX - 1), max(0, proxy.size.width - 2)), y: 1)
                } else {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: proxy.size.width * clampedRemainingPercentage / 100, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(y: 4)
                }
            }
        }
        .frame(height: 15)
        .help(tooltipText ?? "")
    }

    private func markerColor(for pace: UsagePace) -> Color {
        switch pace.stage {
        case .onPace:
            return .white.opacity(0.85)
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.danger
        }
    }
}

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
