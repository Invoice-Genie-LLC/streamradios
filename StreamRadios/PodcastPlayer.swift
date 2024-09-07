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
    var remainingTime: Double {
            max(0, duration - currentTime)
        }
    
    private init() {}
    
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
                    duration = episode.duration
                    currentProgress = 0
        }
        
        // Set up observers
        setupPlayerItemObserver()
        setupTimeObserver()
        
        if let playerItem = player?.currentItem {
                duration = playerItem.asset.duration.seconds
            }
        
        // Now play the episode
        play()
        isPlaying = true
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
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
