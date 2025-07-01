//
//  GlobalPlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/28/24.
//

import SwiftUI

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
            // Player area - show podcast players when podcast is playing, radio players when radio is playing
            if podcastPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
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
                        podcastViewModel.fetchAllEpisodes(for: currentFeed)
                        selectedTab = .podcast
                    },
                    onCloseButtonTap: {
                        podcastPlayer.pause()
                        podcastPlayer.currentEpisode = nil
                        podcastPlayer.currentFeed = nil
                    }
                )
                .onTapGesture {
                    if let currentFeed = podcastPlayer.currentFeed {
                        // Switch to podcast tab and set the current feed
                        selectedPodcast = currentFeed
                        podcastViewModel.fetchAllEpisodes(for: currentFeed)
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
    
    /// Determines if radio player should be shown
    /// Shows radio player when:
    /// - On radio tab, OR
    /// - User wants to play radio (regardless of current network status or tab)
    private var shouldShowRadioPlayer: Bool {
        return selectedTab == .radio || radioPlayer.userWantsToPlay
    }
}

 