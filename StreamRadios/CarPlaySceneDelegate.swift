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

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    
    private let log = OSLog(subsystem: "com.streamradios.carplay", category: "SceneDelegate")
    var interfaceController: CPInterfaceController?
    
    // Track currently displayed templates for real-time updates
    private var currentPodcastTemplate: CPListTemplate?
    private var currentPodcastFeed: PodcastFeed?
    private var lastProgressUpdateTime: Date?
    private var isUpdatingTemplate = false
    
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
                    // Load podcast feeds first (without episodes for performance)
                    let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    
                    let managedFeeds = try context.fetch(feedRequest)
                    os_log("🚗 CarPlay: Found %d podcast feeds in Core Data", log: self.log, type: .info, managedFeeds.count)
                    
                    // Convert each managed feed to PodcastFeed (without loading episodes yet)
                    for managedFeed in managedFeeds {
                        var feed = managedFeed.toPodcastFeed()
                        
                        // Count episodes for this feed (much faster than loading all episodes)
                        let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                        episodeCountRequest.includesPropertyValues = false // Only count, don't load data
                        
                        do {
                            let episodeCount = try context.count(for: episodeCountRequest)
                            // Initialize with empty episodes array - will be loaded on-demand
                            feed.episodes = []
                            os_log("🚗 CarPlay: Feed '%@' has %d episodes (will load on-demand)", log: self.log, type: .debug, feed.title, episodeCount)
                            
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
            print("🚗 CarPlay: Configured with \(podcastFeeds.count) podcast feeds")
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
        
        var favoriteStationItems: [CPListItem] = []
        for station in favoriteStations {
            let item = CPListItem(text: station.name,
                                 detailText: station.country,
                                 image: carPlayManager.getStationArtwork(for: station))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            favoriteStationItems.append(item)
        }
        
        if favoriteStationItems.isEmpty {
            let emptyItem = CPListItem(text: "No Favorite Stations", detailText: "Add stations to favorites to see them here")
            favoriteStationItems.append(emptyItem)
        }
        
        let favoriteStationsSection = CPListSection(items: favoriteStationItems, header: "Favorite Stations", sectionIndexTitle: nil)
        sections.append(favoriteStationsSection)
        
        // Get favorite podcast episodes from CarPlayManager
        let favoriteEpisodes = carPlayManager.getFavoritePodcastEpisodes()
        
        var favoriteEpisodeItems: [CPListItem] = []
        for episode in favoriteEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            
            // Determine episode status based on state and current playback
            if let currentEpisode = PodcastPlayer.shared.currentEpisode,
               currentEpisode.id == episode.id && PodcastPlayer.shared.isPlaying {
                statusText = " • Playing"
            } else if episode.state.isPlayed {
                statusText = " • Complete"
            } else if episode.state.progress > 0 {
                let progressPercent = Int(episode.state.progress * 100)
                statusText = " • \(progressPercent)% complete"
            }
            
            // Find the podcast feed for artwork
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            let podcastFeed = podcastFeeds.first { feed in
                feed.episodes.contains { $0.id == episode.id }
            }
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "microphone"))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            favoriteEpisodeItems.append(item)
        }
        
        if favoriteEpisodeItems.isEmpty {
            let emptyItem = CPListItem(text: "No Favorite Episodes", detailText: "Add podcast episodes to favorites to see them here")
            favoriteEpisodeItems.append(emptyItem)
        }
        
        let favoriteEpisodesSection = CPListSection(items: favoriteEpisodeItems, header: "Favorite Episodes", sectionIndexTitle: nil)
        sections.append(favoriteEpisodesSection)
        
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
        
        var recentStationItems: [CPListItem] = []
        for station in recentStations {
            let timeAgo = formatTimeAgo(station.lastPlayed)
            let item = CPListItem(text: station.name,
                                 detailText: "Played \(timeAgo) • \(station.country)",
                                 image: carPlayManager.getStationArtwork(for: station))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            recentStationItems.append(item)
        }
        
        if recentStationItems.isEmpty {
            let emptyItem = CPListItem(text: "No Recent Stations", detailText: "Recently played stations will appear here")
            recentStationItems.append(emptyItem)
        }
        
        let recentStationsSection = CPListSection(items: recentStationItems, header: "Recently Played Stations", sectionIndexTitle: nil)
        sections.append(recentStationsSection)
        
        // Get recent podcast episodes from CarPlayManager
        let recentEpisodes = carPlayManager.getRecentPodcastEpisodes()
        
        var recentEpisodeItems: [CPListItem] = []
        for episode in recentEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            
            // Determine episode status based on state and current playback
            if let currentEpisode = PodcastPlayer.shared.currentEpisode,
               currentEpisode.id == episode.id && PodcastPlayer.shared.isPlaying {
                statusText = " • Playing"
            } else if episode.state.isPlayed {
                statusText = " • Complete"
            } else if episode.state.progress > 0 {
                let progressPercent = Int(episode.state.progress * 100)
                statusText = " • \(progressPercent)% complete"
            }
            
            // Find the podcast feed for artwork
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            let podcastFeed = podcastFeeds.first { feed in
                feed.episodes.contains { $0.id == episode.id }
            }
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "microphone"))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            recentEpisodeItems.append(item)
        }
        
        if recentEpisodeItems.isEmpty {
            let emptyItem = CPListItem(text: "No Recent Episodes", detailText: "Recently played podcast episodes will appear here")
            recentEpisodeItems.append(emptyItem)
        }
        
        let recentEpisodesSection = CPListSection(items: recentEpisodeItems, header: "Recently Played Episodes", sectionIndexTitle: nil)
        sections.append(recentEpisodesSection)
        
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
                self?.showPodcastDetails(podcast, completion: completion)
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
    
    private func showPodcastDetails(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        os_log("🚗 CarPlay: Showing podcast details for '%@'", log: log, type: .info, podcast.title)
        
        // First, get the total episode count from CoreData
        getEpisodeCount(for: podcast) { [weak self] totalEpisodes in
            guard let self = self else { return }
            
            if totalEpisodes == 0 {
                // No episodes - show empty state
                self.showEmptyPodcastState(podcast, completion: completion)
                return
            }
            
            // Apple's CarPlay guide: "Some cars dynamically limit lists to 12 list items"
            // We use this as our page size to ensure optimal performance across all vehicles
            let episodesPerPage = 12 // CarPlay's suggested limit
            let totalPages = Int(ceil(Double(totalEpisodes) / Double(episodesPerPage)))
            
            os_log("🚗 CarPlay: Podcast '%@' has %d episodes, will create %d pages", log: self.log, type: .info, podcast.title, totalEpisodes, totalPages)
            
            // Load episodes efficiently based on count
            if totalEpisodes <= episodesPerPage {
                // Small number of episodes - load all at once
                self.loadEpisodesForPodcast(podcast) { episodes in
                    var updatedPodcast = podcast
                    updatedPodcast.episodes = episodes
                    self.displayPodcastWithAllEpisodes(updatedPodcast, totalEpisodes: totalEpisodes, completion: completion)
                }
            } else {
                // Large number of episodes - implement efficient pagination
                self.displayPodcastWithPagination(podcast, totalEpisodes: totalEpisodes, episodesPerPage: episodesPerPage, completion: completion)
            }
        }
    }
    
    private func showEmptyPodcastState(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        let emptyItem = CPListItem(text: "No Episodes", detailText: "This podcast doesn't have any episodes yet")
        let section = CPListSection(items: [emptyItem], header: "Episodes", sectionIndexTitle: nil)
        let listTemplate = CPListTemplate(title: podcast.title, sections: [section])
        
        currentPodcastTemplate = listTemplate
        currentPodcastFeed = podcast
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func displayPodcastWithAllEpisodes(_ podcast: PodcastFeed, totalEpisodes: Int, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        var sections: [CPListSection] = []
        
        // Add "Downloaded Episodes" filter if there are any downloaded episodes
        let downloadedEpisodes = podcast.episodes.filter { $0.state.isDownloaded }
        if !downloadedEpisodes.isEmpty {
            let downloadedItem = CPListItem(text: "Downloaded Episodes",
                                           detailText: "\(downloadedEpisodes.count) downloaded",
                                           image: UIImage(systemName: "arrow.down.circle"))
            downloadedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showDownloadedEpisodesFromList(downloadedEpisodes, podcastTitle: podcast.title, completion: completion)
            }
            
            let filterSection = CPListSection(items: [downloadedItem], header: "Filter", sectionIndexTitle: nil)
            sections.append(filterSection)
        }
        
        // Show all episodes in one section
        var episodeItems: [CPListItem] = []
        for episode in podcast.episodes {
            let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
            episodeItems.append(item)
        }
        
        let episodesSection = CPListSection(items: episodeItems, header: "All Episodes (\(totalEpisodes))", sectionIndexTitle: nil)
        sections.append(episodesSection)
        
        let listTemplate = CPListTemplate(title: podcast.title, sections: sections)
        
        currentPodcastTemplate = listTemplate
        currentPodcastFeed = podcast
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func displayPodcastWithPagination(_ podcast: PodcastFeed, totalEpisodes: Int, episodesPerPage: Int, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        var sections: [CPListSection] = []
        
        // Add Downloaded episodes filter section (load count on-demand)
        let downloadedCountRequest = { [weak self] in
            guard let self = self else { return }
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let downloadedRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    downloadedRequest.predicate = NSPredicate(format: "feedId == %@ AND isDownloaded == YES", podcast.id)
                    downloadedRequest.includesPropertyValues = false
                    let downloadedCount = try context.count(for: downloadedRequest)
                    
                    if downloadedCount > 0 {
                        DispatchQueue.main.async {
                            // Add downloaded filter option
                            let downloadedItem = CPListItem(text: "Downloaded Episodes",
                                                           detailText: "\(downloadedCount) downloaded",
                                                           image: UIImage(systemName: "arrow.down.circle"))
                            downloadedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                                self?.loadAndShowDownloadedEpisodes(podcast, completion: completion)
                            }
                            
                            // Add to existing template if possible, or note for next recreation
                            os_log("🚗 CarPlay: Found %d downloaded episodes for pagination view", log: self.log, type: .debug, downloadedCount)
                        }
                    }
                } catch {
                    os_log("🚗 CarPlay: Error counting downloaded episodes: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
        downloadedCountRequest()
        
        // Create pagination sections
        let totalPages = Int(ceil(Double(totalEpisodes) / Double(episodesPerPage)))
        for page in 0..<totalPages {
            let startIndex = page * episodesPerPage
            let endIndex = min(startIndex + episodesPerPage, totalEpisodes)
            
            let pageTitle: String
            if totalPages == 1 {
                pageTitle = "All Episodes (\(totalEpisodes))"
            } else {
                let episodeRange = "\(startIndex + 1)-\(endIndex)"
                pageTitle = "Episodes \(episodeRange) of \(totalEpisodes)"
            }
            
            // Create a loading item that will be replaced with actual episodes
            let loadingItem = CPListItem(text: "Loading episodes...", detailText: "Tap to load \(pageTitle.lowercased())")
            loadingItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.loadAndDisplayEpisodePage(podcast: podcast, page: page, episodesPerPage: episodesPerPage, pageTitle: pageTitle, completion: completion)
            }
            
            let pageSection = CPListSection(items: [loadingItem], header: pageTitle, sectionIndexTitle: nil)
            sections.append(pageSection)
        }
        
        let listTemplate = CPListTemplate(title: podcast.title, sections: sections)
        
        currentPodcastTemplate = listTemplate
        currentPodcastFeed = podcast
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func createEpisodeListItem(episode: PodcastEpisode, podcast: PodcastFeed, carPlayManager: CarPlayManager) -> CPListItem {
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
        
        // Add download indicator
        if episode.state.isDownloaded {
            statusText += " • Downloaded"
        }
        
        let item = CPListItem(text: episode.title,
                             detailText: "\(duration)\(statusText)",
                             image: carPlayManager.getPodcastArtwork(for: podcast))
        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
            self?.playEpisode(episode, completion: completion)
        }
        
        return item
    }
    
    private func loadAndDisplayEpisodePage(podcast: PodcastFeed, page: Int, episodesPerPage: Int, pageTitle: String, completion: @escaping () -> Void) {
        loadEpisodesPage(for: podcast, page: page, episodesPerPage: episodesPerPage) { [weak self] episodes in
            guard let self = self else { return }
            
            let carPlayManager = CarPlayManager.shared
            var episodeItems: [CPListItem] = []
            
            for episode in episodes {
                let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
                episodeItems.append(item)
            }
            
            if episodeItems.isEmpty {
                let emptyItem = CPListItem(text: "No episodes found", detailText: "This page doesn't contain any episodes")
                episodeItems.append(emptyItem)
            }
            
            let pageSection = CPListSection(items: episodeItems, header: pageTitle, sectionIndexTitle: nil)
            let listTemplate = CPListTemplate(title: "\(podcast.title) - \(pageTitle)", sections: [pageSection])
            
            self.interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
                completion()
            })
        }
    }
    
    private func loadAndShowDownloadedEpisodes(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@ AND isDownloaded == YES", podcast.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let downloadedEpisodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    return episode
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.showDownloadedEpisodesFromList(downloadedEpisodes, podcastTitle: podcast.title, completion: completion)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading downloaded episodes: %@", log: self.log, type: .error, error.localizedDescription)
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }
    
    private func showDownloadedEpisodesFromList(_ downloadedEpisodes: [PodcastEpisode], podcastTitle: String, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        var episodeItems: [CPListItem] = []
        
        for episode in downloadedEpisodes {
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
                                 image: UIImage(systemName: "arrow.down.circle.fill"))
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            episodeItems.append(item)
        }
        
        if episodeItems.isEmpty {
            let emptyItem = CPListItem(text: "No Downloaded Episodes", detailText: "Download episodes to listen offline")
            episodeItems.append(emptyItem)
        }
        
        let section = CPListSection(items: episodeItems, header: "Downloaded Episodes", sectionIndexTitle: nil)
        let listTemplate = CPListTemplate(title: "\(podcastTitle) - Downloaded", sections: [section])
        
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
        
        // Listen for station played events to update recents list immediately
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StationPlayedForRecents"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStationPlayedForRecents(notification)
        }
        
        // Listen for CarPlay refresh requests from CarPlayManager
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CarPlayRefreshRequested"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCarPlayRefreshRequest(notification)
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
    
    private func handleStationPlayedForRecents(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            os_log("🚗 CarPlay: Invalid station played notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Station played for recents update - ID: %@", log: log, type: .info, stationId)
        
        // Update CarPlayManager's recents data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent() // This will refresh the recent stations list
        
        // Force refresh the recents tab template if it's currently displayed
        refreshRecentsTabTemplate()
        
        // Also trigger the legacy CarPlay content refresh
        DispatchQueue.main.async {
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    private func handleCarPlayRefreshRequest(_ notification: Notification) {
        os_log("🚗 CarPlay: Received refresh request", log: log, type: .info)
        
        // Force refresh all data
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent()
        
        // Refresh current templates
        refreshRecentsTabTemplate()
        refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
        
        // Also trigger the legacy CarPlay content refresh
        DispatchQueue.main.async {
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    private func refreshRecentsTabTemplate() {
        guard let interfaceController = self.interfaceController else {
            os_log("🚗 CarPlay: Cannot refresh recents - no interface controller", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Refreshing recents tab template", log: log, type: .info)
        
        // Get the current root template
        guard let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: Root template is not a tab bar template", log: log, type: .error)
            return
        }
        
        // Find the recents tab (should be index 2: Stations, Favorites, Recents, Podcasts)
        let recentsTabIndex = 2
        if recentsTabIndex < tabBarTemplate.templates.count,
           let recentsTab = tabBarTemplate.templates[recentsTabIndex] as? CPListTemplate {
            
            // Instead of recreating the entire tab bar template, update the existing recents tab in place
            // Get fresh recents data
            let carPlayManager = CarPlayManager.shared
            let recentStations = carPlayManager.getRecentStations()
            let recentEpisodes = carPlayManager.getRecentPodcastEpisodes()
            
            // Create new sections with updated data
            var newSections: [CPListSection] = []
            
            // Recent stations section
            var recentStationItems: [CPListItem] = []
            for station in recentStations {
                let timeAgo = formatTimeAgo(station.lastPlayed)
                let item = CPListItem(text: station.name,
                                     detailText: "Played \(timeAgo) • \(station.country)",
                                     image: carPlayManager.getStationArtwork(for: station))
                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    self?.playStation(station, completion: completion)
                }
                recentStationItems.append(item)
            }
            
            if recentStationItems.isEmpty {
                let emptyItem = CPListItem(text: "No Recent Stations", detailText: "Recently played stations will appear here")
                recentStationItems.append(emptyItem)
            }
            
            let recentStationsSection = CPListSection(items: recentStationItems, header: "Recently Played Stations", sectionIndexTitle: nil)
            newSections.append(recentStationsSection)
            
            // Recent episodes section
            var recentEpisodeItems: [CPListItem] = []
            for episode in recentEpisodes {
                let duration = formatDuration(episode.duration)
                var statusText = ""
                
                // Determine episode status based on state and current playback
                if let currentEpisode = PodcastPlayer.shared.currentEpisode,
                   currentEpisode.id == episode.id && PodcastPlayer.shared.isPlaying {
                    statusText = " • Playing"
                } else if episode.state.isPlayed {
                    statusText = " • Complete"
                } else if episode.state.progress > 0 {
                    let progressPercent = Int(episode.state.progress * 100)
                    statusText = " • \(progressPercent)% complete"
                }
                
                // Find the podcast feed for artwork
                let podcastFeeds = carPlayManager.getPodcastFeeds()
                let podcastFeed = podcastFeeds.first { feed in
                    feed.episodes.contains { $0.id == episode.id }
                }
                
                let item = CPListItem(text: episode.title,
                                     detailText: "\(duration)\(statusText)",
                                     image: podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "microphone"))
                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    self?.playEpisode(episode, completion: completion)
                }
                recentEpisodeItems.append(item)
            }
            
            if recentEpisodeItems.isEmpty {
                let emptyItem = CPListItem(text: "No Recent Episodes", detailText: "Recently played episodes will appear here")
                recentEpisodeItems.append(emptyItem)
            }
            
            let recentEpisodesSection = CPListSection(items: recentEpisodeItems, header: "Recently Played Episodes", sectionIndexTitle: nil)
            newSections.append(recentEpisodesSection)
            
            // Update the sections directly on the existing template - this preserves navigation
            recentsTab.updateSections(newSections)
            
            os_log("🚗 CarPlay: Successfully updated recents tab sections without changing navigation", log: self.log, type: .info)
        } else {
            os_log("🚗 CarPlay: Recents tab index out of bounds or not a list template", log: log, type: .error)
        }
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
        guard let currentTemplate = currentPodcastTemplate,
              let currentFeed = currentPodcastFeed,
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
        // For real-time updates, we need to recreate the entire template structure
        // This will call showPodcastDetails which now handles pagination properly
        if let interfaceController = interfaceController,
           let topTemplate = interfaceController.topTemplate as? CPListTemplate,
           topTemplate.title == podcast.title {
            
            // Pop current template and recreate with updated data
            interfaceController.popTemplate(animated: false) { [weak self] success, error in
                if success {
                    self?.showPodcastDetails(podcast) {
                        os_log("🚗 CarPlay: Successfully recreated podcast template with all episodes", log: self?.log ?? OSLog.default, type: .info)
                    }
                } else {
                    os_log("🚗 CarPlay: Failed to pop current template: %@", log: self?.log ?? OSLog.default, type: .error, error?.localizedDescription ?? "Unknown error")
                }
            }
        } else {
            // If we're not at the top, just log that we skipped the update
            os_log("🚗 CarPlay: Template not at top of stack, skipping recreation", log: log, type: .debug)
        }
    }
    
    // MARK: - On-Demand Episode Loading
    
    /// Load episodes for a specific podcast feed from CoreData on-demand
    private func loadEpisodesForPodcast(_ podcastFeed: PodcastFeed, completion: @escaping ([PodcastEpisode]) -> Void) {
        os_log("🚗 CarPlay: Loading episodes on-demand for podcast '%@'", log: log, type: .info, podcastFeed.title)
        
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    
                    return episode
                }
                
                os_log("🚗 CarPlay: Successfully loaded %d episodes for podcast '%@'", log: self.log, type: .info, episodes.count, podcastFeed.title)
                
                DispatchQueue.main.async {
                    completion(episodes)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
    
    /// Load a specific page of episodes for pagination
    private func loadEpisodesPage(for podcastFeed: PodcastFeed, page: Int, episodesPerPage: Int, completion: @escaping ([PodcastEpisode]) -> Void) {
        os_log("🚗 CarPlay: Loading page %d of episodes for podcast '%@'", log: log, type: .info, page + 1, podcastFeed.title)
        
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                episodeRequest.fetchOffset = page * episodesPerPage
                episodeRequest.fetchLimit = episodesPerPage
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    
                    return episode
                }
                
                os_log("🚗 CarPlay: Successfully loaded page %d with %d episodes", log: self.log, type: .debug, page + 1, episodes.count)
                
                DispatchQueue.main.async {
                    completion(episodes)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading episode page for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
    
    /// Get total episode count from CoreData
    private func getEpisodeCount(for podcastFeed: PodcastFeed, completion: @escaping (Int) -> Void) {
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeCountRequest.includesPropertyValues = false
                
                let count = try context.count(for: episodeCountRequest)
                
                DispatchQueue.main.async {
                    completion(count)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error counting episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                
                DispatchQueue.main.async {
                    completion(0)
                }
            }
        }
    }
} 
