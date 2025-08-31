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
import AVFoundation
import CoreMedia
import AudioToolbox
import MediaToolbox

struct ShazamMedia: Decodable {
    let title: String?
    let subtitle: String?
    let artistName: String?
    let albumArtURL: URL?
    let genres: [String]
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    static let shared = ShazamViewModel()
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var appleMusicURL: URL?
       @Published var appleMusicItem: MusicKit.Song?
    @Published var userPlaylists: MusicItemCollection<Playlist> = MusicItemCollection<Playlist>()
    @Published var matchedArtworkURL: URL?

    private var audioEngine = AVAudioEngine()
    private var session = SHSession()
    private let signatureGenerator = SHSignatureGenerator()
    
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
            // Use playAndRecord with mixWithOthers to allow radio to continue playing
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try audioSession.setActive(true)
            print("🎤 ShazamViewModel: Audio session configured for recording (mixed with radio)")
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

    // MARK: - Matching Without Microphone
    // Use the app's own playback (stream URL or AVPlayerItem asset) to feed PCM into Shazam
    func matchCurrentStationStreamURL(_ urlString: String, seconds: Double = 12.0) async {
        print("🎵 ShazamViewModel: Live stream recognition requested for: \(urlString)")
        
        // For live streams, we need to tap the audio from the currently playing AVPlayer
        // instead of trying to read from the stream URL directly
        await matchFromCurrentlyPlayingAudio(seconds: seconds)
    }

    func matchFromPlayerItem(_ playerItem: AVPlayerItem, seconds: Double = 12.0) async {
        let asset = playerItem.asset
        await readPCMAndMatch(from: asset, seconds: seconds)
    }
    
    // Alternative approach for live streams - fallback to iTunes metadata search
    func matchFromCurrentlyPlayingAudio(seconds: Double = 5.0) async {
        print("🎵 ShazamViewModel: Live stream AVAssetReader failed - using metadata fallback")
        
        // Since live streams don't work with AVAssetReader, and the user doesn't want microphone,
        // we'll post a no-match notification to trigger iTunes fallback in RadioPlayer
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("ShazamNoMatch"), object: nil)
        }
    }

    // Read PCM frames using AVAssetReader (no mic) and match with ShazamKit
    private func readPCMAndMatch(from asset: AVAsset, seconds: Double) async {
        print("🎵 ShazamViewModel: Starting readPCMAndMatch for \(seconds) seconds")
        
        // Create a fresh signature generator for this recognition attempt
        let localSignatureGenerator = SHSignatureGenerator()
        
        do {
            // Ensure we can read a short segment
            let duration = try await asset.load(.duration)
            print("🎵 ShazamViewModel: Asset duration: \(CMTimeGetSeconds(duration)) seconds")
            let tracks = try await asset.load(.tracks)
            print("🎵 ShazamViewModel: Found \(tracks.count) tracks")
            var audioTrack: AVAssetTrack?
            for t in tracks {
                if t.mediaType == .audio { audioTrack = t; break }
            }
            guard let track = audioTrack else { 
                print("❌ ShazamViewModel: No audio track found in asset")
                return 
            }
            print("✅ ShazamViewModel: Found audio track")

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            // For live streams, use a shorter time range to avoid hanging
            let readDuration = min(seconds, 15.0) // Cap at 15 seconds max
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: readDuration, preferredTimescale: 44100))
            guard reader.startReading() else { 
                print("❌ ShazamViewModel: Failed to start reading asset - status: \(reader.status), error: \(reader.error?.localizedDescription ?? "unknown")")
                return 
            }
            print("✅ ShazamViewModel: Started reading asset for \(readDuration) seconds")

            let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            var collectedSeconds: Double = 0
            var sampleCount = 0

            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let frameCount = CMSampleBufferGetNumSamples(sample)
                if frameCount <= 0 { continue }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                let dataLength = CMBlockBufferGetDataLength(blockBuffer)
                let bytesPerFrame = 2 // 16-bit mono
                let expectedLength = frameCount * bytesPerFrame
                guard dataLength >= expectedLength else { continue }

                if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) {
                    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                    if let dst = pcmBuffer.int16ChannelData?[0] {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: expectedLength, destination: dst)
                        // Append to streaming matcher
                        let when = AVAudioTime(hostTime: mach_absolute_time())
                        session.matchStreamingBuffer(pcmBuffer, at: when)
                        // Also build a signature in parallel for fallback one-shot match
                        try? localSignatureGenerator.append(pcmBuffer, at: when)
                        collectedSeconds += Double(frameCount) / 44100.0
                        sampleCount += 1
                        if sampleCount % 10 == 0 {
                            print("🎵 ShazamViewModel: Processed \(sampleCount) samples, \(String(format: "%.1f", collectedSeconds))s of audio")
                        }
                        if collectedSeconds >= seconds { break }
                    }
                }
            }

            // One-shot signature match as a fallback/completion
            print("🎵 ShazamViewModel: Finished processing \(sampleCount) samples, \(String(format: "%.1f", collectedSeconds))s total")
            if let signature = try? localSignatureGenerator.signature() {
                print("✅ ShazamViewModel: Generated signature, sending to Shazam")
                session.match(signature)
            } else {
                print("❌ ShazamViewModel: Failed to generate signature")
            }
        } catch {
            print("❌ ShazamViewModel: readPCMAndMatch failed: \(error)")
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
                print("🎵 Shazam match found: \(firstItem.title ?? "Unknown") by \(firstItem.artist ?? "Unknown")")
                self.updateShazamMedia(from: firstItem)
                Task { await self.fetchAppleMusicDetails(from: firstItem) }
            }
        }
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature) {
        print("🔍 Shazam: No match found for signature")
        // Post notification that Shazam didn't find a match
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("ShazamNoMatch"), object: nil)
        }
    }
    
    func session(_ session: SHSession, didFailMatchingFor signature: SHSignature, error: Error) {
        print("❌ Shazam recognition failed with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("ShazamNoMatch"), object: nil)
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
                self.matchedArtworkURL = item.artworkURL
                NotificationCenter.default.post(name: Notification.Name("ShazamVerifiedArtwork"), object: nil, userInfo: [
                    "title": title,
                    "artist": artist,
                    "artworkURL": item.artworkURL?.absoluteString ?? ""
                ])
            }
        }
    }

    // MARK: - Apple Music Details (Albums/Artwork)
    private func isrc(from item: SHMediaItem) -> String? { item.isrc }

    private func searchSongOnAppleMusic(title: String?, artist: String?) async throws -> MusicKit.Song? {
        let term = [title, artist].compactMap { $0 }.joined(separator: " ")
        let request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        let response = try await request.response()
        return response.songs.first
    }

    @MainActor
    private func apply(song: MusicKit.Song) {
        self.appleMusicItem = song
        self.appleMusicURL = song.url
        if let artwork = song.artwork, let url = artwork.url(width: 1000, height: 1000) {
            self.matchedArtworkURL = url
        }
    }

    private func fetchAppleMusicDetails(from item: SHMediaItem) async {
        do {
            if let title = item.title, let artist = item.artist, let song = try await searchSongOnAppleMusic(title: title, artist: artist) {
                await apply(song: song)
                return
            }
            // Fallback: try searching by ISRC if available
            if let code = isrc(from: item) {
                let request = MusicCatalogSearchRequest(term: code, types: [Song.self])
                let response = try await request.response()
                if let song = response.songs.first { await apply(song: song) }
            }
        } catch {
            print("❌ Apple Music details fetch failed: \(error)")
        }
    }

    // MARK: - Text-only fallback (no audio matching)
    func fetchAppleMusicUsingStationMetadata(title: String, artist: String) async {
        do {
            if let song = try await searchSongOnAppleMusic(title: title, artist: artist) {
                await apply(song: song)
            }
        } catch {
            print("❌ Apple Music search failed: \(error)")
        }
    }
}
