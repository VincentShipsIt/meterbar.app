import SwiftUI

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
