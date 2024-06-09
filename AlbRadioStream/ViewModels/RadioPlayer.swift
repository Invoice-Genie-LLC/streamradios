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
    private var player: AVPlayer?
    private var cancellable: AnyCancellable?
    
    @Published var isPlaying = false
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?

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
        UserDefaults.standard.set(url, forKey: "lastStationURL") // Save the URL
        cancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
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
        UserDefaults.standard.set(index, forKey: "lastStationIndex") // Save the index
        let station = stations[index]
        if let url = URL(string: station.url) {
            setStationURL(url)
            playPause()
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
