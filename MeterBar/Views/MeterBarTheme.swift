import SwiftUI

enum MeterBarTheme {
    static let anthropicDark = Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255)
    static let anthropicLight = Color(red: 250 / 255, green: 249 / 255, blue: 245 / 255)
    static let claudeAccent = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let warning = Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
    static let toolbarIconForeground = Color.white.opacity(0.92)
    static let toolbarIconBackground = Color(red: 32 / 255, green: 35 / 255, blue: 42 / 255)
    static let toolbarIconBorder = Color.white.opacity(0.14)
}

struct RefreshIconButton: View {
    let title: String?
    let help: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var rotation: Double = 0

    init(
        title: String? = nil,
        help: String = "Refresh",
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.help = help
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            withAnimation(.easeInOut(duration: 0.55)) {
                rotation += 360
            }
            action()
        } label: {
            HStack(spacing: title == nil ? 0 : 7) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 18, height: 18)

                if let title {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .foregroundColor(MeterBarTheme.toolbarIconForeground)
            .frame(width: title == nil ? 32 : nil, height: 32)
            .padding(.horizontal, title == nil ? 0 : 10)
            .background(MeterBarTheme.toolbarIconBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MeterBarTheme.toolbarIconBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}
