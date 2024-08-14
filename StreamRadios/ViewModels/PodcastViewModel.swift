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


class PodcastViewModel: ObservableObject {
    @Published var podcastFeeds: [PodcastFeed] = []
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var podcastUrls: [String] = []
    private let userDefaults = UserDefaults.standard
        private let episodeStatesKey = "PodcastEpisodeStates"
    private let progressKey = "PodcastProgress"
    private let dataStore = DataStore.shared
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastViewModel")
        private let context = CoreDataStack.shared.persistentContainer.viewContext

    private func saveProgress() {
            do {
                let encodedData = try JSONEncoder().encode(podcastFeeds)
                UserDefaults.standard.set(encodedData, forKey: progressKey)
            } catch {
                print("Failed to save progress: \(error)")
            }
        }
    
    private func loadProgress(for episodeId: String) -> Double? {
        // Retrieve the saved progress for the episode from UserDefaults or your preferred storage
        let progressKey = "progress_\(episodeId)"
        return userDefaults.double(forKey: progressKey)
    }

    
    func addPodcastFeed(_ feed: PodcastFeed) {
            isLoading = true
            dataStore.savePodcastFeedToCloudKit(feed) { [weak self] success, _ in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if success {
                        self?.podcastFeeds.append(feed)
                        self?.fetchRSSFeed(for: feed) { _ in }
                    } else {
                        self?.error = "Failed to save podcast feed"
                    }
                }
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
    
    func fetchFavoriteEpisodes() {
            let fetchRequest: NSFetchRequest<ManagedPodcastEpisode> = ManagedPodcastEpisode.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isFavorite == true")
            fetchRequest.fetchBatchSize = 20

            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                DispatchQueue.main.async {
                    self.currentEpisodes = episodes
                }
            } catch {
                print("Failed to fetch favorite episodes: \(error)")
            }
        }
        
    func updateEpisodeState(episodeId: String, isPlayed: Bool, isFavorite: Bool, progress: Double, isDownloaded: Bool) {
        episodeStates[episodeId] = EpisodeState(isPlayed: isPlayed, isFavorite: isFavorite, progress: progress, isDownloaded: isDownloaded)
        updateEpisodeInCurrentEpisodes(episodeId: episodeId) // Remove isDownloaded argument here
        saveProgress() // Save progress whenever it changes
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

    
    func fetchPodcastFeeds() {
            isLoading = true
            dataStore.fetchPodcastFeedsFromCloudKit { [weak self] feeds, error in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if let feeds = feeds {
                        self?.podcastFeeds = feeds
                        for feed in feeds {
                            self?.fetchRSSFeed(for: feed) { _ in }
                        }
                    } else if let error = error {
                        self?.error = error.localizedDescription
                    }
                }
            }
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
            isLoading = true
            dataStore.deletePodcastFeedFromCloudKit(feed) { [weak self] success in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if success {
                        self?.podcastFeeds.removeAll { $0.id == feed.id }
                    } else {
                        self?.error = "Failed to delete podcast feed"
                    }
                }
            }
        }
    
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        os_log("Fetching episodes for feed: %@", log: log, type: .info, feed.title)
        isLoading = true
        fetchRSSFeed(for: feed) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(var updatedFeed): // Make updatedFeed mutable by using var
                    os_log("Successfully fetched episodes for feed: %@", log: self.log, type: .info, feed.title)
                    // Load saved progress for each episode
                    for index in updatedFeed.episodes.indices {
                        let episodeId = updatedFeed.episodes[index].id
                        if let savedProgress = self.loadProgress(for: episodeId) {
                            updatedFeed.episodes[index].state.progress = savedProgress
                        }
                    }
                    self.currentEpisodes = updatedFeed.episodes
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
            
            let rssParser = RSSParser(data: data, feedId: feed.id) // Pass feed.id as feedId
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


    
    func toggleFavorite(for episode: PodcastEpisode) {
            guard let index = currentEpisodes.firstIndex(where: { $0.id == episode.id }) else { return }

            var state = episodeStates[episode.id] ?? episode.state
            state.isFavorite.toggle() // Toggle the favorite status
            episodeStates[episode.id] = state

            // Update the episode in the current episodes list
            currentEpisodes[index].state = state

            // Optionally, save this state persistently
            saveEpisodeState(episodeId: episode.id, state: state)
        }
    
    func saveEpisode(episode: PodcastEpisode) {
            let managedEpisode = ManagedPodcastEpisode(context: context)
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
           saveProgress() // Save the updated states persistently
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
            updatedEpisode.feedId = finalFeed.id // Assign the feedId rather than a feed object
            return updatedEpisode
        }

        DispatchQueue.main.async {
            // Update the feed in podcastFeeds array
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

struct EpisodeState: Codable {
    var isPlayed: Bool
    var isFavorite: Bool
    var progress: Double // 0.0 to 1.0
    var isDownloaded: Bool // Add this line
}

