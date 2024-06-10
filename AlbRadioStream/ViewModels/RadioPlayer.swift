// RadioPlayer.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/8/24.
//

import AVFoundation
import Combine
import UIKit

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    var player: AVPlayer?
    private var statusCancellable: AnyCancellable?
    
    @Published var isPlaying = false
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String = ""

    private override init() {
        super.init()
        configureAudioSession()
        if UserDefaults.standard.bool(forKey: "autoPlayLastStation"),
           let lastStationURL = UserDefaults.standard.url(forKey: "lastStationURL") {
            setStationURL(lastStationURL)
            currentStationIndex = UserDefaults.standard.integer(forKey: "lastStationIndex")
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

    func setStationURL(_ url: URL) {
        player = AVPlayer(url: url)
        UserDefaults.standard.set(url, forKey: "lastStationURL")

        // Cancel previous observer if it exists
        statusCancellable?.cancel()

        // Set up observers
        statusCancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
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
        }
    }

    func play() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
    }

    func playStation(at index: Int, from stations: [RadioStation]) {
        guard index >= 0 && index < stations.count else { return }
        currentStationIndex = index
        metadata = "" // Clear metadata when switching stations
        UserDefaults.standard.set(index, forKey: "lastStationIndex")
        let station = stations[index]
        if let url = URL(string: station.url) {
            setStationURL(url)
            play()
        }
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
                                }
                            } else {
                                self.metadata = ""
                            }
                        }
                    }
                }
            }
        }
    }
}
