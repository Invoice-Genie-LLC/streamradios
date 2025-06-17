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

class PodcastPlayer: ObservableObject, AudioPlayerProtocol {
    @Published var currentEpisode: PodcastEpisode?
    @Published var isPlaying: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0.01
    @Published var currentFeed: PodcastFeed?
    @Published var currentProgress: Double = 0
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
        private let updateInterval: TimeInterval = 0.5
    private var lastReportedProgress: Double = 0
    private let stateManager = EpisodeStateManager.shared
    private var shouldStartFromBeginning: Bool = false


    var remainingTime: Double {
            max(0, duration - currentTime)
        }
    
    private init() {
        setupAudioSession()
               setupReachability()
               setupRemoteCommandCenter()
               setupInterruptionHandling()
               setupTerminationHandling()
       }
    
    private func setupAudioSession() {
        // Audio session is now managed centrally by PlaybackManager
        // This method is kept for backward compatibility
        print("✅ Podcast: Audio session management delegated to PlaybackManager")
    }
    
    private func setupReachability() {
           do {
               reachability = try Reachability()
               reachability?.whenReachable = { [weak self] _ in
                   self?.handleNetworkReconnection()
               }
               try reachability?.startNotifier()
           } catch {
               os_log("Unable to start reachability notifier: %@", log: log, type: .error, error.localizedDescription)
           }
       }
    
    private func setupInterruptionHandling() {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleInterruption),
                                                   name: AVAudioSession.interruptionNotification,
                                                   object: nil)
        }
    
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
    
    @objc private func handleInterruption(notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            
            switch type {
            case .began:
                pause()
            case .ended:
                // Let PlaybackManager handle audio session reactivation
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && PlaybackManager.shared.activePlayer == .podcast {
                    play()
                }
            @unknown default:
                break
            }
        }
    
    @objc private func handleAppTermination(notification: Notification) {
        // Handle different app lifecycle events to ensure progress is saved
        os_log("App lifecycle event detected: %@", log: log, type: .info, notification.name.rawValue)
        
        if notification.name == UIApplication.willTerminateNotification ||
           notification.name == UIApplication.didEnterBackgroundNotification ||
           notification.name == UIApplication.willResignActiveNotification {
            
            // Ensure progress is saved when app is force closed or goes to background
            handleAppWillTerminate()
        }
    }
    
    private func handleNetworkReconnection() {
            guard isPlaying else { return }
            
            isAttemptingReconnection = true
            currentReconnectionAttempt = 0
            attemptReconnection()
        }
    
    private func attemptReconnection() {
            guard currentReconnectionAttempt < maxReconnectionAttempts else {
                stopReconnectionAttempts()
                return
            }
            
            currentReconnectionAttempt += 1
            os_log("Attempting to reconnect (attempt %d of %d)", log: log, type: .info, currentReconnectionAttempt, maxReconnectionAttempts)
            
            play()
            
            reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.checkPlaybackStatus()
            }
        }
    
    private func checkPlaybackStatus() {
            if player?.timeControlStatus == .playing {
                stopReconnectionAttempts()
            } else {
                attemptReconnection()
            }
        }
    
    private func stopReconnectionAttempts() {
           reconnectionTimer?.invalidate()
           reconnectionTimer = nil
           isAttemptingReconnection = false
           currentReconnectionAttempt = 0
           
           if player?.timeControlStatus != .playing {
               os_log("Failed to reconnect after %d attempts", log: log, type: .error, maxReconnectionAttempts)
               pause()
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
            
            allEpisodesInFeed = viewModel.allEpisodes.filter { $0.feedId == feed.id }
            allEpisodesInFeed.sort { $0.publicationDate > $1.publicationDate } // Sort by newest first
            os_log("Loaded %d episodes for feed: %{public}@", log: log, type: .info, allEpisodesInFeed.count, feed.title)
            
            // Verify that all episodes are loaded
            if allEpisodesInFeed.isEmpty {
                os_log("No episodes loaded for feed. Attempting to fetch episodes.", log: log, type: .error)
                fetchEpisodesForFeed(feed)
            }
        }
    
    private func fetchEpisodesForFeed(_ feed: PodcastFeed) {
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
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    
    private func updatePlaybackInfo() {
            guard let player = player else { return }
            currentTime = max(0, player.currentTime().seconds)
            duration = max(0.01, player.currentItem?.duration.seconds ?? 0.01)
            currentProgress = duration > 0 ? min(currentTime / duration, 1) : 0
            
            // Only update UI if there's a significant change AND user is not actively interacting
            if abs(currentProgress - lastReportedProgress) > 0.01 {
                lastReportedProgress = currentProgress
                
                // Check if any views are currently being scrolled by user
                let shouldUpdateUI = !isUserCurrentlyScrolling()
                
                if shouldUpdateUI {
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                    }
                }
            }
            
            // Update now playing info less frequently
            updateNowPlayingInfoDebounced()
        }
    
    private func isUserCurrentlyScrolling() -> Bool {
        // Check if any podcast player views are currently being scrolled
        // This helps prevent UI updates during user interaction
        return UserDefaults.standard.bool(forKey: "isUserScrolling")
    }
    
    func rewindAndPlay(episode: PodcastEpisode) {
        // Find the correct feed for this episode
        guard let feed = viewModel?.podcastFeeds.first(where: { $0.id == episode.feedId }) else {
            os_log("Feed not found for episode: %@", log: log, type: .error, episode.title)
            return
        }
        
        if currentEpisode?.id == episode.id {
            // Same episode - rewind to beginning and play
            seek(to: 0)
            currentTime = 0
            currentProgress = 0
            
            // Reset progress in view model
            viewModel?.updateProgress(for: episode, progress: 0.0)
            
            // Update episode state to not played and reset progress
            var updatedEpisode = episode
            updatedEpisode.state.isPlayed = false
            updatedEpisode.state.progress = 0.0
            viewModel?.updateEpisode(updatedEpisode)
            
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
        
        // Force UI update only if user is not scrolling
        if !isUserCurrentlyScrolling() {
            DispatchQueue.main.async {
                self.viewModel?.objectWillChange.send()
                self.objectWillChange.send()
            }
        }
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
                
                // Preserve existing "finished" status - only mark as finished if progress >= 0.99
                // but don't unmark episodes that were already marked as finished
                if progress >= 0.99 {
                    updatedEpisode.state.isPlayed = true
                } else if !currentEpisode.state.isPlayed {
                    // Only update isPlayed to false if it wasn't already marked as finished
                    updatedEpisode.state.isPlayed = false
                }
                
                // Update the episode in ViewModel
                viewModel?.updateEpisode(updatedEpisode)
                
                // Force UI update only if user is not scrolling
                if !self.isUserCurrentlyScrolling() {
                    DispatchQueue.main.async {
                        self.viewModel?.objectWillChange.send()
                    }
                }
                
                os_log("Updated episode status on navigation away: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, progress)
            }
        }
    
    func ensureProgressTracking(for episode: PodcastEpisode) {
        // If this episode was ever played, ensure it shows as "In Progress"
        if currentEpisode?.id == episode.id && currentTime > 0 {
            let progress = currentTime / duration
            if progress > 0 && progress < 0.99 {
                viewModel?.updateProgress(for: episode, progress: progress)
                
                // Update the episode state
                var updatedEpisode = episode
                updatedEpisode.state.progress = progress
                
                // Only mark as not played if it wasn't already marked as finished
                if !episode.state.isPlayed {
                    updatedEpisode.state.isPlayed = false
                }
                
                viewModel?.updateEpisode(updatedEpisode)
                
                // Force UI update only if user is not scrolling
                if !self.isUserCurrentlyScrolling() {
                    DispatchQueue.main.async {
                        self.viewModel?.objectWillChange.send()
                    }
                }
            }
        }
    }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        stopRadioPlayback()
        
        // If there's a currently playing episode, mark it as "In Progress" before switching
        if let currentEpisode = currentEpisode, currentEpisode.id != episode.id {
            let currentProgress = currentTime / duration
            stateManager.switchToEpisode(
                newEpisodeId: episode.id,
                previousEpisodeId: currentEpisode.id,
                previousProgress: currentProgress
            )
            saveProgressIfNeeded()
        }
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Load all episodes for the feed
        loadAllEpisodesForFeed(feed)
        
        var playUrl: URL?
        
        if let localFilePath = episode.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
            playUrl = URL(fileURLWithPath: localFilePath)
        } else if let url = URL(string: episode.audioUrl) {
            playUrl = url
        } else {
            os_log("Failed to get playable URL for episode: %@", log: log, type: .error, episode.title)
            return
        }
        
        guard let url = playUrl else { return }
        
        let playerItem = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        // Save last played episode in the view model
        viewModel?.updateLastPlayedEpisode(episode)
        
        currentEpisode = episode
        currentFeed = feed
        isPodcastActive = true
        
        // Update currentEpisodeIndex
        if let index = allEpisodesInFeed.firstIndex(where: { $0.id == episode.id }) {
            currentEpisodeIndex = index
            os_log("Set current episode index to %d", log: log, type: .info, index)
        } else {
            os_log("Failed to find index for current episode", log: log, type: .error)
        }
        
        // Initialize time and duration - don't reset to zero yet, let seekToSavedProgress handle it
        duration = episode.duration
        currentProgress = 0
        
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
        
        // Trigger a UI update only if user is not scrolling
        if !isUserCurrentlyScrolling() {
            DispatchQueue.main.async {
                self.viewModel?.objectWillChange.send()
            }
        }
    }
    
    private func setupUpdateTimer() {
           updateTimer?.invalidate()
           updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
               self?.updatePlaybackInfo()
           }
       }
    
    func playLastEpisodeForFeed(_ feed: PodcastFeed) {
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
                    viewModel?.updateEpisodeDuration(currentEpisode, newDuration: newDuration)
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
                self.viewModel?.markEpisodeAsCompleted(currentEpisode)
                self.pause()
                self.updatePlaybackInfo()
                self.updateNowPlayingInfo()
            }
        }
    
    
    private func seekToSavedProgress() {
        guard let currentEpisode = currentEpisode else { return }
        
        // If this is a replay action, always start from the beginning
        if shouldStartFromBeginning {
            os_log("Replay requested - starting from the beginning", log: log, type: .info)
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
            currentProgress = 0
            shouldStartFromBeginning = false  // Reset the flag
            // Update Now Playing info immediately with correct elapsed time
            updateNowPlayingInfo()
            return
        }
        
        // Try to get saved progress from multiple sources for better reliability
        var savedProgress: Double = 0.0
        var progressSource = "none"
        
        // 1. Check ViewModel's in-memory cache first (fastest)
        if let viewModelProgress = viewModel?.episodeProgress[currentEpisode.id], viewModelProgress > 0 {
            savedProgress = viewModelProgress
            progressSource = "viewModel"
        }
        // 2. If not found, check the episode's state directly
        else if currentEpisode.state.progress > 0 {
            savedProgress = currentEpisode.state.progress
            progressSource = "episodeState"
        }
        // 3. As fallback, query Core Data directly (for CarPlay independence)
        else if let viewModel = viewModel {
            let coreDataProgress = viewModel.getProgress(for: currentEpisode)
            if coreDataProgress > 0 {
                savedProgress = coreDataProgress
                progressSource = "coreData"
            }
        }
        
        if savedProgress > 0 && savedProgress < 1.0 {
            let targetTime = savedProgress * duration
            os_log("Seeking to saved progress: %.2f%% (%.1f seconds) from %@", log: log, type: .info, savedProgress * 100, targetTime, progressSource)
            
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
                        os_log("Successfully restored playback position to %.1f seconds", log: self?.log ?? OSLog.default, type: .info, targetTime)
                    }
                } else {
                    os_log("Failed to seek to saved progress", log: self?.log ?? OSLog.default, type: .error)
                    // Even if seeking fails, update Now Playing info
                    DispatchQueue.main.async {
                        self?.updateNowPlayingInfo()
                    }
                }
            }
        } else {
            os_log("No valid saved progress found, starting from the beginning (progress: %.2f)", log: log, type: .info, savedProgress)
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
            currentProgress = 0
            // Update Now Playing info immediately
            updateNowPlayingInfo()
        }
    }
    
    func play() {
        stopRadioPlayback()
        
        guard let player = player, let currentEpisode = currentEpisode, let currentFeed = currentFeed else {
                os_log("No current episode or feed available", log: OSLog.default, type: .error)
                return
            }
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // Ensure progress is tracked when playing starts
           ensureProgressTracking(for: currentEpisode)
        
        // Only reset progress if the episode was completed
        if viewModel?.getProgress(for: currentEpisode) == 1.0 {
                currentTime = 0
                player.seek(to: .zero)
                viewModel?.updateProgress(for: currentEpisode, progress: 0.0)
            }
        
        player.play()
               isPlaying = true
        stateManager.startPlaying(episodeId: currentEpisode.id)

               
               updateNowPlayingInfo()
               setupTimeObserver()
               
               // Only send UI update if user is not scrolling
               if !isUserCurrentlyScrolling() {
                   objectWillChange.send()
               }
            }
    
    
    func pause() {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        player.pause()
        isPlaying = false
        saveProgressIfNeeded()  // Progress is saved here
        stateManager.pausePlayback(episodeId: currentEpisode.id, progress: currentProgress)

        ensureProgressTracking(for: currentEpisode)

        updateNowPlayingInfo()
        
        // Only send UI update if user is not scrolling
        if !isUserCurrentlyScrolling() {
            objectWillChange.send()
        }
        
        // Use centralized audio session management - only deactivate if no other audio is playing
        if !isPlaying && PlaybackManager.shared.activePlayer == .podcast {
            PlaybackManager.shared.deactivateAudioSession()
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()  // Saves progress when pausing
        } else {
            stopRadioPlayback()
            play()
        }
    }
    
    private func stopRadioPlayback() {
        if let radioPlayer = radioPlayer, radioPlayer.isPlaying {
            radioPlayer.pause()
        }
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
        viewModel?.updateProgress(for: currentEpisode, progress: progress)
    }
    
    func skipForward() {
        seek(by: 15)
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
        }
    }
    
    func skipBackward() {
        seek(by: -15)
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
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
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updatePlaybackInfo()
            self?.updateNowPlayingInfoDebounced()
        }
    }
    
    private func updateNowPlayingInfoDebounced() {
        nowPlayingUpdateTimer?.invalidate()
        nowPlayingUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
    }
    
    private func updateNowPlayingInfo() {
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
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentFeed.title
        
        // CRITICAL: Ensure elapsed time is correctly set for CarPlay progress bar
        let elapsedTime = max(0, currentTime)
        let totalDuration = max(0.01, duration)
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        os_log("Podcast Now Playing: Elapsed=%.1fs, Duration=%.1fs, Rate=%.1f", log: log, type: .debug, elapsedTime, totalDuration, isPlaying ? 1.0 : 0.0)
        
        // Enhanced artwork priority: imageData -> iconData -> artworkUrl (same as CarPlay)
        var artworkSet = false
        
        // First priority: Direct image data
        if let imageData = currentFeed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Now Playing: Using imageData for artwork (%d bytes)", log: log, type: .debug, imageData.count)
            }
        }
        
        // Second priority: Base64 encoded icon data
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
        
        os_log("Podcast Now Playing: Updated info for episode '%@' from feed '%@'", log: log, type: .debug, currentEpisode.title, currentFeed.title)
    }
    
    func getCurrentProgress(for episode: PodcastEpisode) -> Double {
           if currentEpisode?.id == episode.id {
               return min(max(currentProgress, 0), 1)
           } else {
               return min(max(viewModel?.getProgress(for: episode) ?? 0, 0), 1)
           }
       }
    
    private func updateProgress() {
            guard let currentEpisode = currentEpisode, duration > 0 else { return }
            let progress = currentTime / duration
            
            self.currentProgress = progress
            stateManager.updateProgress(for: currentEpisode.id, progress: progress, isPlaying: isPlaying)
            
            // Calculate remaining time
            let remainingTime = max(duration - currentTime, 0)
            
            // If the remaining time is less than 1 second or progress is >= 0.99, mark the episode as completed
            if remainingTime < 1 || progress >= 0.99 {
                viewModel?.markEpisodeAsCompleted(currentEpisode)
                os_log("Episode marked as completed: %@", log: log, type: .info, currentEpisode.title)
                
                // Notify CarPlay of episode completion
                NotificationCenter.default.post(
                    name: NSNotification.Name("EpisodeCompleted"),
                    object: nil,
                    userInfo: [
                        "episodeId": currentEpisode.id,
                        "isCompleted": true
                    ]
                )
            } else {
                // Only save progress if it has changed significantly
                if abs(progress - lastSavedProgress) >= saveThreshold {
                    viewModel?.updateProgress(for: currentEpisode, progress: progress)
                    lastSavedProgress = progress
                    os_log("Progress saved for episode: %@, Progress: %.2f, Remaining Time: %@", log: log, type: .info, currentEpisode.title, progress, formatRemainingTime(remainingTime))
                    
                    // Notify CarPlay of progress update for real-time updates
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
                }
            }
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    
    private func formatRemainingTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func handleAppWillTerminate() {
        if let currentEpisode = currentEpisode, isPlaying {
            // Immediately save current progress
            let progress = currentTime / duration
            
            // Save progress in view model
            viewModel?.updateProgress(for: currentEpisode, progress: progress)
            
            // Update episode state to "In Progress" if it was playing
            var updatedEpisode = currentEpisode
            updatedEpisode.state.progress = progress
            
            // Preserve existing "finished" status - only mark as finished if progress >= 0.99
            // but don't unmark episodes that were already marked as finished
            if progress >= 0.99 {
                updatedEpisode.state.isPlayed = true
            } else if !currentEpisode.state.isPlayed {
                // Only update isPlayed to false if it wasn't already marked as finished
                updatedEpisode.state.isPlayed = false
            }
            
            viewModel?.updateEpisode(updatedEpisode)
            
            // Update state manager to mark as in progress
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: progress)
            
            // Force save to UserDefaults and Core Data immediately
            viewModel?.saveContextIfNeeded()
            
            os_log("Force saved progress and marked episode as in progress on app termination: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, progress)
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
            let progress = currentTime / duration
            viewModel?.updateProgress(for: currentEpisode, progress: progress)
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: progress)
            os_log("Saved progress on deinit for episode: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, progress)
        }
        
        playerItemObserver?.invalidate()
        updateTimer?.invalidate()
        nowPlayingUpdateTimer?.invalidate()
        
        // Remove observers to prevent memory leaks
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let userIsScrolling = Notification.Name("userIsScrolling")
    static let userStoppedScrolling = Notification.Name("userStoppedScrolling")
}

struct UserDefaultsKeys {
    static func progressKey(for episodeId: String) -> String {
        return "PodcastProgress_\(episodeId)"
    }
}
