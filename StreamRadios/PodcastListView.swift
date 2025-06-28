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
    @EnvironmentObject private var viewModel: PodcastViewModel
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
    @EnvironmentObject private var radioStationViewModel: RadioStationViewModel
    @State private var scrollToEpisodeID: String?
    @State private var refreshID = UUID()
    @State private var dataCheckTimer: Timer?
    @State private var selectedTab: Tab = .podcast
    @State private var isPlayerSheetPresented = false
    
    // Edit functionality
    @State private var showingEditPodcast = false
    @State private var podcastToEdit: PodcastFeed?
    @State private var editPodcastTitle = ""
    @State private var editPodcastURL = ""
    @State private var isEditDataReady = false
    @State private var isPreparingEditData = false
    

    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    
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
                   } else {
                       // Show the podcast list when no podcast is selected
                       VStack(spacing: 0) {
                           instructionText
                           searchBar
                           podcastList
                       }
                   }
                   
                   // Global Player is now handled by ContentView overlay
                   // This ensures consistent player display across all tabs
               }
               .navigationTitle("Podcasts")
               .navigationBarTitleDisplayMode(.inline)
               .toolbar {
                   ToolbarItemGroup(placement: .navigationBarTrailing) {
                       if !isEditing {
                           Button(action: { viewModel.sortFeedsAlphabetically() }) {
                               Image(systemName: viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                           }
                           Button(action: { showingAddPodcast = true }) {
                               Image(systemName: "plus")
                           }
                       }
                   }
               }
               .onAppear(perform: onAppear)
               .onDisappear {
                   // Clean up timer and notification observer when view disappears
                   dataCheckTimer?.invalidate()
                   dataCheckTimer = nil
                   NotificationCenter.default.removeObserver(self, name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
               }
               .onChange(of: selectedPodcast) { _, newValue in
                   // When selectedPodcast is set from outside (like from ContentView),
                   // automatically show the episode list
                   if let podcast = newValue {
                       viewModel.fetchAllEpisodes(for: podcast)
                   }
               }
               .onChange(of: viewModel.podcastFeeds.count) { _, newCount in
                   // React to ALL feed count changes (including clearing)
                   print("🎯 UI: Detected feed count change to \(newCount) - refreshing view")
                   
                   if newCount > 0 {
                       // Cancel monitoring timer since data is now available
                       dataCheckTimer?.invalidate()
                       dataCheckTimer = nil
                   }
                   
                   // Always refresh when count changes (including when cleared to 0)
                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                       self.refreshID = UUID()
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
               .sheet(isPresented: Binding(
                   get: { showingEditPodcast && isEditDataReady },
                   set: { newValue in 
                       showingEditPodcast = newValue
                       if !newValue {
                           resetEditState()
                       }
                   }
               )) {
                   AddPodcastView(
                       isPresented: Binding(
                           get: { showingEditPodcast && isEditDataReady },
                           set: { newValue in 
                               showingEditPodcast = newValue
                               if !newValue {
                                   resetEditState()
                               }
                           }
                       ),
                       title: Binding(
                           get: { 
                               print("🔧 DEBUG: Getting title binding value: '\(editPodcastTitle)' (ready: \(isEditDataReady))")
                               return editPodcastTitle 
                           },
                           set: { newValue in 
                               print("🔧 DEBUG: Setting title binding to: '\(newValue)'")
                               editPodcastTitle = newValue 
                           }
                       ),
                       url: Binding(
                           get: { 
                               print("🔧 DEBUG: Getting URL binding value: '\(editPodcastURL)' (ready: \(isEditDataReady))")
                               return editPodcastURL 
                           },
                           set: { newValue in 
                               print("🔧 DEBUG: Setting URL binding to: '\(newValue)'")
                               editPodcastURL = newValue 
                           }
                       ),
                       podcastToEdit: podcastToEdit,
                       onAdd: { },
                       onUpdate: { updatedPodcast in
                           updatePodcast(updatedPodcast)
                       }
                   )
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
        VStack(spacing: 0) {
            // Editing mode header right above the list
            if isEditing {
                HStack {
                    Text("Drag to Reorder Podcasts")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.adaptiveSecondaryText)
                        .allowsHitTesting(false)
                    
                    Spacer()
                        .allowsHitTesting(false)
                    
                    Button("Done") {
                        isEditing = false
                        viewModel.saveFeedOrder()
                        refreshID = UUID()
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                
                // Separator line
                Rectangle()
                    .fill(Color.adaptiveSeparator)
                    .frame(height: 0.5)
            }
            
            List {
                if viewModel.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading podcast feeds...")
                    }
                    .foregroundColor(.adaptiveSecondaryText)
                    .padding()
                } else if viewModel.podcastFeeds.isEmpty {
                    Text("No podcast feeds available")
                        .foregroundColor(.adaptiveSecondaryText)
                        .italic()
                        .padding()
                }
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
                                    // In edit mode, prepare edit data reliably
                                    if !isPreparingEditData {
                                        prepareEditData(for: feed) { success in
                                            if success {
                                                showingEditPodcast = true
                                            } else {
                                                print("🔧 ERROR: Failed to prepare edit data for feed: \(feed.title)")
                                                // Show user feedback that edit failed
                                            }
                                        }
                                    }
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
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    // Long press activates sorting mode
                                    if !isEditing {
                                        // Stop any currently playing audio to prevent interference with sorting
                                        if podcastPlayer.isPlaying {
                                            podcastPlayer.pause()
                                        }
                                        
                                        // Also stop radio playback if it's currently playing
                                        let radioPlayer = RadioPlayer.shared
                                        if radioPlayer.isPlaying {
                                            radioPlayer.pause()
                                        }
                                        
                                        isEditing = true
                                        // Haptic feedback for long press
                                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                        impactFeedback.impactOccurred()
                                    }
                                }
                        )
                        .disabled(isEditing)
                        .opacity(isEditing ? 0.6 : 1.0)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isEditing {
                                Button(role: .destructive) {
                                    podcastToDelete = feed
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !isEditing {
                                Button {
                                    // Edit button action - use reliable edit data preparation
                                    if !isPreparingEditData {
                                        prepareEditData(for: feed) { success in
                                            if success {
                                                showingEditPodcast = true
                                            } else {
                                                print("🔧 ERROR: Failed to prepare swipe edit data for feed: \(feed.title)")
                                                // Show user feedback that edit failed
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Edit", systemImage: isPreparingEditData ? "hourglass" : "pencil")
                                }
                                .tint(.blue)
                            }
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
        .background(
            Color.clear
                .onTapGesture {
                    // Tap on background to exit edit mode
                    if isEditing {
                        isEditing = false
                        viewModel.saveFeedOrder()
                        refreshID = UUID()
                    }
                }
        )
    }
    
    private func moveFeeds(from source: IndexSet, to destination: Int) {
        viewModel.moveFeed(from: source, to: destination)
                refreshID = UUID()
        
        viewModel.refreshAllFeeds()
            viewModel.objectWillChange.send()
        }
    
    private func onAppear() {
        os_log("PodcastListView appeared", log: log, type: .info)
        print("🎯 UI: PodcastListView appeared - using environment object data")
        print("🎯 UI: Current feeds count: \(viewModel.podcastFeeds.count)")
        print("🎯 UI: Current feed order count: \(viewModel.podcastFeedOrder.count)")
        
        // Set up notification observer for fresh install data (with debouncing)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FreshInstallDataAvailable"),
            object: nil,
            queue: .main
        ) { _ in
            print("📢 UI: Received FreshInstallDataAvailable notification - refreshing view")
            
            // SwiftUI-compatible debouncing using DispatchQueue
            DispatchQueue.main.async {
                self.refreshID = UUID()
            }
            
            // Cancel any existing timer since data is now available
            self.dataCheckTimer?.invalidate()
            self.dataCheckTimer = nil
        }
        
                // Check if data is already available (in case we missed the notification)
        if viewModel.podcastFeeds.isEmpty {
            print("🔄 UI: No feeds found - starting minimal monitoring")
            
            // Start lightweight monitoring without heavy reload operations
            self.startFreshInstallDataMonitoring()
        } else {
            print("✅ UI: Data already available - \(viewModel.podcastFeeds.count) feeds found")
        }
    }
    
    private func startFreshInstallDataMonitoring() {
        // Cancel any existing timer
        dataCheckTimer?.invalidate()
        
        // Start a timer with reasonable interval to balance responsiveness and performance
        var checkCount = 0
        dataCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            checkCount += 1
            let feedCount = viewModel.podcastFeeds.count
            
            // Reduce logging frequency to avoid spam
            if checkCount % 5 == 1 {
                print("🔍 UI: Monitoring fresh install data - Feeds: \(feedCount) (check \(checkCount))")
            }
            
            if feedCount > 0 {
                print("🎯 UI: Fresh install data detected (\(feedCount) feeds) - refreshing view")
                DispatchQueue.main.async {
                    self.refreshID = UUID()
                    timer.invalidate()
                    self.dataCheckTimer = nil
                }
            } else if checkCount > 30 { // Stop after 9 seconds (30 * 0.3)
                print("🔄 UI: Stopping fresh install monitoring after timeout")
                timer.invalidate()
                self.dataCheckTimer = nil
            }
        }
    }
    

    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        viewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
    }
    
    // MARK: - Edit Helper Methods
    
    private func prepareEditData(for feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
        print("🔧 DEBUG: Preparing edit data for feed: '\(feed.title)' (ID: \(feed.id))")
        
        // Prevent multiple concurrent preparations
        guard !isPreparingEditData else {
            print("🔧 WARNING: Already preparing edit data, ignoring duplicate request")
            return
        }
        
        isPreparingEditData = true
        
        // First, check if the feed data is already valid
        if !feed.title.isEmpty && !feed.url.isEmpty {
            print("🔧 DEBUG: Feed data is valid, proceeding with edit")
            podcastToEdit = feed
            editPodcastTitle = feed.title
            editPodcastURL = feed.url
            isEditDataReady = true
            isPreparingEditData = false
            completion(true)
            return
        }
        
        // Data is invalid, try to reload from Core Data
        print("🔧 WARNING: Feed data invalid - Title: '\(feed.title)', URL: '\(feed.url)'")
        print("🔧 DEBUG: Reloading feeds from Core Data...")
        
        viewModel.loadFeedsFromCoreData()
        
        // Wait for data to load and then check again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { // Increased delay to ensure data loads
            // Find the refreshed feed
            if let refreshedFeed = self.viewModel.podcastFeeds.first(where: { $0.id == feed.id }) {
                print("🔧 DEBUG: Found refreshed feed - Title: '\(refreshedFeed.title)', URL: '\(refreshedFeed.url)'")
                
                if !refreshedFeed.title.isEmpty && !refreshedFeed.url.isEmpty {
                    print("🔧 SUCCESS: Refreshed feed data is valid")
                    self.podcastToEdit = refreshedFeed
                    self.editPodcastTitle = refreshedFeed.title
                    self.editPodcastURL = refreshedFeed.url
                    self.isEditDataReady = true
                    self.isPreparingEditData = false
                    completion(true)
                } else {
                    print("🔧 ERROR: Refreshed feed data is still invalid")
                    self.isEditDataReady = false
                    self.isPreparingEditData = false
                    completion(false)
                }
            } else {
                print("🔧 ERROR: Could not find feed with ID: \(feed.id) after reload")
                self.isEditDataReady = false
                self.isPreparingEditData = false
                completion(false)
            }
        }
    }
    
    private func resetEditState() {
        podcastToEdit = nil
        editPodcastTitle = ""
        editPodcastURL = ""
        isEditDataReady = false
        isPreparingEditData = false
    }

    private func updatePodcast(_ updatedPodcast: PodcastFeed) {
        print("🔧 DEBUG: PodcastListView - Updating podcast - ID: \(updatedPodcast.id), Title: '\(updatedPodcast.title)', URL: '\(updatedPodcast.url)'")
        
        // Update the podcast feed
        viewModel.updatePodcastFeed(updatedPodcast)
        
        // Clean up edit state immediately
        resetEditState()
        
        // Force UI refresh by triggering objectWillChange
        DispatchQueue.main.async {
            self.viewModel.objectWillChange.send()
            self.refreshID = UUID() // Force view refresh to show updated data
        }
        
        print("🔧 DEBUG: PodcastListView - Edit completed and UI refreshed")
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
    
    // Optimized button text with minimal computation and no logging for performance
    private var buttonText: String {
        // Quick check for last played episode (most efficient)
        if viewModel.lastPlayedEpisodes[feed.id] != nil {
            return "Resume Episode"
        }
        
        // Default case - avoid expensive episode iteration for UI performance
        return "Play Latest"
    }
    
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(alignment: .top, spacing: 12) {
                    // Use PodcastIconView for immediate loading from Core Data
                    PodcastIconView(
                        iconData: feed.iconData,
                        imageData: feed.imageData,
                        artworkUrl: feed.artworkUrl
                    )
                    .frame(width: iconSize, height: iconSize)
                    .onTapGesture {
                        onTap()
                    }
                
                VStack(alignment: .leading, spacing: 4) {
                    if isExpanded {
                        Text(feed.descriptionText ?? "No description available")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .onTapGesture {
                                onTap()
                            }
                    } else {
                        Text(feed.descriptionText ?? "No description available")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
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
                
                if !isEditMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: arrowSize))
                        .foregroundColor(.adaptiveSecondaryText)
                        .frame(width: arrowSize, height: iconSize)
                        .onTapGesture {
                            onTap()
                        }
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
        
        print("🎯 DEBUG: Starting playLastPlayedEpisode for feed: \(feed.title)")
        print("🎯 DEBUG: lastPlayedEpisodes dictionary: \(viewModel.lastPlayedEpisodes)")
        
        // First try to get episodes from the feed object
        var feedEpisodes = feed.episodes
        
        // If the feed object doesn't have episodes loaded, try to get them from viewModel
        if feedEpisodes.isEmpty {
            print("⚠️ Feed object has no episodes, trying viewModel.allEpisodes...")
            feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        }
        
        // If still no episodes, try loading from Core Data
        if feedEpisodes.isEmpty {
            print("⚠️ No episodes found anywhere, loading from Core Data...")
            Task {
                await viewModel.loadEpisodesForFeed(feed.id, isInitialLoad: true)
                await MainActor.run {
                    self.attemptPlayback()
                }
            }
            return
        }
        
        print("🔍 Found \(feedEpisodes.count) episodes in feed: \(feed.title)")
        
        // Update episode states with EpisodeStateManager data for accuracy
        feedEpisodes = feedEpisodes.map { episode in
            var updatedEpisode = episode
            updatedEpisode.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            return updatedEpisode
        }
        
        // Case 1: Resume Episode - when there's a specific last played episode
        if let lastPlayedEpisodeId = viewModel.lastPlayedEpisodes[feed.id] {
            print("🔍 Looking for last played episode ID: \(lastPlayedEpisodeId)")
            if let lastPlayedEpisode = feedEpisodes.first(where: { $0.id == lastPlayedEpisodeId }) {
                print("🎯 Playing last played episode: \(lastPlayedEpisode.title)")
                podcastPlayer.playEpisode(lastPlayedEpisode, feed: feed)
                return
            } else {
                print("⚠️ Last played episode ID '\(lastPlayedEpisodeId)' not found in episodes list")
                print("🔍 Available episode IDs: \(feedEpisodes.map { $0.id })")
            }
        }
        
        // Case 2: Resume Episode - when there are episodes with any progress but no specific last played
        let episodesWithProgress = feedEpisodes.filter { $0.state.progress > 0 }
        if !episodesWithProgress.isEmpty {
            print("🔍 Found \(episodesWithProgress.count) episodes with progress")
            for episode in episodesWithProgress {
                print("  - \(episode.title): progress \(episode.state.progress)")
            }
            // Play the episode with the highest progress, or most recently started if tied
            let sortedByProgress = episodesWithProgress.sorted { episode1, episode2 in
                if episode1.state.progress != episode2.state.progress {
                    return episode1.state.progress > episode2.state.progress
                }
                return episode1.publicationDate > episode2.publicationDate
            }
            if let mostProgressedEpisode = sortedByProgress.first {
                print("🎯 Playing most progressed episode: \(mostProgressedEpisode.title) (progress: \(mostProgressedEpisode.state.progress))")
                podcastPlayer.playEpisode(mostProgressedEpisode, feed: feed)
                return
            }
        }
        
        // Case 3: Play Latest - no episodes have been previously played
        // Play the most recent episode (newest by publication date)
        if let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first {
            print("🎯 Playing latest episode: \(latestEpisode.title)")
            podcastPlayer.playEpisode(latestEpisode, feed: feed)
            return
        }
        
        // Fallback: Use the existing logic if no episodes found
        print("⚠️ No episodes found, using fallback")
        podcastPlayer.playLastEpisodeForFeed(feed)
    }
    
    private func attemptPlayback() {
        // Retry the playback after episodes are loaded
        playLastPlayedEpisode()
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
                    .foregroundColor(.adaptivePrimaryText)
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
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    private let buttonSize: CGFloat = 22
    private let rowHeight: CGFloat = 70
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        viewModel.downloadProgress[episode.id] != nil && viewModel.downloadProgress[episode.id]! > 0 && viewModel.downloadProgress[episode.id]! < 1
    }
    
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
                        .foregroundColor(episode.state.isPlayed || progress >= 0.99 ? .adaptiveSecondaryText : (isPlaying ? .blue : .green))
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
                                .foregroundColor(.adaptiveSecondaryText)
                            
                            Text(timeInfo)
                                .font(.system(size: 12))
                                .foregroundColor(.adaptiveSecondaryText)
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
                            .foregroundColor(episode.state.isFavorite ? .blue : .adaptiveSecondaryText)
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    
                    // Download button - simplified
                    Group {
                        if viewModel.currentTab == 2 && episode.state.isDownloaded {
                            // Downloads tab: Show trash can for downloaded episodes
                            Button(action: {
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .frame(width: buttonSize, height: buttonSize)
                            }
                        } else if (viewModel.currentTab == 0 || viewModel.currentTab == 1) && episode.state.isDownloaded {
                            // All tab and Favorites tab: Show filled green download icon for downloaded episodes (not clickable)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .frame(width: buttonSize, height: buttonSize)
                        } else {
                            // All other cases: Show regular download button
                            simplifiedDownloadButton
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
                            .fill(Color.adaptiveSeparator)
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
                    Task {
                        await viewModel.deleteDownloadedEpisode(episode)
                    }
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
                    .foregroundColor(.adaptivePrimaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.adaptiveBorder)) // Adaptive gray for played
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue)) // Changed from green to blue for consistency
            }
        }
        .font(.system(size: 10, weight: .bold))
        .fixedSize() // Ensure full text is displayed without truncation
    }

    private var episodeStatusIndicator: some View {
            Group {
                if episode.state.isPlayed || episode.state.progress >= 0.99 {
                    Text("Played")
                        .foregroundColor(.adaptiveSecondaryText)
                } else if isPlaying {
                    Text("Playing")
                        .foregroundColor(.blue)
                } else if episode.state.progress > 0 || podcastPlayer.getCurrentProgress(for: episode) > 0 {
                    Text("In Progress")
                        .foregroundColor(.orange)
                } else {
                    Text("New")
                        .foregroundColor(.blue) // Changed from green to blue for consistency
                }
            }
            .font(.caption2)
            .fontWeight(.semibold)
        }
    
    private var simplifiedDownloadButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                viewModel.downloadEpisode(episode) { result in
                    // Download state is managed by the progress tracking
                    print("Download completed for episode: \(episode.title)")
                }
            }
        }) {
            ZStack {
                if episode.state.isDownloaded {
                    // Downloaded state - green checkmark
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.green)
                } else if isDownloading, let progress = viewModel.downloadProgress[episode.id] {
                    // Downloading state - circular progress with percentage
                    ZStack {
                        // Background circle
                        Circle()
                            .stroke(Color.adaptiveBorder, lineWidth: 2)
                            .frame(width: buttonSize, height: buttonSize)
                        
                        // Progress circle
                        Circle()
                            .trim(from: 0, to: CGFloat(progress))
                            .stroke(Color.blue, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                            .frame(width: buttonSize, height: buttonSize)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                        
                        // Percentage text or download icon
                        if progress > 0.05 { // Show percentage after 5% to avoid cramped text
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.system(size: buttonSize * 0.4))
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    // Default state - download arrow
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
        }
        .disabled(isDownloading) // Disable button during download
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
    
    // Cache expensive computations to avoid recalculation during scrolling
    private let cachedProgress: Double
    private let cachedStatusText: String
    private let cachedStatusColor: Color
    private let cachedTimeInfo: String?
    private let cachedDateString: String
    private let cachedPlayButtonIcon: String
    private let cachedIsCompleted: Bool
    
    // Cache formatters to avoid recreation
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    private let buttonSize: CGFloat = 22
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        viewModel.downloadProgress[episode.id] != nil && viewModel.downloadProgress[episode.id]! > 0 && viewModel.downloadProgress[episode.id]! < 1
    }
    
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
        
        // Cache expensive computations once during initialization
        // For playing episodes, we'll use real-time progress; for others, use EpisodeStateManager
        self.cachedProgress = isPlaying ? podcastPlayer.currentProgress : EpisodeStateManager.shared.getProgress(for: episode.id)
        let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
        self.cachedIsCompleted = episodeState == .played || self.cachedProgress >= 0.99
        
        // Pre-compute status text and color using EpisodeStateManager
        if isPlaying {
            self.cachedStatusText = "PLAYING"
            self.cachedStatusColor = .blue
        } else {
            self.cachedStatusText = episodeState.statusText.uppercased()
            self.cachedStatusColor = episodeState.statusColor
        }
        
        // Pre-compute play button icon using EpisodeStateManager
        if isPlaying {
            self.cachedPlayButtonIcon = "pause.fill"
        } else {
            self.cachedPlayButtonIcon = episodeState.buttonImage
        }
        
        // Pre-compute date string
        self.cachedDateString = Self.dateFormatter.string(from: episode.publicationDate)
        
        // Pre-compute time info
        if episode.duration > 0 {
            let remainingTime = episode.duration * (1 - cachedProgress)
            if remainingTime > 0 && episode.state.progress > 0 {
                let hours = Int(remainingTime) / 3600
                let minutes = (Int(remainingTime) % 3600) / 60
                if hours > 0 {
                    self.cachedTimeInfo = "\(hours)h \(minutes)m left"
                } else {
                    self.cachedTimeInfo = "\(minutes)m left"
                }
            } else {
                let hours = Int(episode.duration) / 3600
                let minutes = (Int(episode.duration) % 3600) / 60
                if hours > 0 {
                    self.cachedTimeInfo = "\(hours)h \(minutes)m"
                } else {
                    self.cachedTimeInfo = "\(minutes)m"
                }
            }
        } else {
            self.cachedTimeInfo = nil
        }
    }
    
    static func == (lhs: OptimizedEpisodeRowView, rhs: OptimizedEpisodeRowView) -> Bool {
        // Simplified equality check using cached values to reduce computation
        // For playing episodes, allow progress updates to trigger view refresh
        let progressEqual = lhs.isPlaying || rhs.isPlaying ? 
            abs(lhs.podcastPlayer.currentProgress - rhs.podcastPlayer.currentProgress) < 0.01 :
            abs(lhs.cachedProgress - rhs.cachedProgress) < 0.01
            
        return lhs.episode.id == rhs.episode.id &&
        lhs.isPlaying == rhs.isPlaying &&
        progressEqual &&
        lhs.episode.state.isFavorite == rhs.episode.state.isFavorite &&
        lhs.episode.state.isDownloaded == rhs.episode.state.isDownloaded
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
                    Task {
                        await viewModel.deleteDownloadedEpisode(episode)
                    }
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
    
    // MARK: - Optimized Episode Card Design
    private var modernEpisodeCard: some View {
        VStack(spacing: 0) {
            // Simplified episode content without expensive gradients
            Group {
                if viewModel.currentTab == 2 && episode.state.isDownloaded {
                    episodeContentWithSwipe
                } else {
                    episodeContent
                }
            }
            .background(isPlaying ? Color.blue.opacity(0.03) : Color.clear) // Simple background instead of gradient
            
            // Simple separator
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
        }
    }
    
    private var episodeContent: some View {
        HStack(alignment: .top, spacing: 12) {
            // Play button - simplified
            Button(action: isPlaying ? onStop : onPlay) {
                Image(systemName: cachedPlayButtonIcon)
                    .font(.system(size: 28))
                    .foregroundColor(isPlaying ? .blue : EpisodeStateManager.shared.getState(for: episode.id).buttonColor)
            }
            .frame(width: 40, height: 40)
            
            // Episode content
            VStack(alignment: .leading, spacing: 4) {
                // Episode title - limit lines for better performance
                Text(episode.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2) // Limit lines for better scrolling performance
                    .multilineTextAlignment(.leading)
                
                // Progress bar for currently playing episode
                if isPlaying {
                    ProgressView(value: podcastPlayer.currentProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .frame(height: 3)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(1.5)
                        .padding(.vertical, 2)
                        .animation(.easeInOut(duration: 0.3), value: podcastPlayer.currentProgress)
                }
                
                // Metadata row - using cached values
                HStack(spacing: 6) {
                    // Status indicator - using cached values
                    Text(cachedStatusText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(cachedStatusColor)
                        )
                    
                    // Date - using cached string
                    Text(cachedDateString)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.1))
                        )
                    
                    // Duration - using cached time info
                    if let timeInfo = cachedTimeInfo {
                        Text(timeInfo)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.1))
                            )
                    }
                    
                    Spacer()
                }
            }
            
            // Action buttons - simplified
            VStack(alignment: .center, spacing: 4) {
                // Bookmark button - simplified
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
                
                // Download button - simplified
                Group {
                    if viewModel.currentTab == 2 && episode.state.isDownloaded {
                        // Downloads tab: Show trash can for downloaded episodes
                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .frame(width: buttonSize, height: buttonSize)
                        }
                    } else if (viewModel.currentTab == 0 || viewModel.currentTab == 1) && episode.state.isDownloaded {
                        // All tab and Favorites tab: Show filled green download icon for downloaded episodes (not clickable)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: buttonSize, height: buttonSize)
                    } else {
                        // All other cases: Show regular download button
                        simplifiedDownloadButton
                    }
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .frame(width: 50)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
    
    // MARK: - Helper Methods
    
    private var simplifiedDownloadButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                viewModel.downloadEpisode(episode) { result in
                    // Download state is managed by the progress tracking
                    print("Download completed for episode: \(episode.title)")
                }
            }
        }) {
            ZStack {
                if episode.state.isDownloaded {
                    // Downloaded state - green checkmark
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.green)
                } else if let downloadProgress = viewModel.downloadProgress[episode.id], downloadProgress > 0 && downloadProgress < 1 {
                    // Downloading state - circular progress with percentage
                    ZStack {
                        // Background circle
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: buttonSize, height: buttonSize)
                        
                        // Progress circle
                        Circle()
                            .trim(from: 0, to: CGFloat(downloadProgress))
                            .stroke(Color.blue, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                            .frame(width: buttonSize, height: buttonSize)
                            .animation(.easeInOut(duration: 0.3), value: downloadProgress)
                        
                        // Percentage text or download icon
                        if downloadProgress > 0.05 { // Show percentage after 5% to avoid cramped text
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.system(size: buttonSize * 0.4))
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    // Default state - download arrow
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .disabled(isDownloading) // Disable button during download
    }
    
    private func showBannerAlert(message: String) {
        bannerAlertMessage = message
        showingBannerAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingBannerAlert = false
        }
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
    
    // Simple auto-scroll state management
    @State private var hasScrolledToCurrentEpisode = false
    @State private var viewDidAppear = false
    @State private var episodesDidLoad = false
    @State private var lastAppearanceTime = Date()
    
    @State private var isLoadingMore = false
    @State private var scrollDebounceTimer: Timer?
    
    // Animation states for enhanced UI feedback
    @State private var endIndicatorScale: CGFloat = 1.0
    @State private var showSuccessToast = false
    @State private var successMessage = ""
    
    // MARK: - Bindings
    @Binding var selectedPodcast: PodcastFeed?
    @Binding var episodeToScrollTo: PodcastEpisode?
    
    // MARK: - Constants
    private let scrollThreshold: CGFloat = 50
    private let rowHeight: CGFloat = 80

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
            
            // Global Player now handles all playback display
            // No individual mini player needed here
        }
        .navigationBarHidden(true)
                .onAppear(perform: handleOnAppear)
                        .onDisappear {
            // Clean up timers to prevent memory leaks
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = nil
            
            // Reset view state for fresh appearance next time
            viewDidAppear = false
            episodesDidLoad = false
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
                Button(action: { 
                    withAnimation(.none) {
                        selectedPodcast = nil 
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                
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
                    HStack(alignment: .top, spacing: 16) {
                        // Enhanced artwork with shadow and border using pre-downloaded data
                        PodcastIconView(
                            iconData: feed.iconData,
                            imageData: feed.imageData,
                            artworkUrl: feed.artworkUrl
                        )
                        .frame(width: min(120, geometry.size.width * 0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
                        
                                                    VStack(alignment: .leading, spacing: 12) {
                                // Podcast description section
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("ABOUT")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.blue)
                                        .tracking(1.2)
                                    
                                    ScrollView(.vertical, showsIndicators: true) {
                                        Text(feed.descriptionText ?? "No description available")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .padding(.trailing, 8) // Add right padding to prevent text cutoff
                                            .padding(.bottom, 4) // Add some bottom padding for better scrolling
                                    }
                                    .frame(maxHeight: 80) // Set a max height for the scroll view
                                }

                        }
                        .frame(width: geometry.size.width - min(130, geometry.size.width * 0.35) - 40)
                    }
                    .padding(20)
                }
            }
            .frame(height: 140)
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
                
                HStack(spacing: 4) {
                    Text("\(viewModel.currentEpisodes.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                    
                    Text("episode\(viewModel.currentEpisodes.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                    
                    if viewModel.hasMoreEpisodes {
                        Text("• More available")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
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
        .onChange(of: selectedTab) { _, newValue in
            // Update the current tab and reload episodes with proper filtering
            viewModel.currentTab = newValue
            
            // Reset scroll state when changing tabs so auto-scroll can work again if needed
            hasScrolledToCurrentEpisode = false
            
            Task {
                await viewModel.loadEpisodesForFeed(feed.id, isInitialLoad: true)
            }
        }
    }
    
    private var episodeListContent: some View {
        Group {
            if viewModel.isLoadingEpisodes && viewModel.currentEpisodes.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(1.2)
                    Text("Loading episodes...")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Please wait while we fetch the latest episodes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                modernEpisodeList
            }
        }
    }
    


    private var modernEpisodeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.currentEpisodes, id: \.id) { episode in
                        OptimizedEpisodeRowView(
                            episode: episode,
                            isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                            onPlay: { playEpisode(episode) },
                            onStop: { podcastPlayer.togglePlayPause() },
                            viewModel: viewModel,
                            podcastPlayer: podcastPlayer
                        )
                        .id(episode.id)
                    }
                
                // Loading indicator and invisible trigger area for pull-up gesture
                if viewModel.hasMoreEpisodes && !viewModel.currentEpisodes.isEmpty {
                    VStack(spacing: 0) {
                        // Show loading indicator when loading more episodes
                        if isLoadingMore {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                    .scaleEffect(1.2)
                                
                                Text("Loading more episodes...")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            .padding(.vertical, 20)
                            .transition(.opacity.combined(with: .scale))
                        } else {
                            // Instructional area with arrow and text
                            VStack(spacing: 12) {
                                // Animated up arrow
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(.blue)
                                    .scaleEffect(endIndicatorScale)
                                    .animation(
                                        .easeInOut(duration: 1.5)
                                        .repeatForever(autoreverses: true),
                                        value: endIndicatorScale
                                    )
                                
                                // Instructional text
                                Text("Swipe up for more episodes")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .transition(.opacity.combined(with: .scale))
                        }
                        
                        // Invisible trigger area that fills remaining space
                        Rectangle()
                            .fill(Color.clear)
                            .frame(minHeight: 100) // Reduced since we have instructional area
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Also allow tap to load more for easier testing
                                if !isLoadingMore {
                                    Task {
                                        await loadMoreEpisodesRefreshable()
                                    }
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .onChanged { value in
                                        // Visual feedback during drag
                                        if value.translation.height < -20 {
                                            print("Pull-up detected: \(value.translation.height)")
                                        }
                                    }
                                    .onEnded { value in
                                        // Detect upward pull gesture with lower threshold
                                        print("Drag ended with translation: \(value.translation.height)")
                                        if value.translation.height < -20 && !isLoadingMore {
                                            print("Triggering load more episodes")
                                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                            impactFeedback.impactOccurred()
                                            
                                            Task {
                                                await loadMoreEpisodesRefreshable()
                                            }
                                        }
                                    }
                            )
                    }
                }
                

                
                // Extended bottom padding that serves as main trigger area
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 120) // Increased from 70 to 120 for larger trigger area
                    .contentShape(Rectangle())
                    .gesture(
                        // Main pull-up gesture for bottom area
                        DragGesture(minimumDistance: 10)
                            .onEnded { value in
                                if value.translation.height < -20 && !isLoadingMore && viewModel.hasMoreEpisodes {
                                    print("Pull-up triggered from bottom area")
                                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                    impactFeedback.impactOccurred()
                                    
                                    Task {
                                        await loadMoreEpisodesRefreshable()
                                    }
                                }
                            }
                    )
            }
            }
            .background(Color.black)
            .onAppear {
                // Start end indicator animation
                endIndicatorScale = 1.3
                viewDidAppear = true
                lastAppearanceTime = Date()
                
                // Reset scroll tracking for this view session
                hasScrolledToCurrentEpisode = false
                
                // Attempt scroll if episodes are already loaded
                scrollToCurrentEpisodeIfNeeded(proxy: proxy)
            }
            .onChange(of: viewModel.currentEpisodes) { _, newEpisodes in
                // Mark that episodes have loaded
                if !newEpisodes.isEmpty && !episodesDidLoad {
                    episodesDidLoad = true
                    
                    // Attempt scroll when episodes load
                    scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: selectedTab) { _, _ in
                // Reset scroll state when changing tabs so it can scroll again if needed
                hasScrolledToCurrentEpisode = false
            }
        }
        .overlay(
            // Success toast notification
            VStack {
                if showSuccessToast {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 20))
                        
                        Text(successMessage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 25)
                            .fill(Color.green)
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showSuccessToast = false
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.top, 50),
            alignment: .top
        )
    }

    /// Scrolls to currently playing episode when returning to the view
    private func scrollToCurrentEpisodeIfNeeded(proxy: ScrollViewProxy) {
        // Only scroll once per view session
        guard !hasScrolledToCurrentEpisode else {
            return
        }
        
        // Ensure view has appeared and episodes have loaded
        guard viewDidAppear && episodesDidLoad else {
            return
        }
        
        // Check if there's a currently playing episode for this feed
        guard let currentEpisode = podcastPlayer.currentEpisode,
              currentEpisode.feedId == feed.id else {
            // No episode playing for this feed - mark as complete so we don't keep checking
            hasScrolledToCurrentEpisode = true
            return
        }
        
        // Check if the episode exists in the current tab
        if viewModel.currentEpisodes.contains(where: { $0.id == currentEpisode.id }) {
            print("📍 Scrolling to currently playing episode: \(currentEpisode.title) in current tab: \(getTabName(selectedTab))")
            
            performScrollToEpisode(currentEpisode.id, proxy: proxy)
            
        } else {
            // Episode not in current tab - stay in current tab without scrolling
            print("📍 Currently playing episode not available in current tab (\(getTabName(selectedTab))) - staying in current view")
            hasScrolledToCurrentEpisode = true
        }
    }
    
    /// Performs the actual scroll animation to the episode
    private func performScrollToEpisode(_ episodeId: String, proxy: ScrollViewProxy) {
        // Add a small delay to ensure the view is fully rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.8)) {
                proxy.scrollTo(episodeId, anchor: .center)
            }
        }
        
        // Mark as completed for this view session
        hasScrolledToCurrentEpisode = true
    }
    

    
    private func getTabName(_ tab: Int) -> String {
        switch tab {
        case 0: return "All"
        case 1: return "Favorites"
        case 2: return "Downloads"
        default: return "Unknown"
        }
    }

    private func handleOnAppear() {
        let currentEpisodesForThisFeed = viewModel.currentEpisodes.first?.feedId == feed.id
        
        // Reset state for this view appearance
        viewDidAppear = false  // Will be set to true in onAppear
        episodesDidLoad = !viewModel.currentEpisodes.isEmpty && currentEpisodesForThisFeed
        
        print("📱 PodcastPlayerView appeared for feed: \(feed.title)")
        
        // Synchronize viewModel.currentTab with selectedTab to ensure proper filtering
        viewModel.currentTab = selectedTab
        
        if viewModel.currentEpisodes.isEmpty || !currentEpisodesForThisFeed {
            loadInitialEpisodes()
        } else {
            // Reload episodes with the current tab filter to ensure proper filtering
            Task {
                await viewModel.loadEpisodesForFeed(feed.id, isInitialLoad: true)
            }
        }
    }
    
    private func loadInitialEpisodes() {
        Task {
            await viewModel.loadEpisodesForFeed(feed.id, isInitialLoad: true)
        }
    }
    
    private func loadMoreIfNeeded() {
        guard !isLoadingMore && viewModel.hasMoreEpisodes else { 
            // Provide haptic feedback when no more episodes to load
            if !viewModel.hasMoreEpisodes {
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
            }
            return 
        }
        
        // Provide haptic feedback when starting to load
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        
        isLoadingMore = true
        viewModel.loadMoreEpisodes(for: feed) { success in
            DispatchQueue.main.async {
                isLoadingMore = false
                
                // Provide success/failure haptic feedback
                if success {
                    let successFeedback = UINotificationFeedbackGenerator()
                    successFeedback.notificationOccurred(.success)
                } else {
                    let errorFeedback = UINotificationFeedbackGenerator()
                    errorFeedback.notificationOccurred(.error)
                }
            }
        }
    }
    
    private func loadMoreEpisodesRefreshable() async {
        guard !isLoadingMore && viewModel.hasMoreEpisodes else { 
            // Provide haptic feedback when no more episodes to load
            if !viewModel.hasMoreEpisodes {
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
            }
            return 
        }
        
        // Provide haptic feedback when starting to load
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        
        // Set loading state with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            isLoadingMore = true
        }
        
        let episodeCountBefore = viewModel.currentEpisodes.count
        
        await withCheckedContinuation { continuation in
            viewModel.loadMoreEpisodes(for: feed) { success in
                DispatchQueue.main.async {
                    let episodeCountAfter = self.viewModel.currentEpisodes.count
                    let newEpisodesAdded = episodeCountAfter - episodeCountBefore
                    
                    // Show success state briefly before hiding loading
                    if success && newEpisodesAdded > 0 {
                        // Show success feedback
                        let successFeedback = UINotificationFeedbackGenerator()
                        successFeedback.notificationOccurred(.success)
                        
                        // Show success toast
                        self.successMessage = "Added \(newEpisodesAdded) new episodes!"
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                            self.showSuccessToast = true
                        }
                        
                        // Brief delay to show success state
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                self.isLoadingMore = false
                            }
                        }
                    } else {
                        // Handle failure or no new episodes
                        let errorFeedback = UINotificationFeedbackGenerator()
                        errorFeedback.notificationOccurred(.error)
                        
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.isLoadingMore = false
                        }
                    }
                    
                    continuation.resume()
                }
            }
        }
    }
    

    
    private func playEpisode(_ episode: PodcastEpisode) {
        if podcastPlayer.currentEpisode?.id == episode.id {
            // Check the specific episode's progress, not the current player's progress
            let episodeProgress = podcastPlayer.getCurrentProgress(for: episode)
            if episode.state.isPlayed || episodeProgress >= 0.99 {
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


