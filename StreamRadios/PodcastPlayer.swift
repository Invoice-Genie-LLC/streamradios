//
//  PodcastPlayer.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/9/24.
//

import AVFoundation
import Combine
import MediaPlayer

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
    
    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupRemoteCommandCenter()
    }
    
    func playEpisode(_ episode: PodcastEpisode) {
        guard let url = URL(string: episode.audioUrl) else { return }
        
        let playerItem = AVPlayerItem(url: url)
        
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        
        currentEpisode = episode
        play()
    }
    
    func play() {
            if radioPlayer?.isPlaying == true {
                radioPlayer?.pause()
            }
            
            guard let player = player, let currentEpisode = currentEpisode else { return }
            
            player.play()
            isPlaying = true
            
            setupNowPlaying(for: currentEpisode)
            setupTimeObserver()
            observePlayerItem()
            
            updateNowPlayingInfo()
            objectWillChange.send()
        }
    
    func pause() {
            guard let player = player else { return }
            
            player.pause()
            isPlaying = false
            
            updateNowPlayingInfo()
            objectWillChange.send()
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
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
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
        updateNowPlayingInfo()
    }
    
    private func setupNowPlaying(for episode: PodcastEpisode) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = episode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = episode.feed.title
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = episode.feed.title
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let artworkUrlString = episode.feed.artworkUrl, let artworkUrl = URL(string: artworkUrlString) {
            URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                if let data = data, let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                    DispatchQueue.main.async {
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                    }
                }
            }.resume()
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
