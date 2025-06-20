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
    @Binding var selectedPodcast: PodcastFeed?
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
    private let miniPlayerHeight: CGFloat = 60 // Compact mini player height
    
    // Default initializer for backward compatibility
    init() {
        self._selectedPodcast = .constant(nil)
    }
    
    // Initializer with binding
    init(selectedPodcast: Binding<PodcastFeed?>) {
        self._selectedPodcast = selectedPodcast
    }
    
    var body: some View {
           NavigationView {
               ZStack(alignment: .bottom) {
                   // Show episode list inline when a podcast is selected
                   if let selectedPodcast = selectedPodcast {
                       PodcastPlayerView(
                           viewModel: viewModel,
                           feed: selectedPodcast,
                           initialScrollToEpisodeID: podcastPlayer.currentEpisode?.id,
                           podcastPlayer: podcastPlayer,
                           selectedPodcast: $selectedPodcast,
                           episodeToScrollTo: Binding(
                               get: { podcastPlayer.currentEpisode },
                               set: { _ in }
                           )
                       )
                       .transition(.slide)
                   } else {
                       // Show the podcast list when no podcast is selected
                       VStack(spacing: 0) {
                           instructionText
                           searchBar
                           podcastList
                               .padding(.bottom, podcastPlayer.currentEpisode != nil ? miniPlayerHeight : 0)
                       }
                   }
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
               .onChange(of: selectedPodcast) { _, newValue in
                   // When selectedPodcast is set from outside (like from ContentView),
                   // automatically show the episode list
                   if let podcast = newValue {
                       viewModel.fetchAllEpisodes(for: podcast)
                   }
               }
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
                   .padding(.bottom, podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 40 : 0)
                   
                   // Fixed Mini Player
                   if podcastPlayer.isPlaying && !radioPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                       MiniPodcastPlayerView(
                           currentEpisode: currentEpisode,
                           currentFeed: currentFeed,
                           podcastPlayer: podcastPlayer,
                           viewModel: viewModel,
                           selectedPodcast: $selectedPodcast,
                           onListButtonTap: {
                               selectedPodcast = currentFeed
                               scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                           },
                           onCloseButtonTap: {
                               podcastPlayer.pause()
                               podcastPlayer.currentEpisode = nil
                               podcastPlayer.currentFeed = nil
                           }
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
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        UserDefaults.standard.set(true, forKey: "isUserScrolling")
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            UserDefaults.standard.set(false, forKey: "isUserScrolling")
                        }
                    }
            )
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
                                         AsyncImage(url: URL(string: feed.artworkUrl ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "music.note")
                            .foregroundColor(.gray)
                            .frame(width: 60, height: 60)
                    }
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
    
    // Static formatter to avoid recreation
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
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
                    HStack(spacing: 8) {
                        // Status indicator
                        episodeStatusChip
                        
                        // Date
                        Text(Self.dateFormatter.string(from: episode.publicationDate))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Duration/remaining time
                        if let timeInfo = formatTimeInfo() {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.gray)
                            
                            Text(timeInfo)
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer()
                    }
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
    
    
    private var episodeStatusChip: some View {
        Group {
            if episode.state.isPlayed || episode.state.progress >= 0.99 {
                Text("Played")
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray))
            } else if isPlaying {
                Text("Playing")
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue))
            } else if episode.state.progress > 0 || podcastPlayer.getCurrentProgress(for: episode) > 0 {
                Text("In Progress")
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
            } else {
                Text("New")
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green))
            }
        }
        .font(.system(size: 10, weight: .bold))
        .fixedSize() // Ensure full text is displayed without truncation
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
    
    private func formatTimeInfo() -> String? {
        let remainingDuration: Double
        if isPlaying {
            remainingDuration = podcastPlayer.remainingTime
        } else if episode.state.progress > 0 {
            remainingDuration = episode.duration * (1 - episode.state.progress)
        } else {
            remainingDuration = episode.duration
        }
        
        guard remainingDuration > 0 else { return nil }
        
        let hours = Int(remainingDuration) / 3600
        let minutes = (Int(remainingDuration) % 3600) / 60
        
        if episode.state.progress > 0 {
            if hours > 0 {
                return String(format: "%dh %dm left", hours, minutes)
            } else {
                return String(format: "%dm left", minutes)
            }
        } else {
            if hours > 0 {
                return String(format: "%dh %dm", hours, minutes)
            } else {
                return String(format: "%dm", minutes)
            }
        }
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
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

    
    private func formatRemainingTime() -> String {
        return formatTime(remainingTime)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        
        if minutes > 0 {
            return String(format: "%dm %ds left", minutes, seconds)
        } else {
            return String(format: "%ds left", seconds)
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
                bannerAlertView
            }
            
            modernEpisodeCard
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Download"),
                message: Text("Are you sure you want to delete the downloaded file? The episode will remain in the list but will need to be downloaded again to listen offline."),
                primaryButton: .destructive(Text("Delete Download")) {
                    viewModel.deleteDownloadedEpisode(episode)
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var bannerAlertView: some View {
        Text(bannerAlertMessage)
            .font(.caption)
            .foregroundColor(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.red)
            .cornerRadius(6)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
    
    // MARK: - Enhanced Episode Card Design
    private var modernEpisodeCard: some View {
        VStack(spacing: 0) {
            // Main episode content with enhanced visual separation
            Group {
                if viewModel.currentTab == 2 && episode.state.isDownloaded {
                    episodeContentWithSwipe
                } else {
                    episodeContent
                }
            }
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        isPlaying ? Color.blue.opacity(0.05) : Color.clear,
                        Color.clear
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            
            // Compact separator
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 4) // Reduced spacing between episodes
            }
        }
    }
    
    private var episodeContent: some View {
        VStack(spacing: 0) {
            // 3-column layout for perfect alignment
            HStack(alignment: .top, spacing: 0) {
                // Column 1: Play button (fixed width)
                modernPlayButton
                    .frame(width: 50, height: 40, alignment: .leading)
                
                // Column 2: Episode content (flexible width)
                VStack(alignment: .leading, spacing: 4) {
                    // Episode title - allow full display
                    Text(episode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isPlaying ? .white : .primary)
                        .lineLimit(nil) // Allow unlimited lines for full display
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Metadata row - flexible layout to show all content
                    HStack(spacing: 6) {
                        // Status indicator - more compact
                        episodeStatusChip
                        
                        // Date - more compact
                        Text(Self.dateFormatter.string(from: episode.publicationDate))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue.opacity(0.1))
                            )
                            .fixedSize() // Prevent truncation
                        
                        // Duration/remaining time - more compact
                        if let timeInfo = formatTimeInfo() {
                            Text(timeInfo)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.gray.opacity(0.1))
                                )
                                .fixedSize() // Prevent truncation
                        }
                        
                        Spacer(minLength: 0) // Allow space to expand/contract as needed
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                
                // Column 3: Action buttons (fixed width)
                VStack(alignment: .center, spacing: 4) {
                    modernBookmarkButton
                    modernDownloadButton
                }
                .frame(width: 50, alignment: .center)
            }
            
            // Progress bar - only show when actually playing (not just in progress)
            if isPlaying {
                interactiveProgressBar
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16) // Consistent horizontal padding for all episodes
        .padding(.vertical, 12) // Consistent vertical padding for all episodes
        .background(Color.clear) // Remove all background styling
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
    }
    
    private var episodeContentWithSwipe: some View {
        episodeContent
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: {
                    showingDeleteConfirmation = true
                }) {
                    Label("Delete Download", systemImage: "trash.fill")
                }
                .tint(.red)
            }
    }
    
    // MARK: - Modern Components
    
    private var modernPlayButton: some View {
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
            ZStack {
                // Background circle with gradient - more compact
                Circle()
                    .fill(playButtonGradient)
                    .frame(width: 40, height: 40)
                    .shadow(color: playButtonShadowColor, radius: 2, x: 0, y: 1)
                
                // Icon - smaller
                Image(systemName: playButtonIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .offset(x: playButtonIcon == "play.fill" ? 1 : 0) // Slight offset for play icon
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPlaying ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        .frame(width: 40, height: 40, alignment: .leading) // Ensure consistent alignment
    }
    
    private var playButtonGradient: LinearGradient {
        let progress = podcastPlayer.getCurrentProgress(for: episode)
        if episode.state.isPlayed || progress >= 0.99 {
            return LinearGradient(
                gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isPlaying {
            return LinearGradient(
                gradient: Gradient(colors: [Color.orange, Color.red]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    private var playButtonIcon: String {
        // Prioritize current playing state over finished state
        if isPlaying {
            return "pause.fill"
        } else {
            let progress = podcastPlayer.getCurrentProgress(for: episode)
            // If episode was rewound (progress is very low), show play icon even if previously marked as played
            if progress < 0.05 {
                return "play.fill"
            } else if episode.state.isPlayed || progress >= 0.99 {
                return "arrow.counterclockwise"
            } else {
                return "play.fill"
            }
        }
    }
    
    private var playButtonShadowColor: Color {
        if isPlaying {
            return Color.orange.opacity(0.3)
        } else {
            return Color.black.opacity(0.2)
        }
    }
    
    private var episodeStatusChip: some View {
        Text(episodeState.statusText)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(episodeState.statusColor)
            )
            .fixedSize() // Ensure full text is displayed without truncation
    }
    
    private var modernProgressIndicator: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                
                // Progress fill with gradient
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.cyan]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * CGFloat(currentProgress), height: 4)
                    .animation(.easeInOut(duration: 0.3), value: currentProgress)
            }
        }
        .frame(height: 4)
    }
    
    private var interactiveProgressBar: some View {
        GeometryReader { geometry in
            let currentProgress = isPlaying ? podcastPlayer.currentProgress : episode.state.progress
            
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 3)
                
                // Progress fill with gradient
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.cyan]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * CGFloat(currentProgress), height: 3)
                    .animation(.easeInOut(duration: 0.3), value: currentProgress)
                
                // Interactive thumb (only visible when playing)
                if isPlaying {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(geometry.size.width - 12, (geometry.size.width - 12) * currentProgress)))
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard isPlaying else { return }
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        let newTime = progress * podcastPlayer.duration
                        podcastPlayer.seek(to: newTime)
                    }
            )
            .onTapGesture { value in
                guard isPlaying else { return }
                let progress = max(0, min(1, value.x / geometry.size.width))
                let newTime = progress * podcastPlayer.duration
                podcastPlayer.seek(to: newTime)
            }
        }
        .frame(height: isPlaying ? 12 : 3)
    }
    
    private var shouldShowProgress: Bool {
        isPlaying || episode.state.progress > 0.01
    }
    
    private var currentProgress: Double {
        if isPlaying {
            return podcastPlayer.currentProgress
        } else {
            return episode.state.progress
        }
    }
    
    private var modernBookmarkButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't add or remove favorites while the episode is playing.")
            } else {
                viewModel.toggleFavorite(for: episode)
            }
        }) {
            ZStack {
                Circle()
                    .fill(episode.state.isFavorite ? Color.red.opacity(0.2) : Color.clear)
                    .frame(width: 34, height: 34) // Made bigger
                
                Image(systemName: episode.state.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .medium)) // Made bigger
                    .foregroundColor(episode.state.isFavorite ? .red : .gray)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(episode.state.isFavorite ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: episode.state.isFavorite)
    }
    
    private var modernDownloadButton: some View {
        Button(action: {
            if viewModel.currentTab == 2 && episode.state.isDownloaded {
                showingDeleteConfirmation = true
            } else {
                handleDownloadAction()
            }
        }) {
            ZStack {
                Circle()
                    .fill(downloadButtonBackgroundColor)
                    .frame(width: 34, height: 34) // Made bigger
                
                if viewModel.currentTab == 2 && episode.state.isDownloaded {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .medium)) // Made bigger
                        .foregroundColor(.red)
                } else if episode.state.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold)) // Made bigger
                        .foregroundColor(.green)
                } else if isDownloading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(0.8) // Made bigger
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16, weight: .medium)) // Made bigger
                        .foregroundColor(.gray)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isDownloading ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDownloading)
    }
    
    private var downloadButtonBackgroundColor: Color {
        if viewModel.currentTab == 2 && episode.state.isDownloaded {
            return Color.red.opacity(0.2)
        } else if episode.state.isDownloaded {
            return Color.green.opacity(0.2)
        } else if isDownloading {
            return Color.blue.opacity(0.2)
        } else {
            return Color.clear
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleDownloadAction() {
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
    }
    
    private func showBannerAlert(message: String) {
        bannerAlertMessage = message
        showingBannerAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingBannerAlert = false
        }
    }
    
    private func formatTimeInfo() -> String? {
        let remainingDuration: Double
        if isPlaying {
            remainingDuration = podcastPlayer.remainingTime
        } else if episode.state.progress > 0 {
            remainingDuration = episode.duration * (1 - episode.state.progress)
        } else {
            remainingDuration = episode.duration
        }
        
        guard remainingDuration > 0 else { return nil }
        
        let hours = Int(remainingDuration) / 3600
        let minutes = (Int(remainingDuration) % 3600) / 60
        
        if episode.state.progress > 0 {
            if hours > 0 {
                return String(format: "%dh %dm left", hours, minutes)
            } else {
                return String(format: "%dm left", minutes)
            }
        } else {
            if hours > 0 {
                return String(format: "%dh %dm", hours, minutes)
            } else {
                return String(format: "%dm", minutes)
            }
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
            
            // Compact Mini Player
            if podcastPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                MiniPodcastPlayerView(
                    currentEpisode: currentEpisode,
                    currentFeed: currentFeed,
                    podcastPlayer: podcastPlayer,
                    viewModel: viewModel,
                    selectedPodcast: $selectedPodcast,
                    onListButtonTap: {
                        // Already in episode list, no action needed
                    },
                    onCloseButtonTap: {
                        podcastPlayer.pause()
                        podcastPlayer.currentEpisode = nil
                        podcastPlayer.currentFeed = nil
                    }
                )
                .transition(.move(edge: .bottom))
                .frame(height: 60) // Fixed compact height
            }
        }
        .navigationBarHidden(true)
                .onAppear(perform: handleOnAppear)
                        .onDisappear {
            // Clean up timers to prevent memory leaks
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = nil
            
            // Reset scrolling state when view disappears
            userIsScrolling = false
            UserDefaults.standard.set(false, forKey: "isUserScrolling")
            NotificationCenter.default.post(name: .userStoppedScrolling, object: false)
        }
                .onChange(of: viewModel.podcastFeedOrder) { _ in 
                    // Only refresh if episodes haven't been loaded yet or if there's a significant change
                    if viewModel.currentEpisodes.isEmpty {
                        viewModel.fetchAllEpisodes(for: feed)
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
            // Enhanced Navigation Bar with gradient background
            HStack {
                Button(action: { selectedPodcast = nil }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                
                Spacer()
                
                Text(feed.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                Spacer()
                
                AirPlayButton()
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(Color.gray.opacity(0.1))
                    )
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(UIColor.systemBackground),
                        Color(UIColor.systemBackground).opacity(0.95)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 1),
                alignment: .bottom
            )
            
            // Enhanced Feed Info Area with better hierarchy
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 20) {
                        // Enhanced artwork with shadow and border
                        AsyncImage(url: URL(string: feed.artworkUrl ?? "")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.gray.opacity(0.2))
                                
                                Image(systemName: "music.note")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(width: min(130, geometry.size.width * 0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // Podcast description section
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ABOUT")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.blue)
                                    .tracking(1.2)
                                
                                ScrollView {
                                    Text(feed.descriptionText ?? "No description available")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .lineLimit(4)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(height: 50)
                            }
                            
                            // Visual separator
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 1)
                            
                            // Currently playing section
                            VStack(alignment: .leading, spacing: 6) {
                                Text("NOW PLAYING")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.blue)
                                    .tracking(1.2)
                                
                                ScrollView(.vertical, showsIndicators: false) {
                                    Text(podcastPlayer.currentEpisode?.title ?? "No episode playing")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(height: 45)
                                
                                if let currentEpisode = podcastPlayer.currentEpisode {
                                    Text(formatDate(currentEpisode.publicationDate))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.blue.opacity(0.1))
                                        )
                                }
                            }
                        }
                        .frame(width: geometry.size.width - min(130, geometry.size.width * 0.35) - 40)
                    }
                    .padding(20)
                }
            }
            .frame(height: 190)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(UIColor.secondarySystemBackground).opacity(0.8),
                        Color(UIColor.secondarySystemBackground)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            // Bottom separator with gradient
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(height: 2)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue.opacity(0.2), Color.clear]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 4)
            }
        }
    }
    
    private var episodeFilterTabs: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("EPISODES")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                    .tracking(1.0)
                
                Spacer()
                
                Text("\(viewModel.currentEpisodes.count) episode\(viewModel.currentEpisodes.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.1))
                    )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            
            // Enhanced filter tabs
            Picker("", selection: $selectedTab) {
                Text("All").tag(0)
                Text("Favorites").tag(1)
                Text("Downloads").tag(2)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemBackground),
                    Color(UIColor.systemBackground).opacity(0.95)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1),
            alignment: .bottom
        )
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
                modernEpisodeList
            }
        }
    }
    
    private var modernEpisodeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                            .scaleEffect(1.0)
                        Text("Loading more episodes...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.leading, 8)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .onAppear {
                        loadMoreIfNeeded()
                    }
                }
                
                // Bottom padding for compact mini player
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 70)
            }
        }
        .background(Color.black)
        .simultaneousGesture(
            DragGesture()
                .onChanged { _ in
                    UserDefaults.standard.set(true, forKey: "isUserScrolling")
                }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        UserDefaults.standard.set(false, forKey: "isUserScrolling")
                    }
                }
        )
    }

    private func handleOnAppear() {
        let currentEpisodesForThisFeed = viewModel.currentEpisodes.first?.feedId == feed.id
        
        if viewModel.currentEpisodes.isEmpty || !currentEpisodesForThisFeed {
            hasPerformedInitialScroll = false
            hasManuallyScrolled = false
            userIsScrolling = false
            scrollOffset = .zero
            lastScrollOffset = .zero
            
            loadInitialEpisodes()
        } else {
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
        }
    }
    
    private func loadInitialEpisodes() {
        viewModel.loadAllEpisodesForFeed(feed)
    }
    
    private func loadMoreIfNeeded() {
        guard !isLoadingMore && viewModel.hasMoreEpisodes else { return }
        
        isLoadingMore = true
        viewModel.loadMoreEpisodes(for: feed) { _ in
            isLoadingMore = false
        }
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


