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
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    
    private let log = OSLog(subsystem: "com.streamradios.carplay", category: "SceneDelegate")
    var interfaceController: CPInterfaceController?
    
    // Track currently displayed templates for real-time updates
    private var currentPodcastTemplate: CPListTemplate?
    private var currentPodcastFeed: PodcastFeed?
    private var lastProgressUpdateTime: Date?
    private var isUpdatingTemplate = false
    
    // UserDefaults sync monitoring timer
    private var syncMonitoringTimer: Timer?
    
    /// Station the user last tapped in CarPlay, used to drive the now-playing indicator until
    /// RadioPlayer finishes starting the stream and reports it as the current station.
    private var pendingHighlightStationId: String?
    /// Same idea as `pendingHighlightStationId`, for podcast episodes.
    private var pendingHighlightEpisodeId: String?
    
    private var subscriptionObserver: AnyCancellable?
    
    // MARK: - Scene Delegate Methods
    
    /// Initialize CarPlay data independently from the main app
    /// This ensures CarPlay works even when the main app isn't running
    private func initializeCarPlayData() async {
        os_log("🚗 CarPlay: Initializing data independently", log: log, type: .info)
        print("🚗 CarPlay: Starting independent data initialization...")
        
        do {
            // CRITICAL: Initialize EpisodeStateManager to ensure proper app group UserDefaults access
            // This ensures episode states are available even when main app is closed
            await initializeEpisodeStateManager()
            
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
    
    /// Initialize EpisodeStateManager to ensure it's properly set up for CarPlay
    private func initializeEpisodeStateManager() async {
        await MainActor.run {
            // Access the singleton to trigger initialization
            // This ensures the app group UserDefaults are properly initialized
            let _ = EpisodeStateManager.shared
            os_log("🚗 CarPlay: EpisodeStateManager initialized for independent operation", log: log, type: .info)
            print("🚗 CarPlay: EpisodeStateManager ready for episode state access")
        }
    }
    
    /// Load podcast data directly from Core Data for CarPlay
  
    private func loadPodcastDataFromCoreData() async {
        os_log("🚗 CarPlay: Loading podcast data from Core Data (independent mode)", log: log, type: .info)
        print("🚗 CarPlay: Loading podcast feeds independently from Core Data...")
        
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
            // Get the feed order from PodcastViewModel to maintain consistency
            let feedOrder = PodcastViewModel.shared.podcastFeedOrder
            
            // CRITICAL FIX: Sync maxEpisodes from PodcastViewModel to ensure episode limits are respected
            var feedsWithLimits = podcastFeeds
            for i in 0..<feedsWithLimits.count {
                let feedId = feedsWithLimits[i].id
                if let viewModelFeed = PodcastViewModel.shared.podcastFeeds.first(where: { $0.id == feedId }),
                   let maxEpisodes = viewModelFeed.maxEpisodes {
                    feedsWithLimits[i].maxEpisodes = maxEpisodes
                    os_log("🚗 CarPlay: Synced maxEpisodes=%d for feed '%@'", log: self.log, type: .debug, maxEpisodes, feedsWithLimits[i].title)
                }
            }
            
            CarPlayManager.shared.configurePodcastData(feedsWithLimits, feedOrder: feedOrder)
            os_log("🚗 CarPlay: Configured CarPlayManager with %d podcast feeds (episodes will load on-demand)", log: self.log, type: .info, feedsWithLimits.count)
            print("🚗 CarPlay: Configured with \(feedsWithLimits.count) podcast feeds in order")
            
            // CRITICAL FIX: Always refresh templates when feeds are loaded
            print("🚗 CarPlay: Refreshing CarPlay templates with loaded podcast feeds")
            self.refreshPodcastTabTemplate()
            
            // Also refresh current template if we're viewing a podcast
            self.refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
            
            print("🚗 CarPlay: Podcast data loading completed with \(podcastFeeds.count) feeds")
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
        
        // Set up UserDefaults-based sync monitoring for cross-scene communication
        setupCarPlaySyncMonitoring()
        
        // Immediately check for any pending sync requests when CarPlay connects
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.checkForSyncRequests()
        }
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
        
        // Clean up sync monitoring timer
        syncMonitoringTimer?.invalidate()
        syncMonitoringTimer = nil
        os_log("🚗 CarPlay: Sync monitoring timer cleaned up", log: log, type: .info)
        
        subscriptionObserver?.cancel()
        subscriptionObserver = nil
        
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
        
        observeSubscriptionStatus()
        
        // The templates below are always built; only playback and restoration are gated, so an
        // unsubscribed user can still browse and see why nothing plays.
        withEntitlement {
            self.restorePlaybackAfterConnect()
        } otherwise: {
            self.handleBlockedPlayback(reason: "CarPlay connected without an active subscription")
        }
        
        // Setup the root template with a small delay to allow state restoration to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupRootTemplate()
        }
        
        // Validate CarPlay implementation compliance
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.validateCarPlayCompliance()
        }
        
        // Enhanced CarPlay artwork monitoring
        setupEnhancedArtworkMonitoring()
        
        os_log("🚗 CarPlay: Initial template setup complete with independent restoration", log: log, type: .info)
    }
    
    private func restorePlaybackAfterConnect() {
        // CRITICAL: Check if app was force closed and restore independently
        // This enables CarPlay to work without requiring phone app to be opened
        checkAppTerminationAndRestoreIndependently()
        
        // CRITICAL: Restore playback state when CarPlay reconnects after app force close
        // This ensures Now Playing info and UI state are properly restored
        restorePlaybackStateAfterReconnection()
        
        // Instant CarPlay restoration with no delays
        performIndependentCarPlayRestoration()
    }
    
    // MARK: - Subscription Entitlement
    
    /// CarPlay is its own scene, so the in-app paywall never covers it. Without this gate an expired
    /// subscription keeps playing from the car indefinitely.
    private var isEntitled: Bool {
        SubscriptionManager.entitlementSnapshot.isEntitled
    }
    
    /// Runs `onAllowed` only when the user is entitled, refreshing the status first if it hasn't
    /// resolved yet — CarPlay can connect before StoreKit has answered.
    private func withEntitlement(_ onAllowed: @escaping () -> Void, otherwise onBlocked: @escaping () -> Void) {
        let snapshot = SubscriptionManager.entitlementSnapshot
        if snapshot.isEntitled {
            onAllowed()
            return
        }
        
        guard !snapshot.isResolved else {
            onBlocked()
            return
        }
        
        Task { @MainActor in
            await SubscriptionManager.shared.updateSubscriptionStatus()
            if self.isEntitled { onAllowed() } else { onBlocked() }
        }
    }
    
    private func handleBlockedPlayback(reason: String) {
        os_log("🚗 CarPlay: Playback blocked - %@", log: log, type: .info, reason)
        
        stopAllPlaybackForExpiredSubscription()
        presentSubscriptionRequiredAlert()
    }
    
    private func stopAllPlaybackForExpiredSubscription() {
        DispatchQueue.main.async {
            RadioPlayer.shared.stop()
            PodcastPlayer.shared.pause()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            
            // Restoration reads these on the next connect; leaving them set would resume playback.
            let userDefaults = UserDefaults.standard
            userDefaults.set(false, forKey: "CarPlayRadioWasPlaying")
            userDefaults.set(false, forKey: "CarPlayPodcastWasPlaying")
        }
    }
    
    private func presentSubscriptionRequiredAlert() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let interfaceController = self.interfaceController else { return }
            
            let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
            
            let alert = CPAlertTemplate(
                titleVariants: [
                    "Your StreamRadios subscription has ended. Open the app on your iPhone to renew.",
                    "Subscription ended. Open StreamRadios on your iPhone.",
                    "Subscription required"
                ],
                actions: [dismiss]
            )
            
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
        }
    }
    
    /// Cuts playback the moment entitlement lapses mid-drive.
    private func observeSubscriptionStatus() {
        subscriptionObserver = SubscriptionManager.shared.$subscriptionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                guard status != .unknown, !status.isSubscribed else { return }
                
                if RadioPlayer.shared.isPlaying || PodcastPlayer.shared.isPlaying {
                    self.handleBlockedPlayback(reason: "subscription lapsed during CarPlay session")
                }
            }
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
        
        // Skip audio session activation during CarPlay restoration to prevent -50 errors
        // Let the actual playback trigger audio session activation when needed
        
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
        
        // Skip audio session activation during CarPlay restoration to prevent -50 errors
        // Let the actual playback trigger audio session activation when needed
        
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
        
        // Skip audio session activation during CarPlay restoration to prevent -50 errors
        // Let the actual playback trigger audio session activation when needed
        
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
        
        // Skip audio session activation during CarPlay restoration to prevent -50 errors
        // Let the actual playbook trigger audio session activation when needed
        
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
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let iTunesArtworkDataString = station.iTunesArtworkData,
                  let iTunesArtworkData = Data(base64Encoded: iTunesArtworkDataString),
                  let image = UIImage(data: iTunesArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
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
        // CRITICAL: Don't configure audio session directly in CarPlay
        // Let PlaybackManager handle all audio session configuration to avoid conflicts
        os_log("🚗 CarPlay: Skipping direct audio session configuration to avoid conflicts with PlaybackManager", log: log, type: .info)
        
        // PlaybackManager will handle audio session configuration when needed
        // This prevents the -50 errors from competing audio session configurations
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
        
        // Skip audio session activation during CarPlay initialization to prevent -50 errors
        // Only update Now Playing info safely without triggering audio session changes
        createImmediateRadioNowPlayingInfoSafe(for: restoredStation)
        
        // Set up gentle fallback updates that don't trigger audio session activation
        for delay in [0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.createImmediateRadioNowPlayingInfoSafe(for: restoredStation)
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
        
        // Skip audio session activation during CarPlay initialization to prevent -50 errors
        // Only update Now Playing info safely without triggering audio session changes
        createImmediatePodcastNowPlayingInfoSafe(episodeTitle: episodeTitle, progress: progress, episodeId: episodeId, feedId: feedId)
        
        // Set up gentle fallback updates that don't trigger audio session activation
        for delay in [0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.createImmediatePodcastNowPlayingInfoSafe(episodeTitle: episodeTitle, progress: progress, episodeId: episodeId, feedId: feedId)
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
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let iTunesArtworkDataString = station.iTunesArtworkData,
                  let iTunesArtworkData = Data(base64Encoded: iTunesArtworkDataString),
                  let image = UIImage(data: iTunesArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
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
    
    /// Safe version that doesn't trigger additional audio session activation
    private func createImmediateRadioNowPlayingInfoSafe(for station: RadioStation) {
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
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let iTunesArtworkDataString = station.iTunesArtworkData,
                  let iTunesArtworkData = Data(base64Encoded: iTunesArtworkDataString),
                  let image = UIImage(data: iTunesArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Skip setupRemoteCommandCenter() to avoid triggering additional audio session activation
        
        os_log("🚗 CarPlay: Created safe radio Now Playing info (no audio session activation): %@", log: log, type: .info, station.name)
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
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
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
    
    private func createImmediatePodcastNowPlayingInfoSafe(episodeTitle: String, progress: Double, episodeId: String, feedId: String) {
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
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
        }
        // If no artwork available, don't set any artwork (better than corrupted green image)
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // SAFE VERSION: Skip setupRemoteCommandCenter() to avoid audio session activation
        
        os_log("🚗 CarPlay: Created safe podcast Now Playing info (no audio session activation): %@", log: log, type: .info, episodeTitle)
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
        guard isEntitled else {
            handleBlockedPlayback(reason: "state recovery attempted without an active subscription")
            return
        }
        
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
        print("🚗 CarPlay: Creating recents tab...")
        let recentsTab = self.createRecentsTab() 
        print("🚗 CarPlay: Creating stations tab...")
        let stationsTab = self.createStationsTab()
        print("🚗 CarPlay: Creating podcasts tab...")
        let podcastsTab = self.createPodcastsTab()
        print("🚗 CarPlay: Creating downloads tab...")
        let downloadsTab = self.createDownloadsTab()
        
        print("🚗 CarPlay: Creating tab bar template with \([recentsTab, stationsTab, podcastsTab, downloadsTab].count) tabs")
        print("🚗 CarPlay: Tab order - Index 0: \(recentsTab.tabTitle ?? "nil"), Index 1: \(stationsTab.tabTitle ?? "nil"), Index 2: \(podcastsTab.tabTitle ?? "nil"), Index 3: \(downloadsTab.tabTitle ?? "nil")")
        
        // Create tab bar template - Order: Recent, Radio, Podcast, Downloads
        let tabBarTemplate = CPTabBarTemplate(templates: [recentsTab, stationsTab, podcastsTab, downloadsTab])
        
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
        var favoriteRows: [(stationId: String, item: CPListItem)] = []
        // Show ALL favorite stations - no artificial limits
        for station in favoriteStations {
            let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
            
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
            favoriteRows.append((station.id, item))
        }
        registerStationRows(favoriteRows, key: "favorites")
        
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
        
        let listTemplate = CPListTemplate(title: "Radio", sections: sections)
        listTemplate.tabTitle = "Radio"
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
            var downloadRows: [(episodeId: String, item: CPListItem)] = []
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
                    downloadRows.append((episode.id, item))
                }
                
                // Create section for this podcast
                let sectionHeader = "\(feed.title) (\(episodes.count) downloaded)"
                let podcastSection = CPListSection(items: episodeItems, header: sectionHeader, sectionIndexTitle: nil)
                sections.append(podcastSection)
            }
            registerEpisodeRows(downloadRows, key: "downloads")
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
        var recentRows: [(stationId: String, item: CPListItem)] = []
        for station in recentStations {
            let timeAgo = formatTimeAgo(station.lastPlayed)
            let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
            
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
            recentRows.append((station.id, item))
        }
        registerStationRows(recentRows, key: "recents")
        
        if recentStationItems.isEmpty {
            let emptyItem = CPListItem(text: "No Recent Stations", detailText: "Recently played stations will appear here")
            recentStationItems.append(emptyItem)
        }
        
        let recentStationsSection = CPListSection(items: recentStationItems, header: "Recently Played Stations", sectionIndexTitle: nil)
        sections.append(recentStationsSection)
        
        // Get recent podcast episodes from CarPlayManager SECOND (after stations)
        let recentEpisodes = carPlayManager.getRecentPodcastEpisodes()
        
        var recentEpisodeItems: [CPListItem] = []
        var recentEpisodeRows: [(episodeId: String, item: CPListItem)] = []
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
            
            // Use podcast artwork for recently played episodes with persistence support
            var itemImage: UIImage?
            
            // Try to get artwork using the new method that supports persisted data
            itemImage = carPlayManager.getPodcastArtworkByFeedId(episode.feedId)
            
            if let image = itemImage {
                print("CarPlay: Successfully loaded artwork for episode '\(episode.title)' (feedId: \(episode.feedId))")
            } else {
                print("CarPlay: No artwork available for episode '\(episode.title)' (feedId: \(episode.feedId))")
                
                // If we have an active feed, try loading from URL asynchronously
                if let feed = podcastFeed, let artworkUrl = feed.artworkUrl {
                    carPlayManager.loadPodcastArtworkFromURL(for: feed) { [weak self] loadedImage in
                        DispatchQueue.main.async {
                            if loadedImage != nil {
                                // Refresh the CarPlay interface with the loaded artwork
                                print("CarPlay: Artwork loaded from URL for '\(feed.title)', refreshing interface")
                                self?.refreshCarPlayInterface()
                            }
                        }
                    }
                }
            }
            
            // Use microphone icon as fallback if no artwork found
            if itemImage == nil {
                itemImage = UIImage(systemName: "microphone")
            }
            
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
            recentEpisodeRows.append((episode.id, item))
        }
        registerEpisodeRows(recentEpisodeRows, key: "recents")
        
        if recentEpisodeItems.isEmpty {
            let emptyItem = CPListItem(text: "No Recent Episodes", detailText: "Recently played podcast episodes will appear here")
            recentEpisodeItems.append(emptyItem)
        }
        
        let recentEpisodesSection = CPListSection(items: recentEpisodeItems, header: "Recently Played Episodes", sectionIndexTitle: nil)
        sections.append(recentEpisodesSection)
        
        let listTemplate = CPListTemplate(title: "Recent", sections: sections)
        listTemplate.tabTitle = "Recent"
        listTemplate.tabImage = UIImage(systemName: "clock")
        
        return listTemplate
    }
    
    private func createPodcastsTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        print("🚗 CarPlay: Creating Podcast tab - DEBUG START")
        
        // CRITICAL FIX: Ensure podcast data is loaded from Core Data before creating tab
        // This ensures feeds are available even if the phone app is closed
        Task {
            await loadPodcastDataFromCoreData()
        }
        
        // Get podcasts from CarPlayManager and order them the same as PodcastListView
        let carPlayManager = CarPlayManager.shared
        let allPodcastFeeds = carPlayManager.getPodcastFeeds()
        let podcastViewModel = PodcastViewModel.shared
        
        print("🚗 CarPlay: Found \(allPodcastFeeds.count) podcast feeds from CarPlayManager")
        print("🚗 CarPlay: PodcastViewModel has \(podcastViewModel.podcastFeedOrder.count) ordered feeds")
        
        // Order feeds the same way as PodcastListView using podcastFeedOrder
        let orderedFeedIds = podcastViewModel.podcastFeedOrder
        let feedsById = Dictionary(uniqueKeysWithValues: allPodcastFeeds.map { ($0.id, $0) })
        
        // First add feeds in the user's custom order
        var orderedFeeds: [PodcastFeed] = []
        for feedId in orderedFeedIds {
            if let feed = feedsById[feedId] {
                orderedFeeds.append(feed)
            }
        }
        
        // Then add any remaining feeds that aren't in the custom order (shouldn't happen normally)
        let orderedFeedIds_set = Set(orderedFeedIds)
        let remainingFeeds = allPodcastFeeds.filter { !orderedFeedIds_set.contains($0.id) }
        orderedFeeds.append(contentsOf: remainingFeeds)
        
        var podcastItems: [CPListItem] = []
        for podcast in orderedFeeds {
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
            let emptyItem = CPListItem(text: "No Podcasts", detailText: "Open the phone app to sync your podcasts")
            podcastItems.append(emptyItem)
        }
        
        let podcastSection = CPListSection(items: podcastItems, header: "Your Podcasts", sectionIndexTitle: nil)
        sections.append(podcastSection)
        
        let listTemplate = CPListTemplate(title: "Podcast", sections: sections)
        listTemplate.tabTitle = "Podcast"
        listTemplate.tabImage = UIImage(systemName: "microphone")
        
        print("🚗 CarPlay: Podcast tab created with \(sections.count) sections and \(podcastItems.count) items")
        print("🚗 CarPlay: Podcast tab title: '\(listTemplate.title ?? "nil")', tabTitle: '\(listTemplate.tabTitle ?? "nil")'")
        
        return listTemplate
    }
    
    // MARK: - Navigation Handlers
    
    private func showStationsForCountry(_ country: String, completion: @escaping () -> Void) {
        // Validate template depth before navigation
        validateTemplateDepth()
        
        let carPlayManager = CarPlayManager.shared
        let stations = carPlayManager.getStations(for: country)
        
        // Stations are now sorted alphabetically to match phone app order
        let sortOrder = RadioStationViewModel.shared.isAscendingSort ? "ascending" : "descending"
        os_log("🚗 CarPlay: Displaying %d stations for '%@' in %@ alphabetical order", log: log, type: .info, stations.count, country, sortOrder)
        
        var stationItems: [CPListItem] = []
        
        // Show ALL stations for the country - no artificial limits
        var countryRows: [(stationId: String, item: CPListItem)] = []
        for station in stations {
            let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
            
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
            countryRows.append((station.id, item))
        }
        registerStationRows(countryRows, key: "country")
        
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
            // CRITICAL FIX: Respect maxEpisodes limit when calculating initial batch size
            var effectiveTotal = totalEpisodes
            if let maxEpisodes = podcast.maxEpisodes, maxEpisodes > 0 {
                effectiveTotal = min(totalEpisodes, maxEpisodes)
                os_log("🚗 CarPlay: Feed has maxEpisodes limit of %d (total in DB: %d)", log: self.log, type: .info, maxEpisodes, totalEpisodes)
            }
            
            let initialBatchSize = min(50, effectiveTotal) // Load max 50 episodes initially (or maxEpisodes if lower)
            os_log("🚗 CarPlay: Podcast '%@' loading initial batch of %d episodes (effective total: %d)", log: self.log, type: .info, podcast.title, initialBatchSize, effectiveTotal)
            
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
        
        // Add "Latest Episode" section first if we have episodes
        var allEpisodeRows: [(episodeId: String, item: CPListItem)] = []
        if !podcast.episodes.isEmpty {
            let latestEpisode = podcast.episodes.first!
            let latestEpisodeItem = self.createEpisodeListItem(episode: latestEpisode, podcast: podcast, carPlayManager: carPlayManager)
            allEpisodeRows.append((latestEpisode.id, latestEpisodeItem))
            let latestEpisodeSection = CPListSection(items: [latestEpisodeItem], header: "Latest Episode", sectionIndexTitle: nil)
            sections.append(latestEpisodeSection)
        }
        
        // Show remaining episodes (skip the first one since we showed it as "Latest Episode")
        var episodeItems: [CPListItem] = []
        let remainingEpisodes = podcast.episodes.count > 1 ? Array(podcast.episodes.dropFirst()) : []
        
        for episode in remainingEpisodes {
            let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
            episodeItems.append(item)
            allEpisodeRows.append((episode.id, item))
        }
        registerEpisodeRows(allEpisodeRows, key: "episodes")
        
        // Only add Episodes section if we have remaining episodes
        if !episodeItems.isEmpty {
            let episodesSection = CPListSection(items: episodeItems, header: "Episodes", sectionIndexTitle: nil)
            sections.append(episodesSection)
        }
        
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
        
        // Add "Latest Episode" section first if we have episodes
        var allEpisodeRows: [(episodeId: String, item: CPListItem)] = []
        if !podcast.episodes.isEmpty {
            let latestEpisode = podcast.episodes.first!
            let latestEpisodeItem = self.createEpisodeListItem(episode: latestEpisode, podcast: podcast, carPlayManager: carPlayManager)
            allEpisodeRows.append((latestEpisode.id, latestEpisodeItem))
            let latestEpisodeSection = CPListSection(items: [latestEpisodeItem], header: "Latest Episode", sectionIndexTitle: nil)
            sections.append(latestEpisodeSection)
        }
        
        // Show remaining episodes (skip the first one since we showed it as "Latest Episode")
        var episodeItems: [CPListItem] = []
        let remainingEpisodes = podcast.episodes.count > 1 ? Array(podcast.episodes.dropFirst()) : []
        
        for episode in remainingEpisodes {
            let item = self.createEpisodeListItem(episode: episode, podcast: podcast, carPlayManager: carPlayManager)
            episodeItems.append(item)
            allEpisodeRows.append((episode.id, item))
        }
        registerEpisodeRows(allEpisodeRows, key: "episodes")
        
        // CRITICAL FIX: Calculate effective maximum episodes respecting maxEpisodes limit
        let effectiveMaximum: Int
        if let maxEpisodes = podcast.maxEpisodes, maxEpisodes > 0 {
            effectiveMaximum = min(totalEpisodes, maxEpisodes)
            os_log("🚗 CarPlay: Effective maximum episodes: %d (total: %d, limit: %d)", log: self.log, type: .debug, effectiveMaximum, totalEpisodes, maxEpisodes)
        } else {
            effectiveMaximum = totalEpisodes
        }
        
        // Add "Load More Episodes" option only if there are more episodes within the limit
        if loadedCount < effectiveMaximum {
            let remainingCount = effectiveMaximum - loadedCount
            let loadMoreItem = CPListItem(text: "Load More Episodes",
                                         detailText: "\(remainingCount) more episodes available",
                                         image: UIImage(systemName: "ellipsis.circle"))
            loadMoreItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.loadAllRemainingEpisodes(podcast, completion: completion)
            }
            episodeItems.append(loadMoreItem)
        } else if let maxEpisodes = podcast.maxEpisodes, maxEpisodes > 0, loadedCount >= maxEpisodes {
            os_log("🚗 CarPlay: Not showing Load More - reached maxEpisodes limit (%d/%d)", log: self.log, type: .info, loadedCount, maxEpisodes)
        }
        
        // Only add Episodes section if we have remaining episodes or load more option
        if !episodeItems.isEmpty {
            let episodesSection = CPListSection(items: episodeItems, header: "Episodes", sectionIndexTitle: nil)
            sections.append(episodesSection)
        }
        
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
        
        // CRITICAL FIX: Get fresh state from EpisodeStateManager instead of stale episode.state
        // This ensures we always show the correct status and highlighting
        let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
        let episodeProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
        let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
        let isPlayed = (episodeState == .played)
        
        // Determine episode status based on state and current playback
        if isCurrentlyPlaying {
            statusText = " • Playing"
        } else if isPlayed {
            statusText = " • Complete"
        } else if episodeProgress > 0 {
            statusText = " • IN PROGRESS"
        }
        
        // Add download indicator
        if isDownloaded {
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
        var filteredRows: [(episodeId: String, item: CPListItem)] = []
        
        for episode in downloadedEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
            
            // CRITICAL FIX: Get fresh state from EpisodeStateManager
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let episodeProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
            let isPlayed = (episodeState == .played)
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if isPlayed {
                statusText = " • Complete"
            } else if episodeProgress > 0 {
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
            filteredRows.append((episode.id, item))
        }
        registerEpisodeRows(filteredRows, key: "filtered")
        
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
        var filteredRows: [(episodeId: String, item: CPListItem)] = []
        
        for episode in bookmarkedEpisodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episode.id && PodcastPlayer.shared.isPlaying
            
            // CRITICAL FIX: Get fresh state from EpisodeStateManager
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let episodeProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
            let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            let isPlayed = (episodeState == .played)
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if isPlayed {
                statusText = " • Complete"
            } else if episodeProgress > 0 {
                statusText = " • IN PROGRESS"
            }
            
            // Add download indicator if episode is also downloaded
            if isDownloaded {
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
            filteredRows.append((episode.id, item))
        }
        registerEpisodeRows(filteredRows, key: "filtered")
        
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
    
    /// Station whose row should show the now-playing indicator, or nil when radio isn't playing.
    private var highlightedStationId: String? {
        guard PlaybackManager.shared.activePlayer != .podcast else { return nil }
        // `pendingHighlightStationId` is whatever CarPlay last saw start - either a tap here or a
        // station-change notification. RadioPlayer's own `currentlyPlayingStation` lags behind and
        // can stay on the previously restored station, which is what kept row 1 highlighted.
        return pendingHighlightStationId ?? RadioPlayer.shared.currentlyPlayingStation?.id
    }    
    private func shouldShowPlayingIndicator(for station: RadioStation) -> Bool {
        station.id == highlightedStationId
    }
    
    private var appliedSectionSignatures: [String: String] = [:]
    
    /// Rebuilding a list resets its scroll and selection, and `updateSections()` does not reliably
    /// repaint an item's `isPlaying` flag - which leaves two rows highlighted. So rebuild only when
    /// the list contents actually change; the indicator is moved separately by `applyStationHighlight`.
    private func shouldUpdateSections(key: String, data: String) -> Bool {
        guard appliedSectionSignatures[key] != data else { return false }
        appliedSectionSignatures[key] = data
        return true
    }
    
    private var stationRows: [String: [(stationId: String, item: CPListItem)]] = [:]
    
    private static let playingSuffix = " • Playing"
    
    private func registerStationRows(_ rows: [(stationId: String, item: CPListItem)], key: String) {
        stationRows[key] = rows
        applyStationHighlight()
    }
    
    /// Episode whose row should show the now-playing indicator, or nil when nothing is playing.
    private var highlightedEpisodeId: String? {
        guard PlaybackManager.shared.activePlayer != .radio else { return nil }
        return pendingHighlightEpisodeId ?? PodcastPlayer.shared.currentEpisode?.id
    }
    
    private var episodeRows: [String: [(episodeId: String, item: CPListItem)]] = [:]
    
    private func registerEpisodeRows(_ rows: [(episodeId: String, item: CPListItem)], key: String) {
        episodeRows[key] = rows
        applyEpisodeHighlight()
    }
    
    /// Same live-mutation approach as `applyStationHighlight`, for podcast episode rows.
    private func applyEpisodeHighlight() {
        let highlighted = highlightedEpisodeId
        let playingSuffix = Self.playingSuffix
        for rows in episodeRows.values {
            for row in rows {
                let shouldPlay = row.episodeId == highlighted
                // Trailing keeps the equalizer off the artwork, where it reads as part of the logo.
                row.item.playingIndicatorLocation = .trailing
                if row.item.isPlaying != shouldPlay {
                    row.item.isPlaying = shouldPlay
                }
                // Keep the detail text in step with the indicator - a stale " • Playing" on the
                // previously played row is exactly what made the list look doubly highlighted.
                let base = (row.item.detailText ?? "").replacingOccurrences(of: playingSuffix, with: "")
                let wanted = shouldPlay ? base + playingSuffix : base
                if row.item.detailText != wanted {
                    row.item.setDetailText(wanted)
                }
            }
        }
    }
    
    /// Moves the now-playing indicator by mutating the live rows, so exactly one is ever highlighted.
    /// The white row background is CarPlay's focus ring and is not ours to place.
    private func applyStationHighlight() {
        let highlighted = highlightedStationId
        for rows in stationRows.values {
            for row in rows {
                let shouldPlay = row.stationId == highlighted
                row.item.playingIndicatorLocation = .trailing
                if row.item.isPlaying != shouldPlay {
                    row.item.isPlaying = shouldPlay
                }
                let base = (row.item.detailText ?? "").replacingOccurrences(of: Self.playingSuffix, with: "")
                let wanted = shouldPlay ? base + Self.playingSuffix : base
                if row.item.detailText != wanted {
                    row.item.setDetailText(wanted)
                }
            }
        }
    }
    
    private func playStation(_ station: RadioStation, completion: @escaping () -> Void) {
        withEntitlement {
            self.performPlayStation(station, completion: completion)
        } otherwise: {
            self.handleBlockedPlayback(reason: "station tapped without an active subscription")
            completion()
        }
    }
    
    private func performPlayStation(_ station: RadioStation, completion: @escaping () -> Void) {
        os_log("CarPlay: Playing station %@", log: log, type: .info, station.name)
        
        // Move the indicator to the tapped row now; RadioPlayer won't reflect it for another 0.8s.
        pendingHighlightEpisodeId = nil
        pendingHighlightStationId = station.id
        applyStationHighlight()
        applyEpisodeHighlight()
        
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
            
            // Skip audio session activation during CarPlay restoration to prevent -50 errors
            // Let the actual playback trigger audio session activation when needed
            os_log("🚗 CarPlay: Skipping audio session activation during CarPlay restoration", log: self.log, type: .info)
            
            // CRITICAL: Force clear any stale Now Playing info before setting new info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            os_log("🚗 CarPlay: Cleared stale Now Playing info", log: self.log, type: .info)
            
            // CRITICAL: Create immediate Now Playing info for independent operation
            self.createImmediateRadioNowPlayingInfo(for: station)
            
            if RadioStationViewModel.shared.stations.contains(where: { $0.id == station.id }) {
                // Add longer delay to allow CarPlay to fully hand over audio session control
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    // Re-resolve the index here: the list can change during the delay.
                    let stations = RadioStationViewModel.shared.stations
                    guard let stationIndex = stations.firstIndex(where: { $0.id == station.id }) else { return }
                    radioPlayer.playStation(at: stationIndex, from: stations)
                    // Mirrors the phone app so the station lands in Recents and the indicator refreshes.
                    RadioStationViewModel.shared.updateLastPlayed(for: station)
                }
                
                // Gentle fallback attempts that don't trigger concurrent audio session activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Use force update to bypass any active player checks (no setActivePlayer call)
                    radioPlayer.forceUpdateNowPlayingInfo()
                    os_log("🚗 CarPlay: Gentle Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
                
                // Final gentle fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    radioPlayer.forceUpdateNowPlayingInfo()
                    os_log("🚗 CarPlay: Final gentle Now Playing info update for station: %@", log: self.log, type: .info, station.name)
                }
            } else {
                os_log("🚗 CarPlay: Station not found in current stations list, creating independent Now Playing info", log: self.log, type: .error)
                
                // Force create Now Playing info for independent operation (safe version)
                for delay in [0.5, 1.0, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.createImmediateRadioNowPlayingInfoSafe(for: station)
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
        withEntitlement {
            self.performPlayEpisode(episode, completion: completion)
        } otherwise: {
            self.handleBlockedPlayback(reason: "episode tapped without an active subscription")
            completion()
        }
    }
    
    private func performPlayEpisode(_ episode: PodcastEpisode, completion: @escaping () -> Void) {
        os_log("🚗 CarPlay: Playing episode '%@' with progress: %.2f%%", log: log, type: .info, episode.title, episode.state.progress * 100)
        
        // Move the indicator to the tapped row now; the player won't reflect it for a moment.
        pendingHighlightStationId = nil
        pendingHighlightEpisodeId = episode.id
        applyStationHighlight()
        applyEpisodeHighlight()
        
        // Use the existing PodcastPlayer to play the episode
        DispatchQueue.main.async { [self] in
            let podcastPlayer = PodcastPlayer.shared
            let carPlayManager = CarPlayManager.shared
            
            // CARPLAY PROTECTION: Don't reload the same episode that's already playing
            // This prevents progress reset during CarPlay sessions
            if let currentEpisode = podcastPlayer.currentEpisode,
               currentEpisode.id == episode.id,
               podcastPlayer.isPlaying {
                os_log("🚗 CARPLAY PROTECTION: Episode %@ is already playing - not reloading to prevent progress reset", log: self.log, type: .info, episode.title)
                completion()
                return
            }
            
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
                let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
                
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
            registerStationRows(zip(stations.map(\.id), stationItems).map { ($0, $1) }, key: "country")
            
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
        
        // Listen for CarPlay station order changes (immediate refresh)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CarPlayStationOrderChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🚗 CarPlay: Received station order change - refreshing stations template")
            self?.refreshStationsTemplate()
        }
        
        // Listen for CarPlay podcast order changes (immediate refresh)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CarPlayPodcastOrderChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🚗 CarPlay: Received podcast order change - refreshing podcast template")
            self?.refreshPodcastTabTemplate()
        }
        
        // CRITICAL FIX: Listen for instant artwork sync which is posted when radio playback changes
        // This ensures the equalizer indicator updates immediately when stations start/stop playing
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("InstantCarPlayArtworkSync"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // Check if this is a radio station update
            if let userInfo = notification.userInfo,
               let nowPlayingStationId = userInfo["stationId"] as? String {
                os_log("🚗 CarPlay: Radio playback changed to station ID: %@ - refreshing for equalizer update", log: self.log, type: .info, nowPlayingStationId)
                
                self.pendingHighlightStationId = nowPlayingStationId
                self.applyStationHighlight()
                
                // CRITICAL FIX: Pass the station ID from notification to avoid timing issues
                // The notification contains the NEW station being played, while RadioPlayer might still have old station
                
                // Immediately refresh stations tab to update the equalizer indicator
                self.refreshStationsTabTemplate(nowPlayingStationId: nowPlayingStationId)
                
                // Also refresh recents and downloads tabs
                self.refreshRecentsTabTemplate(nowPlayingStationId: nowPlayingStationId)
                self.refreshDownloadsTabTemplate()
                
                // CRITICAL: If user is viewing a country's station list, refresh it immediately too
                if let interfaceController = self.interfaceController,
                   let topTemplate = interfaceController.topTemplate as? CPListTemplate,
                   let templateTitle = topTemplate.title,
                   // Check if this is a country station list (not one of the main tabs)
                   templateTitle != "Recent" && templateTitle != "Radio" && templateTitle != "Podcast" && templateTitle != "Downloads" {
                    
                    os_log("🚗 CarPlay: Refreshing visible country station list: '%@'", log: self.log, type: .info, templateTitle)
                    
                    // Refresh the current country station list
                    self.refreshCurrentCountryStationList(country: templateTitle, nowPlayingStationId: nowPlayingStationId)
                }
            }
        }
    }
    
    /// Refresh the stations template immediately when order changes
    private func refreshStationsTemplate() {
        guard let interfaceController = self.interfaceController,
              let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            print("🚗 CarPlay: No interface controller or tab bar template available for stations refresh")
            return
        }
        
        // Find the stations tab (usually index 1)
        let stationsTabIndex = 1
        guard stationsTabIndex < tabBarTemplate.templates.count,
              let stationsTab = tabBarTemplate.templates[stationsTabIndex] as? CPListTemplate else {
            print("🚗 CarPlay: Stations tab not found for refresh")
            return
        }
        
        // Create fresh stations template with updated order
        let newStationsTab = createStationsTab()
        
        // Replace the stations tab with the updated one
        var updatedTemplates = tabBarTemplate.templates
        updatedTemplates[stationsTabIndex] = newStationsTab
        
        // Update the tab bar template
        let newTabBarTemplate = CPTabBarTemplate(templates: updatedTemplates)
        interfaceController.setRootTemplate(newTabBarTemplate, animated: false)
        
        print("🚗 ⭐ CarPlay: Refreshed stations template with new favorite order")
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
        // CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func handleEpisodeStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String else {
            return
        }
        
        os_log("🚗 CarPlay: Episode state changed: %@", log: log, type: .info, episodeId)
        
        // 🚗 CARPLAY FIX: For favorite/download state changes, use gentle data updates instead of template refreshes
        // This prevents the black screen issue while still updating the data
        let isFavoriteChange = userInfo["isFavorite"] != nil
        let isDownloadChange = userInfo["isDownloaded"] != nil
        
        if isFavoriteChange || isDownloadChange {
            // For favorite/download changes, use immediate but gentle refresh to prevent black screens
            os_log("🚗 CarPlay: Using gentle immediate refresh for favorite/download change", log: log, type: .info)
            let carPlayManager = CarPlayManager.shared
            carPlayManager.updateContent() // Update internal data first
            
            // Use immediate gentle refresh instead of the aggressive template refresh
            performGentleRefreshIfVisible(episodeId: episodeId)
        } else {
            // For other changes (like progress), use the existing refresh logic
            refreshCurrentPodcastTemplateIfNeeded(episodeId: episodeId)
        }
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
        // CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func performDelayedPlaybackUIUpdates(episodeId: String) {
        os_log("🚗 CarPlay: Performing delayed UI updates for episode ID: %@", log: log, type: .info, episodeId)
        
        applyEpisodeHighlight()
        applyStationHighlight()
        
        // Use the same efficient section update approach that works perfectly for Recents tab
        // This provides immediate visual highlighting changes just like Recents does
        forceImmediateSectionUpdate(episodeId: episodeId)
        
        // Also refresh the recents tab, stations tab, and downloads tab to show/hide the highlighted playing state
        refreshRecentsTabTemplate()
        refreshStationsTabTemplate()
        refreshDownloadsTabTemplate()
    }
    
    private func performImmediatePlaybackUIUpdates(episodeId: String) {
        os_log("🚗 CarPlay: Performing immediate UI updates for episode ID: %@", log: log, type: .info, episodeId)
        
        applyEpisodeHighlight()
        applyStationHighlight()
        
        // Use the same efficient section update approach that works perfectly for Recents tab
        // This provides immediate visual highlighting changes just like Recents does
        forceImmediateSectionUpdate(episodeId: episodeId)
        
        // Also refresh the recents tab, stations tab, and downloads tab to show/hide the highlighted playing state
        refreshRecentsTabTemplate()
        refreshStationsTabTemplate()
        refreshDownloadsTabTemplate()
    }
    
    private func handleStationPlayedForRecents(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            os_log("🚗 CarPlay: Invalid station played notification", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Station played for recents update - ID: %@", log: log, type: .info, stationId)
        
        pendingHighlightStationId = stationId
        applyStationHighlight()
        
        // CRITICAL: Force Now Playing info update for radio stations after force close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            RadioPlayer.shared.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Forced Now Playing info update for station start", log: self.log, type: .info)
        }
        
        // Update CarPlayManager's recents data immediately
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent() // This will refresh the recent stations list
        
        // Force refresh the recents tab, stations tab, and downloads tab to show/hide highlighting
        refreshRecentsTabTemplate(nowPlayingStationId: stationId)
        refreshStationsTabTemplate(nowPlayingStationId: stationId)
        refreshDownloadsTabTemplate()
        
        // Additional Now Playing update with UI updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            RadioPlayer.shared.updateNowPlayingInfo()
            os_log("🚗 CarPlay: Additional Now Playing info update for station", log: self.log, type: .info)
        }
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // CarPlay uses CPTemplateApplicationScene and direct template updates
    }
    
    private func handleCarPlayRefreshRequest(_ notification: Notification) {
        let source = notification.userInfo?["source"] as? String ?? "unknown"
        os_log("🚗 CarPlay: Received refresh request from source: %@", log: log, type: .info, source)
        
        // CRITICAL FIX: Don't reload data if podcast is currently playing - this prevents episode restart
        let podcastPlayer = PodcastPlayer.shared
        let isPodcastPlaying = podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil
        let hasUserIntent = podcastPlayer.userWantsToPlay
        let isActivePlayer = PlaybackManager.shared.activePlayer == .podcast
        
        os_log("🚗 CarPlay: Refresh request - isPlaying: %@, hasEpisode: %@, userWantsToPlay: %@, activePlayer: %@", log: log, type: .info, 
               podcastPlayer.isPlaying ? "YES" : "NO",
               podcastPlayer.currentEpisode != nil ? "YES" : "NO",
               hasUserIntent ? "YES" : "NO",
               isActivePlayer ? "podcast" : "other")
        
        if isPodcastPlaying || (hasUserIntent && podcastPlayer.currentEpisode != nil && isActivePlayer) {
            os_log("🚗 CarPlay: Skipping data reload - podcast is currently playing or has active session to prevent episode restart", log: log, type: .info)
            return
        }
        
        // 🔄 ENHANCED SYNC: Force reload podcast data from Core Data when main app requests refresh
        // This ensures that new podcast feeds added in the main app are immediately available in CarPlay
        if source == "SceneDidBecomeActive" || source == "SceneWillEnterForeground" {
            os_log("🚗 CarPlay: Performing enhanced data reload for main app sync", log: log, type: .info)
            
            // Reload podcast feeds data asynchronously to prevent UI blocking
            Task {
                await loadPodcastDataFromCoreData()
                
                // After data reload, refresh UI on main thread
                await MainActor.run {
                    os_log("🚗 CarPlay: Podcast data reloaded, refreshing UI templates", log: self.log, type: .info)
                    
                    // Force refresh all data
                    let carPlayManager = CarPlayManager.shared
                    carPlayManager.updateContent()
                    
                    // Refresh the podcast tab template to show newly loaded feeds
                    self.refreshPodcastTabTemplate()
                    
                    // Refresh current templates
                    self.refreshRecentsTabTemplate()
                    self.refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
                }
            }
        } else {
            // For other refresh sources, use the existing quick refresh
            let carPlayManager = CarPlayManager.shared
            carPlayManager.updateContent()
            
            // Refresh current templates
            refreshRecentsTabTemplate()
            refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
        }
        
        // Note: Removed deprecated MPPlayableContentManager.shared().reloadData()
        // CarPlay uses CPTemplateApplicationScene and direct template updates
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
    
    /// Refresh the recents tab template to show updated recently played content
    /// - Parameter nowPlayingStationId: Optional station ID from notification (preferred over RadioPlayer state)
    private func refreshRecentsTabTemplate(nowPlayingStationId: String? = nil) {
        guard let interfaceController = self.interfaceController else {
            os_log("🚗 CarPlay: Cannot refresh recents - no interface controller", log: log, type: .error)
            return
        }
        
        if let nowPlayingStationId = nowPlayingStationId {
            os_log("🚗 CarPlay: Refreshing recents tab template with nowPlayingStationId: %@", log: log, type: .info, nowPlayingStationId)
        } else {
            os_log("🚗 CarPlay: Refreshing recents tab template (no nowPlayingStationId)", log: log, type: .info)
        }
        
        // Get the current root template
        guard let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: Root template is not a tab bar template", log: log, type: .error)
            return
        }
        
        // Find the recents tab (index 0 based on setupRootTemplate order: Recent, Radio, Podcast, Downloads)
        let recentsTabIndex = 0
        if recentsTabIndex < tabBarTemplate.templates.count,
           let recentsTab = tabBarTemplate.templates[recentsTabIndex] as? CPListTemplate {
            
            // Instead of recreating the entire tab bar template, update the existing recents tab in place
            // Get fresh recents data
            let carPlayManager = CarPlayManager.shared
            let recentStations = carPlayManager.getRecentStations()
            let recentEpisodes = carPlayManager.getRecentPodcastEpisodes()
            
            os_log("🚗 CarPlay Recents: Found %d recent stations", log: self.log, type: .info, recentStations.count)
            
            guard shouldUpdateSections(key: "recents",
                                       data: (recentStations.map(\.id) + recentEpisodes.map(\.id)).joined(separator: ",")) else {
                applyStationHighlight()
                return
            }
            
            // Create new sections with updated data
            var newSections: [CPListSection] = []
            
            // Recent stations section FIRST (as requested)
            var recentStationItems: [CPListItem] = []
            var recentRows: [(stationId: String, item: CPListItem)] = []
            var equalizerSetCount = 0
            for station in recentStations {
                let timeAgo = formatTimeAgo(station.lastPlayed)
                
                let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
                if isCurrentlyPlaying {
                    equalizerSetCount += 1
                }
                
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
                recentRows.append((station.id, item))
            }
            registerStationRows(recentRows, key: "recents")
            
            if recentStationItems.isEmpty {
                let emptyItem = CPListItem(text: "No Recent Stations", detailText: "Recently played stations will appear here")
                recentStationItems.append(emptyItem)
            }
            
            let recentStationsSection = CPListSection(items: recentStationItems, header: "Recently Played Stations", sectionIndexTitle: nil)
            newSections.append(recentStationsSection)
            
            // Recent episodes section SECOND (after stations)
            var recentEpisodeItems: [CPListItem] = []
            var recentEpisodeRows: [(episodeId: String, item: CPListItem)] = []
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
                
                // Use podcast artwork for recently played episodes with persistence support
                var itemImage: UIImage?
                
                // Try to get artwork using the new method that supports persisted data
                itemImage = carPlayManager.getPodcastArtworkByFeedId(episode.feedId)
                
                if let image = itemImage {
                    print("CarPlay: Successfully loaded artwork for episode '\(episode.title)' (feedId: \(episode.feedId))")
                } else {
                    print("CarPlay: No artwork available for episode '\(episode.title)' (feedId: \(episode.feedId))")
                    
                    // If we have an active feed, try loading from URL asynchronously
                    if let feed = podcastFeed, let artworkUrl = feed.artworkUrl {
                        carPlayManager.loadPodcastArtworkFromURL(for: feed) { [weak self] loadedImage in
                            DispatchQueue.main.async {
                                if loadedImage != nil {
                                    // Refresh the CarPlay interface with the loaded artwork
                                    print("CarPlay: Artwork loaded from URL for '\(feed.title)', refreshing interface")
                                    self?.refreshCarPlayInterface()
                                }
                            }
                        }
                    }
                }
                
                // Use microphone icon as fallback if no artwork found
                if itemImage == nil {
                    itemImage = UIImage(systemName: "microphone")
                }
                
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
                recentEpisodeRows.append((episode.id, item))
            }
            registerEpisodeRows(recentEpisodeRows, key: "recents")
            
            if recentEpisodeItems.isEmpty {
                let emptyItem = CPListItem(text: "No Recent Episodes", detailText: "Recently played episodes will appear here")
                recentEpisodeItems.append(emptyItem)
            }
            
            let recentEpisodesSection = CPListSection(items: recentEpisodeItems, header: "Recently Played Episodes", sectionIndexTitle: nil)
            newSections.append(recentEpisodesSection)
            
            // Update the sections directly on the existing template - this preserves navigation
            recentsTab.updateSections(newSections)
            
            os_log("🚗 CarPlay Recents: ✅ Successfully updated with %d stations, %d with equalizer indicator", log: self.log, type: .info, recentStations.count, equalizerSetCount)
            
            if equalizerSetCount == 0 && nowPlayingStationId != nil {
                os_log("⚠️ CarPlay Recents: WARNING - nowPlayingStationId provided but no stations matched!", log: self.log, type: .error)
            }
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
        
        // Find the downloads tab (index 3 based on setupRootTemplate order: Recent, Radio, Podcast, Downloads)
        let downloadsTabIndex = 3
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
            
            guard shouldUpdateSections(key: "downloads",
                                       data: podcastsWithDownloads.flatMap { $0.episodes.map(\.id) }.joined(separator: ",")) else {
                applyEpisodeHighlight()
                return
            }
            
            if podcastsWithDownloads.isEmpty {
                // No downloads found
                let emptyItem = CPListItem(text: "No Downloaded Episodes", 
                                         detailText: "Downloaded podcast episodes will appear here")
                let emptySection = CPListSection(items: [emptyItem], header: "Downloads", sectionIndexTitle: nil)
                newSections.append(emptySection)
            } else {
                var downloadRows: [(episodeId: String, item: CPListItem)] = []
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
                        downloadRows.append((episode.id, item))
                    }
                    
                    // Create section for this podcast
                    let sectionHeader = "\(feed.title) (\(episodes.count) downloaded)"
                    let podcastSection = CPListSection(items: episodeItems, header: sectionHeader, sectionIndexTitle: nil)
                    newSections.append(podcastSection)
                }
                registerEpisodeRows(downloadRows, key: "downloads")
            }
            
            // Update the sections directly on the existing template - this preserves navigation
            downloadsTab.updateSections(newSections)
            
            os_log("🚗 CarPlay: Successfully updated downloads tab sections without changing navigation", log: self.log, type: .info)
        } else {
            os_log("🚗 CarPlay: Downloads tab index out of bounds or not a list template", log: log, type: .error)
        }
    }
    
    /// Set up monitoring for UserDefaults-based sync requests from main app
    private func setupCarPlaySyncMonitoring() {
        os_log("🚗 CarPlay: Setting up UserDefaults-based sync monitoring", log: log, type: .info)
        
        // Invalidate existing timer if any
        syncMonitoringTimer?.invalidate()
        
        // Check for sync requests every 0.5 seconds when CarPlay is active for immediate response
        syncMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForSyncRequests()
        }
        
        // Store timer reference and add to run loop
        if let timer = syncMonitoringTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        os_log("🚗 CarPlay: UserDefaults sync monitoring timer started", log: log, type: .info)
    }
    
    /// Check for sync requests from main app via shared UserDefaults
    private func checkForSyncRequests() {
        guard let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") else {
            os_log("🚗 CarPlay: Failed to access app group UserDefaults", log: log, type: .error)
            return
        }
        
        let syncRequestTime = appGroupDefaults.double(forKey: "CarPlaySyncRequested")
        let syncSource = appGroupDefaults.string(forKey: "CarPlaySyncSource") ?? "Unknown"
        let lastProcessedTime = appGroupDefaults.double(forKey: "CarPlayLastProcessed")
        
        // Debug logging every 10 seconds to avoid spam
        if Int(Date().timeIntervalSince1970) % 10 == 0 {
            os_log("🚗 CarPlay: Sync check - Request: %.1f, Source: %@, LastProcessed: %.1f", 
                   log: log, type: .debug, syncRequestTime, syncSource, lastProcessedTime)
        }
        
        // Check if this is a new sync request (within last 60 seconds and not already processed)
        let now = Date().timeIntervalSince1970
        let timeSinceRequest = now - syncRequestTime
        
        if syncRequestTime > 0 && timeSinceRequest < 60.0 && timeSinceRequest >= 0 {
            // Check if we've already processed this request
            
            if syncRequestTime > lastProcessedTime {
                os_log("🚗 CarPlay: Found new sync request from %@ (%.1f seconds ago)", log: log, type: .info, syncSource, timeSinceRequest)
                
                // Mark this request as processed
                appGroupDefaults.set(syncRequestTime, forKey: "CarPlayLastProcessed")
                appGroupDefaults.synchronize()
                
                // Trigger the sync
                handleCarPlaySyncRequest(source: syncSource)
            } else {
                // Debug: Request already processed
                if timeSinceRequest < 5.0 { // Only log for recent requests
                    os_log("🚗 CarPlay: Sync request already processed (%.1f seconds ago)", log: log, type: .debug, timeSinceRequest)
                }
            }
        } else if syncRequestTime > 0 && timeSinceRequest >= 60.0 {
            // Debug: Request too old
            os_log("🚗 CarPlay: Sync request too old (%.1f seconds ago)", log: log, type: .debug, timeSinceRequest)
        }
    }
    
    /// Handle sync request with proper source identification
    private func handleCarPlaySyncRequest(source: String) {
        os_log("🚗 CarPlay: Processing sync request from source: %@", log: log, type: .info, source)
        
        // Use the existing enhanced sync logic for main app requests
        if source == "SceneDidBecomeActive" || source == "SceneWillEnterForeground" {
            os_log("🚗 CarPlay: Performing enhanced data reload for main app sync", log: log, type: .info)
            
            // Reload podcast feeds data asynchronously to prevent UI blocking
            Task {
                await loadPodcastDataFromCoreData()
                
                // After data reload, refresh UI on main thread
                await MainActor.run {
                    os_log("🚗 CarPlay: Podcast data reloaded, refreshing UI templates", log: self.log, type: .info)
                    
                    // Force refresh all data
                    let carPlayManager = CarPlayManager.shared
                    carPlayManager.updateContent()
                    
                    // Refresh the podcast tab template to show newly loaded feeds
                    self.refreshPodcastTabTemplate()
                    
                    // Refresh current templates
                    self.refreshRecentsTabTemplate()
                    self.refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
                }
            }
        } else {
            // For other refresh sources, use the existing quick refresh
            let carPlayManager = CarPlayManager.shared
            carPlayManager.updateContent()
            
            // Refresh current templates
            refreshRecentsTabTemplate()
            refreshCurrentPodcastTemplateIfNeeded(episodeId: "")
        }
    }
    
    /// Refresh a pushed country station list, if one is on screen, so its indicator stays in sync.
    private func refreshVisibleCountryStationListIfNeeded(nowPlayingStationId: String? = nil) {
        guard let interfaceController = self.interfaceController,
              let topTemplate = interfaceController.topTemplate as? CPListTemplate,
              let templateTitle = topTemplate.title,
              templateTitle != "Recent", templateTitle != "Radio",
              templateTitle != "Podcast", templateTitle != "Downloads" else {
            return
        }
        refreshCurrentCountryStationList(country: templateTitle, nowPlayingStationId: nowPlayingStationId)
    }
    
    /// Refresh the currently visible country station list to update equalizer indicators
    /// - Parameter nowPlayingStationId: Optional station ID from notification (preferred over RadioPlayer state)
    private func refreshCurrentCountryStationList(country: String, nowPlayingStationId: String? = nil) {
        guard let interfaceController = self.interfaceController,
              let topTemplate = interfaceController.topTemplate as? CPListTemplate else {
            return
        }
        
        os_log("🚗 CarPlay: Refreshing country station list for '%@' with updated equalizer indicators", log: log, type: .info, country)
        
        let carPlayManager = CarPlayManager.shared
        let stations = carPlayManager.getStations(for: country)
        
        guard shouldUpdateSections(key: "country:\(country)",
                                   data: stations.map(\.id).joined(separator: ",")) else {
            applyStationHighlight()
            return
        }
        
        var stationItems: [CPListItem] = []
        var rows: [(stationId: String, item: CPListItem)] = []
        
        for station in stations {
            let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
            
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
            rows.append((station.id, item))
        }
        registerStationRows(rows, key: "country")
        
        let section = CPListSection(items: stationItems, header: "\(country) Stations (\(stations.count))", sectionIndexTitle: nil)
        
        // Update the sections to reflect the new playing state
        topTemplate.updateSections([section])
        
        os_log("🚗 CarPlay: Successfully refreshed country station list for '%@' with %d stations", log: log, type: .info, country, stations.count)
    }
    
    /// Refresh the stations tab template to show updated radio station highlighting
    /// - Parameter nowPlayingStationId: Optional station ID from notification (preferred over RadioPlayer state)
    private func refreshStationsTabTemplate(nowPlayingStationId: String? = nil) {
        guard let interfaceController = self.interfaceController else {
            os_log("🚗 CarPlay: Cannot refresh stations - no interface controller", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Refreshing stations tab template", log: log, type: .info)
        
        // Get the current root template
        guard let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: Root template is not a tab bar template", log: log, type: .error)
            return
        }
        
        // Find the stations tab (index 1 based on setupRootTemplate order: Recent, Radio, Podcast, Downloads)
        let stationsTabIndex = 1
        if stationsTabIndex < tabBarTemplate.templates.count,
           let stationsTab = tabBarTemplate.templates[stationsTabIndex] as? CPListTemplate {
            
            // Get fresh stations data - use the same structure as createStationsTab()
            let carPlayManager = CarPlayManager.shared
            let favoriteStations = carPlayManager.getFavoriteStations()
            let availableCountries = carPlayManager.getAvailableCountries()
            
            guard shouldUpdateSections(key: "stations",
                                       data: (favoriteStations.map(\.id) + availableCountries).joined(separator: ",")) else {
                applyStationHighlight()
                return
            }
            
            // Create new sections with updated data
            var newSections: [CPListSection] = []
            
            // Favorite stations section
            if !favoriteStations.isEmpty {
                var favoriteStationItems: [CPListItem] = []
                var favoriteRows: [(stationId: String, item: CPListItem)] = []
                for station in favoriteStations {
                    let isCurrentlyPlaying = shouldShowPlayingIndicator(for: station)
                    
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
                    favoriteRows.append((station.id, item))
                }
                registerStationRows(favoriteRows, key: "favorites")
                
                let favoriteSection = CPListSection(items: favoriteStationItems, header: "Favorites", sectionIndexTitle: nil)
                newSections.append(favoriteSection)
            }
            
            // CRITICAL FIX: Add Browse by Country section (same as createStationsTab)
            // This was missing and causing the country list to disappear when refreshing
            if !availableCountries.isEmpty {
                var countryItems: [CPListItem] = []
                for country in availableCountries {
                    let stations = carPlayManager.getStations(for: country)
                    let item = CPListItem(text: country,
                                         detailText: "\(stations.count) stations",
                                         image: carPlayManager.getFlagImage(for: country))
                    item.handler = { [weak self] item, completion in
                        self?.showStationsForCountry(country, completion: completion)
                    }
                    countryItems.append(item)
                }
                
                if !countryItems.isEmpty {
                    let countrySection = CPListSection(items: countryItems, header: "Browse by Country", sectionIndexTitle: nil)
                    newSections.append(countrySection)
                    os_log("🚗 CarPlay: Added country section with %d countries to stations tab", log: self.log, type: .debug, countryItems.count)
                }
            }
            
            if newSections.isEmpty {
                let emptyItem = CPListItem(text: "No Stations", detailText: "Open the phone app to sync your stations")
                let emptySection = CPListSection(items: [emptyItem], header: "Radio", sectionIndexTitle: nil)
                newSections.append(emptySection)
            }
            
            // Update the sections instead of recreating the entire template (prevents black screen)
            stationsTab.updateSections(newSections)
            
            os_log("🚗 CarPlay: Successfully refreshed stations tab with %d sections", log: log, type: .info, newSections.count)
        } else {
            os_log("🚗 CarPlay: Unable to find stations tab to refresh", log: log, type: .error)
        }
    }
    
    /// Refresh the podcast tab template to show newly added podcast feeds
    private func refreshPodcastTabTemplate() {
        guard let interfaceController = self.interfaceController,
              let tabBarTemplate = interfaceController.rootTemplate as? CPTabBarTemplate else {
            os_log("🚗 CarPlay: Unable to refresh podcast tab - no root template found", log: log, type: .error)
            return
        }
        
        // Find the podcast tab (index 2 based on setupRootTemplate order: recents, stations, podcasts, downloads)
        let podcastTabIndex = 2
        guard podcastTabIndex < tabBarTemplate.templates.count,
              let currentPodcastTab = tabBarTemplate.templates[podcastTabIndex] as? CPListTemplate else {
            os_log("🚗 CarPlay: Unable to find podcast tab to refresh", log: log, type: .error)
            return
        }
        
        os_log("🚗 CarPlay: Refreshing podcast tab template with latest data", log: log, type: .info)
        
        // Get updated podcast feeds from CarPlayManager and order them the same as PodcastListView
        let carPlayManager = CarPlayManager.shared
        let allPodcastFeeds = carPlayManager.getPodcastFeeds()
        let podcastViewModel = PodcastViewModel.shared
        
        // Order feeds the same way as PodcastListView using podcastFeedOrder
        let orderedFeedIds = podcastViewModel.podcastFeedOrder
        let feedsById = Dictionary(uniqueKeysWithValues: allPodcastFeeds.map { ($0.id, $0) })
        
        // First add feeds in the user's custom order
        var orderedFeeds: [PodcastFeed] = []
        for feedId in orderedFeedIds {
            if let feed = feedsById[feedId] {
                orderedFeeds.append(feed)
            }
        }
        
        // Then add any remaining feeds that aren't in the custom order (shouldn't happen normally)
        let orderedFeedIds_set = Set(orderedFeedIds)
        let remainingFeeds = allPodcastFeeds.filter { !orderedFeedIds_set.contains($0.id) }
        orderedFeeds.append(contentsOf: remainingFeeds)
        
        var podcastItems: [CPListItem] = []
        for podcast in orderedFeeds {
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
            let emptyItem = CPListItem(text: "No Podcasts", detailText: "Open the phone app to sync your podcasts")
            podcastItems.append(emptyItem)
        }
        
        let podcastSection = CPListSection(items: podcastItems, header: "Your Podcasts", sectionIndexTitle: nil)
        
        // Update the sections instead of recreating the entire template (prevents black screen)
        currentPodcastTab.updateSections([podcastSection])
        
        os_log("🚗 CarPlay: Successfully refreshed podcast tab with %d feeds", log: log, type: .info, orderedFeeds.count)
    }
    
    /// Gentle refresh that only updates visible templates without causing black screens
    private func performGentleRefreshIfVisible(episodeId: String) {
        // Only refresh if we're currently viewing a podcast episode list
        guard let currentTemplate = interfaceController?.topTemplate as? CPListTemplate,
              let currentFeed = currentPodcastFeed,
              currentTemplate.title == currentFeed.title,
              currentFeed.episodes.contains(where: { $0.id == episodeId }) else {
            os_log("🚗 CarPlay: Skipping gentle refresh - not viewing relevant podcast template", log: log, type: .debug)
            return
        }
        
        // Use the most gentle update method - update sections in place rather than recreating the template
        let carPlayManager = CarPlayManager.shared
        carPlayManager.updateContent()
        
        // Update the current template sections without recreating the template (prevents black screen)
        updateCurrentPodcastTemplateSections(for: currentFeed)
        
        os_log("🚗 CarPlay: Completed gentle refresh for episode: %@", log: log, type: .debug, episodeId)
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
        
        // CRITICAL FIX: Reload episodes directly from Core Data to get fresh episode data
        // CarPlayManager's feeds have empty episode arrays (loaded on-demand), so we must load from Core Data
        os_log("🚗 CarPlay: Reloading episodes from Core Data for feed '%@'", log: log, type: .info, currentFeed.title)
        
        // Load episodes synchronously from Core Data
        let context = CoreDataStack.shared.context
        var reloadedEpisodes: [PodcastEpisode] = []
        
        context.performAndWait {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "feedId == %@", currentFeed.id)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
            
            do {
                let managedEpisodes = try context.fetch(fetchRequest)
                reloadedEpisodes = managedEpisodes.map { $0.toPodcastEpisode() }
                os_log("🚗 CarPlay: Reloaded %d episodes from Core Data for feed '%@'", log: self.log, type: .info, reloadedEpisodes.count, currentFeed.title)
            } catch {
                os_log("🚗 CarPlay: Failed to reload episodes from Core Data: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
        
        guard !reloadedEpisodes.isEmpty else {
            os_log("🚗 CarPlay: No episodes found in Core Data for feed '%@'", log: log, type: .error, currentFeed.title)
            return
        }
        
        // Create updated feed with fresh episodes
        var updatedFeed = currentFeed
        updatedFeed.episodes = reloadedEpisodes
        
        os_log("🚗 CarPlay: Reloaded feed '%@' - now has %d episodes (was %d)", log: log, type: .info, updatedFeed.title, updatedFeed.episodes.count, currentFeed.episodes.count)
        
        // Update the current feed reference with fresh data
        currentPodcastFeed = updatedFeed
        
        // Get the currently playing episode to determine if we need to update this feed
        let currentPlayingEpisodeId = PodcastPlayer.shared.currentEpisode?.id
        
        // Check if the currently playing episode is in this feed OR if any episode in this feed was previously playing
        // This ensures we update when switching between episodes within the same podcast
        let shouldUpdate = currentPlayingEpisodeId == nil || 
                          updatedFeed.episodes.contains(where: { $0.id == currentPlayingEpisodeId }) ||
                          updatedFeed.episodes.contains(where: { $0.id == episodeId })
        
        if !shouldUpdate {
            os_log("🚗 CarPlay: No episodes in current feed need section update", log: log, type: .debug)
            return
        }
        
        os_log("🚗 CarPlay: Updating sections for podcast '%@' - current playing: %@, notification episode: %@", log: log, type: .info, updatedFeed.title, currentPlayingEpisodeId ?? "none", episodeId)
        
        // Use the same efficient section update approach that works perfectly for Recents
        // Reset the updating flag to ensure this critical update goes through
        isUpdatingTemplate = false
        
        // Use immediate section updates with FRESH feed data - same approach as Recents tab which works perfectly
        updateCurrentPodcastTemplateSections(for: updatedFeed)
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
        var allEpisodeRows: [(episodeId: String, item: CPListItem)] = []
        
        // Get current playing state directly from PodcastPlayer for real-time accuracy
        let currentPlayingEpisodeId = PodcastPlayer.shared.currentEpisode?.id
        let isPlayerPlaying = PodcastPlayer.shared.isPlaying
        
        guard shouldUpdateSections(key: "episodes:\(podcast.id)",
                                   data: podcast.episodes.map { "\($0.id):\(EpisodeStateManager.shared.getState(for: $0.id))" }.joined(separator: ",")) else {
            applyEpisodeHighlight()
            return
        }
        
        os_log("🚗 CarPlay: Current playing episode ID: %@, player is playing: %@", log: log, type: .info, currentPlayingEpisodeId ?? "none", isPlayerPlaying ? "YES" : "NO")
        
        for episode in podcast.episodes {
            let duration = formatDuration(episode.duration)
            var statusText = ""
            
            // Get playing state directly from PodcastPlayer for real-time accuracy
            let isCurrentlyPlaying = currentPlayingEpisodeId == episode.id && isPlayerPlaying
            
            if isCurrentlyPlaying {
                os_log("🚗 CarPlay: Episode '%@' is currently playing - will show highlighting", log: log, type: .info, episode.title)
            }
            
            // CRITICAL FIX: Get fresh state from EpisodeStateManager instead of stale episode.state
            // This ensures we always show the correct status and highlighting
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let episodeProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
            let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            let isPlayed = (episodeState == .played)
            
            // Determine episode status based on state and current playback
            if isCurrentlyPlaying {
                statusText = " • Playing"
            } else if isPlayed {
                statusText = " • Complete"
            } else if episodeProgress > 0 {
                statusText = " • IN PROGRESS"
            }
            
            // Add download indicator
            if isDownloaded {
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
            allEpisodeRows.append((episode.id, item))
        }
        registerEpisodeRows(allEpisodeRows, key: "episodes")
        
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
        os_log("🚗 CarPlay: Loading ALL episodes for podcast '%@' (closed app compatible)", log: log, type: .info, podcastFeed.title)
        
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                // CRITICAL FIX: Respect maxEpisodes limit to prevent loading too many episodes
                if let maxEpisodes = podcastFeed.maxEpisodes, maxEpisodes > 0 {
                    episodeRequest.fetchLimit = maxEpisodes
                    os_log("🚗 CarPlay: Applying episode limit of %d for feed '%@'", log: self.log, type: .info, maxEpisodes, podcastFeed.title)
                }
                
                let managedEpisodes = try context.fetch(episodeRequest)
                
                // CRITICAL: Ensure EpisodeStateManager is available before conversion
                // This guarantees episode states work even when main app is closed
                var episodes: [PodcastEpisode] = []
                var filteredCount = 0
                
                for managedEpisode in managedEpisodes {
                    // VALIDATION: Skip episodes with invalid data (0 duration, empty title, empty audio URL)
                    guard managedEpisode.duration > 0,
                          let title = managedEpisode.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let audioUrl = managedEpisode.audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        filteredCount += 1
                        os_log("🚗 CarPlay: FILTERED invalid episode - duration: %.1f, title: '%@'", log: self.log, type: .debug, managedEpisode.duration, managedEpisode.title ?? "nil")
                        continue
                    }
                    
                    // Convert using the standard method which handles EpisodeStateManager access
                    var episode = managedEpisode.toPodcastEpisode()
                    
                    // FALLBACK: If EpisodeStateManager fails, use Core Data values directly
                    // This ensures episodes are always accessible in CarPlay
                    if episode.state.progress == 0 && managedEpisode.progress > 0 {
                        episode.state.progress = managedEpisode.progress
                        os_log("🚗 CarPlay: Using Core Data fallback progress for episode '%@': %.2f%%", log: self.log, type: .debug, episode.title, managedEpisode.progress * 100)
                    }
                    
                    episodes.append(episode)
                }
                
                if filteredCount > 0 {
                    os_log("🚗 CarPlay: Filtered out %d invalid episodes (0 duration or empty data)", log: self.log, type: .info, filteredCount)
                }
                
                os_log("🚗 CarPlay: Successfully loaded %d valid episodes for podcast '%@' (filtered: %d)", log: self.log, type: .info, episodes.count, podcastFeed.title, filteredCount)
                
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
        os_log("🚗 CarPlay: Loading initial %d episodes for podcast '%@' (closed app compatible)", log: log, type: .info, limit, podcastFeed.title)
        
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                // CRITICAL FIX: Respect maxEpisodes limit if it's lower than the requested limit
                let effectiveLimit: Int
                if let maxEpisodes = podcastFeed.maxEpisodes, maxEpisodes > 0 {
                    effectiveLimit = min(limit, maxEpisodes)
                    os_log("🚗 CarPlay: Applying effective limit of %d (requested: %d, max: %d)", log: self.log, type: .info, effectiveLimit, limit, maxEpisodes)
                } else {
                    effectiveLimit = limit
                }
                
                episodeRequest.fetchLimit = effectiveLimit
                
                let managedEpisodes = try context.fetch(episodeRequest)
                
                // CRITICAL: Ensure EpisodeStateManager is available before conversion
                // This guarantees episode states work even when main app is closed
                var episodes: [PodcastEpisode] = []
                var filteredCount = 0
                
                for managedEpisode in managedEpisodes {
                    // VALIDATION: Skip episodes with invalid data (0 duration, empty title, empty audio URL)
                    guard managedEpisode.duration > 0,
                          let title = managedEpisode.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let audioUrl = managedEpisode.audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        filteredCount += 1
                        os_log("🚗 CarPlay: FILTERED invalid episode - duration: %.1f, title: '%@'", log: self.log, type: .debug, managedEpisode.duration, managedEpisode.title ?? "nil")
                        continue
                    }
                    
                    // Convert using the standard method which handles EpisodeStateManager access
                    var episode = managedEpisode.toPodcastEpisode()
                    
                    // FALLBACK: If EpisodeStateManager fails, use Core Data values directly
                    // This ensures episodes are always accessible in CarPlay
                    if episode.state.progress == 0 && managedEpisode.progress > 0 {
                        episode.state.progress = managedEpisode.progress
                        os_log("🚗 CarPlay: Using Core Data fallback progress for episode '%@': %.2f%%", log: self.log, type: .debug, episode.title, managedEpisode.progress * 100)
                    }
                    
                    episodes.append(episode)
                }
                
                if filteredCount > 0 {
                    os_log("🚗 CarPlay: Filtered out %d invalid episodes from initial load (0 duration or empty data)", log: self.log, type: .info, filteredCount)
                }
                
                os_log("🚗 CarPlay: Successfully loaded initial %d valid episodes for podcast '%@' (filtered: %d)", log: self.log, type: .info, episodes.count, podcastFeed.title, filteredCount)
                
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
    

    
    /// Get total VALID episode count from CoreData (excludes 0-duration and invalid episodes)
    /// CRITICAL FIX: Only counts episodes that will actually be displayed after validation
    private func getEpisodeCount(for podcastFeed: PodcastFeed, completion: @escaping (Int) -> Void) {
        let context = CoreDataStack.shared.context
        
        context.perform {
            do {
                let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                
                // Apply maxEpisodes limit if set
                if let maxEpisodes = podcastFeed.maxEpisodes, maxEpisodes > 0 {
                    episodeCountRequest.fetchLimit = maxEpisodes
                    episodeCountRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                }
                
                // Fetch episodes to validate them (more accurate than simple count)
                let managedEpisodes = try context.fetch(episodeCountRequest)
                
                // Count only valid episodes (same validation as loading)
                var validCount = 0
                for managedEpisode in managedEpisodes {
                    // Apply same validation as loadEpisodesForPodcast
                    if managedEpisode.duration > 0,
                       let title = managedEpisode.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let audioUrl = managedEpisode.audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        validCount += 1
                    }
                }
                
                let totalCount = managedEpisodes.count
                let filteredCount = totalCount - validCount
                
                if filteredCount > 0 {
                    os_log("🚗 CarPlay: Episode count for '%@': %d valid (filtered %d invalid)", log: self.log, type: .info, podcastFeed.title, validCount, filteredCount)
                }
                
                DispatchQueue.main.async {
                    completion(validCount)
                }
                
            } catch {
                os_log("🚗 CarPlay: Error counting episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                
                DispatchQueue.main.async {
                    completion(0)
                }
            }
        }
    }
    
    /// Get total VALID episode count from CoreData synchronously (excludes 0-duration and invalid episodes)
    /// CRITICAL FIX: Only counts episodes that will actually be displayed after validation
    private func getEpisodeCountSync(for podcastFeed: PodcastFeed) -> Int {
        let context = CoreDataStack.shared.context
        var validCount = 0
        
        context.performAndWait {
            do {
                let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", podcastFeed.id)
                
                // Apply maxEpisodes limit if set
                if let maxEpisodes = podcastFeed.maxEpisodes, maxEpisodes > 0 {
                    episodeCountRequest.fetchLimit = maxEpisodes
                    episodeCountRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                }
                
                // Fetch episodes to validate them (more accurate than simple count)
                let managedEpisodes = try context.fetch(episodeCountRequest)
                
                // Count only valid episodes (same validation as loading)
                for managedEpisode in managedEpisodes {
                    // Apply same validation as loadEpisodesForPodcast
                    if managedEpisode.duration > 0,
                       let title = managedEpisode.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let audioUrl = managedEpisode.audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        validCount += 1
                    }
                }
                
            } catch {
                os_log("🚗 CarPlay: Error counting episodes for podcast '%@': %@", log: self.log, type: .error, podcastFeed.title, error.localizedDescription)
                validCount = 0
            }
        }
        
        return validCount
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
                        radioPlayer.iTunesArtworkJustSet = true
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
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
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
    
    // MARK: - Interface Refresh
    
    /// Refreshes the CarPlay interface to update artwork after async loading
    private func refreshCarPlayInterface() {
        guard let interfaceController = interfaceController else { return }
        
        // Refresh the root template to update artwork
        DispatchQueue.main.async {
            self.setupRootTemplate()
        }
    }
    
} 
