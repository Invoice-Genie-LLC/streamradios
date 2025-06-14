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

struct PodcastFeed: Identifiable, Codable {
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
        return "\(feedId)_\(id)_\(dateString)_\(titleHash)"
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
    @Published var downloadProgress: [String: Double] = [:]
    @Published var currentTab: Int = 0
    @Published var downloadedEpisodeIds: Set<String> = []
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var hasChanges = false
    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()
    private var backgroundContext: NSManagedObjectContext
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
    private let episodesPerPage = 100
        var currentPage = 1
    private var isInitialLoadComplete = false
    
    init(context: NSManagedObjectContext = CoreDataStack.shared.context) {
        self.context = context
        self.backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.backgroundContext.parent = context

        // Load lastPlayedEpisodes immediately (synchronously) so UI can use it right away
        self.loadLastPlayedEpisodes()

        // Perform initial loading asynchronously on a background thread
        Task(priority: .background) {
            await loadInitialData()
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
        self.isInitialLoadComplete = true
        
        self.objectWillChange.send()
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
    
    func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
            print("DEBUG: loadAllEpisodesForFeed called for feed: \(feed.title) (id: \(feed.id))")
            
            // If episodes are already in memory, use them
            if let cachedEpisodes = episodeCache[feed.id] {
                print("DEBUG: Found \(cachedEpisodes.count) cached episodes for feed: \(feed.title)")
                let uniqueEpisodes = self.removeDuplicatesFromEpisodes(cachedEpisodes)
                self.currentEpisodes = uniqueEpisodes
                self.objectWillChange.send()
                return
            }
            
            print("DEBUG: No cached episodes found for feed: \(feed.title), checking Core Data")
            isLoadingEpisodes = true
            
            // Try to load from Core Data first
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                print("DEBUG: Core Data returned \(managedEpisodes.count) episodes for feed: \(feed.title)")
                
                if !managedEpisodes.isEmpty {
                    // If we have episodes in Core Data, use them
                    let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                        var episode = managedEpisode.toPodcastEpisode()
                        episode.state.isPlayed = managedEpisode.isPlayed
                        episode.state.progress = managedEpisode.progress
                        episode.state.isFavorite = managedEpisode.isFavorite
                        episode.state.isDownloaded = managedEpisode.isDownloaded
                        return episode
                    }
                    
                    DispatchQueue.main.async {
                        let uniqueEpisodes = self.removeDuplicatesFromEpisodes(episodes)
                        self.episodeCache[feed.id] = uniqueEpisodes
                        self.currentEpisodes = uniqueEpisodes
                        self.isLoadingEpisodes = false
                        print("DEBUG: Loaded \(uniqueEpisodes.count) episodes from Core Data for feed: \(feed.title)")
                        self.objectWillChange.send()
                    }
                } else {
                    print("DEBUG: No episodes in Core Data for feed: \(feed.title), checking if should fetch from RSS")
                    print("DEBUG: isInitialLoadComplete: \(isInitialLoadComplete)")
                    // Only fetch from RSS if we have no episodes in Core Data AND initial loading is complete
                    if isInitialLoadComplete {
                        print("DEBUG: Fetching episodes from RSS for feed: \(feed.title)")
                        fetchInitialEpisodesFromRSS(for: feed)
                    } else {
                        // If initial loading isn't complete, just show empty state for now
                        print("DEBUG: Initial loading not complete, showing empty state for feed: \(feed.title)")
                        DispatchQueue.main.async {
                            self.currentEpisodes = []
                            self.isLoadingEpisodes = false
                        }
                    }
                }
            } catch {
                print("Error loading episodes from Core Data: \(error)")
                // If Core Data fails, try RSS as fallback
                fetchInitialEpisodesFromRSS(for: feed)
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
                        self.currentEpisodes = uniqueEpisodes
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
                       let uniqueEpisodes = self.removeDuplicatesFromEpisodes(episodes)
                       self.currentEpisodes = uniqueEpisodes
                       if self.currentTab == 0 {
                           self.episodeCache[feed.id] = uniqueEpisodes
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
              isLoading = true
              fetchRSSFeed(for: feed) { result in
                  DispatchQueue.main.async {
                      self.isLoading = false
                      switch result {
                      case .success(let updatedFeed):
                          self.updateFeed(updatedFeed)
                          self.updateFilteredEpisodes(for: feed.id, selectedTab: self.currentTab)
                      case .failure(let error):
                          print("Failed to fetch episodes: \(error)")
                          // Handle error appropriately
                      }
                  }
              }
          }
    
    func refreshAllFeeds() {
            // Instead of refreshing all feeds, just reload from Core Data
            for feed in podcastFeeds {
                if let cachedEpisodes = episodeCache[feed.id] {
                    // Use cached episodes if available
                    continue
                } else {
                    // Load from Core Data if not cached
                    loadAllEpisodesForFeed(feed)
                }
            }
            objectWillChange.send()
        }
    
    func sortFeedsAlphabetically() {
        // Toggle sort direction
        isAscendingSort.toggle()
        
        let sortedFeeds: [PodcastFeed]
        if isAscendingSort {
            // Ascending A-Z
            sortedFeeds = podcastFeeds.sorted { $0.title.lowercased() < $1.title.lowercased() }
        } else {
            // Descending Z-A
            sortedFeeds = podcastFeeds.sorted { $0.title.lowercased() > $1.title.lowercased() }
        }
        
        podcastFeedOrder = sortedFeeds.map { $0.id }
        saveFeedOrder()
        saveSortDirection()
        objectWillChange.send()
    }

    func moveFeed(from source: IndexSet, to destination: Int) {
        podcastFeedOrder.move(fromOffsets: source, toOffset: destination)
        saveFeedOrder()
        objectWillChange.send()
    }
    
     func saveFeedOrder() {
        do {
            let orderData = try JSONEncoder().encode(podcastFeedOrder)
            UserDefaults.standard.set(orderData, forKey: "PodcastFeedOrder")
        } catch {
            print("Failed to save feed order to UserDefaults: \(error)")
        }
    }
    
    func loadFeedOrder() {
        if let orderData = UserDefaults.standard.data(forKey: "PodcastFeedOrder"),
           let order = try? JSONDecoder().decode([String].self, from: orderData) {
            podcastFeedOrder = order
        } else {
            // If no saved order, create initial order based on current feeds
            podcastFeedOrder = podcastFeeds.map { $0.id }
        }
    }

    func updateEpisodeDuration(_ episode: PodcastEpisode, newDuration: Double) {
        if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
            var updatedEpisode = allEpisodes[index]
            updatedEpisode.duration = newDuration
            allEpisodes[index] = updatedEpisode
            
            if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[currentIndex] = updatedEpisode
            }
            
            updateEpisodeInCoreData(updatedEpisode)
        }
        objectWillChange.send()
    }
    
    private func updateEpisodeInCoreData(_ episode: PodcastEpisode) {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)

        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.duration = episode.duration
                try context.save()
            }
        } catch {
            print("Failed to update episode duration in Core Data: \(error)")
        }
    }
    
    func addPodcastFeed(_ feed: PodcastFeed) {
        isLoading = true
        
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@ OR url == %@", feed.id, feed.url)
        
        do {
            let existingFeeds = try context.fetch(fetchRequest)
            if let existingFeed = existingFeeds.first {
                existingFeed.update(from: feed)
                if let imageData = feed.imageData {
                    existingFeed.iconData = imageData.base64EncodedString()
                }
                os_log("Updated existing podcast feed: %@", log: log, type: .info, feed.title)
            } else {
                let managedFeed = FeedModel(context: context)
                managedFeed.update(from: feed)
                if let imageData = feed.imageData {
                    managedFeed.iconData = imageData.base64EncodedString()
                }
                podcastFeeds.append(feed)
                podcastFeedOrder.append(feed.id)
                os_log("Added new podcast feed: %@", log: log, type: .info, feed.title)
            }
            
            try context.save()
            
            dataStore.savePodcastFeedToCloudKit(feed) { [weak self] success, recordID in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if success {
                        os_log("Saved podcast feed to CloudKit: %@", log: self.log, type: .info, feed.title)
                    } else {
                        os_log("Failed to save podcast feed to CloudKit: %@", log: self.log, type: .error, feed.title)
                    }
                    
                    self.fetchRSSFeed(for: feed) { result in
                        switch result {
                        case .success(let updatedFeed):
                            if let index = self.podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
                                self.podcastFeeds[index] = updatedFeed
                            }
                            self.updateFeed(updatedFeed)
                        case .failure(let error):
                            os_log("Failed to fetch RSS feed for new podcast: %@", log: self.log, type: .error, error.localizedDescription)
                        }
                        self.isLoading = false
                        self.objectWillChange.send()
                    }
                }
            }
        } catch {
            os_log("Failed to save new podcast feed: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to save new podcast feed"
            self.isLoading = false
            self.objectWillChange.send()
        }
    }
    
    func updatePodcastFeed(_ updatedFeed: PodcastFeed) {
        print("DEBUG: updatePodcastFeed called with - ID: \(updatedFeed.id), Title: '\(updatedFeed.title)', URL: '\(updatedFeed.url)'")
        isLoading = true
        
        // Update in memory first
        if let index = podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
            let oldFeed = podcastFeeds[index]
            print("DEBUG: Found feed to update - Old Title: '\(oldFeed.title)', New Title: '\(updatedFeed.title)'")
            print("DEBUG: Found feed to update - Old URL: '\(oldFeed.url)', New URL: '\(updatedFeed.url)'")
            podcastFeeds[index] = updatedFeed
            print("DEBUG: Updated feed in memory")
        } else {
            print("DEBUG: ERROR - Could not find feed with ID: \(updatedFeed.id)")
        }
        
        // Update in Core Data
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", updatedFeed.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedFeed = results.first {
                print("DEBUG: Found managed feed to update - Old Title: '\(managedFeed.title ?? "nil")', New Title: '\(updatedFeed.title)'")
                managedFeed.update(from: updatedFeed)
                try context.save()
                print("DEBUG: Successfully saved to Core Data")
                os_log("Updated podcast feed: %@", log: log, type: .info, updatedFeed.title)
                
                // Force UI update
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
                
                // Update in CloudKit
                dataStore.savePodcastFeedToCloudKit(updatedFeed) { [weak self] success, recordID in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if success {
                            print("DEBUG: Successfully updated in CloudKit")
                            os_log("Updated podcast feed in CloudKit: %@", log: self.log, type: .info, updatedFeed.title)
                        } else {
                            print("DEBUG: Failed to update in CloudKit")
                            os_log("Failed to update podcast feed in CloudKit: %@", log: self.log, type: .error, updatedFeed.title)
                        }
                        
                        // Refetch episodes if URL changed
                        self.fetchRSSFeed(for: updatedFeed) { result in
                            switch result {
                            case .success(let refreshedFeed):
                                print("DEBUG: Successfully refreshed RSS feed")
                                if let index = self.podcastFeeds.firstIndex(where: { $0.id == refreshedFeed.id }) {
                                    self.podcastFeeds[index] = refreshedFeed
                                }
                                self.updateFeed(refreshedFeed)
                            case .failure(let error):
                                print("DEBUG: Failed to refresh RSS feed: \(error)")
                                os_log("Failed to refresh RSS feed after update: %@", log: self.log, type: .error, error.localizedDescription)
                            }
                            self.isLoading = false
                            self.objectWillChange.send()
                        }
                    }
                }
            } else {
                print("DEBUG: ERROR - Could not find managed feed with ID: \(updatedFeed.id)")
                self.isLoading = false
                self.objectWillChange.send()
            }
        } catch {
            print("DEBUG: Core Data error: \(error)")
            os_log("Failed to update podcast feed: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to update podcast feed"
            self.isLoading = false
            self.objectWillChange.send()
        }
    }
    
    func refreshEpisodeStates() {
        for index in allEpisodes.indices {
            let episode = allEpisodes[index]
            allEpisodes[index].state.isFavorite = favoriteEpisodes.contains(where: { $0.id == episode.id })
            allEpisodes[index].state.isDownloaded = downloadedEpisodes.contains(where: { $0.id == episode.id })
        }
        objectWillChange.send() // Trigger a UI update across all tabs
    }
    
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) {
        // Get the current episode from allEpisodes to preserve existing state
        var updatedEpisode: PodcastEpisode
        if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
            // Use the existing episode to preserve all current state (favorites, progress, etc.)
            updatedEpisode = allEpisodes[index]
        } else {
            // Fallback to the original episode if not found
            updatedEpisode = episode
        }
        
        // Only update the download-related properties
        updatedEpisode.state.isDownloaded = false
        updatedEpisode.localFilePath = nil
        
        print("DEBUG: Deleting download for episode: \(updatedEpisode.title), preserving favorite status: \(updatedEpisode.state.isFavorite)")
        
        // Update in-memory arrays immediately for optimistic UI update
        updateEpisodeInLists(updatedEpisode)
        
        // Update cache immediately
        updateEpisodeInCache(updatedEpisode)
        
        // Trigger immediate UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
            // Update filtered episodes for immediate tab filtering
            self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
        }
        
        // Delete the local file
        if let localFilePath = episode.localFilePath {
            do {
                try FileManager.default.removeItem(atPath: localFilePath)
                print("DEBUG: Successfully deleted local file for episode: \(episode.title)")
            } catch {
                print("DEBUG: Error deleting local file for episode \(episode.title): \(error)")
            }
        }
        
        // Then save to Core Data in the background
        DispatchQueue.global(qos: .background).async {
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
            
            do {
                let results = try context.fetch(fetchRequest)
                if let managedEpisode = results.first {
                    managedEpisode.isDownloaded = false
                    managedEpisode.localFilePath = nil
                    try context.save()
                    print("DEBUG: Successfully saved download deletion to Core Data for episode: \(episode.title)")
                }
            } catch {
                print("DEBUG: Error updating CoreData for episode \(episode.title): \(error)")
                
                // If Core Data save fails, revert the UI change
                DispatchQueue.main.async {
                    var revertedEpisode = updatedEpisode
                    revertedEpisode.state.isDownloaded = episode.state.isDownloaded
                    revertedEpisode.localFilePath = episode.localFilePath
                    self.updateEpisodeInLists(revertedEpisode)
                    self.updateEpisodeInCache(revertedEpisode)
                    self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
                    self.objectWillChange.send()
                }
            }
        }
    }
    
    private func loadSavedData() {
        backgroundContext.perform {
            self.loadPodcastFeeds()
            // loadDownloadedEpisodes() and loadFavoriteEpisodes() are now handled by loadAllEpisodes()
            self.loadAllEpisodes()
        }
    }
    
    // Note: loadDownloadedEpisodes() and loadFavoriteEpisodes() are now handled by loadAllEpisodes()
    // These methods are kept for backward compatibility but are no longer needed
    
    func clearAllPodcastData(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var success = true
        
        print("DEBUG: Starting comprehensive podcast data cleanup...")
        
        // 1. Delete all downloaded podcast files
        group.enter()
        deleteAllDownloadedPodcasts { result in
            if !result {
                success = false
                print("DEBUG: Failed to delete downloaded podcast files")
            } else {
                print("DEBUG: Successfully deleted all downloaded podcast files")
            }
            group.leave()
        }
        
        // 2. Delete all podcast episodes from Core Data
        group.enter()
        deleteAllPodcastEpisodesFromCoreData { result in
            if !result {
                success = false
                print("DEBUG: Failed to delete podcast episodes from Core Data")
            } else {
                print("DEBUG: Successfully deleted all podcast episodes from Core Data")
            }
            group.leave()
        }
        
        // 3. Clear all bookmarks, favorites, and progress from UserDefaults
        group.enter()
        clearAllUserDefaultsData { result in
            if !result {
                success = false
                print("DEBUG: Failed to clear UserDefaults data")
            } else {
                print("DEBUG: Successfully cleared all UserDefaults data")
            }
            group.leave()
        }
        
        // 4. Clear all saved episode progress from UserDefaults or other storage
        group.enter()
        clearEpisodeProgressData { result in
            if !result {
                success = false
                print("DEBUG: Failed to clear episode progress data")
            } else {
                print("DEBUG: Successfully cleared episode progress data")
            }
            group.leave()
        }
        
        // 5. Clear EpisodeStateManager data
        group.enter()
        DispatchQueue.main.async {
            EpisodeStateManager.shared.clearAllStates()
            print("DEBUG: Successfully cleared EpisodeStateManager data")
            group.leave()
        }
        
        // 6. Reset PodcastPlayer state and progress
        group.enter()
        DispatchQueue.main.async {
            // Stop current playback and clear episode
            PodcastPlayer.shared.pause()
            PodcastPlayer.shared.currentEpisode = nil
            PodcastPlayer.shared.currentFeed = nil
            PodcastPlayer.shared.currentProgress = 0
            print("DEBUG: Successfully reset PodcastPlayer state")
            group.leave()
        }
        
        group.notify(queue: .main) {
            // Reset view model properties
            self.podcastFeeds = []
            self.allEpisodes = []
            self.currentEpisodes = []
            self.downloadedEpisodes = []
            self.favoriteEpisodes = []
            self.episodeProgress = [:]
            self.lastPlayedEpisodes = [:] // Reset last played episodes
            self.isAscendingSort = true // Reset sort direction
            
            // Clear episode cache
            self.episodeCache.removeAll()
            
            // Force clear any remaining progress keys that might have been missed
            self.forceCleanRemainingProgressData()
            
            // Force a complete UI refresh
            self.objectWillChange.send()
            
            print("DEBUG: Completed comprehensive podcast data cleanup")
            completion(success)
        }
    }
    
    private func clearEpisodeProgressData(completion: @escaping (Bool) -> Void) {
           let userDefaults = UserDefaults.standard
           
           // Remove all keys that start with "PodcastProgress_"
           for key in userDefaults.dictionaryRepresentation().keys {
               if key.hasPrefix("PodcastProgress_") {
                   userDefaults.removeObject(forKey: key)
               }
           }
           
           completion(true)
       }
    
    private func clearAllUserDefaultsData(completion: @escaping (Bool) -> Void) {
        let userDefaults = UserDefaults.standard
        
        // Clear all podcast-related UserDefaults keys
        userDefaults.removeObject(forKey: favoritesKey) // Favorite episodes
        userDefaults.removeObject(forKey: progressKey) // Episode progress
        userDefaults.removeObject(forKey: episodeStatesKey) // Episode states
        userDefaults.removeObject(forKey: episodeListKey) // Episode lists
        userDefaults.removeObject(forKey: bookmarkStatusKey) // Bookmark status
        userDefaults.removeObject(forKey: downloadStatusKey) // Download status
        userDefaults.removeObject(forKey: "LastPlayedEpisodes") // Last played episodes
        userDefaults.removeObject(forKey: "PodcastSortAscending") // Sort direction
        
        // Remove all keys that start with podcast/episode-related prefixes (individual episode progress)
        let allKeys = Array(userDefaults.dictionaryRepresentation().keys)
        var removedKeysCount = 0
        
        for key in allKeys {
            if key.hasPrefix("PodcastProgress_") || 
               key.hasPrefix("PodcastBookmark_") ||
               key.hasPrefix("PodcastDownload_") ||
               key.hasPrefix("PodcastFavorite_") ||
               key.hasPrefix("EpisodeProgress_") ||
               key.hasPrefix("Episode_") ||
               key.hasPrefix("EpisodeStates") ||
               key.hasPrefix("EpisodeProgress") ||
               key.contains("Progress") && (key.contains("Episode") || key.contains("Podcast")) {
                
                print("DEBUG: Removing UserDefaults key: \(key)")
                userDefaults.removeObject(forKey: key)
                removedKeysCount += 1
            }
        }
        
        print("DEBUG: Removed \(removedKeysCount) podcast-related UserDefaults keys")
        
        print("DEBUG: Cleared all podcast-related UserDefaults data")
        completion(true)
    }
    
    private func deleteAllDownloadedPodcasts(completion: @escaping (Bool) -> Void) {
        let fileManager = FileManager.default
        guard let documentsUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            completion(false)
            return
        }
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsUrl, includingPropertiesForKeys: nil)
            for fileURL in fileURLs where fileURL.pathExtension == "mp3" {
                try fileManager.removeItem(at: fileURL)
            }
            completion(true)
        } catch {
            print("Error deleting downloaded podcasts: \(error)")
            completion(false)
        }
    }
    
    private func deleteAllPodcastEpisodesFromCoreData(completion: @escaping (Bool) -> Void) {
        print("DEBUG: Starting Core Data episode deletion...")
        
        // First, try to fetch all episodes and delete them individually to ensure complete cleanup
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        do {
            let allEpisodes = try context.fetch(fetchRequest)
            print("DEBUG: Found \(allEpisodes.count) episodes to delete from Core Data")
            
            // Delete each episode individually to ensure progress is cleared
            for episode in allEpisodes {
                print("DEBUG: Deleting episode: \(episode.title ?? "Unknown") with progress: \(episode.progress)")
                context.delete(episode)
            }
            
            // Save the context
            try context.save()
            print("DEBUG: Successfully deleted all \(allEpisodes.count) episodes from Core Data")
            
            // Also do a batch delete as a backup to catch any remaining data
            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: "PodcastModel"))
            batchDeleteRequest.resultType = .resultTypeObjectIDs
            
            let batchResult = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
            if let objectIDs = batchResult?.result as? [NSManagedObjectID] {
                let changes = [NSDeletedObjectsKey: objectIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                print("DEBUG: Batch delete removed \(objectIDs.count) additional objects")
            }
            
            try context.save()
            completion(true)
        } catch {
            print("DEBUG: Error deleting podcast episodes from Core Data: \(error)")
            completion(false)
        }
    }
    
    private func loadPodcastFeeds() {
            backgroundContext.perform { [weak self] in
                guard let self = self else { return }
                
                let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                do {
                    let managedFeeds = try self.backgroundContext.fetch(fetchRequest)
                    let feeds = managedFeeds.map { $0.toPodcastFeed() }
                    
                    DispatchQueue.main.async {
                        self.podcastFeeds = feeds
                        
                        print("DEBUG: loadPodcastFeeds - Loaded \(feeds.count) feeds:")
                        for feed in feeds {
                            print("DEBUG: loadPodcastFeeds - Feed: \(feed.title) (ID: \(feed.id))")
                        }
                        
                        // Update podcastFeedOrder
                        let existingIds = Set(self.podcastFeedOrder)
                        for feed in self.podcastFeeds where !existingIds.contains(feed.id) {
                            self.podcastFeedOrder.append(feed.id)
                        }
                        
                        os_log("Loaded %d podcast feeds from Core Data", log: self.log, type: .info, self.podcastFeeds.count)
                    }
                } catch {
                    DispatchQueue.main.async {
                        os_log("Failed to load podcast feeds: %@", log: self.log, type: .error, error.localizedDescription)
                    }
                }
            }
        }
    
    private func loadAllEpisodes() {
        backgroundContext.perform { [weak self] in
            guard let self = self else { return }
            
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let managedEpisodes = try self.backgroundContext.fetch(fetchRequest)
                print("DEBUG: loadAllEpisodes - Found \(managedEpisodes.count) episodes in Core Data")
                
                // Group episodes by feedId for debugging
                let episodesByFeed = Dictionary(grouping: managedEpisodes) { $0.feedId ?? "unknown" }
                for (feedId, episodes) in episodesByFeed {
                    print("DEBUG: loadAllEpisodes - Feed \(feedId): \(episodes.count) episodes")
                }
                
                let episodes = managedEpisodes.map { managedEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite  // Load favorite status
                    episode.state.isDownloaded = managedEpisode.isDownloaded  // Load download status
                    return episode
                }
                let downloadedIds = Set(managedEpisodes.compactMap { $0.isDownloaded ? $0.id : nil })
                let favoriteIds = Set(managedEpisodes.compactMap { $0.isFavorite ? $0.id : nil })
                
                print("DEBUG: loadAllEpisodes - Found \(favoriteIds.count) favorite episodes")
                print("DEBUG: loadAllEpisodes - Found \(downloadedIds.count) downloaded episodes")
                
                DispatchQueue.main.async {
                    // Sort episodes by publication date (newest first) for consistent ordering
                    let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
                    self.allEpisodes = sortedEpisodes
                    self.downloadedEpisodeIds = downloadedIds
                    
                    // Populate the favorite and downloaded episode arrays (also sorted)
                    self.favoriteEpisodes = sortedEpisodes.filter { $0.state.isFavorite }
                    self.downloadedEpisodes = sortedEpisodes.filter { $0.state.isDownloaded }
                    
                    print("DEBUG: loadAllEpisodes - Set allEpisodes to \(self.allEpisodes.count) episodes")
                    print("DEBUG: loadAllEpisodes - Set favoriteEpisodes to \(self.favoriteEpisodes.count) episodes")
                    print("DEBUG: loadAllEpisodes - Set downloadedEpisodes to \(self.downloadedEpisodes.count) episodes")
                    
                    os_log("Loaded %d episodes, %d downloaded, %d favorites", log: self.log, type: .info, self.allEpisodes.count, self.downloadedEpisodeIds.count, self.favoriteEpisodes.count)
                }
            } catch {
                DispatchQueue.main.async {
                    print("DEBUG: loadAllEpisodes - Error: \(error)")
                    os_log("Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }
    
    func fetchPodcastFeeds() {
        isLoading = true
        
        // Fetch from CoreData with a large batch size
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.fetchBatchSize = 1000  // Set a large batch size, e.g., 1000
        
        do {
            let managedFeeds = try context.fetch(fetchRequest)
            podcastFeeds = managedFeeds.map { $0.toPodcastFeed() }
            os_log("Loaded %d podcast feeds from Core Data with batch size %d", log: log, type: .info, podcastFeeds.count, fetchRequest.fetchBatchSize)
        } catch {
            os_log("Failed to load podcast feeds from Core Data: %@", log: log, type: .error, error.localizedDescription)
        }
        
        // Fetch from CloudKit
        dataStore.fetchPodcastFeedsFromCloudKit { [weak self] (cloudFeeds, error) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let cloudFeeds = cloudFeeds {
                    // Merge CloudKit feeds with CoreData feeds
                    self.mergeFeedsFromCloudKit(cloudFeeds)
                    os_log("Merged %d podcast feeds from CloudKit", log: self.log, type: .info, cloudFeeds.count)
                } else if let error = error {
                    os_log("Failed to fetch podcast feeds from CloudKit: %@", log: self.log, type: .error, error.localizedDescription)
                }
                
                // Don't automatically fetch RSS feeds immediately on app startup
                // This will be handled by the UI when feeds are actually viewed
                // to prevent overwriting favorite status during initial loading
                
                self.isLoading = false
            }
        }
    }
    
    private func mergeFeedsFromCloudKit(_ cloudFeeds: [PodcastFeed]) {
            let existingFeedIds = Set(podcastFeeds.map { $0.id })
            
            for cloudFeed in cloudFeeds {
                if !existingFeedIds.contains(cloudFeed.id) {
                    // Add new feed from CloudKit to CoreData
                    let managedFeed = FeedModel(context: context)
                    managedFeed.update(from: cloudFeed)
                    podcastFeeds.append(cloudFeed)
                    if !podcastFeedOrder.contains(cloudFeed.id) {
                        podcastFeedOrder.append(cloudFeed.id) // Add new feed ID to the order
                    }
                }
            }
            
            do {
                try context.save()
                os_log("Merged CloudKit feeds with Core Data", log: log, type: .info)
            } catch {
                os_log("Failed to save merged feeds to Core Data: %@", log: log, type: .error, error.localizedDescription)
            }
        }
        
    func deletePodcastFeed(_ feed: PodcastFeed) {
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            for object in results {
                context.delete(object)
            }
            try context.save()
            podcastFeeds.removeAll { $0.id == feed.id }
            allEpisodes.removeAll { $0.feedId == feed.id }
            os_log("Deleted podcast feed from Core Data: %@", log: log, type: .info, feed.title)
            
            // Delete from CloudKit
            DataStore.shared.deletePodcastFeedFromCloudKit(feed) { success in
                DispatchQueue.main.async {
                    if success {
                        os_log("Deleted podcast feed from CloudKit: %@", log: self.log, type: .info, feed.title)
                    } else {
                        os_log("Failed to delete podcast feed from CloudKit: %@", log: self.log, type: .error, feed.title)
                        // Consider handling this failure, perhaps by retrying or notifying the user
                    }
                }
            }
        } catch {
            os_log("Failed to delete podcast feed from Core Data: %@", log: log, type: .error, error.localizedDescription)
        }
    }
        
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
           isLoadingEpisodes = true
           
           // Check cache first
           if let cachedEpisodes = episodeCache[feed.id] {
               DispatchQueue.main.async {
                   let uniqueEpisodes = self.removeDuplicatesFromEpisodes(cachedEpisodes)
                   self.currentEpisodes = uniqueEpisodes
                   self.isLoadingEpisodes = false
                   completion(.success(uniqueEpisodes))
               }
               return
           }
           
           fetchEpisodesInBatches(for: feed, page: currentPage) { [weak self] result in
               guard let self = self else { return }
               
               DispatchQueue.main.async {
                   self.isLoadingEpisodes = false
                   
                   switch result {
                   case .success(let episodes):
                       if episodes.isEmpty && self.currentPage == 1 {
                           // No cached episodes, fetch from RSS
                           self.fetchRSSFeed(for: feed) { rssResult in
                               switch rssResult {
                               case .success(let updatedFeed):
                                   // Save new episodes in batches
                                   self.savePodcastEpisodesInBatches(episodes: updatedFeed.episodes, for: updatedFeed)
                                   
                                   // Update cache and current episodes
                                   self.episodeCache[feed.id] = updatedFeed.episodes
                                   let paginatedEpisodes = Array(updatedFeed.episodes.prefix(self.episodesPerPage))
                                   
                                   DispatchQueue.main.async {
                                       let uniqueEpisodes = self.removeDuplicatesFromEpisodes(paginatedEpisodes)
                                       self.currentEpisodes = uniqueEpisodes
                                       self.hasMoreEpisodes = updatedFeed.episodes.count > self.episodesPerPage
                                       completion(.success(uniqueEpisodes))
                                   }
                                   
                               case .failure(let error):
                                   print("Failed to fetch episodes from RSS: \(error)")
                                   completion(.failure(error))
                               }
                           }
                       } else {
                           // Update current episodes based on page
                           if self.currentPage == 1 {
                               let uniqueEpisodes = self.removeDuplicatesFromEpisodes(episodes)
                               self.currentEpisodes = uniqueEpisodes
                           } else {
                               let combinedEpisodes = self.currentEpisodes + episodes
                               let uniqueEpisodes = self.removeDuplicatesFromEpisodes(combinedEpisodes)
                               self.currentEpisodes = uniqueEpisodes
                           }
                           
                           // Cache first page results
                           if self.currentPage == 1 {
                               self.episodeCache[feed.id] = episodes
                           }
                           
                           completion(.success(episodes))
                       }
                       
                   case .failure(let error):
                       print("Error fetching episodes: \(error)")
                       completion(.failure(error))
                   }
               }
           }
       }
    
    func loadMoreEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
            guard !isLoadingMoreEpisodes && hasMoreEpisodes else {
                completion(.success([]))
                return
            }
            
            isLoadingMoreEpisodes = true
            currentPage += 1
            
            fetchEpisodesWithFilter(for: feed, page: currentPage, tab: currentTab) { [weak self] result in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.isLoadingMoreEpisodes = false
                    
                    switch result {
                    case .success(let newEpisodes):
                        if newEpisodes.isEmpty {
                            self.hasMoreEpisodes = false
                            self.currentPage -= 1
                        } else {
                            let combinedEpisodes = self.currentEpisodes + newEpisodes
                            let uniqueEpisodes = self.removeDuplicatesFromEpisodes(combinedEpisodes)
                            self.currentEpisodes = uniqueEpisodes
                            if self.currentTab == 0 {
                                var cachedEpisodes = self.episodeCache[feed.id] ?? []
                                cachedEpisodes.append(contentsOf: newEpisodes)
                                let uniqueCachedEpisodes = self.removeDuplicatesFromEpisodes(cachedEpisodes)
                                self.episodeCache[feed.id] = uniqueCachedEpisodes
                            }
                        }
                        completion(.success(newEpisodes))
                        
                    case .failure(let error):
                        self.currentPage -= 1
                        completion(.failure(error))
                    }
                }
            }
        }
    
    private func saveEpisodesToCoreData(_ episodes: [PodcastEpisode], for feed: PodcastFeed) {
           let context = CoreDataStack.shared.context
           
           context.perform {
               do {
                   // First, ensure we have the feed in the current context
                   let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                   feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                   
                   let feedResults = try context.fetch(feedFetchRequest)
                   let managedFeed = feedResults.first ?? FeedModel(context: context)
                   managedFeed.update(from: feed)
                   
                   // Now save episodes
                   for episode in episodes {
                       let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                       fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                       
                       let results = try context.fetch(fetchRequest)
                       let managedEpisode = results.first ?? PodcastModel(context: context)
                       managedEpisode.update(from: episode)
                       managedEpisode.feed = managedFeed
                       managedEpisode.feedId = feed.id
                   }
                   
                   try context.save()
                   
                   DispatchQueue.main.async {
                       self.objectWillChange.send()
                   }
               } catch {
                   print("Failed to save episodes to Core Data: \(error)")
               }
           }
       }
    
    private func saveEpisodeStatuses(_ episodes: [PodcastEpisode], for feedId: String) {
            let bookmarkStatus = episodes.reduce(into: [String: Bool]()) { $0[$1.id] = $1.state.isFavorite }
            let downloadStatus = episodes.reduce(into: [String: Bool]()) { $0[$1.id] = $1.state.isDownloaded }

        }
    
    private func fetchNewEpisodes(for feed: PodcastFeed) {
        fetchRSSFeed(for: feed) { result in
            switch result {
            case .success(let parsedFeed):
                DispatchQueue.main.async {
                    let newEpisodes = self.mergeNewEpisodes(parsedFeed.episodes, with: self.allEpisodes.filter { $0.feedId == feed.id })
                    self.updateEpisodes(newEpisodes, for: feed)
                    self.objectWillChange.send()
                }
            case .failure(let error):
                os_log("Failed to fetch new episodes for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
            }
        }
    }
    
    private func mergeNewEpisodes(_ newEpisodes: [PodcastEpisode], with existingEpisodes: [PodcastEpisode]) -> [PodcastEpisode] {
            var mergedEpisodes = existingEpisodes
            for newEpisode in newEpisodes {
                if !mergedEpisodes.contains(where: { $0.id == newEpisode.id }) {
                    mergedEpisodes.insert(newEpisode, at: 0)
                }
            }
            return mergedEpisodes
        }
    
    func clearCache(for feedId: String? = nil) {
            if let feedId = feedId {
                episodeCache.removeValue(forKey: feedId)
            } else {
                episodeCache.removeAll()
            }
        }
    
    func refreshEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
           // Clear cache for this feed
           clearPodcastCache(for: feed.id)
           episodeCache.removeValue(forKey: feed.id)
           
           // Reset pagination
           currentPage = 1
           hasMoreEpisodes = true
           
           // Fetch fresh episodes
           fetchEpisodes(for: feed, completion: completion)
       }
    
    private func updateEpisodes(_ episodes: [PodcastEpisode], for feed: PodcastFeed, append: Bool = false) {
        if append {
            let newEpisodes = episodes.filter { episode in
                !self.allEpisodes.contains { $0.id == episode.id }
            }
            allEpisodes.append(contentsOf: newEpisodes)
        } else {
            allEpisodes.removeAll { $0.feedId == feed.id }
            allEpisodes.append(contentsOf: episodes)
        }
        updateFilteredEpisodes(for: feed.id, selectedTab: currentTab)
    }
    
    func clearSavedEpisodes(for feedId: String? = nil) {
           if let feedId = feedId {
               clearPodcastCache(for: feedId)
               
               // Update in-memory arrays
               allEpisodes.removeAll { $0.feedId == feedId }
               currentEpisodes.removeAll { $0.feedId == feedId }
               downloadedEpisodes.removeAll { $0.feedId == feedId }
               favoriteEpisodes.removeAll { $0.feedId == feedId }
           } else {
               // Clear all feeds
               let allFeedIds = Set(allEpisodes.map { $0.feedId })
               allFeedIds.forEach { clearPodcastCache(for: $0) }
               
               // Clear in-memory arrays
               allEpisodes.removeAll()
               currentEpisodes.removeAll()
               downloadedEpisodes.removeAll()
               favoriteEpisodes.removeAll()
           }
           
           // Clear episode cache
           if let feedId = feedId {
               episodeCache.removeValue(forKey: feedId)
           } else {
               episodeCache.removeAll()
           }
           
           // Trigger UI update
           objectWillChange.send()
       }
    
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
            print("DEBUG: RSS parsing - Feed ID: \(feed.id), Title: \(feed.title), Episodes: \(rssParser.episodes.count)")
            
            var updatedFeed = feed
            updatedFeed.title = feed.title
            updatedFeed.descriptionText = rssParser.podcastDescription
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            updatedFeed.episodes = rssParser.episodes
            
            print("DEBUG: RSS parsing - updatedFeed.id: \(updatedFeed.id), episodes count: \(updatedFeed.episodes.count)")
            
            if let artworkUrl = updatedFeed.artworkUrl, let url = URL(string: artworkUrl) {
                self.fetchAndStoreImage(from: url) { imageData in
                    updatedFeed.imageData = imageData
                    os_log("Artwork fetched for feed: %@, image size: %d bytes", log: self.log, type: .info, feed.title, imageData?.count ?? 0)
                    self.completeRSSFeedUpdate(updatedFeed: updatedFeed, completion: completion)
                }
            } else {
                os_log("No artwork URL found for feed: %@", log: self.log, type: .info, feed.title)
                self.completeRSSFeedUpdate(updatedFeed: updatedFeed, completion: completion)
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
    
    private func fetchAndEncodeImage(from url: URL, completion: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                os_log("Error fetching image: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                completion(nil)
                return
            }
            
            let base64EncodedImage = data.base64EncodedString()
            completion(base64EncodedImage)
        }.resume()
    }
    
    private func completeRSSFeedUpdate(updatedFeed: PodcastFeed, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        DispatchQueue.main.async {
            self.updateFeed(updatedFeed)
            completion(.success(updatedFeed))
        }
    }
    
    private func updateFeed(_ updatedFeed: PodcastFeed) {
        // Update the in-memory array of podcast feeds
        if let index = podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
            podcastFeeds[index] = updatedFeed
        } else {
            podcastFeeds.append(updatedFeed)
        }
        
        // Update Core Data
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", updatedFeed.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedFeed = results.first {
                managedFeed.update(from: updatedFeed)
                managedFeed.imageData = updatedFeed.imageData
                if let imageData = updatedFeed.imageData {
                    os_log("Saving image data (%d bytes) for feed: %@", log: log, type: .info, imageData.count, updatedFeed.title)
                } else {
                    os_log("No image data to save for feed: %@", log: log, type: .info, updatedFeed.title)
                }
                try context.save()
                os_log("Updated feed in Core Data: %@", log: log, type: .info, updatedFeed.title)
            } else {
                // If the feed doesn't exist in Core Data, create a new one
                let newManagedFeed = FeedModel(context: context)
                newManagedFeed.update(from: updatedFeed)
                newManagedFeed.imageData = updatedFeed.imageData
                if let imageData = updatedFeed.imageData {
                    os_log("Saving image data (%d bytes) for new feed: %@", log: log, type: .info, imageData.count, updatedFeed.title)
                } else {
                    os_log("No image data to save for new feed: %@", log: log, type: .info, updatedFeed.title)
                }
                try context.save()
                os_log("Created new feed in Core Data: %@", log: log, type: .info, updatedFeed.title)
            }
        } catch {
            os_log("Failed to update/create feed in Core Data: %@", log: log, type: .error, error.localizedDescription)
        }
        
        // Update episodes while preserving existing state (favorites, downloads, progress)
        print("DEBUG: updateFeed - Processing \(updatedFeed.episodes.count) episodes for feed: \(updatedFeed.title)")
        var episodesToSaveToCoreData: [PodcastEpisode] = []
        
        for newEpisode in updatedFeed.episodes {
            if let index = allEpisodes.firstIndex(where: { $0.id == newEpisode.id }) {
                // Preserve existing state when updating episode
                var updatedEpisode = newEpisode
                let existingEpisode = allEpisodes[index]
                updatedEpisode.state = existingEpisode.state  // Preserve all state (favorites, downloads, progress, etc.)
                allEpisodes[index] = updatedEpisode
                print("DEBUG: updateFeed - Updated existing episode: \(newEpisode.title), preserved state: isFavorite=\(existingEpisode.state.isFavorite), isDownloaded=\(existingEpisode.state.isDownloaded)")
                episodesToSaveToCoreData.append(updatedEpisode)
            } else {
                // For new episodes, check Core Data for any existing state
                let context = CoreDataStack.shared.context
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", newEpisode.id)
                
                do {
                    let results = try context.fetch(fetchRequest)
                    if let managedEpisode = results.first {
                        // Episode exists in Core Data, preserve its state
                        var episodeWithState = newEpisode
                        episodeWithState.state.isPlayed = managedEpisode.isPlayed
                        episodeWithState.state.isFavorite = managedEpisode.isFavorite
                        episodeWithState.state.progress = managedEpisode.progress
                        episodeWithState.state.isDownloaded = managedEpisode.isDownloaded
                        allEpisodes.append(episodeWithState)
                        print("DEBUG: updateFeed - Added episode with preserved Core Data state: \(newEpisode.title), isFavorite=\(managedEpisode.isFavorite)")
                        episodesToSaveToCoreData.append(episodeWithState)
                    } else {
                        // Truly new episode - add to allEpisodes and mark for Core Data saving
                        allEpisodes.append(newEpisode)
                        episodesToSaveToCoreData.append(newEpisode)
                        print("DEBUG: updateFeed - Added new episode: \(newEpisode.title)")
                    }
                } catch {
                    print("DEBUG: updateFeed - Error checking Core Data for episode \(newEpisode.title): \(error)")
                    allEpisodes.append(newEpisode)
                    episodesToSaveToCoreData.append(newEpisode)
                }
            }
        }
        print("DEBUG: updateFeed - allEpisodes now contains \(allEpisodes.count) total episodes")
        
        // Save all episodes to Core Data immediately to ensure they're available for future queries
        print("DEBUG: updateFeed - Saving \(episodesToSaveToCoreData.count) episodes to Core Data")
        for episode in episodesToSaveToCoreData {
            saveEpisodeToCoreDataSynchronously(episode)
        }
        
        // Sort allEpisodes to maintain consistent date ordering (newest first)
        allEpisodes.sort { $0.publicationDate > $1.publicationDate }
        
        // Update the favorite and downloaded episode arrays (also sorted)
        favoriteEpisodes = allEpisodes.filter { $0.state.isFavorite }
        downloadedEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        print("DEBUG: updateFeed - Updated favoriteEpisodes to \(favoriteEpisodes.count) episodes")
        print("DEBUG: updateFeed - Updated downloadedEpisodes to \(downloadedEpisodes.count) episodes")
        
        // Update cache with the latest episodes for this feed
        let feedEpisodes = allEpisodes.filter { $0.feedId == updatedFeed.id }
        episodeCache[updatedFeed.id] = removeDuplicatesFromEpisodes(feedEpisodes)
        print("DEBUG: updateFeed - Updated cache with \(feedEpisodes.count) episodes for feed: \(updatedFeed.title)")
        
        // Update currentEpisodes if necessary
        print("DEBUG: updateFeed called for feed: \(updatedFeed.title) with \(updatedFeed.episodes.count) episodes")
        print("DEBUG: Current currentEpisodes.count: \(currentEpisodes.count)")
        print("DEBUG: Current currentEpisodes.first?.feedId: \(currentEpisodes.first?.feedId ?? "nil")")
        print("DEBUG: updatedFeed.id: \(updatedFeed.id)")
        
        if currentEpisodes.first?.feedId == updatedFeed.id {
            print("DEBUG: Updating currentEpisodes for matching feed")
            let filteredEpisodes = allEpisodes.filter { $0.feedId == updatedFeed.id }
            print("DEBUG: Filtered episodes count: \(filteredEpisodes.count)")
            let uniqueEpisodes = removeDuplicatesFromEpisodes(filteredEpisodes)
            currentEpisodes = uniqueEpisodes
        } else {
            print("DEBUG: NOT updating currentEpisodes - feed ID mismatch or empty currentEpisodes")
        }
        
        // Trigger UI update
        DispatchQueue.main.async {
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
    
    func cleanupDuplicateEpisodes() {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        do {
            let allEpisodes = try context.fetch(fetchRequest)
            var uniqueEpisodes = [String: PodcastModel]()
            var duplicatesToDelete = [PodcastModel]()
            
            for episode in allEpisodes {
                if let id = episode.id {
                    if let existing = uniqueEpisodes[id] {
                        // Keep the most recently updated episode
                        if episode.publicationDate ?? Date() > existing.publicationDate ?? Date() {
                            duplicatesToDelete.append(existing)
                            uniqueEpisodes[id] = episode
                        } else {
                            duplicatesToDelete.append(episode)
                        }
                    } else {
                        uniqueEpisodes[id] = episode
                    }
                }
            }
            
            // Delete duplicates
            for duplicate in duplicatesToDelete {
                context.delete(duplicate)
            }
            
            // Save changes
            try context.save()
            print("Cleaned up \(duplicatesToDelete.count) duplicate episodes")
            
            // Refresh allEpisodes array
            self.loadAllEpisodes()
            
        } catch {
            print("Failed to clean up duplicate episodes: \(error)")
        }
    }
    
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.progress = progress
                try context.save()
                
                // Update the in-memory episode
                var updatedEpisode = episode
                updatedEpisode.state.progress = progress
                
                // Preserve existing "finished" status - only mark as finished if progress >= 0.99
                // but don't unmark episodes that were already marked as finished
                if progress >= 0.99 {
                    updatedEpisode.state.isPlayed = true
                } else if !episode.state.isPlayed {
                    // Only update isPlayed to false if it wasn't already marked as finished
                    updatedEpisode.state.isPlayed = false
                }
                
                updateEpisodeInLists(updatedEpisode)
                
                // Update the progress in the episodeProgress dictionary
                episodeProgress[episode.id] = progress
                
                objectWillChange.send()
            } else {
                print("Episode not found in CoreData")
            }
        } catch {
            print("Failed to update episode progress: \(error)")
        }
    }
    
    func markEpisodeAsCompleted(_ episode: PodcastEpisode) {
        var updatedEpisode = episode
        updatedEpisode.state.isPlayed = true
        updatedEpisode.state.progress = 1.0
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        objectWillChange.send()
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
        
        // Update episodeProgress dictionary
        episodeProgress[updatedEpisode.id] = updatedEpisode.state.progress
        
        // Trigger a UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
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
    
    func saveContextIfNeeded() {
        guard hasChanges else { return }
        
        // Perform the save operation on a background thread
        backgroundContext.perform { [weak self] in
            guard let self = self else { return }
            
            do {
                try self.backgroundContext.save()
                
                // If background save is successful, save the main context on the main thread
                DispatchQueue.main.async {
                    do {
                        try self.context.save()
                        self.hasChanges = false
                        print("Core Data context saved successfully")
                    } catch {
                        print("Failed to save main context: \(error)")
                    }
                }
            } catch {
                print("Failed to save background context: \(error)")
            }
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
            
            // Trigger immediate UI update
            DispatchQueue.main.async {
                self.objectWillChange.send()
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
            
            // Trigger immediate UI update
            DispatchQueue.main.async {
                self.objectWillChange.send()
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
           let backgroundContext = CoreDataStack.shared.newBackgroundContext()
           
           backgroundContext.perform {
               let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
               fetchRequest.predicate = self.buildFilteredPredicate(feedId: feed.id, tab: tab)
               fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
               fetchRequest.fetchLimit = self.episodesPerPage
               fetchRequest.fetchOffset = (page - 1) * self.episodesPerPage
               
               // Enable batch faulting for better performance
               fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
               
               do {
                   let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                   
                   // Convert to PodcastEpisode models with preserved state
                   let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                       var episode = managedEpisode.toPodcastEpisode()
                       episode.state.isPlayed = managedEpisode.isPlayed
                       episode.state.progress = managedEpisode.progress
                       episode.state.isFavorite = managedEpisode.isFavorite
                       episode.state.isDownloaded = managedEpisode.isDownloaded
                       return episode
                   }
                   
                   // Check if there are more episodes
                   let countRequest = NSFetchRequest<NSNumber>(entityName: "PodcastModel")
                   countRequest.predicate = fetchRequest.predicate
                   countRequest.resultType = .countResultType
                   let totalCount = try backgroundContext.count(for: countRequest)
                   let hasMore = totalCount > (page * self.episodesPerPage)
                   
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
            
            // First, try to get episodes from in-memory allEpisodes array (faster and more up-to-date)
            let inMemoryEpisodes = allEpisodes.filter { $0.feedId == feedId }
            print("DEBUG: Found \(inMemoryEpisodes.count) episodes in memory for feedId: \(feedId)")
            
            if !inMemoryEpisodes.isEmpty {
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
                
                // Remove duplicates based on compositeID to prevent ForEach issues
                let uniqueEpisodes = self.removeDuplicatesFromEpisodes(filteredEpisodes)
                
                // Update the cache with the latest states if this is the "All" tab
                if selectedTab == 0 {
                    // Cache the full unfiltered episodes with latest state, not the filtered ones
                    episodeCache[feedId] = self.removeDuplicatesFromEpisodes(inMemoryEpisodes)
                    print("DEBUG: Updated cache with \(inMemoryEpisodes.count) episodes for feedId: \(feedId)")
                }
                
                DispatchQueue.main.async {
                    print("DEBUG: Setting currentEpisodes to \(uniqueEpisodes.count) episodes for feedId: \(feedId) (from memory)")
                    self.currentEpisodes = uniqueEpisodes
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
    
    // Helper method to remove duplicate episodes based on compositeID
    private func removeDuplicatesFromEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else {
            print("DEBUG: No episodes to process")
            return []
        }
        
        var seenCompositeIDs = Set<String>()
        var uniqueEpisodes: [PodcastEpisode] = []
        var duplicatesCount = 0
        var duplicatedTitles: [String] = []
        
        print("DEBUG: Starting duplicate removal for \(episodes.count) episodes")
        
        for episode in episodes {
            if !seenCompositeIDs.contains(episode.compositeID) {
                seenCompositeIDs.insert(episode.compositeID)
                uniqueEpisodes.append(episode)
            } else {
                duplicatesCount += 1
                duplicatedTitles.append(episode.title)
                print("DEBUG: Found duplicate episode with compositeID: \(episode.compositeID), title: \(episode.title)")
            }
        }
        
        // Safety check: if we removed too many episodes (more than 80%), fall back to the original approach
        let removalRatio = Double(duplicatesCount) / Double(episodes.count)
        if removalRatio > 0.8 {
            print("WARNING: Duplicate removal removed \(Int(removalRatio * 100))% of episodes. This seems too aggressive. Falling back to ID-based deduplication.")
            return removeDuplicatesByID(episodes)
        }
        
        if duplicatesCount > 0 {
            print("DEBUG: Removed \(duplicatesCount) duplicate episodes from \(episodes.count) total episodes")
            print("DEBUG: Duplicated titles: \(duplicatedTitles)")
        } else {
            print("DEBUG: No duplicates found in \(episodes.count) episodes")
        }
        
        print("DEBUG: Returning \(uniqueEpisodes.count) unique episodes")
        return uniqueEpisodes
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
    
    // Private setter method to safely update currentEpisodes
    private func setCurrentEpisodes(_ episodes: [PodcastEpisode]) {
        let uniqueEpisodes = removeDuplicatesFromEpisodes(episodes)
        currentEpisodes = uniqueEpisodes
    }
    
    func loadAllEpisodesProgress() {
        backgroundContext.perform {
            // Load episode progress here in the background
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                var progress: [String: Double] = [:]
                var updatedAllEpisodes: [PodcastEpisode] = []
                var updatedCurrentEpisodes: [PodcastEpisode] = []

                for managedEpisode in results {
                    if let id = managedEpisode.id {
                        progress[id] = managedEpisode.progress
                        if let index = self.allEpisodes.firstIndex(where: { $0.id == id }) {
                            var updatedEpisode = self.allEpisodes[index]
                            updatedEpisode.state.progress = managedEpisode.progress
                            updatedAllEpisodes.append(updatedEpisode)
                        }
                        if let currentIndex = self.currentEpisodes.firstIndex(where: { $0.id == id }) {
                            var updatedEpisode = self.currentEpisodes[currentIndex]
                            updatedEpisode.state.progress = managedEpisode.progress
                            updatedCurrentEpisodes.append(updatedEpisode)
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.episodeProgress = progress
                    self.allEpisodes = updatedAllEpisodes
                    self.currentEpisodes = updatedCurrentEpisodes
                    self.objectWillChange.send()
                }
            } catch {
                print("Failed to load episode progress: \(error)")
            }
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
