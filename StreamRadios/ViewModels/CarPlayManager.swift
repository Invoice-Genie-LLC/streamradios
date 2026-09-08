import Foundation
import CarPlay
import UIKit
import os.log
import CoreData
import FlagKit

/// CarPlay Manager for iOS 14+ using CPTemplateApplicationScene
/// Removed deprecated MPPlayableContentDataSource/Delegate extensions
class CarPlayManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = CarPlayManager()
    
    // MARK: - Properties
    private let log = OSLog(subsystem: "com.yourapp.streamradios", category: "CarPlayManager")
    
    // CarPlay remains connected while either its scene or audio route is active. Audio-session
    // category changes can briefly remove the route without disconnecting the CarPlay scene.
    @Published private(set) var isCarPlayConnected: Bool = false
    private var isCarPlaySceneConnected = false
    private var isCarAudioRouteActive = false

    func setCarPlaySceneConnected(_ connected: Bool) {
        isCarPlaySceneConnected = connected
        updateConnectionState()
    }

    func setCarAudioRouteActive(_ active: Bool) {
        isCarAudioRouteActive = active
        updateConnectionState()
    }

    private func updateConnectionState() {
        isCarPlayConnected = isCarPlaySceneConnected || isCarAudioRouteActive
    }
    
    // Data properties
    private var radioStations: [RadioStation] = []
    private var podcastFeeds: [PodcastFeed] = []
    private var podcastFeedOrder: [String] = [] // Maintains same order as main app
    private var recentPodcastEpisodes: [PodcastEpisode] = []
    private var recentlyPlayedEpisodes: [(episode: PodcastEpisode, playedAt: Date)] = []
    private let maxRecentEpisodes = 10
    
    // Image cache for performance
    private var imageCache: [String: UIImage] = [:]
    private var imageCacheAccessTimes: [String: Date] = [:]
    private let maxCacheSize = 50
    private let cacheExpirationTime: TimeInterval = 300 // 5 minutes
    
    // Persisted feed artwork for when app is closed
    private var persistedFeedArtwork: [String: Data] = [:]
    
    private init() {
        os_log("CarPlay: CarPlayManager initialized", log: log, type: .info)
        loadRecentlyPlayedEpisodes()
        setupNotificationListeners()
    }
    
    // MARK: - Real-time Order Synchronization
    
    private func setupNotificationListeners() {
        // Listen for favorite station order changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FavoriteStationOrderChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🚗 CarPlay: Received favorite station order change notification")
            self?.handleFavoriteStationOrderChange(notification)
        }
        
        // Listen for podcast feed order changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastFeedOrderChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🚗 CarPlay: Received podcast feed order change notification")
            self?.handlePodcastFeedOrderChange(notification)
        }
        
        // Listen for favorite station additions/removals
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FavoriteStationChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🚗 CarPlay: Received favorite station change notification")
            self?.handleFavoriteStationChange(notification)
        }

        NotificationCenter.default.addObserver(
            forName: .stationsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRadioStationData(reason: "stations_updated")
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StationsLoaded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRadioStationData(reason: "stations_loaded")
        }
    }

    private func refreshRadioStationData(reason: String) {
        updateContent()
        NotificationCenter.default.post(
            name: NSNotification.Name("CarPlayStationOrderChanged"),
            object: nil,
            userInfo: ["reason": reason]
        )
        print("🚗 CarPlay: Refreshed radio station data after \(reason)")
    }
    
    @MainActor
    private func handleFavoriteStationOrderChange(_ notification: Notification) {
        // Immediately update radio stations data from the main app
        self.radioStations = RadioStationViewModel.shared.stations
        
        // Trigger CarPlay template refresh for stations
        NotificationCenter.default.post(
            name: NSNotification.Name("CarPlayStationOrderChanged"),
            object: nil,
            userInfo: ["reason": "favorite_order_changed"]
        )
        
        print("🚗 ⭐ CarPlay: Updated favorite station order immediately")
    }
    
    @MainActor
    private func handlePodcastFeedOrderChange(_ notification: Notification) {
        // Get updated feed order from main app
        let updatedFeedOrder = PodcastViewModel.shared.podcastFeedOrder
        let updatedFeeds = PodcastViewModel.shared.podcastFeeds

        // During a CarPlay cold launch the phone model can publish its order before its feeds have
        // loaded. Keep the independently loaded Core Data snapshot instead of replacing it with an
        // empty transitional value. A true empty store is still applied by the direct scene loader.
        guard !updatedFeeds.isEmpty || podcastFeeds.isEmpty else {
            print("🚗 🎙️ CarPlay: Ignoring temporary empty podcast feed-order snapshot")
            return
        }
        
        // Update our local data immediately
        self.podcastFeeds = updatedFeeds
        self.podcastFeedOrder = updatedFeedOrder
        
        // Trigger CarPlay template refresh for podcasts
        NotificationCenter.default.post(
            name: NSNotification.Name("CarPlayPodcastOrderChanged"),
            object: nil,
            userInfo: ["reason": "feed_order_changed"]
        )
        
        print("🚗 🎙️ CarPlay: Updated podcast feed order immediately")
    }
    
    @MainActor
    private func handleFavoriteStationChange(_ notification: Notification) {
        // Update radio stations data when favorites are added/removed
        self.radioStations = RadioStationViewModel.shared.stations
        
        // Trigger CarPlay template refresh
        NotificationCenter.default.post(
            name: NSNotification.Name("CarPlayStationOrderChanged"),
            object: nil,
            userInfo: ["reason": "favorite_changed"]
        )
        
        print("🚗 ⭐ CarPlay: Updated favorite stations immediately")
    }
    
    // MARK: - Public Data Access Methods
    
    func updateContent() {
        // Refresh data from main app sources
        let latestStations = RadioStationViewModel.shared.stations
        if !latestStations.isEmpty || radioStations.isEmpty {
            radioStations = latestStations
        }
        updateRecentPodcastEpisodes()
        os_log("CarPlay: Content updated - %d stations, %d recent episodes", log: log, type: .debug, radioStations.count, recentPodcastEpisodes.count)
    }

    func configureRadioData(_ stations: [RadioStation]) {
        guard !stations.isEmpty || radioStations.isEmpty else { return }
        radioStations = stations
        os_log("CarPlay: Configured with %d radio stations", log: log, type: .info, stations.count)
    }
    
    /// Force refresh podcast data immediately - called when main app becomes active
    /// PERFORMANCE FIX: Optimized to prevent redundant calls and main thread blocking
    @MainActor
    func forceRefreshPodcastData() {
        os_log("🚗 CarPlay: Force refresh podcast data requested", log: log, type: .info)
        
        print("🚗 CarPlay: DEBUG - Starting optimized force refresh podcast data")
        
        // PERFORMANCE FIX: Don't call loadFeedsFromCoreData again if it was just called
        // Instead, just sync with existing data to prevent duplicate operations
        
        // Get the latest podcast feeds from PodcastViewModel (already loaded by SceneDelegate)
        let latestFeeds = PodcastViewModel.shared.podcastFeeds
        print("🚗 CarPlay: DEBUG - Found \(latestFeeds.count) feeds in PodcastViewModel (no reload needed)")
        
        // The main model can still be empty while the independent CarPlay Core Data load has
        // already succeeded. Never discard that valid snapshot during this transition.
        if !latestFeeds.isEmpty || podcastFeeds.isEmpty {
            let feedOrder = PodcastViewModel.shared.podcastFeedOrder
            self.configurePodcastData(latestFeeds, feedOrder: feedOrder)
        } else {
            print("🚗 CarPlay: Preserving independently loaded podcast data during phone startup")
        }
        
        // Update our local data
        self.updateContent()
        
        // Send notifications to trigger CarPlay template refresh with optimized timing
        for delay in [0.0, 0.3, 0.8] { // Reduced from 4 notifications to 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CarPlayRefreshRequested"),
                    object: nil,
                    userInfo: ["source": "ForceRefreshPodcastData", "delay": "\(delay)"]
                )
                print("🚗 CarPlay: DEBUG - Sent refresh notification (delay: \(delay)s)")
            }
        }
        
        print("🚗 CarPlay: Optimized force refresh completed with \(latestFeeds.count) feeds")
    }
    
    func configurePodcastData(_ podcastFeeds: [PodcastFeed], feedOrder: [String] = []) {
        self.podcastFeeds = podcastFeeds
        self.podcastFeedOrder = feedOrder.isEmpty ? podcastFeeds.map { $0.id } : feedOrder
        updateRecentPodcastEpisodes()
        os_log("CarPlay: Configured with %d podcast feeds in order", log: log, type: .info, podcastFeeds.count)
    }
    
    func getPodcastFeeds() -> [PodcastFeed] {
        // Use the same ordering as the main app by respecting podcastFeedOrder
        // This ensures CarPlay shows feeds in the exact same order as the main app
        
        // Get the feed order from the main PodcastViewModel
        let feedOrder = podcastFeedOrder
        
        // Create a lookup dictionary for fast access
        let feedLookup = Dictionary(uniqueKeysWithValues: podcastFeeds.map { ($0.id, $0) })
        
        // Return feeds in the same order as the main app
        var orderedFeeds: [PodcastFeed] = []
        
        // First, add feeds that are in the order array
        for feedId in feedOrder {
            if let feed = feedLookup[feedId] {
                orderedFeeds.append(feed)
            }
        }
        
        // Then add any feeds that might not be in the order array (edge case)
        let orderedFeedIds = Set(feedOrder)
        for feed in podcastFeeds {
            if !orderedFeedIds.contains(feed.id) {
                orderedFeeds.append(feed)
            }
        }
        
        return orderedFeeds
    }
    
    func getStations(for country: String) -> [RadioStation] {
        let filteredStations = radioStations.filter { $0.country == country }
        
        // CRITICAL FIX: Sort stations alphabetically to match phone app order
        // Use the same sorting logic as RadioStationViewModel and RadioStationListView
        let isAscendingSort = RadioStationViewModel.shared.isAscendingSort
        
        if isAscendingSort {
            return filteredStations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else {
            return filteredStations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    func getStation(withId id: String) -> RadioStation? {
        radioStations.first { $0.id == id }
    }
    
    func getFavoriteStations() -> [RadioStation] {
        // Get hidden countries (same as main app)
        let hiddenCountriesData = UserDefaults.standard.data(forKey: "hiddenCountries") ?? Data()
        let hiddenCountries = (try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData)) ?? Set<String>()
        
        // Filter out favorites from hidden countries and use EXACT same sorting as main app
        return radioStations.filter { $0.isFavorite && !hiddenCountries.contains($0.country) }
            .sorted { (station1, station2) in
                // First, check if both stations have favoriteOrder values
                if let order1 = station1.favoriteOrder, let order2 = station2.favoriteOrder {
                    return order1 < order2
                }
                
                // If only one has favoriteOrder, prioritize it
                if station1.favoriteOrder != nil && station2.favoriteOrder == nil {
                    return true
                }
                if station1.favoriteOrder == nil && station2.favoriteOrder != nil {
                    return false
                }
                
                // If neither has favoriteOrder, fall back to favoritedAt timestamp (ASCENDING like main app)
                if let date1 = station1.favoritedAt, let date2 = station2.favoritedAt {
                    return date1 < date2
                }
                
                // Final fallback: alphabetical by name
                return station1.name.localizedCaseInsensitiveCompare(station2.name) == .orderedAscending
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

    func getMostRecentPodcastPlayedAt() -> Date? {
        return recentlyPlayedEpisodes.first?.playedAt
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
        // Filter out placeholder entries that shouldn't appear in CarPlay
        let filteredCountries = countries.filter { country in
            return country != "Select Country" && 
                   country != "Unknown Region" && 
                   !country.isEmpty
        }
        return Array(filteredCountries).sorted()
    }
    
    func getFlagImage(for country: String) -> UIImage? {
        // Get the country flag using FlagKit
        // First, find the country data to get the flag code
        let allCountries = Country.getAllCountriesWithAPICodes()
        if let countryData = allCountries.first(where: { $0.name == country }),
           !countryData.flag.isEmpty,
           let flag = Flag(countryCode: countryData.flag) {
            return flag.image(style: FlagStyle.roundedRect)
        }
        
        // Fallback to globe icon if flag not found
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
            print("CarPlay: Successfully loaded artwork from imageData for podcast '\(podcast.title)'")
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
            print("CarPlay: Successfully loaded artwork from iconData for podcast '\(podcast.title)'")
            return image
        }
        
        // Try loading from artwork URL if available and no cached data
        if let artworkUrl = podcast.artworkUrl, !artworkUrl.isEmpty, 
           URL(string: artworkUrl) != nil {
            // For CarPlay, we should try to load synchronously if possible
            // or return nil to let the caller handle async loading
            print("CarPlay: No cached artwork for podcast '\(podcast.title)', artworkUrl available: \(artworkUrl)")
        } else {
            print("CarPlay: No artwork data or URL available for podcast '\(podcast.title)'")
        }
        
        // Return nil instead of fallback - let caller handle fallback
        return nil
    }
    
    /// Get podcast artwork by feed ID, using persisted data when app is closed
    func getPodcastArtworkByFeedId(_ feedId: String) -> UIImage? {
        let cacheKey = "podcast_\(feedId)"
        
        // Check cache first
        if let cachedImage = imageCache[cacheKey] {
            imageCacheAccessTimes[cacheKey] = Date()
            return cachedImage
        }
        
        // Try to find feed in active feeds first
        if let podcastFeed = podcastFeeds.first(where: { $0.id == feedId }) {
            return getPodcastArtwork(for: podcastFeed)
        }
        
        // If feed not found in active feeds, use persisted artwork
        if let persistedData = persistedFeedArtwork[feedId],
           let image = UIImage(data: persistedData) {
            // Cache the image
            imageCache[cacheKey] = image
            imageCacheAccessTimes[cacheKey] = Date()
            cleanupImageCacheIfNeeded()
            print("CarPlay: Successfully loaded artwork from persisted data for feedId: \(feedId)")
            return image
        }
        
        print("CarPlay: No artwork found for feedId: \(feedId) - neither in active feeds nor persisted data")
        return nil
    }
    
    // MARK: - Artwork Loading Helper
    
    func loadPodcastArtworkFromURL(for podcast: PodcastFeed, completion: @escaping (UIImage?) -> Void) {
        guard let artworkUrl = podcast.artworkUrl, !artworkUrl.isEmpty,
              let url = URL(string: artworkUrl) else {
            completion(nil)
            return
        }
        
        // Perform async download
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let image = UIImage(data: data),
                  error == nil else {
                print("CarPlay: Failed to load artwork from URL for podcast '\(podcast.title)': \(error?.localizedDescription ?? "unknown error")")
                completion(nil)
                return
            }
            
            // Cache the loaded image
            let cacheKey = "podcast_\(podcast.id)"
            self.imageCache[cacheKey] = image
            self.imageCacheAccessTimes[cacheKey] = Date()
            self.cleanupImageCacheIfNeeded()
            
            print("CarPlay: Successfully loaded artwork from URL for podcast '\(podcast.title)'")
            completion(image)
        }.resume()
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
                // Find the feed artwork for this episode
                let podcastFeed = podcastFeeds.first { feed in
                    feed.id == item.episode.feedId
                }
                
                return RecentlyPlayedEpisodeData(
                    episodeId: item.episode.id,
                    episodeTitle: item.episode.title,
                    episodeUrl: item.episode.audioUrl,
                    episodeDuration: item.episode.duration,
                    episodePublicationDate: item.episode.publicationDate,
                    playedAt: item.playedAt,
                    podcastTitle: podcastFeed?.title ?? "",
                    podcastId: item.episode.feedId,
                    feedArtworkData: podcastFeed?.imageData,
                    feedArtworkUrl: podcastFeed?.artworkUrl
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
            
            // Convert back to our internal format and populate persisted artwork
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
                
                // Store persisted artwork for this feed
                if let artworkData = data.feedArtworkData {
                    persistedFeedArtwork[data.podcastId] = artworkData
                }
                
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
    let feedArtworkData: Data?
    let feedArtworkUrl: String?
} 
