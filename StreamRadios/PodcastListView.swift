//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI
import Combine

import SwiftUI

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
    
    var filteredPodcasts: [PodcastFeed] {
        if searchText.isEmpty {
            return viewModel.podcastFeeds
        } else {
            return viewModel.podcastFeeds.filter { $0.title.lowercased().contains(searchText.lowercased()) }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                searchBar
                
                List {
                    ForEach(filteredPodcasts) { feed in
                        PodcastRowView(
                            feed: feed,
                            isPlaying: podcastPlayer.currentEpisode?.feed.id == feed.id && podcastPlayer.isPlaying,
                            onPlay: { playLatestEpisode(for: feed) },
                            onStop: { podcastPlayer.togglePlayPause() },
                            onTap: { selectedPodcast = feed }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                podcastToDelete = feed
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
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
                    podcastPlayer.playEpisode(latestEpisode)
                }
            case .failure(let error):
                print("Failed to fetch episodes: \(error.localizedDescription)")
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
    let progress: Double?
    let onPlay: () -> Void
    let onStop: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                
                Text(formatDate(episode.publicationDate))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let progress = progress {
                    ProgressView(value: progress)
                        .accentColor(.blue)
                    
                    Text(formatRemainingTime(progress: progress))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            statusLabel
            
            PlayButton(isPlaying: isPlaying, onPlay: onPlay, onStop: onStop)
        }
    }
    
    private var statusLabel: some View {
        Group {
            if let progress = progress {
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
            } else {
                Text("New")
                    .font(.caption)
                    .padding(4)
                    .background(Color.green)
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
    
    private func formatRemainingTime(progress: Double) -> String {
            guard progress.isFinite, episode.duration.isFinite,
                  progress >= 0, progress <= 1, episode.duration >= 0 else {
                return "Invalid duration"
            }

            let remainingTime = (1 - progress) * episode.duration
            guard remainingTime.isFinite else {
                return "Invalid duration"
            }

            let minutes = Int(max(0, remainingTime) / 60)
            let seconds = Int(max(0, remainingTime).truncatingRemainder(dividingBy: 60))
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
    @State private var selectedTab = 1 // Start with "All" tab
    @State private var seekPosition: Double = 0
    
    var body: some View {
        VStack(spacing: 10) {
            Text(feed.title)
                .font(.title)
                .padding(.top)
            
            if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
                .frame(width: 150, height: 150)
                .cornerRadius(10)
            }
            
            nowPlayingView
            
            Picker("", selection: $selectedTab) {
                Text("All").tag(1)
                Text("Unplayed").tag(0)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            
            episodeList
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            loadEpisodes()
        }
        .onChange(of: podcastPlayer.currentTime) { newValue in
            if !podcastPlayer.isSeeking {
                seekPosition = newValue
            }
        }
    }
    
    private var nowPlayingView: some View {
        Group {
            if let currentEpisode = podcastPlayer.currentEpisode, currentEpisode.feed.id == feed.id {
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
        Slider(value: $seekPosition, in: 0...max(podcastPlayer.duration, 1)) { editing in
            if editing {
                podcastPlayer.isSeeking = true
            } else {
                podcastPlayer.isSeeking = false
                podcastPlayer.seek(to: seekPosition)
            }
        }
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
            List(filteredEpisodes) { episode in
                EpisodeRowView(
                    episode: episode,
                    isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                    progress: selectedTab == 1 ? podcastPlayer.progress[episode.id] : nil,
                    onPlay: {
                        podcastPlayer.playEpisode(episode)
                        if selectedTab == 0 {
                            selectedTab = 1 // Switch to "All" tab
                        }
                    },
                    onStop: { podcastPlayer.togglePlayPause() }
                )
            }
            .listStyle(PlainListStyle())
        }
        
        var filteredEpisodes: [PodcastEpisode] {
            if selectedTab == 1 {
                return viewModel.currentEpisodes
            } else {
                return viewModel.currentEpisodes.filter {
                    return podcastPlayer.progress[$0.id] == nil || podcastPlayer.progress[$0.id] == 0
                }
            }
        }
        
        private func loadEpisodes() {
            viewModel.fetchEpisodes(for: feed) { _ in }
        }
        
        private func formatTime(_ time: Double) -> String {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
