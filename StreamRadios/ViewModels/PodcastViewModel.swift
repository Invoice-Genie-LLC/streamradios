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
    
    // MARK: - Private Properties
    private let log = OSLog(subsystem: "StreamRadios", category: "PodcastViewModel")
    private let feedManager = PodcastFeedManager()
    private let episodeManager = PodcastEpisodeManager()
    private let cloudKitManager = PodcastCloudKitManager.shared
    private var cancellables = Set<AnyCancellable>()
    
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
    private var pendingInitializationTasks = Set<String>()
    
    // Current state
    private var selectedFeedId: String?
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
                
                print("📡 ✅ Applied instant podcast progress sync with UI refresh: \(episodeId) (\(String(format: "%.2f", progress * 100))%%)")
            }
        }
    }
    
    @objc private func handleInstantEpisodeProgressChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            return
        }
        
        print("📡 ⚡ INSTANT PROGRESS UPDATE: Episode \(episodeId) progress \(String(format: "%.2f", progress * 100))%")
        
        DispatchQueue.main.async {
            // Update episodeProgress cache for immediate UI refresh
            self.episodeProgress[episodeId] = progress
            
            // Update UI state immediately
            self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: progress)
            
            print("📡 ⚡ UI REFRESHED: Episode \(episodeId) progress updated to \(String(format: "%.2f", progress * 100))%")
        }
    }
    
    @objc private func handleInstantPodcastFeedAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedData = userInfo["feed"] as? [String: Any] else {
            return
        }
        
        // Convert dictionary back to PodcastFeed
        if let feed = podcastFeedFromDictionary(feedData) {
            // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
            let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
            
            if isDuplicateInMemory {
                print("📡 ⚠️ INSTANT SYNC: Duplicate detected in memory, skipping: \(feed.title)")
                return
            }
            
            // Check Core Data for duplicate (thread-safe)
            Task {
                let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
                
                if isDuplicateInCoreData {
                    print("📡 ⚠️ INSTANT SYNC: Duplicate detected in Core Data, skipping: \(feed.title)")
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
                    print("📡 ✅ Applied instant podcast feed removal sync: \(feedTitle)")
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
        print("📡 🔔 FAVORITE SYNC RECEIVED: Processing favorite sync notification...")
        
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("📡 ❌ FAVORITE SYNC FAILED: Invalid notification data")
            return
        }
        
        print("📡 🔔 FAVORITE SYNC: Episode \(episodeId) favorite change to \(isFavorite)")
        
        // Update episode favorite status from remote sync
        let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
        print("📡 🔔 FAVORITE SYNC: Current state: \(currentFavorite), New state: \(isFavorite)")
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager to ensure consistency
            EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // The UI might be out of sync with the data state, so force refresh
            self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
            
            if currentFavorite != isFavorite {
                print("📡 ✅ Applied instant podcast favorite sync with data change: \(episodeId) (favorite: \(isFavorite))")
            } else {
                print("📡 🔄 FAVORITE SYNC: States matched but forced UI refresh: \(episodeId) (favorite: \(isFavorite))")
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
            // Update EpisodeStateManager to ensure consistency
            EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // The UI might be out of sync with the data state, so force refresh
            self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
            
            if currentDownloaded != isDownloaded {
                print("📡 ✅ Applied instant podcast download sync with data change: \(episodeId) (downloaded: \(isDownloaded))")
            } else {
                print("📡 🔄 DOWNLOAD SYNC: States matched but forced UI refresh: \(episodeId) (downloaded: \(isDownloaded))")
            }
        }
    }
    
    // MARK: - UI State Update Helper
    
    /// Update episode UI state immediately for automatic view refresh across tabs
    private func updateEpisodeUIState(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double? = nil) {
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
            print("🔄 UI UPDATE: Updated currentEpisodes[\\(index)] for episode \\(episodeId)")
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
                print("🔄 UI UPDATE: Updated podcastFeeds[\\(feedIndex)].episodes[\\(episodeIndex)] for episode \\(episodeId)")
                break
            }
        }
        
        // Apply tab filtering immediately if needed
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
    }
    
    // MARK: - CloudKit Automatic Sync Handlers
    
    @objc private func handleCloudKitFeedAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feed = userInfo["feed"] as? PodcastFeed else {
            print("📡 ☁️ CLOUDKIT FEED ADD FAILED: Invalid feed data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT FEED ADD: Received feed addition from CloudKit: \(feed.title)")
        
        // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
        let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
        
        if isDuplicateInMemory {
            print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in memory, skipping: \(feed.title)")
            return
        }
        
        // Check Core Data for duplicate (thread-safe)
        Task {
            let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
            
            if isDuplicateInCoreData {
                print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in Core Data, skipping: \(feed.title)")
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
                    } else {
                        print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Last-second duplicate check prevented duplicate: \(feed.title)")
                    }
                    
                    // Reset parsing progress after successful completion
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                }
                
            } catch {
                print("📡 ❌ CLOUDKIT FEED ADD: Failed to fetch episodes for \(feed.title): \(error)")
                
                // Still save the feed to Core Data even without episodes
                do {
                    try await saveFeedToCoreData(feed)
                    await addFeedToUIOnly(feed)
                    print("📡 ✅ CLOUDKIT FEED ADD: Saved feed without episodes as fallback: \(feed.title)")
                } catch {
                    print("📡 ❌ CLOUDKIT FEED ADD: Failed to save feed as fallback: \(error)")
                }
                
                // Reset parsing progress after error
                await MainActor.run {
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                }
            }
        }
    }
    
    /// Parse RSS feed to get episodes only (without saving feed to Core Data)
    private func parseRSSEpisodesOnly(from url: URL) async throws -> [PodcastEpisode] {
        print("🔍 Parsing RSS episodes from: \(url.absoluteString)")
        
        // Fetch RSS data
        let (feedData, _) = try await URLSession.shared.data(from: url)
        
        // Parse RSS using the same parser as PodcastFeedManager with progress tracking
        let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString) { [weak self] progress, message in
            Task { @MainActor in
                DataSyncManager.shared.updateFeedParsingProgress(progress, message: message)
            }
        }
        let (_, episodes) = try parser.parseComplete()
        
        print("🔍 Parsed \(episodes.count) episodes from RSS")
        return episodes
    }
    
    /// Helper met hod to add feed to UI without episode parsing (fallback)
    @MainActor
    private func addFeedToUIOnly(_ feed: PodcastFeed) {
        if !podcastFeeds.contains(where: { $0.id == feed.id }) {
            podcastFeeds.append(feed)
            podcastFeedOrder.append(feed.id)
            throttledUIUpdate()
            print("📡 ☁️ CLOUDKIT FEED ADD: ✅ Added feed (without episodes) from CloudKit: \(feed.title)")
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
            
            print("📡 ☁️ CLOUDKIT FEED DELETE: Starting comprehensive cleanup for: \(feedTitle)")
            
            Task {
                // Step 1: Get episode IDs for comprehensive cleanup
                let episodeIds = await getEpisodeIdsForFeed(feedId)
                print("📡 ☁️ Found \(episodeIds.count) episodes to clean up for CloudKit deletion: \(feedTitle)")
                
                // Step 2: Clean up episode data from EpisodeStateManager (prevents duplication)
                for episodeId in episodeIds {
                    EpisodeStateManager.shared.clearEpisodeData(episodeId)
                }
                print("📡 ☁️ Cleared \(episodeIds.count) episode states from EpisodeStateManager")
                
                // Step 3: Delete downloaded episode files (prevents storage bloat)
                await deleteDownloadedEpisodeFiles(episodeIds)
                print("📡 ☁️ Cleaned up downloaded files for \(episodeIds.count) episodes")
                
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
                    print("📡 ☁️ Deleted feed and episodes from Core Data: \(feedTitle)")
                    
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
            await MainActor.run {
                self.error = error.localizedDescription
            }
            print("❌ Failed to add podcast feed: \(error)")
            return false
        }
    }
    
    /// Load episodes for a specific feed with efficient pagination and deduplication
    func loadEpisodesForFeed(_ feedId: String, isInitialLoad: Bool = false) async {
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
        
        selectedFeedId = feedId
        currentPage = 1
        
        // Check if episodes are already available before showing loading state
        let feed = podcastFeeds.first(where: { $0.id == feedId })
        let hasEpisodesInMemory = feed?.episodes.isEmpty == false
        
        await MainActor.run {
            // Only show loading if we don't have episodes cached AND we don't have current episodes
            if !hasEpisodesInMemory && self.currentEpisodes.isEmpty {
                self.isLoadingEpisodes = true
            }
            // SMOOTH LOADING: Don't clear currentEpisodes to prevent UI jump
            // Let the new episodes replace them naturally to avoid flickering
        }
        
        // CRITICAL: Refresh episode states from local storage before displaying
        // This ensures any locally available states are shown immediately
        await refreshLocalEpisodeStates()
        
        // AUTO-REFRESH: Check if feed needs RSS refresh for new episodes
        let shouldAutoRefresh = await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: isInitialLoad)
        if shouldAutoRefresh {
            // PERFORMANCE: Do RSS refresh in background to not block UI loading
            // Add a small delay to ensure UI is fully loaded first
            Task.detached(priority: .background) {
                // Wait a moment for UI to settle before starting background refresh
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                do {
                    print("🔄 Auto-refreshing feed \(feedId) from RSS for new episodes...")
                    let (updatedFeed, newEpisodes) = try await self.feedManager.refreshFeed(feedId)
                    
                    if !newEpisodes.isEmpty {
                        print("✅ Found \(newEpisodes.count) new episodes - updating Core Data")
                        try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                        
                        // Update the feed in memory with new episodes on main thread
                        await MainActor.run {
                            if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                                var updatedFeedWithEpisodes = self.podcastFeeds[feedIndex]
                                // Merge existing episodes with new ones, avoiding duplicates
                                let existingEpisodeIds = Set(updatedFeedWithEpisodes.episodes.map { $0.id })
                                let uniqueNewEpisodes = newEpisodes.filter { !existingEpisodeIds.contains($0.id) }
                                
                                // Only update if there are actually new episodes to avoid unnecessary UI jumps
                                if !uniqueNewEpisodes.isEmpty {
                                    print("🔄 Adding \(uniqueNewEpisodes.count) new episodes to UI for feed \(feedId)")
                                    updatedFeedWithEpisodes.episodes.append(contentsOf: uniqueNewEpisodes)
                                    updatedFeedWithEpisodes.episodes.sort { $0.publicationDate > $1.publicationDate }
                                    self.podcastFeeds[feedIndex] = updatedFeedWithEpisodes
                                    
                                    // SMOOTH UPDATE: Only refresh if this is the currently selected feed AND user isn't scrolling
                                    if self.selectedFeedId == feedId && !self.isUserScrolling {
                                        // Use a gentle update instead of full refresh to prevent jumping
                                        self.objectWillChange.send()
                                    }
                                } else {
                                    print("ℹ️ No new episodes to add for feed \(feedId) - UI stays stable")
                                }
                            }
                        }
                    } else {
                        print("ℹ️ No new episodes found for feed \(feedId)")
                    }
                } catch {
                    print("❌ Failed to auto-refresh feed \(feedId): \(error)")
                }
            }
        }
        
        // First check if episodes are already loaded in the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            // Reduce logging during scrolling for better performance
            if !isUserScrolling {
                print("🔍 DEBUG: Found \(feed.episodes.count) episodes already loaded in feed: \(feed.title)")
                print("⚡ Using cached episodes - no network request needed")
            }
            
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
            
            // Reduce logging during scrolling for better performance
            if !isUserScrolling {
                print("🔍 DEBUG: Applied filter \(filter) - showing \(filteredEpisodes.count) of \(episodesWithUpdatedStates.count) episodes")
            }
            
            await MainActor.run {
                // CRITICAL FIX: Remove duplicates and merge states before displaying
                let uniqueFilteredEpisodes = self.removeDuplicatesFromEpisodes(filteredEpisodes)
                self.currentEpisodes = uniqueFilteredEpisodes
                self.isLoadingEpisodes = false
                self.hasMoreEpisodes = false
                // Reduce logging during scrolling for better performance
                if !self.isUserScrolling {
                    if filteredEpisodes.count != uniqueFilteredEpisodes.count {
                        print("📊 ⚡ Deduplicated \(filteredEpisodes.count) to \(uniqueFilteredEpisodes.count) episodes before display")
                    }
                    print("📊 ⚡ Using pre-loaded episodes with filter: \(self.currentEpisodes.count) episodes displayed instantly")
                }
            }
            
            // PERFORMANCE: Clean up pending task before early return
            pendingInitializationTasks.remove(taskKey)
            return
        }
        
        print("🔍 DEBUG: No episodes found in feed object, loading from episode manager...")
        
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
    
    /// Refresh episodes for current feed by fetching from RSS
    func refreshCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        refreshTask?.cancel()
        
        refreshTask = Task {
            do {
                os_log("🔄 Refreshing feed from RSS: %@", log: log, type: .info, feedId)
                
                await MainActor.run {
                    // Only show loading if we don't have episodes to prevent UI jump
                    if self.currentEpisodes.isEmpty {
                        self.isLoadingEpisodes = true
                    }
                }
                
                // CRITICAL FIX: Actually refresh from RSS feed to get new episodes
                let (updatedFeed, newEpisodes) = try await feedManager.refreshFeed(feedId)
                print("✅ RSS refresh completed for '\(updatedFeed.title)' - found \(newEpisodes.count) new episodes")
                
                // Update Core Data with new episodes
                if !newEpisodes.isEmpty {
                    try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                    print("💾 Saved \(newEpisodes.count) new episodes to Core Data")
                }
                
                // Reload episodes from Core Data to show updated list including new episodes
                await loadEpisodesForFeed(feedId)
                
                await MainActor.run {
                    self.isLoadingEpisodes = false
                }
                
            } catch {
                await MainActor.run {
                    self.error = "Failed to refresh feed: \(error.localizedDescription)"
                    self.isLoadingEpisodes = false
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
                // CORRUPTION PROTECTION: If episode is currently playing at 0.0 but we're being asked 
                // to set accumulated progress > 0, this is corruption - use player's actual progress
                if isCurrentlyPlaying && playerProgress == 0.0 && explicitProgress > 0 {
                    finalProgress = playerProgress
                } else {
                    // Explicit progress provided and not a corruption case - use it
                    finalProgress = explicitProgress
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
                
                            // INSTANT SYNC: Sync episode progress immediately across devices
            print("📡 CALLING SYNC: Episode \(episodeId) progress \(finalProgress)")
            PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                episodeId: episodeId,
                progress: finalProgress
            )
            } else if isCurrentlyPlaying {
                // For currently playing episodes, sync the player's progress
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: playerProgress)
                
                // INSTANT SYNC: Sync episode progress immediately across devices
                print("📡 CALLING SYNC: Currently playing episode \(episodeId) progress \(playerProgress)")
                PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                    episodeId: episodeId,
                    progress: playerProgress
                )
            }
            // IMPORTANT: If no explicit progress and not currently playing, DON'T modify stored progress
            
            if let isFavorite = isFavorite {
                print("📡 UPDATE EPISODE STATE: Setting favorite \(episodeId) to \(isFavorite)")
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
                print("📡 UPDATE EPISODE STATE: EpisodeStateManager updated successfully")
                
                // INSTANT SYNC: Sync episode favorite immediately across devices
                print("📡 CALLING SYNC: Episode \(episodeId) favorite \(isFavorite)")
                PodcastCloudKitManager.shared.syncPodcastFavoriteInstantly(
                    episodeId: episodeId,
                    isFavorite: isFavorite
                )
                print("📡 SYNC CALL COMPLETED: syncPodcastFavoriteInstantly finished")
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    print("📡 UI UPDATE: Triggering updateEpisodeUIState for \(episodeId)")
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
                    print("📡 UI UPDATE COMPLETED: Episode UI state updated")
                }
            }
            if let isDownloaded = isDownloaded {
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
                
                // INSTANT SYNC: Sync episode download status immediately across devices
                print("📡 CALLING SYNC: Episode \(episodeId) download \(isDownloaded)")
                PodcastCloudKitManager.shared.syncPodcastDownloadInstantly(
                    episodeId: episodeId,
                    isDownloaded: isDownloaded
                )
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
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
                
                // Trigger immediate UI update for user feedback
                self.throttledUIUpdate()
            }
            
            // Step 3: **CRITICAL** - Delete from CloudKit FIRST before syncing to other devices
            // This prevents CloudKit from restoring the deleted feed on other devices
            var cloudKitDeletionSucceeded = false
            do {
                print("☁️ 🚨 CRITICAL STEP: Deleting from CloudKit BEFORE syncing to other devices")
                print("☁️ Feed to delete: '\(feed.title)' (\(feed.id))")
                
                // Debug: List all feeds in CloudKit before deletion
                print("🔍 DEBUG: Listing all feeds in CloudKit before deletion:")
                await cloudKitManager.debugListAllFeeds()
                
                // Debug: Check if feed exists by exact ID
                await cloudKitManager.debugCheckFeedExists(feed.id)
                
                try await cloudKitManager.deletePodcastFeedFromCloudKit(feed.id)
                cloudKitDeletionSucceeded = true
                
                print("☁️ ✅ SUCCESS: Feed deleted from CloudKit: \(feed.title)")
                print("☁️ ✅ CloudKit deleted all \(episodeIds.count) related episode states")
                
                // Debug: Verify deletion worked
                print("🔍 DEBUG: Verifying deletion in CloudKit:")
                await cloudKitManager.debugCheckFeedExists(feed.id)
                
            } catch {
                cloudKitDeletionSucceeded = false
                print("☁️ ❌ CRITICAL ERROR: Failed to delete from CloudKit: \(error)")
                print("☁️ ❌ This may cause the feed to reappear on other devices!")
                print("☁️ ❌ Error details: \(error.localizedDescription)")
                if let ckError = error as? CKError {
                    print("☁️ ❌ CloudKit error code: \(ckError.code)")
                }
            }
            
            // Step 4: Only sync to other devices AFTER CloudKit deletion succeeds
            // This ensures other devices won't have CloudKit restore the deleted feed
            if cloudKitDeletionSucceeded {
                await MainActor.run {
                    print("📡 🚀 NOW SAFE TO SYNC: CloudKit deletion successful, syncing to other devices")
                    print("📡 📝 Feed ID: \(feed.id)")
                    print("📡 📝 Feed Title: \(feed.title)")
                    print("📡 📝 Episode count: \(episodeIds.count)")
                    
                    PodcastCloudKitManager.shared.syncPodcastFeedRemovedInstantly(
                        feedId: feed.id,
                        feedTitle: feed.title,
                        episodeIds: episodeIds
                    )
                    
                    print("📡 ✅ SYNC TRIGGERED: Other devices will now delete feed safely")
                }
            } else {
                await MainActor.run {
                    print("📡 ⚠️ SYNC SKIPPED: CloudKit deletion failed, not syncing to prevent inconsistency")
                    print("📡 ⚠️ Feed may still exist in CloudKit and could reappear")
                    
                    // Show user warning about potential issues
                    NotificationManager.shared.notifyUserImmediate(
                        title: "Deletion Warning", 
                        message: "Feed deleted locally but may reappear due to sync issues"
                    )
                }
            }
            
            // Step 5: Final local cleanup - EpisodeStateManager, files, and Core Data  
            // (CloudKit deletion was already completed in Step 3 above)
            do {
                // Delete episode progress, favorites, and downloads from EpisodeStateManager
                for episodeId in episodeIds {
                    EpisodeStateManager.shared.clearEpisodeData(episodeId)
                }
                print("✅ Cleared \(episodeIds.count) episode states from EpisodeStateManager")
                
                // Delete downloaded episode files
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                // Delete from Core Data (episodes and feed) - CloudKit was already handled above
                try await deleteFeedFromCoreData(feed)
                print("💾 Deleted feed and \(episodeIds.count) episodes from Core Data: \(feed.title)")
                
                print("🎉 Successfully completed comprehensive deletion of: \(feed.title)")
                print("📊 Final cleanup summary:")
                print("   - CloudKit: ✅ Deleted FIRST (preventing restoration on other devices)")
                print("   - Cross-device sync: ✅ Triggered AFTER CloudKit deletion")
                print("   - EpisodeStateManager: ✅ \(episodeIds.count) episode states cleared")
                print("   - Downloaded files: ✅ Cleaned up")
                print("   - Core Data: ✅ Feed and episodes removed")
                print("🚨 CRITICAL: Proper order prevents feed from reappearing on other devices!")
                
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
                    // CRITICAL FIX: Merge and deduplicate when appending
                    let combinedEpisodes = self.currentEpisodes + result.episodes
                    let uniqueEpisodes = self.removeDuplicatesFromEpisodes(combinedEpisodes)
                    self.currentEpisodes = uniqueEpisodes
                    if combinedEpisodes.count != uniqueEpisodes.count {
                        print("🔄 APPEND DEDUP: Combined \(combinedEpisodes.count) episodes, deduped to \(uniqueEpisodes.count)")
                    }
                } else {
                    // CRITICAL FIX: Deduplicate episodes before replacing
                    let uniqueEpisodes = self.removeDuplicatesFromEpisodes(result.episodes)
                    self.currentEpisodes = uniqueEpisodes
                    if result.episodes.count != uniqueEpisodes.count {
                        print("🔄 REPLACE DEDUP: Loaded \(result.episodes.count) episodes, deduped to \(uniqueEpisodes.count)")
                    }
                }
                
                self.hasMoreEpisodes = result.hasMore
                self.isLoadingEpisodes = false
                
                print("🔍 DEBUG: Updated currentEpisodes to \(self.currentEpisodes.count) episodes")
                os_log("📊 Loaded %d episodes (page %d), hasMore: %@", 
                      log: self.log, type: .info, result.episodes.count, page, result.hasMore ? "true" : "false")
                
                // Report status to DataSyncManager when loading completes
                self.reportStatusToDataSyncManager()
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
        // Update current episodes with refreshed states
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
        // Reduce logging during scrolling for better performance
        if !isUserScrolling {
            print("🔄 Refreshing local episode states for immediate display...")
        }
        
        // Check if we have any episode progress data in EpisodeStateManager
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
                    
                    // Update UI on main thread with explicit refresh
                    await MainActor.run {
                        self.loadFeedsFromCoreData()
                        
                        // CRITICAL: Explicit UI refresh for CloudKit sync completion
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.throttledUIUpdate()
                            print("🎯 CLOUDKIT SYNC: Triggered explicit UI refresh - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                        }
                    }
                } else {
                    print("📡 No feeds found in CloudKit")
                }
            } else {
                print("⚡ Skipping CloudKit podcast feed sync - loading from local storage only for better performance")
                // Just load feeds from Core Data without CloudKit sync
                await MainActor.run {
                    self.loadFeedsFromCoreData()
                    
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
    private func syncEpisodeStatesFromCloudKit(isFreshInstall: Bool) async -> Bool {
        print("🔄 Syncing episode states from CloudKit (fresh install: \(isFreshInstall))")
        
        do {
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
                            let addedFeed = try await feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true)
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
        
        // CRITICAL: Wait briefly for main context synchronization to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
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
            self.throttledUIUpdate()
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
                            
                            let addedFeed = try await self.feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true)
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
            } else if isDefiniteUpgrade {
                print("🔄 App upgrade - syncing episode states with download protection...")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
                if syncSuccess {
                    print("✅ Episode states sync completed successfully for app upgrade")
                } else {
                    print("⚠️ Episode states sync failed for app upgrade - will retry on next launch")
                }
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
    
    /// Check if a feed should be refreshed from RSS for new episodes
    private func shouldRefreshFeedFromRSS(feedId: String, isInitialLoad: Bool) async -> Bool {
        // Check last refresh time first
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        let currentTime = Date().timeIntervalSince1970
        let hoursSinceLastRefresh = (currentTime - lastRefreshTime) / 3600
        
        // Check if feed has episodes in Core Data
        let episodeCount = await getEpisodeCountForFeed(feedId)
        
        // CRITICAL: Only refresh from RSS if really needed to avoid delays
        
        // 1. If feed has no episodes at all, definitely refresh
        if episodeCount == 0 {
            print("🔄 Feed \(feedId) needs refresh: no episodes found")
            UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            return true
        }
        
        // 2. If it's been more than 4 hours since last refresh, do background refresh
        if hoursSinceLastRefresh >= 4.0 {
            print("🔄 Feed \(feedId) needs refresh: \(Int(hoursSinceLastRefresh)) hours since last refresh")
            UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            return true
        }
        
        // 3. If feed has very few episodes (< 3), might need refresh
        if episodeCount < 3 {
            print("🔄 Feed \(feedId) needs refresh: only \(episodeCount) episodes available")
            UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            return true
        }
        
        // 4. For initial loads, only refresh if it's been more than 6 hours (reduced frequency)
        if isInitialLoad && hoursSinceLastRefresh >= 6.0 {
            print("🔄 Feed \(feedId) needs refresh on initial load: \(Int(hoursSinceLastRefresh)) hours since last refresh")
            UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            return true
        }
        
        print("⚡ Feed \(feedId) loading from Core Data: \(episodeCount) episodes available, last refreshed \(Int(hoursSinceLastRefresh * 60)) minutes ago")
        return false
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
    
    /// Reset the episode states sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if episode states get out of sync
    @MainActor
    func resetEpisodeStatesSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
        print("🔄 Reset episode states sync flag - will re-sync from CloudKit on next launch")
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
        print("📡 FAVORITE TOGGLE: About to call updateEpisodeState with isFavorite: \(newState)")
        
        // Use updateEpisodeState for consistent sync and data management
        // This will handle EpisodeStateManager updates, sync, and UI refresh automatically
        updateEpisodeState(episode.id, isFavorite: newState)
        
        print("🔍 DEBUG: ✅ Called updateEpisodeState for '\(episode.title)' favorite: \(newState)")
    }
    
    /// Toggle download state for an episode with proper filtering update
    func toggleDownload(for episode: PodcastEpisode) {
        let currentState = episode.state.isDownloaded
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling download for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        
        // Update EpisodeStateManager immediately (source of truth)
        EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: newState)
        
        // INSTANT SYNC: Sync podcast download immediately across devices
        PodcastCloudKitManager.shared.syncPodcastDownloadInstantly(
            episodeId: episode.id,
            isDownloaded: newState
        )
        
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
    
    /// Load podcast feeds from Core Data using the same pattern as radio stations with deduplication
    func loadFeedsFromCoreData() {
        // PERFORMANCE: Prevent redundant Core Data operations
        guard !isLoadingFromCoreData else {
            print("🔄 Core Data loading already in progress - skipping redundant call")
            return
        }
        
        isLoadingFromCoreData = true
        isLoading = true  // Set main loading flag for UI coordination
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
                    self.throttledUIUpdate()
                    print("📡 ✅ MAIN THREAD: Cleared all in-memory podcast data due to empty Core Data")
                }
                // PERFORMANCE: Reset flag before early return
                isLoadingFromCoreData = false
                isLoading = false  // Clear main loading flag
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
                    let loadedEpisodes = episodeModels.compactMap { $0.toPodcastEpisode() }
                    
                    // CRITICAL FIX: Remove duplicates and merge with EpisodeStateManager
                    episodes = self.removeDuplicatesFromEpisodes(loadedEpisodes)
                    print("📡 Loaded \(loadedEpisodes.count) episodes for feed: \(feedModel.title ?? "Unknown"), \(episodes.count) after deduplication")
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
                
                // Clear loading flags
                self.isLoading = false
                self.isLoadingFeeds = false
                print("📡 ✅ MAIN THREAD: Cleared loading flags - isLoading: false, isLoadingFeeds: false")
                
                // Single UI refresh after all properties are updated
                self.throttledUIUpdate()
                print("📡 ✅ MAIN THREAD: Triggered objectWillChange for UI refresh")
                
                // Report status to DataSyncManager
                self.reportStatusToDataSyncManager()
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
            // Clear loading flags on error
            DispatchQueue.main.async {
                self.isLoading = false
                self.isLoadingFeeds = false
            }
        }
        
        // PERFORMANCE: Reset flag after operation completes
        isLoadingFromCoreData = false
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
        
        // Also force a save to ensure UserDefaults are updated immediately
        EpisodeStateManager.shared.forceSave()
        print("🧹 EPISODE STATE CLEARING: Forced save completed - all local episode data cleared")
    }
    
    /// Remove duplicate episodes while intelligently merging episode states and preserving progress
    private func removeDuplicatesFromEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var seenIds = Set<String>()
        
        // Sort episodes by publication date (newest first) to prioritize recent versions
        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
        
        for episode in sortedEpisodes {
            if seenIds.contains(episode.id) {
                // This is a duplicate - merge state data from EpisodeStateManager
                if var existingEpisode = uniqueEpisodes[episode.id] {
                    // Get the most accurate state from EpisodeStateManager
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
                    let isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                    let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
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
                    
                    print("🔄 DUPLICATE MERGE: Merged duplicate episode '\(episode.title)' - Progress: \(maxProgress), Favorite: \(mergedFavorite), Downloaded: \(mergedDownloaded)")
                }
            } else {
                // First occurrence of this episode - sync with EpisodeStateManager
                var episodeWithState = episode
                
                // Always sync with EpisodeStateManager as the source of truth for cross-device state
                let currentProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
                let isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
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
        
        if episodes.count != result.count {
            print("🧹 DUPLICATE REMOVAL: Removed \(episodes.count - result.count) duplicate episodes (from \(episodes.count) to \(result.count))")
        }
        
        return result
    }

}
