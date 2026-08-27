import SwiftUI

/// The five-bar level meter shown on the currently playing station.
///
/// Animation is driven by SwiftUI's repeating animations rather than a `Timer` firing state
/// updates, so it runs on the render server and doesn't invalidate the row body 20×/second.
public struct SREqualizerBars: View {
    private static let restingHeights: [CGFloat] = [6, 10, 14, 8, 12]
    private static let troughs: [CGFloat] = [0.30, 0.55, 0.25, 0.65, 0.40]

    private let isAnimating: Bool
    private let maxHeight: CGFloat
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isAnimating: Bool, maxHeight: CGFloat = 20, tint: Color = SRColor.accent) {
        self.isAnimating = isAnimating
        self.maxHeight = maxHeight
        self.tint = tint
    }

    private var shouldAnimate: Bool { isAnimating && !reduceMotion }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(Self.restingHeights.enumerated()), id: \.offset) { index, resting in
                SREqualizerBar(
                    resting: resting,
                    maxHeight: maxHeight,
                    trough: Self.troughs[index],
                    // Staggered periods keep the bars from moving in lockstep.
                    duration: 0.36 + Double(index) * 0.07,
                    isAnimating: shouldAnimate,
                    style: shouldAnimate ? AnyShapeStyle(barGradient) : AnyShapeStyle(SRColor.tertiaryText)
                )
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
        // Rebuilding the bars on every start guarantees each run begins at the trough and rises;
        // reusing the state let a restart pick up mid-cycle and fall first.
        .id(shouldAnimate)
        .accessibilityHidden(true)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [tint, tint.opacity(0.55)],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

private struct SREqualizerBar: View {
    let resting: CGFloat
    let maxHeight: CGFloat
    let trough: CGFloat
    let duration: Double
    let isAnimating: Bool
    let style: AnyShapeStyle

    @State private var isRaised = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(style)
            .frame(width: 3, height: isAnimating ? maxHeight : resting)
            .scaleEffect(y: isAnimating && !isRaised ? trough : 1, anchor: .bottom)
            .onAppear {
                guard isAnimating else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    isRaised = true
                }
            }
    }
}
