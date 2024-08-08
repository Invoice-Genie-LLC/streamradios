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
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @EnvironmentObject var radioPlayer: RadioPlayer
    @State private var selectedPodcast: PodcastFeed?
    @State private var isPlayerPresented = false
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                } else if let error = viewModel.error {
                    Text(error)
                        .foregroundColor(.red)
                } else if viewModel.podcastFeeds.isEmpty {
                    VStack {
                        Text("No podcasts added yet")
                        Button("Add Your First Podcast") {
                            showingAddPodcast = true
                        }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                } else {
                    List {
                        ForEach(viewModel.podcastFeeds) { feed in
                            PodcastRowView(
                                feed: feed,
                                isPlaying: radioPlayer.currentPodcastEpisode?.feed.id == feed.id,
                                onPlay: {
                                    playLatestEpisode(for: feed)
                                },
                                onStop: {
                                    radioPlayer.stopPodcast()
                                },
                                onTap: {
                                    selectedPodcast = feed
                                    isPlayerPresented = true
                                }
                            )
                        }
                        .onDelete(perform: deletePodcasts)
                    }
                }
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
    
    private func deletePodcasts(at offsets: IndexSet) {
        offsets.forEach { index in
            let feedToDelete = viewModel.podcastFeeds[index]
            viewModel.deletePodcastFeed(feedToDelete)
        }
    }
    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID(), title: newPodcastTitle, url: newPodcastURL)
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
        HStack {
            if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Color.gray
                }
                .frame(width: 50, height: 50)
                .cornerRadius(8)
            } else {
                Image(systemName: "mic")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.blue)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }
            
            VStack(alignment: .leading) {
                Text(feed.title)
                    .font(.headline)
                Text(feed.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .onTapGesture(perform: onTap)
            
            Spacer()
            
            Button(action: isPlaying ? onStop : onPlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.blue)
            }
        }
    }
}

struct PodcastPlayerView: View {
    @ObservedObject var viewModel: PodcastViewModel
    let feed: PodcastFeed
    @ObservedObject var radioPlayer: RadioPlayer
    @State private var currentEpisodeIndex = 0
    
    var body: some View {
        VStack {
            Text(feed.title)
                .font(.largeTitle)
                .padding()
            
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
                    .padding()
                
                HStack {
                    Button(action: previousEpisode) {
                        Image(systemName: "backward.fill")
                    }
                    
                    Button(action: togglePlayPause) {
                        Image(systemName: radioPlayer.isPodcastPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .resizable()
                            .frame(width: 50, height: 50)
                    }
                    
                    Button(action: nextEpisode) {
                        Image(systemName: "forward.fill")
                    }
                }
                .padding()
            } else {
                Text("No episode playing")
                    .font(.headline)
                    .padding()
            }
            
            List(viewModel.currentEpisodes) { episode in
                VStack(alignment: .leading) {
                    Text(episode.title)
                        .font(.headline)
                    Text(formatDate(episode.publicationDate))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .onTapGesture {
                    radioPlayer.playPodcastEpisode(episode)
                }
            }
        }
        .padding()
        .onAppear {
            loadEpisodes()
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
    
    private func nextEpisode() {
        guard !viewModel.currentEpisodes.isEmpty else { return }
        currentEpisodeIndex = (currentEpisodeIndex + 1) % viewModel.currentEpisodes.count
        radioPlayer.playPodcastEpisode(viewModel.currentEpisodes[currentEpisodeIndex])
    }
    
    private func previousEpisode() {
        guard !viewModel.currentEpisodes.isEmpty else { return }
        currentEpisodeIndex = (currentEpisodeIndex - 1 + viewModel.currentEpisodes.count) % viewModel.currentEpisodes.count
        radioPlayer.playPodcastEpisode(viewModel.currentEpisodes[currentEpisodeIndex])
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
