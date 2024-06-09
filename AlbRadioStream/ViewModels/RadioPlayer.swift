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
    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?

    private override init() {
        super.init()
    }

    func setStationURL(_ url: URL) {
        player = AVPlayer(url: url)
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

    func playStation(at index: Int, from stations: [RadioStation]) {
        guard index >= 0 && index < stations.count else { return }
        currentStationIndex = index
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
