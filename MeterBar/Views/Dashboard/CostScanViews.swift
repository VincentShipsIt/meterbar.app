import AppKit
import SwiftUI

struct CostScanLoadingChart: View {
    let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let spacing: CGFloat = compact ? 4 : 5
                let labelHeight: CGFloat = compact ? 34 : 44
                let chartHeight = max(42, proxy.size.height - labelHeight)
                let barWidth = max(4, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
                let time = timeline.date.timeIntervalSinceReferenceDate
                let sweepWidth = max(42, proxy.size.width * 0.18)
                let sweepX = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8) * (proxy.size.width + sweepWidth) - sweepWidth

                VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning local logs")
                            .font(compact ? .caption : .subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("30 days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ZStack(alignment: .leading) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(0..<barCount, id: \.self) { index in
                                let seed = Double(((index * 17) % 11) + 2) / 13
                                let wave = reduceMotion ? 0.5 : (sin((time * 3.2) + Double(index) * 0.55) + 1) / 2
                                let height = chartHeight * CGFloat(0.14 + (seed * 0.44) + (wave * 0.28))

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                MeterBarTheme.codexAccent.opacity(0.18 + wave * 0.16),
                                                MeterBarTheme.cursorAccent.opacity(0.16 + seed * 0.20)
                                            ],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: barWidth, height: max(4, height))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        if !reduceMotion {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Color.primary.opacity(0.22), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: sweepWidth, height: chartHeight)
                                .offset(x: sweepX)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    if !compact {
                        Text("Parsing Claude and Codex sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

struct CostScanProgressBadge: View {
    let compact: Bool

    var body: some View {
        VStack {
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(compact ? "Scanning..." : "Updating local scan")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, compact ? 9 : 11)
                .padding(.vertical, compact ? 6 : 8)
                .glassEffect(.regular, in: .capsule)

                Spacer()
            }

            Spacer()
        }
        .padding(compact ? 8 : 10)
    }
}

struct CostRefreshLockOverlay: View {
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .opacity(0.62)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0), including: .all)

            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing costs")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Text("Scanning local token logs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing costs")
        .accessibilityHint("Cost results are locked until the local scan finishes.")
    }
}
