import SwiftUI

/// 4pt-based spacing scale. Every gap, padding and inset in the redesign comes from here
/// so rhythm stays consistent across screens.
public enum SRSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

/// Corner radii tuned to iOS 26 concentric-corner behaviour: containers use `.card`,
/// content nested inside a container steps down one level so the curves stay concentric.
public enum SRRadius {
    public static let control: CGFloat = 10
    public static let thumbnail: CGFloat = 12
    public static let card: CGFloat = 18
    public static let sheet: CGFloat = 28
}

/// Standard sizes for artwork so the image pipeline can cache a small, fixed set of
/// downsampled variants instead of one bitmap per unique frame.
public enum SRArtworkSize {
    /// Inline list row thumbnail.
    public static let row: CGFloat = 56
    /// Grid / carousel tile.
    public static let tile: CGFloat = 132
    /// Now-playing bottom accessory.
    public static let accessory: CGFloat = 40
    /// Full-screen player hero.
    public static let hero: CGFloat = 320
}
