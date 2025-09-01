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

// MARK: - Feed Deletion Progress View
struct FeedDeletionProgressView: View {
    @ObservedObject var viewModel: PodcastViewModel
    let feedTitle: String
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Text("Deleting Podcast")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Removing '\(feedTitle)' and all episodes")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 16) {
                    // Progress bar
                    ProgressView(value: viewModel.feedDeletionProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(y: 2)
                    
                    // Percentage
                    Text("\(Int(viewModel.feedDeletionProgress * 100))%")
                        .font(.title3)
                        .fontWeight(.medium)
                    
                    // Current step
                    Text(viewModel.feedDeletionMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 20)
                }
                
                if viewModel.feedDeletionProgress >= 1.0 {
                    Button("Done") {
                        isPresented = false
                        // Reset the progress state
                        viewModel.isDeletingFeed = false
                        viewModel.deletingFeedId = nil
                        viewModel.feedDeletionProgress = 0.0
                        viewModel.feedDeletionMessage = ""
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        isPresented = false
                        // Reset the progress state
                        viewModel.isDeletingFeed = false
                        viewModel.deletingFeedId = nil
                        viewModel.feedDeletionProgress = 0.0
                        viewModel.feedDeletionMessage = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            )
            .shadow(radius: 10)
            .padding(.horizontal, 40)
        }
    }
}

struct PodcastListView: View {
    @EnvironmentObject private var viewModel: PodcastViewModel
    @EnvironmentObject private var alertManager: AlertManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingAddPodcast = false
    @State private var showingSearchPodcasts = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @Binding var selectedPodcast: PodcastFeed?
    @State private var searchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var expandedFeedId: String?
    @State private var isEditing = false
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    @StateObject private var radioPlayer = RadioPlayer.shared
    @EnvironmentObject private var radioStationViewModel: RadioStationViewModel
    @State private var scrollToEpisodeID: String?
    @State private var refreshID = UUID()
    @State private var dataCheckTimer: Timer?
    @State private var selectedTab: Tab = .podcast
    @State private var isPlayerSheetPresented = false
    
    // Auto-focus on newly added podcast
    @State private var newlyAddedPodcastId: String?
    @State private var highlightedPodcastId: String?
    
    // Edit functionality
    @State private var showingEditPodcast = false
    @State private var podcastToEdit: PodcastFeed?
    @State private var editPodcastTitle = ""
    @State private var editPodcastURL = ""
    @State private var isEditDataReady = false
    @State private var isPreparingEditData = false
    
    // PERFORMANCE: Memoized filtered podcasts to avoid expensive recomputation
    @State private var cachedFilteredPodcasts: [PodcastFeed] = []
    
    // Animation state for deletion progress overlay
    @State private var animationScale: CGFloat = 1.0
    @State private var currentDeletingFeedTitle: String = ""
    @State private var lastSearchText: String = ""
    @State private var lastPodcastFeedsCount: Int = 0
    
    // PERFORMANCE: Fast feed lookup cache
    @State private var feedLookupCache: [String: PodcastFeed] = [:]
    @State private var filteredFeedOrderCache: [String] = []
    

    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    
    // Default initializer for backward compatibility
    init() {
        self._selectedPodcast = .constant(nil)
    }
    
    // Episode results list shown while typing in search
    private var episodeResultsList: some View {
        List {
            if viewModel.globalEpisodeSearchResults.isEmpty {
                Text("No matching episodes")
                    .foregroundColor(.adaptiveSecondaryText)
            } else {
                ForEach(viewModel.globalEpisodeSearchResults, id: \.id) { ep in
                    HStack(alignment: .top, spacing: 10) {
                        // Artwork
                        if let feed = viewModel.podcastFeeds.first(where: { $0.id == ep.feedId }) {
                            if let imageData = feed.imageData, let uiImage = UIImage(data: imageData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fill)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else if let urlString = feed.artworkUrl, let url = URL(string: urlString) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(1, contentMode: .fill)
                                    default:
                                        Color.gray.opacity(0.2)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Color.gray.opacity(0.2)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Color.gray.opacity(0.2)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            highlightedText(in: ep.title, query: searchText)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            if let feed = viewModel.podcastFeeds.first(where: { $0.id == ep.feedId }) {
                                HStack(spacing: 6) {
                                    Text(feed.title)
                                    Text(ep.publicationDate, format: .dateTime.year().month().day().hour().minute())
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            }
                            // Description or notes snippet with highlighting (HTML stripped)
                            if !searchText.isEmpty {
                                let descPlain = htmlToPlainText(ep.descriptionText)
                                if descPlain.localizedCaseInsensitiveContains(searchText) {
                                    let s = snippet(from: descPlain, query: searchText)
                                    highlightedText(in: s, query: searchText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                } else if let notesContent = ep.notes?.content {
                                    let plain = htmlToPlainText(notesContent)
                                    if plain.localizedCaseInsensitiveContains(searchText) {
                                        let s = snippet(from: plain, query: searchText)
                                        highlightedText(in: s, query: searchText)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        print("🔎 Tapped episode result: \(ep.title)")
                        guard let feed = viewModel.podcastFeeds.first(where: { $0.id == ep.feedId }) else { return }
                        DispatchQueue.main.async {
                            PodcastPlayer.shared.playEpisode(ep, feed: feed)
                            selectedPodcast = feed
                            Task { await viewModel.loadEpisodesForFeed(feed.id, isInitialLoad: true) }
                            scrollToEpisodeID = ep.id
                        }
                    }
                }
                // Extra bottom space for easier scrolling
                Color.clear.frame(height: 100)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Search Result Helpers
    private func highlightedText(in text: String, query: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return Text(text) }
        var result = Text("")
        var currentIndex = text.startIndex
        while let range = text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive], range: currentIndex..<text.endIndex) {
            let prefix = String(text[currentIndex..<range.lowerBound])
            if !prefix.isEmpty { result = result + Text(prefix) }
            let match = String(text[range])
            result = result + Text(match).foregroundColor(.accentColor).bold()
            currentIndex = range.upperBound
            if range.lowerBound == range.upperBound { break }
        }
        if currentIndex < text.endIndex {
            let suffix = String(text[currentIndex..<text.endIndex])
            result = result + Text(suffix)
        }
        return result
    }

    private func snippet(from text: String, query: String, maxLength: Int = 120, context: Int = 40) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return String(text.prefix(maxLength)) }
        guard let range = text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(maxLength))
        }
        let prefixLen = min(context, text.distance(from: text.startIndex, to: range.lowerBound))
        let suffixLen = min(context, text.distance(from: range.upperBound, to: text.endIndex))
        let start = text.index(range.lowerBound, offsetBy: -prefixLen)
        let end = text.index(range.upperBound, offsetBy: suffixLen)
        var snippet = String(text[start..<end])
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    private func htmlToPlainText(_ html: String) -> String {
        // Fast path: no tags
        guard html.contains("<") else { return decodeHTMLEntities(html) }
        // Remove script/style blocks to avoid noisy text
        let withoutScript = html.replacingOccurrences(of: "<script[\\s\\S]*?>[\\s\\S]*?<\\/script>", with: " ", options: [.regularExpression, .caseInsensitive])
        let withoutStyle = withoutScript.replacingOccurrences(of: "<style[\\s\\S]*?>[\\s\\S]*?<\\/style>", with: " ", options: [.regularExpression, .caseInsensitive])
        // Strip all tags
        let noTags = withoutStyle.replacingOccurrences(of: "<[^>]+>", with: " ", options: [.regularExpression, .caseInsensitive])
        // Collapse whitespace
        let collapsed = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeHTMLEntities(collapsed)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var s = text
        // Common entities
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s
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
                           initialScrollToEpisodeID: scrollToEpisodeID ?? podcastPlayer.currentEpisode?.id,
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
                           
                           if !searchText.isEmpty {
                               episodeResultsList
                           } else {
                               // Podcast progress banner - shows sync operations in real-time (including episode sync)
                               MainPodcastListBanner()
                               
                               podcastList
                           }
                       }
                       .contentShape(Rectangle())
                       .simultaneousGesture(
                           TapGesture().onEnded { _ in
                               // Dismiss keyboard when tapping outside search box
                               UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                           }
                       )
                       .simultaneousGesture(
                           // DEBUG: Triple tap to trigger CloudKit sync and show banner
                           TapGesture(count: 3).onEnded { _ in

                               viewModel.manuallyTriggerCloudKitSync()
                           }
                       )
                   }
                   
                   // Global Player is now handled by ContentView overlay
                   // This ensures consistent player display across all tabs
               }
               .navigationTitle("Podcasts")
               .navigationBarTitleDisplayMode(.inline)
               .toolbar {
                   ToolbarItemGroup(placement: .navigationBarTrailing) {
                       if !isEditing {
                           Button(action: { 
                               // Show confirmation alert for podcast sorting
                               alertManager.showCustomAlert(for: .confirmPodcastSortChange, deleteAction: { 
                                   viewModel.sortFeedsAlphabetically()
                               })
                           }) {
                               Image(systemName: viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                           }
                           Button(action: { showingSearchPodcasts = true }) {
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
                   // automatically show the episode list and request a refresh
                   if let podcast = newValue {
                       viewModel.requestFeedRefresh(podcast.id)
                   }
               }
               .onChange(of: viewModel.podcastFeeds.count) { _, newCount in
                   // React to ALL feed count changes (including clearing)
                   if newCount > 0 {
                       // Cancel monitoring timer since data is now available
                       dataCheckTimer?.invalidate()
                       dataCheckTimer = nil
                       
                       // IMMEDIATE: Force comprehensive UI refresh when feeds become available
                       DispatchQueue.main.async {
                           self.refreshID = UUID()
                           self.initializeCaches()
                       }
                   }
               }
               .id(refreshID)
               .sheet(isPresented: Binding(
                   get: { showingAddPodcast },
                   set: { newValue in 
                       showingAddPodcast = newValue
                       if !newValue {
                           resetAddState()
                           checkForNewlyAddedPodcast()
                       }
                   }
               )) {
                   AddPodcastView(
                       isPresented: Binding(
                           get: { showingAddPodcast },
                           set: { newValue in 
                               showingAddPodcast = newValue
                               if !newValue {
                                   resetAddState()
                                   checkForNewlyAddedPodcast()
                               }
                           }
                       ), 
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
                               return editPodcastTitle 
                           },
                           set: { newValue in 
                               editPodcastTitle = newValue 
                           }
                       ),
                       url: Binding(
                           get: { 
                               return editPodcastURL 
                           },
                           set: { newValue in 
                               editPodcastURL = newValue 
                           }
                       ),
                       podcastToEdit: podcastToEdit,
                       onAdd: { _ in },
                       onUpdate: { updatedPodcast in
                           updatePodcast(updatedPodcast)
                       }
                   )
               }
                               .sheet(isPresented: UIDevice.current.userInterfaceIdiom == .phone ? $showingSearchPodcasts : .constant(false)) {
                    SearchPodcastsView(isPresented: $showingSearchPodcasts)
                }
                .fullScreenCover(isPresented: UIDevice.current.userInterfaceIdiom == .pad ? $showingSearchPodcasts : .constant(false)) {
                    SearchPodcastsView(isPresented: $showingSearchPodcasts)
                }
                .onChange(of: showingSearchPodcasts) { _, isPresented in
                    if !isPresented {
                        // Search sheet was dismissed, check if a new podcast was added
                        checkForNewlyAddedPodcast()
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
           .overlay(
               Group {
                   if alertManager.showCustomAlert {
                       Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                       CustomAlertView(
                           title: alertManager.customAlertTitle,
                           message: alertManager.customAlertMessage,
                           buttonText: alertManager.customAlertPrimaryButtonText,
                           buttonAction: {
                               alertManager.dismissAlert()
                               alertManager.customAlertPrimaryAction?()
                           },
                           secondaryButtonText: alertManager.customAlertSecondaryButtonText,
                           secondaryButtonAction: {
                               alertManager.dismissAlert()
                               alertManager.customAlertSecondaryAction?()
                           }
                       )
                       .transition(.opacity)
                   }
               }
           )
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
                TextField("Search episodes in saved podcasts", text: $searchText)
                    .padding(.vertical, 8)
                    .padding(.trailing, 30)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: searchText) { newValue in
                        searchText = String(newValue.prefix(100))  // Limit to 100 characters
                        viewModel.searchSavedEpisodesAcrossPodcasts(searchText)
                    }
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        viewModel.searchSavedEpisodesAcrossPodcasts("")
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
            // Inline episode results when searching
            
            // Editing mode header right above the list
            if isEditing {
                HStack {
                    Text("Drag to Reorder Podcasts")
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                        .allowsHitTesting(false)
                    
                    Spacer()
                        .allowsHitTesting(false)
                    
                    Button("Done") {
                        isEditing = false
                        viewModel.saveFeedOrder()
                        refreshID = UUID()
                    }
                    .font(.body)
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
            
            ScrollViewReader { proxy in
                List {
                    if viewModel.podcastFeeds.isEmpty {
                        Text("No podcast feeds available")
                            .foregroundColor(.adaptiveSecondaryText)
                            .italic()
                            .padding()
                    }
                    ForEach(getFilteredFeedOrder(), id: \.self) { feedId in
                    if let feed = getFeedById(feedId) {
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
                                    // Request immediate refresh when user selects a feed
                                    print("🔄 USER SELECTED FEED: Requesting immediate refresh for \(feed.title)")
                                    viewModel.requestFeedRefresh(feed.id)
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
                        .overlay(
                            // Highlight effect for newly added podcast
                            highlightedPodcastId == feed.id ?
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.blue, lineWidth: 3)
                                .opacity(0.7)
                                .animation(.easeInOut(duration: 0.5), value: highlightedPodcastId)
                            : nil
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
                        .id(feedId)
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
                .onReceive(NotificationCenter.default.publisher(for: .podcastAddedForFocus)) { notification in
                    if let podcastId = notification.object as? String {
                        newlyAddedPodcastId = podcastId
                        
                        // Check if the podcast is already in the list and trigger scroll immediately
                        if viewModel.podcastFeedOrder.contains(podcastId),
                           viewModel.podcastFeeds.contains(where: { $0.id == podcastId }) {
                            
                            // Use a longer delay to ensure UI is fully updated
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                
                                // First, highlight the podcast
                                highlightedPodcastId = podcastId
                                
                                // Then scroll to it with animation
                                withAnimation(.easeInOut(duration: 0.8)) {
                                    proxy.scrollTo(podcastId, anchor: .center)
                                }
                                
                                // Remove highlight after 2 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    highlightedPodcastId = nil
                                }
                                
                                // Clear the newly added podcast ID after scrolling
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    newlyAddedPodcastId = nil
                                }
                            }
                        } else {
                        }
                    }
                }
                .onChange(of: viewModel.podcastFeedOrder) { _ in
                    
                    // Check if a new podcast was added and scroll to it
                    if let newPodcastId = newlyAddedPodcastId,
                       viewModel.podcastFeedOrder.contains(newPodcastId),
                       viewModel.podcastFeeds.contains(where: { $0.id == newPodcastId }) {
                        
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            
                            // First, highlight the podcast
                            highlightedPodcastId = newPodcastId
                            
                            // Then scroll to it with animation
                            withAnimation(.easeInOut(duration: 0.8)) {
                                proxy.scrollTo(newPodcastId, anchor: .center)
                            }
                            
                            // Remove highlight after 2 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                highlightedPodcastId = nil
                            }
                            
                            // Clear the newly added podcast ID after scrolling
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                newlyAddedPodcastId = nil
                            }
                        }
                    } else {
                        if let newPodcastId = newlyAddedPodcastId {
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)  // Add extra space at the bottom
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        UserDefaults.standard.set(true, forKey: "isUserScrolling")
                        // Post notification for PodcastPlayer scroll detection
                        NotificationCenter.default.post(name: .userIsScrolling, object: nil)
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            UserDefaults.standard.set(false, forKey: "isUserScrolling")
                            // Post notification for PodcastPlayer scroll detection
                            NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                        }
                    }
            )
            .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    currentDeletingFeedTitle = podcast.title
                    viewModel.deletePodcastFeed(podcast)
                }
            } message: { podcast in
                Text("Are you sure you want to delete '\(podcast.title)'? This action cannot be undone.")
            }
            .overlay(
                // Feed Deletion Progress Overlay
                Group {
                    if viewModel.isDeletingFeed {
                        FeedDeletionProgressView(
                            viewModel: viewModel,
                            feedTitle: currentDeletingFeedTitle,
                            isPresented: .constant(true)
                        )
                    }
                }
            )
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
        
        // CRITICAL FIX: Sync live progress from currently playing episode to cache
        // This ensures the episode list shows current live progress, not stale saved progress
        syncCurrentPlayingProgress()
        
        // PERFORMANCE: Initialize caches immediately for fast rendering
        initializeCaches()
        
        // DEFERRED: Move heavy CloudKit sync off main thread with lower priority
        Task.detached(priority: .background) {
            // Add small delay to let UI render first
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            await viewModel.automaticCloudKitSync()
        }
        
        // DEFERRED: Set up notification observers with minimal impact
        Task.detached(priority: .background) {
            await self.setupNotificationObservers()
        }
        
        // LIGHTWEIGHT: Check for existing data without heavy operations
        if viewModel.podcastFeeds.isEmpty {
            // Start lightweight monitoring without heavy reload operations
            self.startFreshInstallDataMonitoring()
        }
    }
    
    private func syncCurrentPlayingProgress() {
        // CRITICAL FIX: Mark navigation event to protect live progress from CloudKit override
        podcastPlayer.markNavigationEvent()
        
        // Sync live progress from currently playing episode to ViewModel cache
        // This prevents progress reset when returning to episode list
        if let currentEpisode = podcastPlayer.currentEpisode,
           podcastPlayer.isPlaying || podcastPlayer.currentTime > 0 {
            let liveProgress = podcastPlayer.currentProgress
            DispatchQueue.main.async {
                self.viewModel.episodeProgress[currentEpisode.id] = liveProgress
            }
        }
    }
    
    private func startFreshInstallDataMonitoring() {
        // Cancel any existing timer
        dataCheckTimer?.invalidate()
        
        // LIGHTWEIGHT: Start minimal monitoring with longer intervals
        var checkCount = 0
        dataCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            checkCount += 1
            let feedCount = self.viewModel.podcastFeeds.count
            
            if feedCount > 0 {
                DispatchQueue.main.async {
                    self.refreshID = UUID()
                    self.initializeCaches() // Refresh caches when data arrives
                    timer.invalidate()
                    self.dataCheckTimer = nil
                }
            } else if checkCount > 15 { // Stop after 15 seconds
                timer.invalidate()
                self.dataCheckTimer = nil
            }
        }
    }
    
    // PERFORMANCE: Setup notification observers off main thread
    @MainActor
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FreshInstallDataAvailable"),
            object: nil,
            queue: .main
        ) { _ in
            self.refreshID = UUID()
            self.initializeCaches()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastDataUpdated"),
            object: nil,
            queue: .main
        ) { _ in
            self.refreshID = UUID()
            self.initializeCaches()
        }
    }
    

    
    private func addPodcast(_ podcastId: String?) {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        viewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
        
        // Set auto-focus if we received a podcast ID
        if let podcastId = podcastId {
            newlyAddedPodcastId = podcastId
        }
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
    
    private func resetAddState() {
        newPodcastTitle = ""
        newPodcastURL = ""
        print("🔧 DEBUG: Form fields cleared - title: '\(newPodcastTitle)', url: '\(newPodcastURL)'")
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
    
    // PERFORMANCE: Initialize all caches for fast rendering
    private func initializeCaches() {
        // Initialize feed lookup cache
        feedLookupCache = Dictionary(uniqueKeysWithValues: viewModel.podcastFeeds.map { ($0.id, $0) })
        
        // Initialize filtered caches
        cachedFilteredPodcasts = viewModel.podcastFeeds
        lastSearchText = searchText
        lastPodcastFeedsCount = viewModel.podcastFeeds.count
        filteredFeedOrderCache = viewModel.podcastFeedOrder
    }
    
    // PERFORMANCE: Fast feed lookup by ID
    private func getFeedById(_ feedId: String) -> PodcastFeed? {
        // Update cache if needed
        if feedLookupCache.count != viewModel.podcastFeeds.count {
            feedLookupCache = Dictionary(uniqueKeysWithValues: viewModel.podcastFeeds.map { ($0.id, $0) })
        }
        return feedLookupCache[feedId]
    }
    
    // PERFORMANCE: Get filtered feed order without expensive nested lookups
    private func getFilteredFeedOrder() -> [String] {
        // SORTING FIX: Invalidate cache when podcastFeedOrder changes to ensure sorting updates are visible
        if searchText == lastSearchText && 
           viewModel.podcastFeeds.count == lastPodcastFeedsCount &&
           filteredFeedOrderCache.count == viewModel.podcastFeedOrder.count {
            
            // Additional check: verify the order hasn't changed by checking first few items
            let currentOrder = viewModel.podcastFeedOrder.prefix(min(3, viewModel.podcastFeedOrder.count))
            let cachedOrder = filteredFeedOrderCache.prefix(min(3, filteredFeedOrderCache.count))
            
            // Use cached result only if order is exactly the same
            if Array(currentOrder) == Array(cachedOrder) {
                return filteredFeedOrderCache
            }
        }
        
        let filteredIds = Set(filteredPodcasts.map { $0.id })
        let result = viewModel.podcastFeedOrder.filter { filteredIds.contains($0) }
        
        // Cache the result
        DispatchQueue.main.async {
            self.filteredFeedOrderCache = result
            self.lastSearchText = self.searchText
            self.lastPodcastFeedsCount = self.viewModel.podcastFeeds.count
        }
        
        return result
    }
    
    // PERFORMANCE: Optimized memoized filtered podcasts
    private var filteredPodcasts: [PodcastFeed] {
        // Use cached result if search text and podcast count haven't changed
        if searchText == lastSearchText && viewModel.podcastFeeds.count == lastPodcastFeedsCount {
            return cachedFilteredPodcasts
        }
        
        // Update cache
        let result: [PodcastFeed]
        if searchText.isEmpty {
            result = viewModel.podcastFeeds
        } else {
            let searchLower = searchText.lowercased()
            result = viewModel.podcastFeeds.filter { feed in
                feed.title.lowercased().contains(searchLower) ||
                (feed.descriptionText?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        // Cache the result
        DispatchQueue.main.async {
            self.cachedFilteredPodcasts = result
            self.lastSearchText = self.searchText
            self.lastPodcastFeedsCount = self.viewModel.podcastFeeds.count
        }
        
        return result
    }
    
    // MARK: - Auto-focus on newly added podcast
    private func checkForNewlyAddedPodcast() {
        // Store the previous podcast count to detect new additions
        let currentCount = viewModel.podcastFeeds.count
        let currentFeedIds = Set(viewModel.podcastFeedOrder)
        
        // Check if we have a new podcast by comparing with what we had before
        // The newest podcast should be the last one in the order
        if currentCount > 0,
           let lastFeedId = viewModel.podcastFeedOrder.last,
           viewModel.podcastFeeds.contains(where: { $0.id == lastFeedId }) {
            
            
            // Set the newly added podcast ID to trigger auto-scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                newlyAddedPodcastId = lastFeedId
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
    private let buttonSize: CGFloat = 20 // Size for play/loading buttons
    
    // PERFORMANCE: Cached button text to avoid expensive computations during scrolling
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
                    .padding(.leading, 16)
                
                HStack(alignment: .top, spacing: 12) {
                    // Use PodcastIconView for immediate loading from Core Data
                    PodcastIconView(
                        iconData: feed.iconData,
                        imageData: feed.imageData,
                        artworkUrl: feed.artworkUrl
                    )
                    .frame(width: iconSize, height: iconSize)
                    .padding(.leading, 16)
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
                                    Group {
                                        if let lastPlayedEpisodeId = viewModel.lastPlayedEpisodes[feed.id],
                                           podcastPlayer.loadingEpisodeId == lastPlayedEpisodeId && !isPlaying {
                                            // Show spinning loading state
                                            Image(systemName: "arrow.2.circlepath.circle.fill")
                                                .resizable()
                                                .frame(width: buttonSize, height: buttonSize)
                                                .foregroundColor(.blue)
                                                .rotationEffect(.degrees(360))
                                                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: podcastPlayer.loadingEpisodeId)
                                        } else {
                                            // Regular play button
                                            Image(systemName: "play.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                    }
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
                        .font(.title3)
                        .foregroundColor(.adaptiveSecondaryText)
                        .frame(width: arrowSize, height: iconSize)
                        .padding(.trailing, 12)
                        .onTapGesture {
                            onTap()
                        }
                }
            }
        }
      //  .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Rounded card with matching rounded stroke so borders are not visually clipped
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPlaying ? Color.blue.opacity(0.03) : Color.adaptiveCardBackground.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isPlaying ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
                )
        )
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
    
    private func checkAndPlayEpisode() {
        // PERFORMANCE: Use optimized method from viewModel to avoid expensive operations
        if let episode = viewModel.getLastPlayedOrLatestEpisode(for: feed) {
            podcastPlayer.playEpisode(episode, feed: feed)
        } else {
            onPlay()
        }
    }
    
    private func playLastPlayedEpisode() {
        // If there's a currently playing episode from this feed, resume it
        if let currentEpisode = podcastPlayer.currentEpisode,
           currentEpisode.feedId == feed.id,
           !podcastPlayer.isPlaying {
            // IMMEDIATE USER FEEDBACK: Set loading state for current episode
            podcastPlayer.loadingEpisodeId = currentEpisode.id
            podcastPlayer.togglePlayPause()
            return
        }
        
        // PERFORMANCE: Use optimized method from viewModel to avoid expensive operations during UI interactions
        if let episode = viewModel.getLastPlayedOrLatestEpisode(for: feed) {
            podcastPlayer.loadingEpisodeId = episode.id
            podcastPlayer.playEpisode(episode, feed: feed)
        } else {
            // Fallback: Use the existing logic if no episodes found
            podcastPlayer.playLastEpisodeForFeed(feed)
        }
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
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    @State private var refreshTrigger = UUID() // Force UI refresh when progress changes
    @State private var downloadButtonPressed = false // For download button press animation
    private let buttonSize: CGFloat = 22
    private let rowHeight: CGFloat = 70
    
    // REAL-TIME PROGRESS: Use computed property that always reflects current state
    private var currentProgress: Double {
        if isPlaying {
            return podcastPlayer.currentProgress
        } else {
            // For non-playing episodes, get real-time progress from viewModel's episodeProgress cache
            // This will update when sync notifications are received
            return viewModel.episodeProgress[episode.id] ?? episode.state.progress
        }
    }
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        viewModel.downloadProgress[episode.id] != nil && viewModel.downloadProgress[episode.id]! > 0 && viewModel.downloadProgress[episode.id]! < 1
    }
    
    // Computed property for checking if episode is marked as played
    private var isEpisodePlayed: Bool {
        EpisodeStateManager.shared.getState(for: episode.id) == .played
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
            return episode.duration * (1 - currentProgress)
        }
    }
    
    init(episode: PodcastEpisode, isPlaying: Bool, onPlay: @escaping () -> Void, onStop: @escaping () -> Void, viewModel: PodcastViewModel, podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            if showingBannerAlert {
                Text(bannerAlertMessage)
                    .font(.caption)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                    .foregroundColor(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(bannerAlertMessage.hasPrefix("Download started") ? Color.blue : Color.red)
            }
            
            // Responsive Layout: Play Button | Episode Info | Action Buttons
            HStack(alignment: .top, spacing: 12) {
                
                // COLUMN 1: Play/Pause button (Fixed width)
                // Calculate progress once for both action and UI
                let currentProgress = podcastPlayer.getCurrentProgress(for: episode)
                
                Button(action: {
                    print("🔄 BUTTON DEBUG 1: Play/Rewind button pressed for episode: \(episode.title)")
                    print("🔄 BUTTON DEBUG 1: episode.id = \(episode.id)")
                    print("🔄 BUTTON DEBUG 1: episode.state.isPlayed = \(episode.state.isPlayed), currentProgress = \(currentProgress)")
                    print("🔄 BUTTON DEBUG 1: episode.state = \(episode.state)")
                    if episode.state.isPlayed || currentProgress >= 0.99 {
                        print("🔄 BUTTON DEBUG 1: Calling rewindAndPlay for episode: \(episode.title)")
                        podcastPlayer.rewindAndPlay(episode: episode)
                    } else if isPlaying {
                        print("🔄 BUTTON DEBUG 1: Calling onStop for episode: \(episode.title)")
                        onStop()
                    } else {
                        print("🔄 BUTTON DEBUG 1: Calling onPlay for episode: \(episode.title)")
                        onPlay()
                    }
                }) {
                    Group {
                        if podcastPlayer.loadingEpisodeId == episode.id && !isPlaying {
                            // Show spinning loading state
                            Image(systemName: "arrow.2.circlepath")
                                .font(.title)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap icon size
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(360))
                                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: podcastPlayer.loadingEpisodeId)
                        } else {
                            // Regular play/pause/replay button
                            Image(systemName: episode.state.isPlayed || currentProgress >= 0.99 ? "arrow.counterclockwise.circle.fill" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                                .resizable()
                                .frame(width: buttonSize + 6, height: buttonSize + 6) // Larger visual button
                                .foregroundColor(episode.state.isPlayed || currentProgress >= 0.99 ? .adaptiveSecondaryText : (isPlaying ? .blue : .green))
                        }
                    }
                    .padding(8) // Add padding for larger tap area
                    .background(Color.clear) // Invisible background to catch taps
                    .contentShape(Rectangle()) // Ensure entire area is tappable
                }
                .frame(width: 60, height: 60) // Larger tap area (was 44x44)
                .padding(.top, 2) // Align with first line of text
                
                // COLUMN 2: Episode info (Flexible width with intelligent truncation)
                VStack(alignment: .leading, spacing: 4) {
                    // Episode title (responsive to available space)
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                        .lineLimit(2)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .layoutPriority(1) // Give title priority in layout
                    
                    // Progress bar for episodes with progress (embedded in content)
                    // CRITICAL FIX: Hide progress bar when episode is marked as played
                    if currentProgress > 0 && currentProgress < 1.0 && !isEpisodePlayed {
                        ProgressView(value: currentProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: isPlaying ? .blue : .gray))
                            .frame(height: 3)
                            .background(Color.adaptiveBorder)
                            .cornerRadius(1.5)
                            .animation(podcastPlayer.isInitialProgressLoad ? nil : .easeInOut(duration: 0.3), value: currentProgress)
                    }
                    
                    // Compact metadata row (priority-based truncation)
                    HStack(spacing: 4) {
                        // Status indicator (highest priority - always visible)
                        episodeStatusChip
                            .layoutPriority(3) // Highest priority
                        
                        // Date (medium priority - truncate if needed)
                        Text(Self.dateFormatter.string(from: episode.publicationDate))
                            .font(.caption)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                            .foregroundColor(.blue)
                            .lineLimit(1)
                            .layoutPriority(2) // Medium priority
                        
                        // Duration/time info (lowest priority - first to disappear)
                        if let timeInfo = formatTimeInfo() {
                            Text("• \(timeInfo)")
                                .font(.caption)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                                .foregroundColor(.adaptiveSecondaryText)
                                .lineLimit(1)
                                .layoutPriority(1) // Lowest priority - will be truncated first
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1) // Give middle column flexibility
                
                // COLUMN 3: Action buttons (Fixed width - always visible)
                VStack(alignment: .center, spacing: 8) {
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
                    
                    // Download button
                    Group {
                        if viewModel.currentTab == 2 && episode.state.isDownloaded {
                            // Downloads tab: Show trash can for downloaded episodes
                            Button(action: {
                                if isPlaying {
                                    showBannerAlert(message: "You can't delete downloads while the episode is playing.")
                                } else {
                                    showingDeleteConfirmation = true
                                }
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
                .frame(width: 50, alignment: .center) // Compact fixed width
                .layoutPriority(2) // High priority - always visible
                .padding(.top, 2) // Align with content
            }
            .frame(minHeight: 64) // Minimum height for touch targets
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                onPlay()
            }
            .onReceive(podcastPlayer.$currentProgress) { _ in
                // Force view refresh when progress changes for playing episodes
                // This will update the currentTimeInfo computed property
            }
            .onReceive(podcastPlayer.$currentTime) { _ in
                // Force view refresh when current time changes for playing episodes
                // This ensures real-time time left updates
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Enhanced background that covers the entire available space - similar to radio station styling
            Rectangle()
                .fill(isPlaying ? Color.blue.opacity(0.03) : Color.adaptiveCardBackground.opacity(0.7))
                .frame(maxWidth: .infinity)
                .overlay(
                    // Border highlight for currently playing episode - matching radio station style
                    Rectangle()
                        .stroke(isPlaying ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
                )
        )
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
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeProgressChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's progress changes instantly
                refreshTrigger = UUID()
                print("📡 ⚡ EPISODE ROW REFRESH: Episode \(episode.title) progress updated")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodePlayedChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's played state changes instantly
                refreshTrigger = UUID()
                print("📡 ⚡ EPISODE ROW REFRESH: Episode \(episode.title) played state updated")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeFavoriteChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's favorite state changes instantly
                refreshTrigger = UUID()
                print("📡 ⚡ EPISODE ROW REFRESH: Episode \(episode.title) favorite state updated")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeDownloadChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's download state changes instantly
                refreshTrigger = UUID()
                print("📡 ⚡ EPISODE ROW REFRESH: Episode \(episode.title) download state updated")
            }
        }
        // REAL-TIME SYNC: Added notification listeners for instant progress, played, favorite, and download state updates to force UI refresh
    }
    
    
    private var episodeStatusChip: some View {
        Group {
            // REAL-TIME STATUS FIX: Use currentProgress instead of episode.state.progress for accurate status during playback
            if episode.state.isPlayed || (currentProgress >= 0.99 && !isPlaying) {
                Text("Played")
                    .foregroundColor(.adaptivePrimaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.adaptiveBorder)) // Adaptive gray for played
            } else if isPlaying {
                Text("Playing")
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
            } else if currentProgress > 0 {
                Text("IN PROGRESS")
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange))
                    .fixedSize()
            } else {
                Text("NEW")
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue)) // Changed from green to blue for consistency
            }
        }
        .font(.caption2)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
        .fixedSize() // Ensure full text is displayed without truncation
    }
    
    private var simplifiedDownloadButton: some View {
        Button(action: {
            // Trigger button press animation
            withAnimation(.easeInOut(duration: 0.1)) {
                downloadButtonPressed = true
            }
            
            // Reset animation after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    downloadButtonPressed = false
                }
            }
            
            // Add haptic feedback for button tap
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                // Check subscription for download feature
                if !subscriptionManager.isSubscribedOrInTrial {
                    showBannerAlert(message: "Podcast downloads are available with StreamRadios Pro. Upgrade to download episodes for offline listening.")
                    return
                }
                
                // Show immediate feedback with a brief message
                showBannerAlert(message: "Download started for \(episode.title)")
                
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
                                .font(.caption2)
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.caption2)
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
        .scaleEffect(downloadButtonPressed ? 0.9 : 1.0) // Add scale animation for press feedback
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
        } else if currentProgress > 0 {
            // CRITICAL FIX: Use currentProgress instead of episode.state.progress for real-time sync
            remainingDuration = episode.duration * (1 - currentProgress)
        } else {
            remainingDuration = episode.duration
        }
        
        guard remainingDuration > 0 else { return nil }
        
        let hours = Int(remainingDuration) / 3600
        let minutes = (Int(remainingDuration) % 3600) / 60
        
        if currentProgress > 0 {
            // CRITICAL FIX: Use currentProgress instead of episode.state.progress for real-time sync
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
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    @State private var refreshTrigger = UUID() // Force UI refresh when progress/played state changes
    @State private var downloadButtonPressed = false // For download button press animation
    
    // Local loading state for visual feedback
    @State private var localLoadingState = false
    
    // Cache expensive computations to avoid recalculation during scrolling
    private let cachedProgress: Double
    private let cachedStatusText: String
    private let cachedStatusColor: Color
    private let cachedTimeInfo: String?
    private let cachedDateString: String
    private let cachedPlayButtonIcon: String
    private let cachedIsCompleted: Bool
    
    // REAL-TIME PROGRESS: Computed property for dynamic progress updates
    private var currentProgress: Double {
        if isPlaying {
            return podcastPlayer.currentProgress
        } else {
            // For non-playing episodes, get real-time progress from viewModel's episodeProgress cache
            // This will update when sync notifications are received
            return viewModel.episodeProgress[episode.id] ?? cachedProgress
        }
    }
    
    // Computed property for checking if episode is marked as played
    private var isEpisodePlayed: Bool {
        EpisodeStateManager.shared.getState(for: episode.id) == .played
    }
    

    
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
    
    // Real-time computed properties for dynamic updates
    private var currentStatusText: String {
        if isPlaying {
            return "PLAYING"
        } else {
            return cachedStatusText
        }
    }
    
    private var currentStatusColor: Color {
        if isPlaying {
            return .blue
        } else {
            return cachedStatusColor
        }
    }
    
    // REAL-TIME TIME INFO: Dynamic time info that updates with progress sync
    private var currentTimeInfo: String? {
        guard episode.duration > 0 else { return nil }
        
        if isPlaying {
            // Use real-time remaining time for currently playing episodes
            let remainingTime = episode.duration - podcastPlayer.currentTime
            if remainingTime > 0 {
                let hours = Int(remainingTime) / 3600
                let minutes = (Int(remainingTime) % 3600) / 60
                if hours > 0 {
                    return "\(hours)h \(minutes)m left"
                } else {
                    return "\(minutes)m left"
                }
            }
        }
        
        // For non-playing episodes, calculate time based on current progress (from sync)
        let progress = currentProgress
        if progress > 0 && progress < 0.99 {
            let remainingTime = episode.duration * (1 - progress)
            if remainingTime > 0 {
                let hours = Int(remainingTime) / 3600
                let minutes = (Int(remainingTime) % 3600) / 60
                if hours > 0 {
                    return "\(hours)h \(minutes)m left"
                } else {
                    return "\(minutes)m left"
                }
            }
        }
        
        // Show total duration if no meaningful progress
        let hours = Int(episode.duration) / 3600
        let minutes = (Int(episode.duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
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
            if remainingTime > 0 && cachedProgress > 0 {
                // CRITICAL FIX: Use cachedProgress instead of episode.state.progress for real-time sync
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
        // Use currentProgress for all progress comparisons to detect real-time sync updates
        let progressEqual = abs(lhs.currentProgress - rhs.currentProgress) < 0.01
            
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
            
            episodeCard
        }
        .id(refreshTrigger) // Force view refresh when progress/played state changes
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
            .background(bannerAlertMessage.hasPrefix("Download started") ? Color.blue : Color.red)
            .cornerRadius(6)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
    
    // MARK: - Optimized Episode Card Design
    private var episodeCard: some View {
        VStack(spacing: 0) {
            // Simplified episode content without expensive gradients
            Group {
                if viewModel.currentTab == 2 && episode.state.isDownloaded {
                    episodeContentWithSwipe
                } else {
                    episodeContent
                }
            }
            .background(
                // Enhanced background that covers the entire available space - similar to radio station styling
                Rectangle()
                    .fill(isPlaying ? Color.blue.opacity(0.03) : Color.adaptiveCardBackground.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .overlay(
                        // Border highlight for currently playing episode - matching radio station style
                        Rectangle()
                            .stroke(isPlaying ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
            )
            
            // Simple separator
            Rectangle()
                .fill(Color.adaptiveSeparator)
                .frame(height: 0.5)
                .padding(.horizontal, 16)
        }
    }
    
    private var episodeContent: some View {
        // Responsive Layout: Play Button | Episode Info | Action Buttons
        HStack(alignment: .top, spacing: 12) {
            
            // COLUMN 1: Play button (Fixed width) with enhanced loading indicator
            ZStack {
                Button(action: isPlaying ? onStop : {
                    // Start local loading state when play button tapped
                    localLoadingState = true
                    onPlay()
                }) {
                    Group {
                        if podcastPlayer.loadingEpisodeId == episode.id && !isPlaying {
                            // Show loading indicator similar to radio station style
                            Image(systemName: cachedPlayButtonIcon)
                                .font(.title2)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                .foregroundColor(.blue)
                                .opacity(0.6)
                        } else {
                            // Regular play/pause button
                            Image(systemName: cachedPlayButtonIcon)
                                .font(.title2)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap icon size
                                .foregroundColor(isPlaying ? .blue : EpisodeStateManager.shared.getState(for: episode.id).buttonColor)
                        }
                    }
                }
                .frame(width: 44, height: 44) // Fixed play button area
                
                // Loading overlay similar to radio station implementation
                if localLoadingState {
                    ZStack {
                        // Semi-transparent circular overlay with more visibility
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 44, height: 44)
                        
                        // Loading spinner
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: localLoadingState)

                }
            }
            .padding(.top, 2) // Align with first line of text
            
            // COLUMN 2: Episode content (Flexible width with intelligent truncation)
            VStack(alignment: .leading, spacing: 4) {
                // Episode title (responsive to available space)
                Text(episode.title)
                    .font(.subheadline)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                    .foregroundColor(.primary)
                    .lineLimit(2) // Limit lines for better scrolling performance
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1) // Give title priority in layout
                
                // Progress bar for episodes with progress (embedded in content)
                // CRITICAL FIX: Hide progress bar when episode is marked as played
                if currentProgress > 0 && currentProgress < 1.0 && !isEpisodePlayed {
                    ProgressView(value: currentProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: isPlaying ? .blue : .gray))
                        .frame(height: 3)
                        .background(Color.adaptiveBorder)
                        .cornerRadius(1.5)
                        .animation(podcastPlayer.isInitialProgressLoad ? nil : .easeInOut(duration: 0.3), value: currentProgress)
                }
                
                // Compact metadata row (priority-based truncation)
                HStack(spacing: 4) {
                    // Status indicator (highest priority - always visible)
                    Text(currentStatusText)
                        .font(.caption2)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(currentStatusColor)
                        )
                        .fixedSize()
                        .layoutPriority(3) // Highest priority
                    
                    // Date (medium priority - truncate if needed)
                    Text(cachedDateString)
                        .font(.caption)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .layoutPriority(2) // Medium priority
                    
                    // Duration (lowest priority - first to disappear)
                    if let timeInfo = currentTimeInfo {
                        Text("• \(timeInfo)")
                            .font(.caption)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap text size
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .layoutPriority(1) // Lowest priority - will be truncated first
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1) // Give middle column flexibility
            
            // COLUMN 3: Action buttons (Fixed width - always visible)
            VStack(alignment: .center, spacing: 8) {
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
                
                // Download button
                Group {
                    if viewModel.currentTab == 2 && episode.state.isDownloaded {
                        // Downloads tab: Show trash can for downloaded episodes
                        Button(action: {
                            if isPlaying {
                                showBannerAlert(message: "You can't delete downloads while the episode is playing.")
                            } else {
                                showingDeleteConfirmation = true
                            }
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
            .frame(width: 50, alignment: .center) // Compact fixed width
            .layoutPriority(2) // High priority - always visible
            .padding(.top, 2) // Align with content
        }
        .frame(minHeight: 64) // Minimum height for touch targets
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Start local loading state when tapped
            localLoadingState = true
            onPlay()
        }
        .onReceive(podcastPlayer.$currentProgress) { _ in
            // Force view refresh when progress changes for playing episodes
            // This will update the currentTimeInfo computed property
        }
        .onReceive(podcastPlayer.$currentTime) { _ in
            // Force view refresh when current time changes for playing episodes
            // This ensures real-time time left updates
        }
        .onReceive(podcastPlayer.$isPlaying) { isPlaying in
            // Clear loading state when playback starts for this episode
            if isPlaying && podcastPlayer.currentEpisode?.id == episode.id {
                localLoadingState = false
            }
        }
        .onChange(of: isPlaying) { _, newIsPlaying in
            // Clear loading state when this episode starts playing
            if newIsPlaying {
                localLoadingState = false
            }
        }
        .onChange(of: localLoadingState) { _, isLoading in
            // Auto-clear loading state after 3 seconds as fallback
            if isLoading {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    localLoadingState = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeProgressChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's progress changes instantly
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodePlayedChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's played state changes instantly
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeFavoriteChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's favorite state changes instantly
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeDownloadChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                // Force view refresh when this episode's download state changes instantly
                refreshTrigger = UUID()
            }
        }
    }
    
        private var episodeContentWithSwipe: some View {
        episodeContent
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: {
                    if isPlaying {
                        showBannerAlert(message: "You can't delete downloads while the episode is playing.")
                    } else {
                        showingDeleteConfirmation = true
                    }
                }) {
                    Label("Delete Download", systemImage: "trash.fill")
                }
                .tint(.red)
            }
    }
    
    private var simplifiedDownloadButton: some View {
        Button(action: {
            // Trigger button press animation
            withAnimation(.easeInOut(duration: 0.1)) {
                downloadButtonPressed = true
            }
            
            // Reset animation after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    downloadButtonPressed = false
                }
            }
            
            // Add haptic feedback for button tap
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                // Check subscription for download feature
                if !subscriptionManager.isSubscribedOrInTrial {
                    showBannerAlert(message: "Podcast downloads are available with StreamRadios Pro. Upgrade to download episodes for offline listening.")
                    return
                }
                
                // Show immediate feedback with a brief message
                showBannerAlert(message: "Download started for \(episode.title)")
                
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
                        .frame(width: 22, height: 22)
                        .foregroundColor(.green)
                } else if let downloadProgress = viewModel.downloadProgress[episode.id], downloadProgress > 0 && downloadProgress < 1 {
                    // Downloading state - circular progress with percentage
                    ZStack {
                        // Background circle
                        Circle()
                            .stroke(Color.adaptiveBorder, lineWidth: 2)
                            .frame(width: 22, height: 22)
                        
                        // Progress circle
                        Circle()
                            .trim(from: 0, to: CGFloat(downloadProgress))
                            .stroke(Color.blue, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 22)
                            .animation(.easeInOut(duration: 0.3), value: downloadProgress)
                        
                        // Percentage text or download icon
                        if downloadProgress > 0.05 { // Show percentage after 5% to avoid cramped text
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    // Default state - download arrow
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: 22, height: 22)
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
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
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
                
                // Podcast progress banner - shows sync operations in real-time
                UnifiedPodcastProgressBanner()
                
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
                            .font(.body)
                        Text("Back")
                            .font(.body)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                Spacer()
                
                AirPlayButton()
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(Color.adaptiveSectionBackground)
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
                    .fill(Color.adaptiveSeparator)
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
                        .shadow(color: Color.adaptiveBorder.opacity(0.3), radius: 6, x: 0, y: 3)
                        
                                                    VStack(alignment: .leading, spacing: 12) {
                                // Podcast description section
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("ABOUT")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .tracking(1.2)
                                        
                                        Spacer()
                                        
                                        // Scroll indicators - show arrows to indicate scrollable content
                                        VStack(spacing: 2) {
                                            Image(systemName: "chevron.up")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Image(systemName: "chevron.down")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .opacity(0.6)
                                    }
                                    
                                    ScrollView(.vertical, showsIndicators: true) {
                                        Text(feed.descriptionText ?? "No description available")
                                            .font(.caption)
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
                    .font(.caption)
                    .foregroundColor(.primary)
                    .tracking(1.0)
                
                // Minimal CloudKit sync indicator next to EPISODES header
                MinimalCloudKitSyncIndicator()
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("\(viewModel.currentEpisodes.count)")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    Text("episode\(viewModel.currentEpisodes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    if viewModel.hasMoreEpisodes {
                        Text("• More available")
                            .font(.caption2)
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
                .fill(Color.adaptiveSeparator)
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
                episodeList
            }
        }
    }
    


    private var episodeRows: some View {
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
    }
    
    private var episodeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    episodeRows
                
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
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }
                            .padding(.vertical, 20)
                            .transition(.opacity.combined(with: .scale))
                        } else {
                            // Instructional area with arrow and text
                            VStack(spacing: 12) {
                                // Animated up arrow
                                Image(systemName: "arrow.up")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                    .scaleEffect(endIndicatorScale)
                                    .animation(
                                        .easeInOut(duration: 1.5)
                                        .repeatForever(autoreverses: true),
                                        value: endIndicatorScale
                                    )
                                
                                // Instructional text
                                Text("Swipe up for more episodes")
                                    .font(.body)
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
            .refreshable {
                // Pull to refresh - fetch new episodes from RSS
                await viewModel.refreshCurrentFeed()
            }
            .background(Color.adaptiveBackground)
            .onAppear {
                // Start end indicator animation
                endIndicatorScale = 1.3
                viewDidAppear = true
                lastAppearanceTime = Date()
                
                // Reset scroll tracking for this view session
                hasScrolledToCurrentEpisode = false
                
                // Attempt scroll if episodes are already loaded
                scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                
                // ENHANCED: Add delayed retry for scroll to handle timing issues
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: viewModel.currentEpisodes) { _, newEpisodes in
                // Mark that episodes have loaded
                if !newEpisodes.isEmpty && !episodesDidLoad {
                    episodesDidLoad = true
                    
                    // Attempt scroll when episodes load
                    scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                    
                    // ENHANCED: Add delayed retry for scroll when episodes load
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                    }
                }
            }
            .onChange(of: selectedTab) { _, _ in
                // Reset scroll state when changing tabs so it can scroll again if needed
                hasScrolledToCurrentEpisode = false
                
                // ENHANCED: Trigger scroll to current episode when switching tabs
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    scrollToCurrentEpisodeIfNeeded(proxy: proxy)
                }
            }
        }
        .overlay(
            // Success toast notification
            VStack {
                if showSuccessToast {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.title3)
                        
                        Text(successMessage)
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 25)
                            .fill(Color.green)
                            .shadow(color: Color.adaptiveBorder.opacity(0.3), radius: 8, x: 0, y: 4)
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
            
            performScrollToEpisode(currentEpisode.id, proxy: proxy)
            
        } else {
            // Episode not in current tab - stay in current tab without scrolling
            
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

    private func syncCurrentPlayingProgress() {
        // CRITICAL FIX: Mark navigation event to protect live progress from CloudKit override
        podcastPlayer.markNavigationEvent()
        
        // Sync live progress from currently playing episode to ViewModel cache
        // This prevents progress reset when returning to episode list
        if let currentEpisode = podcastPlayer.currentEpisode,
           podcastPlayer.isPlaying || podcastPlayer.currentTime > 0 {
            let liveProgress = podcastPlayer.currentProgress
            DispatchQueue.main.async {
                self.viewModel.episodeProgress[currentEpisode.id] = liveProgress
            }
        }
    }
    
    private func handleOnAppear() {
        // CRITICAL FIX: Sync live progress from currently playing episode to cache
        // This ensures the episode list shows current live progress, not stale saved progress
        syncCurrentPlayingProgress()
        
        let currentEpisodesForThisFeed = viewModel.currentEpisodes.first?.feedId == feed.id
        
        // Initialize state for this view appearance  
        episodesDidLoad = !viewModel.currentEpisodes.isEmpty && currentEpisodesForThisFeed
                
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
        // IMMEDIATE USER FEEDBACK: Set loading state as soon as user taps play
        podcastPlayer.loadingEpisodeId = episode.id
        
        if podcastPlayer.currentEpisode?.id == episode.id {
            // Check the specific episode's progress, not the current player's progress
            let episodeProgress = podcastPlayer.getCurrentProgress(for: episode)
            print("🔄 BUTTON DEBUG 2: Current episode tap - episode.state.isPlayed = \(episode.state.isPlayed), episodeProgress = \(episodeProgress)")
            print("🔄 BUTTON DEBUG 2: episode.id = \(episode.id)")
            print("🔄 BUTTON DEBUG 2: episode.state = \(episode.state)")
            if episode.state.isPlayed || episodeProgress >= 0.99 {
                print("🔄 BUTTON DEBUG 2: Calling rewindAndPlay for current episode: \(episode.title)")
                podcastPlayer.rewindAndPlay(episode: episode)
            } else {
                print("🔄 BUTTON DEBUG 2: Calling togglePlayPause for episode: \(episode.title)")
                podcastPlayer.togglePlayPause()
            }
        } else {
            // Check if this different episode is finished and should be rewound
            let episodeProgress = podcastPlayer.getCurrentProgress(for: episode)
            print("🔄 BUTTON DEBUG 2: Different episode tap - episode.state.isPlayed = \(episode.state.isPlayed), episodeProgress = \(episodeProgress)")
            print("🔄 BUTTON DEBUG 2: episode.id = \(episode.id)")
            print("🔄 BUTTON DEBUG 2: episode.state = \(episode.state)")
            if episode.state.isPlayed || episodeProgress >= 0.99 {
                print("🔄 BUTTON DEBUG 2: Calling rewindAndPlay for finished episode: \(episode.title)")
                podcastPlayer.rewindAndPlay(episode: episode)
            } else {
                print("🔄 BUTTON DEBUG 2: Playing different episode normally: \(episode.title)")
                podcastPlayer.playEpisode(episode, feed: feed)
            }
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
                                                        .fill(Color.adaptiveBorder)
                    .frame(height: 4)
                
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geometry.size.width * CGFloat((value - inRange.lowerBound) / (inRange.upperBound - inRange.lowerBound)), height: 4)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.adaptiveBorder.opacity(0.2), radius: 2, x: 0, y: 1)
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
                    onTap: { 
                        selectedPodcast = feed
                        // Request immediate refresh when user selects a feed
                        print("🔄 USER SELECTED FEED: Requesting immediate refresh for \(feed.title)")
                        viewModel.requestFeedRefresh(feed.id)
                    },
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
        .simultaneousGesture(
            DragGesture()
                .onChanged { _ in
                    UserDefaults.standard.set(true, forKey: "isUserScrolling")
                    // Post notification for PodcastPlayer scroll detection
                    NotificationCenter.default.post(name: .userIsScrolling, object: nil)
                }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        UserDefaults.standard.set(false, forKey: "isUserScrolling")
                        // Post notification for PodcastPlayer scroll detection
                        NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                    }
                }
        )
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

// MARK: - Notification Extensions
// Note: Notification names are declared in RadioStationListView.swift to avoid duplication




