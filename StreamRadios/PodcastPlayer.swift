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

class PodcastPlayer: ObservableObject, AudioPlayerProtocol {
    static let shared = PodcastPlayer()
    
    weak var radioPlayer: RadioPlayer?
    
    private var player: AVPlayer?
    @Published var currentEpisode: PodcastEpisode?
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isSeeking = false
    @Published var progress: [String: Double] = [:]
    @Published var currentFeed: PodcastFeed?

    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupRemoteCommandCenter()
    }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        var playUrl: URL?

        // Prefer the local file if it exists and is accessible
        if let localFilePath = episode.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
            playUrl = URL(fileURLWithPath: localFilePath)
            os_log("Playing episode from local file: %@", log: OSLog.default, type: .info, localFilePath)
        } else {
            // Only fall back to streaming if the local file is not available
            os_log("Local file not found or unavailable. Attempting to stream.", log: OSLog.default, type: .error)
            if let url = URL(string: episode.audioUrl), ReachabilityCheck.isConnectedToNetwork() {
                playUrl = url
                os_log("Playing episode from streaming URL: %@", log: OSLog.default, type: .info, episode.audioUrl)
            } else {
                os_log("Cannot play episode. No internet connection and local file is unavailable.", log: OSLog.default, type: .error)
                return
            }
        }

        guard let url = playUrl else {
            os_log("Failed to create play URL for episode: %@", log: OSLog.default, type: .error, episode.title)
            return
        }

        let playerItem = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        currentEpisode = episode
        currentFeed = feed

        // Check if there's saved progress for this episode
        if let savedProgress = loadProgress(for: episode.id) {
            let time = CMTime(seconds: savedProgress * episode.duration, preferredTimescale: 1)
            player?.seek(to: time)
        }

        play()
    }

    private func loadProgress(for episodeId: String) -> Double? {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        return UserDefaults.standard.value(forKey: key) as? Double
    }

    func play() {
        guard let player = player else { return }
        
        // Safely unwrap the currentEpisode and currentFeed
        guard let currentEpisode = currentEpisode, let currentFeed = currentFeed else {
            os_log("No current episode or feed available", log: OSLog.default, type: .error)
            return
        }
        
        player.play()
        isPlaying = true
        
        // Set up now playing information and observers
        setupNowPlaying(for: currentEpisode, feed: currentFeed)
        setupTimeObserver()
        observePlayerItem()
        updateNowPlayingInfo()
        
        objectWillChange.send()
    }

    
    func pause() {
        guard let player = player else { return }
        
        player.pause()
        isPlaying = false
        
        // Save current progress
        if let currentEpisode = currentEpisode {
            let progress = currentTime / duration
            saveProgress(for: currentEpisode.id, progress: progress)
        }
        
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
            play()
        }
    }
    
    private func stopRadioPlayback() {
        if let radioPlayer = radioPlayer as? RadioPlayer, radioPlayer.isPlaying {
            radioPlayer.pause()
        }
    }
    
    func seek(to time: Double) {
        guard let player = player else { return }
        let targetTime = CMTime(seconds: time, preferredTimescale: 1)
        player.seek(to: targetTime) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
        currentTime = time
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
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = time.seconds
            self.updateProgress()
        }
    }
    
    private func observePlayerItem() {
        playerItemObserver?.invalidate()
        playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            if playerItem.status == .readyToPlay {
                self?.updateDuration()
            }
        }
    }
    
    private func updateDuration() {
        if let currentItem = player?.currentItem,
           currentItem.status == .readyToPlay,
           currentItem.duration.seconds.isFinite {
            duration = currentItem.duration.seconds
        } else {
            duration = 0
        }
        updateNowPlayingInfo()
    }
    
    private func updateProgress() {
        guard let episodeId = currentEpisode?.id, duration > 0 else { return }
        let progress = currentTime / duration
        self.progress[episodeId] = progress
        saveProgress(for: episodeId, progress: progress)
        updateNowPlayingInfo()
    }
    
    private func clearProgress(for episodeId: String) {
        let key = UserDefaultsKeys.progressKey(for: episodeId)
        UserDefaults.standard.removeObject(forKey: key)
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
