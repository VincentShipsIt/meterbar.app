import SwiftUI

/// A refresh glyph that spins while work is in flight, and respects Reduce Motion.
/// Bound to real loading/scanning state so it reflects refreshes triggered from
/// anywhere, not just a local button tap.
struct RefreshingIcon: View {
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(rotationDegrees))
            .onAppear(perform: updateRotation)
            .onChange(of: isRefreshing) { _, _ in
                updateRotation()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateRotation()
            }
    }

    private func updateRotation() {
        if isRefreshing, !reduceMotion {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotationDegrees = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                rotationDegrees = 0
            }
        }
    }
}
