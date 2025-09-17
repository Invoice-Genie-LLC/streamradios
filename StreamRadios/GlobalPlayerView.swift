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
    
    @State private var scrollToEpisodeID: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Player area - show podcast players when user wants podcast or playing, radio players when user wants radio or playing
            if shouldShowPodcastPlayer, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                // Podcast is playing - show podcast compact player
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
            } else if shouldShowRadioPlayer {
                // STABILITY FIX: Show radio player with stable station display
                if let currentStation = radioPlayer.currentlyPlayingStation {
                    // CRITICAL: Use radioPlayer.currentlyPlayingStation as the source of truth for display
                    // This ensures station info remains consistent regardless of country switching or auto-play
                    CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata, isPlayerSheetPresented: $isPlayerSheetPresented)
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
                        .padding(.bottom, 0)
                } else if !viewModel.stations.isEmpty && selectedTab == .radio {
                    // Show first available station as default when no station is set (only on radio tab)
                    let defaultStation = viewModel.stations.first!
                    CompactPlayerView(currentStation: defaultStation, metadata: nil, isPlayerSheetPresented: $isPlayerSheetPresented)
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
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
}

 