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
    
    /// Add a new podcast feed with background processing
    func addPodcastFeed(url: String) async -> Bool {
        isLoading = true
        
        guard let feedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.error = "Invalid URL format"
            isLoading = false
            return false
        }
        
        do {
            // Step 1: Parse RSS feed using the same system as test URL
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            let parser = SimplePodcastParser(data: data, feedUrl: url)
            let (feed, episodes) = try parser.parse()
            
            print("📊 Parsed feed '\(feed.title)' with \(episodes.count) episodes")
            
            // Step 2: Save to CloudKit first
            try await PodcastCloudKitManager.shared.savePodcastFeedToCloudKit(feed)
            print("✅ Saved feed to CloudKit: \(feed.title)")
            
            // Step 3: Save to Core Data
            try await saveFeedAndEpisodesToCoreData(feed, episodes: episodes)
            print("✅ Saved feed to Core Data: \(feed.title)")
            
            // Step 4: Update UI
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
            await MainActor.run {
                self.currentEpisodes = feed.episodes
                self.isLoadingEpisodes = false
                self.hasMoreEpisodes = false
                print("📊 Using pre-loaded episodes: \(self.currentEpisodes.count) episodes displayed")
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
    
    /// Update episode state efficiently
    func updateEpisodeState(_ episodeId: String, progress: Double? = nil, isFavorite: Bool? = nil, isDownloaded: Bool? = nil, isPlayed: Bool? = nil) {
        Task {
            // Update episode states directly for now
            EpisodeStateManager.shared.setProgress(for: episodeId, progress: progress ?? 0.0)
            if let isFavorite = isFavorite {
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
            }
            if let isDownloaded = isDownloaded {
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
            }
                
                // Update local state immediately for responsiveness
                await MainActor.run {
                    if let index = self.currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
                        var updatedEpisode = self.currentEpisodes[index]
                        
                        if let progress = progress {
                            updatedEpisode.state.progress = progress
                        }
                        if let isFavorite = isFavorite {
                            updatedEpisode.state.isFavorite = isFavorite
                        }
                        if let isDownloaded = isDownloaded {
                            updatedEpisode.state.isDownloaded = isDownloaded
                        }
                        if let isPlayed = isPlayed {
                            updatedEpisode.state.isPlayed = isPlayed
                        }
                        
                        self.currentEpisodes[index] = updatedEpisode
                    }
                }
                
                // Update counts if necessary
                if isFavorite != nil || isDownloaded != nil {
                    await updateEpisodeCountsForCurrentFeed()
                }
        }
    }
    
    /// Delete a podcast feed
    func deleteFeed(_ feedId: String) {
        Task {
            // Remove from UI immediately
            await MainActor.run {
                self.podcastFeeds.removeAll { $0.id == feedId }
                if self.selectedFeedId == feedId {
                    self.currentEpisodes = []
                    self.selectedFeedId = nil
                }
            }
            
            // TODO: Implement Core Data deletion
            os_log("🗑️ Feed deleted: %@", log: log, type: .info, feedId)
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
            // Note: isFavorite method not yet implemented in EpisodeStateManager
            updated.state.isFavorite = episode.state.isFavorite
            updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
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
            // Always try to sync with CloudKit, not just on fresh installs
            let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            
            if !cloudKitFeeds.isEmpty {
                print("🌟 Synced \(cloudKitFeeds.count) feeds from CloudKit")
                
                // Update UI on main thread
                await MainActor.run {
                    self.loadFeedsFromCoreData()
                }
            } else {
                print("📡 No new feeds to sync from CloudKit")
            }
        } catch {
            print("❌ CloudKit sync failed: \(error)")
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
        }
    }
    
    private func saveFeedAndEpisodesToCoreData(_ feed: PodcastFeed, episodes: [PodcastEpisode]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Check if feed already exists
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "url == %@", feed.url)
                    
                    if let existingFeed = try backgroundContext.fetch(fetchRequest).first {
                        print("📡 Feed already exists in Core Data: \(feed.title)")
                        continuation.resume()
                        return
                    }
                    
                    // Create new feed
                    let managedFeed = FeedModel(context: backgroundContext)
                    managedFeed.update(from: feed)
                    
                    // Save all episodes
                    for episode in episodes {
                        let managedEpisode = PodcastModel(context: backgroundContext)
                        var episodeWithFeedId = episode
                        episodeWithFeedId.feedId = feed.id
                        managedEpisode.update(from: episodeWithFeedId)
                        managedEpisode.feed = managedFeed
                    }
                    
                    try backgroundContext.save()
                    print("✅ Saved feed with \(episodes.count) episodes to Core Data")
                    continuation.resume()
                    
                } catch {
                    print("❌ Failed to save feed to Core Data: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Delete Feed with CloudKit Integration
    
    @MainActor
    func deletePodcastFeed(_ feed: PodcastFeed) {
        isLoading = true
        
        Task {
            do {
                // Step 1: Delete from CloudKit
                try await PodcastCloudKitManager.shared.deletePodcastFeedFromCloudKit(feed.id)
                print("✅ Deleted feed from CloudKit: \(feed.title)")
                
                // Step 2: Delete from Core Data
                try await deleteFeedFromCoreData(feed)
                print("✅ Deleted feed from Core Data: \(feed.title)")
                
                // Step 3: Update UI
                self.loadFeedsFromCoreData()
                isLoading = false
                
            } catch {
                print("❌ Failed to delete podcast feed: \(error)")
                self.error = "Failed to delete podcast feed: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
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
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func toggleFavorite(for episode: PodcastEpisode) {
        let currentState = episode.state.isFavorite
        updateEpisodeState(episode.id, isFavorite: !currentState)
    }
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) {
        updateEpisodeState(episode.id, isDownloaded: false)
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
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new episode management")
    func downloadEpisode(_ episode: PodcastEpisode, completion: @escaping (Result<Bool, Error>) -> Void) {
        // Simulate download progress
        downloadProgress[episode.id] = 0.0
        
        Task {
            // Simulate download with progress updates
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                await MainActor.run {
                    self.downloadProgress[episode.id] = progress
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
            
            // Complete download
            await MainActor.run {
                self.downloadProgress[episode.id] = 1.0
                completion(.success(true))
            }
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use updateFilter instead")
    func switchToTab(_ tab: Int, for feed: PodcastFeed) {
        currentTab = tab
        Task {
            await loadEpisodesForFeed(feed.id)
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

// MARK: - Supporting Types

enum EpisodeFilter: Int, CaseIterable {
    case all = 0
    case favorites = 1
    case downloads = 2
}

struct EpisodeLoadResult {
    let episodes: [PodcastEpisode]
    let hasMore: Bool
    let totalCount: Int
}

// MARK: - Temporary Manager Classes (until project configuration is fixed)

class PodcastFeedManager {
    private let log = OSLog(subsystem: "StreamRadios", category: "FeedManager")
    private let context = CoreDataStack.shared.context
    
    func loadSavedFeeds() async throws -> [PodcastFeed] {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    
                    let managedFeeds = try self.context.fetch(fetchRequest)
                    let feeds = managedFeeds.map { $0.toPodcastFeed() }
                    
                    continuation.resume(returning: feeds)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func addFeed(from url: URL) async throws -> PodcastFeed {
        print("🔄 PodcastFeedManager: Starting to add feed from \(url.absoluteString)")
        
        // Fetch and parse the RSS feed
        let (data, _) = try await URLSession.shared.data(from: url)
        print("📥 PodcastFeedManager: Downloaded \(data.count) bytes of RSS data")
        
        let parser = SimplePodcastParser(data: data, feedUrl: url.absoluteString)
        let (feed, episodes) = try parser.parse()
        
        print("✅ PodcastFeedManager: Parsed feed '\(feed.title)' with \(episodes.count) episodes")
        
        // Save feed and episodes to Core Data
        return try await saveFeedWithEpisodes(feed: feed, episodes: episodes)
    }
    
    private func saveFeedWithEpisodes(feed: PodcastFeed, episodes: [PodcastEpisode]) async throws -> PodcastFeed {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Check if feed already exists
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "url == %@", feed.url)
                    
                    if let existingFeed = try backgroundContext.fetch(fetchRequest).first {
                        print("📡 PodcastFeedManager: Feed already exists, updating...")
                        let podcastFeed = existingFeed.toPodcastFeed()
                        continuation.resume(returning: podcastFeed)
                        return
                    }
                    
                    // Create new feed
                    let managedFeed = FeedModel(context: backgroundContext)
                    managedFeed.update(from: feed)
                    
                    print("💾 PodcastFeedManager: Saving \(episodes.count) episodes...")
                    
                    // Save episodes
                    for episode in episodes {
                        let managedEpisode = PodcastModel(context: backgroundContext)
                        var episodeWithFeedId = episode
                        episodeWithFeedId.feedId = feed.id
                        managedEpisode.update(from: episodeWithFeedId)
                        managedEpisode.feed = managedFeed
                    }
                    
                    try backgroundContext.save()
                    print("✅ PodcastFeedManager: Successfully saved feed with \(episodes.count) episodes")
                    
                    continuation.resume(returning: feed)
                } catch {
                    print("❌ PodcastFeedManager: Failed to save feed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

class PodcastEpisodeManager {
    private let log = OSLog(subsystem: "StreamRadios", category: "EpisodeManager")
    
    func loadEpisodes(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async throws -> EpisodeLoadResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                    fetchRequest.fetchLimit = pageSize
                    fetchRequest.fetchOffset = (page - 1) * pageSize
                    
                    let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                    let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                    
                    let result = EpisodeLoadResult(
                        episodes: episodes,
                        hasMore: managedEpisodes.count == pageSize,
                        totalCount: episodes.count
                    )
                    
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Simple RSS Parser

class SimplePodcastParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let feedUrl: String
    private var parser: XMLParser
    
    // Feed-level properties
    private var feedTitle: String?
    private var feedDescription: String?
    private var feedArtworkUrl: String?
    
    // Episode parsing
    private var episodes: [PodcastEpisode] = []
    private var currentElement = ""
    private var currentEpisode: EpisodeBuilder?
    private var isParsingItem = false
    private var characterBuffer = ""
    
    init(data: Data, feedUrl: String) {
        self.data = data
        self.feedUrl = feedUrl
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }
    
    func parse() throws -> (PodcastFeed, [PodcastEpisode]) {
        guard parser.parse() else {
            throw PodcastError.parsingFailed
        }
        
        guard let title = feedTitle else {
            throw PodcastError.parsingFailed
        }
        
        let feed = PodcastFeed(
            title: title,
            url: feedUrl,
            artworkUrl: feedArtworkUrl,
            description: feedDescription
        )
        
        print("📊 SimplePodcastParser: Parsed '\(title)' with \(episodes.count) episodes")
        return (feed, episodes)
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        characterBuffer = ""
        
        switch elementName {
        case "item":
            isParsingItem = true
            currentEpisode = EpisodeBuilder()
        case "enclosure":
            if isParsingItem, let url = attributeDict["url"] {
                currentEpisode?.audioUrl = url
            }
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterBuffer += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { characterBuffer = "" }
        
        if isParsingItem {
            // Parse episode elements
            switch elementName {
            case "item":
                if let episode = currentEpisode?.build() {
                    episodes.append(episode)
                }
                currentEpisode = nil
                isParsingItem = false
            case "title":
                currentEpisode?.title = characterBuffer
            case "description":
                currentEpisode?.description = characterBuffer
            case "pubDate":
                currentEpisode?.pubDate = characterBuffer
            case "guid":
                currentEpisode?.guid = characterBuffer
            case "itunes:duration":
                currentEpisode?.duration = characterBuffer
            default:
                break
            }
        } else {
            // Parse feed-level elements
            switch elementName {
            case "title":
                if feedTitle == nil { // Only set the first title (channel title)
                    feedTitle = characterBuffer
                }
            case "description":
                if feedDescription == nil {
                    feedDescription = characterBuffer
                }
            case "itunes:image":
                if feedArtworkUrl == nil {
                    feedArtworkUrl = characterBuffer
                }
            default:
                break
            }
        }
    }
}

// MARK: - Episode Builder

private class EpisodeBuilder {
    var title: String?
    var description: String?
    var audioUrl: String?
    var pubDate: String?
    var guid: String?
    var duration: String?
    
    func build() -> PodcastEpisode? {
        guard let title = title,
              let description = description,
              let audioUrl = audioUrl else {
            return nil
        }
        
        let publicationDate = parseDate(pubDate) ?? Date()
        let episodeDuration = parseDuration(duration ?? "0")
        let episodeId = guid ?? UUID().uuidString
        
        return PodcastEpisode(
            id: episodeId,
            title: title,
            descriptionText: description,
            audioUrl: audioUrl,
            publicationDate: publicationDate,
            duration: episodeDuration,
            state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
            feedId: "" // Will be set when saving
        )
    }
    
    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }
}

// MARK: - Error Types

enum PodcastError: Error, LocalizedError {
    case parsingFailed
    case networkError
    case invalidURL
    
    var errorDescription: String? {
        switch self {
        case .parsingFailed:
            return "Failed to parse podcast feed"
        case .networkError:
            return "Network error occurred"
        case .invalidURL:
            return "Invalid podcast URL"
        }
    }
}

// MARK: - Helper Extensions

// Helper function to parse duration
func parseDuration(_ durationString: String) -> TimeInterval {
    let components = durationString.components(separatedBy: ":")
    
    if components.count == 3 {
        // HH:MM:SS format
        let hours = Double(components[0]) ?? 0
        let minutes = Double(components[1]) ?? 0
        let seconds = Double(components[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    } else if components.count == 2 {
        // MM:SS format
        let minutes = Double(components[0]) ?? 0
        let seconds = Double(components[1]) ?? 0
        return minutes * 60 + seconds
    } else {
        // Just seconds
        return Double(durationString) ?? 0
    }
}

// MARK: - CloudKit Integration

/// Enhanced CloudKit manager for podcast feeds with fresh install support
class PodcastCloudKitManager {
    static let shared = PodcastCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "PodcastCloudKit")
    
    // CloudKit Record Types
    private enum RecordType {
        static let podcastFeed = "PodcastFeed"
        static let podcastEpisode = "PodcastEpisode"
    }
    
    // Batch limits for CloudKit operations
    private enum BatchLimits {
        static let maxRecordsPerOperation = 400
        static let maxEpisodesPerFeed = 1000 // Allow more episodes per feed
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
    }
    
    // MARK: - Fresh Install Setup
    
    /// Complete fresh install setup - fetches all podcast feeds from CloudKit and saves to Core Data
    func performFreshInstallSetup() async throws -> [PodcastFeed] {
        os_log("🌟 Starting fresh install CloudKit setup", log: log, type: .info)
        
        // Step 1: Check if this is actually a fresh install
        let coreDataFeedCount = await getCoreDataFeedCount()
        if coreDataFeedCount > 0 {
            os_log("📡 Found %d existing feeds in Core Data - skipping fresh install", log: log, type: .info, coreDataFeedCount)
            return []
        }
        
        // Step 2: Fetch all podcast feeds from CloudKit
        let cloudKitFeeds = try await fetchAllPodcastFeedsFromCloudKit()
        os_log("🌟 Fetched %d podcast feeds from CloudKit", log: log, type: .info, cloudKitFeeds.count)
        
        guard !cloudKitFeeds.isEmpty else {
            os_log("📡 No feeds found in CloudKit - fresh install complete", log: log, type: .info)
            return []
        }
        
        // Step 3: For each feed, parse RSS and save to Core Data using the same system as test URL
        var processedFeeds: [PodcastFeed] = []
        
        for cloudFeed in cloudKitFeeds {
            do {
                let processedFeed = try await parseRSSAndSaveToCoreData(cloudFeed)
                processedFeeds.append(processedFeed)
                os_log("✅ Processed feed: %@", log: log, type: .info, processedFeed.title)
            } catch {
                os_log("❌ Failed to process feed %@: %@", log: log, type: .error, cloudFeed.title, error.localizedDescription)
            }
        }
        
        os_log("🌟 Fresh install complete - processed %d feeds", log: log, type: .info, processedFeeds.count)
        return processedFeeds
    }
    
    /// Sync from CloudKit - fetches all feeds and only adds new ones
    func syncFromCloudKit() async throws -> [PodcastFeed] {
        os_log("🔄 Starting CloudKit sync", log: log, type: .info)
        
        // Step 1: Fetch all podcast feeds from CloudKit
        let cloudKitFeeds = try await fetchAllPodcastFeedsFromCloudKit()
        os_log("📡 Fetched %d podcast feeds from CloudKit", log: log, type: .info, cloudKitFeeds.count)
        
        guard !cloudKitFeeds.isEmpty else {
            os_log("📡 No feeds found in CloudKit", log: log, type: .info)
            return []
        }
        
        // Step 2: Get existing feed URLs from Core Data
        let existingFeedUrls = await getExistingFeedUrls()
        
        // Step 3: Filter out feeds that already exist
        let newFeeds = cloudKitFeeds.filter { !existingFeedUrls.contains($0.url) }
        os_log("📊 Found %d new feeds to sync (out of %d total)", log: log, type: .info, newFeeds.count, cloudKitFeeds.count)
        
        // Step 4: Process only new feeds
        var processedFeeds: [PodcastFeed] = []
        
        for cloudFeed in newFeeds {
            do {
                let processedFeed = try await parseRSSAndSaveToCoreData(cloudFeed)
                processedFeeds.append(processedFeed)
                os_log("✅ Synced new feed: %@", log: log, type: .info, processedFeed.title)
            } catch {
                os_log("❌ Failed to sync feed %@: %@", log: log, type: .error, cloudFeed.title, error.localizedDescription)
            }
        }
        
        os_log("🔄 CloudKit sync complete - processed %d new feeds", log: log, type: .info, processedFeeds.count)
        return processedFeeds
    }
    
    /// Get existing feed URLs from Core Data
    private func getExistingFeedUrls() async -> Set<String> {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                fetchRequest.propertiesToFetch = ["url"]
                
                do {
                    let feedModels = try context.fetch(fetchRequest)
                    let urls = Set(feedModels.compactMap { $0.url })
                    os_log("📊 Found %d existing feed URLs in Core Data", log: self.log, type: .debug, urls.count)
                    continuation.resume(returning: urls)
                } catch {
                    os_log("❌ Error fetching existing feed URLs: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(returning: Set())
                }
            }
        }
    }
    
    // MARK: - Core Data Integration
    
    private func getCoreDataFeedCount() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                fetchRequest.includesPropertyValues = false
                fetchRequest.includesSubentities = false
                
                do {
                    let count = try context.count(for: fetchRequest)
                    continuation.resume(returning: count)
                } catch {
                    os_log("❌ Error counting Core Data feeds: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    private func parseRSSAndSaveToCoreData(_ cloudFeed: PodcastFeed) async throws -> PodcastFeed {
        // Use the same RSS parsing system as the test URL
        guard let url = URL(string: cloudFeed.url) else {
            throw PodcastCloudKitError.invalidURL
        }
        
        // Fetch RSS data
        let (data, _) = try await URLSession.shared.data(from: url)
        os_log("📥 Downloaded RSS data for %@: %d bytes", log: log, type: .debug, cloudFeed.title, data.count)
        
        // Parse using the same parser as test URL
        let parser = SimplePodcastParser(data: data, feedUrl: cloudFeed.url)
        let (parsedFeed, episodes) = try parser.parse()
        
        // Merge CloudKit metadata with parsed data - create new feed with CloudKit ID
        let finalFeed = PodcastFeed(
            id: cloudFeed.id, // Keep CloudKit ID
            title: parsedFeed.title,
            url: parsedFeed.url,
            artworkUrl: parsedFeed.artworkUrl,
            description: parsedFeed.descriptionText,
            iconData: cloudFeed.iconData,
            imageData: cloudFeed.imageData, // Keep CloudKit artwork
            episodes: parsedFeed.episodes
        )
        
        os_log("📊 Parsed %@ with %d episodes", log: log, type: .info, finalFeed.title, episodes.count)
        
        // Save to Core Data
        try await saveFeedAndEpisodesToCoreData(finalFeed, episodes: episodes)
        
        return finalFeed
    }
    
    private func saveFeedAndEpisodesToCoreData(_ feed: PodcastFeed, episodes: [PodcastEpisode]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Check if feed already exists
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    if let existingFeed = try backgroundContext.fetch(fetchRequest).first {
                        os_log("📡 Feed %@ already exists in Core Data", log: self.log, type: .info, feed.title)
                        continuation.resume()
                        return
                    }
                    
                    // Create new feed
                    let managedFeed = FeedModel(context: backgroundContext)
                    managedFeed.update(from: feed)
                    
                    // Save all episodes
                    for episode in episodes {
                        let managedEpisode = PodcastModel(context: backgroundContext)
                        var episodeWithFeedId = episode
                        episodeWithFeedId.feedId = feed.id
                        managedEpisode.update(from: episodeWithFeedId)
                        managedEpisode.feed = managedFeed
                    }
                    
                    try backgroundContext.save()
                    os_log("✅ Saved feed %@ with %d episodes to Core Data", log: self.log, type: .info, feed.title, episodes.count)
                    continuation.resume()
                    
                } catch {
                    os_log("❌ Failed to save feed to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - CloudKit Operations
    
    /// Save new podcast feed to CloudKit
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed) async throws {
        let record = CKRecord(recordType: RecordType.podcastFeed, recordID: CKRecord.ID(recordName: feed.id))
        
        // Basic feed information
        record["title"] = feed.title as CKRecordValue
        record["url"] = feed.url as CKRecordValue
        record["artworkUrl"] = feed.artworkUrl as CKRecordValue?
        record["descriptionText"] = feed.descriptionText as CKRecordValue?
        record["lastUpdated"] = Date() as CKRecordValue
        
        // Handle artwork efficiently
        if let imageData = feed.imageData {
            let asset = try await createAssetFromImageData(imageData, identifier: "artwork_\(feed.id)")
            record["artwork"] = asset
        }
        
        try await privateDatabase.save(record)
        os_log("✅ Saved podcast feed to CloudKit: %@", log: log, type: .info, feed.title)
    }
    
    /// Fetch all podcast feeds from CloudKit
    func fetchAllPodcastFeedsFromCloudKit() async throws -> [PodcastFeed] {
        let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
        return try await withCheckedThrowingContinuation { continuation in
            var allFeeds: [PodcastFeed] = []
            var cursor: CKQueryOperation.Cursor?
            
            func fetchBatch() {
                let operation: CKQueryOperation
                
                if let cursor = cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    operation = CKQueryOperation(query: query)
                }
                
                operation.resultsLimit = BatchLimits.maxRecordsPerOperation
                operation.qualityOfService = .userInitiated
                
                operation.recordFetchedBlock = { record in
                    if let feed = self.podcastFeedFromRecord(record) {
                        allFeeds.append(feed)
                    }
                }
                
                operation.queryCompletionBlock = { nextCursor, error in
                    if let error = error {
                        os_log("❌ Error fetching podcast feeds: %@", log: self.log, type: .error, error.localizedDescription)
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    if let nextCursor = nextCursor {
                        cursor = nextCursor
                        fetchBatch() // Fetch next batch
                    } else {
                        // All batches fetched
                        continuation.resume(returning: allFeeds)
                    }
                }
                
                privateDatabase.add(operation)
            }
            
            fetchBatch()
        }
    }
    
    /// Delete podcast feed from CloudKit
    func deletePodcastFeedFromCloudKit(_ feedId: String) async throws {
        let recordID = CKRecord.ID(recordName: feedId)
        try await privateDatabase.deleteRecord(withID: recordID)
        os_log("✅ Deleted podcast feed from CloudKit: %@", log: log, type: .info, feedId)
    }
    
    // MARK: - Utility Methods
    
    /// Create CloudKit asset from image data
    private func createAssetFromImageData(_ imageData: Data, identifier: String) async throws -> CKAsset {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier)
            .appendingPathExtension("jpg")
        
        try imageData.write(to: tempURL)
        return CKAsset(fileURL: tempURL)
    }
    
    /// Convert CloudKit record to PodcastFeed
    private func podcastFeedFromRecord(_ record: CKRecord) -> PodcastFeed? {
        guard let id = record.recordID.recordName as String?,
              let title = record["title"] as? String,
              let url = record["url"] as? String else {
            return nil
        }
        
        let artworkUrl = record["artworkUrl"] as? String
        let descriptionText = record["descriptionText"] as? String
        
        // Get cached artwork if available
        var imageData: Data?
        if let asset = record["artwork"] as? CKAsset,
           let artworkURL = asset.fileURL {
            imageData = try? Data(contentsOf: artworkURL)
        }
        
        return PodcastFeed(
            id: id,
            title: title,
            url: url,
            artworkUrl: artworkUrl,
            description: descriptionText,
            iconData: nil,
            imageData: imageData,
            episodes: []
        )
    }
}

// MARK: - CloudKit Error Types

enum PodcastCloudKitError: Error, LocalizedError {
    case invalidURL
    case noData
    case parsingFailed
    case cloudKitError(Error)
    case coreDataError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid podcast feed URL"
        case .noData:
            return "No data received from podcast feed"
        case .parsingFailed:
            return "Failed to parse podcast feed"
        case .cloudKitError(let error):
            return "CloudKit error: \(error.localizedDescription)"
        case .coreDataError(let error):
            return "Core Data error: \(error.localizedDescription)"
        }
    }
}
