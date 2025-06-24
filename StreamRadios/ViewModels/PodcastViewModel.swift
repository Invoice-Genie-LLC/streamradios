//
//  PodcastViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import Foundation
import Combine
import SwiftUI
import OSLog
import CoreData
import AVKit
import CloudKit

struct PodcastFeed: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String
    var artworkUrl: String?
    var descriptionText: String?
    var iconData: String?
    var imageData: Data?
    var episodes: [PodcastEpisode] = []
    
    init(id: String = UUID().uuidString, title: String, url: String, artworkUrl: String? = nil, description: String? = nil, iconData: String? = nil, imageData: Data? = nil, episodes: [PodcastEpisode] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.artworkUrl = artworkUrl
        self.descriptionText = description
        self.iconData = iconData
        self.imageData = imageData
        self.episodes = episodes
    }
    
    // Equatable implementation
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.id == rhs.id
    }
}

struct PodcastEpisode: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var descriptionText: String
    var audioUrl: String
    var publicationDate: Date
    var duration: TimeInterval
    var state: EpisodeState
    var feedId: String
    var localFilePath: String?
    var fileSize: Int64? // File size in bytes
    
    init(id: String = UUID().uuidString, title: String, descriptionText: String, audioUrl: String, publicationDate: Date, duration: TimeInterval, state: EpisodeState, feedId: String, localFilePath: String? = nil, fileSize: Int64? = nil) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.audioUrl = audioUrl
        self.publicationDate = publicationDate
        self.duration = duration
        self.state = state
        self.feedId = feedId
        self.localFilePath = localFilePath
        self.fileSize = fileSize
    }
    
    // Implement Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(feedId)
    }
    
    // Equatable based on unique identifier
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        return lhs.id == rhs.id
    }
}

struct EpisodeState: Codable, Equatable, Hashable {
    var isPlayed: Bool
    var isFavorite: Bool
    var progress: Double // 0.0 to 1.0
    var isDownloaded: Bool
}

/// High-performance podcast view model designed for thousands of episodes
@MainActor
class PodcastViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var podcastFeeds: [PodcastFeed] = []
    @Published var isLoading = false
    @Published var isLoadingFeeds = false
    @Published var isLoadingEpisodes = false
    @Published var isLoadingMoreEpisodes = false
    @Published var hasMoreEpisodes = false
    @Published var error: String?
    @Published var currentTab = 0
    @Published var searchQuery = ""
    @Published var episodeCounts = (all: 0, favorites: 0, downloads: 0)
    @Published var showNoEpisodesAlert = false
    @Published var noEpisodesAlertMessage = ""
    @Published var isAscendingSort = true
    @Published var podcastFeedOrder: [String] = []
    @Published var lastPlayedEpisodes: [String: String] = [:]
    @Published var episodeProgress: [String: Double] = [:]
    @Published var downloadProgress: [String: Double] = [:]
    
    // MARK: - Private Properties
    private let log = OSLog(subsystem: "StreamRadios", category: "PodcastViewModel")
    private let feedManager = PodcastFeedManager()
    private let episodeManager = PodcastEpisodeManager()
    private var cancellables = Set<AnyCancellable>()
    
    // Performance optimizations
    private let episodesPerPage = 100
    private var currentPage = 1
    private var loadingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    
    // Current state
    private var selectedFeedId: String?
    private var lastLoadTime: Date = Date()
    
    init() {
        setupObservers()
        
        // Load feeds from Core Data (radio station pattern)
        loadFeedsFromCoreData()
        
        // Always check for CloudKit sync in background
        Task {
            // Clean up any duplicate episodes first to prevent crashes
            do {
                try await episodeManager.cleanupDuplicateEpisodes()
            } catch {
                print("⚠️ Failed to cleanup duplicate episodes: \(error)")
            }
            
            await checkForFreshInstallAndSetup()
            
            // After CloudKit sync, check if any feeds need episode refreshing
            await refreshFeedsWithoutEpisodes()
            
            // Always attempt episode state sync after all initialization is complete
            print("🔄 Final episode state sync after full initialization...")
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
        }
    }
    
    deinit {
        loadingTask?.cancel()
        refreshTask?.cancel()
    }
    
    // MARK: - Public Interface
    
    /// Load podcast feeds from saved data efficiently
    func loadSavedFeeds() {
        isLoadingFeeds = true
        
        Task {
            do {
                let feeds = try await feedManager.loadSavedFeeds()
                await MainActor.run {
                    self.podcastFeeds = feeds
                    self.isLoadingFeeds = false
                    os_log("📡 Loaded %d saved feeds", log: self.log, type: .info, feeds.count)
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to load feeds: \(error.localizedDescription)"
                    self.isLoadingFeeds = false
                    os_log("❌ Failed to load feeds: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }
    
    /// Add a new podcast feed with background processing and CloudKit sync
    func addPodcastFeed(url: String) async -> Bool {
        isLoading = true
        
        guard let feedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.error = "Invalid URL format"
            isLoading = false
            return false
        }
        
        do {
            // Step 1: Use feed manager to add the feed (this handles Core Data saving)
            let feed = try await feedManager.addFeed(from: feedURL)
            
            print("📊 Added feed: \(feed.title)")
            
            // Step 2: Save to CloudKit for future fresh installs
            do {
                try await PodcastCloudKitManager.shared.savePodcastFeedToCloudKit(feed)
                print("✅ Saved feed to CloudKit: \(feed.title)")
            } catch {
                print("⚠️ Failed to save feed to CloudKit (local save succeeded): \(error)")
                // Continue even if CloudKit save fails
            }
            
            // Step 3: Update UI
            self.loadFeedsFromCoreData()
            isLoading = false
            return true
            
        } catch {
            print("❌ Failed to add podcast feed: \(error)")
            self.error = "Failed to add podcast feed: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }
    
    /// Load episodes for a specific feed with efficient pagination
    func loadEpisodesForFeed(_ feedId: String, isInitialLoad: Bool = false) async {
        // Cancel any existing loading task
        loadingTask?.cancel()
        
        selectedFeedId = feedId
        currentPage = 1
        
        await MainActor.run {
            self.isLoadingEpisodes = true
            if isInitialLoad {
                self.currentEpisodes = []
            }
        }
        
        // First check if episodes are already loaded in the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            print("🔍 DEBUG: Found \(feed.episodes.count) episodes already loaded in feed: \(feed.title)")
            
            // Apply filtering based on current tab
            let filter = EpisodeFilter(rawValue: currentTab) ?? .all
            let filteredEpisodes: [PodcastEpisode]
            
            switch filter {
            case .all:
                filteredEpisodes = feed.episodes
            case .favorites:
                filteredEpisodes = feed.episodes.filter { $0.state.isFavorite }
            case .downloads:
                filteredEpisodes = feed.episodes.filter { $0.state.isDownloaded }
            }
            
            print("🔍 DEBUG: Applied filter \(filter) - showing \(filteredEpisodes.count) of \(feed.episodes.count) episodes")
            
            await MainActor.run {
                self.currentEpisodes = filteredEpisodes
                self.isLoadingEpisodes = false
                self.hasMoreEpisodes = false
                print("📊 Using pre-loaded episodes with filter: \(self.currentEpisodes.count) episodes displayed")
            }
            return
        }
        
        print("🔍 DEBUG: No episodes found in feed object, loading from episode manager...")
        
        loadingTask = Task {
            await performEpisodeLoad(feedId: feedId, page: 1, isInitialLoad: isInitialLoad)
        }
        
        await loadingTask?.value
    }
    
    /// Load more episodes (pagination)
    func loadMoreEpisodes() async {
        guard let feedId = selectedFeedId,
              !isLoadingMoreEpisodes,
              hasMoreEpisodes else { return }
        
        await MainActor.run {
            self.isLoadingMoreEpisodes = true
        }
        
        currentPage += 1
        
        await performEpisodeLoad(feedId: feedId, page: currentPage, isAppending: true)
        
        await MainActor.run {
            self.isLoadingMoreEpisodes = false
        }
    }
    
    /// Refresh episodes for current feed
    func refreshCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        refreshTask?.cancel()
        
        refreshTask = Task {
            do {
                os_log("🔄 Refreshing feed: %@", log: log, type: .info, feedId)
                // Simulate feed refresh for now
                let updatedFeed = podcastFeeds.first { $0.id == feedId }!
                let newEpisodes: [PodcastEpisode] = []
                
                await MainActor.run {
                    // Update feed in list
                    if let index = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                        self.podcastFeeds[index] = updatedFeed
                    }
                    
                    os_log("✅ Feed refreshed with %d new episodes", log: self.log, type: .info, newEpisodes.count)
                }
                
                // Reload episodes to show new ones
                await loadEpisodesForFeed(feedId)
                
            } catch {
                await MainActor.run {
                    self.error = "Failed to refresh feed: \(error.localizedDescription)"
                    os_log("❌ Failed to refresh feed: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
        
        await refreshTask?.value
    }
    
    /// Update filter (All, Favorites, Downloads) with efficient reloading
    func updateFilter(tab: Int) {
        guard currentTab != tab else { return }
        
        // Save current episode progress to CloudKit when switching tabs
        if let currentEpisode = PodcastPlayer.shared.currentEpisode, PodcastPlayer.shared.isPlaying {
            let progress = PodcastPlayer.shared.duration > 0 ? PodcastPlayer.shared.currentTime / PodcastPlayer.shared.duration : 0
            os_log("💾 Saving episode progress to CloudKit due to tab switch - Episode: %@, Progress: %.2f", 
                   log: log, type: .info, currentEpisode.title, progress)
            
            Task.detached(priority: .userInitiated) {
                await self.updateEpisodeState(currentEpisode.id, progress: progress, isPlayed: progress >= 0.99)
            }
        }
        
        currentTab = tab
        
        Task {
            if let feedId = selectedFeedId {
                await loadEpisodesForFeed(feedId)
            }
        }
    }
    
    /// Search episodes with debounced loading
    func searchEpisodes(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchQuery != trimmedQuery else { return }
        
        searchQuery = trimmedQuery
        
        // Debounce search
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            guard searchQuery == trimmedQuery else { return } // Check if search changed
            
            if let feedId = selectedFeedId {
                await loadEpisodesForFeed(feedId)
            }
        }
    }
    
    /// Update episode state efficiently with immediate CloudKit and Core Data sync
    func updateEpisodeState(_ episodeId: String, progress: Double? = nil, isFavorite: Bool? = nil, isDownloaded: Bool? = nil, isPlayed: Bool? = nil) {
        Task {
            // Get current state to preserve values not being updated
            let currentProgress = progress ?? EpisodeStateManager.shared.getProgress(for: episodeId)
            let currentFavorite = isFavorite ?? EpisodeStateManager.shared.isFavorite(episodeId)
            let currentDownloaded = isDownloaded ?? EpisodeStateManager.shared.isDownloaded(episodeId)
            
            // Determine the correct EpisodePlaybackState based on progress and isPlayed
            let finalProgress = progress ?? currentProgress
            let finalIsPlayed = isPlayed ?? (finalProgress >= 0.99)
            
            let episodeState: EpisodePlaybackState
            if finalIsPlayed || finalProgress >= 0.99 {
                episodeState = .played
            } else if finalProgress > 0 {
                episodeState = .inProgress
            } else {
                episodeState = .new
            }
            
            // Update EpisodeStateManager first (source of truth)
            if let progress = progress {
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: progress)
            }
            if let isFavorite = isFavorite {
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
            }
            if let isDownloaded = isDownloaded {
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
            }
            
            // Update the episode state in EpisodeStateManager
            EpisodeStateManager.shared.updateProgress(for: episodeId, progress: finalProgress, isPlaying: false)
            
            // Update local state immediately for responsiveness
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
                    var updatedEpisode = self.currentEpisodes[index]
                    
                    updatedEpisode.state.progress = finalProgress
                    updatedEpisode.state.isFavorite = currentFavorite
                    updatedEpisode.state.isDownloaded = currentDownloaded
                    updatedEpisode.state.isPlayed = finalIsPlayed
                    
                    self.currentEpisodes[index] = updatedEpisode
                }
                
                // Update progress cache
                self.episodeProgress[episodeId] = finalProgress
            }
            
            // Sync to CloudKit (single call, non-blocking)
            Task.detached(priority: .userInitiated) {
                await PodcastCloudKitManager.shared.saveEpisodeState(
                    episodeId: episodeId,
                    progress: finalProgress,
                    isFavorite: currentFavorite,
                    isDownloaded: currentDownloaded,
                    isPlayed: finalIsPlayed
                )
            }
            
            // CRITICAL: Save to Core Data immediately for persistence and fast app restart
            let coreDataUpdate = EpisodeStateUpdate(
                episodeId: episodeId,
                progress: finalProgress,
                isFavorite: currentFavorite,
                isDownloaded: currentDownloaded,
                isPlayed: finalIsPlayed
            )
            
            do {
                try await episodeManager.updateEpisodeStates([coreDataUpdate])
                print("💾 Saved episode state to Core Data immediately: \(episodeId)")
            } catch {
                print("❌ Failed to save episode state to Core Data: \(error)")
            }
            
            // Update counts if necessary
            if isFavorite != nil || isDownloaded != nil {
                await updateEpisodeCountsForCurrentFeed()
                
                // Clear cache for this feed since episode states changed
                if let feedId = self.selectedFeedId {
                    await self.episodeManager.clearCacheForFeed(feedId)
                }
                
                // Immediately refresh the filtered list if we're on favorites or downloads tab
                if self.currentTab == EpisodeFilter.favorites.rawValue || self.currentTab == EpisodeFilter.downloads.rawValue {
                    await self.refreshCurrentFilteredList()
                }
            }
        }
    }
    
    /// Remove duplicate feeds manually
    @MainActor
    func removeDuplicateFeeds() {
        Task {
            await cleanupDuplicateFeeds()
            loadFeedsFromCoreData() // Refresh UI
        }
    }
    
    /// Delete a podcast feed
    @MainActor
    func deletePodcastFeed(_ feed: PodcastFeed) {
        isLoading = true
        
        Task {
            do {
                print("🗑️ Deleting feed: \(feed.title)")
                
                // Step 1: Delete from CloudKit
                do {
                    try await PodcastCloudKitManager.shared.deletePodcastFeedFromCloudKit(feed.id)
                    print("✅ Deleted feed from CloudKit: \(feed.title)")
                } catch {
                    print("⚠️ Failed to delete from CloudKit (will continue with local deletion): \(error)")
                    // Continue even if CloudKit deletion fails
                }
                
                // Step 2: Delete from Core Data
                try await deleteFeedFromCoreData(feed)
                print("✅ Deleted feed from Core Data: \(feed.title)")
                
                // Step 3: Update UI
                self.loadFeedsFromCoreData()
                self.isLoading = false
                
                print("🎉 Successfully deleted podcast feed: \(feed.title)")
                
            } catch {
                print("❌ Failed to delete podcast feed: \(error)")
                self.error = "Failed to delete podcast feed: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupObservers() {
        // Setup observers for episode state changes
        // Note: EpisodeStateManager.shared.progressPublisher is not implemented yet
        // Will be added when state management is fully integrated
    }
    
    private func performEpisodeLoad(feedId: String, page: Int, isInitialLoad: Bool = false, isAppending: Bool = false) async {
        os_log("📥 Loading episodes for feed %@ (page %d)", log: log, type: .info, feedId, page)
        print("🔍 DEBUG: performEpisodeLoad called for feedId: \(feedId), page: \(page)")
        
        do {
            let result = try await episodeManager.loadEpisodes(
                feedId: feedId,
                page: page,
                pageSize: episodesPerPage,
                filter: EpisodeFilter(rawValue: currentTab) ?? .all,
                searchQuery: searchQuery.isEmpty ? nil : searchQuery
            )
            
            print("🔍 DEBUG: EpisodeManager returned \(result.episodes.count) episodes, hasMore: \(result.hasMore)")
            
            await MainActor.run {
                if isAppending {
                    self.currentEpisodes.append(contentsOf: result.episodes)
                } else {
                    self.currentEpisodes = result.episodes
                }
                
                self.hasMoreEpisodes = result.hasMore
                self.isLoadingEpisodes = false
                
                print("🔍 DEBUG: Updated currentEpisodes to \(self.currentEpisodes.count) episodes")
                os_log("📊 Loaded %d episodes (page %d), hasMore: %@", 
                      log: self.log, type: .info, result.episodes.count, page, result.hasMore ? "true" : "false")
            }
            
            // Update episode counts
            if page == 1 && !isAppending {
                await updateEpisodeCountsForCurrentFeed()
            }
            
        } catch {
            print("🔍 DEBUG: Error loading episodes: \(error)")
            await MainActor.run {
                self.error = "Failed to load episodes: \(error.localizedDescription)"
                self.isLoadingEpisodes = false
                os_log("❌ Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func refreshEpisodeStatesFromManager() {
        // Update episode states without triggering a full reload
        let updatedEpisodes = currentEpisodes.map { episode in
            var updated = episode
            updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            updated.state.isPlayed = updated.state.progress >= 0.99
            return updated
        }
        
        currentEpisodes = updatedEpisodes
    }
    
    private func updateEpisodeCountsForCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        do {
            // Get episode counts (simplified for now)
            let allCount = currentEpisodes.count
            let favoritesCount = currentEpisodes.filter { $0.state.isFavorite }.count
            let downloadsCount = currentEpisodes.filter { $0.state.isDownloaded }.count
            
            await MainActor.run {
                self.episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
            }
        } catch {
            os_log("❌ Failed to update episode counts: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - Fresh Install & CloudKit Integration
    
    /// Check for CloudKit sync and setup new feeds if needed
    private func checkForFreshInstallAndSetup() async {
        print("🔄 Checking for CloudKit sync...")
        
        do {
            // Check if this is a fresh install (no feeds in Core Data)
            let existingFeedCount = await countExistingFeeds()
            let isFreshInstall = existingFeedCount == 0
            
            if isFreshInstall {
                print("🆕 Fresh install detected - fetching feeds from CloudKit")
            } else {
                print("📱 Existing installation with \(existingFeedCount) feeds - syncing updates")
            }
            
            // Fetch feeds from CloudKit
            let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            
            if !cloudKitFeeds.isEmpty {
                print("🌟 Synced \(cloudKitFeeds.count) feeds from CloudKit")
                
                if isFreshInstall {
                    // Fresh install: Process all feeds and parse their RSS
                    await processFreshInstallFeeds(cloudKitFeeds)
                } else {
                    // Existing install: Merge new feeds only
                    await mergeCloudKitFeeds(cloudKitFeeds)
                }
                
                // Update UI on main thread
                await MainActor.run {
                    self.loadFeedsFromCoreData()
                }
            } else {
                print("📡 No feeds found in CloudKit")
            }
            
        } catch {
            print("❌ CloudKit sync failed: \(error)")
        }
    }
    
    /// Sync episode states from CloudKit with different behavior based on install type
    private func syncEpisodeStatesFromCloudKit(isFreshInstall: Bool) async {
        print("🔄 Syncing episode states from CloudKit (fresh install: \(isFreshInstall))")
        
        do {
            // Get episode IDs from ALL loaded feeds, not just currentEpisodes
            var allEpisodeIds: [String] = []
            
            // Load current feeds and get all episode IDs
            await MainActor.run {
                self.loadFeedsFromCoreData()
                for feed in podcastFeeds {
                    allEpisodeIds.append(contentsOf: feed.episodes.map { $0.id })
                }
            }
            
            print("📊 Found \(allEpisodeIds.count) total episodes across \(podcastFeeds.count) feeds for state sync")
            
            if !allEpisodeIds.isEmpty {
                // Sync episode states with appropriate behavior for install type
                let coreDataUpdates = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds, 
                    isFreshInstall: isFreshInstall
                )
                
                // Save all synced states to Core Data immediately for fast app restart
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 Saved \(coreDataUpdates.count) episode states to Core Data for immediate availability")
                    } catch {
                        print("❌ Failed to save synced episode states to Core Data: \(error)")
                    }
                }
                
                // Refresh episode states from the updated EpisodeStateManager
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                }
                
                print("✅ Episode states synced from CloudKit for \(allEpisodeIds.count) episodes, \(coreDataUpdates.count) saved to Core Data")
            } else {
                print("📊 No episodes found to sync states for - feeds may not have episodes loaded yet")
            }
            
        } catch {
            print("❌ Failed to sync episode states from CloudKit: \(error)")
        }
    }
    
    /// Count existing feeds in Core Data
    private func countExistingFeeds() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Failed to count existing feeds: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    /// Process fresh install feeds by parsing RSS and saving to Core Data
    private func processFreshInstallFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        await MainActor.run {
            self.isLoading = true
        }
        
        // Remove duplicates from CloudKit feeds before processing
        let uniqueFeeds = removeDuplicateFeeds(cloudKitFeeds)
        print("📊 Removed \(cloudKitFeeds.count - uniqueFeeds.count) duplicate feeds from CloudKit data")
        
        for feed in uniqueFeeds {
            do {
                print("📡 Processing feed: \(feed.title)")
                
                // Use FeedManager to properly add feed with RSS parsing
                guard let url = URL(string: feed.url) else {
                    print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                    continue
                }
                
                let addedFeed = try await feedManager.addFeed(from: url)
                print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                
            } catch {
                print("❌ Failed to process feed \(feed.title): \(error)")
                
                // Save feed without episodes if RSS parsing fails
                try? await saveFeedToCoreData(feed)
            }
        }
        
        await MainActor.run {
            self.isLoading = false
        }
        
        print("🎉 Fresh install processing complete")
        
        // Clean up any duplicates that might have been created
        await cleanupDuplicateFeeds()
        
        // IMPORTANT: Now that episodes are loaded, sync their states from CloudKit
        print("🔄 Starting episode state sync after fresh install processing...")
        await syncEpisodeStatesFromCloudKit(isFreshInstall: true)
    }
    
    /// Merge CloudKit feeds with existing local feeds
    private func mergeCloudKitFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        let context = CoreDataStack.shared.context
        
        await withCheckedContinuation { continuation in
            context.perform {
                do {
                    // Get existing feeds and create comprehensive duplicate check
                    let existingRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let existingFeeds = try context.fetch(existingRequest)
                    
                    // Create sets for efficient duplicate checking
                    let existingFeedIds = Set(existingFeeds.compactMap { $0.id })
                    let existingFeedUrls = Set(existingFeeds.compactMap { $0.url })
                    let existingFeedTitles = Set(existingFeeds.compactMap { $0.title })
                    
                    // Add new feeds that don't exist locally (check by ID, URL, and title)
                    var newFeedsAdded = 0
                    for cloudFeed in cloudKitFeeds {
                        let isDuplicateById = existingFeedIds.contains(cloudFeed.id)
                        let isDuplicateByUrl = existingFeedUrls.contains(cloudFeed.url)
                        let isDuplicateByTitle = existingFeedTitles.contains(cloudFeed.title)
                        
                        if !isDuplicateById && !isDuplicateByUrl && !isDuplicateByTitle {
                            let feedModel = FeedModel(context: context)
                            feedModel.update(from: cloudFeed)
                            newFeedsAdded += 1
                            print("📥 Adding new feed from CloudKit: \(cloudFeed.title)")
                        } else {
                            print("⚠️ Skipping duplicate feed from CloudKit: \(cloudFeed.title)")
                        }
                    }
                    
                    if newFeedsAdded > 0 {
                        try context.save()
                        print("✅ Merged \(newFeedsAdded) new feeds from CloudKit")
                    } else {
                        print("📊 No new feeds to merge from CloudKit (all were duplicates)")
                    }
                    
                    continuation.resume()
                } catch {
                    print("❌ Failed to merge CloudKit feeds: \(error)")
                    continuation.resume()
                }
            }
        }
        
        // After merging feeds, sync episode states for existing installation (upgrade)
        if !cloudKitFeeds.isEmpty {
            print("🔄 Starting episode state sync after merging feeds for existing installation...")
            await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
        }
    }
    
    /// Remove duplicate feeds from an array based on URL and title
    private func removeDuplicateFeeds(_ feeds: [PodcastFeed]) -> [PodcastFeed] {
        var seenUrls = Set<String>()
        var seenTitles = Set<String>()
        var uniqueFeeds: [PodcastFeed] = []
        
        for feed in feeds {
            let urlKey = feed.url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let titleKey = feed.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !seenUrls.contains(urlKey) && !seenTitles.contains(titleKey) {
                seenUrls.insert(urlKey)
                seenTitles.insert(titleKey)
                uniqueFeeds.append(feed)
            } else {
                print("🔍 Removing duplicate feed: \(feed.title) (\(feed.url))")
            }
        }
        
        return uniqueFeeds
    }
    
    /// Clean up any duplicate feeds that exist in Core Data
    private func cleanupDuplicateFeeds() async {
        print("🧹 Cleaning up duplicate feeds...")
        
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    let allFeeds = try context.fetch(fetchRequest)
                    
                    var seenUrls = Set<String>()
                    var seenTitles = Set<String>()
                    var feedsToDelete: [FeedModel] = []
                    
                    for feed in allFeeds {
                        guard let url = feed.url, let title = feed.title else { continue }
                        
                        let urlKey = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        let titleKey = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if seenUrls.contains(urlKey) || seenTitles.contains(titleKey) {
                            print("🗑️ Marking duplicate feed for deletion: \(title)")
                            feedsToDelete.append(feed)
                        } else {
                            seenUrls.insert(urlKey)
                            seenTitles.insert(titleKey)
                        }
                    }
                    
                    // Delete duplicate feeds
                    for feed in feedsToDelete {
                        context.delete(feed)
                    }
                    
                    if !feedsToDelete.isEmpty {
                        try context.save()
                        print("✅ Deleted \(feedsToDelete.count) duplicate feeds")
                    } else {
                        print("📊 No duplicate feeds found")
                    }
                    
                    continuation.resume()
                } catch {
                    print("❌ Failed to cleanup duplicate feeds: \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Save feed to Core Data with episodes
    private func saveFeedToCoreData(_ feed: PodcastFeed) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = CoreDataStack.shared.context
            
            context.perform {
                do {
                    // Create or update feed
                    let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    let feedModel: FeedModel
                    if let existingFeed = try context.fetch(feedRequest).first {
                        feedModel = existingFeed
                    } else {
                        feedModel = FeedModel(context: context)
                        feedModel.id = feed.id
                    }
                    
                    feedModel.update(from: feed)
                    
                    // Save episodes
                    for episode in feed.episodes {
                        let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        episodeRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                        
                        let episodeModel: PodcastModel
                        if let existingEpisode = try context.fetch(episodeRequest).first {
                            episodeModel = existingEpisode
                        } else {
                            episodeModel = PodcastModel(context: context)
                            episodeModel.id = episode.id
                        }
                        
                        episodeModel.update(from: episode)
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Updated initialization to include CloudKit sync check
    @MainActor
    func initializeWithCloudKitSupport() {
        print("🚀 Initializing PodcastViewModel with CloudKit support...")
        
        // Start with Core Data load for immediate UI
        loadFeedsFromCoreData()
        print("📊 Loaded \(podcastFeeds.count) feeds from Core Data")
        
        // Always check for CloudKit sync in background
        Task {
            await checkForFreshInstallAndSetup()
            
            // After CloudKit sync, check if any feeds need episode refreshing
            await refreshFeedsWithoutEpisodes()
            
            // Always attempt episode state sync after all initialization is complete
            print("🔄 Final episode state sync after full initialization...")
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
        }
    }
    
    /// Initialize episode state syncing for app startup
    @MainActor
    func initializeEpisodeStateSync() {
        print("🔄 Initializing episode state sync...")
        
        Task {
            // Determine if this is a fresh install
            let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let isFreshInstall = !hasLaunchedBefore
            
            if isFreshInstall {
                print("🆕 Fresh install detected - syncing episode states (excluding downloads)")
            } else {
                print("📱 Existing installation - syncing all episode states including downloads")
            }
            
            // Get all episode IDs from current episodes and all feeds
            var allEpisodeIds: [String] = []
            
            // Add current episodes
            allEpisodeIds.append(contentsOf: currentEpisodes.map { $0.id })
            
            // Add episodes from all feeds
            for feed in podcastFeeds {
                allEpisodeIds.append(contentsOf: feed.episodes.map { $0.id })
            }
            
            // Remove duplicates
            allEpisodeIds = Array(Set(allEpisodeIds))
            
            if !allEpisodeIds.isEmpty {
                // Sync episode states from CloudKit
                await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds,
                    isFreshInstall: isFreshInstall
                )
                
                // Update UI with synced states
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    if let selectedFeedId = self.selectedFeedId {
                        Task {
                            await self.loadEpisodesForFeed(selectedFeedId)
                        }
                    }
                }
                
                print("✅ Episode state sync completed for \(allEpisodeIds.count) episodes")
            } else {
                print("📊 No episodes found for state sync")
            }
        }
    }
    
    /// Refresh any feeds that don't have episodes by re-parsing their RSS
    private func refreshFeedsWithoutEpisodes() async {
        print("🔍 Checking for feeds without episodes...")
        
        // Check each feed for episode count
        var feedsToRefresh: [PodcastFeed] = []
        
        for feed in podcastFeeds {
            let episodeCount = await getEpisodeCountForFeed(feed.id)
            if episodeCount == 0 {
                print("📡 Feed '\(feed.title)' has 0 episodes, needs refresh")
                feedsToRefresh.append(feed)
            }
        }
        
        if !feedsToRefresh.isEmpty {
            print("🔄 Refreshing \(feedsToRefresh.count) feeds without episodes...")
            
            for feed in feedsToRefresh {
                do {
                    guard let url = URL(string: feed.url) else {
                        print("❌ Invalid URL for feed: \(feed.title)")
                        continue
                    }
                    
                    print("📡 Refreshing feed: \(feed.title)")
                    let (_, newEpisodes) = try await feedManager.refreshFeed(feed.id)
                    print("✅ Refreshed feed '\(feed.title)' with \(newEpisodes.count) episodes")
                    
                } catch {
                    print("❌ Failed to refresh feed '\(feed.title)': \(error)")
                }
            }
            
            // Reload feeds after refreshing
            await MainActor.run {
                self.loadFeedsFromCoreData()
                print("🎉 Completed refreshing feeds without episodes")
            }
        } else {
            print("✅ All feeds have episodes")
        }
    }
    
    /// Get episode count for a specific feed
    private func getEpisodeCountForFeed(_ feedId: String) async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.predicate = NSPredicate(format: "feedId == %@", feedId)
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Failed to count episodes for feed \(feedId): \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    // MARK: - Delete Feed with CloudKit Integration
    
    private func deleteFeedFromCoreData(_ feed: PodcastFeed) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = CoreDataStack.shared.context
            
            context.perform {
                do {
                    // Delete feed
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    let results = try context.fetch(fetchRequest)
                    for feedModel in results {
                        context.delete(feedModel)
                    }
                    
                    // Delete associated episodes
                    let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    episodeRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    
                    let episodes = try context.fetch(episodeRequest)
                    for episode in episodes {
                        context.delete(episode)
                    }
                    
                    try context.save()
                    continuation.resume()
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Refresh the current filtered episode list immediately
    private func refreshCurrentFilteredList() async {
        guard let feedId = selectedFeedId else { return }
        
        print("🔄 Refreshing filtered list for tab: \(currentTab)")
        
        // Reload episodes with current filter
        await performEpisodeLoad(feedId: feedId, page: 1, isInitialLoad: false, isAppending: false)
    }
    
    /// Delete downloaded episode with confirmation
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) async {
        print("🔍 DEBUG: Deleting download for '\(episode.title)' on tab \(currentTab)")
        
        // Delete the downloaded file from local storage
        print("🗑️ Deleting downloaded episode: \(episode.title)")
        
        do {
            // Delete the local file if it exists
            if let localFilePath = episode.localFilePath, !localFilePath.isEmpty {
                let localURL = URL(fileURLWithPath: localFilePath)
                if FileManager.default.fileExists(atPath: localFilePath) {
                    try FileManager.default.removeItem(at: localURL)
                    print("📁 Successfully deleted local file: \(localFilePath)")
                } else {
                    print("⚠️ Local file doesn't exist at path: \(localFilePath)")
                }
            }
            
            // CRITICAL: Update EpisodeStateManager first (source of truth for download state)
            EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
            
            // Clear local file path from Core Data
            await episodeManager.updateEpisodeLocalPath(episode.id, localPath: nil)
            
            // Update episode state in Core Data to ensure consistency
            try await episodeManager.updateEpisodeStates([
                EpisodeStateUpdate(episodeId: episode.id, isDownloaded: false)
            ])
            
            // Clear cache to force fresh load
            await episodeManager.clearCacheForFeed(episode.feedId)
            
            // Update local state immediately for all tabs
            await MainActor.run {
                // Update the episode in place across all states immediately
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    var updatedEpisode = self.currentEpisodes[index]
                    updatedEpisode.state.isDownloaded = false
                    updatedEpisode.localFilePath = nil
                    self.currentEpisodes[index] = updatedEpisode
                    print("🔍 DEBUG: Updated episode state immediately - isDownloaded: false")
                }
                
                // Update the episode in the feed object as well
                if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == self.selectedFeedId }),
                   let episodeIndex = self.podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episode.id }) {
                    var updatedFeed = self.podcastFeeds[feedIndex]
                    updatedFeed.episodes[episodeIndex].state.isDownloaded = false
                    updatedFeed.episodes[episodeIndex].localFilePath = nil
                    self.podcastFeeds[feedIndex] = updatedFeed
                }
                
                // If we're on downloads tab, remove the episode immediately
                if self.currentTab == EpisodeFilter.downloads.rawValue {
                    self.currentEpisodes.removeAll { $0.id == episode.id }
                }
            }
            
            print("✅ Successfully deleted download for episode: \(episode.title)")
            
        } catch {
            print("❌ Failed to delete downloaded episode: \(error)")
            
            // Even if file deletion fails, still update the database states to prevent ghost downloads
            EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
            await episodeManager.updateEpisodeLocalPath(episode.id, localPath: nil)
            do {
                try await episodeManager.updateEpisodeStates([
                    EpisodeStateUpdate(episodeId: episode.id, isDownloaded: false)
                ])
            } catch {
                print("❌ Failed to update episode states: \(error)")
            }
        }
    }
}

// MARK: - Backward Compatibility Methods

extension PodcastViewModel {
    // These methods provide backward compatibility with existing UI code
    
    @available(*, deprecated, message: "Use loadEpisodesForFeed instead")
    func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
        Task {
            await loadEpisodesForFeed(feed.id, isInitialLoad: true)
        }
    }
    
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func markEpisodeAsPlayed(_ episodeId: String) {
        updateEpisodeState(episodeId, isPlayed: true)
    }
    
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func toggleFavorite(for episodeId: String) {
        let currentState = currentEpisodes.first { $0.id == episodeId }?.state.isFavorite ?? false
        updateEpisodeState(episodeId, isFavorite: !currentState)
    }
    
    // MARK: - PodcastPlayer Compatibility Methods
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateEpisode(_ episode: PodcastEpisode) {
        Task {
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    self.currentEpisodes[index] = episode
                }
            }
        }
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
        updateEpisodeState(episode.id, progress: progress)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use EpisodeStateManager.shared.getProgress directly")
    func getProgress(for episode: PodcastEpisode) -> Double {
        return EpisodeStateManager.shared.getProgress(for: episode.id)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func markEpisodeAsCompleted(_ episode: PodcastEpisode) {
        updateEpisodeState(episode.id, progress: 1.0, isPlayed: true)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateEpisodeDuration(_ episode: PodcastEpisode, newDuration: TimeInterval) {
        Task {
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    var updatedEpisode = self.currentEpisodes[index]
                    updatedEpisode.duration = newDuration
                    self.currentEpisodes[index] = updatedEpisode
                }
            }
        }
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        // Simply mark as played for now
        updateEpisodeState(episode.id, isPlayed: true)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use podcastFeeds directly")
    func getLastPlayedOrLatestEpisode(for feed: PodcastFeed) -> PodcastEpisode? {
        // Return the first episode from current episodes if any
        return currentEpisodes.first
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use currentEpisodes directly")
    var allEpisodes: [PodcastEpisode] {
        return currentEpisodes
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use proper error handling")
    func showNoEpisodesInProgressAlert(for feed: PodcastFeed) {
        print("⚠️ No episodes in progress for feed: \(feed.title)")
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use Core Data save functionality")
    func saveContextIfNeeded() {
        Task {
            do {
                try CoreDataStack.shared.context.save()
            } catch {
                print("❌ Failed to save context: \(error)")
            }
        }
    }
    
    /// For AddStationView compatibility
    @available(*, deprecated, message: "Use loadEpisodesForFeed instead")
    func fetchAllEpisodes(for feed: PodcastFeed) {
        Task {
            await loadEpisodesForFeed(feed.id, isInitialLoad: true)
        }
    }
    
    /// For PodcastPlayer compatibility
    @available(*, deprecated, message: "Use loadEpisodesForFeed instead")
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        Task {
            do {
                await loadEpisodesForFeed(feed.id, isInitialLoad: true)
                await MainActor.run {
                    let episodes = self.currentEpisodes.filter { $0.feedId == feed.id }
                    completion(.success(episodes))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use episode state filters instead")
    var favoriteEpisodes: [PodcastEpisode] {
        return allEpisodes.filter { $0.state.isFavorite }
    }
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use episode state filters instead")
    var downloadedEpisodes: [PodcastEpisode] {
        return allEpisodes.filter { $0.state.isDownloaded }
    }
    
    /// Toggle favorite state for an episode with proper filtering update
    func toggleFavorite(for episode: PodcastEpisode) {
        let currentState = episode.state.isFavorite
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling favorite for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        
        // Update EpisodeStateManager immediately (source of truth)
        EpisodeStateManager.shared.setFavorite(episode.id, isFavorite: newState)
        
        // Update local state immediately for all tabs
        Task { @MainActor in
            // Update the episode in place across all states immediately
            if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                var updatedEpisode = self.currentEpisodes[index]
                updatedEpisode.state.isFavorite = newState
                self.currentEpisodes[index] = updatedEpisode
                print("🔍 DEBUG: Updated episode state immediately - isFavorite: \(newState)")
            }
            
            // Update the episode in the feed object as well
            if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == self.selectedFeedId }),
               let episodeIndex = self.podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episode.id }) {
                var updatedFeed = self.podcastFeeds[feedIndex]
                updatedFeed.episodes[episodeIndex].state.isFavorite = newState
                self.podcastFeeds[feedIndex] = updatedFeed
            }
            
            // Apply filtering immediately based on current tab without reloading
            let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
            switch filter {
            case .favorites:
                // If we're on favorites tab and unfavoriting, remove the episode
                if !newState {
                    self.currentEpisodes.removeAll { $0.id == episode.id }
                }
            case .downloads:
                // No change needed for downloads tab when favoriting
                break
            case .all:
                // All tab shows everything, no filtering needed
                break
            }
        }
        
        // Update episode state with proper sync (background operation)
        updateEpisodeState(episode.id, isFavorite: newState)
    }
    
    /// Toggle download state for an episode with proper filtering update
    func toggleDownload(for episode: PodcastEpisode) {
        let currentState = episode.state.isDownloaded
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling download for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        
        // Update EpisodeStateManager immediately (source of truth)
        EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: newState)
        
        // Update local state immediately for all tabs
        Task { @MainActor in
            // Update the episode in place across all states immediately
            if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                var updatedEpisode = self.currentEpisodes[index]
                updatedEpisode.state.isDownloaded = newState
                self.currentEpisodes[index] = updatedEpisode
                print("🔍 DEBUG: Updated episode state immediately - isDownloaded: \(newState)")
            }
            
            // Update the episode in the feed object as well
            if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == self.selectedFeedId }),
               let episodeIndex = self.podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episode.id }) {
                var updatedFeed = self.podcastFeeds[feedIndex]
                updatedFeed.episodes[episodeIndex].state.isDownloaded = newState
                self.podcastFeeds[feedIndex] = updatedFeed
            }
            
            // Apply filtering immediately based on current tab without reloading
            let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
            switch filter {
            case .downloads:
                // If we're on downloads tab and removing download, remove the episode
                if !newState {
                    self.currentEpisodes.removeAll { $0.id == episode.id }
                }
            case .favorites:
                // No change needed for favorites tab when downloading
                break
            case .all:
                // All tab shows everything, no filtering needed
                break
            }
        }
        
        // Update episode state with proper sync (background operation)
        updateEpisodeState(episode.id, isDownloaded: newState)
    }
    
    /// For SettingsView compatibility
    @available(*, deprecated, message: "Use clear methods from managers instead")
    func clearAllPodcastData(completion: @escaping (Bool) -> Void) {
        clearPodcastCoreData { success, error in
            completion(success)
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use error handling instead")
    func triggerNoEpisodesAlert() {
        showNoEpisodesAlert = true
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use feed management methods instead")
    func saveFeedOrder() {
        saveFeedsToCoreData()
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func fetchPodcastFeeds() {
        loadFeedsFromCoreData()
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func loadFeedOrder() {
        // Load feeds from Core Data first, then sync order
        loadFeedsFromCoreData()
        podcastFeedOrder = podcastFeeds.map { $0.id }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func moveFeed(from source: IndexSet, to destination: Int) {
        movePodcastFeed(from: source, to: destination)
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func refreshAllFeeds() {
        Task {
            for feed in podcastFeeds {
                await loadEpisodesForFeed(feed.id, isInitialLoad: false)
            }
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use addPodcastFeed(url:) instead")
    func addPodcastFeed(_ feed: PodcastFeed) {
        Task {
            let success = await addPodcastFeed(url: feed.url)
            if success {
                await MainActor.run {
                    self.podcastFeedOrder.append(feed.id)
                }
            }
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func updatePodcastFeed(_ feed: PodcastFeed) {
        // Update the feed in the array
        if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
            podcastFeeds[index] = feed
        }
        
        // Save to Core Data
        saveFeedsToCoreData()
        
        print("📡 Updated podcast feed: \(feed.title)")
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func sortFeedsAlphabetically() {
        isAscendingSort.toggle()
        
        podcastFeeds.sort { feed1, feed2 in
            if isAscendingSort {
                return feed1.title.localizedCaseInsensitiveCompare(feed2.title) == .orderedAscending
            } else {
                return feed1.title.localizedCaseInsensitiveCompare(feed2.title) == .orderedDescending
            }
        }
        
        // Update feed order to match sorted feeds
        podcastFeedOrder = podcastFeeds.map { $0.id }
    }
    
    /// Sanitize filename by removing invalid characters
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid characters for filesystem
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "_")
        
        // Limit length to avoid filesystem issues
        let maxLength = 100
        if sanitized.count > maxLength {
            let startIndex = sanitized.startIndex
            let endIndex = sanitized.index(startIndex, offsetBy: maxLength)
            return String(sanitized[startIndex..<endIndex])
        }
        
        return sanitized
    }
    
    /// Download episode to local storage for offline playback
    func downloadEpisode(_ episode: PodcastEpisode, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let audioURL = URL(string: episode.audioUrl) else {
            completion(.failure(NSError(domain: "PodcastViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio URL"])))
            return
        }
        
        // Initialize download progress
        downloadProgress[episode.id] = 0.0
        
        // Create URLSession for downloading
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        // Start download task
        let downloadTask = session.downloadTask(with: audioURL) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    return
                }
                
                guard let tempURL = tempURL else {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    completion(.failure(NSError(domain: "PodcastViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "No download URL"])))
                    return
                }
                
                // Create local file path
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
                
                // Create episodes folder if it doesn't exist
                if !FileManager.default.fileExists(atPath: episodesFolder.path) {
                    try? FileManager.default.createDirectory(at: episodesFolder, withIntermediateDirectories: true)
                }
                
                // Create unique filename - sanitize episode ID for filesystem
                let fileExtension = audioURL.pathExtension.isEmpty ? "mp3" : audioURL.pathExtension
                let sanitizedId = self.sanitizeFilename(episode.id)
                let fileName = "\(sanitizedId).\(fileExtension)"
                let localURL = episodesFolder.appendingPathComponent(fileName)
                
                print("📁 DEBUG: Original episode ID: \(episode.id)")
                print("📁 DEBUG: Sanitized filename: \(fileName)")
                print("📁 DEBUG: Full local path: \(localURL.path)")
                print("📁 DEBUG: Temp file exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
                
                do {
                    // Check if temp file exists
                    guard FileManager.default.fileExists(atPath: tempURL.path) else {
                        throw NSError(domain: "PodcastViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Temporary download file not found at: \(tempURL.path)"])
                    }
                    
                    // Remove existing file if it exists
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.removeItem(at: localURL)
                        print("📁 DEBUG: Removed existing file at: \(localURL.path)")
                    }
                    
                    // Move downloaded file to permanent location
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                    print("📁 DEBUG: Successfully moved file from \(tempURL.path) to \(localURL.path)")
                    
                    // CRITICAL: Update both EpisodeStateManager AND Core Data for download state
                    EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: true)
                    
                    // Save local file path and download state to Core Data
                    Task {
                        await self.episodeManager.updateEpisodeLocalPath(episode.id, localPath: localURL.path)
                        // Also update the download state in Core Data to ensure consistency
                        do {
                            try await self.episodeManager.updateEpisodeStates([
                                EpisodeStateUpdate(episodeId: episode.id, isDownloaded: true)
                            ])
                        } catch {
                            print("❌ Failed to update episode states after download: \(error)")
                        }
                    }
                    
                    // Update local episode state immediately
                    if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                        var updatedEpisode = self.currentEpisodes[index]
                        updatedEpisode.state.isDownloaded = true
                        updatedEpisode.localFilePath = localURL.path
                        self.currentEpisodes[index] = updatedEpisode
                        print("🔍 DEBUG: Episode download completed - marked as downloaded with local path: \(localURL.path)")
                    }
                    
                    // Update the episode in the feed object as well
                    if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == self.selectedFeedId }),
                       let episodeIndex = self.podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episode.id }) {
                        var updatedFeed = self.podcastFeeds[feedIndex]
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = true
                        updatedFeed.episodes[episodeIndex].localFilePath = localURL.path
                        self.podcastFeeds[feedIndex] = updatedFeed
                    }
                    
                    self.downloadProgress[episode.id] = 1.0
                    completion(.success(true))
                    
                    // Clear download progress after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.downloadProgress.removeValue(forKey: episode.id)
                    }
                    
                    print("📁 Episode downloaded successfully to: \(localURL.path)")
                    
                } catch {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    print("❌ Failed to save downloaded episode: \(error)")
                }
            }
        }
        
        // Observe download progress
        let observation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.downloadProgress[episode.id] = progress.fractionCompleted
            }
        }
        
        downloadTask.resume()
        
        // Store observation to prevent deallocation
        // Note: In a production app, you'd want to manage these observations properly
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use updateFilter instead")
    func switchToTab(_ tab: Int, for feed: PodcastFeed) {
        currentTab = tab
        selectedFeedId = feed.id
        print("🔄 Switching to tab \(tab) for feed: \(feed.title)")
        Task {
            await loadEpisodesForFeed(feed.id, isInitialLoad: true)
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use loadMoreEpisodes() instead")
    func loadMoreEpisodes(for feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
        Task {
            await loadMoreEpisodes()
            await MainActor.run {
                completion(true)
            }
        }
    }
    
    // MARK: - Core Data Management (Radio Station Pattern)
    
    /// Save podcast feeds to Core Data using the same pattern as radio stations
    func saveFeedsToCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        
        // Fetch existing feeds
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        
        do {
            let existingFeeds = try context.fetch(fetchRequest)
            let existingDict = Dictionary(uniqueKeysWithValues: existingFeeds.map { ($0.id!, $0) })
            
            for (index, feed) in podcastFeeds.enumerated() {
                if let existingFeed = existingDict[feed.id] {
                    // Update existing feed
                    existingFeed.title = feed.title
                    existingFeed.url = feed.url
                    existingFeed.artworkUrl = feed.artworkUrl
                    existingFeed.descriptionText = feed.descriptionText
                    existingFeed.iconData = feed.iconData
                    existingFeed.imageData = feed.imageData
                    existingFeed.sortOrder = Int16(index)
                } else {
                    // Create new feed if it doesn't exist
                    let newFeed = FeedModel(context: context)
                    newFeed.id = feed.id
                    newFeed.title = feed.title
                    newFeed.url = feed.url
                    newFeed.artworkUrl = feed.artworkUrl
                    newFeed.descriptionText = feed.descriptionText
                    newFeed.iconData = feed.iconData
                    newFeed.imageData = feed.imageData
                    newFeed.sortOrder = Int16(index)
                }
            }
            
            // Remove feeds that are no longer in the array
            let feedIDs = Set(podcastFeeds.map { $0.id })
            for existingFeed in existingFeeds {
                if !feedIDs.contains(existingFeed.id!) {
                    context.delete(existingFeed)
                }
            }
            
            // Save changes
            try context.save()
            print("📡 CoreData podcast feeds updated successfully.")
        } catch {
            print("❌ Failed to update podcast feeds in CoreData: \(error)")
        }
    }
    
    /// Load podcast feeds from Core Data using the same pattern as radio stations
    func loadFeedsFromCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        
        // Add a sort descriptor to ensure feeds are loaded in the correct order
        let sortDescriptor = NSSortDescriptor(key: "sortOrder", ascending: true)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            let results = try context.fetch(request)
            if results.isEmpty {
                print("📡 No podcast feeds found in CoreData.")
                return
            }
            
            podcastFeeds = results.map { feedModel in
                // Load episodes for this feed
                var episodes: [PodcastEpisode] = []
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedModel.id ?? "")
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                do {
                    let episodeModels = try context.fetch(episodeRequest)
                    episodes = episodeModels.compactMap { $0.toPodcastEpisode() }
                    print("📡 Loaded \(episodes.count) episodes for feed: \(feedModel.title ?? "Unknown")")
                } catch {
                    print("❌ Failed to load episodes for feed \(feedModel.title ?? "Unknown"): \(error)")
                }
                
                return PodcastFeed(
                    id: feedModel.id ?? UUID().uuidString,
                    title: feedModel.title ?? "Unknown Feed",
                    url: feedModel.url ?? "",
                    artworkUrl: feedModel.artworkUrl,
                    description: feedModel.descriptionText,
                    iconData: feedModel.iconData,
                    imageData: feedModel.imageData,
                    episodes: episodes
                )
            }
            
            // Update feed order to match loaded feeds
            podcastFeedOrder = podcastFeeds.map { $0.id }
            
            print("📡 Loaded \(podcastFeeds.count) podcast feeds from CoreData.")
            
            // Debug: Check if episodes exist in Core Data
            let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let allEpisodes = try context.fetch(episodeRequest)
                print("🔍 DEBUG: Found \(allEpisodes.count) total episodes in Core Data")
                
                // Group by feedId to see distribution
                let episodesByFeed = Dictionary(grouping: allEpisodes) { $0.feedId ?? "unknown" }
                for (feedId, episodes) in episodesByFeed {
                    if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                        print("🔍 DEBUG: Feed '\(feed.title)' has \(episodes.count) episodes in Core Data")
                    } else {
                        print("🔍 DEBUG: Unknown feedId '\(feedId)' has \(episodes.count) episodes")
                    }
                }
            } catch {
                print("❌ Failed to count episodes: \(error)")
            }
            
            // Load episodes for the first feed if available
            if let firstFeed = podcastFeeds.first {
                print("📡 Loading episodes for first feed: \(firstFeed.title) (\(firstFeed.episodes.count) episodes available)")
                Task {
                    await loadEpisodesForFeed(firstFeed.id, isInitialLoad: true)
                }
            } else {
                print("📡 No feeds found in Core Data")
            }
            
        } catch {
            print("❌ Failed to load podcast feeds from CoreData: \(error)")
        }
    }
    
    /// Delete a podcast feed from Core Data (following radio station pattern)
    func deletePodcastFeedFromCoreData(_ feed: PodcastFeed) {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", feed.id)
        
        do {
            let results = try context.fetch(request)
            for object in results {
                context.delete(object)
            }
            try context.save()
            
            // Remove from in-memory arrays
            podcastFeeds.removeAll { $0.id == feed.id }
            podcastFeedOrder.removeAll { $0 == feed.id }
            
            // Remove associated episodes
            currentEpisodes.removeAll { $0.feedId == feed.id }
            
            print("📡 Podcast feed deleted from CoreData successfully.")
        } catch {
            print("❌ Failed to delete podcast feed from CoreData: \(error)")
        }
    }
    
    /// Clear all podcast data from Core Data (following radio station pattern)
    func clearPodcastCoreData(completion: @escaping (Bool, Error?) -> Void) {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        
        // Delete episodes first
        let episodeDeleteRequest = NSBatchDeleteRequest(fetchRequest: PodcastModel.fetchRequest())
        
        // Delete feeds
        let feedDeleteRequest = NSBatchDeleteRequest(fetchRequest: FeedModel.fetchRequest())
        
        context.perform {
            do {
                try context.execute(episodeDeleteRequest)
                try context.execute(feedDeleteRequest)
                try context.save()
                
                // Clear in-memory data
                DispatchQueue.main.async {
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    completion(true, nil)
                }
            } catch {
                print("❌ Error deleting podcast data from CoreData: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(false, error)
                }
            }
        }
    }
    
    /// Move feed order (following radio station pattern)
    func movePodcastFeed(from source: IndexSet, to destination: Int) {
        podcastFeedOrder.move(fromOffsets: source, toOffset: destination)
        
        // Reorder the actual feeds array to match
        var reorderedFeeds: [PodcastFeed] = []
        for feedId in podcastFeedOrder {
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                reorderedFeeds.append(feed)
            }
        }
        podcastFeeds = reorderedFeeds
        
        // Save the new order to Core Data
        saveFeedsToCoreData()
    }
}
