//
//  NeumorphicShadow.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/26/24.
//

import SwiftUI

struct NeumorphicShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 2, y: 2)
            .shadow(color: Color.white.opacity(0.3), radius: 2, x: -2, y: -2)
    }
}

// MARK: - iPad-Aware Font Scaling System

extension Font {
    /// Device-aware font scaling for iPad
    private static var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    /// iPad font scale factor - 1.3x larger fonts on iPad for better readability
    private static let iPadScaleFactor: CGFloat = 1.3
    
    /// Creates a system font with automatic iPad scaling
    static func adaptiveSystem(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        let scaledSize = isIPad ? size * iPadScaleFactor : size
        return .system(size: scaledSize, weight: weight, design: design)
    }
    
    /// Adaptive title fonts
    static var adaptiveTitle: Font {
        isIPad ? .title.weight(.semibold) : .title2.weight(.semibold)
    }
    
    static var adaptiveTitle2: Font {
        isIPad ? .title2 : .title3
    }
    
    static var adaptiveTitle3: Font {
        isIPad ? .title3 : .headline
    }
    
    /// Adaptive headline fonts
    static var adaptiveHeadline: Font {
        adaptiveSystem(size: 17, weight: .semibold)
    }
    
    /// Adaptive body fonts
    static var adaptiveBody: Font {
        adaptiveSystem(size: 17, weight: .regular)
    }
    
    static var adaptiveCallout: Font {
        adaptiveSystem(size: 16, weight: .regular)
    }
    
    static var adaptiveSubheadline: Font {
        adaptiveSystem(size: 15, weight: .regular)
    }
    
    static var adaptiveFootnote: Font {
        adaptiveSystem(size: 13, weight: .regular)
    }
    
    static var adaptiveCaption: Font {
        adaptiveSystem(size: 12, weight: .regular)
    }
    
    static var adaptiveCaption2: Font {
        adaptiveSystem(size: 11, weight: .regular)
    }
    
    /// Custom sized adaptive fonts for specific UI elements
    static func adaptiveCustom(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        adaptiveSystem(size: size, weight: weight, design: design)
    }
    
    /// Specific sizes for common UI patterns
    static var adaptiveTabBarTitle: Font {
        adaptiveSystem(size: 10, weight: .medium)
    }
    
    static var adaptiveTabBarTitleSelected: Font {
        adaptiveSystem(size: 10, weight: .semibold)
    }
    
    static var adaptiveButtonTitle: Font {
        adaptiveSystem(size: 16, weight: .semibold)
    }
    
    static var adaptiveButtonSubtitle: Font {
        adaptiveSystem(size: 13, weight: .regular)
    }
    
    static var adaptiveSettingsTitle: Font {
        adaptiveSystem(size: 18, weight: .semibold)
    }
    
    static var adaptiveSettingsSubtitle: Font {
        adaptiveSystem(size: 13, weight: .regular)
    }
    
    static var adaptivePlayerTitle: Font {
        adaptiveSystem(size: 20, weight: .semibold)
    }
    
    static var adaptivePlayerMetadata: Font {
        adaptiveSystem(size: 16, weight: .medium)
    }
    
    static var adaptiveStationName: Font {
        adaptiveSystem(size: 18, weight: .semibold)
    }
    
    static var adaptiveWarningText: Font {
        adaptiveSystem(size: 14, weight: .semibold)
    }
    
    static var adaptiveAlertTitle: Font {
        adaptiveSystem(size: 18, weight: .bold)
    }
    
    static var adaptiveAlertMessage: Font {
        adaptiveSystem(size: 16, weight: .regular)
    }
}

// MARK: - Adaptive Colors for Light/Dark Theme Support

extension Color {
    // Primary background colors
    static let adaptiveBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.black : UIColor.systemBackground
    })
    
    static let adaptiveSecondaryBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0) : UIColor.secondarySystemBackground
    })
    
    // Text colors
    static let adaptivePrimaryText = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.label
    })
    
    static let adaptiveSecondaryText = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.gray : UIColor.secondaryLabel
    })
    
    // Border and separator colors
    static let adaptiveBorder = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.gray.withAlphaComponent(0.2) : UIColor.separator
    })
    
    static let adaptiveSeparator = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.gray.withAlphaComponent(0.2) : UIColor.separator.withAlphaComponent(0.3)
    })
    
    // Card background colors
    static let adaptiveCardBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.gray.withAlphaComponent(0.15) : UIColor.white
    })
    
    // Overlay background for sections
    static let adaptiveSectionBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.gray.withAlphaComponent(0.1) : UIColor.quaternarySystemFill
    })
    
    // Tab bar background
    static let adaptiveTabBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.95) : UIColor.systemBackground.withAlphaComponent(0.95)
    })
    
    // Input field background
    static let adaptiveFieldBackground = Color(UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? UIColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0) : UIColor.systemGray6
    })
}

