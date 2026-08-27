import SwiftUI

/// Type ramp for the redesign. Everything is built on Dynamic Type text styles so the app
/// scales correctly for accessibility; only weight and design are customised.
public enum SRFont {
    public static let screenTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let sectionTitle = Font.system(.title3, design: .rounded, weight: .semibold)

    public static let rowTitle = Font.system(.body, design: .rounded, weight: .semibold)
    public static let rowSubtitle = Font.system(.subheadline, design: .rounded, weight: .regular)
    public static let rowDetail = Font.system(.caption, design: .rounded, weight: .regular)

    public static let badge = Font.system(.caption2, design: .rounded, weight: .semibold)
    public static let control = Font.system(.subheadline, design: .rounded, weight: .semibold)

    public static let playerTitle = Font.system(.title2, design: .rounded, weight: .bold)
    public static let playerSubtitle = Font.system(.subheadline, design: .rounded, weight: .medium)
    /// Tabular figures so elapsed/remaining time doesn't jitter as digits change.
    public static let playerTimecode = Font.system(.caption, design: .rounded, weight: .medium)
        .monospacedDigit()
}

public extension Text {
    func srStyle(_ font: Font, color: Color = .primary) -> Text {
        self.font(font).foregroundColor(color)
    }
}
