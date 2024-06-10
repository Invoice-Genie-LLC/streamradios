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

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var statusCancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var networkRetryTimer: Timer?
    private var retryCount = 0
    private let maxRetryCount = 5
    private let monitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private var wasPlayingBeforeNetworkLoss = false
    @Published var isBuffering = false

    @Published var isPlaying = false
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String = ""

    private let userDefaultsSuiteName = "group.radio.AlbRadioStream"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }

    private override init() {
        super.init()
        configureAudioSession()
        startNetworkMonitoring()
        addObservers()
        if let userDefaults = userDefaults,
           userDefaults.bool(forKey: "autoPlayLastStation"),
           let lastStationURL = userDefaults.url(forKey: "lastStationURL") {
            setStationURL(lastStationURL)
            currentStationIndex = userDefaults.integer(forKey: "lastStationIndex")
            play()
        }
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
            if path.status == .satisfied {
                print("Network connected")
                self.isNetworkAvailable = true
                self.retryStreamIfNeeded()
                if self.wasPlayingBeforeNetworkLoss {
                    // Ensure a fresh connection
                    if let userDefaults = self.userDefaults,
                       let lastStationURL = userDefaults.url(forKey: "lastStationURL") {
                        self.setStationURL(lastStationURL)
                        self.play()
                    }
                }
            } else {
                print("Network disconnected")
                self.isNetworkAvailable = false
                self.wasPlayingBeforeNetworkLoss = self.isPlaying
                if self.isPlaying {
                    self.pause()
                }
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)

        // Start periodic network check
        networkRetryTimer = Timer.scheduledTimer(timeInterval: 10.0, target: self, selector: #selector(checkNetworkAndRetry), userInfo: nil, repeats: true)
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
        retryCount += 1
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.refreshStream()
        }
        print("Retrying stream, attempt \(retryCount)")
    }

    private func refreshStream() {
        guard let lastStationURL = userDefaults?.url(forKey: "lastStationURL") else { return }
        setStationURL(lastStationURL)
        play()
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

    func setStationURL(_ url: URL) {
        player = AVPlayer(url: url)
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
        addMetadataOutput()
    }

    private func addMetadataOutput() {
        let metadataOutput = AVPlayerItemMetadataOutput()
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        player?.currentItem?.add(metadataOutput)
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
    }

    func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func playStation(at index: Int, from stations: [RadioStation]) {
        guard index >= 0 && index < stations.count else { return }
        currentStationIndex = index
        metadata = "" // Clear metadata when switching stations
        userDefaults?.set(index, forKey: "lastStationIndex")
        let station = stations[index]
        if let url = URL(string: station.url) {
            setStationURL(url)
            play()
        }
        updateNowPlayingInfo()
        updateWidget()
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
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = songTitle.isEmpty ? "Unknown Title" : songTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = artistName.isEmpty ? "Unknown Artist" : artistName
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let albumArt = albumArt {
            let artwork = MPMediaItemArtwork(boundsSize: albumArt.size) { size in
                return albumArt
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < RadioStationViewModel().stations.count {
            let currentStation = RadioStationViewModel().stations[currentStationIndex]
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
        guard let currentStationIndex = currentStationIndex else { return }
        let viewModel = RadioStationViewModel()

        guard currentStationIndex < viewModel.stations.count else {
            return
        }

        let currentStation = viewModel.stations[currentStationIndex]
        let metadata = self.metadata

        userDefaults?.set(currentStation.name, forKey: "stationName")
        userDefaults?.set(currentStation.iconData, forKey: "stationIcon")
        userDefaults?.set(metadata, forKey: "stationMetadata")

        WidgetCenter.shared.reloadAllTimelines()
        print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
    }
}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from playerItemTrack: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                if item.commonKey?.rawValue == "title" {
                    item.loadValuesAsynchronously(forKeys: ["stringValue"]) { [weak self] in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            if let stringValue = item.stringValue {
                                // Only update metadata if the station has not changed
                                if self.currentStationIndex == self.currentStationIndex {
                                    self.metadata = stringValue
                                    self.updateNowPlayingInfo()
                                    self.updateWidget()
                                }
                            } else {
                                self.metadata = ""
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
