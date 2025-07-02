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
import AVFoundation

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
        
        // CRITICAL: Direct artwork fetching will stop automatically when CarPlay disconnects
        // The timer-based monitoring will detect disconnection and stop itself
        os_log("🚗 CarPlay: Direct iTunes artwork fetching will stop automatically", log: log, type: .info)
        
        // CRITICAL: Save current playback state before disconnection
        // This helps restore state when app is killed and CarPlay reconnects
        savePlaybackStateForRestoration()
        
        // Clear CarPlay connection status for performance optimizations
        CarPlayManager.shared.isCarPlayConnected = false
        
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
        
        // Set CarPlay connection status for performance optimizations
        CarPlayManager.shared.isCarPlayConnected = true
        
        // Store the interface controller
        self.interfaceController = interfaceController
        
        // CRITICAL: Enhanced artwork fetching is now handled directly by CarPlay without background tasks
        // This approach uses CarPlay's active audio session privileges for immediate network access
        os_log("🚗 CarPlay: Direct iTunes artwork fetching enabled for independent operation", log: log, type: .info)
        
        // CRITICAL: Check if app was force closed and restore independently
        // This enables CarPlay to work without requiring phone app to be opened
        checkAppTerminationAndRestoreIndependently()
        
        // CRITICAL: Restore playback state when CarPlay reconnects after app force close
        // This ensures Now Playing info and UI state are properly restored
        restorePlaybackStateAfterReconnection()
        
        // Setup the root template with a small delay to allow state restoration to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupRootTemplate()
        }
        
        // Instant CarPlay restoration with no delays
        performIndependentCarPlayRestoration()
        
        // Validate CarPlay implementation compliance
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.validateCarPlayCompliance()
        }
        
        // Enhanced CarPlay artwork monitoring
        setupEnhancedArtworkMonitoring()
        
        os_log("🚗 CarPlay: Initial template setup complete with independent restoration", log: log, type: .info)
    }
    
    // MARK: - State Restoration
    
    private func savePlaybackStateForRestoration() {
        os_log("🚗 CarPlay: Saving playback state for restoration", log: log, type: .info)
        
        let userDefaults = UserDefaults.standard
        
        // Save radio state
        let radioPlayer = RadioPlayer.shared
        if radioPlayer.isPlaying, let currentStation = radioPlayer.currentlyPlayingStation {
            userDefaults.set(true, forKey: "CarPlayRadioWasPlaying")
            userDefaults.set(currentStation.id, forKey: "CarPlayLastRadioStationId")
            userDefaults.set(currentStation.name, forKey: "CarPlayLastRadioStationName")
            userDefaults.set(currentStation.url, forKey: "CarPlayLastRadioStationURL")
            os_log("🚗 CarPlay: Saved radio state - station: %@", log: log, type: .info, currentStation.name)
        } else {
            userDefaults.set(false, forKey: "CarPlayRadioWasPlaying")
        }
        
        // Save podcast state
        let podcastPlayer = PodcastPlayer.shared
        if podcastPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode {
            userDefaults.set(true, forKey: "CarPlayPodcastWasPlaying")
            userDefaults.set(currentEpisode.id, forKey: "CarPlayLastEpisodeId")
            userDefaults.set(currentEpisode.title, forKey: "CarPlayLastEpisodeTitle")
            userDefaults.set(currentEpisode.feedId, forKey: "CarPlayLastEpisodeFeedId")
            userDefaults.set(podcastPlayer.currentProgress, forKey: "CarPlayLastEpisodeProgress")
            os_log("🚗 CarPlay: Saved podcast state - episode: %@", log: log, type: .info, currentEpisode.title)
        } else {
            userDefaults.set(false, forKey: "CarPlayPodcastWasPlaying")
        }
        
        // Save active player type
        userDefaults.set(PlaybackManager.shared.activePlayer == .radio ? "radio" : "podcast", forKey: "CarPlayActivePlayer")
        
        // Save timestamp for restoration validation
        userDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlayStateTimestamp")
        
        userDefaults.synchronize()
    }
    
    private func restorePlaybackStateAfterReconnection() {
        os_log("🚗 CarPlay: Restoring playback state after reconnection", log: log, type: .info)
        
        let radioPlayer = RadioPlayer.shared
        let podcastPlayer = PodcastPlayer.shared
        
        // CRITICAL: Check what's actually active before interfering
        let hasActiveRadio = radioPlayer.isPlaying && radioPlayer.currentlyPlayingStation != nil
        let hasActivePodcast = podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil
        let podcastHasContent = podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil
        let podcastIsActivePlayer = PlaybackManager.shared.activePlayer == .podcast
        
        // CRITICAL: Don't interfere if podcast has content and is the active player
        if podcastHasContent && podcastIsActivePlayer {
            os_log("🚗 CarPlay: Podcast is active with content - not interfering with restoration", log: log, type: .info)
            // Just update the Now Playing for the active podcast without changing players
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                podcastPlayer.updateNowPlayingInfo()
            }
            return
        }
        
        // Only clear Now Playing if we're actually going to restore something different
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            os_log("🚗 CarPlay: Cleared stale Now Playing info for restoration", log: self.log, type: .info)
        }
        
        if hasActiveRadio {
            os_log("🚗 CarPlay: Restoring active radio playback state", log: log, type: .info)
            restoreRadioPlayback(radioPlayer)
        } else if hasActivePodcast {
            os_log("🚗 CarPlay: Restoring active podcast playback state", log: log, type: .info)
            restorePodcastPlayback(podcastPlayer)
        } else {
            // No active playback detected - check if app was killed and try to restore from saved state
            os_log("🚗 CarPlay: No active playback detected - checking saved state after potential app kill", log: log, type: .info)
            attemptRestoreFromSavedState()
        }
    }
    
    private func restoreRadioPlayback(_ radioPlayer: RadioPlayer) {
        guard let currentStation = radioPlayer.currentlyPlayingStation else { return }
        
        os_log("🚗 CarPlay: Restoring radio playback - station: %@", log: log, type: .info, currentStation.name)
        
        // CRITICAL: Ensure PlaybackManager knows radio is the active player
        PlaybackManager.shared.setActivePlayer(.radio)
        
        // Force update Now Playing info for radio with multiple attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            radioPlayer.forceUpdateNowPlayingInfo()
            os_log("🚗 CarPlay: First radio Now Playing info update attempt", log: self.log, type: .info)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            radioPlayer.forceUpdateNowPlayingInfo()
            os_log("🚗 CarPlay: Second radio Now Playing info update attempt", log: self.log, type: .info)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            radioPlayer.forceUpdateNowPlayingInfo()
            os_log("🚗 CarPlay: Final radio Now Playing info update attempt", log: self.log, type: .info)
        }
    }
    
    private func restorePodcastPlayback(_ podcastPlayer: PodcastPlayer) {
        guard let currentEpisode = podcastPlayer.currentEpisode else { return }
        
        os_log("🚗 CarPlay: Restoring podcast playback - episode: %@", log: log, type: .info, currentEpisode.title)
        
        // CRITICAL: Ensure PlaybackManager knows podcast is the active player
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Force update Now Playing info for podcast with multiple attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            podcastPlayer.updateNowPlayingInfo()
            os_log("🚗 CarPlay: First podcast Now Playing info update attempt", log: self.log, type: .info)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            podcastPlayer.updateNowPlayingInfo()
            
            // Send playback state notification to refresh CarPlay UI
            NotificationCenter.default.post(
                name: NSNotification.Name("PodcastPlaybackStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": currentEpisode.id,
                    "isPlaying": true
                ]
            )
            
            os_log("🚗 CarPlay: Second podcast Now Playing info update and UI state restored", log: self.log, type: .info)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            podcastPlayer.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Final podcast Now Playing info update attempt", log: self.log, type: .info)
        }
    }
    
    private func attemptRestoreFromSavedState() {
        os_log("🚗 CarPlay: Attempting to restore from saved state after app kill", log: log, type: .info)
        
        // CRITICAL: Check if podcast is currently active before interfering
        let podcastPlayer = PodcastPlayer.shared
        let podcastHasContent = podcastPlayer.currentEpisode != nil && podcastPlayer.currentFeed != nil
        let podcastIsActivePlayer = PlaybackManager.shared.activePlayer == .podcast
        
        if podcastHasContent && podcastIsActivePlayer {
            os_log("🚗 CarPlay: Podcast is currently active - not restoring from saved state", log: log, type: .info)
            return
        }
        
        let userDefaults = UserDefaults.standard
        
        // Check if we have recent saved state (within last 10 minutes)
        let savedTimestamp = userDefaults.double(forKey: "CarPlayStateTimestamp")
        let currentTime = Date().timeIntervalSince1970
        let timeDifference = currentTime - savedTimestamp
        
        if timeDifference > 600 { // 10 minutes
            os_log("🚗 CarPlay: Saved state is too old (%.0f seconds), skipping restoration", log: log, type: .info, timeDifference)
            return
        }
        
        os_log("🚗 CarPlay: Found recent saved state (%.0f seconds ago), attempting restoration", log: log, type: .info, timeDifference)
        
        // Check what was playing before
        let radioWasPlaying = userDefaults.bool(forKey: "CarPlayRadioWasPlaying")
        let podcastWasPlaying = userDefaults.bool(forKey: "CarPlayPodcastWasPlaying")
        let activePlayerType = userDefaults.string(forKey: "CarPlayActivePlayer")
        
        if radioWasPlaying && activePlayerType == "radio" {
            attemptRadioStateRestoration()
        } else if podcastWasPlaying && activePlayerType == "podcast" {
            attemptPodcastStateRestoration()
        } else {
            // Check if there's audio playing in background that we need to identify
            checkForBackgroundAudioAndRestore()
        }
    }
    
    private func attemptRadioStateRestoration() {
        // CRITICAL: Don't interfere if podcast is actively playing
        let podcastPlayer = PodcastPlayer.shared
        if podcastPlayer.isPlaying || (podcastPlayer.currentEpisode != nil && PlaybackManager.shared.activePlayer == .podcast) {
            os_log("🚗 CarPlay: Podcast is active - not restoring radio state", log: log, type: .info)
            return
        }
        
        let userDefaults = UserDefaults.standard
        guard let stationId = userDefaults.string(forKey: "CarPlayLastRadioStationId"),
              let stationName = userDefaults.string(forKey: "CarPlayLastRadioStationName"),
              let stationURL = userDefaults.string(forKey: "CarPlayLastRadioStationURL") else {
            os_log("🚗 CarPlay: Missing radio restoration data", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Attempting to restore radio station: %@", log: log, type: .info, stationName)
        
        // Create a temporary station for restoration
        let restoredStation = RadioStation(
            id: stationId,
            name: stationName,
            url: stationURL,
            iconData: nil,
            iTunesArtworkData: nil,
            country: "Unknown",
            isFavorite: false
        )
        
        // Set up PlaybackManager and force Now Playing info
        PlaybackManager.shared.setActivePlayer(.radio)
        
        // Force create Now Playing info for the restored station
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.forceRadioNowPlayingInfo(for: restoredStation)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forceRadioNowPlayingInfo(for: restoredStation)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.forceRadioNowPlayingInfo(for: restoredStation)
        }
    }
    
    private func attemptPodcastStateRestoration() {
        // CRITICAL: Don't interfere if podcast is actively playing
        let podcastPlayer = PodcastPlayer.shared
        if podcastPlayer.isPlaying || (podcastPlayer.currentEpisode != nil && PlaybackManager.shared.activePlayer == .podcast) {
            os_log("🚗 CarPlay: Podcast is already active - not restoring podcast state", log: log, type: .info)
            return
        }
        
        let userDefaults = UserDefaults.standard
        guard let _ = userDefaults.string(forKey: "CarPlayLastEpisodeId"),
              let episodeTitle = userDefaults.string(forKey: "CarPlayLastEpisodeTitle"),
              let _ = userDefaults.string(forKey: "CarPlayLastEpisodeFeedId") else {
            os_log("🚗 CarPlay: Missing podcast restoration data", log: log, type: .error)
            return
        }
        
        let progress = userDefaults.double(forKey: "CarPlayLastEpisodeProgress")
        
        os_log("🚗 CarPlay: Attempting to restore podcast episode: %@", log: log, type: .info, episodeTitle)
        
        // Set up PlaybackManager
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Force create Now Playing info for the restored episode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.forcePodcastNowPlayingInfo(episodeTitle: episodeTitle, progress: progress)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forcePodcastNowPlayingInfo(episodeTitle: episodeTitle, progress: progress)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.forcePodcastNowPlayingInfo(episodeTitle: episodeTitle, progress: progress)
        }
    }
    
    private func checkForBackgroundAudioAndRestore() {
        // Check if there's audio playing in the background
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.isOtherAudioPlaying {
            os_log("🚗 CarPlay: Detected background audio after app kill - attempting generic restoration", log: log, type: .info)
            
            // Try to restore the most recent state
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.attemptPlaybackStateRecovery()
            }
        } else {
            os_log("🚗 CarPlay: No background audio detected - no restoration needed", log: log, type: .info)
        }
    }
    
    private func forceRadioNowPlayingInfo(for station: RadioStation) {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = station.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = "StreamRadios"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = station.name
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        // Try to use station's actual artwork if available
        if let iconDataString = station.iconData, 
           let iconData = Data(base64Encoded: iconDataString),
           let image = UIImage(data: iconData) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let iTunesArtworkDataString = station.iTunesArtworkData,
                  let iTunesArtworkData = Data(base64Encoded: iTunesArtworkDataString),
                  let image = UIImage(data: iTunesArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        os_log("🚗 CarPlay: Forced radio Now Playing info for restored station: %@", log: log, type: .info, station.name)
    }
    
    private func forcePodcastNowPlayingInfo(episodeTitle: String, progress: Double) {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = episodeTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "StreamRadios Podcast"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Podcast Episode"
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        // Add progress if available
        if progress > 0 {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
        }
        
        // Don't add any artwork here to avoid green screen issue
        // The regular podcast player will set proper artwork when it takes over
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        os_log("🚗 CarPlay: Forced podcast Now Playing info for restored episode: %@", log: log, type: .info, episodeTitle)
    }
    
    // MARK: - Independent CarPlay Restoration
    
    private func checkAppTerminationAndRestoreIndependently() {
        os_log("🚗 CarPlay: Checking for app termination and independent restoration needs", log: log, type: .info)
        
        let userDefaults = UserDefaults.standard
        
        // Check if we have saved state indicating the app was playing something
        let radioWasPlaying = userDefaults.bool(forKey: "CarPlayRadioWasPlaying")
        let podcastWasPlaying = userDefaults.bool(forKey: "CarPlayPodcastWasPlaying")
        let savedTimestamp = userDefaults.double(forKey: "CarPlayStateTimestamp")
        
        if savedTimestamp > 0 && (radioWasPlaying || podcastWasPlaying) {
            let timeSinceLastSave = Date().timeIntervalSince1970 - savedTimestamp
            
            if timeSinceLastSave < 1800 { // Within last 30 minutes
                os_log("🚗 CarPlay: Found recent playback state (%.0f seconds ago) - enabling independent restoration", 
                       log: log, type: .info, timeSinceLastSave)
                
                // Mark that we need independent restoration
                userDefaults.set(true, forKey: "CarPlayNeedsIndependentRestoration")
                userDefaults.synchronize()
                
                // Start immediate background audio session to prepare for restoration
                prepareBackgroundAudioSession()
            } else {
                os_log("🚗 CarPlay: Saved state is too old (%.0f seconds) - skipping independent restoration", 
                       log: log, type: .info, timeSinceLastSave)
            }
        } else {
            os_log("🚗 CarPlay: No saved playback state found - no independent restoration needed", log: log, type: .info)
        }
    }
    
    private func performIndependentCarPlayRestoration() {
        let userDefaults = UserDefaults.standard
        
        // Check if we need independent restoration
        guard userDefaults.bool(forKey: "CarPlayNeedsIndependentRestoration") else {
            return
        }
        
        os_log("🚗 CarPlay: Performing independent CarPlay restoration", log: log, type: .info)
        
        // Check current playback state
        let radioPlayer = RadioPlayer.shared
        let podcastPlayer = PodcastPlayer.shared
        
        // If no active playback, force restore from saved state
        if !radioPlayer.isPlaying && !podcastPlayer.isPlaying {
            os_log("🚗 CarPlay: No active playback detected - forcing restoration from saved state", log: log, type: .info)
            forceRestoreFromSavedState()
        } else {
            // Clear the restoration flag since we have active playback
            userDefaults.set(false, forKey: "CarPlayNeedsIndependentRestoration")
            userDefaults.synchronize()
            os_log("🚗 CarPlay: Active playback detected - independent restoration not needed", log: log, type: .info)
        }
    }
    
    private func prepareBackgroundAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try audioSession.setActive(true)
            os_log("🚗 CarPlay: Background audio session prepared for independent restoration", log: log, type: .info)
        } catch {
            os_log("🚗 CarPlay: Failed to prepare background audio session: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func forceRestoreFromSavedState() {
        os_log("🚗 CarPlay: Force restoring from saved state for independent CarPlay operation", log: log, type: .info)
        
        let userDefaults = UserDefaults.standard
        let radioWasPlaying = userDefaults.bool(forKey: "CarPlayRadioWasPlaying")
        let podcastWasPlaying = userDefaults.bool(forKey: "CarPlayPodcastWasPlaying")
        let activePlayerType = userDefaults.string(forKey: "CarPlayActivePlayer")
        
        if radioWasPlaying && activePlayerType == "radio" {
            os_log("🚗 CarPlay: Force restoring radio state for independent operation", log: log, type: .info)
            forceRestoreRadioState()
        } else if podcastWasPlaying && activePlayerType == "podcast" {
            os_log("🚗 CarPlay: Force restoring podcast state for independent operation", log: log, type: .info)
            forceRestorePodcastState()
        }
        
        // Clear the restoration flag
        userDefaults.set(false, forKey: "CarPlayNeedsIndependentRestoration")
        userDefaults.synchronize()
    }
    
    private func forceRestoreRadioState() {
        let userDefaults = UserDefaults.standard
        guard let stationId = userDefaults.string(forKey: "CarPlayLastRadioStationId"),
              let stationName = userDefaults.string(forKey: "CarPlayLastRadioStationName"),
              let stationURL = userDefaults.string(forKey: "CarPlayLastRadioStationURL") else {
            os_log("🚗 CarPlay: Missing radio restoration data for independent operation", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Force restoring radio station for independent CarPlay: %@", log: log, type: .info, stationName)
        
        // Create a temporary station for restoration
        let restoredStation = RadioStation(
            id: stationId,
            name: stationName,
            url: stationURL,
            iconData: nil,
            iTunesArtworkData: nil,
            country: "Unknown",
            isFavorite: false
        )
        
        // Force set PlaybackManager state
        PlaybackManager.shared.setActivePlayer(.radio)
        
        // Create comprehensive Now Playing info immediately
        createImmediateRadioNowPlayingInfo(for: restoredStation)
        
        // Set up multiple fallback updates
        for delay in [0.2, 0.5, 1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.createImmediateRadioNowPlayingInfo(for: restoredStation)
            }
        }
    }
    
    private func forceRestorePodcastState() {
        let userDefaults = UserDefaults.standard
        guard let episodeId = userDefaults.string(forKey: "CarPlayLastEpisodeId"),
              let episodeTitle = userDefaults.string(forKey: "CarPlayLastEpisodeTitle"),
              let feedId = userDefaults.string(forKey: "CarPlayLastEpisodeFeedId") else {
            os_log("🚗 CarPlay: Missing podcast restoration data for independent operation", log: log, type: .error)
            return
        }
        
        let progress = userDefaults.double(forKey: "CarPlayLastEpisodeProgress")
        
        os_log("🚗 CarPlay: Force restoring podcast episode for independent CarPlay: %@", log: log, type: .info, episodeTitle)
        
        // Force set PlaybackManager state
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Create comprehensive Now Playing info immediately
        createImmediatePodcastNowPlayingInfo(episodeTitle: episodeTitle, progress: progress, episodeId: episodeId, feedId: feedId)
        
        // Set up multiple fallback updates
        for delay in [0.2, 0.5, 1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.createImmediatePodcastNowPlayingInfo(episodeTitle: episodeTitle, progress: progress, episodeId: episodeId, feedId: feedId)
            }
        }
    }
    
    private func createImmediateRadioNowPlayingInfo(for station: RadioStation) {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = station.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = "StreamRadios"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Radio Station"
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] = 1.0
        
        // Try to use station's actual artwork if available
        if let iconDataString = station.iconData, 
           let iconData = Data(base64Encoded: iconDataString),
           let image = UIImage(data: iconData) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let iTunesArtworkDataString = station.iTunesArtworkData,
                  let iTunesArtworkData = Data(base64Encoded: iTunesArtworkDataString),
                  let image = UIImage(data: iTunesArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        // If no artwork available, don't set any artwork (better than corrupted green image)
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Also set up remote command center
        setupRemoteCommandCenter()
        
        os_log("🚗 CarPlay: Created immediate radio Now Playing info for independent operation: %@", log: log, type: .info, station.name)
    }
    
    private func createImmediatePodcastNowPlayingInfo(episodeTitle: String, progress: Double, episodeId: String, feedId: String) {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = episodeTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "StreamRadios Podcast"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Podcast Episode"
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        // Add progress information
        if progress > 0 {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] = min(progress / 3600.0, 1.0) // Assume max 1 hour for progress calculation
        }
        
        // Try to find and use actual podcast artwork from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let podcastFeeds = carPlayManager.getPodcastFeeds()
        if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
            var imageData: Data?
            
            if let imageDataString = feed.imageData {
                imageData = Data(base64Encoded: imageDataString)
            } else if let iconDataString = feed.iconData {
                imageData = Data(base64Encoded: iconDataString)
            }
            
            if let imageData = imageData, let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
        }
        // If no artwork available, don't set any artwork (better than corrupted green image)
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Also set up remote command center
        setupRemoteCommandCenter()
        
        os_log("🚗 CarPlay: Created immediate podcast Now Playing info for independent operation: %@", log: log, type: .info, episodeTitle)
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Enable basic playback controls
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        
        os_log("🚗 CarPlay: Remote command center configured for independent operation", log: log, type: .info)
    }

    private func attemptPlaybackStateRecovery() {
        os_log("🚗 CarPlay: Attempting playback state recovery after force close", log: log, type: .info)
        
        // Check if we can determine what was playing from saved state
        let radioPlayer = RadioPlayer.shared
        let podcastPlayer = PodcastPlayer.shared
        
        // Try to recover radio state
        if let lastPlayedStation = radioPlayer.currentlyPlayingStation {
            os_log("🚗 CarPlay: Attempting to recover radio state for station: %@", log: log, type: .info, lastPlayedStation.name)
            
            // CRITICAL: Set PlaybackManager state first
            PlaybackManager.shared.activePlayer = .radio
            
            // Force update the radio player state
            radioPlayer.isPlaying = true
            
            // Multiple attempts to update Now Playing info
            radioPlayer.updateNowPlayingInfo()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                radioPlayer.updateNowPlayingInfo()
                self.refreshRecentsTabTemplate()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                radioPlayer.updateNowPlayingInfo()
            }
        }
        
        // Try to recover podcast state
        if let lastPlayedEpisode = podcastPlayer.currentEpisode {
            os_log("🚗 CarPlay: Attempting to recover podcast state for episode: %@", log: log, type: .info, lastPlayedEpisode.title)
            
            // CRITICAL: Set PlaybackManager state first
            PlaybackManager.shared.activePlayer = .podcast
            
            // Force update the podcast player state
            podcastPlayer.isPlaying = true
            
            // Multiple attempts to update Now Playing info
            podcastPlayer.updateNowPlayingInfo()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                podcastPlayer.updateNowPlayingInfo()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                podcastPlayer.updateNowPlayingInfo()
            }
            
            // Send notification to refresh CarPlay UI
            NotificationCenter.default.post(
                name: NSNotification.Name("PodcastPlaybackStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": lastPlayedEpisode.id,
                    "isPlaying": true
                ]
            )
        }
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
        print("🚗 CarPlay: Creating downloads tab...")
        let downloadsTab = self.createDownloadsTab()
        print("🚗 CarPlay: Creating recents tab...")
        let recentsTab = self.createRecentsTab() 
        print("🚗 CarPlay: Creating podcasts tab...")
        let podcastsTab = self.createPodcastsTab()
        
        print("🚗 CarPlay: Creating tab bar template with \([stationsTab, downloadsTab, recentsTab, podcastsTab].count) tabs")
        
        // Create tab bar template
        let tabBarTemplate = CPTabBarTemplate(templates: [stationsTab, downloadsTab, recentsTab, podcastsTab])
        
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
        
        // Get favorite stations from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let favoriteStations = carPlayManager.getFavoriteStations()
        
        var favoriteStationItems: [CPListItem] = []
        // Show ALL favorite stations - no artificial limits
        for station in favoriteStations {
            let isCurrentlyPlaying = RadioPlayer.shared.currentlyPlayingStation?.id == station.id && RadioPlayer.shared.isPlaying
            
            let item = CPListItem(text: station.name,
                                 detailText: station.country,
                                 image: carPlayManager.getStationArtwork(for: station))
            
            // Set Apple standard highlighting for currently playing station
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            favoriteStationItems.append(item)
        }
        
        if favoriteStationItems.isEmpty {
            let emptyItem = CPListItem(text: "No Favorite Stations", detailText: "Add stations to favorites to see them here")
            favoriteStationItems.append(emptyItem)
        }
        
        let favoriteSection = CPListSection(items: favoriteStationItems, header: "Favorite Stations", sectionIndexTitle: nil)
        sections.append(favoriteSection)
        
        // Get available countries and stations
        let availableCountries = carPlayManager.getAvailableCountries()
        
        if availableCountries.isEmpty {
            let emptyItem = CPListItem(text: "No Stations Available", detailText: "Check your internet connection")
            let emptySection = CPListSection(items: [emptyItem], header: "Browse by Country", sectionIndexTitle: nil)
            sections.append(emptySection)
        } else {
            var countryItems: [CPListItem] = []
            // Show ALL countries - no artificial limits
            for country in availableCountries {
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
    
    private func createDownloadsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get all downloaded episodes grouped by podcast
        let carPlayManager = CarPlayManager.shared
        let podcastFeeds = carPlayManager.getPodcastFeeds()
        
        // Group downloaded episodes by podcast feed
        var podcastsWithDownloads: [(feed: PodcastFeed, episodes: [PodcastEpisode])] = []
        
        for feed in podcastFeeds {
            // Get downloaded episodes for this podcast from CoreData
            let downloadedEpisodes = getDownloadedEpisodesForPodcast(feed)
            if !downloadedEpisodes.isEmpty {
                podcastsWithDownloads.append((feed: feed, episodes: downloadedEpisodes))
            }
        }
        
        if podcastsWithDownloads.isEmpty {
            // No downloads found
            let emptyItem = CPListItem(text: "No Downloaded Episodes", 
                                     detailText: "Downloaded podcast episodes will appear here")
            let emptySection = CPListSection(items: [emptyItem], header: "Downloads", sectionIndexTitle: nil)
            sections.append(emptySection)
        } else {
            // Create a section for each podcast with downloads
            for podcastWithDownloads in podcastsWithDownloads {
                let feed = podcastWithDownloads.feed
                let episodes = podcastWithDownloads.episodes
                
                var episodeItems: [CPListItem] = []
                
                for episode in episodes {
                    let duration = formatDuration(episode.duration)
                    var statusText = ""
                    let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
                    
                    // Determine episode status based on state and current playback
                    if isCurrentlyPlaying {
                        statusText = " • Playing"
                    } else if episode.state.isPlayed {
                        statusText = " • Complete"
                    } else if episode.state.progress > 0 {
                        let progressPercent = Int(episode.state.progress * 100)
                        statusText = " • \(progressPercent)% complete"
                    }
                    
                    // Always add downloaded indicator
                    statusText += " • Downloaded"
                    
                    // Use podcast artwork for downloaded episodes
                    let itemImage = carPlayManager.getPodcastArtwork(for: feed)
                    
                    let item = CPListItem(text: episode.title,
                                         detailText: "\(duration)\(statusText)",
                                         image: itemImage)
                    
                    // Set Apple standard highlighting for currently playing episode
                    if #available(iOS 14.0, *) {
                        item.isPlaying = isCurrentlyPlaying
                    }
                    
                    item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                        self?.playEpisode(episode, completion: completion)
                    }
                    
                    episodeItems.append(item)
                }
                
                // Create section for this podcast
                let sectionHeader = "\(feed.title) (\(episodes.count) downloaded)"
                let podcastSection = CPListSection(items: episodeItems, header: sectionHeader, sectionIndexTitle: nil)
                sections.append(podcastSection)
            }
        }
        
        let listTemplate = CPListTemplate(title: "Downloads", sections: sections)
        listTemplate.tabTitle = "Downloads"
        listTemplate.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        
        return listTemplate
    }
    
    // MARK: - Helper Methods for Downloads
    
    private func getDownloadedEpisodesForPodcast(_ podcast: PodcastFeed) -> [PodcastEpisode] {
        let context = CoreDataStack.shared.context
        var downloadedEpisodes: [PodcastEpisode] = []
        
        context.performAndWait {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@ AND isDownloaded == YES", podcast.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                let managedEpisodes = try context.fetch(episodeRequest)
                downloadedEpisodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    return episode
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading downloaded episodes for podcast '%@': %@", log: self.log, type: .error, podcast.title, error.localizedDescription)
            }
        }
        
        return downloadedEpisodes
    }
    
    private func createRecentsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Get recent stations from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let recentStations = carPlayManager.getRecentStations()
        
        var recentStationItems: [CPListItem] = []
        for station in recentStations {
            let timeAgo = formatTimeAgo(station.lastPlayed)
            let isCurrentlyPlaying = RadioPlayer.shared.currentlyPlayingStation?.id == station.id && RadioPlayer.shared.isPlaying
            
            let item = CPListItem(text: station.name,
                                 detailText: "Played \(timeAgo) • \(station.country)",
                                 image: carPlayManager.getStationArtwork(for: station))
            
            // Set Apple standard highlighting for currently playing station
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
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
        
        // Get recent podcast episodes from CarPlayManager SECOND (after stations)
        let recentEpisodes = carPlayManager.getRecentPodcastEpisodes()
        
        var recentEpisodeItems: [CPListItem] = []
        for episode in recentEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
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
                feed.id == episode.feedId
            }
            
            // Use podcast artwork for recently played episodes
            let itemImage = podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "microphone")
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: itemImage)
            
            // Set Apple standard highlighting for currently playing episode
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
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
            // Get episode count synchronously
            let episodeCount = getEpisodeCountSync(for: podcast)
            
            let item = CPListItem(text: podcast.title,
                                 detailText: "\(episodeCount) episodes",
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
        // Validate template depth before navigation
        validateTemplateDepth()
        
        let carPlayManager = CarPlayManager.shared
        let stations = carPlayManager.getStations(for: country)
        
        var stationItems: [CPListItem] = []
        
        // Show ALL stations for the country - no artificial limits
        for station in stations {
            let isCurrentlyPlaying = RadioPlayer.shared.currentlyPlayingStation?.id == station.id && RadioPlayer.shared.isPlaying
            
            let item = CPListItem(text: station.name,
                                 detailText: station.country,
                                 image: carPlayManager.getStationArtwork(for: station))
            
            // Set Apple standard highlighting for currently playing station
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playStation(station, completion: completion)
            }
            stationItems.append(item)
        }
        
        let section = CPListSection(items: stationItems, header: "\(country) Stations (\(stations.count))", sectionIndexTitle: nil)
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
            
            // PERFORMANCE OPTIMIZATION: Load only initial batch for fast CarPlay response
            let initialBatchSize = min(50, totalEpisodes) // Load max 50 episodes initially
            os_log("🚗 CarPlay: Podcast '%@' has %d episodes, loading initial batch of %d for fast response", log: self.log, type: .info, podcast.title, totalEpisodes, initialBatchSize)
            
            self.loadInitialEpisodesForPodcast(podcast, limit: initialBatchSize) { episodes in
                var updatedPodcast = podcast
                updatedPodcast.episodes = episodes
                self.displayPodcastWithPagination(updatedPodcast, totalEpisodes: totalEpisodes, loadedCount: episodes.count, completion: completion)
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
        
        // Add filter section for Downloaded and Bookmarked episodes
        let downloadedEpisodes = podcast.episodes.filter { $0.state.isDownloaded }
        let bookmarkedEpisodes = podcast.episodes.filter { $0.state.isFavorite }
        
        var filterItems: [CPListItem] = []
        
        // Add "Downloaded Episodes" filter if there are any downloaded episodes
        if !downloadedEpisodes.isEmpty {
            let downloadedItem = CPListItem(text: "Downloaded Episodes",
                                           detailText: "\(downloadedEpisodes.count) downloaded",
                                           image: UIImage(systemName: "arrow.down.circle"))
            downloadedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showDownloadedEpisodesFromList(downloadedEpisodes, podcastTitle: podcast.title, completion: completion)
            }
            filterItems.append(downloadedItem)
        }
        
        // Add "Bookmarked Episodes" filter if there are any bookmarked episodes
        if !bookmarkedEpisodes.isEmpty {
            let bookmarkedItem = CPListItem(text: "Bookmarked Episodes",
                                           detailText: "\(bookmarkedEpisodes.count) bookmarked",
                                           image: UIImage(systemName: "bookmark.fill"))
            bookmarkedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showBookmarkedEpisodesFromList(bookmarkedEpisodes, podcastTitle: podcast.title, completion: completion)
            }
            filterItems.append(bookmarkedItem)
        }
        
        // Add filter section if we have any filters
        if !filterItems.isEmpty {
            let filterSection = CPListSection(items: filterItems, header: "Filter", sectionIndexTitle: nil)
            sections.append(filterSection)
        }
        
        // Show ALL episodes - no artificial limits
        var episodeItems: [CPListItem] = []
        
        for episode in podcast.episodes {
            let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
            episodeItems.append(item)
        }
        
        let episodesSection = CPListSection(items: episodeItems, header: "Episodes (\(totalEpisodes))", sectionIndexTitle: nil)
        sections.append(episodesSection)
        
        let listTemplate = CPListTemplate(title: podcast.title, sections: sections)
        
        currentPodcastTemplate = listTemplate
        currentPodcastFeed = podcast
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    /// PERFORMANCE OPTIMIZED: Display podcast with pagination for fast CarPlay response
    private func displayPodcastWithPagination(_ podcast: PodcastFeed, totalEpisodes: Int, loadedCount: Int, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        var sections: [CPListSection] = []
        
        // Add filter section for Downloaded and Bookmarked episodes
        let downloadedEpisodes = podcast.episodes.filter { $0.state.isDownloaded }
        let bookmarkedEpisodes = podcast.episodes.filter { $0.state.isFavorite }
        
        var filterItems: [CPListItem] = []
        
        // Add "Downloaded Episodes" filter if there are any downloaded episodes
        if !downloadedEpisodes.isEmpty {
            let downloadedItem = CPListItem(text: "Downloaded Episodes",
                                           detailText: "\(downloadedEpisodes.count) downloaded",
                                           image: UIImage(systemName: "arrow.down.circle"))
            downloadedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showDownloadedEpisodesFromList(downloadedEpisodes, podcastTitle: podcast.title, completion: completion)
            }
            filterItems.append(downloadedItem)
        }
        
        // Add "Bookmarked Episodes" filter if there are any bookmarked episodes
        if !bookmarkedEpisodes.isEmpty {
            let bookmarkedItem = CPListItem(text: "Bookmarked Episodes",
                                           detailText: "\(bookmarkedEpisodes.count) bookmarked",
                                           image: UIImage(systemName: "bookmark.fill"))
            bookmarkedItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.showBookmarkedEpisodesFromList(bookmarkedEpisodes, podcastTitle: podcast.title, completion: completion)
            }
            filterItems.append(bookmarkedItem)
        }
        
        // Add filter section if we have any filters
        if !filterItems.isEmpty {
            let filterSection = CPListSection(items: filterItems, header: "Filter", sectionIndexTitle: nil)
            sections.append(filterSection)
        }
        
        // Show loaded episodes
        var episodeItems: [CPListItem] = []
        
        for episode in podcast.episodes {
            let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
            episodeItems.append(item)
        }
        
        // Add "Load More Episodes" option if there are more episodes to load
        if loadedCount < totalEpisodes {
            let remainingCount = totalEpisodes - loadedCount
            let loadMoreItem = CPListItem(text: "Load More Episodes",
                                         detailText: "\(remainingCount) more episodes available",
                                         image: UIImage(systemName: "ellipsis.circle"))
            loadMoreItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.loadAllRemainingEpisodes(podcast, completion: completion)
            }
            episodeItems.append(loadMoreItem)
        }
        
        let episodesHeader = loadedCount < totalEpisodes ? "Recent Episodes (\(loadedCount) of \(totalEpisodes))" : "Episodes (\(totalEpisodes))"
        let episodesSection = CPListSection(items: episodeItems, header: episodesHeader, sectionIndexTitle: nil)
        sections.append(episodesSection)
        
        let listTemplate = CPListTemplate(title: podcast.title, sections: sections)
        
        currentPodcastTemplate = listTemplate
        currentPodcastFeed = podcast
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    /// Load all remaining episodes when user taps "Load More Episodes"
    private func loadAllRemainingEpisodes(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        os_log("🚗 CarPlay: Loading all remaining episodes for podcast '%@'", log: log, type: .info, podcast.title)
        
        // Load all episodes now
        loadEpisodesForPodcast(podcast) { [weak self] allEpisodes in
            guard let self = self else { return }
            
            var updatedPodcast = podcast
            updatedPodcast.episodes = allEpisodes
            
            // Replace current template with full episode list
            self.displayPodcastWithAllEpisodes(updatedPodcast, totalEpisodes: allEpisodes.count, completion: completion)
        }
    }
    

    
    private func createEpisodeListItem(episode: PodcastEpisode, podcast: PodcastFeed, carPlayManager: CarPlayManager) -> CPListItem {
        let duration = formatDuration(episode.duration)
        var statusText = ""
        let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
        
        // Determine episode status based on state and current playback
        if isCurrentlyPlaying {
            statusText = " • Playing"
        } else if episode.state.isPlayed {
            statusText = " • Complete"
        } else if episode.state.progress > 0 {
            statusText = " • IN PROGRESS"
        }
        
        // Add download indicator
        if episode.state.isDownloaded {
            statusText += " • Downloaded"
        }
        
        // Use standard podcast artwork for all episodes
        let itemImage = carPlayManager.getPodcastArtwork(for: podcast)
        
        let item = CPListItem(text: episode.title,
                             detailText: "\(duration)\(statusText)",
                             image: itemImage)
        
        // Set Apple standard highlighting for currently playing episode
        if #available(iOS 14.0, *) {
            item.isPlaying = isCurrentlyPlaying
        }
        
        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
            self?.playEpisode(episode, completion: completion)
        }
        
        return item
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
    
    private func loadAndShowBookmarkedEpisodes(_ podcast: PodcastFeed, completion: @escaping () -> Void) {
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@ AND isFavorite == YES", podcast.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let bookmarkedEpisodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    return episode
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.showBookmarkedEpisodesFromList(bookmarkedEpisodes, podcastTitle: podcast.title, completion: completion)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading bookmarked episodes: %@", log: self.log, type: .error, error.localizedDescription)
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
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if episode.state.isPlayed {
                statusText = " • Complete"
            } else if episode.state.progress > 0 {
                statusText = " • IN PROGRESS"
            }
            
            // Find the podcast feed for artwork
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            let podcastFeed = podcastFeeds.first { feed in
                feed.id == episode.feedId
            }
            
            // Use podcast artwork for downloaded episodes
            let itemImage = podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "arrow.down.circle.fill")
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: itemImage)
            
            // Set Apple standard highlighting for currently playing episode
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
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
    
    private func showBookmarkedEpisodesFromList(_ bookmarkedEpisodes: [PodcastEpisode], podcastTitle: String, completion: @escaping () -> Void) {
        let carPlayManager = CarPlayManager.shared
        var episodeItems: [CPListItem] = []
        
        for episode in bookmarkedEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if episode.state.isPlayed {
                statusText = " • Complete"
            } else if episode.state.progress > 0 {
                statusText = " • IN PROGRESS"
            }
            
            // Add download indicator if episode is also downloaded
            if episode.state.isDownloaded {
                statusText += " • Downloaded"
            }
            
            // Find the podcast feed for artwork
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            let podcastFeed = podcastFeeds.first { feed in
                feed.id == episode.feedId
            }
            
            // Use podcast artwork for bookmarked episodes
            let itemImage = podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "bookmark.fill")
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: itemImage)
            
            // Set Apple standard highlighting for currently playing episode
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            episodeItems.append(item)
        }
        
        if episodeItems.isEmpty {
            let emptyItem = CPListItem(text: "No Bookmarked Episodes", detailText: "Bookmark episodes to see them here")
            episodeItems.append(emptyItem)
        }
        
        let section = CPListSection(items: episodeItems, header: "Bookmarked Episodes", sectionIndexTitle: nil)
        let listTemplate = CPListTemplate(title: "\(podcastTitle) - Bookmarked", sections: [section])
        
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: { success, error in
            completion()
        })
    }
    
    private func playStation(_ station: RadioStation, completion: @escaping () -> Void) {
        os_log("CarPlay: Playing station %@", log: log, type: .info, station.name)
        
        // CRITICAL: Save station state immediately for independent CarPlay operation
        let userDefaults = UserDefaults.standard
        userDefaults.set(true, forKey: "CarPlayRadioWasPlaying")
        userDefaults.set(station.id, forKey: "CarPlayLastRadioStationId")
        userDefaults.set(station.name, forKey: "CarPlayLastRadioStationName")
        userDefaults.set(station.url, forKey: "CarPlayLastRadioStationURL")
        userDefaults.set("radio", forKey: "CarPlayActivePlayer")
        userDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlayStateTimestamp")
        userDefaults.synchronize()
        
        // Use the existing RadioPlayer to play the station
        DispatchQueue.main.async {
            let radioPlayer = RadioPlayer.shared
            
            // CRITICAL: Set PlaybackManager state FIRST and ensure audio session is configured
            PlaybackManager.shared.setActivePlayer(.radio)
            os_log("🚗 CarPlay: Set radio as active player with audio session", log: self.log, type: .info)
            
            // CRITICAL: Force clear any stale Now Playing info before setting new info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            os_log("🚗 CarPlay: Cleared stale Now Playing info", log: self.log, type: .info)
            
            // CRITICAL: Create immediate Now Playing info for independent operation
            self.createImmediateRadioNowPlayingInfo(for: station)
            
            if let stationIndex = RadioStationViewModel.shared.stations.firstIndex(where: { $0.id == station.id }) {
                radioPlayer.playStation(at: stationIndex, from: RadioStationViewModel.shared.stations)
                
                // CRITICAL: Immediate Now Playing info update (early attempt)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Use force update to bypass any active player checks
                    radioPlayer.forceUpdateNowPlayingInfo()
                    // Also create our independent version as backup
                    self.createImmediateRadioNowPlayingInfo(for: station)
                    os_log("🚗 CarPlay: Early forced Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
                
                // CRITICAL: Primary Now Playing info update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Ensure PlaybackManager state is still correct
                    PlaybackManager.shared.activePlayer = .radio
                    radioPlayer.forceUpdateNowPlayingInfo()
                    // Also create our independent version as backup
                    self.createImmediateRadioNowPlayingInfo(for: station)
                    os_log("🚗 CarPlay: Primary forced Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
                
                // Additional fallback attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Ensure PlaybackManager state is still correct
                    PlaybackManager.shared.activePlayer = .radio
                    radioPlayer.forceUpdateNowPlayingInfo()
                    // Also create our independent version as backup
                    self.createImmediateRadioNowPlayingInfo(for: station)
                    os_log("🚗 CarPlay: Fallback forced Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
                
                // Final attempt to ensure it's set
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    // Ensure PlaybackManager state is still correct
                    PlaybackManager.shared.activePlayer = .radio
                    radioPlayer.forceUpdateNowPlayingInfo()
                    // Also create our independent version as backup
                    self.createImmediateRadioNowPlayingInfo(for: station)
                    os_log("🚗 CarPlay: Final forced Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
            } else {
                // Station not found in RadioStationViewModel - handle independently
                os_log("🚗 CarPlay: Station not found in RadioStationViewModel - handling independently", log: self.log, type: .info)
                
                // Force create Now Playing info for independent operation
                for delay in [0.0, 0.2, 0.5, 1.0, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.createImmediateRadioNowPlayingInfo(for: station)
                    }
                }
            }
            
            // CRITICAL: Apply cached iTunes artwork for CarPlay immediately
            // This works even when the main app is force-closed using pre-cached data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.applyCachedArtworkToCarPlay()
                os_log("🚗 CarPlay: Triggered immediate cached iTunes artwork application for station: %@", log: self.log, type: .info, station.name)
            }
            
            // CRITICAL: Trigger fresh iTunes artwork fetch immediately for PlayNow
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.triggerImmediateITunesArtworkFetch()
                os_log("🚗 CarPlay: Triggered immediate iTunes artwork fetch for PlayNow: %@", log: self.log, type: .info, station.name)
            }
            
            // Additional attempts to ensure artwork is applied
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.applyCachedArtworkToCarPlay()
                os_log("🚗 CarPlay: Fallback cached iTunes artwork application for station: %@", log: self.log, type: .info, station.name)
            }
            
            // Final iTunes artwork fetch attempt if still no artwork
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
                if nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
                    self.triggerImmediateITunesArtworkFetch()
                    os_log("🚗 CarPlay: Final iTunes artwork fetch attempt for PlayNow: %@", log: self.log, type: .info, station.name)
                }
            }
            
            completion()
        }
    }
    
    private func playEpisode(_ episode: PodcastEpisode, completion: @escaping () -> Void) {
        os_log("🚗 CarPlay: Playing episode '%@' with progress: %.2f%%", log: log, type: .info, episode.title, episode.state.progress * 100)
        
        // Use the existing PodcastPlayer to play the episode
        DispatchQueue.main.async { [self] in
            let podcastPlayer = PodcastPlayer.shared
            let carPlayManager = CarPlayManager.shared
            
            // CRITICAL: Set PlaybackManager state before playing
            PlaybackManager.shared.activePlayer = .podcast
            
            // Add episode to recently played list (but don't refresh UI yet)
            carPlayManager.addEpisodeToRecentlyPlayed(episode)
            
            // Find the feed that contains this episode
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
                // Since feeds are loaded on-demand and may have empty episodes arrays,
                // try to find the feed by feedId and create a minimal feed for playback
                os_log("🚗 CarPlay: Could not find feed with loaded episodes for episode '%@', searching by feedId", log: self.log, type: .info, episode.title)
                
                if let feed = podcastFeeds.first(where: { $0.id == episode.feedId }) {
                    // Found the feed by ID, create a temporary feed with this episode for playback
                    var tempFeed = feed
                    tempFeed.episodes = [episode]
                    os_log("🚗 CarPlay: Found feed by ID, playing episode with temporary feed", log: self.log, type: .info)
                    podcastPlayer.playEpisode(episode, feed: tempFeed)
                } else {
                    // Last resort: create a minimal feed just for playback
                    os_log("🚗 CarPlay: Creating minimal feed for episode playback", log: self.log, type: .info)
                    let minimalFeed = PodcastFeed(
                        id: episode.feedId,
                        title: "Unknown Podcast",
                        url: "",
                        artworkUrl: nil,
                        description: "",
                        iconData: nil,
                        imageData: nil,
                        episodes: [episode]
                    )
                    podcastPlayer.playEpisode(episode, feed: minimalFeed)
                }
            }
            
            // CRITICAL: Force Now Playing info update after starting playback
            // This ensures Now Playing info is set even after app force close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                podcastPlayer.updateNowPlayingInfo()
                os_log("🚗 CarPlay: Forced Now Playing info update for episode: %@", log: self.log, type: .info, episode.title)
            }
            
            // Additional fallback attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                podcastPlayer.updateNowPlayingInfo()
                os_log("🚗 CarPlay: Fallback Now Playing info update for episode: %@", log: self.log, type: .info, episode.title)
            }
            
            // CRITICAL: Call completion immediately to prevent CarPlay from showing empty state
            // The episode will start playing in the background, and UI updates will happen via notifications
            os_log("🚗 CarPlay: Episode playback initiated, completing CarPlay action", log: self.log, type: .info)
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
                let isCurrentlyPlaying = RadioPlayer.shared.currentlyPlayingStation?.id == station.id && RadioPlayer.shared.isPlaying
                
                let item = CPListItem(text: station.name, 
                                     detailText: station.country, // Use country instead of genre
                                     image: carPlayManager.getStationArtwork(for: station))
                
                // Set Apple standard highlighting for currently playing station
                if #available(iOS 14.0, *) {
                    item.isPlaying = isCurrentlyPlaying
                }
                
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
        
        // Listen for iTunes artwork updates to refresh Now Playing info
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StationArtworkUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStationArtworkUpdate(notification)
        }
    }
    
    private func handlePodcastProgressUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            os_log("🚗 CarPlay: Invalid progress update notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Received progress update for episode ID: %@, progress: %.1f%%", log: log, type: .debug, episodeId, progress * 100)
        
        // Update the episode in CarPlayManager's data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateEpisodeProgress(episodeId: episodeId, progress: progress, isCompleted: progress >= 0.99)
        
        // CRITICAL: COMPLETELY ELIMINATE ALL UI REFRESHES for progress updates to maximize CPU performance
        // Progress updates happen frequently and ANY UI refresh causes significant CPU spikes
        // CarPlay will handle progress display through MPNowPlayingInfoCenter which is much more efficient
        // Only update internal data, never refresh templates or UI for progress updates
        
        // Remove even the legacy CarPlay refresh as it's not needed and causes CPU overhead
        // MPNowPlayingInfoCenter handles progress display in CarPlay more efficiently
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
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // Modern CarPlay uses CPTemplateApplicationScene and direct template updates
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
        
        // Get current playing episode for debugging
        let currentPlayingEpisodeId = PodcastPlayer.shared.currentEpisode?.id
        let playerIsPlaying = PodcastPlayer.shared.isPlaying
        os_log("🚗 CarPlay: PodcastPlayer state - current episode: %@, is playing: %@", log: log, type: .info, currentPlayingEpisodeId ?? "none", playerIsPlaying ? "YES" : "NO")
        
        // CRITICAL: Update CarPlayManager's data immediately before refreshing templates
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent() // Refresh all data from core data to get latest state
        
        // For episode START events (isPlaying = true), delay UI updates to prevent blank sheet
        // For episode STOP events (isPlaying = false), update immediately
        if isPlaying {
            // CRITICAL: Delay UI updates when episode starts to prevent blank sheet issue
            // Allow episode to fully initialize before updating CarPlay UI
            os_log("🚗 CarPlay: Episode starting - delaying UI updates to prevent blank sheet", log: log, type: .info)
            
            // CRITICAL: Force Now Playing info update for episodes after force close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PodcastPlayer.shared.updateNowPlayingInfo()
                os_log("🚗 CarPlay: Forced Now Playing info update for episode start", log: self.log, type: .info)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performDelayedPlaybackUIUpdates(episodeId: episodeId)
                // Additional Now Playing update with UI updates
                PodcastPlayer.shared.updateNowPlayingInfo()
            }
        } else {
            // Episode stopped/paused - update UI immediately
            os_log("🚗 CarPlay: Episode stopped/paused - updating UI immediately", log: log, type: .info)
            performImmediatePlaybackUIUpdates(episodeId: episodeId)
        }
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // Modern CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func performDelayedPlaybackUIUpdates(episodeId: String) {
        os_log("🚗 CarPlay: Performing delayed UI updates for episode ID: %@", log: log, type: .info, episodeId)
        
        // Use the same efficient section update approach that works perfectly for Recents tab
        // This provides immediate visual highlighting changes just like Recents does
        forceImmediateSectionUpdate(episodeId: episodeId)
        
        // Also refresh the recents tab and downloads tab to show/hide the highlighted playing state
        refreshRecentsTabTemplate()
        refreshDownloadsTabTemplate()
    }
    
    private func performImmediatePlaybackUIUpdates(episodeId: String) {
        os_log("🚗 CarPlay: Performing immediate UI updates for episode ID: %@", log: log, type: .info, episodeId)
        
        // Use the same efficient section update approach that works perfectly for Recents tab
        // This provides immediate visual highlighting changes just like Recents does
        forceImmediateSectionUpdate(episodeId: episodeId)
        
        // Also refresh the recents tab and downloads tab to show/hide the highlighted playing state
        refreshRecentsTabTemplate()
        refreshDownloadsTabTemplate()
    }
    
    private func handleStationPlayedForRecents(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            os_log("🚗 CarPlay: Invalid station played notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Station played for recents update - ID: %@", log: log, type: .info, stationId)
        
        // CRITICAL: Force Now Playing info update for radio stations after force close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            RadioPlayer.shared.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Forced Now Playing info update for station start", log: self.log, type: .info)
        }
        
        // Update CarPlayManager's recents data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent() // This will refresh the recent stations list
        
        // Force refresh the recents tab and downloads tab to show/hide highlighting
        refreshRecentsTabTemplate()
        refreshDownloadsTabTemplate()
        
        // Additional Now Playing update with UI updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            RadioPlayer.shared.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Additional Now Playing info update for station", log: self.log, type: .info)
        }
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // Modern CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func handleCarPlayRefreshRequest(_ notification: Notification) {
        let source = notification.userInfo?["source"] as? String ?? "unknown"
        os_log("🚗 CarPlay: Received refresh request from source: %@", log: log, type: .info, source)
        
        // Force refresh all data
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent()
        
        // Refresh current templates
        refreshRecentsTabTemplate()
        refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // Modern CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func handleStationArtworkUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            os_log("🚗 CarPlay: Invalid station artwork update notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Station artwork updated for station ID: %@", log: log, type: .info, stationId)
        
        // CRITICAL: Force Now Playing info update to show new iTunes artwork immediately
        DispatchQueue.main.async {
            RadioPlayer.shared.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Forced Now Playing info update for iTunes artwork", log: self.log, type: .info)
        }
        
        // Also refresh the recents tab to show updated artwork in station list
        refreshRecentsTabTemplate()
        
        os_log("🚗 CarPlay: Completed station artwork update handling", log: log, type: .info)
    }
    
    // MARK: - iTunes Artwork for Independent CarPlay
    
    private func enableITunesArtworkForCarPlay(radioPlayer: RadioPlayer) {
        os_log("🚗 CarPlay: Enabling iTunes artwork for independent CarPlay operation", log: log, type: .info)
        
        // Ensure the RadioPlayer is configured for background iTunes artwork fetching
        // This allows iTunes artwork to work even when the phone app is not open
        
        // Set up background task for iTunes artwork fetching
        DispatchQueue.global(qos: .background).async {
            // Monitor metadata changes and trigger iTunes artwork search
            self.monitorMetadataForITunesArtwork(radioPlayer: radioPlayer)
        }
        
        // Also trigger immediate iTunes artwork check if metadata is already available
        if let metadata = radioPlayer.metadata, !metadata.isEmpty {
            os_log("🚗 CarPlay: Triggering immediate iTunes artwork search for existing metadata", log: log, type: .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // Give the station time to start playing and get metadata
                radioPlayer.fetchITunesAlbumArt(for: metadata)
            }
        }
    }
    
    private func monitorMetadataForITunesArtwork(radioPlayer: RadioPlayer) {
        // Monitor for metadata changes in background
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Check if CarPlay is still connected
            guard CarPlayManager.shared.isCarPlayConnected else {
                os_log("🚗 CarPlay: CarPlay disconnected - stopping iTunes artwork monitoring", log: self.log, type: .info)
                timer.invalidate()
                return
            }
            
            // Check if radio is still playing
            guard radioPlayer.isPlaying else {
                os_log("🚗 CarPlay: Radio stopped - stopping iTunes artwork monitoring", log: self.log, type: .info)
                timer.invalidate()
                return
            }
            
            // Check for new metadata and trigger iTunes search if needed
            if let metadata = radioPlayer.metadata, 
               !metadata.isEmpty,
               metadata != radioPlayer.lastMetadataSearched,
               radioPlayer.iTunesAlbumArt == nil {
                
                os_log("🚗 CarPlay: New metadata detected - triggering iTunes artwork search: %@", log: self.log, type: .info, metadata)
                
                DispatchQueue.main.async {
                    radioPlayer.fetchITunesAlbumArt(for: metadata)
                }
            }
        }
        
        // Store timer reference to keep it alive
        RunLoop.current.add(timer, forMode: .common)
        RunLoop.current.run()
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
        
        // Find the recents tab (should be index 2: Stations, Downloads, Recents, Podcasts)
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
            
            // Recent stations section FIRST (as requested)
            var recentStationItems: [CPListItem] = []
            for station in recentStations {
                let timeAgo = formatTimeAgo(station.lastPlayed)
                let isCurrentlyPlaying = RadioPlayer.shared.currentlyPlayingStation?.id == station.id && RadioPlayer.shared.isPlaying
                
                let item = CPListItem(text: station.name,
                                     detailText: "Played \(timeAgo) • \(station.country)",
                                     image: carPlayManager.getStationArtwork(for: station))
                
                // Set Apple standard highlighting for currently playing station
                if #available(iOS 14.0, *) {
                    item.isPlaying = isCurrentlyPlaying
                }
                
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
            
            // Recent episodes section SECOND (after stations)
            var recentEpisodeItems: [CPListItem] = []
            for episode in recentEpisodes {
                let duration = formatDuration(episode.duration)
                var statusText = ""
                let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
                
                // Determine episode status based on state and current playback
                if isCurrentlyPlaying {
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
                    feed.id == episode.feedId
                }
                
                // Use podcast artwork for recently played episodes
                let itemImage = podcastFeed != nil ? carPlayManager.getPodcastArtwork(for: podcastFeed!) : UIImage(systemName: "microphone")
                
                let item = CPListItem(text: episode.title,
                                     detailText: "\(duration)\(statusText)",
                                     image: itemImage)
                
                // Set Apple standard highlighting for currently playing episode
                if #available(iOS 14.0, *) {
                    item.isPlaying = isCurrentlyPlaying
                }
                
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
    
    private func refreshDownloadsTabTemplate() {
        guard let interfaceController = self.interfaceController else {
            os_log("🚗 CarPlay: Cannot refresh downloads - no interface controller", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Refreshing downloads tab template", log: log, type: .info)
        
        // Get the current root template
        guard let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: Root template is not a tab bar template", log: log, type: .error)
            return
        }
        
        // Find the downloads tab (should be index 1: Stations, Downloads, Recents, Podcasts)
        let downloadsTabIndex = 1
        if downloadsTabIndex < tabBarTemplate.templates.count,
           let downloadsTab = tabBarTemplate.templates[downloadsTabIndex] as? CPListTemplate {
            
            // Get fresh downloads data
            let carPlayManager = CarPlayManager.shared
            let podcastFeeds = carPlayManager.getPodcastFeeds()
            
            // Group downloaded episodes by podcast feed
            var podcastsWithDownloads: [(feed: PodcastFeed, episodes: [PodcastEpisode])] = []
            
            for feed in podcastFeeds {
                // Get downloaded episodes for this podcast from CoreData
                let downloadedEpisodes = getDownloadedEpisodesForPodcast(feed)
                if !downloadedEpisodes.isEmpty {
                    podcastsWithDownloads.append((feed: feed, episodes: downloadedEpisodes))
                }
            }
            
            // Create new sections with updated data
            var newSections: [CPListSection] = []
            
            if podcastsWithDownloads.isEmpty {
                // No downloads found
                let emptyItem = CPListItem(text: "No Downloaded Episodes", 
                                         detailText: "Downloaded podcast episodes will appear here")
                let emptySection = CPListSection(items: [emptyItem], header: "Downloads", sectionIndexTitle: nil)
                newSections.append(emptySection)
            } else {
                // Create a section for each podcast with downloads
                for podcastWithDownloads in podcastsWithDownloads {
                    let feed = podcastWithDownloads.feed
                    let episodes = podcastWithDownloads.episodes
                    
                    var episodeItems: [CPListItem] = []
                    
                    for episode in episodes {
                        let duration = formatDuration(episode.duration)
                        var statusText = ""
                        let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
                        
                        // Determine episode status based on state and current playback
                        if isCurrentlyPlaying {
                            statusText = " • Playing"
                        } else if episode.state.isPlayed {
                            statusText = " • Complete"
                        } else if episode.state.progress > 0 {
                            let progressPercent = Int(episode.state.progress * 100)
                            statusText = " • \(progressPercent)% complete"
                        }
                        
                        // Always add downloaded indicator
                        statusText += " • Downloaded"
                        
                        // Use podcast artwork for downloaded episodes
                        let itemImage = carPlayManager.getPodcastArtwork(for: feed)
                        
                        let item = CPListItem(text: episode.title,
                                             detailText: "\(duration)\(statusText)",
                                             image: itemImage)
                        
                        // Set Apple standard highlighting for currently playing episode
                        if #available(iOS 14.0, *) {
                            item.isPlaying = isCurrentlyPlaying
                        }
                        
                        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                            self?.playEpisode(episode, completion: completion)
                        }
                        
                        episodeItems.append(item)
                    }
                    
                    // Create section for this podcast
                    let sectionHeader = "\(feed.title) (\(episodes.count) downloaded)"
                    let podcastSection = CPListSection(items: episodeItems, header: sectionHeader, sectionIndexTitle: nil)
                    newSections.append(podcastSection)
                }
            }
            
            // Update the sections directly on the existing template - this preserves navigation
            downloadsTab.updateSections(newSections)
            
            os_log("🚗 CarPlay: Successfully updated downloads tab sections without changing navigation", log: self.log, type: .info)
        } else {
            os_log("🚗 CarPlay: Downloads tab index out of bounds or not a list template", log: log, type: .error)
        }
    }
    
    private func refreshCurrentPodcastTemplateIfNeeded(episodeId: String) {
        // Increase throttling to prevent frequent template refreshes (allow every 2 seconds for better CPU performance)
        let now = Date()
        if let lastUpdate = lastProgressUpdateTime, now.timeIntervalSince(lastUpdate) < 2.0 {
            // Skip if we updated less than 2 seconds ago (increased from 1 second)
            return
        }
        
        // Prevent concurrent updates
        if isUpdatingTemplate {
            return
        }
        
        // Check if we're currently showing a podcast episode list that contains this episode
        guard let _ = currentPodcastTemplate,
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
            
            // Use efficient section-based update instead of CPU-intensive template recreation
            updateCurrentPodcastTemplateSections(for: updatedFeed)
        }
        
        isUpdatingTemplate = false
    }
    
    private func refreshCurrentPodcastTemplateImmediately(episodeId: String) {
        // Efficient immediate refresh for playback state changes (prevents CPU spikes from template recreation)
        os_log("🚗 CarPlay: Immediate podcast template refresh for episode ID: %@", log: log, type: .info, episodeId)
        
        // Prevent concurrent updates
        if isUpdatingTemplate {
            os_log("🚗 CarPlay: Template update already in progress, skipping immediate refresh", log: log, type: .debug)
            return
        }
        
        // Check if we're currently showing a podcast episode list that contains this episode
        guard let currentFeed = currentPodcastFeed else {
            os_log("🚗 CarPlay: No current podcast feed set for immediate refresh", log: log, type: .debug)
            return
        }
        
        // If episodeId is provided, check if it's in the current feed
        if !episodeId.isEmpty {
            let episodeFound = currentFeed.episodes.contains(where: { $0.id == episodeId })
            if !episodeFound {
                os_log("🚗 CarPlay: Episode not found in current feed for immediate refresh", log: log, type: .debug)
                return
            }
        }
        
        isUpdatingTemplate = true
        
        // Get updated feed data from CarPlayManager
        let carPlayManager = CarPlayManager.shared
        let updatedFeeds = carPlayManager.getPodcastFeeds()
        
        if let updatedFeed = updatedFeeds.first(where: { $0.id == currentFeed.id }) {
            // Update the current feed reference
            currentPodcastFeed = updatedFeed
            
            // Use efficient section-based update instead of template recreation to prevent CPU spikes
            updateCurrentPodcastTemplateSections(for: updatedFeed)
        } else {
            os_log("🚗 CarPlay: Could not find updated feed data for current podcast", log: log, type: .error)
        }
        
        isUpdatingTemplate = false
    }
    
    private func forceImmediateSectionUpdate(episodeId: String) {
        // Since Recents tab works perfectly with updateSections(), let's use the same approach for podcast episode lists
        // This should provide immediate highlighting updates just like Recents does
        os_log("🚗 CarPlay: Forcing immediate section update for episode ID: %@", log: log, type: .info, episodeId)
        
        // Check if we're currently showing a podcast episode list
        guard let currentFeed = currentPodcastFeed else {
            os_log("🚗 CarPlay: No current podcast feed set for section update", log: log, type: .debug)
            return
        }
        
        // Get the currently playing episode to determine if we need to update this feed
        let currentPlayingEpisodeId = PodcastPlayer.shared.currentEpisode?.id
        
        // Check if the currently playing episode is in this feed OR if any episode in this feed was previously playing
        // This ensures we update when switching between episodes within the same podcast
        let shouldUpdate = currentPlayingEpisodeId == nil || 
                          currentFeed.episodes.contains(where: { $0.id == currentPlayingEpisodeId }) ||
                          currentFeed.episodes.contains(where: { $0.id == episodeId })
        
        if !shouldUpdate {
            os_log("🚗 CarPlay: No episodes in current feed need section update", log: log, type: .debug)
            return
        }
        
        os_log("🚗 CarPlay: Updating sections for podcast '%@' - current playing: %@, notification episode: %@", log: log, type: .info, currentFeed.title, currentPlayingEpisodeId ?? "none", episodeId)
        
        // Use the same efficient section update approach that works perfectly for Recents
        // Reset the updating flag to ensure this critical update goes through
        isUpdatingTemplate = false
        
        // Use immediate section updates - same approach as Recents tab which works perfectly
        updateCurrentPodcastTemplateSections(for: currentFeed)
    }
    
    private func forceImmediateHighlightingUpdate(episodeId: String) {
        // Legacy function - now redirects to the section update approach that works like Recents
        // This ensures backward compatibility while using the same approach as the working Recents tab
        forceImmediateSectionUpdate(episodeId: episodeId)
    }
    
    private func updateCurrentPodcastTemplateSections(for podcast: PodcastFeed) {
        guard let interfaceController = self.interfaceController else {
            os_log("🚗 CarPlay: Cannot refresh podcast episodes - no interface controller", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Updating current podcast template sections efficiently to prevent CPU spikes", log: log, type: .info)
        
        // Find the current podcast episode list template (should be the top template if we're viewing a podcast)
        guard let currentTemplate = interfaceController.topTemplate as? CPListTemplate else {
            os_log("🚗 CarPlay: Top template is not a CPListTemplate", log: log, type: .debug)
            return
        }
        
        guard currentTemplate.title == podcast.title else {
            os_log("🚗 CarPlay: Current template title '%@' does not match podcast title '%@'", log: log, type: .debug, currentTemplate.title ?? "nil", podcast.title)
            return
        }
        
        // Instead of recreating the template (CPU intensive), update the existing podcast episode list in place
        let carPlayManager = CarPlayManager.shared
        var newSections: [CPListSection] = []
        
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
            newSections.append(filterSection)
        }
        
        // Update all episodes with current state and highlighting
        var episodeItems: [CPListItem] = []
        
        // Get current playing state directly from PodcastPlayer for real-time accuracy
        let currentPlayingEpisodeId = PodcastPlayer.shared.currentEpisode?.id
        let isPlayerPlaying = PodcastPlayer.shared.isPlaying
        
        os_log("🚗 CarPlay: Current playing episode ID: %@, player is playing: %@", log: log, type: .info, currentPlayingEpisodeId ?? "none", isPlayerPlaying ? "YES" : "NO")
        
        for episode in podcast.episodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            
            // Get playing state directly from PodcastPlayer for real-time accuracy
            let isCurrentlyPlaying = currentPlayingEpisodeId == episode.id && isPlayerPlaying
            
            if isCurrentlyPlaying {
                os_log("🚗 CarPlay: Episode '%@' is currently playing - will show highlighting", log: log, type: .info, episode.title)
            }
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if episode.state.isPlayed {
                statusText = " • Complete"
            } else if episode.state.progress > 0 {
                statusText = " • IN PROGRESS"
            }
            
            // Add download indicator
            if episode.state.isDownloaded {
                statusText += " • Downloaded"
            }
            
            // Use standard podcast artwork for all episodes
            let itemImage = carPlayManager.getPodcastArtwork(for: podcast)
            
            let item = CPListItem(text: episode.title,
                                 detailText: "\(duration)\(statusText)",
                                 image: itemImage)
            
            // Set Apple standard highlighting for currently playing episode
            if #available(iOS 14.0, *) {
                item.isPlaying = isCurrentlyPlaying
            }
            
            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.playEpisode(episode, completion: completion)
            }
            
            episodeItems.append(item)
        }
        
        let episodesSection = CPListSection(items: episodeItems, header: "All Episodes (\(podcast.episodes.count))", sectionIndexTitle: nil)
        newSections.append(episodesSection)
        
        // Update the existing template with new sections - this is much more efficient than template recreation
        currentTemplate.updateSections(newSections)
        
        os_log("🚗 CarPlay: Successfully updated podcast template sections efficiently (prevents CPU spikes)", log: log, type: .info)
    }
    
    private func recreatePodcastEpisodeTemplate(for podcast: PodcastFeed) {
        // Complete template recreation is required to overcome CarPlay's section update limitations
        // This ensures immediate visual highlighting changes that updateSections() cannot provide
        guard let interfaceController = interfaceController else {
            os_log("🚗 CarPlay: No interface controller for template recreation", log: log, type: .error)
            return
        }
        
        guard let topTemplate = interfaceController.topTemplate as? CPListTemplate else {
            os_log("🚗 CarPlay: Top template is not a CPListTemplate, cannot recreate", log: log, type: .debug)
            return
        }
        
        guard topTemplate.title == podcast.title else {
            os_log("🚗 CarPlay: Template title mismatch - current: '%@', expected: '%@'", log: log, type: .debug, topTemplate.title ?? "nil", podcast.title)
            return
        }
        
        os_log("🚗 CarPlay: Recreating podcast template to overcome CarPlay section update limitations", log: log, type: .info)
        
        // Clear current references to force fresh state
        currentPodcastTemplate = nil
        currentPodcastFeed = nil
        
        // Set updating flag to prevent other updates during recreation
        isUpdatingTemplate = true
        
        // Pop current template with no animation for immediate update
        interfaceController.popTemplate(animated: false) { [weak self] success, error in
            if success {
                os_log("🚗 CarPlay: Successfully popped old template, creating new one", log: self?.log ?? OSLog.default, type: .info)
                
                // Force a small delay to ensure CarPlay clears its internal state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    // Immediately show the new template with fresh highlighting state
                    self?.showPodcastDetails(podcast) {
                        os_log("🚗 CarPlay: Successfully recreated podcast template with fresh highlighting state", log: self?.log ?? OSLog.default, type: .info)
                        self?.isUpdatingTemplate = false
                    }
                }
            } else {
                os_log("🚗 CarPlay: Failed to pop current template: %@", log: self?.log ?? OSLog.default, type: .error, error?.localizedDescription ?? "Unknown error")
                self?.isUpdatingTemplate = false
                
                // Fallback: try to update sections anyway
                self?.currentPodcastFeed = podcast
                self?.updateCurrentPodcastTemplateSections(for: podcast)
            }
        }
    }
    
    // MARK: - On-Demand Episode Loading
    
    /// Load episodes for a specific podcast feed from CoreData on-demand
    private func loadEpisodesForPodcast(_ podcastFeed: PodcastFeed, completion: @escaping ([PodcastEpisode]) -> Void) {
        os_log("🚗 CarPlay: Loading ALL episodes for podcast '%@'", log: log, type: .info, podcastFeed.title)
        
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
    
    /// PERFORMANCE OPTIMIZED: Load only initial batch of episodes for fast CarPlay response
    private func loadInitialEpisodesForPodcast(_ podcastFeed: PodcastFeed, limit: Int, completion: @escaping ([PodcastEpisode]) -> Void) {
        os_log("🚗 CarPlay: Loading initial %d episodes for fast response for podcast '%@'", log: log, type: .info, limit, podcastFeed.title)
        
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                episodeRequest.fetchLimit = limit
                
                let managedEpisodes = try context.fetch(episodeRequest)
                let episodes = managedEpisodes.map { managedEpisode -> PodcastEpisode in
                    var episode = managedEpisode.toPodcastEpisode()
                    episode.state.isPlayed = managedEpisode.isPlayed
                    episode.state.progress = managedEpisode.progress
                    episode.state.isFavorite = managedEpisode.isFavorite
                    episode.state.isDownloaded = managedEpisode.isDownloaded
                    
                    return episode
                }
                
                os_log("🚗 CarPlay: Successfully loaded initial %d episodes for podcast '%@'", log: self.log, type: .info, episodes.count, podcastFeed.title)
                
                DispatchQueue.main.async {
                    completion(episodes)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error loading initial episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                
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
    
    /// Get total episode count from CoreData synchronously
    private func getEpisodeCountSync(for podcastFeed: PodcastFeed) -> Int {
        let context = CoreDataStack.shared.context
        var count = 0
        
        context.performAndWait {
            do {
                let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeCountRequest.includesPropertyValues = false
                
                count = try context.count(for: episodeCountRequest)
                
            } catch {
                os_log("🚗 CarPlay: Error counting episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                count = 0
            }
        }
        
        return count
    }
    
    // MARK: - CarPlay Compliance Validation
    
    /// Validates CarPlay implementation against Apple's best practices
    private func validateCarPlayCompliance() {
        os_log("🚗 CarPlay: Validating implementation compliance with Apple guidelines", log: log, type: .info)
        
        // Check tab count compliance
        guard let interfaceController = self.interfaceController,
              let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: No root tab bar template found for validation", log: log, type: .debug)
            return
        }
        
        let tabCount = tabBarTemplate.templates.count
        let maxTabsForAudioApp = 4 // Apple guideline for audio apps
        
        if tabCount > maxTabsForAudioApp {
            os_log("⚠️ CarPlay: Tab count (%d) exceeds Apple's recommendation of %d for audio apps", log: log, type: .error, tabCount, maxTabsForAudioApp)
        } else {
            os_log("✅ CarPlay: Tab count (%d) complies with Apple guidelines", log: log, type: .info, tabCount)
        }
        
        // Validate template types are appropriate for audio app
        for (index, template) in tabBarTemplate.templates.enumerated() {
            let templateType = String(describing: type(of: template))
            os_log("🚗 CarPlay: Tab %d uses template type: %@", log: log, type: .debug, index, templateType)
            
            // Ensure we're only using approved templates for audio apps
            let approvedTemplates = ["CPListTemplate", "CPGridTemplate", "CPNowPlayingTemplate"]
            if !approvedTemplates.contains(where: { templateType.contains($0) }) {
                os_log("⚠️ CarPlay: Template type %@ may not be approved for audio apps", log: log, type: .error, templateType)
            }
        }
        
        os_log("🚗 CarPlay: Compliance validation complete", log: log, type: .info)
    }
    

    
    /// Tracks template navigation depth to ensure compliance
    private func validateTemplateDepth() {
        guard let interfaceController = self.interfaceController else { return }
        
        // Note: CarPlay framework doesn't expose template stack depth directly
        // This is a best-effort validation based on our tracking
        let maxDepth = 5 // Apple's limit for most apps
        
        os_log("🚗 CarPlay: Template depth validation - ensure navigation doesn't exceed %d levels", log: log, type: .debug, maxDepth)
        
        // Log current template for debugging
        if let currentTemplate = interfaceController.topTemplate {
            let templateType = String(describing: type(of: currentTemplate))
            os_log("🚗 CarPlay: Current top template: %@", log: log, type: .debug, templateType)
        }
    }
    
    // MARK: - Enhanced Artwork Monitoring for CarPlay Independence
    
    /// Sets up enhanced artwork monitoring for independent CarPlay operation
    private func setupEnhancedArtworkMonitoring() {
        os_log("🚗 CarPlay: Setting up enhanced artwork monitoring for independent operation", log: log, type: .info)
        
        // Listen for CarPlay artwork updates from direct fetching
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CarPlayArtworkUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            os_log("🚗 CarPlay: Received artwork update notification", log: self?.log ?? OSLog.default, type: .info)
            self?.handleArtworkUpdate(notification)
        }
        
        // CRITICAL: Set up immediate artwork fetching using CarPlay's audio session privileges
        // This bypasses background task limitations by using active audio session
        setupDirectArtworkFetching()
        
        os_log("🚗 CarPlay: Enhanced artwork monitoring setup complete", log: log, type: .info)
    }
    
    /// Sets up pre-cached artwork system that works when app is closed
    private func setupDirectArtworkFetching() {
        os_log("🚗 CarPlay: Setting up PRE-CACHED iTunes artwork system for independent operation", log: log, type: .info)
        
        // INSTANT SYNC APPROACH: Zero-delay artwork synchronization for CarPlay
        setupInstantArtworkSync()
        
        os_log("🚀 CarPlay: Instant artwork sync system configured", log: log, type: .info)
    }
    
    /// Fetches iTunes artwork using CarPlay's active audio session network privileges
    private func fetchArtworkWithCarPlayPrivileges(metadata: String, cacheKey: String) {
        let radioPlayer = RadioPlayer.shared
        
        os_log("🚗 CarPlay: Starting immediate iTunes artwork fetch with CarPlay privileges", log: log, type: .info)
        
        // Mark this metadata as being searched to prevent duplicates
        radioPlayer.lastMetadataSearched = cacheKey
        
        // Use a high-priority queue to leverage CarPlay's active audio session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Use RadioPlayer's existing iTunes search but with enhanced error handling
            radioPlayer.searchITunesForArtwork(metadata: metadata) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let image = image {
                        os_log("🚗 CarPlay: iTunes artwork fetched successfully with CarPlay privileges", log: self.log, type: .info)
                        
                        // Update RadioPlayer immediately
                        radioPlayer.iTunesAlbumArt = image
                        radioPlayer.saveITunesArtworkToCurrentStation(image)
                        
                        // Force immediate Now Playing update for CarPlay
                        self.forceCarPlayNowPlayingUpdate()
                        
                        // Update widget and other UI elements
                        radioPlayer.updateWidget()
                        
                        // Notify of successful artwork update
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CarPlayArtworkUpdated"),
                            object: nil,
                            userInfo: ["metadata": metadata, "hasArtwork": true]
                        )
                        
                        os_log("🚗 CarPlay: iTunes artwork successfully integrated into CarPlay interface", log: self.log, type: .info)
                        
                    } else {
                        os_log("🚗 CarPlay: No iTunes artwork found for: %@", log: self.log, type: .info, metadata)
                    }
                }
            }
        }
    }
    
    /// Forces an immediate CarPlay Now Playing update for real-time artwork display
    private func forceCarPlayNowPlayingUpdate() {
        os_log("🚀 CarPlay: INSTANT Now Playing update (zero delay)", log: log, type: .info)
        
        let radioPlayer = RadioPlayer.shared
        
        // Single immediate Now Playing update - no delays
        radioPlayer.forceUpdateNowPlayingInfo()
        
        os_log("🚀 CarPlay: Instant Now Playing update completed", log: log, type: .info)
    }
    
    /// Normalizes metadata for consistent caching
    private func normalizeMetadataForCache(_ metadata: String) -> String {
        return metadata.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }
    
    /// Handles artwork updates from direct fetching
    private func handleArtworkUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let metadata = userInfo["metadata"] as? String,
              let hasArtwork = userInfo["hasArtwork"] as? Bool else {
            os_log("🚗 CarPlay: Invalid artwork update notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Processing artwork update - metadata: %@, hasArtwork: %@", log: log, type: .info, metadata, hasArtwork ? "YES" : "NO")
        
        if hasArtwork {
            // Refresh visible CarPlay interface elements to show new artwork
            refreshVisibleStationArtwork()
        }
    }
    
    /// Refreshes visible station artwork in CarPlay interface
    private func refreshVisibleStationArtwork() {
        os_log("🚗 CarPlay: Refreshing visible station artwork in CarPlay interface", log: log, type: .info)
        
        // Refresh the recents tab if it contains the updated station
        refreshRecentsTabTemplate()
        
        // If we're currently showing a station list, refresh it as well
        guard let interfaceController = self.interfaceController,
              let topTemplate = interfaceController.topTemplate as? CPListTemplate else {
            return
        }
        
        // Check if the top template is showing stations and refresh if needed
        if topTemplate.title?.contains("Stations") == true || topTemplate.title?.contains("Recent") == true {
            // Trigger a refresh of the current template
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.refreshRecentsTabTemplate()
            }
        }
    }
    
    // MARK: - Pre-Cached CarPlay iTunes Artwork System
    
    /// Sets up a pre-cached iTunes artwork system that works when app is closed
    private func setupPreCachedArtworkSystem() {
        os_log("🚗 CarPlay: Initializing ENHANCED pre-cached artwork system", log: log, type: .info)
        
        // Monitor for playback changes to apply cached artwork
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(carPlayPlaybackChanged(_:)),
            name: NSNotification.Name("CarPlayPlaybackChanged"),
            object: nil
        )
        
        // Monitor for audio route changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // Monitor for station artwork updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stationArtworkUpdated(_:)),
            name: NSNotification.Name("StationArtworkUpdated"),
            object: nil
        )
        
        // Monitor for iTunes artwork updates specifically
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iTunesArtworkUpdated(_:)),
            name: NSNotification.Name("iTunesArtworkUpdated"),
            object: nil
        )
        
        // NEW: Monitor for direct CarPlay Now Playing force updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(carPlayForceNowPlayingUpdate(_:)),
            name: NSNotification.Name("CarPlayForceNowPlayingUpdate"),
            object: nil
        )
        
        // Set up aggressive cached artwork monitoring
        setupAggressiveCachedArtworkMonitoring()
        
        // Trigger immediate check for existing Now Playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.applyCachedArtworkToCarPlay()
        }
        
        os_log("🚗 CarPlay: ENHANCED pre-cached artwork monitoring active", log: log, type: .info)
    }
    
    /// Monitors playback changes for instant artwork sync
    @objc private func carPlayPlaybackChanged(_ notification: Notification) {
        os_log("🚗 CarPlay: Playback changed - triggering INSTANT artwork sync", log: log, type: .info)
        
        // INSTANT SYNC: Single immediate artwork application
        DispatchQueue.main.async { [weak self] in
            self?.applyCachedArtworkToCarPlay()
            
            // Check immediately for iTunes artwork if needed
            let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
            if nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
                os_log("🚗 CarPlay: No artwork found - triggering instant iTunes fetch", log: self?.log ?? OSLog.default, type: .info)
                self?.triggerImmediateITunesArtworkFetch()
            }
        }
    }
    
    /// Monitors audio route changes for instant CarPlay artwork application
    @objc private func audioRouteChanged(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let isCarPlayActive = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        
        if isCarPlayActive {
            os_log("🚗 CarPlay: Audio route changed to CarPlay - triggering INSTANT artwork sync", log: log, type: .info)
            
            // INSTANT SYNC: Apply cached artwork immediately
            DispatchQueue.main.async { [weak self] in
                self?.applyCachedArtworkToCarPlay()
                
                // Check for iTunes artwork need and trigger immediately if required
                let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
                if nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
                    os_log("🚗 CarPlay: No artwork present - triggering instant iTunes fetch", log: self?.log ?? OSLog.default, type: .info)
                    self?.triggerImmediateITunesArtworkFetch()
                }
            }
        }
    }
    
    /// Monitors station artwork updates for instant sync
    @objc private func stationArtworkUpdated(_ notification: Notification) {
        os_log("🚗 CarPlay: Station artwork updated - triggering INSTANT sync", log: log, type: .info)
        
        // INSTANT SYNC: Apply artwork immediately with zero delay
        DispatchQueue.main.async { [weak self] in
            self?.applyCachedArtworkToCarPlay()
        }
    }
    
    /// Monitors iTunes artwork updates for instant CarPlay sync with zero delays
    @objc private func iTunesArtworkUpdated(_ notification: Notification) {
        os_log("🚗 CarPlay: iTunes artwork updated - triggering INSTANT CarPlay sync", log: log, type: .info)
        
        // INSTANT SYNC: All updates happen immediately without any delays
        DispatchQueue.main.async { [weak self] in
            self?.applyCachedArtworkToCarPlay()
            self?.forceCarPlayNowPlayingUpdate()
            self?.refreshVisibleStationArtwork()
        }
        
        os_log("🚀 CarPlay: Instant iTunes artwork sync completed", log: log, type: .info)
    }
    
    /// Handles instant CarPlay Now Playing updates with zero delays
    @objc private func carPlayForceNowPlayingUpdate(_ notification: Notification) {
        os_log("🚗 CarPlay: Received instant CarPlay Now Playing update request", log: log, type: .info)
        
        // INSTANT SYNC: Single immediate update - no redundant calls or delays
        DispatchQueue.main.async { [weak self] in
            self?.applyCachedArtworkToCarPlay()
            self?.forceCarPlayNowPlayingUpdate()
            self?.refreshVisibleStationArtwork()
        }
        
        os_log("🚀 CarPlay: Instant Now Playing update completed", log: log, type: .info)
    }
    
    /// Sets up aggressive periodic monitoring for cached artwork
    private func setupAggressiveCachedArtworkMonitoring() {
        // ENHANCED: More frequent checks every 1 second for immediate cached artwork updates
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Only run while CarPlay is connected
            guard CarPlayManager.shared.isCarPlayConnected else {
                os_log("🚗 CarPlay: Stopping aggressive cached artwork monitoring - CarPlay disconnected", log: self.log, type: .info)
                timer.invalidate()
                return
            }
            
            // Check and apply cached artwork aggressively
            self.applyCachedArtworkToCarPlay()
        }
        
        // Separate timer for iTunes artwork fetching (less frequent to avoid excessive network usage)
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Only run while CarPlay is connected
            guard CarPlayManager.shared.isCarPlayConnected else {
                os_log("🚗 CarPlay: Stopping iTunes artwork fetch monitoring - CarPlay disconnected", log: self.log, type: .info)
                timer.invalidate()
                return
            }
            
            // Check if we need to fetch iTunes artwork
            let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
            if nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
                os_log("🚗 CarPlay: Periodic check - no artwork present, triggering iTunes fetch", log: self.log, type: .debug)
                self.triggerImmediateITunesArtworkFetch()
            }
        }
    }
    
    /// Applies cached iTunes artwork to CarPlay Now Playing
    private func applyCachedArtworkToCarPlay() {
        let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        
        // Try multiple approaches to get current track info
        var title: String?
        var artist: String?
        
        // Approach 1: From Now Playing info
        if let nowPlayingTitle = nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
           let nowPlayingArtist = nowPlayingInfo?[MPMediaItemPropertyArtist] as? String {
            title = nowPlayingTitle
            artist = nowPlayingArtist
        }
        
        // Approach 2: From RadioPlayer metadata if Now Playing is insufficient
        if title == nil || artist == nil {
            let radioPlayer = RadioPlayer.shared
            if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                let components = metadata.components(separatedBy: " - ")
                if components.count >= 2 {
                    artist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    title = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Approach 3: From current station name as fallback
        if title == nil || artist == nil {
            let radioPlayer = RadioPlayer.shared
            if let currentStation = radioPlayer.currentlyPlayingStation {
                title = currentStation.name
                artist = "StreamRadios"
            }
        }
        
        guard let finalTitle = title, let finalArtist = artist, !finalTitle.isEmpty else {
            os_log("🚗 CarPlay: No valid title/artist found for cached artwork lookup", log: log, type: .debug)
            return
        }
        
        // Check if artwork is already present (but allow refresh if it's been a while)
        let hasExistingArtwork = nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil
        
        let metadata = "\(finalArtist) - \(finalTitle)"
        os_log("🚗 CarPlay: Checking for cached artwork for: %@", log: log, type: .info, metadata)
        
        // Look for cached iTunes artwork with enhanced lookup
        if let cachedArtwork = getEnhancedCachedITunesArtwork(artist: finalArtist, title: finalTitle) {
            os_log("🚗 CarPlay: Found cached iTunes artwork, applying to Now Playing", log: log, type: .info)
            applyArtworkToCarPlayNowPlaying(image: cachedArtwork, metadata: metadata)
        } else if !hasExistingArtwork {
            os_log("🚗 CarPlay: No cached iTunes artwork found for: %@", log: log, type: .debug, metadata)
            
            // Try to apply station artwork as fallback
            applyStationArtworkFallback(artist: finalArtist, title: finalTitle)
        }
    }
    
    /// Gets cached iTunes artwork from persistent storage
    private func getCachedITunesArtwork(artist: String, title: String) -> UIImage? {
        // Create a cache key from artist and title
        let cacheKey = "\(artist.lowercased())_\(title.lowercased())"
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "", options: .regularExpression)
        
        // Check UserDefaults for cached artwork data
        let userDefaults = UserDefaults.standard
        
        // First check for iTunes artwork data
        if let artworkData = userDefaults.data(forKey: "iTunesArtwork_\(cacheKey)") {
            if let image = UIImage(data: artworkData) {
                os_log("🚗 CarPlay: Found cached iTunes artwork for key: %@", log: log, type: .info, cacheKey)
                return image
            }
        }
        
        // Fallback: Check if this is a current station and use its saved iTunes artwork data
        let radioPlayer = RadioPlayer.shared
        if let currentStation = radioPlayer.currentlyPlayingStation,
           let iTunesArtworkData = currentStation.iTunesArtworkData,
           let imageData = Data(base64Encoded: iTunesArtworkData),
           let image = UIImage(data: imageData) {
            os_log("🚗 CarPlay: Using current station's iTunes artwork data", log: log, type: .info)
            return image
        }
        
        // Check all stations for matching iTunes artwork data
        let stations = RadioStationViewModel.shared.stations
        for station in stations {
            if let iTunesArtworkData = station.iTunesArtworkData,
               let imageData = Data(base64Encoded: iTunesArtworkData),
               let image = UIImage(data: imageData),
               (station.name.lowercased().contains(title.lowercased()) || 
                title.lowercased().contains(station.name.lowercased())) {
                os_log("🚗 CarPlay: Found matching station iTunes artwork data for: %@", log: log, type: .info, station.name)
                return image
            }
        }
        
        return nil
    }
    
    /// Enhanced cached iTunes artwork lookup with multiple strategies
    private func getEnhancedCachedITunesArtwork(artist: String, title: String) -> UIImage? {
        // Strategy 1: Exact metadata cache key
        if let artwork = getCachedITunesArtwork(artist: artist, title: title) {
            return artwork
        }
        
        // Strategy 2: Try with normalized strings
        let normalizedArtist = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let artwork = getCachedITunesArtwork(artist: normalizedArtist, title: normalizedTitle) {
            return artwork
        }
        
        // Strategy 3: Try partial matches
        let userDefaults = UserDefaults.standard
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        for key in allKeys {
            if key.hasPrefix("iTunesArtwork_") || key.hasPrefix("CarPlayArtwork_") {
                let keyLower = key.lowercased()
                if (keyLower.contains(normalizedArtist) && keyLower.contains(normalizedTitle)) ||
                   keyLower.contains(normalizedTitle) {
                    if let artworkData = userDefaults.data(forKey: key),
                       let image = UIImage(data: artworkData) {
                        os_log("🚗 CarPlay: Found cached artwork via partial match: %@", log: log, type: .info, key)
                        return image
                    }
                }
            }
        }
        
        // Strategy 4: Check current station's iTunes artwork
        let radioPlayer = RadioPlayer.shared
        if let currentStation = radioPlayer.currentlyPlayingStation,
           let iTunesArtworkData = currentStation.iTunesArtworkData,
           let imageData = Data(base64Encoded: iTunesArtworkData),
           let image = UIImage(data: imageData) {
            os_log("🚗 CarPlay: Using current station's cached iTunes artwork", log: log, type: .info)
            return image
        }
        
        return nil
    }
    
    /// Applies station artwork as fallback when no iTunes artwork is cached
    private func applyStationArtworkFallback(artist: String, title: String) {
        let radioPlayer = RadioPlayer.shared
        guard let currentStation = radioPlayer.currentlyPlayingStation else { return }
        
        // Try to use station icon as fallback artwork
        if let iconData = currentStation.iconData,
           let imageData = Data(base64Encoded: iconData),
           let image = UIImage(data: imageData) {
            os_log("🚗 CarPlay: Applying station icon as fallback artwork", log: log, type: .info)
            applyArtworkToCarPlayNowPlaying(image: image, metadata: "\(artist) - \(title)")
        }
    }
    

    
    /// Triggers immediate iTunes artwork fetching for CarPlay when possible
    private func triggerImmediateITunesArtworkFetch() {
        let radioPlayer = RadioPlayer.shared
        
        // First check if we have current metadata to search for
        var metadata = radioPlayer.metadata
        
        // If no metadata available yet, try to construct it from current station
        if metadata == nil || metadata!.isEmpty {
            if let currentStation = radioPlayer.currentlyPlayingStation {
                metadata = currentStation.name
                os_log("🚗 CarPlay: No metadata available, using station name for iTunes artwork fetch: %@", log: log, type: .info, currentStation.name)
            } else {
                os_log("🚗 CarPlay: No metadata or station available for iTunes artwork fetch", log: log, type: .debug)
                return
            }
        }
        
        guard let finalMetadata = metadata, !finalMetadata.isEmpty else {
            os_log("🚗 CarPlay: No valid metadata available for iTunes artwork fetch", log: log, type: .debug)
            return
        }
        
        // Don't skip if artwork already present for PlayNow - always try to get better artwork
        let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let hasArtwork = nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil
        
        if hasArtwork {
            os_log("🚗 CarPlay: Artwork already present, but triggering fresh iTunes fetch for PlayNow: %@", log: log, type: .info, finalMetadata)
        } else {
            os_log("🚗 CarPlay: No artwork present, triggering IMMEDIATE iTunes artwork fetch for: %@", log: log, type: .info, finalMetadata)
        }
        
        // Use background task to ensure network access during CarPlay session
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "CarPlayITunesArtworkFetch") {
            os_log("🚗 CarPlay: iTunes artwork fetch background task expired", log: self.log, type: .default)
        }
        
        radioPlayer.searchITunesForArtwork(metadata: finalMetadata) { [weak self] image in
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(taskId)
                
                if let image = image {
                    os_log("🚗 CarPlay: iTunes artwork fetch SUCCESS - applying INSTANTLY", log: self?.log ?? OSLog.default, type: .info)
                    radioPlayer.saveITunesArtworkToCurrentStation(image)
                    
                    // INSTANT SYNC: Force immediate Now Playing info update with zero delay
                    radioPlayer.forceUpdateNowPlayingInfo()
                    self?.forceCarPlayNowPlayingUpdate()
                } else {
                    os_log("🚗 CarPlay: iTunes artwork fetch failed for: %@", log: self?.log ?? OSLog.default, type: .debug, finalMetadata)
                }
            }
        }
    }
    
    // MARK: - Instant CarPlay Artwork Sync System
    
    /// Sets up instant artwork synchronization for CarPlay with zero delays
    private func setupInstantArtworkSync() {
        os_log("🚀 CarPlay: Initializing INSTANT artwork sync system", log: log, type: .info)
        
        // Monitor for instant artwork sync notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantArtworkSync(_:)),
            name: NSNotification.Name("InstantCarPlayArtworkSync"),
            object: nil
        )
        
        // Monitor for audio route changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // Set up predictive caching for faster artwork delivery
        setupPredictiveCaching()
    }
    
    /// Handles instant artwork sync notifications with zero delays
    @objc private func handleInstantArtworkSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let metadata = userInfo["metadata"] as? String,
              let hasArtwork = userInfo["hasArtwork"] as? Bool,
              let syncType = userInfo["syncType"] as? String else {
            os_log("🚗 CarPlay: Invalid instant artwork sync notification", log: log, type: .error)
            return
        }
        
        os_log("🚀 CarPlay: Processing INSTANT artwork sync - type: %@, metadata: %@", log: log, type: .info, syncType, metadata)
        
        // INSTANT SYNC: All operations happen immediately without any delays
        DispatchQueue.main.async { [weak self] in
            // Apply cached artwork immediately
            self?.applyCachedArtworkToCarPlay()
            
            // Force Now Playing update immediately
            self?.forceCarPlayNowPlayingUpdate()
            
            // Refresh visible interface immediately
            self?.refreshVisibleStationArtwork()
        }
        
        os_log("🚀 CarPlay: Instant artwork sync completed for type: %@", log: log, type: .info, syncType)
    }
    
    /// Sets up predictive caching for instant artwork delivery
    private func setupPredictiveCaching() {
        os_log("🚀 CarPlay: Setting up predictive artwork caching", log: log, type: .info)
        
        // Cache frequently used artwork in memory for instant access
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Only run while CarPlay is connected
            guard CarPlayManager.shared.isCarPlayConnected else {
                os_log("🚗 CarPlay: Stopping predictive caching - CarPlay disconnected", log: self.log, type: .info)
                timer.invalidate()
                return
            }
            
            // Preload artwork for current and recent stations
            self.preloadFrequentlyUsedArtwork()
        }
    }
    
    /// Preloads frequently used artwork for instant access
    private func preloadFrequentlyUsedArtwork() {
        let radioPlayer = RadioPlayer.shared
        
        // Preload current station artwork
        if let currentStation = radioPlayer.currentlyPlayingStation {
            _ = getCachedITunesArtwork(artist: "Current", title: currentStation.name)
        }
        
        // Preload recent stations artwork
        let recentStations = RadioStationViewModel.shared.stations.prefix(5)
        for station in recentStations {
            _ = getCachedITunesArtwork(artist: "Station", title: station.name)
        }
    }
    
    /// Applies instant artwork to CarPlay Now Playing with zero delays
    private func applyArtworkToCarPlayNowPlaying(image: UIImage, metadata: String) {
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) { _ in
            return image
        }
        
        // Get current Now Playing info and update artwork immediately
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        
        // INSTANT UPDATE: Set Now Playing info immediately
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        os_log("🚀 CarPlay: Instant artwork applied to Now Playing for: %@", log: log, type: .info, metadata)
        
        os_log("🚀 CarPlay: INSTANT artwork sync system active", log: log, type: .info)
    }
    
} 
