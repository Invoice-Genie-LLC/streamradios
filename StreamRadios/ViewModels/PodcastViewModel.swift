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
     var notificationCenter: NotificationCenterProtocol
    private var lastFetchTimes: [String: Date] = [:]
        private var lastEpisodeLoadTimes: [String: Date] = [:]
        private let fetchInterval: TimeInterval = 3600 // 1 hour
        private let loadInterval: TimeInterval = 300
    
    init(context: NSManagedObjectContext = CoreDataStack.shared.context,
             notificationCenter: NotificationCenterProtocol = UNUserNotificationCenter.current()) {
            self.context = context
            self.notificationCenter = notificationCenter
            self.backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            self.backgroundContext.parent = context

            // Load data from UserDefaults
            loadUserDefaultsData()

            // Perform initial loading asynchronously
            Task {
                await loadInitialData()
            }
        }
    
    private func loadUserDefaultsData() {
           // Load data that's still stored in UserDefaults
           if let lastPlayed = userDefaults.dictionary(forKey: "LastPlayedEpisodes") as? [String: String] {
               lastPlayedEpisodes = lastPlayed
           }
           podcastFeedOrder = userDefaults.stringArray(forKey: "PodcastFeedOrder") ?? []
           // Add any other UserDefaults data that needs to be loaded
       }

    @MainActor
        private func loadInitialData() async {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadSavedData() }
                group.addTask { await self.loadAllEpisodesProgress() }
                group.addTask { await self.loadCoreDataEntities() }
            }
            
            self.objectWillChange.send()
        }
    
    @MainActor
        private func loadSavedData() {
            // This method now focuses on loading data that's not in Core Data
            loadPodcastFeedOrder()
            // Any other non-Core Data loading operations
        }
    
    @MainActor
         func loadAllEpisodesProgress() {
            // Load episode progress from Core Data instead of UserDefaults
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let results = try context.fetch(fetchRequest)
                for episode in results {
                    if let id = episode.id {
                        episodeProgress[id] = episode.progress
                    }
                }
            } catch {
                os_log("Failed to load episode progress: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    
    @MainActor
        private func loadCoreDataEntities() async {
            // Load podcast feeds
            let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            do {
                let managedFeeds = try context.fetch(feedFetchRequest)
                podcastFeeds = managedFeeds.map { $0.toPodcastFeed() }
            } catch {
                os_log("Failed to load podcast feeds: %@", log: log, type: .error, error.localizedDescription)
            }

            // Load all episodes
            let episodeFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let managedEpisodes = try context.fetch(episodeFetchRequest)
                allEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                
                // Update other episode-related properties
                downloadedEpisodes = allEpisodes.filter { $0.state.isDownloaded }
                favoriteEpisodes = allEpisodes.filter { $0.state.isFavorite }
                downloadedEpisodeIds = Set(downloadedEpisodes.map { $0.id })
            } catch {
                os_log("Failed to load episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    
    private func loadPodcastFeedOrder() {
            if let orderData = UserDefaults.standard.data(forKey: "PodcastFeedOrder"),
               let order = try? JSONDecoder().decode([String].self, from: orderData) {
                podcastFeedOrder = order
            } else {
                podcastFeedOrder = podcastFeeds.map { $0.id }
            }
        }
    
    func checkForNewEpisodes(for feed: PodcastFeed, completion: @escaping (Bool, [PodcastEpisode]) -> Void) {
        fetchRSSFeed(for: feed) { result in
            switch result {
            case .success(let updatedFeed):
                let existingEpisodes = Set(self.allEpisodes.filter { $0.feedId == feed.id }.map { $0.id })
                let newEpisodes = updatedFeed.episodes.filter { !existingEpisodes.contains($0.id) }
                
                if !newEpisodes.isEmpty {
                    DispatchQueue.main.async {
                        self.allEpisodes.append(contentsOf: newEpisodes)
                        self.updateFilteredEpisodes(for: feed.id, selectedTab: self.currentTab)
                        self.saveEpisodesToUserDefaults(self.allEpisodes.filter { $0.feedId == feed.id }, for: feed.id)
                        self.objectWillChange.send()
                    }
                    completion(true, newEpisodes)
                } else {
                    completion(false, [])
                }
                
            case .failure(let error):
                os_log("Failed to check for new episodes: %@", log: self.log, type: .error, error.localizedDescription)
                completion(false, [])
            }
        }
    }
    
    func scheduleEpisodeChecks() {
        for feed in podcastFeeds {
            scheduleCheck(for: feed)
        }
    }

     func scheduleCheck(for feed: PodcastFeed) {
        let checkInterval: TimeInterval = 3600 // Check every hour, adjust as needed
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + checkInterval) { [weak self] in
            guard let self = self else { return }
            
            self.checkForNewEpisodes(for: feed) { hasNewEpisodes, newEpisodes in
                if hasNewEpisodes {
                    self.sendNotification(for: feed, newEpisodes: newEpisodes)
                }
                self.scheduleCheck(for: feed) // Schedule next check
            }
        }
    }
    
    func sendNotification(for feed: PodcastFeed, newEpisodes: [PodcastEpisode]) {
        let content = UNMutableNotificationContent()
        content.title = "New Episodes Available"
        content.body = "\(newEpisodes.count) new episode(s) available for \(feed.title)"
        content.sound = .default
        content.userInfo = ["feedId": feed.id]
           
           let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
           
           notificationCenter.add(request) { error in
               if let error = error {
                   print("Error sending notification: \(error.localizedDescription)")
               }
           }
       }
    
    
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        DispatchQueue.main.async {
            self.lastPlayedEpisodes[episode.feedId] = episode.id
            self.saveLastPlayedEpisodes() // Ensure this is also on the main thread
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
    
    private func saveLastPlayedEpisodes() {
        DispatchQueue.main.async {
            UserDefaults.standard.set(self.lastPlayedEpisodes, forKey: "LastPlayedEpisodes")
        }
    }

    
    private func loadLastPlayedEpisodes() {
        if let saved = UserDefaults.standard.dictionary(forKey: "LastPlayedEpisodes") as? [String: String] {
            DispatchQueue.main.async {
                self.lastPlayedEpisodes = saved
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
            os_log("Fetching episodes for feed: %@", log: log, type: .info, feed.title)
            isLoadingEpisodes = true

            if let savedEpisodes = loadEpisodesFromUserDefaults(for: feed.id) {
                os_log("Loaded episodes from UserDefaults for feed: %@", log: log, type: .info, feed.title)
                let updatedEpisodes = applyStoredStatuses(to: savedEpisodes, feedId: feed.id)
                updateEpisodes(updatedEpisodes, for: feed)
                isLoadingEpisodes = false
                completion(.success(updatedEpisodes))
                
                // Fetch new episodes in the background
                fetchNewEpisodes(for: feed)
                
            } else {
                // If no saved episodes, fetch from RSS
                fetchRSSFeed(for: feed) { result in
                    DispatchQueue.main.async {
                        self.isLoadingEpisodes = false
                        switch result {
                        case .success(let parsedFeed):
                            os_log("Successfully fetched episodes for feed: %@", log: self.log, type: .info, feed.title)
                            let updatedEpisodes = self.applyStoredStatuses(to: parsedFeed.episodes, feedId: feed.id)
                            self.updateEpisodes(updatedEpisodes, for: feed)
                            self.saveEpisodesToUserDefaults(updatedEpisodes, for: feed.id)
                            self.saveEpisodeStatuses(updatedEpisodes, for: feed.id)
                            completion(.success(updatedEpisodes))
                        case .failure(let error):
                            os_log("Failed to fetch episodes for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                            self.error = error.localizedDescription
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    
    private func applyStoredStatuses(to episodes: [PodcastEpisode], feedId: String) -> [PodcastEpisode] {
            let bookmarkStatus = loadBookmarkStatus(for: feedId)
            let downloadStatus = loadDownloadStatus(for: feedId)
            
            return episodes.map { episode in
                var updatedEpisode = episode
                updatedEpisode.state.isFavorite = bookmarkStatus[episode.id] ?? false
                updatedEpisode.state.isDownloaded = downloadStatus[episode.id] ?? false
                return updatedEpisode
            }
        }
    
    private func saveEpisodeStatuses(_ episodes: [PodcastEpisode], for feedId: String) {
            let bookmarkStatus = episodes.reduce(into: [String: Bool]()) { $0[$1.id] = $1.state.isFavorite }
            let downloadStatus = episodes.reduce(into: [String: Bool]()) { $0[$1.id] = $1.state.isDownloaded }
            
            saveBookmarkStatus(bookmarkStatus, for: feedId)
            saveDownloadStatus(downloadStatus, for: feedId)
        }
    
    private func loadBookmarkStatus(for feedId: String) -> [String: Bool] {
            return userDefaults.dictionary(forKey: bookmarkStatusKey(for: feedId)) as? [String: Bool] ?? [:]
        }

        private func saveBookmarkStatus(_ status: [String: Bool], for feedId: String) {
            userDefaults.set(status, forKey: bookmarkStatusKey(for: feedId))
        }

        private func loadDownloadStatus(for feedId: String) -> [String: Bool] {
            return userDefaults.dictionary(forKey: downloadStatusKey(for: feedId)) as? [String: Bool] ?? [:]
        }

        private func saveDownloadStatus(_ status: [String: Bool], for feedId: String) {
            userDefaults.set(status, forKey: downloadStatusKey(for: feedId))
        }

        private func bookmarkStatusKey(for feedId: String) -> String {
            return "\(bookmarkStatusKey)_\(feedId)"
        }

        private func downloadStatusKey(for feedId: String) -> String {
            return "\(downloadStatusKey)_\(feedId)"
        }
    
    private func fetchNewEpisodes(for feed: PodcastFeed) {
            fetchRSSFeed(for: feed) { result in
                switch result {
                case .success(let parsedFeed):
                    DispatchQueue.main.async {
                        let newEpisodes = self.mergeNewEpisodes(parsedFeed.episodes, with: self.allEpisodes.filter { $0.feedId == feed.id })
                        self.updateEpisodes(newEpisodes, for: feed)
                        self.saveEpisodesToUserDefaults(newEpisodes, for: feed.id)
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
    
    
    private func updateEpisodes(_ episodes: [PodcastEpisode], for feed: PodcastFeed) {
           allEpisodes.removeAll { $0.feedId == feed.id }
           allEpisodes.append(contentsOf: episodes)
           updateFilteredEpisodes(for: feed.id, selectedTab: currentTab)
       }
    
    func loadEpisodesFromUserDefaults(for feedId: String) -> [PodcastEpisode]? {
        // Instead of loading from UserDefaults, load from Core Data
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        
        do {
            let managedEpisodes = try context.fetch(fetchRequest)
            return managedEpisodes.map { $0.toPodcastEpisode() }
        } catch {
            print("Failed to load episodes: \(error)")
            return nil
        }
    }
    
    func loadEpisodes(for feed: PodcastFeed, force: Bool = false, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        let now = Date()
        if !force, let lastLoadTime = lastEpisodeLoadTimes[feed.id], now.timeIntervalSince(lastLoadTime) < loadInterval {
            os_log("Using cached episodes for feed: %@", log: log, type: .info, feed.title)
            completion(.success(currentEpisodes.filter { $0.feedId == feed.id }))
            return
        }
        
        os_log("Loading episodes for feed: %@", log: log, type: .info, feed.title)
        isLoadingEpisodes = true
        
        if let savedEpisodes = loadEpisodesFromUserDefaults(for: feed.id) {
            os_log("Loaded episodes from UserDefaults for feed: %@", log: log, type: .info, feed.title)
            let updatedEpisodes = applyStoredStatuses(to: savedEpisodes, feedId: feed.id)
            updateEpisodes(updatedEpisodes, for: feed)
            isLoadingEpisodes = false
            completion(.success(updatedEpisodes))
            
            // Fetch new episodes in the background
            fetchNewEpisodes(for: feed)
        } else {
            fetchRSSFeed(for: feed) { result in
                DispatchQueue.main.async {
                    self.isLoadingEpisodes = false
                    switch result {
                    case .success(let parsedFeed):
                        os_log("Successfully fetched episodes for feed: %@", log: self.log, type: .info, feed.title)
                        let updatedEpisodes = self.applyStoredStatuses(to: parsedFeed.episodes, feedId: feed.id)
                        self.updateEpisodes(updatedEpisodes, for: feed)
                        self.saveEpisodesToUserDefaults(updatedEpisodes, for: feed.id)
                        self.saveEpisodeStatuses(updatedEpisodes, for: feed.id)
                        completion(.success(updatedEpisodes))
                    case .failure(let error):
                        os_log("Failed to fetch episodes for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                        self.error = error.localizedDescription
                        completion(.failure(error))
                    }
                }
            }
        }
        
        lastEpisodeLoadTimes[feed.id] = now
    }
    
    func saveEpisodesToUserDefaults(_ episodes: [PodcastEpisode], for feedId: String) {
        // Instead of saving to UserDefaults, save to Core Data
        for episode in episodes {
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
                managedEpisode.update(from: episode)
            } catch {
                print("Failed to save episode: \(error)")
            }
        }
        
        do {
            try context.save()
        } catch {
            print("Failed to save context: \(error)")
        }
    }
    
    private func episodeListKey(for feedId: String) -> String {
            return "\(episodeListKey)_\(feedId)"
        }
    
    func clearSavedEpisodes(for feedId: String? = nil) {
            if let feedId = feedId {
                userDefaults.removeObject(forKey: episodeListKey(for: feedId))
                userDefaults.removeObject(forKey: bookmarkStatusKey(for: feedId))
                userDefaults.removeObject(forKey: downloadStatusKey(for: feedId))
            } else {
                let allKeys = userDefaults.dictionaryRepresentation().keys
                for key in allKeys where key.hasPrefix(episodeListKey) || key.hasPrefix(bookmarkStatusKey) || key.hasPrefix(downloadStatusKey) {
                    userDefaults.removeObject(forKey: key)
                }
            }
        }
    
    func fetchRSSFeed(for feed: PodcastFeed, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        let now = Date()
        if let lastFetchTime = lastFetchTimes[feed.id], now.timeIntervalSince(lastFetchTime) < fetchInterval {
            os_log("Using cached RSS feed for: %@", log: log, type: .info, feed.title)
            completion(.success(feed))
            return
        }
        
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
            
            self.lastFetchTimes[feed.id] = now
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
        if let index = podcastFeeds.firstIndex(where: { $0.id == updatedFeed.id }) {
            podcastFeeds[index] = updatedFeed
        } else {
            podcastFeeds.append(updatedFeed)
        }
        
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", updatedFeed.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let managedFeed = results.first {
                managedFeed.update(from: updatedFeed)
                if let existingFeed = podcastFeeds.first(where: { $0.id == updatedFeed.id }),
                   existingFeed.imageData != updatedFeed.imageData {
                    managedFeed.imageData = updatedFeed.imageData
                    if let imageData = updatedFeed.imageData {
                        os_log("Saving new image data (%d bytes) for feed: %@", log: log, type: .info, imageData.count, updatedFeed.title)
                    }
                }
                try context.save()
                os_log("Updated feed in Core Data: %@", log: log, type: .info, updatedFeed.title)
            } else {
                let newManagedFeed = FeedModel(context: context)
                newManagedFeed.update(from: updatedFeed)
                newManagedFeed.imageData = updatedFeed.imageData
                if let imageData = updatedFeed.imageData {
                    os_log("Saving image data (%d bytes) for new feed: %@", log: log, type: .info, imageData.count, updatedFeed.title)
                }
                try context.save()
                os_log("Created new feed in Core Data: %@", log: log, type: .info, updatedFeed.title)
            }
        } catch {
            os_log("Failed to update/create feed in Core Data: %@", log: log, type: .error, error.localizedDescription)
        }
        
        for episode in updatedFeed.episodes {
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
            } else {
                allEpisodes.append(episode)
            }
        }
        
        if currentEpisodes.first?.feedId == updatedFeed.id {
            currentEpisodes = allEpisodes.filter { $0.feedId == updatedFeed.id }
        }
        
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
    
    func updateEpisode(_ updatedEpisode: PodcastEpisode) {
        if let index = allEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            allEpisodes[index] = updatedEpisode
        }
        if let index = currentEpisodes.firstIndex(where: { $0.id == updatedEpisode.id }) {
            currentEpisodes[index] = updatedEpisode
        }
        saveEpisodeToCoreData(updatedEpisode)
        
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
        var updatedEpisode = episode
        updatedEpisode.state.isFavorite.toggle()
        
        if updatedEpisode.state.isFavorite {
            if !favoriteEpisodes.contains(where: { $0.id == updatedEpisode.id }) {
                favoriteEpisodes.append(updatedEpisode)
            }
        } else {
            favoriteEpisodes.removeAll { $0.id == updatedEpisode.id }
        }
        
        updateEpisodeInLists(updatedEpisode)
        saveEpisodeToCoreData(updatedEpisode)
        
        // Update and save bookmark status
        var bookmarkStatus = loadBookmarkStatus(for: episode.feedId)
        bookmarkStatus[episode.id] = updatedEpisode.state.isFavorite
        saveBookmarkStatus(bookmarkStatus, for: episode.feedId)
        
        objectWillChange.send()
    }
    
    func updateEpisodeDownloadStatus(_ episode: PodcastEpisode, isDownloaded: Bool) {
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
        saveEpisodeToCoreData(updatedEpisode)
        
        // Update and save download status
        var downloadStatus = loadDownloadStatus(for: episode.feedId)
        downloadStatus[episode.id] = isDownloaded
        saveDownloadStatus(downloadStatus, for: episode.feedId)
        
        objectWillChange.send()
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
                
                if self.backgroundContext.hasChanges {
                    try self.backgroundContext.save()
                    
                    DispatchQueue.main.async {
                        self.context.perform {
                            do {
                                try self.context.save()
                                print("Successfully saved episode state to Core Data: \(episode.title)")
                            } catch {
                                print("Failed to save main context after background save: \(error)")
                            }
                        }
                    }
                }
            } catch {
                print("Failed to save episode to Core Data: \(error)")
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
        // Update the currentTab on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.currentTab = selectedTab
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Update allEpisodes with the latest bookmark and download statuses
            let updatedAllFeedEpisodes = self.allEpisodes.map { episode -> PodcastEpisode in
                var updatedEpisode = episode
                if episode.feedId == feedId {
                    updatedEpisode.state.isFavorite = self.favoriteEpisodes.contains(where: { $0.id == episode.id })
                    updatedEpisode.state.isDownloaded = self.downloadedEpisodes.contains(where: { $0.id == episode.id })
                }
                return updatedEpisode
            }
            
            let filteredEpisodes: [PodcastEpisode]
            switch self.currentTab {
            case 0: // All
                filteredEpisodes = updatedAllFeedEpisodes.filter { $0.feedId == feedId }
            case 1: // Favorite
                filteredEpisodes = self.favoriteEpisodes.filter { $0.feedId == feedId }
            case 2: // Downloads
                filteredEpisodes = self.downloadedEpisodes.filter { $0.feedId == feedId }
            default:
                filteredEpisodes = updatedAllFeedEpisodes.filter { $0.feedId == feedId }
            }
            
            let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
            
            DispatchQueue.main.async {
                // Update allEpisodes with the latest statuses
                self.allEpisodes = updatedAllFeedEpisodes
                self.currentEpisodes = sortedEpisodes
                self.objectWillChange.send()
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
