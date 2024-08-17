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

struct PodcastFeed: Identifiable, Codable {
    let id: String // This should be a UUID
    var title: String
    var url: String
    var artworkUrl: String?
    var description: String?
    var iconData: String?
    var episodes: [PodcastEpisode] = []
    
    // Example initializer with UUID
    init(id: String = UUID().uuidString, title: String, url: String, artworkUrl: String? = nil, description: String? = nil, iconData: String? = nil, episodes: [PodcastEpisode] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.artworkUrl = artworkUrl
        self.description = description
        self.iconData = iconData
        self.episodes = episodes
    }
}

struct PodcastEpisode: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var description: String
    var audioUrl: String
    var publicationDate: Date
    var duration: TimeInterval
    var state: EpisodeState
    var feedId: String
    var localFilePath: String?
    
    init(id: String = UUID().uuidString, title: String, description: String, audioUrl: String, publicationDate: Date, duration: TimeInterval, state: EpisodeState, feedId: String, localFilePath: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.audioUrl = audioUrl
        self.publicationDate = publicationDate
        self.duration = duration
        self.state = state
        self.feedId = feedId
        self.localFilePath = localFilePath
    }
    
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        return lhs.id == rhs.id
    }
}

struct EpisodeState: Codable {
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
    @Published var isLoading = false
    @Published var error: String?
    @Published var episodeProgress: [String: Double] = [:]
    
    private let userDefaults = UserDefaults.standard
    private let episodeStatesKey = "PodcastEpisodeStates"
    private let favoritesKey = "FavoritePodcastEpisodes"
    private let progressKey = "PodcastProgress"
    private let podcastUrlsKey = "PodcastUrls"
    private let dataStore = DataStore.shared
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastViewModel")
    private let context = CoreDataStack.shared.persistentContainer.viewContext
    private var lastSavedProgress: [String: Double] = [:]
    private let fileManager = FileManager.default
    private var hasChanges = false

    
    init() {
        loadSavedData()
    }
    
    func loadSavedData() {
            loadPodcastFeeds()
            loadAllEpisodes()
            loadDownloadedEpisodes()
            loadFavoriteEpisodes()
            loadAllEpisodesProgress()
        }
    
    private func loadDownloadedEpisodes() {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                downloadedEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                os_log("Loaded %d downloaded episodes from Core Data", log: log, type: .info, downloadedEpisodes.count)
            } catch {
                os_log("Failed to load downloaded episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        }

        private func loadFavoriteEpisodes() {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isFavorite == YES")
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                favoriteEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                os_log("Loaded %d favorite episodes from Core Data", log: log, type: .info, favoriteEpisodes.count)
            } catch {
                os_log("Failed to load favorite episodes: %@", log: log, type: .error, error.localizedDescription)
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

            // 3. Clear all bookmarks and favorites
            group.enter()
            clearAllBookmarksAndFavorites { result in
                if !result {
                    success = false
                }
                group.leave()
            }

            group.notify(queue: .main) {
                completion(success)
            }
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

        private func clearAllBookmarksAndFavorites(completion: @escaping (Bool) -> Void) {
            UserDefaults.standard.removeObject(forKey: favoritesKey)
            episodeProgress.removeAll()
            
            // Clear any other UserDefaults keys related to podcasts
            // For example:
            // UserDefaults.standard.removeObject(forKey: "PodcastBookmarks")
            
            completion(true)
        }
    
    private func loadPodcastFeeds() {
            let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            do {
                let managedFeeds = try context.fetch(fetchRequest)
                podcastFeeds = managedFeeds.map { $0.toPodcastFeed() }
                os_log("Loaded %d podcast feeds from Core Data", log: log, type: .info, podcastFeeds.count)
            } catch {
                os_log("Failed to load podcast feeds: %@", log: log, type: .error, error.localizedDescription)
            }
        }

    private func loadAllEpisodes() {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                self.allEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                print("Loaded \(self.allEpisodes.count) episodes")
            } catch {
                print("Failed to load episodes: \(error)")
            }
        }
    
    private func convertToPodcastEpisode(_ managedEpisode: PodcastModel) -> PodcastEpisode {
            return PodcastEpisode(
                id: managedEpisode.id ?? UUID().uuidString,
                title: managedEpisode.title ?? "",
                description: managedEpisode.descriptionText ?? "",
                audioUrl: managedEpisode.audioUrl ?? "",
                publicationDate: managedEpisode.publicationDate ?? Date(),
                duration: managedEpisode.duration,
                state: EpisodeState(
                    isPlayed: managedEpisode.progress == 1.0,
                    isFavorite: managedEpisode.isFavorite,
                    progress: managedEpisode.progress,
                    isDownloaded: managedEpisode.isDownloaded
                ),
                feedId: managedEpisode.feedId ?? "",
                localFilePath: managedEpisode.localFilePath
            )
        }

        private func loadFavorites() {
            if let favoriteIds = userDefaults.array(forKey: favoritesKey) as? [String] {
                for episodeId in favoriteIds {
                    if let index = allEpisodes.firstIndex(where: { $0.id == episodeId }) {
                        allEpisodes[index].state.isFavorite = true
                    }
                }
                os_log("Loaded %d favorites from UserDefaults", log: log, type: .info, favoriteIds.count)
            }
        }
    
    func fetchPodcastFeeds() {
        isLoading = true
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        
        do {
            let managedFeeds = try context.fetch(fetchRequest)
            podcastFeeds = managedFeeds.map { $0.toPodcastFeed() }
            os_log("Loaded %d podcast feeds from Core Data", log: log, type: .info, podcastFeeds.count)
            
            for feed in podcastFeeds {
                fetchRSSFeed(for: feed) { _ in }
            }
        } catch {
            os_log("Failed to load podcast feeds: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to load podcast feeds"
        }
        
        isLoading = false
    }
    
    func addPodcastFeed(_ feed: PodcastFeed) {
        isLoading = true
        
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@ OR url == %@", feed.id, feed.url)
        
        do {
            let existingFeeds = try context.fetch(fetchRequest)
            if let existingFeed = existingFeeds.first {
                existingFeed.update(from: feed)
                os_log("Updated existing podcast feed: %@", log: log, type: .info, feed.title)
            } else {
                let managedFeed = FeedModel(context: context)
                managedFeed.update(from: feed)
                os_log("Added new podcast feed: %@", log: log, type: .info, feed.title)
            }
            
            try context.save()
            
            fetchPodcastFeeds()
            
            fetchRSSFeed(for: feed) { _ in }
        } catch {
            os_log("Failed to save new podcast feed: %@", log: log, type: .error, error.localizedDescription)
            self.error = "Failed to save new podcast feed"
        }
        
        isLoading = false
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
            os_log("Deleted podcast feed: %@", log: log, type: .info, feed.title)
        } catch {
            os_log("Failed to delete podcast feed: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        os_log("Fetching episodes for feed: %@", log: log, type: .info, feed.title)
        isLoading = true
        fetchRSSFeed(for: feed) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let updatedFeed):
                    os_log("Successfully fetched episodes for feed: %@", log: self.log, type: .info, feed.title)
                    self.updateEpisodes(for: updatedFeed)
                    completion(.success(updatedFeed.episodes))
                case .failure(let error):
                    os_log("Failed to fetch episodes for feed: %@, error: %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                    self.error = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
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
            updatedFeed.title = rssParser.podcastTitle ?? feed.title
            updatedFeed.description = rssParser.podcastDescription
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            updatedFeed.episodes = rssParser.episodes
            
            if let artworkUrl = updatedFeed.artworkUrl, let url = URL(string: artworkUrl) {
                self.fetchAndEncodeImage(from: url) { encodedImage in
                    updatedFeed.iconData = encodedImage
                    self.completeRSSFeedUpdate(updatedFeed: updatedFeed, completion: completion)
                }
            } else {
                self.completeRSSFeedUpdate(updatedFeed: updatedFeed, completion: completion)
            }
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
        
        saveEpisodesToCoreData(updatedFeed.episodes)
    }
    
    func updateEpisodes(for feed: PodcastFeed) {
            var updatedEpisodes = [PodcastEpisode]()
            
            for episode in feed.episodes {
                if let existingIndex = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    // Update existing episode
                    var updatedEpisode = episode
                    updatedEpisode.state = allEpisodes[existingIndex].state
                    allEpisodes[existingIndex] = updatedEpisode
                    updatedEpisodes.append(updatedEpisode)
                } else {
                    // Add new episode
                    allEpisodes.append(episode)
                    updatedEpisodes.append(episode)
                }
            }
            
            saveEpisodesToCoreData(updatedEpisodes)
            currentEpisodes = allEpisodes.filter { $0.feedId == feed.id }
            
            objectWillChange.send()
        }
    
    func cleanupDuplicateEpisodes() {
            let context = CoreDataStack.shared.persistentContainer.viewContext
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
    
    private func saveEpisodesToCoreData(_ episodes: [PodcastEpisode]) {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            
            for episode in episodes {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                
                do {
                    let results = try context.fetch(fetchRequest)
                    let managedEpisode: PodcastModel
                    
                    if let existingEpisode = results.first {
                        // Update existing episode
                        managedEpisode = existingEpisode
                    } else {
                        // Create new episode only if it doesn't exist
                        managedEpisode = PodcastModel(context: context)
                    }
                    
                    // Update managed episode properties
                    managedEpisode.update(from: episode)
                    
                } catch {
                    print("Failed to fetch/save episode: \(error)")
                }
            }
            
            // Save context after processing all episodes
            do {
                try context.save()
                print("Successfully saved episodes to Core Data")
            } catch {
                print("Failed to save context: \(error)")
            }
            
            // Refresh allEpisodes array to reflect the changes
            loadAllEpisodes()
        }
    
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
            episodeProgress[episode.id] = progress
            
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                var updatedEpisode = allEpisodes[index]
                updatedEpisode.state.progress = progress
                allEpisodes[index] = updatedEpisode
                
                if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    currentEpisodes[currentIndex] = updatedEpisode
                }
                
                saveEpisodeProgress(updatedEpisode)
            }
            
            hasChanges = true
            objectWillChange.send()
        }
    
    private func saveEpisodeProgress(_ episode: PodcastEpisode) {
           let context = CoreDataStack.shared.persistentContainer.viewContext
           let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
           fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
           
           do {
               let results = try context.fetch(fetchRequest)
               if let managedEpisode = results.first {
                   managedEpisode.progress = episode.state.progress
                   hasChanges = true
               }
           } catch {
               print("Failed to save episode progress: \(error)")
           }
       }
    
    func saveContextIfNeeded() {
            if hasChanges {
                let context = CoreDataStack.shared.persistentContainer.viewContext
                do {
                    try context.save()
                    hasChanges = false
                    print("Core Data context saved successfully")
                } catch {
                    print("Failed to save Core Data context: \(error)")
                }
            }
        }
    
    private func saveEpisodeProgress(episode: PodcastEpisode, progress: Double) {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let existingEpisode = results.first {
                existingEpisode.progress = progress
                existingEpisode.update(from: episode)
            } else {
                let newEpisode = PodcastModel(context: context)
                newEpisode.update(from: episode)
                newEpisode.progress = progress
            }
            
            try context.save()
            os_log("Saved progress for episode: %@, progress: %f", log: log, type: .debug, episode.title, progress)
        } catch {
            os_log("Failed to save episode progress: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    func getProgress(for episode: PodcastEpisode) -> Double {
        return episodeProgress[episode.id] ?? 0.0
    }
    
    func toggleFavorite(for episode: PodcastEpisode) {
            guard var updatedEpisode = allEpisodes.first(where: { $0.id == episode.id }) else { return }
            
            updatedEpisode.state.isFavorite.toggle()
            
            if updatedEpisode.state.isFavorite {
                favoriteEpisodes.append(updatedEpisode)
            } else {
                favoriteEpisodes.removeAll { $0.id == updatedEpisode.id }
            }
            
            updateEpisodeInLists(updatedEpisode)
            saveEpisodesToCoreData([updatedEpisode])
            
            hasChanges = true
            os_log("Toggled favorite for episode: %@, isFavorite: %@", log: log, type: .info, updatedEpisode.title, updatedEpisode.state.isFavorite ? "true" : "false")
        }
    
    private func updateEpisodeInLists(_ episode: PodcastEpisode) {
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
            }
            
            if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[currentIndex] = episode
            }
            
            if let downloadIndex = downloadedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                downloadedEpisodes[downloadIndex] = episode
            }
            
            if let favoriteIndex = favoriteEpisodes.firstIndex(where: { $0.id == episode.id }) {
                favoriteEpisodes[favoriteIndex] = episode
            }
        }

    
    private func updateFavorites(episodeId: String, isFavorite: Bool) {
        var favorites = Set(userDefaults.array(forKey: favoritesKey) as? [String] ?? [])
        
        if isFavorite {
            favorites.insert(episodeId)
        } else {
            favorites.remove(episodeId)
        }
        
        userDefaults.set(Array(favorites), forKey: favoritesKey)
        os_log("Updated favorites in UserDefaults, total count: %d", log: log, type: .info, favorites.count)
    }
    
    func getFavoriteEpisodes() -> [PodcastEpisode] {
        return allEpisodes.filter { $0.state.isFavorite }
    }
    
    func fetchFavoriteEpisodes() {
            let favoriteIds = getFavoriteEpisodeIds()
            os_log("Fetching favorite episodes, count: %d", log: log, type: .info, favoriteIds.count)
            
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", favoriteIds)

            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                DispatchQueue.main.async {
                    self.currentEpisodes = episodes
                    os_log("Updated currentEpisodes with favorite episodes, count: %d", log: self.log, type: .info, episodes.count)
                }
            } catch {
                os_log("Failed to fetch favorite episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        }
        
        func getFavoriteEpisodeIds() -> Set<String> {
            let favoriteIds = userDefaults.array(forKey: favoritesKey) as? [String] ?? []
            os_log("Retrieved favorite episode IDs from UserDefaults, count: %d", log: log, type: .info, favoriteIds.count)
            return Set(favoriteIds)
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
                    completion(.failure(error))
                }
                return
            }
            
            guard let localUrl = localUrl else {
                DispatchQueue.main.async {
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
                
                var updatedEpisode = episode
                updatedEpisode.localFilePath = destinationUrl.path
                updatedEpisode.state.isDownloaded = true
                
                DispatchQueue.main.async {
                    self.updateDownloadedEpisode(updatedEpisode)
                    completion(.success(updatedEpisode))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
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
        
    private func updateDownloadedEpisode(_ episode: PodcastEpisode) {
            // Update in allEpisodes
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index] = episode
            } else {
                allEpisodes.append(episode)
            }
            
            // Update in currentEpisodes
            if let index = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[index] = episode
            }
            
            // Update in downloadedEpisodes
            if let index = downloadedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                downloadedEpisodes[index] = episode
            } else {
                downloadedEpisodes.append(episode)
            }
            
            // Save to Core Data
            saveEpisodesToCoreData([episode])
            
            // Trigger UI update
            objectWillChange.send()
        }
    
    func updateFilteredEpisodes(for feedId: String, selectedTab: Int) {
            switch selectedTab {
            case 0: // All
                currentEpisodes = allEpisodes.filter { $0.feedId == feedId }
            case 1: // Unplayed
                currentEpisodes = allEpisodes.filter { $0.feedId == feedId && $0.state.progress == 0 }
            case 2: // Favorite
                currentEpisodes = favoriteEpisodes.filter { $0.feedId == feedId }
            case 3: // Downloads
                currentEpisodes = downloadedEpisodes.filter { $0.feedId == feedId }
            default:
                currentEpisodes = allEpisodes.filter { $0.feedId == feedId }
            }
            currentEpisodes.sort { $0.publicationDate > $1.publicationDate }
            
            // Trigger UI update
            objectWillChange.send()
        }
        
        func deleteDownloadedEpisode(_ episode: PodcastEpisode) {
            if let localFilePath = episode.localFilePath {
                do {
                    try fileManager.removeItem(atPath: localFilePath)
                    os_log("Deleted local file for episode: %@", log: log, type: .info, episode.title)
                } catch {
                    os_log("Failed to delete local file for episode: %@, error: %@", log: log, type: .error, episode.title, error.localizedDescription)
                }
            }

            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)

            do {
                let results = try context.fetch(fetchRequest)
                for object in results {
                    context.delete(object)
                }

                try context.save()

                allEpisodes.removeAll { $0.id == episode.id }
                currentEpisodes.removeAll { $0.id == episode.id }
                
                os_log("Deleted episode from Core Data and in-memory list: %@", log: log, type: .info, episode.title)
            } catch {
                os_log("Failed to delete episode from Core Data: %@, error: %@", log: log, type: .error, episode.title, error.localizedDescription)
            }
        }
        
        func clearAllPodcastEpisodes(completion: @escaping (Bool) -> Void) {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            
            do {
                let episodes = try context.fetch(fetchRequest)
                for episode in episodes {
                    if let localFilePath = episode.localFilePath {
                        do {
                            try fileManager.removeItem(atPath: localFilePath)
                            os_log("Deleted local file for episode: %@", log: log, type: .info, episode.title ?? "Unknown Title")
                        } catch {
                            os_log("Failed to delete local file for episode: %@, error: %@", log: log, type: .error, episode.title ?? "Unknown Title", error.localizedDescription)
                        }
                    }
                    context.delete(episode)
                }
                
                try context.save()
                os_log("Cleared all podcast episodes from Core Data", log: log, type: .info)
                
                userDefaults.removeObject(forKey: episodeStatesKey)
                userDefaults.removeObject(forKey: favoritesKey)
                userDefaults.removeObject(forKey: progressKey)
                os_log("Cleared episode states, favorites, and progress from UserDefaults", log: log, type: .info)
                
                allEpisodes.removeAll()
                currentEpisodes.removeAll()
                os_log("Reset allEpisodes and currentEpisodes in the view model", log: log, type: .info)
                
                completion(true)
            } catch {
                os_log("Failed to clear podcast episodes: %@", log: log, type: .error, error.localizedDescription)
                completion(false)
            }
        }
        
    func loadAllEpisodesProgress() {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            
            do {
                let results = try context.fetch(fetchRequest)
                for managedEpisode in results {
                    if let id = managedEpisode.id {
                        episodeProgress[id] = managedEpisode.progress
                        
                        if let index = allEpisodes.firstIndex(where: { $0.id == id }) {
                            allEpisodes[index].state.progress = managedEpisode.progress
                        }
                        
                        if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == id }) {
                            currentEpisodes[currentIndex].state.progress = managedEpisode.progress
                        }
                    }
                }
            } catch {
                print("Failed to load episode progress: \(error)")
            }
            
            objectWillChange.send()
        }
    }

class RSSParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    var podcastTitle: String?
    var podcastDescription: String?
    var artworkUrl: String?
    var episodes: [PodcastEpisode] = []
    private let feedId: String
    
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
        case "enclosure":
            if isParsingItem {
                currentEnclosure = attributeDict["url"]
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
               let description = currentDescription,
               let pubDateString = currentPubDate,
               let enclosure = currentEnclosure {
                
                let pubDate = DateFormatter.rfc2822.date(from: pubDateString) ?? Date()
                let duration = TimeInterval(currentDuration ?? "0") ?? 0
                
                // Use the GUID if available, otherwise generate a UUID
                let id = currentGuid ?? UUID().uuidString
                
                let episode = PodcastEpisode(
                    id: id,
                    title: title,
                    description: description,
                    audioUrl: enclosure,
                    publicationDate: pubDate,
                    duration: duration,
                    state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
                    feedId: feedId
                )
                
                episodes.append(episode)
            }
            
            isParsingItem = false
        }
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
