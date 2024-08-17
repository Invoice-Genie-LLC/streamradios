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
    let progress: Double
    let onPlay: () -> Void
    let onStop: () -> Void
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var isFavorite: Bool
    @State private var isDownloaded: Bool
    @State private var isDownloading: Bool = false

    init(episode: PodcastEpisode, isPlaying: Bool, progress: Double, onPlay: @escaping () -> Void, onStop: @escaping () -> Void, viewModel: PodcastViewModel, podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.progress = progress
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
        _isFavorite = State(initialValue: episode.state.isFavorite)
        _isDownloaded = State(initialValue: episode.state.isDownloaded)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(formatDate(episode.publicationDate))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if progress > 0.0 && progress < 1.0 {
                    ProgressView(value: progress)
                        .accentColor(.blue)
                    
                    HStack {
                        Text(formatRemainingTime(progress: progress, duration: episode.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            statusLabel
            
            Spacer()

            Button(action: {
                isFavorite.toggle()
                viewModel.toggleFavorite(for: episode)
            }) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(isFavorite ? .yellow : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer().frame(width: 16)
            
            Button(action: {
                if !isDownloaded {
                    isDownloading = true
                    viewModel.downloadEpisode(episode) { result in
                        DispatchQueue.main.async {
                            isDownloading = false
                            switch result {
                            case .success(let updatedEpisode):
                                isDownloaded = updatedEpisode.state.isDownloaded
                            case .failure(let error):
                                print("Download failed: \(error)")
                            }
                        }
                    }
                } else {
                    // Handle already downloaded state
                }
            }) {
                if isDownloading {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(isDownloaded ? .blue : .gray)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Spacer().frame(width: 16)
            
            Button(action: {
                if isPlaying {
                    onStop()
                } else {
                    onPlay()
                }
            }) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.blue)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 8)
    }

    private var statusLabel: some View {
        Group {
            if progress == 0 {
                Text("New")
                    .font(.caption)
                    .padding(4)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(4)
            } else if progress > 0 && progress < 1 {
                Text("In Progress")
                    .font(.caption)
                    .padding(4)
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(4)
            } else {
                Text("Played")
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(4)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatRemainingTime(progress: Double, duration: TimeInterval) -> String {
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
    let feed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var currentEpisodeIndex = 0
    @State private var selectedTab = 0 // Start with "All" tab
    @State private var seekPosition: Double = 0
    @State private var lastLoggedSeekPosition: Double = 0
    private let seekThreshold: Double = 1.0
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastPlayerView")

    var body: some View {
        VStack(spacing: 10) {
            Text(feed.title)
                .font(.title)
                .padding(.top)
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
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
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
        .disabled(podcastPlayer.duration == 0)
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
            ForEach(viewModel.currentEpisodes, id: \.id) { episode in
                EpisodeRowView(
                    episode: episode,
                    isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                    progress: viewModel.getProgress(for: episode),
                    onPlay: {
                        playEpisode(episode, feed: feed)
                    },
                    onStop: {
                        podcastPlayer.togglePlayPause()
                    },
                    viewModel: viewModel, // Pass the viewModel correctly
                    podcastPlayer: podcastPlayer // Pass the podcastPlayer correctly
                )
            }
        }
        .listStyle(PlainListStyle())
    }

    private func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        if podcastPlayer.currentEpisode?.id == episode.id {
            // If it's the same episode, just toggle play/pause
            podcastPlayer.togglePlayPause()
        } else {
            // If it's a different episode, play it from the beginning or saved progress
            podcastPlayer.playEpisode(episode, feed: feed)
        }
    }

    var filteredEpisodes: [PodcastEpisode] {
        viewModel.currentEpisodes
    }

    private func loadEpisodes() {
        viewModel.fetchEpisodes(for: feed) { _ in
            updateFilteredEpisodes()
        }
    }
    
    private func updateFilteredEpisodes() {
        switch selectedTab {
        case 0: // All
            viewModel.currentEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        case 1: // Unplayed
            viewModel.currentEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id && $0.state.progress == 0 }
        case 2: // Favorite
            viewModel.currentEpisodes = viewModel.favoriteEpisodes.filter { $0.feedId == feed.id }
        case 3: // Downloads
            viewModel.currentEpisodes = viewModel.downloadedEpisodes.filter { $0.feedId == feed.id }
        default:
            viewModel.currentEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        }

        viewModel.currentEpisodes.sort { $0.publicationDate > $1.publicationDate }

        // Log to ensure progress is correctly calculated and included
        for episode in viewModel.currentEpisodes {
            print("Episode: \(episode.title), Progress: \(episode.state.progress)")
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



