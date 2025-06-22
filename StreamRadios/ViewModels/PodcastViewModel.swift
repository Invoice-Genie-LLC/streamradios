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

struct PodcastFeed: Identifiable, Codable, Equatable {
    let id: String
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
    var fileSize: Int64? // New property for file size in bytes
    
    var compositeID: String {
        // Use a more comprehensive identifier to avoid duplicates
        let dateString = String(publicationDate.timeIntervalSince1970)
        let titleHash = String(abs(title.hashValue))
        let audioUrlHash = String(abs(audioUrl.hashValue))
        // Include description snippet for additional uniqueness
        let descriptionSnippet = String(descriptionText.prefix(50).hashValue)
        return "\(feedId)_\(id)_\(dateString)_\(titleHash)_\(audioUrlHash)_\(descriptionSnippet)"
    }
    
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
        hasher.combine(publicationDate)
    }
    
    // We already have Equatable conformance, but let's make sure it's consistent with our hash function
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        return lhs.id == rhs.id &&
        lhs.feedId == rhs.feedId &&
        lhs.publicationDate == rhs.publicationDate
    }
}

struct EpisodeState: Codable, Equatable, Hashable {
    var isPlayed: Bool
    var isFavorite: Bool
    var progress: Double // 0.0 to 1.0
    var isDownloaded: Bool
}

class PodcastViewModel: ObservableObject {
    @Published var podcastFeeds: [PodcastFeed] = []
    @Published var allEpisodes: [PodcastEpisode] = []
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var downloadedEpisodes: [PodcastEpisode] = []
    @Published var favoriteEpisodes: [PodcastEpisode] = []
    private let episodeStatesKey = "PodcastEpisodeStates"
    private let favoritesKey = "FavoritePodcastEpisodes"
    private let progressKey = "PodcastProgress"
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastViewModel")
    @Published var isLoading = false
    @Published var error: String?
    @Published var episodeProgress: [String: Double] = [:]
    private var episodeProgressCache: [String: Double] = [:] // Non-published cache for getProgress
    @Published var downloadProgress: [String: Double] = [:]
    @Published var currentTab: Int = 0
    @Published var downloadedEpisodeIds: Set<String> = []
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var hasChanges = false
    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()
    private var backgroundContext: NSManagedObjectContext
    // Enhanced managers for optimal performance (temporarily using DataStore for compatibility)
    private let dataStore = DataStore.shared
    
    @Published var podcastFeedOrder: [String] = []
    @Published var isLoadingEpisodes = false
    private var episodeCache: [String: [PodcastEpisode]] = [:]
    private let episodeListKey = "PodcastEpisodeList"
    private let bookmarkStatusKey = "PodcastBookmarkStatus"
    private let downloadStatusKey = "PodcastDownloadStatus"
    @Published var lastPlayedEpisodes: [String: String] = [:]
    @Published var showNoEpisodesAlert = false
    @Published var noEpisodesAlertMessage = ""
    @Published var isAscendingSort = true // Track sort direction
    @Published var isLoadingMoreEpisodes = false
    @Published var hasMoreEpisodes = true
    private let episodesPerPage = 100 // Episodes per page for pagination
    var currentPage = 1
    private var isInitialLoadComplete = false
    
    // Fresh install episode limit
    private let maxEpisodesPerFeed = 100
    
    // Throttling for UI updates to prevent CPU spikes
    private var lastUpdateTime = Date()
    private let updateThrottleInterval: TimeInterval = 2.0 // 2 seconds between updates
    
    init(context: NSManagedObjectContext = CoreDataStack.shared.context) {
        self.context = context
        self.backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.backgroundContext.parent = context

        // Load lastPlayedEpisodes immediately (synchronously) so UI can use it right away
        self.loadLastPlayedEpisodes()

        // Check if this is a fresh install
        if isFirstInstall() {
            os_log("🌟 Fresh install detected - starting enhanced CloudKit setup", log: log, type: .info)
            Task(priority: .userInitiated) {
                await performOptimizedFreshInstallSetup()
            }
        } else {
            os_log("📱 Existing install - loading from Core Data", log: log, type: .info)
            // Perform instant loading for existing installs
            Task(priority: .userInitiated) {
                await loadInstantlyFromCoreData()
            }
        }
    }

    // MARK: - Fresh Install Setup
    
    private func isFirstInstall() -> Bool {
        let hasPodcastsKey = "HasPodcastsInstalled"
        return !UserDefaults.standard.bool(forKey: hasPodcastsKey)
    }
    
    private func markFirstInstallComplete() {
        UserDefaults.standard.set(true, forKey: "HasPodcastsInstalled")
    }
    
    /// Optimized fresh install setup with enhanced CloudKit and efficient preloading
    @MainActor
    private func performOptimizedFreshInstallSetup() async {
        os_log("🌟 Starting optimized fresh install setup", log: log, type: .info)
        isLoading = true
        
        do {
            // Step 1: Fetch all podcast feeds from CloudKit efficiently
            let cloudKitFeeds = try await fetchPodcastFeedsFromCloudKit()
            os_log("🌟 Retrieved %d feeds from CloudKit", log: log, type: .info, cloudKitFeeds.count)
            
            // Step 2: Process all feeds in parallel for maximum performance
            let preloadedFeeds = await processFeedsInParallel(cloudKitFeeds)
            os_log("🌟 Processed %d feeds with episodes", log: log, type: .info, preloadedFeeds.count)
            
            // Step 3: Store efficiently using batch operations
            await storeFeedsEfficientlyToCoreData(preloadedFeeds)
            os_log("🌟 Stored all data to Core Data efficiently", log: log, type: .info)
            
            // Step 4: Update UI with the preloaded data
            podcastFeeds = preloadedFeeds
            allEpisodes = preloadedFeeds.flatMap { $0.episodes }
            
            // Step 5: Cache episodes for instant access
            for feed in preloadedFeeds {
                episodeCache[feed.id] = feed.episodes
            }
            
            // Step 6: Set up feed order
            podcastFeedOrder = preloadedFeeds.map { $0.id }
            saveFeedOrder()
            
            // Step 7: Mark fresh install as complete
            markFirstInstallComplete()
            
            os_log("✅ Fresh install completed with %d feeds and %d episodes", 
                   log: log, type: .info, preloadedFeeds.count, allEpisodes.count)
            
        } catch {
            os_log("❌ Fresh install failed: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to set up podcasts: \(error.localizedDescription)"
        }
        
        isLoading = false
        isInitialLoadComplete = true
        
        // Notify CarPlay with fully loaded data
        CarPlayManager.shared.configurePodcastData(podcastFeeds)
        
        // Load episode progress in background
        Task(priority: .background) {
            await loadEpisodeProgress()
        }
    }
    
    /// Instant loading for existing installs using optimized Core Data
    @MainActor
    private func loadInstantlyFromCoreData() async {
        os_log("⚡ Loading podcasts instantly from Core Data", log: log, type: .info)
        isLoading = true
        
        do {
            // Load all podcasts with preloaded episodes instantly using optimized fetching
            let loadedFeeds = await loadAllPodcastsWithEpisodesInstantly()
            
            // Update UI immediately
            podcastFeeds = loadedFeeds
            allEpisodes = loadedFeeds.flatMap { $0.episodes }
            
            // Cache episodes for instant access
            for feed in loadedFeeds {
                episodeCache[feed.id] = feed.episodes
            }
            
            // Load feed order
            loadFeedOrder()
            
            os_log("⚡ Instantly loaded %d feeds with %d episodes", 
                   log: log, type: .info, loadedFeeds.count, allEpisodes.count)
            
        } catch {
            os_log("❌ Failed to load from Core Data: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to load podcasts: \(error.localizedDescription)"
        }
        
        isLoading = false
        isInitialLoadComplete = true
        
        // Notify CarPlay
        CarPlayManager.shared.configurePodcastData(podcastFeeds)
        
        // Load episode progress in background
        Task(priority: .background) {
            await loadEpisodeProgress()
        }
    }
    
    private func processFeedForFreshInstall(_ feed: PodcastFeed) async throws -> PodcastFeed {
        // Fetch RSS feed
        let updatedFeed = try await performRSSFetch(for: feed)
        
        // Limit episodes to maxEpisodesPerFeed
        let limitedEpisodes = Array(updatedFeed.episodes.prefix(maxEpisodesPerFeed))
        var processedFeed = updatedFeed
        processedFeed.episodes = limitedEpisodes
        
                 // Save to CoreData in background
         await saveFeedToCoreData(processedFeed)
        
        return processedFeed
    }
    
    private func saveFeedToCoreData(_ feed: PodcastFeed) async {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            do {
                // Save the feed
                let managedFeed = FeedModel(context: backgroundContext)
                managedFeed.update(from: feed)
                managedFeed.imageData = feed.imageData
                
                // Save episodes
                for episode in feed.episodes {
                    let managedEpisode = PodcastModel(context: backgroundContext)
                    managedEpisode.update(from: episode)
                    managedEpisode.feed = managedFeed
                    managedEpisode.feedId = feed.id
                }
                
                try backgroundContext.save()
                print("🎯 Saved feed '\(feed.title)' with \(feed.episodes.count) episodes to CoreData")
                
            } catch {
                print("❌ Error saving feed to CoreData: \(error)")
            }
        }
    }
    
    private func cacheArtworkForAllFeeds() async {
        print("🎯 Starting artwork caching for all feeds...")
        
        let feedsToCache = podcastFeeds.filter { $0.imageData == nil && $0.artworkUrl != nil }
        
        await withTaskGroup(of: Void.self) { group in
            for feed in feedsToCache {
                group.addTask {
                    await self.cacheArtworkForFeed(feed)
                }
            }
        }
        
        print("🎯 Artwork caching completed")
    }
    
    private func cacheArtworkForFeed(_ feed: PodcastFeed) async {
        guard let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Update the feed with cached artwork
            if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                await MainActor.run {
                    podcastFeeds[index].imageData = data
                }
            }
            
            // Save to CoreData
            await updateFeedInCoreData(feed, with: data)
            
            print("🎯 Cached artwork for feed: \(feed.title)")
            
        } catch {
            print("❌ Failed to cache artwork for feed \(feed.title): \(error)")
        }
    }
    
    private func updateFeedInCoreData(_ feed: PodcastFeed, with imageData: Data) async {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
            
            do {
                let results = try backgroundContext.fetch(fetchRequest)
                if let managedFeed = results.first {
                    managedFeed.imageData = imageData
                    try backgroundContext.save()
                }
            } catch {
                print("❌ Error updating feed artwork in CoreData: \(error)")
            }
        }
    }
    
    // MARK: - Load More Episodes (Pull to Refresh)
    
    func loadMoreEpisodesFromRSS(for feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
        print("🔄 Loading more episodes from RSS for feed: \(feed.title)")
        
        Task {
            do {
                let updatedFeed = try await performRSSFetch(for: feed)
                
                // Get current episodes from CoreData
                let currentStoredEpisodes = await self.getCurrentEpisodesFromCoreData(for: feed)
                let currentEpisodeIds = Set(currentStoredEpisodes.map { $0.id })
                
                // Find new episodes
                let newEpisodes = updatedFeed.episodes.filter { !currentEpisodeIds.contains($0.id) }
                
                if !newEpisodes.isEmpty {
                    // Save new episodes to CoreData
                    await saveNewEpisodesToCoreData(newEpisodes, for: feed)
                    
                    // Update local cache and current episodes
                    await MainActor.run {
                        if let index = self.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                            let allEpisodes = (self.podcastFeeds[index].episodes + newEpisodes)
                                .sorted { $0.publicationDate > $1.publicationDate }
                            self.podcastFeeds[index].episodes = allEpisodes
                        }
                        
                        // Update episode cache
                        self.episodeCache[feed.id] = (self.episodeCache[feed.id] ?? []) + newEpisodes
                        
                        // Update current episodes list if this is the active feed
                        if self.currentEpisodes.first?.feedId == feed.id {
                            self.currentEpisodes = (self.currentEpisodes + newEpisodes)
                                .sorted { $0.publicationDate > $1.publicationDate }
                        }
                        
                        self.objectWillChange.send()
                    }
                    
                    print("🔄 Added \(newEpisodes.count) new episodes for feed: \(feed.title)")
                    completion(true)
                } else {
                    print("🔄 No new episodes found for feed: \(feed.title)")
                    completion(false)
                }
            } catch {
                print("❌ Error loading more episodes: \(error)")
                completion(false)
            }
        }
    }
    
         // MARK: - Optimized Pull-to-Refresh
     
     /// Optimized method for loading more episodes with proper pagination
     func loadMoreEpisodes(for feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
         guard !isLoadingMoreEpisodes && hasMoreEpisodes else {
             completion(false)
             return
         }
         
         isLoadingMoreEpisodes = true
         let nextPage = currentPage + 1
         
         print("DEBUG: Loading more episodes - current page: \(currentPage), next page: \(nextPage)")
         
         // Use proper pagination instead of RSS refetch for "load more"
         fetchEpisodesWithFilter(for: feed, page: nextPage, tab: currentTab) { [weak self] result in
             guard let self = self else { 
                 completion(false)
                 return 
             }
             
             DispatchQueue.main.async {
                 self.isLoadingMoreEpisodes = false
                 
                 switch result {
                 case .success(let newEpisodes):
                     if !newEpisodes.isEmpty {
                         // Append new episodes to current episodes
                         let beforeCount = self.currentEpisodes.count
                         var updatedEpisodes = self.currentEpisodes
                         updatedEpisodes.append(contentsOf: newEpisodes)
                         
                         // Remove duplicates while preserving order
                         let uniqueEpisodes = self.removeDuplicatesFromEpisodes(updatedEpisodes)
                         self.currentEpisodes = uniqueEpisodes
                         
                         // Update pagination state
                         self.currentPage = nextPage
                         
                         // Check if we got less than a full page (indicates no more episodes)
                         if newEpisodes.count < self.episodesPerPage {
                             self.hasMoreEpisodes = false
                         }
                         
                         let newEpisodesAdded = uniqueEpisodes.count - beforeCount
                         print("DEBUG: Added \(newEpisodesAdded) new episodes (page \(nextPage)). Total: \(uniqueEpisodes.count)")
                         
                         self.objectWillChange.send()
                         completion(newEpisodesAdded > 0)
                     } else {
                         // No new episodes found
                         self.hasMoreEpisodes = false
                         completion(false)
                     }
                     
                 case .failure(let error):
                     print("❌ Failed to load more episodes: \(error)")
                     completion(false)
                 }
             }
         }
     }
     
     // MARK: - Utility Methods
     
     /// Save feed order to UserDefaults
     func saveFeedOrder() {
         UserDefaults.standard.set(podcastFeedOrder, forKey: "savedFeedOrder")
     }
     
     /// Move feed from one position to another
     func moveFeed(from source: IndexSet, to destination: Int) {
         podcastFeedOrder.move(fromOffsets: source, toOffset: destination)
         saveFeedOrder()
         objectWillChange.send()
     }
     
     /// Delete a podcast feed
     func deletePodcastFeed(_ feed: PodcastFeed) {
         // Remove from in-memory collections
         podcastFeeds.removeAll { $0.id == feed.id }
         podcastFeedOrder.removeAll { $0 == feed.id }
         allEpisodes.removeAll { $0.feedId == feed.id }
         currentEpisodes.removeAll { $0.feedId == feed.id }
         favoriteEpisodes.removeAll { $0.feedId == feed.id }
         downloadedEpisodes.removeAll { $0.feedId == feed.id }
         episodeCache.removeValue(forKey: feed.id)
         
         // Remove from Core Data
         let backgroundContext = CoreDataStack.shared.newBackgroundContext()
         backgroundContext.perform {
             // Delete episodes first
             let episodeFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
             episodeFetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
             
             do {
                 let episodes = try backgroundContext.fetch(episodeFetchRequest)
                 for episode in episodes {
                     backgroundContext.delete(episode)
                 }
             } catch {
                 print("❌ Error deleting episodes for feed \(feed.id): \(error)")
             }
             
             // Delete the feed
             let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
             feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
             
             do {
                 let feeds = try backgroundContext.fetch(feedFetchRequest)
                 for feedModel in feeds {
                     backgroundContext.delete(feedModel)
                 }
                 try backgroundContext.save()
             } catch {
                 print("❌ Error deleting feed \(feed.id): \(error)")
             }
         }
         
         // Save updated feed order
         saveFeedOrder()
         objectWillChange.send()
     }
     
     /// Add a new podcast feed
     func addPodcastFeed(_ feed: PodcastFeed) {
         // Add to in-memory collections
         podcastFeeds.append(feed)
         podcastFeedOrder.append(feed.id)
         
         // Save to Core Data
         let backgroundContext = CoreDataStack.shared.newBackgroundContext()
         backgroundContext.perform {
             let feedModel = FeedModel(context: backgroundContext)
             feedModel.id = feed.id
             feedModel.title = feed.title
             feedModel.url = feed.url
             feedModel.descriptionText = feed.descriptionText
             feedModel.artworkUrl = feed.artworkUrl
             
             do {
                 try backgroundContext.save()
             } catch {
                 print("❌ Error saving new feed \(feed.id): \(error)")
             }
         }
         
         // Fetch episodes for the new feed
         Task {
             do {
                 let rssData = try await performRSSFetch(for: feed)
                 await saveFeedToCoreData(rssData)
             } catch {
                 print("❌ Error fetching episodes for new feed: \(error)")
             }
         }
         
         saveFeedOrder()
         objectWillChange.send()
     }
     
     /// Update an existing podcast feed
     func updatePodcastFeed(_ updatedFeed: PodcastFeed) {
         // Update in-memory collection
         if let index = podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
             podcastFeeds[index] = updatedFeed
         }
         
         // Update in Core Data
         let backgroundContext = CoreDataStack.shared.newBackgroundContext()
         backgroundContext.perform {
             let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
             fetchRequest.predicate = NSPredicate(format: "id == %@", updatedFeed.id)
             
             do {
                 let feeds = try backgroundContext.fetch(fetchRequest)
                 if let feedModel = feeds.first {
                     feedModel.title = updatedFeed.title
                     feedModel.url = updatedFeed.url
                     feedModel.descriptionText = updatedFeed.descriptionText
                     feedModel.artworkUrl = updatedFeed.artworkUrl
                     try backgroundContext.save()
                 }
             } catch {
                 print("❌ Error updating feed \(updatedFeed.id): \(error)")
             }
         }
         
         objectWillChange.send()
     }
     
     /// Load episode progress from UserDefaults/EpisodeStateManager
     func loadAllEpisodesProgress() {
         // Load progress from EpisodeStateManager
         let allEpisodeIds = allEpisodes.map { $0.id }
         
         for episodeId in allEpisodeIds {
             let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
             if progress > 0 {
                 episodeProgress[episodeId] = progress
                 episodeProgressCache[episodeId] = progress
             }
         }
         
         print("🔄 Loaded progress for \(episodeProgress.count) episodes")
     }
     
     /// Clean up duplicate episodes
     func cleanupDuplicateEpisodes() {
         let backgroundContext = CoreDataStack.shared.newBackgroundContext()
         
         backgroundContext.perform {
             let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
             
             do {
                 let allEpisodes = try backgroundContext.fetch(fetchRequest)
                 var uniqueEpisodes = [String: PodcastModel]()
                 var duplicatesToDelete = [PodcastModel]()
                 
                 for episode in allEpisodes {
                     let key = "\(episode.feedId ?? "")_\(episode.id ?? "")"
                     
                     if let existingEpisode = uniqueEpisodes[key] {
                         // Keep the episode with more complete data
                         if episode.progress > existingEpisode.progress ||
                            episode.isFavorite && !existingEpisode.isFavorite ||
                            episode.isDownloaded && !existingEpisode.isDownloaded {
                             duplicatesToDelete.append(existingEpisode)
                             uniqueEpisodes[key] = episode
                         } else {
                             duplicatesToDelete.append(episode)
                         }
                     } else {
                         uniqueEpisodes[key] = episode
                     }
                 }
                 
                 // Delete duplicates
                 for duplicate in duplicatesToDelete {
                     backgroundContext.delete(duplicate)
                 }
                 
                 if !duplicatesToDelete.isEmpty {
                     try backgroundContext.save()
                     print("🧹 Cleaned up \(duplicatesToDelete.count) duplicate episodes")
                 }
                 
             } catch {
                 print("❌ Error cleaning up duplicate episodes: \(error)")
             }
         }
     }
     
     /// Save context if there are changes
     func saveContextIfNeeded() {
         if context.hasChanges {
             do {
                 try context.save()
                 print("💾 Saved context with changes")
             } catch {
                 print("❌ Error saving context: \(error)")
             }
         }
     }
    
    private func getCurrentEpisodesFromCoreData(for feed: PodcastFeed) async -> [PodcastEpisode] {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        return await backgroundContext.perform {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
            
            do {
                let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                return managedEpisodes.map { $0.toPodcastEpisode() }
            } catch {
                print("❌ Error fetching current episodes: \(error)")
                return []
            }
        }
    }
    
    private func saveNewEpisodesToCoreData(_ episodes: [PodcastEpisode], for feed: PodcastFeed) async {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            do {
                // Get the feed
                let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                
                let feedResults = try backgroundContext.fetch(feedFetchRequest)
                guard let managedFeed = feedResults.first else {
                    print("❌ Feed not found in CoreData")
                    return
                }
                
                // Save new episodes
                for episode in episodes {
                    let managedEpisode = PodcastModel(context: backgroundContext)
                    managedEpisode.update(from: episode)
                    managedEpisode.feed = managedFeed
                    managedEpisode.feedId = feed.id
                }
                
                try backgroundContext.save()
                print("🔄 Saved \(episodes.count) new episodes to CoreData")
                
            } catch {
                print("❌ Error saving new episodes to CoreData: \(error)")
            }
        }
    }

    @MainActor
    private func loadInitialData() async {
        // Load saved data first (including all episodes with favorite status)
        await backgroundContext.perform {
            self.loadSavedData()
        }
        
        // Then load episode progress
        await backgroundContext.perform {
            self.loadAllEpisodesProgress()
        }
        
        // Wait a bit to ensure Core Data loading is complete before any RSS updates
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Mark initial loading as complete
        await MainActor.run {
            self.isInitialLoadComplete = true
        }
        
        // Notify CarPlay that podcast data is now available
        CarPlayManager.shared.configurePodcastData(self.podcastFeeds)
        
        self.sendThrottledUpdate()
    }
    
    // MARK: - Load Data from CoreData
    
    private func loadSavedData() {
        print("🔄 Loading saved podcast data from CoreData...")
        
        // Load podcast feeds first
        loadPodcastFeeds()
        
        // Load all episodes with their states
        loadAllEpisodes()
        
        print("🔄 Finished loading saved data - Feeds: \(podcastFeeds.count), Episodes: \(allEpisodes.count)")
    }
    
    private func loadPodcastFeeds() {
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        fetchRequest.fetchBatchSize = 50 // Batch for performance
        
        do {
            let managedFeeds = try backgroundContext.fetch(fetchRequest)
            let feeds = managedFeeds.map { managedFeed -> PodcastFeed in
                var feed = managedFeed.toPodcastFeed()
                feed.imageData = managedFeed.imageData // Preserve cached artwork
                return feed
            }
            
            // Update on main thread
            DispatchQueue.main.async {
                self.podcastFeeds = feeds
                self.loadFeedOrder()
                print("🔄 Loaded \(feeds.count) podcast feeds from CoreData")
            }
            
        } catch {
            print("❌ Error loading podcast feeds from CoreData: \(error)")
        }
    }
    
    private func loadAllEpisodes() {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        fetchRequest.fetchBatchSize = 100 // Batch for performance
        fetchRequest.relationshipKeyPathsForPrefetching = ["feed"] // Prefetch relationships
        
        do {
            let managedEpisodes = try backgroundContext.fetch(fetchRequest)
            var episodes: [PodcastEpisode] = []
            var favoriteEps: [PodcastEpisode] = []
            var downloadedEps: [PodcastEpisode] = []
            var episodeCacheDict: [String: [PodcastEpisode]] = [:]
            
            for managedEpisode in managedEpisodes {
                var episode = managedEpisode.toPodcastEpisode()
                
                // Preserve states from CoreData
                episode.state.isPlayed = managedEpisode.isPlayed
                episode.state.progress = managedEpisode.progress
                episode.state.isFavorite = managedEpisode.isFavorite
                episode.state.isDownloaded = managedEpisode.isDownloaded
                episode.localFilePath = managedEpisode.localFilePath
                
                episodes.append(episode)
                
                // Build filtered arrays
                if episode.state.isFavorite {
                    favoriteEps.append(episode)
                }
                
                if episode.state.isDownloaded {
                    downloadedEps.append(episode)
                }
                
                // Build episode cache by feed
                if episodeCacheDict[episode.feedId] == nil {
                    episodeCacheDict[episode.feedId] = []
                }
                episodeCacheDict[episode.feedId]?.append(episode)
            }
            
            // Update on main thread
            DispatchQueue.main.async {
                self.allEpisodes = episodes
                self.favoriteEpisodes = favoriteEps
                self.downloadedEpisodes = downloadedEps
                self.episodeCache = episodeCacheDict
                
                print("🔄 Loaded \(episodes.count) episodes from CoreData")
                print("🔄 - Favorite episodes: \(favoriteEps.count)")
                print("🔄 - Downloaded episodes: \(downloadedEps.count)")
            }
            
                 } catch {
             print("❌ Error loading episodes from CoreData: \(error)")
         }
     }
     
     // MARK: - Optimized Episode Progress Loading
     
     /// Load episode progress efficiently in background
     private func loadEpisodeProgress() async {
         os_log("📊 Loading episode progress", log: log, type: .debug)
         
         await backgroundContext.perform {
             do {
                 let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "PodcastModel")
                 fetchRequest.propertiesToFetch = ["id", "progress", "isPlayed", "isFavorite", "isDownloaded"]
                 fetchRequest.resultType = .dictionaryResultType
                 
                 let results = try self.backgroundContext.fetch(fetchRequest) as! [[String: Any]]
                 var progressDict: [String: Double] = [:]
                 var progressCacheDict: [String: Double] = [:]
                 
                 for result in results {
                     if let id = result["id"] as? String,
                        let progress = result["progress"] as? Double {
                         progressDict[id] = progress
                         progressCacheDict[id] = progress
                     }
                 }
                 
                 DispatchQueue.main.async {
                     self.episodeProgress = progressDict
                     self.episodeProgressCache = progressCacheDict
                     os_log("📊 Loaded progress for %d episodes", log: self.log, type: .debug, progressDict.count)
                 }
                 
             } catch {
                 os_log("❌ Error loading episode progress: %@", log: self.log, type: .error, error.localizedDescription)
             }
         }
     }
     
     // MARK: - Enhanced Helper Methods
     
     /// Fetch podcast feeds from CloudKit with error handling
     private func fetchPodcastFeedsFromCloudKit() async throws -> [PodcastFeed] {
         return try await withCheckedThrowingContinuation { continuation in
             dataStore.fetchPodcastFeedsFromCloudKit { feeds, error in
                 if let error = error {
                     continuation.resume(throwing: error)
                 } else {
                     continuation.resume(returning: feeds ?? [])
                 }
             }
         }
     }
     
     /// Process multiple feeds in parallel for optimal performance
     private func processFeedsInParallel(_ feeds: [PodcastFeed]) async -> [PodcastFeed] {
         return await withTaskGroup(of: PodcastFeed?.self) { group in
             var processedFeeds: [PodcastFeed] = []
             
             for feed in feeds {
                 group.addTask {
                     do {
                         return try await self.processFeedForFreshInstall(feed)
                     } catch {
                         os_log("❌ Error processing feed %@: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                         return nil
                     }
                 }
             }
             
             for await processedFeed in group {
                 if let feed = processedFeed {
                     processedFeeds.append(feed)
                 }
             }
             
             return processedFeeds
         }
     }
     
     /// Store feeds efficiently to Core Data using batch operations
     private func storeFeedsEfficientlyToCoreData(_ feeds: [PodcastFeed]) async {
         await backgroundContext.perform {
             do {
                 // Clear existing data first
                 let episodeDeleteRequest = NSBatchDeleteRequest(fetchRequest: PodcastModel.fetchRequest())
                 try self.backgroundContext.execute(episodeDeleteRequest)
                 
                 let feedDeleteRequest = NSBatchDeleteRequest(fetchRequest: FeedModel.fetchRequest())
                 try self.backgroundContext.execute(feedDeleteRequest)
                 
                 // Save feeds and episodes efficiently
                 for feed in feeds {
                     let managedFeed = FeedModel(context: self.backgroundContext)
                     managedFeed.update(from: feed)
                     managedFeed.imageData = feed.imageData
                     
                     for episode in feed.episodes {
                         let managedEpisode = PodcastModel(context: self.backgroundContext)
                         managedEpisode.update(from: episode)
                         managedEpisode.feed = managedFeed
                         managedEpisode.feedId = feed.id
                     }
                 }
                 
                 try self.backgroundContext.save()
                 os_log("✅ Efficiently stored %d feeds with episodes to Core Data", log: self.log, type: .info, feeds.count)
                 
             } catch {
                 os_log("❌ Error storing feeds to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
             }
         }
     }
     
     /// Load all podcasts with episodes instantly from Core Data
     private func loadAllPodcastsWithEpisodesInstantly() async -> [PodcastFeed] {
         return await backgroundContext.perform {
             do {
                 let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                 feedRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
                 feedRequest.fetchBatchSize = 100
                 feedRequest.relationshipKeyPathsForPrefetching = ["episodes"]
                 
                 let managedFeeds = try self.backgroundContext.fetch(feedRequest)
                 var podcastFeeds: [PodcastFeed] = []
                 
                 for managedFeed in managedFeeds {
                     var feed = managedFeed.toPodcastFeed()
                     
                     // Load episodes for this feed
                     let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                     episodeRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                     episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                     episodeRequest.fetchBatchSize = 500
                     
                     let managedEpisodes = try self.backgroundContext.fetch(episodeRequest)
                     feed.episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                     
                     podcastFeeds.append(feed)
                 }
                 
                 return podcastFeeds
                 
             } catch {
                 os_log("❌ Error loading podcasts from Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                 return []
             }
         }
     }
     
     /// Get episodes from Core Data for a specific feed
     private func getEpisodesFromCoreData(for feedId: String) async -> [PodcastEpisode] {
         return await backgroundContext.perform {
             do {
                 let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                 request.predicate = NSPredicate(format: "feedId == %@", feedId)
                 request.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                 request.fetchBatchSize = 500
                 
                 let managedEpisodes = try self.backgroundContext.fetch(request)
                 return managedEpisodes.map { $0.toPodcastEpisode() }
                 
             } catch {
                 os_log("❌ Error loading episodes for feed %@: %@", log: self.log, type: .error, feedId, error.localizedDescription)
                 return []
             }
         }
     }
     
     /// Add new episodes to Core Data efficiently
     private func addNewEpisodesToCoreData(_ episodes: [PodcastEpisode], feedId: String) async {
         guard !episodes.isEmpty else { return }
         
         await backgroundContext.perform {
             do {
                 // Check for existing episodes to avoid duplicates
                 let existingRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                 existingRequest.predicate = NSPredicate(format: "feedId == %@ AND id IN %@", feedId, episodes.map { $0.id })
                 existingRequest.propertiesToFetch = ["id"]
                 
                 let existingEpisodes = try self.backgroundContext.fetch(existingRequest)
                 let existingIds = Set(existingEpisodes.compactMap { $0.id })
                 
                 let newEpisodes = episodes.filter { !existingIds.contains($0.id) }
                 
                 for episode in newEpisodes {
                     let managedEpisode = PodcastModel(context: self.backgroundContext)
                     managedEpisode.update(from: episode)
                     managedEpisode.feedId = feedId
                 }
                 
                 try self.backgroundContext.save()
                 os_log("✅ Added %d new episodes for feed %@", log: self.log, type: .info, newEpisodes.count, feedId)
                 
             } catch {
                 os_log("❌ Error adding episodes to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
             }
         }
     }
     
     // MARK: - Public API Methods
     
     // MARK: - Instant Episode Access (Zero Performance Issues)
     
     /// Get episodes for a feed instantly (no UI delays)
     func getEpisodesInstantly(for feedId: String) -> [PodcastEpisode] {
         // First try cache for immediate response
         if let cachedEpisodes = episodeCache[feedId] {
             os_log("⚡ Retrieved %d episodes from cache for feed: %@", log: log, type: .debug, cachedEpisodes.count, feedId)
             return cachedEpisodes
         }
         
         // If not in cache, get from the preloaded data
         if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
             episodeCache[feedId] = feed.episodes // Cache for next time
             os_log("⚡ Retrieved %d episodes from preloaded data for feed: %@", log: log, type: .debug, feed.episodes.count, feedId)
             return feed.episodes
         }
         
         // Fallback: load asynchronously from Core Data (this should rarely happen)
         Task(priority: .userInitiated) {
             let episodes = await self.getEpisodesFromCoreData(for: feedId)
             await MainActor.run {
                 self.episodeCache[feedId] = episodes
                 self.objectWillChange.send()
             }
        }
         
         return [] // Return empty array immediately, will be updated asynchronously
     }
     
     /// Preload episodes for a feed in background (for feeds not yet cached)
     func preloadEpisodes(for feedId: String) {
         guard episodeCache[feedId] == nil else { return }
         
         Task(priority: .background) {
             let episodes = await self.getEpisodesFromCoreData(for: feedId)
             await MainActor.run {
                 self.episodeCache[feedId] = episodes
                 os_log("📦 Preloaded %d episodes for feed: %@", log: self.log, type: .debug, episodes.count, feedId)
             }
         }
     }
     
     /// Method to call from UI to fetch podcast feeds (now optimized)
     func fetchPodcastFeeds() {
         if isFirstInstall() {
             // This will be handled by performOptimizedFreshInstallSetup in init
             return
         } else {
             // Load instantly from CoreData for existing installs
             Task(priority: .userInitiated) {
                 await loadInstantlyFromCoreData()
             }
         }
     }
    
    // Switch to a different tab with pagination
    func switchToTab(_ tab: Int, for feed: PodcastFeed) {
        currentTab = tab
        currentPage = 1
        hasMoreEpisodes = true
        isLoadingEpisodes = true
        
        // Clear current episodes to show loading state
        DispatchQueue.main.async {
            self.currentEpisodes = []
            self.objectWillChange.send()
        }
        
        // Load first page of episodes for the selected tab
        fetchEpisodesWithFilter(for: feed, page: 1, tab: tab) { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isLoadingEpisodes = false
                
                switch result {
                case .success(let episodes):
                    print("DEBUG: Loaded \(episodes.count) episodes for tab \(tab) of feed: \(feed.title)")
                    self.setCurrentEpisodes(episodes)
                    
                    // If we got less than the page size, there are no more episodes
                    if episodes.count < self.episodesPerPage {
                        self.hasMoreEpisodes = false
                    }
                    
                    self.objectWillChange.send()
                case .failure(let error):
                    print("Failed to load episodes for tab \(tab): \(error)")
                    self.error = "Failed to load episodes: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // Load initial episodes with proper pagination (100 episodes)
    func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
        print("DEBUG: loadAllEpisodesForFeed called for feed: \(feed.title)")
        
        // Reset pagination state for fresh start
        currentPage = 1
        hasMoreEpisodes = true
        isLoadingEpisodes = true
        
        // Clear current episodes to show loading state
        DispatchQueue.main.async {
            self.currentEpisodes = []
            self.objectWillChange.send()
        }
        
        // First check if we have cached episodes and can show them immediately for better UX
        if let cachedEpisodes = episodeCache[feed.id], !cachedEpisodes.isEmpty {
            print("DEBUG: Found \(cachedEpisodes.count) cached episodes, showing first \(episodesPerPage)")
            let paginatedEpisodes = Array(cachedEpisodes.prefix(episodesPerPage))
            DispatchQueue.main.async {
                self.setCurrentEpisodes(paginatedEpisodes)
                self.hasMoreEpisodes = cachedEpisodes.count > self.episodesPerPage
                self.objectWillChange.send()
            }
        }
        
        // Load first page of episodes (100 episodes) with pagination
        fetchEpisodesWithFilter(for: feed, page: 1, tab: currentTab) { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isLoadingEpisodes = false
                
                switch result {
                case .success(let episodes):
                    print("DEBUG: Loaded initial \(episodes.count) episodes for feed: \(feed.title)")
                    self.setCurrentEpisodes(episodes)
                    
                    // Update cache with fresh data
                    if self.currentTab == 0 {
                        self.episodeCache[feed.id] = self.removeDuplicatesFromEpisodes(episodes)
                    }
                    
                    // Determine if there are more episodes
                    self.hasMoreEpisodes = episodes.count >= self.episodesPerPage
                    
                    print("DEBUG: Initial load complete. Episodes: \(episodes.count), hasMoreEpisodes: \(self.hasMoreEpisodes)")
                    self.objectWillChange.send()
                    
                case .failure(let error):
                    print("❌ Failed to load episodes for feed: \(error)")
                    self.error = "Failed to load episodes: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // Throttled update method to prevent excessive UI updates
    private func sendThrottledUpdate() {
        let now = Date()
        
        // Skip update if user is scrolling or if we updated too recently
        if UserDefaults.standard.bool(forKey: "isUserScrolling") {
            return
        }
        
        if now.timeIntervalSince(lastUpdateTime) < updateThrottleInterval {
            return
        }
        
        lastUpdateTime = now
        objectWillChange.send()
    }

    
    func savePodcastEpisodesInBatches(episodes: [PodcastEpisode], for feed: PodcastFeed, batchSize: Int = 100) {
           let backgroundContext = CoreDataStack.shared.newBackgroundContext()
           let totalBatches = Int(ceil(Double(episodes.count) / Double(batchSize)))
           
           backgroundContext.performAndWait {
               do {
                   // Create feed in background context
                   let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                   feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                   
                   let feedResults = try backgroundContext.fetch(feedFetchRequest)
                   let managedFeed = feedResults.first ?? FeedModel(context: backgroundContext)
                   managedFeed.update(from: feed)
                   
                   // Process episodes in batches
                   for batchIndex in 0..<totalBatches {
                       let start = batchIndex * batchSize
                       let end = min(start + batchSize, episodes.count)
                       let currentBatch = Array(episodes[start..<end])
                       
                       autoreleasepool {
                           self.processBatch(currentBatch, in: backgroundContext, for: managedFeed)
                       }
                   }
                   
                   // Final save of the background context
                   try backgroundContext.save()
                   
                   // Notify main context of changes
                   DispatchQueue.main.async {
                       CoreDataStack.shared.context.perform {
                           do {
                               try CoreDataStack.shared.context.save()
                               self.objectWillChange.send()
                           } catch {
                               print("Error saving main context: \(error)")
                           }
                       }
                   }
               } catch {
                   print("Error in batch save operation: \(error)")
               }
           }
       }
    
    private func processBatch(_ episodes: [PodcastEpisode], in context: NSManagedObjectContext, for feed: FeedModel) {
            // First, ensure we have the feed in the correct context
            let feedID = feed.id ?? ""
            let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            feedFetchRequest.predicate = NSPredicate(format: "id == %@", feedID)
            
            do {
                // Get or create feed in the current context
                let feedResults = try context.fetch(feedFetchRequest)
                let managedFeed = feedResults.first ?? FeedModel(context: context)
                managedFeed.update(from: feed.toPodcastFeed())  // Convert to PodcastFeed and back to ensure clean data
                
                // Now process episodes in the same context
                for episode in episodes {
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                    
                    let results = try context.fetch(fetchRequest)
                    let managedEpisode = results.first ?? PodcastModel(context: context)
                    managedEpisode.update(from: episode)
                    managedEpisode.feed = managedFeed  // Set relationship in the same context
                    managedEpisode.feedId = feedID     // Ensure feedId is set
                }
                
                // Save the context
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                print("Error processing batch: \(error)")
            }
        }
    
    func fetchEpisodesInBatches(for feed: PodcastFeed, page: Int, pageSize: Int = 50, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                fetchRequest.fetchLimit = pageSize
                fetchRequest.fetchOffset = (page - 1) * pageSize
                
                // Enable batch faulting for better performance
                fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
                
                do {
                    let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                    
                    // Convert to PodcastEpisode models
                    let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                        var episode = managedEpisode.toPodcastEpisode()
                        
                        // Preserve existing state
                        episode.state.isPlayed = managedEpisode.isPlayed
                        episode.state.progress = managedEpisode.progress
                        episode.state.isFavorite = managedEpisode.isFavorite
                        episode.state.isDownloaded = managedEpisode.isDownloaded
                        
                        return episode
                    }
                    
                    // Check if there are more episodes available
                    let countRequest = NSFetchRequest<NSNumber>(entityName: "PodcastModel")
                    countRequest.predicate = fetchRequest.predicate
                    countRequest.resultType = .countResultType
                    let totalCount = try backgroundContext.count(for: countRequest)
                    let hasMore = totalCount > (page * pageSize)
                    
                    DispatchQueue.main.async {
                        self.hasMoreEpisodes = hasMore
                        completion(.success(episodes))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    
    func clearPodcastCache(for feedId: String) {
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                
                let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                batchDeleteRequest.resultType = .resultTypeObjectIDs
                
                do {
                    let result = try backgroundContext.execute(batchDeleteRequest) as? NSBatchDeleteResult
                    if let objectIDs = result?.result as? [NSManagedObjectID] {
                        // Sync changes with main context
                        let changes = [NSDeletedObjectsKey: objectIDs]
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [CoreDataStack.shared.context])
                    }
                } catch {
                    print("Error clearing podcast cache: \(error)")
                }
            }
        }
    

    
    private func fetchInitialEpisodesFromRSS(for feed: PodcastFeed) {
            print("DEBUG: fetchInitialEpisodesFromRSS called for feed: \(feed.title)")
            fetchRSSFeed(for: feed) { result in
                switch result {
                case .success(let updatedFeed):
                    print("DEBUG: RSS fetch successful for feed: \(feed.title), found \(updatedFeed.episodes.count) episodes")
                    // Save episodes to Core Data in batches
                    self.savePodcastEpisodesInBatches(episodes: updatedFeed.episodes, for: updatedFeed)
                    
                    DispatchQueue.main.async {
                        // Update the cache and current episodes
                        let uniqueEpisodes = self.removeDuplicatesFromEpisodes(updatedFeed.episodes)
                        self.episodeCache[feed.id] = uniqueEpisodes
                        self.setCurrentEpisodes(updatedFeed.episodes)
                        self.isLoadingEpisodes = false
                        print("DEBUG: Updated currentEpisodes with \(uniqueEpisodes.count) episodes for feed: \(feed.title)")
                        self.objectWillChange.send()
                    }
                    
                case .failure(let error):
                    print("DEBUG: Failed to fetch episodes from RSS for feed: \(feed.title): \(error)")
                    DispatchQueue.main.async {
                        self.isLoadingEpisodes = false
                        self.error = "Failed to load episodes: \(error.localizedDescription)"
                    }
                }
            }
        }
    
    func loadInitialEpisodes(for feed: PodcastFeed) {
           currentPage = 1
           hasMoreEpisodes = true
           currentEpisodes.removeAll()
           isLoadingEpisodes = true
           
           fetchEpisodesWithFilter(for: feed, page: 1, tab: currentTab) { [weak self] result in
               guard let self = self else { return }
               
               DispatchQueue.main.async {
                   self.isLoadingEpisodes = false
                   
                   switch result {
                   case .success(let episodes):
                       self.setCurrentEpisodes(episodes)
                                                if self.currentTab == 0 {
                             self.episodeCache[feed.id] = self.removeDuplicatesFromEpisodes(episodes)
                       }
                       self.objectWillChange.send()
                       
                   case .failure(let error):
                       print("Failed to load initial episodes: \(error)")
                       self.error = "Failed to load episodes: \(error.localizedDescription)"
                   }
               }
           }
       }
    
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        DispatchQueue.main.async {
            self.lastPlayedEpisodes[episode.feedId] = episode.id
            self.saveLastPlayedEpisodes() // Save to UserDefaults
        }
    }
    
    // Add new method to save lastPlayedEpisodes to UserDefaults
    private func saveLastPlayedEpisodes() {
        UserDefaults.standard.set(lastPlayedEpisodes, forKey: "LastPlayedEpisodes")
    }
    
    // Add new method to load lastPlayedEpisodes from UserDefaults
    private func loadLastPlayedEpisodes() {
        if let savedLastPlayed = UserDefaults.standard.object(forKey: "LastPlayedEpisodes") as? [String: String] {
            lastPlayedEpisodes = savedLastPlayed
        }
        
        // Load sort direction
        isAscendingSort = UserDefaults.standard.bool(forKey: "PodcastSortAscending")
    }
    
    // Save sort direction to UserDefaults
    private func saveSortDirection() {
        UserDefaults.standard.set(isAscendingSort, forKey: "PodcastSortAscending")
    }
    
    // Force clear any remaining progress data that might have been missed
    private func forceCleanRemainingProgressData() {
        let userDefaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? "com.streamradios.app"
        
        // Get ALL UserDefaults keys for this app
        if let allAppKeys = userDefaults.persistentDomain(forName: domain)?.keys {
            var additionalKeysRemoved = 0
            
            for key in allAppKeys {
                // Remove any key that might contain episode/podcast progress data
                let lowercaseKey = key.lowercased()
                if lowercaseKey.contains("progress") || 
                   lowercaseKey.contains("episode") || 
                   lowercaseKey.contains("podcast") ||
                   lowercaseKey.contains("playback") ||
                   lowercaseKey.contains("duration") ||
                   lowercaseKey.contains("currenttime") {
                    print("DEBUG: Force removing remaining key: \(key)")
                    userDefaults.removeObject(forKey: key)
                    additionalKeysRemoved += 1
                }
            }
            
            print("DEBUG: Force removed \(additionalKeysRemoved) additional keys")
        }
        
        // Synchronize to ensure all changes are saved
        userDefaults.synchronize()
    }
    
    // Add missing fetchEpisodes method
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        fetchEpisodesWithFilter(for: feed, page: 1, tab: 0) { result in
            switch result {
            case .success(let episodes):
                completion(.success(episodes))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // Add missing updateEpisodeDuration method  
    func updateEpisodeDuration(_ episode: PodcastEpisode, newDuration: TimeInterval) {
        var updatedEpisode = episode
        updatedEpisode.duration = newDuration
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        objectWillChange.send()
    }
    
    // Add missing fetchRSSFeed method
    private func fetchRSSFeed(for feed: PodcastFeed, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        os_log("Starting RSS feed fetch for feed: %@", log: log, type: .info, feed.title)
        guard let url = URL(string: feed.url) else {
            os_log("Invalid URL for feed: %@", log: log, type: .error, feed.url)
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                os_log("Error fetching RSS feed for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                os_log("No data received for RSS feed: %@", log: self.log, type: .error, feed.title)
                completion(.failure(NSError(domain: "No data received", code: 0, userInfo: nil)))
                return
            }
            
            os_log("RSS feed data received for feed: %@, data size: %d bytes", log: self.log, type: .info, feed.title, data.count)
            
            let rssParser = RSSParser(data: data, feedId: feed.id)
            rssParser.parse()
            
            os_log("RSS parsing completed for feed: %@. Found %d episodes.", log: self.log, type: .info, feed.title, rssParser.episodes.count)
            
            var updatedFeed = feed
            updatedFeed.title = feed.title
            updatedFeed.descriptionText = rssParser.podcastDescription
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            updatedFeed.episodes = rssParser.episodes
            
            if let artworkUrl = updatedFeed.artworkUrl, let url = URL(string: artworkUrl) {
                self.fetchAndStoreImage(from: url) { imageData in
                    updatedFeed.imageData = imageData
                    os_log("Artwork fetched for feed: %@, image size: %d bytes", log: self.log, type: .info, feed.title, imageData?.count ?? 0)
                    DispatchQueue.main.async {
                        completion(.success(updatedFeed))
                    }
                }
            } else {
                os_log("No artwork URL found for feed: %@", log: self.log, type: .info, feed.title)
                DispatchQueue.main.async {
                    completion(.success(updatedFeed))
                }
            }
        }.resume()
    }
    
    private func fetchAndStoreImage(from url: URL, completion: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                os_log("Error fetching image: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                completion(nil)
                return
            }
            
            completion(data)
        }.resume()
    }
    

    
    // Add missing clearAllPodcastData method
    func clearAllPodcastData(completion: @escaping (Bool) -> Void) {
        // Clear in-memory data
        podcastFeeds.removeAll()
        allEpisodes.removeAll()
        currentEpisodes.removeAll()
        favoriteEpisodes.removeAll()
        downloadedEpisodes.removeAll()
        episodeCache.removeAll()
        episodeProgress.removeAll()
        episodeProgressCache.removeAll() // Clear non-published cache too
        lastPlayedEpisodes.removeAll()
        
        // Clear Core Data
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        backgroundContext.perform {
            // Delete all podcasts
            let podcastRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
            let deletePodcastRequest = NSBatchDeleteRequest(fetchRequest: podcastRequest)
            
            // Delete all feeds
            let feedRequest: NSFetchRequest<NSFetchRequestResult> = FeedModel.fetchRequest()
            let deleteFeedRequest = NSBatchDeleteRequest(fetchRequest: feedRequest)
            
            do {
                try backgroundContext.execute(deletePodcastRequest)
                try backgroundContext.execute(deleteFeedRequest)
                try backgroundContext.save()
                
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                    completion(true)
                }
            } catch {
                print("Failed to clear podcast data: \(error)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        
        // Clear UserDefaults
        forceCleanRemainingProgressData()
    }
    
    // Add missing deleteDownloadedEpisode method
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) {
        // Update episode state
        var updatedEpisode = episode
        updatedEpisode.state.isDownloaded = false
        
        // Update in all collections
        updateEpisodeInLists(updatedEpisode)
        
        // Save to Core Data
        saveEpisodeToCoreData(updatedEpisode)
        
        // Update downloaded episodes list
        downloadedEpisodes.removeAll { $0.id == episode.id }
        
        // Notify UI
        objectWillChange.send()
    }
    

    
    func refreshAllFeeds() {
        isLoadingEpisodes = true
        let dispatchGroup = DispatchGroup()
        
        for feed in podcastFeeds {
            dispatchGroup.enter()
            fetchRSSFeed(for: feed) { result in
                switch result {
                case .success(let updatedFeed):
                    Task.detached(priority: .utility) {
                        await self.updateFeedInCoreData(updatedFeed)
                        DispatchQueue.main.async {
                            dispatchGroup.leave()
                        }
                    }
                case .failure(let error):
                    print("Failed to refresh feed \(feed.title): \(error)")
                    dispatchGroup.leave()
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            self.isLoadingEpisodes = false
            self.objectWillChange.send()
        }
    }
    
    func loadFeedOrder() {
        if let savedOrder = UserDefaults.standard.array(forKey: "savedFeedOrder") as? [String] {
            // Update podcastFeedOrder with saved order
            podcastFeedOrder = savedOrder.filter { feedId in
                podcastFeeds.contains { $0.id == feedId }
            }
            
            // Add any new feeds not in saved order
            let existingIds = Set(podcastFeedOrder)
            let newFeedIds = podcastFeeds.compactMap { feed in
                existingIds.contains(feed.id) ? nil : feed.id
            }
            podcastFeedOrder.append(contentsOf: newFeedIds)
            
            // Sort podcastFeeds to match the order
            podcastFeeds.sort { feed1, feed2 in
                let index1 = podcastFeedOrder.firstIndex(of: feed1.id) ?? Int.max
                let index2 = podcastFeedOrder.firstIndex(of: feed2.id) ?? Int.max
                return index1 < index2
            }
        } else {
            // No saved order, use current feed order
            podcastFeedOrder = podcastFeeds.map { $0.id }
        }
        objectWillChange.send()
    }
    
    func sortFeedsAlphabetically() {
        isAscendingSort.toggle()
        if isAscendingSort {
            podcastFeeds.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } else {
            podcastFeeds.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
        podcastFeedOrder = podcastFeeds.map { $0.id } // Update order array
        saveFeedOrder()
        objectWillChange.send()
    }
    
    func getLastPlayedOrLatestEpisode(for feed: PodcastFeed) -> PodcastEpisode? {
            let feedEpisodes = allEpisodes.filter { $0.feedId == feed.id }
            
            // Check for last played episode
            if let lastPlayedEpisodeId = lastPlayedEpisodes[feed.id],
               let lastPlayedEpisode = feedEpisodes.first(where: { $0.id == lastPlayedEpisodeId }) {
                return lastPlayedEpisode
            }
            
            // Check for episodes in progress
            let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
            
            if let firstInProgressEpisode = episodesInProgress.first {
                return firstInProgressEpisode
            }
            
            // If no episodes in progress, return the latest episode
            return feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first
        }

    func showNoEpisodesInProgressAlert(for feed: PodcastFeed) {
            DispatchQueue.main.async {
                self.noEpisodesAlertMessage = "No episodes in progress for \(feed.title). Playing the latest episode."
                self.showNoEpisodesAlert = true
            }
        }
    
   
   

    
    func fetchAllEpisodes(for feed: PodcastFeed) {
        // Prevent multiple simultaneous fetches for the same feed
        guard !isLoadingEpisodes else { return }
        
        // First, show cached episodes immediately if available (but respect pagination)
        if let cachedEpisodes = episodeCache[feed.id], !cachedEpisodes.isEmpty {
            DispatchQueue.main.async {
                // Only show the first page of cached episodes to respect pagination
                let paginatedEpisodes = Array(cachedEpisodes.prefix(self.episodesPerPage))
                self.setCurrentEpisodes(paginatedEpisodes)
                // DON'T call updateFilteredEpisodes here as it would load all episodes from memory
                self.objectWillChange.send()
            }
        }
        
        // Set loading state
        DispatchQueue.main.async {
            self.isLoadingEpisodes = true
        }
        
        // Perform RSS fetch asynchronously on background queue
        Task.detached(priority: .userInitiated) {
            await self.fetchRSSFeedAsync(for: feed)
        }
    }
    
    @MainActor
    private func fetchRSSFeedAsync(for feed: PodcastFeed) async {
        defer {
            isLoadingEpisodes = false
        }
        
        do {
            let updatedFeed = try await performRSSFetch(for: feed)
            
            // Update the feed with new episodes
            updateFeed(updatedFeed)
            // DON'T call updateFilteredEpisodes here as it would load all episodes from memory
            // The pagination is handled by loadAllEpisodesForFeed and loadMoreEpisodes
            
            // Notify UI update
            objectWillChange.send()
            
        } catch {
            print("Failed to fetch episodes: \(error)")
            // Handle error appropriately - don't block UI
        }
    }
    
    private func performRSSFetch(for feed: PodcastFeed) async throws -> PodcastFeed {
        guard let url = URL(string: feed.url) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Parse RSS on background thread
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rssParser = RSSParser(data: data, feedId: feed.id)
                rssParser.parse()
                
                var updatedFeed = feed
                updatedFeed.title = feed.title
                updatedFeed.descriptionText = rssParser.podcastDescription
                updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
                updatedFeed.episodes = rssParser.episodes
                
                // Fetch artwork asynchronously if needed
                if let artworkUrl = updatedFeed.artworkUrl, let artworkURL = URL(string: artworkUrl) {
                    Task {
                        do {
                            let (imageData, _) = try await URLSession.shared.data(from: artworkURL)
                            updatedFeed.imageData = imageData
                        } catch {
                            print("Failed to fetch artwork: \(error)")
                        }
                        continuation.resume(returning: updatedFeed)
                    }
                } else {
                    continuation.resume(returning: updatedFeed)
                }
            }
        }
    }
    
    private func updateFeed(_ updatedFeed: PodcastFeed) {
        // Perform Core Data updates on background queue to avoid UI blocking
        Task.detached(priority: .utility) {
            await self.updateFeedInBackground(updatedFeed)
        }
    }
    
    @MainActor
    private func updateFeedInBackground(_ updatedFeed: PodcastFeed) async {
        // Update the in-memory array of podcast feeds
        if let index = podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
            podcastFeeds[index] = updatedFeed
        } else {
            podcastFeeds.append(updatedFeed)
        }
        
        // Perform Core Data operations asynchronously 
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.updateFeedInCoreData(updatedFeed)
            }
            
            group.addTask {
                await self.processEpisodesInBatches(updatedFeed)
            }
        }
        
        // Update cache with the latest episodes for this feed
        let feedEpisodes = allEpisodes.filter { $0.feedId == updatedFeed.id }
        episodeCache[updatedFeed.id] = removeDuplicatesFromEpisodes(feedEpisodes)
        
        // Update currentEpisodes if necessary (but respect pagination)
        if currentEpisodes.first?.feedId == updatedFeed.id {
            // DON'T call updateFilteredEpisodes here as it would load all episodes from memory
            // The current episodes are already properly paginated
            // Just update the UI to reflect any changes
        }
        
        // Notify UI update
        objectWillChange.send()
    }
    
    private func updateFeedInCoreData(_ updatedFeed: PodcastFeed) async {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", updatedFeed.id)
            
            do {
                let results = try backgroundContext.fetch(fetchRequest)
                if let managedFeed = results.first {
                    managedFeed.update(from: updatedFeed)
                    managedFeed.imageData = updatedFeed.imageData
                } else {
                    // If the feed doesn't exist in Core Data, create a new one
                    let newManagedFeed = FeedModel(context: backgroundContext)
                    newManagedFeed.update(from: updatedFeed)
                    newManagedFeed.imageData = updatedFeed.imageData
                }
                try backgroundContext.save()
            } catch {
                print("Failed to update/create feed in Core Data: \(error)")
            }
        }
    }
    
    private func processEpisodesInBatches(_ updatedFeed: PodcastFeed) async {
        let batchSize = 50
        let episodes = updatedFeed.episodes
        let totalBatches = Int(ceil(Double(episodes.count) / Double(batchSize)))
        
        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, episodes.count)
            let batch = Array(episodes[startIndex..<endIndex])
            
            await self.processBatch(batch, for: updatedFeed)
            
            // Add small delay between batches to prevent UI blocking
            try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        }
        
        // Update arrays after all batches are processed
        await MainActor.run {
            // Sort allEpisodes to maintain consistent date ordering (newest first)
            allEpisodes.sort { $0.publicationDate > $1.publicationDate }
            
            // Update the favorite and downloaded episode arrays (also sorted)
            favoriteEpisodes = allEpisodes.filter { $0.state.isFavorite }
            downloadedEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        }
    }
    
    private func processBatch(_ episodes: [PodcastEpisode], for feed: PodcastFeed) async {
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        // Process episodes and prepare updates on background thread
        let processedEpisodes: [PodcastEpisode] = await backgroundContext.perform {
            var resultEpisodes: [PodcastEpisode] = []
            
            for newEpisode in episodes {
                var episodeToAdd = newEpisode
                
                // Check Core Data for existing state
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", newEpisode.id)
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    if let managedEpisode = results.first {
                        // Episode exists in Core Data, preserve its state
                        episodeToAdd.state.isPlayed = managedEpisode.isPlayed
                        episodeToAdd.state.isFavorite = managedEpisode.isFavorite
                        episodeToAdd.state.progress = managedEpisode.progress
                        episodeToAdd.state.isDownloaded = managedEpisode.isDownloaded
                        
                        // Update existing episode in Core Data
                        managedEpisode.update(from: episodeToAdd)
                    } else {
                        // Truly new episode - save to Core Data
                        let managedEpisode = PodcastModel(context: backgroundContext)
                        managedEpisode.update(from: episodeToAdd)
                    }
                } catch {
                    // Fallback: treat as new episode
                    let managedEpisode = PodcastModel(context: backgroundContext)
                    managedEpisode.update(from: episodeToAdd)
                }
                
                resultEpisodes.append(episodeToAdd)
            }
            
            // Save batch to Core Data
            do {
                try backgroundContext.save()
            } catch {
                print("Error saving batch to Core Data: \(error)")
            }
            
            return resultEpisodes
        }
        
        // Update published properties on main thread
        await MainActor.run {
            for processedEpisode in processedEpisodes {
                if let index = self.allEpisodes.firstIndex(where: { $0.id == processedEpisode.id }) {
                    // Update existing episode, preserving any in-memory state changes
                    var updatedEpisode = processedEpisode
                    let existingEpisode = self.allEpisodes[index]
                    
                    // Preserve any runtime state that might be newer than Core Data
                    if existingEpisode.state.progress > processedEpisode.state.progress {
                        updatedEpisode.state.progress = existingEpisode.state.progress
                    }
                    
                    self.allEpisodes[index] = updatedEpisode
                } else {
                    // Add new episode
                    self.allEpisodes.append(processedEpisode)
                }
            }
            
            // Update derived collections
            self.favoriteEpisodes = self.allEpisodes.filter { $0.state.isFavorite }
            self.downloadedEpisodes = self.allEpisodes.filter { $0.state.isDownloaded }
            
            // Trigger UI update
            self.objectWillChange.send()
        }
    }
    

    
    // Add synchronous Core Data saving method for immediate episode persistence
    private func saveEpisodeToCoreDataSynchronously(_ episode: PodcastEpisode) {
        guard !episode.id.isEmpty, !episode.title.isEmpty, !episode.feedId.isEmpty else {
            print("Invalid episode data, not saving to Core Data")
            return
        }
        
        let context = self.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            let managedEpisode: PodcastModel
            
            if let existingEpisode = results.first {
                managedEpisode = existingEpisode
            } else {
                managedEpisode = PodcastModel(context: context)
            }
            
            updateManagedEpisode(managedEpisode, from: episode)
            
            // Save the context synchronously
            try context.save()
            print("DEBUG: Successfully saved episode to Core Data: \(episode.title)")
            
        } catch {
            print("DEBUG: Failed to save episode to Core Data: \(error)")
        }
    }
    

    
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
        // Update both caches immediately
        episodeProgress[episode.id] = progress
        episodeProgressCache[episode.id] = progress
        
        // Ensure Core Data operations happen on the main thread
        if Thread.isMainThread {
            updateProgressInCoreData(episode, progress: progress)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateProgressInCoreData(episode, progress: progress)
            }
        }
    }
    
    private func updateProgressInCoreData(_ episode: PodcastEpisode, progress: Double) {
        // Perform Core Data operations on a background queue to avoid main thread I/O
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            let context = CoreDataStack.shared.context
            context.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                
                do {
                    let results = try context.fetch(fetchRequest)
                    if let managedEpisode = results.first {
                        managedEpisode.progress = progress
                        
                        // Update completion status
                        if progress >= 0.99 {
                            managedEpisode.isPlayed = true
                        } else if !episode.state.isPlayed {
                            // Only update isPlayed to false if it wasn't already marked as finished
                            managedEpisode.isPlayed = false
                        }
                        
                        try context.save()
                        
                        // Update the in-memory episode on main thread
                        DispatchQueue.main.async {
                            var updatedEpisode = episode
                            updatedEpisode.state.progress = progress
                            
                            // Preserve existing "finished" status - only mark as finished if progress >= 0.99
                            // but don't unmark episodes that were already marked as finished
                            if progress >= 0.99 {
                                updatedEpisode.state.isPlayed = true
                                
                                // Notify CarPlay immediately of episode completion
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("EpisodeCompleted"),
                                    object: nil,
                                    userInfo: [
                                        "episodeId": episode.id,
                                        "isCompleted": true,
                                        "progress": progress
                                    ]
                                )
                            } else if !episode.state.isPlayed {
                                // Only update isPlayed to false if it wasn't already marked as finished
                                updatedEpisode.state.isPlayed = false
                            }
                            
                            self.updateEpisodeInLists(updatedEpisode)
                            self.objectWillChange.send()
                        }
                    } else {
                        print("Episode not found in CoreData")
                    }
                } catch {
                    print("Failed to update episode progress: \(error)")
                }
            }
        }
    }
    
    func markEpisodeAsCompleted(_ episode: PodcastEpisode) {
        var updatedEpisode = episode
        updatedEpisode.state.isPlayed = true
        updatedEpisode.state.progress = 1.0
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        objectWillChange.send()
        
        // Immediately notify CarPlay of episode completion for real-time updates
        NotificationCenter.default.post(
            name: NSNotification.Name("EpisodeCompleted"),
            object: nil,
            userInfo: [
                "episodeId": episode.id,
                "isCompleted": true,
                "progress": 1.0
            ]
        )
        
        os_log("Episode marked as completed and CarPlay notified: %@", log: log, type: .info, episode.title)
    }
    
    func updateEpisode(_ updatedEpisode: PodcastEpisode) {
        if let index = allEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            allEpisodes[index] = updatedEpisode
        }
        if let index = currentEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            currentEpisodes[index] = updatedEpisode
        }
        saveEpisodeToCoreData(updatedEpisode)
        
        objectWillChange.send()
        
        // Update favorite episodes with consistent sorting
        if updatedEpisode.state.isFavorite {
            if !favoriteEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                favoriteEpisodes.append(updatedEpisode)
                favoriteEpisodes.sort { $0.publicationDate > $1.publicationDate }
            } else if let index = favoriteEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
                favoriteEpisodes[index] = updatedEpisode
            }
        } else {
            favoriteEpisodes.removeAll { $0.id == updatedEpisode.id }
        }
        
        // Update downloaded episodes with consistent sorting
        if updatedEpisode.state.isDownloaded {
            if !downloadedEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                downloadedEpisodes.append(updatedEpisode)
                downloadedEpisodes.sort { $0.publicationDate > $1.publicationDate }
            } else if let index = downloadedEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
                downloadedEpisodes[index] = updatedEpisode
            }
        } else {
            downloadedEpisodes.removeAll { $0.id == updatedEpisode.id }
        }
        
        // Update both progress caches
        episodeProgress[updatedEpisode.id] = updatedEpisode.state.progress
        episodeProgressCache[updatedEpisode.id] = updatedEpisode.state.progress
        
        // Trigger a throttled UI update
        DispatchQueue.main.async {
            self.sendThrottledUpdate()
        }
    }
    
    private func saveEpisodeCompletedState(_ episode: PodcastEpisode) {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.progress = 1.0  // Set progress to 100%
                try context.save()
            }
        } catch {
            print("Failed to save episode completed state: \(error)")
        }
    }
    

    
    
    func toggleFavorite(for episode: PodcastEpisode) {
            // First, update the UI immediately for instant feedback
            var updatedEpisode = episode
            updatedEpisode.state.isFavorite.toggle()
            
            print("DEBUG: Toggling favorite for episode: \(episode.title) to \(updatedEpisode.state.isFavorite)")
            
            // Update in-memory arrays immediately
            updateEpisodeInLists(updatedEpisode)
            
            // Update cache immediately
            updateEpisodeInCache(updatedEpisode)
            
                    // Trigger throttled UI update
        DispatchQueue.main.async {
            self.sendThrottledUpdate()
            // Update filtered episodes for immediate tab filtering
            print("DEBUG: About to call updateFilteredEpisodes from toggleFavorite with currentTab: \(self.currentTab)")
            self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
        }
            
            // Then save to Core Data in the background
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
            
            context.perform {
                do {
                    let results = try context.fetch(fetchRequest)
                    let managedEpisode: PodcastModel
                    
                    if let existingEpisode = results.first {
                        managedEpisode = existingEpisode
                    } else {
                        managedEpisode = PodcastModel(context: context)
                        managedEpisode.update(from: episode)
                    }
                    
                    // Set the favorite status to match our UI update
                    managedEpisode.isFavorite = updatedEpisode.state.isFavorite
                    try context.save()
                    
                    print("DEBUG: Successfully saved favorite status to Core Data for episode: \(episode.title)")
                    
                } catch {
                    print("Failed to save favorite status to Core Data: \(error)")
                    
                    // If Core Data save fails, revert the UI change
                    DispatchQueue.main.async {
                        var revertedEpisode = updatedEpisode
                        revertedEpisode.state.isFavorite = episode.state.isFavorite
                        self.updateEpisodeInLists(revertedEpisode)
                        self.updateEpisodeInCache(revertedEpisode)
                        self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
                        self.objectWillChange.send()
                    }
                }
            }
        }
    
    func updateEpisodeDownloadStatus(_ episode: PodcastEpisode, isDownloaded: Bool) {
            // First, update the UI immediately
            var updatedEpisode = episode
            updatedEpisode.state.isDownloaded = isDownloaded
            
            // Update in-memory arrays immediately
            updateEpisodeInLists(updatedEpisode)
            
            // Update cache immediately
            updateEpisodeInCache(updatedEpisode)
            
            // Trigger throttled UI update
            DispatchQueue.main.async {
                self.sendThrottledUpdate()
                self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
            }
            
            // Then save to Core Data
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
            
            do {
                let results = try context.fetch(fetchRequest)
                if let managedEpisode = results.first {
                    managedEpisode.isDownloaded = isDownloaded
                    try context.save()
                    print("DEBUG: Successfully saved download status to Core Data for episode: \(episode.title)")
                }
            } catch {
                print("Failed to update episode download status: \(error)")
                
                // If Core Data save fails, revert the UI change
                DispatchQueue.main.async {
                    var revertedEpisode = updatedEpisode
                    revertedEpisode.state.isDownloaded = episode.state.isDownloaded
                    self.updateEpisodeInLists(revertedEpisode)
                    self.updateEpisodeInCache(revertedEpisode)
                    self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
                    self.objectWillChange.send()
                }
            }
        }
    
    private func saveEpisodeToCoreData(_ episode: PodcastEpisode) {
        guard !episode.id.isEmpty, !episode.title.isEmpty, !episode.feedId.isEmpty else {
            print("Invalid episode data, not saving to Core Data")
            return
        }
        
        // Perform Core Data operations on a background queue
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            let context = self.context
            context.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                
                do {
                    let results = try context.fetch(fetchRequest)
                    let managedEpisode: PodcastModel
                    
                    if let existingEpisode = results.first {
                        managedEpisode = existingEpisode
                    } else {
                        managedEpisode = PodcastModel(context: context)
                    }
                    
                    self.updateManagedEpisode(managedEpisode, from: episode)
                    
                    // Save the context
                    try context.save()
                    print("Successfully saved episode state to Core Data: \(episode.title)")
                    
                } catch {
                    print("Failed to save episode to Core Data: \(error)")
                }
            }
        }
    }
    
    private func updateManagedEpisode(_ managedEpisode: PodcastModel, from episode: PodcastEpisode) {
        managedEpisode.id = episode.id
        managedEpisode.title = episode.title
        managedEpisode.descriptionText = episode.descriptionText
        managedEpisode.audioUrl = episode.audioUrl
        managedEpisode.publicationDate = episode.publicationDate
        managedEpisode.duration = episode.duration
        managedEpisode.isPlayed = episode.state.isPlayed
        managedEpisode.isFavorite = episode.state.isFavorite
        managedEpisode.progress = episode.state.progress
        managedEpisode.isDownloaded = episode.state.isDownloaded
        managedEpisode.feedId = episode.feedId
        managedEpisode.localFilePath = episode.localFilePath
        managedEpisode.fileSize = episode.fileSize ?? 0
        
        // Update the feed relationship
        let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedFetchRequest.predicate = NSPredicate(format: "id == %@", episode.feedId)
        
        do {
            let feeds = try managedEpisode.managedObjectContext?.fetch(feedFetchRequest)
            if let feed = feeds?.first {
                managedEpisode.feed = feed
            }
        } catch {
            print("Failed to fetch feed for episode: \(error)")
        }
    }

    
    func getProgress(for episode: PodcastEpisode) -> Double {
        // Skip expensive Core Data queries during scrolling for better performance
        if UserDefaults.standard.bool(forKey: "isUserScrolling") {
            // Return cached value or episode state progress during scrolling
            return episodeProgressCache[episode.id] ?? episode.state.progress
        }
        
        // First check the non-published cache for better performance
        if let cachedProgress = episodeProgressCache[episode.id] {
            return cachedProgress
        }
        
        // Check the published cache as well
        if let cachedProgress = episodeProgress[episode.id] {
            episodeProgressCache[episode.id] = cachedProgress
            return cachedProgress
        }
        
        // Use episode state progress as fallback to avoid expensive Core Data queries
        let progress = episode.state.progress
        
        // Cache the result
        episodeProgressCache[episode.id] = progress
        
        // Defer updating the published property to avoid publishing during view updates
        DispatchQueue.main.async { [weak self] in
            self?.episodeProgress[episode.id] = progress
        }
        
        return progress
    }
    
    private func getProgressFromCoreData(_ episode: PodcastEpisode) -> Double {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                return managedEpisode.progress
            }
        } catch {
            print("Failed to fetch episode progress: \(error)")
        }
        
        return 0.0
    }
    
    private func updateEpisodeInLists(_ episode: PodcastEpisode) {
            // Skip updates if user is scrolling to prevent CPU spikes
            if UserDefaults.standard.bool(forKey: "isUserScrolling") {
                return
            }
            
            print("DEBUG: Updating episode in lists: \(episode.title), isFavorite: \(episode.state.isFavorite)")
            
            // Update in allEpisodes
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
                print("DEBUG: Updated episode in allEpisodes at index \(index)")
            }
            
            // Update in currentEpisodes
            if let index = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[index] = episode
                print("DEBUG: Updated episode in currentEpisodes at index \(index)")
            }
            
            // Update favoriteEpisodes with consistent sorting
            if episode.state.isFavorite {
                if !favoriteEpisodes.contains(where: { $0.id == episode.id }) {
                    favoriteEpisodes.append(episode)
                    favoriteEpisodes.sort { $0.publicationDate > $1.publicationDate }
                    print("DEBUG: Added episode to favoriteEpisodes and sorted")
                } else if let index = favoriteEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    favoriteEpisodes[index] = episode
                    print("DEBUG: Updated episode in favoriteEpisodes at index \(index)")
                }
            } else {
                let removedCount = favoriteEpisodes.count
                favoriteEpisodes.removeAll { $0.id == episode.id }
                if favoriteEpisodes.count < removedCount {
                    print("DEBUG: Removed episode from favoriteEpisodes")
                }
            }
            
            // Update downloadedEpisodes with consistent sorting
            if episode.state.isDownloaded {
                if !downloadedEpisodes.contains(where: { $0.id == episode.id }) {
                    downloadedEpisodes.append(episode)
                    downloadedEpisodes.sort { $0.publicationDate > $1.publicationDate }
                    print("DEBUG: Added episode to downloadedEpisodes and sorted")
                } else if let index = downloadedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    downloadedEpisodes[index] = episode
                    print("DEBUG: Updated episode in downloadedEpisodes at index \(index)")
                }
            } else {
                let removedCount = downloadedEpisodes.count
                downloadedEpisodes.removeAll { $0.id == episode.id }
                if downloadedEpisodes.count < removedCount {
                    print("DEBUG: Removed episode from downloadedEpisodes")
                }
            }
            
            print("DEBUG: favoriteEpisodes count: \(favoriteEpisodes.count), downloadedEpisodes count: \(downloadedEpisodes.count)")
            
            // Don't call updateFilteredEpisodes here to avoid redundant calls
            // The caller should handle this
        }
    
    
    func downloadEpisode(_ episode: PodcastEpisode, completion: @escaping (Result<PodcastEpisode, Error>) -> Void) {
            guard let url = URL(string: episode.audioUrl) else {
                completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
                return
            }
            
            let task = URLSession.shared.downloadTask(with: url) { [weak self] localUrl, response, error in
                guard let self = self else { return }
                
                if let error = error {
                    DispatchQueue.main.async {
                        self.downloadProgress.removeValue(forKey: episode.id)
                        completion(.failure(error))
                    }
                    return
                }
                
                guard let localUrl = localUrl else {
                    DispatchQueue.main.async {
                        self.downloadProgress.removeValue(forKey: episode.id)
                        completion(.failure(NSError(domain: "No data received", code: 0, userInfo: nil)))
                    }
                    return
                }
                
                do {
                    let documentsDirectory = try self.getDocumentsDirectory()
                    let sanitizedFileName = self.sanitizeFileName(episode.title)
                    let destinationUrl = documentsDirectory.appendingPathComponent("\(sanitizedFileName).mp3")
                    
                    if FileManager.default.fileExists(atPath: destinationUrl.path) {
                        try FileManager.default.removeItem(at: destinationUrl)
                    }
                    
                    try FileManager.default.moveItem(at: localUrl, to: destinationUrl)
                    
                    // Update CoreData and UI state
                    let context = CoreDataStack.shared.context
                    context.performAndWait {
                        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                        
                        do {
                            let results = try context.fetch(fetchRequest)
                            let managedEpisode = results.first ?? PodcastModel(context: context)
                            managedEpisode.update(from: episode)
                            managedEpisode.isDownloaded = true
                            managedEpisode.localFilePath = destinationUrl.path
                            
                            try context.save()
                            
                            DispatchQueue.main.async {
                                // Get the current episode from allEpisodes to preserve existing state
                                var updatedEpisode: PodcastEpisode
                                if let index = self.allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                                    // Use the existing episode to preserve all current state (favorites, progress, etc.)
                                    updatedEpisode = self.allEpisodes[index]
                                } else {
                                    // Fallback to the original episode if not found
                                    updatedEpisode = episode
                                }
                                
                                // Only update the download-related properties
                                updatedEpisode.state.isDownloaded = true
                                updatedEpisode.localFilePath = destinationUrl.path
                                
                                print("DEBUG: Download completed for episode: \(updatedEpisode.title), preserving favorite status: \(updatedEpisode.state.isFavorite)")
                                
                                // Update in all collections using updateEpisodeInLists for consistency
                                self.updateEpisodeInLists(updatedEpisode)
                                
                                // Update cache immediately instead of clearing it
                                self.updateEpisodeInCache(updatedEpisode)
                                
                                // Update UI
                                self.downloadProgress.removeValue(forKey: episode.id)
                                self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
                                self.objectWillChange.send()
                                
                                completion(.success(updatedEpisode))
                            }
                        } catch {
                            print("Failed to update download status in CoreData: \(error)")
                            completion(.failure(error))
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.downloadProgress.removeValue(forKey: episode.id)
                        completion(.failure(error))
                    }
                }
            }
            
            // Set up progress tracking with immediate UI updates
            task.progress.publisher(for: \.fractionCompleted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] progress in
                    self?.downloadProgress[episode.id] = progress
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
            
            task.resume()
        }
    
    private func getDocumentsDirectory() throws -> URL {
        guard let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Documents directory not found", code: 0, userInfo: nil)
        }
        return path
    }
    
    private func sanitizeFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return fileName.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
    
    // In PodcastViewModel class, update the updateFilteredEpisodes method:
    
    private func buildFilteredPredicate(feedId: String, tab: Int) -> NSPredicate {
           switch tab {
           case 1: // Favorites
               return NSPredicate(format: "feedId == %@ AND isFavorite == YES", feedId)
           case 2: // Downloads
               return NSPredicate(format: "feedId == %@ AND isDownloaded == YES", feedId)
           default: // All Episodes (tab 0)
               return NSPredicate(format: "feedId == %@", feedId)
           }
       }
    
    func fetchEpisodesWithFilter(for feed: PodcastFeed, page: Int, tab: Int, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
           print("DEBUG: fetchEpisodesWithFilter - feedId: \(feed.id), page: \(page), tab: \(tab), episodesPerPage: \(episodesPerPage)")
           
           let backgroundContext = CoreDataStack.shared.newBackgroundContext()
           
           backgroundContext.perform {
               let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
               fetchRequest.predicate = self.buildFilteredPredicate(feedId: feed.id, tab: tab)
               fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
               fetchRequest.fetchLimit = self.episodesPerPage
               fetchRequest.fetchOffset = (page - 1) * self.episodesPerPage
               
               // Optimize for performance
               fetchRequest.fetchBatchSize = self.episodesPerPage
               fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
               fetchRequest.includesPropertyValues = true
               fetchRequest.returnsObjectsAsFaults = false
               
               print("DEBUG: CoreData fetch - limit: \(fetchRequest.fetchLimit), offset: \(fetchRequest.fetchOffset)")
               
               do {
                   let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                   print("DEBUG: CoreData returned \(managedEpisodes.count) episodes for page \(page)")
                   
                   // Convert to PodcastEpisode models with preserved state
                   let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                       var episode = managedEpisode.toPodcastEpisode()
                       episode.state.isPlayed = managedEpisode.isPlayed
                       episode.state.progress = managedEpisode.progress
                       episode.state.isFavorite = managedEpisode.isFavorite
                       episode.state.isDownloaded = managedEpisode.isDownloaded
                       return episode
                   }
                   
                   // Only count total if needed for hasMoreEpisodes determination
                   // Create a separate count request without fetchLimit/fetchOffset to avoid SQL error
                   let countRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                   countRequest.predicate = fetchRequest.predicate
                   countRequest.includesSubentities = false
                   let totalCount = try backgroundContext.count(for: countRequest)
                   let hasMore = totalCount > (page * self.episodesPerPage)
                   
                   print("DEBUG: Converted \(episodes.count) episodes, hasMore: \(hasMore)")
                   
                   DispatchQueue.main.async {
                       self.hasMoreEpisodes = hasMore
                       completion(.success(episodes))
                   }
               } catch {
                   print("❌ fetchEpisodesWithFilter error: \(error)")
                   DispatchQueue.main.async {
                       completion(.failure(error))
                   }
               }
           }
       }
    

    func updateFilteredEpisodes(for feedId: String, selectedTab: Int) {
            print("DEBUG: updateFilteredEpisodes called for feedId: \(feedId), selectedTab: \(selectedTab)")
            
            // Update the currentTab
            self.currentTab = selectedTab
            
            // First priority: Check if we have cached episodes for this feed
            if let cachedEpisodes = episodeCache[feedId], !cachedEpisodes.isEmpty {
                print("DEBUG: Using cached episodes: \(cachedEpisodes.count) episodes")
                
                var filteredEpisodes = cachedEpisodes
                
                switch selectedTab {
                case 1: // Favorites
                    filteredEpisodes = cachedEpisodes.filter { $0.state.isFavorite }
                    print("DEBUG: Filtered to \(filteredEpisodes.count) favorite episodes from cache")
                case 2: // Downloads
                    filteredEpisodes = cachedEpisodes.filter { $0.state.isDownloaded }
                    print("DEBUG: Filtered to \(filteredEpisodes.count) downloaded episodes from cache")
                default:
                    print("DEBUG: Showing all \(filteredEpisodes.count) episodes from cache")
                    break
                }
                
                // Apply consistent date sorting (newest first) to all tabs
                filteredEpisodes.sort { $0.publicationDate > $1.publicationDate }
                
                // Remove duplicates based on compositeID to prevent ForEach issues
                let uniqueEpisodes = self.removeDuplicatesFromEpisodes(filteredEpisodes)
                
                DispatchQueue.main.async {
                    print("DEBUG: Setting currentEpisodes to \(uniqueEpisodes.count) episodes for feedId: \(feedId) (from cache)")
                    self.currentEpisodes = uniqueEpisodes
                    self.objectWillChange.send()
                }
                
                // Update our in-memory collections based on cached data
                self.favoriteEpisodes = cachedEpisodes.filter { $0.state.isFavorite }
                self.downloadedEpisodes = cachedEpisodes.filter { $0.state.isDownloaded }
                
                return
            }
            
            // Check if we should use in-memory episodes or respect initial pagination
            let inMemoryEpisodes = allEpisodes.filter { $0.feedId == feedId }
            print("DEBUG: Found \(inMemoryEpisodes.count) episodes in memory for feedId: \(feedId)")
            
            // IMPORTANT: Only use in-memory episodes if we've already loaded more than one page
            // AND if we're not currently loading episodes (to prevent overriding fresh loads)
            // This prevents showing all episodes on initial load or during pagination
            if !inMemoryEpisodes.isEmpty && (currentPage > 1 || inMemoryEpisodes.count <= episodesPerPage) && !isLoadingEpisodes && !isLoadingMoreEpisodes {
                // Use in-memory episodes and apply tab filtering
                var filteredEpisodes = inMemoryEpisodes
                
                switch selectedTab {
                case 1: // Favorites
                    filteredEpisodes = inMemoryEpisodes.filter { $0.state.isFavorite }
                    print("DEBUG: Filtered to \(filteredEpisodes.count) favorite episodes")
                case 2: // Downloads
                    filteredEpisodes = inMemoryEpisodes.filter { $0.state.isDownloaded }
                    print("DEBUG: Filtered to \(filteredEpisodes.count) downloaded episodes")
                default:
                    print("DEBUG: Showing all \(filteredEpisodes.count) episodes")
                    break
                }
                
                // Apply consistent date sorting (newest first) to all tabs
                filteredEpisodes.sort { $0.publicationDate > $1.publicationDate }
                print("DEBUG: After tab filtering and sorting: \(filteredEpisodes.count) episodes")
                
                // IMPORTANT: Apply pagination to prevent showing all episodes at once
                // Only show episodes up to the current page
                let maxEpisodesToShow = currentPage * episodesPerPage
                if filteredEpisodes.count > maxEpisodesToShow {
                    filteredEpisodes = Array(filteredEpisodes.prefix(maxEpisodesToShow))
                    print("DEBUG: Applied pagination limit: showing \(filteredEpisodes.count) out of \(inMemoryEpisodes.count) total episodes")
                }
                
                // Remove duplicates based on compositeID to prevent ForEach issues
                let uniqueEpisodes = self.removeDuplicatesFromEpisodes(filteredEpisodes)
                
                // Update the cache with the latest states if this is the "All" tab
                if selectedTab == 0 {
                    // Cache the full unfiltered episodes with latest state, not the filtered ones
                    episodeCache[feedId] = self.removeDuplicatesFromEpisodes(inMemoryEpisodes)
                    print("DEBUG: Updated cache with \(inMemoryEpisodes.count) episodes for feedId: \(feedId)")
                }
                
                DispatchQueue.main.async {
                    print("DEBUG: Setting currentEpisodes to \(uniqueEpisodes.count) episodes for feedId: \(feedId) (from memory with pagination)")
                    self.currentEpisodes = uniqueEpisodes
                    
                    // Update hasMoreEpisodes based on whether we have more episodes available
                    let totalAvailable = selectedTab == 0 ? inMemoryEpisodes.count : 
                                       selectedTab == 1 ? inMemoryEpisodes.filter { $0.state.isFavorite }.count :
                                       inMemoryEpisodes.filter { $0.state.isDownloaded }.count
                    self.hasMoreEpisodes = uniqueEpisodes.count < totalAvailable
                    
                    self.objectWillChange.send()
                }
                
                // Update our in-memory collections
                self.favoriteEpisodes = inMemoryEpisodes.filter { $0.state.isFavorite }
                self.downloadedEpisodes = inMemoryEpisodes.filter { $0.state.isDownloaded }
                
                return
            }
            
            print("DEBUG: No episodes in memory for feedId: \(feedId), falling back to Core Data fetch")
            print("DEBUG: Cache status - episodeCache keys: \(Array(episodeCache.keys))")
            print("DEBUG: allEpisodes count: \(allEpisodes.count), episodes for this feed: \(allEpisodes.filter { $0.feedId == feedId }.count)")
            
            // Fallback: get the latest states from Core Data
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            
            // Build predicate based on tab
            var predicates: [NSPredicate] = [NSPredicate(format: "feedId == %@", feedId)]
            
            switch selectedTab {
            case 1: // Favorites
                predicates.append(NSPredicate(format: "isFavorite == YES"))
            case 2: // Downloads
                predicates.append(NSPredicate(format: "isDownloaded == YES"))
            default:
                break
            }
            
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
            
            do {
                let results = try context.fetch(fetchRequest)
                print("DEBUG: Core Data fetch returned \(results.count) episodes for feedId: \(feedId)")
                
                let episodes = results.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    return episode
                }
                
                // Remove duplicates based on compositeID to prevent ForEach issues
                let uniqueEpisodes = self.removeDuplicatesFromEpisodes(episodes)
                
                // Update the cache with the latest states if this is the "All" tab
                if selectedTab == 0 {
                    // For Core Data fallback, we need to fetch ALL episodes for the feed, not just filtered ones
                    // Let's fetch all episodes for this feed to properly update the cache
                    let allEpisodesFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    allEpisodesFetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                    allEpisodesFetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                    
                    do {
                        let allResults = try context.fetch(allEpisodesFetchRequest)
                        let allEpisodesFromCoreData = allResults.map { managedEpisode -> PodcastEpisode in
                            var episode = managedEpisode.toPodcastEpisode()
                            episode.state.isPlayed = managedEpisode.isPlayed
                            episode.state.progress = managedEpisode.progress
                            episode.state.isFavorite = managedEpisode.isFavorite
                            episode.state.isDownloaded = managedEpisode.isDownloaded
                            return episode
                        }
                        episodeCache[feedId] = self.removeDuplicatesFromEpisodes(allEpisodesFromCoreData)
                    } catch {
                        print("Error fetching all episodes for cache: \(error)")
                        episodeCache[feedId] = uniqueEpisodes // Fallback to filtered episodes
                    }
                }
                
                DispatchQueue.main.async {
                    print("DEBUG: Setting currentEpisodes to \(uniqueEpisodes.count) episodes for feedId: \(feedId) (from Core Data)")
                    if uniqueEpisodes.isEmpty {
                        print("WARNING: No episodes found for feedId: \(feedId). This feed will appear empty.")
                        print("DEBUG: Original episodes count before deduplication was: \(episodes.count)")
                    }
                    self.currentEpisodes = uniqueEpisodes
                    self.objectWillChange.send()
                }
                
                // Update our in-memory collections to match Core Data
                self.favoriteEpisodes = episodes.filter { $0.state.isFavorite }
                self.downloadedEpisodes = episodes.filter { $0.state.isDownloaded }
                
            } catch {
                print("Error fetching filtered episodes: \(error)")
            }
        }
    
    private func updateEpisodeInCache(_ episode: PodcastEpisode) {
            if var cachedEpisodes = episodeCache[episode.feedId],
               let index = cachedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                cachedEpisodes[index] = episode
                episodeCache[episode.feedId] = cachedEpisodes
                print("DEBUG: Updated episode in cache: \(episode.title), isFavorite: \(episode.state.isFavorite)")
            } else {
                print("DEBUG: Episode not found in cache or cache empty for feedId: \(episode.feedId)")
            }
        }
    
    // Helper method to remove duplicate episodes based on episode ID with intelligent merging
    private func removeDuplicatesFromEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else {
            print("DEBUG: No episodes to process")
            return []
        }
        
        var episodeMap: [String: PodcastEpisode] = [:]
        var duplicatesCount = 0
        
        print("DEBUG: Starting duplicate removal for \(episodes.count) episodes")
        
        for episode in episodes {
            if let existingEpisode = episodeMap[episode.id] {
                // Found duplicate - merge intelligently to preserve progress data
                duplicatesCount += 1
                
                // Merge episode states, preserving the highest progress and combining favorites/downloads
                var mergedEpisode = existingEpisode
                
                // Cross-reference with EpisodeStateManager for most current data
                let stateManagerProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
                let currentProgress = max(episode.state.progress, existingEpisode.state.progress)
                mergedEpisode.state.progress = max(stateManagerProgress, currentProgress)
                
                // Merge favorite and download states (true if either is true)
                mergedEpisode.state.isFavorite = existingEpisode.state.isFavorite || episode.state.isFavorite
                mergedEpisode.state.isDownloaded = existingEpisode.state.isDownloaded || episode.state.isDownloaded
                
                episodeMap[episode.id] = mergedEpisode
            } else {
                episodeMap[episode.id] = episode
            }
        }
        
        let uniqueEpisodes = Array(episodeMap.values)
        
        if duplicatesCount > 0 {
            print("DEBUG: Intelligently merged \(duplicatesCount) duplicate episodes from \(episodes.count) total episodes")
        } else {
            print("DEBUG: No duplicates found in \(episodes.count) episodes")
        }
        
        print("DEBUG: Returning \(uniqueEpisodes.count) unique episodes")
        
        // Sort episodes by publication date (newest first) before returning
        return uniqueEpisodes.sorted { $0.publicationDate > $1.publicationDate }
    }
    
    // Fallback method to remove duplicates by ID only
    private func removeDuplicatesByID(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        var seenIDs = Set<String>()
        var uniqueEpisodes: [PodcastEpisode] = []
        
        for episode in episodes {
            if !seenIDs.contains(episode.id) {
                seenIDs.insert(episode.id)
                uniqueEpisodes.append(episode)
            }
        }
        
        print("DEBUG: Fallback deduplication by ID: \(episodes.count) -> \(uniqueEpisodes.count)")
        return uniqueEpisodes
    }
    
    // Private setter method to efficiently update currentEpisodes
    private func setCurrentEpisodes(_ episodes: [PodcastEpisode]) {
        // For performance, only deduplicate if we suspect there might be duplicates
        let episodeCount = episodes.count
        let uniqueIDs = Set(episodes.map { $0.id })
        
        if episodeCount == uniqueIDs.count {
            // No duplicates detected, use episodes as-is for better performance
            currentEpisodes = episodes
            print("DEBUG: setCurrentEpisodes (optimized) - \(episodes.count) episodes")
        } else {
            // Duplicates detected, perform minimal deduplication
            print("WARNING: \(episodeCount - uniqueIDs.count) duplicates detected, deduplicating...")
            var seenIDs = Set<String>()
            let uniqueEpisodes = episodes.filter { episode in
                if seenIDs.contains(episode.id) {
                    return false
                } else {
                    seenIDs.insert(episode.id)
                    return true
                }
            }
            currentEpisodes = uniqueEpisodes
            print("DEBUG: setCurrentEpisodes (deduplicated) - \(uniqueEpisodes.count) episodes")
        }
    }
    

}

class RSSParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    var podcastTitle: String?
    var podcastDescription: String?
    var artworkUrl: String?
    var episodes: [PodcastEpisode] = []
    private let feedId: String
    private var currentFileSize: Int64?
    
    private var currentElement = ""
    private var currentTitle: String?
    private var currentDescription: String?
    private var currentPubDate: String?
    private var currentDuration: String?
    private var currentEnclosure: String?
    private var currentGuid: String?
    private var isParsingItem = false
    
    init(data: Data, feedId: String) {
        self.parser = XMLParser(data: data)
        self.feedId = feedId
        super.init()
        self.parser.delegate = self
    }
    
    func parse() {
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        switch elementName {
        case "item":
            isParsingItem = true
            currentTitle = nil
            currentDescription = nil
            currentPubDate = nil
            currentDuration = nil
            currentEnclosure = nil
            currentGuid = nil
            currentFileSize = nil
        case "enclosure":
            if isParsingItem {
                currentEnclosure = attributeDict["url"]
                if let fileSizeString = attributeDict["length"], let fileSize = Int64(fileSizeString) {
                    currentFileSize = fileSize
                }
            }
        case "itunes:image":
            if !isParsingItem {
                artworkUrl = attributeDict["href"]
            }
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "item" {
                if let title = currentTitle,
                   let descriptionText = currentDescription,
                   let pubDateString = currentPubDate,
                   let enclosure = currentEnclosure {
                    
                    let pubDate = DateFormatter.rfc2822.date(from: pubDateString) ?? Date()
                    let duration = parseDuration(currentDuration ?? "0")
                    let id = currentGuid ?? UUID().uuidString
                    
                    let episode = PodcastEpisode(
                        id: id,
                        title: title,
                        descriptionText: descriptionText,
                        audioUrl: enclosure,
                        publicationDate: pubDate,
                        duration: duration,
                        state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
                        feedId: feedId,
                        fileSize: currentFileSize
                    )
                    
                    episodes.append(episode)
                }
                
                isParsingItem = false
            }
        }
    
    private func parseDuration(_ durationString: String) -> TimeInterval {
        let components = durationString.components(separatedBy: ":")
        var duration: TimeInterval = 0

        switch components.count {
        case 3:
            // Format: HH:MM:SS
            let hours = Double(components[0]) ?? 0
            let minutes = Double(components[1]) ?? 0
            let seconds = Double(components[2]) ?? 0
            duration = hours * 3600 + minutes * 60 + seconds

        case 2:
            // Format: MM:SS
            let minutes = Double(components[0]) ?? 0
            let seconds = Double(components[1]) ?? 0
            duration = minutes * 60 + seconds

        case 1:
            // Format: Seconds
            duration = Double(components[0]) ?? 0

        default:
            // Invalid format, return 0
            duration = 0
        }

        // Ensure non-negative duration
        return max(duration, 0)
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let data = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !data.isEmpty {
            switch currentElement {
            case "title":
                if isParsingItem {
                    currentTitle = (currentTitle ?? "") + data
                } else {
                    podcastTitle = (podcastTitle ?? "") + data
                }
            case "description":
                if isParsingItem {
                    currentDescription = (currentDescription ?? "") + data
                } else {
                    podcastDescription = (podcastDescription ?? "") + data
                }
            case "pubDate":
                if isParsingItem {
                    currentPubDate = (currentPubDate ?? "") + data
                }
            case "itunes:duration":
                if isParsingItem {
                    currentDuration = (currentDuration ?? "") + data
                }
            case "guid":
                if isParsingItem {
                    currentGuid = (currentGuid ?? "") + data
                }
            default:
                break
            }
        }
    }
}

extension DateFormatter {
    static let rfc2822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
