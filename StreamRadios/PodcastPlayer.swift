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

    

    var remainingTime: Double {
            max(0, duration - currentTime)
        }
    
    private init() {
        setupAudioSession()
               setupReachability()
               setupRemoteCommandCenter()
               setupInterruptionHandling()
       }
    
    private func setupAudioSession() {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                os_log("Failed to set up audio session: %@", log: log, type: .error, error.localizedDescription)
            }
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
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    play()
                }
            @unknown default:
                break
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
           objectWillChange.send()
       }
    
    func rewindAndPlay(episode: PodcastEpisode) {
        if currentEpisode?.id == episode.id {
            // If it's the same episode, rewind and play immediately
            seek(to: 0)
            play()
        } else {
            // If it's a different episode, play it from the beginning
            playEpisode(episode, feed: viewModel?.podcastFeeds.first { $0.id == episode.feedId } ?? PodcastFeed(id: "", title: "", url: ""))
        }
        isPlaying = true
    }
    
    func configure(with viewModel: PodcastViewModel) {
        self.viewModel = viewModel
    }
    
    func setRadioPlayer(_ player: RadioPlayer) {
        self.radioPlayer = player
    }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        stopRadioPlayback()
        
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            os_log("Failed to activate audio session: %@", log: log, type: .error, error.localizedDescription)
        }
        
        // Save progress of the current episode if there is one
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
        }

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
        
        // Update episode progress
        var updatedEpisode = episode
        if viewModel?.getProgress(for: episode) == 0 {
            updatedEpisode.state.progress = 0.001
            viewModel?.updateEpisode(updatedEpisode)
        }
        
        if let savedProgress = viewModel?.episodeProgress[episode.id] {
            let targetTime = savedProgress * episode.duration
            player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1))
            currentTime = targetTime
            updatedEpisode.state.progress = savedProgress
            viewModel?.updateEpisode(updatedEpisode)
        } else {
            currentTime = 0
            duration = episode.duration
            currentProgress = 0
        }
        
        setupPlayerItemObserver()
        setupTimeObserver()
        
        if let playerItem = player?.currentItem {
            duration = playerItem.asset.duration.seconds
        }
        play()
        isPlaying = true
        updateNowPlayingInfo()
        setupBackgroundPlayback()

        os_log("Started playing episode: %@", log: log, type: .info, episode.title)
        
        // Trigger a UI update
        DispatchQueue.main.async {
            self.viewModel?.objectWillChange.send()
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
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                
                // Enable background audio
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                    try audioSession.setActive(true)
                    os_log("Successfully set up background audio", log: log, type: .info)
                } catch {
                    os_log("Failed to set up background audio: %@", log: log, type: .error, error.localizedDescription)
                }
            } catch {
                os_log("Error setting up audio session: %@", log: log, type: .error, error.localizedDescription)
            }
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
        if let savedProgress = viewModel?.episodeProgress[currentEpisode.id] {
            let targetTime = savedProgress * duration
            os_log("Seeking to saved progress: %f seconds", targetTime)
            player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = targetTime
        } else {
            os_log("No saved progress found, starting from the beginning")
        }
    }
    
    func play() {
        stopRadioPlayback()
        
        guard let player = player, let currentEpisode = currentEpisode, let currentFeed = currentFeed else {
                os_log("No current episode or feed available", log: OSLog.default, type: .error)
                return
            }
        
        // Only reset progress if the episode was completed
        if viewModel?.getProgress(for: currentEpisode) == 1.0 {
                currentTime = 0
                player.seek(to: .zero)
                viewModel?.updateProgress(for: currentEpisode, progress: 0.0)
            }
        
        player.play()
               isPlaying = true
               
               updateNowPlayingInfo()
               setupTimeObserver()
               
               objectWillChange.send()
        
                PlaybackManager.shared.setActivePlayer(.podcast)
            }
    
    
    func pause() {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        player.pause()
        isPlaying = false
        saveProgressIfNeeded()  // Progress is saved here
        
        updateNowPlayingInfo()
        objectWillChange.send()
        
        do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    os_log("Failed to deactivate audio session: %@", log: log, type: .error, error.localizedDescription)
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
        os_log("Progress saved for episode: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, progress)
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
           }
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
            
            // Calculate remaining time
            let remainingTime = max(duration - currentTime, 0)
            
            // If the remaining time is less than 1 second or progress is >= 0.99, mark the episode as completed
            if remainingTime < 1 || progress >= 0.99 {
                viewModel?.markEpisodeAsCompleted(currentEpisode)
                os_log("Episode marked as completed: %@", log: log, type: .info, currentEpisode.title)
            } else {
                // Only save progress if it has changed significantly
                if abs(progress - lastSavedProgress) >= saveThreshold {
                    viewModel?.updateProgress(for: currentEpisode, progress: progress)
                    lastSavedProgress = progress
                    os_log("Progress saved for episode: %@, Progress: %.2f, Remaining Time: %@", log: log, type: .info, currentEpisode.title, progress, formatRemainingTime(remainingTime))
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
        if let currentEpisode = currentEpisode {
            saveProgressIfNeeded()
            os_log("Saved progress on app termination for episode: %@", log: log, type: .info, currentEpisode.title)
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
        
        if let artworkUrlString = feed.artworkUrl, let artworkUrl = URL(string: artworkUrlString) {
            URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                if let data = data, let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                    DispatchQueue.main.async {
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                    }
                }
            }.resume()
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    private func updateNowPlayingInfo() {
            guard let currentEpisode = currentEpisode,
                  let currentFeed = currentFeed else {
                os_log("Unable to update now playing info: current episode or feed is nil", log: log, type: .error)
                return
            }
            
            var nowPlayingInfo = [String: Any]()
            nowPlayingInfo[MPMediaItemPropertyTitle] = currentEpisode.title
            nowPlayingInfo[MPMediaItemPropertyArtist] = currentFeed.title
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentFeed.title
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            
            if let artworkUrlString = currentFeed.artworkUrl,
               let artworkUrl = URL(string: artworkUrlString) {
                URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        DispatchQueue.main.async {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                        }
                    } else {
                        os_log("Failed to load artwork: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                    }
                }.resume()
            } else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
            
            os_log("Updated now playing info for episode: %@", log: log, type: .debug, currentEpisode.title)
        }
    
    deinit {
        playerItemObserver?.invalidate()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }
}

struct UserDefaultsKeys {
    static func progressKey(for episodeId: String) -> String {
        return "PodcastProgress_\(episodeId)"
    }
}
