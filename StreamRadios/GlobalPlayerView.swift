//
//  GlobalPlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/28/24.
//

import SwiftUI
import AVFoundation

/// Publishes how tall the tab bar actually is, above the home indicator.
///
/// SwiftUI doesn't expose this, and it differs by idiom, OS version and whether the device has a
/// home indicator at all — a constant that clears the bar on iPhone overlaps it on iPad.
final class TabBarClearance: ObservableObject {
    static let shared = TabBarClearance()

    @Published private(set) var height: CGFloat = 49

    /// The window's bottom safe-area inset, so callers can cancel it out with negative padding.
    @Published private(set) var bottomInset: CGFloat = 0

    private var measuredForWindowSize: CGSize?

    func measure(from view: UIView?, includeTabBar: Bool = true) {
        guard let window = view?.window else { return }

        let inset = window.safeAreaInsets.bottom
        if abs(inset - bottomInset) > 0.5 { bottomInset = inset }

        guard includeTabBar else { return }
        if measuredForWindowSize == window.bounds.size { return }
        guard let bar = Self.tabBar(in: window) else { return }

        let barFrame = bar.convert(bar.bounds, to: window)
        // The bar can be mid-transition or parked offscreen while it's hidden; ignore those frames.
        guard barFrame.maxY <= window.bounds.maxY + 1 else { return }
        let measured = window.bounds.maxY - barFrame.minY - inset
        guard measured > 0 else { return }

        measuredForWindowSize = window.bounds.size
        if abs(measured - height) > 0.5 { height = measured }
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let found = tabBar(in: subview) { return found }
        }
        return nil
    }
}

/// Invisible hook that lets `TabBarClearance` reach the UIKit window behind the SwiftUI hierarchy.
struct TabBarClearanceProbe: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            TabBarClearance.shared.measure(from: uiView, includeTabBar: isActive)
        }
    }
}

/// Global player that displays across all main views (except sheet views)
/// Shows either podcast or radio player depending on what's currently playing
/// Uses the same positioning and logic as ContentView
struct GlobalPlayerView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var podcastPlayer: PodcastPlayer
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    
    @Binding var selectedPodcast: PodcastFeed?
    @Binding var isPlayerSheetPresented: Bool
    @Binding var selectedTab: Tab
    @Binding var isFooterMenuHidden: Bool
    @Binding var isScrolling: Bool
    
    @State private var scrollToEpisodeID: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Player area with home button - prioritize based on last active player
            if shouldShowPodcastPlayerFirst,
               let currentEpisode = podcastPlayer.currentEpisode,
               let currentFeed = podcastPlayer.currentFeed {
                // Show podcast player only when we have both episode and feed loaded
                HStack(spacing: 8) {
                    // Home button on the left (only shows when scrolling)
                    HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                        .zIndex(1) // Ensure home button is above player to prevent tap-through
                    
                    // Podcast player with smooth animation
                    CompactPodcastPlayerView(
                        currentEpisode: currentEpisode,
                        currentFeed: currentFeed,
                        podcastPlayer: podcastPlayer,
                        viewModel: podcastViewModel,
                        selectedPodcast: $selectedPodcast,
                        onListButtonTap: {
                            // Switch to podcast tab and set the current feed
                            selectedPodcast = currentFeed
                            podcastViewModel.requestFeedRefresh(currentFeed.id)
                            selectedTab = .podcast
                        },
                        onCloseButtonTap: {
                            // Do not dismiss the player when closing; just pause and keep it visible
                            podcastPlayer.pause()
                        }
                    )
                    .zIndex(0) // Player is below home button
                }
                .padding(.horizontal, playerHorizontalPadding)
            } else if shouldShowRadioPlayerFirst {
                // STABILITY FIX: Show radio player with stable station display and home button
                if let currentStation = radioPlayer.currentlyPlayingStation {
                    // CRITICAL: Use radioPlayer.currentlyPlayingStation as the source of truth for display
                    // This ensures station info remains consistent regardless of country switching or auto-play
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                            .zIndex(1) // Ensure home button is above player to prevent tap-through
                        
                        // Radio player with smooth animation
                        CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .zIndex(0) // Player is below home button
                    }
                    .padding(.horizontal, playerHorizontalPadding)
                    .padding(.bottom, 0)
                } else if !viewModel.stations.isEmpty && shouldShowRadioPlayerFirst {
                    // Show first available station as default when no station is set and radio should be prioritized
                    let defaultStation = viewModel.stations.first!
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                            .zIndex(1) // Ensure home button is above player to prevent tap-through
                        
                        // Radio player with smooth animation
                        CompactPlayerView(currentStation: defaultStation, metadata: nil, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .zIndex(0) // Player is below home button
                    }
                    .padding(.horizontal, playerHorizontalPadding)
                    .padding(.bottom, 0)
                }
            }
        }
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 600 : .infinity)
        .background(
            // Invisible background to block tap-through while allowing button interactions
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
        )
    }
    
    /// Determines if podcast player should be shown
    /// Shows podcast player when there's a current episode and feed loaded
    /// Player stays visible whether playing, paused, or stopped
    private var shouldShowPodcastPlayer: Bool {
        // Show player whenever there's a current episode and feed
        // This keeps the player visible even when paused
        return podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil
    }
    
    /// Determines if radio player should be shown
    /// Shows radio player when there's a current station set
    /// Player stays visible whether playing, paused, or stopped
    private var shouldShowRadioPlayer: Bool {
        // Show player whenever there's a current station
        // This keeps the player visible even when paused
        return radioPlayer.currentlyPlayingStation != nil
    }
    
    /// Determines if podcast player should be prioritized based on last active player
    private var shouldShowPodcastPlayerFirst: Bool {
        let lastActivePlayer = PlaybackManager.shared.getLastActivePlayer()
        
        // If podcast was the last active player, prioritize it (even without content loaded yet)
        if lastActivePlayer == .podcast {
            return true
        }
        
        // If only podcast has content, show it
        if shouldShowPodcastPlayer && !shouldShowRadioPlayer {
            return true
        }
        
        // If both have content, check last active player
        if shouldShowPodcastPlayer && shouldShowRadioPlayer {
            return lastActivePlayer == .podcast
        }
        
        // Default: don't show podcast first
        return false
    }
    
    /// Consistent horizontal padding for the player
    /// Player maintains the same size regardless of scrolling state and TabView visibility
    /// Same padding whether TabView is visible or hidden for consistent appearance
    private var playerHorizontalPadding: CGFloat {
        // Consistent padding in all states to match screenshot spacing
        return 24
    }
    
    /// Determines if radio player should be prioritized based on last active player
    private var shouldShowRadioPlayerFirst: Bool {
        let lastActivePlayer = PlaybackManager.shared.getLastActivePlayer()
        
        // If radio was the last active player, prioritize it
        if lastActivePlayer == .radio {
            return true
        }
        
        // If podcast was the last active player, don't show radio first
        if lastActivePlayer == .podcast {
            return false
        }
        
        // If only radio has content, show it
        if shouldShowRadioPlayer && !shouldShowPodcastPlayer {
            return true
        }
        
        // If both have content, check last active player
        if shouldShowPodcastPlayer && shouldShowRadioPlayer {
            return lastActivePlayer == .radio
        }
        
        // Default: show radio if it has content and no last active player preference
        return shouldShowRadioPlayer
    }
    
}

// MARK: - Home Button Component

struct HomeButton: View {
    @Binding var isFooterMenuHidden: Bool
    @Binding var isScrolling: Bool
    @Environment(\.colorScheme) var colorScheme
    
    // The button is the only way back to the tab bar, so its visibility has to be derived from
    // the menu state. A latched @State flag resets whenever the player is rebuilt, which stranded
    // the user with no tab bar and no way to restore it.
    private var shouldShow: Bool { isFooterMenuHidden || isScrolling }
    
    // Computed properties for adaptive colors
    private var iconColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var buttonGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05),
                Color.white.opacity(0.15)
            ]
        } else {
            return [
                Color.black.opacity(0.15),
                Color.black.opacity(0.05),
                Color.black.opacity(0.10)
            ]
        }
    }
    
    private var buttonBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1),
                Color.white.opacity(0.3)
            ]
        } else {
            return [
                Color.black.opacity(0.3),
                Color.black.opacity(0.15),
                Color.black.opacity(0.25)
            ]
        }
    }
    
    var body: some View {
        Group {
            if shouldShow {
                Button(action: {
                    print("🏠 HOME BUTTON: Tapped - forcing TabView to show")
                    // Use smooth animation for TabView restoration
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        // CRITICAL: Always force TabView to show regardless of current state
                        isFooterMenuHidden = false // Show TabView when tapped
                        isScrolling = false // Stop scrolling state immediately
                    }
                    
                    // SAFETY: Post notification to ensure all views reset their scrolling state
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ForceTabViewVisible"),
                        object: nil,
                        userInfo: ["source": "HomeButton"]
                    )
                    
                    print("🏠 HOME BUTTON: TabView restoration complete - isFooterMenuHidden: \(isFooterMenuHidden), isScrolling: \(isScrolling)")
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 55, height: 55)
                        
                        // Glass gradient overlay for more depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 55, height: 55)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .frame(width: 55, height: 55)
                        
                        Image(systemName: "house.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(iconColor)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.3).combined(with: .opacity).combined(with: .move(edge: .leading)),
                    removal: .scale(scale: 0.8).combined(with: .opacity).combined(with: .move(edge: .leading))
                ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: shouldShow)
    }
}

 
