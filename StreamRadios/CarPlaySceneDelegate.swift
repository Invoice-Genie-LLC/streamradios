//
//  CarPlaySceneDelegate.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/19/24.
//

import UIKit
import CarPlay
import os.log
import CoreData

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    
    private let log = OSLog(subsystem: "com.streamradios.carplay", category: "SceneDelegate")
    var interfaceController: CPInterfaceController?
    
    // MARK: - Scene Delegate Methods
    
    /// Initialize CarPlay data independently from the main app
    /// This ensures CarPlay works even when the main app isn't running
    private func initializeCarPlayData() async {
        os_log("🚗 CarPlay: Initializing data independently", log: log, type: .info)
        print("🚗 CarPlay: Starting independent data initialization...")
        
        // Load podcast feeds and episodes from Core Data directly
        await loadPodcastDataFromCoreData()
        
        // Load radio stations from the shared view model
        await loadRadioStationsData()
        
        os_log("🚗 CarPlay: Data initialization complete", log: log, type: .info)
        print("🚗 CarPlay: Independent data initialization complete")
    }
    
    /// Load podcast data directly from Core Data for CarPlay
    private func loadPodcastDataFromCoreData() async {
        os_log("🚗 CarPlay: Loading podcast data from Core Data", log: log, type: .info)
        
        let context = CoreDataStack.shared.context
        
        // Load podcast feeds first
        let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
        var podcastFeeds: [PodcastFeed] = []
        
        do {
            let managedFeeds = try context.fetch(feedRequest)
            os_log("🚗 CarPlay: Found %d podcast feeds in Core Data", log: log, type: .info, managedFeeds.count)
            
            // Convert each managed feed to PodcastFeed and load its episodes
            for managedFeed in managedFeeds {
                var feed = managedFeed.toPodcastFeed()
                
                // Load episodes for this feed
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                do {
                    let managedEpisodes = try context.fetch(episodeRequest)
                    let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                        var episode = managedEpisode.toPodcastEpisode()
                        episode.state.isPlayed = managedEpisode.isPlayed
                        episode.state.progress = managedEpisode.progress
                        episode.state.isFavorite = managedEpisode.isFavorite
                        episode.state.isDownloaded = managedEpisode.isDownloaded
                        return episode
                    }
                    
                    feed.episodes = episodes
                    os_log("🚗 CarPlay: Loaded %d episodes for feed '%@'", log: log, type: .debug, episodes.count, feed.title)
                    
                } catch {
                    os_log("🚗 CarPlay: Error loading episodes for feed '%@': %@", log: log, type: .error, feed.title, error.localizedDescription)
                }
                
                podcastFeeds.append(feed)
            }
            
            // Configure CarPlayManager with the loaded podcast data
            await MainActor.run {
                CarPlayManager.shared.configurePodcastData(podcastFeeds)
                os_log("🚗 CarPlay: Configured CarPlayManager with %d podcast feeds", log: self.log, type: .info, podcastFeeds.count)
                print("🚗 CarPlay: Configured with \(podcastFeeds.count) podcast feeds")
            }
            
        } catch {
            os_log("🚗 CarPlay: Error loading podcast feeds from Core Data: %@", log: log, type: .error, error.localizedDescription)
            print("🚗 CarPlay: Error loading podcast feeds: \(error.localizedDescription)")
            
            // Fallback: Initialize with empty data so CarPlay still works
            await MainActor.run {
                CarPlayManager.shared.configurePodcastData([])
                os_log("🚗 CarPlay: Fallback - configured with empty podcast data", log: self.log, type: .info)
            }
        }
    }
    
    /// Load radio stations data for CarPlay
    private func loadRadioStationsData() async {
        os_log("🚗 CarPlay: Loading radio stations data", log: log, type: .info)
        
        await MainActor.run {
            // Ensure RadioStationViewModel is initialized
            let radioViewModel = RadioStationViewModel.shared
            let stations = radioViewModel.stations
            
            // Update CarPlayManager with radio station data
            CarPlayManager.shared.updateContent()
            
            os_log("🚗 CarPlay: Loaded %d radio stations", log: self.log, type: .info, stations.count)
            print("🚗 CarPlay: Loaded \(stations.count) radio stations")
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, 
                                didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        os_log("🚗 CarPlay scene connected successfully!", log: log, type: .info)
        
        // Print debug info
        print("🚗 CarPlay: Scene delegate didConnect called")
        print("🚗 CarPlay: Interface controller: \(interfaceController)")
        
        // Ensure CarPlayManager is properly initialized with data
        let carPlayManager = CarPlayManager.shared
        print("🚗 CarPlay: CarPlayManager initialized")
        
        // Initialize podcast data independently for CarPlay
        // This ensures CarPlay works even when the main app isn't running
        Task {
            await self.initializeCarPlayData()
            
            // Set up the interface after data is loaded
            await MainActor.run {
                self.setupRootTemplate()
            }
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, 
                                didDisconnect interfaceController: CPInterfaceController) {
        os_log("🚗 CarPlay scene disconnected", log: log, type: .info)
        print("🚗 CarPlay: Scene delegate didDisconnect called")
        self.interfaceController = nil
    }
    
    // MARK: - CarPlay Interface Setup
    
    private func setupRootTemplate() {
        guard let interfaceController = self.interfaceController else {
            os_log("❌ CarPlay interface controller not available", log: log, type: .error)
            print("❌ CarPlay: Interface controller is nil!")
            return
        }
        
        os_log("🚗 Setting up CarPlay root template", log: log, type: .info)
        print("🚗 CarPlay: Starting template setup...")
        
        // Create the 4 main tabs
        print("🚗 CarPlay: Creating stations tab...")
        let stationsTab = self.createStationsTab()
        print("🚗 CarPlay: Creating favorites tab...")
        let favoritesTab = self.createFavoritesTab()
        print("🚗 CarPlay: Creating recents tab...")
        let recentsTab = self.createRecentsTab() 
        print("🚗 CarPlay: Creating podcasts tab...")
        let podcastsTab = self.createPodcastsTab()
        
        print("🚗 CarPlay: Creating tab bar template with \([stationsTab, favoritesTab, recentsTab, podcastsTab].count) tabs")
        
        // Create tab bar template
        let tabBarTemplate = CPTabBarTemplate(templates: [stationsTab, favoritesTab, recentsTab, podcastsTab])
        
        print("🚗 CarPlay: Setting root template...")
        
        // Set as root template
        interfaceController.setRootTemplate(tabBarTemplate, animated: true, completion: { success, error in
            if success {
                os_log("✅ CarPlay root template set successfully", log: self.log, type: .info)
                print("✅ CarPlay: Root template set successfully!")
            } else {
                os_log("❌ Failed to set CarPlay root template: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                print("❌ CarPlay: Failed to set root template: \(error?.localizedDescription ?? "Unknown error")")
            }
        })
    }
    
    // MARK: - Tab Creation Methods
    
    private func createStationsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get countries and stations from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let availableCountries = carPlayManager.getAvailableCountries()
        
        os_log("🚗 CarPlay: Creating stations tab with %d countries", log: log, type: .info, availableCountries.count)
        print("🚗 CarPlay: Available countries: \(availableCountries.count)")
        print("🚗 CarPlay: Countries: \(availableCountries.prefix(5))") // Show first 5 countries
        
        if availableCountries.isEmpty {
            // Fallback: Show message when no data is available
            print("⚠️ CarPlay: No countries available, showing loading message")
            let emptyItem = CPListItem(text: "Loading Stations...", detailText: "Please wait while stations are loading")
            let emptySection = CPListSection(items: [emptyItem], header: "Stations", sectionIndexTitle: nil)
            sections.append(emptySection)
        } else {
            var countryItems: [CPListItem] = []
            for country in availableCountries.prefix(20) { // Limit to first 20 countries for performance
                let stations = carPlayManager.getStations(for: country)
                print("🚗 CarPlay: Country \(country) has \(stations.count) stations")
                let item = CPListItem(text: country, 
                                     detailText: "\(stations.count) stations",
                                     image: carPlayManager.getFlagImage(for: country))
                item.handler = { [weak self] item, completion in
                    print("🚗 CarPlay: User tapped country: \(country)")
                    self?.showStationsForCountry(country, completion: completion)
                }
                countryItems.append(item)
            }
            
            if !countryItems.isEmpty {
                let countrySection = CPListSection(items: countryItems, header: "Browse by Country", sectionIndexTitle: nil)
                sections.append(countrySection)
                print("🚗 CarPlay: Created country section with \(countryItems.count) items")
            } else {
                print("⚠️ CarPlay: No country items created")
            }
        }
        
        let listTemplate = CPListTemplate(title: "Stations", sections: sections)
        listTemplate.tabTitle = "Stations"
        listTemplate.tabImage = UIImage(systemName: "radio")
        
        print("🚗 CarPlay: Stations tab created with \(sections.count) sections")
        return listTemplate
    }
    
    private func createFavoritesTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get favorite stations from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let favoriteStations = carPlayManager.getFavoriteStations()
        
        var favoriteItems: [CPListItem] = []
        for station in favoriteStations {
            let item = CPListItem(text: station.name,
                                 detailText: station.country,
                                 image: carPlayManager.getStationArtwork(for: station))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            favoriteItems.append(item)
        }
        
        if favoriteItems.isEmpty {
            let emptyItem = CPListItem(text: "No Favorite Stations", detailText: "Add stations to favorites to see them here")
            favoriteItems.append(emptyItem)
        }
        
        let favoriteSection = CPListSection(items: favoriteItems, header: "Your Favorite Stations", sectionIndexTitle: nil)
        sections.append(favoriteSection)
        
        let listTemplate = CPListTemplate(title: "Favorites", sections: sections)
        listTemplate.tabTitle = "Favorites"
        listTemplate.tabImage = UIImage(systemName: "star.fill")
        
        return listTemplate
    }
    
    private func createRecentsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get recent stations from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let recentStations = carPlayManager.getRecentStations()
        
        var recentItems: [CPListItem] = []
        for station in recentStations {
            let timeAgo = formatTimeAgo(station.lastPlayed)
            let item = CPListItem(text: station.name,
                                 detailText: "Played \(timeAgo) • \(station.country)",
                                 image: carPlayManager.getStationArtwork(for: station))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            recentItems.append(item)
        }
        
        if recentItems.isEmpty {
            let emptyItem = CPListItem(text: "No Recent Stations", detailText: "Recently played stations will appear here")
            recentItems.append(emptyItem)
        }
        
        let recentSection = CPListSection(items: recentItems, header: "Recently Played", sectionIndexTitle: nil)
        sections.append(recentSection)
        
        let listTemplate = CPListTemplate(title: "Recents", sections: sections)
        listTemplate.tabTitle = "Recents"
        listTemplate.tabImage = UIImage(systemName: "clock")
        
        return listTemplate
    }
    
    private func createPodcastsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get podcasts from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let podcastFeeds = carPlayManager.getPodcastFeeds()
        
        var podcastItems: [CPListItem] = []
        for podcast in podcastFeeds {
            let item = CPListItem(text: podcast.title,
                                 detailText: "\(podcast.episodes.count) episodes",
                                 image: carPlayManager.getPodcastArtwork(for: podcast))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showPodcastEpisodes(podcast, completion: completion)
            }
            podcastItems.append(item)
        }
        
        if podcastItems.isEmpty {
            let emptyItem = CPListItem(text: "No Podcasts", detailText: "Add podcasts to see them here")
            podcastItems.append(emptyItem)
        }
        
        let podcastSection = CPListSection(items: podcastItems, header: "Your Podcasts", sectionIndexTitle: nil)
        sections.append(podcastSection)
        
        let listTemplate = CPListTemplate(title: "Podcasts", sections: sections)
        listTemplate.tabTitle = "Podcasts"
        listTemplate.tabImage = UIImage(systemName: "microphone")
        
        return listTemplate
    }
    
    // MARK: - Navigation Handlers
    
    private func showStationsForCountry(_ country: String, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        let stations = carPlayManager.getStations(for: country)
        
        var stationItems: [CPListItem] = []
        for station in stations {
            let item = CPListItem(text: station.name,
                                 detailText: station.country,
                                 image: carPlayManager.getStationArtwork(for: station))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            stationItems.append(item)
        }
        
        let section = CPListSection(items: stationItems, header: "\(country) Stations", sectionIndexTitle: nil)
        let listTemplate = CPListTemplate(title: country, sections: [section])
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func showPodcastEpisodes(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        
        var episodeItems: [CPListItem] = []
        for episode in podcast.episodes.prefix(20) { // Limit to first 20 episodes
            let duration = formatDuration(episode.duration)
            let progress = episode.state.progress > 0 ? " • \(Int(episode.state.progress * 100))% played" : ""
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(progress)",
                                 image: carPlayManager.getPodcastArtwork(for: podcast))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            episodeItems.append(item)
        }
        
        let section = CPListSection(items: episodeItems, header: "Episodes", sectionIndexTitle: nil)
        let listTemplate = CPListTemplate(title: podcast.title, sections: [section])
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func playStation(_ station: RadioStation, completion: @escaping () -> Void) {
        os_log("CarPlay: Playing station %@", log: log, type: .info, station.name)
        
        // Use the existing RadioPlayer to play the station
        DispatchQueue.main.async {
            let radioPlayer = RadioPlayer.shared
            if let stationIndex = RadioStationViewModel.shared.stations.firstIndex(where: { $0.id == station.id }) {
                radioPlayer.playStation(at: stationIndex, from: RadioStationViewModel.shared.stations)
            }
            completion()
        }
    }
    
    private func playEpisode(_ episode: PodcastEpisode, completion: @escaping () -> Void) {
        os_log("CarPlay: Playing episode %@", log: log, type: .info, episode.title)
        
        // Use the existing PodcastPlayer to play the episode
        DispatchQueue.main.async {
            let podcastPlayer = PodcastPlayer.shared
            // Find the feed that contains this episode
            let carPlayManager = CarPlayManager.shared
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            if let feed = podcastFeeds.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) }) {
                podcastPlayer.playEpisode(episode, feed: feed)
            }
            completion()
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatTimeAgo(_ date: Date?) -> String {
        guard let date = date else { return "unknown" }
        
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)
        
        if timeInterval < 3600 { // Less than 1 hour
            let minutes = Int(timeInterval / 60)
            return "\(minutes)m ago"
        } else if timeInterval < 86400 { // Less than 1 day
            let hours = Int(timeInterval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(timeInterval / 86400)
            return "\(days)d ago"
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func createStationsForCountry(_ country: String) -> CPListTemplate {
        var sections: [CPListSection] = []
        
        let carPlayManager = CarPlayManager.shared
        let stations = carPlayManager.getStations(for: country)
        
        os_log("🚗 CarPlay: Creating station list for %@ with %d stations", log: log, type: .info, country, stations.count)
        print("🚗 CarPlay: Stations for \\(country): \\(stations.count)")
        
        if stations.isEmpty {
            let emptyItem = CPListItem(text: "No Stations", detailText: "No stations found for this country")
            let emptySection = CPListSection(items: [emptyItem], header: "Stations", sectionIndexTitle: nil)
            sections.append(emptySection)
        } else {
            let stationItems = stations.map { station in
                let item = CPListItem(text: station.name, 
                                     detailText: station.country, // Use country instead of genre
                                     image: carPlayManager.getStationArtwork(for: station))
                
                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    print("🚗 CarPlay: Playing station \\(station.name)")
                    self?.playStation(station, completion: completion)
                }
                
                return item
            }
            
            let stationSection = CPListSection(items: stationItems, header: "\\(country) Stations", sectionIndexTitle: nil)
            sections.append(stationSection)
        }
        
        let template = CPListTemplate(title: "\\(country) Stations", sections: sections)
        template.emptyViewTitleVariants = ["No Stations"]
        template.emptyViewSubtitleVariants = ["No stations available for this country"]
        
        return template
    }
} 
