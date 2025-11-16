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

// MARK: - Notification Names
extension Notification.Name {
    static let episodeListScrolling = Notification.Name("episodeListScrolling")
    static let episodeListScrollingStopped = Notification.Name("episodeListScrollingStopped")
}

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
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var expandedFeedId: String?
    @State private var isEditing = false
    var isScrolling: Binding<Bool>
    var isFooterMenuHidden: Binding<Bool>
    
    // FORCE UI REFRESH: Observe uiRefreshTrigger to force SwiftUI re-evaluation
    @State private var uiRefreshObserver = UUID()
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    @StateObject private var radioPlayer = RadioPlayer.shared
    @EnvironmentObject private var radioStationViewModel: RadioStationViewModel
    @State private var scrollToEpisodeID: String?
    @State private var refreshID = UUID()
    @State private var selectedTab: Tab = .podcast
    @State private var isPlayerSheetPresented = false
    @State private var dataCheckTimer: Timer?
    
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
    @State private var lastPodcastFeedsCount: Int = 0
    
    // PERFORMANCE: Fast feed lookup cache
    @State private var feedLookupCache: [String: PodcastFeed] = [:]
    @State private var filteredFeedOrderCache: [String] = []
    

    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    
    // Default initializer for backward compatibility
    init() {
        self._selectedPodcast = .constant(nil)
        self.isScrolling = .constant(false)
        self.isFooterMenuHidden = .constant(false)
    }
    

    // Initializer with binding
    init(selectedPodcast: Binding<PodcastFeed?>) {
        self._selectedPodcast = selectedPodcast
        self.isScrolling = .constant(false)
        self.isFooterMenuHidden = .constant(false)
    }
    
    // Initializer with scroll detection binding
    init(selectedPodcast: Binding<PodcastFeed?>, isScrolling: Binding<Bool>) {
        self._selectedPodcast = selectedPodcast
        self.isScrolling = isScrolling
        self.isFooterMenuHidden = .constant(false)
    }
    
    // Main initializer with all parameters
    init(selectedPodcast: Binding<PodcastFeed?>, isScrolling: Binding<Bool>, isFooterMenuHidden: Binding<Bool>) {
        self._selectedPodcast = selectedPodcast
        self.isScrolling = isScrolling
        self.isFooterMenuHidden = isFooterMenuHidden
    }
    
    var body: some View {
        let _ = uiRefreshObserver // Force SwiftUI to observe uiRefreshTrigger
        return NavigationView {
               ZStack(alignment: .bottom) {
                   // Show episode list inline when a podcast is selected
                   if let selectedPodcast = selectedPodcast {
                       VStack(spacing: 0) {
                           // FORCE UI REFRESH: Hidden view that observes uiRefreshTrigger for episode player
                           Text("").hidden().id(uiRefreshObserver)
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
                       }
                   } else {
                       // Show the podcast list when no podcast is selected
                       VStack(spacing: 0) {
                           // FORCE UI REFRESH: Hidden view that observes uiRefreshTrigger
                           Text("").hidden().id(uiRefreshObserver)
                           
                           // Only show instruction text when there are no podcasts at all
                           if viewModel.podcastFeeds.isEmpty {
                               instructionText
                           }
                           
                           // Podcast progress banner - shows sync operations in real-time (including episode sync)
                           MainPodcastListBanner()
                           
                           podcastList
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
                       if !isEditing && selectedPodcast == nil {
                           HStack(spacing: 8) {
                               // Sort button
                               Button(action: {
                                   // Show confirmation alert for podcast sorting
                                   alertManager.showCustomAlert(for: .confirmPodcastSortChange, deleteAction: {
                                       viewModel.sortFeedsAlphabetically()
                                   })
                               }) {
                                   Image(systemName: viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                                       .foregroundColor(.adaptivePrimaryText)
                                       .font(.system(size: 16, weight: .medium))
                                       .frame(width: 32, height: 32)
                               }
                               
                               // Plus button
                               Button(action: { showingSearchPodcasts = true }) {
                                   Image(systemName: "plus")
                                       .foregroundColor(.adaptivePrimaryText)
                                       .font(.system(size: 16, weight: .medium))
                                       .frame(width: 32, height: 32)
                               }
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
                   // INSTANT BACK NAVIGATION: Handle back navigation immediately without any delays
                   if newValue == nil {
                       // User is navigating back - handle this instantly on main thread
                       print("🔙 INSTANT BACK: User navigating back to podcast list")
                       
                       // IMMEDIATE: Clear episode loading state first for instant UI update
                       if podcastPlayer.loadingEpisodeId != nil {
                           podcastPlayer.loadingEpisodeId = nil
                           print("🔙 INSTANT BACK: Cleared episode loading state immediately")
                       }
                       
                       // DEFERRED: Move heavy operations to background to prevent UI blocking
                       Task.detached(priority: .background) {
                           // Cancel any pending operations in background
                           await MainActor.run {
                               self.viewModel.cancelPendingOperations()
                           }
                           print("🔙 BACKGROUND: Cleared pending operations after back navigation")
                       }
                       
                       return // Exit immediately to prevent any blocking operations
                   }
                   
                   // FORWARD NAVIGATION: Only trigger refresh when selecting a podcast
                   if let podcast = newValue {
                       print("📱 FORWARD: User selected podcast: \(podcast.title)")
                       // When selectedPodcast is set from outside (like from ContentView),
                       // automatically show the episode list and request a refresh
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
           .onReceive(NotificationCenter.default.publisher(for: .episodeListScrolling)) { _ in
               // Episode list is scrolling - hide TabView and show home button
               if !isScrolling.wrappedValue {
                   isScrolling.wrappedValue = true
                   // FIRST-TIME PLAYBACK PROTECTION: Only set scroll state, let ContentView handle TabView hiding
                   // REMOVED: Direct isFooterMenuHidden assignment - let ContentView shouldHideFooterMenu logic handle this
               }
           }
           .onReceive(NotificationCenter.default.publisher(for: .episodeListScrollingStopped)) { _ in
               // Episode list stopped scrolling - hide home button after delay
               DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                   isScrolling.wrappedValue = false
                   // Note: Don't reset isFooterMenuHidden here - let home button control it
                   
                   // Post notification for episode title scrolling
                   NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
               }
           }
    }
    
    private var instructionText: some View {
        Text("Add podcasts to get started")
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
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
            
            Group {
                if viewModel.podcastFeeds.isEmpty {
                    // Beautiful empty state
                    emptyStateView
                } else {
                    ScrollViewReader { proxy in
                        List {
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
                        .id(feedId)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isEditing {
                                Button {
                                    print("🔄 SHARE BUTTON TAPPED for feed: \(feed.title)")
                                    sharePodcastFeed(feed)
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                                
                                Button(role: .destructive) {
                                    print("🗑️ DELETE BUTTON TAPPED for feed: \(feed.title)")
                                    podcastToDelete = feed
                                    showingDeleteConfirmation = true
                                    print("🗑️ Delete confirmation should show now")
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !isEditing {
                                Button {
                                    print("✏️ EDIT BUTTON TAPPED for feed: \(feed.title)")
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
                        .disabled(isEditing)
                        .opacity(isEditing ? 0.6 : 1.0)
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
                    } // End of ScrollViewReader
                } // End of else
            } // End of Group
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)  // Add extra space at the bottom
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10) // Increase minimum distance to avoid interfering with swipe actions
                    .onChanged { value in
                        // Only trigger for primarily vertical scrolling (not horizontal swipes)
                        let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                        if isVerticalScroll {
                            // Update when drag distance is significant enough
                            if !isScrolling.wrappedValue {
                                isScrolling.wrappedValue = true
                                // FIRST-TIME PLAYBACK PROTECTION: Only set scroll state, let ContentView handle TabView hiding
                                // REMOVED: Direct isFooterMenuHidden assignment - let ContentView shouldHideFooterMenu logic handle this
                            }
                            UserDefaults.standard.set(true, forKey: "isUserScrolling")
                            // Post notification for PodcastPlayer scroll detection
                            NotificationCenter.default.post(name: .userIsScrolling, object: nil)
                        }
                    }
                    .onEnded { value in
                        // Only trigger for primarily vertical scrolling (not horizontal swipes)
                        let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                        if isVerticalScroll {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                isScrolling.wrappedValue = false
                                // Note: Don't reset isFooterMenuHidden here - let home button control it
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                UserDefaults.standard.set(false, forKey: "isUserScrolling")
                                // Post notification for PodcastPlayer scroll detection
                                NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                            }
                        }
                    }
            )
            .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
                Button("Cancel", role: .cancel) {
                    print("🗑️ DELETE CANCELLED for: \(podcast.title)")
                }
                Button("Delete", role: .destructive) {
                    print("🗑️ DELETE CONFIRMED for: \(podcast.title)")
                    currentDeletingFeedTitle = podcast.title
                    viewModel.deletePodcastFeed(podcast)
                    print("🗑️ Called viewModel.deletePodcastFeed")
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
        
        // No need for refreshID = UUID() or refreshAllFeeds() since moveFeed now sends proper notifications
        // and objectWillChange.send() is sufficient for UI updates without disrupting TabView state
        viewModel.objectWillChange.send()
    }
    
    private func onAppear() {
        os_log("PodcastListView appeared", log: log, type: .info)
        
        // CRITICAL FIX: Sync live progress from currently playing episode to cache
        // This ensures the episode list shows current live progress, not stale saved progress
        syncCurrentPlayingProgress()
        
        // PERFORMANCE: Initialize caches immediately for fast rendering
        initializeCaches()
        
        // PERFORMANCE: Only trigger CloudKit sync if we don't have cached episodes
        // This prevents expensive sync operations when just switching between cached tabs
        let needsCloudKitSync = viewModel.currentEpisodes.isEmpty && viewModel.podcastFeeds.isEmpty
        
        if needsCloudKitSync {
            // DEFERRED: Move heavy CloudKit sync off main thread with lower priority
            Task.detached(priority: .background) {
                // Add small delay to let UI render first
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                await viewModel.automaticCloudKitSync()
            }
        } else {
            print("⚡ PERFORMANCE: Skipping CloudKit sync - using cached episode data")
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
    
    // MARK: - Empty State View
    
    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 30)
                
                // Animated icon
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 140, height: 140)
                    
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 70))
                        .foregroundColor(.blue)
                        .symbolRenderingMode(.hierarchical)
                }
                .padding(.bottom, 32)
                
                // Headline
                Text("Start Your Podcast Journey")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.adaptivePrimaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
                
                // Description
                Text("Discover and subscribe to your favorite podcasts. Stay updated with the latest episodes and never miss a beat.")
                    .font(.system(size: 16))
                    .foregroundColor(.adaptiveSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                
                // Primary action button
                Button(action: {
                    showingSearchPodcasts = true
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Browse Podcasts")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(14)
                    .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 16)
                
                // Secondary action button
                Button(action: {
                    showingAddPodcast = true
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Add by RSS URL")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(14)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
                
                // Feature highlights
                VStack(spacing: 20) {
                    featureRow(
                        icon: "cloud.fill",
                        title: "Cloud Sync",
                        description: "Your subscriptions sync across all your devices"
                    )
                    
                    featureRow(
                        icon: "arrow.down.circle.fill",
                        title: "Offline Listening",
                        description: "Download episodes and listen anywhere"
                    )
                }
                .padding(.horizontal, 40)
                
                Spacer()
                    .frame(height: 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.adaptiveBackground)
    }
    
    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(.adaptiveSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
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
        // PERFORMANCE: Use optimized feed refresh instead of expensive fetchEpisodes
        viewModel.requestFeedRefresh(feed.id)
        
        // Get episodes immediately from cache or current episodes
        let episodes = viewModel.feedIsolationManager.getEpisodesForFeed(feed.id) ?? viewModel.currentEpisodes.filter { $0.feedId == feed.id }
        if let latestEpisode = episodes.first {
            podcastPlayer.playEpisode(latestEpisode, feed: feed)
        } else {
            print("⚠️ No episodes available for feed: \(feed.title)")
        }
    }
    
    // PERFORMANCE: Initialize all caches for fast rendering
    private func initializeCaches() {
        // Initialize feed lookup cache
        feedLookupCache = Dictionary(uniqueKeysWithValues: viewModel.podcastFeeds.map { ($0.id, $0) })
        
        // Initialize filtered caches
        cachedFilteredPodcasts = viewModel.podcastFeeds
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
        if viewModel.podcastFeeds.count == lastPodcastFeedsCount &&
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
            self.lastPodcastFeedsCount = self.viewModel.podcastFeeds.count
        }
        
        return result
    }
    
    // PERFORMANCE: Optimized memoized filtered podcasts
    private var filteredPodcasts: [PodcastFeed] {
        // Use cached result if podcast count hasn't changed
        if viewModel.podcastFeeds.count == lastPodcastFeedsCount {
            return cachedFilteredPodcasts
        }
        
        // Return all feeds (no global search anymore)
        return viewModel.podcastFeeds
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
    
    // MARK: - Share Functionality
    private func sharePodcastFeed(_ feed: PodcastFeed) {
        let subject = "Check out this podcast: \(feed.title)"
        let body = """
        I thought you might enjoy this podcast!
        
        \(feed.title)
        \(feed.descriptionText?.isEmpty == false ? "\n\(feed.descriptionText!)\n" : "")
        Feed URL: \(feed.url)
        """
        
        // Let iOS handle the sharing - it will show available apps that can handle RSS feeds
        
        // Create a simple URL that can be handled by podcast apps
        let feedURL = URL(string: feed.url)!
        
        let activityController = UIActivityViewController(
            activityItems: [subject, body, feedURL],
            applicationActivities: nil
        )
        
        // Configure for specific sharing options
        activityController.completionWithItemsHandler = { (activityType: UIActivity.ActivityType?, completed: Bool, returnedItems: [Any]?, error: Error?) in
            if completed {
                print("Successfully shared podcast: \(feed.title)")
            }
        }
        
        // Present the share sheet
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            // Handle iPad presentation
            if let popover = activityController.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            rootViewController.present(activityController, animated: true)
        }
    }
    
}

// MARK: - Share Content Handler
class ShareContent: NSObject, UIActivityItemSource {
    private let subject: String
    private let body: String
    private let url: String
    
    init(subject: String, body: String, url: String) {
        self.subject = subject
        self.body = body
        self.url = url
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return body
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Handle different sharing types
        switch activityType {
        case .mail:
            // For email, return the body text (subject will be handled separately)
            return body
        case .message:
            // For SMS, return the body text
            return body
        case .copyToPasteboard:
            // For copy to clipboard, return the feed URL for easy pasting into podcast apps
            return url
        default:
            // For other sharing options (social media, etc.), return the feed URL
            return url
        }
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        // Provide subject for email
        if activityType == .mail {
            return subject
        }
        return ""
    }
}

// MARK: - Custom Search Bar
struct CustomSearchBar: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var placeholder: String = "Search..."
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isTextFieldFocused: Bool
    
    private var searchBarBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6)
    }
    
    private var textColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var iconColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    var body: some View {
        // Search field with icons
        HStack(spacing: 8) {
            // Magnifying glass icon
            Image(systemName: "magnifyingglass")
                .foregroundColor(iconColor)
                .font(.system(size: 16, weight: .medium))
            
            // Text field
            TextField(placeholder, text: $searchText)
                .font(.system(size: 16))
                .foregroundColor(textColor)
                .focused($isTextFieldFocused)
                .submitLabel(.search)
                .onChange(of: searchText) { _, newValue in
                    // Limit search text and trigger episode search
                    let limitedText = String(newValue.prefix(100))
                    if limitedText != searchText {
                        searchText = limitedText
                    }
                    PodcastViewModel.shared.searchSavedEpisodesAcrossPodcasts(searchText)
                }
            
            // Clear button when text exists
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    PodcastViewModel.shared.searchSavedEpisodesAcrossPodcasts("")
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(iconColor)
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(searchBarBackgroundColor)
        .cornerRadius(12)
        .onAppear {
            // Auto-focus when search bar appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: isPresented) { _, newValue in
            // Auto-focus when search is presented
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isTextFieldFocused = true
                }
            } else {
                isTextFieldFocused = false
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
        .padding(.horizontal, 8)
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
        .padding(.trailing, -5)
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

// Use a class to persist the export URL across SwiftUI state invalidations
class ExportURLHolder: ObservableObject {
    @Published var exportURL: URL?
    
    func setURL(_ url: URL) {
        exportURL = url
    }
    
    func clearURL() {
        exportURL = nil
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
    @State private var localLoadingState = false // For play button loading animation
    @State private var swipeOffset: CGFloat = 0 // Track swipe position for custom swipe actions
    @State private var isSwipeGestureActive = false // Track if we're in a horizontal swipe
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var pendingExportURL: URL?
    @StateObject private var exportURLHolder = ExportURLHolder()
    private let buttonSize: CGFloat = 22
    private let rowHeight: CGFloat = 70
    private let swipeActionWidth: CGFloat = 180 // Width for action buttons area (circular design)
    
    // FORCE UI REFRESH: Get real-time episode state from viewModel
    private var currentEpisode: PodcastEpisode {
        // Force SwiftUI to re-evaluate when uiRefreshTrigger changes
        let refreshTrigger = viewModel.uiRefreshTrigger
        
        // 🛡️ CONTAMINATION PREVENTION: Only access currentEpisodes if this episode belongs to current feed
        guard episode.feedId == viewModel.selectedFeedId else {
            return episode
        }
        
        // 🔄 REAL-TIME UPDATE: Search for updated episode in currentEpisodes to get latest state
        // This ensures we have the updated localFilePath after downloads complete
        if let foundEpisode = viewModel.currentEpisodes.first(where: { $0.id == episode.id }) {
            // Debug logging to track UI refresh
            if foundEpisode.state.isFavorite != episode.state.isFavorite {
                print("🎯 EPISODE ROW: Episode \(episode.id) favorite changed: \(episode.state.isFavorite) -> \(foundEpisode.state.isFavorite) (trigger: \(refreshTrigger))")
            }
            return foundEpisode
        }
        
        return episode
    }
    
    // REAL-TIME PROGRESS: Use computed property that always reflects current state
    private var currentProgress: Double {
        if isPlaying {
            return podcastPlayer.currentProgress
        } else {
            // CRITICAL FIX: Always use EpisodeStateManager as source of truth for saved progress
            // This ensures progress bar matches exactly where progress was last saved
            return EpisodeStateManager.shared.getProgress(for: episode.id)
        }
    }
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        viewModel.downloadProgress[episode.id] != nil && viewModel.downloadProgress[episode.id]! > 0 && viewModel.downloadProgress[episode.id]! < 1
    }
    
    // REAL-TIME DOWNLOAD STATE: Always check EpisodeStateManager for current download status
    private var isDownloaded: Bool {
        // Force refresh trigger to re-evaluate when downloads change
        let _ = viewModel.uiRefreshTrigger
        return EpisodeStateManager.shared.isDownloaded(episode.id)
    }
    
    // Computed property for checking if episode is marked as played
    private var isEpisodePlayed: Bool {
        EpisodeStateManager.shared.getState(for: episode.id) == .played
    }
    
    // Static formatter to avoid recreation
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
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
                let progressPercent = Int((viewModel.downloadProgress[episode.id] ?? 0) * 100)
                let isDownloadBanner = bannerAlertMessage.hasPrefix("Download")
                
                HStack(spacing: 8) {
                    Text(isDownloadBanner && isDownloading ? "Downloading: \(progressPercent)%" : bannerAlertMessage)
                        .font(.caption)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .foregroundColor(.white)
                    
                    if isDownloadBanner && isDownloading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity)
                .background(isDownloadBanner ? Color.blue : Color.red)
            }
            
            // ZStack for swipe-to-reveal action buttons
            ZStack(alignment: .trailing) {
                // Action buttons behind the row
                HStack(spacing: 0) {
                    Spacer()
                    swipeActionButtons
                        .frame(width: swipeActionWidth)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                
                // Main row content with opaque background
                rowContent
                    .background(
                        // Use system background color which is always opaque
                        Color(UIColor.systemBackground)
                    )
                    .cornerRadius(8)
                    .offset(x: swipeOffset)
                    .gesture(
                        // Use regular gesture to allow context menu long press to work
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                let horizontalDrag = value.translation.width
                                let verticalDrag = value.translation.height
                                
                                // Determine gesture direction early
                                if !isSwipeGestureActive {
                                    // Check if this is clearly a horizontal swipe
                                    if abs(horizontalDrag) > 20 && abs(horizontalDrag) > abs(verticalDrag) * 2 {
                                        isSwipeGestureActive = true
                                        
                                        // Close any other swiped row when starting a new swipe
                                        if viewModel.swipedEpisodeId != nil && viewModel.swipedEpisodeId != episode.id {
                                            viewModel.swipedEpisodeId = nil
                                        }
                                    }
                                }
                                
                                // Only handle offset if we've determined this is a horizontal swipe
                                if isSwipeGestureActive {
                                    // Constrain swipe: negative (left) up to action width, no positive (right) past 0
                                    if horizontalDrag < 0 {
                                        swipeOffset = max(horizontalDrag, -swipeActionWidth)
                                    } else if swipeOffset < 0 {
                                        // Allow swiping back right to close
                                        swipeOffset = min(0, swipeOffset + horizontalDrag)
                                    }
                                }
                            }
                            .onEnded { value in
                                let horizontalDrag = value.translation.width
                                let verticalDrag = value.translation.height
                                
                                // Only handle if we activated the swipe gesture
                                if isSwipeGestureActive {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        // If swiped more than halfway, snap to open; otherwise close
                                        if swipeOffset < -swipeActionWidth / 2 {
                                            swipeOffset = -swipeActionWidth
                                            viewModel.swipedEpisodeId = episode.id // Mark this row as swiped
                                        } else {
                                            swipeOffset = 0
                                            // Clear if this was the swiped row
                                            if viewModel.swipedEpisodeId == episode.id {
                                                viewModel.swipedEpisodeId = nil
                                            }
                                        }
                                    }
                                }
                                
                                // Reset gesture state
                                isSwipeGestureActive = false
                            }
                    )
                    .onChange(of: viewModel.swipedEpisodeId) { newId in
                        // Close this row if another row was swiped
                        if newId != episode.id && swipeOffset != 0 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                swipeOffset = 0
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .clipped() // Clip the action buttons that extend beyond the row
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if isDownloaded {
                // Export Audio button
                Button(action: {
                    exportEpisodeFile()
                }) {
                    Label("Export Audio", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            // Try URLs in order of preference: persistent holder first, then fallbacks
            if let fileURL = exportURLHolder.exportURL ?? shareURL ?? pendingExportURL {
                ExportSheet(fileURL: fileURL) {
                    showingShareSheet = false
                    // Clean up temp file after sharing
                    if fileURL.path.contains("tmp/") {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    // Clear all URL references
                    self.exportURLHolder.clearURL()
                    self.shareURL = nil
                    self.pendingExportURL = nil
                }
            } else {
                VStack {
                    Text("Error: No file to share")
                        .foregroundColor(.red)
                    Text("Export URL was lost. Please try again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Dismiss") {
                        showingShareSheet = false
                    }
                    .padding(.top)
                }
                .padding()
            }
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Downloaded Episode"),
                message: Text("Are you sure you want to delete this downloaded episode?"),
                primaryButton: .destructive(Text("Delete")) {
                    Task {
                        await viewModel.deleteDownloadedEpisode(episode)
                    }
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                },
                secondaryButton: .cancel() {
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeProgressChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodePlayedChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeFavoriteChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                refreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("EpisodeDownloadChangedInstantly"))) { notification in
            if let userInfo = notification.userInfo,
               let episodeId = userInfo["episodeId"] as? String,
               episodeId == episode.id {
                refreshTrigger = UUID()
            }
        }
    }
    
    private var rowContent: some View {
        VStack(spacing: 0) {
            // Responsive Layout: Play Button | Episode Info | Status Badges
            HStack(alignment: .top, spacing: 12) {
                
                // COLUMN 1: Play/Pause button (Fixed width)
                // Calculate progress once for both action and UI
                let currentProgress = podcastPlayer.getCurrentProgress(for: episode)
                
                Button(action: {
                    // FIX: Use EpisodeStateManager as source of truth for button behavior
                    let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
                    let isPlayedByState = episodeState == .played
                    let isCompletedByProgress = currentProgress >= 0.99
                    
                    if isPlayedByState || isCompletedByProgress {
                        // Start loading animation for rewind and play
                        localLoadingState = true
                        
                        // Add a small delay to ensure the loading animation is visible
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            podcastPlayer.rewindAndPlay(episode: episode)
                        }
                    } else if isPlaying {
                        onStop()
                    } else {
                        // Start loading animation for play
                        localLoadingState = true
                        
                        // Add a small delay to ensure the loading animation is visible
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            onPlay()
                        }
                    }
                }) {
                    // FIX: Use EpisodeStateManager for consistent button display
                    let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
                    let isPlayedByState = episodeState == .played
                    let isCompletedByProgress = currentProgress >= 0.99
                    let shouldShowRewind = isPlayedByState || isCompletedByProgress
                    
                    // Regular play/pause/replay button with consistent state logic
                    Image(systemName: shouldShowRewind ? "arrow.counterclockwise.circle.fill" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                        .resizable()
                        .frame(width: buttonSize + 6, height: buttonSize + 6) // Larger visual button
                        .foregroundColor(shouldShowRewind ? .adaptiveSecondaryText : (isPlaying ? .blue : .green))
                        .opacity((localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && !isPlaying)) ? 0.3 : 1.0) // Dim button when loading
                        .scaleEffect((localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && !isPlaying)) ? 0.9 : 1.0) // Shrink button when loading
                        .animation(.easeInOut(duration: 0.1), value: localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && !isPlaying))
                }
                .frame(width: 44, height: 44) // Fixed play button area
                .overlay(
                    // Loading overlay with spinning animation
                    ZStack {
                        if localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && !isPlaying) {
                            // Debug: Print when loading overlay is shown
                            let _ = print("🎬 LOADING OVERLAY: Showing for episode \(episode.title), localLoadingState: \(localLoadingState), loadingEpisodeId: \(podcastPlayer.loadingEpisodeId ?? "nil")")
                            
                            // Semi-transparent circular overlay
                            Circle()
                                .fill(Color.blue.opacity(0.8))
                                .frame(width: 44, height: 44)
                            
                            // Loading spinner
                            ProgressView()
                                .scaleEffect(1.0)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: localLoadingState)
                )
                .padding(.top, 2) // Align with first line of text
                .onChange(of: isPlaying) { _, newValue in
                    // Clear loading state when episode starts playing (with minimum display time)
                    if newValue {
                        // Ensure loading animation is visible for at least 300ms
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            localLoadingState = false
                        }
                    }
                }
                .onChange(of: podcastPlayer.loadingEpisodeId) { _, newValue in
                    // Clear loading state when loading completes or changes
                    if newValue != episode.id {
                        localLoadingState = false
                    }
                }
                
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
                    
                    // Progress bar - only show on currently playing episode
                    if isPlaying && currentProgress > 0 && currentProgress < 1.0 && !isEpisodePlayed {
                        ProgressView(value: currentProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
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
                .contentShape(Rectangle())
                .onTapGesture {
                    // Start local loading state when tapped
                    print("🎬 ROW TAP LOADING: Setting localLoadingState = true for episode: \(episode.title)")
                    localLoadingState = true
                    onPlay()
                }
                
                // Visual status indicators (download/favorite badges)
                VStack(alignment: .trailing, spacing: 4) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.body)
                            .foregroundColor(.green)
                    }
                    
                    if currentEpisode.state.isFavorite {
                        Image(systemName: "bookmark.fill")
                            .font(.body)
                            .foregroundColor(.orange)
                    }
                }
                .frame(width: 28)
                .padding(.top, 2)
            }
            .frame(minHeight: 64) // Minimum height for touch targets
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
    }
    
    // Swipe action buttons that appear behind the row
    private var swipeActionButtons: some View {
        HStack(spacing: 16) {
            // Favorite button
            Button {
                viewModel.toggleFavorite(for: episode)
                withAnimation {
                    swipeOffset = 0
                    viewModel.swipedEpisodeId = nil
                }
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(currentEpisode.state.isFavorite ? Color.orange : Color.purple)
                            .frame(width: 56, height: 56)
                        
                        Image(systemName: currentEpisode.state.isFavorite ? "bookmark.slash.fill" : "bookmark.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    
                    Text(currentEpisode.state.isFavorite ? "Unfavorite" : "Favorite")
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
            }
            
            // Download/Delete button
            if isDownloaded {
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: "trash.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        
                        Text("Delete")
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                }
            } else {
                Button {
                    handleDownloadAction()
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isDownloading ? Color.gray : Color.blue)
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        
                        Text("Download")
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                }
                .disabled(isDownloading)
            }
        }
        .padding(.horizontal, 12)
    }
    
    
    private var episodeStatusChip: some View {
        Group {
            // CRITICAL FIX: Always use EpisodeStateManager as the source of truth for status display
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let isPlayedByState = episodeState == .played
            let isCompletedByProgress = currentProgress >= 0.99 && !isPlaying
            
            // LOG: Debug status determination for troubleshooting
            let _ = print("📊 STATUS DEBUG [\(episode.id.prefix(8))]: state=\(episodeState.rawValue), progress=\(String(format: "%.3f", currentProgress)), isPlaying=\(isPlaying), episode.state.isPlayed=\(episode.state.isPlayed)")
            
            if isPlayedByState || isCompletedByProgress {
                Text("Played")
                    .foregroundColor(.adaptivePrimaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.adaptiveBorder))
            } else if isPlaying {
                Text("Playing")
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
            } else if episodeState == .inProgress {
                // CRITICAL FIX: Use episodeState instead of currentProgress for "IN PROGRESS" determination
                // This ensures the status shows immediately when an episode is paused
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
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
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
            
            if !episode.state.isDownloaded && !isDownloading {
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
    
    private func showBannerAlert(message: String, autoDismiss: Bool = true) {
        bannerAlertMessage = message
        showingBannerAlert = true
        
        // Only auto-dismiss if specified (not for download banners)
        if autoDismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingBannerAlert = false
            }
        }
    }
    
    private func handleDownloadAction() {
        // Add haptic feedback for swipe action
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        if !episode.state.isDownloaded && !isDownloading {
            // Check subscription for download feature
            if !subscriptionManager.isSubscribedOrInTrial {
                showBannerAlert(message: "Podcast downloads are available with StreamRadios Pro. Upgrade to download episodes for offline listening.")
                return
            }
            
            // Show download banner that stays visible during download
            showBannerAlert(message: "Download started for \(episode.title)", autoDismiss: false)
            
            viewModel.downloadEpisode(episode) { result in
                // Download state is managed by the progress tracking
                print("Download completed for episode: \(episode.title)")
                
                // Hide banner when download completes
                DispatchQueue.main.async {
                    showingBannerAlert = false
                }
            }
        }
    }
    
    private func exportEpisodeFile() {
        // Check if episode has a local file path
        guard let localFilePath = currentEpisode.localFilePath,
              !localFilePath.isEmpty,
              FileManager.default.fileExists(atPath: localFilePath) else {
            showBannerAlert(message: "Downloaded file not found")
            return
        }
        
        let fileURL = URL(fileURLWithPath: localFilePath)
        
        // Create a temporary copy with .mp3 extension to ensure compatibility
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = currentEpisode.title.replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        let tempURL = tempDir.appendingPathComponent("\(fileName).mp3")
        
        do {
            // Remove existing temp file if it exists
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            
            // Copy the file to temp directory with .mp3 extension
            try FileManager.default.copyItem(at: fileURL, to: tempURL)
            
            // Verify the file was copied successfully
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                showBannerAlert(message: "Failed to prepare file for export")
                return
            }
            
            // Set the export URL using the persistent holder and show the share sheet
            DispatchQueue.main.async {
                // Use the persistent holder that won't be affected by SwiftUI state invalidation
                self.exportURLHolder.setURL(tempURL)
                
                // Also set the state variables as backup (though they may get invalidated)
                self.shareURL = tempURL
                self.pendingExportURL = tempURL
                
                // Present the sheet
                self.showingShareSheet = true
            }
            
        } catch {
            showBannerAlert(message: "Failed to prepare file for export")
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
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var pendingExportURL: URL?
    @State private var swipeOffset: CGFloat = 0 // Track swipe position for custom swipe actions
    @State private var isSwipeGestureActive = false // Track if we're in a horizontal swipe
    @StateObject private var exportURLHolder = ExportURLHolder()
    
    // FORCE UI REFRESH: Get real-time episode state from viewModel
    private var currentEpisode: PodcastEpisode {
        // Force SwiftUI to re-evaluate when uiRefreshTrigger changes
        let refreshTrigger = viewModel.uiRefreshTrigger
        
        // 🛡️ CONTAMINATION PREVENTION: Only access currentEpisodes if this episode belongs to current feed
        guard episode.feedId == viewModel.selectedFeedId else {
            return episode
        }
        
        // 🔄 REAL-TIME UPDATE: Search for updated episode in currentEpisodes to get latest state
        // This ensures we have the updated localFilePath after downloads complete
        if let foundEpisode = viewModel.currentEpisodes.first(where: { $0.id == episode.id }) {
            // Debug logging to track UI refresh
            if foundEpisode.state.isFavorite != episode.state.isFavorite {
            }
            return foundEpisode
        }
        
        return episode
    }
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
            // CRITICAL FIX: Always use EpisodeStateManager as source of truth for saved progress
            // This ensures progress bar matches exactly where progress was last saved
            return EpisodeStateManager.shared.getProgress(for: episode.id)
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
        formatter.timeStyle = .short
        return formatter
    }()
    
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    private let buttonSize: CGFloat = 22
    private let swipeActionWidth: CGFloat = 180 // Width for action buttons area (circular design)
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        viewModel.downloadProgress[episode.id] != nil && viewModel.downloadProgress[episode.id]! > 0 && viewModel.downloadProgress[episode.id]! < 1
    }
    
    // REAL-TIME DOWNLOAD STATE: Always check EpisodeStateManager for current download status
    private var isDownloaded: Bool {
        // Force refresh trigger to re-evaluate when downloads change
        let _ = viewModel.uiRefreshTrigger
        return EpisodeStateManager.shared.isDownloaded(episode.id)
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
        .contextMenu {
            if isDownloaded {
                // Export Audio button
                Button(action: {
                    exportEpisodeFile()
                }) {
                    Label("Export Audio", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            // Try URLs in order of preference: persistent holder first, then fallbacks
            if let fileURL = exportURLHolder.exportURL ?? shareURL ?? pendingExportURL {
                ExportSheet(fileURL: fileURL) {
                    showingShareSheet = false
                    // Clean up temp file after sharing
                    if fileURL.path.contains("tmp/") {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    // Clear all URL references
                    self.exportURLHolder.clearURL()
                    self.shareURL = nil
                    self.pendingExportURL = nil
                }
            } else {
                VStack {
                    Text("Error: No file to share")
                        .foregroundColor(.red)
                    Text("Export URL was lost. Please try again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Dismiss") {
                        showingShareSheet = false
                    }
                    .padding(.top)
                }
                .padding()
            }
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Download"),
                message: Text("Are you sure you want to delete the downloaded file? The episode will remain in the list but will need to be downloaded again to listen offline."),
                primaryButton: .destructive(Text("Delete Download")) {
                    Task {
                        await viewModel.deleteDownloadedEpisode(episode)
                    }
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                },
                secondaryButton: .cancel() {
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                }
            )
        }
    }
    
    private var bannerAlertView: some View {
        let progressPercent = Int((viewModel.downloadProgress[episode.id] ?? 0) * 100)
        let isDownloadBanner = bannerAlertMessage.hasPrefix("Download")
        
        return HStack(spacing: 8) {
            Text(isDownloadBanner && isDownloading ? "Downloading: \(progressPercent)%" : bannerAlertMessage)
                .font(.caption)
                .foregroundColor(.white)
            
            if isDownloadBanner && isDownloading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(isDownloadBanner ? Color.blue : Color.red)
        .cornerRadius(6)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    
    // MARK: - Optimized Episode Card Design
    private var episodeCard: some View {
        ZStack(alignment: .trailing) {
            // Action buttons behind the row
            HStack(spacing: 0) {
                Spacer()
                swipeActionButtons
                    .frame(width: swipeActionWidth)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Main card content with opaque background
            VStack(spacing: 0) {
                // Simplified episode content without expensive gradients
                Group {
                    episodeContent
                }
                
                // Simple separator
                Rectangle()
                    .fill(Color.adaptiveSeparator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
            }
            .background(
                // Use system background color which is always opaque
                Color(UIColor.systemBackground)
            )
            .cornerRadius(8)
            .offset(x: swipeOffset)
            .gesture(
                // Use regular gesture to allow context menu long press to work
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        let horizontalDrag = value.translation.width
                        let verticalDrag = value.translation.height
                        
                        // Determine gesture direction early
                        if !isSwipeGestureActive {
                            // Check if this is clearly a horizontal swipe
                            if abs(horizontalDrag) > 20 && abs(horizontalDrag) > abs(verticalDrag) * 2 {
                                isSwipeGestureActive = true
                                
                                // Close any other swiped row when starting a new swipe
                                if viewModel.swipedEpisodeId != nil && viewModel.swipedEpisodeId != episode.id {
                                    viewModel.swipedEpisodeId = nil
                                }
                            }
                        }
                        
                        // Only handle offset if we've determined this is a horizontal swipe
                        if isSwipeGestureActive {
                            // Constrain swipe: negative (left) up to action width, no positive (right) past 0
                            if horizontalDrag < 0 {
                                swipeOffset = max(horizontalDrag, -swipeActionWidth)
                            } else if swipeOffset < 0 {
                                // Allow swiping back right to close
                                swipeOffset = min(0, swipeOffset + horizontalDrag)
                            }
                        }
                    }
                    .onEnded { value in
                        let horizontalDrag = value.translation.width
                        let verticalDrag = value.translation.height
                        
                        // Only handle if we activated the swipe gesture
                        if isSwipeGestureActive {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                // If swiped more than halfway, snap to open; otherwise close
                                if swipeOffset < -swipeActionWidth / 2 {
                                    swipeOffset = -swipeActionWidth
                                    viewModel.swipedEpisodeId = episode.id // Mark this row as swiped
                                } else {
                                    swipeOffset = 0
                                    // Clear if this was the swiped row
                                    if viewModel.swipedEpisodeId == episode.id {
                                        viewModel.swipedEpisodeId = nil
                                    }
                                }
                            }
                        }
                        
                        // Reset gesture state
                        isSwipeGestureActive = false
                    }
            )
            .onChange(of: viewModel.swipedEpisodeId) { newId in
                // Close this row if another row was swiped
                if newId != episode.id && swipeOffset != 0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        swipeOffset = 0
                    }
                }
            }
        }
        .clipped() // Clip the action buttons that extend beyond the row
    }
    
    // Swipe action buttons that appear behind the row
    private var swipeActionButtons: some View {
        HStack(spacing: 16) {
            // Favorite button
            Button {
                viewModel.toggleFavorite(for: episode)
                withAnimation {
                    swipeOffset = 0
                    viewModel.swipedEpisodeId = nil
                }
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(currentEpisode.state.isFavorite ? Color.orange : Color.purple)
                            .frame(width: 56, height: 56)
                        
                        Image(systemName: currentEpisode.state.isFavorite ? "bookmark.slash.fill" : "bookmark.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    
                    Text(currentEpisode.state.isFavorite ? "Unfavorite" : "Favorite")
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
            }
            
            // Download/Delete button
            if isDownloaded {
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: "trash.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        
                        Text("Delete")
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                }
            } else {
                Button {
                    handleDownloadAction()
                    withAnimation {
                        swipeOffset = 0
                        viewModel.swipedEpisodeId = nil
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isDownloading ? Color.gray : Color.blue)
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        
                        Text("Download")
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                }
                .disabled(isDownloading)
            }
        }
        .padding(.horizontal, 12)
    }
    
    private var episodeContent: some View {
        // Responsive Layout: Play Button | Episode Info | Action Buttons
        HStack(alignment: .top, spacing: 12) {
            
            // COLUMN 1: Play button (Fixed width) with enhanced loading indicator
            ZStack {
                Button(action: isPlaying ? onStop : {
                    // Start local loading state when play button tapped
                    print("🎬 OPTIMIZED LOADING: Setting localLoadingState = true for play")
                    localLoadingState = true
                    
                    // Add a small delay to ensure the loading animation is visible
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        onPlay()
                    }
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
                            // FIX: Use real-time EpisodeStateManager for button display
                            let currentEpisodeState = EpisodeStateManager.shared.getState(for: episode.id)
                            let currentButtonIcon = isPlaying ? "pause.fill" : currentEpisodeState.buttonImage
                            let currentButtonColor = isPlaying ? .blue : currentEpisodeState.buttonColor
                            
                            // Regular play/pause button with real-time state
                            Image(systemName: currentButtonIcon)
                                .font(.title2)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1) // Cap icon size
                                .foregroundColor(currentButtonColor)
                                .opacity((localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && podcastPlayer.loadingEpisodeId != nil)) ? 0.3 : 1.0) // Dim button when loading
                                .scaleEffect((localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && podcastPlayer.loadingEpisodeId != nil)) ? 0.9 : 1.0) // Shrink button when loading
                                .animation(.easeInOut(duration: 0.1), value: localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && podcastPlayer.loadingEpisodeId != nil))
                        }
                    }
                }
                .frame(width: 44, height: 44) // Fixed play button area
                
                // Loading overlay similar to radio station implementation
                let shouldShowLoading = localLoadingState || (podcastPlayer.loadingEpisodeId == episode.id && podcastPlayer.loadingEpisodeId != nil)
                
                if shouldShowLoading {
                    ZStack {
                        // Semi-transparent circular overlay with more visibility
                        Circle()
                            .fill(Color.blue.opacity(0.8))
                            .frame(width: 44, height: 44)
                        
                        // Loading spinner
                        ProgressView()
                            .scaleEffect(1.0)
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
                
                // Progress bar - only show on currently playing episode
                if isPlaying && currentProgress > 0 && currentProgress < 1.0 && !isEpisodePlayed {
                    ProgressView(value: currentProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
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
            .contentShape(Rectangle())
            .onTapGesture {
                // Start local loading state when tapped
                print("🎬 OPTIMIZED ROW TAP LOADING: Setting localLoadingState = true for episode: \(episode.title)")
                localLoadingState = true
                
                // Ensure loading state is visible for minimum duration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    onPlay()
                }
            }
            
            // Visual status indicators (download/favorite badges)
            VStack(alignment: .trailing, spacing: 4) {
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundColor(.green)
                }
                
                if currentEpisode.state.isFavorite {
                    Image(systemName: "bookmark.fill")
                        .font(.body)
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 28)
            .padding(.top, 2)
        }
        .frame(minHeight: 64) // Minimum height for touch targets
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(podcastPlayer.$currentProgress) { _ in
            // Force view refresh when progress changes for playing episodes
            // This will update the currentTimeInfo computed property
        }
        .onReceive(podcastPlayer.$currentTime) { _ in
            // Force view refresh when current time changes for playing episodes
            // This ensures real-time time left updates
        }
        .onChange(of: podcastPlayer.loadingEpisodeId) { _, newLoadingId in
            print("🎬 LOADING STATE CHANGE: Episode \(episode.title) - loadingEpisodeId changed to: \(newLoadingId ?? "nil")")
        }
        .onChange(of: podcastPlayer.isPlaying) { _, isPlaying in
            // Clear loading state when playback starts for this episode
            if isPlaying && podcastPlayer.currentEpisode?.id == episode.id {
                localLoadingState = false
            }
        }
        .onChange(of: isPlaying) { _, newIsPlaying in
            // Clear loading state when this episode starts playing (with minimum display time)
            if newIsPlaying {
                // Ensure loading animation is visible for at least 300ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    localLoadingState = false
                }
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
            
            if !episode.state.isDownloaded && !isDownloading {
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
    
    private func handleDownloadAction() {
        // Add haptic feedback for swipe action
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        if !episode.state.isDownloaded && !isDownloading {
            // Check subscription for download feature
            if !subscriptionManager.isSubscribedOrInTrial {
                showBannerAlert(message: "Podcast downloads are available with StreamRadios Pro. Upgrade to download episodes for offline listening.")
                return
            }
            
            // Show download banner that stays visible during download
            showBannerAlert(message: "Download started for \(episode.title)", autoDismiss: false)
            
            viewModel.downloadEpisode(episode) { result in
                // Download state is managed by the progress tracking
                print("Download completed for episode: \(episode.title)")
                
                // Hide banner when download completes
                DispatchQueue.main.async {
                    showingBannerAlert = false
                }
            }
        }
    }
    
    private func exportEpisodeFile() {
        // Check if episode has a local file path
        guard let localFilePath = currentEpisode.localFilePath,
              !localFilePath.isEmpty,
              FileManager.default.fileExists(atPath: localFilePath) else {
            showBannerAlert(message: "Downloaded file not found")
            return
        }
        
        let fileURL = URL(fileURLWithPath: localFilePath)
        
        // Create a temporary copy with .mp3 extension to ensure compatibility
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = currentEpisode.title.replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        let tempURL = tempDir.appendingPathComponent("\(fileName).mp3")
        
        do {
            // Remove existing temp file if it exists
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            
            // Copy the file to temp directory with .mp3 extension
            try FileManager.default.copyItem(at: fileURL, to: tempURL)
            
            // Verify the file was copied successfully
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                showBannerAlert(message: "Failed to prepare file for export")
                return
            }
            
            // Set the export URL using the persistent holder and show the share sheet
            DispatchQueue.main.async {
                // Use the persistent holder that won't be affected by SwiftUI state invalidation
                self.exportURLHolder.setURL(tempURL)
                
                // Also set the state variables as backup (though they may get invalidated)
                self.shareURL = tempURL
                self.pendingExportURL = tempURL
                
                // Present the sheet
                self.showingShareSheet = true
            }
            
        } catch {
            showBannerAlert(message: "Failed to prepare file for export")
        }
    }
    
    private func showBannerAlert(message: String, autoDismiss: Bool = true) {
        bannerAlertMessage = message
        showingBannerAlert = true
        
        // Only auto-dismiss if specified (not for download banners)
        if autoDismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingBannerAlert = false
            }
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
    
    // Search state
    @State private var searchText = ""
    @State private var isSearchPresented = false
    
    // Cached artwork to prevent flickering during scrolls
    @State private var cachedArtworkImage: UIImage?
    
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
                // Search Bar (when presented)
                if isSearchPresented {
                    CustomSearchBar(searchText: $searchText, isPresented: $isSearchPresented, placeholder: "Search episodes in \(feed.title)")
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // About section - displayed above episodes
                if !isSearchPresented {
                    aboutSection
                }
                
                if !isSearchPresented {
                    episodeFilterTabs
                }
                
                // Podcast progress banner - shows sync operations in real-time
                if !isSearchPresented {
                    UnifiedPodcastProgressBanner()
                }
                
                episodeListContent
            }
            
            // Global Player now handles all playback display
            // No individual mini player needed here
        }
        .navigationTitle(feed.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    // CRITICAL: Execute navigation IMMEDIATELY on main thread with highest priority
                    // This ensures nothing can block or delay the back navigation
                    Task { @MainActor in
                        print("🔙 INSTANT BACK: User tapped back button - FORCING IMMEDIATE NAVIGATION")
                        
                        // CRITICAL: Cancel ALL ongoing operations immediately
                        viewModel.operationInProgress = false
                        viewModel.isLoadingEpisodes = false
                        podcastPlayer.loadingEpisodeId = nil
                        
                        // CRITICAL: Set selectedPodcast to nil immediately - triggers navigation
                        selectedPodcast = nil
                        
                        print("🔙 INSTANT BACK: Navigation completed - selectedPodcast set to nil")
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .padding(8) // Increase tappable area
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(TapGesture().onEnded { _ in
                    // EMERGENCY FALLBACK: If button action doesn't fire, this gesture will
                    Task { @MainActor in
                        selectedPodcast = nil
                    }
                })
                .allowsHitTesting(true) // Ensure button is always tappable
                .zIndex(1000) // Ensure button is above all other content
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSearchPresented {
                    Button("Cancel") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isSearchPresented = false
                            searchText = ""
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
                    .foregroundColor(.blue)
                } else {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isSearchPresented = true
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.adaptivePrimaryText)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                }
            }
        }
                .onAppear(perform: handleOnAppear)
                        .onDisappear {
            // Clean up timers to prevent memory leaks
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = nil
            
            // Save progress for currently playing/paused episode before leaving
            if let currentEpisode = podcastPlayer.currentEpisode,
               currentEpisode.feedId == feed.id,
               podcastPlayer.currentTime > 0 {
                // Save progress immediately without blocking navigation
                Task.detached(priority: .background) {
                    await MainActor.run {
                        self.podcastPlayer.saveProgressIfNeeded()
                    }
                }
            }
            
            // Reset view state for fresh appearance next time
            viewDidAppear = false
            episodesDidLoad = false
        }
                .onChange(of: viewModel.podcastFeedOrder) { _ in
                    // PERFORMANCE: Use optimized feed refresh instead of expensive fetchAllEpisodes
                    if viewModel.currentEpisodes.isEmpty {
                        viewModel.requestFeedRefresh(feed.id)
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
                        .foregroundColor(.adaptiveSecondaryText)
                    
                    Text("episode\(viewModel.currentEpisodes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                    
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
                Text("Current Episodes").tag(0)
                Text("All Episodes").tag(1)
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
            // PERFORMANCE CRITICAL: Use optimized updateFilter instead of expensive loadEpisodesForFeed
            // This prevents 500% CPU spikes and app hangs during tab switching
            print("🔄 PodcastListView: Tab changed from \(viewModel.currentTab) to \(newValue) - using fast switch")
            
            // Reset scroll state when changing tabs so auto-scroll can work again if needed
            hasScrolledToCurrentEpisode = false
            
            // Use the optimized updateFilter method instead of expensive loadEpisodesForFeed
            viewModel.updateFilter(tab: newValue)
        }
    }
    
    private var episodeListContent: some View {
        Group {
            if isSearchPresented && !searchText.isEmpty {
                // Show search results list
                searchResultsList
            } else if viewModel.isLoadingEpisodes && viewModel.currentEpisodes.isEmpty {
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
    
    // MARK: - About Section
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ABOUT")
                    .font(.caption)
                    .foregroundColor(.white)
                    .tracking(1.0)
                
                Spacer()
                
                // Scroll indicators - show arrows to indicate scrollable content
                VStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .opacity(0.6)
            }
            
            HStack(alignment: .top, spacing: 16) {
                // Feed artwork on the left - using cached UIImage to prevent flickering
                if let cachedImage = cachedArtworkImage {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    // Placeholder while loading
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.gray)
                                .font(.largeTitle)
                        )
                }
                
                // Description text on the right
                ScrollView(.vertical, showsIndicators: true) {
                    Text(feed.descriptionText ?? "No description available")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.trailing, 8) // Add right padding to prevent text cutoff
                        .padding(.bottom, 4) // Add some bottom padding for better scrolling
                }
                .frame(maxHeight: 120) // Match artwork height for better alignment
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var episodeRows: some View {
        // 🚀 PERFORMANCE: Only access currentEpisodes ONCE per render, not per episode row
        let allEpisodes: [PodcastEpisode]
        if viewModel.selectedFeedId == feed.id {
            allEpisodes = viewModel.currentEpisodes
        } else {
            allEpisodes = []
        }
        
        // 🛡️ SMART UI CONTAMINATION PREVENTION: Filter and show only clean episodes
        let episodes: [PodcastEpisode]
        if allEpisodes.isEmpty {
            episodes = [] // No episodes to show
        } else if allEpisodes.allSatisfy({ $0.feedId == feed.id }) {
            episodes = allEpisodes // All episodes belong to this feed
        } else {
            // Some episodes don't belong to this feed - filter to show only clean ones
            episodes = allEpisodes.filter { $0.feedId == feed.id }
            print("🛡️ SMART UI PROTECTION: Filtered to show \(episodes.count) clean episodes out of \(allEpisodes.count) total")
        }
        
        // 🛡️ AGGRESSIVE CONTAMINATION DETECTION: Check for ANY wrong episodes
        let wrongFeedEpisodes = allEpisodes.filter { $0.feedId != feed.id }
        if !wrongFeedEpisodes.isEmpty {
            print("🚨 UI CONTAMINATION DETECTED: Found \(wrongFeedEpisodes.count) episodes from wrong feed in \(feed.id)")
            for episode in wrongFeedEpisodes.prefix(3) {
                print("🚨 WRONG EPISODE: '\(episode.title)' belongs to \(episode.feedId), not \(feed.id)")
            }
            
            // 🛡️ IMMEDIATE EMERGENCY RESPONSE: Multiple layers of cleanup
            print("🛡️ SMART RESPONSE: Starting targeted contamination cleanup")
            
            // Single cleanup operation - no multiple layers needed
            DispatchQueue.main.async {
                print("🧹 SMART CLEANUP: Assigning clean episodes immediately")
                viewModel.safelyAssignCurrentEpisodes(episodes, targetFeedId: self.feed.id, updateSelectedFeed: false)
            }
            
            // Simple recovery check - no delays
            DispatchQueue.main.async {
                if viewModel.currentEpisodes.isEmpty && !episodes.isEmpty {
                    print("🔧 INSTANT RECOVERY: Assigning episodes immediately")
                    viewModel.safelyAssignCurrentEpisodes(episodes, targetFeedId: self.feed.id, updateSelectedFeed: false)
                } else {
                    print("✅ RECOVERY: Episode display recovered successfully")
                }
            }
        }
        
        // PERFORMANCE: LazyVStack already handles virtualization, no need to manually limit episodes
        // Just display all episodes and let SwiftUI handle the rendering optimization
        return ForEach(episodes, id: \.id) { episode in
            OptimizedEpisodeRowView(
                episode: episode,
                isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                onPlay: {
                    print("🎬 EPISODE LIST LOADING: Setting loading state for episode: \(episode.title)")
                    // Set loading state in PodcastPlayer for immediate feedback
                    podcastPlayer.loadingEpisodeId = episode.id
                    playEpisode(episode)
                },
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
                // Pull to refresh - fetch new episodes from RSS with enhanced feedback
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                
                await viewModel.refreshCurrentFeed()
                
                // Show success feedback after refresh
                if !viewModel.currentEpisodes.isEmpty {
                    showSuccessToast = true
                    successMessage = "Episodes refreshed"
                    
                    // Auto-hide toast after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSuccessToast = false
                        }
                    }
                }
            }
            .simultaneousGesture(
                // Detect scroll gestures to close any active swipe
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        // Close any swiped row when user starts scrolling
                        if viewModel.swipedEpisodeId != nil {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                viewModel.swipedEpisodeId = nil
                            }
                        }
                    }
            )
            .background(Color.adaptiveBackground)
            .onAppear {
                // Cache artwork image to prevent flickering during scrolls
                if cachedArtworkImage == nil {
                    if let imageData = feed.imageData {
                        cachedArtworkImage = UIImage(data: imageData)
                    }
                }
                
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
            .onChange(of: feed.imageData) { _, newImageData in
                // Update cached artwork when feed image changes
                if let imageData = newImageData {
                    cachedArtworkImage = UIImage(data: imageData)
                }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // Only trigger for primarily vertical scrolling (not horizontal swipes)
                    let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                    if isVerticalScroll {
                        // Post notification that episode list is scrolling
                        NotificationCenter.default.post(name: .episodeListScrolling, object: nil)
                    }
                }
                .onEnded { value in
                    // Only trigger for primarily vertical scrolling (not horizontal swipes)
                    let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                    if isVerticalScroll {
                        // Post notification that episode list stopped scrolling
                        NotificationCenter.default.post(name: .episodeListScrollingStopped, object: nil)
                        
                        // Also post notification for episode title scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                        }
                    }
                }
        )
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
                            .fill(Color(red: 0.0, green: 0.6, blue: 0.0))
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
        // CPU MONITORING: Track CPU when feed view appears
        
        // CRITICAL FIX: Sync live progress from currently playing episode to cache
        // This ensures the episode list shows current live progress, not stale saved progress
        syncCurrentPlayingProgress()
        
        // CRITICAL FIX: Check if current episodes actually belong to this feed
        // CARPLAY FIX: Don't check selectedFeedId - it can change when CarPlay plays from different feed
        // Only check if the episodes themselves belong to this feed
        let currentEpisodesForThisFeed = !viewModel.currentEpisodes.isEmpty &&
                                        viewModel.currentEpisodes.first?.feedId == feed.id &&
                                        viewModel.currentEpisodes.allSatisfy { $0.feedId == feed.id }
        
        print("🔄 FEED CHECK: feedId=\(feed.id), selectedFeedId=\(viewModel.selectedFeedId ?? "nil"), episodes=\(viewModel.currentEpisodes.count), firstEpisodeFeedId=\(viewModel.currentEpisodes.first?.feedId ?? "nil"), allMatch=\(viewModel.currentEpisodes.allSatisfy { $0.feedId == feed.id })")
        
        // Initialize state for this view appearance
        episodesDidLoad = !viewModel.currentEpisodes.isEmpty && currentEpisodesForThisFeed
                
        // Synchronize viewModel.currentTab with selectedTab to ensure proper filtering
        // PERFORMANCE: Only sync if different to avoid triggering expensive operations
        if viewModel.currentTab != selectedTab {
            print("🔄 PodcastListView: Syncing tab from \(viewModel.currentTab) to \(selectedTab)")
            viewModel.updateFilter(tab: selectedTab)
        }
        
        // CRITICAL FIX: Determine if we're actually switching feeds
        // This is a real feed switch ONLY if:
        // 1. selectedFeedId is different from what we're displaying AND
        // 2. The current episodes don't belong to this feed AND
        // 3. We're NOT returning from background (to prevent clearing on app resume)
        // This prevents CarPlay playback changes from being treated as feed switches
        let needsFeedSwitch = viewModel.selectedFeedId != feed.id && !currentEpisodesForThisFeed && !viewModel.isReturningFromBackground
        
        if needsFeedSwitch {
            print("🔄 PodcastListView: Real feed switch detected - from \(viewModel.selectedFeedId ?? "nil") to \(feed.id)")
            viewModel.selectedFeedId = feed.id
            print("🔄 PodcastListView: Clearing episodes for real feed switch")
            viewModel.currentEpisodes.removeAll()
            // CRITICAL: Also clear loading state to prevent race conditions
            viewModel.operationInProgress = false
            viewModel.isLoadingEpisodes = false
            // CRITICAL: Clear pending task tracking to allow immediate reload
            let taskKey = "\(feed.id)-true"
            viewModel.pendingInitializationTasks.remove(taskKey)
            print("🔄 PodcastListView: Cleared loading state and pending tasks for feed switch")
        } else if viewModel.isReturningFromBackground {
            // CRITICAL FIX: Only preserve episodes if they belong to THIS feed
            // If episodes are from a different feed, clear them and load correct ones
            if currentEpisodesForThisFeed {
                print("🔄 PodcastListView: Returning from background - preserving episodes (\(viewModel.currentEpisodes.count) episodes for feed \(feed.id))")
            } else {
                print("🔄 PodcastListView: Returning from background - but episodes are from different feed, clearing them")
                viewModel.currentEpisodes.removeAll()
            }
            
            // Update selectedFeedId to match current feed to stay in sync
            if viewModel.selectedFeedId != feed.id {
                viewModel.selectedFeedId = feed.id
            }
            
            // CRITICAL: Clear the flag AFTER checking it so future navigations work normally
            viewModel.clearBackgroundReturnFlag()
        } else {
            // Update selectedFeedId if needed, but don't clear episodes if they're already correct
            if viewModel.selectedFeedId != feed.id {
                print("🔄 PodcastListView: ⚠️ selectedFeedId mismatch (\(viewModel.selectedFeedId ?? "nil") vs \(feed.id)) but episodes are correct - updating selectedFeedId only")
                viewModel.selectedFeedId = feed.id
            } else {
                print("🔄 PodcastListView: Already viewing feed \(feed.id) with correct episodes - no changes needed")
            }
            // CARPLAY FIX: Episodes belong to this feed, so keep them even if selectedFeedId was different
            
            // Clear background return flag if it was set (handles edge cases)
            if viewModel.isReturningFromBackground {
                viewModel.clearBackgroundReturnFlag()
            }
        }
        
        // CRITICAL PERFORMANCE: Skip ALL expensive operations when snapshots are available
        let hasSnapshot = viewModel.feedIsolationManager.getEpisodesForFeed(feed.id) != nil
        if hasSnapshot {
            print("⚡ ULTRA PERFORMANCE: Using cache for feed \(feed.id) - SKIPPING ALL EXPENSIVE OPERATIONS")
            // Use cached data directly without any loading operations
            let cachedEpisodes = viewModel.feedIsolationManager.getEpisodesForFeed(feed.id)
            if !cachedEpisodes.isEmpty {
                print("💾 CACHE SUCCESS: Displaying \(cachedEpisodes.count) episodes instantly - NO EXPENSIVE OPERATIONS NEEDED")
                // The snapshot will be used automatically by the view model
            }
        } else if !currentEpisodesForThisFeed || viewModel.currentEpisodes.isEmpty {
            print("🔄 PodcastListView: Loading episodes for feed: \(feed.id) (selectedFeedId: \(viewModel.selectedFeedId ?? "nil"))")
            print("🔄 PodcastListView: Current episodes count: \(viewModel.currentEpisodes.count), currentEpisodesForThisFeed: \(currentEpisodesForThisFeed)")
            loadInitialEpisodes()
        } else {
            print("⚡ PERFORMANCE: Skipping episode load - episodes already loaded for feed: \(feed.id)")
        }
    }
    
    private func loadInitialEpisodes() {
        // CPU MONITORING: Track CPU when initial episodes are requested
        
        // PERFORMANCE: Use optimized feed refresh to leverage snapshots
        viewModel.requestFeedRefresh(feed.id)
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
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let isPlayedByState = episodeState == .played
            let isCompletedByProgress = episodeProgress >= 0.99
            
            print("🔄 BUTTON DEBUG 2: Current episode tap - episodeState = \(episodeState.rawValue), progress = \(String(format: "%.3f", episodeProgress))")
            print("🔄 BUTTON DEBUG 2: episode.id = \(episode.id)")
            print("🔄 BUTTON DEBUG 2: isPlayedByState = \(isPlayedByState), isCompletedByProgress = \(isCompletedByProgress), episode.state.isPlayed = \(episode.state.isPlayed)")
            
            if isPlayedByState || isCompletedByProgress {
                print("🔄 BUTTON DEBUG 2: Calling rewindAndPlay for current episode: \(episode.title)")
                podcastPlayer.rewindAndPlay(episode: episode)
            } else {
                print("🔄 BUTTON DEBUG 2: Calling togglePlayPause for episode: \(episode.title)")
                podcastPlayer.togglePlayPause()
            }
        } else {
            // Check if this different episode is finished and should be rewound
            let episodeProgress = podcastPlayer.getCurrentProgress(for: episode)
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let isPlayedByState = episodeState == .played
            let isCompletedByProgress = episodeProgress >= 0.99
            
            print("🔄 BUTTON DEBUG 2: Different episode tap - episodeState = \(episodeState.rawValue), progress = \(String(format: "%.3f", episodeProgress))")
            print("🔄 BUTTON DEBUG 2: episode.id = \(episode.id)")
            print("🔄 BUTTON DEBUG 2: isPlayedByState = \(isPlayedByState), isCompletedByProgress = \(isCompletedByProgress), episode.state.isPlayed = \(episode.state.isPlayed)")
            
            if isPlayedByState || isCompletedByProgress {
                print("🔄 BUTTON DEBUG 2: Calling rewindAndPlay for finished episode: \(episode.title)")
                podcastPlayer.rewindAndPlay(episode: episode)
            } else {
                print("🔄 BUTTON DEBUG 2: Playing different episode normally: \(episode.title)")
                podcastPlayer.playEpisode(episode, feed: feed)
            }
        }
    }
    
    // MARK: - Search Results List
    
    private var searchResultsList: some View {
        // Search across ALL episodes in the feed, not just current tab
        let allEpisodes = feed.episodes
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = allEpisodes.filter { episode in
            if episode.title.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            if htmlToPlainText(episode.descriptionText).localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            if let notesContent = episode.notes?.content {
                let plain = htmlToPlainText(notesContent)
                if plain.localizedCaseInsensitiveContains(trimmedQuery) {
                    return true
                }
            }
            return false
        }
        
        return Group {
            if results.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No matching episodes")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Try a different search term")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results, id: \.id) { episode in
                            searchResultRow(episode: episode, query: trimmedQuery)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playEpisode(episode)
                                }
                        }
                    }
                }
            }
        }
    }
    
    private func searchResultRow(episode: PodcastEpisode, query: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Episode title with highlighting
            highlightedText(episode.title, query: query)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)
            
            // Snippet from description or notes
            if let snippetText = snippet(for: episode, query: query) {
                highlightedText(snippetText, query: query)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            
            // Episode metadata
            HStack(spacing: 8) {
                Text(formatDate(episode.publicationDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if episode.duration > 0 {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(formatDuration(episode.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
        .overlay(
            Rectangle()
                .fill(Color.adaptiveSeparator)
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    // MARK: - Search Helper Methods
    
    private func highlightedText(_ text: String, query: String) -> Text {
        guard !query.isEmpty else { return Text(text) }
        
        let parts = text.components(separatedBy: query)
        if parts.count == 1 {
            // Try case-insensitive
            let lowerText = text.lowercased()
            let lowerQuery = query.lowercased()
            if let range = lowerText.range(of: lowerQuery) {
                let beforeMatch = String(text[..<range.lowerBound])
                let match = String(text[range])
                let afterMatch = String(text[range.upperBound...])
                return Text(beforeMatch) + Text(match).foregroundColor(.blue).bold() + highlightedText(afterMatch, query: query)
            }
            return Text(text)
        }
        
        var result = Text("")
        for (index, part) in parts.enumerated() {
            result = result + Text(part)
            if index < parts.count - 1 {
                result = result + Text(query).foregroundColor(.blue).bold()
            }
        }
        return result
    }
    
    private func snippet(for episode: PodcastEpisode, query: String) -> String? {
        let lowerQuery = query.lowercased()
        
        // Try description first
        let descPlain = htmlToPlainText(episode.descriptionText)
        if let range = descPlain.lowercased().range(of: lowerQuery) {
            return extractSnippet(from: descPlain, around: range)
        }
        
        // Try notes
        if let notesContent = episode.notes?.content {
            let notesPlain = htmlToPlainText(notesContent)
            if let range = notesPlain.lowercased().range(of: lowerQuery) {
                return extractSnippet(from: notesPlain, around: range)
            }
        }
        
        // Fallback to start of description
        if !descPlain.isEmpty {
            return String(descPlain.prefix(150))
        }
        
        return nil
    }
    
    private func extractSnippet(from text: String, around range: Range<String.Index>) -> String {
        let snippetLength = 150
        let start = text.index(range.lowerBound, offsetBy: -snippetLength / 2, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: snippetLength / 2, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { snippet = "..." + snippet }
        if end != text.endIndex { snippet = snippet + "..." }
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
    
    private func formatDuration(_ duration: Double) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
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
                    Button {
                        sharePodcastFeed(feed)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                    
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
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // Only trigger for primarily vertical scrolling (not horizontal swipes)
                    let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                    if isVerticalScroll {
                        UserDefaults.standard.set(true, forKey: "isUserScrolling")
                        // Post notification for PodcastPlayer scroll detection
                        NotificationCenter.default.post(name: .userIsScrolling, object: nil)
                    }
                }
                .onEnded { value in
                    // Only trigger for primarily vertical scrolling (not horizontal swipes)
                    let isVerticalScroll = abs(value.translation.height) > abs(value.translation.width)
                    if isVerticalScroll {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            UserDefaults.standard.set(false, forKey: "isUserScrolling")
                            // Post notification for PodcastPlayer scroll detection
                            NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                        }
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
    
    // MARK: - Share Functionality
    private func sharePodcastFeed(_ feed: PodcastFeed) {
        let subject = "Check out this podcast: \(feed.title)"
        let body = """
        I thought you might enjoy this podcast!
        
        \(feed.title)
        \(feed.descriptionText?.isEmpty == false ? "\n\(feed.descriptionText!)\n" : "")
        Feed URL: \(feed.url)
        """
        
        // Let iOS handle the sharing - it will show available apps that can handle RSS feeds
        
        // Create a simple URL that can be handled by podcast apps
        let feedURL = URL(string: feed.url)!
        
        let activityController = UIActivityViewController(
            activityItems: [subject, body, feedURL],
            applicationActivities: nil
        )
        
        // Configure for specific sharing options
        activityController.completionWithItemsHandler = { (activityType: UIActivity.ActivityType?, completed: Bool, returnedItems: [Any]?, error: Error?) in
            if completed {
                print("Successfully shared podcast: \(feed.title)")
            }
        }
        
        // Present the share sheet
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            // Handle iPad presentation
            if let popover = activityController.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            rootViewController.present(activityController, animated: true)
        }
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

// MARK: - Custom Podcast App Activity
class PodcastAppActivity: UIActivity {
    private let title: String
    private let imageName: String
    private let feedURL: String
    private let urlScheme: String?
    
    init(title: String, image: String, feedURL: String, urlScheme: String?) {
        self.title = title
        self.imageName = image
        self.feedURL = feedURL
        self.urlScheme = urlScheme
        super.init()
    }
    
    override var activityType: UIActivity.ActivityType? {
        return UIActivity.ActivityType("com.streamradios.\(title.lowercased().replacingOccurrences(of: " ", with: ""))")
    }
    
    override var activityTitle: String? {
        return title
    }
    
    override var activityImage: UIImage? {
        return UIImage(systemName: imageName)
    }
    
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        return true
    }
    
    override func perform() {
        if title == "Copy Feed URL" {
            // Copy to clipboard
            UIPasteboard.general.string = feedURL
            print("📋 Copied feed URL to clipboard: \(feedURL)")
            activityDidFinish(true)
            return
        }
        
        // Try multiple URL schemes for each app to maximize compatibility
        let urlsToTry = getURLsToTry(for: title, feedURL: feedURL)
        
        tryOpeningURLs(urlsToTry, appName: title) { [weak self] success in
            if !success {
                // Final fallback: copy URL to clipboard
                UIPasteboard.general.string = self?.feedURL ?? ""
                print("📋 All URL schemes failed, copied feed URL to clipboard as fallback")
            }
            self?.activityDidFinish(true)
        }
    }
    
    private func getURLsToTry(for appName: String, feedURL: String) -> [String] {
        let encodedURL = feedURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? feedURL
        
        switch appName {
        case "Apple Podcasts":
            return [
                "podcast://\(feedURL)",
                "podcasts://\(feedURL)",
                "https://podcasts.apple.com/podcast/id?url=\(encodedURL)"
            ]
        case "Overcast":
            return [
                "overcast://x-callback-url/add?url=\(encodedURL)",
                "overcast://add?url=\(encodedURL)"
            ]
        case "Pocket Casts":
            return [
                "pocketcasts://subscribe/\(encodedURL)",
                "https://pca.st/subscribe?url=\(encodedURL)"
            ]
        case "Castro":
            return [
                "castro://subscribe/\(encodedURL)",
                "castro://add/\(encodedURL)"
            ]
        default:
            return [feedURL]
        }
    }
    
    private func tryOpeningURLs(_ urls: [String], appName: String, completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty else {
            completion(false)
            return
        }
        
        let urlString = urls[0]
        let remainingURLs = Array(urls.dropFirst())
        
        guard let url = URL(string: urlString) else {
            // Try next URL
            tryOpeningURLs(remainingURLs, appName: appName, completion: completion)
            return
        }
        
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url) { success in
                    if success {
                        print("🎧 Successfully opened \(appName) with URL: \(urlString)")
                        completion(true)
                    } else {
                        print("❌ Failed to open \(appName) with URL: \(urlString)")
                        // Try next URL
                        self.tryOpeningURLs(remainingURLs, appName: appName, completion: completion)
                    }
                }
            } else {
                print("📱 Cannot open URL scheme for \(appName): \(urlString)")
                // Try next URL
                self.tryOpeningURLs(remainingURLs, appName: appName, completion: completion)
            }
        }
    }
}

// MARK: - Notification Extensions
// Note: Notification names are declared in RadioStationListView.swift to avoid duplication




