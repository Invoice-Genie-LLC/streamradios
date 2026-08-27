import SwiftUI

/// Thin, opinionated wrappers over the real iOS 26 Liquid Glass APIs.
///
/// Important: this file intentionally contains **no** simulated glass — no `.ultraThinMaterial`
/// stacks, no gradient strokes. Those are more expensive to composite than the real effect and
/// they don't refract, morph or respond to motion. Everything here delegates to `glassEffect`.
public extension View {
    /// Standard container surface: a card floating over scrolling content.
    func srGlassCard(radius: CGFloat = SRRadius.card) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A glass surface that reacts to touch. Use for anything tappable that isn't a `Button`.
    func srGlassInteractive(radius: CGFloat = SRRadius.control) -> some View {
        glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Tinted glass, for accent surfaces such as the active filter chip.
    func srGlassTinted(_ tint: Color, radius: CGFloat = SRRadius.control) -> some View {
        glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Groups sibling glass elements so they blend and morph into one another instead of
/// rendering as separate, isolated blobs.
///
/// This is the piece the previous implementation was missing: `glassEffect` on its own does
/// not coordinate between views. Any row of glass controls (toolbars, transport buttons,
/// filter chips) should be wrapped in one of these.
public struct SRGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = SRSpacing.md, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

/// Circular glass icon button — the transport/utility control used throughout the redesign.
public struct SRGlassIconButton: View {
    private let systemName: String
    private let diameter: CGFloat
    private let tint: Color?
    private let action: () -> Void

    public init(
        _ systemName: String,
        diameter: CGFloat = 44,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.diameter = diameter
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .tint(tint)
        .accessibilityLabel(Text(systemName.replacingOccurrences(of: ".", with: " ")))
    }
}
