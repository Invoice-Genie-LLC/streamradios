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

class ShazamViewModel: NSObject, ObservableObject {
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://google.com"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var isFetchingLyrics = false
    private let audioEngine = AVAudioEngine()
    private let session = SHSession()
    private let signatureGenerator = SHSignatureGenerator()
    
    override init() {
        super.init()
        session.delegate = self
    }
    
    public func startOrEndListening() {
        let audioSession = AVAudioSession.sharedInstance()
        
        guard !audioEngine.isRunning else {
            stopListening()
            return
        }
        
        audioSession.requestRecordPermission { [weak self] granted in
            guard let self = self, granted else {
                DispatchQueue.main.async {
                    print("Microphone permission is denied")
                }
                return
            }
            
            do {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay, .mixWithOthers])
                                try audioSession.setPreferredSampleRate(44100) // High-quality audio
                                try audioSession.setPreferredIOBufferDuration(0.005) // Reduce latency
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                self.setupAudioEngine()
            } catch {
                print("Failed to set up audio session: \(error)")
                DispatchQueue.main.async {
                    // ToDo - Handle errors, such as by showing an alert
                }
            }
        }
    }
    
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    private func setupAudioEngine() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            self?.session.matchStreamingBuffer(buffer, at: when)
        }
        
        // Since prepare() does not throw, no need to use 'try' with it
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Error starting audio engine: \(error)")
            DispatchQueue.main.async {
                // ToDo - Handle UI or state updates on errors
            }
        }
    }
}

extension ShazamViewModel: SHSessionDelegate {
    func session(_ session: SHSession, didFind match: SHMatch) {
        DispatchQueue.main.async {
            if let firstItem = match.mediaItems.first {
                var media = ShazamMedia(title: firstItem.title,
                                        subtitle: firstItem.subtitle,
                                        artistName: firstItem.artist,
                                        albumArtURL: firstItem.artworkURL,
                                        genres: firstItem.genres,
                                        lyrics: nil)
                
                if let artist = media.artistName, let title = media.title {
                    self.fetchLyrics(for: artist, song: title) { result in
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
            defer {
                DispatchQueue.main.async {
                    self.isFetchingLyrics = false
                }
            }
            
            guard let data = data, error == nil else {
                print("Error fetching lyrics: \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async {
                    completion(.failure(error ?? NSError(domain: "Unknown error", code: 0, userInfo: nil)))
                }
                return
            }
            
            do {
                if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let lyrics = result["lyrics"] as? String {
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
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }
}
