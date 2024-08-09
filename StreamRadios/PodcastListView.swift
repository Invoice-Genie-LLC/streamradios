//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI
import Combine

struct PodcastListView: View {
    @StateObject private var viewModel = PodcastViewModel()
    @EnvironmentObject var radioPlayer: RadioPlayer
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var selectedPodcast: PodcastFeed?
    @State private var searchText = ""
    var podcastProgress: [String: Int] = [:]
    
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
                            isPlaying: radioPlayer.currentPodcastEpisode?.feed.id == feed.id,
                            onPlay: { playLatestEpisode(for: feed) },
                            onStop: { radioPlayer.stopPodcast() },
                            onTap: { selectedPodcast = feed }
                        )
                    }
                    .onDelete(perform: deletePodcasts)
                }
                .listStyle(PlainListStyle())
            }
            .navigationTitle("Podcasts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddPodcast = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPodcast) {
                AddPodcastView(isPresented: $showingAddPodcast, title: $newPodcastTitle, url: $newPodcastURL, onAdd: addPodcast)
            }
            .sheet(item: $selectedPodcast) { podcast in
                PodcastPlayerView(viewModel: viewModel, feed: podcast, radioPlayer: radioPlayer)
            }
        }
    }
    
    private var searchBar: some View {
        TextField("Search podcasts", text: $searchText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(.horizontal)
    }
    
    private func deletePodcasts(at offsets: IndexSet) {
        offsets.forEach { index in
            let feedToDelete = filteredPodcasts[index]
            viewModel.deletePodcastFeed(feedToDelete)
        }
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
                    radioPlayer.playPodcastEpisode(latestEpisode)
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
            PodcastArtworkView(artworkUrl: feed.artworkUrl)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(feed.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            PlayButton(isPlaying: isPlaying, onPlay: onPlay, onStop: onStop)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}


struct EpisodeRowView: View {
    let episode: PodcastEpisode
    let isPlaying: Bool
    let progress: Double
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
                
                if progress > 0 {
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
    
    private func formatRemainingTime(progress: Double) -> String {
        let remainingTime = (1 - progress) * episode.duration
        let minutes = Int(remainingTime / 60)
        let seconds = Int(remainingTime.truncatingRemainder(dividingBy: 60))
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
    @ObservedObject var radioPlayer: RadioPlayer
    @State private var currentEpisodeIndex = 0
    @State private var selectedTab = 0
    @State private var seekPosition: Double = 0
    
    var filteredEpisodes: [PodcastEpisode] {
        if selectedTab == 0 {
            return viewModel.currentEpisodes.filter {
                return radioPlayer.podcastProgress[$0.id] == nil || radioPlayer.podcastProgress[$0.id] == 0
            }
        } else {
            return viewModel.currentEpisodes
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text(feed.title)
                .font(.title)
                .padding(.top)
            
            if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
                .frame(width: 200, height: 200)
                .cornerRadius(10)
            }
            
            if let currentEpisode = radioPlayer.currentPodcastEpisode, currentEpisode.feed.id == feed.id {
                Text(currentEpisode.title)
                    .font(.headline)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 10) {
                    HStack(spacing: 30) {
                        Button(action: radioPlayer.rewind) {
                            Image(systemName: "gobackward.15")
                                .resizable()
                                .frame(width: 30, height: 30)
                        }
                        
                        Button(action: togglePlayPause) {
                            Image(systemName: radioPlayer.isPodcastPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .resizable()
                                .frame(width: 60, height: 60)
                        }
                        
                        Button(action: radioPlayer.skipForward) {
                            Image(systemName: "goforward.15")
                                .resizable()
                                .frame(width: 30, height: 30)
                        }
                    }
                    
                    Slider(value: $seekPosition, in: 0...max(radioPlayer.currentPodcastDuration, 1)) { editing in
                        if editing {
                            radioPlayer.isSeeking = true
                        } else {
                            radioPlayer.isSeeking = false
                            radioPlayer.seek(to: seekPosition)
                        }
                    }
                    .disabled(radioPlayer.currentPodcastDuration == 0)
                    
                    HStack {
                        Text(formatTime(radioPlayer.currentPodcastTime))
                        Spacer()
                        Text(formatTime(radioPlayer.currentPodcastDuration))
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
            } else {
                Text("No episode playing")
                    .font(.headline)
                    .padding()
            }
            
            Picker("", selection: $selectedTab) {
                Text("Unplayed").tag(0)
                Text("All").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            
            List(filteredEpisodes) { episode in
                            EpisodeRowView(
                                episode: episode,
                                isPlaying: radioPlayer.currentPodcastEpisode?.id == episode.id,
                                progress: radioPlayer.podcastProgress[episode.id] ?? 0,
                                onPlay: { radioPlayer.playPodcastEpisode(episode) },
                                onStop: { radioPlayer.stopPodcast() }
                            )
                        }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            loadEpisodes()
        }
        .onChange(of: radioPlayer.currentPodcastTime) { newValue in
            if !radioPlayer.isSeeking {
                seekPosition = newValue
            }
        }
    }
    
    private func loadEpisodes() {
        viewModel.fetchEpisodes(for: feed) { _ in }
    }
    
    private func togglePlayPause() {
        if radioPlayer.isPodcastPlaying {
            radioPlayer.pausePodcast()
        } else {
            radioPlayer.playPodcast()
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension PodcastViewModel {
    func refreshAllPodcasts() async {
        // Implement the logic to refresh all podcasts
        // This might involve re-fetching RSS feeds for all podcasts
    }
}

