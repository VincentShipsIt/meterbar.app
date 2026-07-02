import AppKit
import SwiftUI

/// Colored On/Off chip showing whether paid "extra usage" / overage is enabled for a service.
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
            let base = "Extra usage is ON — overage can be billed beyond your plan."
            return status.detail.map { "\(base)\n\($0)" } ?? base
        case .off:
            return "Extra usage is OFF — usage is capped at your subscription quota."
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
