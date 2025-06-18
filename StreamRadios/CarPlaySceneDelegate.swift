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
import MediaPlayer

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
    
    private let log = OSLog(subsystem: "com.streamradios.carplay", category: "SceneDelegate")
    var interfaceController: CPInterfaceController?
    
    // Track currently displayed templates for real-time updates
    private var currentPodcastTemplate: CPListTemplate?
    private var currentPodcastFeed: PodcastFeed?
    private var lastProgressUpdateTime: Date?
    private var isUpdatingTemplate = false
    private var currentPodcastTabType: PodcastTabType = .all
    private var currentPodcastTabBarTemplate: CPTabBarTemplate?
    
    enum PodcastTabType {
        case all
        case favorites
        case downloads
    }
    
    // MARK: - Scene Delegate Methods
    
    /// Initialize CarPlay data independently from the main app
    /// This ensures CarPlay works even when the main app isn't running
    private func initializeCarPlayData() async {
        os_log("🚗 CarPlay: Initializing data independently", log: log, type: .info)
        print("🚗 CarPlay: Starting independent data initialization...")
        
        do {
            // Load podcast feeds and episodes from Core Data directly
            await loadPodcastDataFromCoreData()
            
            // Load radio stations from the shared view model
            await loadRadioStationsData()
            
            os_log("🚗 CarPlay: Data initialization complete", log: log, type: .info)
            print("🚗 CarPlay: Independent data initialization complete")
            
        } catch {
            os_log("🚗 CarPlay: Error during data initialization: %@", log: log, type: .error, error.localizedDescription)
            print("🚗 CarPlay: Error during initialization: \(error.localizedDescription)")
            
            // Initialize with empty data so CarPlay still works
            await MainActor.run {
                CarPlayManager.shared.configurePodcastData([])
                CarPlayManager.shared.updateContent()
            }
        }
    }
    
    /// Load podcast data directly from Core Data for CarPlay
    private func loadPodcastDataFromCoreData() async {
        os_log("🚗 CarPlay: Loading podcast data from Core Data", log: log, type: .info)
        
        // Use the main context and perform operations on its queue to avoid threading issues
        let context = CoreDataStack.shared.context
        
        var podcastFeeds: [PodcastFeed] = []
        
        // Perform Core Data operations on the context's queue to avoid threading violations
        await withCheckedContinuation { continuation in
            context.perform {
                do {
                    // Load podcast feeds first - WITHOUT loading all episodes
                    let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    
                    let managedFeeds = try context.fetch(feedRequest)
                    os_log("🚗 CarPlay: Found %d podcast feeds in Core Data", log: self.log, type: .info, managedFeeds.count)
                    
                    // Convert each managed feed to PodcastFeed WITHOUT loading episodes yet
                    for managedFeed in managedFeeds {
                        var feed = managedFeed.toPodcastFeed()
                        
                        // Only get episode count for display purposes, don't load actual episodes
                        let episodeCountRequest: NSFetchRequest<NSNumber> = NSFetchRequest(entityName: "PodcastModel")
                        episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                        episodeCountRequest.resultType = .countResultType
                        
                        do {
                            let episodeCount = try context.count(for: episodeCountRequest)
                            os_log("🚗 CarPlay: Feed '%@' has %d episodes (count only)", log: self.log, type: .debug, feed.title, episodeCount)
                            
                            // Initialize with empty episodes array - episodes will be loaded on-demand
                            feed.episodes = []
                            
                        } catch {
                            os_log("🚗 CarPlay: Error counting episodes for feed '%@': %@", log: self.log, type: .error, feed.title, error.localizedDescription)
                            feed.episodes = []
                        }
                        
                        podcastFeeds.append(feed)
                    }
                    
                    continuation.resume()
                    
                } catch {
                    os_log("🚗 CarPlay: Error loading podcast feeds from Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                    print("🚗 CarPlay: Error loading podcast feeds: \(error.localizedDescription)")
                    continuation.resume()
                }
            }
        }
        
        // Configure CarPlayManager with the loaded podcast data on main actor
        await MainActor.run {
            CarPlayManager.shared.configurePodcastData(podcastFeeds)
            os_log("🚗 CarPlay: Configured CarPlayManager with %d podcast feeds (episodes will load on-demand)", log: self.log, type: .info, podcastFeeds.count)
            print("🚗 CarPlay: Configured with \(podcastFeeds.count) podcast feeds (episodes will load on-demand)")
        }
    }
    
    /// Load episodes for a specific feed on-demand for better performance
    func loadEpisodesForFeed(_ feedId: String, completion: @escaping ([PodcastEpisode]) -> Void) {
        os_log("🚗 CarPlay: Loading episodes on-demand for feed ID: %@", log: log, type: .info, feedId)
        
        let context = CoreDataStack.shared.context
        
        // Perform Core Data operations on the context's queue
        context.perform {
            do {
                // Load episodes with pagination for better performance
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                episodeRequest.fetchLimit = 50 // Load first 50 episodes only for CarPlay
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    
                    // Log progress for debugging
                    if managedEpisode.progress > 0 {
                        os_log("🚗 CarPlay: Episode '%@' has progress: %.2f%%", log: self.log, type: .debug, episode.title, managedEpisode.progress * 100)
                    }
                    
                    return episode
                }
                
                os_log("🚗 CarPlay: Loaded %d episodes on-demand for feed ID: %@", log: self.log, type: .info, episodes.count, feedId)
                
                DispatchQueue.main.async {
                    completion(episodes)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading episodes on-demand for feed ID '%@': %@", log: self.log, type: .error, feedId, error.localizedDescription)
                DispatchQueue.main.async {
                    completion([])
                }
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
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let templateApplicationScene = scene as? CPTemplateApplicationScene else { 
            os_log("❌ CarPlay: Scene is not CPTemplateApplicationScene", log: log, type: .error)
            return 
        }
        
        os_log("🚗 CarPlay: Scene willConnectTo called", log: log, type: .info)
        print("🚗 CarPlay: Scene willConnectTo called")
        
        // The interface controller will be set up in templateApplicationScene:didConnect:
        // We'll initialize data in the background
        os_log("🚗 CarPlay: Starting background data initialization...", log: log, type: .info)
        Task {
            do {
                await initializeCarPlayData()
            } catch {
                os_log("❌ CarPlay: Data initialization failed: %@", log: log, type: .error, error.localizedDescription)
            }
        }
        
        // Set up real-time update listeners
        setupProgressUpdateListeners()
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, 
                                didDisconnect interfaceController: CPInterfaceController) {
        os_log("🚗 CarPlay scene disconnected", log: log, type: .info)
        print("🚗 CarPlay: Scene delegate didDisconnect called")
        
        // Clean up notification observers
        NotificationCenter.default.removeObserver(self)
        
        // Clear template references
        currentPodcastTemplate = nil
        currentPodcastFeed = nil
        
        self.interfaceController = nil
    }
    
    // MARK: - CPTemplateApplicationSceneDelegate Required Methods
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, 
                                didConnect interfaceController: CPInterfaceController) {
        os_log("🚗 CarPlay: Scene delegate didConnect called", log: log, type: .info)
        print("🚗 CarPlay: Scene delegate didConnect called")
        
        // Store the interface controller
        self.interfaceController = interfaceController
        
        // Setup the root template immediately
        setupRootTemplate()
        
        os_log("🚗 CarPlay: Initial template setup complete", log: log, type: .info)
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
        os_log("🚗 CarPlay: Showing episodes for podcast: %@", log: log, type: .info, podcast.title)
        
        // Load episodes on-demand if not already loaded
        if podcast.episodes.isEmpty {
            os_log("🚗 CarPlay: Episodes not loaded for podcast '%@', loading on-demand...", log: log, type: .info, podcast.title)
            
            loadEpisodesForFeed(podcast.id) { [weak self] episodes in
                guard let self = self else { return }
                
                os_log("🚗 CarPlay: Loaded %d episodes on-demand for podcast '%@'", log: self.log, type: .info, episodes.count, podcast.title)
                
                // Update the podcast with loaded episodes
                var updatedPodcast = podcast
                updatedPodcast.episodes = episodes
                
                // Create episode list template with tabs after loading episodes
                self.createAndShowPodcastTemplate(updatedPodcast, completion: completion)
            }
        } else {
            // Episodes already loaded, show immediately
            createAndShowPodcastTemplate(podcast, completion: completion)
        }
    }
    
    private func createAndShowPodcastTemplate(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        // Create horizontal tabs for All, Favorites and Downloads
        let allTab = createAllTabTemplate(for: podcast)
        let favoritesTab = createFavoritesTabTemplate(for: podcast)
        let downloadsTab = createDownloadsTabTemplate(for: podcast)
        
        let tabBarTemplate = CPTabBarTemplate(templates: [allTab, favoritesTab, downloadsTab])
        tabBarTemplate.delegate = self
        
        // Track the current template and feed for real-time updates
        currentPodcastTemplate = allTab  // Start with All tab (default)
        currentPodcastFeed = podcast
        currentPodcastTabType = .all  // Default to All tab
        currentPodcastTabBarTemplate = tabBarTemplate
        
        // Set as root template since CPTabBarTemplate cannot be pushed
        interfaceController?.setRootTemplate(tabBarTemplate, animated: true) { success, error in
            if success {
                os_log("🚗 CarPlay: Successfully displayed podcast episodes with tabs", log: self.log, type: .info)
            } else {
                os_log("🚗 CarPlay: Failed to display podcast episodes: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
            }
            completion()
        }
    }
    
    private func createAllTabTemplate(for podcast: PodcastFeed) -> CPListTemplate {
        let allEpisodes = podcast.episodes
        let listItems = allEpisodes.map { episode in
            createEpisodeListItem(episode: episode, podcast: podcast)
        }
        
        // Add a back navigation item at the top of the list
        let backItem = CPListItem(text: "← Back to Podcast List", detailText: "Return to all podcasts")
        backItem.handler = { [weak self] _, completion in
            self?.returnToPodcastList()
            completion()
        }
        
        let template = CPListTemplate(title: podcast.title, sections: [
            CPListSection(items: [backItem]),
            CPListSection(items: listItems.isEmpty ? [createEmptyStateItem(message: "No episodes")] : listItems)
        ])
        
        template.tabTitle = "All"
        template.tabImage = UIImage(systemName: "list.bullet")
        
        return template
    }
    
    private func createFavoritesTabTemplate(for podcast: PodcastFeed) -> CPListTemplate {
        let favoriteEpisodes = podcast.episodes.filter { episode in
            episode.state.isFavorite
        }
        
        let listItems = favoriteEpisodes.map { episode in
            createEpisodeListItem(episode: episode, podcast: podcast)
        }
        
        // Add a back navigation item at the top of the list
        let backItem = CPListItem(text: "← Back to Podcast List", detailText: "Return to all podcasts")
        backItem.handler = { [weak self] _, completion in
            self?.returnToPodcastList()
            completion()
        }
        
        let template = CPListTemplate(title: podcast.title, sections: [
            CPListSection(items: [backItem]),
            CPListSection(items: listItems.isEmpty ? [createEmptyStateItem(message: "No favorite episodes")] : listItems)
        ])
        
        template.tabTitle = "Favorites"
        template.tabImage = UIImage(systemName: "star.fill")
        
        return template
    }
    
    private func createDownloadsTabTemplate(for podcast: PodcastFeed) -> CPListTemplate {
        let downloadedEpisodes = podcast.episodes.filter { episode in
            episode.state.isDownloaded
        }
        
        let listItems = downloadedEpisodes.map { episode in
            createEpisodeListItem(episode: episode, podcast: podcast)
        }
        
        // Add a back navigation item at the top of the list
        let backItem = CPListItem(text: "← Back to Podcast List", detailText: "Return to all podcasts")
        backItem.handler = { [weak self] _, completion in
            self?.returnToPodcastList()
            completion()
        }
        
        let template = CPListTemplate(title: podcast.title, sections: [
            CPListSection(items: [backItem]),
            CPListSection(items: listItems.isEmpty ? [createEmptyStateItem(message: "No downloaded episodes")] : listItems)
        ])
        
        template.tabTitle = "Downloads"
        template.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        
        return template
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
        os_log("🚗 CarPlay: Playing episode '%@' with progress: %.2f%%", log: log, type: .info, episode.title, episode.state.progress * 100)
        
        // Use the existing PodcastPlayer to play the episode
        DispatchQueue.main.async { [self] in
            let podcastPlayer = PodcastPlayer.shared
            // Find the feed that contains this episode
            let carPlayManager = CarPlayManager.shared
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            if let feed = podcastFeeds.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) }) {
                // Ensure the episode has the latest progress data from the feed
                if let feedEpisode = feed.episodes.first(where: { $0.id == episode.id }) {
                    os_log("🚗 CarPlay: Episode progress from feed: %.2f%%, isPlayed: %@", log: self.log, type: .debug, feedEpisode.state.progress * 100, feedEpisode.state.isPlayed ? "true" : "false")
                    podcastPlayer.playEpisode(feedEpisode, feed: feed)
                } else {
                    // Fallback to the original episode if not found in feed
                    podcastPlayer.playEpisode(episode, feed: feed)
                }
            } else {
                os_log("🚗 CarPlay: Warning - Could not find feed for episode '%@'", log: self.log, type: .error, episode.title)
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
    
    // MARK: - Real-Time Update Listeners
    
    private func setupProgressUpdateListeners() {
        os_log("🚗 CarPlay: Setting up real-time progress update listeners", log: log, type: .info)
        
        // Listen for podcast progress updates
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastProgressUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handlePodcastProgressUpdate(notification)
        }
        
        // Listen for episode completion
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EpisodeCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleEpisodeCompletion(notification)
        }
        
        // Listen for episode state changes (favorites, downloads, etc.)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EpisodeStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleEpisodeStateChange(notification)
        }
        
        // Listen for playback state changes (play/pause)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastPlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handlePlaybackStateChange(notification)
        }
    }
    
    private func handlePodcastProgressUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            os_log("🚗 CarPlay: Invalid progress update notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Received progress update for episode ID: %@, progress: %.1f%%", log: log, type: .info, episodeId, progress * 100)
        
        // Update the episode in CarPlayManager's data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateEpisodeProgress(episodeId: episodeId, progress: progress, isCompleted: progress >= 0.99)
        
        // Log current template state for debugging
        if let currentFeed = currentPodcastFeed {
            let episodeFound = currentFeed.episodes.contains(where: { $0.id == episodeId })
            os_log("🚗 CarPlay: Current feed: %@, contains episode: %@", log: log, type: .debug, currentFeed.title, episodeFound ? "YES" : "NO")
            
            if episodeFound {
                if let episode = currentFeed.episodes.first(where: { $0.id == episodeId }) {
                    os_log("🚗 CarPlay: Episode current progress: %.1f%%", log: log, type: .debug, episode.state.progress * 100)
                }
            }
        } else {
            os_log("🚗 CarPlay: No current podcast feed set", log: log, type: .debug)
        }
        
        // Update the currently displayed podcast episode list immediately if it contains this episode
        refreshCurrentPodcastTemplateIfNeeded(episodeId: episodeId)
        
        // Also refresh the legacy CarPlay content for older systems
        DispatchQueue.main.async {
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    private func handleEpisodeCompletion(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String else {
            return
        }
        
        os_log("🚗 CarPlay: Episode completed: %@", log: log, type: .info, episodeId)
        
        // Update the episode in CarPlayManager's data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateEpisodeProgress(episodeId: episodeId, progress: 1.0, isCompleted: true)
        
        // Refresh the current template immediately to show completion
        refreshCurrentPodcastTemplateIfNeeded(episodeId: episodeId)
        
        // Also refresh the legacy CarPlay content for older systems
        DispatchQueue.main.async {
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    private func handleEpisodeStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String else {
            return
        }
        
        os_log("🚗 CarPlay: Episode state changed: %@", log: log, type: .info, episodeId)
        refreshCurrentPodcastTemplateIfNeeded(episodeId: episodeId)
    }
    
    private func handlePlaybackStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isPlaying = userInfo["isPlaying"] as? Bool else {
            os_log("🚗 CarPlay: Invalid playback state change notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Playback state changed for episode ID: %@, isPlaying: %@", log: log, type: .info, episodeId, isPlaying ? "YES" : "NO")
        
        // Update the episode status display immediately
        refreshCurrentPodcastTemplateIfNeeded(episodeId: episodeId)
    }
    
    private func refreshCurrentPodcastTemplateIfNeeded(episodeId: String) {
        // Throttle updates to prevent too frequent template refreshes (allow every 1 second for status changes)
        let now = Date()
        if let lastUpdate = lastProgressUpdateTime, now.timeIntervalSince(lastUpdate) < 1.0 {
            // Skip if we updated less than 1 second ago
            return
        }
        
        // Prevent concurrent updates
        if isUpdatingTemplate {
            return
        }
        
        // Check if we're currently showing a podcast episode list that contains this episode
        guard let currentFeed = currentPodcastFeed,
              currentFeed.episodes.contains(where: { $0.id == episodeId }) else {
            os_log("🚗 CarPlay: No current template or episode not found in current feed", log: log, type: .debug)
            return
        }
        
        os_log("🚗 CarPlay: Refreshing current podcast template for episode: %@", log: log, type: .debug, episodeId)
        
        isUpdatingTemplate = true
        lastProgressUpdateTime = now
        
        // Get updated feed data from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let updatedFeeds = carPlayManager.getPodcastFeeds()
        
        if let updatedFeed = updatedFeeds.first(where: { $0.id == currentFeed.id }) {
            // Update the current feed reference
            currentPodcastFeed = updatedFeed
            
            // Force a template recreation for better reliability
            recreatePodcastEpisodeTemplate(for: updatedFeed)
        }
        
        isUpdatingTemplate = false
    }
    
    private func recreatePodcastEpisodeTemplate(for podcast: PodcastFeed) {
        os_log("🚗 CarPlay: Recreating podcast template for tab type: %@", log: log, type: .debug, String(describing: currentPodcastTabType))
        
        // For tab bar templates, we need to recreate the entire tab bar
        if let interfaceController = interfaceController,
           let currentTabBar = currentPodcastTabBarTemplate {
            
            // Create new tabs with updated data
            let allTab = createAllTabTemplate(for: podcast)
            let favoritesTab = createFavoritesTabTemplate(for: podcast)
            let downloadsTab = createDownloadsTabTemplate(for: podcast)
            
            let newTabBarTemplate = CPTabBarTemplate(templates: [allTab, favoritesTab, downloadsTab])
            newTabBarTemplate.delegate = self
            
            // Update current template reference based on current tab type
            switch currentPodcastTabType {
            case .all:
                currentPodcastTemplate = allTab
            case .favorites:
                currentPodcastTemplate = favoritesTab
            case .downloads:
                currentPodcastTemplate = downloadsTab
            }
            
            // Update the tab bar template reference
            currentPodcastTabBarTemplate = newTabBarTemplate
            
            // Replace the current tab bar template
            interfaceController.setRootTemplate(newTabBarTemplate, animated: false) { success, error in
                if success {
                    os_log("🚗 CarPlay: Successfully recreated tab bar template", log: self.log, type: .debug)
                } else {
                    os_log("🚗 CarPlay: Failed to recreate tab bar template: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                }
            }
        }
    }
    
    private func createEpisodeListItem(episode: PodcastEpisode, podcast: PodcastFeed) -> CPListItem {
        let carPlayManager = CarPlayManager.shared
        let duration = formatDuration(episode.duration)
        var statusText = ""
        
        // Determine episode status based on state and current playback
        if let currentEpisode = PodcastPlayer.shared.currentEpisode,
           currentEpisode.id == episode.id && PodcastPlayer.shared.isPlaying {
            statusText = " • Playing"
        } else if episode.state.isPlayed {
            statusText = " • Complete"
        } else if episode.state.progress > 0 {
            statusText = " • In Progress"
        }
        
        let item = CPListItem(text: episode.title,
                             detailText: "\(duration)\(statusText)",
                             image: carPlayManager.getPodcastArtwork(for: podcast))
        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
            self?.playEpisode(episode, completion: completion)
        }
        return item
    }
    
    private func createEmptyStateItem(message: String) -> CPListItem {
        let item = CPListItem(text: message, detailText: nil)
        // Make it non-selectable by not setting a handler
        return item
    }
    
    private func createPodcastListTemplate() -> CPListTemplate? {
        // Get podcasts from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let podcastFeeds = carPlayManager.getPodcastFeeds()
        
        os_log("🚗 CarPlay: Creating podcast list with %d feeds", log: log, type: .info, podcastFeeds.count)
        
        var sections: [CPListSection] = []
        
        if podcastFeeds.isEmpty {
            let emptyItem = CPListItem(text: "No Podcasts", detailText: "Add podcasts to see them here")
            let emptySection = CPListSection(items: [emptyItem])
            sections.append(emptySection)
        } else {
            let podcastItems = podcastFeeds.map { feed in
                let episodeCount = feed.episodes.count
                let detailText = episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes"
                
                let item = CPListItem(text: feed.title,
                                     detailText: detailText,
                                     image: carPlayManager.getPodcastArtwork(for: feed))
                
                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    self?.showPodcastEpisodes(feed, completion: completion)
                }
                
                return item
            }
            
            let podcastSection = CPListSection(items: podcastItems)
            sections.append(podcastSection)
        }
        
        let listTemplate = CPListTemplate(title: "Podcasts", sections: sections)
        listTemplate.emptyViewTitleVariants = ["No Podcasts"]
        listTemplate.emptyViewSubtitleVariants = ["Add podcasts to see them here"]
        
        return listTemplate
    }
    
    private func returnToPodcastList() {
        // Create and show the podcast list template to return to
        guard let podcastListTemplate = createPodcastListTemplate() else {
            os_log("🚗 CarPlay: Failed to create podcast list template", log: log, type: .error)
            return
        }
        
        interfaceController?.setRootTemplate(podcastListTemplate, animated: true) { success, error in
            if success {
                os_log("🚗 CarPlay: Successfully returned to podcast list", log: self.log, type: .info)
            } else {
                os_log("🚗 CarPlay: Failed to return to podcast list: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
            }
        }
        
        // Clear current podcast tracking
        currentPodcastTemplate = nil
        currentPodcastFeed = nil
        currentPodcastTabBarTemplate = nil
    }
    
    // MARK: - CPTabBarTemplateDelegate
    
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard let listTemplate = selectedTemplate as? CPListTemplate else { return }
        
        // Update current tab type based on selected template
        if listTemplate.tabTitle == "All" {
            currentPodcastTabType = .all
            os_log("🚗 CarPlay: User selected All tab", log: log, type: .info)
        } else if listTemplate.tabTitle == "Favorites" {
            currentPodcastTabType = .favorites
            os_log("🚗 CarPlay: User selected Favorites tab", log: log, type: .info)
        } else if listTemplate.tabTitle == "Downloads" {
            currentPodcastTabType = .downloads
            os_log("🚗 CarPlay: User selected Downloads tab", log: log, type: .info)
        }
        
        // Update current template reference
        currentPodcastTemplate = listTemplate
    }
} 
