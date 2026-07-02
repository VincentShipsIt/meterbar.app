import SwiftUI

struct PopoverOverviewPanel: View {
    let metrics: [ServiceType: UsageMetrics]
    let claudeAccounts: [ClaudeCodeAccount]
    let claudeAccountMetrics: [UUID: UsageMetrics]
    let claudeCodeHasAccess: Bool
    let codexCliHasAccess: Bool
    let cursorHasAccess: Bool
    let enabledServices: Set<ServiceType>
    let openDashboard: () -> Void

    private var snapshots: [PopoverProviderSnapshot] {
        var result: [PopoverProviderSnapshot] = []

        if isEnabled(.codexCli) {
            result.append(PopoverProviderSnapshot(
                title: "Codex",
                logoKind: .codex,
                accentColor: MeterBarTheme.codexAccent,
                metrics: metrics[.codexCli],
                emptyDetail: codexCliHasAccess ? "Waiting for refresh" : "Run codex login"
            ))
        }

        if isEnabled(.claudeCode) {
            let accountMetrics = claudeAccountMetrics
            if !accountMetrics.isEmpty {
                for account in claudeAccounts {
                    let title = account.isDefault && claudeAccounts.count == 1 ? "Claude" : account.name
                    result.append(PopoverProviderSnapshot(
                        title: title,
                        logoKind: .claude,
                        accentColor: MeterBarTheme.claudeAccent,
                        metrics: accountMetrics[account.id],
                        emptyDetail: account.isDefault ? "Waiting for refresh" : "Run claude login",
                        accountID: account.id
                    ))
                }
            } else {
                result.append(PopoverProviderSnapshot(
                    title: "Claude",
                    logoKind: .claude,
                    accentColor: MeterBarTheme.claudeAccent,
                    metrics: metrics[.claudeCode],
                    emptyDetail: claudeCodeHasAccess ? "Waiting for refresh" : "Run claude login"
                ))
            }
        }

        if isEnabled(.cursor) {
            result.append(PopoverProviderSnapshot(
                title: "Cursor",
                logoKind: .cursor,
                accentColor: MeterBarTheme.cursorAccent,
                metrics: metrics[.cursor],
                emptyDetail: cursorHasAccess ? "Waiting for refresh" : "Log in to Cursor"
            ))
        }

        return result
    }

    private func isEnabled(_ service: ServiceType) -> Bool {
        enabledServices.contains(service)
    }

    private var tightestLimit: PopoverLimit? {
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
                    PopoverProviderStatusCard(snapshot: snapshot)
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

struct PopoverProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let logoKind: ProviderLogoKind
    let accentColor: Color
    let updatedAt: Date?
    let limits: [PopoverLimit]
    let emptyDetail: String
    let extraUsage: ExtraUsageStatus?
    let resetCreditsAvailable: Int?

    init(
        title: String,
        logoKind: ProviderLogoKind,
        accentColor: Color,
        metrics: UsageMetrics?,
        emptyDetail: String,
        accountID: UUID? = nil
    ) {
        // Disambiguate by account id so two accounts that share a display name
        // (e.g. both "Work") don't collide on a single Identifiable id, which
        // would corrupt the ForEach that renders the provider cards.
        self.id = "\(title)-\(logoKind)-\(accountID?.uuidString ?? "default")"
        self.title = title
        self.logoKind = logoKind
        self.accentColor = accentColor
        self.updatedAt = metrics?.lastUpdated
        self.emptyDetail = emptyDetail
        self.extraUsage = metrics?.extraUsage
        self.resetCreditsAvailable = metrics?.resetCreditsAvailable
        self.limits = [
            PopoverLimit(title: "Session", limit: metrics?.sessionLimit),
            PopoverLimit(title: "Weekly", limit: metrics?.weeklyLimit),
            PopoverLimit(title: logoKind == .claude ? "Sonnet" : "Code Review", limit: metrics?.codeReviewLimit)
        ].compactMap { $0 }
    }

    var primaryLimit: PopoverLimit? {
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
}

struct PopoverLimit: Identifiable {
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

extension View {
    /// Popover content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the popover and dashboard cards stay visually identical.
    func cardSurface() -> some View {
        meterBarCardSurface()
    }
}
