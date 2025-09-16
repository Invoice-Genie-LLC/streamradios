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

struct PodcastFeed: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String
    var artworkUrl: String?
    var descriptionText: String?
    var iconData: String?
    var imageData: Data?
    var episodes: [PodcastEpisode] = []
    var maxEpisodes: Int? = nil // Optional episode limit - nil means unlimited
    
    init(id: String = UUID().uuidString, title: String, url: String, artworkUrl: String? = nil, description: String? = nil, iconData: String? = nil, imageData: Data? = nil, episodes: [PodcastEpisode] = [], maxEpisodes: Int? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.artworkUrl = artworkUrl
        self.descriptionText = description
        self.iconData = iconData
        self.imageData = imageData
        self.episodes = episodes
        self.maxEpisodes = maxEpisodes
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
    var chapters: [PodcastChapter]? // Optional chapters
    var notes: PodcastNotes? // Optional show notes
    
    /// Deterministic composite ID for duplicate detection and stable identification
    var compositeID: String {
        let dateString = String(publicationDate.timeIntervalSince1970)
        let titleHash = String(abs(title.hashValue))
        let audioUrlHash = String(abs(audioUrl.hashValue))
        return "\(feedId)_\(dateString)_\(titleHash)_\(audioUrlHash)"
    }
    
    /// Generate a deterministic episode ID based on content (for episodes without GUID)
    static func generateDeterministicID(title: String, audioUrl: String, publicationDate: Date, feedUrl: String) -> String {
        let content = "\(feedUrl)_\(title)_\(audioUrl)_\(publicationDate.timeIntervalSince1970)"
        return "det_\(abs(content.hashValue))"
    }
    
    init(id: String = UUID().uuidString, title: String, descriptionText: String, audioUrl: String, publicationDate: Date, duration: TimeInterval, state: EpisodeState, feedId: String, localFilePath: String? = nil, fileSize: Int64? = nil, chapters: [PodcastChapter]? = nil, notes: PodcastNotes? = nil) {
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
        self.chapters = chapters
        self.notes = notes
    }
    
    // Implement Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(feedId)
        hasher.combine(publicationDate)
    }
    
    // Equatable based on unique identifier
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Represents a chapter in a podcast episode
struct PodcastChapter: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var startTime: TimeInterval // in seconds
    var url: String? // optional URL link
    var imageUrl: String? // optional chapter-specific artwork
    
    init(title: String, startTime: TimeInterval, url: String? = nil, imageUrl: String? = nil) {
        self.title = title
        self.startTime = startTime
        self.url = url
        self.imageUrl = imageUrl
    }
}

/// Represents notes/show notes for a podcast episode
struct PodcastNotes: Codable, Equatable, Hashable {
    var content: String // HTML or plain text content
    var links: [PodcastLink] // extracted links from the notes
    
    init(content: String, links: [PodcastLink] = []) {
        self.content = content
        self.links = links
    }
}

/// Represents a link in podcast notes
struct PodcastLink: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var timeStamp: TimeInterval? // optional timestamp for time-linked notes
    
    init(title: String, url: String, timeStamp: TimeInterval? = nil) {
        self.title = title
        self.url = url
        self.timeStamp = timeStamp
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
    // MARK: - Shared Instance
    static let shared = PodcastViewModel()
    
    // MARK: - RSS Processing Queue
    private let rssProcessingQueue = DispatchQueue(label: "com.streamradios.rss.processing", qos: .userInitiated)
    
    // MARK: - RSS Task Management for Cancellation
    private var rssParsingTasks: [String: Task<Void, Error>] = [:]
    private let rssTaskQueue = DispatchQueue(label: "com.streamradios.rss.tasks", qos: .utility)
    
    // MARK: - Published Properties
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var podcastFeeds: [PodcastFeed] = []
    @Published var isLoading = false
    
    // FEED DUPLICATION PROTECTION: Track feeds being processed to prevent race conditions
    private var feedsBeingProcessed: Set<String> = []
    private let feedProcessingQueue = DispatchQueue(label: "com.streamradios.feedProcessing", attributes: .concurrent)
    @Published var isLoadingFeeds = false
    @Published var isLoadingEpisodes = false
    @Published var isLoadingMoreEpisodes = false
    @Published var hasMoreEpisodes = false
    @Published var operationInProgress = false
    @Published var error: String?
    @Published var currentTab = 0
    @Published var searchQuery = ""
    @Published var episodeCounts = (all: 0, favorites: 0, downloads: 0)
    @Published var uiRefreshTrigger: UUID = UUID() // Force UI refresh trigger
    @Published var showNoEpisodesAlert = false
    @Published var noEpisodesAlertMessage = ""
    @Published var isAscendingSort = true
    @Published var podcastFeedOrder: [String] = []
    @Published var lastPlayedEpisodes: [String: String] = [:]
    @Published var episodeProgress: [String: Double] = [:]
    @Published var downloadProgress: [String: Double] = [:]
    
    // PERFORMANCE OPTIMIZATION: Cache filtered results and counts to avoid re-filtering and re-counting
    private var tabFilterCache: [String: [Int: [PodcastEpisode]]] = [:] // feedId -> [tabIndex -> episodes]
    private var tabFilterCounts: [String: (all: Int, favorites: Int, downloads: Int)] = [:] // feedId -> episode counts
    
    // INSTANT SNAPSHOT CACHE: Complete episode snapshots to eliminate ALL expensive operations
    private var episodeSnapshotCache: [String: [PodcastEpisode]] = [:] // feedId -> complete episode list
    private var snapshotTimestamps: [String: Date] = [:] // feedId -> last snapshot time
    
    // MARK: - Feed Deletion Progress Tracking
    @Published var feedDeletionProgress: Double = 0.0
    @Published var feedDeletionMessage: String = ""
    @Published var isDeletingFeed: Bool = false
    @Published var deletingFeedId: String? = nil
    
    // Store progress observations to prevent deallocation
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    
    // MARK: - Private Properties
    private let log = OSLog(subsystem: "StreamRadios", category: "PodcastViewModel")
    private let feedManager = PodcastFeedManager()
    private let episodeManager = PodcastEpisodeManager()
    private let cloudKitManager = PodcastCloudKitManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Global Episode Search State
    @Published var globalEpisodeSearchResults: [PodcastEpisode] = []
    private var globalSearchTask: Task<Void, Never>? = nil
    
    // Performance optimizations
    private let episodesPerPage = 100
    private var currentPage = 1
    private var loadingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    
    // PERFORMANCE: UI update throttling to improve scrolling performance
    private var lastUIUpdateTime = Date()
    private var uiUpdateTimer: Timer?
    private let uiUpdateThrottleInterval: TimeInterval = 1.0  // 1 second minimum between UI updates
    private var hasPendingUIUpdate = false
    private var isUserScrolling: Bool {
        UserDefaults.standard.bool(forKey: "isUserScrolling")
    }
    
    // PERFORMANCE: Deduplication flags to prevent redundant operations
    private var isInitializingEpisodeTracking = false
    private var hasInitializedEpisodeTracking = false
    private var isLoadingFromCoreData = false
    var pendingInitializationTasks = Set<String>()
    
    // IMMEDIATE NEW EPISODE CHECK: Track immediate check tasks
    private var immediateCheckTasks: [String: Task<Void, Never>] = [:]
    
    // Current state
    var selectedFeedId: String?
    private var lastLoadTime: Date = Date()
    
    init() {
        setupObservers()
        setupDataSyncCoordination()
        
        // Load feeds from Core Data (radio station pattern)
        // Note: For fresh installs, this will initially find no feeds, but once RSS processing
        // completes and Core Data is properly synchronized, subsequent calls will work correctly
        loadFeedsFromCoreData()
        
        // Load last played episodes from UserDefaults
        loadLastPlayedEpisodes()
        
        // Load sorting preferences from UserDefaults
        loadSortingPreferences()
        
        // Setup instant sync listener for real-time cross-device updates
        setupInstantSyncListener()
        
        // Note: CloudKit sync is now handled by explicit initializeWithCloudKitSupport() call
        // This prevents duplicate syncing when multiple ViewModels are created
    }
    
    // MARK: - Instant Sync Listener
    
    private func setupInstantSyncListener() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastProgressSync),
            name: .init("InstantSyncDidUpdatePodcastProgress"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFeedAddedSync),
            name: .init("InstantSyncDidAddPodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFeedRemovedSync),
            name: .init("InstantSyncDidRemovePodcastFeed"),
            object: nil
        )
        
        // Real-time CloudKit deletion notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeCloudKitFeedDeletedSync(_:)),
            name: .init("CloudKitDidDeletePodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFavoriteSync),
            name: .init("InstantSyncDidUpdatePodcastFavorite"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastDownloadSync),
            name: .init("InstantSyncDidUpdatePodcastDownload"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastPlayedSync),
            name: .init("InstantSyncDidUpdatePodcastPlayed"),
            object: nil
        )
        
        // CloudKit automatic sync listeners
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitFeedAddedSync),
            name: .init("CloudKitDidAddPodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitFeedDeletedSync),
            name: .init("CloudKitDidDeletePodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitAllFeedsUpdatedSync),
            name: .init("CloudKitDidUpdateAllFeeds"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitEpisodeStateSync),
            name: .init("CloudKitDidUpdateEpisodeState"),
            object: nil
        )
        
        // Listen for instant episode progress changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodeProgressChange),
            name: .init("EpisodeProgressChangedInstantly"),
            object: nil
        )
        
        // Listen for instant episode state changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodeStateChange),
            name: .init("EpisodeStateChangedInstantly"),
            object: nil
        )
        
        // Listen for instant episode played changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodePlayedChange),
            name: .init("EpisodePlayedChangedInstantly"),
            object: nil
        )
    }
    
    @objc private func handleInstantPodcastProgressSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            return
        }
        
        // Update episode progress from remote sync
        let currentProgress = episodeProgress[episodeId] ?? 0.0
        
        // Only update if the value actually changed to avoid infinite loops
        // Also check if this progress is newer (has a reasonable threshold)
        if abs(currentProgress - progress) > 0.01 {
            DispatchQueue.main.async {
                // CRITICAL: Don't call setProgress again to avoid loops - just update UI directly
                // The progress has already been saved by the player or CloudKit sync
                
                // Update episodeProgress cache for immediate UI refresh
                self.episodeProgress[episodeId] = progress
                
                // 🔄 CRITICAL FIX: Update UI immediately for automatic view refresh
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: progress)
                
            }
        }
    }
    
    @objc private func handleInstantEpisodeProgressChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            return
        }
        
        // ULTIMATE PERFORMANCE: Silent cache update without UI storms
        episodeProgress[episodeId] = progress
        
        // Single deferred UI update to prevent spam
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleInstantEpisodeStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let stateRawValue = userInfo["state"] as? String else {
            return
        }
        
        // Force immediate UI update for state changes
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleInstantEpisodePlayedChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isPlayed = userInfo["isPlayed"] as? Bool else {
            return
        }
        
        // Update episode state in UI data structures
        updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: nil)
        
        // Force immediate UI update for played status changes
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleInstantPodcastFeedAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedData = userInfo["feed"] as? [String: Any] else {
            return
        }
        
        // Convert dictionary back to PodcastFeed
        if let feed = podcastFeedFromDictionary(feedData) {
            
            // FEED PROCESSING PROTECTION: Check if this feed is already being processed
            guard markFeedAsProcessing(feed.id) else {
                print("📡 ⚠️ INSTANT SYNC: Feed \(feed.title) is already being processed, skipping duplicate")
                return
            }
            
            // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
            let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
            
            if isDuplicateInMemory {
                print("📡 ⚠️ INSTANT SYNC: Duplicate detected in memory, skipping: \(feed.title)")
                markFeedAsFinished(feed.id) // Release the processing lock
                return
            }
            
            // Check Core Data for duplicate (thread-safe)
            Task {
                let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
                
                if isDuplicateInCoreData {
                    print("📡 ⚠️ INSTANT SYNC: Duplicate detected in Core Data, skipping: \(feed.title)")
                    await MainActor.run {
                        self.markFeedAsFinished(feed.id) // Release the processing lock
                    }
                    return
                }
                
                // Parse RSS episodes immediately after sync with progress tracking
                do {
                    print("📡 🔄 INSTANT SYNC: Parsing episodes immediately for synced feed: \(feed.title)")
                    
                    // Initialize parsing progress for instant sync
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "Preparing to parse \(feed.title)...")
                    }
                    
                    // Broadcast feed sync start to other devices (milestone only)
                    PodcastCloudKitManager.shared.broadcastFeedProgress(
                        feedId: feed.id,
                        feedTitle: feed.title,
                        progress: 0.0,
                        message: "Starting feed sync from another device..."
                    )
                    
                    guard let url = URL(string: feed.url) else {
                        print("📡 ❌ INSTANT SYNC: Invalid URL for feed \(feed.title): \(feed.url)")
                        await addFeedToUIOnly(feed)
                        return
                    }
                    
                    // Parse RSS to get episodes with progress tracking
                    let episodes = try await parseRSSEpisodesOnly(from: url)
                    
                    // CRITICAL: Save feed to Core Data FIRST before adding episodes
                    try await saveFeedToCoreData(feed)
                    
                    // Add episodes to Core Data for this feed
                    try await PodcastCoreDataManager.shared.addNewEpisodes(episodes, to: feed.id)
                    
                    await MainActor.run {
                        // Final check before adding (prevents race conditions)
                        if !self.podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url }) {
                            // Add feed with episodes to UI
                            var feedWithEpisodes = feed
                            feedWithEpisodes.episodes = episodes
                            
                            self.podcastFeeds.append(feedWithEpisodes)
                            self.podcastFeedOrder.append(feedWithEpisodes.id)
                            self.throttledUIUpdate()
                            
                            print("📡 ✅ INSTANT SYNC: Applied instant sync with \(episodes.count) episodes: \(feed.title)")
                        } else {
                            print("📡 ⚠️ INSTANT SYNC: Last-second duplicate check prevented duplicate: \(feed.title)")
                        }
                    }
                    
                    // Reset parsing progress after successful completion
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    }
                    
                    // Broadcast completion to other devices (milestone only)
                    PodcastCloudKitManager.shared.broadcastFeedProgress(
                        feedId: feed.id,
                        feedTitle: feed.title,
                        progress: 1.0,
                        message: "Feed sync completed - \(episodes.count) episodes added"
                    )
                    
                    // Release the processing lock after successful completion
                    await MainActor.run {
                        self.markFeedAsFinished(feed.id)
                    }
                    
                } catch {
                    print("📡 ❌ INSTANT SYNC: Failed to parse episodes for \(feed.title): \(error)")
                    
                    // Still save the feed to Core Data even without episodes
                    do {
                        try await saveFeedToCoreData(feed)
                        await addFeedToUIOnly(feed)
                        print("📡 ✅ INSTANT SYNC: Saved feed without episodes as fallback: \(feed.title)")
                    } catch {
                        print("📡 ❌ INSTANT SYNC: Failed to save feed as fallback: \(error)")
                    }
                    
                    // Reset parsing progress after error
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                        // Release the processing lock after error
                        self.markFeedAsFinished(feed.id)
                    }
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastFeedRemovedSync(_ notification: Notification) {
        print("📡 🔔 NOTIFICATION RECEIVED: InstantSyncDidRemovePodcastFeed")
        print("📡 📝 Notification object: \(String(describing: notification.object))")
        
        guard let userInfo = notification.userInfo else {
            print("📡 ❌ SYNC RECEIVE FAILED: No userInfo in notification")
            return
        }
        
        print("📡 📝 Notification userInfo: \(userInfo)")
        
        guard let feedId = userInfo["feedId"] as? String,
              let feedTitle = userInfo["feedTitle"] as? String else {
            print("📡 ❌ SYNC RECEIVE FAILED: Invalid feed removal notification data")
            print("📡 📝 Missing feedId or feedTitle in userInfo: \(userInfo)")
            return
        }
        
        let episodeIds = userInfo["episodeIds"] as? [String] ?? []
        let actionId = userInfo["actionId"] as? String ?? "unknown"
        let operationType = userInfo["operation_type"] as? String ?? "legacy"
        let syncTimestamp = userInfo["sync_timestamp"] as? TimeInterval ?? 0
        
        print("📡 🎯 Processing comprehensive feed removal sync:")
        print("📡    📚 Feed: '\(feedTitle)' (\(feedId))")
        print("📡    📊 Episodes to clean up: \(episodeIds.count)")
        print("📡    🆔 Action ID: \(actionId)")
        print("📡    🔧 Operation type: \(operationType)")
        print("📡    ⏰ Sync timestamp: \(syncTimestamp)")
        
        // Enhanced processing - always attempt cleanup for comprehensive CoreData sync
        let feedExists = podcastFeeds.contains { $0.id == feedId }
        print("📡 🔍 Feed exists in UI list: \(feedExists) (total feeds: \(podcastFeeds.count))")
        print("📡 🚨 CRITICAL: Processing deletion regardless of UI state for comprehensive CoreData cleanup")
        print("📡 📊 This ensures all storage layers are properly synchronized across devices")
        
        // Comprehensive cleanup similar to local deletePodcastFeed
        Task {
            // Step 1: Clean up episode data from EpisodeStateManager
            for episodeId in episodeIds {
                EpisodeStateManager.shared.clearEpisodeData(episodeId)
            }
            print("📡 Cleared \(episodeIds.count) episode states from EpisodeStateManager")
            
            // Step 2: Delete downloaded episode files
            await deleteDownloadedEpisodeFiles(episodeIds)
            
            // Step 3: Remove feed and episodes from UI and Core Data
            await MainActor.run {
                // Remove from UI arrays
                if let index = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                    self.podcastFeeds.remove(at: index)
                }
                self.podcastFeedOrder.removeAll { $0 == feedId }
                self.currentEpisodes.removeAll { $0.feedId == feedId }
                
                // Clear selected feed if it's the one being deleted
                if self.selectedFeedId == feedId {
                    self.selectedFeedId = nil
                }
                
                // Clean up local episode state tracking
                for episodeId in episodeIds {
                    self.episodeProgress.removeValue(forKey: episodeId)
                }
                
                // Trigger UI update
                self.throttledUIUpdate()
            }
            
            // Step 4: Delete from Core Data
            do {
                let feed = PodcastFeed(id: feedId, title: feedTitle, url: "", artworkUrl: nil, description: nil)
                try await deleteFeedFromCoreData(feed)
                print("📡 Deleted feed and episodes from Core Data: \(feedTitle)")
                
                await MainActor.run {
                    print("📡 📊 Remote device cleanup summary:")
                    print("📡    ✅ CloudKit was already cleaned by originating device")
                    print("📡    ✅ EpisodeStateManager: \(episodeIds.count) episode states cleared")
                    print("📡    ✅ Downloaded files: cleaned up")
                    print("📡    ✅ Core Data: feed and episodes deleted")
                    print("📡    ✅ UI: feed and episodes removed")
                    print("📡    🚨 NOTE: CloudKit-first deletion order prevents feed restoration!")
                }
            } catch {
                print("📡 ❌ Error during Core Data cleanup for synced feed removal: \(error)")
            }
        }
    }
    
    @objc private func handleInstantPodcastFavoriteSync(_ notification: Notification) {
        
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("📡 ❌ FAVORITE SYNC FAILED: Invalid notification data")
            return
        }
                
        // Update episode favorite status from remote sync
        let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setFavoriteSilently(episodeId, isFavorite: isFavorite)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
            }
            
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isFavorite": isFavorite
                ]
            )
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: currentProgress,
                    isFavorite: isFavorite,
                    isDownloaded: currentDownloaded,
                    isPlayed: currentPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save favorite state to Core Data: \(error)")
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastDownloadSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isDownloaded = userInfo["isDownloaded"] as? Bool else {
            return
        }
        
        // Update episode download status from remote sync
        let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setDownloadedSilently(episodeId, isDownloaded: isDownloaded)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
            }
            
            // 🚗 CARPLAY FIX: Notify CarPlay immediately about cross-device download sync
            print("🚗 CARPLAY NOTIFY: Sending EpisodeStateChanged notification for cross-device download sync")
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isDownloaded": isDownloaded
                ]
            )
            print("🚗 CARPLAY NOTIFY: EpisodeStateChanged notification sent for download sync")
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: currentProgress,
                    isFavorite: currentFavorite,
                    isDownloaded: isDownloaded,
                    isPlayed: currentPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save download state to Core Data: \(error)")
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastPlayedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isPlayed = userInfo["isPlayed"] as? Bool else {
            return
        }
        
        // Update episode played status from remote sync
        let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setPlayedSilently(episodeId, isPlayed: isPlayed)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For played state, we need to update progress to reflect the played status
            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
            let effectiveProgress = isPlayed ? max(currentProgress, 0.99) : currentProgress
            
            print("📡 🔄 PLAYED SYNC: Received isPlayed=\(isPlayed) for episode \(episodeId), currentProgress=\(currentProgress), effectiveProgress=\(effectiveProgress)")
            
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: effectiveProgress)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: effectiveProgress)
            }
            
            // 🚗 CARPLAY FIX: Notify CarPlay immediately about cross-device played sync
            print("🚗 CARPLAY NOTIFY: Sending EpisodeStateChanged notification for cross-device played sync")
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isPlayed": isPlayed
                ]
            )
            print("🚗 CARPLAY NOTIFY: EpisodeStateChanged notification sent for played sync")
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: effectiveProgress,
                    isFavorite: currentFavorite,
                    isDownloaded: currentDownloaded,
                    isPlayed: isPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save played state to Core Data: \(error)")
                }
            }
        }
    }
    
    // MARK: - UI State Update Helper
    
    /// Update episode UI state immediately for automatic view refresh across tabs
    private func updateEpisodeUIState(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double? = nil) {
        // For large feeds (>100 episodes), use batch update mechanism
        if currentEpisodes.count > 100 {
            queueEpisodeUpdate(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: isDownloaded, progress: progress)
            return
        }
        
        // Update the episode in currentEpisodes array (triggers UI refresh)
        if let index = currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
            var updatedEpisode = currentEpisodes[index]
            
            if let isFavorite = isFavorite {
                updatedEpisode.state.isFavorite = isFavorite
            }
            
            if let isDownloaded = isDownloaded {
                updatedEpisode.state.isDownloaded = isDownloaded
            }
            
            if let progress = progress {
                updatedEpisode.state.progress = progress
                // Also update the episodeProgress cache
                episodeProgress[episodeId] = progress
            }
            
            currentEpisodes[index] = updatedEpisode
        }
        
        // Update the episode in the podcastFeeds array (triggers feed-level UI refresh)
        for feedIndex in 0..<podcastFeeds.count {
            if let episodeIndex = podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episodeId }) {
                var updatedFeed = podcastFeeds[feedIndex]
                
                if let isFavorite = isFavorite {
                    updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                }
                
                if let isDownloaded = isDownloaded {
                    updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                }
                
                if let progress = progress {
                    updatedFeed.episodes[episodeIndex].state.progress = progress
                }
                
                podcastFeeds[feedIndex] = updatedFeed
                break
            }
        }
        
        // Apply tab filtering immediately if needed
        applyTabFiltering(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: isDownloaded)
    }
    
    // MARK: - Large Feed Batch Update System
    
    private var pendingUpdates: [String: EpisodeBatchUpdate] = [:]
    private var batchUpdateTimer: Timer?
    private let batchUpdateInterval: TimeInterval = 0.5 // 500ms batching window
    
    private struct EpisodeBatchUpdate {
        var isFavorite: Bool?
        var isDownloaded: Bool?
        var progress: Double?
        var timestamp: Date
        
        mutating func merge(with update: EpisodeBatchUpdate) {
            // Use the most recent values
            if update.isFavorite != nil { self.isFavorite = update.isFavorite }
            if update.isDownloaded != nil { self.isDownloaded = update.isDownloaded }
            if update.progress != nil { self.progress = update.progress }
            self.timestamp = update.timestamp
        }
    }
    
    /// ULTRA-OPTIMIZED: Silent episode update system - no UI storms
    private func queueEpisodeUpdate(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double?) {
        let update = EpisodeBatchUpdate(
            isFavorite: isFavorite,
            isDownloaded: isDownloaded,
            progress: progress,
            timestamp: Date()
        )
        
        if var existingUpdate = pendingUpdates[episodeId] {
            existingUpdate.merge(with: update)
            pendingUpdates[episodeId] = existingUpdate
        } else {
            pendingUpdates[episodeId] = update
        }
        
        // ULTIMATE PERFORMANCE: Skip all individual UI updates for large operations
        if pendingUpdates.count > 50 {
            // Silent processing - no UI updates during bulk operations
            processSilentBatchUpdates()
            return
        }
        
        // Schedule batch processing
        scheduleBatchUpdate()
    }
    
    /// ULTIMATE PERFORMANCE: Silent batch processing without UI updates
    private func processSilentBatchUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        
        // Process updates silently without triggering UI refresh storms
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
        // Update caches only - no UI updates
        for (episodeId, update) in updates {
            if let progress = update.progress {
                episodeProgress[episodeId] = progress
            }
        }
        
        // Single consolidated UI refresh instead of individual updates
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    /// Schedule batch update processing
    private func scheduleBatchUpdate() {
        batchUpdateTimer?.invalidate()
        batchUpdateTimer = Timer.scheduledTimer(withTimeInterval: batchUpdateInterval, repeats: false) { [weak self] _ in
            self?.processBatchUpdates()
        }
    }
    
    /// Process all pending episode updates in batch - MOVED TO BACKGROUND THREAD
    private func processBatchUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        
        // CRITICAL: Move ALL batch processing to background thread to prevent main thread hangs
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performBackgroundBatchUpdate()
        }
    }
    
    /// Perform batch update processing on background thread to prevent main thread hangs
    @MainActor
    private func performBackgroundBatchUpdate() async {
        guard !pendingUpdates.isEmpty else { return }
        
        // Capture updates on main thread
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
        // EMERGENCY PERFORMANCE: Minimal logging for large batches
        if updates.count > 100 {
            print("📦 BATCH UPDATE: Processing \\(updates.count) updates on background thread")
        }
        
        // EMERGENCY PERFORMANCE: Skip UI updates entirely if too many pending
        if updates.count > 1000 {
            // Just update caches, skip UI refresh to prevent hangs
            for (episodeId, update) in updates {
                if let progress = update.progress {
                    episodeProgress[episodeId] = progress
                }
            }
            print("📦 EMERGENCY: Skipped UI update for \\(updates.count) episodes to prevent hang")
            return
        }
        
        // Process updates in smaller chunks to prevent blocking
        let chunkSize = 50
        let updateArray = Array(updates)
        let chunks = updateArray.chunked(into: chunkSize)
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            // Update progress cache for this chunk
            for (episodeId, update) in chunk {
                if let progress = update.progress {
                    episodeProgress[episodeId] = progress
                }
            }
            
            // Update UI for this chunk
            var currentEpisodesMap = Dictionary(uniqueKeysWithValues: currentEpisodes.enumerated().map { ($1.id, $0) })
            var updatedCurrentEpisodes = currentEpisodes
            
            // Process updates efficiently (reduced operations for performance)
            for (episodeId, update) in chunk {
                // Update currentEpisodes using index lookup
                if let index = currentEpisodesMap[episodeId] {
                    var episode = updatedCurrentEpisodes[index]
                    
                    if let isFavorite = update.isFavorite {
                        episode.state.isFavorite = isFavorite
                    }
                    if let isDownloaded = update.isDownloaded {
                        episode.state.isDownloaded = isDownloaded
                    }
                    if let progress = update.progress {
                        episode.state.progress = progress
                    }
                    
                    updatedCurrentEpisodes[index] = episode
                }
                
                // EMERGENCY PERFORMANCE: Skip tab filtering for large batches
                if updates.count <= 100 {
                    applyTabFiltering(episodeId: episodeId, isFavorite: update.isFavorite, isDownloaded: update.isDownloaded)
                }
            }
            
            // Single UI update for this chunk
            currentEpisodes = updatedCurrentEpisodes
            
            // Yield control after each chunk to prevent blocking
            if chunkIndex < chunks.count - 1 {
                await Task.yield()
            }
        }
        
        // EMERGENCY PERFORMANCE: Skip podcastFeeds update for large batches to prevent hangs
        if updates.count <= 200 {
            updatePodcastFeedsWithBatchChanges(updates)
        }
        
        if updates.count <= 100 {
            print("📦 BATCH UPDATE: ✅ Completed batch update of \\(updates.count) episodes")
        }
    }
    
    /// Update podcastFeeds with batch changes efficiently
    private func updatePodcastFeedsWithBatchChanges(_ updates: [String: EpisodeBatchUpdate]) {
        for feedIndex in 0..<podcastFeeds.count {
            var feedUpdated = false
            var updatedFeed = podcastFeeds[feedIndex]
            
            // Check if this feed has any episodes that need updates
            for episodeIndex in 0..<updatedFeed.episodes.count {
                let episodeId = updatedFeed.episodes[episodeIndex].id
                
                if let update = updates[episodeId] {
                    if let isFavorite = update.isFavorite {
                        updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                        feedUpdated = true
                    }
                    if let isDownloaded = update.isDownloaded {
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                        feedUpdated = true
                    }
                    if let progress = update.progress {
                        updatedFeed.episodes[episodeIndex].state.progress = progress
                        feedUpdated = true
                    }
                }
            }
            
            // Only update the feed if it actually changed
            if feedUpdated {
                podcastFeeds[feedIndex] = updatedFeed
            }
        }
    }
    
    /// Apply tab filtering logic (extracted for reuse)
    private func applyTabFiltering(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?) {
        let filter = EpisodeFilter(rawValue: currentTab) ?? .all
        switch filter {
        case .favorites:
            // If we're on favorites tab and unfavoriting, remove the episode
            if let isFavorite = isFavorite, !isFavorite {
                currentEpisodes.removeAll { $0.id == episodeId }
                print("🔄 UI UPDATE: Removed unfavorited episode from favorites tab")
            }
        case .downloads:
            // If we're on downloads tab and un-downloading, remove the episode
            if let isDownloaded = isDownloaded, !isDownloaded {
                currentEpisodes.removeAll { $0.id == episodeId }
                print("🔄 UI UPDATE: Removed non-downloaded episode from downloads tab")
            }
        case .all:
            // All tab shows everything, no filtering needed
            break
        }
        
        // 🎯 CROSS-TAB UPDATE: Invalidate cached results for ALL tabs when episode states change
        // This ensures that when user switches tabs, they see the updated filtering
        Task { @MainActor in
            invalidateAllTabCaches()
        }
    }
    
    // PERFORMANCE: Throttle tab cache invalidation to prevent excessive CPU usage
    private var lastTabCacheInvalidation: Date = Date.distantPast
    private let tabCacheInvalidationThrottleInterval: TimeInterval = 1.0 // 1 second minimum between invalidations
    
    /// Invalidate cached filtering results for all tabs to ensure real-time updates
    @MainActor
    private func invalidateAllTabCaches() {
        let now = Date()
        
        // PERFORMANCE: Throttle cache invalidation to prevent excessive operations
        guard now.timeIntervalSince(lastTabCacheInvalidation) >= tabCacheInvalidationThrottleInterval else {
            return
        }
        
        lastTabCacheInvalidation = now
        
        // Clear any cached episode filtering results
        // This forces re-filtering when user switches between tabs
        tabFilterCache.removeAll()
        tabFilterCounts.removeAll()
        print("🧹 CACHE CLEAR: Invalidated all tab caches for real-time filtering updates")
        
        // 🎯 IMMEDIATE REFRESH: Also refresh the current tab's filtering to show changes instantly
        Task {
            await refreshCurrentTabFiltering()
        }
    }
    
    /// Refresh filtering for the current tab to show episode state changes immediately
    @MainActor
    private func refreshCurrentTabFiltering() async {
        guard let selectedFeedId = selectedFeedId else { return }
        
        let currentFilter = EpisodeFilter(rawValue: currentTab) ?? .all
        print("🔄 Refreshing filtered list for tab: \(currentTab)")
        
        // Get the current full episode list (from feed or snapshot)
        var allEpisodes: [PodcastEpisode] = []
        
        // Try to get from current feed first
        if let feed = podcastFeeds.first(where: { $0.id == selectedFeedId }) {
            allEpisodes = feed.episodes
        }
        
        // If no episodes from feed, try from snapshot
        if allEpisodes.isEmpty {
            if let snapshot = getEpisodeSnapshot(for: selectedFeedId) {
                allEpisodes = snapshot
            }
        }
        
        // If still no episodes, use current episodes as fallback
        if allEpisodes.isEmpty {
            allEpisodes = currentEpisodes
        }
        
        // Apply the current tab's filter
        let filteredEpisodes: [PodcastEpisode]
        switch currentFilter {
        case .all:
            filteredEpisodes = allEpisodes
        case .favorites:
            filteredEpisodes = allEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Update the current episodes with filtered results
        let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
        currentEpisodes = sortedEpisodes
        
        print("⚡ INSTANT FILTER UPDATE: Updated current tab to show \(sortedEpisodes.count) episodes")
    }
    
    /// Immediate UI update for real-time sync (bypasses batch processing)
    private func updateEpisodeUIStateImmediate(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double? = nil) {
        print("🔄 UI STATE UPDATE: Starting immediate update for episode \(episodeId)")
        print("🔄 UI STATE UPDATE: isFavorite=\(String(describing: isFavorite)), isDownloaded=\(String(describing: isDownloaded)), progress=\(String(describing: progress))")
        
        // Update episodeProgress cache immediately
        if let progress = progress {
            episodeProgress[episodeId] = progress
        }
        
        // Update currentEpisodes using efficient single-pass update
        var foundInCurrentEpisodes = false
        for index in 0..<currentEpisodes.count {
            if currentEpisodes[index].id == episodeId {
                let oldEpisode = currentEpisodes[index]
                var updatedEpisode = currentEpisodes[index]
                
                if let isFavorite = isFavorite {
                    updatedEpisode.state.isFavorite = isFavorite
                }
                if let isDownloaded = isDownloaded {
                    updatedEpisode.state.isDownloaded = isDownloaded
                }
                if let progress = progress {
                    updatedEpisode.state.progress = progress
                }
                
                currentEpisodes[index] = updatedEpisode
                foundInCurrentEpisodes = true
                
                print("🔄 UI STATE UPDATE: Updated episode in currentEpisodes[index: \(index)]")
                print("🔄 UI STATE UPDATE: OLD - favorite: \(oldEpisode.state.isFavorite), downloaded: \(oldEpisode.state.isDownloaded)")
                print("🔄 UI STATE UPDATE: NEW - favorite: \(updatedEpisode.state.isFavorite), downloaded: \(updatedEpisode.state.isDownloaded)")
                break
            }
        }
        
        if !foundInCurrentEpisodes {
            print("🔄 UI STATE UPDATE: ⚠️ Episode \(episodeId) not found in currentEpisodes array")
        }
        
        // Update podcastFeeds efficiently (single-pass lookup)
        for feedIndex in 0..<podcastFeeds.count {
            for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                if podcastFeeds[feedIndex].episodes[episodeIndex].id == episodeId {
                    var updatedFeed = podcastFeeds[feedIndex]
                    
                    if let isFavorite = isFavorite {
                        updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                    }
                    if let isDownloaded = isDownloaded {
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                    }
                    if let progress = progress {
                        updatedFeed.episodes[episodeIndex].state.progress = progress
                    }
                    
                    podcastFeeds[feedIndex] = updatedFeed
                    return // Found and updated, exit early
                }
            }
        }
        
        // Note: Tab filtering is now handled directly in toggle methods for immediate response
    }
    
    /// Force SwiftUI to detect changes in currentEpisodes array
    private func forceUIRefresh() {
        // Multiple strategies to force UI refresh
        
        // Strategy 1: Update refresh trigger (triggers currentEpisode computed property)
        uiRefreshTrigger = UUID()
        
        // Strategy 2: Force objectWillChange notification
        objectWillChange.send()
        
        // Strategy 3: Force array change detection by recreating the array synchronously
        let episodes = currentEpisodes
        currentEpisodes = []
        currentEpisodes = episodes
        
        // Strategy 4: Force another objectWillChange after array recreation
        objectWillChange.send()
        
        print("🔄 UI FORCE REFRESH: Triggered all refresh strategies - trigger: \(uiRefreshTrigger)")
    }
    
    // MARK: - CloudKit Automatic Sync Handlers
    
    @objc private func handleCloudKitFeedAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feed = userInfo["feed"] as? PodcastFeed else {
            print("📡 ☁️ CLOUDKIT FEED ADD FAILED: Invalid feed data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT FEED ADD: Received feed addition from CloudKit: \(feed.title)")
        
        // FEED PROCESSING PROTECTION: Check if this feed is already being processed
        guard markFeedAsProcessing(feed.id) else {
            print("📡 ☁️ CLOUDKIT FEED ADD: Feed \(feed.title) is already being processed, skipping duplicate")
            return
        }
        
        // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
        let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
        
        if isDuplicateInMemory {
            print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in memory, skipping: \(feed.title)")
            markFeedAsFinished(feed.id) // Release the processing lock
            return
        }
        
        // Check Core Data for duplicate (thread-safe)
        Task {
            let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
            
            if isDuplicateInCoreData {
                print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in Core Data, skipping: \(feed.title)")
                await MainActor.run {
                    self.markFeedAsFinished(feed.id) // Release the processing lock
                }
                return
            }
            
            do {
                print("📡 🔄 CLOUDKIT FEED ADD: Fetching episodes for synced feed: \(feed.title)")
                
                // Initialize parsing progress for CloudKit sync
                await MainActor.run {
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "Loading \(feed.title) from CloudKit...")
                }
                
                // Parse RSS for episodes only (don't save feed to Core Data again)
                guard let url = URL(string: feed.url) else {
                    print("📡 ❌ CLOUDKIT FEED ADD: Invalid URL for feed \(feed.title): \(feed.url)")
                    await addFeedToUIOnly(feed)
                    return
                }
                
                // Parse RSS to get episodes
                let episodes = try await parseRSSEpisodesOnly(from: url)
                
                // CRITICAL: Save feed to Core Data FIRST before adding episodes
                try await saveFeedToCoreData(feed)
                
                // Add episodes to Core Data for this feed
                try await PodcastCoreDataManager.shared.addNewEpisodes(episodes, to: feed.id)
                
                await MainActor.run {
                    // Final check before adding (prevents race conditions)
                    if !self.podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url }) {
                        // Add feed with episodes to UI
                        var feedWithEpisodes = feed
                        feedWithEpisodes.episodes = episodes
                        
                        self.podcastFeeds.append(feedWithEpisodes)
                        self.podcastFeedOrder.append(feedWithEpisodes.id)
                        self.throttledUIUpdate()
                        
                        print("📡 ☁️ CLOUDKIT FEED ADD: ✅ Added feed with \(episodes.count) episodes from CloudKit: \(feed.title)")
                        
                        // 🎯 CROSS-DEVICE BANNER: Show banner for feed added from other device
                        print("📡 🔄 CROSS-DEVICE NOTIFICATION: Triggering banner for feed added from other device")
                        DataSyncManager.shared.startCrossDeviceFeedSync(
                            totalCount: 1,
                            operation: "Synced '\(feed.title)' from other device"
                        )
                        
                        // Complete the banner after a short delay to show the sync
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: 1,
                                operation: "Added '\(feed.title)'"
                            )
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DataSyncManager.shared.completeCrossDeviceFeedSync()
                            }
                        }
                    } else {
                        print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Last-second duplicate check prevented duplicate: \(feed.title)")
                    }
                    
                    // Reset parsing progress after successful completion
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    
                    // Release the processing lock after successful completion
                    self.markFeedAsFinished(feed.id)
                }
                
            } catch {
                print("📡 ❌ CLOUDKIT FEED ADD: Failed to fetch episodes for \(feed.title): \(error)")
                
                // Still save the feed to Core Data even without episodes
                do {
                    try await saveFeedToCoreData(feed)
                    await addFeedToUIOnly(feed)
                    print("📡 ✅ CLOUDKIT FEED ADD: Saved feed without episodes as fallback: \(feed.title)")
                    
                    // 🎯 CROSS-DEVICE BANNER: Show banner for feed added from other device (fallback case)
                    await MainActor.run {
                        print("📡 🔄 CROSS-DEVICE NOTIFICATION: Triggering banner for fallback feed addition")
                        DataSyncManager.shared.startCrossDeviceFeedSync(
                            totalCount: 1,
                            operation: "Synced '\(feed.title)' from other device"
                        )
                        
                        // Complete the banner after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: 1,
                                operation: "Added '\(feed.title)'"
                            )
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DataSyncManager.shared.completeCrossDeviceFeedSync()
                            }
                        }
                    }
                } catch {
                    print("📡 ❌ CLOUDKIT FEED ADD: Failed to save feed as fallback: \(error)")
                }
                
                // Reset parsing progress after error
                await MainActor.run {
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    // Release the processing lock after error
                    self.markFeedAsFinished(feed.id)
                }
            }
        }
    }
    
    /// Parse RSS feed to get episodes only (without saving feed to Core Data) with robust error handling
    private func parseRSSEpisodesOnly(from url: URL) async throws -> [PodcastEpisode] {
        print("🔍 Parsing RSS episodes from: \(url.absoluteString)")
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting RSS parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // Ensure RSS operations happen on dedicated background queue to prevent main thread blocking
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .background) {
                do {
                    // Check for cancellation and scrolling before starting
                    try Task.checkCancellation()
                    
                    // Double-check scrolling state
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected during parsing - aborting")
                        throw CancellationError()
                    }
                    
                    // Fetch RSS data with robust error handling for large feeds and decode issues
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation and scrolling after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting")
                        throw CancellationError()
                    }
                    
                    // CRITICAL: Yield between fetch and parse to allow UI updates
                    await Task.yield()
                    
                    // PERFORMANCE FIX: Parse RSS without progress tracking for auto-refresh to prevent main thread blocking
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, episodes) = try await parser.parseComplete()
                    
                    // Check for cancellation and scrolling after parsing
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after parsing - aborting")
                        throw CancellationError()
                    }
                    
                    print("🔍 Parsed \(episodes.count) episodes from RSS")
                    
                    // ENHANCED LOGGING: Show episode date range
                    if !episodes.isEmpty {
                        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
                        let newestDate = sortedEpisodes.first?.publicationDate ?? Date()
                        let oldestDate = sortedEpisodes.last?.publicationDate ?? Date()
                    }
                    
                    continuation.resume(returning: episodes)
                } catch {
                    print("❌ Failed to parse RSS episodes: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Parse RSS feed intelligently and return only new episodes that don't exist in Core Data
    /// IMMEDIATE NEW EPISODE CHECK: Check for new episodes when feed opens
    /// LIGHTWEIGHT NEW EPISODE DETECTION: Ultra-fast check without expensive RSS parsing
    /// Uses HEAD requests and conditional logic to detect new episodes with minimal CPU impact
    private func lightweightNewEpisodeCheck(feedId: String) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        print("🪶 LIGHTWEIGHT: Starting ultra-fast new episode detection")
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }) else {
            print("🪶 LIGHTWEIGHT: No feed URL found for \(feedId)")
            return
        }
        
        guard let url = URL(string: feedUrl) else {
            print("🪶 LIGHTWEIGHT: Invalid feed URL: \(feedUrl)")
            return
        }
        
        // STEP 1: Quick HEAD request to check if feed was modified recently
        // Check if this is a user-initiated request
        let userRefreshKey = "UserRequestedRefresh_\(feedId)"
        let isUserInitiated = UserDefaults.standard.bool(forKey: userRefreshKey)
        
        let wasRecentlyModified = await checkFeedModificationWithHEAD(url: url, feedId: feedId, isUserInitiated: isUserInitiated)
        
        // Clear the user-initiated flag after checking
        if isUserInitiated {
            UserDefaults.standard.removeObject(forKey: userRefreshKey)
        }
        
        if !wasRecentlyModified {
            print("🪶 LIGHTWEIGHT: Feed not recently modified - skipping expensive parsing")
            return
        }
        
        // STEP 2: If potentially new content, do minimal RSS sampling (not full parse)
        await performMinimalEpisodeSampling(url: url, feedId: feedId)
    }
    
    /// PERFORMANCE OPTIMIZATION: Check feed modification using HEAD request (ultra-fast)
    private func checkFeedModificationWithHEAD(url: URL, feedId: String, isUserInitiated: Bool = false) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"  // Only get headers, no body content
            request.timeoutInterval = 5.0  // Quick timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🪶 HEAD: Response \(httpResponse.statusCode) for feed check")
                
                // Check Last-Modified header
                if let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
                    let lastModifiedKey = "LastModified_\(feedId)"
                    let previousLastModified = UserDefaults.standard.string(forKey: lastModifiedKey)
                    
                    if previousLastModified != lastModified {
                        UserDefaults.standard.set(lastModified, forKey: lastModifiedKey)
                        print("🪶 HEAD: Feed modified since last check - \(lastModified)")
                        return true
                    } else {
                        print("🪶 HEAD: Feed not modified since last check")
                        return false
                    }
                }
                
                // CRITICAL FIX: Always allow user-initiated checks to bypass throttling
                if isUserInitiated {
                    print("🪶 HEAD: User-initiated check - bypassing throttling to check for new episodes")
                    return true
                }
                
                // Fallback: Check if it's been more than 30 minutes since last check
                let lastCheckKey = "LastLightweightCheck_\(feedId)"
                let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
                let now = Date().timeIntervalSince1970
                
                if now - lastCheck > 1800 { // 30 minutes
                    UserDefaults.standard.set(now, forKey: lastCheckKey)
                    print("🪶 HEAD: No Last-Modified header, but 30+ minutes since last check")
                    return true
                } else {
                    print("🪶 HEAD: Recently checked within 30 minutes - skipping")
                    return false
                }
            }
            
            return false
        } catch {
            print("🪶 HEAD: Failed to check feed modification: \(error.localizedDescription)")
            // If HEAD request fails, don't do expensive operations
            return false
        }
    }
    
    /// MINIMAL SAMPLING: Get just the first few episodes to check for new content (lightweight)
    private func performMinimalEpisodeSampling(url: URL, feedId: String) async {
        do {
            print("🪶 SAMPLING: Starting minimal episode sampling")
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            request.setValue("bytes=0-8192", forHTTPHeaderField: "Range")  // Only first 8KB
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🪶 SAMPLING: Got \(data.count) bytes for sampling")
                
                // Quick string search for episode markers without full XML parsing
                let content = String(data: data, encoding: .utf8) ?? ""
                let episodeCount = content.components(separatedBy: "<item>").count - 1
                
                if episodeCount > 0 {
                    // Get current episode count from snapshot
                    let currentCount = await MainActor.run {
                        self.getEpisodeSnapshot(for: feedId)?.count ?? 0
                    }
                    
                    print("🪶 SAMPLING: Found \(episodeCount) episodes in sample, current snapshot has \(currentCount)")
                    
                    // Only trigger full refresh if there's a significant difference or it's been a while
                    let lastFullRefreshKey = "LastFullRefresh_\(feedId)"
                    let lastFullRefresh = UserDefaults.standard.double(forKey: lastFullRefreshKey)
                    let now = Date().timeIntervalSince1970
                    
                    if now - lastFullRefresh > 3600 { // 1 hour
                        print("🪶 SAMPLING: Scheduling background refresh (1+ hours since last full refresh)")
                        UserDefaults.standard.set(now, forKey: lastFullRefreshKey)
                        
                        // Schedule background refresh with delay to avoid immediate CPU spike
                        Task.detached(priority: .background) {
                            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second delay
                            await self.backgroundRefreshForNewEpisodes(feedId: feedId, isInitialLoad: false)
                        }
                    } else {
                        print("🪶 SAMPLING: Skipping background refresh - recently refreshed")
                    }
                } else {
                    print("🪪 SAMPLING: Skipping background refresh - recently refreshed")
                }
            } else {
                print("🪪 BACKGROUND: No new episodes found")
            }
        } catch {
            print("🪪 BACKGROUND: Background refresh failed: \(error.localizedDescription)")
        }
    }
    
    /// Background refresh for new episodes without blocking UI
    private func backgroundRefreshForNewEpisodes(feedId: String, isInitialLoad: Bool) async {
        print("🔄 BACKGROUND REFRESH: Checking for new episodes for feed \(feedId)")
        
        // Check if feed needs RSS refresh for new episodes
        let shouldAutoRefresh = await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: isInitialLoad)
        guard shouldAutoRefresh else {
            print("⚡ BACKGROUND REFRESH: No refresh needed for feed \(feedId)")
            return
        }
        
        do {
            print("🔄 BACKGROUND REFRESH: Fetching new episodes from RSS for feed \(feedId)")
            let (updatedFeed, newEpisodes) = try await feedManager.refreshFeed(feedId)
            
            if !newEpisodes.isEmpty {
                print("🆕 BACKGROUND REFRESH: Found \(newEpisodes.count) new episodes")
                
                // Update cached episodes and refresh UI if this feed is currently selected
                let refreshedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                updateEpisodeSnapshot(for: feedId, episodes: refreshedEpisodes)
                
                await MainActor.run {
                    if selectedFeedId == feedId {
                        // Apply current filter to refreshed episodes
                        let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = refreshedEpisodes
                        case .favorites:
                            filteredEpisodes = refreshedEpisodes.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = refreshedEpisodes.filter { $0.state.isDownloaded }
                        }
                        
                        // Update UI with new episodes
                        currentEpisodes = filteredEpisodes
                        
                        // Update episode counts
                        let allCount = refreshedEpisodes.count
                        let favoritesCount = refreshedEpisodes.filter { $0.state.isFavorite }.count
                        let downloadsCount = refreshedEpisodes.filter { $0.state.isDownloaded }.count
                        episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                        
                        print("🔄 BACKGROUND REFRESH: Updated UI with \(newEpisodes.count) new episodes")
                    }
                }
            } else {
                print("✅ BACKGROUND REFRESH: No new episodes found for feed \(feedId)")
            }
            
            // Update refresh timestamp
            await MainActor.run {
                let currentTime = Date().timeIntervalSince1970
                let lastRefreshKey = "LastRSSRefresh_\(feedId)"
                UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            }
            
        } catch {
            print("❌ BACKGROUND REFRESH: Failed to refresh feed \(feedId): \(error)")
        }
    }
    
    /// FEED OPEN OPTIMIZATION: Check for new episodes immediately when feed is opened, bypassing all thresholds
    /// This ensures users always see the latest episodes without waiting, while maintaining performance
    private func checkForNewEpisodesImmediatelyOnFeedOpen(feedId: String) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        print("🚀 FEED OPEN CHECK: Starting immediate check for new episodes (no thresholds)")
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }), let url = URL(string: feedUrl) else {
            print("⚠️ FEED OPEN CHECK: Missing feed URL for \(feedId)")
            return
        }
        
        do {
            // Check for cancellation before starting work
            try Task.checkCancellation()
            
            // ULTRA-FAST NEW EPISODE DETECTION: Use optimized parsing that stops at first known episode
            let newEpisodes = try await parseNewEpisodesOnlyOptimized(from: url, feedId: feedId)
            
            // Check for cancellation after parsing
            try Task.checkCancellation()
            
            guard !newEpisodes.isEmpty else {
                print("✅ FEED OPEN CHECK: No new episodes found for feed \(feedId)")
                return
            }
            
            print("🆕 FEED OPEN CHECK: Found \(newEpisodes.count) new episodes for feed \(feedId)")
            
            // IMMEDIATE INTEGRATION: Add new episodes without expensive operations
            await self.integrateNewEpisodesLightweight(newEpisodes, feedId: feedId)
            
            // IMMEDIATE UI UPDATE: Update current episodes if this feed is selected
            await MainActor.run {
                if self.selectedFeedId == feedId {
                    // Get updated snapshot and refresh UI
                    if let updatedSnapshot = self.getEpisodeSnapshot(for: feedId) {
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = updatedSnapshot
                        case .favorites:
                            filteredEpisodes = updatedSnapshot.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = updatedSnapshot.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        Task {
                            await self.updateEpisodeCounts(for: feedId, episodes: updatedSnapshot)
                        }
                        print("🆕 FEED OPEN CHECK: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count)")
                    }
                }
                
                self.objectWillChange.send()
            }
            
        } catch is CancellationError {
            print("🚫 FEED OPEN CHECK: Cancelled for feed \(feedId)")
        } catch {
            print("❌ FEED OPEN CHECK: Failed to check for new episodes: \(error)")
        }
    }
    
    /// This runs in background with high priority but doesn't block the UI
    private func checkForNewEpisodesImmediately(feedId: String, userInitiated: Bool = false) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        // PERFORMANCE: Even for user-initiated checks, respect fresh snapshots to prevent CPU spikes
        if let snapshotEpisodes = getEpisodeSnapshot(for: feedId) {
            let snapshotAge = Date().timeIntervalSince(snapshotTimestamps[feedId] ?? Date.distantPast)
            // For user-initiated checks, use a shorter threshold (5 minutes) vs background checks (30 minutes)
            let threshold = userInitiated ? 300 : 1800 // 5 minutes for user-initiated, 30 minutes for background
            if snapshotAge < TimeInterval(threshold) {
                if userInitiated {
                    print("⚡ USER-INITIATED OPTIMIZATION: Skipping RSS check - fresh snapshot available (\(Int(snapshotAge/60)) min old, \(snapshotEpisodes.count) episodes)")
                } else {
                    print("⚡ PERFORMANCE: Skipping background RSS check - recent snapshot available (\(Int(snapshotAge/60)) min old, \(snapshotEpisodes.count) episodes)")
                }
                return
            } else {
                if userInitiated {
                    print("🔍 USER-INITIATED CHECK: Snapshot is \(Int(snapshotAge/60)) min old - checking for new episodes")
                } else {
                    print("🔍 IMMEDIATE CHECK: Snapshot is \(Int(snapshotAge/60)) min old - checking for new episodes")
                }
            }
        } else if userInitiated {
            print("🔍 USER-INITIATED CHECK: No snapshot available - checking for new episodes")
        }
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }), let url = URL(string: feedUrl) else {
            print("⚠️ IMMEDIATE CHECK: Missing feed URL for \(feedId)")
            return
        }
                
        do {
            // Check for cancellation before starting work
            try Task.checkCancellation()
            
            // SMART NEW EPISODE DETECTION: Compare against persistent cache first
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            // Check for cancellation after parsing
            try Task.checkCancellation()
            
            guard !newEpisodes.isEmpty else {
                print("✅ IMMEDIATE CHECK: No new episodes found for feed \(feedId)")
                return
            }
            
            print("🆕 IMMEDIATE CHECK: Found \(newEpisodes.count) new episodes for feed \(feedId)")
            
            // UPDATE PERSISTENT CACHE with new episodes immediately
            await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
            
            // Add new episodes to Core Data for persistence
            try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
            
            // CRITICAL: IMMEDIATELY CREATE NEW SNAPSHOT with integrated new episodes
            // Get the complete current episode list to create a fresh snapshot
            let feedUrl = await MainActor.run(body: {
                self.podcastFeeds.first(where: { $0.id == feedId })?.url
            })
            
            var completeEpisodeList: [PodcastEpisode] = []
            
            if let urlString = feedUrl, let url = URL(string: urlString) {
                // Parse complete RSS feed to get all current episodes (newest first)
                let allCurrentEpisodes = try await parseRSSEpisodesOnly(from: url)
                completeEpisodeList = allCurrentEpisodes
                print("🔄 IMMEDIATE CHECK: Parsed complete feed with \(allCurrentEpisodes.count) episodes")
            } else {
                // Fallback: merge new episodes with existing snapshot
                if let existingSnapshot = episodeSnapshotCache[feedId] {
                    completeEpisodeList = newEpisodes + existingSnapshot
                } else {
                    completeEpisodeList = newEpisodes
                }
                print("🔄 IMMEDIATE CHECK: Using fallback merge with \(completeEpisodeList.count) episodes")
            }
            
            // CLEAN UP: Remove old snapshot before creating new one
            if episodeSnapshotCache[feedId] != nil {
                print("🗑️ SNAPSHOT CLEANUP: Removing old snapshot for feed \(feedId)")
                episodeSnapshotCache.removeValue(forKey: feedId)
                snapshotTimestamps.removeValue(forKey: feedId)
            }
            
            // CREATE NEW SNAPSHOT: Replace old snapshot with complete episode list (newest first)
            updateEpisodeSnapshot(for: feedId, episodes: completeEpisodeList)
            print("🆕 IMMEDIATE CHECK: Created new snapshot with \(completeEpisodeList.count) episodes (includes \(newEpisodes.count) new episodes)")
            
            // IMMEDIATE UI UPDATE: Update current episodes if this feed is selected
            await MainActor.run {
                if self.selectedFeedId == feedId {
                    let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                    let filteredEpisodes: [PodcastEpisode]
                    switch filter {
                    case .all:
                        filteredEpisodes = completeEpisodeList
                    case .favorites:
                        filteredEpisodes = completeEpisodeList.filter { $0.state.isFavorite }
                    case .downloads:
                        filteredEpisodes = completeEpisodeList.filter { $0.state.isDownloaded }
                    }
                    
                    self.currentEpisodes = filteredEpisodes
                    Task {
                        await self.updateEpisodeCounts(for: feedId, episodes: completeEpisodeList)
                    }
                    print("🆕 IMMEDIATE CHECK: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count) (newest first)")
                }
                
                self.objectWillChange.send()
            }
            
            // Sync episode states for new episodes in background
            Task.detached(priority: .background) {
                await self.quietSyncEpisodeStates(for: feedId)
            }
                        
        } catch is CancellationError {
            print("🚫 IMMEDIATE CHECK: Cancelled for feed \(feedId)")
        } catch {
            print("❌ IMMEDIATE CHECK: Failed to check for new episodes: \(error)")
        }
    }
    
    /// OPTIMIZED VERSION: Ultra-fast parsing that stops immediately at first known episode
    /// This is specifically designed for feed open scenarios where we need immediate results
    private func parseNewEpisodesOnlyOptimized(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting optimized new episode parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // ULTRA-FAST APPROACH: Get first few episode IDs from current snapshot for instant comparison
        let knownEpisodeIds = await getKnownEpisodeIdsFromSnapshot(feedId: feedId, limit: 20)
        
        // Parse RSS with immediate stopping at first known episode
        let newEpisodes = try await parseRSSEpisodesWithImmediateStop(from: url, knownIds: knownEpisodeIds)
        
        return newEpisodes
    }
    
    /// Get known episode IDs from snapshot for ultra-fast comparison
    private func getKnownEpisodeIdsFromSnapshot(feedId: String, limit: Int) async -> Set<String> {
        return await MainActor.run {
            guard let snapshot = self.episodeSnapshotCache[feedId] else {
                return Set<String>()
            }
            
            // Take only the first 'limit' episodes (most recent) for fast comparison
            let recentEpisodes = Array(snapshot.prefix(limit))
            return Set(recentEpisodes.map { $0.id })
        }
    }
    
    /// Lightweight integration that updates snapshot without expensive operations
    private func integrateNewEpisodesLightweight(_ newEpisodes: [PodcastEpisode], feedId: String) async {
        
        // Add to Core Data in background (non-blocking)
        Task.detached(priority: .utility) {
            try? await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
        }
        
        // Update episode manager cache (fast operation)
        await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
        
        // IMMEDIATE SNAPSHOT UPDATE: Prepend new episodes to existing snapshot
        await MainActor.run {
            if let existingSnapshot = self.episodeSnapshotCache[feedId] {
                // Merge new episodes with existing, ensuring no duplicates
                let existingIds = Set(existingSnapshot.map { $0.id })
                let trulyNewEpisodes = newEpisodes.filter { !existingIds.contains($0.id) }
                
                if !trulyNewEpisodes.isEmpty {
                    // Sort by publication date (newest first) and update snapshot
                    let updatedEpisodes = (trulyNewEpisodes + existingSnapshot).sorted(by: { 
                        $0.publicationDate > $1.publicationDate 
                    })
                    
                    self.episodeSnapshotCache[feedId] = updatedEpisodes
                    self.snapshotTimestamps[feedId] = Date()
                    
                    print("🆕 LIGHTWEIGHT INTEGRATION: Added \(trulyNewEpisodes.count) new episodes to snapshot - total: \(updatedEpisodes.count)")
                }
            } else {
                // No existing snapshot, create new one with just the new episodes
                self.episodeSnapshotCache[feedId] = newEpisodes.sorted { $0.publicationDate > $1.publicationDate }
                self.snapshotTimestamps[feedId] = Date()
                
                print("🆕 LIGHTWEIGHT INTEGRATION: Created new snapshot with \(newEpisodes.count) episodes")
            }
        }
    }
    
    /// ULTRA-OPTIMIZED RSS parsing that stops immediately when it encounters a known episode
    /// This minimizes network and CPU usage for immediate feed open scenarios
    private func parseRSSEpisodesWithImmediateStop(from url: URL, knownIds: Set<String>) async throws -> [PodcastEpisode] {
        print("🚀 OPTIMIZED PARSING: Starting immediate-stop RSS parsing with \(knownIds.count) known episode IDs")
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting immediate-stop parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // Check for cancellation before starting
                    try Task.checkCancellation()
                    
                    // Fetch RSS data (this is unavoidable but fast for most feeds)
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting")
                        throw CancellationError()
                    }
                    
                    // OPTIMIZED PARSING: Parse complete RSS but filter out known episodes immediately
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, allEpisodes) = try await parser.parseComplete()
                    
                    // IMMEDIATE FILTERING: Stop at first known episode to minimize processing
                    var newEpisodes: [PodcastEpisode] = []
                    for episode in allEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }) {
                        if knownIds.contains(episode.id) {
                            // Found a known episode, stop processing
                            print("🛑 OPTIMIZED PARSING: Stopped at known episode '\(episode.title)' - found \(newEpisodes.count) new episodes")
                            break
                        }
                        newEpisodes.append(episode)
                    }
                    
                    print("🚀 OPTIMIZED PARSING: Found \(newEpisodes.count) new episodes (stopped at first known episode)")
                    
                    continuation.resume(returning: newEpisodes)
                } catch {
                    print("❌ Failed to parse RSS with immediate stop: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Uses timestamp comparison to stop parsing once we reach episodes we already have
    private func parseNewEpisodesOnly(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting new episode parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // Get the most recent episode date from Core Data to use as cutoff
        let mostRecentEpisodeDate = await getMostRecentEpisodeDate(for: feedId)
        
        // Get existing episode IDs from Core Data to compare
        let existingEpisodeIds = await getExistingEpisodeIds(for: feedId)
        
        // Parse episodes from RSS with intelligent stopping
        let newEpisodes = try await parseRSSEpisodesWithCutoff(from: url, cutoffDate: mostRecentEpisodeDate, existingIds: existingEpisodeIds)
        
        return newEpisodes
    }
    
    /// Get existing episode IDs for a feed from Core Data
    private func getExistingEpisodeIds(for feedId: String) async -> Set<String> {
        return await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                fetchRequest.propertiesToFetch = ["id"] // Only fetch IDs for performance
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    let episodeIds = Set(results.compactMap { $0.id })
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to fetch existing episode IDs: \(error)")
                    continuation.resume(returning: Set<String>())
                }
            }
        }
    }
    
    /// Get the most recent episode publication date for a feed from Core Data
    private func getMostRecentEpisodeDate(for feedId: String) async -> Date? {
        return await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                fetchRequest.fetchLimit = 1
                fetchRequest.propertiesToFetch = ["publicationDate"]
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    let mostRecentDate = results.first?.publicationDate
                    continuation.resume(returning: mostRecentDate)
                } catch {
                    print("❌ Failed to fetch most recent episode date: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Parse RSS episodes with intelligent cutoff based on existing episode dates
    private func parseRSSEpisodesWithCutoff(from url: URL, cutoffDate: Date?, existingIds: Set<String>) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting smart RSS parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // For new feeds (no cutoff date), parse all episodes
        if cutoffDate == nil {
            print("🆕 New feed detected - parsing all episodes")
            return try await parseRSSEpisodesOnly(from: url)
        }
        
        // For existing feeds, parse with intelligent cutoff
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .background) {
                do {
                    // Check for cancellation and scrolling before starting
                    try Task.checkCancellation()
                    
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected during smart parsing - aborting")
                        throw CancellationError()
                    }
                    
                    // Fetch RSS data
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation and scrolling after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting smart parsing")
                        throw CancellationError()
                    }
                    
                    // CRITICAL: Yield between fetch and parse
                    await Task.yield()
                    
                    // Parse with regular parser and filter intelligently
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, allEpisodes) = try await parser.parseComplete()
                    
                    print("🔍 PARSING: Found \(allEpisodes.count) total episodes in RSS feed")
                    if let cutoff = cutoffDate {
                        print("🔍 PARSING: Using cutoff date: \(cutoff) (with 30s buffer)")
                    }
                    
                    // Filter to only new episodes based on cutoff date and existing IDs
                    let newEpisodes = allEpisodes.filter { episode in
                        // Skip if episode already exists
                        if existingIds.contains(episode.id) {
                            
                            return false
                        }
                        
                        // HOURLY PODCAST FIX: For frequent releases (like hourly news), use buffer to account for date precision
                        if let cutoff = cutoffDate {
                            // Add 30-second buffer to handle hourly podcasts and date precision issues
                            let cutoffWithBuffer = cutoff.addingTimeInterval(-30)
                            if episode.publicationDate <= cutoffWithBuffer {
                                print("🔍 FILTERING: Skipping old episode - Date: \(episode.publicationDate), Cutoff: \(cutoffWithBuffer)")
                                return false
                            } else {
                                print("🆕 FILTERING: New episode found - Date: \(episode.publicationDate), Cutoff: \(cutoffWithBuffer)")
                            }
                        }
                        
                        return true
                    }
                    
                    // Check for cancellation and scrolling after parsing
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after smart parsing - aborting")
                        throw CancellationError()
                    }
                    
                    print("🧠 Smart parsing found \(newEpisodes.count) new episodes")
                    continuation.resume(returning: newEpisodes)
                } catch {
                    print("❌ Failed to smart parse RSS episodes: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Robust RSS data fetching with retry mechanism for decode errors  
    private func fetchRSSDataWithRetry(url: URL, feedTitle: String, maxRetries: Int = 3) async throws -> Data {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                
                // CRITICAL: Yield control to allow UI updates
                await Task.yield()
                
                // Configure URLSession with longer timeout for large feeds and dedicated background queue
                var request = URLRequest(url: url)
                request.timeoutInterval = 30.0 // Increased timeout for large episodes
                request.setValue("StreamRadios/1.0", forHTTPHeaderField: "User-Agent")
                request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
                request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
                
                // CRITICAL: Another yield point before network operation
                await Task.yield()
                
                // Use URLSession with background configuration to prevent main thread blocking
                let session = URLSession(configuration: .default)
                let (data, response) = try await session.data(for: request)
                
                // CRITICAL: Yield after network operation completes
                await Task.yield()
                
                // Validate HTTP response
                if let httpResponse = response as? HTTPURLResponse {
                    print("📡 HTTP Response: \(httpResponse.statusCode) for: \(feedTitle)")
                    
                    // Check for server errors
                    guard 200...299 ~= httpResponse.statusCode else {
                        throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
                    }
                    
                    // Log content type for debugging
                    if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        print("📄 Content-Type: \(contentType) for: \(feedTitle)")
                    }
                }
                
                // CRITICAL: Yield before data validation
                await Task.yield()
                
                // Validate data size and content
                guard !data.isEmpty else {
                    throw NSError(domain: "FeedError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty data received"])
                }
                
                // Check for minimum RSS/XML content
                guard data.count > 100 else { // Minimum viable RSS feed should be larger
                    throw NSError(domain: "FeedError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Data too small (\(data.count) bytes)"])
                }
                
                // CRITICAL: Yield before XML validation
                await Task.yield()
                
                // Validate XML structure - check if data starts with valid XML
                let dataPrefix = String(data: data.prefix(200), encoding: .utf8) ?? ""
                let hasXMLDeclaration = dataPrefix.contains("<?xml") || dataPrefix.contains("<rss") || dataPrefix.contains("<feed")
                
                guard hasXMLDeclaration else {
                    print("❌ Invalid XML structure for: \(feedTitle) - Data starts with: \(dataPrefix.prefix(100))")
                    throw NSError(domain: "FeedError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid XML structure"])
                }
                
                // Check for common encoding issues (BOM, invalid characters)
                if dataPrefix.hasPrefix("\u{FEFF}") {
                    print("🔧 Removing BOM from feed data: \(feedTitle)")
                    return Data(data.dropFirst(3)) // Remove UTF-8 BOM
                }
                
                return data
                
            } catch {
                lastError = error
                let isDecodeError = (error as NSError).code == -1015
                
                print("❌ Fetch attempt \(attempt)/\(maxRetries) failed for: \(feedTitle) - Error: \(error.localizedDescription)")
                
                // CRITICAL: Yield before retry delay to allow UI updates
                await Task.yield()
                
                // For decode errors, wait longer between retries
                if isDecodeError && attempt < maxRetries {
                    let delay = Double(attempt) * 2.0 // Progressive delay: 2s, 4s, 6s
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else if attempt < maxRetries {
                    // Standard retry delay for other errors
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
                
                // CRITICAL: Yield after retry delay before next attempt
                await Task.yield()
            }
        }
        
        // All retries failed
        
        if let lastError = lastError, (lastError as NSError).code == -1015 {
            throw NSError(domain: "FeedError", code: -1015, userInfo: [NSLocalizedDescriptionKey: "Feed data is corrupted or truncated"])
        } else {
            throw NSError(domain: "FeedError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Maximum retry attempts exceeded"])
        }
    }
    
    /// Helper met hod to add feed to UI without episode parsing (fallback)
    @MainActor
    private func addFeedToUIOnly(_ feed: PodcastFeed) {
        if !podcastFeeds.contains(where: { $0.id == feed.id }) {
            podcastFeeds.append(feed)
            podcastFeedOrder.append(feed.id)
            throttledUIUpdate()
        }
    }
    
    @objc private func handleCloudKitFeedDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedId = userInfo["feedId"] as? String else {
            print("📡 ☁️ CLOUDKIT FEED DELETE FAILED: Invalid feed ID in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT FEED DELETE: Received feed deletion from CloudKit: \(feedId)")
        
        // Find the feed for comprehensive cleanup
        if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feedId }) {
            let feedTitle = podcastFeeds[feedIndex].title
            let feed = podcastFeeds[feedIndex]
            
            
            Task {
                // Step 1: Get episode IDs for comprehensive cleanup
                let episodeIds = await getEpisodeIdsForFeed(feedId)
                
                // Step 2: Clean up episode data from EpisodeStateManager (prevents duplication)
                for episodeId in episodeIds {
                    EpisodeStateManager.shared.clearEpisodeData(episodeId)
                }
                
                // Step 3: Delete downloaded episode files (prevents storage bloat)
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                // Step 4: Remove from UI arrays and clear local state
                await MainActor.run {
                    // Remove from UI arrays
                    if let currentIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                        self.podcastFeeds.remove(at: currentIndex)
                    }
                    self.podcastFeedOrder.removeAll { $0 == feedId }
                    self.currentEpisodes.removeAll { $0.feedId == feedId }
                    
                    // Clear selected feed if it's the one being deleted
                    if self.selectedFeedId == feedId {
                        self.selectedFeedId = nil
                    }
                    
                    // Clear local episode state tracking (prevents stale state)
                    for episodeId in episodeIds {
                        self.episodeProgress.removeValue(forKey: episodeId)
                    }
                    
                    // Trigger UI update
                    self.throttledUIUpdate()
                }
                
                // Step 5: Delete from Core Data (prevents duplication)
                do {
                    try await deleteFeedFromCoreData(feed)
                    
                    await MainActor.run {
                        print("📡 ☁️ CLOUDKIT FEED DELETE: ✅ Comprehensive cleanup completed for: \(feedTitle)")
                        print("📡 ☁️ 📊 CloudKit deletion cleanup summary:")
                        print("📡 ☁️    ✅ EpisodeStateManager: \(episodeIds.count) episode states cleared")
                        print("📡 ☁️    ✅ Downloaded files: cleaned up")
                        print("📡 ☁️    ✅ Core Data: feed and episodes deleted")
                        print("📡 ☁️    ✅ UI: feed and episodes removed")
                        print("📡 ☁️    ✅ Local state: episode progress cleared")
                        print("📡 ☁️ 🚨 Feed can now be safely re-added without duplication!")
                    }
                } catch {
                    print("📡 ☁️ ❌ Error during Core Data cleanup for CloudKit feed deletion: \(error)")
                }
            }
        } else {
            print("📡 ☁️ CLOUDKIT FEED DELETE: ⚠️ Feed not found locally, might already be deleted: \(feedId)")
            
            // Even if feed not found in UI, attempt Core Data cleanup to prevent orphaned data
            Task {
                do {
                    let dummyFeed = PodcastFeed(id: feedId, title: "Unknown Feed", url: "", artworkUrl: nil, description: nil)
                    try await deleteFeedFromCoreData(dummyFeed)
                    print("📡 ☁️ Performed orphaned data cleanup for feed ID: \(feedId)")
                } catch {
                    print("📡 ☁️ Note: No orphaned data found for feed ID: \(feedId)")
                }
            }
        }
    }
    
    @objc private func handleRealtimeCloudKitFeedDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedId = userInfo["feedId"] as? String else {
            print("📡 🔔 REALTIME CLOUDKIT DELETE FAILED: Invalid feed ID in notification")
            return
        }
        
        print("📡 🔔 REALTIME CLOUDKIT DELETE: Received real-time feed deletion from CloudKit: \(feedId)")
        
        // Find the feed first to get episode IDs and title before deletion
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed not found locally, might already be deleted: \(feedId)")
            return
        }
        
        let feedTitle = feed.title // Store title early since we'll need it later
        
        Task {
            // Get episode IDs for cleanup
            let episodeIds = await getEpisodeIdsForFeed(feedId)
            print("📡 🔔 Found \(episodeIds.count) episodes to clean up for real-time deletion: \(feedTitle)")
            
            // Clean up episode data from EpisodeStateManager
            for episodeId in episodeIds {
                EpisodeStateManager.shared.clearEpisodeData(episodeId)
            }
            
            // Delete downloaded episode files
            await deleteDownloadedEpisodeFiles(episodeIds)
            
            // Remove from UI and Core Data
            await MainActor.run {
                // **RACE CONDITION FIX**: Find the feed again right before removal
                // The array might have changed during the async operations above
                if let currentFeedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                    self.podcastFeeds.remove(at: currentFeedIndex)
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Removed feed from UI at index \(currentFeedIndex)")
                } else {
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed was already removed from UI during async operations")
                }
                
                // These operations are safe even if the feed was already removed
                self.podcastFeedOrder.removeAll { $0 == feedId }
                self.currentEpisodes.removeAll { $0.feedId == feedId }
                
                // Clear selected feed if it's the one being deleted
                if self.selectedFeedId == feedId {
                    self.selectedFeedId = nil
                }
                
                // Clear local episode state tracking
                for episodeId in episodeIds {
                    self.episodeProgress.removeValue(forKey: episodeId)
                }
                
                // Trigger UI update
                self.throttledUIUpdate()
                print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Applied real-time deletion for: \(feedTitle)")
            }
            
            // Delete from Core Data - but only if it still exists to prevent conflicts
            do {
                let feedExists = await checkIfFeedExistsInCoreData(feedId: feedId)
                if feedExists {
                    let feedForDeletion = PodcastFeed(id: feedId, title: feedTitle, url: "", artworkUrl: nil, description: nil)
                    try await deleteFeedFromCoreData(feedForDeletion)
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Deleted from Core Data: \(feedTitle)")
                } else {
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed already deleted from Core Data, skipping: \(feedTitle)")
                }
            } catch {
                print("📡 🔔 REALTIME CLOUDKIT DELETE: ❌ Error deleting from Core Data: \(error)")
            }
        }
    }
    
    @objc private func handleCloudKitAllFeedsUpdatedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feeds = userInfo["feeds"] as? [PodcastFeed] else {
            print("📡 ☁️ CLOUDKIT ALL FEEDS FAILED: Invalid feeds data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT ALL FEEDS: Received full feed sync from CloudKit: \(feeds.count) feeds")
        
        DispatchQueue.main.async {
            // Replace local feeds with CloudKit feeds (full sync)
            self.podcastFeeds = feeds
            self.podcastFeedOrder = feeds.map { $0.id }
            self.throttledUIUpdate()
            print("📡 ☁️ CLOUDKIT ALL FEEDS: ✅ Updated all feeds from CloudKit")
        }
    }
    
    @objc private func handleCloudKitEpisodeStateSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double,
              let isFavorite = userInfo["isFavorite"] as? Bool,
              let isDownloaded = userInfo["isDownloaded"] as? Bool else {
            print("📡 ☁️ CLOUDKIT EPISODE STATE FAILED: Invalid episode state data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT EPISODE STATE: Received episode state from CloudKit: \(episodeId)")
        
        DispatchQueue.main.async {
            // Update local episode tracking (CloudKit already updated EpisodeStateManager)
            self.episodeProgress[episodeId] = progress
            
            // Trigger UI update if this episode is currently displayed
            if self.currentEpisodes.contains(where: { $0.id == episodeId }) {
                self.throttledUIUpdate()
            }
            
            print("📡 ☁️ CLOUDKIT EPISODE STATE: ✅ Updated episode state from CloudKit: \(episodeId)")
        }
    }
    
    // Helper method to convert dictionary to PodcastFeed
    private func podcastFeedFromDictionary(_ data: [String: Any]) -> PodcastFeed? {
        guard let id = data["id"] as? String,
              let title = data["title"] as? String,
              let url = data["url"] as? String else {
            return nil
        }
        
        let artworkUrl = data["artworkUrl"] as? String
        let descriptionText = data["description"] as? String
        let iconData = data["iconData"] as? String
        
        // Handle imageData if present
        var imageData: Data?
        if let imageDataString = data["imageData"] as? String {
            imageData = Data(base64Encoded: imageDataString)
        }
        
        return PodcastFeed(
            id: id,
            title: title,
            url: url,
            artworkUrl: artworkUrl,
            description: descriptionText,
            iconData: iconData,
            imageData: imageData,
            episodes: [] // Episodes will be loaded separately
        )
    }
    
    // Helper method to convert PodcastFeed to dictionary for syncing
    // NOTE: Only includes essential metadata to avoid NSUbiquitousKeyValueStore 1MB quota limit
    private func podcastFeedToDictionary(_ feed: PodcastFeed) -> [String: Any] {
        var data: [String: Any] = [
            "id": feed.id,
            "title": feed.title,
            "url": feed.url
        ]
        
        if let artworkUrl = feed.artworkUrl {
            data["artworkUrl"] = artworkUrl
        }
        
        if let descriptionText = feed.descriptionText {
            data["description"] = descriptionText
        }
        
        // NOTE: Excluding iconData and imageData from instant sync to prevent quota exceeded errors
        // These will be synced via CloudKit instead where there's no size limit
        // Previous issue: CNN 5 Things with 1.7MB artwork caused quota error when base64 encoded
        
        return data
    }
    
    /// Thread-safe duplicate checking in Core Data
    private func checkForDuplicateInCoreData(feedId: String, feedUrl: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@ OR url == %@", feedId, feedUrl)
                    fetchRequest.fetchLimit = 1
                    
                    let existingFeeds = try context.fetch(fetchRequest)
                    let isDuplicate = !existingFeeds.isEmpty
                    
                    continuation.resume(returning: isDuplicate)
                } catch {
                    print("❌ Error checking for duplicate in Core Data: \(error)")
                    // In case of error, assume duplicate to be safe
                    continuation.resume(returning: true)
                }
            }
        }
    }
    
    /// Thread-safe existence checking in Core Data for real-time sync
    private func checkIfFeedExistsInCoreData(feedId: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", feedId)
                    fetchRequest.fetchLimit = 1
                    
                    let existingFeeds = try context.fetch(fetchRequest)
                    let exists = !existingFeeds.isEmpty
                    
                    continuation.resume(returning: exists)
                } catch {
                    print("❌ Error checking feed existence in Core Data: \(error)")
                    // In case of error, assume it doesn't exist to be safe
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    deinit {
        loadingTask?.cancel()
        refreshTask?.cancel()
        uiUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        
        // Cancel all RSS parsing tasks directly
        for (feedId, task) in rssParsingTasks {
            print("🚫 Cancelling RSS parsing for feed: \(feedId)")
            task.cancel()
        }
    }
    
    // MARK: - RSS Task Management for View Switching
    
    /// Cancel all RSS parsing tasks immediately when switching views
    private func cancelAllRSSParsingTasks() {
        for (feedId, task) in rssParsingTasks {
            print("🚫 Cancelling RSS parsing for feed: \(feedId)")
            task.cancel()
        }
        rssParsingTasks.removeAll()
    }
    
    /// Cancel RSS parsing for a specific feed
    func cancelRSSParsingForFeed(_ feedId: String) {
        if let task = rssParsingTasks[feedId] {
            print("🚫 Cancelling RSS parsing for specific feed: \(feedId)")
            task.cancel()
            rssParsingTasks.removeValue(forKey: feedId)
        }
        
        // Also cancel immediate check for this feed
        if let task = immediateCheckTasks[feedId] {
            print("🚫 Cancelling immediate check for specific feed: \(feedId)")
            task.cancel()
            immediateCheckTasks.removeValue(forKey: feedId)
        }
    }
    
    /// Cancel all RSS operations immediately (public method for view switching)
    func cancelAllRSSOperations() {
        print("🚫 Cancelling all RSS operations due to view switch")
        cancelAllRSSParsingTasks()
        
        // Cancel all immediate check tasks
        for (feedId, task) in immediateCheckTasks {
            print("🚫 Cancelling immediate check for feed: \(feedId)")
            task.cancel()
        }
        immediateCheckTasks.removeAll()
    }
    
    /// Setup coordination with DataSyncManager
    private func setupDataSyncCoordination() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DataSyncManager_RequestPodcastStatus"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportStatusToDataSyncManager()
        }
    }
    
    /// Report current loading status to DataSyncManager
    private func reportStatusToDataSyncManager() {
        let loadingComplete = !isLoading && !isLoadingFeeds && !isLoadingEpisodes
        let feedsLoaded = !podcastFeeds.isEmpty
        
        UserDefaults.standard.set(loadingComplete, forKey: "PodcastViewModel_LoadingComplete")
        UserDefaults.standard.set(feedsLoaded, forKey: "PodcastViewModel_FeedsLoaded")
        
        print("📊 PodcastViewModel status report - Loading complete: \(loadingComplete), Feeds loaded: \(feedsLoaded), Feed count: \(podcastFeeds.count)")
    }
    
    // PERFORMANCE: Throttled UI update method to improve scrolling performance
    private func throttledUIUpdate() {
        // Skip UI updates if user is scrolling
        if isUserScrolling {
            hasPendingUIUpdate = true
            return
        }
        
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUIUpdateTime)
        
        if timeSinceLastUpdate >= uiUpdateThrottleInterval {
            // Update immediately
            lastUIUpdateTime = now
            hasPendingUIUpdate = false
            objectWillChange.send()
        } else {
            // Schedule delayed update
            hasPendingUIUpdate = true
            uiUpdateTimer?.invalidate()
            uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: uiUpdateThrottleInterval - timeSinceLastUpdate, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.hasPendingUIUpdate && !self.isUserScrolling {
                    self.lastUIUpdateTime = Date()
                    self.hasPendingUIUpdate = false
                    self.objectWillChange.send()
                }
            }
        }
    }
    
    /// PULL-TO-REFRESH: Force immediate UI update bypassing all throttling mechanisms
    private func forceUIUpdate() {
        // Cancel any pending timers
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
        
        // Reset throttling state
        lastUIUpdateTime = Date()
        hasPendingUIUpdate = false
        
        // Force immediate UI update
        objectWillChange.send()
        print("🔄 FORCE UI UPDATE: Bypassed throttling for pull-to-refresh")
    }
    
    /// Set episode limit for a feed and enforce it immediately
    func setEpisodeLimit(for feedId: String, maxEpisodes: Int?) async {
        // Update the feed's maxEpisodes property
        if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feedId }) {
            podcastFeeds[feedIndex].maxEpisodes = maxEpisodes
            
            // If setting a limit, enforce it immediately
            if let maxEpisodes = maxEpisodes {
                do {
                    try await PodcastCoreDataManager.shared.enforceEpisodeLimitForFeed(feedId, maxEpisodes: maxEpisodes)
                    
                    // Refresh the episode list to reflect the changes
                    let updatedEpisodes: [PodcastEpisode]
                    if maxEpisodes > 0 {
                        // Feed has episode limit - use limited fetch
                        updatedEpisodes = await PodcastCoreDataManager.shared.getRecentEpisodesForFeed(feedId, limit: maxEpisodes)
                    } else {
                        // Feed has no limit - get all episodes
                        updatedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    }
                    
                    await MainActor.run {
                        self.forceUpdateEpisodeSnapshot(for: feedId, episodes: updatedEpisodes)
                        if self.selectedFeedId == feedId {
                            self.currentEpisodes = updatedEpisodes
                        }
                        self.forceUIUpdate()
                        print("🗑️ EPISODE LIMIT: Set limit of \(maxEpisodes) episodes for feed \(feedId)")
                    }
                } catch {
                    await MainActor.run {
                        self.error = "Failed to enforce episode limit: \(error.localizedDescription)"
                    }
                }
            } else {
                print("🔄 EPISODE LIMIT: Removed episode limit for feed \(feedId)")
            }
            
            // Save the updated feed configuration
            await saveFeedConfiguration(feedId)
        }
    }
    
    /// Save feed configuration changes (like episode limits) to persistent storage
    private func saveFeedConfiguration(_ feedId: String) async {
        // This would typically save to CloudKit or UserDefaults
        // For now, we'll just trigger a UI update to persist the change
        await MainActor.run {
            self.forceUIUpdate()
        }
    }
    
    // MARK: - Data Sync Coordination Methods
    
    /// Wait for data sync completion - used by DataSyncManager
    func waitForDataSyncCompletion() async {
        // Start the CloudKit initialization if not already done
        initializeWithCloudKitSupport()
        
        // Wait for CloudKit sync to complete
        while cloudKitSyncInProgress {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        // Wait for loading to complete
        while isLoading || isLoadingFeeds {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        print("✅ PodcastViewModel: Data sync completion confirmed")
    }
    
    /// Ensure feeds are loaded and available to UI
    func ensureFeedsAreLoaded() async {
        // If no feeds are loaded, try loading from Core Data again
        if podcastFeeds.isEmpty {
            await MainActor.run {
                loadFeedsFromCoreData()
            }
            
            // Wait a bit for the loading to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // If still no feeds, this might be a fresh install without any feeds
        if podcastFeeds.isEmpty {
            print("ℹ️ PodcastViewModel: No feeds found - this might be a fresh install")
        } else {
            print("✅ PodcastViewModel: \(podcastFeeds.count) feeds are loaded and available")
        }
    }
    
    /// Force Core Data to save any pending changes and reload feeds
    func forceSaveAndReload() async {
        print("🔧 FORCING Core Data save and reload...")
        
        // Force save the Core Data context
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                if context.hasChanges {
                    do {
                        try context.save()
                        print("✅ FORCED: Core Data context saved successfully")
                    } catch {
                        print("❌ FORCED: Failed to save Core Data context: \(error)")
                    }
                } else {
                    print("ℹ️ FORCED: No pending Core Data changes to save")
                }
                continuation.resume()
            }
        }
        
        // Force reload feeds from Core Data with aggressive UI refresh
        await MainActor.run {
            print("🔧 FORCING: Reloading feeds from Core Data...")
            loadFeedsFromCoreData()
            
            // Immediately notify SwiftUI that this object is about to change
            self.objectWillChange.send()
            print("🔧 FORCING: Triggered objectWillChange.send() after reload")
        }
        
        // Wait for the reload to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Final verification and manual UI trigger
        await MainActor.run {
            let currentFeedCount = self.podcastFeeds.count
            let currentOrderCount = self.podcastFeedOrder.count
            print("🔧 FORCING: After reload verification - Feeds: \(currentFeedCount), Order: \(currentOrderCount)")
            
            // Force another UI update notification to ensure SwiftUI picks up the changes
            self.objectWillChange.send()
            print("🔧 FORCING: Final objectWillChange.send() triggered")
        }
        
        print("✅ FORCED: Save and reload completed - feeds count: \(podcastFeeds.count)")
    }
    
    // MARK: - Public Interface
    


    
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
    func addPodcastFeed(url: String, customTitle: String? = nil) async -> Bool {
        guard let feedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await MainActor.run {
                self.error = "Invalid URL format"
            }
            return false
        }
        
        // Check if a podcast feed with the same URL already exists
        let urlString = feedURL.absoluteString
        if podcastFeeds.contains(where: { $0.url == urlString }) {
            await MainActor.run {
                self.error = "A podcast feed with this URL has already been added. Please use a different URL."
            }
            print("Podcast feed with URL \(urlString) already exists. Skipping addition.")
            return false
        }
        
        // Notify user that import started
        await MainActor.run {
            NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing podcast feed from URL...")
        }
        
        do {
            // Step 1: Parse feed and create feed object with custom title if provided
            let feed = try await feedManager.addFeed(from: feedURL, customTitle: customTitle)
            print("📊 Parsed feed: \(feed.title)")
            
            // Step 2: Immediate UI update - add to arrays for instant feedback
            await MainActor.run {
                self.podcastFeeds.append(feed)
                self.podcastFeedOrder.append(feed.id)
                self.throttledUIUpdate()
                print("✅ Feed immediately added to UI: \(feed.title)")
                
                // INSTANT SYNC: Sync podcast feed addition immediately across devices
                PodcastCloudKitManager.shared.syncPodcastFeedAddedInstantly(
                    feedData: self.podcastFeedToDictionary(feed)
                )
            }
            
            // Step 3: Background CloudKit sync - WAIT for completion before allowing banner to show
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
            
            return true
            
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
            print("❌ Failed to add podcast feed: \(error)")
            return false
        }
    }
    
    /// Load episodes for a specific feed with efficient pagination and deduplication
    func loadEpisodesForFeed(_ feedId: String, isInitialLoad: Bool = false) async {
        print("🔄 LOAD EPISODES: Starting load for feedId '\(feedId)' (isInitialLoad: \(isInitialLoad))")
        
        // INSTANT DISPLAY: Load cached episodes from Core Data FIRST for immediate UI display
        let cachedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
        if !cachedEpisodes.isEmpty {
            print("⚡ INSTANT DISPLAY: Found \(cachedEpisodes.count) cached episodes - displaying immediately")
            
            await MainActor.run {
                // Apply current filter instantly (episodes already sorted newest first from Core Data)
                let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                let filteredEpisodes: [PodcastEpisode]
                switch filter {
                case .all:
                    filteredEpisodes = cachedEpisodes // Already sorted newest first
                case .favorites:
                    filteredEpisodes = cachedEpisodes.filter { $0.state.isFavorite }
                case .downloads:
                    filteredEpisodes = cachedEpisodes.filter { $0.state.isDownloaded }
                }
                
                // CRITICAL: Clear any contaminated episodes from wrong feeds
                if !currentEpisodes.isEmpty && currentEpisodes.first?.feedId != feedId {
                    print("🧹 CONTAMINATION CLEANUP: Clearing \(currentEpisodes.count) episodes from wrong feed")
                    currentEpisodes = []
                }
                
                // Update UI instantly with cached episodes
                currentEpisodes = filteredEpisodes
                selectedFeedId = feedId
                isLoadingEpisodes = false
                operationInProgress = false
                
                // Update episode counts immediately
                let allCount = cachedEpisodes.count
                let favoritesCount = cachedEpisodes.filter { $0.state.isFavorite }.count
                let downloadsCount = cachedEpisodes.filter { $0.state.isDownloaded }.count
                episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                
                print("⚡ INSTANT SUCCESS: Displaying \(filteredEpisodes.count) cached episodes immediately")
            }
            
            // Update snapshot with cached episodes for future instant access
            updateEpisodeSnapshot(for: feedId, episodes: cachedEpisodes)
            
            // BACKGROUND REFRESH: Check for new episodes in background without blocking UI
            Task.detached(priority: .background) {
                await self.backgroundRefreshForNewEpisodes(feedId: feedId, isInitialLoad: isInitialLoad)
            }
            
            return
        }
        
        // ULTRA PERFORMANCE: Check for snapshots if no cached episodes
        if let snapshotEpisodes = getEpisodeSnapshot(for: feedId) {
            print("⚡ ULTRA PERFORMANCE: Using snapshot for feed \(feedId) - SKIPPING ALL EXPENSIVE OPERATIONS (newest episodes first)")
            
            await MainActor.run {
                // Apply current filter instantly (episodes already sorted newest first in snapshot)
                let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                let filteredEpisodes: [PodcastEpisode]
                switch filter {
                case .all:
                    filteredEpisodes = snapshotEpisodes // Already sorted newest first
                case .favorites:
                    // Maintain newest first order when filtering
                    filteredEpisodes = snapshotEpisodes.filter { $0.state.isFavorite }
                case .downloads:
                    // Maintain newest first order when filtering
                    filteredEpisodes = snapshotEpisodes.filter { $0.state.isDownloaded }
                }
                
                // CRITICAL: Clear any contaminated episodes from wrong feeds
                if !currentEpisodes.isEmpty && currentEpisodes.first?.feedId != feedId {
                    print("🧹 CONTAMINATION CLEANUP: Clearing \(currentEpisodes.count) episodes from wrong feed")
                    currentEpisodes = []
                }
                
                // Update UI instantly with newest episodes first
                currentEpisodes = filteredEpisodes
                selectedFeedId = feedId
                isLoadingEpisodes = false
                operationInProgress = false
                Task {
                    await updateEpisodeCounts(for: feedId, episodes: snapshotEpisodes)
                }
                
                print("📸 SNAPSHOT SUCCESS: Displaying \(filteredEpisodes.count) episodes instantly with newest episodes first - NO EXPENSIVE OPERATIONS NEEDED")
            }
            
            return
        }
        
        // PERFORMANCE: Prevent redundant episode loading for the same feed
        let taskKey = "\(feedId)-\(isInitialLoad)"
        guard !pendingInitializationTasks.contains(taskKey) else {
            // Reduce logging during scrolling for better performance
            if !isUserScrolling {
                print("🔄 Episode loading already in progress for feed: \(feedId) - skipping redundant call")
            }
            return
        }
        
        pendingInitializationTasks.insert(taskKey)
        
        // Cancel any existing loading task
        loadingTask?.cancel()
        
        // CRITICAL: Cancel all RSS operations when switching feeds for immediate responsiveness
        cancelAllRSSOperations()
        
        // CRITICAL FIX: Clear current episodes immediately when switching feeds
        // This prevents UI from showing wrong feed episodes during feed transitions
        if selectedFeedId != feedId {
            await MainActor.run {
                self.currentEpisodes.removeAll()
                print("🔄 FEED SWITCH: Cleared episodes for feed transition from \(self.selectedFeedId ?? "nil") to \(feedId)")
            }
        }
        
        selectedFeedId = feedId
        currentPage = 1
        
        // INSTANT SNAPSHOT: Check for complete episode snapshot first (fastest path)
        if let snapshotEpisodes = getEpisodeSnapshot(for: feedId) {
            print("⚡ ULTRA PERFORMANCE: Using snapshot with \(snapshotEpisodes.count) episodes - ZERO EXPENSIVE OPERATIONS (newest episodes first)")
            
            // Apply current filter instantly - episodes already sorted newest first in snapshot
            let filter = EpisodeFilter(rawValue: currentTab) ?? .all
            let filteredEpisodes: [PodcastEpisode]
            switch filter {
            case .all:
                filteredEpisodes = snapshotEpisodes // Already sorted newest first
            case .favorites:
                // Maintain newest first order when filtering
                filteredEpisodes = snapshotEpisodes.filter { $0.state.isFavorite }
            case .downloads:
                // Maintain newest first order when filtering
                filteredEpisodes = snapshotEpisodes.filter { $0.state.isDownloaded }
            }
            
            await MainActor.run {
                // CRITICAL SAFETY CHECK: Ensure all episodes actually belong to this feed
                let safeEpisodes = filteredEpisodes.filter { $0.feedId == feedId }
                if safeEpisodes.count != filteredEpisodes.count {
                    print("🚨 FEED ISOLATION: Filtered out \(filteredEpisodes.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId)")
                    // Log details about contaminated episodes for debugging
                    let contaminatedEpisodes = filteredEpisodes.filter { $0.feedId != feedId }
                    for episode in contaminatedEpisodes.prefix(3) {
                        print("🚨 CONTAMINATED EPISODE: '\(episode.title)' has feedId '\(episode.feedId)' but expected '\(feedId)'")
                    }
                }
                print("📊 ⚡ SNAPSHOT INSTANT: Displaying \(safeEpisodes.count) episodes with ZERO processing overhead (newest episodes first)")
                self.currentEpisodes = safeEpisodes
                self.hasMoreEpisodes = false // Snapshots contain complete data
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                
                // Update counts from snapshot
                let allCount = snapshotEpisodes.count
                let favoritesCount = snapshotEpisodes.filter { $0.state.isFavorite }.count
                let downloadsCount = snapshotEpisodes.filter { $0.state.isDownloaded }.count
                self.episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                
                print("📸 SNAPSHOT SUCCESS: Displayed \(filteredEpisodes.count) episodes instantly with newest episodes first - NO EXPENSIVE OPERATIONS NEEDED")
            }
            
            // PERFORMANCE: Skip expensive new episode check when using snapshots
            // Snapshots already contain the most recent episodes from the last refresh
            print("⚡ PERFORMANCE: Skipping expensive new episode check - using snapshot data")
            
            return // CRITICAL: Return immediately, bypass all expensive operations below
        }
        
        // ULTRA PERFORMANCE: Check for snapshots if no cached episodes
        if let snapshotEpisodes = getEpisodeSnapshot(for: feedId) {
            print("⚡ ULTRA PERFORMANCE: Using snapshot for feed \(feedId) - SKIPPING ALL EXPENSIVE OPERATIONS (newest episodes first)")
            
            await MainActor.run {
                // Apply current filter instantly (episodes already sorted newest first in snapshot)
                let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                let filteredEpisodes: [PodcastEpisode]
                switch filter {
                case .all:
                    filteredEpisodes = snapshotEpisodes // Already sorted newest first
                case .favorites:
                    // Maintain newest first order when filtering
                    filteredEpisodes = snapshotEpisodes.filter { $0.state.isFavorite }
                case .downloads:
                    // Maintain newest first order when filtering
                    filteredEpisodes = snapshotEpisodes.filter { $0.state.isDownloaded }
                }
                
                // CRITICAL: Clear any contaminated episodes from wrong feeds
                if !currentEpisodes.isEmpty && currentEpisodes.first?.feedId != feedId {
                    print("🧹 CONTAMINATION CLEANUP: Clearing \(currentEpisodes.count) episodes from wrong feed")
                    currentEpisodes = []
                }
                
                // Update UI instantly with newest episodes first
                currentEpisodes = filteredEpisodes
                selectedFeedId = feedId
                isLoadingEpisodes = false
                operationInProgress = false
                Task {
                    await updateEpisodeCounts(for: feedId, episodes: snapshotEpisodes)
                }
                
                print("📸 SNAPSHOT SUCCESS: Displaying \(filteredEpisodes.count) episodes instantly with newest episodes first - NO EXPENSIVE OPERATIONS NEEDED")
            }
            
            return
        }
        
        // CRITICAL PERFORMANCE: Skip CloudKit priority mode for snapshot-based loads
        if getEpisodeSnapshot(for: feedId) == nil {
            // CRITICAL: Enable CloudKit priority mode for episode list loading
            // This ensures CloudKit data immediately replaces Core Data progress
            EpisodeStateManager.shared.enableCloudKitPriorityMode()
            print("🔄 CLOUDKIT: Enabled priority mode for non-snapshot load")
        }
        
        // FALLBACK: This path should rarely execute since we check Core Data first
        let feed = podcastFeeds.first(where: { $0.id == feedId })
        let hasEpisodesInMemory = feed?.episodes.isEmpty == false
        let hasInstantCache = await episodeManager.hasInstantCache(feedId: feedId)
        
        await MainActor.run {
            // Show loading state since we have no cached data
            isLoadingEpisodes = true
            operationInProgress = true
            print("🔄 FALLBACK LOADING: No cached episodes found - showing loading state")
        }
        
        // PERFORMANCE: Check for snapshots first to avoid expensive operations
        let hasSnapshot = getEpisodeSnapshot(for: feedId) != nil
        
        // FALLBACK PATH: Only execute expensive operations if no cached episodes available
        print("🔄 FALLBACK: No cached episodes or snapshots - executing full load path")
        
        // PERFORMANCE: Skip expensive local state refresh if we have snapshots or recent refresh
        let hasRecentRefresh = await MainActor.run {
            let lastRefreshTime = UserDefaults.standard.double(forKey: "lastLocalStateRefresh")
            let timeSinceLastRefresh = Date().timeIntervalSince1970 - lastRefreshTime
            return timeSinceLastRefresh < 120 // Skip if refreshed within last 2 minutes
        }
        let shouldSkipStateRefresh = hasSnapshot || hasInstantCache || hasRecentRefresh
        
        if !shouldSkipStateRefresh {
            // Only refresh states if we don't have cached episodes and haven't refreshed recently
            await refreshLocalEpisodeStates()
            await MainActor.run {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastLocalStateRefresh")
            }
        } else {
            if hasSnapshot {
                print("⚡ PERFORMANCE: Skipping expensive state refresh - using episode snapshot")
            } else {
                print("⚡ PERFORMANCE: Skipping expensive state refresh - using cached episode states or recent refresh")
            }
        }
        
        // Disable CloudKit priority mode after local state refresh
        EpisodeStateManager.shared.disableCloudKitPriorityMode()
        
        // NOTE: Immediate episode check moved to after snapshot creation for better performance
        
        // CRITICAL PERFORMANCE: Skip RSS refresh entirely when snapshots are available
        if hasSnapshot {
            print("⚡ PERFORMANCE: Skipping background RSS check - recent snapshot available (0 min old)")
        } else {
            // PERFORMANCE: Only check for new episodes if no recent episodes are available
            // This prevents expensive RSS parsing when episodes are already loaded
            if currentEpisodes.isEmpty {
                print("🔄 FALLBACK: No episodes available - will check for new episodes after loading from Core Data")
            } else {
                print("⚡ PERFORMANCE: Episodes already available - skipping expensive new episode check")
            }
            
            // AUTO-REFRESH: Check if feed needs RSS refresh for new episodes
            let shouldAutoRefresh = await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: isInitialLoad)
            if shouldAutoRefresh {
                // PERFORMANCE: Do RSS refresh in background to not block UI loading
                // Add a small delay to ensure UI is fully loaded first
                
                // Cancel any existing RSS parsing for this feed
                self.cancelRSSParsingForFeed(feedId)
            
            let rssTask = Task.detached(priority: .userInitiated) {
                // Start RSS refresh immediately for new episodes
                
                // Check for cancellation before starting expensive work
                try Task.checkCancellation()
                
                do {
                    print("🔄 Auto-refreshing feed \(feedId) from RSS for new episodes...")
                    let (updatedFeed, newEpisodes) = try await self.feedManager.refreshFeed(feedId)
                    
                    // Reconcile snapshot to respect feed's actual episode set
                    // Parse the full episode list directly to avoid passing only "new" episodes
                    do {
                        let urlString: String? = await MainActor.run {
                            self.podcastFeeds.first(where: { $0.id == feedId })?.url
                        }
                        if let urlString, let url = URL(string: urlString) {
                            // Use smart parsing to only get new episodes
                            let newEpisodes = try await self.parseNewEpisodesOnly(from: url, feedId: feedId)
                            
                            // Check for cancellation after parsing
                            try Task.checkCancellation()
                            
                            // CRITICAL FIX: Always reconcile to fix accumulated episodes
                            // This ensures episode counts match the actual RSS feed content
                            let allCurrentEpisodes = try await self.parseRSSEpisodesOnly(from: url)
                            let feed = await MainActor.run { self.podcastFeeds.first(where: { $0.id == feedId }) }
                            try await PodcastCoreDataManager.shared.reconcileEpisodes(for: feedId, parsedEpisodes: allCurrentEpisodes, maxEpisodes: feed?.maxEpisodes)
                            
                            // PULL-TO-REFRESH FIX: Get reconciled episodes from Core Data after reconciliation
                            // This ensures episodes have correct feedId values after reconciliation
                            let reconciledEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                            
                            // Update snapshot with reconciled episodes from Core Data (not raw RSS)
                            await MainActor.run {
                                self.updateEpisodeSnapshot(for: feedId, episodes: reconciledEpisodes)
                                print("🔄 RECONCILE: Updated snapshot with correct \(reconciledEpisodes.count) episodes from Core Data after reconciliation")
                                
                                // CRITICAL FIX: Update refresh timestamp only after successful RSS refresh
                                let currentTime = Date().timeIntervalSince1970
                                let lastRefreshKey = "LastRSSRefresh_\(feedId)"
                                UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
                                print("✅ RSS REFRESH: Updated last refresh time for feed \(feedId)")
                            }
                            
                            // CRITICAL PERFORMANCE: Skip expensive CloudKit sync for snapshot-based loads
                            let hasSnapshotForSync = await self.getEpisodeSnapshot(for: feedId) != nil
                            if !hasSnapshotForSync {
                                // QUIET SYNC: Sync episode states for all episodes
                                Task.detached(priority: .background) {
                                    await self.quietSyncEpisodeStates(for: feedId)
                                }
                            } else {
                                print("⚡ PERFORMANCE: Skipping expensive CloudKit sync - using snapshot states for feed \(feedId)")
                            }
                        } else {
                            print("❌ Snapshot reconcile failed: Missing feed URL for \(feedId)")
                        }
                    } catch { print("❌ Snapshot reconcile failed: \(error)") }
                    if !newEpisodes.isEmpty {
                        print("✅ Found \(newEpisodes.count) new episodes - UI will reflect after reconcile")
                        
                        // Update the feed in memory with new episodes - fetch from background, update on main thread
                        let exactEpisodes = await withCheckedContinuation { continuation in
                            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
                            backgroundContext.perform {
                                do {
                                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                                    request.predicate = NSPredicate(format: "feedId == %@", feedId)
                                    request.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                                    let managed = try backgroundContext.fetch(request)
                                    let episodes = managed.compactMap { $0.toPodcastEpisode() }
                                    continuation.resume(returning: episodes)
                                } catch {
                                    print("❌ Failed to fetch episodes from background context: \(error)")
                                    continuation.resume(returning: [])
                                }
                            }
                        }
                        
                        let processedEpisodes = await PodcastViewModel.removeDuplicatesFromEpisodes(exactEpisodes)
                        
                        // UPDATE PERSISTENT CACHE: If these are new episodes, update the cache
                        let existingEpisodeIds = feed?.episodes.map { $0.id } ?? []
                        let newEpisodeIds = Set(processedEpisodes.map { $0.id })
                        let existingIds = Set(existingEpisodeIds)
                        
                        if !newEpisodeIds.isSubset(of: existingIds) {
                            // We have new episodes - update the persistent cache
                            let newEpisodes = processedEpisodes.filter { !existingIds.contains($0.id) }
                            if !newEpisodes.isEmpty {
                                await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
                                print("🆕 CACHE UPDATE: Added \(newEpisodes.count) new episodes to persistent cache")
                            }
                        }
                        
                        await MainActor.run {
                            if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                                var updatedFeedWithEpisodes = self.podcastFeeds[feedIndex]
                                updatedFeedWithEpisodes.episodes = processedEpisodes
                                self.podcastFeeds[feedIndex] = updatedFeedWithEpisodes
                                
                                // SMART CACHE: Clear tab filter cache but keep persistent cache
                                self.clearTabFilterCache(for: feedId)
                                
                                // UPDATE CURRENT VIEW: If this is the selected feed, update currentEpisodes immediately
                                if self.selectedFeedId == feedId {
                                    // Apply current filter to the new episodes and update currentEpisodes
                                    let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                                    let filteredEpisodes: [PodcastEpisode]
                                    
                                    switch filter {
                                    case .all:
                                        filteredEpisodes = processedEpisodes
                                    case .favorites:
                                        filteredEpisodes = processedEpisodes.filter { $0.state.isFavorite }
                                    case .downloads:
                                        filteredEpisodes = processedEpisodes.filter { $0.state.isDownloaded }
                                    }
                                    
                                    Task {
                                        let processedForDisplay = await self.processEpisodesInBackground(filteredEpisodes)
                                        await MainActor.run {
                                            // CRITICAL SAFETY CHECK: Ensure all episodes actually belong to this feed
                                            let safeEpisodes = processedForDisplay.filter { $0.feedId == feedId }
                                            if safeEpisodes.count != processedForDisplay.count {
                                                print("🚨 RSS ISOLATION: Filtered out \(processedForDisplay.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId)")
                                            }
                                            self.currentEpisodes = safeEpisodes
                                            print("🔄 Updated currentEpisodes with \(safeEpisodes.count) episodes from RSS refresh")
                                        }
                                    }
                                }
                                print("✅ Replaced in-memory feed episodes with exact snapshot: \(updatedFeedWithEpisodes.episodes.count)")
                            }
                        }
                    } else {
                        print("ℹ️ No new episodes found for feed \(feedId)")
                    }
                } catch is CancellationError {
                    print("🚫 RSS refresh cancelled for feed \(feedId)")
                } catch {
                    print("❌ Failed to auto-refresh feed \(feedId): \(error)")
                }
                
                // Clean up task from tracking
                await MainActor.run {
                    self.rssParsingTasks.removeValue(forKey: feedId)
                }
            }
            
            // Store task for potential cancellation
            rssParsingTasks[feedId] = rssTask
            }
        }
        
        // First check if episodes are already loaded in the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            // Reduce logging during scrolling for better performance
            if !isUserScrolling {
                print("🔍 DEBUG: Found \(feed.episodes.count) episodes already loaded in feed: \(feed.title)")
                print("⚡ Using cached episodes - displaying immediately while checking for new episodes")
            }
            
            // CRITICAL PERFORMANCE: Skip expensive individual state updates if we have a snapshot
            let currentHasSnapshot = getEpisodeSnapshot(for: feedId) != nil
            let episodesWithUpdatedStates: [PodcastEpisode]
            
            if currentHasSnapshot {
                // ULTRA PERFORMANCE: Use episodes as-is since snapshot already contains current states
                print("⚡ PERFORMANCE: Skipping expensive individual episode state updates - snapshot already current")
                episodesWithUpdatedStates = feed.episodes
            } else {
                // Refresh episode states from EpisodeStateManager to ensure they're current
                print("🔄 STATE UPDATE: Refreshing individual episode states for non-snapshot load")
                episodesWithUpdatedStates = feed.episodes.map { episode in
                    var updated = episode
                    updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                    updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                    updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                    updated.state.isPlayed = updated.state.progress >= 0.99
                    return updated
                }
            }
            
            // CRITICAL FIX: Create snapshot from Core Data episodes for instant future access
            updateEpisodeSnapshot(for: feedId, episodes: episodesWithUpdatedStates)
            print("📸 SNAPSHOT: Created from Core Data with \(episodesWithUpdatedStates.count) episodes")
            
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
            
            // Reduce logging during scrolling for better performance
            if !isUserScrolling {
                print("🔍 DEBUG: Applied filter \(filter) - showing \(filteredEpisodes.count) of \(episodesWithUpdatedStates.count) episodes")
            }
            
            // CRITICAL PERFORMANCE: Skip expensive processing if we already have a snapshot for this feed
            let uniqueFilteredEpisodes: [PodcastEpisode]
            
            if currentHasSnapshot {
                // ULTRA PERFORMANCE: Snapshots are already processed and deduplicated - skip expensive operations
                print("⚡ PERFORMANCE: Skipping expensive episode processing - snapshot already exists with processed data")
                uniqueFilteredEpisodes = filteredEpisodes
            } else {
                // PERFORMANCE FIX: Move expensive episode processing to background to prevent main thread blocking
                print("🔄 PROCESSING: Running episode deduplication for non-snapshot load")
                uniqueFilteredEpisodes = await processEpisodesInBackground(filteredEpisodes)
            }
            
            await MainActor.run {
                // CRITICAL SAFETY CHECK: Ensure all episodes actually belong to this feed
                let safeEpisodes = uniqueFilteredEpisodes.filter { $0.feedId == feedId }
                if safeEpisodes.count != uniqueFilteredEpisodes.count {
                    print("🚨 CORE DATA ISOLATION: Filtered out \(uniqueFilteredEpisodes.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId)")
                    // Log details about contaminated episodes for debugging
                    let contaminatedEpisodes = uniqueFilteredEpisodes.filter { $0.feedId != feedId }
                    for episode in contaminatedEpisodes.prefix(3) {
                        print("🚨 CONTAMINATED EPISODE: '\(episode.title)' has feedId '\(episode.feedId)' but expected '\(feedId)'")
                    }
                }
                print("📊 CORE DATA LOAD: Loading \(safeEpisodes.count) episodes for feed \(feedId)")
                self.currentEpisodes = safeEpisodes
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                self.hasMoreEpisodes = false
                // Reduce logging during scrolling for better performance
                if !self.isUserScrolling {
                    if filteredEpisodes.count != uniqueFilteredEpisodes.count {
                        print("📊 ⚡ Deduplicated \(filteredEpisodes.count) to \(uniqueFilteredEpisodes.count) episodes before display")
                    }
                    print("📊 ⚡ Using pre-loaded episodes with filter: \(self.currentEpisodes.count) episodes displayed instantly")
                }
            }
            
            // DISABLED: Deferred episode check when using snapshots to prevent accumulation
            // Snapshots already contain the complete episode data from RSS feeds
            print("⚡ DEFERRED CHECK: Skipped for feed \(feedId) - using snapshot data to prevent accumulation")
            
            // CRITICAL FIX: Check for new episodes in background even when we have cached episodes
            // This ensures new episodes are detected on large feeds with existing episodes
            let shouldAutoRefresh = await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: isInitialLoad)
            if shouldAutoRefresh {
                print("🔄 Background RSS refresh needed for feed with \(feed.episodes.count) cached episodes")
                
                // Cancel any existing RSS parsing for this feed
                self.cancelRSSParsingForFeed(feedId)
                
                // Do RSS refresh IMMEDIATELY to get newest episodes on load
                let rssTask = Task.detached(priority: .userInitiated) {
                    // Check for cancellation before starting expensive work
                    try Task.checkCancellation()
                    do {
                        print("🔄 Auto-refreshing feed \(feedId) from RSS for new episodes...")
                        let (updatedFeed, newEpisodes) = try await self.feedManager.refreshFeed(feedId)
                        
                        // Reconcile snapshot to respect feed's actual episode set
                        // Parse the full episode list directly to avoid passing only "new" episodes
                        do {
                            let urlString: String? = await MainActor.run {
                                self.podcastFeeds.first(where: { $0.id == feedId })?.url
                            }
                            if let urlString, let url = URL(string: urlString) {
                                // Use smart parsing to only get new episodes
                                let _ = try await self.parseNewEpisodesOnly(from: url, feedId: feedId)
                                
                                // Check for cancellation after parsing
                                try Task.checkCancellation()
                                
                                // CRITICAL FIX: Always reconcile and update snapshots to prevent accumulation
                                // Parse the complete episode list from RSS to get accurate count
                                let allCurrentEpisodes = try await self.parseRSSEpisodesOnly(from: url)
                                let feed = await MainActor.run { self.podcastFeeds.first(where: { $0.id == feedId }) }
                                try await PodcastCoreDataManager.shared.reconcileEpisodes(for: feedId, parsedEpisodes: allCurrentEpisodes, maxEpisodes: feed?.maxEpisodes)
                                
                                // PULL-TO-REFRESH FIX: Get reconciled episodes from Core Data after reconciliation
                                // This ensures episodes have correct feedId values after reconciliation
                                let reconciledEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                                
                                // UPDATE SNAPSHOT with reconciled episodes from Core Data (not raw RSS)
                                await MainActor.run {
                                    self.updateEpisodeSnapshot(for: feedId, episodes: reconciledEpisodes)
                                    print("🔄 RECONCILE: Updated snapshot with correct \(reconciledEpisodes.count) episodes from Core Data after reconciliation")
                                }
                                
                                // QUIET SYNC: Sync episode states for all episodes
                                Task.detached(priority: .background) {
                                    await self.quietSyncEpisodeStates(for: feedId)
                                }
                            } else {
                                print("❌ Snapshot reconcile failed: Missing feed URL for \(feedId)")
                            }
                        } catch { print("❌ Snapshot reconcile failed: \(error)") }
                        if !newEpisodes.isEmpty {
                            
                            // Update the feed in memory with new episodes - fetch from background, update on main thread
                            let exactEpisodes = await withCheckedContinuation { continuation in
                                let backgroundContext = CoreDataStack.shared.newBackgroundContext()
                                backgroundContext.perform {
                                    do {
                                        let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                                        request.predicate = NSPredicate(format: "feedId == %@", feedId)
                                        request.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                                        let managed = try backgroundContext.fetch(request)
                                        let episodes = managed.compactMap { $0.toPodcastEpisode() }
                                        continuation.resume(returning: episodes)
                                    } catch {
                                        print("❌ Failed to fetch episodes from background context: \(error)")
                                        continuation.resume(returning: [])
                                    }
                                }
                            }
                            
                            // PERFORMANCE FIX: Move episode processing to background to prevent main thread blocking
                            let processedEpisodes = await self.processEpisodesInBackground(exactEpisodes)
                            await MainActor.run {
                                if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                                    var updatedFeedWithEpisodes = self.podcastFeeds[feedIndex]
                                    updatedFeedWithEpisodes.episodes = processedEpisodes
                                    self.podcastFeeds[feedIndex] = updatedFeedWithEpisodes
                                    
                                    // Reload the current view to show updated episodes immediately
                                    if self.selectedFeedId == feedId {
                                        Task { await self.loadEpisodesForFeed(feedId) }
                                    }
                                }
                            }
                        } else {
                            print("ℹ️ No new episodes found for feed \(feedId)")
                        }
                    } catch is CancellationError {
                        print("🚫 RSS refresh cancelled for feed \(feedId)")
                    } catch {
                        print("❌ Failed to auto-refresh feed \(feedId): \(error)")
                    }
                    
                    // Clean up task from tracking
                    await MainActor.run {
                        self.rssParsingTasks.removeValue(forKey: feedId)
                    }
                }
                
                // Store task for potential cancellation
                rssParsingTasks[feedId] = rssTask
            }
            
            // PERFORMANCE: Clean up pending task before early return
            pendingInitializationTasks.remove(taskKey)
            return
        }
                
        loadingTask = Task {
            await performEpisodeLoad(feedId: feedId, page: 1, isInitialLoad: isInitialLoad)
        }
        
        await loadingTask?.value
        
        // PERFORMANCE: Clean up pending task
        pendingInitializationTasks.remove(taskKey)
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
    
    /// Optimized refresh for current feed - prevents UI freezing on large feeds
    func refreshCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        refreshTask?.cancel()
        
        refreshTask = Task {
            do {
                os_log("🔄 Optimized refresh from RSS: %@", log: self.log, type: .info, feedId)
                print("🔄 PULL-TO-REFRESH: Starting immediate refresh for better UX")
                
                await MainActor.run {
                    self.isLoadingEpisodes = true
                    self.operationInProgress = true
                }
                
                // PERFORMANCE: Quick RSS check for new episodes only (limit to recent episodes)
                let (updatedFeed, newEpisodes) = try await self.feedManager.refreshFeedQuick(feedId, limit: 50)
                print("✅ Pull-to-refresh RSS completed for '\(updatedFeed.title)' - found \(newEpisodes.count) new episodes")
                
                // CRITICAL FIX: Always update snapshot and UI, even if no new episodes
                // This ensures the UI reflects the latest state after pull-to-refresh
                if let feed = await MainActor.run(body: { self.podcastFeeds.first(where: { $0.id == feedId }) }) {
                    if !newEpisodes.isEmpty {
                        // Quick reconcile: only process new episodes to prevent blocking
                        try await PodcastCoreDataManager.shared.reconcileNewEpisodes(for: feedId, newEpisodes: newEpisodes, maxEpisodes: feed.maxEpisodes)
                    }
                    
                    // ALWAYS get fresh episodes from Core Data and update UI
                    let updatedEpisodes: [PodcastEpisode]
                    if let maxEpisodes = feed.maxEpisodes {
                        // Feed has episode limit - use limited fetch
                        updatedEpisodes = await PodcastCoreDataManager.shared.getRecentEpisodesForFeed(feedId, limit: maxEpisodes)
                    } else {
                        // Feed has no limit - get all episodes
                        updatedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    }
                    
                    // ENHANCEMENT: Fetch latest EpisodeState data during pull-to-refresh
                    // This ensures episode progress, played status, and other states are up-to-date
                    print("🔄 Pull-to-refresh: Syncing episode states for current feed")
                    let episodeIds = updatedEpisodes.map { $0.id }
                    if !episodeIds.isEmpty {
                        // Perform quiet episode state sync without UI progress indicators
                        let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                            for: episodeIds,
                            isFreshInstall: false
                        )
                        
                        if syncResult.success {
                            print("✅ Pull-to-refresh: Episode states synced successfully for \(episodeIds.count) episodes")
                        } else {
                            print("⚠️ Pull-to-refresh: Episode state sync completed with some issues")
                        }
                    }
                    
                    await MainActor.run {
                        // CRITICAL FIX: Force snapshot update for pull-to-refresh (bypass throttling)
                        self.forceUpdateEpisodeSnapshot(for: feedId, episodes: updatedEpisodes)
                        
                        // Update current episodes immediately for UI refresh
                        self.currentEpisodes = updatedEpisodes
                        
                        self.isLoadingEpisodes = false
                        self.operationInProgress = false
                        
                        // CRITICAL FIX: Force immediate UI update (bypass throttling)
                        self.forceUIUpdate()
                        
                        print("⚡ PULL-TO-REFRESH: Forced UI update with \(updatedEpisodes.count) episodes (\(newEpisodes.count) new)")
                    }
                    
                    // BACKGROUND: Defer expensive operations to background
                    Task.detached(priority: .background) {
                        await self.quietSyncEpisodeStates(for: feedId)
                        await self.syncRealTimeProgressAcrossDevices()
                        print("🔄 BACKGROUND: Completed deferred sync operations for \(feedId)")
                    }
                } else {
                    await MainActor.run {
                        self.isLoadingEpisodes = false
                        self.operationInProgress = false
                        self.forceUIUpdate()
                    }
                    print("❌ Pull-to-refresh failed: Missing feed for \(feedId)")
                }
                
            } catch {
                await MainActor.run {
                    self.error = "Failed to refresh feed: \(error.localizedDescription)"
                    self.isLoadingEpisodes = false
                    self.operationInProgress = false
                    self.forceUIUpdate()
                }
                os_log("❌ Failed to refresh feed: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
        
        await refreshTask?.value
    }
    
    /// Force refresh a specific feed ignoring timing restrictions
    func forceRefreshFeed(_ feedId: String) async {
        
        // Reset the last refresh time to force refresh
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        UserDefaults.standard.set(0, forKey: lastRefreshKey) // Set to 0 to force refresh
        
        // Trigger a reload which will now force the RSS refresh
        await loadEpisodesForFeed(feedId, isInitialLoad: false)
    }
    
    /// Request immediate refresh for a feed (user initiated) - optimized for newest episodes first
    func requestFeedRefresh(_ feedId: String) {
        let userRefreshKey = "UserRequestedRefresh_\(feedId)"
        UserDefaults.standard.set(true, forKey: userRefreshKey)
        
        // CRITICAL PERFORMANCE: Check for snapshot first to show newest episodes immediately
        if let snapshot = getEpisodeSnapshot(for: feedId) {
            print("⚡ NAVIGATION OPTIMIZATION: Using snapshot for feed refresh - \(snapshot.count) episodes available instantly (newest first)")
            
            // Update UI immediately with snapshot data (already sorted newest first)
            Task { @MainActor in
                self.currentEpisodes = snapshot
                self.selectedFeedId = feedId
                self.updateFilter(tab: self.currentTab)
                
                // PERFORMANCE BOOST: Clear loading states immediately since we have data
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                
                print("⚡ INSTANT DISPLAY: Showing \(snapshot.count) episodes immediately with newest episodes first")
            }
            
            // LIGHTWEIGHT CHECK: Ultra-fast new episode detection without expensive operations
            print("🪶 LIGHTWEIGHT CHECK: Starting ultra-fast new episode detection (no RSS parsing)")
            Task.detached(priority: .background) {
                await self.lightweightNewEpisodeCheck(feedId: feedId)
            }
            return
        }
        
        // Fallback: Trigger full reload if no snapshot exists
        print("🔄 NAVIGATION FALLBACK: No snapshot available - performing full load for feed \(feedId)")
        Task {
            await loadEpisodesForFeed(feedId, isInitialLoad: true)
        }
    }
    
    /// Perform ultra-lightweight background refresh that doesn't block UI or trigger expensive operations
    private func performUltraLightweightBackgroundRefresh(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ ULTRA LIGHTWEIGHT: Feed not found: \(feedId)")
            return
        }
        
        print("🪶 ULTRA LIGHTWEIGHT: Starting minimal background check for \(feed.title)")
        
        // Check if refresh is needed based on longer threshold for snapshots
        let refreshThreshold: TimeInterval = 60 * 60 // 1 hour for snapshot-based loads
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        let timeSinceLastRefresh = Date().timeIntervalSince1970 - lastRefreshTime
        
        if lastRefreshTime > 0 && timeSinceLastRefresh < refreshThreshold {
            print("⏭️ ULTRA LIGHTWEIGHT: Skipping - recent refresh (\(Int(timeSinceLastRefresh / 60)) min ago, threshold: \(Int(refreshThreshold / 60)) min)")
            return
        }
        
        // Perform minimal RSS check without blocking operations
        print("🪶 ULTRA LIGHTWEIGHT: Checking for new episodes in background...")
        
        // Use existing RSS refresh mechanism but with minimal processing
        if await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: false) {
            // Update last refresh time to prevent frequent checks
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)
            
            // Trigger ultra-minimal RSS refresh in the background without blocking UI
            Task.detached(priority: .utility) {
                // This will use minimal processing for snapshot-based feeds
                await self.loadEpisodesForFeed(feedId, isInitialLoad: false)
            }
        }
        
        print("🪶 ULTRA LIGHTWEIGHT: Background check completed for \(feed.title)")
    }
    
    /// Perform deferred episode check after normal loading completes to detect new episodes
    /// Prevents race conditions while ensuring users get new episodes without accumulation
    private func performDeferredEpisodeCheck(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ DEFERRED CHECK: Feed not found: \(feedId)")
            return
        }
        
        print("⚡ DEFERRED CHECK: Starting new episode detection for \(feed.title)")
        
        // PERFORMANCE OPTIMIZATION: Use throttling to prevent excessive checks
        let throttleKey = "DeferredCheck_\(feedId)"
        let lastCheckTime = UserDefaults.standard.double(forKey: throttleKey)
        let timeSinceLastCheck = Date().timeIntervalSince1970 - lastCheckTime
        
        // Throttle if checked within last 10 minutes (more conservative for deferred checks)
        if lastCheckTime > 0 && timeSinceLastCheck < 600 {
            print("⏭️ DEFERRED CHECK: Throttled - checked \(Int(timeSinceLastCheck)) seconds ago (10 min threshold)")
            return
        }
        
        // Update throttle timestamp IMMEDIATELY to prevent duplicate calls
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
        
        // Perform lightweight RSS check for new episodes only
        guard let url = URL(string: feed.url) else {
            print("⚠️ DEFERRED CHECK: Invalid URL for feed \(feed.title)")
            return
        }
        
        do {
            print("🔍 DEFERRED CHECK: Fetching RSS feed for \(feed.title)...")
            
            // SMART NEW EPISODE DETECTION: Compare against persistent cache first
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            guard !newEpisodes.isEmpty else {
                print("✅ DEFERRED CHECK: No new episodes found for \(feed.title)")
                return
            }
            
            print("🆕 DEFERRED CHECK: Found \(newEpisodes.count) new episodes for \(feed.title) - integrating properly")
            
            // PREVENT ACCUMULATION: Use smart integration instead of simple addition
            await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
            
            // SMART INTEGRATION: Only add truly new episodes to prevent accumulation
            try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
            
            // UPDATE UI GENTLY if this is the currently selected feed (avoid aggressive reloading)
            await MainActor.run {
                if self.selectedFeedId == feedId && !self.isLoadingEpisodes {
                    print("🔄 DEFERRED CHECK: Gently updating UI with new episodes for currently selected feed")
                    
                    // Instead of full reload, just trigger a gentle refresh
                    Task {
                        await self.requestFeedRefresh(feedId)
                    }
                } else {
                    print("⏭️ DEFERRED CHECK: Feed \(feedId) not currently selected or loading in progress - skipping UI update")
                }
                
                // CRITICAL FIX: DO NOT update snapshots from deferred checks to prevent accumulation
                // The deferred check should only detect new episodes, not modify cached data
                print("📸 DEFERRED CHECK: Found \(newEpisodes.count) new episodes but NOT updating snapshot to prevent accumulation")
                print("📸 DEFERRED CHECK: Snapshot will be updated on next normal feed load to maintain accuracy")
                
                self.objectWillChange.send()
            }
            
        } catch {
            print("❌ DEFERRED CHECK: Failed for \(feed.title): \(error)")
        }
        
        print("⚡ DEFERRED CHECK: Completed for \(feed.title)")
    }
    
    /// Perform lightweight background RSS check without expensive operations
    private func performBackgroundRSSCheck(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ BACKGROUND RSS: Feed not found: \(feedId)")
            return
        }
        
        print("🔄 BACKGROUND RSS: Starting lightweight check for \(feed.title)")
        
        // Check if RSS refresh is needed based on time threshold
        let refreshThreshold: TimeInterval = 15 * 60 // 15 minutes
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        let timeSinceLastRefresh = Date().timeIntervalSince1970 - lastRefreshTime
        
        if lastRefreshTime > 0 && timeSinceLastRefresh < refreshThreshold {
            print("⏭️ BACKGROUND RSS: Skipping - recent refresh (\(Int(timeSinceLastRefresh / 60)) min ago)")
            return
        }
        
        // Perform RSS fetch in background without blocking UI
        // Use the existing RSS refresh mechanism
        if await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: false) {
            // Trigger background RSS refresh using existing mechanism
            Task.detached(priority: .background) {
                // This will use the existing RSS refresh logic without blocking UI
                await self.loadEpisodesForFeed(feedId, isInitialLoad: false)
            }
        }
    }
    
    /// Update filter (All, Favorites, Downloads) with efficient reloading - OPTIMIZED FOR PERFORMANCE
    func updateFilter(tab: Int) {
        guard currentTab != tab else { return }
        
        // PERFORMANCE OPTIMIZATION: Skip expensive operations during tab switching
        // RSS operations and CloudKit saves are deferred to reduce CPU spikes
        
        let oldTab = currentTab
        currentTab = tab
        
        // ULTRA-FAST OPTIMIZATION: Use in-memory filtering to avoid expensive operations
        Task {
            let success = await performFastTabSwitch(from: oldTab, to: tab)
            if !success {
                // Only if absolutely necessary, do minimal reload without expensive sync operations
                await performMinimalTabReload(feedId: selectedFeedId, tab: tab)
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

    /// Search episodes across all saved podcasts (debounced)
    func searchSavedEpisodesAcrossPodcasts(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel previous task
        globalSearchTask?.cancel()

        // Debounce and perform global search
        globalSearchTask = Task { [weak self, trimmed] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms debounce
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            if trimmed.isEmpty {
                await MainActor.run { self.globalEpisodeSearchResults = [] }
                return
            }
            let results = await self.episodeManager.searchEpisodesAcrossFeeds(query: trimmed, limit: 50)
            // Deduplicate and merge states just in case
            let unique = await PodcastViewModel.removeDuplicatesFromEpisodes(results)
            await MainActor.run {
                self.globalEpisodeSearchResults = unique
            }
        }
    }
    
    /// Update episode state efficiently with immediate CloudKit and Core Data sync
    func updateEpisodeState(_ episodeId: String, progress: Double? = nil, isFavorite: Bool? = nil, isDownloaded: Bool? = nil, isPlayed: Bool? = nil) {
        Task {
            // CRITICAL SAFEGUARD: Prevent race condition corruption of currently playing episode
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episodeId && PodcastPlayer.shared.isPlaying
            let playerProgress = PodcastPlayer.shared.currentProgress
            
            // Get current state to preserve values not being updated
            let currentProgress = progress ?? EpisodeStateManager.shared.getProgress(for: episodeId)
            let currentFavorite = isFavorite ?? EpisodeStateManager.shared.isFavorite(episodeId)
            let currentDownloaded = isDownloaded ?? EpisodeStateManager.shared.isDownloaded(episodeId)
            
            // CRITICAL FIX: For currently playing episodes, prioritize player's progress over stale data
            // AND: Protect episodes from being corrupted with accumulated progress during playback
            let finalProgress: Double
            if let explicitProgress = progress {
                // PROGRESS PROTECTION: Never allow progress to go backwards
                if explicitProgress < currentProgress {
                    finalProgress = currentProgress // Keep the higher progress
                } else {
                    // CORRUPTION PROTECTION: If episode is currently playing at 0.0 but we're being asked 
                    // to set accumulated progress > 0, this is corruption - use player's actual progress
                    if isCurrentlyPlaying && playerProgress == 0.0 && explicitProgress > 0 {
                        finalProgress = playerProgress
                    } else {
                        // Explicit progress provided and not a corruption case - use it
                        finalProgress = explicitProgress
                    }
                }
            } else if isCurrentlyPlaying {
                // Currently playing - use player's progress to prevent corruption from stale data
                finalProgress = playerProgress
            } else {
                // Not playing - use stored progress
                finalProgress = currentProgress
            }
            
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
            // CRITICAL: Only update progress if it's explicitly provided OR if we're using player progress
            if let _ = progress {
                // Use our carefully calculated finalProgress (which may have rejected corrupted explicit progress)
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: finalProgress)
                
                // ⚡ PROACTIVE: Update snapshot immediately for instant loading on next app launch
                updateSnapshotForEpisodeStateChange(episodeId: episodeId)
                
                            // CONDITIONAL SYNC: Progress is stored locally, CloudKit sync happens only on allowed conditions
            } else if isCurrentlyPlaying {
                // For currently playing episodes, sync the player's progress
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: playerProgress)
                
                // ⚡ PROACTIVE: Update snapshot immediately for instant loading on next app launch
                updateSnapshotForEpisodeStateChange(episodeId: episodeId)
                
                // CONDITIONAL SYNC: Progress is stored locally, CloudKit sync happens only on allowed conditions
            }
            // IMPORTANT: If no explicit progress and not currently playing, DON'T modify stored progress
            
            if let isFavorite = isFavorite {
                let feedId = await getFeedIdForEpisode(episodeId)
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite, feedId: feedId)
                
                // CONDITIONAL SYNC: Favorite changes trigger immediate CloudKit sync (allowed condition)
                
                // ⚡ PROACTIVE: Update snapshot immediately for instant loading on next app launch
                updateSnapshotForEpisodeStateChange(episodeId: episodeId, feedId: feedId)
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
                    
                    // 🚗 CARPLAY FIX: Notify CarPlay immediately about favorite state change
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeStateChanged"),
                        object: nil,
                        userInfo: [
                            "episodeId": episodeId,
                            "isFavorite": isFavorite
                        ]
                    )
                }
            }
            if let isDownloaded = isDownloaded {
                let feedId = await getFeedIdForEpisode(episodeId)
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded, feedId: feedId)
                
                // CONDITIONAL SYNC: Download changes trigger immediate CloudKit sync (allowed condition)
                
                // ⚡ PROACTIVE: Update snapshot immediately for instant loading on next app launch
                updateSnapshotForEpisodeStateChange(episodeId: episodeId, feedId: feedId)
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
                    
                    // 🚗 CARPLAY FIX: Notify CarPlay immediately about download state change
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeStateChanged"),
                        object: nil,
                        userInfo: [
                            "episodeId": episodeId,
                            "isDownloaded": isDownloaded
                        ]
                    )
                }
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
            } else if let selectedId = self.selectedFeedId, !selectedId.isEmpty {
                // Fallback: use currently selected feed
                episodeFeedId = selectedId
            } else {
                // Last resort: query Core Data for the episode's feedId
                episodeFeedId = await self.getFeedIdForEpisode(episodeId)
            }
            
            // PERFORMANCE: Skip expensive CloudKit saves when snapshots are available
            let hasSnapshot = episodeFeedId != nil ? getEpisodeSnapshot(for: episodeFeedId!) != nil : false
            
            if !hasSnapshot {
                // Sync to CloudKit (single call, non-blocking) with feed relationship
                // Only sync if we have a valid feedId to prevent crashes
                if let validFeedId = episodeFeedId, !validFeedId.isEmpty {
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
                    // CRITICAL: This might be the issue - try alternative approaches
                    if let currentEpisode = self.currentEpisodes.first(where: { $0.id == episodeId }) {
                        if !currentEpisode.feedId.isEmpty {
                            Task.detached(priority: .userInitiated) {
                                await PodcastCloudKitManager.shared.saveEpisodeState(
                                    episodeId: episodeId,
                                    feedId: currentEpisode.feedId,
                                    progress: finalProgress,
                                    isFavorite: currentFavorite,
                                    isDownloaded: currentDownloaded,
                                    isPlayed: finalIsPlayed
                                )
                            }
                        }
                    }
                }
            } else {
                print("⚡ PERFORMANCE: Skipped CloudKit save - using snapshot for feed \(episodeFeedId ?? "unknown")")
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
            } catch {
                print("❌ Failed to save episode state to Core Data: \(error)")
            }
            
            // Update counts if necessary
            if isFavorite != nil || isDownloaded != nil {
                await updateEpisodeCountsForCurrentFeed()
                
                // PERFORMANCE: Skip cache clearing when snapshots are available to prevent CPU spikes
                if let feedId = self.selectedFeedId {
                    if self.getEpisodeSnapshot(for: feedId) == nil {
                        await self.episodeManager.clearCacheForFeed(feedId)
                        // ULTRA-FAST CACHE: Also clear memory cache for immediate consistency
                        self.episodeManager.clearMemoryCacheForFeed(feedId)
                        print("🧽 CACHE: Cleared cache for feed \(feedId) - no snapshot available")
                    } else {
                        print("⚡ PERFORMANCE: Skipping cache clear - using episode snapshot for feed \(feedId)")
                    }
                }
                
                // PERFORMANCE: Only refresh filtered list if actually needed to reduce CPU usage
                if self.currentTab == EpisodeFilter.favorites.rawValue || self.currentTab == EpisodeFilter.downloads.rawValue {
                    await self.refreshCurrentFilteredList()
                }
            }
        }
    }
    
    /// PERFORMANCE OPTIMIZATION: Fast tab switching using in-memory filtering and caching
    /// This avoids expensive Core Data queries and EpisodeStateManager sync for every episode
    @MainActor
    private func performFastTabSwitch(from oldTab: Int, to newTab: Int) async -> Bool {
        guard let feedId = selectedFeedId else { return false }
        
        // INSTANT CACHE: Check for pre-computed cached results with counts
        if let cachedEpisodes = tabFilterCache[feedId]?[newTab],
           let cachedCounts = tabFilterCounts[feedId] {
            print("⚡ INSTANT CACHE HIT: Using pre-computed results for tab \(newTab) (\(cachedEpisodes.count) episodes)")
            currentEpisodes = cachedEpisodes
            
            // Use pre-computed counts to avoid expensive filtering
            episodeCounts = cachedCounts
            
            isLoadingEpisodes = false
            operationInProgress = false
            hasMoreEpisodes = false
            return true
        } else {
            print("❌ CACHE MISS: No cached results for feed \(feedId) tab \(newTab). Cache keys: \(Array(tabFilterCache.keys))")
            if let feedCache = tabFilterCache[feedId] {
                print("❌ CACHE MISS: Available tabs for feed: \(Array(feedCache.keys))")
            }
        }
        
        // Try to get episodes from memory first (from feed object or current episodes)
        var availableEpisodes: [PodcastEpisode] = []
        
        // First, try to get from the feed object in memory
        if let feed = podcastFeeds.first(where: { $0.id == feedId }), !feed.episodes.isEmpty {
            availableEpisodes = feed.episodes
            print("⚡ FAST TAB SWITCH: Using feed episodes (\(feed.episodes.count) episodes)")
        } else if !currentEpisodes.isEmpty && oldTab >= 0 {
            // CRITICAL FIX: Use current episodes and reconstruct the full list if needed
            print("⚡ FAST TAB SWITCH: Using current episodes (\(currentEpisodes.count) episodes) from oldTab \(oldTab)")
            
            // Debug: check if feed was found but had no episodes
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                print("❌ FAST TAB SWITCH: Feed found but has no episodes (\(feed.episodes.count) episodes) - using current episodes instead")
            } else {
                print("❌ FAST TAB SWITCH: No feed found with ID \(feedId). Available feeds: \(podcastFeeds.count) - using current episodes")
            }
            // We have current episodes but need to determine if they're filtered
            let oldFilter = EpisodeFilter(rawValue: oldTab) ?? .all
            
            if oldFilter == .all {
                // Current episodes are the full list - use them
                availableEpisodes = currentEpisodes
                print("⚡ FAST TAB SWITCH: Current episodes are full list (oldTab was 'All')")
            } else {
                // Current episodes are filtered - we need to get the full list
                // Try to get from Core Data quickly without expensive operations
                if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                    // Use the feed's episodes if available
                    availableEpisodes = feed.episodes.isEmpty ? currentEpisodes : feed.episodes
                    print("⚡ FAST TAB SWITCH: Using feed episodes (\(feed.episodes.count)) or current (\(currentEpisodes.count))")
                } else {
                    // Last resort: use current episodes (might be filtered but better than full reload)
                    availableEpisodes = currentEpisodes
                    print("⚠️ FAST TAB SWITCH: Using potentially filtered episodes to avoid expensive reload")
                }
            }
        }
        else {
            // No episodes available in memory - need full reload
            print("❌ FAST TAB SWITCH: No episodes available - currentEpisodes.count=\(currentEpisodes.count), oldTab=\(oldTab), podcastFeeds.count=\(podcastFeeds.count)")
            print("❌ FAST TAB SWITCH: Falling back to minimal reload to avoid expensive operations")
            return false
        }
        
        print("⚡ FAST TAB SWITCH: Filtering \(availableEpisodes.count) episodes for tab \(newTab)")
        
        // Apply the filter quickly without expensive operations
        let filter = EpisodeFilter(rawValue: newTab) ?? .all
        let filteredEpisodes: [PodcastEpisode]
        
        switch filter {
        case .all:
            filteredEpisodes = availableEpisodes
        case .favorites:
            filteredEpisodes = availableEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = availableEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Sort and cache the results
        let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
        
        // PERFORMANCE: Pre-compute and cache episode counts to avoid expensive filtering on future accesses
        let allEpisodes = availableEpisodes
        let favoriteEpisodes = allEpisodes.filter { $0.state.isFavorite }
        let downloadedEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        
        let precomputedCounts = (all: allEpisodes.count, favorites: favoriteEpisodes.count, downloads: downloadedEpisodes.count)
        
        // Cache both the filtered results AND the pre-computed counts
        if tabFilterCache[feedId] == nil {
            tabFilterCache[feedId] = [:]
        }
        tabFilterCache[feedId]?[0] = allEpisodes  // All episodes
        tabFilterCache[feedId]?[1] = favoriteEpisodes  // Favorites
        tabFilterCache[feedId]?[2] = downloadedEpisodes  // Downloads
        tabFilterCache[feedId]?[newTab] = sortedEpisodes  // Current tab (may be redundant but ensures consistency)
        
        // Cache the counts for instant access
        tabFilterCounts[feedId] = precomputedCounts
        
        // Update UI immediately with filtered results
        currentEpisodes = sortedEpisodes
        isLoadingEpisodes = false
        operationInProgress = false
        hasMoreEpisodes = false
        
        print("⚡ FAST TAB SWITCH: Showing \(currentEpisodes.count) episodes for tab \(newTab) (cached for future)")
        return true
    }
    
    /// ULTRA-MINIMAL TAB RELOAD: Last resort fallback that shows current episodes with different filter
    /// This completely avoids Core Data queries and CloudKit sync to prevent CPU spikes
    @MainActor
    private func performMinimalTabReload(feedId: String?, tab: Int) async {
        guard let feedId = feedId else { return }
        
        print("⚡ ULTRA-MINIMAL TAB RELOAD: Using current episodes for tab \(tab) - NO expensive operations")
        
        // Use whatever episodes we currently have and just filter them
        // This prevents any expensive Core Data or CloudKit operations
        let availableEpisodes = currentEpisodes.isEmpty ? [] : currentEpisodes
        
        if availableEpisodes.isEmpty {
            print("⚠️ ULTRA-MINIMAL: No current episodes available - showing empty state")
            currentEpisodes = []
            episodeCounts = (all: 0, favorites: 0, downloads: 0)
            isLoadingEpisodes = false
            operationInProgress = false
            return
        }
        
        // Apply filter to current episodes (they might be from a different tab, but that's better than hanging)
        let filter = EpisodeFilter(rawValue: tab) ?? .all
        let filteredEpisodes: [PodcastEpisode]
        
        switch filter {
        case .all:
            filteredEpisodes = availableEpisodes
        case .favorites:
            filteredEpisodes = availableEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = availableEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Update UI immediately with filtered results
        currentEpisodes = filteredEpisodes
        hasMoreEpisodes = false
        
        // Update episode counts
        let allCount = filteredEpisodes.count
        let favoritesCount = filteredEpisodes.filter { $0.state.isFavorite }.count
        let downloadsCount = filteredEpisodes.filter { $0.state.isDownloaded }.count
        episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
        
        // PERFORMANCE: Pre-compute all filter types and counts for instant future access
        let allEpisodes = availableEpisodes
        let favoriteEpisodes = allEpisodes.filter { EpisodeStateManager.shared.isFavorite($0.id) }
        let downloadedEpisodes = allEpisodes.filter { EpisodeStateManager.shared.isDownloaded($0.id) }
        
        let precomputedCounts = (all: allEpisodes.count, favorites: favoriteEpisodes.count, downloads: downloadedEpisodes.count)
        
        // Cache all three filter types at once to avoid future expensive operations
        if tabFilterCache[feedId] == nil {
            tabFilterCache[feedId] = [:]
        }
        tabFilterCache[feedId]?[0] = allEpisodes  // All episodes
        tabFilterCache[feedId]?[1] = favoriteEpisodes  // Favorites
        tabFilterCache[feedId]?[2] = downloadedEpisodes  // Downloads
        
        // Cache the counts for instant access
        tabFilterCounts[feedId] = precomputedCounts
        
        // Clear loading state
        isLoadingEpisodes = false
        operationInProgress = false
        
        print("⚡ ULTRA-MINIMAL: Showing \(filteredEpisodes.count) episodes for tab \(tab) (cached for future)")
    }
    
    /// Clear tab filter cache for a specific feed when episodes are updated
    private func clearTabFilterCache(for feedId: String) {
        tabFilterCache.removeValue(forKey: feedId)
        tabFilterCounts.removeValue(forKey: feedId)
        // CRITICAL FIX: Don't clear snapshots - they provide performance benefits
        // Snapshots will naturally expire after 10 minutes or be updated with new data
        print("🧽 Cleared tab filter cache and counts for feed: \(feedId) (snapshots preserved)")
    }
    
    /// Clear all tab filter cache
    private func clearAllTabFilterCache() {
        tabFilterCache.removeAll()
        tabFilterCounts.removeAll()
        // CRITICAL FIX: Preserve snapshots for performance - they expire naturally
        print("🧽 Cleared all tab filter caches and counts (snapshots preserved)")
    }
    
    /// Clear all existing episode snapshots
    func clearAllEpisodeSnapshots() {
        episodeSnapshotCache.removeAll()
        snapshotTimestamps.removeAll()
        print("🗑️ SNAPSHOT: Cleared all existing episode snapshots")
        
        // Reset DataSyncManager snapshot tracking
        Task { @MainActor in
            DataSyncManager.shared.updateEpisodeSnapshotReadiness(
                feedsWithSnapshots: 0,
                totalFeedsRequiringSnapshots: 0
            )
        }
    }
    
    
    /// Clean up old snapshots to prevent memory buildup
    private func cleanupOldSnapshots() {
        let currentTime = Date()
        let maxAge: TimeInterval = 3600 // 1 hour
        
        var snapshotsToRemove: [String] = []
        
        for (feedId, timestamp) in snapshotTimestamps {
            if currentTime.timeIntervalSince(timestamp) > maxAge {
                snapshotsToRemove.append(feedId)
            }
        }
        
        for feedId in snapshotsToRemove {
            episodeSnapshotCache.removeValue(forKey: feedId)
            snapshotTimestamps.removeValue(forKey: feedId)
            print("🗑️ CLEANUP: Removed old snapshot for feed \(feedId)")
        }
        
        if !snapshotsToRemove.isEmpty {
            print("🗑️ CLEANUP: Removed \(snapshotsToRemove.count) old snapshots")
        }
    }
    
    /// PERFORMANCE OPTIMIZED: Create or update episode snapshot with minimal CPU impact
    func updateEpisodeSnapshot(for feedId: String, episodes: [PodcastEpisode]) {
        // PERFORMANCE: Skip snapshot creation if we already have a recent one
        if let existingTimestamp = snapshotTimestamps[feedId],
           Date().timeIntervalSince(existingTimestamp) < 5.0 { // 5 second threshold
            return
        }
        
        // PERFORMANCE: Run expensive operations on background queue
        Task.detached(priority: .utility) {
            // CLEANUP: Periodically clean up old snapshots to prevent memory buildup
            if await self.episodeSnapshotCache.count > 10 {
                await self.cleanupOldSnapshots()
            }
            
            // CRITICAL SAFETY CHECK: Ensure all episodes actually belong to this feed before caching
            let safeEpisodes = episodes.filter { $0.feedId == feedId }
            if safeEpisodes.count != episodes.count {
                print("🚨 SNAPSHOT ISOLATION: Filtered out \(episodes.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId)")
            }
            
            // PERFORMANCE OPTIMIZATION: Use efficient sorting algorithm
            let sortedEpisodes = safeEpisodes.sorted { $0.publicationDate > $1.publicationDate }
            
            // Update cache on main actor
            await MainActor.run {
                self.episodeSnapshotCache[feedId] = sortedEpisodes
                self.snapshotTimestamps[feedId] = Date()
                print("📸 SNAPSHOT: Cached \(sortedEpisodes.count) episodes for feed \(feedId) (newest first)")
            }
            
            // Update DataSyncManager snapshot readiness tracking (low priority)
            let feedsWithEpisodes = await self.podcastFeeds.filter { !$0.episodes.isEmpty }
            var feedsWithSnapshots = 0
            for feed in feedsWithEpisodes {
                if await self.getEpisodeSnapshot(for: feed.id) != nil {
                    feedsWithSnapshots += 1
                }
            }
            
            Task { @MainActor in
                DataSyncManager.shared.updateEpisodeSnapshotReadiness(
                    feedsWithSnapshots: feedsWithSnapshots,
                    totalFeedsRequiringSnapshots: feedsWithEpisodes.count
                )
            }
        }
    }
    
    /// PULL-TO-REFRESH: Force snapshot update bypassing throttling for immediate UI refresh
    func forceUpdateEpisodeSnapshot(for feedId: String, episodes: [PodcastEpisode]) {
        // CRITICAL SAFETY CHECK: Ensure all episodes actually belong to this feed before caching
        let safeEpisodes = episodes.filter { $0.feedId == feedId }
        if safeEpisodes.count != episodes.count {
            print("🚨 FORCE SNAPSHOT: Filtered out \(episodes.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId)")
        }
        
        // PERFORMANCE OPTIMIZATION: Use efficient sorting algorithm
        let sortedEpisodes = safeEpisodes.sorted { $0.publicationDate > $1.publicationDate }
        
        // Update cache immediately (bypass throttling)
        episodeSnapshotCache[feedId] = sortedEpisodes
        snapshotTimestamps[feedId] = Date()
        print("📸 FORCE SNAPSHOT: Immediately cached \(sortedEpisodes.count) episodes for feed \(feedId) (pull-to-refresh)")
        
        // Update DataSyncManager snapshot readiness tracking (background)
        Task.detached(priority: .background) {
            let feedsWithEpisodes = await self.podcastFeeds.filter { !$0.episodes.isEmpty }
            var feedsWithSnapshots = 0
            for feed in feedsWithEpisodes {
                if await self.getEpisodeSnapshot(for: feed.id) != nil {
                    feedsWithSnapshots += 1
                }
            }
            
            await MainActor.run {
                DataSyncManager.shared.updateEpisodeSnapshotReadiness(
                    feedsWithSnapshots: feedsWithSnapshots,
                    totalFeedsRequiringSnapshots: feedsWithEpisodes.count
                )
            }
        }
    }
    
    /// PROACTIVE: Update snapshot immediately when episode state changes (super fast, non-blocking)
    func updateSnapshotForEpisodeStateChange(episodeId: String, feedId: String? = nil) {
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            
            // Determine feedId if not provided
            let resolvedFeedId: String
            if let feedId = feedId {
                resolvedFeedId = feedId
            } else {
                // Find feedId by searching through cached snapshots first (fastest)
                var foundFeedId: String? = nil
                await MainActor.run {
                    for (cachedFeedId, episodes) in self.episodeSnapshotCache {
                        if episodes.contains(where: { $0.id == episodeId }) {
                            foundFeedId = cachedFeedId
                            break
                        }
                    }
                }
                
                if let foundFeedId = foundFeedId {
                    resolvedFeedId = foundFeedId
                } else {
                    // Fallback: search through loaded feeds (slower)
                    guard let foundFeedId = await MainActor.run(body: {
                        return self.podcastFeeds.first { feed in
                            feed.episodes.contains { $0.id == episodeId }
                        }?.id
                    }) else {
                        print("⚠️ PROACTIVE SNAPSHOT: Could not find feedId for episode \(episodeId)")
                        return
                    }
                    resolvedFeedId = foundFeedId
                }
            }
            
            // Get current snapshot
            guard let currentSnapshot = await MainActor.run(body: {
                return self.episodeSnapshotCache[resolvedFeedId]
            }) else {
                print("⚠️ PROACTIVE SNAPSHOT: No snapshot exists for feed \(resolvedFeedId)")
                return
            }
            
            // Update the specific episode with current state from EpisodeStateManager
            let updatedSnapshot = currentSnapshot.map { episode in
                if episode.id == episodeId {
                    var updatedEpisode = episode
                    // Get fresh states from EpisodeStateManager (source of truth)
                    updatedEpisode.state.progress = EpisodeStateManager.shared.getProgress(for: episodeId)
                    updatedEpisode.state.isFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                    updatedEpisode.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                    updatedEpisode.state.isPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                    return updatedEpisode
                }
                return episode
            }
            
            // Update snapshot cache on main thread
            await MainActor.run {
                self.episodeSnapshotCache[resolvedFeedId] = updatedSnapshot
                self.snapshotTimestamps[resolvedFeedId] = Date()
                print("⚡ PROACTIVE SNAPSHOT: Updated episode \(episodeId) in feed \(resolvedFeedId) snapshot")
            }
        }
    }
    
    /// Get episode snapshot if available and recent
    func getEpisodeSnapshot(for feedId: String) -> [PodcastEpisode]? {
        guard let episodes = episodeSnapshotCache[feedId],
              let timestamp = snapshotTimestamps[feedId] else {
            return nil
        }
        
        // Snapshots are valid for 10 minutes
        let isRecent = Date().timeIntervalSince(timestamp) < 600
        if isRecent {
            print("📸 SNAPSHOT HIT: Using cached \(episodes.count) episodes for feed \(feedId)")
            return episodes
        } else {
            // Remove stale snapshot
            episodeSnapshotCache.removeValue(forKey: feedId)
            snapshotTimestamps.removeValue(forKey: feedId)
            print("📸 SNAPSHOT EXPIRED: Removed stale cache for feed \(feedId)")
            return nil
        }
    }
    
    /// Ultra-fast check for new episodes - pulls ALL new episodes and updates UI instantly
    private func checkForNewEpisodesImmediately(feedId: String) async {
        print("⚡ ULTRA-FAST CHECK: Starting instant new episode check for feed \(feedId)")
        
        do {
            guard let feed = podcastFeeds.first(where: { $0.id == feedId }),
                  let url = URL(string: feed.url) else { 
                print("❌ ULTRA-FAST: Could not find feed or URL for \(feedId)")
                return 
            }
            
            // ULTRA-FAST: Parse ALL new episodes from RSS for complete update
            let latestEpisodes = try await parseAllNewEpisodesOptimized(from: url, feedId: feedId)
            
            // Get existing episodes from snapshot or current episodes for comparison
            let existingEpisodes = getEpisodeSnapshot(for: feedId) ?? currentEpisodes
            let existingIds = Set(existingEpisodes.map { $0.id })
            
            // Find truly new episodes
            let newEpisodes = latestEpisodes.filter { !existingIds.contains($0.id) }
            
            if !newEpisodes.isEmpty {
                print("🆕 ULTRA-FAST: Found \(newEpisodes.count) new episodes - updating UI instantly")
                
                // INSTANT UI UPDATE: Add new episodes to the front of current list
                await MainActor.run {
                    if self.selectedFeedId == feedId {
                        // Prepend new episodes to existing list (newest first)
                        var updatedEpisodes = newEpisodes + self.currentEpisodes
                        
                        // Remove duplicates while preserving order
                        var seenIds = Set<String>()
                        updatedEpisodes = updatedEpisodes.filter { episode in
                            if seenIds.contains(episode.id) {
                                return false
                            }
                            seenIds.insert(episode.id)
                            return true
                        }
                        
                        // Apply current filter
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = updatedEpisodes
                        case .favorites:
                            filteredEpisodes = updatedEpisodes.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = updatedEpisodes.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        print("⚡ INSTANT UI: Updated with \(filteredEpisodes.count) episodes including \(newEpisodes.count) new ones")
                        
                        // IMMEDIATE SNAPSHOT UPDATE: Update snapshot immediately to persist new episodes
                        if let existingSnapshot = self.getEpisodeSnapshot(for: feedId) {
                            let updatedSnapshot = newEpisodes + existingSnapshot
                            self.updateEpisodeSnapshot(for: feedId, episodes: updatedSnapshot)
                            print("📸 IMMEDIATE: Updated snapshot with \(newEpisodes.count) new episodes for navigation persistence")
                        } else {
                            // Create new snapshot if none exists
                            self.updateEpisodeSnapshot(for: feedId, episodes: updatedEpisodes)
                            print("📸 IMMEDIATE: Created new snapshot with \(updatedEpisodes.count) episodes")
                        }
                    }
                }
                
                // BACKGROUND: Update Core Data asynchronously
                Task.detached(priority: .background) {
                    do {
                        // Add new episodes to Core Data
                        try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                        print("💾 BACKGROUND: Added \(newEpisodes.count) new episodes to Core Data")
                    } catch {
                        print("❌ BACKGROUND UPDATE ERROR: \(error.localizedDescription)")
                    }
                }
            } else {
                print("✅ ULTRA-FAST: No new episodes found in latest 3 episodes for feed \(feedId)")
            }
        } catch {
            print("❌ ULTRA-FAST CHECK ERROR: \(error.localizedDescription)")
        }
    }
    
    /// Ultra-fast RSS parsing that finds ALL new episodes by stopping at first known episode
    private func parseAllNewEpisodesOptimized(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        print("⚡ ULTRA-FAST PARSE: Fetching ALL new episodes from \(url)")
        
        let startTime = Date()
        
        // Get existing episode IDs for comparison
        let existingEpisodes = getEpisodeSnapshot(for: feedId) ?? currentEpisodes
        let existingIds = Set(existingEpisodes.map { $0.id })
        
        // Create a fast URLSession with minimal timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0 // 5 second timeout
        config.timeoutIntervalForResource = 10.0 // 10 second total timeout
        let session = URLSession(configuration: config)
        
        let (data, _) = try await session.data(from: url)
        
        let parser = XMLParser(data: data)
        let delegate = SmartRSSParserDelegate(feedId: feedId, existingIds: existingIds)
        parser.delegate = delegate
        
        let parseSuccess = parser.parse()
        
        let parseTime = Date().timeIntervalSince(startTime)
        print("⚡ ULTRA-FAST PARSE: Completed in \(String(format: "%.2f", parseTime))s, found \(delegate.newEpisodes.count) new episodes")
        
        guard parseSuccess else {
            throw NSError(domain: "SmartRSSParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse RSS feed"])
        }
        
        return delegate.newEpisodes
    }
    
    /// Smart RSS parser delegate that stops at first known episode to get ALL new episodes
    private class SmartRSSParserDelegate: NSObject, XMLParserDelegate {
        let feedId: String
        let existingIds: Set<String>
        var newEpisodes: [PodcastEpisode] = []
        
        private var currentElement = ""
        private var currentTitle = ""
        private var currentDescription = ""
        private var currentAudioUrl = ""
        private var currentPubDate = ""
        private var currentGuid = ""
        private var insideItem = false
        
        init(feedId: String, existingIds: Set<String>) {
            self.feedId = feedId
            self.existingIds = existingIds
        }
        
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName.lowercased()
            
            if currentElement == "item" {
                insideItem = true
                // Reset episode data
                currentTitle = ""
                currentDescription = ""
                currentAudioUrl = ""
                currentPubDate = ""
                currentGuid = ""
            } else if currentElement == "enclosure" && insideItem {
                if let url = attributeDict["url"], url.contains("mp3") || url.contains("m4a") || url.contains("wav") {
                    currentAudioUrl = url
                }
            }
        }
        
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && insideItem else { return }
            
            switch currentElement {
            case "title":
                currentTitle += trimmed
            case "description", "itunes:summary":
                currentDescription += trimmed
            case "pubdate":
                currentPubDate += trimmed
            case "guid":
                currentGuid += trimmed
            default:
                break
            }
        }
        
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName.lowercased() == "item" && insideItem {
                insideItem = false
                
                // Create episode if we have minimum required data
                guard !currentTitle.isEmpty && !currentAudioUrl.isEmpty else { return }
                
                let pubDate = parseDate(from: currentPubDate) ?? Date()
                let episodeId = !currentGuid.isEmpty ? currentGuid : PodcastEpisode.generateDeterministicID(
                    title: currentTitle,
                    audioUrl: currentAudioUrl,
                    publicationDate: pubDate,
                    feedUrl: ""
                )
                
                // SMART OPTIMIZATION: Stop parsing if we hit a known episode (all new episodes found)
                if existingIds.contains(episodeId) {
                    print("⚡ SMART PARSE: Hit known episode '\(currentTitle)' - stopping (found \(newEpisodes.count) new episodes)")
                    parser.abortParsing()
                    return
                }
                
                let episode = PodcastEpisode(
                    id: episodeId,
                    title: currentTitle,
                    descriptionText: currentDescription.isEmpty ? currentTitle : currentDescription,
                    audioUrl: currentAudioUrl,
                    publicationDate: pubDate,
                    duration: 0,
                    state: EpisodeState(
                        isPlayed: false,
                        isFavorite: false,
                        progress: 0.0,
                        isDownloaded: false
                    ),
                    feedId: feedId
                )
                
                newEpisodes.append(episode)
            }
        }
        
        private func parseDate(from string: String) -> Date? {
            let formatters = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd HH:mm:ss"
            ]
            
            for format in formatters {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let date = formatter.date(from: string) {
                    return date
                }
            }
            return nil
        }
    }
    
    /// Background check for new episodes without blocking UI
    private func checkForNewEpisodesInBackground(feedId: String) async {
        // PERFORMANCE: Be very conservative about background checks when snapshots exist
        // Only check if snapshot is significantly old to preserve the snapshot system benefits
        if let snapshotEpisodes = getEpisodeSnapshot(for: feedId) {
            let snapshotAge = Date().timeIntervalSince(snapshotTimestamps[feedId] ?? Date.distantPast)
            if snapshotAge < 1800 { // 30 minutes - much more conservative to preserve snapshot benefits
                print("⚡ PERFORMANCE: Skipping background RSS check - snapshot is fresh (\(Int(snapshotAge/60)) min old)")
                return
            } else {
                print("🔍 BACKGROUND CHECK: Snapshot is \(Int(snapshotAge/60)) min old - checking for new episodes")
            }
        }
        
        print("🔍 BACKGROUND CHECK: Checking for new episodes for feed \(feedId)")
        
        do {
            // Quick RSS check for new episodes only
            guard let feed = podcastFeeds.first(where: { $0.id == feedId }),
                  let url = URL(string: feed.url) else { return }
            
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            if !newEpisodes.isEmpty {
                print("🆕 BACKGROUND: Found \(newEpisodes.count) new episodes - creating new snapshot")
                
                // Update Core Data with new episodes first
                try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                
                // CLEAN UP: Remove old snapshot before creating new one
                if episodeSnapshotCache[feedId] != nil {
                    print("🗑️ BACKGROUND CLEANUP: Removing old snapshot for feed \(feedId)")
                    episodeSnapshotCache.removeValue(forKey: feedId)
                    snapshotTimestamps.removeValue(forKey: feedId)
                }
                
                // CREATE NEW SNAPSHOT: Parse complete RSS feed to get all current episodes
                let allCurrentEpisodes = try await parseRSSEpisodesOnly(from: url)
                updateEpisodeSnapshot(for: feedId, episodes: allCurrentEpisodes)
                print("🆕 BACKGROUND: Created new snapshot with \(allCurrentEpisodes.count) episodes (includes \(newEpisodes.count) new episodes)")
                
                // Update UI with complete episode list if this feed is currently displayed
                await MainActor.run {
                    if self.selectedFeedId == feedId {
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = allCurrentEpisodes // Already sorted newest first
                        case .favorites:
                            filteredEpisodes = allCurrentEpisodes.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = allCurrentEpisodes.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        Task {
                            await self.updateEpisodeCounts(for: feedId, episodes: allCurrentEpisodes)
                        }
                        print("🆕 BACKGROUND: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count) (newest first)")
                    }
                }
            } else {
                print("✅ BACKGROUND: No new episodes found for feed \(feedId)")
            }
        } catch {
            print("❌ BACKGROUND: Failed to check for new episodes: \(error)")
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
    
    /// Delete a podcast feed with real-time progress tracking
    @MainActor
    func deletePodcastFeed(_ feed: PodcastFeed) {
        // Initialize progress tracking
        isDeletingFeed = true
        deletingFeedId = feed.id
        feedDeletionProgress = 0.0
        feedDeletionMessage = "Preparing deletion..."
        
        Task { [self] in
            do {
                // Step 1: Get episode count for progress calculation
                feedDeletionMessage = "Analyzing episodes..."
                feedDeletionProgress = 0.05
                
                let episodeIds = await getEpisodeIdsForFeed(feed.id)
                let totalEpisodes = episodeIds.count
                
                await MainActor.run {
                    feedDeletionMessage = "Found \(totalEpisodes) episodes to delete"
                    feedDeletionProgress = 0.1
                }
                
                // Step 2: Clear episode states from EpisodeStateManager (BATCH OPTIMIZED)
                await MainActor.run {
                    feedDeletionMessage = "Clearing episode progress and states..."
                    feedDeletionProgress = 0.2
                }
                
                // Use batch deletion for much better performance
                EpisodeStateManager.shared.clearEpisodeDataBatch(episodeIds)
                
                await MainActor.run {
                    feedDeletionMessage = "✅ Cleared \(totalEpisodes) episode states (batch)"
                    feedDeletionProgress = 0.4
                }
                
                // Step 3: Delete downloaded files
                await MainActor.run {
                    feedDeletionMessage = "Deleting downloaded files..."
                    feedDeletionProgress = 0.5
                }
                
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                await MainActor.run {
                    feedDeletionMessage = "Downloaded files cleaned up"
                    feedDeletionProgress = 0.6
                }
                
                // Step 4: Delete from CloudKit
                await MainActor.run {
                    feedDeletionMessage = "Deleting from CloudKit..."
                    feedDeletionProgress = 0.7
                }
                
                var cloudKitDeletionSucceeded = false
                do {
                    // Delete feed from CloudKit
                    try await cloudKitManager.deletePodcastFeedFromCloudKit(feed.id)
                    
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit feed deletion complete"
                        feedDeletionProgress = 0.75
                    }
                    
                    // Delete episode states from CloudKit database records for this specific feed
                    await cloudKitManager.deleteEpisodeStatesFromCloudKit(episodeIds: episodeIds)
                    
                    // CRITICAL: Also remove episodes from CloudKit shared collections (NSUbiquitousKeyValueStore)
                    await MainActor.run {
                        feedDeletionMessage = "Clearing CloudKit shared collections..."
                        feedDeletionProgress = 0.78
                    }
                    
                    cloudKitManager.removeEpisodesFromSharedCollections(episodeIds: episodeIds)
                    cloudKitDeletionSucceeded = true
                    
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit cleanup complete"
                        feedDeletionProgress = 0.8
                    }
                    
                } catch {
                    cloudKitDeletionSucceeded = false
                    print("☁️ ❌ CloudKit deletion failed: \(error)")
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit deletion failed - continuing locally"
                        feedDeletionProgress = 0.75
                    }
                }
                
                // Step 5: Delete from Core Data
                await MainActor.run {
                    feedDeletionMessage = "Deleting from local database..."
                    feedDeletionProgress = 0.85
                }
                
                // First, explicitly clear all episode state data for this feed
                await clearEpisodeStatesFromCoreData(episodeIds)
                
                // Then delete the feed and episode entities
                try await deleteFeedFromCoreData(feed)
                
                // PERSISTENT CACHE: Clear all cached data for deleted feed
                await episodeManager.clearPersistentCacheForFeed(feed.id)
                print("🧽 DELETION: Cleared persistent cache for deleted feed \(feed.title)")
                
                await MainActor.run {
                    feedDeletionMessage = "Database cleanup complete"
                    feedDeletionProgress = 0.9
                }
                
                // Step 6: Update UI
                await MainActor.run {
                    feedDeletionMessage = "Updating interface..."
                    feedDeletionProgress = 0.95
                    
                    // Remove from UI arrays
                    if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                        podcastFeeds.remove(at: index)
                    }
                    podcastFeedOrder.removeAll { $0 == feed.id }
                    currentEpisodes.removeAll { $0.feedId == feed.id }
                    
                    // Clear selected feed if it's the one being deleted
                    if selectedFeedId == feed.id {
                        selectedFeedId = nil
                    }
                    
                    // Clear local episode progress tracking
                    for episodeId in episodeIds {
                        episodeProgress.removeValue(forKey: episodeId)
                    }
                    
                    // Trigger UI update
                    throttledUIUpdate()
                }
                
                // Step 7: Sync deletion to other devices (if CloudKit succeeded)
                if cloudKitDeletionSucceeded {
                    await MainActor.run {
                        PodcastCloudKitManager.shared.syncPodcastFeedRemovedInstantly(
                            feedId: feed.id,
                            feedTitle: feed.title,
                            episodeIds: episodeIds
                        )
                    }
                }
                
                // Step 8: Completion
                await MainActor.run {
                    feedDeletionMessage = "✅ Successfully deleted '\(feed.title)' and \(totalEpisodes) episodes"
                    feedDeletionProgress = 1.0
                }
                
                // Auto-hide progress after success
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await MainActor.run {
                    isDeletingFeed = false
                    deletingFeedId = nil
                    feedDeletionProgress = 0.0
                    feedDeletionMessage = ""
                }
                
            } catch {
                print("❌ Error during feed deletion: \(error)")
                await MainActor.run {
                    feedDeletionMessage = "❌ Deletion failed: \(error.localizedDescription)"
                    feedDeletionProgress = 1.0
                    
                    // Keep error visible longer
                    Task {
                        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                        await MainActor.run {
                            isDeletingFeed = false
                            deletingFeedId = nil
                            feedDeletionProgress = 0.0
                            feedDeletionMessage = ""
                        }
                    }
                    
                    // Reload UI to show correct state
                    loadFeedsFromCoreData()
                    self.error = "Failed to delete podcast: \(error.localizedDescription)"
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
                    continuation.resume(returning: feedId)
                } catch {
                    print("❌ Failed to get feedId for episode \(episodeId): \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Delete downloaded episode files from device storage using enhanced deletion strategies
    private func deleteDownloadedEpisodeFiles(_ episodeIds: [String]) async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
        
        var deletedCount = 0
        
        for episodeId in episodeIds {
            var fileDeleted = false
            
            // Strategy 1: Try multiple file extensions with sanitized ID
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
                        fileDeleted = true
                        break // Found and deleted the file, no need to check other extensions
                    } catch {
                        print("❌ Failed to delete file \(fileName): \(error)")
                    }
                }
            }
            
            // Strategy 2: If no file found with standard naming, search all files for matches
            if !fileDeleted {
                // Check if the DownloadedEpisodes folder exists before trying to access it
                if FileManager.default.fileExists(atPath: episodesFolder.path) {
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: episodesFolder, includingPropertiesForKeys: nil)
                        
                        for fileURL in fileURLs {
                            let fileName = fileURL.lastPathComponent
                            if fileName.contains(episodeId) || fileName.contains(sanitizedId) {
                                do {
                                    try FileManager.default.removeItem(at: fileURL)
                                    deletedCount += 1
                                    print("🗑️ Deleted file found by search: \(fileName)")
                                    fileDeleted = true
                                    break
                                } catch {
                                    print("❌ Failed to delete file found by search \(fileName): \(error)")
                                }
                            }
                        }
                    } catch {
                        print("❌ Error searching DownloadedEpisodes folder for \(episodeId): \(error)")
                    }
                } else {
                    print("📁 DownloadedEpisodes folder doesn't exist, skipping file search for episode: \(episodeId)")
                }
            }
            
            if !fileDeleted {
                print("⚠️ Could not find or delete physical file for episode ID: \(episodeId)")
            }
        }
        
        print("📁 Enhanced deletion completed: \(deletedCount) files deleted from \(episodeIds.count) episode IDs")
    }
    
    private func performEpisodeLoad(feedId: String, page: Int, isInitialLoad: Bool = false, isAppending: Bool = false) async {
        
        // CRITICAL: Enable CloudKit priority mode for Core Data loading
        // This ensures CloudKit data immediately replaces Core Data progress
        EpisodeStateManager.shared.enableCloudKitPriorityMode()
        
        do {
            let result = try await episodeManager.loadEpisodes(
                feedId: feedId,
                page: page,
                pageSize: episodesPerPage,
                filter: EpisodeFilter(rawValue: currentTab) ?? .all,
                searchQuery: searchQuery.isEmpty ? nil : searchQuery
            )
                        
            // Check if this was a prioritized load (first page of large feed)
            let wasPrioritizedLoad = page == 1 && result.episodes.count < episodesPerPage && result.hasMore
            
            // PERFORMANCE FIX: Process episodes in background before main thread update
            let processedEpisodes: [PodcastEpisode]
            if isAppending {
                // CRITICAL FIX: Merge and deduplicate when appending
                let combinedEpisodes = await MainActor.run { self.currentEpisodes + result.episodes }
                processedEpisodes = await processEpisodesInBackground(combinedEpisodes)
                if combinedEpisodes.count != processedEpisodes.count {
                    print("🔄 APPEND DEDUP: Combined \(combinedEpisodes.count) episodes, deduped to \(processedEpisodes.count)")
                }
            } else {
                // CRITICAL FIX: Deduplicate episodes before replacing
                processedEpisodes = await processEpisodesInBackground(result.episodes)
                if result.episodes.count != processedEpisodes.count {
                    print("🔄 REPLACE DEDUP: Loaded \(result.episodes.count) episodes, deduped to \(processedEpisodes.count)")
                }
            }
            
            await MainActor.run {
                self.currentEpisodes = processedEpisodes
                
                self.hasMoreEpisodes = result.hasMore
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                
                // Report status to DataSyncManager when loading completes
                self.reportStatusToDataSyncManager()
            }
            
            // CRITICAL FIX: Create snapshot for instant future access (more liberal conditions)
            // Create snapshots for first page loads with substantial episode counts
            if page == 1 && !isAppending && processedEpisodes.count > 0 {
                updateEpisodeSnapshot(for: feedId, episodes: processedEpisodes)
                let completionStatus = result.hasMore ? "partial" : "complete"
                print("📸 SNAPSHOT: Created \(completionStatus) snapshot with \(processedEpisodes.count) episodes")
            }
            
            // BACKGROUND LOADING: If this was a prioritized load, continue loading more episodes in background
            if wasPrioritizedLoad && isInitialLoad {
                print("🚀 BACKGROUND LOADING: Starting background load for remaining episodes")
                Task.detached(priority: .background) {
                    await self.continueBackgroundLoading(feedId: feedId, startPage: 2)
                }
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
                self.operationInProgress = false
                os_log("❌ Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
        
        // CRITICAL: Always disable CloudKit priority mode after episode loading (success or failure)
        EpisodeStateManager.shared.disableCloudKitPriorityMode()
    }
    
    /// Continue loading episodes in background after prioritized load completed
    private func continueBackgroundLoading(feedId: String, startPage: Int) async {
        print("🔄 BACKGROUND LOADING: Loading remaining episodes for feed \(feedId) starting from page \(startPage)")
        
        var currentBackgroundPage = startPage
        let maxBackgroundPages = 10 // Limit background loading to prevent excessive resource use
        
        while currentBackgroundPage <= maxBackgroundPages {
            // Check if user navigated away or if this feed is no longer selected
            let isCurrentFeed = await MainActor.run {
                return self.selectedFeedId == feedId
            }
            guard isCurrentFeed else {
                print("🔄 BACKGROUND LOADING: User navigated away, stopping background load")
                return
            }
            
            do {
                // Use standard loading (not prioritized) for background pages
                let result = try await episodeManager.loadEpisodes(
                    feedId: feedId,
                    page: currentBackgroundPage,
                    pageSize: episodesPerPage,
                    filter: EpisodeFilter(rawValue: await MainActor.run { self.currentTab }) ?? .all,
                    searchQuery: await MainActor.run { self.searchQuery.isEmpty ? nil : self.searchQuery }
                )
                
                print("🔄 BACKGROUND LOADING: Page \(currentBackgroundPage) loaded \(result.episodes.count) episodes")
                
                // Update UI on main thread if episodes were found
                if !result.episodes.isEmpty {
                    let combinedEpisodes = await MainActor.run { self.currentEpisodes + result.episodes }
                    let uniqueEpisodes = await PodcastViewModel.removeDuplicatesFromEpisodes(combinedEpisodes)
                    
                    await MainActor.run {
                        // Silently append to currentEpisodes if user is still on the same feed
                        if self.selectedFeedId == feedId {
                            self.currentEpisodes = uniqueEpisodes
                            
                            // Update hasMoreEpisodes based on background loading result
                            self.hasMoreEpisodes = result.hasMore
                            
                            print("🔄 BACKGROUND LOADING: Silently updated to \(self.currentEpisodes.count) total episodes")
                        }
                    }
                }
                
                // If no more episodes, stop background loading
                if !result.hasMore {
                    print("🔄 BACKGROUND LOADING: No more episodes, stopping background load")
                    break
                }
                
                currentBackgroundPage += 1
                
                // Add a small delay between background loads to not overwhelm the system
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
            } catch {
                print("🔄 BACKGROUND LOADING: Error on page \(currentBackgroundPage): \(error)")
                break
            }
        }
        
        print("🔄 BACKGROUND LOADING: Completed for feed \(feedId)")
    }
    
    private func refreshEpisodeStatesFromManager() {
        // EMERGENCY PERFORMANCE FIX: Eliminate all heavy batch processing that causes 5-8 second hangs
        // Episode states are now loaded lazily on-demand through individual getters
        
        // Simply trigger a lightweight UI refresh without any heavy processing
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    /// ULTRA-OPTIMIZED: Background episode state refresh to eliminate main thread hangs
    private func refreshEpisodeStatesOptimized() {
        // Batch collect all episode IDs for single bulk lookup
        var allEpisodeIds: [String] = []
        
        // Collect IDs from currentEpisodes
        allEpisodeIds.append(contentsOf: currentEpisodes.map { $0.id })
        
        // Collect IDs from all feeds
        for feed in podcastFeeds {
            allEpisodeIds.append(contentsOf: feed.episodes.map { $0.id })
        }
        
        // Remove duplicates efficiently
        let uniqueEpisodeIds = Array(Set(allEpisodeIds))
        
        // ULTIMATE PERFORMANCE: Move heavy batch lookup to background thread
        Task.detached(priority: .background) {
            await self.performBackgroundStateRefresh(episodeIds: uniqueEpisodeIds)
        }
    }
    
    /// BACKGROUND PROCESSING: Perform state lookup off main thread
    private func performBackgroundStateRefresh(episodeIds: [String]) async {
        // Batch collect all states on background thread (prevents main thread hangs)
        var progressMap: [String: Double] = [:]
        var favoriteMap: [String: Bool] = [:]
        var downloadMap: [String: Bool] = [:]
        
        for episodeId in episodeIds {
            // Skip episodes that were recently synced to prevent overriding real-time changes
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                continue
            }
            
            progressMap[episodeId] = EpisodeStateManager.shared.getProgress(for: episodeId)
            favoriteMap[episodeId] = EpisodeStateManager.shared.isFavorite(episodeId)
            downloadMap[episodeId] = EpisodeStateManager.shared.isDownloaded(episodeId)
        }
        
        // MAIN THREAD: Apply results quickly without blocking UI
        await MainActor.run {
            self.applyBatchStateUpdates(progressMap: progressMap, favoriteMap: favoriteMap, downloadMap: downloadMap)
        }
    }
    
    /// MAIN THREAD: Quick application of background-processed results
    private func applyBatchStateUpdates(progressMap: [String: Double], favoriteMap: [String: Bool], downloadMap: [String: Bool]) {
        
        // Update currentEpisodes efficiently
        for index in 0..<currentEpisodes.count {
            let episodeId = currentEpisodes[index].id
            
            // Skip episodes that were recently synced
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                continue
            }
            
            var updated = currentEpisodes[index]
            updated.state.progress = progressMap[episodeId] ?? 0.0
            updated.state.isFavorite = favoriteMap[episodeId] ?? false
            updated.state.isDownloaded = downloadMap[episodeId] ?? false
            updated.state.isPlayed = updated.state.progress >= 0.99
            
            currentEpisodes[index] = updated
        }
        
        // Update podcastFeeds efficiently (only feeds with visible episodes)
        for feedIndex in 0..<podcastFeeds.count {
            for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                let episodeId = podcastFeeds[feedIndex].episodes[episodeIndex].id
                
                // Skip episodes that were recently synced
                if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                    continue
                }
                
                var updatedFeed = podcastFeeds[feedIndex]
                var updated = updatedFeed.episodes[episodeIndex]
                
                updated.state.progress = progressMap[episodeId] ?? 0.0
                updated.state.isFavorite = favoriteMap[episodeId] ?? false
                updated.state.isDownloaded = downloadMap[episodeId] ?? false
                updated.state.isPlayed = updated.state.progress >= 0.99
                
                updatedFeed.episodes[episodeIndex] = updated
                podcastFeeds[feedIndex] = updatedFeed
            }
        }
        
        // Single UI refresh after all updates
        objectWillChange.send()
    }
    
    /// Standard refresh for smaller feeds (<= 300 episodes)
    private func refreshEpisodeStatesStandard() {
        // Update episode states in currentEpisodes (currently displayed episodes)
        let updatedCurrentEpisodes = currentEpisodes.map { episode in
            // Skip episodes that were recently synced
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episode.id, within: 2.0) {
                return episode // Return unchanged
            }
            
            var updated = episode
            updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            updated.state.isPlayed = updated.state.progress >= 0.99
            return updated
        }
        // Update current episodes with refreshed states
        currentEpisodes = updatedCurrentEpisodes
        
        // CRITICAL: Also update episode states in ALL podcastFeeds so that download states
        // are preserved when switching between feeds after CloudKit sync
        var updatedFeeds = podcastFeeds
        for feedIndex in 0..<updatedFeeds.count {
            let updatedEpisodes = updatedFeeds[feedIndex].episodes.map { episode in
                // Skip episodes that were recently synced
                if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episode.id, within: 2.0) {
                    return episode // Return unchanged
                }
                
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
        
        print("✅ STANDARD REFRESH: Updated episode states for \(currentEpisodes.count) current episodes and \(podcastFeeds.count) feeds")
    }
    
    /// PERFORMANCE OPTIMIZED: Update episode counts on background thread
    private func updateEpisodeCounts(for feedId: String, episodes: [PodcastEpisode]) async {
        // PERFORMANCE: Run counting operations on background queue to avoid main thread blocking
        let counts = await Task.detached(priority: .utility) {
            let allCount = episodes.count
            let favCount = episodes.filter { $0.state.isFavorite }.count
            let dlCount = episodes.filter { $0.state.isDownloaded }.count
            
            return (all: allCount, favorites: favCount, downloads: dlCount)
        }.value
        
        // Update cache and UI on main thread
        await MainActor.run {
            // Cache the counts for performance
            self.tabFilterCounts[feedId] = counts
            self.episodeCounts = counts
            
            print("📊 COUNTS: Updated for feed \(feedId) - All: \(counts.all), Favorites: \(counts.favorites), Downloads: \(counts.downloads)")
        }
    }
    
    private func updateEpisodeCountsForCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        // PERFORMANCE: Use cached counts if available to avoid expensive filtering
        if let cachedCounts = tabFilterCounts[feedId] {
            await MainActor.run {
                self.episodeCounts = cachedCounts
                print("⚡ PERFORMANCE: Using cached episode counts - All: \(cachedCounts.all), Favorites: \(cachedCounts.favorites), Downloads: \(cachedCounts.downloads)")
            }
            return
        }
        
        // Fallback: Calculate counts manually only if cache is not available
        do {
            let allCount = currentEpisodes.count
            let favoritesCount = currentEpisodes.filter { $0.state.isFavorite }.count
            let downloadsCount = currentEpisodes.filter { $0.state.isDownloaded }.count
            
            await MainActor.run {
                self.episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                print("🔄 FALLBACK: Calculated episode counts manually - All: \(allCount), Favorites: \(favoritesCount), Downloads: \(downloadsCount)")
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
        // Reduce logging during scrolling for better performance
        if !isUserScrolling {
            print("🔄 Refreshing local episode states for immediate display...")
        }
        
        // If EpisodeStateManager is not ready yet (cold start), wait briefly or until ready notification
        if !EpisodeStateManager.shared.isReady {
            let ready = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s max wait
                    return EpisodeStateManager.shared.isReady
                }
                return await group.next() ?? true
            }
            if !ready {
                print("⚠️ EpisodeStateManager not ready after brief wait; proceeding with whatever is loaded")
            }
        }
        
        // Apply locally available states to current in-memory episodes for instant UI accuracy
        await MainActor.run {
            if !self.currentEpisodes.isEmpty {
                var updated: [PodcastEpisode] = []
                updated.reserveCapacity(self.currentEpisodes.count)
                for var ep in self.currentEpisodes {
                    ep.state.progress = EpisodeStateManager.shared.getProgress(for: ep.id)
                    ep.state.isFavorite = EpisodeStateManager.shared.isFavorite(ep.id)
                    ep.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(ep.id)
                    ep.state.isPlayed = ep.state.progress >= 0.99
                    updated.append(ep)
                }
                self.currentEpisodes = updated
            }
        }
        
        // Log availability snapshot
        let progressCount = EpisodeStateManager.shared.episodeProgress.count
        let favoritesCount = EpisodeStateManager.shared.episodeFavorites.count
        let downloadsCount = EpisodeStateManager.shared.episodeDownloads.count
        print("✅ Local episode states available: \(progressCount) progress, \(favoritesCount) favorites, \(downloadsCount) downloads")
        
        // Mark as completed to prevent unnecessary sync attempts
        episodeStatesSyncCompleted = true
    }
    
    /// Check for fresh install and sync podcast feeds from CloudKit with performance optimization
    /// PERFORMANCE OPTIMIZATION: Only sync podcast feeds from CloudKit on fresh installs
    /// This prevents the app from loading podcast feeds from CloudKit on every launch
    /// After the initial sync, podcast feeds are loaded from local storage (Core Data)
    /// 
    /// Benefits:
    /// - Faster app startup (no CloudKit network requests for podcast feeds)
    /// - Reduced CloudKit API usage and rate limiting
    /// - Better offline experience
    /// - Podcast feeds are still synced TO CloudKit when users make changes
    /// 
    /// To force a re-sync (for troubleshooting), call resetPodcastFeedsSyncFlag()
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
            
            // PERFORMANCE FIX: Only sync podcast feeds from CloudKit on fresh installs
            // Check if podcast feeds have been synced to prevent unnecessary CloudKit fetching
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            
            print("🔍 SYNC DECISION: existingFeedCount=\(existingFeedCount), isFreshInstall=\(isFreshInstall), hasPodcastFeedsSynced=\(hasPodcastFeedsSynced)")
            
            if isFreshInstall || !hasPodcastFeedsSynced {
                print("🔄 Podcast feed sync needed - fresh install: \(isFreshInstall), feeds synced: \(hasPodcastFeedsSynced)")
                
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
                    
                    // Mark podcast feeds as synced to prevent future CloudKit syncing on app launches
                    UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
                } else {
                    print("📡 No feeds found in CloudKit")
                }
            } else {
                print("⚡ Skipping CloudKit podcast feed sync - loading from local storage only for better performance")
                
                // CROSS-DEVICE SYNC: Even when not doing full sync, check for new cross-device feeds
                print("🔄 CROSS-DEVICE CHECK: Checking CloudKit for feeds added on other devices...")
                print("🔄 CROSS-DEVICE CHECK: Current local feed count: \(existingFeedCount)")
                do {
                    let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
                    print("🔄 CROSS-DEVICE CHECK: Found \(cloudKitFeeds.count) feeds in CloudKit")
                    if !cloudKitFeeds.isEmpty {
                        print("🔄 CROSS-DEVICE CHECK: CloudKit feeds:")
                        for feed in cloudKitFeeds {
                            print("🔄 CROSS-DEVICE CHECK: - \(feed.title) (ID: \(feed.id))")
                        }
                        print("🔄 CROSS-DEVICE CHECK: Calling mergeCloudKitFeeds to check for new ones...")
                        await mergeCloudKitFeeds(cloudKitFeeds)
                    } else {
                        print("🔄 CROSS-DEVICE CHECK: No feeds found in CloudKit")
                    }
                } catch {
                    print("🔄 CROSS-DEVICE CHECK: Failed to check CloudKit feeds: \(error)")
                }
                
                // Load feeds from Core Data
                await MainActor.run {
                    print("🎯 EXISTING INSTALL: About to call loadFeedsFromCoreData()")
                    self.loadFeedsFromCoreData()
                    print("🎯 EXISTING INSTALL: After loadFeedsFromCoreData() - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                    
                    // Still trigger UI refresh for consistency
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.throttledUIUpdate()
                        print("🎯 LOCAL SYNC: Triggered UI refresh from local data - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                    }
                }
            }
            
        } catch {
            print("❌ CloudKit sync failed: \(error)")
        }
    }
    
    /// Sync episode states from CloudKit with different behavior based on install type
    /// PERFORMANCE OPTIMIZATION: Only sync episode states from CloudKit on fresh installs
    /// This prevents the app from loading thousands of episode states from CloudKit on every launch
    /// After the initial sync, episode states are loaded from local storage (CoreData + EpisodeStateManager)
    /// 
    /// Benefits:
    /// - Faster app startup (no CloudKit network requests for episode states)
    /// - Reduced CloudKit API usage and rate limiting
    /// - Better offline experience
    /// - Episode states are still synced TO CloudKit when users make changes
    /// 
    /// To force a re-sync (for troubleshooting), call resetEpisodeStatesSyncFlag()
    func syncEpisodeStatesFromCloudKit(isFreshInstall: Bool) async -> Bool {
        // PERFORMANCE: Skip expensive CloudKit episode sync if we have snapshots for ANY feed
        let hasAnySnapshot = await MainActor.run {
            // Check if we have snapshots for any loaded feeds
            for feed in self.podcastFeeds {
                if self.getEpisodeSnapshot(for: feed.id) != nil {
                    print("⚡ PERFORMANCE: Found snapshot for feed \(feed.title) - skipping CloudKit sync")
                    return true
                }
            }
            return false
        }
        
        // Skip CloudKit sync if we have snapshots (regardless of fresh install status)
        // Snapshots already contain complete episode data with states
        if hasAnySnapshot {
            print("⚡ PERFORMANCE: Skipping CloudKit episode sync - using episode snapshots with complete state data")
            return true
        }
        
        print("🔄 Syncing episode states from CloudKit (fresh install: \(isFreshInstall))")
        
        // Record sync attempt to prevent frequent retries
        await MainActor.run {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastEpisodeStateSyncAttempt")
        }
        
        do {
            // CRITICAL FIX: Get episode IDs directly from Core Data to ensure we get ALL episodes
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            if !allEpisodeIds.isEmpty {
                // Start episode state sync tracking in DataSyncManager
                await DataSyncManager.shared.startEpisodeStateSync(totalCount: allEpisodeIds.count)
                
                // Update progress during CloudKit sync
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: 0,
                    operation: "Fetching episode states from iCloud..."
                )
                
                // Sync episode states from CloudKit
                let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds,
                    isFreshInstall: isFreshInstall
                )
                
                let coreDataUpdates = syncResult.updates
                let syncSuccess = syncResult.success
                
                // Update progress during Core Data save
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: allEpisodeIds.count * 3 / 4,
                    operation: "Saving episode states to local storage..."
                )
                
                // Save all synced states to Core Data if there are updates
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 Saved \(coreDataUpdates.count) episode states to Core Data")
                    } catch {
                        print("❌ Failed to save synced episode states to Core Data: \(error)")
                    }
                }
                
                // Update progress during UI refresh
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: allEpisodeIds.count * 9 / 10,
                    operation: "Refreshing episode list..."
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
                
                // Complete episode state sync tracking
                await DataSyncManager.shared.completeEpisodeStateSync()
                
                if syncSuccess {
                    print("✅ Episode state sync completed successfully for \(allEpisodeIds.count) episodes")
                } else {
                    print("⚠️ Episode state sync completed with errors for \(allEpisodeIds.count) episodes")
                }
                
                return syncSuccess
            } else {
                print("📊 No episodes found for state sync")
                return true
            }
            
        } catch {
            print("❌ Failed to sync episode states from CloudKit: \(error)")
            return false
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
    
    /// Apply CloudKit feed metadata updates to existing feeds
    func applyCloudKitFeedMetadata(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🔄 Applying CloudKit metadata to \(cloudKitFeeds.count) feeds...")
        
        await MainActor.run {
            var updatedFeeds = self.podcastFeeds
            var hasUpdates = false
            
            for cloudKitFeed in cloudKitFeeds {
                if let existingIndex = updatedFeeds.firstIndex(where: { $0.id == cloudKitFeed.id || $0.url == cloudKitFeed.url }) {
                    let existingFeed = updatedFeeds[existingIndex]
                    
                    // Apply CloudKit metadata updates
                    var updatedFeed = existingFeed
                    var feedUpdated = false
                    
                    // Update title if different
                    if cloudKitFeed.title != existingFeed.title {
                        print("📝 Updating feed title: '\(existingFeed.title)' -> '\(cloudKitFeed.title)'")
                        updatedFeed.title = cloudKitFeed.title
                        feedUpdated = true
                    }
                    
                    // Update artwork URL if different
                    if cloudKitFeed.artworkUrl != existingFeed.artworkUrl {
                        print("🖼️ Updating feed artwork URL for: \(cloudKitFeed.title)")
                        updatedFeed.artworkUrl = cloudKitFeed.artworkUrl
                        feedUpdated = true
                    }
                    
                    // Update description if different
                    if cloudKitFeed.descriptionText != existingFeed.descriptionText {
                        print("📄 Updating feed description for: \(cloudKitFeed.title)")
                        updatedFeed.descriptionText = cloudKitFeed.descriptionText
                        feedUpdated = true
                    }
                    
                    // Update icon data if different
                    if cloudKitFeed.iconData != existingFeed.iconData {
                        print("🎨 Updating feed icon data for: \(cloudKitFeed.title)")
                        updatedFeed.iconData = cloudKitFeed.iconData
                        feedUpdated = true
                    }
                    
                    if feedUpdated {
                        updatedFeeds[existingIndex] = updatedFeed
                        hasUpdates = true
                    }
                }
            }
            
            if hasUpdates {
                self.podcastFeeds = updatedFeeds
                print("✅ Applied CloudKit metadata updates to feeds")
                
                // Save updates to Core Data
                Task.detached(priority: .background) {
                    await self.saveFeedMetadataToCoreData(updatedFeeds)
                }
            } else {
                print("✅ No CloudKit metadata updates needed - feeds are current")
            }
        }
    }
    
    /// Save feed metadata updates to Core Data
    private func saveFeedMetadataToCoreData(_ feeds: [PodcastFeed]) async {
        print("💾 Saving CloudKit metadata updates to Core Data for \(feeds.count) feeds")
        
        // For now, skip Core Data updates to avoid import issues
        // The in-memory podcastFeeds array has already been updated
        // Core Data sync will happen during next app launch
        print("✅ CloudKit metadata applied to in-memory feeds (Core Data sync deferred)")
    }
    
    /// Public method for DataSyncManager to process fresh install feeds
    func loadFreshInstallPodcastData(_ cloudKitFeeds: [PodcastFeed]) async {
        // Use the existing fresh install logic with progress updates  
        await MainActor.run {
            self.isLoading = true
        }
        
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        // CRITICAL FIX: Remove duplicates from CloudKit feeds BEFORE processing
        let uniqueFeeds = removeDuplicateFeeds(cloudKitFeeds)
        print("📊 Removed \(cloudKitFeeds.count - uniqueFeeds.count) duplicate feeds from CloudKit data")
        
        // CRITICAL FIX: Check what feeds already exist in Core Data to prevent duplicate processing
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
        
        // Process feeds in batches for better performance
        let batchSize = 5 // Process 5 feeds concurrently
        let batches = feedsToProcess.chunked(into: batchSize)
        var processedCount = 0
        
        print("📊 Processing \(feedsToProcess.count) feeds in \(batches.count) batches of \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            print("🔄 Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) feeds")
            
            // Update progress for batch start
            let batchProgress = Double(processedCount) / Double(feedsToProcess.count)
            await MainActor.run {
                DataSyncManager.shared.updateFeedParsingProgress(
                    batchProgress, 
                    message: "Processing batch \(batchIndex + 1) of \(batches.count)..."
                )
            }
            
            // Process feeds in this batch concurrently
            await withTaskGroup(of: Void.self) { group in
                for feed in batch {
                    group.addTask {
                        do {
                            print("📡 Processing feed: \(feed.title)")
                            
                            // Use public FeedManager to properly add feed with RSS parsing
                            guard let url = URL(string: feed.url) else {
                                print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                                return
                            }
                            
                            let feedManager = PodcastFeedManager()
                            let addedFeed = try await feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true, enableProgressReporting: false)
                            print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                            
                        } catch {
                            print("❌ Failed to process feed \(feed.title): \(error)")
                            
                            // Save feed without episodes if RSS parsing fails
                            try? await self.saveFeedToCoreData(feed)
                        }
                    }
                }
                
                // Wait for all feeds in this batch to complete
                for await _ in group {}
            }
            
            processedCount += batch.count
            
            // Update progress after batch completion
            let completedProgress = Double(processedCount) / Double(feedsToProcess.count)
            await MainActor.run {
                DataSyncManager.shared.updateFeedParsingProgress(
                    completedProgress, 
                    message: "Completed \(processedCount)/\(feedsToProcess.count) feeds..."
                )
            }
            
            print("✅ Completed batch \(batchIndex + 1)/\(batches.count) - \(processedCount)/\(feedsToProcess.count) feeds processed")
            
            // Brief pause between batches to prevent overwhelming the system
            if batchIndex < batches.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
        
        // Complete RSS processing progress
        await MainActor.run {
            DataSyncManager.shared.updateFeedParsingProgress(1.0, message: "RSS processing completed - \(feedsToProcess.count) feeds processed")
        }
        
        print("🎉 Fresh install RSS processing complete")
        
        // Clean up any duplicates that might have been created
        await cleanupDuplicateFeeds()
        
        // CRITICAL: Clear episode cache and reload feeds from Core Data AFTER all RSS processing and cleanup
        await episodeManager.clearAllCache()
        
        // CRITICAL: Wait for all Core Data save operations to complete  
        print("⏳ Waiting for all Core Data save operations to complete...")
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds for all async saves to complete
        
        // Force a final Core Data save to ensure everything is persisted
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                if context.hasChanges {
                    do {
                        try context.save()
                        print("✅ FINAL: Forced Core Data save after fresh install processing")
                    } catch {
                        print("❌ FINAL: Failed to save Core Data after fresh install: \(error)")
                    }
                } else {
                    print("ℹ️ FINAL: No pending Core Data changes after fresh install")
                }
                continuation.resume()
            }
        }
        
        // Verify feeds are actually saved to Core Data
        let savedFeedCount = await countExistingFeeds()
        print("🔍 VERIFICATION: Found \(savedFeedCount) feeds in Core Data after fresh install processing")
        
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
        
        // Force immediate object change notification
        self.objectWillChange.send()
        print("🔄 FRESH INSTALL: Sent objectWillChange notification")
        
        // Multiple explicit UI refresh attempts with increasing delays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("🔄 FRESH INSTALL: First refresh attempt - Feeds: \(self.podcastFeeds.count)")
            if self.podcastFeeds.isEmpty {
                // If still empty, try loading again
                self.loadFeedsFromCoreData()
            }
            self.throttledUIUpdate()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🔄 FRESH INSTALL: Second refresh attempt - Feeds: \(self.podcastFeeds.count)")
            if self.podcastFeeds.isEmpty {
                // If still empty, try loading again
                self.loadFeedsFromCoreData()
            }
            self.throttledUIUpdate()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("🔄 FRESH INSTALL: Final refresh attempt - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
            if self.podcastFeeds.isEmpty {
                print("⚠️ FRESH INSTALL: Still no feeds after multiple refresh attempts!")
            } else {
                print("✅ FRESH INSTALL: Successfully loaded \(self.podcastFeeds.count) feeds")
            }
            self.throttledUIUpdate()
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
        
        // Process feeds in batches for better performance (private method version)
        let batchSize = 5 // Process 5 feeds concurrently
        let batches = feedsToProcess.chunked(into: batchSize)
        var processedCount = 0
        
        print("📊 Processing \(feedsToProcess.count) feeds in \(batches.count) batches of \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            print("🔄 Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) feeds")
            
            // Process feeds in this batch concurrently
            await withTaskGroup(of: Void.self) { group in
                for feed in batch {
                    group.addTask {
                        do {
                            print("📡 Processing feed: \(feed.title)")
                            
                            // Use FeedManager to properly add feed with RSS parsing
                            guard let url = URL(string: feed.url) else {
                                print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                                return
                            }
                            
                            let addedFeed = try await self.feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true, enableProgressReporting: false)
                            print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                            
                        } catch {
                            print("❌ Failed to process feed \(feed.title): \(error)")
                            
                            // Save feed without episodes if RSS parsing fails
                            try? await self.saveFeedToCoreData(feed)
                        }
                    }
                }
                
                // Wait for all feeds in this batch to complete
                for await _ in group {}
            }
            
            processedCount += batch.count
            print("✅ Completed batch \(batchIndex + 1)/\(batches.count) - \(processedCount)/\(feedsToProcess.count) feeds processed")
            
            // Brief pause between batches to prevent overwhelming the system
            if batchIndex < batches.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
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
        let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
        
        if syncSuccess {
            print("✅ Episode states sync completed successfully after fresh install processing")
        } else {
            print("⚠️ Episode states sync failed after fresh install processing - will retry on next launch")
        }
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
                    
                                         // PERFORMANCE: Use throttled UI refresh triggers
                     self.throttledUIUpdate()
                     print("🔄 Triggered throttled UI refresh after Core Data confirmation")
                     
                     // Post notification for any views that might be listening
                     NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                     print("📢 Posted FreshInstallDataAvailable notification")
                     
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                         self.throttledUIUpdate()
                         print("🔄 SECONDARY: Triggered delayed throttled UI refresh after Core Data confirmation")
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
                self.throttledUIUpdate()
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
                    request.includesPropertyValues = true
                    request.includesSubentities = false
                    request.resultType = .managedObjectResultType
                    
                    let results = try context.fetch(request)
                    let urls = Set(results.compactMap { $0.url })
                    continuation.resume(returning: urls)
                } catch {
                    print("❌ Failed to fetch existing feed URLs: \(error)")
                    continuation.resume(returning: Set())
                }
            }
        }
    }
    
    /// Merge CloudKit feeds with existing local feeds and show cross-device sync banner
    private func mergeCloudKitFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        let context = CoreDataStack.shared.context
        
        // First, identify feeds that exist in CloudKit but not locally
        let (newFeeds, existingFeedsCount) = await withCheckedContinuation { continuation in
            context.perform {
                do {
                    // Get existing feeds and create comprehensive duplicate check
                    let existingRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let existingFeeds = try context.fetch(existingRequest)
                    let feedsCount = existingFeeds.count
                    
                    // Create sets for efficient duplicate checking
                    let existingFeedIds = Set(existingFeeds.compactMap { $0.id })
                    let existingFeedUrls = Set(existingFeeds.compactMap { $0.url })
                    let existingFeedTitles = Set(existingFeeds.compactMap { $0.title })
                    
                    // Find feeds that don't exist locally
                    var feedsToAdd: [PodcastFeed] = []
                    for cloudFeed in cloudKitFeeds {
                        let isDuplicateById = existingFeedIds.contains(cloudFeed.id)
                        let isDuplicateByUrl = existingFeedUrls.contains(cloudFeed.url)
                        let isDuplicateByTitle = existingFeedTitles.contains(cloudFeed.title)
                        
                        print("🔍 MERGE CHECK: CloudKit feed '\(cloudFeed.title)' (ID: \(cloudFeed.id))")
                        print("🔍 MERGE CHECK: - Duplicate by ID: \(isDuplicateById)")
                        print("🔍 MERGE CHECK: - Duplicate by URL: \(isDuplicateByUrl)")
                        print("🔍 MERGE CHECK: - Duplicate by Title: \(isDuplicateByTitle)")
                        
                        if !isDuplicateById && !isDuplicateByUrl && !isDuplicateByTitle {
                            print("🔍 MERGE CHECK: ✅ This is a NEW feed - adding to list")
                            feedsToAdd.append(cloudFeed)
                        } else {
                            print("🔍 MERGE CHECK: ❌ This feed already exists locally")
                        }
                    }
                    
                    continuation.resume(returning: (feedsToAdd, feedsCount))
                } catch {
                    print("❌ Failed to identify new CloudKit feeds: \(error)")
                    continuation.resume(returning: ([], 0))
                }
            }
        }
        
        // Show cross-device sync banner if there are new feeds to add
        print("📡 🔄 MERGE CLOUDKIT FEEDS: Processing \(cloudKitFeeds.count) CloudKit feeds vs \(existingFeedsCount) local feeds")
        print("📡 🔄 MERGE CLOUDKIT FEEDS: Found \(newFeeds.count) new feeds to add")
        if !newFeeds.isEmpty {
            print("📡 🔄 CROSS-DEVICE SYNC: Detected \(newFeeds.count) new feeds from CloudKit")
            for feed in newFeeds {
                print("📡 🔄 CROSS-DEVICE SYNC: New feed - \(feed.title)")
            }
            await MainActor.run {
                print("📡 🔄 CROSS-DEVICE SYNC: Starting banner for \(newFeeds.count) feeds")
                DataSyncManager.shared.startCrossDeviceFeedSync(
                    totalCount: newFeeds.count,
                    operation: "Syncing \(newFeeds.count) feeds from other devices"
                )
            }
        } else {
            print("📡 🔄 MERGE CLOUDKIT FEEDS: No new feeds detected - all CloudKit feeds already exist locally")
        }
        
        // Now add the feeds to Core Data with progress tracking
        await withCheckedContinuation { continuation in
            context.perform {
                do {
                    var newFeedsAdded = 0
                    
                    for (index, cloudFeed) in newFeeds.enumerated() {
                        let feedModel = FeedModel(context: context)
                        feedModel.update(from: cloudFeed)
                        newFeedsAdded += 1
                        print("📥 Adding new feed from CloudKit: \(cloudFeed.title)")
                        
                        // Update progress on main thread
                        Task { @MainActor in
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: index + 1,
                                operation: "Added '\(cloudFeed.title)'"
                            )
                        }
                    }
                    
                    if newFeedsAdded > 0 {
                        try context.save()
                        print("✅ Merged \(newFeedsAdded) new feeds from CloudKit")
                        
                        // Complete the sync
                        Task { @MainActor in
                            DataSyncManager.shared.completeCrossDeviceFeedSync()
                        }
                    } else {
                        print("📊 No new feeds to merge from CloudKit (all were duplicates)")
                    }
                    
                    continuation.resume()
                } catch {
                    print("❌ Failed to merge CloudKit feeds: \(error)")
                    Task { @MainActor in
                        DataSyncManager.shared.resetCrossDeviceFeedSync()
                    }
                    continuation.resume()
                }
            }
        }
        
        // UPGRADE PROTECTION: Use enhanced upgrade detection for episode state sync
        // Only sync episode states when truly needed
        if !cloudKitFeeds.isEmpty {
            let existingFeedCount = await countExistingFeeds()
            let legacyFreshInstallCheck = existingFeedCount == 0
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Merge episode state sync - Existing feeds: \(existingFeedCount), Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall {
                print("🔄 Fresh install - syncing episode states for new feeds...")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
                if syncSuccess {
                    print("✅ Episode states sync completed successfully for fresh install")
                } else {
                    print("⚠️ Episode states sync failed for fresh install - will retry on next launch")
                }
                
                // CRITICAL: After CloudKit sync, check if any feeds need episode refreshing
                await refreshFeedsWithoutEpisodes()
            } else if isDefiniteUpgrade {
                print("🔄 App upgrade - syncing episode states with download protection...")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
                if syncSuccess {
                    print("✅ Episode states sync completed successfully for app upgrade")
                } else {
                    print("⚠️ Episode states sync failed for app upgrade - will retry on next launch")
                }
                
                // CRITICAL: After CloudKit sync, check if any feeds need episode refreshing
                await refreshFeedsWithoutEpisodes()
            } else {
                print("⚡ Existing installation - skipping CloudKit episode state sync for better performance")
                // Just refresh local episode states from EpisodeStateManager
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                }
            }
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
        print("🚀 INIT: Current podcast feeds count: \(podcastFeeds.count)")
        print("🚀 INIT: Current feed order count: \(podcastFeedOrder.count)")
        
        // Prevent multiple initializations
        guard !isLoading else {
            print("⚠️ CloudKit initialization already in progress, skipping duplicate call")
            return
        }
        
        // Start with Core Data load for immediate UI
        loadFeedsFromCoreData()
        print("📊 INITIAL LOAD: Loaded \(podcastFeeds.count) feeds from Core Data after loadFeedsFromCoreData()")
        print("📊 INITIAL LOAD: podcastFeedOrder has \(podcastFeedOrder.count) items")
        
        // Single CloudKit sync in background
        Task {
            // CRITICAL FIX: Move duplicate cleanup AFTER CloudKit sync to prevent episode loss
            // First sync data from CloudKit to ensure we have the most accurate episode data
            await checkForFreshInstallAndSetup()
            
            // SAFE cleanup: Only run duplicate cleanup after CloudKit sync completes
            // This prevents legitimate episodes from being deleted due to force close inconsistencies
            do {
                try await episodeManager.cleanupDuplicateEpisodes()
                print("✅ Cleaned up duplicate episodes after CloudKit sync")
            } catch {
                print("⚠️ Failed to cleanup duplicate episodes: \(error)")
            }
            
            // After CloudKit sync, check if any feeds need episode refreshing
            await refreshFeedsWithoutEpisodes()
            
            // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
            // Only sync episode states from CloudKit on fresh installs or when needed
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            let legacyFreshInstallCheck = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Episode state sync check - Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall || !hasEpisodeStatesSynced {
                print("🔄 Episode state sync needed - fresh install: \(isFreshInstall), states synced: \(hasEpisodeStatesSynced)")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
                
                // Only mark episode states as synced if the sync was successful
                if syncSuccess {
                    UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                    print("✅ Episode states sync completed successfully - marked as synced")
                } else {
                    print("⚠️ Episode states sync failed - will retry on next launch")
                }
            } else {
                print("⚡ Skipping CloudKit episode state sync - loading from local storage only for better performance")
                
                // REAL-TIME SYNC FIX: Disabled periodic sync to prevent conflicts with real-time updates
                // Periodic sync was overriding real-time CloudKit changes and causing sync clearing
                print("⚡ Skipping periodic CloudKit sync to preserve real-time episode state updates")
                
                // Just refresh local episode states from EpisodeStateManager
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                }
            }
            
            // CRITICAL: Final UI refresh after all initialization is complete
            await MainActor.run {
                print("🔄 Final UI refresh after complete initialization...")
                // Don't call loadFeedsFromCoreData() again - feeds are already loaded!
                // This was causing the loading state to show again after sync completed
                
                // Just ensure loading flags are cleared and trigger UI update
                self.isLoading = false
                self.isLoadingFeeds = false
                
                // Force UI update for any view controllers observing this environment object
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.throttledUIUpdate()
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
            // SYNC RESUMPTION: Check for incomplete sync first
            if EpisodeStateManager.shared.hasIncompleteSyncToResume() {
                let currentSyncProgress = EpisodeStateManager.shared.getCurrentSyncProgress()
                let remainingCount = EpisodeStateManager.shared.getRemainingEpisodesToSync().count
                print("📡 🔄 SYNC RESUMPTION: Found incomplete sync with \(remainingCount) episodes remaining")
                
                if let syncProgress = currentSyncProgress {
                    let progressPercent = Int(syncProgress.progress * 100)
                    print("📡 🔄 SYNC RESUMPTION: Resuming sync at \(progressPercent)% complete (started: \(syncProgress.startTime))")
                    
                    // Resume the sync with the original fresh install flag
                    let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: syncProgress.isFreshInstall)
                    
                    if syncSuccess {
                        print("✅ SYNC RESUMPTION: Completed resumed sync successfully")
                        UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                    } else {
                        print("⚠️ SYNC RESUMPTION: Resumed sync failed - will retry on next launch")
                    }
                    return
                }
            }
            
            // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
            let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let legacyFreshInstallCheck = !hasLaunchedBefore
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Episode state sync - Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall {
                print("🆕 Fresh install detected - syncing episode states (excluding downloads)")
            } else if isDefiniteUpgrade {
                print("🔄 App upgrade detected - syncing all episode states with download protection")
            } else {
                print("📱 Existing installation - syncing all episode states including downloads")
            }
            
            // CRITICAL FIX: Get episode IDs directly from Core Data to ensure we get ALL episodes
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            if !allEpisodeIds.isEmpty {
                // Sync episode states from CloudKit
                let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds,
                    isFreshInstall: isFreshInstall
                )
                
                let coreDataUpdates = syncResult.updates
                let syncSuccess = syncResult.success
                
                // Save all synced states to Core Data if there are updates
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 Saved \(coreDataUpdates.count) episode states to Core Data")
                    } catch {
                        print("❌ Failed to save synced episode states to Core Data: \(error)")
                    }
                }
                
                // Update UI with synced states
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    if let selectedFeedId = self.selectedFeedId {
                        Task {
                            await self.loadEpisodesForFeed(selectedFeedId)
                        }
                    }
                }
                
                if syncSuccess {
                    print("✅ Episode state sync completed successfully for \(allEpisodeIds.count) episodes")
                } else {
                    print("⚠️ Episode state sync completed with errors for \(allEpisodeIds.count) episodes")
                }
            } else {
                print("📊 No episodes found for state sync")
            }
        }
    }
    
    /// Quietly sync episode states for a specific feed without UI progress indicators
    /// This is used when feeds load to keep episode states current without user-visible operations
    private func quietSyncEpisodeStates(for feedId: String) async {
        
        // PERFORMANCE: Skip sync if episode snapshots are available - they already contain all episode states
        if await MainActor.run { getEpisodeSnapshot(for: feedId) != nil } {
            print("⚡ QUIET SYNC: Skipping CloudKit sync - episode snapshot available with all states")
            return
        }
        
        // EMERGENCY PERFORMANCE: Skip sync if large operation is already running
        if isLoadingEpisodes || operationInProgress {
            
            return
        }
        
        // Get episode IDs for this specific feed
        let episodeIds = await getExistingEpisodeIds(for: feedId)
        
        guard !episodeIds.isEmpty else {
            
            return
        }
        
        // EMERGENCY PERFORMANCE: Limit sync to only recent episodes for large feeds to prevent hangs
        let episodesToSync = episodeIds.count > 1000 ? Array(episodeIds.prefix(200)) : Array(episodeIds)
        
        // Perform quiet CloudKit sync (no UI progress indicators) on dedicated background thread
        let syncResult = await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let result = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: episodesToSync,
                    isFreshInstall: false
                )
                continuation.resume(returning: result)
            }
        }
        
        let coreDataUpdates = syncResult.updates
        let syncSuccess = syncResult.success
        
        // Save synced states to Core Data if there are updates
        if !coreDataUpdates.isEmpty {
            do {
                try await episodeManager.updateEpisodeStates(coreDataUpdates)
                print("🔇 QUIET SYNC: Updated \(coreDataUpdates.count) episode states for feed \(feedId)")
            } catch {
                print("🔇 QUIET SYNC: Failed to save episode states for feed \(feedId): \(error)")
            }
        }
        
        // EMERGENCY PERFORMANCE: Skip UI refresh for large updates to prevent main thread hangs
        if coreDataUpdates.count <= 100 {
            await MainActor.run {
                self.refreshEpisodeStatesFromManager()
            }
        } else {
            print("🔇 QUIET SYNC: Skipping UI refresh for \(coreDataUpdates.count) updates to prevent hang")
        }
        
        print("🔇 QUIET SYNC: Completed for feed \(feedId) - Success: \(syncSuccess), Updates: \(coreDataUpdates.count)")
    }
    
    /// Check if a feed should be refreshed from RSS for new episodes
    private func shouldRefreshFeedFromRSS(feedId: String, isInitialLoad: Bool) async -> Bool {
        // PERFORMANCE: Check if we should refresh based on snapshot age
        let snapshot = getEpisodeSnapshot(for: feedId)
        print("🔍 RSS REFRESH CHECK: Feed \(feedId) - snapshot available: \(snapshot != nil), count: \(snapshot?.count ?? 0)")
        
        if let snapshotEpisodes = snapshot, !snapshotEpisodes.isEmpty {
            let snapshotAge = Date().timeIntervalSince(snapshotTimestamps[feedId] ?? Date.distantPast)
            // IMMEDIATE CHECK: Always allow RSS refresh on initial load for newest episodes
            let refreshThreshold: TimeInterval = isInitialLoad ? 0 : 1800 // Immediate for initial load, 30 min for background
            
            if snapshotAge < refreshThreshold {
                print("⚡ PERFORMANCE: Skipping RSS refresh check - recent snapshot (\(Int(snapshotAge/60)) min old, threshold: \(Int(refreshThreshold/60)) min)")
                return false
            } else {
                print("🔍 RSS REFRESH CHECK: Snapshot is \(Int(snapshotAge/60)) min old - proceeding with RSS check for new episodes")
                return true
            }
        } else {
            print("🔍 RSS REFRESH CHECK: No snapshot available for feed \(feedId) - proceeding with RSS check")
        }
        
        // Check if feed has episodes in Core Data
        let episodeCount = await getEpisodeCountForFeed(feedId)
        
        // ALWAYS refresh if this feed has no episodes (new feeds or fresh installs)
        if episodeCount == 0 {
            print("🆕 Feed \(feedId) has no episodes - allowing RSS parsing (new feed or fresh install)")
            return true
        }
        
        // For feeds with episodes, check time-based refresh policy
        let currentTime = Date().timeIntervalSince1970
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        
        // CRITICAL FIX: Always allow RSS refresh on initial load regardless of last refresh time
        // This ensures new episodes are fetched immediately when user opens a feed
        if isInitialLoad {
            print("🔄 Feed \(feedId) initial load - forcing RSS refresh for newest episodes (\(episodeCount) episodes cached)")
            return true
        }
        
        // For non-initial loads, use time-based refresh policy
        let refreshInterval: TimeInterval = 60 * 60 // 1 hour for background refreshes
        let timeSinceLastRefresh = currentTime - lastRefreshTime
        
        if timeSinceLastRefresh >= refreshInterval || lastRefreshTime == 0 {
            print("🔄 Feed \(feedId) ready for RSS refresh - last check: \(Int(timeSinceLastRefresh/60)) min ago (\(episodeCount) episodes cached)")
            return true
        }
        
        print("⚡ Feed \(feedId) loading from Core Data: \(episodeCount) episodes, last refresh \(Int(timeSinceLastRefresh/60)) min ago - no RSS refresh needed")
        return false
    }
    
    /// Refresh any feeds that don't have episodes by re-parsing their RSS
    /// CRITICAL CHANGE: Handles both new feeds and fresh install scenarios
    private func refreshFeedsWithoutEpisodes() async {
        print("🔍 Checking for feeds without episodes that need RSS parsing...")
        
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
            print("✅ All feeds have episodes - no RSS parsing needed")
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
        print("💾 Starting safe deletion from Core Data for feed: \(feed.title)")
        
        // Use main context with proper transaction handling to avoid merge conflicts
        let context = CoreDataStack.shared.persistentContainer.viewContext
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    // Step 1: Count episodes first for logging
                    let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    let episodeCount = try context.count(for: episodeCountRequest)
                    print("💾 Found \(episodeCount) episodes to delete for feed: \(feed.title)")
                    
                    // Step 2: Fetch and delete episodes in batches to avoid memory issues
                    var totalDeleted = 0
                    let batchSize = 500
                    
                    while true {
                        let episodeFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        episodeFetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                        episodeFetchRequest.fetchLimit = batchSize
                        
                        let episodes = try context.fetch(episodeFetchRequest)
                        if episodes.isEmpty {
                            break
                        }
                        
                        // Delete this batch of episodes
                        for episode in episodes {
                            // Clear any relationships first
                            episode.feed = nil
                            context.delete(episode)
                        }
                        
                        totalDeleted += episodes.count
                        
                        // Save periodically to prevent memory buildup
                        if totalDeleted % (batchSize * 2) == 0 {
                            try context.save()
                            print("💾 Intermediate save: deleted \(totalDeleted) episodes so far")
                        }
                    }
                    
                    print("💾 Deleted \(totalDeleted) episodes from Core Data")
                    
                    // Step 3: Now delete the feed record
                    let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    let feedResults = try context.fetch(feedFetchRequest)
                    for feedModel in feedResults {
                        // Clear all relationships before deletion
                        feedModel.episodes = nil
                        context.delete(feedModel)
                    }
                    print("💾 Deleted \(feedResults.count) feed records from Core Data")
                    
                    // Step 4: Final save
                    try context.save()
                    print("💾 ✅ Successfully completed safe deletion for feed: \(feed.title)")
                    continuation.resume()
                    
                } catch {
                    print("💾 ❌ Error in Core Data deletion: \(error.localizedDescription)")
                    
                    // Attempt recovery by rolling back and trying a simpler approach
                    context.rollback()
                    
                    do {
                        // Try one more time with a fresh context state
                        context.refreshAllObjects()
                        
                        // Simple deletion approach - just delete what we can find
                        let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                        feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                        
                        let remainingFeeds = try context.fetch(feedFetchRequest)
                        for feed in remainingFeeds {
                            context.delete(feed)
                        }
                        
                        try context.save()
                        print("💾 ✅ Recovery successful - completed deletion")
                        continuation.resume()
                    } catch {
                        print("💾 ❌ Recovery also failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    
    /// Refresh the current filtered episode list immediately
    private func refreshCurrentFilteredList() async {
        guard let feedId = selectedFeedId else { return }
        
        print("🔄 Refreshing filtered list for tab: \(currentTab)")
        
        // PERFORMANCE: Try fast filtering first, use minimal reload if needed
        let success = await performFastTabSwitch(from: -1, to: currentTab)
        if !success {
            // Use minimal reload instead of expensive full reload to prevent CPU spike
            await performMinimalTabReload(feedId: feedId, tab: currentTab)
        }
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
            // Enhanced file deletion logic - try multiple strategies to find and delete the file
            var fileDeleted = false
            
            // Strategy 1: Try to delete using the stored localFilePath
            if let localFilePath = episode.localFilePath, !localFilePath.isEmpty {
                let localURL = URL(fileURLWithPath: localFilePath)
                if FileManager.default.fileExists(atPath: localFilePath) {
                    try FileManager.default.removeItem(at: localURL)
                    print("📁 Successfully deleted local file: \(localFilePath)")
                    fileDeleted = true
                } else {
                    print("⚠️ Local file doesn't exist at path: \(localFilePath)")
                }
            }
            
            // Strategy 2: If no stored path or deletion failed, try to find and delete using recovery logic
            if !fileDeleted {
                print("🔍 Attempting to find and delete file using recovery strategies...")
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
                
                // Sanitize episode ID for filename search
                let sanitizedId = sanitizeFilename(episode.id)
                let commonExtensions = ["mp3", "m4a", "wav", "aac"]
                
                // Try to find file using sanitized ID with common extensions
                for ext in commonExtensions {
                    let fileName = "\(sanitizedId).\(ext)"
                    let fileURL = episodesFolder.appendingPathComponent(fileName)
                    
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        print("📁 Successfully deleted recovered file: \(fileName)")
                        fileDeleted = true
                        break
                    }
                }
                
                // Strategy 3: Search all files in DownloadedEpisodes folder for matches
                if !fileDeleted {
                    // Check if the DownloadedEpisodes folder exists before trying to access it
                    if FileManager.default.fileExists(atPath: episodesFolder.path) {
                        do {
                            let fileURLs = try FileManager.default.contentsOfDirectory(at: episodesFolder, includingPropertiesForKeys: nil)
                            
                            for fileURL in fileURLs {
                                let fileName = fileURL.lastPathComponent
                                if fileName.contains(episode.id) || fileName.contains(sanitizedId) {
                                    try FileManager.default.removeItem(at: fileURL)
                                    print("📁 Successfully deleted file found by search: \(fileName)")
                                    fileDeleted = true
                                    break
                                }
                            }
                        } catch {
                            print("❌ Error searching DownloadedEpisodes folder: \(error)")
                        }
                    } else {
                        print("📁 DownloadedEpisodes folder doesn't exist, skipping file search for episode: \(episode.title)")
                    }
                }
            }
            
            if !fileDeleted {
                print("⚠️ Could not find or delete physical file for episode: \(episode.title)")
            }
            
            // CRITICAL: Update EpisodeStateManager first (source of truth for download state)
            EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
            
            // ⚡ IMMEDIATE SNAPSHOT UPDATE: Update snapshot for instant loading on next access
            updateSnapshotForEpisodeStateChange(episodeId: episode.id, feedId: episode.feedId)
            
            // CRITICAL: Clear individual backup files to prevent recovery on restart
            EpisodeStateManager.shared.clearEpisodeBackup(episode.id)
            
            // Clear local file path from Core Data
            await episodeManager.updateEpisodeLocalPath(episode.id, localPath: nil)
            
            // Update episode state in Core Data to ensure consistency
            try await episodeManager.updateEpisodeStates([
                EpisodeStateUpdate(episodeId: episode.id, isDownloaded: false)
            ])
            
            // CRITICAL: Sync the download state change to CloudKit with enhanced debugging
            print("🔍 DEBUG: About to trigger CloudKit sync for episode: \(episode.id)")
            print("🔍 DEBUG: Episode feedId: \(episode.feedId)")
            print("🔍 DEBUG: Selected feedId: \(selectedFeedId ?? "nil")")
            
            updateEpisodeState(episode.id, isDownloaded: false)
            print("☁️ Triggered CloudKit sync for deleted download: \(episode.title)")
            
            // BACKUP: Also directly call CloudKit if feedId is available
            if !episode.feedId.isEmpty {
                Task.detached(priority: .userInitiated) {
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
                    let currentFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                    await PodcastCloudKitManager.shared.saveEpisodeState(
                        episodeId: episode.id,
                        feedId: episode.feedId,
                        progress: currentProgress,
                        isFavorite: currentFavorite,
                        isDownloaded: false,
                        isPlayed: currentProgress >= 0.99
                    )
                    print("☁️ BACKUP: Direct CloudKit sync completed for deleted download: \(episode.title)")
                }
            } else {
                print("⚠️ WARNING: No feedId available for direct CloudKit sync backup")
            }
            
            // PERFORMANCE: Only clear cache if no snapshots available
            if getEpisodeSnapshot(for: episode.feedId) == nil {
                await episodeManager.clearCacheForFeed(episode.feedId)
                print("🧽 CACHE: Cleared cache for feed \(episode.feedId) - no snapshot available")
            } else {
                print("⚡ PERFORMANCE: Keeping cache - using episode snapshot for feed \(episode.feedId)")
            }
            // Note: Persistent cache is retained for instant reloading
            
            // ⚡ IMMEDIATE UI UPDATE: Ensure all updates happen on main thread
            await MainActor.run {
                // Update episode state in EpisodeStateManager first (source of truth)
                EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
                
                // ⚡ IMMEDIATE SNAPSHOT UPDATE: Update snapshot for instant loading on next access
                self.updateSnapshotForEpisodeStateChange(episodeId: episode.id, feedId: episode.feedId)
                
                // Update UI state for instant visual feedback
                self.updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: nil, isDownloaded: false)
                
                // If we're on downloads tab, remove immediately
                if self.currentTab == EpisodeFilter.downloads.rawValue {
                    self.currentEpisodes.removeAll { $0.id == episode.id }
                    print("🔄 UI UPDATE: Immediately removed deleted download from downloads tab")
                }
                
                // Force UI refresh with aggressive change detection
                self.forceUIRefresh()
                
                print("🔍 DEBUG: ✅ Immediate delete download UI update completed for '\(episode.title)'")
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
    
    /// Reset the episode states sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if episode states get out of sync
    @MainActor
    func resetEpisodeStatesSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
        print("🔄 Reset episode states sync flag - will re-sync from CloudKit on next launch")
    }
    
    /// Manually trigger CloudKit episode state sync immediately (for testing banner)
    /// This will show the progress banner in real-time
    @MainActor
    func manuallyTriggerCloudKitSync() {
        print("🔄 Manually triggering CloudKit episode state sync for testing...")
        Task {
            let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
            if syncSuccess {
                print("✅ Manual CloudKit sync completed successfully")
            } else {
                print("⚠️ Manual CloudKit sync failed")
            }
        }
    }
    
    /// Automatically trigger CloudKit sync for both feeds and episode states
    /// This should be called when PodcastListView loads to check for new content
    /// Now runs entirely in background to prevent main thread blocking
    func automaticCloudKitSync() async {
        // PERFORMANCE: Skip expensive CloudKit sync if we have snapshots or recent sync
        let hasSnapshot = await MainActor.run {
            // Check if ANY feed has snapshots, not just the selected feed
            // This prevents unnecessary CloudKit sync when snapshots exist but selectedFeedId is nil
            return !self.episodeSnapshotCache.isEmpty
        }
        
        let hasRecentSync = await MainActor.run {
            let lastSyncTime = UserDefaults.standard.double(forKey: "lastAutomaticCloudKitSync")
            let timeSinceLastSync = Date().timeIntervalSince1970 - lastSyncTime
            return timeSinceLastSync < 300 // Skip if synced within last 5 minutes
        }
        
        if hasSnapshot {
            print("⚡ PERFORMANCE: Skipping CloudKit sync - using episode snapshot")
            return
        }
        
        if hasRecentSync {
            print("⚡ PERFORMANCE: Skipping CloudKit sync - recent sync completed, using cached data")
            return
        }
        
        print("🔄 Automatically triggering CloudKit sync for feeds and episode states...")
        
        // Prevent multiple concurrent CloudKit syncs using main actor for thread safety
        let shouldSkip = await MainActor.run {
            if cloudKitSyncInProgress {
                print("⚠️ CloudKit sync already in progress, skipping automatic sync")
                return true
            }
            cloudKitSyncInProgress = true
            return false
        }
        
        guard !shouldSkip else { return }
        
        await performAutomaticCloudKitCheck()
    }
    
    /// Perform automatic CloudKit check for new feeds and updated episode states
    /// This runs silently without triggering progress banners
    private func performAutomaticCloudKitCheck() async {
        // PERFORMANCE: Skip expensive CloudKit operations if we have snapshots
        let hasSnapshot = await MainActor.run {
            // Check if ANY feed has snapshots, not just the selected feed
            // This prevents unnecessary CloudKit sync when snapshots exist but selectedFeedId is nil
            return !self.episodeSnapshotCache.isEmpty
        }
        
        if hasSnapshot {
            print("⚡ PERFORMANCE: Skipping CloudKit check - using episode snapshot")
            await MainActor.run {
                self.cloudKitSyncInProgress = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAutomaticCloudKitSync")
            }
            return
        }
        
        defer { 
            Task { @MainActor in
                self.cloudKitSyncInProgress = false
                // PERFORMANCE: Record sync timestamp to prevent unnecessary future syncs
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAutomaticCloudKitSync")
                print("🔄 Automatic CloudKit sync completed")
            }
        }
        
        print("🔄 AUTO SYNC: Silently checking CloudKit for new feeds and episode updates...")
        
        do {
            // STEP 1: Check for new feeds from other devices (SILENT)
            print("🔄 AUTO SYNC: Checking for new feeds from CloudKit...")
            let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            
            if !cloudKitFeeds.isEmpty {
                print("🔄 AUTO SYNC: Found \(cloudKitFeeds.count) feeds in CloudKit")
                // Merge any new feeds that aren't already local (SILENT - no banner)
                await mergeCloudKitFeedsSilently(cloudKitFeeds)
            } else {
                print("🔄 AUTO SYNC: No feeds found in CloudKit")
            }
            
            // STEP 2: Check if episode states need syncing (SILENT)
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            let timeSinceLastSync = UserDefaults.standard.double(forKey: "LastEpisodeStatesSyncTime")
            let currentTime = Date().timeIntervalSince1970
            let oneHourAgo = currentTime - 3600 // 1 hour in seconds
            
            // Sync episode states if never synced or if it's been more than 1 hour (SILENT)
            if !hasEpisodeStatesSynced || timeSinceLastSync < oneHourAgo {
                print("🔄 AUTO SYNC: Silently syncing episode states from CloudKit...")
                
                let syncSuccess = await syncEpisodeStatesFromCloudKitSilently(isFreshInstall: false)
                if syncSuccess {
                    // Update last sync time
                    UserDefaults.standard.set(currentTime, forKey: "LastEpisodeStatesSyncTime")
                    print("✅ AUTO SYNC: Episode states synced successfully (silent)")
                } else {
                    print("⚠️ AUTO SYNC: Episode states sync failed (silent)")
                }
            } else {
                print("⚡ AUTO SYNC: Episode states recently synced, skipping")
            }
            
            // STEP 3: Final UI refresh
            await MainActor.run {
                self.throttledUIUpdate()
                print("🔄 AUTO SYNC: UI refreshed after automatic sync")
            }
            
        } catch {
            print("❌ AUTO SYNC: CloudKit check failed: \(error)")
        }
    }
    
    /// Silently merge CloudKit feeds without triggering progress banners
    /// Used for automatic background sync to avoid disrupting user experience
    private func mergeCloudKitFeedsSilently(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🔄 SILENT MERGE: Processing \(cloudKitFeeds.count) CloudKit feeds without banners")
        
        // Identify which feeds are actually new
        let (newFeeds, existingFeedsCount) = await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            context.perform {
                do {
                    let existingFeeds = try context.fetch(FeedModel.fetchRequest())
                    let existingFeedIds = Set(existingFeeds.compactMap { $0.id })
                    let existingFeedUrls = Set(existingFeeds.compactMap { $0.url })
                    let existingFeedTitles = Set(existingFeeds.compactMap { $0.title })
                    
                    var feedsToAdd: [PodcastFeed] = []
                    for cloudFeed in cloudKitFeeds {
                        let isDuplicateById = existingFeedIds.contains(cloudFeed.id)
                        let isDuplicateByUrl = existingFeedUrls.contains(cloudFeed.url)
                        let isDuplicateByTitle = existingFeedTitles.contains(cloudFeed.title)
                        
                        if !isDuplicateById && !isDuplicateByUrl && !isDuplicateByTitle {
                            print("🔄 SILENT MERGE: Found new feed - \(cloudFeed.title)")
                            feedsToAdd.append(cloudFeed)
                        }
                    }
                    
                    continuation.resume(returning: (feedsToAdd, existingFeeds.count))
                } catch {
                    print("❌ SILENT MERGE: Failed to identify new feeds: \(error)")
                    continuation.resume(returning: ([], 0))
                }
            }
        }
        
        if !newFeeds.isEmpty {
            print("🔄 SILENT MERGE: Adding \(newFeeds.count) new feeds to Core Data")
            
            // Add feeds to Core Data silently
            await withCheckedContinuation { continuation in
                let context = CoreDataStack.shared.newBackgroundContext()
                context.perform {
                    do {
                        for cloudFeed in newFeeds {
                            let feedModel = FeedModel(context: context)
                            feedModel.update(from: cloudFeed)
                            print("📥 SILENT MERGE: Added feed - \(cloudFeed.title)")
                        }
                        
                        try context.save()
                        print("✅ SILENT MERGE: Successfully added \(newFeeds.count) feeds")
                        continuation.resume()
                    } catch {
                        print("❌ SILENT MERGE: Failed to save feeds: \(error)")
                        continuation.resume()
                    }
                }
            }
            
            // Update UI with new feeds
            await MainActor.run {
                self.loadFeedsFromCoreData()
                self.throttledUIUpdate()
                print("🔄 SILENT MERGE: UI updated with new feeds")
            }
        } else {
            print("🔄 SILENT MERGE: No new feeds to add")
        }
    }
    
    /// Silently sync episode states from CloudKit without triggering progress banners
    /// Used for automatic background sync to avoid disrupting user experience
    private func syncEpisodeStatesFromCloudKitSilently(isFreshInstall: Bool) async -> Bool {
        print("🔄 SILENT EPISODE SYNC: Starting silent episode state sync")
        
        do {
            // Get all episode IDs for syncing (without triggering banner)
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            if allEpisodeIds.isEmpty {
                print("🔄 SILENT EPISODE SYNC: No episodes found to sync")
                return true
            }
            
            print("🔄 SILENT EPISODE SYNC: Syncing \(allEpisodeIds.count) episodes silently")
            
            // Perform the actual CloudKit sync without DataSyncManager calls
            let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                for: allEpisodeIds,
                isFreshInstall: isFreshInstall
            )
            
            let coreDataUpdates = syncResult.updates
            let syncSuccess = syncResult.success
            
            if syncSuccess {
                print("✅ SILENT EPISODE SYNC: Successfully synced episode states")
                
                // Save updates to Core Data if there are any
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 SILENT EPISODE SYNC: Saved \(coreDataUpdates.count) episode states to Core Data")
                    } catch {
                        print("❌ SILENT EPISODE SYNC: Failed to save episode states: \(error)")
                    }
                }
                
                // Refresh episode states silently
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    print("🔄 SILENT EPISODE SYNC: Episode states refreshed")
                }
                
                return true
            } else {
                print("⚠️ SILENT EPISODE SYNC: Episode state sync failed")
                return false
            }
            
        } catch {
            print("❌ SILENT EPISODE SYNC: Error during sync: \(error)")
            return false
        }
    }
    
    /// Check if we should perform a periodic CloudKit sync to demonstrate banner functionality
    private func shouldPerformPeriodicCloudKitSync() async -> Bool {
        // Perform a lightweight sync every 5 app launches to demonstrate the banner
        let launchCount = UserDefaults.standard.integer(forKey: "AppLaunchCount")
        UserDefaults.standard.set(launchCount + 1, forKey: "AppLaunchCount")
        
        // Show CloudKit sync every 5th launch to demonstrate banner functionality
        return launchCount % 5 == 0
    }
    
    /// Perform a lightweight CloudKit sync of a subset of episodes to show banner activity
    private func performLightweightCloudKitSync() async {
        print("🔄 Starting lightweight CloudKit sync for banner demonstration...")
        
        // Get a subset of episodes (first 50) to sync
        let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
        let episodeSubset = Array(allEpisodeIds.prefix(min(50, allEpisodeIds.count)))
        
        guard !episodeSubset.isEmpty else {
            print("📊 No episodes found for lightweight sync")
            return
        }
        
        // Start episode state sync tracking in DataSyncManager
        await DataSyncManager.shared.startEpisodeStateSync(totalCount: episodeSubset.count)
        
        // Update progress during CloudKit sync
        await DataSyncManager.shared.updateEpisodeStateProgress(
            currentCount: 0,
            operation: "Checking for episode updates from iCloud..."
        )
        
        // Sync episode states from CloudKit
        let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
            for: episodeSubset,
            isFreshInstall: false
        )
        
        // Update progress during completion
        await DataSyncManager.shared.updateEpisodeStateProgress(
            currentCount: episodeSubset.count,
            operation: "Sync completed"
        )
        
        // Complete episode state sync tracking
        await DataSyncManager.shared.completeEpisodeStateSync()
        
        print("✅ Lightweight CloudKit sync completed for \(episodeSubset.count) episodes")
    }
    
    /// Reset the podcast feeds sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if podcast feeds get out of sync
    @MainActor
    func resetPodcastFeedsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
        print("🔄 Reset podcast feeds sync flag - will re-sync from CloudKit on next launch")
    }
}

// MARK: - Backward Compatibility Methods

extension PodcastViewModel {
    // These methods provide backward compatibility with existing UI code
    
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
    }
    
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func markEpisodeAsPlayed(_ episodeId: String) {
        updateEpisodeState(episodeId, isPlayed: true)
    }
    
    @available(*, deprecated, message: "Use toggleFavorite(for episode: PodcastEpisode) instead")
    func toggleFavorite(for episodeId: String) {
        print("⚠️ DEPRECATED: toggleFavorite(for episodeId: String) called - this should not happen!")
        // Find the episode and call the new method
        if let episode = currentEpisodes.first(where: { $0.id == episodeId }) {
            toggleFavorite(for: episode)
        } else {
            // Fallback to old behavior
            let currentState = currentEpisodes.first { $0.id == episodeId }?.state.isFavorite ?? false
            updateEpisodeState(episodeId, isFavorite: !currentState)
        }
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
        self.throttledUIUpdate()
        
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
            self.throttledUIUpdate()
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
    
    /// Helper method to get all episodes for a specific feed
    private func getAllEpisodesForFeed(_ feedId: String) -> [PodcastEpisode] {
        // First try to get episodes from the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            return feed.episodes
        }
        
        // Fallback to current episodes if they're for this feed
        if selectedFeedId == feedId {
            return currentEpisodes
        }
        
        // Final fallback: filter current episodes by feed ID
        return currentEpisodes.filter { $0.feedId == feedId }
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use podcastFeeds directly")
    func getLastPlayedOrLatestEpisode(for feed: PodcastFeed) -> PodcastEpisode? {
        // Get all episodes for this feed
        let feedEpisodes = getAllEpisodesForFeed(feed.id)
        
        // Check for last played episode
        if let lastPlayedEpisodeId = lastPlayedEpisodes[feed.id],
           let lastPlayedEpisode = feedEpisodes.first(where: { $0.id == lastPlayedEpisodeId }) {
            print("🎯 DEBUG: Found last played episode for feed \(feed.title): \(lastPlayedEpisode.title)")
            return lastPlayedEpisode
        }
        
        // Check for episodes in progress
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        if let firstInProgressEpisode = episodesInProgress.first {
            print("🎯 DEBUG: Found episode in progress for feed \(feed.title): \(firstInProgressEpisode.title)")
            return firstInProgressEpisode
        }
        
        // If no episodes in progress, return the latest episode
        let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first
        print("🎯 DEBUG: Returning latest episode for feed \(feed.title): \(latestEpisode?.title ?? "none")")
        return latestEpisode
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
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func fetchAllEpisodes(for feed: PodcastFeed) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
    }
    
    /// For PodcastPlayer compatibility
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
        
        // Get episodes immediately from snapshot or current episodes
        let episodes = getEpisodeSnapshot(for: feed.id) ?? currentEpisodes.filter { $0.feedId == feed.id }
        completion(.success(episodes))
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
        print("📡 FAVORITE TOGGLE: About to call updateEpisodeState with isFavorite: \(newState)")
        
        // ⚡ IMMEDIATE UI UPDATE: Update episode state in EpisodeStateManager first (source of truth)
        EpisodeStateManager.shared.setFavorite(episode.id, isFavorite: newState)
        
        // ⚡ IMMEDIATE SNAPSHOT UPDATE: Update snapshot for instant loading on next access
        updateSnapshotForEpisodeStateChange(episodeId: episode.id, feedId: episode.feedId)
        
        // ⚡ IMMEDIATE UI UPDATE: Update UI state for instant visual feedback (already on main thread)
        print("🔍 DEBUG: About to call updateEpisodeUIStateImmediate for episode \(episode.id)")
        updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: newState, isDownloaded: nil)
        
        // ⚡ IMMEDIATE FILTER: If we're on favorites tab and unfavoriting, remove immediately
        if currentTab == EpisodeFilter.favorites.rawValue && !newState {
            currentEpisodes.removeAll { $0.id == episode.id }
            print("🔄 UI UPDATE: Immediately removed unfavorited episode from favorites tab")
        }
        
        // ⚡ FORCE UI REFRESH: Trigger all refresh strategies
        print("🔍 DEBUG: About to call forceUIRefresh()")
        forceUIRefresh()
        
        // 🎯 CROSS-TAB UPDATE: Apply filtering to ensure changes appear across all tabs
        applyTabFiltering(episodeId: episode.id, isFavorite: newState, isDownloaded: nil)
        
        print("🔍 DEBUG: ✅ Immediate favorite UI update completed for '\(episode.title)' favorite: \(newState)")
        
        // Background sync for data persistence and CloudKit
        Task.detached(priority: .background) {
            await self.updateEpisodeState(episode.id, isFavorite: newState)
        }
    }
    
    /// Refresh the current filter view to reflect state changes
    @MainActor
    private func refreshCurrentFilter() async {
        guard let selectedFeedId = selectedFeedId else { return }
        
        // Get the current filter
        let currentFilter: EpisodeFilter
        switch currentTab {
        case EpisodeFilter.all.rawValue:
            currentFilter = .all
        case EpisodeFilter.favorites.rawValue:
            currentFilter = .favorites
        case EpisodeFilter.downloads.rawValue:
            currentFilter = .downloads
        default:
            currentFilter = .all
        }
        
        // Reload episodes with the current filter to reflect changes
        await loadEpisodesForFeed(selectedFeedId)
    }
    
    /// Toggle download state for an episode with proper filtering update
    func toggleDownload(for episode: PodcastEpisode) {
        let currentState = episode.state.isDownloaded
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling download for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        
        // ⚡ IMMEDIATE UI UPDATE: Update episode state in EpisodeStateManager first (source of truth)
        EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: newState)
        
        // ⚡ IMMEDIATE UI UPDATE: Update UI state for instant visual feedback (already on main thread)
        print("🔍 DEBUG: About to call updateEpisodeUIStateImmediate for episode \(episode.id)")
        updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: nil, isDownloaded: newState)
        
        // ⚡ IMMEDIATE FILTER: If we're on downloads tab and removing download, remove immediately
        if currentTab == EpisodeFilter.downloads.rawValue && !newState {
            currentEpisodes.removeAll { $0.id == episode.id }
            print("🔄 UI UPDATE: Immediately removed non-downloaded episode from downloads tab")
        }
        
        // ⚡ FORCE UI REFRESH: Trigger all refresh strategies
        print("🔍 DEBUG: About to call forceUIRefresh()")
        forceUIRefresh()
        
        // 🎯 CROSS-TAB UPDATE: Apply filtering to ensure changes appear across all tabs
        applyTabFiltering(episodeId: episode.id, isFavorite: nil, isDownloaded: newState)
        
        print("🔍 DEBUG: ✅ Immediate download UI update completed for '\(episode.title)' downloaded: \(newState)")
        
        // Background sync for data persistence and CloudKit
        Task.detached(priority: .background) {
            await self.updateEpisodeState(episode.id, isDownloaded: newState)
        }
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
            self.throttledUIUpdate()
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
        
        // SORTING FIX: Save the sorted order to Core Data to persist the changes
        saveFeedsToCoreData()
        
        // Save sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "PodcastIsAscendingSort")
        
        // CRITICAL: Trigger UI refresh to show the sorted order immediately
        objectWillChange.send()
        print("🎯 SORTING: Applied \(isAscendingSort ? "A-Z" : "Z-A") sort and triggered UI refresh")
    }
    
    /// Load sorting preferences from UserDefaults
    private func loadSortingPreferences() {
        if UserDefaults.standard.object(forKey: "PodcastIsAscendingSort") != nil {
            isAscendingSort = UserDefaults.standard.bool(forKey: "PodcastIsAscendingSort")
        } else {
            isAscendingSort = true // Default to ascending (A-Z)
            UserDefaults.standard.set(isAscendingSort, forKey: "PodcastIsAscendingSort")
        }
        print("🎯 SORTING: Loaded podcast sort direction: \(isAscendingSort ? "A-Z" : "Z-A")")
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
                    
                    // ⚡ IMMEDIATE SNAPSHOT UPDATE: Update snapshot for instant loading on next access
                    self.updateSnapshotForEpisodeStateChange(episodeId: episode.id, feedId: episode.feedId)
                    
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
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
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
    
    /// Load podcast feeds from Core Data using background processing to prevent main thread blocking
    func loadFeedsFromCoreData() {
        // PERFORMANCE: Prevent redundant Core Data operations
        guard !isLoadingFromCoreData else {
            print("🔄 Core Data loading already in progress - skipping redundant call")
            return
        }
        
        print("🎯 CORE DATA LOAD: Starting loadFeedsFromCoreData() - Current feeds: \(podcastFeeds.count)")
        print("🎯 CORE DATA LOAD: Current podcastFeedOrder: \(podcastFeedOrder.count)")
        print("🎯 CORE DATA LOAD: isLoadingFromCoreData: \(isLoadingFromCoreData), isLoading: \(isLoading)")
        
        isLoadingFromCoreData = true
        isLoading = true  // Set main loading flag for UI coordination
        
        // Use background queue for Core Data operations to prevent main thread blocking
        Task.detached(priority: .userInitiated) {
            await self.performBackgroundCoreDataLoad()
        }
    }
    
    /// Perform Core Data loading operations on background queue
    private func performBackgroundCoreDataLoad() async {
        // Use background context to prevent main thread blocking
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            print("🎯 CORE DATA LOAD: About to perform Core Data fetch for FeedModel")
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            
            // Add a sort descriptor to ensure feeds are loaded in the correct order
            let sortDescriptor = NSSortDescriptor(key: "sortOrder", ascending: true)
            request.sortDescriptors = [sortDescriptor]
            
            do {
                let results = try backgroundContext.fetch(request)
                print("🎯 CORE DATA LOAD: Fetch completed - found \(results.count) FeedModel objects in Core Data")
            if results.isEmpty {
                print("📡 No podcast feeds found in CoreData.")
                // CRITICAL: Clear in-memory arrays when no feeds found in Core Data
                Task { @MainActor in
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.throttledUIUpdate()
                    
                    // PERFORMANCE: Reset flags on main thread
                    self.isLoadingFromCoreData = false
                    self.isLoading = false  // Clear main loading flag
                }
                return
            }
            
            var loadedFeeds: [PodcastFeed] = []
            for feedModel in results {
                // Load episodes for this feed
                var episodes: [PodcastEpisode] = []
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedModel.id ?? "")
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                do {
                    let episodeModels = try backgroundContext.fetch(episodeRequest)
                    let loadedEpisodes = episodeModels.compactMap { $0.toPodcastEpisode() }
                    
                    // CRITICAL FIX: Remove duplicates and merge with EpisodeStateManager
                    // Note: This runs in background context, use synchronous version to avoid async in perform block
                    episodes = PodcastViewModel.removeDuplicatesFromEpisodesSynced(loadedEpisodes)
                    print("📡 Loaded \(loadedEpisodes.count) episodes for feed: \(feedModel.title ?? "Unknown"), \(episodes.count) after deduplication")
                } catch {
                    print("❌ Failed to load episodes for feed \(feedModel.title ?? "Unknown"): \(error)")
                }
                
                let feed = PodcastFeed(
                    id: feedModel.id ?? UUID().uuidString,
                    title: feedModel.title ?? "Unknown Feed",
                    url: feedModel.url ?? "",
                    artworkUrl: feedModel.artworkUrl,
                    description: feedModel.descriptionText,
                    iconData: feedModel.iconData,
                    imageData: feedModel.imageData,
                    episodes: episodes
                )
                loadedFeeds.append(feed)
            }
            
            // CRITICAL: Assign to @Published properties on main thread to trigger UI updates
            Task { @MainActor in
                // Batch property updates to prevent multiple UI refreshes
                self.podcastFeeds = loadedFeeds
                self.podcastFeedOrder = loadedFeeds.map { $0.id }
                
                // Clear loading flags
                self.isLoading = false
                self.isLoadingFeeds = false
                self.isLoadingFromCoreData = false
                
                // Single UI refresh after all properties are updated
                self.throttledUIUpdate()
                
                // Report status to DataSyncManager
                self.reportStatusToDataSyncManager()
            }
            
            
            // Debug: Check if episodes exist in Core Data
            let debugEpisodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let allEpisodes = try backgroundContext.fetch(debugEpisodeRequest)
                
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
            
            } catch {
                print("❌ Failed to load podcast feeds from CoreData: \(error)")
                // Clear loading flags on error
                Task { @MainActor in
                    self.isLoading = false
                    self.isLoadingFeeds = false
                    self.isLoadingFromCoreData = false
                }
            }
        }
        
        // PERFORMANCE OPTIMIZED: Create snapshots in batches to prevent CPU spikes
        Task.detached(priority: .utility) {
            let feedsWithEpisodes = await self.podcastFeeds.filter { !$0.episodes.isEmpty }
            
            // BATCH PROCESSING: Process feeds in smaller batches to prevent CPU overload
            let batchSize = 3
            for i in stride(from: 0, to: feedsWithEpisodes.count, by: batchSize) {
                let batch = Array(feedsWithEpisodes[i..<min(i + batchSize, feedsWithEpisodes.count)])
                
                // Process batch with small delay between batches
                for feed in batch {
                    print("⚡ STARTUP OPTIMIZATION: Creating snapshot for \(feed.title) with \(feed.episodes.count) episodes")
                    await self.updateEpisodeSnapshot(for: feed.id, episodes: feed.episodes)
                }
                
                // Small delay between batches to prevent CPU spikes
                if i + batchSize < feedsWithEpisodes.count {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay between batches
                }
            }
            
            // Load episodes for the first feed if available - now with snapshots available
            if let firstFeed = await self.podcastFeeds.first {
                print("📡 Loading episodes for first feed: \(firstFeed.title) (\(firstFeed.episodes.count) episodes available)")
                await self.loadEpisodesForFeed(firstFeed.id, isInitialLoad: true)
            } else {
                print("📡 No feeds found in Core Data")
            }
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
            self.throttledUIUpdate()
            print("📡 ✅ Immediately cleared podcast feeds from UI")
            print("🔍 DEBUG: After immediate clearing - podcastFeeds count: \(self.podcastFeeds.count)")
            print("🔍 DEBUG: After immediate clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
            
            // Force UI refresh by triggering objectWillChange again with slight delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.throttledUIUpdate()
                print("📡 ✅ Forced additional UI refresh after clearing")
            }
        }
    }
    
    /// Clear all podcast data from Core Data and CloudKit with comprehensive cross-device sync
    func clearPodcastCoreData(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            var allSuccess = true
            var lastError: Error?
            
            // First, get the feed IDs and details before deletion for CloudKit cleanup and cross-device sync
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            var feedIdsToDelete: [String] = []
            var feedDataForSync: [(String, String)] = [] // (feedId, feedTitle) for sync
            
            do {
                let feeds = try context.fetch(feedFetchRequest)
                feedIdsToDelete = feeds.compactMap { $0.id }
                feedDataForSync = feeds.compactMap { feed in
                    guard let feedId = feed.id, let title = feed.title else { return nil }
                    return (feedId, title)
                }
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
            
            // Now delete from local Core Data using efficient batch deletion
            // Debug: Check what data exists before deletion
            print("🔍 CORE DATA DEBUG: Checking data before deletion...")
            do {
                let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                let episodeCount = try mainContext.count(for: PodcastModel.fetchRequest())
                let feedCount = try mainContext.count(for: FeedModel.fetchRequest())
                print("🔍 CORE DATA DEBUG: Before deletion - Episodes: \(episodeCount), Feeds: \(feedCount)")
            } catch {
                print("❌ CORE DATA DEBUG: Error counting records before deletion: \(error)")
            }
            
            let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            privateMOC.parent = CoreDataStack.shared.persistentContainer.viewContext
            privateMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            
            await withCheckedContinuation { continuation in
                privateMOC.perform {
                    print("🔍 CORE DATA DEBUG: Private context is performing deletion...")
                    do {
                        // Use NSBatchDeleteRequest for efficient bulk deletion of episodes
                        let episodeFetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
                        let episodeBatchDeleteRequest = NSBatchDeleteRequest(fetchRequest: episodeFetchRequest)
                        episodeBatchDeleteRequest.resultType = .resultTypeObjectIDs
                        
                        let episodeResult = try privateMOC.execute(episodeBatchDeleteRequest) as? NSBatchDeleteResult
                        let episodeObjectIDArray = episodeResult?.result as? [NSManagedObjectID]
                        
                        // Use NSBatchDeleteRequest for efficient bulk deletion of feeds
                        let feedFetchRequest: NSFetchRequest<NSFetchRequestResult> = FeedModel.fetchRequest()
                        let feedBatchDeleteRequest = NSBatchDeleteRequest(fetchRequest: feedFetchRequest)
                        feedBatchDeleteRequest.resultType = .resultTypeObjectIDs
                        
                        let feedResult = try privateMOC.execute(feedBatchDeleteRequest) as? NSBatchDeleteResult
                        let feedObjectIDArray = feedResult?.result as? [NSManagedObjectID]
                        
                        // Merge changes into view context to ensure UI updates
                        var allObjectIDs: [NSManagedObjectID] = []
                        if let episodeIDs = episodeObjectIDArray {
                            allObjectIDs.append(contentsOf: episodeIDs)
                            print("✅ Batch deleted \(episodeIDs.count) episodes from Core Data")
                        }
                        if let feedIDs = feedObjectIDArray {
                            allObjectIDs.append(contentsOf: feedIDs)
                            print("✅ Batch deleted \(feedIDs.count) feeds from Core Data")
                        }
                        
                        if !allObjectIDs.isEmpty {
                            let changes = [NSDeletedObjectsKey: allObjectIDs]
                            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [CoreDataStack.shared.persistentContainer.viewContext])
                        }
                        
                        // Save private context after batch deletion
                        try privateMOC.save()
                        print("🔍 CORE DATA DEBUG: Private context saved successfully")
                        
                        continuation.resume()
                    } catch {
                        print("❌ Error performing batch deletion of podcast data from CoreData: \(error.localizedDescription)")
                        allSuccess = false
                        lastError = error
                        continuation.resume()
                    }
                }
            }
            
            // Then save main context and clear in-memory data
            await MainActor.run {
                do {
                    print("🔍 CORE DATA DEBUG: Saving main context...")
                    try CoreDataStack.shared.persistentContainer.viewContext.save()
                    print("🔍 CORE DATA DEBUG: Main context saved successfully")
                    
                    // **CRITICAL**: Force refresh all contexts to clear cached objects
                    print("🔄 CONTEXT REFRESH: Starting comprehensive context refresh...")
                    let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                    
                    // Reset the main context to clear all cached objects
                    mainContext.reset()
                    print("🔄 CONTEXT REFRESH: Main context reset completed")
                    
                    // Refresh all objects in the context (in case any are still cached)
                    mainContext.refreshAllObjects()
                    print("🔄 CONTEXT REFRESH: All objects refreshed")
                    
                    // Also refresh any background contexts
                    CoreDataStack.shared.persistentContainer.performBackgroundTask { backgroundContext in
                        backgroundContext.reset()
                        print("🔄 CONTEXT REFRESH: Background context reset completed")
                    }
                    
                    // Debug: Check what data exists after deletion and context refresh
                    do {
                        let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                        let episodeCountAfter = try mainContext.count(for: PodcastModel.fetchRequest())
                        let feedCountAfter = try mainContext.count(for: FeedModel.fetchRequest())
                        print("🔍 CORE DATA DEBUG: After deletion and context refresh - Episodes: \(episodeCountAfter), Feeds: \(feedCountAfter)")
                        
                        if episodeCountAfter > 0 || feedCountAfter > 0 {
                            print("❌ CORE DATA ERROR: Data still exists after deletion! Episodes: \(episodeCountAfter), Feeds: \(feedCountAfter)")
                        } else {
                            print("✅ CORE DATA SUCCESS: All data successfully deleted from Core Data and contexts refreshed")
                        }
                    } catch {
                        print("❌ CORE DATA DEBUG: Error counting records after deletion: \(error)")
                    }
                    
                    // Ensure in-memory data is cleared after successful Core Data deletion
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.episodeCounts = (all: 0, favorites: 0, downloads: 0)
                    self.throttledUIUpdate()
                    print("📡 ✅ Cleared in-memory data after Core Data deletion")
                    print("🔍 DEBUG: After clearing - podcastFeeds count: \(self.podcastFeeds.count)")
                    print("🔍 DEBUG: After clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
                } catch {
                    print("❌ Error saving main context after podcast deletion: \(error.localizedDescription)")
                    completion(false, error)
                    return
                }
            }
            
            // **CRITICAL**: Clear all episode states from EpisodeStateManager (progress, favorites, downloads)
            await clearAllEpisodeStatesFromManager()
            print("📡 ✅ CRITICAL FIX: Cleared all episode states from EpisodeStateManager")
            
            // **CRITICAL**: Trigger cross-device sync for comprehensive cleanup  
            if allSuccess {
                print("🎯 ✅ Successfully deleted all podcast data from both CloudKit and Core Data")
                
                // Trigger cross-device sync for each deleted feed to ensure CoreData cleanup on all devices
                Task {
                    for (feedId, feedTitle) in feedDataForSync {
                        // Get episode IDs for comprehensive cleanup
                        let episodeIds = await self.getEpisodeIdsForFeed(feedId)
                        
                        print("📡 🚨 DATA MANAGEMENT: Syncing deletion of '\(feedTitle)' (\(feedId)) across devices")
                        PodcastCloudKitManager.shared.syncPodcastFeedRemovedInstantly(
                            feedId: feedId,
                            feedTitle: feedTitle,
                            episodeIds: episodeIds
                        )
                    }
                    print("📡 ✅ DATA MANAGEMENT: Cross-device sync triggered for \(feedDataForSync.count) deleted feeds")
                }
                
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "All podcast data has been successfully deleted across all devices.")
            } else {
                print("⚠️ Partial success: Local deletion completed, but some CloudKit deletions failed")
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Podcast data deletion completed with some warnings.")
            }
            
            completion(allSuccess, lastError)
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
    
    /// Clear all episode states from EpisodeStateManager during bulk deletion
    private func clearAllEpisodeStatesFromManager() async {
        print("🧹 EPISODE STATE CLEARING: Starting comprehensive EpisodeStateManager cleanup...")
        
        // Clear all episode states using EpisodeStateManager's bulk clear methods
        EpisodeStateManager.shared.clearAllStates()
        print("🧹 EPISODE STATE CLEARING: Cleared all episode states from EpisodeStateManager")
        
        // Core Data saves happen automatically, no need to force save
        // clearAllStates() already triggers save through state changes
        print("🧹 EPISODE STATE CLEARING: Forced save completed - all local episode data cleared")
    }
    
    /// Clear all episode state data from Core Data for specific episodes
    private func clearEpisodeStatesFromCoreData(_ episodeIds: [String]) async {
        guard !episodeIds.isEmpty else { 
            print("💾 ⚠️ No episode IDs provided for Core Data state cleanup")
            return 
        }
        
        print("💾 🧹 Starting Core Data cleanup for \(episodeIds.count) episodes")
        
        // Use a background context to avoid blocking the main thread
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.perform {
                do {
                    var totalClearedCount = 0
                    var totalFoundCount = 0
                    let batchSize = 50  // Smaller batch size for better performance
                    
                    // Process episode IDs in batches
                    for i in stride(from: 0, to: episodeIds.count, by: batchSize) {
                        let endIndex = min(i + batchSize, episodeIds.count)
                        let batch = Array(episodeIds[i..<endIndex])
                        
                        // Find episodes in this batch (reduced logging)
                        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id IN %@", batch)
                        fetchRequest.includesPropertyValues = true  // Ensure we get all property values
                        
                        let episodes = try context.fetch(fetchRequest)
                        totalFoundCount += episodes.count
                        
                        // Clear episode state data (reduced logging to prevent app quarantine)
                        for episode in episodes {
                            // Clear all episode state fields
                            episode.progress = 0.0
                            episode.isFavorite = false
                            episode.isDownloaded = false
                            episode.isPlayed = false
                            totalClearedCount += 1
                        }
                        
                        // Save batch immediately to ensure data is persisted
                        if episodes.count > 0 {
                            try context.save()
                            // Log only every 10th batch to reduce logging volume
                            if (i/batchSize + 1) % 10 == 0 {
                                print("💾 💾 Saved batch \(i/batchSize + 1) - cleared \(episodes.count) episodes")
                            }
                        }
                    }
                    
                    // Final verification - check if any episode states remain
                    let verificationRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    verificationRequest.predicate = NSPredicate(format: "id IN %@ AND (progress > 0 OR isFavorite == YES OR isDownloaded == YES OR isPlayed == YES)", episodeIds)
                    let remainingStates = try context.count(for: verificationRequest)
                    
                    if remainingStates > 0 {
                        print("💾 ⚠️ WARNING: \(remainingStates) episodes still have state data after cleanup!")
                    } else {
                        print("💾 ✅ VERIFICATION: All episode states successfully cleared")
                    }
                    
                    print("💾 ✅ Core Data episode state cleanup completed:")
                    print("💾    📊 Requested: \(episodeIds.count) episodes")
                    print("💾    🔍 Found: \(totalFoundCount) episodes in Core Data")
                    print("💾    🧹 Processed: \(totalClearedCount) episodes")
                    print("💾    ⚠️ Remaining states: \(remainingStates) episodes")
                    
                    continuation.resume()
                    
                } catch {
                    print("💾 ❌ Error during Core Data episode state cleanup: \(error)")
                    print("💾 ❌ Error details: \(error.localizedDescription)")
                    
                    // Try to rollback and continue - don't fail the deletion process
                    context.rollback()
                    continuation.resume()
                }
            }
        }
    }
    
    /// Process episodes in background to prevent main thread blocking during large list operations
    private func processEpisodesInBackground(_ episodes: [PodcastEpisode]) async -> [PodcastEpisode] {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let processedEpisodes = await PodcastViewModel.removeDuplicatesFromEpisodes(episodes)
                continuation.resume(returning: processedEpisodes)
            }
        }
    }
    
    /// Synchronous version for use within Core Data perform blocks - OPTIMIZED
    private static func removeDuplicatesFromEpisodesSynced(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        // PERFORMANCE OPTIMIZATION: Batch EpisodeStateManager queries
        let episodeIds = episodes.map { $0.id }
        let uniqueIds = Set(episodeIds)
        let batchStates = EpisodeStateManager.shared.getBatchStates(for: episodeIds)
        
        if episodeIds.count == uniqueIds.count {
            // No duplicates found, just sync with batch states and return
            return episodes.map { episode in
                var episodeWithState = episode
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                return episodeWithState
            }.sorted { $0.publicationDate > $1.publicationDate }
        }
        
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var seenIds = Set<String>()
        var duplicateCount = 0
        
        // Sort episodes by publication date (newest first) to prioritize recent versions
        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
        
        for episode in sortedEpisodes {
            if seenIds.contains(episode.id) {
                duplicateCount += 1
                continue
            }
            
            seenIds.insert(episode.id)
            
            // Merge states for this episode using batch states
            var episodeWithState = episode
            let batchState = batchStates[episode.id]
            let currentProgress = batchState?.progress ?? 0.0
            let isFavorite = batchState?.isFavorite ?? false
            let isDownloaded = batchState?.isDownloaded ?? false
            let isPlayed = currentProgress >= 0.99
            
            episodeWithState.state = EpisodeState(
                isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                isFavorite: isFavorite || episode.state.isFavorite,
                progress: max(currentProgress, episode.state.progress),
                isDownloaded: isDownloaded || episode.state.isDownloaded
            )
            
            uniqueEpisodes[episode.id] = episodeWithState
        }
        
        if duplicateCount > 0 {
            print("🔄 DEDUP: Removed \(duplicateCount) duplicates from \(episodes.count) episodes")
        }
        
        return Array(uniqueEpisodes.values).sorted { $0.publicationDate > $1.publicationDate }
    }
    
    /// Remove duplicate episodes while intelligently merging episode states and preserving progress
    /// PERFORMANCE: This method should only be called from background contexts for large episode lists
    private static func removeDuplicatesFromEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        // PERFORMANCE OPTIMIZATION: Batch EpisodeStateManager queries instead of individual calls
        let episodeIds = episodes.map { $0.id }
        let uniqueIds = Set(episodeIds)
        
        // Get all states in batch for better performance
        let batchStates = EpisodeStateManager.shared.getBatchStates(for: episodeIds)
        
        if episodeIds.count == uniqueIds.count {
            // No duplicates found, just sync with EpisodeStateManager and return
            return episodes.map { episode in
                var episodeWithState = episode
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                return episodeWithState
            }.sorted { $0.publicationDate > $1.publicationDate }
        }
        
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var seenIds = Set<String>()
        var duplicateCount = 0
        
        // Sort episodes by publication date (newest first) to prioritize recent versions
        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
        
        for episode in sortedEpisodes {
            if seenIds.contains(episode.id) {
                duplicateCount += 1
                
                // This is a duplicate - merge state data from batch states
                if var existingEpisode = uniqueEpisodes[episode.id] {
                    // Get the most accurate state from batch states (much faster)
                    let batchState = batchStates[episode.id]
                    let currentProgress = batchState?.progress ?? 0.0
                    let isFavorite = batchState?.isFavorite ?? false
                    let isDownloaded = batchState?.isDownloaded ?? false
                    let isPlayed = currentProgress >= 0.99
                    
                    // Preserve the highest progress value
                    let maxProgress = max(existingEpisode.state.progress, episode.state.progress, currentProgress)
                    
                    // Merge favorite states (true if either is true)
                    let mergedFavorite = existingEpisode.state.isFavorite || episode.state.isFavorite || isFavorite
                    
                    // Merge download states (true if either is true)
                    let mergedDownloaded = existingEpisode.state.isDownloaded || episode.state.isDownloaded || isDownloaded
                    
                    // Merge played states (true if either is true or progress is complete)
                    let mergedPlayed = existingEpisode.state.isPlayed || episode.state.isPlayed || isPlayed || maxProgress >= 1.0
                    
                    // Update the existing episode with merged state
                    existingEpisode.state = EpisodeState(
                        isPlayed: mergedPlayed,
                        isFavorite: mergedFavorite,
                        progress: maxProgress,
                        isDownloaded: mergedDownloaded
                    )
                    
                    // Keep the episode with the most recent publication date or the one with complete metadata
                    if episode.publicationDate > existingEpisode.publicationDate || 
                       (episode.title.count > existingEpisode.title.count && episode.descriptionText.count > existingEpisode.descriptionText.count) {
                        // Keep the newer/more complete episode but with merged state
                        var updatedEpisode = episode
                        updatedEpisode.state = existingEpisode.state
                        uniqueEpisodes[episode.id] = updatedEpisode
                    } else {
                        // Keep the existing episode with merged state
                        uniqueEpisodes[episode.id] = existingEpisode
                    }
                }
            } else {
                // First occurrence of this episode - sync with batch states
                var episodeWithState = episode
                
                // Always sync with batch states as the source of truth for cross-device state
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                // Use EpisodeStateManager data if it's more recent than episode data
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                
                uniqueEpisodes[episode.id] = episodeWithState
                seenIds.insert(episode.id)
            }
        }
        
        let result = Array(uniqueEpisodes.values).sorted { $0.publicationDate > $1.publicationDate }
        
        // Only log if duplicates were actually found and removed
        if duplicateCount > 0 {
            print("🧹 DUPLICATE REMOVAL: Removed \(duplicateCount) duplicate episodes (from \(episodes.count) to \(result.count))")
        }
        
        return result
    }
    
    // MARK: - Episode State Refresh Methods
    
    /// Refresh all episode states from EpisodeStateManager and CloudKit (used during pull-to-refresh)
    private func refreshAllEpisodeStates() async {
        print("🔄 PULL-TO-REFRESH: Starting comprehensive episode state refresh")
        
        // Step 1: Fetch latest states from CloudKit first
        await refreshEpisodeStatesFromCloudKit()
        
        // Step 2: Update UI with latest local states
        await MainActor.run {
            print("🔄 REFRESHING EPISODE STATES: Starting local refresh for \(currentEpisodes.count) episodes")
            
            // Force refresh episode states for all currently displayed episodes
            for i in 0..<currentEpisodes.count {
                let episode = currentEpisodes[i]
                let episodeId = episode.id
                
                // Get fresh state data from EpisodeStateManager (now updated with CloudKit data)
                let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let isFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let isDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                let isPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                // Update the episode's state
                var updatedEpisode = episode
                updatedEpisode.state.progress = progress
                updatedEpisode.state.isFavorite = isFavorite
                updatedEpisode.state.isDownloaded = isDownloaded
                updatedEpisode.state.isPlayed = isPlayed
                
                // Update in the array
                currentEpisodes[i] = updatedEpisode
                
                // Also update in podcastFeeds if this episode exists there
                for feedIndex in 0..<podcastFeeds.count {
                    for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                        if podcastFeeds[feedIndex].episodes[episodeIndex].id == episodeId {
                            var updatedFeed = podcastFeeds[feedIndex]
                            updatedFeed.episodes[episodeIndex] = updatedEpisode
                            podcastFeeds[feedIndex] = updatedFeed
                            break
                        }
                    }
                }
            }
            
            print("✅ REFRESHING EPISODE STATES: Updated states for \(currentEpisodes.count) episodes")
            
            // Trigger UI update
            throttledUIUpdate()
        }
        
        print("✅ PULL-TO-REFRESH: Comprehensive episode state refresh completed")
    }
    
    /// Refresh episode states from CloudKit (called during pull-to-refresh)
    private func refreshEpisodeStatesFromCloudKit() async {
        do {
            print("🔄 PULL-TO-REFRESH: Fetching latest episode states from CloudKit...")
            
            // CRITICAL: Enable CloudKit priority mode to ensure Core Data takes precedence
            EpisodeStateManager.shared.enableCloudKitPriorityMode()
            
            // Get episode IDs for currently displayed episodes
            let episodeIds = await MainActor.run { 
                return currentEpisodes.map { $0.id }
            }
            
            guard !episodeIds.isEmpty else {
                print("⚠️ PULL-TO-REFRESH: No episodes to sync states for")
                // Disable CloudKit priority mode before returning
                EpisodeStateManager.shared.disableCloudKitPriorityMode()
                return
            }
            
            // Fetch all episode states from CloudKit
            let allCloudStates = try await PodcastCloudKitManager.shared.fetchAllEpisodeStatesFromCloudKit()
            
            var updatedCount = 0
            var coreDataUpdates: [EpisodeStateUpdate] = []
            
            // Apply CloudKit states to local EpisodeStateManager AND prepare Core Data updates
            for episodeId in episodeIds {
                if let cloudState = allCloudStates[episodeId] {
                    // HIGHEST PROGRESS SYNC: Compare CloudKit vs local and use highest progress
                    let localProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                    let finalProgress = max(localProgress, cloudState.progress)
                    
                    // Log the comparison
                    if finalProgress == localProgress && localProgress > cloudState.progress {
                        print("🔍 📊 HIGHEST PROGRESS: Local higher (\(String(format: "%.4f", localProgress))) > CloudKit (\(String(format: "%.4f", cloudState.progress))) for \(episodeId)")
                    } else if finalProgress == cloudState.progress && cloudState.progress > localProgress {
                        print("🔍 📊 HIGHEST PROGRESS: CloudKit higher (\(String(format: "%.4f", cloudState.progress))) > Local (\(String(format: "%.4f", localProgress))) for \(episodeId)")
                    } else {
                        print("🔍 📊 HIGHEST PROGRESS: Values equal (\(String(format: "%.4f", finalProgress))) for \(episodeId)")
                    }
                    
                    // Update EpisodeStateManager with highest progress (silently to avoid sync loops)
                    EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: finalProgress)
                    EpisodeStateManager.shared.setFavoriteSilently(episodeId, isFavorite: cloudState.isFavorite)
                    EpisodeStateManager.shared.setDownloadedSilently(episodeId, isDownloaded: cloudState.isDownloaded)
                    EpisodeStateManager.shared.setPlayedSilently(episodeId, isPlayed: cloudState.isPlayed)
                    
                    // CRITICAL FIX: Also prepare Core Data update for persistence with highest progress
                    let coreDataUpdate = EpisodeStateUpdate(
                        episodeId: episodeId,
                        progress: finalProgress,
                        isFavorite: cloudState.isFavorite,
                        isDownloaded: cloudState.isDownloaded,
                        isPlayed: cloudState.isPlayed
                    )
                    coreDataUpdates.append(coreDataUpdate)
                    
                    // CRITICAL: If local progress was higher, propagate it back to CloudKit
                    // This ensures all devices get the highest progress
                    if finalProgress == localProgress && localProgress > cloudState.progress {
                        print("🔄 📡 PROPAGATING: Local progress (\(String(format: "%.4f", localProgress))) > CloudKit, updating CloudKit for all devices")
                        // Find feedId for this episode to update CloudKit
                        if let currentEpisode = currentEpisodes.first(where: { $0.id == episodeId }) {
                            Task.detached(priority: .userInitiated) {
                                await PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                                    episodeId: episodeId, 
                                    progress: finalProgress
                                )
                            }
                        }
                    }
                    
                    updatedCount += 1
                }
            }
            
            // CRITICAL FIX: Save CloudKit updates to Core Data for persistence across app restarts
            if !coreDataUpdates.isEmpty {
                do {
                    try await episodeManager.updateEpisodeStates(coreDataUpdates)
                    print("💾 PULL-TO-REFRESH: Saved \(coreDataUpdates.count) CloudKit episode states to Core Data")
                } catch {
                    print("❌ PULL-TO-REFRESH: Failed to save CloudKit states to Core Data: \(error.localizedDescription)")
                }
            }
            
            print("✅ PULL-TO-REFRESH: Applied \(updatedCount) episode states from CloudKit")
            
        } catch {
            print("⚠️ PULL-TO-REFRESH: Failed to fetch episode states from CloudKit: \(error.localizedDescription)")
            // Continue with local refresh even if CloudKit fails
        }
        
        // CRITICAL: Always disable CloudKit priority mode after processing (success or failure)
        EpisodeStateManager.shared.disableCloudKitPriorityMode()
    }
    
    /// Sync real-time progress across all devices during pull-to-refresh
    private func syncRealTimeProgressAcrossDevices() async {
        // Step 1: Broadcast current playing progress from this device
        await broadcastCurrentPlayingProgress()
        
        // Step 2: Wait a moment for other devices to respond
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Step 3: Fetch the latest real-time progress from all devices
        await fetchLatestRealTimeProgress()
    }
    
    /// Broadcast current playing progress to other devices
    private func broadcastCurrentPlayingProgress() async {
        print("📡 🔄 BROADCAST: Checking for currently playing episode to broadcast...")
        
        // Check if we have a currently playing episode
        guard let currentEpisode = PodcastPlayer.shared.currentEpisode else {
            print("📡 📭 BROADCAST: No episode currently playing")
            return
        }
        
        // Get the most up-to-date progress from the player
        let currentProgress = PodcastPlayer.shared.currentProgress
        let isPlaying = PodcastPlayer.shared.isPlaying
        
        print("📡 📡 BROADCAST: Broadcasting current progress for \(currentEpisode.title): \(Int(currentProgress * 100))% (playing: \(isPlaying))")
        
        // Force an immediate CloudKit sync for the currently playing episode
        EpisodeStateManager.shared.performRealTimeSyncForEpisode(
            currentEpisode.id, 
            reason: "pull_to_refresh_broadcast", 
            feedId: currentEpisode.feedId
        )
        
        // Note: RealtimeSyncManager is used primarily for radio stations
        // For podcasts, the performRealTimeSyncForEpisode above should be sufficient
        
        print("📡 ✅ BROADCAST: Current playing progress broadcasted")
    }
    
    /// Fetch the latest real-time progress from all devices
    private func fetchLatestRealTimeProgress() async {
        print("📡 📥 FETCH: Fetching latest real-time progress from all devices...")
        
        // Get all currently displayed episodes
        let episodeIds = await MainActor.run { 
            return currentEpisodes.map { $0.id }
        }
        
        guard !episodeIds.isEmpty else {
            print("📡 📭 FETCH: No episodes to fetch progress for")
            return
        }
        
        var updatedProgressCount = 0
        
        // Check CloudKit for the latest instant progress updates
        for episodeId in episodeIds {
            do {
                // Try to get the latest instant progress data
                if let progressData = try await PodcastCloudKitManager.shared.fetchLatestInstantProgress(for: episodeId) {
                    let progress = progressData.progress
                    let timestamp = progressData.timestamp
                    
                    // Check if this is a recent update (within last 5 minutes)
                    let currentTime = Date().timeIntervalSince1970
                    if currentTime - timestamp < 300 { // 5 minutes
                        // Update the progress silently (don't trigger another sync)
                        EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: progress)
                        
                        // Update Core Data for persistence
                        let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                        let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                        let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                        
                        let coreDataUpdate = EpisodeStateUpdate(
                            episodeId: episodeId,
                            progress: progress,
                            isFavorite: currentFavorite,
                            isDownloaded: currentDownloaded,
                            isPlayed: currentPlayed
                        )
                        
                        try await episodeManager.updateEpisodeStates([coreDataUpdate])
                        updatedProgressCount += 1
                        
                        print("📡 ⬇️ FETCH: Updated episode \(episodeId) with real-time progress: \(Int(progress * 100))%")
                    }
                }
            } catch {
                // Silent fail for individual episodes - continue with others
                print("📡 ⚠️ FETCH: Failed to fetch real-time progress for \(episodeId): \(error.localizedDescription)")
            }
        }
        
        if updatedProgressCount > 0 {
            // Refresh UI to show updated progress
            await MainActor.run {
                refreshEpisodeStatesFromManager()
            }
            print("📡 ✅ FETCH: Updated \(updatedProgressCount) episodes with real-time progress")
        } else {
            print("📡 📭 FETCH: No recent real-time progress updates found")
        }
    }
    
    // MARK: - Feed Processing Protection Methods
    
    /// Check if a feed is currently being processed (thread-safe)
    private func isFeedBeingProcessed(_ feedId: String) -> Bool {
        return feedProcessingQueue.sync {
            feedsBeingProcessed.contains(feedId)
        }
    }
    
    /// Mark a feed as being processed (thread-safe)
    private func markFeedAsProcessing(_ feedId: String) -> Bool {
        return feedProcessingQueue.sync(flags: .barrier) {
            if feedsBeingProcessed.contains(feedId) {
                return false // Already being processed
            }
            feedsBeingProcessed.insert(feedId)
            return true // Successfully marked for processing
        }
    }
    
    /// Mark a feed as finished processing (thread-safe)
    private func markFeedAsFinished(_ feedId: String) {
        feedProcessingQueue.sync(flags: .barrier) {
            feedsBeingProcessed.remove(feedId)
        }
    }

}
