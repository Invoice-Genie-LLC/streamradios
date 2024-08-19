//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI
import Combine
import os

struct PodcastListView: View {
    @StateObject private var viewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var selectedPodcast: PodcastFeed? // Binding for selectedPodcast
    @State private var searchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var seekPosition: Double = 0.0
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    
    var filteredPodcasts: [PodcastFeed] {
        return viewModel.podcastFeeds.sorted { $0.episodes.first?.publicationDate ?? Date() > $1.episodes.first?.publicationDate ?? Date() }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                searchBar
                PodcastList(
                    feeds: filteredPodcasts,
                    podcastPlayer: podcastPlayer,
                    onPlay: { playLatestEpisode(for: $0) },
                    onDelete: { feed in
                        podcastToDelete = feed
                        showingDeleteConfirmation = true
                    },
                    selectedPodcast: $selectedPodcast
                )
            }
            .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    viewModel.deletePodcastFeed(podcast)
                }
            } message: { podcast in
                Text("Are you sure you want to delete '\(podcast.title)'? This action cannot be undone.")
            }
            .navigationTitle("Podcasts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddPodcast = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                os_log("PodcastListView appeared", log: log, type: .info)
                viewModel.fetchPodcastFeeds()
            }
            .sheet(isPresented: $showingAddPodcast) {
                AddPodcastView(isPresented: $showingAddPodcast, title: $newPodcastTitle, url: $newPodcastURL, onAdd: addPodcast)
            }
            .sheet(item: $selectedPodcast) { podcast in
                PodcastPlayerView(viewModel: viewModel, feed: podcast, podcastPlayer: podcastPlayer)
            }
            
        }
    }
    
    private var searchBar: some View {
        TextField("Search podcasts", text: $searchText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(.horizontal)
    }
    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        viewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
    }
    
    private func playLatestEpisode(for feed: PodcastFeed) {
        viewModel.fetchEpisodes(for: feed) { result in
            switch result {
            case .success(let episodes):
                if let latestEpisode = episodes.first {
                    podcastPlayer.playEpisode(latestEpisode, feed: feed)
                }
            case .failure(let error):
                os_log("Failed to fetch episodes: %@", log: log, type: .error, error.localizedDescription)
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
    
    var body: some View {
        HStack(spacing: 12) {
            PodcastIconView(iconData: feed.iconData, artworkUrl: feed.artworkUrl)
                .frame(width: 60, height: 60)
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(feed.description ?? "No description available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            PlayButton(isPlaying: isPlaying, onPlay: onPlay, onStop: onStop)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct PodcastIconView: View {
    let iconData: String?
    let artworkUrl: String?
    
    var body: some View {
        Group {
            if let iconData = iconData, let uiImage = UIImage(data: Data(base64Encoded: iconData) ?? Data()) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let artworkUrl = artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
            } else {
                Image(systemName: "mic")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .background(Color.blue)
                    .foregroundColor(.white)
            }
        }
    }
}

struct EpisodeRowView: View {
    let episode: PodcastEpisode
    let isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var isFavorite: Bool
    @State private var isDownloaded: Bool
    @State private var isDownloading: Bool = false
    @State private var progress: Double
    @State private var showingDeleteConfirmation = false
    private let buttonSize: CGFloat = 30

    init(episode: PodcastEpisode, isPlaying: Bool, onPlay: @escaping () -> Void, onStop: @escaping () -> Void, viewModel: PodcastViewModel, podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
        _isFavorite = State(initialValue: episode.state.isFavorite)
        _isDownloaded = State(initialValue: episode.state.isDownloaded)
        _progress = State(initialValue: viewModel.getProgress(for: episode))
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Episode title
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)

                // Episode publication date and "In Progress" label in one line
                HStack {
                    Text(formatDate(episode.publicationDate))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if isPlaying || progress > 0 {
                        Text("In Progress")
                            .font(.caption)
                            .padding(4)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }

                // Display file size if available and time remaining
                if isPlaying || progress > 0 {
                    ProgressView(value: isPlaying ? safeProgress(podcastPlayer.currentTime, podcastPlayer.duration) : progress)
                        .accentColor(.blue)
                    
                    HStack {
                        // File size
                        if let fileSize = episode.fileSize {
                            Text(formatFileSize(fileSize))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()

                        // Time remaining
                        Text(formatRemainingTime(progress: isPlaying ? safeProgress(podcastPlayer.currentTime, podcastPlayer.duration) : progress, duration: episode.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Favorite button
            Button(action: {
                viewModel.toggleFavorite(for: episode)
            }) {
                Image(systemName: episode.state.isFavorite ? "star.fill" : "star")
                    .foregroundColor(episode.state.isFavorite ? .yellow : .gray)
                    .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(PlainButtonStyle())

            // Download/Delete button
            Button(action: {
                if viewModel.currentTab == 3 && episode.state.isDownloaded {
                    showingDeleteConfirmation = true
                } else if !isDownloading && !episode.state.isDownloaded {
                    isDownloading = true
                    viewModel.downloadEpisode(episode) { result in
                        DispatchQueue.main.async {
                            isDownloading = false
                            // Handle result if needed
                        }
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .fill(episode.state.isDownloaded ? Color.blue : Color.clear)
                        .frame(width: buttonSize, height: buttonSize)

                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: buttonSize, height: buttonSize)

                    if viewModel.currentTab == 3 && episode.state.isDownloaded {
                        Image(systemName: "trash")
                            .foregroundColor(.white)
                    } else if isDownloading {
                        Circle()
                            .trim(from: 0, to: CGFloat(viewModel.downloadProgress[episode.id] ?? 0))
                            .stroke(Color.blue, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                            .frame(width: buttonSize, height: buttonSize)

                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.gray)
                    } else if episode.state.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(PlainButtonStyle())
            .alert(isPresented: $showingDeleteConfirmation) {
                Alert(
                    title: Text("Delete Downloaded Episode"),
                    message: Text("Are you sure you want to delete this downloaded episode? This will not affect its favorite status."),
                    primaryButton: .destructive(Text("Delete")) {
                        viewModel.deleteDownloadedEpisode(episode)
                    },
                    secondaryButton: .cancel()
                )
            }

            // Play/Pause button
            Button(action: isPlaying ? onStop : onPlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: buttonSize, height: buttonSize)
                    .foregroundColor(.blue)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 8)
        .onAppear {
            // Update progress when the view appears
            progress = viewModel.getProgress(for: episode)
        }
    }

    // Helper method to format the date
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // Helper method to format file size
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // Helper method to safely calculate progress
    private func safeProgress(_ currentTime: Double, _ duration: Double) -> Double {
        guard duration > 0, currentTime.isFinite else {
            return 0.0
        }
        return currentTime / duration
    }

    // Helper method to format the remaining time based on progress and duration
    private func formatRemainingTime(progress: Double, duration: TimeInterval) -> String {
        guard progress.isFinite else {
            return "Unknown"
        }
        let remainingTime = (1 - progress) * duration
        let minutes = Int(remainingTime) / 60
        let seconds = Int(remainingTime) % 60
        return String(format: "%d:%02d remaining", minutes, seconds)
    }
}



struct PodcastArtworkView: View {
    let artworkUrl: String?
    
    var body: some View {
        Group {
            if let artworkUrl = artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
            } else {
                Image(systemName: "mic")
                    .resizable()
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.blue)
            }
        }
        .frame(width: 60, height: 60)
        .cornerRadius(8)
    }
}

struct PlayButton: View {
    let isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    
    var body: some View {
        Button(action: isPlaying ? onStop : onPlay) {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .resizable()
                .frame(width: 30, height: 30)
                .foregroundColor(.blue)
        }
    }
}

struct EmptyPodcastView: View {
    @Binding var showingAddPodcast: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .foregroundColor(.blue)
            
            Text("No podcasts added yet")
                .font(.headline)
            
            Button("Add Your First Podcast") {
                showingAddPodcast = true
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
    }
}

struct ErrorView: View {
    let message: String
    
    var body: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 50)
                .foregroundColor(.red)
            
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding()
        }
    }
}

struct PodcastPlayerView: View {
    @ObservedObject var viewModel: PodcastViewModel
    @Environment(\.presentationMode) var presentationMode
    let feed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var currentEpisodeIndex = 0
    @State private var selectedTab = 0 // Start with "All" tab
    @State private var seekPosition: Double = 0
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastPlayerView")
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation bar
            HStack {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                
                Spacer()
                
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                
                Spacer()
                
                // This empty view balances the back button
                Color.clear
                    .frame(width: 60, height: 1)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(UIColor.systemBackground))
            .shadow(color: Color.gray.opacity(0.3), radius: 2, x: 0, y: 1)
        }
        VStack(spacing: 10) {
            Text(feed.title)
                .font(.title)
                .padding(.top)
                .onAppear {
                    viewModel.fetchEpisodes(for: feed) { _ in
                        viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
                    }
                }
            
                .onAppear {
                    os_log("PodcastPlayerView appeared for feed: %@", log: log, type: .info, feed.title)
                }
            
            if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
                .frame(width: 150, height: 150)
                .cornerRadius(10)
                .onAppear {
                    os_log("Artwork loaded for feed: %@", log: log, type: .info, feed.title)
                }
            }
            
            nowPlayingView
            
            Picker("", selection: $selectedTab) {
                Text("All").tag(0)
                Text("Unplayed").tag(1)
                Text("Favorite").tag(2)
                Text("Downloads").tag(3)
            }
            .onAppear {
                viewModel.fetchEpisodes(for: feed) { _ in
                    viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(feed.title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .onAppear {
                viewModel.fetchEpisodes(for: feed) { _ in
                    viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
                }
            }
            .onChange(of: selectedTab) { newValue in
                viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: newValue)
            }
            
            Divider()
                .frame(height: 2)
                .background(Color.blue)
                .padding(.horizontal, 20)
            
            episodeList
        }
        .onAppear {
            viewModel.fetchEpisodes(for: feed) { _ in
                viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
            }
        }
    }
    
    private var nowPlayingView: some View {
        Group {
            if let currentEpisode = podcastPlayer.currentEpisode, currentEpisode.feedId == feed.id {
                VStack(spacing: 5) {
                    Text(currentEpisode.title)
                        .font(.headline)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                    
                    playerControls
                    
                    progressSlider
                        .padding(.horizontal, 20)
                    timeLabels
                        .padding(.horizontal, 20)
                }
            } else {
                Text("No episode playing")
                    .font(.headline)
                    .padding()
            }
        }
    }
    
    private var playerControls: some View {
        HStack(spacing: 30) {
            Button(action: podcastPlayer.skipBackward) {
                Image(systemName: "gobackward.15")
                    .resizable()
                    .frame(width: 30, height: 30)
            }
            
            Button(action: podcastPlayer.togglePlayPause) {
                Image(systemName: podcastPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 60, height: 60)
            }
            
            Button(action: podcastPlayer.skipForward) {
                Image(systemName: "goforward.15")
                    .resizable()
                    .frame(width: 30, height: 30)
            }
        }
    }
    
    private var progressSlider: some View {
        Slider(value: $seekPosition, in: 0...max(podcastPlayer.duration, 1), onEditingChanged: { editing in
            if !editing {
                podcastPlayer.seek(to: seekPosition)
            }
        })
        .onChange(of: podcastPlayer.currentTime) { newValue in
            seekPosition = newValue
        }
    }
    
    private var timeLabels: some View {
        HStack {
            Text(formatTime(podcastPlayer.currentTime))
            Spacer()
            Text(formatTime(podcastPlayer.duration))
        }
        .font(.caption)
    }
    
    private var episodeList: some View {
        List {
            ForEach(viewModel.currentEpisodes, id: \.compositeID) { episode in
                EpisodeRowView(
                    episode: episode,
                    isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                    onPlay: {
                        playEpisode(episode, feed: feed)
                    },
                    onStop: {
                        podcastPlayer.togglePlayPause()
                    },
                    viewModel: viewModel,
                    podcastPlayer: podcastPlayer
                )
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        if podcastPlayer.currentEpisode?.id == episode.id {
            podcastPlayer.togglePlayPause()
        } else {
            podcastPlayer.playEpisode(episode, feed: feed)
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct PodcastList: View {
    let feeds: [PodcastFeed]
    @ObservedObject var podcastPlayer: PodcastPlayer
    let onPlay: (PodcastFeed) -> Void
    let onDelete: (PodcastFeed) -> Void
    @Binding var selectedPodcast: PodcastFeed? // Use a binding to update the selectedPodcast
    
    var body: some View {
        List {
            ForEach(feeds) { feed in
                PodcastRowView(
                    feed: feed,
                    isPlaying: podcastPlayer.currentEpisode?.feedId == feed.id && podcastPlayer.isPlaying,
                    onPlay: { onPlay(feed) }, // Use the passed onPlay closure
                    onStop: { podcastPlayer.togglePlayPause() },
                    onTap: { selectedPodcast = feed } // Update the binding when a podcast is selected
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
}



