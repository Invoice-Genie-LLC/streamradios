//
//  MainTabView.swift
//  StreamRadios
//
//  Created by AI Assistant
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @StateObject private var radioViewModel = RadioStationViewModel()
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var alertManager = AlertManager()
    @State private var selectedTab: MainTab = .radio
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Radio Tab
            NavigationView {
                RadioMainView()
                    .environmentObject(radioViewModel)
                    .environmentObject(radioPlayer)
                    .environmentObject(alertManager)
            }
            .tabItem {
                Image(systemName: MainTab.radio.systemImageName)
                Text(MainTab.radio.title)
            }
            .tag(MainTab.radio)
            
            // Podcasts Tab
            NavigationView {
                PodcastMainView()
                    .environmentObject(podcastViewModel)
                    .environmentObject(podcastPlayer)
                    .environmentObject(radioPlayer)
            }
            .tabItem {
                Image(systemName: MainTab.podcasts.systemImageName)
                Text(MainTab.podcasts.title)
            }
            .tag(MainTab.podcasts)
            
            // Settings Tab
            NavigationView {
                SettingsView()
                    .environmentObject(radioPlayer)
                    .environmentObject(podcastPlayer)
                    .environmentObject(radioViewModel)
            }
            .tabItem {
                Image(systemName: MainTab.settings.systemImageName)
                Text(MainTab.settings.title)
            }
            .tag(MainTab.settings)
        }
        .accentColor(.primary)
    }
}

// Wrapper for the existing ContentView functionality
struct RadioMainView: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var alertManager: AlertManager
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var isAddStationViewPresented = false
    @State private var isPlayerSheetPresented = false
    @State private var showSideMenu = false
    @State private var isEditingMode = false
    @State private var isEditingStation = false
    @State private var selectedStationForEdit: RadioStation?
    @State private var bitrateMessage = "Loading bitrate information..."
    @State private var showAlertForCountryBeforeAddingStation = false
    @State private var activeSheet: ActiveSheet?
    @State private var selectedTab: RadioTab = .all
    @State private var selectedPodcast: PodcastFeed?
    @State private var showPodcastListView = false
    @State private var seekPosition: Double = 0
    @State private var showPodcastPlayerSheet = false
    @State private var showAllEpisodes = false
    @State private var scrollToEpisodeID: String?
    
    var body: some View {
        ContentView()
            .environmentObject(viewModel)
            .environmentObject(alertManager)
            .environmentObject(podcastPlayer)
    }
}

// New Podcast Main View that matches the radio station design
struct PodcastMainView: View {
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @EnvironmentObject var podcastPlayer: PodcastPlayer
    @EnvironmentObject var radioPlayer: RadioPlayer
    @State private var searchText = ""
    @State private var selectedFilter: PodcastFilter = .all
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var selectedPodcast: PodcastFeed?
    @State private var isEditing = false
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var podcastToEdit: PodcastFeed?
    @State private var showingEditPodcast = false
    @State private var editPodcastTitle = ""
    @State private var editPodcastURL = ""
    @State private var refreshID = UUID()
    
    private let miniPlayerHeight: CGFloat = 60
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Top filter bar
                filterBar
                
                // Search bar
                searchBar
                
                // Podcast list
                podcastList
                    .padding(.bottom, podcastPlayer.currentEpisode != nil ? miniPlayerHeight : 0)
            }
            .navigationTitle("Podcasts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        isEditing.toggle()
                        if !isEditing {
                            podcastViewModel.saveFeedOrder()
                            refreshID = UUID()
                        }
                    }) {
                        Text(isEditing ? "Done" : "Edit")
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !isEditing {
                        Button(action: podcastViewModel.sortFeedsAlphabetically) {
                            Image(systemName: podcastViewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                        }
                        Button(action: { showingAddPodcast = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .onAppear {
                podcastViewModel.loadFeedOrder()
                podcastViewModel.fetchPodcastFeeds()
            }
            .id(refreshID)
            
            // Mini Player
            if podcastPlayer.isPlaying && !radioPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                MiniPlayerView(
                    podcastPlayer: podcastPlayer,
                    viewModel: podcastViewModel,
                    selectedPodcast: $selectedPodcast,
                    onListButtonTap: {
                        if let currentFeed = podcastPlayer.currentFeed {
                            selectedPodcast = currentFeed
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
                viewModel: podcastViewModel,
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
        .alert(isPresented: $podcastViewModel.showNoEpisodesAlert) {
            Alert(
                title: Text("No Episodes in Progress"),
                message: Text(podcastViewModel.noEpisodesAlertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                podcastViewModel.deletePodcastFeed(podcast)
            }
        } message: { podcast in
            Text("Are you sure you want to delete '\(podcast.title)'? This action cannot be undone.")
        }
    }
    
    private var filterBar: some View {
        HStack(spacing: 16) {
            ForEach(PodcastFilter.allCases, id: \.self) { filter in
                Button(action: {
                    selectedFilter = filter
                }) {
                    Text(filter.title)
                        .font(.subheadline)
                        .fontWeight(selectedFilter == filter ? .semibold : .regular)
                        .foregroundColor(selectedFilter == filter ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedFilter == filter ? Color.accentColor.opacity(0.1) : Color.clear
                        )
                        .cornerRadius(8)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
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
                        searchText = String(newValue.prefix(100))
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
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredPodcasts, id: \.id) { podcast in
                    PodcastStationRowView(
                        podcast: podcast,
                        isPlaying: podcastPlayer.currentEpisode?.feedId == podcast.id && podcastPlayer.isPlaying,
                        onTap: {
                            if isEditing {
                                podcastToEdit = podcast
                                editPodcastTitle = podcast.title
                                editPodcastURL = podcast.url
                                showingEditPodcast = true
                            } else {
                                selectedPodcast = podcast
                            }
                        },
                        onPlay: {
                            podcastPlayer.playLastEpisodeForFeed(podcast)
                        },
                        isEditMode: isEditing
                    )
                    .contextMenu {
                        Button("Edit") {
                            podcastToEdit = podcast
                            editPodcastTitle = podcast.title
                            editPodcastURL = podcast.url
                            showingEditPodcast = true
                        }
                        Button("Delete", role: .destructive) {
                            podcastToDelete = podcast
                            showingDeleteConfirmation = true
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal)
        }
    }
    
    private var filteredPodcasts: [PodcastFeed] {
        var podcasts = podcastViewModel.podcastFeeds
        
        // Apply search filter
        if !searchText.isEmpty {
            podcasts = podcasts.filter { podcast in
                podcast.title.lowercased().contains(searchText.lowercased()) ||
                (podcast.descriptionText?.lowercased().contains(searchText.lowercased()) ?? false)
            }
        }
        
        // Apply category filter
        switch selectedFilter {
        case .all:
            break
        case .favorites:
            // Filter for podcasts with favorite episodes
            podcasts = podcasts.filter { podcast in
                podcastViewModel.allEpisodes.contains { episode in
                    episode.feedId == podcast.id && episode.state.isFavorite
                }
            }
        case .downloaded:
            // Filter for podcasts with downloaded episodes
            podcasts = podcasts.filter { podcast in
                podcastViewModel.allEpisodes.contains { episode in
                    episode.feedId == podcast.id && episode.state.isDownloaded
                }
            }
        }
        
        return podcasts
    }
    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        podcastViewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
    }
    
    private func updatePodcast(_ updatedPodcast: PodcastFeed) {
        podcastViewModel.updatePodcastFeed(updatedPodcast)
        showingEditPodcast = false
        editPodcastTitle = ""
        editPodcastURL = ""
        podcastToEdit = nil
        refreshID = UUID()
    }
}

enum PodcastFilter: CaseIterable {
    case all
    case favorites 
    case downloaded
    
    var title: String {
        switch self {
        case .all:
            return "All"
        case .favorites:
            return "Favorites"
        case .downloaded:
            return "Downloaded"
        }
    }
}

// New podcast row view that matches the radio station design
struct PodcastStationRowView: View {
    let podcast: PodcastFeed
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlay: () -> Void
    let isEditMode: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Podcast artwork/icon
            PodcastIconView(
                iconData: podcast.iconData,
                imageData: podcast.imageData,
                artworkUrl: podcast.artworkUrl
            )
            .frame(width: 60, height: 60)
            .cornerRadius(8)
            
            // Podcast info
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                if let description = podcast.descriptionText {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Podcast")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Play/Signal indicator
            if isPlaying {
                HStack(spacing: 2) {
                    ForEach(0..<4) { index in
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: 3, height: CGFloat.random(in: 8...20))
                            .animation(
                                Animation.easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(index) * 0.1),
                                value: isPlaying
                            )
                    }
                }
                .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .onTapGesture {
            onTap()
        }
    }
} 