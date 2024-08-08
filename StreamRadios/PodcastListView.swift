//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI

struct PodcastListView: View {
    @StateObject private var viewModel = PodcastViewModel()
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    
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
                            NavigationLink(destination: PodcastEpisodesView(viewModel: viewModel, feed: feed)) {
                                PodcastRowView(feed: feed)
                            }
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
}

struct PodcastRowView: View {
    let feed: PodcastFeed
    
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
        }
    }
}

struct PodcastEpisodesView: View {
    @ObservedObject var viewModel: PodcastViewModel
    let feed: PodcastFeed
    
    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
            } else if let error = viewModel.error {
                Text(error)
                    .foregroundColor(.red)
            } else if viewModel.currentEpisodes.isEmpty {
                Text("No episodes found")
            } else {
                List(viewModel.currentEpisodes) { episode in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(episode.title)
                            .font(.headline)
                        Text(episode.description)
                            .font(.subheadline)
                            .lineLimit(2)
                        HStack {
                            Text(formatDate(episode.publicationDate))
                                .font(.caption)
                            Spacer()
                            Text(formatDuration(episode.duration))
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                    .onTapGesture {
                        print("Selected episode: \(episode.title)")
                    }
                }
            }
        }
        .navigationTitle(feed.title)
        .onAppear {
            viewModel.fetchEpisodes(for: feed)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
}


