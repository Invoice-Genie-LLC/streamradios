import SwiftUI
import UIKit

/// Colour tokens.
///
/// Deliberately small. Liquid Glass derives its appearance from the content *behind* it,
/// so the redesign leans on system semantic colours and lets glass do the work. Only the
/// brand accent and a few state colours are defined explicitly.
public enum SRColor {
    public static let accent = Color(
        light: UIColor(red: 0.13, green: 0.42, blue: 0.94, alpha: 1),
        dark: UIColor(red: 0.35, green: 0.61, blue: 1.00, alpha: 1)
    )

    /// Used for the "live" indicator on streaming radio.
    public static let live = Color(
        light: UIColor(red: 0.85, green: 0.16, blue: 0.20, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.36, blue: 0.38, alpha: 1)
    )

    public static let success = Color(
        light: UIColor(red: 0.11, green: 0.58, blue: 0.31, alpha: 1),
        dark: UIColor(red: 0.29, green: 0.80, blue: 0.47, alpha: 1)
    )

    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary
    public static let tertiaryText = Color(uiColor: .tertiaryLabel)

    /// Neutral fill for artwork placeholders and skeleton rows.
    public static let placeholder = Color(uiColor: .secondarySystemFill)
    public static let separator = Color(uiColor: .separator)
}

private extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
