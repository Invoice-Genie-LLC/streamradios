//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI
import Combine
import os
import AVKit

import SwiftUI
import os

struct PodcastListView: View {
    @StateObject private var viewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var selectedPodcast: PodcastFeed?
    @State private var searchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var expandedFeedId: String?
    @State private var isEditing = false
    @StateObject private var radioPlayer = RadioPlayer.shared
    @State private var scrollToEpisodeID: String?
    @State private var refreshID = UUID()
    
    // Edit functionality
    @State private var showingEditPodcast = false
    @State private var podcastToEdit: PodcastFeed?
    @State private var editPodcastTitle = ""
    @State private var editPodcastURL = ""
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    private let miniPlayerHeight: CGFloat = 60 // Adjust this value based on your MiniPlayerView height
    
    var body: some View {
           NavigationView {
               ZStack(alignment: .bottom) {
                   VStack(spacing: 0) {
                       instructionText
                       searchBar
                       podcastList
                           .padding(.bottom, podcastPlayer.currentEpisode != nil ? miniPlayerHeight : 0)
                   }
                   .navigationTitle("Podcasts")
                   .toolbar {
                                       ToolbarItem(placement: .navigationBarLeading) {
                                           Button(action: {
                                               isEditing.toggle()
                                               if !isEditing {
                                                   viewModel.saveFeedOrder()
                                                   refreshID = UUID() // Force view refresh
                                               }
                                           }) {
                                               Text(isEditing ? "Done" : "Edit")
                                           }
                                       
                       }
                       ToolbarItemGroup(placement: .navigationBarTrailing) {
                           if !isEditing {
                               Button(action: viewModel.sortFeedsAlphabetically) {
                                   Image(systemName: viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                               }
                               Button(action: { showingAddPodcast = true }) {
                                   Image(systemName: "plus")
                               }
                           }
                       }
                   }
                   .onAppear(perform: onAppear)
                   .id(refreshID)
                   .sheet(isPresented: $showingAddPodcast) {
                       AddPodcastView(
                           isPresented: $showingAddPodcast, 
                           title: $newPodcastTitle, 
                           url: $newPodcastURL, 
                           podcastToEdit: nil,
                           onAdd: addPodcast,
                           onUpdate: nil
                       )
                   }
                   .sheet(isPresented: $showingEditPodcast) {
                       AddPodcastView(
                           isPresented: $showingEditPodcast,
                           title: $editPodcastTitle,
                           url: $editPodcastURL,
                           podcastToEdit: podcastToEdit,
                           onAdd: { },
                           onUpdate: { updatedPodcast in
                               updatePodcast(updatedPodcast)
                           }
                       )
                   }
                   .sheet(item: $selectedPodcast) { podcast in
                       PodcastPlayerView(
                           viewModel: viewModel,
                           feed: podcast,
                           initialScrollToEpisodeID: podcastPlayer.currentEpisode?.id,
                           podcastPlayer: podcastPlayer,
                           selectedPodcast: $selectedPodcast,
                           episodeToScrollTo: Binding(
                               get: { podcastPlayer.currentEpisode },
                               set: { _ in }
                           )
                       )
                   }
                   .padding(.bottom, podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 40 : 0)
                   
                   // Fixed Mini Player
                   if podcastPlayer.isPlaying && !radioPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                       MiniPlayerView(
                           podcastPlayer: podcastPlayer,
                           viewModel: viewModel,
                           selectedPodcast: $selectedPodcast,
                           onListButtonTap: {
                               if let currentFeed = podcastPlayer.currentFeed {
                                   selectedPodcast = currentFeed
                                   scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                               }
                           },
                           onCloseButtonTap: {
                               podcastPlayer.pause()
                               podcastPlayer.currentEpisode = nil
                               podcastPlayer.currentFeed = nil
                           },
                           isPlaylistButtonDisabled: false
                       )
                       .transition(.move(edge: .bottom))
                   }
               }
               
           }
           .alert(isPresented: $viewModel.showNoEpisodesAlert) {
               Alert(
                   title: Text("No Episodes in Progress"),
                   message: Text(viewModel.noEpisodesAlertMessage),
                   dismissButton: .default(Text("OK"))
               )
           }
       }
    
    private var instructionText: some View {
        Text("Tap on a podcast image to explore its episodes and discover more content.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
                .padding(.leading, 8)
            
            ZStack(alignment: .trailing) {
                TextField("Search podcasts", text: $searchText)
                    .padding(.vertical, 8)
                    .padding(.trailing, 30)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: searchText) { newValue in
                        searchText = String(newValue.prefix(100))  // Limit to 100 characters
                    }
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .padding(.trailing, 8)
                    }
                    .transition(.opacity)
                    .animation(.default, value: searchText)
                }
            }
        }
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var podcastList: some View {
            List {
                ForEach(viewModel.podcastFeedOrder, id: \.self) { feedId in
                    if let feed = viewModel.podcastFeeds.first(where: { $0.id == feedId }),
                       filteredPodcasts.contains(where: { $0.id == feedId }) {
                        PodcastRowView(
                            feed: feed,
                            isPlaying: podcastPlayer.currentEpisode?.feedId == feed.id && podcastPlayer.isPlaying,
                            onPlay: { podcastPlayer.playLastEpisodeForFeed(feed) },
                            onStop: { podcastPlayer.togglePlayPause() },
                            onTap: { 
                                if isEditing {
                                    // In edit mode, open edit view
                                    podcastToEdit = feed
                                    editPodcastTitle = feed.title
                                    editPodcastURL = feed.url
                                    showingEditPodcast = true
                                } else {
                                    // Normal mode, show podcast episodes
                                    selectedPodcast = feed
                                }
                            },
                            isExpanded: Binding(
                                get: { expandedFeedId == feed.id },
                                set: { isExpanded in
                                    expandedFeedId = isExpanded ? feed.id : nil
                                }
                            ),
                            viewModel: viewModel,
                            podcastPlayer: podcastPlayer,
                            isEditMode: isEditing
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                podcastToDelete = feed
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                // Edit button action
                                podcastToEdit = feed
                                editPodcastTitle = feed.title
                                editPodcastURL = feed.url
                                showingEditPodcast = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .onMove(perform: isEditing ? moveFeeds : nil)
            }
            .listStyle(PlainListStyle())
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    viewModel.deletePodcastFeed(podcast)
                }
            } message: { podcast in
                Text("Are you sure you want to delete '\(podcast.title)'? This action cannot be undone.")
            }
        }
    
    private func moveFeeds(from source: IndexSet, to destination: Int) {
        viewModel.moveFeed(from: source, to: destination)
                refreshID = UUID()
        
        viewModel.refreshAllFeeds()
            viewModel.objectWillChange.send()
        }
    
    private func onAppear() {
        os_log("PodcastListView appeared", log: log, type: .info)
        viewModel.loadFeedOrder()
        viewModel.fetchPodcastFeeds()
    }
    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        viewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
    }
    
    private func updatePodcast(_ updatedPodcast: PodcastFeed) {
        print("DEBUG: Updating podcast - Title: '\(updatedPodcast.title)', URL: '\(updatedPodcast.url)'")
        viewModel.updatePodcastFeed(updatedPodcast)
        showingEditPodcast = false
        editPodcastTitle = ""
        editPodcastURL = ""
        podcastToEdit = nil
        refreshID = UUID() // Force view refresh to show updated data
    }
    
    private func playLatestEpisode(for feed: PodcastFeed) {
        viewModel.fetchEpisodes(for: feed, completion: { result in
            switch result {
            case .success(let episodes):
                if let latestEpisode = episodes.first {
                    podcastPlayer.playEpisode(latestEpisode, feed: feed)
                }
            case .failure(let error):
                os_log("Failed to fetch episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        })
    }
    
    var filteredPodcasts: [PodcastFeed] {
        if searchText.isEmpty {
            return viewModel.podcastFeeds
        } else {
            return viewModel.podcastFeeds.filter { feed in
                feed.title.lowercased().contains(searchText.lowercased()) ||
                (feed.descriptionText?.lowercased().contains(searchText.lowercased()) ?? false)
            }
        }
    }
}

struct ToolbarItems: ToolbarContent {
    @Binding var isEditing: Bool
    let onAddTapped: () -> Void
    let onSortTapped: () -> Void
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                isEditing.toggle()
            }) {
                Text(isEditing ? "Done" : "Edit")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !isEditing {
                Button(action: onSortTapped) {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Button(action: onAddTapped) {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

struct PodcastRowView: View {
    let feed: PodcastFeed
    let isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onTap: () -> Void
    @Binding var isExpanded: Bool
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    let isEditMode: Bool
    
    private let iconSize: CGFloat = 88 // Adjusted to match 4 lines of text plus some padding
    private let arrowSize: CGFloat = 20 // New constant for arrow size
    
    // Computed property to check if there are episodes in progress for this feed
    private var hasInProgressEpisodes: Bool {
        let feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        return feedEpisodes.contains { $0.state.progress > 0 && $0.state.progress < 1 }
    }
    
    // Computed property to get the appropriate button text
    private var buttonText: String {
        let feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        // Priority 1: Check if we have a last played episode for this feed
        if let lastPlayedEpisodeId = viewModel.lastPlayedEpisodes[feed.id] {
            // Always return "Resume Episode" if we have a last played episode recorded
            // This handles the case where episodes haven't loaded yet or progress data is still syncing
            return "Resume Episode"
        }
        
        // Priority 2: Check for any episodes in progress (fallback for older data)
        if !episodesInProgress.isEmpty {
            return "Resume Podcast"
        }
        
        // Priority 3: Check if we have any episodes with stored progress from UserDefaults
        // This is a backup check for episodes that might have progress but aren't in lastPlayedEpisodes yet
        for episode in feedEpisodes {
            let progressKey = "PodcastProgress_\(episode.id)"
            let storedProgress = UserDefaults.standard.double(forKey: progressKey)
            if storedProgress > 0 && storedProgress < 1 {
                return "Resume Podcast"
            }
        }
        
        // Default case: No previous playback detected
        return "Play Latest"
    }
    
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(alignment: .top, spacing: 12) {
                    PodcastIconView(iconData: feed.iconData, imageData: feed.imageData, artworkUrl: feed.artworkUrl)
                        .frame(width: iconSize, height: iconSize)
                        .onTapGesture {
                            onTap()
                        }
                
                VStack(alignment: .leading, spacing: 4) {
                    if isExpanded {
                        Text(feed.descriptionText ?? "No description available")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .fixedSize(horizontal: false, vertical: true)
                            .onTapGesture {
                                onTap()
                            }
                    } else {
                        Text(feed.descriptionText ?? "No description available")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .lineLimit(4)
                            .frame(height: iconSize, alignment: .top)
                            .onTapGesture {
                                onTap()
                            }
                    }
                    
                    HStack {
                        if isPlaying && podcastPlayer.currentEpisode?.feedId == feed.id {
                            Button(action: {
                                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                impactFeedback.impactOccurred()
                                onStop()
                            }) {
                                HStack {
                                    Image(systemName: "pause.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Pause")
                                        .font(.footnote)
                                        .foregroundColor(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        } else {
                            Button(action: {
                                playLastPlayedEpisode()
                            }) {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundColor(.green)
                                    Text(buttonText)
                                        .font(.footnote)
                                        .foregroundColor(.green)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: arrowSize))
                    .foregroundColor(.gray)
                    .frame(width: arrowSize, height: iconSize)
                    .onTapGesture {
                        onTap()
                    }
            }
        }
      //  .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }
    
    private func checkAndPlayEpisode() {
        let feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        if episodesInProgress.isEmpty {
            viewModel.showNoEpisodesInProgressAlert(for: feed)
            if let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first {
                podcastPlayer.playEpisode(latestEpisode, feed: feed)
            }
        } else {
            onPlay()
        }
    }
    
    private func playLastPlayedEpisode() {
        // If there's a currently playing episode from this feed, resume it
        if let currentEpisode = podcastPlayer.currentEpisode,
           currentEpisode.feedId == feed.id,
           !podcastPlayer.isPlaying {
            podcastPlayer.togglePlayPause()
            return
        }
        
        // Get all episodes for this feed
        let feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        // Case 1: If there are episodes in progress (Resume Podcast button)
        if !episodesInProgress.isEmpty {
            // Try to play the specific last played episode if it has progress
            if let lastPlayedEpisodeId = viewModel.lastPlayedEpisodes[feed.id],
               let lastPlayedEpisode = episodesInProgress.first(where: { $0.id == lastPlayedEpisodeId }) {
                podcastPlayer.playEpisode(lastPlayedEpisode, feed: feed)
                return
            }
            
            // If no specific last played episode found, play the first in-progress episode
            if let firstInProgressEpisode = episodesInProgress.first {
                podcastPlayer.playEpisode(firstInProgressEpisode, feed: feed)
                return
            }
        }
        
        // Case 2: No episodes in progress (Play Latest button)
        // Play the most recent episode (newest by publication date)
        if let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first {
            podcastPlayer.playEpisode(latestEpisode, feed: feed)
            return
        }
        
        // Fallback: Use the existing logic if no episodes found
        podcastPlayer.playLastEpisodeForFeed(feed)
    }
}

struct PodcastIconView: View {
    let iconData: String?
    let imageData: Data?
    let artworkUrl: String?
    
    var body: some View {
        Group {
            if let imageData = imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(10)
            } else if let iconData = iconData, let data = Data(base64Encoded: iconData), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(10)
            } else if let artworkUrl = artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(10)
                    case .failure:
                        Image(systemName: "photo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(10)
                            .foregroundColor(.gray)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "mic.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .background(Color.blue.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}

struct EpisodeRowView: View {
    let episode: PodcastEpisode
    var isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var progress: Double
    @State private var isDownloading: Bool = false
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    private let buttonSize: CGFloat = 22
    private let rowHeight: CGFloat = 70
    private var remainingTime: Double {
        if isPlaying {
            return podcastPlayer.remainingTime
        } else {
            return episode.duration * (1 - progress)
        }
    }
    
    init(episode: PodcastEpisode, isPlaying: Bool, onPlay: @escaping () -> Void, onStop: @escaping () -> Void, viewModel: PodcastViewModel, podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
        _progress = State(initialValue: viewModel.getProgress(for: episode))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            if showingBannerAlert {
                Text(bannerAlertMessage)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
            }
            
            HStack(alignment: .center, spacing: 10) {
                // Play/Pause button
                Button(action: {
                    let progress = podcastPlayer.getCurrentProgress(for: episode)
                    if episode.state.isPlayed || progress >= 0.99 {
                        podcastPlayer.rewindAndPlay(episode: episode)
                    } else if isPlaying {
                        onStop()
                    } else {
                        onPlay()
                    }
                }) {
                    Image(systemName: episode.state.isPlayed || progress >= 0.99 ? "arrow.counterclockwise.circle.fill" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(episode.state.isPlayed || progress >= 0.99 ? .blue : (isPlaying ? .blue : .green))
                }
                .frame(width: buttonSize, height: buttonSize)
                
                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    // Episode title (2 lines)
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    // Episode info and status
                    HStack(spacing: 2) {
                        episodeStatusIndicator
                            .fixedSize()
                        Text("•")
                            .fixedSize()
                        Text(formatDate(episode.publicationDate))
                            .lineLimit(1)
                        Text("•")
                            .fixedSize()
                        Text(formatRemainingTime())
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Right column: File size, Bookmark button, Download button
                VStack(alignment: .trailing, spacing: 4) {
                    // File size
                    if let fileSize = episode.fileSize, fileSize > 0 {
                        Text(formatFileSize(fileSize))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Bookmark button
                    Button(action: {
                        if isPlaying {
                            showBannerAlert(message: "You can't add or remove favorites while the episode is playing.")
                        } else {
                            viewModel.toggleFavorite(for: episode)
                        }
                    }) {
                        Image(systemName: episode.state.isFavorite ? "bookmark.fill" : "bookmark")
                            .foregroundColor(episode.state.isFavorite ? .blue : .gray)
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    
                    // Download button or trash can
                    Group {
                        if viewModel.currentTab == 2 && episode.state.isDownloaded {
                            Button(action: {
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .frame(width: buttonSize, height: buttonSize)
                            }
                        } else {
                            downloadButton
                        }
                    }
                    .frame(width: buttonSize, height: buttonSize)
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, 10)
            
            // Progress bar (only for playing episode)
            if isPlaying {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 3)
                        
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * CGFloat(progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Downloaded Episode"),
                message: Text("Are you sure you want to delete this downloaded episode?"),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.deleteDownloadedEpisode(episode)
                },
                secondaryButton: .cancel()
            )
        }
        .onReceive(podcastPlayer.$currentProgress) { _ in
            if podcastPlayer.currentEpisode?.id == episode.id {
                progress = podcastPlayer.currentProgress
            }
        }
        .onReceive(viewModel.$episodeProgress) { _ in
            progress = viewModel.getProgress(for: episode)
        }
    }
    
    
    private var episodeStatusIndicator: some View {
            Group {
                if episode.state.isPlayed || episode.state.progress >= 0.99 {
                    Text("Played")
                        .foregroundColor(.gray)
                } else if isPlaying {
                    Text("Playing")
                        .foregroundColor(.blue)
                } else if episode.state.progress > 0 || podcastPlayer.getCurrentProgress(for: episode) > 0 {
                    Text("In Progress")
                        .foregroundColor(.orange)
                } else {
                    Text("New")
                        .foregroundColor(.green)
                }
            }
            .font(.caption2)
            .fontWeight(.semibold)
        }
    
    private var downloadButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                isDownloading = true
                viewModel.downloadEpisode(episode) { result in
                    DispatchQueue.main.async {
                        isDownloading = false
                    }
                }
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: buttonSize, height: buttonSize)
                
                if episode.state.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.green)
                } else if isDownloading {
                    Circle()
                        .trim(from: 0, to: CGFloat(viewModel.downloadProgress[episode.id] ?? 0))
                        .stroke(Color.blue, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: buttonSize, height: buttonSize)
                    
                    Image(systemName: "arrow.down")
                        .font(.system(size: buttonSize * 0.5))
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private func showBannerAlert(message: String) {
        bannerAlertMessage = message
        showingBannerAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingBannerAlert = false
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    private func formatRemainingTime() -> String {
        return formatTime(remainingTime)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d remaining", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d remaining", minutes, seconds)
        }
    }
    
    
}

struct OptimizedEpisodeRowView: View, Equatable {
    let episode: PodcastEpisode
    let isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    @State private var isDownloading: Bool = false
    
    // Cache formatters to avoid recreation
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    private var episodeState: EpisodePlaybackState {
        EpisodeStateManager.shared.getState(for: episode.id)
    }
    
    private let playbackProgress: Double
    private let buttonSize: CGFloat = 22
    
    init(episode: PodcastEpisode,
         isPlaying: Bool,
         onPlay: @escaping () -> Void,
         onStop: @escaping () -> Void,
         viewModel: PodcastViewModel,
         podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
        self.playbackProgress = isPlaying ? podcastPlayer.currentProgress : episode.state.progress
    }
    
    static func == (lhs: OptimizedEpisodeRowView, rhs: OptimizedEpisodeRowView) -> Bool {
        lhs.episode.id == rhs.episode.id &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.playbackProgress == rhs.playbackProgress &&
        lhs.episode.state == rhs.episode.state &&
        abs((lhs.viewModel.downloadProgress[lhs.episode.id] ?? 0) - (rhs.viewModel.downloadProgress[rhs.episode.id] ?? 0)) < 0.01
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if showingBannerAlert {
                Text(bannerAlertMessage)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
            }
            
            HStack(alignment: .center, spacing: 10) {
                // Play/Pause button
                playButton
                    .frame(width: buttonSize, height: buttonSize)
                
                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 2) {
                        episodeStatusIndicator
                            .fixedSize()
                        Text("•")
                            .fixedSize()
                        Text(Self.dateFormatter.string(from: episode.publicationDate))
                            .lineLimit(1)
                        if let remainingTime = formatRemainingTime() {
                            Text("•")
                                .fixedSize()
                            Text(remainingTime)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Right column: File size, Bookmark button, Download button
                VStack(alignment: .trailing, spacing: 4) {
                    if let fileSize = episode.fileSize, fileSize > 0 {
                        Text(formatFileSize(fileSize))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Bookmark button
                    Button(action: {
                        if isPlaying {
                            showBannerAlert(message: "You can't add or remove favorites while the episode is playing.")
                        } else {
                            viewModel.toggleFavorite(for: episode)
                        }
                    }) {
                        Image(systemName: episode.state.isFavorite ? "bookmark.fill" : "bookmark")
                            .foregroundColor(episode.state.isFavorite ? .blue : .gray)
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    
                    // Download button or trash can
                    Group {
                        if viewModel.currentTab == 2 && episode.state.isDownloaded {
                            Button(action: {
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .frame(width: buttonSize, height: buttonSize)
                            }
                        } else {
                            downloadButton
                        }
                    }
                    .frame(width: buttonSize, height: buttonSize)
                }
            }
            .frame(height: 70)
            .padding(.horizontal, 10)
            
            // Progress bar (only for playing episode)
            if isPlaying {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 3)
                        
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * CGFloat(playbackProgress), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Downloaded Episode"),
                message: Text("Are you sure you want to delete this downloaded episode?"),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.deleteDownloadedEpisode(episode)
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var episodeStatusIndicator: some View {
        Text(episodeState.statusText)
            .foregroundColor(episodeState.statusColor)
            .font(.caption2)
            .fontWeight(.semibold)
    }
    
    private var playButton: some View {
        Button(action: {
            switch episodeState {
            case .played:
                podcastPlayer.rewindAndPlay(episode: episode)
            case .playing:
                onStop()
            default:
                onPlay()
            }
        }) {
            Image(systemName: episodeState.buttonImage)
                .resizable()
                .frame(width: buttonSize, height: buttonSize)
                .foregroundColor(episodeState.buttonColor)
        }
    }
    
    private var downloadButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                isDownloading = true
                viewModel.downloadEpisode(episode) { result in
                    DispatchQueue.main.async {
                        isDownloading = false
                    }
                }
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: buttonSize, height: buttonSize)
                
                if episode.state.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.green)
                } else if isDownloading {
                    Circle()
                        .trim(from: 0, to: CGFloat(viewModel.downloadProgress[episode.id] ?? 0))
                        .stroke(Color.blue, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: buttonSize, height: buttonSize)
                    
                    Image(systemName: "arrow.down")
                        .font(.system(size: buttonSize * 0.5))
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private func showBannerAlert(message: String) {
        bannerAlertMessage = message
        showingBannerAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingBannerAlert = false
        }
    }
    
    private func formatRemainingTime() -> String? {
        let duration = isPlaying ? podcastPlayer.remainingTime : (episode.duration * (1 - episode.state.progress))
        guard duration > 0 else { return nil }
        
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d remaining", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d remaining", minutes, seconds)
        }
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
struct PodcastPlayerView: View {
    // MARK: - Properties
    @ObservedObject var viewModel: PodcastViewModel
    @Environment(\.presentationMode) var presentationMode
    let feed: PodcastFeed
    let initialScrollToEpisodeID: String?
    @ObservedObject var podcastPlayer: PodcastPlayer
    @StateObject private var radioPlayer = RadioPlayer.shared
    
    // MARK: - State
    @State private var selectedTab = 0
    @State private var seekPosition: Double = 0
    @State private var isSeekingManually = false
    @State private var debounceTimer: Timer?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showPodcastPlayerSheet = false
    @State private var hasPerformedInitialScroll = false
    @State private var hasInitiallyScrolled = false
    @State private var shouldAllowAutoScroll = true
    @State private var hasManuallyScrolled = false
    @State private var isLoadingMore = false
    @State private var scrollOffset: CGPoint = .zero
    @State private var viewportHeight: CGFloat = 0
    @State private var userIsScrolling = false
    @State private var scrollStartOffset: CGPoint = .zero
    @State private var lastScrollOffset: CGPoint = .zero
    @State private var scrollDebounceTimer: Timer?
    
    // MARK: - Bindings
    @Binding var selectedPodcast: PodcastFeed?
    @Binding var episodeToScrollTo: PodcastEpisode?
    
    // MARK: - Constants
    private let scrollThreshold: CGFloat = 50
    private let rowHeight: CGFloat = 80
    private let miniPlayerHeight: CGFloat = 60
    private let userScrollThreshold: CGFloat = 10.0 // Minimum distance to consider as user scrolling
    
    // MARK: - Computed Properties
    private var sliderRange: ClosedRange<Double> {
        0...max(podcastPlayer.duration, 0.01)
    }
    
    // MARK: - Body
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                playerHeader
                episodeFilterTabs
                episodeListContent
            }
            
            // Mini Player
            if podcastPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                miniPlayer
                    .transition(.move(edge: .bottom))
            }
        }
        .navigationBarHidden(true)
                .onAppear(perform: handleOnAppear)
                .onDisappear {
                    // Clean up timers to prevent memory leaks
                    scrollDebounceTimer?.invalidate()
                    scrollDebounceTimer = nil
                }
                .onChange(of: viewModel.podcastFeedOrder) { _ in 
                    // Only refresh if episodes haven't been loaded yet or if there's a significant change
                    if viewModel.currentEpisodes.isEmpty {
                        refreshEpisodes()
                    }
                }
                .sheet(isPresented: $showPodcastPlayerSheet) {
                    if let podcast = selectedPodcast {
                        PodcastPlayerView(
                            viewModel: viewModel,
                            feed: podcast,
                            initialScrollToEpisodeID: podcastPlayer.currentEpisode?.id,
                            podcastPlayer: podcastPlayer,
                            selectedPodcast: $selectedPodcast,
                            episodeToScrollTo: Binding(
                                get: { podcastPlayer.currentEpisode },
                                set: { _ in }
                            )
                        )
                    }
                }
    }
    
    // MARK: - View Components
    private var playerHeader: some View {
        VStack(spacing: 0) {
            // Navigation Bar
            HStack {
                Button(action: updateViewModelAndDismiss) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.primary)
                }
                Spacer()
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                AirPlayButton()
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal)
            .frame(height: 44)
            .background(Color(UIColor.systemBackground))
            
            // Feed Info Area
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    FeedImageView(feed: feed)
                        .frame(width: min(120, geometry.size.width * 0.3))
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView {
                            Text(feed.descriptionText ?? "No description available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                        }
                        .frame(height: 60)
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 4) {
                            ScrollView(.vertical, showsIndicators: false) {
                                Text(podcastPlayer.currentEpisode?.title ?? "No episode playing")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(height: 60)
                            
                            if let currentEpisode = podcastPlayer.currentEpisode {
                                Text(formatDate(currentEpisode.publicationDate))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.trailing, 10)
                    }
                    .frame(width: geometry.size.width - min(120, geometry.size.width * 0.3) - 32)
                }
                .padding()
            }
            .frame(height: 180)
            .background(Color(UIColor.secondarySystemBackground))
        }
    }
    
    private var episodeFilterTabs: some View {
        Picker("", selection: $selectedTab) {
            Text("All").tag(0)
            Text("Favorites").tag(1)
            Text("Downloads").tag(2)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
        .onChange(of: selectedTab) { newValue in
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: newValue)
        }
    }
    
    private var episodeListContent: some View {
        Group {
            if viewModel.isLoadingEpisodes {
                ProgressView("Loading episodes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                optimizedEpisodeList
            }
        }
    }
    
    private var optimizedEpisodeList: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.currentEpisodes, id: \.compositeID) { episode in
                        OptimizedEpisodeRowView(
                            episode: episode,
                            isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                            onPlay: { playEpisode(episode) },
                            onStop: { podcastPlayer.togglePlayPause() },
                            viewModel: viewModel,
                            podcastPlayer: podcastPlayer
                        )
                        .id(episode.compositeID)
                    }
                    
                    if viewModel.hasMoreEpisodes && !viewModel.isLoadingMoreEpisodes {
                        ProgressView()
                            .padding()
                            .onAppear {
                                loadMoreIfNeeded()
                            }
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .trackScrollOffset(coordinateSpace: "scrollArea", offset: $scrollOffset)
                .onAppear {
                    scrollProxy = proxy
                    // Perform initial scroll to the current episode only once when view first opens
                    performInitialScrollIfNeeded(proxy: proxy)
                }
                .onChange(of: scrollOffset) { newOffset in
                    handleScrollOffsetChange(newOffset)
                }
            }
        }
        .coordinateSpace(name: "scrollArea")
    }

    private func performInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        // Only perform initial scroll if:
        // 1. We haven't already performed it
        // 2. There's a current episode playing
        // 3. The episode exists in the current list
        // 4. User hasn't manually scrolled yet
        // 5. Episodes have actually loaded (not empty)
        guard !hasPerformedInitialScroll,
              !hasManuallyScrolled,
              !viewModel.currentEpisodes.isEmpty,
              let currentEpisode = podcastPlayer.currentEpisode,
              podcastPlayer.isPlaying,
              viewModel.currentEpisodes.contains(where: { $0.compositeID == currentEpisode.compositeID }) else {
            return
        }
        
        // Mark as performed immediately to prevent multiple calls
        hasPerformedInitialScroll = true
        
        // Add a slight delay to ensure the view is properly laid out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Double-check that we should still scroll (user might have scrolled in the meantime)
            guard !self.hasManuallyScrolled else { return }
            
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(currentEpisode.compositeID, anchor: .center)
            }
        }
    }
    
    private func handleScrollOffsetChange(_ newOffset: CGPoint) {
        // Detect if user is actively scrolling
        let scrollDistance = abs(newOffset.y - lastScrollOffset.y)
        
        // Only consider it user scrolling if:
        // 1. The distance is significant enough
        // 2. We're not in the middle of an initial auto-scroll
        // 3. The initial scroll has been completed or enough time has passed
        if scrollDistance > userScrollThreshold && hasPerformedInitialScroll {
            // User is scrolling - mark as manual scroll and disable auto-scroll
            if !userIsScrolling {
                userIsScrolling = true
                hasManuallyScrolled = true
                scrollStartOffset = lastScrollOffset
            }
            
            // Reset the debounce timer
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                userIsScrolling = false
            }
        }
        
        lastScrollOffset = newOffset
        
        // Check if we should load more content
        checkIfShouldLoadMore()
    }
    
    private var miniPlayer: some View {
        VStack(spacing: 0) {
            Spacer()
            MiniPlayerView(
                podcastPlayer: podcastPlayer,
                viewModel: viewModel,
                selectedPodcast: $selectedPodcast,
                onListButtonTap: handleMiniPlayerListTap,
                onCloseButtonTap: handleMiniPlayerClose,
                isPlaylistButtonDisabled: true
            )
            .padding(.top, 15)
            .padding(.bottom, 20)
            .background(Color(UIColor.systemBackground))
        }
        .edgesIgnoringSafeArea(.bottom)
    }
    
    // MARK: - Helper Methods
    private func checkIfShouldLoadMore() {
        let threshold: CGFloat = 50
        let contentHeight = CGFloat(viewModel.currentEpisodes.count) * rowHeight
        let triggerPoint = contentHeight - viewportHeight - threshold

        if -scrollOffset.y > triggerPoint && !isLoadingMore && viewModel.hasMoreEpisodes {
            loadMoreIfNeeded()
        }
    }
    
    private func handleOnAppear() {
        // Only reset scroll state if this is truly a fresh view (episodes are empty)
        // This prevents resetting state when the view is just being refreshed
        if viewModel.currentEpisodes.isEmpty {
            hasPerformedInitialScroll = false
            hasManuallyScrolled = false
            userIsScrolling = false
            scrollOffset = .zero
            lastScrollOffset = .zero
            
            loadInitialEpisodes()
        } else {
            // View already has episodes loaded, just ensure we have the latest data
            // but don't reset scroll state
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
        }
    }
    
    private func handleMiniPlayerListTap() {
        if let currentFeed = podcastPlayer.currentFeed {
            selectedPodcast = currentFeed
            viewModel.fetchAllEpisodes(for: currentFeed)
            showPodcastPlayerSheet = true
        }
    }
    
    private func handleMiniPlayerClose() {
        podcastPlayer.pause()
        podcastPlayer.currentEpisode = nil
        podcastPlayer.currentFeed = nil
    }
    
    private func loadInitialEpisodes() {
            viewModel.loadAllEpisodesForFeed(feed)
        }
    
    private func refreshEpisodes() {
            guard !viewModel.isLoadingEpisodes else { return }
            viewModel.clearCache(for: feed.id)
            viewModel.loadAllEpisodesForFeed(feed)
        }
    
    private func loadMoreIfNeeded() {
           guard !isLoadingMore && viewModel.hasMoreEpisodes else { return }
           
           isLoadingMore = true
           viewModel.loadMoreEpisodes(for: feed) { _ in
               isLoadingMore = false
           }
       }
    
    // Removed redundant scrolling methods to prevent interference with user scrolling
    // All auto-scrolling is now handled only in performInitialScrollIfNeeded(proxy:)
    
    private func isEpisodeVisible(_ episodeCompositeId: String) -> Bool {
        guard let episodeIndex = viewModel.currentEpisodes.firstIndex(where: { $0.compositeID == episodeCompositeId }) else {
            return false
        }
        
        let episodeYPosition = CGFloat(episodeIndex) * rowHeight
        let visibleRangeStart = -scrollOffset.y
        let visibleRangeEnd = -scrollOffset.y + viewportHeight
        
        return episodeYPosition >= visibleRangeStart && episodeYPosition <= visibleRangeEnd
    }
    
    private func playEpisode(_ episode: PodcastEpisode) {
            if podcastPlayer.currentEpisode?.id == episode.id {
                if episode.state.isPlayed || podcastPlayer.currentProgress >= 0.99 {
                    podcastPlayer.rewindAndPlay(episode: episode)
                } else {
                    podcastPlayer.togglePlayPause()
                }
            } else {
                podcastPlayer.playEpisode(episode, feed: feed)
            }
        }
    
    private func updateViewModelAndDismiss() {
        // First, handle the currently playing episode status
        podcastPlayer.handleNavigationAway()
        
        // Then proceed with the existing logic
        if let currentEpisode = podcastPlayer.currentEpisode {
            podcastPlayer.saveProgressIfNeeded()
            
            let progress = podcastPlayer.getCurrentProgress(for: currentEpisode)
            var updatedEpisode = currentEpisode
            
            if progress >= 0.99 {
                updatedEpisode.state.isPlayed = true
                updatedEpisode.state.progress = 1.0
            } else if progress > 0 {
                updatedEpisode.state.isPlayed = false
                updatedEpisode.state.progress = progress
            }
            
            viewModel.updateEpisode(updatedEpisode)
            
            if updatedEpisode.state.isFavorite != viewModel.favoriteEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                viewModel.toggleFavorite(for: updatedEpisode)
            }
            
            let isDownloaded = viewModel.downloadedEpisodes.contains(where: { $0.id == updatedEpisode.id })
            if updatedEpisode.state.isDownloaded != isDownloaded {
                if isDownloaded {
                    updatedEpisode.state.isDownloaded = true
                    viewModel.updateEpisode(updatedEpisode)
                } else {
                    viewModel.deleteDownloadedEpisode(updatedEpisode)
                }
            }
            
            // Update progress for all episodes in the current feed
            for episode in viewModel.currentEpisodes {
                let episodeProgress = podcastPlayer.getCurrentProgress(for: episode)
                if episodeProgress > 0 {
                    var updatedPlayedEpisode = episode
                    updatedPlayedEpisode.state.progress = episodeProgress
                    updatedPlayedEpisode.state.isPlayed = episodeProgress >= 0.99
                    viewModel.updateEpisode(updatedPlayedEpisode)
                }
            }
        }
        
        viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: viewModel.currentTab)
        
        DispatchQueue.main.async {
            viewModel.objectWillChange.send()
        }
        
        presentationMode.wrappedValue.dismiss()
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}


private func formatTime(_ time: Double) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%02d:%02d", minutes, seconds)
}


struct ProgressSlider: View {
    @Binding var value: Double
    let inRange: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 4)
                
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geometry.size.width * CGFloat((value - inRange.lowerBound) / (inRange.upperBound - inRange.lowerBound)), height: 4)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                    .offset(x: geometry.size.width * CGFloat((value - inRange.lowerBound) / (inRange.upperBound - inRange.lowerBound)) - 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let newValue = Double(gesture.location.x / geometry.size.width) * (inRange.upperBound - inRange.lowerBound) + inRange.lowerBound
                                value = min(max(newValue, inRange.lowerBound), inRange.upperBound)
                                onEditingChanged(true)
                            }
                            .onEnded { _ in
                                onEditingChanged(false)
                            }
                    )
            }
        }
    }
}



struct RefreshControl: View {
var coordinateSpace: CoordinateSpace
var onRefresh: () -> Void

@State private var refresh: Bool = false
@State private var frozen: Bool = false

var body: some View {
    GeometryReader { geo in
        if (geo.frame(in: coordinateSpace).midY > 50) {
            Spacer()
                .onAppear {
                    if !refresh {
                        refresh = true
                    }
                }
        } else if (geo.frame(in: coordinateSpace).maxY < 1) {
            Spacer()
                .onAppear {
                    if refresh {
                        Task {
                            frozen = true
                            onRefresh()
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            frozen = false
                            refresh = false
                        }
                    }
                }
        }
        ZStack(alignment: .center) {
            if refresh || frozen {
                ProgressView()
            }
        }.frame(height: geo.size.height)
    }.padding(.top, -50)
}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let routePickerView = AVRoutePickerView()
        routePickerView.activeTintColor = .blue
        routePickerView.tintColor = .gray
        
        // Customize the button appearance
        if let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton {
            button.setImage(UIImage(systemName: "airplayaudio"), for: .normal)
            button.contentVerticalAlignment = .fill
            button.contentHorizontalAlignment = .fill
            button.imageEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        }
        
        return routePickerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PodcastList: View {
    let feeds: [PodcastFeed]
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    let onPlay: (PodcastFeed) -> Void
    let onDelete: (PodcastFeed) -> Void
    @Binding var selectedPodcast: PodcastFeed?
    @State private var expandedFeedId: String?
    
    var body: some View {
        List {
            ForEach(orderedFeeds, id: \.id) { feed in
                PodcastRowView(
                    feed: feed,
                    isPlaying: podcastPlayer.currentEpisode?.feedId == feed.id && podcastPlayer.isPlaying,
                    onPlay: {
                        if let episode = viewModel.getLastPlayedOrLatestEpisode(for: feed) {
                            podcastPlayer.playEpisode(episode, feed: feed)
                        }
                    },
                    onStop: { podcastPlayer.togglePlayPause() },
                    onTap: { selectedPodcast = feed },
                    isExpanded: Binding(
                        get: { expandedFeedId == feed.id },
                        set: { isExpanded in
                            expandedFeedId = isExpanded ? feed.id : nil
                        }
                    ),
                    viewModel: viewModel,  // Pass the viewModel here
                    podcastPlayer: podcastPlayer,
                    isEditMode: false  // Add the missing parameter - PodcastList is not in edit mode
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onDelete(feed)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var orderedFeeds: [PodcastFeed] {
        let orderedIds = Set(viewModel.podcastFeedOrder)
        let orderedFeeds = feeds.filter { orderedIds.contains($0.id) }
            .sorted { viewModel.podcastFeedOrder.firstIndex(of: $0.id)! < viewModel.podcastFeedOrder.firstIndex(of: $1.id)! }
        let remainingFeeds = feeds.filter { !orderedIds.contains($0.id) }
        return orderedFeeds + remainingFeeds
    }
}

extension View {
    func debounce(delay: Double, action: @escaping () -> Void) -> some View {
        self.modifier(DebouncedAction(delay: delay, action: action))
    }
}

struct DebouncedAction: ViewModifier {
    let delay: Double
    let action: () -> Void
    
    @State private var workItem: DispatchWorkItem?
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                workItem?.cancel()
            }
            .onDisappear {
                workItem?.cancel()
            }
            .onChange(of: UUID()) { _ in
                workItem?.cancel()
                let newWorkItem = DispatchWorkItem(block: action)
                workItem = newWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newWorkItem)
            }
    }
}
