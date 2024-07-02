//
//  ShazamViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import SwiftUI
import ShazamKit
import AVKit

struct ShazamMedia: Decodable {
    let title: String?
    let subtitle: String?
    let artistName: String?
    let albumArtURL: URL?
    let genres: [String]
    var lyrics: String?  // Optional to handle cases where lyrics might not be available
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var isFetchingLyrics = false
    
    private var audioEngine = AVAudioEngine()
    private var session = SHSession()
    
    override init() {
        super.init()
        session.delegate = self
        configureAudioSession()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up the audio session: \(error)")
        }
    }
    
    public func startOrEndListening() {
        guard !audioEngine.isRunning else {
            stopListening()
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self, granted else {
                DispatchQueue.main.async {
                    print("Microphone permission is denied")
                }
                return
            }
            self.setupAudioEngine()
        }
    }

    private func setupAudioEngine() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            self?.session.matchStreamingBuffer(buffer, at: when)
        }

        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Error starting audio engine: \(error)")
            DispatchQueue.main.async {
                // Handle UI or state updates on errors
            }
        }
    }

    func stopListening() {
        // Perform the audio stopping logic in the background if needed
        DispatchQueue.global(qos: .userInitiated).async {
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)

            // Once stopping is done, update any UI elements on the main thread
            DispatchQueue.main.async {
                self.isRecording = false
                // Any other UI updates related to stopping the recording
            }
        }
    }

    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch interruptionType {
        case .began:
            print("Audio interruption began.")
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                print("Audio interruption ended. Resuming audio engine...")
                setupAudioEngine()
            }
        @unknown default:
            break
        }
    }
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        DispatchQueue.main.async {
            if let firstItem = match.mediaItems.first {
                self.updateShazamMedia(from: firstItem)
            }
        }
    }

    private func updateShazamMedia(from item: SHMediaItem) {
        var media = ShazamMedia(title: item.title,
                                subtitle: item.subtitle,
                                artistName: item.artist,
                                albumArtURL: item.artworkURL,
                                genres: item.genres,
                                lyrics: nil)
        if let artist = media.artistName, let title = media.title {
            fetchLyrics(for: artist, song: title) { result in
                switch result {
                case .success(let lyrics):
                    media.lyrics = lyrics
                case .failure:
                    media.lyrics = "Lyrics not available"
                }
                self.shazamMedia = media
            }
        }
    }

    func fetchLyrics(for artist: String, song: String, completion: @escaping (Result<String, Error>) -> Void) {
        let formattedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
        let formattedSong = song.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
        
        let urlString = "https://api.lyrics.ovh/v1/\(formattedArtist)/\(formattedSong)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        isFetchingLyrics = true
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            defer { DispatchQueue.main.async { self.isFetchingLyrics = false } }
            
            guard let data = data, error == nil else {
                print("Error fetching lyrics: \(error?.localizedDescription ?? "Unknown error")")
                completion(.failure(error ?? NSError(domain: "Unknown error", code: 0, userInfo: nil)))
                return
            }
            
            do {
                if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let lyrics = result["lyrics"] as? String {
                    DispatchQueue.main.async {
                        completion(.success(lyrics))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "Lyrics not found", code: 0, userInfo: nil)))
                    }
                }
            } catch {
                print("Error parsing lyrics data: \(error)")
                completion(.failure(error))
            }
        }
        task.resume()
    }
}
