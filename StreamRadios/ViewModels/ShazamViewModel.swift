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
    
    var isValid: Bool {
        return title != nil && artistName != nil && albumArtURL != nil
    }
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var isAutoDetecting = false
    @Published var appleMusicURL: URL?
    @Published var appleMusicItem: MusicKit.Song?
    @Published var userPlaylists: MusicItemCollection<Playlist> = MusicItemCollection<Playlist>()
    @Published var currentSongArtwork: UIImage?
    @Published var lastDetectedSong: ShazamMedia?

    private var audioEngine = AVAudioEngine()
    private var session = SHSession()
    private var autoDetectionTimer: Timer?
    private var radioPlayer: RadioPlayer?
    
    // Auto-detection settings
    private let autoDetectionInterval: TimeInterval = 15.0 // Detect every 15 seconds for faster updates
    private let listeningDuration: TimeInterval = 12.0 // Listen for 12 seconds each cycle
    private let maxConsecutiveFailures = 4 // Increased tolerance
    private var consecutiveFailures = 0
    private var bufferErrors = 0
    private let maxBufferErrors = 5 // Allow more buffer errors before resetting
    private let songDataTimeout: TimeInterval = 90.0 // Clear song data after 1.5 minutes of no detection
    private var lastSuccessfulDetection: Date?
    
    override init() {
        super.init()
        session.delegate = self
        configureAudioSession()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        
        // Listen for radio playback changes
        NotificationCenter.default.addObserver(self, selector: #selector(radioPlaybackChanged), name: NSNotification.Name("RadioPlaybackChanged"), object: nil)
    }
    
    func setRadioPlayer(_ player: RadioPlayer) {
        self.radioPlayer = player
    }
    
    // Method to trigger immediate detection when radio metadata changes
    func triggerImmediateDetection() {
        guard isAutoDetecting else { return }
        
        print("Triggering immediate detection due to potential song change")
        
        // Clear old song data since we detected a potential new song
        clearForNewSong()
        
        // Stop current listening if running
        if audioEngine.isRunning {
            stopListening()
        }
        
        // Start detection immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.isAutoDetecting {
                self.performAutoDetection()
            }
        }
    }
    
    @objc private func radioPlaybackChanged() {
        DispatchQueue.main.async {
            if let radioPlayer = self.radioPlayer, radioPlayer.isPlaying {
                self.startAutoDetection()
            } else {
                self.stopAutoDetection()
            }
        }
    }
    
    func startAutoDetection() {
        guard !isAutoDetecting else { return }
        
        print("Starting automatic song detection for radio")
        isAutoDetecting = true
        consecutiveFailures = 0
        
        // Start immediate detection
        performAutoDetection()
        
        // Schedule periodic detection
        autoDetectionTimer = Timer.scheduledTimer(withTimeInterval: autoDetectionInterval, repeats: true) { [weak self] _ in
            self?.performAutoDetection()
        }
    }
    
    func stopAutoDetection() {
        print("Stopping automatic song detection")
        isAutoDetecting = false
        autoDetectionTimer?.invalidate()
        autoDetectionTimer = nil
        
        if audioEngine.isRunning {
            stopListening()
        }
        
        // Clear detected song data when stopping auto-detection
        clearDetectedSong()
    }
    
    private func performAutoDetection() {
        guard isAutoDetecting else { return }
        
        // Check if we should clear old song data due to timeout
        checkAndClearOldSongData()
        
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self, granted else {
                print("Microphone permission denied for auto-detection")
                return
            }
            
            DispatchQueue.main.async {
                self.startBriefListening()
            }
        }
    }
    
    private func startBriefListening() {
        guard !audioEngine.isRunning else { return }
        
        configureAudioSession()
        setupAudioEngine()
        
        // Stop listening after the configured duration
        DispatchQueue.main.asyncAfter(deadline: .now() + listeningDuration) {
            if self.audioEngine.isRunning {
                self.stopListening()
            }
        }
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Only configure if not already in a compatible mode
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                print("Shazam audio session configured successfully")
            }
        } catch {
            print("Failed to set up Shazam audio session: \(error)")
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
            
            DispatchQueue.main.async {
                self.configureAudioSession()
                self.setupAudioEngine()
            }
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
        // Stop and reset audio engine if already running
        if audioEngine.isRunning {
            stopListening()
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Remove any existing taps
        inputNode.removeTap(onBus: 0)
        
        // Install tap with smaller buffer size and simpler error handling
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            guard let self = self else { return }
            
            // Apply gain and send to Shazam - let ShazamKit handle errors internally
            self.applyGain(to: buffer)
            self.session.matchStreamingBuffer(buffer, at: when)
        }
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
                print("Shazam audio engine started successfully")
            }
        } catch {
            print("Error starting Shazam audio engine: \(error)")
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
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
            
            DispatchQueue.main.async {
                self.isRecording = false
                print("Shazam audio engine stopped")
            }
        }
    }
    
    private func resetShazamSession() {
        print("Resetting Shazam session due to persistent errors")
        
        // Stop current session gracefully
        if audioEngine.isRunning {
            stopListening()
        }
        
        // Create new session to reset buffer state
        session = SHSession()
        session.delegate = self
        
        // Restart listening after a longer delay to let things settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.isAutoDetecting {
                print("Restarting Shazam detection after reset")
                self.startBriefListening()
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
                self.consecutiveFailures = 0 // Reset failure count on successful detection
                self.bufferErrors = 0 // Reset buffer error count on successful detection
                print("Successfully detected new song - resetting detection cycle")
            }
        }
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature) {
        DispatchQueue.main.async {
            self.consecutiveFailures += 1
            print("Song not detected. Consecutive failures: \(self.consecutiveFailures)")
            
            // Clear previous song data when no match is found
            self.clearDetectedSong()
            
            // If too many consecutive failures, temporarily pause auto-detection
            if self.consecutiveFailures >= self.maxConsecutiveFailures {
                print("Too many consecutive failures. Pausing auto-detection for 2 minutes.")
                self.pauseAutoDetectionTemporarily()
            } else {
                // If we're still within tolerance, try again sooner for potential song changes
                self.scheduleQuickRetry()
            }
        }
    }
    
    func session(_ session: SHSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            print("Shazam session failed with error: \(error)")
            
            // Handle specific error codes
            let nsError = error as NSError
            if nsError.code == 101 {
                self.bufferErrors += 1
                print("Audio buffer continuity error (\(self.bufferErrors)/\(self.maxBufferErrors))")
                
                // Only reset after multiple buffer errors
                if self.bufferErrors >= self.maxBufferErrors {
                    print("Too many buffer errors - resetting session")
                    self.bufferErrors = 0
                    self.resetShazamSession()
                }
            } else {
                // For other errors, increment failure count
                self.consecutiveFailures += 1
                if self.consecutiveFailures >= self.maxConsecutiveFailures {
                    self.pauseAutoDetectionTemporarily()
                }
            }
        }
    }
    
    private func scheduleQuickRetry() {
        // Try again in 8 seconds if we failed to detect (potential song change)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if self.isAutoDetecting && !self.audioEngine.isRunning {
                print("Quick retry for potential song change")
                self.performAutoDetection()
            }
        }
    }
    
    private func pauseAutoDetectionTemporarily() {
        stopAutoDetection()
        
        // Resume after 2 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) {
            if let radioPlayer = self.radioPlayer, radioPlayer.isPlaying {
                self.startAutoDetection()
            }
        }
    }
    
    private func updateShazamMedia(from item: SHMediaItem) {
        let media = ShazamMedia(title: item.title,
                                subtitle: item.subtitle,
                                artistName: item.artist,
                                albumArtURL: item.artworkURL,
                                genres: item.genres)
        
        if media.isValid {
            print("Song detected: \(media.title ?? "Unknown") by \(media.artistName ?? "Unknown")")
            
            self.shazamMedia = media
            self.lastDetectedSong = media
            self.lastSuccessfulDetection = Date()
            
            // Download album artwork first, then notify
            if let artworkURL = media.albumArtURL {
                downloadAlbumArtwork(from: artworkURL, media: media)
            } else {
                // No artwork to download, notify immediately
                NotificationCenter.default.post(name: NSNotification.Name("SongDetected"), object: media)
            }
        }
    }
    
    private func downloadAlbumArtwork(from url: URL, media: ShazamMedia) {
        // Create a URLSession with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0 // 10 second timeout
        config.timeoutIntervalForResource = 15.0 // 15 second total timeout
        config.requestCachePolicy = .returnCacheDataElseLoad // Use cache if available
        let session = URLSession(configuration: config)
        
        var hasNotified = false // Prevent duplicate notifications
        
        // Set up a timeout fallback (increased to 8 seconds)
        let timeoutTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !hasNotified else { return }
                hasNotified = true
                print("Artwork download timeout for: \(media.title ?? "Unknown") - proceeding without artwork")
                self.currentSongArtwork = nil
                NotificationCenter.default.post(name: NSNotification.Name("SongDetected"), object: media)
            }
        }
        
        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, !hasNotified else { return }
                hasNotified = true
                
                // Cancel the timeout timer since we got a response
                timeoutTimer.invalidate()
                
                if let data = data, error == nil, let image = UIImage(data: data) {
                    // Successfully downloaded artwork
                    self.currentSongArtwork = image
                    print("Album artwork downloaded successfully for: \(media.title ?? "Unknown") (\(data.count) bytes)")
                } else {
                    // Failed to download artwork
                    print("Failed to download album artwork: \(error?.localizedDescription ?? "Unknown error")")
                    self.currentSongArtwork = nil
                }
                
                // Always notify after attempting download (success or failure)
                NotificationCenter.default.post(name: NSNotification.Name("SongDetected"), object: media)
            }
        }.resume()
    }
    
    private func checkAndClearOldSongData() {
        guard let lastDetection = lastSuccessfulDetection else { return }
        
        let timeSinceLastDetection = Date().timeIntervalSince(lastDetection)
        if timeSinceLastDetection > songDataTimeout {
            print("Clearing old song data due to timeout (\(Int(timeSinceLastDetection))s since last detection)")
            clearDetectedSong()
        }
    }
    
    // Method to clear song data when we know a new song has started
    func clearForNewSong() {
        print("Clearing song data for new song detection")
        clearDetectedSong()
        consecutiveFailures = 0 // Reset failure count for new song
        lastSuccessfulDetection = nil // Reset timeout tracking
    }
    
    private func clearDetectedSong() {
        // Clear all song-related data atomically
        self.currentSongArtwork = nil
        self.lastDetectedSong = nil
        self.lastSuccessfulDetection = nil
        
        // Reset shazamMedia to default state
        self.shazamMedia = ShazamMedia(title: "",
                                       subtitle: "Subtitle...",
                                       artistName: "",
                                       albumArtURL: URL(string: "https://example.com/default.jpg"),
                                       genres: ["Pop"])
        
        print("Cleared detected song data - UI should fall back to radio station icon")
        
        // Notify radio player to clear song detection immediately
        NotificationCenter.default.post(name: NSNotification.Name("SongDetectionCleared"), object: nil)
    }
    
    deinit {
        stopAutoDetection()
        NotificationCenter.default.removeObserver(self)
    }
}
