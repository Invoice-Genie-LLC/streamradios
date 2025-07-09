//
//  PodcastPlayer.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/9/24.
//

import AVFoundation
import Combine
import MediaPlayer
import os
import Reachability
import SwiftUI

// Connection state for podcast player
enum PodcastConnectionState {
    case connected
    case connecting
    case disconnected
    case buffering
    case error
}

class PodcastPlayer: ObservableObject, AudioPlayerProtocol {
    @Published var currentEpisode: PodcastEpisode?
    @Published var isPlaying: Bool = false
    @Published var userWantsToPlay: Bool = false  // CRITICAL: Persistent user intent flag like RadioPlayer
    @Published var loadingEpisodeId: String? = nil  // Track which episode is currently loading
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0.01
    @Published var currentFeed: PodcastFeed?
    @Published var currentProgress: Double = 0
    @Published var connectionState: PodcastConnectionState = .disconnected
    static let shared = PodcastPlayer()
    weak var radioPlayer: RadioPlayer?
    var player: AVPlayer?
    private let saveThreshold: Double = 0.05
    private var lastSavedProgress: Double = 0.0
    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastPlayer")
    weak var viewModel: PodcastViewModel?
    private var reachability: Reachability?
    @Published var isAttemptingReconnection: Bool = false
    private var reconnectionTimer: Timer?
    private let maxReconnectionAttempts = 5
    private var currentReconnectionAttempt = 0
    private var remoteCommandCenter: MPRemoteCommandCenter?
    @Published var currentEpisodeIndex: Int?
    private var allEpisodesInFeed: [PodcastEpisode] = []
    @Published var isPodcastActive: Bool = false
    private var nowPlayingUpdateTimer: Timer?
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 2.0
    private var lastReportedProgress: Double = 0
    private let stateManager = EpisodeStateManager.shared
    private var shouldStartFromBeginning: Bool = false
    private var lastCarPlayProgress: Double?
    
    // Track if position has been restored to prevent repeated calls during scrolling
    private var hasRestoredPositionForCurrentEpisode: Bool = false
    private var currentEpisodeIdForRestoration: String?

    // MARK: - Performance Optimization Properties
    private var isUserScrolling = false
    private var scrollDetectionTimer: Timer?
    private var lastScrollNotificationTime = Date()
    
    // Optimized update intervals for better performance
    private let lightUpdateInterval: TimeInterval = 1.0  // Set to 1.0s for smooth elapsed time display
    private let heavyUpdateInterval: TimeInterval = 15.0 // Increased from 10.0s to 15.0s to reduce CPU usage
    private let scrollingPauseInterval: TimeInterval = 30.0 // Pause heavy updates longer during scrolling

    // Performance optimization flags
    private var isCarPlayActive: Bool {
        return CarPlayManager.shared.isCarPlayConnected
    }

    var remainingTime: Double {
            max(0, duration - currentTime)
        }
    
    private init() {
        setupAudioSession()
               setupReachability()
               setupRemoteCommandCenter()
               // setupInterruptionHandling() - REMOVED: Now handled in setupCarPlayRouteChangeHandling
               setupTerminationHandling()
               setupCarPlayRouteChangeHandling()
       }
    
    private func setupAudioSession() {
        // Audio session is now managed centrally by PlaybackManager
        // This method is kept for backward compatibility
        print("✅ Podcast: Audio session management delegated to PlaybackManager")
    }
    
    private func setupReachability() {
           do {
               reachability = try Reachability()
               reachability?.whenReachable = { [weak self] reachability in
                   os_log("🌐 PodcastPlayer: Network became reachable", log: self?.log ?? OSLog.default, type: .info)
                   self?.handleNetworkReconnection()
               }
               reachability?.whenUnreachable = { [weak self] _ in
                   os_log("🌐 PodcastPlayer: Network became unreachable", log: self?.log ?? OSLog.default, type: .info)
                   self?.handleNetworkDisconnection()
               }
               try reachability?.startNotifier()
           } catch {
               os_log("Unable to start reachability notifier: %@", log: log, type: .error, error.localizedDescription)
           }
       }
       
           private func handleNetworkDisconnection() {
        os_log("🌐 PodcastPlayer: Handling network disconnection", log: log, type: .info)
        
        // Stop any ongoing reconnection attempts
        stopReconnectionAttempts()
        
        // Pause playback if we're playing from a remote URL (not local file)
        if isPlaying && userWantsToPlay {
            if let currentEpisode = currentEpisode {
                // Check if we're playing from a local file (offline) or streaming
                let isPlayingLocalFile = currentEpisode.localFilePath != nil && !currentEpisode.localFilePath!.isEmpty
                if !isPlayingLocalFile {
                    os_log("🌐 PodcastPlayer: Network lost during streaming, pausing playback", log: log, type: .info)
                    player?.pause()
                    isPlaying = false
                    // Keep userWantsToPlay = true so we can resume when network returns
                    // Show connecting state to indicate we're waiting to reconnect (spinning button)
                    connectionState = .connecting
                } else {
                    os_log("🌐 PodcastPlayer: Network lost but playing local file, continuing playback", log: log, type: .info)
                    // For local files, we can continue playing even without network
                    connectionState = .connected
                }
            }
        } else if userWantsToPlay && currentEpisode != nil {
            // User wants to play but isn't currently playing - show connecting state (spinning button)
            os_log("🌐 PodcastPlayer: Network lost while user wants to play, showing connecting state", log: log, type: .info)
            connectionState = .connecting
        } else {
            // User doesn't want to play or no episode - show disconnected state
            connectionState = .disconnected
        }
    }
    
    // REMOVED: Old setupInterruptionHandling - now handled in setupCarPlayRouteChangeHandling with better CarPlay support
    
    private func setupTerminationHandling() {
        // Listen for app termination notifications
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.willTerminateNotification,
                                             object: nil)
        
        // Also listen for when app goes to background (force close might trigger this first)
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.didEnterBackgroundNotification,
                                             object: nil)
        
        // Listen for when app resigns active state
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.willResignActiveNotification,
                                             object: nil)
    }
    
    private func setupCarPlayRouteChangeHandling() {
        // Listen for audio session route changes (CarPlay connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // CRITICAL: Handle audio interruptions to prevent CarPlay disconnection from pausing podcast
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        print("🚗 PodcastPlayer: CarPlay route change and audio interruption monitoring setup complete")
    }
    
    // REMOVED: Old handleInterruption method replaced with handleAudioInterruption for better CarPlay support
    
    @objc private func handleAppTermination(notification: Notification) {
        // Handle different app lifecycle events to ensure progress is saved
        os_log("App lifecycle event detected: %@", log: log, type: .info, notification.name.rawValue)
        
        if notification.name == UIApplication.willTerminateNotification ||
           notification.name == UIApplication.didEnterBackgroundNotification ||
           notification.name == UIApplication.willResignActiveNotification {
            
            // Ensure progress is saved when app is force closed or goes to background
            handleAppWillTerminate()
            
            // Additional safety: Force save to UserDefaults
            UserDefaults.standard.synchronize()
        }
    }
    
    /// Handles audio session route changes to detect CarPlay connection/disconnection
    @objc private func audioSessionRouteChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let _ = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        
        // Check if CarPlay is in the current route
        let isCarPlayCurrentlyConnected = currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
        
        let wasCarPlayConnected = CarPlayManager.shared.isCarPlayConnected
        
        // CARPLAY CONNECTION DETECTION
        if isCarPlayCurrentlyConnected && !wasCarPlayConnected {
            print("🚗 PodcastPlayer: CarPlay CONNECTED - enhancing experience")
            CarPlayManager.shared.isCarPlayConnected = true
        }
        
        // CARPLAY DISCONNECTION DETECTION - CRITICAL FIX
        else if !isCarPlayCurrentlyConnected && wasCarPlayConnected {
            print("🚗 PodcastPlayer: CarPlay DISCONNECTED - ensuring seamless transition to main app")
            CarPlayManager.shared.isCarPlayConnected = false
            
            // CRITICAL: Ensure seamless playback transition when CarPlay disconnects
            if player != nil && currentEpisode != nil {
                let wasPlayingBeforeDisconnect = isPlaying || player?.timeControlStatus == .playing
                print("🔄 CarPlay Disconnect: Podcast was playing: \(wasPlayingBeforeDisconnect)")
                
                // AGGRESSIVE: Always try to maintain podcast playback during CarPlay disconnection
                // Even if it wasn't playing, if there's a current episode, keep it visible
                print("🔄 CarPlay Disconnect: Ensuring seamless podcast transition to main app")
                
                // IMMEDIATE: Force audio session to remain active and continue playback
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // CRITICAL: Set podcast as active player FIRST to maintain UI visibility
                    PlaybackManager.shared.setActivePlayer(.podcast)
                    print("🚗 CarPlay Disconnect: Set podcast as active player immediately")
                    
                    // Aggressively maintain audio session for seamless transition
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: [])
                        print("✅ CarPlay Disconnect: Audio session kept active for main app podcast")
                    } catch {
                        print("⚠️ CarPlay Disconnect: Failed to maintain audio session: \(error)")
                    }
                    
                    // CRITICAL: Force player to continue/resume playback if it was playing
                    if wasPlayingBeforeDisconnect {
                        if self.player?.timeControlStatus != .playing {
                            print("🔄 CarPlay Disconnect: Force resuming podcast playback in main app")
                            self.player?.play()
                        }
                        
                        // AGGRESSIVE: Ensure isPlaying state is correct and maintained
                        self.isPlaying = true
                    }
                    
                    // Force update Now Playing info for main app immediately
                    self.updateNowPlayingInfo()
                    
                    // Force UI refresh to show podcast player
                    self.objectWillChange.send()
                    
                    print("✅ CarPlay Disconnect: Aggressive podcast transition to main app completed")
                }
                
                // BACKUP: Multiple checks to ensure everything is maintained
                for delay in [0.3, 0.8, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        
                        // Ensure PlaybackManager still has podcast as active player
                        if PlaybackManager.shared.activePlayer != .podcast && self.currentEpisode != nil {
                            print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Restoring podcast as active player")
                            PlaybackManager.shared.setActivePlayer(.podcast)
                        }
                        
                        // Resume playback if it was playing and got stopped
                        if wasPlayingBeforeDisconnect && self.player?.timeControlStatus != .playing && self.currentEpisode != nil {
                            print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Force resuming podcast playback")
                            self.player?.play()
                            self.isPlaying = true
                        }
                        
                        // Ensure UI state is maintained for current episode
                        if self.currentEpisode != nil && PlaybackManager.shared.activePlayer == .podcast {
                            if wasPlayingBeforeDisconnect && !self.isPlaying {
                                print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Restoring playing state")
                                self.isPlaying = true
                                self.objectWillChange.send()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func handleNetworkReconnection() {
        // Only attempt reconnection if the user wants to play and we have an episode
        guard userWantsToPlay, let currentEpisode = currentEpisode else {
            os_log("Network reconnection skipped - user doesn't want to play or no current episode", log: log, type: .info)
            connectionState = .connected
            return
        }
        
        // Check if we're playing from a remote URL (not local file)
        let isPlayingLocalFile = currentEpisode.localFilePath != nil && !currentEpisode.localFilePath!.isEmpty
        
        // If we're not currently playing and not playing a local file, attempt to resume
        if !isPlaying && !isPlayingLocalFile {
            os_log("🌐 PodcastPlayer: Network reconnected, attempting to resume streaming playback", log: log, type: .info)
            connectionState = .connecting
            isAttemptingReconnection = true
            currentReconnectionAttempt = 0
            attemptReconnection()
        } else if isPlayingLocalFile {
            os_log("🌐 PodcastPlayer: Network reconnected, local file playback continuing", log: log, type: .info)
            connectionState = .connected
        } else {
            // Already playing, just update state
            connectionState = .connected
        }
    }
    
    private func attemptReconnection() {
        guard currentReconnectionAttempt < maxReconnectionAttempts else {
            stopReconnectionAttempts()
            return
        }
        
        guard let currentEpisode = currentEpisode else {
            os_log("No current episode available for reconnection", log: log, type: .error)
            stopReconnectionAttempts()
            return
        }
        
        currentReconnectionAttempt += 1
        os_log("🔄 PodcastPlayer: Attempting reconnection %d of %d for episode: %@", 
               log: log, type: .info, currentReconnectionAttempt, maxReconnectionAttempts, currentEpisode.title)
        
        // Try to resume playback
        play()
        
        // Check if reconnection was successful after a delay
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.checkReconnectionStatus()
        }
    }
    
    private func checkReconnectionStatus() {
        if player?.timeControlStatus == .playing && isPlaying {
            os_log("✅ PodcastPlayer: Network reconnection successful", log: log, type: .info)
            connectionState = .connected
            stopReconnectionAttempts()
        } else {
            os_log("⚠️ PodcastPlayer: Reconnection attempt failed, trying again...", log: log, type: .info)
            attemptReconnection()
        }
    }
    
    private func stopReconnectionAttempts() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        isAttemptingReconnection = false
        currentReconnectionAttempt = 0
        
        if player?.timeControlStatus != .playing {
            os_log("❌ PodcastPlayer: Failed to reconnect after %d attempts", log: log, type: .error, maxReconnectionAttempts)
            connectionState = .error
            // Don't clear userWantsToPlay so they can try again manually
        } else {
            connectionState = .connected
        }
    }
    
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.play()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.pause()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipToNextEpisode()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipToPreviousEpisode()
                return .success
            }
            return .commandFailed
        }
        
        // Enable skip forward command (for seeking within episodes)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 15)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipForward()
                return .success
            }
            return .commandFailed
        }
        
        // Enable skip backward command (for seeking within episodes)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipBackward()
                return .success
            }
            return .commandFailed
        }
        
        // CRITICAL: Enable toggle play/pause command for CarPlay
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.togglePlayPause()
                os_log("Remote Command: Toggle play/pause executed", log: self?.log ?? OSLog.default, type: .info)
                return .success
            }
            return .commandFailed
        }
        
        // Disable commands that don't make sense for podcasts
        commandCenter.stopCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        
        os_log("Podcast Remote Command Center configured for CarPlay", log: log, type: .info)
    }
    
    private func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
            guard let viewModel = viewModel else {
                os_log("ViewModel is not set", log: log, type: .error)
                return
            }
            
            Task { @MainActor in
                allEpisodesInFeed = viewModel.allEpisodes.filter { $0.feedId == feed.id }
                allEpisodesInFeed.sort { $0.publicationDate > $1.publicationDate } // Sort by newest first
                os_log("Loaded %d episodes for feed: %{public}@", log: log, type: .info, allEpisodesInFeed.count, feed.title)
                
                // Verify that all episodes are loaded
                if allEpisodesInFeed.isEmpty {
                    os_log("No episodes loaded for feed. Attempting to fetch episodes.", log: log, type: .error)
                    Task { @MainActor in
                        fetchEpisodesForFeed(feed)
                    }
                }
            }
        }
    
    private func fetchEpisodesForFeed(_ feed: PodcastFeed) {
            Task { @MainActor in
                viewModel?.fetchEpisodes(for: feed) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let episodes):
                        self.allEpisodesInFeed = episodes.sorted { $0.publicationDate > $1.publicationDate }
                        os_log("Fetched and sorted %d episodes for feed: %{public}@", log: self.log, type: .info, self.allEpisodesInFeed.count, feed.title)
                        DispatchQueue.main.async {
                            self.objectWillChange.send()
                        }
                    case .failure(let error):
                        os_log("Failed to fetch episodes: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    }
                }
            }
        }
    
    func skipToNextEpisode() {
            os_log("Attempting to skip to next episode", log: log, type: .info)
            guard let currentIndex = currentEpisodeIndex else {
                os_log("Current episode index is nil", log: log, type: .error)
                return
            }
            
            os_log("Current episode index: %d", log: log, type: .info, currentIndex)
            os_log("Total episodes in feed: %d", log: log, type: .info, allEpisodesInFeed.count)
            
            let nextIndex = currentIndex + 1
            guard nextIndex < allEpisodesInFeed.count else {
                os_log("Already at the last episode", log: log, type: .info)
                return
            }
            
            let nextEpisode = allEpisodesInFeed[nextIndex]
            os_log("Skipping to next episode: %{public}@", log: log, type: .info, nextEpisode.title)
            playEpisode(nextEpisode, feed: currentFeed!)
        }
    
    func skipToPreviousEpisode() {
            os_log("Attempting to skip to previous episode", log: log, type: .info)
            guard let currentIndex = currentEpisodeIndex else {
                os_log("Current episode index is nil", log: log, type: .error)
                return
            }
            
            os_log("Current episode index: %d", log: log, type: .info, currentIndex)
            os_log("Total episodes in feed: %d", log: log, type: .info, allEpisodesInFeed.count)
            
            let previousIndex = currentIndex - 1
            guard previousIndex >= 0 else {
                os_log("Already at the first episode", log: log, type: .info)
                return
            }
            
            let previousEpisode = allEpisodesInFeed[previousIndex]
            os_log("Skipping to previous episode: %{public}@", log: log, type: .info, previousEpisode.title)
            playEpisode(previousEpisode, feed: currentFeed!)
        }
    
    private func changeToEpisode(_ episode: PodcastEpisode, in feed: PodcastFeed) {
        os_log("Changing to episode: %@", log: log, type: .info, episode.title)
        saveProgressIfNeeded() // Save progress of the current episode
        playEpisode(episode, feed: feed)
        updateNowPlayingInfo()
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    
    // PERFORMANCE: Optimized for better threading and Main Thread safety
    private func updatePlaybackInfo() {
        guard let player = player else { return }
        
        // Skip all updates if user is scrolling to prevent CPU spikes
        if isUserScrolling {
            return
        }
        
        // MAIN THREAD FIX: Check app state on main thread to prevent violations
        Task { @MainActor in
            // Skip updates if app is in background to save battery
            guard UIApplication.shared.applicationState == .active else { return }
            
            // Heavy operations only (time updates are handled separately in updateCurrentTimeOnly())
            // OPTIMIZE: Only update progress every 10 seconds to minimize CPU usage
            Task {
                await self.updateProgressThrottled()
            }
            
            // OPTIMIZE: Update Now Playing info very infrequently (every 5s)
            self.updateNowPlayingInfoDebounced()
        }
    }
    
    // PERFORMANCE: Async throttled progress update method
    private func updateProgressThrottled() async {
        // OPTIMIZE: Only update progress every 15 seconds during playback to drastically reduce CPU usage
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) < heavyUpdateInterval {
            return
        }
        lastProgressUpdate = now
        
        await updateProgress()
    }
    
    // Track last progress update time
    private var lastProgressUpdate = Date()
    
    // PERFORMANCE: Removed old method, now using isUserScrolling property directly
    
    func rewindAndPlay(episode: PodcastEpisode) {
        // IMMEDIATE USER FEEDBACK: Set loading state as soon as user taps rewind and play
        loadingEpisodeId = episode.id
        
        // Find the correct feed for this episode
        Task { @MainActor in
            guard let feed = viewModel?.podcastFeeds.first(where: { $0.id == episode.feedId }) else {
                os_log("Feed not found for episode: %@", log: log, type: .error, episode.title)
                return
            }
            
            self.performRewindAndPlay(episode: episode, feed: feed)
        }
    }
    
    private func performRewindAndPlay(episode: PodcastEpisode, feed: PodcastFeed) {
        
        if currentEpisode?.id == episode.id {
            // Same episode - rewind to beginning and play
            seek(to: 0)
            currentTime = 0
            currentProgress = 0
            
            // Reset progress in view model by updating cache directly
            Task { @MainActor in
                viewModel?.episodeProgress[episode.id] = 0.0
                
                // Update episode state to not played and reset progress
                viewModel?.updateEpisodeState(episode.id, progress: 0.0, isPlayed: false)
            }
            
            // Update state manager
            stateManager.rewindAndPlay(episodeId: episode.id)
            
            // Start playing
            play()
            
            os_log("Rewound and playing episode: %@", log: log, type: .info, episode.title)
        } else {
            // Different episode - load it and start from beginning
            shouldStartFromBeginning = true
            playEpisode(episode, feed: feed)
            os_log("Loaded new episode and playing from beginning: %@", log: log, type: .info, episode.title)
        }
        
        isPlaying = true
        
        // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
        // UI will update naturally through other mechanisms
    }
    
    func configure(with viewModel: PodcastViewModel) {
        self.viewModel = viewModel
    }
    
    func setRadioPlayer(_ player: RadioPlayer) {
        self.radioPlayer = player
    }
    
    func handleNavigationAway() {
            if let currentEpisode = currentEpisode, isPlaying {
                // Save current progress immediately
                saveProgressIfNeeded()
                
                // Update episode state to reflect "In Progress"
                var updatedEpisode = currentEpisode
                let progress = currentTime / duration
                updatedEpisode.state.progress = progress
                
                // Save to CloudKit when user navigates away
                saveProgressToCloudKit(for: currentEpisode, progress: progress, reason: "user navigated away from episode")
                
                // Preserve existing "finished" status - only mark as finished if progress >= 0.99
                // but don't unmark episodes that were already marked as finished
                if progress >= 0.99 {
                    updatedEpisode.state.isPlayed = true
                } else if !currentEpisode.state.isPlayed {
                    // Only update isPlayed to false if it wasn't already marked as finished
                    updatedEpisode.state.isPlayed = false
                }
                
                // Update the episode in ViewModel
                Task { @MainActor in
                    let isPlayed = progress >= 0.99 ? true : (currentEpisode.state.isPlayed ? true : false)
                    viewModel?.updateEpisodeState(currentEpisode.id, progress: progress, isPlayed: isPlayed)
                }
                
                // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
                
                os_log("Updated episode status on navigation away: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, progress)
            }
        }
    
    func ensureProgressTracking(for episode: PodcastEpisode) {
        // If this episode was ever played, ensure it shows as "In Progress"
        if currentEpisode?.id == episode.id && currentTime > 0 {
            let progress = currentTime / duration
            if progress > 0 && progress < 0.99 {
                Task { @MainActor in
                    // Update cache directly without triggering CloudKit saves
                    viewModel?.episodeProgress[episode.id] = progress
                    
                    // Update the episode state
                    let isPlayed = episode.state.isPlayed ? true : false
                    viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: isPlayed)
                }
                
                // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
            }
        }
    }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        // IMMEDIATE USER FEEDBACK: Set loading state as soon as user taps play
        loadingEpisodeId = episode.id
        
        // CRITICAL: Set user intent to play podcast (like RadioPlayer)
        userWantsToPlay = true
        
        // Reset position restoration flag for the new episode
        hasRestoredPositionForCurrentEpisode = false
        currentEpisodeIdForRestoration = nil
        
        // Reset network state when loading a new episode
        resetNetworkState()
        
        // Completely stop radio playback to prevent it from getting stuck in "connecting" state
        RadioPlayer.shared.stop()
        
        // If there's a currently playing episode, mark it as "In Progress" before switching
        if let currentEpisode = currentEpisode, currentEpisode.id != episode.id {
            // Get the most accurate current time from the player
            let actualCurrentTime = player?.currentItem?.currentTime().seconds ?? currentTime
            let actualDuration = player?.currentItem?.duration.seconds ?? duration
            
            // Calculate progress with the most up-to-date values
            let currentProgress = actualDuration > 0 ? actualCurrentTime / actualDuration : 0
            
            // Update our internal state to match the actual player state
            if actualCurrentTime.isFinite && actualCurrentTime >= 0 {
                currentTime = actualCurrentTime
            }
            if actualDuration.isFinite && actualDuration > 0 {
                duration = actualDuration
            }
            
            // Save progress immediately when switching episodes
            saveProgressForEpisodeSwitch(currentEpisode, progress: currentProgress, actualTime: actualCurrentTime)
            
            stateManager.switchToEpisode(
                newEpisodeId: episode.id,
                previousEpisodeId: currentEpisode.id,
                previousProgress: currentProgress
            )
        }
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Load all episodes for the feed
        loadAllEpisodesForFeed(feed)
        
        var playUrl: URL?
        
        // Debug logging for offline playback
        print("🔍 DEBUG: Attempting to play episode: \(episode.title)")
        print("🔍 DEBUG: Episode localFilePath: \(episode.localFilePath ?? "nil")")
        print("🔍 DEBUG: Episode audioUrl: \(episode.audioUrl)")
        print("🔍 DEBUG: Episode isDownloaded: \(episode.state.isDownloaded)")
        print("🔍 DEBUG: Episode fileSize: \(episode.fileSize ?? 0)")
        
        os_log("🔍 DEBUG: Attempting to play episode: %@", log: log, type: .info, episode.title)
        os_log("🔍 DEBUG: Episode localFilePath: %@", log: log, type: .info, episode.localFilePath ?? "nil")
        os_log("🔍 DEBUG: Episode audioUrl: %@", log: log, type: .info, episode.audioUrl)
        os_log("🔍 DEBUG: Episode isDownloaded: %@", log: log, type: .info, episode.state.isDownloaded ? "true" : "false")
        
        if let localFilePath = episode.localFilePath, !localFilePath.isEmpty {
            let fileExists = FileManager.default.fileExists(atPath: localFilePath)
            os_log("🔍 DEBUG: Local file exists at path '%@': %@", log: log, type: .info, localFilePath, fileExists ? "YES" : "NO")
            
            if fileExists {
                playUrl = URL(fileURLWithPath: localFilePath)
                os_log("✅ DEBUG: Using local file for offline playback: %@", log: log, type: .info, localFilePath)
            } else {
                os_log("❌ DEBUG: Local file not found, falling back to streaming", log: log, type: .error)
            }
        } else {
            os_log("🔍 DEBUG: No local file path available, using streaming URL", log: log, type: .info)
        }
        
        if playUrl == nil {
            if let url = URL(string: episode.audioUrl) {
                playUrl = url
                os_log("🔍 DEBUG: Using streaming URL: %@", log: log, type: .info, episode.audioUrl)
            } else {
                os_log("❌ Failed to get playable URL for episode: %@", log: log, type: .error, episode.title)
                return
            }
        }
        
        guard let url = playUrl else { return }
        
        let playerItem = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        // Save last played episode in the view model immediately (thread-safe)
        viewModel?.updateLastPlayedEpisodeImmediate(episode)
        
        // Add to CarPlay recently played list for CarPlay integration
        CarPlayManager.shared.addEpisodeToRecentlyPlayed(episode)
        
        currentEpisode = episode
        currentFeed = feed
        isPodcastActive = true
        
        // Reset CarPlay progress tracking for new episode
        lastCarPlayProgress = nil
        
        // Update currentEpisodeIndex
        if let index = allEpisodesInFeed.firstIndex(where: { $0.id == episode.id }) {
            currentEpisodeIndex = index
            os_log("Set current episode index to %d", log: log, type: .info, index)
        } else {
            os_log("Failed to find index for current episode", log: log, type: .error)
        }
        
        // Initialize time and duration - preserve existing progress for episodes that were partially played
        duration = episode.duration
        
        // Initialize progress from saved state, but only for episodes that have been played before
        if !shouldStartFromBeginning {
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            let savedProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
            
            // Only restore progress if the episode is not new (has been played before)
            if episodeState != .new && savedProgress > 0 {
                currentProgress = savedProgress
                os_log("🎯 Preserving existing progress: %.2f%% for episode: %@ (state: %@)", log: log, type: .info, savedProgress * 100, episode.title, episodeState.rawValue)
            } else {
                currentProgress = 0
            }
        } else {
            // Only reset to 0 if explicitly starting from beginning
            currentProgress = 0
        }
        
        // Set up observers first so we can properly seek when ready
        setupPlayerItemObserver()
        setupTimeObserver()
        
        if let playerItem = player?.currentItem {
            duration = playerItem.asset.duration.seconds
        }
        
        // Only start playing the new episode after we've handled the previous one
        if currentEpisode?.id == episode.id {
            stateManager.startPlaying(episodeId: episode.id)
        }
        
        play()
        isPlaying = true
        updateNowPlayingInfo()
        setupBackgroundPlayback()
        
        // Ensure remote command center is configured for CarPlay
        setupRemoteCommandCenter()

        os_log("Started playing episode: %@", log: log, type: .info, episode.title)
        
        // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
    }
    
    // REMOVED: setupUpdateTimer() - redundant with setupTimeObserver()
    // This eliminates duplicate timer causing CPU spikes
    
    func playLastEpisodeForFeed(_ feed: PodcastFeed) {
            Task { @MainActor in
                if let episode = viewModel?.getLastPlayedOrLatestEpisode(for: feed) {
                    let feedEpisodes = viewModel?.allEpisodes.filter { $0.feedId == feed.id } ?? []
                    let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
                    
                    if episodesInProgress.isEmpty {
                        viewModel?.showNoEpisodesInProgressAlert(for: feed)
                    }
                    
                    playEpisode(episode, feed: feed)
                } else {
                    print("No episodes available for this feed")
                    viewModel?.showNoEpisodesInProgressAlert(for: feed)
                }
            }
        }
    
    private func setupBackgroundPlayback() {
        // Background audio is handled by the centralized PlaybackManager
        // This ensures consistent audio session configuration
        os_log("Background playback configured via PlaybackManager", log: log, type: .info)
    }
    
    private func updateDuration() {
            guard let currentItem = player?.currentItem else { return }
            let newDuration = currentItem.asset.duration.seconds
            if newDuration.isFinite && newDuration > 0 {
                duration = newDuration
                if let currentEpisode = currentEpisode {
                    Task { @MainActor in
                        viewModel?.updateEpisodeDuration(currentEpisode, newDuration: newDuration)
                    }
                }
            }
        }
    
    private func setupPlayerItemObserver() {
            playerItemObserver?.invalidate()
            playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
                guard let self = self else { return }
                if playerItem.status == .readyToPlay {
                    self.duration = playerItem.duration.seconds
                    self.updatePlaybackInfo()
                    self.seekToSavedProgress()
                }
            }

            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
                guard let self = self, let currentEpisode = self.currentEpisode else { return }
                
                os_log("🎵 Episode finished playing (AVPlayerItemDidPlayToEndTime): %@", log: self.log, type: .info, currentEpisode.title)
                
                // Update current time and progress to reflect completion
                self.currentTime = self.duration
                self.currentProgress = 1.0
                
                // Mark episode as completed in EpisodeStateManager
                self.stateManager.completeEpisode(episodeId: currentEpisode.id)
                
                // Save to CloudKit when episode completes
                self.saveProgressToCloudKit(for: currentEpisode, progress: 1.0, reason: "episode completed")
                
                // Mark episode as completed (deprecated method for compatibility)
                self.viewModel?.markEpisodeAsCompleted(currentEpisode)
                
                // Pause playback
                self.pause()
                
                // Update playback info and Now Playing
                self.updatePlaybackInfo()
                self.updateNowPlayingInfo()
                
                // Notify CarPlay of episode completion
                NotificationCenter.default.post(
                    name: NSNotification.Name("EpisodeCompleted"),
                    object: nil,
                    userInfo: [
                        "episodeId": currentEpisode.id,
                        "isCompleted": true
                    ]
                )
                
                os_log("🚗 Episode completion notification sent to CarPlay: %@", log: self.log, type: .info, currentEpisode.title)
            }
        }
    
    
    private func seekToSavedProgress() {
        guard let currentEpisode = currentEpisode else { return }
        
        // Prevent repeated restoration calls for the same episode to improve scrolling performance
        if hasRestoredPositionForCurrentEpisode && currentEpisodeIdForRestoration == currentEpisode.id {
            os_log("⚡ Skipping position restoration - already restored for episode: %@", log: log, type: .debug, currentEpisode.title)
            return
        }
        
        // If this is a replay action, always start from the beginning
        if shouldStartFromBeginning {
            os_log("🔄 Replay requested - starting from the beginning", log: log, type: .info)
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
            currentProgress = 0
            shouldStartFromBeginning = false  // Reset the flag
            hasRestoredPositionForCurrentEpisode = true
            currentEpisodeIdForRestoration = currentEpisode.id
            // Update Now Playing info immediately with correct elapsed time
            updateNowPlayingInfo()
            return
        }
        
        // CRITICAL: Check if this is a new episode - if so, always start from beginning
        let episodeState = EpisodeStateManager.shared.getState(for: currentEpisode.id)
        
        if episodeState == .new {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
            currentProgress = 0
            hasRestoredPositionForCurrentEpisode = true
            currentEpisodeIdForRestoration = currentEpisode.id
            updateNowPlayingInfo()
            return
        }
        
        // Try to get saved progress from multiple sources for better reliability
        var savedProgress: Double = 0.0
        var progressSource = "none"
        
        // 1. Check EpisodeStateManager first (most up-to-date from episode switches)
        let stateManagerProgress = stateManager.getProgress(for: currentEpisode.id)
        let stateManagerCurrentTime = stateManager.getCurrentTime(for: currentEpisode.id)
        
        // PRIORITIZE CURRENT TIME OVER PROGRESS for accuracy
        if stateManagerCurrentTime > 0 && duration > 0 {
            let targetTime = stateManagerCurrentTime
            let targetProgress = targetTime / duration
            
            currentTime = targetTime
            currentProgress = targetProgress
            
            // Seek to the exact saved time
            player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                if completed {
                    DispatchQueue.main.async {
                        self?.currentTime = targetTime
                        self?.currentProgress = targetProgress
                        self?.updatePlaybackInfo()
                        self?.updateNowPlayingInfo()
                        self?.hasRestoredPositionForCurrentEpisode = true
                        self?.currentEpisodeIdForRestoration = currentEpisode.id
                        os_log("🔍 ✅ RESTORED position to %.1f seconds (%.2f%%)", log: self?.log ?? OSLog.default, type: .info, targetTime, targetProgress * 100)
                    }
                }
            }
            return
        }
        else if stateManagerProgress > 0 {
            savedProgress = stateManagerProgress
            progressSource = "stateManager"
        }
        // 2. Skip ViewModel's in-memory cache for now to avoid main actor issues
        // 3. Check the episode's state directly
        else if currentEpisode.state.progress > 0 {
            savedProgress = currentEpisode.state.progress
            progressSource = "episodeState"
        }
        // 4. Skip Core Data fallback for now to avoid main actor issues
        
        if savedProgress > 0 && savedProgress < 1.0 {
            let targetTime = savedProgress * duration
            
            // Update currentTime immediately BEFORE seeking to fix progress bar
            currentTime = targetTime
            currentProgress = savedProgress
            
            // Seek to the saved position
            player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                if completed {
                    DispatchQueue.main.async {
                        // Ensure the time is correctly set after seeking
                        self?.currentTime = targetTime
                        self?.currentProgress = savedProgress
                        self?.updatePlaybackInfo()
                        // Update Now Playing info with correct elapsed time
                        self?.updateNowPlayingInfo()
                        self?.hasRestoredPositionForCurrentEpisode = true
                        self?.currentEpisodeIdForRestoration = currentEpisode.id
                        os_log("🔍 ✅ RESTORED position to %.1f seconds (%.2f%%)", log: self?.log ?? OSLog.default, type: .info, targetTime, savedProgress * 100)
                    }
                } else {
                    // Even if seeking fails, update Now Playing info
                    DispatchQueue.main.async {
                        self?.updateNowPlayingInfo()
                        self?.hasRestoredPositionForCurrentEpisode = true
                        self?.currentEpisodeIdForRestoration = currentEpisode.id
                    }
                }
            }
        } else {
            // Don't reset progress if it was already set from playEpisode - only reset if truly no progress exists
            if currentProgress == 0 && currentTime == 0 {
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
                currentProgress = 0
            }
            // Update Now Playing info immediately
            updateNowPlayingInfo()
            
            // Mark restoration as complete even if no seeking was needed
            hasRestoredPositionForCurrentEpisode = true
            currentEpisodeIdForRestoration = currentEpisode.id
        }
    }
    
    func play() {
        // CRITICAL: Set user intent when resuming playback
        userWantsToPlay = true
        
        stopRadioPlayback()
        
        guard let player = player, let currentEpisode = currentEpisode, let currentFeed = currentFeed else {
                os_log("No current episode or feed available", log: OSLog.default, type: .error)
                return
            }
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Ensure progress is tracked when playing starts
           ensureProgressTracking(for: currentEpisode)
        
        // Skip progress check for now to avoid main actor issues
        
        player.play()
               isPlaying = true
        
        // Clear loading state when playback successfully starts
        loadingEpisodeId = nil
        
        // Update connection state when starting playback
        connectionState = .connected
        
        // Update StateManager when starting playback
        stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: true)
        stateManager.startPlaying(episodeId: currentEpisode.id)
        
        updateNowPlayingInfo()
        setupTimeObserver()
        
        // Reset heavy update timer when starting playback
        lastHeavyUpdate = Date()
        
        // Reset network state on manual play (like radio player)
        if !isAttemptingReconnection {
            resetNetworkState()
        }
        
        // Notify CarPlay of playback state change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastPlaybackStateChanged"),
            object: nil,
            userInfo: [
                "episodeId": currentEpisode.id,
                "isPlaying": true
            ]
        )
        
        // Disable all UI updates during playback to prevent CPU spikes
        // objectWillChange.send()
    }
    
    /// Reset network state to prepare for fresh connection assessment
    private func resetNetworkState() {
        os_log("🌐 PodcastPlayer: Resetting network state for fresh connection", log: log, type: .info)
        
        // Clear any pending reconnection attempts
        stopReconnectionAttempts()
        
        // Reset connection state based on current network availability
        if let reachability = reachability {
            connectionState = reachability.connection != .unavailable ? .connected : .disconnected
        } else {
            connectionState = .connected
        }
        
        // Reset reachability state if needed
        if let reachability = reachability {
            do {
                try reachability.startNotifier()
                os_log("🌐 PodcastPlayer: Reachability monitoring restarted", log: log, type: .info)
            } catch {
                os_log("🌐 PodcastPlayer: Failed to restart reachability monitoring: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    }
    
    
    func pause() {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        player.pause()
        isPlaying = false
        
        // Clear loading state when pausing
        loadingEpisodeId = nil
        
        // Connection state should reflect network availability, not playback state
        // Don't change connection state when pausing
        
        // Calculate current progress
        let progress = duration > 0 ? currentTime / duration : 0
        
        // Save progress to persistent storage when user pauses
        saveProgressIfNeeded()
        
        // Save to CloudKit when user pauses
        saveProgressToCloudKit(for: currentEpisode, progress: progress, reason: "user paused episode")
        
        // Update StateManager with current progress when pausing
        let actualCurrentTime = player.currentTime().seconds
        stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: false, currentTime: actualCurrentTime)
        stateManager.pausePlayback(episodeId: currentEpisode.id, progress: currentProgress)
        
        os_log("⏸️ User paused episode - progress saved: %@, Progress: %.2f%%", 
               log: log, type: .info, currentEpisode.title, progress * 100)

        ensureProgressTracking(for: currentEpisode)

        updateNowPlayingInfo()
        
        // Notify CarPlay of playback state change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastPlaybackStateChanged"),
            object: nil,
            userInfo: [
                "episodeId": currentEpisode.id,
                "isPlaying": false
            ]
        )
        
        // Disable all UI updates during playback to prevent CPU spikes
        // UI will update only when playback state changes (play/pause/stop)
        // objectWillChange.send()
        
        // Use centralized audio session management - only deactivate if no other audio is playing
        if !isPlaying && PlaybackManager.shared.activePlayer == .podcast {
            PlaybackManager.shared.deactivateAudioSession()
        }
    }
    
    /// Stops podcast and clears user intent (like RadioPlayer stop functionality)
    func stop() {
        guard let player = player else { return }
        
        // Save progress before stopping if we have a current episode
        if let currentEpisode = currentEpisode {
            let progress = duration > 0 ? currentTime / duration : 0
            
            // Save progress when stopping
            saveProgressIfNeeded()
            saveProgressToCloudKit(for: currentEpisode, progress: progress, reason: "user stopped episode")
            
            // Update StateManager
            let actualCurrentTime = player.currentTime().seconds
            stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: false, currentTime: actualCurrentTime)
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: currentProgress)
        }
        
        player.pause()
        isPlaying = false
        userWantsToPlay = false  // Clear user intent
        
        // Connection state should reflect network availability, not playback state
        // Don't change connection state when stopping
        
        // Clear current episode and feed
        self.currentEpisode = nil
        self.currentFeed = nil
        
        updateNowPlayingInfo()
        print("⏹️ Podcast stopped and user intent cleared")
    }
    
    /// Handles audio interruptions to prevent CarPlay disconnection from pausing podcast
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔇 PodcastPlayer: Audio interruption began - checking if CarPlay related")
            
            // CRITICAL: Don't pause if this is a CarPlay transition and user wants to continue podcast
            if userWantsToPlay && currentEpisode != nil {
                print("🚗 PodcastPlayer: Resisting audio interruption - user wants podcast to continue")
                
                // Brief delay to let CarPlay transition complete, then aggressively resume
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self,
                          let player = self.player,
                          self.userWantsToPlay,
                          self.currentEpisode != nil else { return }
                    
                    print("🔄 PodcastPlayer: Aggressively resuming after CarPlay interruption")
                    
                    // Reactivate audio session and resume playback
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: [])
                        player.play()
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                        print("✅ PodcastPlayer: Successfully resumed after CarPlay interruption")
                    } catch {
                        print("⚠️ PodcastPlayer: Failed to resume after interruption: \(error)")
                    }
                }
            }
            
        case .ended:
            print("🔊 PodcastPlayer: Audio interruption ended")
            
            // Resume if user wants to continue and we have content
            if userWantsToPlay && currentEpisode != nil && !isPlaying {
                print("🔄 PodcastPlayer: Resuming podcast after interruption ended")
                play()
            }
            
        @unknown default:
            break
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            stop()  // Stops player and removes from UI when pausing
        } else {
            stopRadioPlayback()
            play()
        }
    }
    
    private func stopRadioPlayback() {
        // Completely stop radio playback to prevent it from getting stuck in "connecting" state
        RadioPlayer.shared.stop()
        os_log("🛑 Radio playback completely stopped for podcast playback", log: log, type: .info)
    }
    
    func seek(to time: Double) {
        guard let player = player else { return }
        let targetTime = CMTime(seconds: time, preferredTimescale: 1)
        player.seek(to: targetTime)
        currentTime = time
    }
    
    func saveProgressIfNeeded() {
        guard let currentEpisode = currentEpisode, duration > 0 else { return }
        let progress = currentTime / duration
        
        // Save progress to persistent storage
        stateManager.updateProgress(for: currentEpisode.id, progress: progress, isPlaying: isPlaying, currentTime: currentTime)
        stateManager.forceSave()
        
        // Update local cache
        Task { @MainActor in
            viewModel?.episodeProgress[currentEpisode.id] = progress
        }
        
        // Force UserDefaults sync for additional safety
        UserDefaults.standard.synchronize()
        
        os_log("💾 Progress saved to disk for episode: %@, Progress: %.2f%%, Reason: Manual save", 
               log: log, type: .info, currentEpisode.title, progress * 100)
    }
    
    /// Save episode progress to CloudKit only when specific user actions occur
    /// - When user navigates away by tapping another episode to play
    /// - When user pauses the episode  
    /// - When user switches to other tabs like Favorites or Downloads
    /// - When user puts the app in the background
    /// - When user force closes the app
    private func saveProgressToCloudKit(for episode: PodcastEpisode, progress: Double, reason: String) {
        os_log("💾 Saving episode progress to CloudKit due to: %@ - Episode: %@, Progress: %.2f", 
               log: log, type: .info, reason, episode.title, progress)
        
        Task.detached(priority: .userInitiated) { [self] in
            await self.viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: progress >= 0.99)
        }
    }
    
    private func saveProgressForEpisodeSwitch(_ episode: PodcastEpisode, progress: Double, actualTime: Double? = nil) {
        // Ensure progress is saved immediately when switching episodes
        guard duration > 0 else { return }
        
        let timeToSave = actualTime ?? currentTime
        os_log("🔄 Saving progress immediately for episode switch: %@ (%.2f%% | %.1fs)", log: log, type: .info, episode.title, progress * 100, timeToSave)
        
        // Save to CloudKit when switching episodes
        saveProgressToCloudKit(for: episode, progress: progress, reason: "user switched to another episode")
        
        // 1. Update progress in state manager FIRST (highest priority for seeking)
        stateManager.updateProgress(for: episode.id, progress: progress, isPlaying: false, currentTime: timeToSave)
        
        // 2. Update progress in view model (in-memory cache)
        Task { @MainActor in
            viewModel?.episodeProgress[episode.id] = progress
            
            // 3. Update the episode state using the new method
            let isPlayed = progress >= 0.99
            viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: isPlayed)
        }
        
        // 4. Force save the state manager data immediately
        stateManager.forceSave()
        
        // 5. Force synchronize UserDefaults for additional safety
        UserDefaults.standard.synchronize()
        
        os_log("✅ Progress saved successfully for episode: %@ at %.2f%% to all storage locations", log: log, type: .info, episode.title, progress * 100)
    }
    
    func skipForward() {
        seek(by: 15)
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
            // Update StateManager when user manually seeks
            let actualCurrentTime = player?.currentTime().seconds ?? currentTime
            stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: isPlaying, currentTime: actualCurrentTime)
        }
    }
    
    func skipBackward() {
        seek(by: -15)
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
            // Update StateManager when user manually seeks
            let actualCurrentTime = player?.currentTime().seconds ?? currentTime
            stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: isPlaying, currentTime: actualCurrentTime)
        }
    }
    
    private func seek(by seconds: Double) {
        let newTime = min(max(currentTime + seconds, 0), duration)
        seek(to: newTime)
    }
    
    private func setupTimeObserver() {
        if let existingObserver = timeObserver {
            player?.removeTimeObserver(existingObserver)
        }
        
        // PERFORMANCE OPTIMIZATION: Reduce update frequency from 1s to 2s to improve scrolling
        // This dramatically reduces CPU usage while maintaining acceptable UI responsiveness
        let interval = CMTime(seconds: lightUpdateInterval, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .global(qos: .utility)) { [weak self] _ in
            // Use background queue for time updates to avoid blocking main thread
            DispatchQueue.main.async { [weak self] in
                self?.updateCurrentTimeOnly()
            }
        }
        
        // Set up scroll detection to pause heavy updates during user interaction
        setupScrollDetection()
    }
    
    // PERFORMANCE: Setup scroll detection to pause expensive updates during scrolling
    private func setupScrollDetection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollStart),
            name: .userIsScrolling,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollEnd),
            name: .userStoppedScrolling,
            object: nil
        )
    }
    
    @objc private func handleScrollStart() {
        isUserScrolling = true
        lastScrollNotificationTime = Date()
        
        // Cancel any pending scroll detection timer
        scrollDetectionTimer?.invalidate()
        
        // Reduce logging during scrolling for better performance
        // os_log("🏃‍♂️ User started scrolling - pausing heavy updates for performance", log: log, type: .debug)
    }
    
    @objc private func handleScrollEnd() {
        // Use a timer to detect when scrolling has truly stopped
        scrollDetectionTimer?.invalidate()
        scrollDetectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.isUserScrolling = false
            // Reduce logging during scrolling for better performance
            // os_log("🛑 User stopped scrolling - resuming normal updates", log: self?.log ?? OSLog.default, type: .debug)
        }
    }
    
    // Lightweight method that only updates time values without heavy operations
    private func updateCurrentTimeOnly() {
        guard let player = player else { return }
        
        // PERFORMANCE: Skip all updates during scrolling to prevent hangs
        if isUserScrolling {
            return
        }
        
        // MAIN THREAD FIX: Check app state on main thread to prevent violations
        Task { @MainActor in
            // Skip all updates if app is in background to save battery
            guard UIApplication.shared.applicationState == .active else { return }
            
            Task { [weak self] in
                guard let self = self else { return }
                
                // Only update the time values - no heavy operations
                await MainActor.run {
                    self.currentTime = max(0, player.currentTime().seconds)
                    
                    if let currentItem = player.currentItem {
                        let newDuration = currentItem.duration.seconds
                        if newDuration.isFinite && newDuration > 0 {
                            self.duration = newDuration
                        }
                    }
                    
                    // Calculate progress for display
                    self.currentProgress = self.duration > 0 ? min(self.currentTime / self.duration, 1) : 0
                }
                
                // PERFORMANCE: Only trigger heavy operations if user is not scrolling
                if !self.isUserScrolling {
                    self.updatePlaybackInfoThrottled()
                }
            }
        }
    }
    
    // Throttled heavy operations to prevent CPU spikes - optimized for better performance
    private var lastHeavyUpdate = Date()
    private func updatePlaybackInfoThrottled() {
        let now = Date()
        
        // PERFORMANCE: Increase throttle interval and skip during scrolling
        let throttleInterval = isUserScrolling ? scrollingPauseInterval : heavyUpdateInterval
        
        if now.timeIntervalSince(lastHeavyUpdate) >= throttleInterval {
            lastHeavyUpdate = now
            
            // Run heavy operations on background queue to avoid blocking UI
            Task.detached(priority: .utility) { [weak self] in
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    private func updateNowPlayingInfoDebounced() {
        nowPlayingUpdateTimer?.invalidate()
        
        // PERFORMANCE: Increase debounce interval based on scroll state
        let debounceInterval: TimeInterval = isUserScrolling ? 30.0 : 10.0
        
        nowPlayingUpdateTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            // Skip if user is actively scrolling
            guard let self = self, !self.isUserScrolling else { return }
            
            Task.detached(priority: .utility) { [weak self] in
                await self?.updateNowPlayingInfo()
            }
        }
    }
    
    func updateNowPlayingInfo() {
        // Only update Now Playing info if podcast is the active player
        guard PlaybackManager.shared.activePlayer == .podcast else {
            os_log("Podcast is not the active player, skipping Now Playing update", log: log, type: .info)
            return
        }
        
        guard let currentEpisode = currentEpisode,
              let currentFeed = currentFeed else {
            os_log("Unable to update now playing info: current episode or feed is nil", log: log, type: .error)
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentEpisode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentFeed.title
        // FIXED: Remove duplicate feed title from album field to avoid double display in CarPlay
        // nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentFeed.title
        
        // CRITICAL: Ensure elapsed time is correctly set for CarPlay progress bar
        let elapsedTime = max(0, currentTime)
        let totalDuration = max(0.01, duration)
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        os_log("Podcast Now Playing: Elapsed=%.1fs, Duration=%.1fs, Rate=%.1f", log: log, type: .debug, elapsedTime, totalDuration, isPlaying ? 1.0 : 0.0)
        
        // Optimized artwork handling - use cached artwork to reduce CPU overhead
        var artworkSet = false
        
        // First priority: Direct image data (most efficient)
        if let imageData = currentFeed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Now Playing: Using imageData for artwork (%d bytes)", log: log, type: .debug, imageData.count)
            }
        }
        
        // Second priority: Base64 encoded icon data (efficient)
        if !artworkSet, let iconData = currentFeed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Now Playing: Using iconData for artwork (%d bytes)", log: log, type: .debug, data.count)
            } else {
                os_log("Podcast Now Playing: Failed to decode iconData base64", log: log, type: .error)
            }
        }
        
        // OPTIMIZATION: Skip artwork URL downloads to reduce CPU and network overhead
        // Artwork URL downloads are expensive and not critical for CarPlay functionality
        // CarPlay will use the feed artwork or system defaults if no artwork is available
        if !artworkSet {
            os_log("Podcast Now Playing: No cached artwork available, skipping download to optimize CPU usage", log: log, type: .debug)
        }
        
        // Third priority: Download from artwork URL (async)
        if !artworkSet, let artworkUrlString = currentFeed.artworkUrl, !artworkUrlString.isEmpty {
            if let artworkUrl = URL(string: artworkUrlString) {
                os_log("Podcast Now Playing: Downloading artwork from URL: %@", log: log, type: .info, artworkUrlString)
                
                URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        var updatedInfo = nowPlayingInfo
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        
                        DispatchQueue.main.async {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            os_log("Podcast Now Playing: Successfully set artwork from URL (%d bytes, %dx%d)", 
                                   log: self.log, type: .info, data.count, Int(image.size.width), Int(image.size.height))
                            
                            // CRITICAL: Save artwork to Core Data immediately for fast app restart and podcast player display
                            Task {
                                do {
                                    try await PodcastCoreDataManager.shared.updateFeedArtwork(currentFeed.id, imageData: data)
                                    os_log("📦 Saved downloaded artwork to Core Data for feed: %@", log: self.log, type: .info, currentFeed.title)
                                    
                                    // Update the viewModel's feed with the downloaded artwork for immediate UI update
                                    await MainActor.run {
                                        if let viewModel = self.viewModel {
                                            if let feedIndex = viewModel.podcastFeeds.firstIndex(where: { $0.id == currentFeed.id }) {
                                                viewModel.podcastFeeds[feedIndex].imageData = data
                                                os_log("🔄 Updated in-memory feed artwork for immediate display: %@", log: self.log, type: .info, currentFeed.title)
                                            }
                                        }
                                    }
                                } catch {
                                    os_log("❌ Failed to save artwork to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                                }
                            }
                        }
                    } else {
                        os_log("Podcast Now Playing: Failed to load artwork from URL: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                    }
                }.resume()
            }
        }
        
        // Set the now playing info (with or without artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        if !artworkSet {
            os_log("Podcast Now Playing: No artwork available for feed '%@'", log: log, type: .info, currentFeed.title)
        }
        
        os_log("Podcast Now Playing: Update complete for episode '%@' from feed '%@'", log: log, type: .debug, currentEpisode.title, currentFeed.title)
    }
    
    func getCurrentProgress(for episode: PodcastEpisode) -> Double {
           if currentEpisode?.id == episode.id {
               return min(max(currentProgress, 0), 1)
           } else {
               // Skip viewModel getProgress call to avoid main actor issues
               return min(max(episode.state.progress, 0), 1)
           }
       }
    
    // PERFORMANCE: Async progress update with optimized UI updates
    private func updateProgress() async {
        guard let currentEpisode = currentEpisode, duration > 0 else { return }
        let progress = currentTime / duration
        
        await MainActor.run {
            self.currentProgress = progress
        }
        
        // Calculate remaining time
        let remainingTime = max(duration - currentTime, 0)
        
        // PERFORMANCE: Only update in-memory progress during playback - NO saves or StateManager updates
        // Progress will only be saved when:
        // 1. App is force closed (handleAppWillTerminate)
        // 2. App goes to background (handleAppTermination)  
        // 3. User pauses episode (pause function)
        // 4. User switches episodes (playEpisode function)
        
        // OPTIMIZE: Reduce in-memory cache updates to every 10% to minimize CPU usage (was 25%)
        let progressPercent = Int(progress * 100)
        let lastProgressPercent = Int((lastCarPlayProgress ?? 0) * 100)
        
        // Only update memory and CarPlay every 10% to drastically reduce CPU usage
        if progressPercent != lastProgressPercent && progressPercent % 10 == 0 {
            lastCarPlayProgress = progress
            
            // PERFORMANCE: Update cache only when not scrolling
            if !isUserScrolling {
                await MainActor.run {
                    viewModel?.episodeProgress[currentEpisode.id] = progress
                }
                
                // OPTIMIZE: Reduce CarPlay notifications to minimum (every 10%)
                NotificationCenter.default.post(
                    name: NSNotification.Name("PodcastProgressUpdated"),
                    object: nil,
                    userInfo: [
                        "episodeId": currentEpisode.id,
                        "progress": progress,
                        "isPlaying": isPlaying,
                        "currentTime": currentTime,
                        "duration": duration
                    ]
                )
                
                os_log("🚗 CarPlay progress update sent: %@, Progress: %.1f%% (CPU optimized)", log: log, type: .debug, currentEpisode.title, progress * 100)
            }
        }
        
        // Check for episode completion AFTER saving progress
        if remainingTime < 1 || progress >= 0.99 {
            await MainActor.run {
                viewModel?.markEpisodeAsCompleted(currentEpisode)
            }
            os_log("Episode marked as completed: %@", log: log, type: .info, currentEpisode.title)
            
            // PERFORMANCE: Only send completion notification when not scrolling
            if !isUserScrolling {
                NotificationCenter.default.post(
                    name: NSNotification.Name("EpisodeCompleted"),
                    object: nil,
                    userInfo: [
                        "episodeId": currentEpisode.id,
                        "isCompleted": true
                    ]
                )
            }
        }
        
        // PERFORMANCE: Completely disable objectWillChange.send() to eliminate scrolling lag
        // UI updates will happen naturally through @Published properties and SwiftUI's observation system
        // This is the most critical optimization for smooth scrolling during playback
    }
    
    private func formatRemainingTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func handleAppWillTerminate() {
        if let currentEpisode = currentEpisode {
            // Get the most accurate current time from the player
            let actualCurrentTime = player?.currentTime().seconds ?? currentTime
            let calculatedProgress = duration > 0 ? actualCurrentTime / duration : 0
            
            // CRITICAL: Preserve maximum progress to prevent reset during force close
            // Get existing progress from StateManager and use the maximum value
            let existingProgress = stateManager.getProgress(for: currentEpisode.id)
            let maxProgress = max(calculatedProgress, existingProgress, currentProgress)
            
            // Use the most accurate current time, but preserve progress if it's higher
            let finalCurrentTime = max(actualCurrentTime, currentTime)
            
            os_log("🛑 App force close/background - saving progress for episode: %@ (calculated: %.2f%%, existing: %.2f%%, current: %.2f%% -> final: %.2f%%)", 
                   log: log, type: .info, currentEpisode.title, calculatedProgress * 100, existingProgress * 100, currentProgress * 100, maxProgress * 100)
            
            // Save to CloudKit when app is force closed
            saveProgressToCloudKit(for: currentEpisode, progress: maxProgress, reason: "app force closed")
            
            // Save to StateManager with maximum progress (synchronous and reliable)
            stateManager.updateProgress(for: currentEpisode.id, progress: maxProgress, isPlaying: false, currentTime: finalCurrentTime)
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: maxProgress)
            
            // Force synchronize UserDefaults immediately
            UserDefaults.standard.synchronize()
            
            // Update in-memory cache directly without triggering CloudKit saves (avoid complex Core Data operations during termination)
            Task { @MainActor in
                viewModel?.episodeProgress[currentEpisode.id] = maxProgress
            }
            
            os_log("✅ Progress saved for app force close/background: %@, Progress: %.2f%%", log: log, type: .info, currentEpisode.title, maxProgress * 100)
        }
    }
    
    private func setupNowPlaying(for episode: PodcastEpisode, feed: PodcastFeed) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = episode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = feed.title
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = feed.title
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Enhanced artwork priority: imageData -> iconData -> artworkUrl (same as CarPlay)
        var artworkSet = false
        
        // First priority: Direct image data
        if let imageData = feed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Setup: Using imageData for artwork (%d bytes)", log: log, type: .debug, imageData.count)
            }
        }
        
        // Second priority: Base64 encoded icon data
        if !artworkSet, let iconData = feed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Setup: Using iconData for artwork (%d bytes)", log: log, type: .debug, data.count)
            } else {
                os_log("Podcast Setup: Failed to decode iconData base64", log: log, type: .error)
            }
        }
        
        // Third priority: Download from artwork URL (async)
        if !artworkSet, let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty {
            if let artworkUrl = URL(string: artworkUrlString) {
                os_log("Podcast Setup: Downloading artwork from URL: %@", log: log, type: .info, artworkUrlString)
                
                URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        var updatedInfo = nowPlayingInfo
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        
                        DispatchQueue.main.async {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            os_log("Podcast Setup: Successfully set artwork from URL (%d bytes, %dx%d)", 
                                   log: self.log, type: .info, data.count, Int(image.size.width), Int(image.size.height))
                            
                            // CRITICAL: Save artwork to Core Data immediately for fast app restart and podcast player display
                            Task {
                                do {
                                    try await PodcastCoreDataManager.shared.updateFeedArtwork(feed.id, imageData: data)
                                    os_log("📦 Saved downloaded artwork to Core Data for feed: %@", log: self.log, type: .info, feed.title)
                                    
                                    // Update the viewModel's feed with the downloaded artwork for immediate UI update
                                    await MainActor.run {
                                        if let viewModel = self.viewModel {
                                            if let feedIndex = viewModel.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                                                viewModel.podcastFeeds[feedIndex].imageData = data
                                                os_log("🔄 Updated in-memory feed artwork for immediate display: %@", log: self.log, type: .info, feed.title)
                                            }
                                        }
                                    }
                                } catch {
                                    os_log("❌ Failed to save artwork to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                                }
                            }
                        }
                    } else {
                        os_log("Podcast Setup: Failed to load artwork from URL: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                    }
                }.resume()
            }
        }
        
        // Set the now playing info (with or without artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        if !artworkSet {
            os_log("Podcast Setup: No artwork available for feed '%@'", log: log, type: .info, feed.title)
        }
        
        os_log("Podcast Setup: Setup complete for episode '%@' from feed '%@'", log: log, type: .debug, episode.title, feed.title)
    }
    
    deinit {
        // Ensure progress is saved even if the object is deallocated unexpectedly
        if let currentEpisode = currentEpisode, isPlaying {
            let calculatedProgress = duration > 0 ? currentTime / duration : 0
            
            // CRITICAL: Preserve maximum progress during deallocation
            let existingProgress = stateManager.getProgress(for: currentEpisode.id)
            let maxProgress = max(calculatedProgress, existingProgress, currentProgress)
            
            // Update in-memory cache directly without triggering CloudKit saves
            Task { @MainActor in
                viewModel?.episodeProgress[currentEpisode.id] = maxProgress
            }
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: maxProgress)
            os_log("Saved maximum progress on deinit for episode: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, maxProgress)
        }
        
        // Clean up network reconnection resources
        stopReconnectionAttempts()
        
        // Stop reachability monitoring
        reachability?.stopNotifier()
        
        playerItemObserver?.invalidate()
        updateTimer?.invalidate()
        nowPlayingUpdateTimer?.invalidate()
        
        // Remove observers to prevent memory leaks
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Notification Extensions
// Note: Notification names are declared in RadioStationListView.swift to avoid duplication

struct UserDefaultsKeys {
    static func progressKey(for episodeId: String) -> String {
        return "PodcastProgress_\(episodeId)"
    }
}
