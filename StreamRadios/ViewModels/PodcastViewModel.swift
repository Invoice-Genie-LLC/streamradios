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
    @Published var preloadedEpisodes: [String: [PodcastEpisode]] = [:]

    
    init(context: NSManagedObjectContext = CoreDataStack.shared.context) {
        self.context = context
        self.backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.backgroundContext.parent = context
        
        // Perform initial loading asynchronously
        backgroundContext.perform { [weak self] in
            guard let self = self else { return }
            
            self.loadSavedData()
            self.loadAllEpisodesProgress()
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    func preloadEpisodesForAllFeeds() {
            for feed in podcastFeeds {
                fetchEpisodes(for: feed) { result in
                    switch result {
                    case .success(let episodes):
                        DispatchQueue.main.async {
                            self.preloadedEpisodes[feed.id] = episodes
                        }
                    case .failure(let error):
                        print("Failed to preload episodes for feed \(feed.title): \(error)")
                    }
                }
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
    
    func sortFeedsAlphabetically() {
            let sortedFeeds = podcastFeeds.sorted { $0.title.lowercased() < $1.title.lowercased() }
            podcastFeedOrder = sortedFeeds.map { $0.id }
            saveFeedOrder()
        }

    func moveFeed(from source: IndexSet, to destination: Int) {
        podcastFeedOrder.move(fromOffsets: source, toOffset: destination)
        saveFeedOrder()
    }
    
    private func saveFeedOrder() {
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
                
                // Update in currentEpisodes if present
                if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    currentEpisodes[currentIndex] = updatedEpisode
                }
                
                // Update in Core Data
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
                existingFeed.imageData = feed.imageData
                os_log("Updated existing podcast feed: %@", log: log, type: .info, feed.title)
            } else {
                let managedFeed = FeedModel(context: context)
                managedFeed.update(from: feed)
                managedFeed.imageData = feed.imageData
                podcastFeeds.append(feed)
                podcastFeedOrder.append(feed.id) // Add new feed ID to the order
                os_log("Added new podcast feed: %@", log: log, type: .info, feed.title)
            }
            
            try context.save()
            
            // Save to CloudKit
            dataStore.savePodcastFeedToCloudKit(feed) { [weak self] success, recordID in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if success {
                        os_log("Saved podcast feed to CloudKit: %@", log: self.log, type: .info, feed.title)
                    } else {
                        os_log("Failed to save podcast feed to CloudKit: %@", log: self.log, type: .error, feed.title)
                    }
                    
                    // Fetch RSS feed for the newly added podcast
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
    
    func updateEpisode(_ updatedEpisode: PodcastEpisode) {
        if let index = allEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            allEpisodes[index] = updatedEpisode
        }
        if let index = currentEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            currentEpisodes[index] = updatedEpisode
        }
        saveEpisodeToCoreData(updatedEpisode)
        objectWillChange.send()
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
        // Delete the local file
        if let localFilePath = episode.localFilePath {
            do {
                try FileManager.default.removeItem(atPath: localFilePath)
                print("Successfully deleted local file for episode: \(episode.title)")
            } catch {
                print("Error deleting local file for episode \(episode.title): \(error)")
            }
        }
        
        // Update the episode state
        if var updatedEpisode = allEpisodes.first(where: { $0.id == episode.id }) {
            updatedEpisode.state.isDownloaded = false
            updatedEpisode.localFilePath = nil
            // Preserve the favorite status
            updatedEpisode.state.isFavorite = episode.state.isFavorite
            updateEpisodeInLists(updatedEpisode)
        }
        
        // Remove from downloadedEpisodes
        downloadedEpisodes.removeAll { $0.id == episode.id }
        
        // Update Core Data
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedEpisode = results.first {
                managedEpisode.isDownloaded = false
                managedEpisode.localFilePath = nil
                // Preserve the favorite status
                managedEpisode.isFavorite = episode.state.isFavorite
                try context.save()
                print("Successfully updated Core Data for episode: \(episode.title)")
            }
        } catch {
            print("Error updating Core Data for episode \(episode.title): \(error)")
        }
        
        // Refresh the current episodes list
        updateFilteredEpisodes(for: episode.feedId, selectedTab: currentTab)
        
        objectWillChange.send()
    }
    
    func loadSavedData() {
        loadPodcastFeeds()
        loadDownloadedEpisodes()
        loadFavoriteEpisodes()
        loadAllEpisodes()
    }
    
    private func loadDownloadedEpisodes() {
            backgroundContext.perform { [weak self] in
                guard let self = self else { return }
                
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
                
                do {
                    let managedEpisodes = try self.backgroundContext.fetch(fetchRequest)
                    let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                    
                    DispatchQueue.main.async {
                        self.downloadedEpisodes = episodes
                        os_log("Loaded %d downloaded episodes from Core Data", log: self.log, type: .info, self.downloadedEpisodes.count)
                    }
                } catch {
                    DispatchQueue.main.async {
                        os_log("Failed to load downloaded episodes: %@", log: self.log, type: .error, error.localizedDescription)
                    }
                }
            }
        }
    
    func loadFavoriteEpisodes() {
            backgroundContext.perform { [weak self] in
                guard let self = self else { return }
                
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "isFavorite == YES")
                
                do {
                    let managedEpisodes = try self.backgroundContext.fetch(fetchRequest)
                    let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                    
                    DispatchQueue.main.async {
                        self.favoriteEpisodes = episodes
                        os_log("Loaded %d favorite episodes from Core Data", log: self.log, type: .info, self.favoriteEpisodes.count)
                    }
                } catch {
                    DispatchQueue.main.async {
                        os_log("Failed to load favorite episodes: %@", log: self.log, type: .error, error.localizedDescription)
                    }
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
        if let preloadedEpisodes = preloadedEpisodes[feed.id] {
                   completion(.success(preloadedEpisodes))
                   return
               }
        os_log("Fetching episodes for feed: %@", log: log, type: .info, feed.title)
        isLoading = true
        fetchRSSFeed(for: feed) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let parsedFeed):
                    os_log("Successfully fetched episodes for feed: %@", log: self.log, type: .info, feed.title)
                    self.updateEpisodes(for: parsedFeed)
                    self.updateFilteredEpisodes(for: feed.id, selectedTab: self.currentTab)
                    completion(.success(parsedFeed.episodes))
                case .failure(let error):
                    os_log("Failed to fetch episodes for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                    self.error = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }
    
    
    private func updateEpisodes(for feed: PodcastFeed) {
            var updatedEpisodes = [PodcastEpisode]()
            var seenIds = Set<String>()
            
            for var episode in feed.episodes {
                if seenIds.contains(episode.id) {
                    episode.id = UUID().uuidString
                }
                seenIds.insert(episode.id)
                
                // Validate and correct duration
                episode.duration = max(episode.duration, 0)
                
                if let existingIndex = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    var existingEpisode = allEpisodes[existingIndex]
                    if existingEpisode.state.isDownloaded {
                        episode.state.isDownloaded = true
                        episode.localFilePath = existingEpisode.localFilePath
                    }
                    
                    existingEpisode = episode
                    allEpisodes[existingIndex] = existingEpisode
                    updatedEpisodes.append(existingEpisode)
                } else {
                    allEpisodes.append(episode)
                    updatedEpisodes.append(episode)
                }
            }
            
            currentEpisodes = allEpisodes.filter { $0.feedId == feed.id }
            
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
            
            os_log("RSS feed data received for feed: %@", log: self.log, type: .info, feed.title)
            
            let rssParser = RSSParser(data: data, feedId: feed.id)
            rssParser.parse()
            
            var updatedFeed = feed
            updatedFeed.title = feed.title
            updatedFeed.descriptionText = rssParser.podcastDescription
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            updatedFeed.episodes = rssParser.episodes
            
            if let artworkUrl = updatedFeed.artworkUrl, let url = URL(string: artworkUrl) {
                        self.fetchAndStoreImage(from: url) { imageData in
                            updatedFeed.imageData = imageData
                            self.completeRSSFeedUpdate(updatedFeed: updatedFeed, completion: completion)
                        }
                    } else {
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
          episodeProgress[episode.id] = progress
          var updatedEpisode = episode
          updatedEpisode.state.progress = progress
          updateEpisodeInLists(updatedEpisode)
          saveEpisodeToCoreData(updatedEpisode)
          saveContextIfNeeded()
      }
    
    func markEpisodeAsCompleted(_ episode: PodcastEpisode) {
        var updatedEpisode = episode
        updatedEpisode.state.isPlayed = true
        updatedEpisode.state.progress = 1.0
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        objectWillChange.send()
    }
    
    func updateEpisodePlayStatus(_ episode: PodcastEpisode, isPlayed: Bool) {
        var updatedEpisode = episode
        updatedEpisode.state.isPlayed = isPlayed
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
    }
    
    func resetEpisodeProgress(_ episode: PodcastEpisode) -> PodcastEpisode {
        var updatedEpisode = episode
        updatedEpisode.state.progress = 0.0
        updatedEpisode.state.isPlayed = false
        
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        episodeProgress[episode.id] = 0.0
        
        updateFilteredEpisodes(for: episode.feedId, selectedTab: currentTab)
        
        objectWillChange.send()
        
        return updatedEpisode
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
        var updatedEpisode = episode
        updatedEpisode.state.isFavorite.toggle()
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
    }
    
    private func saveEpisodeToCoreData(_ episode: PodcastEpisode) {
        backgroundContext.perform { [weak self] in
            guard let self = self else { return }
            
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
            
            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                let managedEpisode: PodcastModel
                
                if let existingEpisode = results.first {
                    managedEpisode = existingEpisode
                } else {
                    managedEpisode = PodcastModel(context: self.backgroundContext)
                }
                
                managedEpisode.update(from: episode)
                try self.backgroundContext.save()
                
                DispatchQueue.main.async {
                    print("Successfully saved episode state to Core Data: \(episode.title)")
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to save episode to Core Data: \(error)")
                }
            }
        }
    }
    
    func getProgress(for episode: PodcastEpisode) -> Double {
        return episodeProgress[episode.id] ?? 0.0
    }
    
    private func updateEpisodeInLists(_ episode: PodcastEpisode) {
        // Update in allEpisodes
        if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
            allEpisodes[index] = episode
        }
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
                
                // Remove any existing file
                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try FileManager.default.removeItem(at: destinationUrl)
                }
                
                try FileManager.default.moveItem(at: localUrl, to: destinationUrl)
                
                DispatchQueue.main.async {
                    var updatedEpisode = episode
                    updatedEpisode.state.isDownloaded = true
                    updatedEpisode.localFilePath = destinationUrl.path
                    
                    self.updateEpisodeInLists(updatedEpisode)
                    self.saveEpisodeToCoreData(updatedEpisode)
                    self.downloadProgress.removeValue(forKey: episode.id)
                    completion(.success(updatedEpisode))
                }
            } catch {
                DispatchQueue.main.async {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    completion(.failure(error))
                }
            }
        }
        
        // Set up progress tracking
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
    
    func updateFilteredEpisodes(for feedId: String, selectedTab: Int) {
        currentTab = selectedTab
        
        refreshEpisodeStates() // Refresh states before filtering
        
        let allFeedEpisodes = allEpisodes.filter { $0.feedId == feedId }
        
        switch selectedTab {
        case 0: // All
            currentEpisodes = allFeedEpisodes
        case 1: // Favorite
            currentEpisodes = favoriteEpisodes.filter { $0.feedId == feedId }
        case 2: // Downloads
            currentEpisodes = downloadedEpisodes.filter { $0.feedId == feedId }
        default:
            currentEpisodes = allFeedEpisodes
        }
        
        currentEpisodes.sort { $0.publicationDate > $1.publicationDate }
        objectWillChange.send() // Ensure UI update
    }
    
    func loadAllEpisodesProgress() {
            backgroundContext.perform { [weak self] in
                guard let self = self else { return }
                
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
                        os_log("Loaded progress for %d episodes", log: self.log, type: .info, self.episodeProgress.count)
                        self.objectWillChange.send()
                    }
                } catch {
                    DispatchQueue.main.async {
                        os_log("Failed to load episode progress: %@", log: self.log, type: .error, error.localizedDescription)
                    }
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
