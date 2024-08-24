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
    static let shared = PodcastPlayer()
       
       weak var radioPlayer: RadioPlayer?
       
        var player: AVPlayer?
       @Published var currentEpisode: PodcastEpisode?
       @Published var isPlaying: Bool = false
       @Published var currentTime: Double = 0
       @Published var duration: Double = 0
       @Published var isSeeking = false
       @Published var progress: [String: Double] = [:]
        @State private var seekPosition: Double = 0
       @Published var currentFeed: PodcastFeed?
        private let saveThreshold: Double = 0.05
        private var lastSavedProgress: Double = 0.0
       private var timeObserver: Any?
       private var playerItemObserver: NSKeyValueObservation?
       private var cancellables = Set<AnyCancellable>()
    private var lastSavedTime: TimeInterval = 0
        private let saveInterval: TimeInterval = 5
    @Published var currentProgress: Double = 0
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastPlayer")

    
    var onEpisodeStart: ((PodcastEpisode) -> Void)?

    
    weak var viewModel: PodcastViewModel?

    private init() {}
    
    func configure(with viewModel: PodcastViewModel) {
            self.viewModel = viewModel
        }
    
    func setRadioPlayer(_ player: RadioPlayer) {
           self.radioPlayer = player
       }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
            // Stop radio playback if it's playing
            stopRadioPlayback()
            
            var playUrl: URL?

            if let localFilePath = episode.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
                playUrl = URL(fileURLWithPath: localFilePath)
            } else if let url = URL(string: episode.audioUrl) {
                playUrl = url
            } else {
                return
            }

            guard let url = playUrl else { return }

            let playerItem = AVPlayerItem(url: url)
            if player == nil {
                player = AVPlayer(playerItem: playerItem)
            } else {
                player?.replaceCurrentItem(with: playerItem)
            }

            // Save progress of the previous episode before switching
            saveProgressIfNeeded()

            // Set the current episode and feed before playing
            currentEpisode = episode
            currentFeed = feed
            
            // Mark the episode as "In Progress" immediately
            if viewModel?.getProgress(for: episode) == 0 {
                viewModel?.updateProgress(for: episode, progress: 0.001)
            }

            // Load the saved progress
            if let savedProgress = viewModel?.episodeProgress[episode.id] {
                let targetTime = savedProgress * episode.duration
                player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1))
                currentTime = targetTime
            } else {
                currentTime = 0
            }

            duration = episode.duration

            // Set up observers
            setupPlayerItemObserver()
            setupTimeObserver()

            // Now play the episode
            play()
            isPlaying = true
        }
    
    private func setupPlayerItemObserver() {
           playerItemObserver?.invalidate()
           playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
               guard let self = self else { return }
               if playerItem.status == .readyToPlay {
                   self.duration = playerItem.duration.seconds
                   self.seekToSavedProgress()
               }
           }

           NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
           NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
               guard let self = self, let currentEpisode = self.currentEpisode else { return }

               // Mark the episode as "Played"
               self.viewModel?.markEpisodeAsCompleted(currentEpisode)

               // Stop the playback but don't reset current time
               self.pause()

               // Update the progress and now playing info
               self.updateProgress()
               self.updateNowPlayingInfo()

               // Notify observers of the change
               self.objectWillChange.send()
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
    
    private func loadProgress(for episodeId: String) -> Double? {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        return UserDefaults.standard.value(forKey: key) as? Double
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
            
            // Set up now playing information, observers, etc.
            setupNowPlaying(for: currentEpisode, feed: currentFeed)
            setupTimeObserver()
            updateNowPlayingInfo()

            objectWillChange.send()
        }
    
    func pause() {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        player.pause()
        isPlaying = false
        saveProgressIfNeeded()  // Progress is saved here
        
        updateNowPlayingInfo()
        objectWillChange.send()
    }
    
    private func saveProgress(for episodeId: String, progress: Double) {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        UserDefaults.standard.set(progress, forKey: key)
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
    
    private func saveProgressIfNeeded() {
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
    
    private func setupTimeObserver() {
            if let existingObserver = timeObserver {
                player?.removeTimeObserver(existingObserver)
            }

            let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                self.currentTime = time.seconds
                self.updateProgress()
            }
        }
    
    func getCurrentProgress(for episode: PodcastEpisode) -> Double {
                if currentEpisode?.id == episode.id {
                    return min(max(currentProgress, 0), 1)
                } else {
                    return min(max(viewModel?.getProgress(for: episode) ?? 0, 0), 1)
                }
            }
    
    private func observePlayerItem() {
        playerItemObserver?.invalidate()
        playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            guard let self = self else { return }
            if playerItem.status == .readyToPlay {
                self.updateDuration()
                self.seekPosition = self.currentTime // Update seek position as well
            }
        }
    }
    
    private func updateDuration() {
        if let currentItem = player?.currentItem, currentItem.status == .readyToPlay, currentItem.duration.seconds.isFinite {
            duration = currentItem.duration.seconds
        } else {
            duration = 0
        }
        updateNowPlayingInfo()
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
    
    private func clearProgress(for episodeId: String) {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        UserDefaults.standard.removeObject(forKey: key)
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
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
                return .success
            }
            return .commandFailed
        }
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
