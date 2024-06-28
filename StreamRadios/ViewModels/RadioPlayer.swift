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

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var statusCancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let monitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private var wasPlayingBeforeNetworkLoss = false
    var audioPlayer: AVPlayer?
    @Published var isBuffering = false
    @Published var isPlaying = false
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String?
    @Published var currentBitrate: Int? = nil
    private var reachability: Reachability?
    
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    
    var bitrateSubject = CurrentValueSubject<String, Never>("Playing at high bitrate: 256 kbps")
    private let userDefaultsSuiteName = "group.streamradios"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }
    
    private var viewModel: RadioStationViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        configureAudioSession()
        startNetworkMonitoring()
        addObservers()
        autoPlayLastStationSetup()
        
        // Register background task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.radio.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    private func autoPlayLastStationSetup() {
        if autoPlayLastStation, let lastStationURL = userDefaults?.url(forKey: "lastStationURL") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.setStationURL(lastStationURL)
                self.currentStationIndex = self.userDefaults?.integer(forKey: "lastStationIndex")
                self.play()
            }
        }
    }
    
    func getCurrentTime() -> TimeInterval {
        return audioPlayer?.currentTime().seconds ?? 0
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
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            // Log the network status and type
            if path.status == .satisfied {
                print("Network connected")
                self.isNetworkAvailable = true
                NotificationCenter.default.post(name: .NetworkReconnectNotification, object: nil)
                if self.wasPlayingBeforeNetworkLoss {
                    self.retryStream()
                }
            } else {
                print("Network disconnected")
                self.isNetworkAvailable = false
                self.wasPlayingBeforeNetworkLoss = self.isPlaying
                if self.isPlaying {
                    self.pause()
                }
            }

            // Log detailed network properties
            print("Interface types: \(path.availableInterfaces.map { $0.type })")
            print("Is constrained: \(path.isConstrained)")
            print("Is expensive: \(path.isExpensive)")

            // Update bitrate based on network type and conditions
            self.updateBitrateBasedOnNetwork()
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
    }

    private func startBuffering() {
        isBuffering = true
        retryStream()
    }
    
    private func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidStall), name: .AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidFailToPlayToEnd), name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        
        // Add KVO observers for buffering and playing state
        addObserver(self, forKeyPath: #keyPath(player.currentItem.isPlaybackBufferEmpty), options: [.new, .old], context: nil)
        addObserver(self, forKeyPath: #keyPath(player.currentItem.isPlaybackLikelyToKeepUp), options: [.new, .old], context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(player.currentItem.isPlaybackBufferEmpty) {
            if let isEmpty = change?[.newKey] as? Bool {
                isBuffering = isEmpty
                updateNowPlayingInfo()
            }
        } else if keyPath == #keyPath(player.currentItem.isPlaybackLikelyToKeepUp) {
            if let isLikelyToKeepUp = change?[.newKey] as? Bool {
                isBuffering = !isLikelyToKeepUp
                updateNowPlayingInfo()
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    @objc private func playerItemDidStall(notification: Notification) {
        retryStream()
    }
    
    @objc private func playerItemDidFailToPlayToEnd(notification: Notification) {
        retryStream()
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
    
    private func refreshStream() {
        guard let lastStationURL = userDefaults?.url(forKey: "lastStationURL") else { return }
        setStationURL(lastStationURL)
        player?.seek(to: .zero)
        player?.play()
        resetRetryCount()
        print("Stream refreshed")
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
        updateBitrateBasedOnNetwork()
    }
    
    private func updateBitrateBasedOnNetwork() {
        let path = monitor.currentPath

        DispatchQueue.main.async {
            print("Network status: \(path.status == .satisfied ? "Connected" : "Disconnected")")

            if path.usesInterfaceType(.cellular) {
                print("Network type: Cellular")

                self.performReachabilityCheck { isReachable in
                    if !isReachable {
                        print("Cellular network is not reachable. Setting bitrate to 64 kbps.")
                        self.setBitrate(64000) // 64 kbps
                    } else if path.isConstrained {
                        print("Network is constrained. Setting bitrate to 64 kbps.")
                        self.setBitrate(64000) // 64 kbps
                    } else if path.isExpensive {
                        print("Network is expensive. Setting bitrate to 96 kbps.")
                        self.setBitrate(96000) // 96 kbps
                    } else {
                        print("Normal cellular network. Setting bitrate to 128 kbps.")
                        self.setBitrate(128000) // 128 kbps
                    }
                }
            } else if path.usesInterfaceType(.wifi) {
                print("Network type: Wi-Fi. Setting bitrate to 256 kbps.")
                self.setBitrate(256000) // 256 kbps
            } else {
                print("Unknown network type. Setting bitrate to 128 kbps.")
                self.setBitrate(128000) // 128 kbps
            }
        }
    }
    
    private func setBitrate(_ bitrate: Double) {
        guard let playerItem = player?.currentItem else { return }
        let currentBitrate = playerItem.preferredPeakBitRate
        print("Current bitrate: \(currentBitrate), New bitrate: \(bitrate)")
        
        if currentBitrate != bitrate {
            playerItem.preferredPeakBitRate = bitrate
            let bitrateMessage = "Playing at \(bitrate / 1000) kbps"
            bitrateSubject.send(bitrateMessage)
            print("Bitrate updated to \(bitrate)")
            self.retryStream()
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
    
    func playStation(at index: Int, from stations: [RadioStation]) {
        guard index >= 0 && index < stations.count else { return }
        stopCurrentStation()
        currentStationIndex = index
        metadata = nil // Clear metadata when switching stations
        userDefaults?.set(index, forKey: "lastStationIndex")
        let station = stations[index]
        if let url = URL(string: station.url) {
            setStationURL(url)
            play()
        }
        updateNowPlayingInfo()
        updateWidget()
    }
    
    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
    }
    
    func stopCurrentStation() {
        player?.pause()
        player = nil
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func nextStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
        let nextIndex = (currentIndex + 1) % stations.count
        playStation(at: nextIndex, from: stations)
    }
    
    func previousStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
        let previousIndex = (currentIndex - 1 + stations.count) % stations.count
        playStation(at: previousIndex, from: stations)
    }
    
    private func updateNowPlayingInfo() {
        guard let viewModel = viewModel else { return }
        
        var nowPlayingInfo = [String: Any]()
        if let currentStationIndex = currentStationIndex,
           currentStationIndex < viewModel.stations.count {
            let currentStation = viewModel.stations[currentStationIndex]
            nowPlayingInfo[MPMediaItemPropertyTitle] = songTitle.isEmpty ? currentStation.name : songTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName.isEmpty ? (metadata ?? currentStation.name) : artistName
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let albumArt = albumArt {
            let artwork = MPMediaItemArtwork(boundsSize: albumArt.size) { size in
                return albumArt
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < viewModel.stations.count {
            let currentStation = viewModel.stations[currentStationIndex]
            if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
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
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.pause()
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            if let self = self, let viewModel = self.viewModel {
                self.nextStation(from: viewModel.stations)
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            if let self = self, let viewModel = self.viewModel {
                self.previousStation(from: viewModel.stations)
                return .success
            }
            return .commandFailed
        }
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
