//
//  CarPlayManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/19/24.
//

import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import os.log
import CoreData
import SwiftUI
import Combine
import FlagKit

class CarPlayManager: NSObject, ObservableObject {
    static let shared = CarPlayManager()
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "CarPlay")
    private var cancellables = Set<AnyCancellable>()
    
    // Data caches for CarPlay
    private var allStations: [RadioStation] = []
    private var favoriteStations: [RadioStation] = []
    private var recentStations: [RadioStation] = []
    private var stationsByCountry: [String: [RadioStation]] = [:]
    private var availableCountries: [String] = []
    
    private var podcastFeeds: [PodcastFeed] = []
    private var favoritePodcasts: [PodcastFeed] = []
    private var downloadedPodcasts: [PodcastFeed] = []
    private var recentPodcastEpisodes: [PodcastEpisode] = []
    
    // Image cache for artwork
    private var imageCache: [String: UIImage] = [:]
    private var imageCacheAccessTimes: [String: Date] = [:]
    
    private override init() {
        super.init()
    }
    
    func setupCarPlay() {
        // CarPlay is now handled by CarPlaySceneDelegate using CPTabBarTemplate
        // This method is kept for data configuration only
        
        // Initial data load
        updateContent()
        
        // Set up data observers
        setupDataObservers()
        
        os_log("CarPlay data manager configured successfully (scene-based approach)", log: log, type: .info)
    }
    
    private func setupDataObservers() {
        // Observe radio station changes
        RadioStationViewModel.shared.$stations
            .sink { [weak self] stations in
                self?.updateRadioStations(stations)
            }
            .store(in: &cancellables)
        
        // Listen for podcast updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePodcastData),
            name: NSNotification.Name("PodcastDataUpdated"),
            object: nil
        )
        
        // NOTE: CarPlay disabled for iTunes artwork updates - only shows station icons
        // NotificationCenter.default.addObserver(
        //     self,
        //     selector: #selector(handleStationArtworkUpdate(_:)),
        //     name: NSNotification.Name("StationArtworkUpdated"),
        //     object: nil
        // )
    }
    
    func updateContent() {
        updateRadioStations(RadioStationViewModel.shared.stations)
    }
    
    private func updateRadioStations(_ stations: [RadioStation]) {
        os_log("CarPlay: Updating radio stations - received %d stations", log: log, type: .info, stations.count)
        
        // Log station icon statistics (CarPlay only shows station icons, not iTunes artwork)
        let stationsWithIcon = stations.filter { $0.iconData != nil && !$0.iconData!.isEmpty }
        
        os_log("🎨 CarPlay: Station artwork stats - Total: %d, WithIcon: %d", 
               log: log, type: .info, stations.count, stationsWithIcon.count)
        
        // Log details of first few stations with icon artwork
        for (index, station) in stationsWithIcon.prefix(3).enumerated() {
            os_log("🎨 CarPlay: Station %d with icon artwork: '%@' (data length: %d)", 
                   log: log, type: .debug, index, station.name, station.iconData!.count)
        }
        
        allStations = stations
        favoriteStations = stations.filter { $0.isFavorite }
        recentStations = stations.filter { $0.lastPlayed != nil }
        stationsByCountry = Dictionary(grouping: stations) { $0.country }
        availableCountries = Array(stationsByCountry.keys).sorted()
        
        // Skip demo stations since CarPlay only shows station icons, not iTunes artwork
        os_log("🎨 CarPlay: Skipping demo stations - CarPlay displays only station icons", 
               log: log, type: .info)
        
        // Skip adding sample artwork since CarPlay only shows station icons
        os_log("🎨 CarPlay: No sample artwork needed - CarPlay displays only station icons", 
               log: log, type: .info)
        
        os_log("CarPlay: Final counts - total: %d, favorites: %d, recent: %d, countries: %d", 
               log: log, type: .info, allStations.count, favoriteStations.count, recentStations.count, availableCountries.count)
    }
    
    private func enhancePopularStationsWithiTunesArtwork() {
        // Create sample iTunes artwork for testing
        guard let sampleiTunesArtwork = createSampleiTunesArtwork() else {
            os_log("CarPlay: Failed to create sample iTunes artwork", log: log, type: .error)
            return
        }
        
        let sampleiTunesArtworkBase64 = sampleiTunesArtwork.base64EncodedString()
        
        os_log("CarPlay: Enhancing popular stations with iTunes artwork", log: log, type: .info)
        
        // List of popular station names that should get iTunes artwork
        let popularStationPatterns = [
            "kiss", "kiis", "wild", "hot", "power", "z100", "wplj", "klos", "kroq", "krock"
        ]
        
        var enhancedCount = 0
        for i in 0..<allStations.count {
            let stationName = allStations[i].name.lowercased()
            
            // Check if this station matches any popular pattern
            let isPopular = popularStationPatterns.contains { pattern in
                stationName.contains(pattern)
            }
            
            if isPopular && allStations[i].iTunesArtworkData == nil {
                allStations[i].iTunesArtworkData = sampleiTunesArtworkBase64
                enhancedCount += 1
                os_log("CarPlay: Enhanced station '%@' with iTunes artwork", log: log, type: .debug, allStations[i].name)
                
                // Limit to first 10 matches to avoid too much processing
                if enhancedCount >= 10 {
                    break
                }
            }
        }
        
        // Update derived arrays
        favoriteStations = allStations.filter { $0.isFavorite }.sorted { first, second in
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
        recentStations = allStations.filter { $0.lastPlayed != nil }.sorted { 
            ($0.lastPlayed ?? Date.distantPast) > ($1.lastPlayed ?? Date.distantPast) 
        }.prefix(10).map { $0 }
        
        os_log("CarPlay: Enhanced %d popular stations with iTunes artwork", log: log, type: .info, enhancedCount)
    }
    
    @objc private func updatePodcastData() {
        // Filter podcasts by type
        favoritePodcasts = podcastFeeds.filter { feed in
            feed.episodes.contains { $0.state.isFavorite }
        }
        
        downloadedPodcasts = podcastFeeds.filter { feed in
            feed.episodes.contains { $0.state.isDownloaded }
        }
        
        // Get recent podcast episodes (last 5 played)
        var allEpisodes: [PodcastEpisode] = []
        for feed in podcastFeeds {
            allEpisodes.append(contentsOf: feed.episodes)
        }
        
        // Sort by play history and take the 5 most recent
        recentPodcastEpisodes = allEpisodes
            .filter { episode in
                // Filter episodes that have been played or have progress
                episode.state.progress > 0 || episode.state.isPlayed
            }
            .sorted { episode1, episode2 in
                // Sort by publication date as a proxy for recent activity
                episode1.publicationDate > episode2.publicationDate
            }
            .prefix(5)
            .map { $0 }
        
        os_log("CarPlay: Updated podcast data - %d feeds, %d favorites, %d downloads, %d recent episodes", 
               log: log, type: .info, podcastFeeds.count, favoritePodcasts.count, downloadedPodcasts.count, recentPodcastEpisodes.count)
        
        DispatchQueue.main.async {
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    func configurePodcastData(_ podcastFeeds: [PodcastFeed]) {
        self.podcastFeeds = podcastFeeds
        
        // Load episodes for each feed from Core Data if they're missing
        Task {
            await loadEpisodesForFeeds()
        }
        
        // Update recent podcast episodes
        updateRecentPodcastEpisodes()
        
        // Cleanup old cached images periodically
        cleanupImageCache()
        
        // Try to fetch missing artwork for podcast feeds
        Task {
            await self.fetchMissingPodcastArtwork()
        }
        
        os_log("CarPlay: Configured with podcast data - %d feeds", log: log, type: .info, podcastFeeds.count)
        
        // Debug podcast feed artwork data
        for feed in podcastFeeds {
            let hasImageData = feed.imageData != nil && !feed.imageData!.isEmpty
            let hasIconData = feed.iconData != nil && !feed.iconData!.isEmpty
            let hasArtworkUrl = feed.artworkUrl != nil && !feed.artworkUrl!.isEmpty
            
            os_log("CarPlay: Feed '%@' has %d episodes - imageData: %@ (%d bytes), iconData: %@ (%d chars), artworkUrl: %@ (%@)", 
                   log: log, type: .info, feed.title, feed.episodes.count,
                   hasImageData ? "true" : "false", feed.imageData?.count ?? 0,
                   hasIconData ? "true" : "false", feed.iconData?.count ?? 0,
                   hasArtworkUrl ? "true" : "false", feed.artworkUrl ?? "none")
            
            // Also debug the base64 decoding if iconData exists
            if let iconData = feed.iconData, !iconData.isEmpty {
                if let decodedData = Data(base64Encoded: iconData) {
                    os_log("CarPlay: Feed '%@' iconData decodes successfully to %d bytes", log: log, type: .debug, feed.title, decodedData.count)
                } else {
                    os_log("CarPlay: Feed '%@' iconData FAILED to decode from base64", log: log, type: .error, feed.title)
                }
            }
        }
        
        DispatchQueue.main.async {
            self.updatePodcastData()
        }
    }
    
    // Helper methods
    private func findStationIndex(_ station: RadioStation) -> Int {
        return allStations.firstIndex(where: { $0.id == station.id }) ?? 0
    }
    
    private func findPodcastFeedForEpisode(_ episode: PodcastEpisode) -> PodcastFeed? {
        return podcastFeeds.first { $0.id == episode.feedId }
    }
    
    private func syncEpisodesWithFeeds(_ allEpisodes: [PodcastEpisode]) {
        // Update podcast feeds with latest episode data
        for i in 0..<podcastFeeds.count {
            let feedEpisodes = allEpisodes.filter { $0.feedId == podcastFeeds[i].id }
            podcastFeeds[i].episodes = feedEpisodes
            os_log("CarPlay: Synced %d episodes for feed '%@'", log: log, type: .debug, feedEpisodes.count, podcastFeeds[i].title)
        }
    }
    
    private func loadMissingEpisodes(_ podcastViewModel: PodcastViewModel) async {
        for feed in podcastFeeds where feed.episodes.isEmpty {
            os_log("CarPlay: Loading episodes for feed '%@' with URL: %@", log: log, type: .info, feed.title, feed.url)
            
            // Fetch episodes for this feed
            await withCheckedContinuation { continuation in
                podcastViewModel.fetchEpisodes(for: feed) { result in
                    switch result {
                    case .success(let episodes):
                        os_log("CarPlay: Successfully loaded %d episodes for feed '%@'", log: self.log, type: .info, episodes.count, feed.title)
                    case .failure(let error):
                        os_log("CarPlay: Failed to load episodes for feed '%@': %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    // Load episodes for all feeds from Core Data
    private func loadEpisodesForFeeds() async {
        os_log("CarPlay: Loading episodes for %d podcast feeds from Core Data", log: log, type: .info, podcastFeeds.count)
        
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<podcastFeeds.count {
                taskGroup.addTask {
                    let feed = self.podcastFeeds[i]
                    
                    // Skip if feed already has episodes
                    if !feed.episodes.isEmpty {
                        os_log("CarPlay: Feed '%@' already has %d episodes, skipping load", log: self.log, type: .debug, feed.title, feed.episodes.count)
                        return
                    }
                    
                    // Load episodes from Core Data
                    let context = CoreDataStack.shared.context
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                    
                    do {
                        let managedEpisodes = try context.fetch(fetchRequest)
                        os_log("CarPlay: Found %d episodes in Core Data for feed '%@'", log: self.log, type: .debug, managedEpisodes.count, feed.title)
                        
                        if !managedEpisodes.isEmpty {
                            let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                                var episode = managedEpisode.toPodcastEpisode()
                                episode.state.isPlayed = managedEpisode.isPlayed
                                episode.state.progress = managedEpisode.progress
                                episode.state.isFavorite = managedEpisode.isFavorite
                                episode.state.isDownloaded = managedEpisode.isDownloaded
                                return episode
                            }
                            
                            // Update the feed with its episodes
                            await MainActor.run {
                                self.podcastFeeds[i].episodes = episodes
                                os_log("CarPlay: Updated feed '%@' with %d episodes", log: self.log, type: .info, feed.title, episodes.count)
                            }
                        }
                    } catch {
                        os_log("CarPlay: Error loading episodes for feed '%@': %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                    }
                }
            }
        }
        
        // After loading all episodes, update the podcast data
        os_log("CarPlay: Finished loading episodes for all feeds", log: log, type: .info)
        await MainActor.run {
            self.updatePodcastData()
            
            // Reload CarPlay data to reflect the new episodes
            DispatchQueue.main.async {
                MPPlayableContentManager.shared().reloadData()
            }
        }
    }
    
    // Fetch missing artwork for podcast feeds
    private func fetchMissingPodcastArtwork() async {
        for i in 0..<podcastFeeds.count {
            let feed = podcastFeeds[i]
            let hasImageData = feed.imageData != nil && !feed.imageData!.isEmpty
            let hasIconData = feed.iconData != nil && !feed.iconData!.isEmpty
            
            // If feed has no artwork but has an artwork URL, try to fetch it
            if !hasImageData && !hasIconData, 
               let artworkUrlString = feed.artworkUrl,
               !artworkUrlString.isEmpty,
               let artworkUrl = URL(string: artworkUrlString) {
                
                os_log("CarPlay: Attempting to fetch missing artwork for feed '%@' from URL: %@", 
                       log: log, type: .info, feed.title, artworkUrlString)
                
                do {
                    let (data, _) = try await URLSession.shared.data(from: artworkUrl)
                    
                    // Validate the downloaded image data
                    if !data.isEmpty, data.count > 16, let testImage = UIImage(data: data) {
                        os_log("CarPlay: Successfully downloaded artwork for feed '%@' (%d bytes, %dx%d)", 
                               log: log, type: .info, feed.title, data.count, 
                               Int(testImage.size.width), Int(testImage.size.height))
                        
                        // Update the feed with the new image data
                        podcastFeeds[i].imageData = data
                        
                        // Also cache it immediately for CarPlay use
                        let cacheKey = "feed_artwork_\(feed.id)"
                        imageCache[cacheKey] = testImage
                        imageCacheAccessTimes[cacheKey] = Date()
                        
                        // Trigger UI update for CarPlay
                        await MainActor.run {
                            updatePodcastData()
                        }
                    } else {
                        os_log("CarPlay: Downloaded artwork for feed '%@' is invalid or too small", 
                               log: log, type: .default, feed.title)
                    }
                } catch {
                    os_log("CarPlay: Failed to download artwork for feed '%@': %@", 
                           log: log, type: .error, feed.title, error.localizedDescription)
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    // Safe image processing helper to prevent crashes
    private func createSafeArtwork(from imageData: Data?, fallbackSystemImage: String, maxSize: CGFloat = 300) -> MPMediaItemArtwork? {
        // Try to create image from data with validation
        if let data = imageData, !data.isEmpty, data.count > 16 {
            return autoreleasepool {
                if let originalImage = UIImage(data: data),
                   originalImage.size.width > 0, originalImage.size.height > 0,
                   originalImage.size.width <= 2048, originalImage.size.height <= 2048 {
                    
                    // Create a persistent copy of the image to ensure retention
                    let targetSize = CGSize(
                        width: min(originalImage.size.width, maxSize),
                        height: min(originalImage.size.height, maxSize)
                    )
                    
                    // Create a renderer to ensure the image is properly retained
                    let renderer = UIGraphicsImageRenderer(size: targetSize)
                    let persistentImage = renderer.image { context in
                        originalImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                    
                    // Store a strong reference to the image
                    let cacheKey = "artwork_\(abs(data.hashValue))"
                    
                    os_log("CarPlay: Created persistent artwork image (%dx%d) with key %@", log: log, type: .debug, 
                           Int(persistentImage.size.width), Int(persistentImage.size.height), cacheKey)
                    
                    // Create artwork with a direct image reference (not using cache in closure to avoid retain cycles)
                    return MPMediaItemArtwork(boundsSize: targetSize) { [persistentImage] requestedSize in
                        return persistentImage
                    }
                }
                return nil
            }
        }
        
        // Fallback to system image with proper retention
        if let systemImage = UIImage(systemName: fallbackSystemImage) {
            let artworkSize = CGSize(width: min(systemImage.size.width, 64), 
                                   height: min(systemImage.size.height, 64))
            
            os_log("CarPlay: Using system image fallback: %@", log: log, type: .debug, fallbackSystemImage)
            
            return MPMediaItemArtwork(boundsSize: artworkSize) { [systemImage] requestedSize in
                return systemImage
            }
        }
        
        return nil
    }
    
    // Safe base64 image processing helper
    private func createSafeArtworkFromBase64(_ base64String: String?, fallbackSystemImage: String, maxSize: CGFloat = 300) -> MPMediaItemArtwork? {
        guard let base64 = base64String, !base64.isEmpty else {
            os_log("CarPlay: Base64 string is empty, using fallback", log: log, type: .debug)
            return createSafeArtwork(from: nil, fallbackSystemImage: fallbackSystemImage, maxSize: maxSize)
        }
        
        guard let imageData = Data(base64Encoded: base64) else {
            os_log("CarPlay: Failed to decode base64 data, using fallback", log: log, type: .debug)
            return createSafeArtwork(from: nil, fallbackSystemImage: fallbackSystemImage, maxSize: maxSize)
        }
        
        os_log("CarPlay: Successfully decoded base64 data (%d bytes)", log: log, type: .debug, imageData.count)
        return createSafeArtwork(from: imageData, fallbackSystemImage: fallbackSystemImage, maxSize: maxSize)
    }
    
    // Clean up old cached images to prevent memory issues
    private func cleanupImageCache() {
        let now = Date()
        let maxAge: TimeInterval = 300 // 5 minutes
        
        var keysToRemove: [String] = []
        for (key, accessTime) in imageCacheAccessTimes {
            if now.timeIntervalSince(accessTime) > maxAge {
                keysToRemove.append(key)
            }
        }
        
        for key in keysToRemove {
            imageCache.removeValue(forKey: key)
            imageCacheAccessTimes.removeValue(forKey: key)
        }
        
        if !keysToRemove.isEmpty {
            os_log("CarPlay: Cleaned up %d old cached images", log: log, type: .debug, keysToRemove.count)
        }
        
        // Also log current cache status
        os_log("CarPlay: Image cache status - %d items, %d access times tracked", log: log, type: .debug, 
               imageCache.count, imageCacheAccessTimes.count)
    }
    
    // Get country flag image using FlagKit with better mapping and debugging
    func getFlagImage(for country: String) -> UIImage? {
        os_log("CarPlay: Getting flag for country: '%@'", log: log, type: .debug, country)
        
        // Improved country code mapping with more variations
        let countryCodeMapping: [String: String] = [
            // English names
            "United States": "US", "USA": "US", "US": "US", "America": "US",
            "United Kingdom": "GB", "UK": "GB", "Britain": "GB", "England": "GB",
            "Canada": "CA", "Australia": "AU", "Germany": "DE", "France": "FR",
            "Italy": "IT", "Spain": "ES", "Netherlands": "NL", "Belgium": "BE",
            "Switzerland": "CH", "Austria": "AT", "Sweden": "SE", "Norway": "NO",
            "Denmark": "DK", "Finland": "FI", "Poland": "PL", "Czech Republic": "CZ",
            "Ireland": "IE", "Portugal": "PT", "Greece": "GR", "Japan": "JP",
            "South Korea": "KR", "Korea": "KR", "China": "CN", "India": "IN",
            "Brazil": "BR", "Mexico": "MX", "Argentina": "AR", "Chile": "CL",
            "Colombia": "CO", "Peru": "PE", "Russia": "RU", "Turkey": "TR",
            "Israel": "IL", "Egypt": "EG", "South Africa": "ZA", "Nigeria": "NG",
            "Kenya": "KE", "Morocco": "MA", "Tunisia": "TN", "Algeria": "DZ",
            "New Zealand": "NZ", "Indonesia": "ID", "Malaysia": "MY",
            "Singapore": "SG", "Thailand": "TH", "Philippines": "PH", "Vietnam": "VN",
            // Common variations and other names
            "United States of America": "US", "Estados Unidos": "US",
            "Reino Unido": "GB", "Royaume-Uni": "FR",
            "Deutschland": "DE", "Allemagne": "FR",
            "España": "ES", "Espagne": "FR", "Italia": "IT", "Italie": "FR",
            "Nederland": "NL", "Pays-Bas": "FR", "Belgique": "BE", "België": "BE",
            "Schweiz": "CH", "Suisse": "FR", "Österreich": "AT", "Autriche": "FR",
            "Sverige": "SE", "Suède": "FR", "Norge": "NO", "Norvège": "FR",
            "Danmark": "DK", "Danemark": "FR", "Suomi": "FI", "Finlande": "FR",
            "Polska": "PL", "Pologne": "FR", "Česká republika": "CZ",
            "Éire": "IE", "Irlande": "FR", "Ελλάδα": "GR", "Grèce": "FR",
            "日本": "JP", "Japon": "FR", "한국": "KR", "Corée du Sud": "FR",
            "中国": "CN", "Chine": "FR", "भारत": "IN", "Inde": "FR",
            "Brasil": "BR", "Brésil": "FR", "México": "MX", "Mexique": "FR",
        ]
        
        // Clean the country string
        let cleanCountry = country.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip unknown or generic regions
        if ["Unknown Region", "Unknown", "N/A", ""].contains(cleanCountry) {
            os_log("CarPlay: Skipping unknown country '%@', using default flag", log: log, type: .debug, country)
            return UIImage(systemName: "flag.fill")
        }
        
        // Get country code
        let countryCode: String?
        if let mappedCode = countryCodeMapping[cleanCountry] {
            countryCode = mappedCode
        } else {
            // Try the country name as-is if it's already a 2-letter code
            countryCode = cleanCountry.count == 2 ? cleanCountry.uppercased() : nil
        }
        
        guard let code = countryCode else {
            os_log("CarPlay: No country code found for '%@', using default flag", log: log, type: .debug, country)
            return UIImage(systemName: "flag.fill")
        }
        
        os_log("CarPlay: Using country code '%@' for '%@'", log: log, type: .debug, code, country)
        
        // Try to get flag from FlagKit
        if let flag = Flag(countryCode: code) {
            let flagImage = flag.image(style: .roundedRect)
            os_log("CarPlay: Successfully created flag image for '%@' (%@)", log: log, type: .debug, country, code)
            return flagImage
        } else {
            os_log("CarPlay: FlagKit failed to create flag for code '%@', using fallback", log: log, type: .debug, code)
        }
        
        // Fallback to system flag icon
        return UIImage(systemName: "flag.fill")
    }
    

    
    private func addSampleRadioStationsIfNeeded() {
        // Instead of only adding when empty, let's enhance existing stations with sample artwork
        guard !allStations.isEmpty else { 
            // Original logic for when no stations exist
            addEmptyStationSamples()
            return 
        }
        
        // Add sample artwork to first few existing stations for testing
        addSampleArtworkToExistingStations()
        
        // ALWAYS add a few demo stations with iTunes artwork for testing
        addDemoStationsWithiTunesArtwork()
    }
    
    private func addDemoStationsWithiTunesArtwork() {
        // Create sample iTunes artwork for demo stations
        guard let sampleiTunesArtwork = createSampleiTunesArtwork() else {
            os_log("❌ CarPlay: Failed to create sample iTunes artwork for demo stations", log: log, type: .error)
            return
        }
        
        let sampleiTunesArtworkBase64 = sampleiTunesArtwork.base64EncodedString()
        os_log("✅ CarPlay: Created sample iTunes artwork (base64 length: %d)", log: log, type: .info, sampleiTunesArtworkBase64.count)
        
        // FIRST: Add iTunes artwork to existing real stations that have been played recently
        var enhancedCount = 0
        for i in 0..<min(5, allStations.count) {
            if allStations[i].iTunesArtworkData == nil || allStations[i].iTunesArtworkData!.isEmpty {
                allStations[i].iTunesArtworkData = sampleiTunesArtworkBase64
                enhancedCount += 1
                os_log("✅ CarPlay: Enhanced existing station '%@' with iTunes artwork for CarPlay display", 
                       log: log, type: .info, allStations[i].name)
            }
        }
        
        // SECOND: Create demo stations that look like real radio stations
        let demoStations = [
            RadioStation(
                id: "demo_kiis_fm",
                name: "KIIS FM 102.7",
                url: "http://stream.kiis.com/stream",
                iconData: nil,
                iTunesArtworkData: sampleiTunesArtworkBase64,
                country: "USA",
                isFavorite: true,
                favoritedAt: Date(),
                favoriteOrder: 1
            ),
            RadioStation(
                id: "demo_wild_947",
                name: "Wild 94.7",
                url: "http://stream.wild947.com/stream",
                iconData: nil,
                iTunesArtworkData: sampleiTunesArtworkBase64,
                country: "USA",
                isFavorite: true,
                favoritedAt: Date(),
                favoriteOrder: 2
            ),
            RadioStation(
                id: "demo_radio_emanuel_itunes",
                name: "Radio Emanuel (Demo)",
                url: "http://stream.radioemanuel.com/stream",
                iconData: nil,
                iTunesArtworkData: sampleiTunesArtworkBase64,
                country: "Albania",
                isFavorite: false
            )
        ]
        
        os_log("✅ CarPlay: Created %d demo stations", log: log, type: .info, demoStations.count)
        
        // Log demo station details
        for (index, station) in demoStations.enumerated() {
            os_log("📍 Demo Station %d: '%@' (country: %@, iTunes data: %d chars)", 
                   log: log, type: .info, index, station.name, station.country, station.iTunesArtworkData?.count ?? 0)
        }
        
        // Add demo stations to the arrays strategically
        let originalCount = allStations.count
        allStations = demoStations + allStations
        favoriteStations = demoStations.filter { $0.isFavorite } + favoriteStations
        
        os_log("✅ CarPlay: Added demo stations - total stations changed from %d to %d", 
               log: log, type: .info, originalCount, allStations.count)
        
        // Update country groupings to include the new demo stations
        stationsByCountry = Dictionary(grouping: allStations) { $0.country }
        availableCountries = Array(stationsByCountry.keys).sorted()
        
        os_log("✅ CarPlay: Updated country groupings - now have %d countries: %@", 
               log: log, type: .info, availableCountries.count, availableCountries.joined(separator: ", "))
        
        // Final verification
        let finalStationsWithiTunes = allStations.filter { $0.iTunesArtworkData != nil && !$0.iTunesArtworkData!.isEmpty }
        os_log("✅ CarPlay: Final verification - %d stations now have iTunes artwork", 
               log: log, type: .info, finalStationsWithiTunes.count)
        
        os_log("✅ CarPlay: Demo station addition completed - enhanced %d existing + added %d demo stations", 
               log: log, type: .info, enhancedCount, demoStations.count)
    }
    
    private func addEmptyStationSamples() {
        
        // Create sample artwork for radio stations
        let sampleStationArtwork = createSampleRadioStationArtwork()
        let sampleStationArtworkBase64 = sampleStationArtwork?.base64EncodedString()
        
        // Create sample iTunes artwork (different design)
        let sampleiTunesArtwork = createSampleiTunesArtwork()
        let sampleiTunesArtworkBase64 = sampleiTunesArtwork?.base64EncodedString()
        
        let sampleStations = [
            RadioStation(
                id: "sample-station-1",
                name: "Sample Radio Station",
                url: "https://example.com/stream1",
                iconData: sampleStationArtworkBase64,
                iTunesArtworkData: nil,
                country: "Test Country",
                isFavorite: true,
                favoritedAt: Date(),
                favoriteOrder: 1,
                lastPlayed: Date()
            ),
            RadioStation(
                id: "sample-station-2", 
                name: "iTunes Art Station",
                url: "https://example.com/stream2",
                iconData: nil,
                iTunesArtworkData: sampleiTunesArtworkBase64,
                country: "Test Country",
                isFavorite: false,
                favoritedAt: nil,
                favoriteOrder: nil,
                lastPlayed: Date(timeIntervalSinceNow: -3600)
            ),
            RadioStation(
                id: "sample-station-3",
                name: "Both Artwork Station",
                url: "https://example.com/stream3", 
                iconData: sampleStationArtworkBase64,
                iTunesArtworkData: sampleiTunesArtworkBase64,
                country: "Test Country",
                isFavorite: true,
                favoritedAt: Date(),
                favoriteOrder: 2,
                lastPlayed: Date(timeIntervalSinceNow: -7200)
            )
        ]
        
        allStations = sampleStations
        favoriteStations = sampleStations.filter { $0.isFavorite }
        recentStations = sampleStations.filter { $0.lastPlayed != nil }
        stationsByCountry = Dictionary(grouping: sampleStations) { $0.country }
        availableCountries = Array(stationsByCountry.keys).sorted()
        
        os_log("CarPlay: Added sample radio stations for testing", log: log, type: .info)
    }
    
    private func addSampleArtworkToExistingStations() {
        // Add sample artwork to first few stations for testing
        let sampleStationArtwork = createSampleRadioStationArtwork()
        let sampleStationArtworkBase64 = sampleStationArtwork?.base64EncodedString()
        
        let sampleiTunesArtwork = createSampleiTunesArtwork()
        let sampleiTunesArtworkBase64 = sampleiTunesArtwork?.base64EncodedString()
        
        os_log("CarPlay: Starting to enhance stations with sample artwork", log: log, type: .info)
        os_log("CarPlay: Sample station artwork created: %@", log: log, type: .debug, sampleStationArtworkBase64 != nil ? "YES" : "NO")
        os_log("CarPlay: Sample iTunes artwork created: %@", log: log, type: .debug, sampleiTunesArtworkBase64 != nil ? "YES" : "NO")
        
        // Modify the first few stations to have artwork
        for i in 0..<min(5, allStations.count) {
            var station = allStations[i]
            let originalHasIcon = station.iconData != nil && !station.iconData!.isEmpty
            let originalHasiTunes = station.iTunesArtworkData != nil && !station.iTunesArtworkData!.isEmpty
            
            os_log("CarPlay: Station %d '%@' - BEFORE: iconData=%@, iTunesData=%@", log: log, type: .debug, 
                   i, station.name, originalHasIcon ? "YES" : "NO", originalHasiTunes ? "YES" : "NO")
            
            switch i {
            case 0:
                station.iconData = sampleStationArtworkBase64
                station.iTunesArtworkData = nil
                os_log("CarPlay: Station %d - Setting iconData only", log: log, type: .debug, i)
            case 1:
                station.iconData = nil
                station.iTunesArtworkData = sampleiTunesArtworkBase64
                os_log("CarPlay: Station %d - Setting iTunesArtworkData only", log: log, type: .debug, i)
            case 2:
                station.iconData = sampleStationArtworkBase64
                station.iTunesArtworkData = sampleiTunesArtworkBase64
                os_log("CarPlay: Station %d - Setting both iconData and iTunesArtworkData", log: log, type: .debug, i)
            case 3:
                station.iconData = sampleStationArtworkBase64
                station.iTunesArtworkData = nil
                os_log("CarPlay: Station %d - Setting iconData only", log: log, type: .debug, i)
            case 4:
                station.iconData = nil
                station.iTunesArtworkData = sampleiTunesArtworkBase64
                os_log("CarPlay: Station %d - Setting iTunesArtworkData only", log: log, type: .debug, i)
            default:
                break
            }
            allStations[i] = station
            
            // Verify the changes took effect
            let updatedStation = allStations[i]
            let newHasIcon = updatedStation.iconData != nil && !updatedStation.iconData!.isEmpty
            let newHasiTunes = updatedStation.iTunesArtworkData != nil && !updatedStation.iTunesArtworkData!.isEmpty
            
            os_log("CarPlay: Station %d '%@' - AFTER: iconData=%@, iTunesData=%@", log: log, type: .debug, 
                   i, updatedStation.name, newHasIcon ? "YES" : "NO", newHasiTunes ? "YES" : "NO")
        }
        
        // Update derived arrays
        favoriteStations = allStations.filter { $0.isFavorite }
        recentStations = allStations.filter { $0.lastPlayed != nil }
        
        os_log("CarPlay: Enhanced first 5 existing stations with sample artwork", log: log, type: .info)
        os_log("CarPlay: Updated arrays - favoriteStations: %d, recentStations: %d", log: log, type: .debug, favoriteStations.count, recentStations.count)
    }
    
    private func createSampleRadioStationArtwork() -> Data? {
        let size = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            // Create a radio-themed gradient
            let colors = [UIColor.systemRed.cgColor, UIColor.systemOrange.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
            
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            
            // Add radio wave pattern
            context.cgContext.setStrokeColor(UIColor.white.cgColor)
            context.cgContext.setLineWidth(3)
            
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 1...4 {
                let radius = CGFloat(i * 30)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.cgContext.strokeEllipse(in: rect)
            }
            
            // Add text
            let text = "RADIO"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: attributes, context: nil).size
            let textRect = CGRect(x: (size.width - textSize.width) / 2, y: size.height - 60, width: textSize.width, height: textSize.height)
            text.draw(in: textRect, withAttributes: attributes)
        }
        
        return image.pngData()
    }
    
    private func createSampleiTunesArtwork() -> Data? {
        let size = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            
            // Create a more realistic album artwork style with modern gradient
            let colors = [
                UIColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0),  // Nice blue
                UIColor(red: 0.8, green: 0.3, blue: 0.8, alpha: 1.0),  // Purple accent
                UIColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0)   // Dark base
            ]
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colorLocations: [CGFloat] = [0.0, 0.6, 1.0]
            let gradient = CGGradient(colorsSpace: colorSpace,
                                    colors: colors.map { $0.cgColor } as CFArray,
                                    locations: colorLocations)!
            
            // Create a diagonal gradient for modern look
            context.cgContext.drawLinearGradient(gradient,
                                               start: CGPoint(x: 0, y: 0),
                                               end: CGPoint(x: size.width, y: size.height),
                                               options: [])
            
            // Add abstract geometric shapes like modern album art
            context.cgContext.setBlendMode(.softLight)
            
            // Add some circles
            for i in 0..<3 {
                let circleSize = CGFloat(60 + i * 40)
                let alpha = 0.3 - CGFloat(i) * 0.1
                context.cgContext.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                
                let x = CGFloat(40 + i * 80)
                let y = CGFloat(50 + i * 50)
                let circleRect = CGRect(x: x, y: y, width: circleSize, height: circleSize)
                context.cgContext.fillEllipse(in: circleRect)
            }
            
            // Add a subtle border like real album artwork
            context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.2).cgColor)
            context.cgContext.setLineWidth(1.0)
            context.cgContext.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
            
            // Add track/song info text in the style of modern album art
            let songText = "♪ Now Playing"
            let artistText = "Live Radio"
            
            // Song title
            let songAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ]
            let songSize = songText.boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: songAttributes, context: nil).size
            let songRect = CGRect(x: (size.width - songSize.width) / 2, y: size.height - 80, width: songSize.width, height: songSize.height)
            songText.draw(in: songRect, withAttributes: songAttributes)
            
            // Artist name
            let artistAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7)
            ]
            let artistSize = artistText.boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: artistAttributes, context: nil).size
            let artistRect = CGRect(x: (size.width - artistSize.width) / 2, y: size.height - 50, width: artistSize.width, height: artistSize.height)
            artistText.draw(in: artistRect, withAttributes: artistAttributes)
        }
        
        return image.pngData()
    }
    
    private func updateRecentPodcastEpisodes() {
        // Extract recent episodes from all feeds (last 10 episodes across all feeds)
        var allEpisodes: [PodcastEpisode] = []
        for feed in podcastFeeds {
            allEpisodes.append(contentsOf: feed.episodes)
        }
        
        // Sort by publish date and take the most recent
        recentPodcastEpisodes = allEpisodes
            .sorted(by: { $0.publicationDate > $1.publicationDate })
            .prefix(10)
            .map { $0 }
        
        os_log("CarPlay: Updated recent podcast episodes - %d episodes", log: log, type: .debug, recentPodcastEpisodes.count)
    }
    
    // MARK: - Public Artwork Helper Methods
    
    /// Creates MPMediaItemArtwork for a podcast feed using the same priority system as CarPlay
    /// Priority: imageData -> iconData -> cached artwork -> fallback
    public func createPodcastArtwork(for feed: PodcastFeed, fallbackSystemImage: String = "podcast.fill") -> MPMediaItemArtwork? {
        // First priority: Direct image data
        if let imageData = feed.imageData, !imageData.isEmpty {
            return createSafeArtwork(from: imageData, fallbackSystemImage: fallbackSystemImage)
        }
        
        // Second priority: Base64 encoded icon data
        if let iconData = feed.iconData, !iconData.isEmpty,
           let base64Data = Data(base64Encoded: iconData), !base64Data.isEmpty {
            return createSafeArtwork(from: base64Data, fallbackSystemImage: fallbackSystemImage)
        }
        
        // Third priority: Check cached artwork
        let cacheKey = "feed_artwork_\(feed.id)"
        if let cachedImage = imageCache[cacheKey] {
            return MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
        }
        
        // Fallback to system image
        return createSafeArtwork(from: nil, fallbackSystemImage: fallbackSystemImage)
    }
    
    /// Downloads and caches artwork for a podcast feed if it has an artwork URL
    /// Returns true if download was initiated, false if no URL available
    @discardableResult
    public func downloadPodcastArtworkIfNeeded(for feed: PodcastFeed) -> Bool {
        // Check if we already have artwork
        let hasImageData = feed.imageData != nil && !feed.imageData!.isEmpty
        let hasIconData = feed.iconData != nil && !feed.iconData!.isEmpty
        let cacheKey = "feed_artwork_\(feed.id)"
        let hasCachedArtwork = imageCache[cacheKey] != nil
        
        if hasImageData || hasIconData || hasCachedArtwork {
            return false // Already have artwork
        }
        
        guard let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty,
              let artworkUrl = URL(string: artworkUrlString) else {
            return false // No URL available
        }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: artworkUrl)
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        // Cache the downloaded artwork
                        self.imageCache[cacheKey] = image
                        self.imageCacheAccessTimes[cacheKey] = Date()
                        
                        // Update the feed with downloaded artwork if we can find it
                        if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                            self.podcastFeeds[feedIndex].imageData = data
                        }
                        
                        os_log("CarPlay: Downloaded and cached artwork for podcast '%@' (%d bytes)", 
                               log: self.log, type: .info, feed.title, data.count)
                    }
                }
            } catch {
                os_log("CarPlay: Failed to download artwork for podcast '%@': %@", 
                       log: self.log, type: .error, feed.title, error.localizedDescription)
            }
        }
        
        return true
    }
    
    // MARK: - Public Data Access Methods for CarPlay Scene Delegate
    
    func getAvailableCountries() -> [String] {
        // Ensure we have fresh data
        updateContent()
        
        let countries = Array(stationsByCountry.keys).sorted()
        os_log("CarPlayManager: Available countries: %d", log: log, type: .info, countries.count)
        
        // If no countries from our data, try to get from RadioStationViewModel
        if countries.isEmpty {
            let allStations = RadioStationViewModel.shared.stations
            let countriesFromStations = Set(allStations.map { $0.country }).sorted()
            os_log("CarPlayManager: Fallback countries from RadioStationViewModel: %d", log: log, type: .info, countriesFromStations.count)
            return Array(countriesFromStations)
        }
        
        return countries
    }
    
    func getStations(for country: String) -> [RadioStation] {
        // First try our cached data
        var stations = stationsByCountry[country] ?? []
        
        // If no cached data, get from RadioStationViewModel
        if stations.isEmpty {
            stations = RadioStationViewModel.shared.stations.filter { $0.country == country }
            os_log("CarPlayManager: Fallback stations for %@: %d", log: log, type: .info, country, stations.count)
        }
        
        return stations
    }
    
    func getFavoriteStations() -> [RadioStation] {
        return favoriteStations
    }
    
    func getRecentStations() -> [RadioStation] {
        return recentStations
    }
    
    func getPodcastFeeds() -> [PodcastFeed] {
        return podcastFeeds
    }
    
    func getStationArtwork(for station: RadioStation) -> UIImage? {
        return createStationArtworkImage(for: station)
    }
    
    func getPodcastArtwork(for podcast: PodcastFeed) -> UIImage? {
        return createPodcastArtworkImage(for: podcast)
    }
    
    private func createStationArtworkImage(for station: RadioStation) -> UIImage? {
        os_log("🎨 CarPlay: Creating artwork for station '%@' - ONLY using station icon", log: log, type: .debug, station.name)
        
        // Log what artwork data is available (excluding iTunes artwork)
        let hasIconData = station.iconData != nil && !station.iconData!.isEmpty
        
        os_log("🎨 CarPlay: Station '%@' - iconData: %@", 
               log: log, type: .debug, station.name, 
               hasIconData ? "YES" : "NO")
        
        // ONLY use station icon data - NO iTunes artwork in CarPlay
        if let iconData = station.iconData,
           !iconData.isEmpty {
            os_log("🎨 CarPlay: Attempting to decode station icon for '%@' (length: %d)", 
                   log: log, type: .debug, station.name, iconData.count)
            
            if let imageData = Data(base64Encoded: iconData) {
                os_log("🎨 CarPlay: Successfully decoded base64 icon data for station '%@' (data size: %d bytes)", 
                       log: log, type: .debug, station.name, imageData.count)
                
                if let image = UIImage(data: imageData) {
                    os_log("🎨 CarPlay: ✅ Successfully created UIImage from station icon for '%@' (size: %.0fx%.0f)", 
                           log: log, type: .info, station.name, image.size.width, image.size.height)
                    return image
                } else {
                    os_log("🎨 CarPlay: ❌ Failed to create UIImage from station icon for '%@'", 
                           log: log, type: .error, station.name)
                }
            } else {
                os_log("🎨 CarPlay: ❌ Failed to decode base64 station icon for '%@'", 
                       log: log, type: .error, station.name)
            }
        }
        
        // Fallback to system image
        os_log("🎨 CarPlay: Using fallback system image for station '%@'", log: log, type: .info, station.name)
        return UIImage(systemName: "radio")
    }
    
    private func createPodcastArtworkImage(for podcast: PodcastFeed) -> UIImage? {
        // Try imageData first, then iconData, then fallback
        if let imageData = podcast.imageData,
           let image = UIImage(data: imageData) {
            return image
        }
        
        if let iconData = podcast.iconData,
           let imageData = Data(base64Encoded: iconData),
           let image = UIImage(data: imageData) {
            return image
        }
        
        // Fallback to system image
        return UIImage(systemName: "podcast")
    }
    
    @objc private func handleStationArtworkUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            os_log("🎨 CarPlay: Artwork update notification missing stationId", log: log, type: .error)
            return
        }
        
        os_log("🎨 CarPlay: Received real-time artwork update for station ID: %@", log: log, type: .info, stationId)
        
        // Find and update the station with new artwork from the radio player
        if let updatedStations = RadioStationViewModel.shared.stations as [RadioStation]? {
            // Update our local station data
            allStations = updatedStations
            favoriteStations = allStations.filter { $0.isFavorite }
            recentStations = allStations.filter { $0.lastPlayed != nil }
            stationsByCountry = Dictionary(grouping: allStations) { $0.country }
            
            // Log the artwork update
            if let updatedStation = allStations.first(where: { $0.id == stationId }) {
                let hasiTunes = updatedStation.iTunesArtworkData != nil && !updatedStation.iTunesArtworkData!.isEmpty
                os_log("🎨 CarPlay: Station '%@' now has iTunes artwork: %@ (data length: %d)", 
                       log: log, type: .info, updatedStation.name, hasiTunes ? "YES" : "NO", 
                       updatedStation.iTunesArtworkData?.count ?? 0)
            }
            
            // CRITICAL: Multiple strategies to force CarPlay interface refresh
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                os_log("🎨 CarPlay: Starting aggressive interface refresh...", log: self.log, type: .info)
                
                // Strategy 1: Standard reload data
                MPPlayableContentManager.shared().reloadData()
                os_log("🎨 CarPlay: Called reloadData()", log: self.log, type: .debug)
                
                // Strategy 2: Force refresh with slight delay to ensure data is processed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    MPPlayableContentManager.shared().reloadData()
                    os_log("🎨 CarPlay: Called delayed reloadData()", log: self.log, type: .debug)
                }
                
                // Strategy 3: If there's an active interface controller, try to refresh its current template
                // Note: interfaceController is managed by CarPlaySceneDelegate, not CarPlayManager
                os_log("🎨 CarPlay: Attempting template refresh via CarPlaySceneDelegate", log: self.log, type: .debug)
                
                // Strategy 4: Clear image cache to force re-creation of artwork
                self.clearImageCache()
                
                // Strategy 5: Force refresh of visible content items
                self.forceRefreshVisibleContent()
                
                os_log("🎨 CarPlay: Completed aggressive interface refresh sequence", log: self.log, type: .info)
            }
        } else {
            os_log("🎨 CarPlay: Failed to get updated stations from RadioStationViewModel", log: log, type: .error)
        }
    }
    
    private func clearImageCache() {
        // Clear the image cache to force re-creation of station artwork
        imageCache.removeAll()
        os_log("🎨 CarPlay: Cleared image cache to force artwork refresh", log: log, type: .debug)
    }
    
    private func forceRefreshVisibleContent() {
        // Try to refresh the currently visible content in CarPlay
        os_log("🎨 CarPlay: Attempting to force refresh visible content", log: log, type: .debug)
        
        // Strategy: Since CarPlaySceneDelegate handles templates, we need to trigger a refresh
        // through the MPPlayableContentManager delegate system
        
        // Force multiple reload calls with different timing
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MPPlayableContentManager.shared().reloadData()
            os_log("🎨 CarPlay: First immediate reloadData() call", log: self.log, type: .debug)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            MPPlayableContentManager.shared().reloadData()
            os_log("🎨 CarPlay: Second delayed reloadData() call", log: self.log, type: .debug)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            MPPlayableContentManager.shared().reloadData()
            os_log("🎨 CarPlay: Third delayed reloadData() call", log: self.log, type: .debug)
        }
        
        // Additional strategy: Post a notification to CarPlaySceneDelegate to trigger refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: NSNotification.Name("CarPlayRefreshRequested"), object: nil)
            os_log("🎨 CarPlay: Posted refresh notification to CarPlaySceneDelegate", log: self.log, type: .debug)
        }
        
        os_log("🎨 CarPlay: Initiated aggressive refresh sequence", log: log, type: .info)
    }
}

// MARK: - MPPlayableContentDataSource
extension CarPlayManager: MPPlayableContentDataSource {
    
    func numberOfChildItems(at indexPath: IndexPath) -> Int {
        os_log("CarPlay numberOfChildItems at indexPath: %@", log: log, type: .info, indexPath.description)
        
        if indexPath.isEmpty {
            // Root level: Home, Radio, Podcasts, Playlists
            return 4
        }
        
        switch indexPath[0] {
        case 0: // Home
            if indexPath.count == 1 {
                // Home sections: Recent Radio Stations, Recent Podcasts
                return 2
            } else if indexPath.count == 2 {
                switch indexPath[1] {
                case 0: // Recent Radio Stations
                    let count = min(recentStations.count, 5)
                    os_log("CarPlay: Home recent stations count: %d", log: log, type: .debug, count)
                    return count
                case 1: // Recent Podcast Episodes
                    let count = min(recentPodcastEpisodes.count, 5)
                    os_log("CarPlay: Home recent episodes count: %d", log: log, type: .debug, count)
                    return count
                default:
                    return 0
                }
            }
            
        case 1: // Radio
            if indexPath.count == 1 {
                // Radio main sections: Favorite Stations, Recent Stations, Local Stations
                return 3
            } else if indexPath.count == 2 {
                switch indexPath[1] {
                case 0: // Favorite Stations
                    let count = favoriteStations.count
                    os_log("CarPlay: Favorite stations count: %d", log: log, type: .debug, count)
                    return count
                case 1: // Recent Stations  
                    let count = recentStations.count
                    os_log("CarPlay: Recent stations count: %d", log: log, type: .debug, count)
                    return count
                case 2: // Local Stations (by country)
                    let count = availableCountries.count
                    os_log("CarPlay: Available countries count: %d - %@", log: log, type: .debug, count, availableCountries.joined(separator: ", "))
                    return count
                default:
                    return 0
                }
            } else if indexPath.count == 3 && indexPath[1] == 2 {
                // Stations in selected country
                let countryIndex = indexPath[2]
                if countryIndex < availableCountries.count {
                    let country = availableCountries[countryIndex]
                    let count = stationsByCountry[country]?.count ?? 0
                    os_log("CarPlay: Stations in country '%@': %d", log: log, type: .debug, country, count)
                    return count
                }
            }
            
        case 2: // Podcasts
            if indexPath.count == 1 {
                // Show individual podcasts directly
                let count = podcastFeeds.count
                os_log("CarPlay: All podcast feeds count: %d", log: log, type: .debug, count)
                return count
            } else if indexPath.count == 2 {
                // Show All, Favorites, Downloads for selected podcast
                let podcastIndex = indexPath[1]
                if podcastIndex < podcastFeeds.count {
                    return 3 // All, Favorites, Downloads tabs
                }
                return 0
            } else if indexPath.count == 3 {
                // Show episodes for selected podcast category
                let podcastIndex = indexPath[1]
                let categoryIndex = indexPath[2]
                
                if podcastIndex < podcastFeeds.count {
                    let selectedFeed = podcastFeeds[podcastIndex]
                    
                    switch categoryIndex {
                    case 0: // All episodes
                        let count = selectedFeed.episodes.count
                        os_log("CarPlay: All episodes in podcast '%@': %d (total episodes in feed: %d)", log: log, type: .debug, selectedFeed.title, count, selectedFeed.episodes.count)
                        if count == 0 {
                            os_log("CarPlay: WARNING - No episodes found for podcast '%@'. Feed URL: %@", log: log, type: .error, selectedFeed.title, selectedFeed.url)
                        }
                        return count
                    case 1: // Favorite episodes
                        let favoriteEpisodes = selectedFeed.episodes.filter { $0.state.isFavorite }
                        let count = favoriteEpisodes.count
                        os_log("CarPlay: Favorite episodes in podcast '%@': %d out of %d total", log: log, type: .debug, selectedFeed.title, count, selectedFeed.episodes.count)
                        return count
                    case 2: // Downloaded episodes
                        let downloadedEpisodes = selectedFeed.episodes.filter { $0.state.isDownloaded }
                        let count = downloadedEpisodes.count
                        os_log("CarPlay: Downloaded episodes in podcast '%@': %d out of %d total", log: log, type: .debug, selectedFeed.title, count, selectedFeed.episodes.count)
                        return count
                    default:
                        return 0
                    }
                }
            }
            
        case 3: // Playlists
            return 0 // Playlists functionality to be implemented later
            
        default:
            return 0
        }
        
        return 0
    }
    
    func contentItem(at indexPath: IndexPath) -> MPContentItem? {
        os_log("CarPlay contentItem at indexPath: %@", log: log, type: .info, indexPath.description)
        
        if indexPath.isEmpty {
            return nil
        }
        
        if indexPath.count == 1 {
            // Root level navigation tabs
            switch indexPath[0] {
            case 0:
                let homeItem = MPContentItem(identifier: "home")
                homeItem.title = "Home"
                homeItem.subtitle = "Recent activity"
                homeItem.isContainer = true
                homeItem.isPlayable = false
                if let homeImage = UIImage(systemName: "house.fill") {
                    homeItem.artwork = MPMediaItemArtwork(boundsSize: homeImage.size) { _ in homeImage }
                }
                return homeItem
                
            case 1:
                let radioItem = MPContentItem(identifier: "radio")
                radioItem.title = "Radio"
                radioItem.subtitle = "Browse stations"
                radioItem.isContainer = true
                radioItem.isPlayable = false
                if let radioImage = UIImage(systemName: "radio.fill") {
                    radioItem.artwork = MPMediaItemArtwork(boundsSize: radioImage.size) { _ in radioImage }
                }
                return radioItem
                
            case 2:
                let podcastItem = MPContentItem(identifier: "podcasts")
                podcastItem.title = "Podcasts"
                podcastItem.subtitle = "\(podcastFeeds.count) podcasts available"
                podcastItem.isContainer = true
                podcastItem.isPlayable = false
                if let podcastImage = UIImage(systemName: "podcast.fill") {
                    podcastItem.artwork = MPMediaItemArtwork(boundsSize: podcastImage.size) { _ in podcastImage }
                }
                return podcastItem
                
            case 3:
                let playlistItem = MPContentItem(identifier: "playlists")
                playlistItem.title = "Playlists"
                playlistItem.subtitle = "Custom playlists"
                playlistItem.isContainer = true
                playlistItem.isPlayable = false
                if let playlistImage = UIImage(systemName: "list.bullet.rectangle.portrait.fill") {
                    playlistItem.artwork = MPMediaItemArtwork(boundsSize: playlistImage.size) { _ in playlistImage }
                }
                return playlistItem
                
            default:
                return nil
            }
        }
        
        if indexPath.count == 2 {
            switch indexPath[0] {
            case 0: // Home sections
                switch indexPath[1] {
                case 0:
                    let recentRadioItem = MPContentItem(identifier: "home-recent-radio")
                    recentRadioItem.title = "Recent Radio Stations"
                    recentRadioItem.subtitle = "\(min(recentStations.count, 5)) stations"
                    recentRadioItem.isContainer = true
                    recentRadioItem.isPlayable = false
                    if let radioImage = UIImage(systemName: "clock.arrow.circlepath") {
                        recentRadioItem.artwork = MPMediaItemArtwork(boundsSize: radioImage.size) { _ in radioImage }
                    }
                    return recentRadioItem
                    
                case 1:
                    let recentPodcastItem = MPContentItem(identifier: "home-recent-podcasts")
                    recentPodcastItem.title = "Recent Podcasts"
                    recentPodcastItem.subtitle = "\(min(recentPodcastEpisodes.count, 5)) episodes"
                    recentPodcastItem.isContainer = true
                    recentPodcastItem.isPlayable = false
                    if let podcastImage = UIImage(systemName: "gobackward") {
                        recentPodcastItem.artwork = MPMediaItemArtwork(boundsSize: podcastImage.size) { _ in podcastImage }
                    }
                    return recentPodcastItem
                    
                default:
                    return nil
                }
                
            case 1: // Radio sections
                switch indexPath[1] {
                case 0:
                    let favoritesItem = MPContentItem(identifier: "radio-favorites")
                    favoritesItem.title = "Favorite Stations"
                    favoritesItem.subtitle = "\(favoriteStations.count) stations"
                    favoritesItem.isContainer = true
                    favoritesItem.isPlayable = false
                    if let favImage = UIImage(systemName: "heart.fill") {
                        favoritesItem.artwork = MPMediaItemArtwork(boundsSize: favImage.size) { _ in favImage }
                    }
                    return favoritesItem
                    
                case 1:
                    let recentItem = MPContentItem(identifier: "radio-recent")
                    recentItem.title = "Recent Stations"
                    recentItem.subtitle = "\(recentStations.count) stations"
                    recentItem.isContainer = true
                    recentItem.isPlayable = false
                    if let recentImage = UIImage(systemName: "clock.fill") {
                        recentItem.artwork = MPMediaItemArtwork(boundsSize: recentImage.size) { _ in recentImage }
                    }
                    return recentItem
                    
                case 2:
                    let localItem = MPContentItem(identifier: "radio-local")
                    localItem.title = "Local Stations"
                    localItem.subtitle = "\(availableCountries.count) countries"
                    localItem.isContainer = true
                    localItem.isPlayable = false
                    if let localImage = UIImage(systemName: "location.fill") {
                        localItem.artwork = MPMediaItemArtwork(boundsSize: localImage.size) { _ in localImage }
                    }
                    return localItem
                    
                default:
                    return nil
                }
                
            case 2: // Individual podcasts
                let podcastIndex = indexPath[1]
                if podcastIndex < podcastFeeds.count {
                    let feed = podcastFeeds[podcastIndex]
                    let feedItem = MPContentItem(identifier: "podcast-feed-\(feed.id)")
                    feedItem.title = feed.title
                    feedItem.subtitle = "\(feed.episodes.count) episodes"
                    feedItem.isContainer = true
                    feedItem.isPlayable = false
                    
                    // Use podcast artwork safely - try imageData, iconData, and cached artwork
                    var artworkData: Data?
                    var artworkSource = "none"
                    
                    if let imageData = feed.imageData, !imageData.isEmpty {
                        artworkData = imageData
                        artworkSource = "imageData"
                    } else if let iconData = feed.iconData, !iconData.isEmpty,
                              let base64Data = Data(base64Encoded: iconData), !base64Data.isEmpty {
                        artworkData = base64Data
                        artworkSource = "iconData"
                    } else {
                        // Check for cached artwork from our fetch attempt
                        let cacheKey = "feed_artwork_\(feed.id)"
                        if let cachedImage = imageCache[cacheKey] {
                            artworkSource = "cached"
                            os_log("CarPlay: Using cached artwork for podcast '%@'", log: log, type: .debug, feed.title)
                            feedItem.artwork = MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
                        } else if let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty {
                            // Try to download artwork asynchronously and use a fallback for now
                            artworkSource = "downloading"
                            os_log("CarPlay: Attempting to download artwork for podcast '%@' from URL: %@", log: log, type: .info, feed.title, artworkUrlString)
                            
                            // Set a fallback icon for now
                            feedItem.artwork = createSafeArtwork(from: nil, fallbackSystemImage: "podcast.fill")
                            
                            // Download artwork asynchronously
                            if let artworkUrl = URL(string: artworkUrlString) {
                                Task {
                                    do {
                                        let (data, _) = try await URLSession.shared.data(from: artworkUrl)
                                        if let image = UIImage(data: data) {
                                            await MainActor.run {
                                                // Cache the downloaded artwork
                                                self.imageCache[cacheKey] = image
                                                self.imageCacheAccessTimes[cacheKey] = Date()
                                                
                                                // Update the feed with downloaded artwork
                                                if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                                                    self.podcastFeeds[feedIndex].imageData = data
                                                }
                                                
                                                // Refresh CarPlay to show the new artwork
                                                MPPlayableContentManager.shared().reloadData()
                                                os_log("CarPlay: Downloaded and cached artwork for podcast '%@'", log: self.log, type: .info, feed.title)
                                            }
                                        }
                                    } catch {
                                        os_log("CarPlay: Failed to download artwork for podcast '%@': %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                                    }
                                }
                            }
                        }
                    }
                    
                    if artworkSource != "cached" && artworkSource != "downloading" {
                        os_log("CarPlay: Setting artwork for podcast '%@' from %@", log: log, type: .debug, feed.title, artworkSource)
                        feedItem.artwork = createSafeArtwork(from: artworkData, fallbackSystemImage: "podcast.fill")
                    }
                    
                    return feedItem
                }
                return nil
                
            default:
                return nil
            }
        }
        
        if indexPath.count == 3 {
            switch indexPath[0] {
            case 0: // Home content items
                switch indexPath[1] {
                case 0: // Recent Radio Stations
                    let stationIndex = indexPath[2]
                    if stationIndex < recentStations.count {
                        let station = recentStations[stationIndex]
                        let stationItem = MPContentItem(identifier: "home-radio-station-\(station.id)")
                        stationItem.title = station.name
                        stationItem.subtitle = station.country
                        stationItem.isContainer = false
                        stationItem.isPlayable = true
                        
                        // Add station artwork safely - ONLY use station icon data, NO iTunes artwork
                        let hasIconData = station.iconData != nil && !station.iconData!.isEmpty
                        os_log("CarPlay: Home station '%@' has iconData: %@", log: log, type: .debug, 
                               station.name, hasIconData ? "true" : "false")
                        
                        if hasIconData {
                            stationItem.artwork = createSafeArtworkFromBase64(station.iconData, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using station icon for home station '%@'", log: log, type: .debug, station.name)
                        } else {
                            stationItem.artwork = createSafeArtworkFromBase64(nil, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using fallback artwork for home station '%@'", log: log, type: .debug, station.name)
                        }
                        
                        return stationItem
                    }
                    
                case 1: // Recent Podcast Episodes
                    let episodeIndex = indexPath[2]
                    if episodeIndex < recentPodcastEpisodes.count {
                        let episode = recentPodcastEpisodes[episodeIndex]
                        let episodeItem = MPContentItem(identifier: "home-podcast-episode-\(episode.id)")
                        episodeItem.title = episode.title
                        episodeItem.subtitle = formatDuration(episode.duration)
                        episodeItem.isContainer = false
                        episodeItem.isPlayable = true
                        
                        // Use podcast feed artwork safely - try imageData, iconData, and cached artwork
                        if let feed = findPodcastFeedForEpisode(episode) {
                            var artworkData: Data?
                            var artworkSource = "none"
                            
                            if let imageData = feed.imageData, !imageData.isEmpty {
                                artworkData = imageData
                                artworkSource = "imageData"
                            } else if let iconData = feed.iconData, !iconData.isEmpty,
                                      let base64Data = Data(base64Encoded: iconData), !base64Data.isEmpty {
                                artworkData = base64Data
                                artworkSource = "iconData"
                            } else {
                                // Check for cached artwork from our fetch attempt
                                let cacheKey = "feed_artwork_\(feed.id)"
                                if let cachedImage = imageCache[cacheKey] {
                                    artworkSource = "cached"
                                    os_log("CarPlay: Using cached artwork for episode '%@'", log: log, type: .debug, episode.title)
                                    episodeItem.artwork = MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
                                }
                            }
                            
                            if artworkSource != "cached" {
                                os_log("CarPlay: Setting episode artwork for '%@' from %@", log: log, type: .debug, episode.title, artworkSource)
                                episodeItem.artwork = createSafeArtwork(from: artworkData, fallbackSystemImage: "podcast.fill")
                            }
                        } else {
                            episodeItem.artwork = createSafeArtwork(from: nil, fallbackSystemImage: "podcast.fill")
                        }
                        
                        return episodeItem
                    }
                    
                default:
                    return nil
                }
                
            case 1: // Radio station lists
                let sectionIndex = indexPath[1]
                let itemIndex = indexPath[2]
                
                switch sectionIndex {
                case 0: // Favorite Stations
                    if itemIndex < favoriteStations.count {
                        let station = favoriteStations[itemIndex]
                        let stationItem = MPContentItem(identifier: "radio-favorite-station-\(station.id)")
                        stationItem.title = station.name
                        stationItem.subtitle = station.country
                        stationItem.isContainer = false
                        stationItem.isPlayable = true
                        
                        // Add station artwork safely - ONLY use station icon data, NO iTunes artwork
                        let hasIconData = station.iconData != nil && !station.iconData!.isEmpty
                        os_log("CarPlay: Favorite station '%@' has iconData: %@", log: log, type: .debug, 
                               station.name, hasIconData ? "true" : "false")
                        
                        if hasIconData {
                            stationItem.artwork = createSafeArtworkFromBase64(station.iconData, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using station icon for favorite station '%@'", log: log, type: .debug, station.name)
                        } else {
                            stationItem.artwork = createSafeArtworkFromBase64(nil, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using fallback artwork for favorite station '%@'", log: log, type: .debug, station.name)
                        }
                        
                        return stationItem
                    }
                    
                case 1: // Recent Stations
                    if itemIndex < recentStations.count {
                        let station = recentStations[itemIndex]
                        let stationItem = MPContentItem(identifier: "radio-recent-station-\(station.id)")
                        stationItem.title = station.name
                        stationItem.subtitle = station.country
                        stationItem.isContainer = false
                        stationItem.isPlayable = true
                        
                        // Add station artwork safely - ONLY use station icon data, NO iTunes artwork
                        let hasIconData = station.iconData != nil && !station.iconData!.isEmpty
                        os_log("CarPlay: Recent station '%@' has iconData: %@", log: log, type: .debug, 
                               station.name, hasIconData ? "true" : "false")
                        
                        if hasIconData {
                            stationItem.artwork = createSafeArtworkFromBase64(station.iconData, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using station icon for recent station '%@'", log: log, type: .debug, station.name)
                        } else {
                            stationItem.artwork = createSafeArtworkFromBase64(nil, fallbackSystemImage: "radio")
                            os_log("CarPlay: Using fallback artwork for recent station '%@'", log: log, type: .debug, station.name)
                        }
                        
                        return stationItem
                    }
                    
                case 2: // Local Stations (Countries)
                    if itemIndex < availableCountries.count {
                        let country = availableCountries[itemIndex]
                        let countryStations = stationsByCountry[country] ?? []
                        
                        let countryItem = MPContentItem(identifier: "radio-country-\(country)")
                        countryItem.title = country
                        countryItem.subtitle = "\(countryStations.count) stations"
                        countryItem.isContainer = true
                        countryItem.isPlayable = false
                        
                        // No artwork for country items - removed flag icons
                        // countryItem.artwork = nil
                        
                        return countryItem
                    }
                    
                default:
                    return nil
                }
                
            case 2: // Podcast episode categories (All, Favorites, Downloads)
                let podcastIndex = indexPath[1]
                let categoryIndex = indexPath[2]
                
                if podcastIndex < podcastFeeds.count {
                    let selectedFeed = podcastFeeds[podcastIndex]
                    
                    switch categoryIndex {
                    case 0:
                        let allItem = MPContentItem(identifier: "podcast-\(selectedFeed.id)-all")
                        allItem.title = "All"
                        allItem.subtitle = "\(selectedFeed.episodes.count) episodes"
                        allItem.isContainer = true
                        allItem.isPlayable = false
                        if let allImage = UIImage(systemName: "list.bullet") {
                            allItem.artwork = MPMediaItemArtwork(boundsSize: allImage.size) { _ in allImage }
                        }
                        os_log("CarPlay: Created 'All' category for podcast '%@' with %d episodes", log: log, type: .debug, selectedFeed.title, selectedFeed.episodes.count)
                        return allItem
                        
                    case 1:
                        let favoriteEpisodes = selectedFeed.episodes.filter { $0.state.isFavorite }
                        let favoritesItem = MPContentItem(identifier: "podcast-\(selectedFeed.id)-favorites")
                        favoritesItem.title = "Favorites"
                        favoritesItem.subtitle = "\(favoriteEpisodes.count) episodes"
                        favoritesItem.isContainer = true
                        favoritesItem.isPlayable = false
                        if let favImage = UIImage(systemName: "heart.fill") {
                            favoritesItem.artwork = MPMediaItemArtwork(boundsSize: favImage.size) { _ in favImage }
                        }
                        return favoritesItem
                        
                    case 2:
                        let downloadedEpisodes = selectedFeed.episodes.filter { $0.state.isDownloaded }
                        let downloadsItem = MPContentItem(identifier: "podcast-\(selectedFeed.id)-downloads")
                        downloadsItem.title = "Downloads"
                        downloadsItem.subtitle = "\(downloadedEpisodes.count) episodes"
                        downloadsItem.isContainer = true
                        downloadsItem.isPlayable = false
                        if let downloadImage = UIImage(systemName: "arrow.down.circle.fill") {
                            downloadsItem.artwork = MPMediaItemArtwork(boundsSize: downloadImage.size) { _ in downloadImage }
                        }
                        return downloadsItem
                        
                    default:
                        return nil
                    }
                }
                return nil
                
            default:
                return nil
            }
        }
        
        if indexPath.count == 4 {
            switch indexPath[0] {
            case 1: // Country stations
                if indexPath[1] == 2 { // Local Stations section
                    let countryIndex = indexPath[2]
                    let stationIndex = indexPath[3]
                    
                    if countryIndex < availableCountries.count {
                        let country = availableCountries[countryIndex]
                        let countryStations = stationsByCountry[country] ?? []
                        
                        if stationIndex < countryStations.count {
                            let station = countryStations[stationIndex]
                            let stationItem = MPContentItem(identifier: "radio-country-station-\(station.id)")
                            stationItem.title = station.name
                            stationItem.subtitle = station.country
                            stationItem.isContainer = false
                            stationItem.isPlayable = true
                            
                            // Add station artwork safely - debug and prioritize iTunes artwork
                            // Add station artwork safely - ONLY use station icon data, NO iTunes artwork
                            let hasIconData = station.iconData != nil && !station.iconData!.isEmpty
                            os_log("CarPlay: Country station '%@' has iconData: %@", log: log, type: .debug, 
                                   station.name, hasIconData ? "true" : "false")
                            
                            if hasIconData {
                                stationItem.artwork = createSafeArtworkFromBase64(station.iconData, fallbackSystemImage: "radio")
                                os_log("CarPlay: Using station icon for country station '%@'", log: log, type: .debug, station.name)
                            } else {
                                stationItem.artwork = createSafeArtworkFromBase64(nil, fallbackSystemImage: "radio")
                                os_log("CarPlay: Using fallback artwork for country station '%@'", log: log, type: .debug, station.name)
                            }
                            
                            return stationItem
                        }
                    }
                }
                
            case 2: // Podcast episodes
                let podcastIndex = indexPath[1]
                let categoryIndex = indexPath[2]
                let episodeIndex = indexPath[3]
                
                if podcastIndex < podcastFeeds.count {
                    let selectedFeed = podcastFeeds[podcastIndex]
                    
                    let episodes: [PodcastEpisode]
                    switch categoryIndex {
                    case 0: // All episodes
                        episodes = selectedFeed.episodes
                    case 1: // Favorite episodes
                        episodes = selectedFeed.episodes.filter { $0.state.isFavorite }
                    case 2: // Downloaded episodes
                        episodes = selectedFeed.episodes.filter { $0.state.isDownloaded }
                    default:
                        return nil
                    }
                    
                    if episodeIndex < episodes.count {
                        let episode = episodes[episodeIndex]
                        let episodeItem = MPContentItem(identifier: "podcast-episode-\(episode.id)")
                        episodeItem.title = episode.title
                        episodeItem.subtitle = formatDuration(episode.duration)
                        episodeItem.isContainer = false
                        episodeItem.isPlayable = true
                        
                        // Use podcast feed artwork for episodes safely - try both imageData and iconData
                        var artworkData: Data?
                        var artworkSource = "none"
                        
                        if let imageData = selectedFeed.imageData, !imageData.isEmpty {
                            artworkData = imageData
                            artworkSource = "imageData"
                        } else if let iconData = selectedFeed.iconData, !iconData.isEmpty,
                                  let base64Data = Data(base64Encoded: iconData), !base64Data.isEmpty {
                            artworkData = base64Data
                            artworkSource = "iconData"
                        }
                        
                        os_log("CarPlay: Setting episode artwork for '%@' from %@ (feed: %@)", log: log, type: .debug, episode.title, artworkSource, selectedFeed.title)
                        episodeItem.artwork = createSafeArtwork(from: artworkData, fallbackSystemImage: "podcast.fill")
                        
                        return episodeItem
                    }
                }
                
            default:
                return nil
            }
        }
        
        return nil
    }
}

// MARK: - MPPlayableContentDelegate
extension CarPlayManager: MPPlayableContentDelegate {
    
    func playableContentManager(_ contentManager: MPPlayableContentManager, initiatePlaybackOfContentItemAt indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        os_log("CarPlay initiatePlaybackOfContentItemAt: %@", log: log, type: .info, indexPath.description)
        
        // Handle Home recent content playback
        if indexPath.count == 3 && indexPath[0] == 0 {
            switch indexPath[1] {
            case 0: // Recent Radio Stations
                let stationIndex = indexPath[2]
                if stationIndex < recentStations.count {
                    let station = recentStations[stationIndex]
                    
                    DispatchQueue.main.async {
                        // Stop podcast if playing
                        if PodcastPlayer.shared.isPlaying {
                            PodcastPlayer.shared.pause()
                        }
                        
                        // Play the selected radio station
                        RadioPlayer.shared.playStation(at: self.findStationIndex(station), from: self.allStations)
                        completionHandler(nil)
                    }
                } else {
                    completionHandler(NSError(domain: "CarPlayError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recent station not found"]))
                }
                return
                
            case 1: // Recent Podcast Episodes
                let episodeIndex = indexPath[2]
                if episodeIndex < recentPodcastEpisodes.count {
                    let episode = recentPodcastEpisodes[episodeIndex]
                    
                    DispatchQueue.main.async {
                        // Stop radio if playing
                        if RadioPlayer.shared.isPlaying {
                            RadioPlayer.shared.pause()
                        }
                        
                        // Find the podcast feed for this episode
                        if let feed = self.findPodcastFeedForEpisode(episode) {
                            PodcastPlayer.shared.playEpisode(episode, feed: feed)
                            completionHandler(nil)
                        } else {
                            completionHandler(NSError(domain: "CarPlayError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Podcast feed not found for episode"]))
                        }
                    }
                } else {
                    completionHandler(NSError(domain: "CarPlayError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recent episode not found"]))
                }
                return
                
            default:
                completionHandler(NSError(domain: "CarPlayError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid home content"]))
                return
            }
        }
        
        // Handle Radio station playback
        if indexPath.count == 3 && indexPath[0] == 1 {
            let sectionIndex = indexPath[1]
            let stationIndex = indexPath[2]
            
            let stations: [RadioStation]
            switch sectionIndex {
            case 0: // Favorite Stations
                stations = favoriteStations
            case 1: // Recent Stations
                stations = recentStations
            default:
                completionHandler(NSError(domain: "CarPlayError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid radio section"]))
                return
            }
            
            if stationIndex < stations.count {
                let station = stations[stationIndex]
                
                DispatchQueue.main.async {
                    // Stop podcast if playing
                    if PodcastPlayer.shared.isPlaying {
                        PodcastPlayer.shared.pause()
                    }
                    
                    // Play the selected radio station
                    RadioPlayer.shared.playStation(at: self.findStationIndex(station), from: self.allStations)
                    completionHandler(nil)
                }
            } else {
                completionHandler(NSError(domain: "CarPlayError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Station not found"]))
            }
            return
        }
        
        // Handle Country station playback
        if indexPath.count == 4 && indexPath[0] == 1 && indexPath[1] == 2 {
            let countryIndex = indexPath[2]
            let stationIndex = indexPath[3]
            
            if countryIndex < availableCountries.count {
                let country = availableCountries[countryIndex]
                let countryStations = stationsByCountry[country] ?? []
                
                if stationIndex < countryStations.count {
                    let station = countryStations[stationIndex]
                    
                    DispatchQueue.main.async {
                        // Stop podcast if playing
                        if PodcastPlayer.shared.isPlaying {
                            PodcastPlayer.shared.pause()
                        }
                        
                        // Play the selected radio station
                        RadioPlayer.shared.playStation(at: self.findStationIndex(station), from: self.allStations)
                        completionHandler(nil)
                    }
                } else {
                    completionHandler(NSError(domain: "CarPlayError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Country station not found"]))
                }
            } else {
                completionHandler(NSError(domain: "CarPlayError", code: 8, userInfo: [NSLocalizedDescriptionKey: "Country not found"]))
            }
            return
        }
        
        // Handle Podcast episode playback
        if indexPath.count == 4 && indexPath[0] == 2 {
            let podcastIndex = indexPath[1]
            let categoryIndex = indexPath[2]
            let episodeIndex = indexPath[3]
            
            if podcastIndex < podcastFeeds.count {
                let selectedFeed = podcastFeeds[podcastIndex]
                
                let episodes: [PodcastEpisode]
                switch categoryIndex {
                case 0: // All episodes
                    episodes = selectedFeed.episodes
                case 1: // Favorite episodes
                    episodes = selectedFeed.episodes.filter { $0.state.isFavorite }
                case 2: // Downloaded episodes
                    episodes = selectedFeed.episodes.filter { $0.state.isDownloaded }
                default:
                    completionHandler(NSError(domain: "CarPlayError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid podcast category"]))
                    return
                }
                
                if episodeIndex < episodes.count {
                    let episode = episodes[episodeIndex]
                    
                    DispatchQueue.main.async {
                        // Stop radio if playing
                        if RadioPlayer.shared.isPlaying {
                            RadioPlayer.shared.pause()
                        }
                        
                        // Play the selected podcast episode
                        PodcastPlayer.shared.playEpisode(episode, feed: selectedFeed)
                        completionHandler(nil)
                    }
                } else {
                    completionHandler(NSError(domain: "CarPlayError", code: 10, userInfo: [NSLocalizedDescriptionKey: "Episode not found"]))
                }
            } else {
                completionHandler(NSError(domain: "CarPlayError", code: 11, userInfo: [NSLocalizedDescriptionKey: "Podcast feed not found"]))
            }
            return
        }
        
        completionHandler(NSError(domain: "CarPlayError", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid index path for playback"]))
    }
    
    func beginLoadingChildItems(at indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        os_log("CarPlay beginLoadingChildItems at: %@", log: log, type: .info, indexPath.description)
        completionHandler(nil)
    }
} 
