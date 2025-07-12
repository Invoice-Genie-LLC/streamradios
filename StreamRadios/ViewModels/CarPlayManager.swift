import Foundation
import CarPlay
import UIKit
import os.log
import CoreData

/// CarPlay Manager for iOS 14+ using CPTemplateApplicationScene
/// Removed deprecated MPPlayableContentDataSource/Delegate extensions
class CarPlayManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = CarPlayManager()
    
    // MARK: - Properties
    private let log = OSLog(subsystem: "com.yourapp.streamradios", category: "CarPlayManager")
    
    // CarPlay connection status for performance optimizations
    @Published var isCarPlayConnected: Bool = false
    
    // Data properties
    private var radioStations: [RadioStation] = []
    private var podcastFeeds: [PodcastFeed] = []
    private var recentPodcastEpisodes: [PodcastEpisode] = []
    private var recentlyPlayedEpisodes: [(episode: PodcastEpisode, playedAt: Date)] = []
    private let maxRecentEpisodes = 10
    
    // Image cache for performance
    private var imageCache: [String: UIImage] = [:]
    private var imageCacheAccessTimes: [String: Date] = [:]
    private let maxCacheSize = 50
    private let cacheExpirationTime: TimeInterval = 300 // 5 minutes
    
    private init() {
        os_log("CarPlay: CarPlayManager initialized", log: log, type: .info)
        loadRecentlyPlayedEpisodes()
    }
    
    // MARK: - Public Data Access Methods
    
    func updateContent() {
        // Refresh data from main app sources
        radioStations = RadioStationViewModel.shared.stations
        updateRecentPodcastEpisodes()
        os_log("CarPlay: Content updated - %d stations, %d recent episodes", log: log, type: .debug, radioStations.count, recentPodcastEpisodes.count)
    }
    
    func configurePodcastData(_ podcastFeeds: [PodcastFeed]) {
        self.podcastFeeds = podcastFeeds
        updateRecentPodcastEpisodes()
        os_log("CarPlay: Configured with %d podcast feeds", log: log, type: .info, podcastFeeds.count)
    }
    
    func getPodcastFeeds() -> [PodcastFeed] {
        return podcastFeeds
    }
    
    func getStations(for country: String) -> [RadioStation] {
        return radioStations.filter { $0.country == country }
    }
    
    func getFavoriteStations() -> [RadioStation] {
        return radioStations.filter { $0.isFavorite }.sorted { first, second in
            if let firstOrder = first.favoriteOrder, let secondOrder = second.favoriteOrder {
                return firstOrder < secondOrder
            } else if first.favoriteOrder != nil {
                return true
            } else if second.favoriteOrder != nil {
                return false
            } else {
                return (first.favoritedAt ?? Date.distantPast) > (second.favoritedAt ?? Date.distantPast)
            }
        }
    }
    
    func getRecentStations() -> [RadioStation] {
        return radioStations.filter { $0.lastPlayed != nil }.sorted {
            ($0.lastPlayed ?? Date.distantPast) > ($1.lastPlayed ?? Date.distantPast)
        }.prefix(10).map { $0 }
    }
    
    func getRecentPodcastEpisodes() -> [PodcastEpisode] {
        return recentPodcastEpisodes
    }
    
    func getFavoritePodcastEpisodes() -> [PodcastEpisode] {
        var favoriteEpisodes: [PodcastEpisode] = []
        for feed in podcastFeeds {
            favoriteEpisodes.append(contentsOf: feed.episodes.filter { $0.state.isFavorite })
        }
        return favoriteEpisodes.sorted { $0.publicationDate > $1.publicationDate }
    }
    
    func getAvailableCountries() -> [String] {
        let countries = Set(radioStations.map { $0.country })
        return Array(countries).sorted()
    }
    
    func getFlagImage(for country: String) -> UIImage? {
        // Return a simple system image for countries since flag images would require FlagKit
        return UIImage(systemName: "globe")
    }
    
    // MARK: - Artwork Methods
    
    func getStationArtwork(for station: RadioStation) -> UIImage? {
        let cacheKey = "station_\(station.id)"
        
        // Check cache first
        if let cachedImage = imageCache[cacheKey] {
            imageCacheAccessTimes[cacheKey] = Date()
            return cachedImage
        }
        
        // Try to create artwork from station icon data
        if let iconData = station.iconData, !iconData.isEmpty,
           let data = Data(base64Encoded: iconData),
           let image = UIImage(data: data) {
            // Cache the image
            imageCache[cacheKey] = image
            imageCacheAccessTimes[cacheKey] = Date()
            cleanupImageCacheIfNeeded()
            return image
        }
        
        // Return system fallback
        return UIImage(systemName: "radio")
    }
    
    func getPodcastArtwork(for podcast: PodcastFeed) -> UIImage? {
        let cacheKey = "podcast_\(podcast.id)"
        
        // Check cache first
        if let cachedImage = imageCache[cacheKey] {
            imageCacheAccessTimes[cacheKey] = Date()
            return cachedImage
        }
        
        // Try to create artwork from podcast image data
        if let imageData = podcast.imageData, !imageData.isEmpty,
           let image = UIImage(data: imageData) {
            // Cache the image
            imageCache[cacheKey] = image
            imageCacheAccessTimes[cacheKey] = Date()
            cleanupImageCacheIfNeeded()
            return image
        }
        
        // Try icon data as fallback
        if let iconData = podcast.iconData, !iconData.isEmpty,
           let data = Data(base64Encoded: iconData),
           let image = UIImage(data: data) {
            // Cache the image
            imageCache[cacheKey] = image
            imageCacheAccessTimes[cacheKey] = Date()
            cleanupImageCacheIfNeeded()
            return image
        }
        
        // Return system fallback
        return UIImage(systemName: "microphone")
    }
    
    // MARK: - Recently Played Episodes Management
    
    func addEpisodeToRecentlyPlayed(_ episode: PodcastEpisode) {
        let now = Date()
        
        os_log("CarPlay: Adding episode '%@' to recently played", log: log, type: .info, episode.title)
        
        // Remove any existing entry for this episode to avoid duplicates
        recentlyPlayedEpisodes.removeAll { $0.episode.id == episode.id }
        
        // Add to the beginning of the list
        recentlyPlayedEpisodes.insert((episode: episode, playedAt: now), at: 0)
        
        // Keep only the most recent episodes
        if recentlyPlayedEpisodes.count > maxRecentEpisodes {
            recentlyPlayedEpisodes = Array(recentlyPlayedEpisodes.prefix(maxRecentEpisodes))
        }
        
        // Update the recent episodes list
        updateRecentPodcastEpisodes()
        
        // Save to UserDefaults for persistence
        saveRecentlyPlayedEpisodes()
        
        os_log("CarPlay: Added episode to recently played list (now %d total)", log: log, type: .info, recentlyPlayedEpisodes.count)
    }
    
    func updateEpisodeProgress(episodeId: String, progress: Double, isCompleted: Bool = false) {
        // Find and update the episode in our podcast feeds
        for i in 0..<podcastFeeds.count {
            if let episodeIndex = podcastFeeds[i].episodes.firstIndex(where: { $0.id == episodeId }) {
                podcastFeeds[i].episodes[episodeIndex].state.progress = progress
                if isCompleted {
                    podcastFeeds[i].episodes[episodeIndex].state.isPlayed = true
                }
                
                os_log("CarPlay: Updated episode progress to %.2f%%", log: log, type: .debug, progress * 100)
                break
            }
        }
        
        // Update recent episodes list
        updateRecentPodcastEpisodes()
    }
    
    // MARK: - Private Helper Methods
    
    private func updateRecentPodcastEpisodes() {
        // Use the recently played episodes that track actual play times
        recentPodcastEpisodes = recentlyPlayedEpisodes.map { $0.episode }
        
        // If we have no recently played episodes, fall back to episodes with progress
        if recentPodcastEpisodes.isEmpty {
            var allEpisodes: [PodcastEpisode] = []
            for feed in podcastFeeds {
                allEpisodes.append(contentsOf: feed.episodes)
            }
            
            recentPodcastEpisodes = allEpisodes
                .filter { episode in
                    episode.state.progress > 0 || episode.state.isPlayed
                }
                .sorted { episode1, episode2 in
                    episode1.publicationDate > episode2.publicationDate
                }
                .prefix(5)
                .map { $0 }
        }
        
        os_log("CarPlay: Updated recent podcast episodes - %d episodes", log: log, type: .debug, recentPodcastEpisodes.count)
    }
    
    // MARK: - Image Cache Management
    
    private func cleanupImageCacheIfNeeded() {
        guard imageCache.count > maxCacheSize else { return }
        
        let now = Date()
        var itemsToRemove: [String] = []
        
        // Remove expired items first
        for (key, accessTime) in imageCacheAccessTimes {
            if now.timeIntervalSince(accessTime) > cacheExpirationTime {
                itemsToRemove.append(key)
            }
        }
        
        // If still over limit, remove least recently used
        if imageCache.count - itemsToRemove.count > maxCacheSize {
            let sortedByAccess = imageCacheAccessTimes.sorted { $0.value < $1.value }
            let additionalToRemove = sortedByAccess.prefix(imageCache.count - itemsToRemove.count - maxCacheSize)
            itemsToRemove.append(contentsOf: additionalToRemove.map { $0.key })
        }
        
        // Remove items
        for key in itemsToRemove {
            imageCache.removeValue(forKey: key)
            imageCacheAccessTimes.removeValue(forKey: key)
        }
        
        if !itemsToRemove.isEmpty {
            os_log("CarPlay: Cleaned up %d cached images", log: log, type: .debug, itemsToRemove.count)
        }
    }
    
    // MARK: - Persistence
    
    private func saveRecentlyPlayedEpisodes() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let recentEpisodesData = recentlyPlayedEpisodes.map { item in
                RecentlyPlayedEpisodeData(
                    episodeId: item.episode.id,
                    episodeTitle: item.episode.title,
                    episodeUrl: item.episode.audioUrl,
                    episodeDuration: item.episode.duration,
                    episodePublicationDate: item.episode.publicationDate,
                    playedAt: item.playedAt,
                    podcastTitle: "",
                    podcastId: item.episode.feedId
                )
            }
            
            let data = try encoder.encode(recentEpisodesData)
            UserDefaults.standard.set(data, forKey: "carPlayRecentlyPlayedEpisodes")
            
            os_log("CarPlay: Saved %d recently played episodes", log: log, type: .debug, recentEpisodesData.count)
        } catch {
            os_log("CarPlay: Failed to save recently played episodes: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func loadRecentlyPlayedEpisodes() {
        guard let data = UserDefaults.standard.data(forKey: "carPlayRecentlyPlayedEpisodes") else {
            os_log("CarPlay: No saved recently played episodes found", log: log, type: .debug)
            return
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            let recentEpisodesData = try decoder.decode([RecentlyPlayedEpisodeData].self, from: data)
            
            // Convert back to our internal format
            recentlyPlayedEpisodes = recentEpisodesData.map { data in
                let episode = PodcastEpisode(
                    id: data.episodeId,
                    title: data.episodeTitle,
                    descriptionText: "",
                    audioUrl: data.episodeUrl,
                    publicationDate: data.episodePublicationDate,
                    duration: data.episodeDuration,
                    state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
                    feedId: data.podcastId
                )
                return (episode: episode, playedAt: data.playedAt)
            }
            
            // Remove episodes older than 30 days
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            recentlyPlayedEpisodes = recentlyPlayedEpisodes.filter { $0.playedAt > thirtyDaysAgo }
            
            os_log("CarPlay: Loaded %d recently played episodes", log: log, type: .info, recentlyPlayedEpisodes.count)
        } catch {
            os_log("CarPlay: Failed to load recently played episodes: %@", log: log, type: .error, error.localizedDescription)
            UserDefaults.standard.removeObject(forKey: "carPlayRecentlyPlayedEpisodes")
        }
    }
}

// MARK: - Data Structures

private struct RecentlyPlayedEpisodeData: Codable {
    let episodeId: String
    let episodeTitle: String
    let episodeUrl: String
    let episodeDuration: TimeInterval
    let episodePublicationDate: Date
    let playedAt: Date
    let podcastTitle: String
    let podcastId: String
} 
