//
//  GlobalPlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/28/24.
//

import SwiftUI
import AVFoundation

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
                    
                    // Podcast player
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
                    .onTapGesture {
                        if let currentFeed = podcastPlayer.currentFeed {
                            // Switch to podcast tab and set the current feed
                            selectedPodcast = currentFeed
                            podcastViewModel.requestFeedRefresh(currentFeed.id)
                            selectedTab = .podcast
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else if shouldShowRadioPlayerFirst {
                // STABILITY FIX: Show radio player with stable station display and home button
                if let currentStation = radioPlayer.currentlyPlayingStation {
                    // CRITICAL: Use radioPlayer.currentlyPlayingStation as the source of truth for display
                    // This ensures station info remains consistent regardless of country switching or auto-play
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                        
                        // Radio player
                        CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
                } else if !viewModel.stations.isEmpty && shouldShowRadioPlayerFirst {
                    // Show first available station as default when no station is set and radio should be prioritized
                    let defaultStation = viewModel.stations.first!
                    HStack(spacing: 8) {
                        // Home button on the left (only shows when scrolling)
                        HomeButton(isFooterMenuHidden: $isFooterMenuHidden, isScrolling: $isScrolling)
                        
                        // Radio player
                        CompactPlayerView(currentStation: defaultStation, metadata: nil, isPlayerSheetPresented: $isPlayerSheetPresented)
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
                }
            }
        }
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
    @State private var shouldShow = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Group {
            // Show button directly based on isScrolling OR shouldShow state
            if isScrolling || shouldShow {
                Button(action: {
                    // Use transaction to disable all animations and prevent refreshes
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isFooterMenuHidden = false // Show TabView when tapped
                        isScrolling = false // Stop scrolling state immediately
                        shouldShow = false // Hide Home button only when tapped
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(colorScheme == .dark ? Color.black.opacity(0.6) : Color.primary.opacity(0.8))
                            .frame(width: 55, height: 55)
                        
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .modifier(GlassEffectModifier(shape: Circle()))
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Monitor isScrolling changes and update shouldShow immediately
        .onChange(of: isScrolling) { oldValue, newValue in
            print("🏠 DEBUG: HomeButton onChange - oldValue: \(oldValue), newValue: \(newValue), shouldShow: \(shouldShow)")
            if newValue {
                // Show immediately when scrolling starts
                shouldShow = true
                print("🏠 DEBUG: HomeButton shouldShow set to true")
            }
            // Don't hide when scrolling stops - only when button is tapped
        }
        // Check current state on appear
        .onAppear {
            if isScrolling {
                shouldShow = true
            }
        }
    }
}

 
