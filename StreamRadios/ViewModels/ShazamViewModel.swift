//
//  ShazamViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import SwiftUI
import ShazamKit
import AVKit
import MusicKit

struct ShazamMedia: Decodable {
    let title: String?
    let subtitle: String?
    let artistName: String?
    let albumArtURL: URL?
    let genres: [String]
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var appleMusicURL: URL?
       @Published var appleMusicItem: MusicKit.Song?
    @Published var userPlaylists: MusicItemCollection<Playlist> = MusicItemCollection<Playlist>()

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
            // Store the current category to restore it later
            let currentCategory = audioSession.category
            let currentMode = audioSession.mode
            let currentOptions = audioSession.categoryOptions
            
            // Store original configuration for restoration
            UserDefaults.standard.set(currentCategory.rawValue, forKey: "ShazamOriginalAudioCategory")
            UserDefaults.standard.set(currentMode.rawValue, forKey: "ShazamOriginalAudioMode") 
            UserDefaults.standard.set(currentOptions.rawValue, forKey: "ShazamOriginalAudioOptions")
            
            print("🎤 ShazamViewModel: Stored original audio session configuration")
            
        } catch {
            print("❌ ShazamViewModel: Failed to store audio session configuration: \(error)")
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
    
    func addToLibrary() async throws {
            guard let song = appleMusicItem else {
                throw NSError(domain: "ShazamError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No Apple Music item available"])
            }
            
            do {
                try await MusicLibrary.shared.add(song)
                print("Song added successfully")
            } catch {
                print("Failed to add song: \(error)")
                throw error
            }
        }
    
    func fetchAppleMusicItem() async throws {
            guard let songTitle = shazamMedia.title, let artistName = shazamMedia.artistName else {
                throw NSError(domain: "ShazamError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Song information not available"])
            }
            
            let searchRequest = MusicCatalogSearchRequest(term: "\(songTitle) \(artistName)", types: [Song.self])
            let searchResponse = try await searchRequest.response()
            
            guard let song = searchResponse.songs.first else {
                throw NSError(domain: "ShazamError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Song not found in Apple Music"])
            }
            
            DispatchQueue.main.async {
                self.appleMusicItem = song
                self.appleMusicURL = song.url
            }
        }
    
    func addToPlaylist(_ playlist: Playlist) async throws {
            guard let song = appleMusicItem else {
                throw NSError(domain: "ShazamError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No Apple Music item available"])
            }
            
            do {
                let library = MusicLibrary.shared
                try await library.add(song, to: playlist)
                print("Song added successfully to playlist")
            } catch {
                print("Failed to add song to playlist: \(error)")
                throw error
            }
        }
    
    private func setupAudioEngine() {
        // Ensure audio session is properly configured before setting up engine
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            print("🎤 ShazamViewModel: Audio session configured for recording")
        } catch {
            print("❌ ShazamViewModel: Failed to configure audio session: \(error)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
            return
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Validate the recording format before proceeding
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            print("❌ ShazamViewModel: Invalid recording format - sampleRate: \(recordingFormat.sampleRate), channels: \(recordingFormat.channelCount)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
            return
        }
        
        print("🎤 ShazamViewModel: Using recording format - sampleRate: \(recordingFormat.sampleRate), channels: \(recordingFormat.channelCount)")
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            self?.applyGain(to: buffer)
            self?.session.matchStreamingBuffer(buffer, at: when)
        }
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
            print("✅ ShazamViewModel: Audio engine started successfully")
        } catch {
            print("❌ ShazamViewModel: Error starting audio engine: \(error)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    private func applyGain(to buffer: AVAudioPCMBuffer) {
        let gain: Float = 2.0 // Adjust the gain value as needed
        let frameLength = Int(buffer.frameLength)
        let channels = UnsafeBufferPointer(start: buffer.floatChannelData, count: Int(buffer.format.channelCount))
        
        for channel in channels {
            for frame in 0..<frameLength {
                channel[frame] *= gain
            }
        }
    }
    
    func stopListening() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Stop audio engine safely
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
                print("🔇 ShazamViewModel: Audio engine stopped")
            }
            
            // Remove tap safely
            if self.audioEngine.inputNode.numberOfInputs > 0 {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                print("🔇 ShazamViewModel: Audio input tap removed")
            }
            
            // Restore original audio session configuration
            self.restoreOriginalAudioSession()
            
            DispatchQueue.main.async {
                self.isRecording = false
                print("🔇 ShazamViewModel: Shazam listening stopped")
            }
        }
    }
    
    private func restoreOriginalAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Get the stored original configuration
        let originalCategoryRaw = UserDefaults.standard.string(forKey: "ShazamOriginalAudioCategory") ?? AVAudioSession.Category.playback.rawValue
        let originalModeRaw = UserDefaults.standard.string(forKey: "ShazamOriginalAudioMode") ?? AVAudioSession.Mode.default.rawValue
        let originalOptionsRaw = UserDefaults.standard.object(forKey: "ShazamOriginalAudioOptions") as? UInt ?? AVAudioSession.CategoryOptions.allowBluetooth.rawValue
        
        do {
            let originalCategory = AVAudioSession.Category(rawValue: originalCategoryRaw)
            let originalMode = AVAudioSession.Mode(rawValue: originalModeRaw)
            let originalOptions = AVAudioSession.CategoryOptions(rawValue: originalOptionsRaw)
            
            try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ ShazamViewModel: Restored original audio session configuration - category: \(originalCategory.rawValue)")
            
            // Clean up stored values
            UserDefaults.standard.removeObject(forKey: "ShazamOriginalAudioCategory")
            UserDefaults.standard.removeObject(forKey: "ShazamOriginalAudioMode")
            UserDefaults.standard.removeObject(forKey: "ShazamOriginalAudioOptions")
            
            // Let PlaybackManager know the active player to ensure proper state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                PlaybackManager.shared.activateAudioSessionForPlayer(PlaybackManager.shared.activePlayer)
            }
            
        } catch {
            print("❌ ShazamViewModel: Failed to restore original audio session: \(error)")
            // Fallback: Let PlaybackManager reconfigure immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                PlaybackManager.shared.activateAudioSessionForPlayer(PlaybackManager.shared.activePlayer)
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
                                genres: item.genres)
        if let artist = media.artistName, let title = media.title {
            DispatchQueue.main.async {
                self.shazamMedia = media
            }
        }
    }
}
