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
    let id: String
    var title: String
    var url: String
    var artworkUrl: String?
    var description: String?
    var iconData: String?
    var episodes: [PodcastEpisode] = []
}

struct PodcastEpisode: Identifiable, Codable {
    let id: String
    var title: String
    var description: String
    var audioUrl: String
    var publicationDate: Date
    var duration: TimeInterval
    var state: EpisodeState
    var feedId: String
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
    @Published var podcastUrls: [String] = []
        @Published var isLoading = false
        @Published var error: String?
        
        private let userDefaults = UserDefaults.standard
    private let episodeStatesKey = "PodcastEpisodeStates"
        private let favoritesKey = "FavoritePodcastEpisodes"
        private let progressKey = "PodcastProgress"
    private let podcastUrlsKey = "PodcastUrls"
        private let dataStore = DataStore.shared
        private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastViewModel")
        private let context = CoreDataStack.shared.persistentContainer.viewContext
    
    init() {
            loadSavedData()
        }
    
    private func loadSavedData() {
            loadPodcastFeeds()
            loadAllEpisodes()
            loadFavorites()
            loadProgress()
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
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                allEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                os_log("Loaded %d episodes from Core Data", log: log, type: .info, allEpisodes.count)
            } catch {
                os_log("Failed to load episodes: %@", log: log, type: .error, error.localizedDescription)
            }
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

        private func loadProgress() {
            if let progressDict = userDefaults.dictionary(forKey: progressKey) as? [String: Double] {
                for (episodeId, progress) in progressDict {
                    if let index = allEpisodes.firstIndex(where: { $0.id == episodeId }) {
                        allEpisodes[index].state.progress = progress
                    }
                }
                os_log("Loaded progress for %d episodes from UserDefaults", log: log, type: .info, progressDict.count)
            }
        }

    private var episodeStates: [String: EpisodeState] {
        get {
            if let data = userDefaults.data(forKey: episodeStatesKey),
               let states = try? JSONDecoder().decode([String: EpisodeState].self, from: data) {
                return states
            }
            return [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: episodeStatesKey)
            }
        }
    }

    private func saveProgress() {
        do {
            let encodedData = try JSONEncoder().encode(podcastFeeds)
            UserDefaults.standard.set(encodedData, forKey: progressKey)
        } catch {
            print("Failed to save progress: \(error)")
        }
    }
    
    private func loadProgress(for episodeId: String) -> Double? {
        let progressKey = "progress_\(episodeId)"
        return userDefaults.double(forKey: progressKey)
    }
    
    func addPodcastFeed(_ feed: PodcastFeed) {
            isLoading = true
            let managedFeed = FeedModel(context: context)
            managedFeed.update(from: feed)
            
            do {
                try context.save()
                podcastFeeds.append(feed)
                os_log("Added new podcast feed: %@", log: log, type: .info, feed.title)
                fetchRSSFeed(for: feed) { _ in }
            } catch {
                os_log("Failed to save new podcast feed: %@", log: log, type: .error, error.localizedDescription)
            }
            
            isLoading = false
        }
    
    func fetchPodcastFeeds() {
            isLoading = true
            for feed in podcastFeeds {
                fetchRSSFeed(for: feed) { _ in }
            }
            isLoading = false
        }
    
    func addPodcastUrl(_ url: String) {
        isLoading = true
        DataStore.shared.savePodcastURLToCloudKit(url) { success, _ in
            DispatchQueue.main.async {
                self.isLoading = false
                if success {
                    self.podcastUrls.append(url)
                } else {
                    self.error = "Failed to save podcast URL"
                }
            }
        }
    }
    
    func fetchPodcastUrls() {
        isLoading = true
        DataStore.shared.fetchPodcastURLsFromCloudKit { urls, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let urls = urls {
                    self.podcastUrls = urls
                } else if let error = error {
                    self.error = error.localizedDescription
                }
            }
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
    
    private func updateEpisodes(for feed: PodcastFeed) {
            for episode in feed.episodes {
                if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    allEpisodes[index] = episode
                } else {
                    allEpisodes.append(episode)
                }
            }
            saveEpisodesToCoreData(feed.episodes)
            currentEpisodes = allEpisodes.filter { $0.feedId == feed.id }
        }
    
    private func saveEpisodesToCoreData(_ episodes: [PodcastEpisode]) {
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
                    os_log("Failed to save episode to Core Data: %@", log: log, type: .error, error.localizedDescription)
                }
            }
            
            do {
                try context.save()
                os_log("Saved %d episodes to Core Data", log: log, type: .info, episodes.count)
            } catch {
                os_log("Failed to save context after updating episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    
    private func updateAllEpisodes(with newEpisodes: [PodcastEpisode]) {
            for episode in newEpisodes {
                if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    allEpisodes[index] = episode
                } else {
                    allEpisodes.append(episode)
                }
            }
        }

    
    func updateEpisodeState(episodeId: String, isPlayed: Bool, isFavorite: Bool, progress: Double, isDownloaded: Bool) {
        episodeStates[episodeId] = EpisodeState(isPlayed: isPlayed, isFavorite: isFavorite, progress: progress, isDownloaded: isDownloaded)
        updateEpisodeInCurrentEpisodes(episodeId: episodeId)
        saveProgress()
        updateFavorites(episodeId: episodeId, isFavorite: isFavorite)
    }
    
    private func updateEpisodeInCurrentEpisodes(episodeId: String) {
        if let index = currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
            let currentState = episodeStates[episodeId] ?? EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false)
            currentEpisodes[index].state = currentState
        }
    }
    
    func getEpisodeState(episodeId: String) -> EpisodeState {
        return episodeStates[episodeId] ?? EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false)
    }
    
    func toggleFavorite(for episode: PodcastEpisode) {
            guard let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) else { return }

            allEpisodes[index].state.isFavorite.toggle()
            let isFavorite = allEpisodes[index].state.isFavorite

            if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[currentIndex].state.isFavorite = isFavorite
            }

            updateFavorites(episodeId: episode.id, isFavorite: isFavorite)
            
            os_log("Toggled favorite for episode: %@, isFavorite: %@", log: log, type: .info, episode.title, isFavorite ? "true" : "false")
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
    
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
            if let index = allEpisodes.firstIndex(where: { $0.id == episode.id }) {
                allEpisodes[index].state.progress = progress
            }
            
            if let currentIndex = currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                currentEpisodes[currentIndex].state.progress = progress
            }
            
            var progressDict = userDefaults.dictionary(forKey: progressKey) as? [String: Double] ?? [:]
            progressDict[episode.id] = progress
            userDefaults.set(progressDict, forKey: progressKey)
            
            os_log("Updated progress for episode: %@, progress: %.2f", log: log, type: .info, episode.title, progress)
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


    func loadInitialData() {
            os_log("Loading initial data", log: log, type: .info)
            fetchPodcastFeeds()
            fetchFavoriteEpisodes()
        }
    
    func saveEpisode(episode: PodcastEpisode) {
        let managedEpisode = PodcastModel(context: context)
        managedEpisode.id = episode.id
        managedEpisode.title = episode.title
        managedEpisode.descriptionText = episode.description
        managedEpisode.audioUrl = episode.audioUrl
        managedEpisode.publicationDate = episode.publicationDate
        managedEpisode.duration = episode.duration
        managedEpisode.isFavorite = episode.state.isFavorite
        managedEpisode.isDownloaded = episode.state.isDownloaded
        managedEpisode.progress = episode.state.progress
        managedEpisode.feedId = episode.feedId

        do {
            try context.save()
        } catch {
            print("Failed to save episode: \(error)")
        }
    }
    
    private func saveEpisodeState(episodeId: String, state: EpisodeState) {
        episodeStates[episodeId] = state
        saveProgress()
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
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            
            if let artworkUrl = updatedFeed.artworkUrl, let url = URL(string: artworkUrl) {
                self.fetchAndEncodeImage(from: url) { encodedImage in
                    updatedFeed.iconData = encodedImage
                    self.completeRSSFeedUpdate(updatedFeed: updatedFeed, rssParser: rssParser, completion: completion)
                }
            } else {
                self.completeRSSFeedUpdate(updatedFeed: updatedFeed, rssParser: rssParser, completion: completion)
            }
        }.resume()
    }
    
    private func fetchAndEncodeImage(from url: URL, completion: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Error fetching image: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
                return
            }
            
            let base64EncodedImage = data.base64EncodedString()
            completion(base64EncodedImage)
        }.resume()
    }
    
    private func completeRSSFeedUpdate(updatedFeed: PodcastFeed, rssParser: RSSParser, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        var finalFeed = updatedFeed
        finalFeed.episodes = rssParser.episodes.map { episode in
            var updatedEpisode = episode
            updatedEpisode.feedId = finalFeed.id
            return updatedEpisode
        }

        DispatchQueue.main.async {
            if let index = self.podcastFeeds.firstIndex(where: { $0.id == finalFeed.id }) {
                self.podcastFeeds[index] = finalFeed
            }

            completion(.success(finalFeed))
        }
    }
}

class RSSParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
        var podcastTitle: String?
        var artworkUrl: String?
        var episodes: [PodcastEpisode] = []
        var currentFeedId: String? // Add this property to store the feed ID
        
        private var currentElement = ""
        private var currentTitle: String?
        private var currentDescription: String?
        private var currentPubDate: String?
        private var currentDuration: String?
        private var currentEnclosure: String?
        private var isParsingItem = false
        
        init(data: Data, feedId: String) { // Add feedId to the initializer
            self.parser = XMLParser(data: data)
            self.currentFeedId = feedId // Initialize the currentFeedId
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
                
                let episode = PodcastEpisode(
                    id: UUID().uuidString,  // Generate a new UUID for the episode ID
                    title: title,
                    description: description,
                    audioUrl: enclosure,
                    publicationDate: pubDate,
                    duration: duration,
                    state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false), // Provide a default EpisodeState
                    feedId: currentFeedId! // Force unwrap currentFeedId
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
                }
            case "pubDate":
                if isParsingItem {
                    currentPubDate = (currentPubDate ?? "") + data
                }
            case "itunes:duration":
                if isParsingItem {
                    currentDuration = (currentDuration ?? "") + data
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
