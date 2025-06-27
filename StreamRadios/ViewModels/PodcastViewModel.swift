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
import UserNotifications
import BackgroundTasks

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
    
    // Store progress observations to prevent deallocation
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    
    // MARK: - New Episode Notification Properties
    private var lastKnownEpisodeCounts: [String: Int] = [:]
    private var lastKnownLatestEpisodeDates: [String: Date] = [:]
    private var backgroundCheckTimer: Timer?
    
    // MARK: - Private Properties
    private let log = OSLog(subsystem: "StreamRadios", category: "PodcastViewModel")
    private let feedManager = PodcastFeedManager()
    private let episodeManager = PodcastEpisodeManager()
    private let cloudKitManager = PodcastCloudKitManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Notification support for testing
    var notificationCenter: NotificationCenterProtocol?
    
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
        setupBackgroundNotificationObserver()
        
        // Load feeds from Core Data (radio station pattern)
        // Note: For fresh installs, this will initially find no feeds, but once RSS processing
        // completes and Core Data is properly synchronized, subsequent calls will work correctly
        loadFeedsFromCoreData()
        
        // Load last played episodes from UserDefaults
        loadLastPlayedEpisodes()
        
        // Note: CloudKit sync is now handled by explicit initializeWithCloudKitSupport() call
        // This prevents duplicate syncing when multiple ViewModels are created
    }
    
    deinit {
        loadingTask?.cancel()
        refreshTask?.cancel()
        backgroundCheckTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Background Notification Setup
    
    /// Set up observer for background episode checks
    private func setupBackgroundNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BackgroundPodcastCheck"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.checkForNewEpisodes()
            }
        }
    }
    
    // MARK: - New Episode Notification Methods
    
    /// Send notification for new episodes
    func sendNotification(for feed: PodcastFeed, newEpisodes: [PodcastEpisode]) {
        let episodeCount = newEpisodes.count
        let title = "New Episodes Available"
        let message = "\(episodeCount) new episode(s) available for \(feed.title)"
        
        if let notificationCenter = notificationCenter {
            // Use injected notification center (for testing)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = UNNotificationSound.default
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            notificationCenter.add(request, withCompletionHandler: nil)
        } else {
            // Use real notification manager
            NotificationManager.shared.notifyUser(title: title, message: message)
        }
        
        print("📱 Sent notification for \(episodeCount) new episodes in feed: \(feed.title)")
    }
    
    /// Check for new episodes across all feeds
    func checkForNewEpisodes() async {
        print("🔍 [DEBUG] Checking for new episodes across all feeds...")
        print("🔍 [DEBUG] Current time: \(Date())")
        print("🔍 [DEBUG] Number of feeds to check: \(podcastFeeds.count)")
        
        for feed in podcastFeeds {
            await checkForNewEpisodes(in: feed)
        }
        
        // Save the updated tracking data
        saveEpisodeTrackingData()
        print("🔍 [DEBUG] Completed checking all feeds")
    }
    
    /// Manually trigger new episode check (for UI buttons)
    @MainActor
    func manuallyCheckForNewEpisodes() {
        Task {
            await checkForNewEpisodes()
        }
    }
    
    /// Test method to simulate background notification (for debugging)
    @MainActor
    func testBackgroundNotification() {
        print("🧪 [TEST] Simulating background notification...")
        NotificationCenter.default.post(name: NSNotification.Name("BackgroundPodcastCheck"), object: nil)
    }
    
    /// Check for new episodes in a specific feed
    private func checkForNewEpisodes(in feed: PodcastFeed) async {
        do {
            // Refresh the feed to get latest episodes
            let (updatedFeed, allEpisodes) = try await feedManager.refreshFeed(feed.id)
            
            // Compare with last known state
            let currentEpisodeCount = allEpisodes.count
            let lastKnownCount = lastKnownEpisodeCounts[feed.id] ?? 0
            
            // Check if we have new episodes by count
            if currentEpisodeCount > lastKnownCount {
                let newEpisodeCount = currentEpisodeCount - lastKnownCount
                print("📱 Found \(newEpisodeCount) new episodes in feed: \(feed.title)")
                
                // Get the newest episodes
                let sortedEpisodes = allEpisodes.sorted { $0.publicationDate > $1.publicationDate }
                let newEpisodes = Array(sortedEpisodes.prefix(newEpisodeCount))
                
                // Send notification
                sendNotification(for: feed, newEpisodes: newEpisodes)
                
                // Update our tracking
                lastKnownEpisodeCounts[feed.id] = currentEpisodeCount
                if let latestEpisode = sortedEpisodes.first {
                    lastKnownLatestEpisodeDates[feed.id] = latestEpisode.publicationDate
                }
                
                // Update the feed in our local array
                await MainActor.run {
                    if let index = self.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                        self.podcastFeeds[index] = updatedFeed
                    }
                }
            } else {
                // Also check by date in case episodes were updated
                let sortedEpisodes = allEpisodes.sorted { $0.publicationDate > $1.publicationDate }
                if let latestEpisode = sortedEpisodes.first {
                    let lastKnownDate = lastKnownLatestEpisodeDates[feed.id] ?? Date.distantPast
                    
                    if latestEpisode.publicationDate > lastKnownDate {
                        print("📱 Found newer episode by date in feed: \(feed.title)")
                        sendNotification(for: feed, newEpisodes: [latestEpisode])
                        
                        // Update tracking
                        lastKnownLatestEpisodeDates[feed.id] = latestEpisode.publicationDate
                        lastKnownEpisodeCounts[feed.id] = currentEpisodeCount
                    }
                }
            }
            
        } catch {
            print("❌ Failed to check for new episodes in feed \(feed.title): \(error)")
        }
    }
    
    /// Initialize episode tracking for existing feeds
    private func initializeEpisodeTracking() async {
        print("📊 Initializing episode tracking for \(podcastFeeds.count) feeds...")
        
        // Load previously saved tracking data
        loadEpisodeTrackingData()
        
        for feed in podcastFeeds {
            // Only set initial values if we don't have saved data
            if lastKnownEpisodeCounts[feed.id] == nil {
                let episodeCount = feed.episodes.count
                lastKnownEpisodeCounts[feed.id] = episodeCount
                
                if let latestEpisode = feed.episodes.max(by: { $0.publicationDate < $1.publicationDate }) {
                    lastKnownLatestEpisodeDates[feed.id] = latestEpisode.publicationDate
                }
            }
        }
        
        // Save the initial tracking data
        saveEpisodeTrackingData()
        
        print("✅ Episode tracking initialized")
    }
    
    /// Save episode tracking data to UserDefaults
    private func saveEpisodeTrackingData() {
        let defaults = UserDefaults.standard
        
        // Save episode counts
        let countsData = try? JSONEncoder().encode(lastKnownEpisodeCounts)
        defaults.set(countsData, forKey: "lastKnownEpisodeCounts")
        
        // Save latest episode dates
        let datesDict = lastKnownLatestEpisodeDates.mapValues { $0.timeIntervalSince1970 }
        let datesData = try? JSONEncoder().encode(datesDict)
        defaults.set(datesData, forKey: "lastKnownLatestEpisodeDates")
        
        print("💾 Saved episode tracking data for \(lastKnownEpisodeCounts.count) feeds")
    }
    
    /// Load episode tracking data from UserDefaults
    private func loadEpisodeTrackingData() {
        let defaults = UserDefaults.standard
        
        // Load episode counts
        if let countsData = defaults.data(forKey: "lastKnownEpisodeCounts"),
           let counts = try? JSONDecoder().decode([String: Int].self, from: countsData) {
            lastKnownEpisodeCounts = counts
            print("📁 Loaded episode counts for \(counts.count) feeds")
        }
        
        // Load latest episode dates
        if let datesData = defaults.data(forKey: "lastKnownLatestEpisodeDates"),
           let datesDict = try? JSONDecoder().decode([String: TimeInterval].self, from: datesData) {
            lastKnownLatestEpisodeDates = datesDict.mapValues { Date(timeIntervalSince1970: $0) }
            print("📁 Loaded episode dates for \(datesDict.count) feeds")
        }
    }
    
    /// Start background episode checking using BGTaskScheduler
    func startBackgroundEpisodeChecking() {
        // Initialize tracking first
        Task {
            await initializeEpisodeTracking()
        }
        
        // Schedule the first background task
        BackgroundTaskManager.shared.schedulePodcastEpisodeCheck()
        print("🕐 Started background episode checking using BGTaskScheduler")
    }
    
    /// Stop background checking
    func stopBackgroundEpisodeChecking() {
        // Cancel any pending background tasks
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.streamradios.podcast.episodecheck")
        print("⏹️ Stopped background episode checking")
    }
    
    /// Legacy timer-based checking (for fallback when background tasks aren't available)
    func startPeriodicEpisodeChecking(interval: TimeInterval = 3600) { // Default: 1 hour
        backgroundCheckTimer?.invalidate()
        
        // Initialize tracking first
        Task {
            await initializeEpisodeTracking()
        }
        
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkForNewEpisodes()
            }
        }
        
        print("🕐 Started fallback timer-based episode checking every \(interval) seconds")
    }
    
    /// Stop periodic checking
    func stopPeriodicEpisodeChecking() {
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = nil
        print("⏹️ Stopped periodic episode checking")
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
    
    /// Add a new podcast feed with immediate UI update and background processing
    func addPodcastFeed(url: String) async -> Bool {
        guard let feedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await MainActor.run {
                self.error = "Invalid URL format"
            }
            return false
        }
        
        // Notify user that import started
        await MainActor.run {
            NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing podcast feed from URL...")
        }
        
        do {
            // Step 1: Parse feed and create feed object
            let feed = try await feedManager.addFeed(from: feedURL)
            print("📊 Parsed feed: \(feed.title)")
            
            // Step 2: Immediate UI update - add to arrays for instant feedback
            await MainActor.run {
                self.podcastFeeds.append(feed)
                self.podcastFeedOrder.append(feed.id)
                self.objectWillChange.send()
                print("✅ Feed immediately added to UI: \(feed.title)")
            }
            
            // Step 3: Background CloudKit sync
            Task {
                do {
                    try await cloudKitManager.savePodcastFeedToCloudKit(feed)
                    print("☁️ Successfully saved feed to CloudKit: \(feed.title)")
                    
                    // Notify user of successful import
                    await MainActor.run {
                        NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported podcast '\(feed.title)'.")
                    }
                } catch {
                    print("⚠️ Failed to save feed to CloudKit (local save succeeded): \(error)")
                    // Continue even if CloudKit save fails - local data is preserved
                    
                    // Notify user of successful import with warning
                    await MainActor.run {
                        NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported podcast '\(feed.title)' locally. Some data may not sync to iCloud.")
                    }
                }
            }
            
            return true
            
        } catch {
            print("❌ Failed to add podcast feed: \(error)")
            await MainActor.run {
                self.error = "Failed to add podcast feed: \(error.localizedDescription)"
                NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: "Failed to import podcast feed: \(error.localizedDescription)")
            }
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
        
        // CRITICAL: Refresh episode states from local storage before displaying
        // This ensures any locally available states are shown immediately
        await refreshLocalEpisodeStates()
        
        // First check if episodes are already loaded in the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            print("🔍 DEBUG: Found \(feed.episodes.count) episodes already loaded in feed: \(feed.title)")
            
            // Refresh episode states from EpisodeStateManager to ensure they're current
            let episodesWithUpdatedStates = feed.episodes.map { episode in
                var updated = episode
                updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                updated.state.isPlayed = updated.state.progress >= 0.99
                return updated
            }
            
            // Apply filtering based on current tab
            let filter = EpisodeFilter(rawValue: currentTab) ?? .all
            let filteredEpisodes: [PodcastEpisode]
            
            switch filter {
            case .all:
                filteredEpisodes = episodesWithUpdatedStates
            case .favorites:
                filteredEpisodes = episodesWithUpdatedStates.filter { $0.state.isFavorite }
            case .downloads:
                filteredEpisodes = episodesWithUpdatedStates.filter { $0.state.isDownloaded }
            }
            
            print("🔍 DEBUG: Applied filter \(filter) - showing \(filteredEpisodes.count) of \(episodesWithUpdatedStates.count) episodes")
            
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
                
                // Check for new episodes in this specific feed
                if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                    await checkForNewEpisodes(in: feed)
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
            
            // Get feedId for the episode to establish CloudKit relationship
            let episodeFeedId: String?
            if let currentEpisode = self.currentEpisodes.first(where: { $0.id == episodeId }) {
                episodeFeedId = currentEpisode.feedId
                print("💾 DEBUG: Found feedId from currentEpisodes: \(episodeFeedId ?? "nil")")
            } else if let selectedId = self.selectedFeedId, !selectedId.isEmpty {
                // Fallback: use currently selected feed
                episodeFeedId = selectedId
                print("💾 DEBUG: Using selectedFeedId as fallback: \(episodeFeedId ?? "nil")")
            } else {
                // Last resort: query Core Data for the episode's feedId
                episodeFeedId = await self.getFeedIdForEpisode(episodeId)
                print("💾 DEBUG: Core Data lookup returned feedId: \(episodeFeedId ?? "nil")")
            }
            
            // Sync to CloudKit (single call, non-blocking) with feed relationship
            // Only sync if we have a valid feedId to prevent crashes
            if let validFeedId = episodeFeedId, !validFeedId.isEmpty {
                print("💾 DEBUG: Starting CloudKit save for episode \(episodeId)")
                print("💾 DEBUG: - feedId: \(validFeedId)")
                print("💾 DEBUG: - finalProgress: \(finalProgress)")
                print("💾 DEBUG: - currentFavorite: \(currentFavorite)")
                print("💾 DEBUG: - currentDownloaded: \(currentDownloaded)")
                print("💾 DEBUG: - finalIsPlayed: \(finalIsPlayed)")
                
                Task.detached(priority: .userInitiated) {
                    await PodcastCloudKitManager.shared.saveEpisodeState(
                        episodeId: episodeId,
                        feedId: validFeedId,
                        progress: finalProgress,
                        isFavorite: currentFavorite,
                        isDownloaded: currentDownloaded,
                        isPlayed: finalIsPlayed
                    )
                }
            } else {
                print("⚠️ Skipping CloudKit sync for episode \(episodeId) - no valid feedId found")
                print("⚠️ Debug: selectedFeedId=\(self.selectedFeedId ?? "nil"), currentEpisodes.count=\(self.currentEpisodes.count)")
                print("⚠️ Debug: currentEpisodes contain this episode? \(self.currentEpisodes.contains { $0.id == episodeId })")
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
        print("🗑️ Starting comprehensive deletion of feed: \(feed.title)")
        NotificationManager.shared.notifyUserImmediate(title: "Deletion Started", message: "Deleting podcast '\(feed.title)' and all episodes...")
        
        // Step 1: Get all episode IDs BEFORE any deletion starts to ensure we capture all episodes
        Task {
            let episodeIds = await getEpisodeIdsForFeed(feed.id)
            print("🗑️ Found \(episodeIds.count) episodes to clean up for feed: \(feed.title)")
            
            // Step 2: Immediate UI update - remove from arrays for instant feedback
            await MainActor.run {
                if let index = self.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                    self.podcastFeeds.remove(at: index)
                }
                self.podcastFeedOrder.removeAll { $0 == feed.id }
                self.currentEpisodes.removeAll { $0.feedId == feed.id }
                
                // Clear selected feed if it's the one being deleted
                if self.selectedFeedId == feed.id {
                    self.selectedFeedId = nil
                }
                
                // Trigger immediate UI update
                self.objectWillChange.send()
            }
            
            // Step 3: Background cleanup - all data associated with the feed
            do {
                // Delete episode progress, favorites, and downloads from EpisodeStateManager
                for episodeId in episodeIds {
                    EpisodeStateManager.shared.clearEpisodeData(episodeId)
                }
                print("✅ Cleared \(episodeIds.count) episode states from EpisodeStateManager")
                
                // Delete downloaded episode files
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                // Delete feed and all associated episode states from CloudKit
                do {
                    print("🔄 Attempting to delete feed and episode states from CloudKit: \(feed.id)")
                    print("🔍 Feed details - Title: '\(feed.title)', URL: '\(feed.url)'")
                    
                    // Debug: List all feeds in CloudKit before deletion
                    print("🔍 DEBUG: Listing all feeds in CloudKit before deletion:")
                    await cloudKitManager.debugListAllFeeds()
                    
                    // Debug: Check if feed exists by exact ID
                    await cloudKitManager.debugCheckFeedExists(feed.id)
                    
                    try await cloudKitManager.deletePodcastFeedFromCloudKit(feed.id)
                    print("☁️ Successfully deleted feed from CloudKit: \(feed.title)")
                    print("☁️ CloudKit explicitly deleted all \(episodeIds.count) related episode states (progress, favorites, downloads)")
                    
                    // Debug: List all feeds in CloudKit after deletion
                    print("🔍 DEBUG: Listing all feeds in CloudKit after deletion:")
                    await cloudKitManager.debugListAllFeeds()
                    
                } catch {
                    print("❌ Failed to delete feed from CloudKit: \(error)")
                    print("❌ CloudKit deletion error details: \(error.localizedDescription)")
                    if let ckError = error as? CKError {
                        print("❌ CloudKit error code: \(ckError.code)")
                        print("❌ CloudKit error description: \(ckError.localizedDescription)")
                    }
                    
                    // Debug: List all feeds after failed deletion
                    print("🔍 DEBUG: Listing all feeds in CloudKit after failed deletion:")
                    await cloudKitManager.debugListAllFeeds()
                }
                
                // Delete from Core Data (episodes and feed) - this will also remove episode states
                try await deleteFeedFromCoreData(feed)
                print("💾 Deleted feed and \(episodeIds.count) episodes from Core Data: \(feed.title)")
                
                print("🎉 Successfully completed comprehensive deletion of: \(feed.title)")
                print("📊 Cleanup summary:")
                print("   - EpisodeStateManager: \(episodeIds.count) episode states cleared")
                print("   - CloudKit: Feed and \(episodeIds.count) episode states explicitly deleted")
                print("   - Downloaded files: cleaned up")
                print("   - Core Data: feed and \(episodeIds.count) episodes deleted")
                
                // Notify user of successful deletion
                await MainActor.run {
                    NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Successfully deleted podcast '\(feed.title)' and all \(episodeIds.count) episodes.")
                }
                
            } catch {
                print("❌ Error during background cleanup: \(error)")
                
                // If background cleanup fails, reload UI to show correct state
                await MainActor.run {
                    self.loadFeedsFromCoreData()
                    self.error = "Failed to completely delete podcast: \(error.localizedDescription)"
                    NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to delete podcast '\(feed.title)': \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupObservers() {
        // Setup observers for episode state changes
        // Note: EpisodeStateManager.shared.progressPublisher is not implemented yet
        // Will be added when state management is fully integrated
    }
    
    /// Get all episode IDs for a feed from Core Data
    private func getEpisodeIdsForFeed(_ feedId: String) async -> [String] {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "feedId == %@", feedId)
                
                do {
                    let episodes = try context.fetch(request)
                    let episodeIds = episodes.compactMap { $0.id }
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to get episode IDs: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Get feedId for a specific episode from Core Data (fallback method)
    private func getFeedIdForEpisode(_ episodeId: String) async -> String? {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", episodeId)
                request.propertiesToFetch = ["feedId"]
                request.fetchLimit = 1
                
                do {
                    let episodes = try context.fetch(request)
                    let feedId = episodes.first?.feedId
                    print("🔍 Core Data lookup for episode \(episodeId) found feedId: \(feedId ?? "nil")")
                    continuation.resume(returning: feedId)
                } catch {
                    print("❌ Failed to get feedId for episode \(episodeId): \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Delete downloaded episode files from device storage
    private func deleteDownloadedEpisodeFiles(_ episodeIds: [String]) async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
        
        var deletedCount = 0
        
        for episodeId in episodeIds {
            // Try multiple file extensions as episodes might have different formats
            let extensions = ["mp3", "m4a", "wav", "aac"]
            let sanitizedId = sanitizeFilename(episodeId)
            
            for ext in extensions {
                let fileName = "\(sanitizedId).\(ext)"
                let fileURL = episodesFolder.appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        deletedCount += 1
                        print("🗑️ Deleted downloaded file: \(fileName)")
                        break // Found and deleted the file, no need to check other extensions
                    } catch {
                        print("❌ Failed to delete file \(fileName): \(error)")
                    }
                }
            }
        }
        
        print("📁 Deleted \(deletedCount) downloaded episode files")
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
        print("🔄 Refreshing episode states from EpisodeStateManager for ALL feeds")
        
        // Update episode states in currentEpisodes (currently displayed episodes)
        let updatedCurrentEpisodes = currentEpisodes.map { episode in
            var updated = episode
            updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            updated.state.isPlayed = updated.state.progress >= 0.99
            return updated
        }
        currentEpisodes = updatedCurrentEpisodes
        
        // CRITICAL: Also update episode states in ALL podcastFeeds so that download states
        // are preserved when switching between feeds after CloudKit sync
        var updatedFeeds = podcastFeeds
        for feedIndex in 0..<updatedFeeds.count {
            let updatedEpisodes = updatedFeeds[feedIndex].episodes.map { episode in
                var updated = episode
                updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                updated.state.isPlayed = updated.state.progress >= 0.99
                return updated
            }
            updatedFeeds[feedIndex].episodes = updatedEpisodes
        }
        podcastFeeds = updatedFeeds
        
        print("✅ Updated episode states for \(currentEpisodes.count) current episodes and \(podcastFeeds.count) feeds")
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
    private var cloudKitSyncInProgress = false
    private var episodeStatesSyncCompleted = false
    
    /// Refresh episode states from local storage only - no CloudKit sync
    /// This provides immediate display of any locally available states
    private func refreshLocalEpisodeStates() async {
        print("🔄 Refreshing local episode states for immediate display...")
        
        // Check if we have any episode progress data in EpisodeStateManager
        let progressCount = EpisodeStateManager.shared.episodeProgress.count
        let favoritesCount = EpisodeStateManager.shared.episodeFavorites.count
        let downloadsCount = EpisodeStateManager.shared.episodeDownloads.count
        
        print("✅ Local episode states available: \(progressCount) progress, \(favoritesCount) favorites, \(downloadsCount) downloads")
        
        // Mark as completed to prevent unnecessary sync attempts
        episodeStatesSyncCompleted = true
    }
    
    private func checkForFreshInstallAndSetup() async {
        // Prevent multiple concurrent CloudKit syncs
        guard !cloudKitSyncInProgress else {
            print("⚠️ CloudKit sync already in progress, skipping duplicate call")
            return
        }
        
        cloudKitSyncInProgress = true
        defer { 
            cloudKitSyncInProgress = false
            print("🔄 CloudKit sync completed, setting flag to false")
        }
        
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
                
                // Update UI on main thread with explicit refresh
                await MainActor.run {
                    self.loadFeedsFromCoreData()
                    
                    // CRITICAL: Explicit UI refresh for CloudKit sync completion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.objectWillChange.send()
                        print("🎯 CLOUDKIT SYNC: Triggered explicit UI refresh - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                    }
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
            // CRITICAL FIX: Get episode IDs directly from Core Data, not from in-memory podcastFeeds
            // During fresh install, podcastFeeds array may not be fully populated yet
            var allEpisodeIds: [String] = []
            
            // Get episode IDs directly from Core Data to ensure we get ALL episodes from ALL feeds
            allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            print("📊 Found \(allEpisodeIds.count) total episodes from Core Data for state sync")
            
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
                print("📊 No episodes found to sync states for - Core Data may not have episodes loaded yet")
            }
            
        } catch {
            print("❌ Failed to sync episode states from CloudKit: \(error)")
        }
    }
    
    /// Get all episode IDs directly from Core Data to ensure we don't miss any
    private func getAllEpisodeIdsFromCoreData() async -> [String] {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.propertiesToFetch = ["id", "feedId", "title"]
                    request.resultType = .dictionaryResultType
                    
                    // Core Data returns [NSDictionary] for dictionary result type, not [[String: Any]]
                    let results = try context.fetch(request) as! [NSDictionary]
                    let episodeIds = results.compactMap { $0["id"] as? String }
                    
                    // Debug: Show distribution of episodes across feeds
                    let episodesByFeed = Dictionary(grouping: results) { dict in
                        dict["feedId"] as? String ?? "unknown"
                    }
                    
                    print("🔍 DEBUG: Retrieved \(episodeIds.count) episode IDs from Core Data across \(episodesByFeed.count) feeds")
                    for (feedId, episodes) in episodesByFeed {
                        print("🔍 DEBUG: Feed '\(feedId)' has \(episodes.count) episodes for sync")
                        
                        // Show some example episode titles for verification
                        let sampleTitles = episodes.prefix(3).compactMap { $0["title"] as? String }
                        if !sampleTitles.isEmpty {
                            print("🔍 DEBUG: Sample episodes from feed '\(feedId)': \(sampleTitles.joined(separator: ", "))")
                        }
                    }
                    
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to fetch episode IDs from Core Data: \(error)")
                    continuation.resume(returning: [])
                }
            }
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
    
    /// Public method for DataSyncManager to process fresh install feeds
    func loadFreshInstallPodcastData(_ cloudKitFeeds: [PodcastFeed]) async {
        // Use the existing fresh install logic with progress updates  
        await MainActor.run {
            self.isLoading = true
        }
        
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        // Start artwork download tracking
        await MainActor.run {
            DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: cloudKitFeeds.count)
        }
        
        // Process feeds directly without accessing private methods
        for feed in cloudKitFeeds {
            do {
                print("📡 Processing feed: \(feed.title)")
                
                // Use public FeedManager to properly add feed with RSS parsing
                guard let url = URL(string: feed.url) else {
                    print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                    continue
                }
                
                let feedManager = PodcastFeedManager()
                let addedFeed = try await feedManager.addFeed(from: url, forceRefresh: true)
                print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                
            } catch {
                print("❌ Failed to process feed \(feed.title): \(error)")
                
                // Skip saving if RSS parsing fails - let the existing system handle it
                print("⚠️ Skipping feed save due to RSS parsing failure")
            }
        }
        
        print("🎉 Fresh install RSS processing complete")
        
        // CRITICAL: Trigger UI refresh after fresh install processing
        print("🔄 Triggered UI refresh after fresh install RSS processing")
        await triggerFreshInstallUIRefresh()
    }
    
    /// Explicitly trigger UI refresh for fresh install scenarios
    @MainActor
    func triggerFreshInstallUIRefresh() {
        print("🔄 Starting fresh install UI refresh...")
        
        // Force reload feeds from Core Data to pick up newly saved data
        loadFeedsFromCoreData()
        
        // Explicit UI refresh with a slight delay to ensure Core Data operations complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.objectWillChange.send()
            print("🎯 FRESH INSTALL: Triggered explicit UI refresh - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
        }
        
        // Set loading to false after refresh
        self.isLoading = false
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
        
        // Check what feeds already exist in Core Data to prevent duplicate processing
        let existingFeedUrls = await getExistingFeedUrls()
        let feedsToProcess = uniqueFeeds.filter { !existingFeedUrls.contains($0.url) }
        
        if feedsToProcess.isEmpty {
            print("✅ All feeds already exist in Core Data, skipping processing")
            await MainActor.run { 
                self.isLoading = false
                // Start artwork tracking even if no new feeds to process
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: 0)
            }
            return
        }
        
        print("📊 Processing \(feedsToProcess.count) new feeds (skipping \(uniqueFeeds.count - feedsToProcess.count) existing)")
        
        // Start artwork download tracking for the feeds we're about to process
        await MainActor.run {
            DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: feedsToProcess.count)
        }
        
        for feed in feedsToProcess {
            do {
                print("📡 Processing feed: \(feed.title)")
                
                // Use FeedManager to properly add feed with RSS parsing
                guard let url = URL(string: feed.url) else {
                    print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                    continue
                }
                
                let addedFeed = try await feedManager.addFeed(from: url, forceRefresh: true)
                print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                
            } catch {
                print("❌ Failed to process feed \(feed.title): \(error)")
                
                // Save feed without episodes if RSS parsing fails
                try? await saveFeedToCoreData(feed)
            }
        }
        
        print("🎉 Fresh install RSS processing complete")
        
        // Clean up any duplicates that might have been created
        await cleanupDuplicateFeeds()
        
        // CRITICAL: Clear episode cache and reload feeds from Core Data AFTER all RSS processing and cleanup
        await episodeManager.clearAllCache()
        
        // CRITICAL: Wait briefly for main context synchronization to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        await MainActor.run {
            self.isLoading = false
            
            // CRITICAL: Wait for Core Data to actually have the data before UI refresh
            self.waitForCoreDataAndRefreshUI()
        }
        
        // IMPORTANT: Now that episodes are loaded, sync their states from CloudKit
        print("🔄 Starting episode state sync after fresh install processing...")
        // CRITICAL FIX: Determine fresh install status properly instead of hard-coding
        let existingFeedCount = await countExistingFeeds()
        let isFreshInstall = existingFeedCount <= 1 // Allow for the feeds we just added
        print("🔍 Fresh install determination: existingFeedCount=\(existingFeedCount), isFreshInstall=\(isFreshInstall)")
        await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
    }
    
    /// Wait for Core Data to contain the fresh install data and then refresh UI
    @MainActor
    private func waitForCoreDataAndRefreshUI() {
        var attempts = 0
        let maxAttempts = 20 // 2 seconds max wait
        
        func checkAndRefresh() {
            attempts += 1
            
            // Check if Core Data now has feeds
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            
            do {
                let results = try context.fetch(request)
                if !results.isEmpty {
                    // Core Data has feeds now - load and refresh UI
                    print("🎯 Core Data now has \(results.count) feeds - refreshing UI")
                    self.loadFeedsFromCoreData()
                    
                                         // Multiple UI refresh triggers
                     self.objectWillChange.send()
                     print("🔄 Triggered UI refresh after Core Data confirmation")
                     
                     // Post notification for any views that might be listening
                     NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                     print("📢 Posted FreshInstallDataAvailable notification")
                     
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                         self.objectWillChange.send()
                         print("🔄 SECONDARY: Triggered delayed UI refresh after Core Data confirmation")
                     }
                     
                     // Single delayed notification to avoid excessive refreshes
                     DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                         NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                         print("📢 DELAYED: Final re-post for any late-appearing views")
                     }
                    
                    return // Success - exit the retry loop
                }
            } catch {
                print("❌ Failed to check Core Data during UI refresh wait: \(error)")
            }
            
            // If still no data and haven't exceeded max attempts, try again
            if attempts < maxAttempts {
                print("🔄 Core Data still empty (attempt \(attempts)/\(maxAttempts)) - waiting...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkAndRefresh()
                }
            } else {
                print("⚠️ Timeout waiting for Core Data to contain feeds - proceeding with UI refresh anyway")
                self.loadFeedsFromCoreData()
                self.objectWillChange.send()
            }
        }
        
        // Start the checking process
        checkAndRefresh()
    }
    
    /// Get existing feed URLs from Core Data to prevent duplicate processing
    private func getExistingFeedUrls() async -> Set<String> {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    request.propertiesToFetch = ["url"]
                    request.resultType = .dictionaryResultType
                    
                    let results = try context.fetch(request) as! [[String: Any]]
                    let urls = Set(results.compactMap { $0["url"] as? String })
                    continuation.resume(returning: urls)
                } catch {
                    print("❌ Failed to fetch existing feed URLs: \(error)")
                    continuation.resume(returning: Set())
                }
            }
        }
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
            // CRITICAL FIX: Determine fresh install status properly instead of hard-coding
            let existingFeedCount = await countExistingFeeds()
            let isFreshInstall = existingFeedCount == 0
            print("🔍 Fresh install determination in merge: existingFeedCount=\(existingFeedCount), isFreshInstall=\(isFreshInstall)")
            await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
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
        
        // Prevent multiple initializations
        guard !isLoading else {
            print("⚠️ CloudKit initialization already in progress, skipping duplicate call")
            return
        }
        
        // Start with Core Data load for immediate UI
        loadFeedsFromCoreData()
        print("📊 Loaded \(podcastFeeds.count) feeds from Core Data")
        
        // Single CloudKit sync in background
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
            
            // CRITICAL: Final UI refresh after all initialization is complete
            await MainActor.run {
                print("🔄 Final UI refresh after complete initialization...")
                self.loadFeedsFromCoreData()
                
                // Force UI update for any view controllers observing this environment object
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.objectWillChange.send()
                    print("🎯 FINAL: Triggered final UI refresh - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                }
            }
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
            
            // CRITICAL FIX: Get episode IDs directly from Core Data to ensure we get ALL episodes
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
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
            
            // Start artwork download tracking for refreshed feeds
            await MainActor.run {
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: feedsToRefresh.count)
            }
            
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
            // Complete artwork tracking immediately if no feeds need refreshing
            await MainActor.run {
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: 0)
            }
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
        try await withCheckedThrowingContinuation { continuation in
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
        
        // Notify user that deletion started
        await MainActor.run {
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Started", message: "Deleting downloaded episode '\(episode.title)'...")
        }
        
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
            
            // Notify user of successful deletion
            await MainActor.run {
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Successfully deleted download for '\(episode.title)'.")
            }
            
        } catch {
            print("❌ Failed to delete downloaded episode: \(error)")
            
            // Notify user of failed deletion
            await MainActor.run {
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to delete download for '\(episode.title)': \(error.localizedDescription)")
            }
            
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
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        print("🎯 DEBUG: updateLastPlayedEpisode called for: \(episode.title) in feed: \(episode.feedId)")
        
        // Update the lastPlayedEpisodes dictionary immediately on main thread
        self.lastPlayedEpisodes[episode.feedId] = episode.id
        self.saveLastPlayedEpisodes()
        
        print("🎯 DEBUG: lastPlayedEpisodes after update: \(self.lastPlayedEpisodes)")
        
        // Force UI update by triggering objectWillChange
        self.objectWillChange.send()
        
        print("🎯 Updated last played episode for feed \(episode.feedId): \(episode.title)")
        
        // Also update episode state in background
        Task {
            self.updateEpisodeState(episode.id, isPlayed: false) // Don't mark as played yet, just track
        }
    }
    
    /// Non-MainActor version for immediate updates from background threads
    nonisolated func updateLastPlayedEpisodeImmediate(_ episode: PodcastEpisode) {
        print("🎯 DEBUG: updateLastPlayedEpisodeImmediate called for: \(episode.title) in feed: \(episode.feedId)")
        
        // Update UserDefaults immediately (thread-safe)
        var currentDict = UserDefaults.standard.object(forKey: "LastPlayedEpisodes") as? [String: String] ?? [:]
        currentDict[episode.feedId] = episode.id
        UserDefaults.standard.set(currentDict, forKey: "LastPlayedEpisodes")
        
        print("🎯 DEBUG: Updated UserDefaults with lastPlayedEpisodes")
        
        // Update the main actor state asynchronously
        Task { @MainActor in
            self.lastPlayedEpisodes[episode.feedId] = episode.id
            self.objectWillChange.send()
            print("🎯 DEBUG: Updated MainActor state for feed \(episode.feedId): \(episode.title)")
        }
    }
    
    /// Save lastPlayedEpisodes to UserDefaults
    private func saveLastPlayedEpisodes() {
        UserDefaults.standard.set(lastPlayedEpisodes, forKey: "LastPlayedEpisodes")
    }
    
    /// Load lastPlayedEpisodes from UserDefaults
    private func loadLastPlayedEpisodes() {
        if let savedLastPlayed = UserDefaults.standard.object(forKey: "LastPlayedEpisodes") as? [String: String] {
            lastPlayedEpisodes = savedLastPlayed
        }
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
            // Check for new episodes when refreshing all feeds
            await checkForNewEpisodes()
            
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
        print("📡 PodcastViewModel - Before update:")
        if let existingFeed = podcastFeeds.first(where: { $0.id == feed.id }) {
            print("📡   Existing - Title: '\(existingFeed.title)', URL: '\(existingFeed.url)'")
        }
        print("📡   New - Title: '\(feed.title)', URL: '\(feed.url)'")
        
        // Update the feed in the array immediately for UI responsiveness
        if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
            podcastFeeds[index] = feed
            print("📡 Updated feed at index \(index)")
        } else {
            print("❌ Feed with ID \(feed.id) not found in podcastFeeds array")
            return
        }
        
        // Trigger immediate UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        
        // Save to Core Data
        saveFeedsToCoreData()
        
        // Save to CloudKit in background
        Task {
            do {
                try await cloudKitManager.savePodcastFeedToCloudKit(feed)
                print("☁️ Successfully saved podcast feed to CloudKit: \(feed.title)")
            } catch {
                print("❌ Failed to save podcast feed to CloudKit: \(error)")
                // Note: We don't revert CoreData changes on CloudKit failure
                // CloudKit sync will retry later
            }
        }
        
        print("📡 Updated podcast feed completed: \(feed.title)")
        
        // Verify the update
        if let verifyFeed = podcastFeeds.first(where: { $0.id == feed.id }) {
            print("📡 Verification - Title: '\(verifyFeed.title)', URL: '\(verifyFeed.url)'")
        }
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
                    self.progressObservations.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    return
                }
                
                guard let tempURL = tempURL else {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    self.progressObservations.removeValue(forKey: episode.id)
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
                    
                    // CRITICAL: Trigger CloudKit sync for the download state change
                    self.updateEpisodeState(episode.id, isDownloaded: true)
                    print("💾 Triggered CloudKit sync for downloaded episode: \(episode.title)")
                    
                    // Clear download progress and observation after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.downloadProgress.removeValue(forKey: episode.id)
                        self.progressObservations.removeValue(forKey: episode.id)
                    }
                    
                    print("📁 Episode downloaded successfully to: \(localURL.path)")
                    
                } catch {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    self.progressObservations.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    print("❌ Failed to save downloaded episode: \(error)")
                }
            }
        }
        
        // Observe download progress
        let observation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.downloadProgress[episode.id] = progress.fractionCompleted
                print("📥 Download progress for \(episode.title): \(Int(progress.fractionCompleted * 100))%")
            }
        }
        
        // Store observation to prevent deallocation
        progressObservations[episode.id] = observation
        
        downloadTask.resume()
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
                // CRITICAL: Clear in-memory arrays when no feeds found in Core Data
                DispatchQueue.main.async {
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.objectWillChange.send()
                    print("📡 ✅ MAIN THREAD: Cleared all in-memory podcast data due to empty Core Data")
                }
                return
            }
            
            let loadedFeeds = results.map { feedModel in
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
            
            // CRITICAL: Assign to @Published properties on main thread to trigger UI updates
            DispatchQueue.main.async {
                // Batch property updates to prevent multiple UI refreshes
                self.podcastFeeds = loadedFeeds
                self.podcastFeedOrder = loadedFeeds.map { $0.id }
                print("📡 ✅ MAIN THREAD: Updated podcastFeeds with \(loadedFeeds.count) feeds")
                print("📡 ✅ MAIN THREAD: Updated podcastFeedOrder with \(self.podcastFeedOrder.count) items")
                
                // Single UI refresh after all properties are updated
                self.objectWillChange.send()
                print("📡 ✅ MAIN THREAD: Triggered objectWillChange for UI refresh")
            }
            
            print("📡 Loaded \(loadedFeeds.count) podcast feeds from CoreData.")
            
            // Debug: Check if episodes exist in Core Data
            let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let allEpisodes = try context.fetch(episodeRequest)
                print("🔍 DEBUG: Found \(allEpisodes.count) total episodes in Core Data")
                
                // Group by feedId to see distribution
                let episodesByFeed = Dictionary(grouping: allEpisodes) { $0.feedId ?? "unknown" }
                for (feedId, episodes) in episodesByFeed {
                    if let feed = loadedFeeds.first(where: { $0.id == feedId }) {
                        print("🔍 DEBUG: Feed '\(feed.title)' has \(episodes.count) episodes in Core Data")
                    } else {
                        print("🔍 DEBUG: Unknown feedId '\(feedId)' has \(episodes.count) episodes")
                    }
                }
            } catch {
                print("❌ Failed to count episodes: \(error)")
            }
            
            // Initialize episode tracking for newly loaded feeds
            Task {
                await initializeEpisodeTracking()
            }
            
            // Load episodes for the first feed if available
            if let firstFeed = loadedFeeds.first {
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
    

    
    /// Clear podcast feeds from UI immediately for instant user feedback
    func clearPodcastFeedsFromUI() {
        // Must be called on main queue since it updates @Published properties
        DispatchQueue.main.async {
            self.podcastFeeds.removeAll()
            self.podcastFeedOrder.removeAll()
            self.currentEpisodes.removeAll()
            self.episodeCounts = (all: 0, favorites: 0, downloads: 0)
            self.objectWillChange.send()
            print("📡 ✅ Immediately cleared podcast feeds from UI")
            print("🔍 DEBUG: After immediate clearing - podcastFeeds count: \(self.podcastFeeds.count)")
            print("🔍 DEBUG: After immediate clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
            
            // Force UI refresh by triggering objectWillChange again with slight delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.objectWillChange.send()
                print("📡 ✅ Forced additional UI refresh after clearing")
            }
        }
    }
    
    /// Clear all podcast data from Core Data and CloudKit
    func clearPodcastCoreData(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            var allSuccess = true
            var lastError: Error?
            
            // First, get the feed IDs before deletion for CloudKit cleanup
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            var feedIdsToDelete: [String] = []
            
            do {
                let feeds = try context.fetch(feedFetchRequest)
                feedIdsToDelete = feeds.compactMap { $0.id }
                print("🗑️ Found \(feedIdsToDelete.count) feeds to delete from CloudKit")
                
                // Debug: List all feeds that will be deleted
                for feed in feeds {
                    if let feedId = feed.id, let title = feed.title {
                        print("🗑️ Will delete feed: '\(title)' (ID: \(feedId))")
                    }
                }
                
                // Also check in-memory feeds for comparison
                print("🔍 DEBUG: In-memory feeds at deletion time: \(self.podcastFeeds.count)")
                for feed in self.podcastFeeds {
                    print("🔍 DEBUG: In-memory feed: '\(feed.title)' (ID: \(feed.id))")
                }
            } catch {
                print("❌ Error fetching feeds for CloudKit deletion: \(error.localizedDescription)")
                // Continue with local deletion even if we can't get feed IDs
            }
            
            // Delete from CloudKit first (for each feed) with retry mechanism for race conditions
            for feedId in feedIdsToDelete {
                do {
                    // Add a small delay to handle CloudKit eventual consistency
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    try await cloudKitManager.deletePodcastFeedFromCloudKit(feedId)
                    print("☁️ Successfully deleted feed \(feedId) from CloudKit")
                } catch {
                    print("❌ Failed to delete feed \(feedId) from CloudKit: \(error)")
                    
                    // Check if it's a "not found" error (which might be okay - feed might not have been synced to CloudKit yet)
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        print("⚠️ Feed \(feedId) not found in CloudKit - this may be expected for recently added feeds")
                        // Don't mark as failure for "not found" errors since the feed doesn't exist anyway
                    } else {
                        allSuccess = false
                        lastError = error
                    }
                    // Continue deleting other feeds even if one fails
                }
            }
            
            // Now delete from local Core Data
            let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            privateMOC.parent = CoreDataStack.shared.persistentContainer.viewContext
            privateMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            
            await withCheckedContinuation { continuation in
                privateMOC.perform {
                    do {
                        // Fetch and delete episodes first
                        let episodeFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        let episodes = try privateMOC.fetch(episodeFetchRequest)
                        for episode in episodes {
                            privateMOC.delete(episode)
                        }
                        
                        // Fetch and delete feeds
                        let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                        let feeds = try privateMOC.fetch(feedFetchRequest)
                        for feed in feeds {
                            privateMOC.delete(feed)
                        }
                        
                        // Save private context first
                        try privateMOC.save()
                        
                        continuation.resume()
                    } catch {
                        print("❌ Error deleting podcast data from CoreData: \(error.localizedDescription)")
                        allSuccess = false
                        lastError = error
                        continuation.resume()
                    }
                }
            }
            
            // Then save main context and clear in-memory data
            DispatchQueue.main.async {
                do {
                    try CoreDataStack.shared.persistentContainer.viewContext.save()
                    
                    // Ensure in-memory data is cleared after successful Core Data deletion
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.episodeCounts = (all: 0, favorites: 0, downloads: 0)
                    self.objectWillChange.send()
                    print("📡 ✅ Cleared in-memory data after Core Data deletion")
                    print("🔍 DEBUG: After clearing - podcastFeeds count: \(self.podcastFeeds.count)")
                    print("🔍 DEBUG: After clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
                    
                    if allSuccess {
                        print("🎯 ✅ Successfully deleted all podcast data from both CloudKit and Core Data")
                        NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "All podcast data has been successfully deleted.")
                    } else {
                        print("⚠️ Partial success: Local deletion completed, but some CloudKit deletions failed")
                        NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Podcast data deletion completed with some warnings.")
                    }
                    
                    completion(allSuccess, lastError)
                } catch {
                    print("❌ Error saving main context after podcast deletion: \(error.localizedDescription)")
                    NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to complete podcast data deletion: \(error.localizedDescription)")
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
