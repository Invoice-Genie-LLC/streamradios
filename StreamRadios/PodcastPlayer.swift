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
    }
    
    private func setupPlayerItemObserver() {
            playerItemObserver?.invalidate()
            playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
                guard let self = self else { return }
                if playerItem.status == .readyToPlay {
                    self.duration = playerItem.duration.seconds
                    self.updateProgress()
                }
            }
            
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
                guard let self = self, let currentEpisode = self.currentEpisode else { return }
                self.viewModel?.markEpisodeAsCompleted(currentEpisode)
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
        
        player.play()
        isPlaying = true
        
        // Set up now playing information, observers, etc.
        setupNowPlaying(for: currentEpisode, feed: currentFeed)
        setupTimeObserver()
        updateNowPlayingInfo()

        objectWillChange.send()
    }
    
    func pause() {
            guard let player = player else { return }
            
            player.pause()
            isPlaying = false
            saveProgressIfNeeded()
            
            updateNowPlayingInfo()
            objectWillChange.send()
        }
    
    private func saveProgress(for episodeId: String, progress: Double) {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        UserDefaults.standard.set(progress, forKey: key)
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
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
       }
    
    func skipForward() {
        seek(by: 15)
    }
    
    func skipBackward() {
        seek(by: -15)
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
            timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                self.currentTime = time.seconds
                self.updateProgress()
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
            
            if currentTime - lastSavedTime >= saveInterval {
                viewModel?.updateProgress(for: currentEpisode, progress: progress)
                lastSavedTime = currentTime
            }
        }
    
    private func clearProgress(for episodeId: String) {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    func handleAppWillTerminate() {
            saveProgressIfNeeded()
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
