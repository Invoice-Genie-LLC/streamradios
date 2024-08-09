// RadioPlayer.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/8/24.
//

import AVFoundation
import Combine
import UIKit
import WidgetKit
import Network
import MediaPlayer
import BackgroundTasks
import SwiftUI
import Reachability
import SystemConfiguration

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusCancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let monitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private var wasPlayingBeforeNetworkLoss = false
    @Published var isBuffering = false
    @Published var isPlaying = false
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String?
    @Published var isHandlingAlarm = false
    @Published var currentlyPlayingStation: RadioStation?
    @Published var alarmStation: RadioStation?
    private var reachability: Reachability?
    private var isOnCellularNetwork = false
    @Published var currentPodcastEpisode: PodcastEpisode?
        @Published var isPodcastPlaying = false
    @Published var podcastProgress: [String: Double] = [:]
    @Published var currentPodcastTime: Double = 0.0
    @Published var currentPodcastDuration: Double = 1.0
    @Published var isSeeking: Bool = false

    private var timeObserver: Any?


    var currentPodcastProgress: Double {
            return currentPodcastDuration > 0 ? currentPodcastTime / currentPodcastDuration : 0
        }

    
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    
    var bitrateSubject = CurrentValueSubject<String, Never>("Playing at high bitrate: 256 kbps")
    private let userDefaultsSuiteName = "group.streamradios"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }
    
    var viewModel: RadioStationViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
            super.init()
            configureAudioSession()
            addInterruptionObserver()
            autoPlayLastStationSetup()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                self.isOnCellularNetwork = path.isExpensive
                self.adjustForNetworkConditions()
                self.updateBitrateBasedOnNetwork(path: path)
            }
            let queue = DispatchQueue(label: "NetworkMonitor")
            monitor.start(queue: queue)
        }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == #keyPath(AVPlayerItem.status) {
                let status: AVPlayerItem.Status
                if let statusNumber = change?[.newKey] as? NSNumber {
                    status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
                } else {
                    status = .unknown
                }
                
                // Check status and update duration
                if status == .readyToPlay {
                    if let duration = player?.currentItem?.duration {
                        currentPodcastDuration = CMTimeGetSeconds(duration)
                    }
                }
            }
        }

    func playPodcastEpisode(_ episode: PodcastEpisode) {
            guard let url = URL(string: episode.audioUrl) else { return }
            let playerItem = AVPlayerItem(url: url)
            
            if player == nil {
                player = AVPlayer(playerItem: playerItem)
            } else {
                player?.replaceCurrentItem(with: playerItem)
            }
            
            currentPodcastEpisode = episode
            currentPodcastTime = 0.0
            currentPodcastDuration = 0.0 // We'll update this once the item is ready to play
            
            // Observe the status of the player item
            playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new, .old], context: nil)
            
            player?.play()
            isPodcastPlaying = true
            
            setupTimeObserver()
        }
    
    func playPodcast() {
            guard currentPodcastEpisode != nil else {
                print("No podcast episode set to play")
                return
            }
            player?.play()
            isPodcastPlaying = true
            updateNowPlayingInfoForPodcast()
            updateWidgetForPodcast()
        }

        func pausePodcast() {
            guard currentPodcastEpisode != nil else {
                print("No podcast episode to pause")
                return
            }
            player?.pause()
            isPodcastPlaying = false
            updateNowPlayingInfoForPodcast()
        }

        func stopPodcast() {
            player?.pause()
            player = nil
            currentPodcastEpisode = nil
            isPodcastPlaying = false
            updateNowPlayingInfoForPodcast()
            updateWidgetForPodcast()
        }
    
    func skipForward() {
            seek(by: 15)
        }
        
    func rewind() {
            seek(by: -15)
        }
    
    func seek(by seconds: Double) {
            guard let player = player else { return }
            let newTime = min(max(currentPodcastTime + seconds, 0), currentPodcastDuration)
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
            currentPodcastTime = newTime
        }
    
    func seek(to time: Double) {
            guard let player = player else { return }
            let newTime = min(max(time, 0), currentPodcastDuration)
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
            currentPodcastTime = newTime
        }
    
    private func updatePodcastProgress() {
            guard let currentEpisode = currentPodcastEpisode, currentPodcastDuration > 0 else { return }
            let progress = currentPodcastTime / currentPodcastDuration
            podcastProgress[currentEpisode.id] = progress
        }

        // ... (other methods remain the same)

        deinit {
            if let timeObserver = timeObserver {
                player?.removeTimeObserver(timeObserver)
            }
            player?.currentItem?.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        }
    
    
    private func setupTimeObserver() {
            let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self, !self.isSeeking else { return }
                self.currentPodcastTime = time.seconds
                self.updatePodcastProgress()
            }
        }
    
    private func updateNowPlayingInfoForPodcast() {
           guard let episode = currentPodcastEpisode else { return }

           var nowPlayingInfo = [String: Any]()
           nowPlayingInfo[MPMediaItemPropertyTitle] = episode.title
           nowPlayingInfo[MPMediaItemPropertyArtist] = episode.feed.title
           nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = episode.feed.title
           nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds
           nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = episode.duration
           nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPodcastPlaying ? 1.0 : 0.0

           if let artworkUrlString = episode.feed.artworkUrl, let artworkUrl = URL(string: artworkUrlString) {
               // Load artwork asynchronously
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
           print("Updated now playing info for podcast: \(nowPlayingInfo)")
       }
    
    private func updateWidgetForPodcast() {
            guard let episode = currentPodcastEpisode else { return }

            userDefaults?.set(episode.title, forKey: "podcastEpisodeTitle")
            userDefaults?.set(episode.feed.title, forKey: "podcastTitle")
            userDefaults?.set(episode.feed.artworkUrl, forKey: "podcastArtworkUrl")

            WidgetCenter.shared.reloadAllTimelines()
            print("Widget updated for podcast episode: \(episode.title)")
        }
    
    private func updateBitrateText(_ bitrate: Double) {
        let bitrateMessage = "Playing at \(Int(bitrate / 1000)) kbps"
        bitrateSubject.send(bitrateMessage)
        print("Bitrate text updated to: \(bitrateMessage)")
    }
    
    func autoPlayLastStationSetup() {
        if autoPlayLastStation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Only auto-play if we're not currently handling an alarm
                if !self.isHandlingAlarm {
                    if let lastStationID = UserDefaults.standard.string(forKey: "LastPlayedStationID"),
                       let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) {
                        // Play the last played station
                        self.currentlyPlayingStation = lastStation
                        if let url = URL(string: lastStation.url) {
                            self.setStationURL(url)
                            if let index = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                                self.currentStationIndex = index
                                UserDefaults.standard.set(index, forKey: "lastStationIndex")
                            }
                            self.play()
                        }
                    } else if let lastStationURL = self.userDefaults?.url(forKey: "lastStationURL") {
                        // Fall back to the old method if LastPlayedStationID is not available
                        self.setStationURL(lastStationURL)
                        self.currentStationIndex = self.userDefaults?.integer(forKey: "lastStationIndex")
                        if let index = self.currentStationIndex,
                           index < self.viewModel?.stations.count ?? 0 {
                            self.currentlyPlayingStation = self.viewModel?.stations[index]
                        }
                        self.play()
                    }
                }
            }
        }
    }
    
    func resetAlarmState() {
        isHandlingAlarm = false
    }
    
    func setViewModel(_ viewModel: RadioStationViewModel) {
        self.viewModel = viewModel
        
        // Observe changes in the stations array
        viewModel.$stations
            .sink { [weak self] _ in
                self?.updateNowPlayingInfo()
            }
            .store(in: &cancellables)
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Set the audio session category to playback
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay, .interruptSpokenAudioAndMixWithOthers])
            
            // Override the output audio port to speaker
            try audioSession.overrideOutputAudioPort(.speaker)
            
            // Activate the audio session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Set the preferred IO buffer duration
            try audioSession.setPreferredIOBufferDuration(0.005)
            
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    func addInterruptionObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    private func adjustForNetworkConditions() {
        if isOnCellularNetwork {
            player?.currentItem?.preferredForwardBufferDuration = 20
            player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        } else {
            player?.currentItem?.preferredForwardBufferDuration = 5
            player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .began {
            // Interruption began, pause the player
            player?.pause()
        } else if type == .ended {
            // Interruption ended, reactivate the audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume playback if it should resume
                    player?.play()
                }
            } catch {
                print("Failed to reactivate audio session: \(error)")
            }
        }
    }
    
    @objc private func checkNetworkAndRetry() {
        if isNetworkAvailable && wasPlayingBeforeNetworkLoss && !isPlaying {
            retryStreamIfNeeded()
        }
    }
    
    private func retryStream() {
        guard let currentPlayerItem = player?.currentItem,
              let asset = currentPlayerItem.asset as? AVURLAsset else { return }
        
        let currentTime = currentPlayerItem.currentTime()
        let newPlayerItem = AVPlayerItem(url: asset.url)
        newPlayerItem.preferredPeakBitRate = currentPlayerItem.preferredPeakBitRate
        
        player?.replaceCurrentItem(with: newPlayerItem)
        player?.seek(to: currentTime)
        player?.play()
    }
    
    private func resetRetryCount() {
        retryCount = 0
        retryTimer?.invalidate()
    }
    
    private func retryStreamIfNeeded() {
        if !isPlaying && wasPlayingBeforeNetworkLoss {
            retryStream()
        }
    }
    
    private func setStationURL(_ url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.automaticallyWaitsToMinimizeStalling = true
        userDefaults?.set(url, forKey: "lastStationURL")
        
        // Cancel previous observer if it exists
        statusCancellable?.cancel()
        
        // Set up observers
        statusCancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.isPlaying = (status == .playing)
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                print("Set station URL: isPlaying = \(self.isPlaying), isBuffering = \(self.isBuffering)")
                self.updateNowPlayingInfo()
            }
        
        // Set the bitrate and add metadata output
        updateBitrateBasedOnNetwork(path: monitor.currentPath)
        
        addMetadataOutput()
    }
    
    private func updateBitrateBasedOnNetwork(path: NWPath) {
            DispatchQueue.main.async {
                print("Network status: \(path.status == .satisfied ? "Connected" : "Disconnected")")
                
                if path.usesInterfaceType(.cellular) {
                    print("Network type: Cellular")
                    if path.isConstrained {
                        print("Network is constrained. Updating bitrate text to 64 kbps.")
                        self.updateBitrateText(64000) // 64 kbps
                    } else if path.isExpensive {
                        print("Network is expensive. Updating bitrate text to 96 kbps.")
                        self.updateBitrateText(96000) // 96 kbps
                    } else {
                        print("Normal cellular network. Updating bitrate text to 128 kbps.")
                        self.updateBitrateText(128000) // 128 kbps
                    }
                } else if path.usesInterfaceType(.wifi) {
                    print("Network type: Wi-Fi. Updating bitrate text to 256 kbps.")
                    self.updateBitrateText(256000) // 256 kbps
                } else {
                    print("Unknown network type. Updating bitrate text to 128 kbps.")
                    self.updateBitrateText(128000) // 128 kbps
                }
            }
        }
    
    func resumePlayback() {
        if let player = player, !isPlaying {
            player.play()
            isPlaying = true
        }
    }
    
    private func setBitrate(_ bitrate: Double) {
        guard let playerItem = player?.currentItem else { return }
        let currentBitrate = playerItem.preferredPeakBitRate
        print("Current bitrate: \(currentBitrate), New bitrate: \(bitrate)")
        
        if currentBitrate != bitrate {
            playerItem.preferredPeakBitRate = bitrate
            updateBitrateText(bitrate)
        } else {
            print("Bitrate remains unchanged at \(bitrate)")
        }
        
        // Ensure metadata output is added
        addMetadataOutput()
    }
    
    private func performReachabilityCheck(completion: @escaping (Bool) -> Void) {
        reachability = try? Reachability()
        
        reachability?.whenReachable = { reachability in
            DispatchQueue.main.async {
                completion(true)
            }
            reachability.stopNotifier()
        }
        
        reachability?.whenUnreachable = { _ in
            DispatchQueue.main.async {
                completion(false)
            }
            self.reachability.unsafelyUnwrapped.stopNotifier()
        }
        
        do {
            try reachability?.startNotifier()
        } catch {
            completion(false)
        }
    }
    
    private func addMetadataOutput() {
        guard let currentItem = player?.currentItem else {
            print("No current item found in player.")
            return
        }
        let metadataOutput = AVPlayerItemMetadataOutput()
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        currentItem.add(metadataOutput)
        print("Metadata output added to player item.")
    }
    
    func playPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
            resetRetryCount()
        }
        updateNowPlayingInfo()
        updateWidget()
    }
    
    func play() {
        guard let player = player else { return }
        // Ensure the player is properly set up with the current station URL
        if player.currentItem?.asset as? AVURLAsset == nil,
           let lastStationURL = userDefaults?.url(forKey: "lastStationURL") {
            setStationURL(lastStationURL)
        }
        player.play()
        isPlaying = true
        resetRetryCount()
        updateNowPlayingInfo()
        updateWidget()
        scheduleAppRefresh()
    }
    
    func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func togglePlayPause() {
            if isPlaying {
                pause()
            } else {
                play()
            }
        }
    
    func stop() {
           player?.pause()
           player = nil
           currentStationIndex = nil
           isPlaying = false
           metadata = nil
       }
    
    func playStation(at index: Int, from stations: [RadioStation]) {
        guard index >= 0 && index < stations.count else { return }
        
        stopCurrentStation()
        currentStationIndex = index
        metadata = nil // Clear metadata when switching stations
        let station = stations[index]
        currentlyPlayingStation = station
        
        if let url = URL(string: station.url) {
            setStationURL(url)
            play()
        }
        
        isPlaying = true  // Set isPlaying to true when starting a new station
        updateNowPlayingInfo()
        updateWidget()
        updateLastPlayed(station)
        saveLastPlayedStation()
    }
    
    func playStationForAlarm(station: RadioStation) {
        print("Playing station for alarm: \(station.name)")
        guard let url = URL(string: station.url) else {
            print("Invalid URL for station: \(station.name)")
            return
        }

        setStationURL(url)
        play()
        alarmStation = station
    }
    
    func stopCurrentStation() {
        player?.pause()
        player = nil
        isPlaying = false
        updateNowPlayingInfo()
        currentlyPlayingStation = nil
    }
    
    func nextStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
                let nextIndex = (currentIndex + 1) % stations.count
                playStation(at: nextIndex, from: stations)
                updateLastPlayed(stations[nextIndex])
    }
    
    func previousStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
               let previousIndex = (currentIndex - 1 + stations.count) % stations.count
               playStation(at: previousIndex, from: stations)
               updateLastPlayed(stations[previousIndex])
    }
    
    private func updateLastPlayed(_ station: RadioStation) {
           viewModel?.updateLastPlayed(for: station)
       }
    
     func saveLastPlayedStation() {
        if let currentStation = currentlyPlayingStation {
            UserDefaults.standard.set(currentStation.id, forKey: "LastPlayedStationID")
            if let index = viewModel?.stations.firstIndex(where: { $0.id == currentStation.id }) {
                UserDefaults.standard.set(index, forKey: "lastStationIndex")
            }
        }
    }

    private func loadLastPlayedStation() {
        if let lastStationID = UserDefaults.standard.string(forKey: "LastPlayedStationID"),
           let lastStation = viewModel?.stations.first(where: { $0.id == lastStationID }) {
            currentlyPlayingStation = lastStation
            if let url = URL(string: lastStation.url) {
                setStationURL(url)
                play()
            }
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let viewModel = viewModel else { return }
        
        var nowPlayingInfo = [String: Any]()
        
        let currentStation: RadioStation?
        if isHandlingAlarm {
            currentStation = alarmStation
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < viewModel.stations.count {
            currentStation = viewModel.stations[currentStationIndex]
        } else {
            currentStation = nil
        }
        
        if let station = currentStation {
            nowPlayingInfo[MPMediaItemPropertyTitle] = songTitle.isEmpty ? station.name : songTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName.isEmpty ? (metadata ?? station.name) : artistName
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let albumArt = albumArt {
            let artwork = MPMediaItemArtwork(boundsSize: albumArt.size) { size in
                return albumArt
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let station = currentStation,
                  let iconData = station.iconData,
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("Updated now playing info: \(nowPlayingInfo)")
    }
    
    private func updateWidget() {
        guard let currentStationIndex = currentStationIndex, let viewModel = viewModel else { return }
        
        guard currentStationIndex < viewModel.stations.count else {
            return
        }
        
        let currentStation = viewModel.stations[currentStationIndex]
        let metadata = self.metadata ?? "No song or album title available"
        
        userDefaults?.set(currentStation.name, forKey: "stationName")
        userDefaults?.set(currentStation.iconData, forKey: "stationIcon")
        userDefaults?.set(metadata, forKey: "stationMetadata")
        
        WidgetCenter.shared.reloadAllTimelines()
        print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
    }
    
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            if self?.currentPodcastEpisode != nil {
                self?.playPodcast()
            } else {
                self?.play()
            }
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            if self?.currentPodcastEpisode != nil {
                self?.pausePodcast()
            } else {
                self?.pause()
            }
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            if let self = self {
                if self.currentPodcastEpisode != nil {
                    // Implement next podcast episode logic here
                    // For now, we'll just return success
                    return .success
                } else if let viewModel = self.viewModel {
                    self.nextStation(from: viewModel.stations)
                    return .success
                }
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            if let self = self {
                if self.currentPodcastEpisode != nil {
                    // Implement previous podcast episode logic here
                    // For now, we'll just return success
                    return .success
                } else if let viewModel = self.viewModel {
                    self.previousStation(from: viewModel.stations)
                    return .success
                }
            }
            return .commandFailed
        }
        
        // Add seek forward and backward commands for podcasts
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            if let self = self, self.currentPodcastEpisode != nil {
                self.seekForward()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            if let self = self, self.currentPodcastEpisode != nil {
                self.seekBackward()
                return .success
            }
            return .commandFailed
        }
    }

    // Add these methods to your RadioPlayer class
    func seekForward() {
        guard let player = player, currentPodcastEpisode != nil else { return }
        let newTime = player.currentTime() + CMTime(seconds: 15, preferredTimescale: 1)
        player.seek(to: newTime)
    }

    func seekBackward() {
        guard let player = player, currentPodcastEpisode != nil else { return }
        let newTime = player.currentTime() - CMTime(seconds: 15, preferredTimescale: 1)
        player.seek(to: newTime)
    }
    
    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.radio.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // Refresh every 15 minutes.
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            // Clean up any resources before the task expires.
        }
        
        checkNetworkAndRetry()
        
        task.setTaskCompleted(success: true)
    }
    
    
}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from playerItemTrack: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                if let commonKey = item.commonKey, commonKey.rawValue == "title" {
                    item.loadValuesAsynchronously(forKeys: ["stringValue"]) { [weak self] in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            if let stringValue = item.stringValue, !stringValue.isEmpty {
                                self.metadata = stringValue
                                self.updateNowPlayingInfo()
                                self.updateWidget()
                            } else if self.metadata == nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    if self.metadata == nil || self.metadata?.isEmpty == true {
                                        self.metadata = "No song or album title available"
                                        self.updateNowPlayingInfo()
                                        self.updateWidget()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let NetworkReconnectNotification = Notification.Name("NetworkReconnectNotification")
}

extension RadioPlayer {
    func playFavoriteStationForAlarm() {
        print("playFavoriteStationForAlarm called")
        isHandlingAlarm = true
        
        if let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID"),
           let favoriteStation = viewModel?.stations.first(where: { $0.id == favoriteStationID }) {
            print("Playing saved favorite station for alarm: \(favoriteStation.name)")
            alarmStation = favoriteStation
            playStationForAlarm(station: favoriteStation)
        } else {
            print("Error: No valid favorite station found for alarm")
            alarmStation = nil
        }
    }
}
