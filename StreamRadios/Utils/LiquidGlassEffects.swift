//
//  LiquidGlassEffects.swift
//  StreamRadios
//
//  Created by Assistant on 9/16/25.
//

import SwiftUI

/// Liquid glass visual effects for iOS 26+
@available(iOS 26.0, *)
struct LiquidGlassEffects {
    
    /// Primary liquid glass background with transparency and blur
    static func liquidGlassBackground() -> some View {
        ZStack {
            // Base transparent layer
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.6)
            
            // Liquid glass gradient overlay
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // Subtle shimmer effect
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .animation(
                    Animation.easeInOut(duration: 3.0)
                        .repeatForever(autoreverses: true),
                    value: UUID()
                )
        }
    }
    
    /// Liquid glass border with subtle glow
    static func liquidGlassBorder() -> some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.3),
                        Color.white.opacity(0.1),
                        Color.white.opacity(0.2)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .shadow(color: Color.white.opacity(0.1), radius: 8, x: 0, y: 0)
    }
    
    /// Liquid glass button with interactive effects
    static func liquidGlassButton(isPressed: Bool = false) -> some View {
        ZStack {
            // Base glass layer
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.8)
            
            // Interactive gradient
            Circle()
                .fill(
                    LinearGradient(
                        colors: isPressed ? [
                            Color.white.opacity(0.3),
                            Color.white.opacity(0.1)
                        ] : [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // Subtle border
            Circle()
                .stroke(
                    Color.white.opacity(0.25),
                    lineWidth: 1
                )
        }
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .shadow(color: Color.black.opacity(0.1), radius: isPressed ? 2 : 4, x: 0, y: isPressed ? 1 : 2)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
    
    /// Liquid glass artwork frame
    static func liquidGlassArtworkFrame() -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial)
            .opacity(0.7)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
    
    /// Liquid glass text background
    static func liquidGlassTextBackground() -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.ultraThinMaterial)
            .opacity(0.4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

/// View modifier for applying liquid glass effects
@available(iOS 26.0, *)
struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double
    
    init(cornerRadius: CGFloat = 16, opacity: Double = 0.6) {
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                        .opacity(opacity)
                    
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.15),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

/// Extension to easily apply liquid glass effects
extension View {
    @available(iOS 26.0, *)
    func liquidGlass(cornerRadius: CGFloat = 16, opacity: Double = 0.6) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}
