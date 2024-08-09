//
//  PodcastViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import Foundation
import Combine
import SwiftUI

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
    var feed: PodcastFeed
    var state: EpisodeState
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
    
    

    private func saveProgress() {
            do {
                let encodedData = try JSONEncoder().encode(podcastFeeds)
                UserDefaults.standard.set(encodedData, forKey: progressKey)
            } catch {
                print("Failed to save progress: \(error)")
            }
        }
    private func loadProgress() {
           guard let savedData = UserDefaults.standard.data(forKey: progressKey) else { return }
           do {
               let decodedFeeds = try JSONDecoder().decode([PodcastFeed].self, from: savedData)
               self.podcastFeeds = decodedFeeds
           } catch {
               print("Failed to load progress: \(error)")
           }
       }
    
    func addPodcastFeed(_ feed: PodcastFeed) {
        isLoading = true
        DataStore.shared.savePodcastFeedToCloudKit(feed) { [weak self] success, _ in
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
        
    func updateEpisodeState(episodeId: String, isPlayed: Bool, progress: Double) {
           episodeStates[episodeId] = EpisodeState(isPlayed: isPlayed, progress: progress)
           updateEpisodeInCurrentEpisodes(episodeId: episodeId)
           saveProgress() // Save progress whenever it changes
       }
        
        private func updateEpisodeInCurrentEpisodes(episodeId: String) {
            if let index = currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
                currentEpisodes[index].state = episodeStates[episodeId] ?? EpisodeState(isPlayed: false, progress: 0.0)
            }
        }
        
        func getEpisodeState(episodeId: String) -> EpisodeState {
            return episodeStates[episodeId] ?? EpisodeState(isPlayed: false, progress: 0.0)
        }
    
    func fetchPodcastFeeds() {
        isLoading = true
        DataStore.shared.fetchPodcastFeedsFromCloudKit { feeds, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let feeds = feeds {
                    self.podcastFeeds = feeds
                    for feed in feeds {
                        self.fetchRSSFeed(for: feed) { _ in }
                    }
                } else if let error = error {
                    self.error = error.localizedDescription
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
            DataStore.shared.deletePodcastFeedFromCloudKit(feed) { [weak self] success in
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
           isLoading = true
           fetchRSSFeed(for: feed) { result in
               DispatchQueue.main.async {
                   self.isLoading = false
                   switch result {
                   case .success(let updatedFeed):
                       let episodes = updatedFeed.episodes.map { episode in
                           var updatedEpisode = episode
                           updatedEpisode.state = self.getEpisodeState(episodeId: episode.id)
                           return updatedEpisode
                       }
                       self.currentEpisodes = episodes
                       completion(.success(episodes))
                   case .failure(let error):
                       self.error = error.localizedDescription
                       completion(.failure(error))
                   }
               }
           }
       }
    
    private func fetchRSSFeed(for feed: PodcastFeed, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        guard let url = URL(string: feed.url) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data received", code: 0, userInfo: nil)))
                return
            }
            
            let rssParser = RSSParser(data: data)
            rssParser.parse()
            
            var updatedFeed = feed
            updatedFeed.title = rssParser.podcastTitle ?? feed.title
            updatedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
            
            // Fetch and encode icon image if artworkUrl is available
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
            updatedEpisode.feed = finalFeed
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
    
    private var currentElement = ""
    private var currentTitle: String?
    private var currentDescription: String?
    private var currentPubDate: String?
    private var currentDuration: String?
    private var currentEnclosure: String?
    private var isParsingItem = false
    
    init(data: Data) {
        self.parser = XMLParser(data: data)
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
                    id: UUID().uuidString,  // Convert UUID to String
                    title: title,
                    description: description,
                    audioUrl: enclosure,
                    publicationDate: pubDate,
                    duration: duration,
                    feed: PodcastFeed(id: UUID().uuidString, title: "", url: ""),
                    state: EpisodeState(isPlayed: false, progress: 0.0) // Provide a default EpisodeState
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
    var progress: Double // 0.0 to 1.0
}
