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
        return "\(feedId)_\(id)_\(publicationDate.timeIntervalSince1970)"
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
    @Published var isLoadingMoreEpisodes = false
    @Published var hasMoreEpisodes = true
    private let episodesPerPage = 100
        var currentPage = 1
    
    init(context: NSManagedObjectContext = CoreDataStack.shared.context) {
        self.context = context
        self.backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.backgroundContext.parent = context

        // Perform initial loading asynchronously on a background thread
        Task(priority: .background) {
            await loadInitialData()
        }
    }

    @MainActor
    private func loadInitialData() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.backgroundContext.perform {
                    self.loadSavedData()
                }
            }
            group.addTask {
                await self.backgroundContext.perform {
                    self.loadAllEpisodesProgress()
                }
            }
        }
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
            // Check cache first
            if let cachedEpisodes = episodeCache[feed.id] {
                self.currentEpisodes = cachedEpisodes
                self.objectWillChange.send()
                return
            }
            
            isLoadingEpisodes = true
            
            let context = CoreDataStack.shared.context
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    return episode
                }
                
                if episodes.isEmpty {
                    // If no cached episodes, fetch from RSS
                    fetchRSSFeed(for: feed) { result in
                        switch result {
                        case .success(let updatedFeed):
                            self.saveEpisodesToCoreData(updatedFeed.episodes, for: updatedFeed)
                            self.episodeCache[feed.id] = updatedFeed.episodes
                            
                            DispatchQueue.main.async {
                                self.currentEpisodes = updatedFeed.episodes
                                self.isLoadingEpisodes = false
                                self.objectWillChange.send()
                            }
                        case .failure(let error):
                            print("Failed to fetch episodes from RSS: \(error)")
                            DispatchQueue.main.async {
                                self.isLoadingEpisodes = false
                                self.error = "Failed to load episodes: \(error.localizedDescription)"
                            }
                        }
                    }
                } else {
                    // Use cached episodes
                    self.episodeCache[feed.id] = episodes
                    DispatchQueue.main.async {
                        self.currentEpisodes = episodes
                        self.isLoadingEpisodes = false
                        self.objectWillChange.send()
                    }
                }
            } catch {
                print("Error fetching episodes from CoreData: \(error)")
                DispatchQueue.main.async {
                    self.isLoadingEpisodes = false
                    self.error = "Failed to load episodes: \(error.localizedDescription)"
                }
            }
        }
    
    func loadInitialEpisodes(for feed: PodcastFeed) {
        currentPage = 1
        hasMoreEpisodes = true
        currentEpisodes.removeAll()
        
        switch currentTab {
        case 1: // Favorites
            currentEpisodes = favoriteEpisodes.filter { $0.feedId == feed.id }
                .sorted { $0.publicationDate > $1.publicationDate }
            hasMoreEpisodes = false // No pagination for filtered lists
            
        case 2: // Downloads
            currentEpisodes = downloadedEpisodes.filter { $0.feedId == feed.id }
                .sorted { $0.publicationDate > $1.publicationDate }
            hasMoreEpisodes = false // No pagination for filtered lists
            
        default: // All Episodes (tab 0)
            fetchEpisodes(for: feed) { [weak self] result in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.isLoadingEpisodes = false
                    
                    switch result {
                    case .success(let episodes):
                        self.currentEpisodes = episodes
                        self.objectWillChange.send()
                    case .failure(let error):
                        print("Failed to load initial episodes: \(error)")
                        self.error = "Failed to load episodes: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        DispatchQueue.main.async {
            self.lastPlayedEpisodes[episode.feedId] = episode.id
        }
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
            for feed in podcastFeeds {
                refreshEpisodes(for: feed) { _ in }
            }
            objectWillChange.send()
        }
    
    func sortFeedsAlphabetically() {
        let sortedFeeds = podcastFeeds.sorted { $0.title.lowercased() < $1.title.lowercased() }
        podcastFeedOrder = sortedFeeds.map { $0.id }
        saveFeedOrder()
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
    
    func refreshEpisodeStates() {
        for index in allEpisodes.indices {
            let episode = allEpisodes[index]
            allEpisodes[index].state.isFavorite = favoriteEpisodes.contains(where: { $0.id == episode.id })
            allEpisodes[index].state.isDownloaded = downloadedEpisodes.contains(where: { $0.id == episode.id })
        }
        objectWillChange.send() // Trigger a UI update across all tabs
    }
    
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) {
        if let localFilePath = episode.localFilePath {
            do {
                try FileManager.default.removeItem(atPath: localFilePath)
                print("Successfully deleted local file for episode: \(episode.title)")
            } catch {
                print("Error deleting local file for episode \(episode.title): \(error)")
            }
        }
        
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.isDownloaded = false
                managedEpisode.localFilePath = nil
                try context.save()
                
                var updatedEpisode = episode
                updatedEpisode.state.isDownloaded = false
                updatedEpisode.localFilePath = nil
                updateEpisodeInLists(updatedEpisode)
                
                downloadedEpisodes.removeAll { $0.id == episode.id }
                
                objectWillChange.send()
            }
        } catch {
            print("Error updating CoreData for episode \(episode.title): \(error)")
        }
    }
    
    private func loadSavedData() {
        backgroundContext.perform {
            self.loadPodcastFeeds()
            self.loadDownloadedEpisodes()
            self.loadFavoriteEpisodes()
            self.loadAllEpisodes()
        }
    }
    
    func loadDownloadedEpisodes() {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isDownloaded == %@", NSNumber(value: true))
        
        DispatchQueue.global(qos: .background).async { // Perform fetch on a background thread
            do {
                let results = try context.fetch(fetchRequest)
                let episodes = results.map { $0.toPodcastEpisode() }
                
                DispatchQueue.main.async { // Update UI on the main thread
                    self.downloadedEpisodes = episodes
                    self.objectWillChange.send()
                }
            } catch {
                print("Failed to load downloaded episodes: \(error)")
            }
        }
    }
    
    func loadFavoriteEpisodes() {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isFavorite == %@", NSNumber(value: true))
        
        DispatchQueue.global(qos: .background).async { // Perform fetch on a background thread
            do {
                let results = try context.fetch(fetchRequest)
                let episodes = results.map { $0.toPodcastEpisode() }
                
                DispatchQueue.main.async { // Update UI on the main thread
                    self.favoriteEpisodes = episodes
                    self.objectWillChange.send()
                }
            } catch {
                print("Failed to load favorite episodes: \(error)")
            }
        }
    }
    
    func clearAllPodcastData(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var success = true
        
        // 1. Delete all downloaded podcast files
        group.enter()
        deleteAllDownloadedPodcasts { result in
            if !result {
                success = false
            }
            group.leave()
        }
        
        // 2. Delete all podcast episodes from Core Data
        group.enter()
        deleteAllPodcastEpisodesFromCoreData { result in
            if !result {
                success = false
            }
            group.leave()
        }
        
        // 3. Clear all bookmarks, favorites, and progress from UserDefaults
        group.enter()
        clearAllUserDefaultsData { result in
            if !result {
                success = false
            }
            group.leave()
        }
        
        // 4. Clear all saved episode progress from UserDefaults or other storage
               group.enter()
               clearEpisodeProgressData { result in
                   if !result {
                       success = false
                   }
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
        userDefaults.removeObject(forKey: favoritesKey)
        userDefaults.removeObject(forKey: progressKey)
        userDefaults.removeObject(forKey: episodeStatesKey)
        
        // Remove all keys that start with "PodcastProgress_"
        for key in userDefaults.dictionaryRepresentation().keys {
            if key.hasPrefix("PodcastProgress_") {
                userDefaults.removeObject(forKey: key)
            }
        }
        
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
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            try context.execute(batchDeleteRequest)
            try context.save()
            completion(true)
        } catch {
            print("Error deleting podcast episodes from Core Data: \(error)")
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
                let episodes = managedEpisodes.map { managedEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    return episode
                }
                let downloadedIds = Set(managedEpisodes.compactMap { $0.isDownloaded ? $0.id : nil })
                
                DispatchQueue.main.async {
                    self.allEpisodes = episodes
                    self.downloadedEpisodeIds = downloadedIds
                    os_log("Loaded %d episodes, %d downloaded", log: self.log, type: .info, self.allEpisodes.count, self.downloadedEpisodeIds.count)
                }
            } catch {
                DispatchQueue.main.async {
                    os_log("Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }
    
    
    func fetchPodcastFeeds() {
            isLoading = true
            
            // Fetch from CoreData
            let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            
            do {
                let managedFeeds = try context.fetch(fetchRequest)
                podcastFeeds = managedFeeds.map { $0.toPodcastFeed() }
                os_log("Loaded %d podcast feeds from Core Data", log: log, type: .info, podcastFeeds.count)
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
                    
                    for feed in self.podcastFeeds {
                        self.fetchRSSFeed(for: feed) { _ in }
                    }
                    
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
                   self.currentEpisodes = cachedEpisodes
                   self.isLoadingEpisodes = false
                   completion(.success(cachedEpisodes))
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
                                       self.currentEpisodes = paginatedEpisodes
                                       self.hasMoreEpisodes = updatedFeed.episodes.count > self.episodesPerPage
                                       completion(.success(paginatedEpisodes))
                                   }
                                   
                               case .failure(let error):
                                   print("Failed to fetch episodes from RSS: \(error)")
                                   completion(.failure(error))
                               }
                           }
                       } else {
                           // Update current episodes based on page
                           if self.currentPage == 1 {
                               self.currentEpisodes = episodes
                           } else {
                               self.currentEpisodes.append(contentsOf: episodes)
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
           guard !isLoadingMoreEpisodes && hasMoreEpisodes else { return }
           
           isLoadingMoreEpisodes = true
           currentPage += 1
           
           fetchEpisodesInBatches(for: feed, page: currentPage) { [weak self] result in
               guard let self = self else { return }
               
               DispatchQueue.main.async {
                   self.isLoadingMoreEpisodes = false
                   
                   switch result {
                   case .success(let newEpisodes):
                       if newEpisodes.isEmpty {
                           self.hasMoreEpisodes = false
                           self.currentPage -= 1 // Revert page increment
                       } else {
                           self.currentEpisodes.append(contentsOf: newEpisodes)
                       }
                       completion(.success(newEpisodes))
                       
                   case .failure(let error):
                       self.currentPage -= 1 // Revert page increment on failure
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
            
            var updatedFeed = feed
            updatedFeed.title = feed.title
            updatedFeed.descriptionText = rssParser.podcastDescription
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            updatedFeed.episodes = rssParser.episodes
            
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
        
        // Update episodes
        for episode in updatedFeed.episodes {
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
            } else {
                allEpisodes.append(episode)
            }
        }
        
        // Update currentEpisodes if necessary
        if currentEpisodes.first?.feedId == updatedFeed.id {
            currentEpisodes = allEpisodes.filter { $0.feedId == updatedFeed.id }
        }
        
        // Trigger UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
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
        
        // Update favorite episodes
        if updatedEpisode.state.isFavorite {
            if !favoriteEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                favoriteEpisodes.append(updatedEpisode)
            } else if let index = favoriteEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
                favoriteEpisodes[index] = updatedEpisode
            }
        } else {
            favoriteEpisodes.removeAll { $0.id == updatedEpisode.id }
        }
        
        // Update downloaded episodes
        if updatedEpisode.state.isDownloaded {
            if !downloadedEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                downloadedEpisodes.append(updatedEpisode)
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
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        context.performAndWait {
            do {
                let results = try context.fetch(fetchRequest)
                let managedEpisode: PodcastModel
                
                if let existingEpisode = results.first {
                    managedEpisode = existingEpisode
                } else {
                    managedEpisode = PodcastModel(context: context)
                    managedEpisode.id = episode.id
                    managedEpisode.title = episode.title
                    managedEpisode.feedId = episode.feedId
                    managedEpisode.descriptionText = episode.descriptionText
                    managedEpisode.audioUrl = episode.audioUrl
                    managedEpisode.publicationDate = episode.publicationDate
                    managedEpisode.duration = episode.duration
                }
                
                // Toggle favorite status
                managedEpisode.isFavorite.toggle()
                let newFavoriteStatus = managedEpisode.isFavorite
                
                // Save context immediately
                try context.save()
                
                // Update in-memory state on main thread
                DispatchQueue.main.async {
                    // Update the episode in all relevant collections
                    var updatedEpisode = episode
                    updatedEpisode.state.isFavorite = newFavoriteStatus
                    
                    // Update allEpisodes
                    if let index = self.allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                        self.allEpisodes[index] = updatedEpisode
                    }
                    
                    // Update favoriteEpisodes
                    if newFavoriteStatus {
                        if !self.favoriteEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                            self.favoriteEpisodes.append(updatedEpisode)
                        }
                    } else {
                        self.favoriteEpisodes.removeAll { $0.id == updatedEpisode.id }
                    }
                    
                    // Clear cache and update filtered episodes
                    self.episodeCache.removeValue(forKey: episode.feedId)
                    self.updateFilteredEpisodes(for: episode.feedId, selectedTab: self.currentTab)
                    
                    // Force UI update
                    self.objectWillChange.send()
                }
            } catch {
                print("Failed to toggle favorite status: \(error)")
            }
        }
    }
    
    func updateEpisodeDownloadStatus(_ episode: PodcastEpisode, isDownloaded: Bool) {
        let context = CoreDataStack.shared.context
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.isDownloaded = isDownloaded
                try context.save()
                
                var updatedEpisode = episode
                updatedEpisode.state.isDownloaded = isDownloaded
                
                if isDownloaded {
                    if !downloadedEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                        downloadedEpisodes.append(updatedEpisode)
                    }
                } else {
                    downloadedEpisodes.removeAll { $0.id == updatedEpisode.id }
                }
                
                updateEpisodeInLists(updatedEpisode)
                objectWillChange.send()
            }
        } catch {
            print("Failed to update episode download status: \(error)")
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
        // Update in allEpisodes
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
            }
            
            // Update in currentEpisodes
            if let index = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[index] = episode
            }
        // Update favoriteEpisodes
        if episode.state.isFavorite {
            if !favoriteEpisodes.contains(where: { $0.id == episode.id }) {
                favoriteEpisodes.append(episode)
            } else if let index = favoriteEpisodes.firstIndex(where: { $0.id == episode.id }) {
                favoriteEpisodes[index] = episode
            }
        } else {
            favoriteEpisodes.removeAll { $0.id == episode.id }
        }
        
        // Update downloadedEpisodes
        if episode.state.isDownloaded {
            if !downloadedEpisodes.contains(where: { $0.id == episode.id }) {
                downloadedEpisodes.append(episode)
            } else if let index = downloadedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                downloadedEpisodes[index] = episode
            }
        } else {
            downloadedEpisodes.removeAll { $0.id == episode.id }
        }
        
        updateFilteredEpisodes(for: episode.feedId, selectedTab: currentTab)
        objectWillChange.send()
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
                                var updatedEpisode = episode
                                updatedEpisode.state.isDownloaded = true
                                updatedEpisode.localFilePath = destinationUrl.path
                                
                                // Update in all collections
                                if let index = self.allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                                    self.allEpisodes[index] = updatedEpisode
                                }
                                
                                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                                    self.currentEpisodes[index] = updatedEpisode
                                }
                                
                                if !self.downloadedEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                                    self.downloadedEpisodes.append(updatedEpisode)
                                }
                                
                                // Clear cache for immediate refresh
                                self.episodeCache.removeValue(forKey: episode.feedId)
                                
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

    func updateFilteredEpisodes(for feedId: String, selectedTab: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.currentTab = selectedTab
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let filteredEpisodes: [PodcastEpisode]
            
            switch selectedTab {
            case 0: // All Episodes
                // Show all episodes for this feed
                filteredEpisodes = self.allEpisodes.filter { $0.feedId == feedId }
            
            case 1: // Favorites
                // Only show episodes that are marked as favorite for this feed
                filteredEpisodes = self.favoriteEpisodes.filter { $0.feedId == feedId }
            
            case 2: // Downloads
                // Only show episodes that are downloaded for this feed
                filteredEpisodes = self.downloadedEpisodes.filter { $0.feedId == feedId }
            
            default:
                filteredEpisodes = self.allEpisodes.filter { $0.feedId == feedId }
            }
            
            // Sort episodes by publication date (newest first)
            let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
            
            DispatchQueue.main.async {
                self.currentEpisodes = sortedEpisodes
                self.objectWillChange.send()
            }
        }
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
