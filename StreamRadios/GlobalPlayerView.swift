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
                // Show radio player when appropriate
                if let currentStation = viewModel.currentlyPlayingStation {
                    // Show current station (playing or paused)
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
        .background(
            Color.adaptiveSecondaryBackground
                .edgesIgnoringSafeArea(.all)
        )
    }
    
    /// Determines if podcast player should be shown
    /// Shows podcast player when:
    /// - User wants to play podcast (persistent intent), OR
    /// - Podcast is actively playing (current state)
    /// This mirrors the RadioPlayer logic exactly for consistent CarPlay behavior
    private var shouldShowPodcastPlayer: Bool {
        // CRITICAL: Mirror RadioPlayer logic exactly - check user intent first
        // This is the key to surviving CarPlay connections/disconnections
        if podcastPlayer.userWantsToPlay && podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil {
            return true
        }
        
        // Fallback: Show if actively playing (secondary check)
        if podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil {
            return true
        }
        
        return false
    }
    
    /// Determines if radio player should be shown
    /// Show only when:
    /// - User wants to play radio, OR
    /// - Radio is actively playing or paused and a station is set
    private var shouldShowRadioPlayer: Bool {
        if radioPlayer.userWantsToPlay { return true }
        if (radioPlayer.isPlaying || radioPlayer.connectionState == .paused) && radioPlayer.currentlyPlayingStation != nil {
            return true
        }
        return false
    }
}

 