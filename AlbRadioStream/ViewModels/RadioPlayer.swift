//
//  RadioPlayer.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import AVFoundation
import Combine
import UIKit

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    private var player: AVPlayer?
    private var cancellable: AnyCancellable?

    @Published var isPlaying = false
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var currentURL: String?
    @Published var currentStationIndex: Int = 0
    var stations: [RadioStation] = []

    private override init() {
        super.init()
        configureAudioSession()
    }

    func setStationURL(_ url: URL, index: Int? = nil) {
        player = AVPlayer(url: url)
        currentURL = url.absoluteString
        if let index = index {
            currentStationIndex = index
        }
        observePlayerState()
    }

    private func observePlayerState() {
        cancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
    }

    func playPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        currentURL = nil
    }

    func nextStation() {
        guard !stations.isEmpty else { return }
        currentStationIndex = (currentStationIndex + 1) % stations.count
        setStationURL(URL(string: stations[currentStationIndex].url)!, index: currentStationIndex)
        playPause()
    }

    func previousStation() {
        guard !stations.isEmpty else { return }
        currentStationIndex = (currentStationIndex - 1 + stations.count) % stations.count
        setStationURL(URL(string: stations[currentStationIndex].url)!, index: currentStationIndex)
        playPause()
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, options: [.allowBluetooth, .allowAirPlay])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
}
