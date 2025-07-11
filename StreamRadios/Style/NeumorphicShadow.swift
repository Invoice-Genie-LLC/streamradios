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

