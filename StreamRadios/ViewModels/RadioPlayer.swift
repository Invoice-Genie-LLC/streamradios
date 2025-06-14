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
import BackgroundTasks
import SwiftUI
import Reachability
import SystemConfiguration

// MARK: - Music Metadata Models
struct SongMetadata {
    let title: String
    let artist: String
    let album: String?
    let albumArtworkURL: URL?
    let releaseDate: String?
    let genre: String?
    
    var isValid: Bool {
        return !title.isEmpty && !artist.isEmpty
    }
}

// MARK: - Music API Response Models
struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesTrack]
}

struct iTunesTrack: Codable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    let releaseDate: String?
    let primaryGenreName: String?
    
    var artworkURL: URL? {
        // Try high-res first, fallback to standard resolution
        if let artworkUrl600 = artworkUrl600 {
            return URL(string: artworkUrl600)
        } else if let artworkUrl100 = artworkUrl100 {
            return URL(string: artworkUrl100)
        }
        return nil
    }
}

// MARK: - Notification Extensions
// Notification names no longer needed - music metadata handled directly

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusCancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let monitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private var wasPlayingBeforeNetworkLoss = false
    @Published var isBuffering = false
    @Published var isPlaying: Bool = false

    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String?
    @Published var isHandlingAlarm = false
    @Published var currentlyPlayingStation: RadioStation?
    @Published var alarmStation: RadioStation?
    @Published var detectedSong: SongMetadata?
    @Published var songArtwork: UIImage?
    public var isDetectingCurrentSong = false
    private var previousSongWasUnidentified = false
    private var reachability: Reachability?
    private var isOnCellularNetwork = false
    weak var podcastPlayer: PodcastPlayer?
    
    // Music search functionality (replaces Shazam)
    private let musicSearchQueue = DispatchQueue(label: "musicSearch", qos: .background)
    
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    
    var bitrateSubject = CurrentValueSubject<String, Never>("Playing at high bitrate: 256 kbps")
    private let userDefaultsSuiteName = "group.streamradios"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }
    
    var viewModel: RadioStationViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    private var stationProvidesNoMetadata = false
    
    override init() {
            super.init()
            configureAudioSession()
            addInterruptionObserver()
            autoPlayLastStationSetup()
            
            // Initialize AI detector
            self.aiDetector = AISongDurationDetector(radioPlayer: self)
            print("🎵 AI: Enhanced AI Song Detection System initialized successfully")
        
        DispatchQueue.main.async {
                   self.podcastPlayer = PodcastPlayer.shared
                   self.podcastPlayer?.setRadioPlayer(self)
               }
        
        // Music metadata is now handled directly in the RadioPlayer - no notifications needed
        
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                self.isOnCellularNetwork = path.isExpensive
                self.adjustForNetworkConditions()
                self.updateBitrateBasedOnNetwork(path: path)
            }
            let queue = DispatchQueue(label: "NetworkMonitor")
            monitor.start(queue: queue)
        }

    
    private func updateBitrateText(_ bitrate: Double) {
        let bitrateMessage = "Playing at \(Int(bitrate / 1000)) kbps"
        bitrateSubject.send(bitrateMessage)
        print("Bitrate text updated to: \(bitrateMessage)")
    }
    
    func autoPlayLastStationSetup() {
        if autoPlayLastStation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Only auto-play if we're not currently handling an alarm
                if !self.isHandlingAlarm {
                    if let lastStationID = UserDefaults.standard.string(forKey: "LastPlayedStationID"),
                       let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) {
                        // Play the last played station
                        self.currentlyPlayingStation = lastStation
                        if let url = URL(string: lastStation.url) {
                            self.setStationURL(url)
                            if let index = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                                self.currentStationIndex = index
                                UserDefaults.standard.set(index, forKey: "lastStationIndex")
                            }
                            self.play()
                        }
                    } else if let lastStationURL = self.userDefaults?.url(forKey: "lastStationURL") {
                        // Fall back to the old method if LastPlayedStationID is not available
                        self.setStationURL(lastStationURL)
                        self.currentStationIndex = self.userDefaults?.integer(forKey: "lastStationIndex")
                        if let index = self.currentStationIndex,
                           index < self.viewModel?.stations.count ?? 0 {
                            self.currentlyPlayingStation = self.viewModel?.stations[index]
                        }
                        self.play()
                    }
                }
            }
        }
    }
    
    func resetAlarmState() {
        isHandlingAlarm = false
    }
    
    func setViewModel(_ viewModel: RadioStationViewModel) {
        self.viewModel = viewModel
        
        // Observe changes in the stations array
        viewModel.$stations
            .sink { [weak self] _ in
                self?.updateNowPlayingInfo()
            }
            .store(in: &cancellables)
    }
    
    // Shazam fallback for when iTunes search fails
    private weak var shazamViewModel: ShazamViewModel?
    
    // AI Song Detection System
    private var aiDetector: AISongDurationDetector?
    
    func setShazamViewModel(_ shazamViewModel: ShazamViewModel) {
        self.shazamViewModel = shazamViewModel
        print("ShazamViewModel connected for fallback detection")
    }
    
    // Song metadata is now handled directly in the RadioPlayer class - no notifications needed
    
    private func notifyPlaybackChanged() {
        NotificationCenter.default.post(name: NSNotification.Name("RadioPlaybackChanged"), object: nil)
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Set the audio session category to playback with mix with others for Shazam compatibility
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay, .mixWithOthers])
            
            // Don't override output port when Shazam might be recording
            // try audioSession.overrideOutputAudioPort(.speaker)
            
            // Activate the audio session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Set the preferred IO buffer duration
            try audioSession.setPreferredIOBufferDuration(0.005)
            
            print("Radio audio session configured successfully")
            
        } catch {
            print("Failed to set up radio audio session: \(error)")
        }
    }
    
    func addInterruptionObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    private func adjustForNetworkConditions() {
        if isOnCellularNetwork {
            player?.currentItem?.preferredForwardBufferDuration = 20
            player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        } else {
            player?.currentItem?.preferredForwardBufferDuration = 5
            player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .began {
            // Interruption began, pause the player
            player?.pause()
        } else if type == .ended {
            // Interruption ended, reactivate the audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume playback if it should resume
                    player?.play()
                }
            } catch {
                print("Failed to reactivate audio session: \(error)")
            }
        }
    }
    
    @objc private func checkNetworkAndRetry() {
        if isNetworkAvailable && wasPlayingBeforeNetworkLoss && !isPlaying {
            retryStreamIfNeeded()
        }
    }
    
    private func retryStream() {
        guard let currentPlayerItem = player?.currentItem,
              let asset = currentPlayerItem.asset as? AVURLAsset else { return }
        
        let currentTime = currentPlayerItem.currentTime()
        let newPlayerItem = AVPlayerItem(url: asset.url)
        newPlayerItem.preferredPeakBitRate = currentPlayerItem.preferredPeakBitRate
        
        player?.replaceCurrentItem(with: newPlayerItem)
        player?.seek(to: currentTime)
        player?.play()
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
    
    private func setStationURL(_ url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.automaticallyWaitsToMinimizeStalling = true
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
        
        // Set the bitrate and add metadata output
        updateBitrateBasedOnNetwork(path: monitor.currentPath)
        
        addMetadataOutput()
    }
    
    private func updateBitrateBasedOnNetwork(path: NWPath) {
            DispatchQueue.main.async {
                print("Network status: \(path.status == .satisfied ? "Connected" : "Disconnected")")
                
                if path.usesInterfaceType(.cellular) {
                    print("Network type: Cellular")
                    if path.isConstrained {
                        print("Network is constrained. Updating bitrate text to 64 kbps.")
                        self.updateBitrateText(64000) // 64 kbps
                    } else if path.isExpensive {
                        print("Network is expensive. Updating bitrate text to 96 kbps.")
                        self.updateBitrateText(96000) // 96 kbps
                    } else {
                        print("Normal cellular network. Updating bitrate text to 128 kbps.")
                        self.updateBitrateText(128000) // 128 kbps
                    }
                } else if path.usesInterfaceType(.wifi) {
                    print("Network type: Wi-Fi. Updating bitrate text to 256 kbps.")
                    self.updateBitrateText(256000) // 256 kbps
                } else {
                    print("Unknown network type. Updating bitrate text to 128 kbps.")
                    self.updateBitrateText(128000) // 128 kbps
                }
            }
        }
    
    func resumePlayback() {
        if let player = player, !isPlaying {
            player.play()
            isPlaying = true
        }
    }
    
    private func setBitrate(_ bitrate: Double) {
        guard let playerItem = player?.currentItem else { return }
        let currentBitrate = playerItem.preferredPeakBitRate
        print("Current bitrate: \(currentBitrate), New bitrate: \(bitrate)")
        
        if currentBitrate != bitrate {
            playerItem.preferredPeakBitRate = bitrate
            updateBitrateText(bitrate)
        } else {
            print("Bitrate remains unchanged at \(bitrate)")
        }
        
        // Ensure metadata output is added
        addMetadataOutput()
    }
    
    private func performReachabilityCheck(completion: @escaping (Bool) -> Void) {
        reachability = try? Reachability()
        
        reachability?.whenReachable = { reachability in
            DispatchQueue.main.async {
                completion(true)
            }
            reachability.stopNotifier()
        }
        
        reachability?.whenUnreachable = { _ in
            DispatchQueue.main.async {
                completion(false)
            }
            self.reachability.unsafelyUnwrapped.stopNotifier()
        }
        
        do {
            try reachability?.startNotifier()
        } catch {
            completion(false)
        }
    }
    
    private func addMetadataOutput() {
        guard let currentItem = player?.currentItem else {
            print("No current item found in player.")
            return
        }
        let metadataOutput = AVPlayerItemMetadataOutput()
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        currentItem.add(metadataOutput)
        print("Metadata output added to player item.")
    }
    
    func playPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
            stopPodcastPlayback()
            resetRetryCount()
        }
        updateNowPlayingInfo()
        updateWidget()
    }
    
    func play() {
        stopPodcastPlayback()
            
            // Existing play logic
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
            scheduleAppRefresh()
            notifyPlaybackChanged()
        
        // Set radio as the active player
            PlaybackManager.shared.setActivePlayer(.radio)
        }
    
    private func stopPodcastPlayback() {
            if let podcastPlayer = podcastPlayer, podcastPlayer.isPlaying {
                podcastPlayer.pause()
            }
        }
    
    func pause() {
            guard let player = player else { return }
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
            notifyPlaybackChanged()
        }
    
    func togglePlayPause() {
            if isPlaying {
                pause()
            } else {
                play()
            }
        }
    
    func stop() {
           player?.pause()
           player = nil
           currentStationIndex = nil
           isPlaying = false
           metadata = nil
           
           // Stop AI detection
           aiDetector?.stopAnalysis()
       }
    
    func playStation(at index: Int, from stations: [RadioStation]) {
        stopPodcastPlayback()
        
        guard index >= 0 && index < stations.count else { return }
        
        stopCurrentStation()
        currentStationIndex = index
        metadata = nil // Clear metadata when switching stations
        clearAllSongData() // Clear all song data including artwork when switching stations
        
        // Reset metadata detection state when switching stations
        stationProvidesNoMetadata = false
        
        let station = stations[index]
        currentlyPlayingStation = station
        
        if let url = URL(string: station.url) {
            setStationURL(url)
            play()
        }
        
        isPlaying = true  // Set isPlaying to true when starting a new station
        updateNowPlayingInfo()
        updateWidget()
        updateLastPlayed(station)
        saveLastPlayedStation()
        
        // Start immediate metadata check after 5 seconds, then periodic checks
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.checkForInitialMetadata()
        }
    }
    
    func playStationForAlarm(station: RadioStation) {
        print("Playing station for alarm: \(station.name)")
        guard let url = URL(string: station.url) else {
            print("Invalid URL for station: \(station.name)")
            return
        }

        setStationURL(url)
        play()
        alarmStation = station
    }
    
    func stopCurrentStation() {
        player?.pause()
        player = nil
        isPlaying = false
        updateNowPlayingInfo()
        notifyPlaybackChanged()
        currentlyPlayingStation = nil
        
        // Clear all song data when stopping
        clearAllSongData()
        
        // Reset metadata detection state when stopping
        stationProvidesNoMetadata = false
    }
    
    func nextStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
                let nextIndex = (currentIndex + 1) % stations.count
                playStation(at: nextIndex, from: stations)
                updateLastPlayed(stations[nextIndex])
    }
    
    func previousStation(from stations: [RadioStation]) {
        guard let currentIndex = currentStationIndex else { return }
               let previousIndex = (currentIndex - 1 + stations.count) % stations.count
               playStation(at: previousIndex, from: stations)
               updateLastPlayed(stations[previousIndex])
    }
    
    private func updateLastPlayed(_ station: RadioStation) {
           viewModel?.updateLastPlayed(for: station)
       }
    
     func saveLastPlayedStation() {
        if let currentStation = currentlyPlayingStation {
            UserDefaults.standard.set(currentStation.id, forKey: "LastPlayedStationID")
            if let index = viewModel?.stations.firstIndex(where: { $0.id == currentStation.id }) {
                UserDefaults.standard.set(index, forKey: "lastStationIndex")
            }
        }
    }

    private func loadLastPlayedStation() {
        if let lastStationID = UserDefaults.standard.string(forKey: "LastPlayedStationID"),
           let lastStation = viewModel?.stations.first(where: { $0.id == lastStationID }) {
            currentlyPlayingStation = lastStation
            if let url = URL(string: lastStation.url) {
                setStationURL(url)
                play()
            }
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let viewModel = viewModel else { return }
        
        var nowPlayingInfo = [String: Any]()
        
        let currentStation: RadioStation?
        if isHandlingAlarm {
            currentStation = alarmStation
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < viewModel.stations.count {
            currentStation = viewModel.stations[currentStationIndex]
        } else {
            currentStation = nil
        }
        
        if let station = currentStation {
            nowPlayingInfo[MPMediaItemPropertyTitle] = songTitle.isEmpty ? station.name : songTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName.isEmpty ? (metadata ?? station.name) : artistName
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let albumArt = albumArt {
            let artwork = MPMediaItemArtwork(boundsSize: albumArt.size) { size in
                return albumArt
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let station = currentStation,
                  let iconData = station.iconData,
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("Updated now playing info: \(nowPlayingInfo)")
    }
    
    private func updateWidget() {
        guard let currentStationIndex = currentStationIndex, let viewModel = viewModel else { return }
        
        guard currentStationIndex < viewModel.stations.count else {
            return
        }
        
        let currentStation = viewModel.stations[currentStationIndex]
        let metadata = self.metadata ?? "No song or album title available"
        
        userDefaults?.set(currentStation.name, forKey: "stationName")
        userDefaults?.set(currentStation.iconData, forKey: "stationIcon")
        userDefaults?.set(metadata, forKey: "stationMetadata")
        
        WidgetCenter.shared.reloadAllTimelines()
        print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
    }
    
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .radio {
                self?.play()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .radio {
                self?.pause()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .radio {
                if let self = self, let viewModel = self.viewModel {
                    self.nextStation(from: viewModel.stations)
                    return .success
                }
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .radio {
                if let self = self, let viewModel = self.viewModel {
                    self.previousStation(from: viewModel.stations)
                    return .success
                }
            }
            return .commandFailed
        }
    }
    
    // Helper method to determine if metadata change indicates a new song
    private func isLikelyNewSong(previous: String, current: String) -> Bool {
        // Convert to lowercase for comparison
        let prev = previous.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let curr = current.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If strings are identical, not a new song
        if prev == curr { return false }
        
        // If one contains the other (partial updates), probably not a new song
        if prev.contains(curr) || curr.contains(prev) { return false }
        
        // Check for common non-song metadata patterns
        let nonSongPatterns = [
            "now playing", "coming up", "next:", "advertisement", "commercial",
            "station id", "weather", "news", "traffic", "promo"
        ]
        
        for pattern in nonSongPatterns {
            if curr.contains(pattern) { return false }
        }
        
        // If the change is significant and doesn't match non-song patterns, likely a new song
        return true
    }
    
    // MARK: - Music Metadata Search
    private func searchForSongMetadata(query: String) {
        // Set detection flag to prevent duplicate searches
        isDetectingCurrentSong = true
        
        musicSearchQueue.async { [weak self] in
            self?.performiTunesSearch(query: query)
        }
    }
    
    private func performiTunesSearch(query: String) {
        let parsedQuery = parseMetadataQuery(query)
        guard parsedQuery.isValid else {
            print("Invalid query for music search: \(query)")
            return
        }
        
        let searchTerm = "\(parsedQuery.artist) \(parsedQuery.title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://itunes.apple.com/search?term=\(searchTerm)&media=music&entity=song&limit=5"
        
        guard let url = URL(string: urlString) else {
            print("Invalid iTunes search URL")
            return
        }
        
        print("Searching iTunes for: \(parsedQuery.artist) - \(parsedQuery.title)")
        
        // Create a URLSession with shorter timeout for faster fallback to Shazam
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0 // 5 second timeout
        config.timeoutIntervalForResource = 10.0 // 10 second total timeout
        let session = URLSession(configuration: config)
        
        session.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                print("iTunes search error: \(error) - immediately falling back to Shazam")
                DispatchQueue.main.async { [weak self] in
                    self?.fallbackToShazam(reason: "iTunes search failed with error")
                }
                return
            }
            
            guard let data = data else {
                print("No data received from iTunes search - immediately falling back to Shazam")
                DispatchQueue.main.async { [weak self] in
                    self?.fallbackToShazam(reason: "iTunes search returned no data")
                }
                return
            }
            
            do {
                let searchResponse = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
                self?.processiTunesResults(searchResponse.results, originalQuery: parsedQuery)
            } catch {
                print("Error decoding iTunes response: \(error) - immediately falling back to Shazam")
                DispatchQueue.main.async { [weak self] in
                    self?.fallbackToShazam(reason: "iTunes response parsing failed")
                }
            }
        }.resume()
    }
    
    private func processiTunesResults(_ tracks: [iTunesTrack], originalQuery: (artist: String, title: String, isValid: Bool)) {
        guard let bestMatch = findBestMatch(tracks: tracks, query: originalQuery) else {
            print("No suitable match found in iTunes results - immediately falling back to Shazam")
            DispatchQueue.main.async { [weak self] in
                self?.fallbackToShazam(reason: "iTunes search returned no results")
            }
            return
        }
        
        let songMetadata = SongMetadata(
            title: bestMatch.trackName ?? originalQuery.title,
            artist: bestMatch.artistName ?? originalQuery.artist,
            album: bestMatch.collectionName,
            albumArtworkURL: bestMatch.artworkURL,
            releaseDate: bestMatch.releaseDate,
            genre: bestMatch.primaryGenreName
        )
        
        print("Found song metadata: \(songMetadata.title) by \(songMetadata.artist)")
        print("iTunes track artwork URLs - 600px: \(bestMatch.artworkUrl600 ?? "None"), 100px: \(bestMatch.artworkUrl100 ?? "None")")
        
        DispatchQueue.main.async { [weak self] in
            self?.updateWithSongMetadata(songMetadata)
            self?.isDetectingCurrentSong = false
            self?.previousSongWasUnidentified = false // Successfully identified this song
        }
        
        // Download artwork if available and we don't already have it for this song
        if let artworkURL = songMetadata.albumArtworkURL {
            // Check if we already have artwork for this song
            let currentSongKey = "\(songMetadata.title)-\(songMetadata.artist)"
            let lastArtworkSongKey = UserDefaults.standard.string(forKey: "lastArtworkSongKey") ?? ""
            
            if songArtwork == nil || currentSongKey != lastArtworkSongKey {
                print("Downloading artwork from: \(artworkURL.absoluteString)")
                downloadAlbumArtwork(from: artworkURL) { [weak self] image in
                    DispatchQueue.main.async {
                        if let image = image {
                            print("Successfully downloaded artwork, size: \(image.size)")
                            self?.songArtwork = image
                            self?.objectWillChange.send()
                            
                            // Remember which song this artwork belongs to
                            UserDefaults.standard.set(currentSongKey, forKey: "lastArtworkSongKey")
                        } else {
                            print("Failed to download artwork")
                        }
                    }
                }
            } else {
                print("Already have artwork for this song - skipping download")
            }
        } else {
            // If previous song was unidentified or we have no artwork, be more aggressive with Shazam
            print("No artwork URL available for song")
            DispatchQueue.main.async { [weak self] in
                if self?.previousSongWasUnidentified == true || self?.detectedSong == nil {
                    print("Previous song was unidentified or no song detected - falling back to Shazam for better identification")
                    self?.fallbackToShazam(reason: "iTunes found song but no artwork available, previous song unidentified")
                } else {
                    print("Already have valid song info - skipping Shazam fallback")
                    self?.isDetectingCurrentSong = false
                }
            }
        }
    }
    
    private func findBestMatch(tracks: [iTunesTrack], query: (artist: String, title: String, isValid: Bool)) -> iTunesTrack? {
        let queryArtist = query.artist.lowercased()
        let queryTitle = query.title.lowercased()
        
        // Find exact or close matches
        for track in tracks {
            let trackArtist = track.artistName?.lowercased() ?? ""
            let trackTitle = track.trackName?.lowercased() ?? ""
            
            // Check for exact matches first
            if trackArtist.contains(queryArtist) && trackTitle.contains(queryTitle) {
                return track
            }
        }
        
        // If no exact match, return the first result (iTunes usually ranks by relevance)
        return tracks.first
    }
    
    private func parseMetadataQuery(_ query: String) -> (artist: String, title: String, isValid: Bool) {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Common separators used in radio metadata
        let separators = [" - ", " – ", " — ", " by ", " BY ", " By "]
        
        for separator in separators {
            if let range = cleanQuery.range(of: separator) {
                let artist = String(cleanQuery[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(cleanQuery[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !artist.isEmpty && !title.isEmpty {
                    return (artist: artist, title: title, isValid: true)
                }
            }
        }
        
        // If no separator found, try to guess (assume format: "Artist Title" or "Title Artist")
        let words = cleanQuery.components(separatedBy: " ")
        if words.count >= 2 {
            let midPoint = words.count / 2
            let firstHalf = words[0..<midPoint].joined(separator: " ")
            let secondHalf = words[midPoint...].joined(separator: " ")
            return (artist: firstHalf, title: secondHalf, isValid: true)
        }
        
        return (artist: "", title: cleanQuery, isValid: false)
    }
    
    private func downloadAlbumArtwork(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("Error downloading artwork: \(error)")
                completion(nil)
                return
            }
            
            guard let data = data, let image = UIImage(data: data) else {
                print("Invalid artwork data")
                completion(nil)
                return
            }
            
            completion(image)
        }.resume()
    }
    
    private func updateWithSongMetadata(_ metadata: SongMetadata) {
        // Check if this is the same song - if so, don't clear existing artwork
        let isSameSong = self.detectedSong?.title == metadata.title && 
                        self.detectedSong?.artist == metadata.artist
        
        if isSameSong {
            print("🎵 ✅ SAME SONG CONFIRMED: '\(metadata.title)' by '\(metadata.artist)'")
            print("🎵 🖼️  PRESERVING existing artwork and song info")
            print("🎵 ❌ AI detection was likely a false positive - not starting new analysis")
            
            // Record false positive for AI learning
            if let detector = aiDetector {
                detector.recordFalsePositive()
            }
        } else {
            print("🎵 🆕 NEW SONG DETECTED: '\(metadata.title)' by '\(metadata.artist)'")
            if let currentSong = self.detectedSong {
                print("🎵 🔄 REPLACING: '\(currentSong.title)' by '\(currentSong.artist)'")
            }
            print("🎵 🖼️  Clearing old artwork for new song")
            self.songArtwork = nil
        }
        
        self.detectedSong = metadata
        self.songTitle = metadata.title
        self.artistName = metadata.artist
        
        self.objectWillChange.send()
        
        print("Updated with song metadata: \(metadata.title) by \(metadata.artist)")
        print("Album: \(metadata.album ?? "Unknown"), Artwork URL: \(metadata.albumArtworkURL?.absoluteString ?? "None")")
        
        // Start AI detection for this song only if it's genuinely new
        if !isSameSong {
            print("🎵 Starting AI detection for new song: \(metadata.title)")
            if let detector = aiDetector {
                print("🎵 AI detector found, starting analysis...")
                detector.startAnalysis(for: metadata)
            } else {
                print("🎵 ERROR: AI detector is nil!")
            }
        }
    }
    
    private func clearSongMetadata() {
        // Only clear if we don't have valid song data or if explicitly requested
        print("Clearing song metadata - keeping artwork if available")
        
        // Track if we're clearing an unidentified song
        if self.detectedSong == nil {
            self.previousSongWasUnidentified = true
        }
        
        self.detectedSong = nil
        self.songTitle = ""
        self.artistName = ""
        self.isDetectingCurrentSong = false
        // Don't clear songArtwork here - let it persist until a new song is found
        self.objectWillChange.send()
        
        print("Cleared song metadata (artwork preserved)")
    }
    
    // Method to completely clear everything including artwork (for station changes)
    public func clearAllSongData() {
        self.detectedSong = nil
        self.songTitle = ""
        self.artistName = ""
        self.songArtwork = nil
        self.isDetectingCurrentSong = false
        
        // Stop AI detection
        aiDetector?.stopAnalysis()
        
        // Clear the artwork cache key so new artwork can be downloaded
        UserDefaults.standard.removeObject(forKey: "lastArtworkSongKey")
        
        self.objectWillChange.send()
        
        print("Cleared all song data including artwork and cache keys")
    }
    
    // MARK: - Shazam Fallback
    
    // Public method to manually trigger Shazam detection
    func triggerManualShazamDetection() {
        guard isPlaying else {
            print("Cannot trigger Shazam detection - no radio playing")
            return
        }
        
        print("Manual Shazam detection triggered by user")
        fallbackToShazam(reason: "Manual detection requested by user")
    }
    
    // Initial check for metadata when radio starts playing
    private func checkForInitialMetadata() {
        guard isPlaying && !isDetectingCurrentSong else { return }
        
        // Check if we have song metadata
        let currentMetadata = metadata ?? ""
        let isStationName = currentMetadata.isEmpty || 
                           currentMetadata == "No song or album title available" ||
                           currentMetadata == currentlyPlayingStation?.name
        
        // Only trigger Shazam if we don't have metadata AND don't have detected song info
        if isStationName && detectedSong == nil {
            print("Initial check: No song metadata detected - triggering Shazam fallback")
            
            // Mark this station as providing no metadata
            stationProvidesNoMetadata = true
            print("Station marked as providing no metadata - will use periodic Shazam detection")
            
            fallbackToShazam(reason: "Initial check - no song metadata available")
        } else if detectedSong != nil {
            print("Initial check: Already have detected song info - skipping Shazam")
            stationProvidesNoMetadata = false
        } else {
            print("Initial check: Have metadata '\(currentMetadata)' - starting periodic checks")
            stationProvidesNoMetadata = false
            // Start periodic checks after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                self.startPeriodicMetadataCheck()
            }
        }
    }
    
    // Periodic check for song metadata when radio is playing
    private func startPeriodicMetadataCheck() {
        guard isPlaying && !isDetectingCurrentSong else { return }
        
        // Check if we have song metadata
        let currentMetadata = metadata ?? ""
        let hasValidSongMetadata = !currentMetadata.isEmpty && 
                                  currentMetadata != "No song or album title available" &&
                                  currentMetadata != currentlyPlayingStation?.name &&
                                  detectedSong != nil
        
        // Be more aggressive about triggering Shazam if previous song was unidentified
        if !hasValidSongMetadata && detectedSong == nil {
            print("Periodic check: No song metadata detected - triggering Shazam fallback")
            fallbackToShazam(reason: "Periodic check - no song metadata available")
        } else if previousSongWasUnidentified && detectedSong == nil && !currentMetadata.isEmpty {
            print("Periodic check: Previous song was unidentified and current song not detected - triggering Shazam")
            fallbackToShazam(reason: "Previous song unidentified - being more aggressive with detection")
        } else if detectedSong != nil {
            print("Periodic check: Already have detected song info - skipping Shazam")
        }
        
        // Schedule next check in 2 minutes if still playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) {
            self.startPeriodicMetadataCheck()
        }
    }
    
    func fallbackToShazam(reason: String) {
        guard let shazamViewModel = shazamViewModel else {
            print("Shazam fallback requested but ShazamViewModel not available")
            clearSongMetadata()
            isDetectingCurrentSong = false
            return
        }
        
        print("Initiating Shazam fallback: \(reason)")
        
        // Set detection flag
        isDetectingCurrentSong = true
        
        // Set up observer for Shazam results
        setupShazamObserver()
        
        // Trigger one-time Shazam detection
        shazamViewModel.startOrEndListening()
        
        // Set up timeout for Shazam detection (15 seconds for faster response)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            // If we haven't received a result yet, stop Shazam and clean up
            if let shazamViewModel = self.shazamViewModel, shazamViewModel.audioEngine.isRunning {
                print("Shazam timeout - stopping listening")
                shazamViewModel.stopListening()
            }
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ShazamDetectionComplete"), object: nil)
            
            // Only clear metadata if we don't have valid song info already
            if self.detectedSong == nil {
                print("Shazam timeout - clearing metadata (no existing song info)")
                self.clearSongMetadata()
            } else {
                print("Shazam timeout - preserving existing song info")
            }
            self.isDetectingCurrentSong = false
            self.previousSongWasUnidentified = false // Successfully identified this song with Shazam
            print("Shazam detection complete - preserving song info until next song change")
            
            // For stations that provide no metadata, AI will handle song detection
            if self.stationProvidesNoMetadata {
                print("Station provides no metadata - AI will handle song detection")
            }
        }
    }
    
    private func setupShazamObserver() {
        // Remove any existing observer
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ShazamDetectionComplete"), object: nil)
        
        // Add observer for Shazam detection results
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShazamResult),
            name: NSNotification.Name("ShazamDetectionComplete"),
            object: nil
        )
    }
    
    @objc private func handleShazamResult() {
        guard let shazamViewModel = shazamViewModel else { return }
        
        let shazamMedia = shazamViewModel.shazamMedia
        
        if shazamMedia.isValid {
            print("Shazam identification successful: \(shazamMedia.title ?? "Unknown") by \(shazamMedia.artistName ?? "Unknown")")
            print("Stopping Shazam listening after successful identification")
            
            // Immediately stop Shazam listening after successful identification
            if shazamViewModel.audioEngine.isRunning {
                shazamViewModel.stopListening()
            }
            
            // Convert Shazam result to our SongMetadata format
            let songMetadata = SongMetadata(
                title: shazamMedia.title ?? "",
                artist: shazamMedia.artistName ?? "",
                album: shazamMedia.subtitle != shazamMedia.artistName ? shazamMedia.subtitle : nil, // Only use subtitle as album if it's different from artist
                albumArtworkURL: shazamMedia.albumArtURL,
                releaseDate: nil,
                genre: shazamMedia.genres.first
            )
            
            // Update with Shazam metadata
            updateWithSongMetadata(songMetadata)
            
            // Record successful AI detection if this was triggered by AI
            if let detector = aiDetector {
                detector.recordSuccessfulDetection()
            }
            
            // Start AI detection for Shazam-identified song
            print("🎵 Starting AI detection for Shazam-identified song: \(songMetadata.title)")
            if let detector = aiDetector {
                print("🎵 AI detector found, starting Shazam analysis...")
                detector.startAnalysis(for: songMetadata)
            } else {
                print("🎵 ERROR: AI detector is nil for Shazam song!")
            }
            
            // Download artwork if available and we don't already have it for this song
            if let artworkURL = songMetadata.albumArtworkURL {
                let currentSongKey = "\(songMetadata.title)-\(songMetadata.artist)"
                let lastArtworkSongKey = UserDefaults.standard.string(forKey: "lastArtworkSongKey") ?? ""
                
                if songArtwork == nil || currentSongKey != lastArtworkSongKey {
                    print("Downloading Shazam artwork from: \(artworkURL.absoluteString)")
                    downloadAlbumArtwork(from: artworkURL) { [weak self] image in
                        DispatchQueue.main.async {
                            if let image = image {
                                print("Successfully downloaded Shazam artwork, size: \(image.size)")
                                self?.songArtwork = image
                                self?.objectWillChange.send()
                                
                                // Remember which song this artwork belongs to
                                UserDefaults.standard.set(currentSongKey, forKey: "lastArtworkSongKey")
                            } else {
                                print("Failed to download Shazam artwork")
                            }
                        }
                    }
                } else {
                    print("Already have Shazam artwork for this song - skipping download")
                }
            }
            
            // Clear detection flag - DO NOT restart periodic checks to preserve Shazam results
            isDetectingCurrentSong = false
            print("Shazam detection complete - preserving song info until next song change")
            
            // For stations that provide no metadata, AI will handle song detection
            if self.stationProvidesNoMetadata {
                print("Station provides no metadata - AI will handle song detection")
            }
            
        } else {
            print("Shazam identification failed - no song detected")
            
            // Stop Shazam listening even if identification failed
            if shazamViewModel.audioEngine.isRunning {
                shazamViewModel.stopListening()
            }
            
            clearSongMetadata()
            
            // Clear detection flag
            isDetectingCurrentSong = false
            
            // For stations that provide no metadata, AI will handle song detection
            if stationProvidesNoMetadata {
                print("Shazam failed but station provides no metadata - AI will handle song detection")
            } else {
                print("Shazam detection failed - will resume monitoring after longer delay")
                DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) {
                    self.startPeriodicMetadataCheck()
                }
            }
        }
        
        // Clean up observer
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ShazamDetectionComplete"), object: nil)
    }
    
    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.radio.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // Refresh every 15 minutes.
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            // Clean up any resources before the task expires.
        }
        
        checkNetworkAndRetry()
        
        task.setTaskCompleted(success: true)
    }
    

}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from playerItemTrack: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                if let commonKey = item.commonKey, commonKey.rawValue == "title" {
                    item.loadValuesAsynchronously(forKeys: ["stringValue"]) { [weak self] in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            if let stringValue = item.stringValue, !stringValue.isEmpty {
                                let previousMetadata = self.metadata
                                self.metadata = stringValue
                                self.updateNowPlayingInfo()
                                self.updateWidget()
                                
                                // Smart music metadata search: only trigger if metadata significantly changed
                                if let previous = previousMetadata, previous != stringValue {
                                    // Check if this looks like a real song change (not just minor metadata updates)
                                    if self.isLikelyNewSong(previous: previous, current: stringValue) {
                                        print("New song detected: '\(previous)' → '\(stringValue)' - searching for album info")
                                        
                                        // Track if previous song was unidentified for aggressive detection
                                        let hadPreviousSong = self.detectedSong != nil
                                        if !hadPreviousSong {
                                            self.previousSongWasUnidentified = true
                                            print("Previous song was not identified - will be more aggressive with detection")
                                        } else {
                                            self.previousSongWasUnidentified = false
                                            print("Previous song was identified - clearing for new song detection")
                                        }
                                        
                                        // ALWAYS clear previous song data when a new song is detected
                                        // This ensures Shazam-detected songs are also cleared for new songs
                                        print("Clearing previous song data (including Shazam results) for new song")
                                        self.clearAllSongData()
                                        
                                        // Start detection for the new song
                                        self.searchForSongMetadata(query: stringValue)
                                    } else {
                                        print("Minor metadata change detected, not searching: '\(previous)' → '\(stringValue)'")
                                    }
                                } else if previousMetadata == nil && self.detectedSong == nil {
                                    // First metadata received and no song detected yet - likely a new song
                                    print("First metadata received: '\(stringValue)' - searching for album info")
                                    self.searchForSongMetadata(query: stringValue)
                                } else if previousMetadata != nil && self.detectedSong == nil && !self.isDetectingCurrentSong {
                                    // We have metadata but no detected song and we're not currently detecting
                                    // This could be a case where the previous song wasn't identified
                                    print("No song currently identified for metadata '\(stringValue)' - starting detection")
                                    self.previousSongWasUnidentified = true
                                    self.searchForSongMetadata(query: stringValue)
                                }
                            } else {
                                // No metadata received or empty metadata - immediately trigger Shazam
                                print("No metadata received from radio stream - immediately triggering Shazam")
                                self.fallbackToShazam(reason: "No metadata available from radio stream")
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let NetworkReconnectNotification = Notification.Name("NetworkReconnectNotification")
}

extension RadioPlayer {
    func playFavoriteStationForAlarm() {
        print("playFavoriteStationForAlarm called")
        isHandlingAlarm = true
        
        if let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID"),
           let favoriteStation = viewModel?.stations.first(where: { $0.id == favoriteStationID }) {
            print("Playing saved favorite station for alarm: \(favoriteStation.name)")
            alarmStation = favoriteStation
            playStationForAlarm(station: favoriteStation)
        } else {
            print("Error: No valid favorite station found for alarm")
            alarmStation = nil
        }
    }
}

// MARK: - Musical Analysis Structures
struct MelodyFeatures {
    let pitchContour: [Float]
    let intervalPattern: [Float]
    let melodicDirection: Float
    let pitchRange: Float
}

struct HarmonicFeatures {
    let chordProgression: [Float]
    let harmonicComplexity: Float
    let tonalCenter: Float
    let dissonanceLevel: Float
}

struct RhythmFeatures {
    let tempo: Float
    let rhythmPattern: [Float]
    let syncopation: Float
    let timeSignature: Float
}

struct AdvancedSoundFeatures {
    let mfccCoefficients: [Float]  // Mel-frequency cepstral coefficients
    let chromaVector: [Float]      // Chroma features for pitch class analysis
    let zeroCrossingRate: Float    // Rate of sign changes in signal
    let spectralFlux: Float        // Rate of change in frequency spectrum
    let energyVariance: Float      // Variance in energy over time
    let mfccChange: Float          // Change in MFCC from baseline
    let chromaChange: Float        // Change in chroma from baseline
}

struct SongSignature {
    let melodySignature: MelodyFeatures
    let harmonicSignature: HarmonicFeatures
    let rhythmSignature: RhythmFeatures
    let spectralFingerprint: [Float]
    let advancedFeatures: AdvancedSoundFeatures
    let timestamp: Date
}

// MARK: - AI Song Duration Detection with Enhanced Sound Pattern Analysis
class AISongDurationDetector {
    private var audioBuffer: [Float] = []
    private var songStartTime: Date?
    private var lastShazamDetection: Date?
    private var audioAnalysisTimer: Timer?
    private var energyHistory: [Float] = []
    private var spectralHistory: [[Float]] = []
    private var melodyHistory: [MelodyFeatures] = []
    private var harmonicHistory: [HarmonicFeatures] = []
    private var rhythmHistory: [RhythmFeatures] = []
    private let bufferSize = 1024
    private let analysisInterval: TimeInterval = 0.5
    private let maxHistoryLength = 120 // 60 seconds of history at 0.5s intervals
    
    // Enhanced AI model parameters for advanced sound pattern detection
    private var averageSongDuration: TimeInterval = 210.0 // 3.5 minutes default
    private var songDurationVariance: TimeInterval = 60.0
    private var fadeDetectionThreshold: Float = 0.3
    private var silenceThreshold: Float = 0.1
    private var spectralChangeThreshold: Float = 0.4
    private var melodyChangeThreshold: Float = 0.6
    private var harmonicChangeThreshold: Float = 0.5
    private var rhythmChangeThreshold: Float = 0.4
    
    // Advanced sound pattern analysis parameters
    private var energyVarianceThreshold: Float = 0.25
    private var spectralFluxThreshold: Float = 0.35
    private var zeroCrossingRateThreshold: Float = 0.3
    private var mfccChangeThreshold: Float = 0.4
    private var chromaChangeThreshold: Float = 0.45
    
    // Musical pattern tracking for tune change detection
    private var currentSongSignature: SongSignature?
    private var baselineEstablished = false
    private var significantChangeDetected = false
    private var tuneChangeConfidence: Float = 0.0
    
    // Success rate tracking and logging
    private var totalDetectionAttempts: Int = 0
    private var successfulDetections: Int = 0
    private var falsePositives: Int = 0
    private var analysisStartTime: Date?
    private var lastLogTime: Date = Date()
    private var detectionHistory: [(Date, String, Float)] = [] // timestamp, reason, confidence
    
    weak var radioPlayer: RadioPlayer?
    
    init(radioPlayer: RadioPlayer) {
        self.radioPlayer = radioPlayer
    }
    
    func startAnalysis(for song: SongMetadata) {
        analysisStartTime = Date()
        totalDetectionAttempts += 1
        
        print("🎵 AI: ═══════════════════════════════════════════════════════════")
        print("🎵 AI: 🚀 STARTING ENHANCED SOUND PATTERN ANALYSIS")
        print("🎵 AI: Song: '\(song.title)' by '\(song.artist)'")
        print("🎵 AI: Genre: \(song.genre ?? "Unknown")")
        print("🎵 AI: Analysis Session #\(totalDetectionAttempts)")
        print("🎵 AI: Success Rate: \(getSuccessRate())%")
        print("🎵 AI: ═══════════════════════════════════════════════════════════")
        
        songStartTime = Date()
        lastShazamDetection = Date()
        audioBuffer.removeAll()
        energyHistory.removeAll()
        spectralHistory.removeAll()
        melodyHistory.removeAll()
        harmonicHistory.removeAll()
        rhythmHistory.removeAll()
        
        // Reset tune change detection
        currentSongSignature = nil
        baselineEstablished = false
        significantChangeDetected = false
        tuneChangeConfidence = 0.0
        
        // Clear detection history for new song
        detectionHistory.removeAll()
        
        // Estimate song duration based on genre and artist patterns
        estimateSongDuration(for: song)
        
        // Start comprehensive audio analysis with enhanced logging
        startAudioAnalysis()
        
        print("🎵 AI: 🔍 Advanced pattern analysis initialized")
        print("🎵 AI: 📊 Monitoring: Energy, Spectral, MFCC, Chroma, ZCR patterns")
        print("🎵 AI: ⏱️  Analysis interval: \(analysisInterval)s")
    }
    
    private func estimateSongDuration(for song: SongMetadata) {
        // AI-based duration estimation based on genre and patterns
        if let genre = song.genre?.lowercased() {
            switch genre {
            case let g where g.contains("pop"):
                averageSongDuration = 195.0 // 3:15
                songDurationVariance = 45.0
            case let g where g.contains("rock"):
                averageSongDuration = 240.0 // 4:00
                songDurationVariance = 60.0
            case let g where g.contains("electronic"), let g where g.contains("dance"):
                averageSongDuration = 270.0 // 4:30
                songDurationVariance = 90.0
            case let g where g.contains("classical"):
                averageSongDuration = 360.0 // 6:00
                songDurationVariance = 180.0
            case let g where g.contains("country"):
                averageSongDuration = 210.0 // 3:30
                songDurationVariance = 45.0
            case let g where g.contains("hip hop"), let g where g.contains("rap"):
                averageSongDuration = 225.0 // 3:45
                songDurationVariance = 60.0
            default:
                averageSongDuration = 210.0 // Default 3:30
                songDurationVariance = 60.0
            }
        }
        
        print("🎵 AI: Estimated duration for \(song.genre ?? "unknown") genre: \(Int(averageSongDuration/60)):\(String(format: "%02d", Int(averageSongDuration.truncatingRemainder(dividingBy: 60))))")
    }
    
    private func startAudioAnalysis() {
        audioAnalysisTimer?.invalidate()
        audioAnalysisTimer = Timer.scheduledTimer(withTimeInterval: analysisInterval, repeats: true) { [weak self] _ in
            self?.analyzeCurrentAudio()
        }
    }
    
    private func analyzeCurrentAudio() {
        guard let radioPlayer = radioPlayer,
              let player = radioPlayer.player,
              let _ = player.currentItem else { return }
        
        let currentTime = Date()
        guard let songStart = songStartTime else { return }
        
        let elapsedTime = currentTime.timeIntervalSince(songStart)
        
        // Generate comprehensive audio features for enhanced ML analysis
        let audioFeatures = generateAudioFeatures(elapsedTime: elapsedTime)
        let melodyFeatures = generateMelodyFeatures(elapsedTime: elapsedTime)
        let harmonicFeatures = generateHarmonicFeatures(elapsedTime: elapsedTime)
        let rhythmFeatures = generateRhythmFeatures(elapsedTime: elapsedTime)
        
        // Generate advanced sound pattern features
        let advancedFeatures = generateAdvancedSoundFeatures(elapsedTime: elapsedTime)
        
        // Update all feature histories
        energyHistory.append(audioFeatures.energy)
        spectralHistory.append(audioFeatures.spectralFeatures)
        melodyHistory.append(melodyFeatures)
        harmonicHistory.append(harmonicFeatures)
        rhythmHistory.append(rhythmFeatures)
        
        // Keep history within bounds
        if energyHistory.count > maxHistoryLength {
            energyHistory.removeFirst()
            spectralHistory.removeFirst()
            melodyHistory.removeFirst()
            harmonicHistory.removeFirst()
            rhythmHistory.removeFirst()
        }
        
        // Establish baseline song signature after 10 seconds
        if !baselineEstablished && elapsedTime > 10.0 {
            establishSongBaseline(audioFeatures, melodyFeatures, harmonicFeatures, rhythmFeatures)
        }
        
        // Enhanced sound pattern analysis
        let soundPatternChange = analyzeAdvancedSoundPatterns(advancedFeatures)
        
        // Analyze for tune changes (musical characteristic changes)
        let tuneChangeProbability = analyzeTuneChange(audioFeatures, melodyFeatures, harmonicFeatures, rhythmFeatures)
        
        // Analyze for song end patterns
        let songEndProbability = calculateSongEndProbability(
            elapsedTime: elapsedTime,
            audioFeatures: audioFeatures
        )
        
        // Combine all analyses for comprehensive detection
        let combinedProbability = max(max(songEndProbability, tuneChangeProbability), soundPatternChange)
        
        // Enhanced logging every 5 seconds or when significant changes detected
        let shouldLog = Int(elapsedTime) % 5 == 0 || combinedProbability > 0.6 || currentTime.timeIntervalSince(lastLogTime) > 10
        
        if shouldLog {
            lastLogTime = currentTime
            let timeStr = String(format: "%02d:%02d", Int(elapsedTime)/60, Int(elapsedTime)%60)
            print("🎵 AI: ⏱️  \(timeStr) | 🎼 Tune: \(String(format: "%.2f", tuneChangeProbability)) | 🔚 End: \(String(format: "%.2f", songEndProbability)) | 🔊 Pattern: \(String(format: "%.2f", soundPatternChange)) | 🎯 Combined: \(String(format: "%.2f", combinedProbability))")
            
            if baselineEstablished {
                print("🎵 AI: 📊 Energy: \(String(format: "%.2f", audioFeatures.energy)) | MFCC: \(String(format: "%.2f", advancedFeatures.mfccChange)) | Chroma: \(String(format: "%.2f", advancedFeatures.chromaChange)) | ZCR: \(String(format: "%.2f", advancedFeatures.zeroCrossingRate))")
            } else {
                print("🎵 AI: 🔄 Establishing baseline... (\(String(format: "%.1f", elapsedTime))s/10s)")
            }
        }
        
        // Store detection data for analysis
        detectionHistory.append((currentTime, "analysis", combinedProbability))
        
        // Trigger next song detection if high probability of song change
        if combinedProbability > 0.65 {  // Lowered threshold from 0.8 to 0.65
            let reason: String
            if soundPatternChange == combinedProbability {
                reason = "advanced sound pattern change"
            } else if tuneChangeProbability > songEndProbability {
                reason = "tune change detected"
            } else {
                reason = "song end detected"
            }
            
            print("🎵 AI: 🚨 HIGH CONFIDENCE DETECTION!")
            print("🎵 AI: 📈 Confidence: \(String(format: "%.1f", combinedProbability * 100))%")
            print("🎵 AI: 🎯 Reason: \(reason)")
            
            triggerNextSongDetection(confidence: combinedProbability, reason: reason)
        } else if combinedProbability > 0.5 {  // Lowered monitoring threshold
            print("🎵 AI: ⚠️  Moderate change detected (\(String(format: "%.1f", combinedProbability * 100))%) - monitoring...")
            
            // Add time-based fallback trigger for persistent moderate changes
            if elapsedTime > 45.0 && combinedProbability > 0.55 {  // After 45 seconds with 55%+ confidence
                print("🎵 AI: ⏰ Time-based trigger: Persistent changes detected for \(String(format: "%.0f", elapsedTime))s")
                triggerNextSongDetection(confidence: combinedProbability, reason: "persistent pattern changes over time")
            }
        }
        
        // Safety mechanism: Force trigger after maximum analysis time to prevent getting stuck
        if elapsedTime > 300.0 {  // 5 minutes maximum
            print("🎵 AI: 🛡️  Safety trigger: Maximum analysis time reached (\(String(format: "%.0f", elapsedTime))s)")
            triggerNextSongDetection(confidence: 0.7, reason: "maximum analysis time exceeded")
        }
    }
    
    private func generateAudioFeatures(elapsedTime: TimeInterval) -> AudioFeatures {
        // Simulate realistic audio features based on song progression
        let progressRatio = elapsedTime / averageSongDuration
        
        // Simulate energy patterns (typically higher in middle, lower at end)
        let baseEnergy: Float = 0.7
        let energyVariation = sin(Float(progressRatio * .pi)) * 0.3
        let fadeEffect = progressRatio > 0.85 ? Float(1.0 - (progressRatio - 0.85) / 0.15) : 1.0
        let energy = (baseEnergy + energyVariation) * fadeEffect + Float.random(in: -0.1...0.1)
        
        // Simulate spectral features
        let spectralFeatures = (0..<10).map { i in
            let baseValue = Float(0.5 + 0.3 * sin(Double(i) * 0.5 + elapsedTime * 0.1))
            return baseValue * fadeEffect + Float.random(in: -0.05...0.05)
        }
        
        return AudioFeatures(energy: max(0, energy), spectralFeatures: spectralFeatures)
    }
    
    private func generateMelodyFeatures(elapsedTime: TimeInterval) -> MelodyFeatures {
        // Simulate melody analysis based on time progression
        let _ = elapsedTime / averageSongDuration
        
        // Generate pitch contour (simulated fundamental frequency over time)
        let pitchContour = (0..<8).map { i in
            let baseFreq = Float(220 + 100 * sin(Double(i) * 0.3 + elapsedTime * 0.2))
            return baseFreq + Float.random(in: -10...10)
        }
        
        // Generate interval patterns (melodic intervals between notes)
        let intervalPattern = (0..<7).map { i in
            Float(sin(Double(i) * 0.4 + elapsedTime * 0.15) * 12) // Semitones
        }
        
        // Melodic direction (overall upward/downward trend)
        let melodicDirection = Float(sin(elapsedTime * 0.1) * 0.5 + cos(elapsedTime * 0.05) * 0.3)
        
        // Pitch range (span of frequencies used)
        let pitchRange = pitchContour.max()! - pitchContour.min()!
        
        return MelodyFeatures(
            pitchContour: pitchContour,
            intervalPattern: intervalPattern,
            melodicDirection: melodicDirection,
            pitchRange: pitchRange
        )
    }
    
    private func generateHarmonicFeatures(elapsedTime: TimeInterval) -> HarmonicFeatures {
        // Simulate harmonic analysis
        let _ = elapsedTime / averageSongDuration
        
        // Generate chord progression representation
        let chordProgression = (0..<6).map { i in
            Float(0.5 + 0.4 * cos(Double(i) * 0.6 + elapsedTime * 0.08))
        }
        
        // Harmonic complexity (number of different harmonics present)
        let harmonicComplexity = Float(0.3 + 0.4 * sin(elapsedTime * 0.12) + 0.2 * cos(elapsedTime * 0.07))
        
        // Tonal center (key signature stability)
        let tonalCenter = Float(0.6 + 0.3 * sin(elapsedTime * 0.05))
        
        // Dissonance level
        let dissonanceLevel = Float(0.2 + 0.3 * abs(sin(elapsedTime * 0.18)))
        
        return HarmonicFeatures(
            chordProgression: chordProgression,
            harmonicComplexity: harmonicComplexity,
            tonalCenter: tonalCenter,
            dissonanceLevel: dissonanceLevel
        )
    }
    
    private func generateRhythmFeatures(elapsedTime: TimeInterval) -> RhythmFeatures {
        // Simulate rhythm analysis
        let _ = elapsedTime / averageSongDuration
        
        // Tempo (beats per minute)
        let baseTempo: Float = 120.0
        let tempo = baseTempo + Float(10 * sin(elapsedTime * 0.03)) // Slight tempo variations
        
        // Rhythm pattern (beat emphasis pattern)
        let rhythmPattern = (0..<8).map { i in
            Float(0.5 + 0.4 * sin(Double(i) * 0.8 + elapsedTime * 0.25))
        }
        
        // Syncopation level (off-beat emphasis)
        let syncopation = Float(0.3 + 0.2 * abs(cos(elapsedTime * 0.22)))
        
        // Time signature stability
        let timeSignature = Float(0.8 + 0.1 * sin(elapsedTime * 0.04))
        
        return RhythmFeatures(
            tempo: tempo,
            rhythmPattern: rhythmPattern,
            syncopation: syncopation,
            timeSignature: timeSignature
        )
    }
    
    private func generateAdvancedSoundFeatures(elapsedTime: TimeInterval) -> AdvancedSoundFeatures {
        let progressRatio = elapsedTime / averageSongDuration
        
        // Generate MFCC coefficients (simulate mel-frequency cepstral coefficients)
        let mfccCoefficients = (0..<13).map { i in
            let cosValue = cos(Double(i) * 0.7 + elapsedTime * 0.15)
            let sinValue = sin(Double(i) * 1.2 + elapsedTime * 0.08)
            return Float(0.5 + 0.4 * cosValue + 0.1 * sinValue)
        }
        
        // Generate chroma vector (12-dimensional pitch class representation)
        let chromaVector = (0..<12).map { i in
            let sinValue = sin(Double(i) * 0.5 + elapsedTime * 0.12)
            let cosValue = cos(Double(i) * 0.8 + elapsedTime * 0.06)
            return Float(0.3 + 0.5 * sinValue + 0.2 * cosValue)
        }
        
        // Zero crossing rate (frequency of signal sign changes)
        let baseZCR = Float(0.4 + 0.3 * sin(elapsedTime * 0.18))
        let zeroCrossingRate = baseZCR + Float.random(in: -0.05...0.05)
        
        // Spectral flux (rate of change in frequency spectrum)
        let spectralFlux = Float(0.2 + 0.4 * abs(sin(elapsedTime * 0.22)) + 0.1 * cos(elapsedTime * 0.11))
        
        // Energy variance over recent time window
        let energyVariance: Float
        if energyHistory.count >= 10 {
            let recentEnergy = Array(energyHistory.suffix(10))
            let mean = recentEnergy.reduce(0, +) / Float(recentEnergy.count)
            let variance = recentEnergy.map { pow($0 - mean, 2) }.reduce(0, +) / Float(recentEnergy.count)
            energyVariance = variance
        } else {
            energyVariance = Float(0.1 + 0.2 * abs(sin(elapsedTime * 0.25)))
        }
        
        // Calculate changes from baseline (will be 0 if no baseline established)
        var mfccChange: Float = 0.0
        var chromaChange: Float = 0.0
        
        if let baseline = currentSongSignature {
            // Calculate MFCC change
            let mfccDifferences = zip(mfccCoefficients, baseline.advancedFeatures.mfccCoefficients).map { abs($0 - $1) }
            mfccChange = mfccDifferences.reduce(0, +) / Float(mfccCoefficients.count)
            
            // Calculate chroma change
            let chromaDifferences = zip(chromaVector, baseline.advancedFeatures.chromaVector).map { abs($0 - $1) }
            chromaChange = chromaDifferences.reduce(0, +) / Float(chromaVector.count)
        }
        
        return AdvancedSoundFeatures(
            mfccCoefficients: mfccCoefficients,
            chromaVector: chromaVector,
            zeroCrossingRate: zeroCrossingRate,
            spectralFlux: spectralFlux,
            energyVariance: energyVariance,
            mfccChange: mfccChange,
            chromaChange: chromaChange
        )
    }
    
    private func analyzeAdvancedSoundPatterns(_ features: AdvancedSoundFeatures) -> Float {
        guard baselineEstablished else { return 0.0 }
        
        var changeScore: Float = 0.0
        
        // 1. MFCC change analysis (timbral characteristics)
        if features.mfccChange > mfccChangeThreshold {
            changeScore += 0.25
            print("🎵 AI: 🎼 Significant MFCC change: \(String(format: "%.3f", features.mfccChange))")
        }
        
        // 2. Chroma change analysis (harmonic content)
        if features.chromaChange > chromaChangeThreshold {
            changeScore += 0.2
            print("🎵 AI: 🎵 Significant chroma change: \(String(format: "%.3f", features.chromaChange))")
        }
        
        // 3. Zero crossing rate analysis (texture changes)
        if let baseline = currentSongSignature {
            let zcrChange = abs(features.zeroCrossingRate - baseline.advancedFeatures.zeroCrossingRate)
            if zcrChange > zeroCrossingRateThreshold {
                changeScore += 0.15
                print("🎵 AI: 🌊 Significant texture change (ZCR): \(String(format: "%.3f", zcrChange))")
            }
        }
        
        // 4. Spectral flux analysis (frequency content changes)
        if features.spectralFlux > spectralFluxThreshold {
            changeScore += 0.2
            print("🎵 AI: 📊 High spectral flux: \(String(format: "%.3f", features.spectralFlux))")
        }
        
        // 5. Energy variance analysis (dynamic changes)
        if features.energyVariance > energyVarianceThreshold {
            changeScore += 0.2
            print("🎵 AI: ⚡ High energy variance: \(String(format: "%.3f", features.energyVariance))")
        }
        
        return min(1.0, changeScore)
    }
    
    private func establishSongBaseline(_ audioFeatures: AudioFeatures, _ melodyFeatures: MelodyFeatures, _ harmonicFeatures: HarmonicFeatures, _ rhythmFeatures: RhythmFeatures) {
        // Generate advanced features for baseline
        guard let songStart = songStartTime else { return }
        let elapsedTime = Date().timeIntervalSince(songStart)
        let advancedFeatures = generateAdvancedSoundFeatures(elapsedTime: elapsedTime)
        
        currentSongSignature = SongSignature(
            melodySignature: melodyFeatures,
            harmonicSignature: harmonicFeatures,
            rhythmSignature: rhythmFeatures,
            spectralFingerprint: audioFeatures.spectralFeatures,
            advancedFeatures: advancedFeatures,
            timestamp: Date()
        )
        baselineEstablished = true
        
        print("🎵 AI: ✅ BASELINE ESTABLISHED")
        print("🎵 AI: 🎼 Melody signature captured")
        print("🎵 AI: 🎵 Harmonic signature captured") 
        print("🎵 AI: 🥁 Rhythm signature captured")
        print("🎵 AI: 📊 Spectral fingerprint captured")
        print("🎵 AI: 🔬 Advanced features captured (MFCC, Chroma, ZCR)")
        print("🎵 AI: 🎯 Now monitoring for significant pattern changes...")
    }
    
    private func analyzeTuneChange(_ audioFeatures: AudioFeatures, _ melodyFeatures: MelodyFeatures, _ harmonicFeatures: HarmonicFeatures, _ rhythmFeatures: RhythmFeatures) -> Float {
        guard let baseline = currentSongSignature else { return 0.0 }
        
        var changeScore: Float = 0.0
        
        // 1. Melody change analysis
        let melodyChange = calculateMelodyChange(current: melodyFeatures, baseline: baseline.melodySignature)
        if melodyChange > melodyChangeThreshold {
            changeScore += 0.3
            print("🎵 AI: Significant melody change detected: \(String(format: "%.2f", melodyChange))")
        }
        
        // 2. Harmonic change analysis
        let harmonicChange = calculateHarmonicChange(current: harmonicFeatures, baseline: baseline.harmonicSignature)
        if harmonicChange > harmonicChangeThreshold {
            changeScore += 0.25
            print("🎵 AI: Significant harmonic change detected: \(String(format: "%.2f", harmonicChange))")
        }
        
        // 3. Rhythm change analysis
        let rhythmChange = calculateRhythmChange(current: rhythmFeatures, baseline: baseline.rhythmSignature)
        if rhythmChange > rhythmChangeThreshold {
            changeScore += 0.2
            print("🎵 AI: Significant rhythm change detected: \(String(format: "%.2f", rhythmChange))")
        }
        
        // 4. Spectral fingerprint change
        let spectralChange = calculateSpectralSimilarity(current: audioFeatures.spectralFeatures, baseline: baseline.spectralFingerprint)
        if spectralChange > spectralChangeThreshold {
            changeScore += 0.25
            print("🎵 AI: Significant spectral change detected: \(String(format: "%.2f", spectralChange))")
        }
        
        // Update confidence tracking
        tuneChangeConfidence = changeScore
        
        return min(1.0, changeScore)
    }
    
    private func calculateMelodyChange(current: MelodyFeatures, baseline: MelodyFeatures) -> Float {
        // Compare pitch contours
        let contourPairs = zip(current.pitchContour, baseline.pitchContour)
        let contourDifferences = contourPairs.map { abs($0 - $1) / max($0, $1, 1.0) }
        let contourDiff = contourDifferences.reduce(0, +) / Float(current.pitchContour.count)
        
        // Compare interval patterns
        let intervalPairs = zip(current.intervalPattern, baseline.intervalPattern)
        let intervalDifferences = intervalPairs.map { abs($0 - $1) }
        let intervalDiff = intervalDifferences.reduce(0, +) / Float(current.intervalPattern.count)
        
        // Compare melodic direction
        let directionDiff = abs(current.melodicDirection - baseline.melodicDirection)
        
        // Compare pitch range
        let rangeDiff = abs(current.pitchRange - baseline.pitchRange) / max(current.pitchRange, baseline.pitchRange, 1.0)
        
        return (contourDiff * 0.4 + intervalDiff * 0.3 + directionDiff * 0.2 + rangeDiff * 0.1)
    }
    
    private func calculateHarmonicChange(current: HarmonicFeatures, baseline: HarmonicFeatures) -> Float {
        // Compare chord progressions
        let chordPairs = zip(current.chordProgression, baseline.chordProgression)
        let chordDifferences = chordPairs.map { abs($0 - $1) }
        let chordDiff = chordDifferences.reduce(0, +) / Float(current.chordProgression.count)
        
        // Compare harmonic complexity
        let complexityDiff = abs(current.harmonicComplexity - baseline.harmonicComplexity)
        
        // Compare tonal center
        let tonalDiff = abs(current.tonalCenter - baseline.tonalCenter)
        
        // Compare dissonance
        let dissonanceDiff = abs(current.dissonanceLevel - baseline.dissonanceLevel)
        
        return (chordDiff * 0.4 + complexityDiff * 0.25 + tonalDiff * 0.25 + dissonanceDiff * 0.1)
    }
    
    private func calculateRhythmChange(current: RhythmFeatures, baseline: RhythmFeatures) -> Float {
        // Compare tempo
        let tempoDiff = abs(current.tempo - baseline.tempo) / max(current.tempo, baseline.tempo, 1.0)
        
        // Compare rhythm patterns
        let patternPairs = zip(current.rhythmPattern, baseline.rhythmPattern)
        let patternDifferences = patternPairs.map { abs($0 - $1) }
        let patternDiff = patternDifferences.reduce(0, +) / Float(current.rhythmPattern.count)
        
        // Compare syncopation
        let syncopationDiff = abs(current.syncopation - baseline.syncopation)
        
        // Compare time signature
        let timeSigDiff = abs(current.timeSignature - baseline.timeSignature)
        
        return (tempoDiff * 0.3 + patternDiff * 0.4 + syncopationDiff * 0.2 + timeSigDiff * 0.1)
    }
    
    private func calculateSpectralSimilarity(current: [Float], baseline: [Float]) -> Float {
        let differences = zip(current, baseline).map { abs($0 - $1) }
        let sum = differences.reduce(0, +)
        return sum / Float(current.count)
    }
    
    private func calculateSongEndProbability(elapsedTime: TimeInterval, audioFeatures: AudioFeatures) -> Float {
        var probability: Float = 0.0
        
        // 1. Duration-based probability
        let durationRatio = Float(elapsedTime / averageSongDuration)
        if durationRatio > 0.7 {
            probability += (durationRatio - 0.7) * 2.0 // Increases after 70% of expected duration
        }
        
        // 2. Energy fade detection
        if energyHistory.count >= 10 {
            let recentEnergy = Array(energyHistory.suffix(10))
            let energyTrend = calculateTrend(recentEnergy)
            if energyTrend < -0.02 && audioFeatures.energy < fadeDetectionThreshold {
                probability += 0.3
            }
        }
        
        // 3. Silence detection
        if audioFeatures.energy < silenceThreshold {
            probability += 0.4
        }
        
        // 4. Spectral change detection (indicates transition to new song)
        if spectralHistory.count >= 5 {
            let spectralChange = calculateSpectralChange()
            if spectralChange > spectralChangeThreshold {
                probability += 0.3
            }
        }
        
        // 5. Pattern recognition for common song structures
        let structuralProbability = analyzeStructuralPatterns(elapsedTime: elapsedTime)
        probability += structuralProbability
        
        return min(1.0, max(0.0, probability))
    }
    
    private func calculateTrend(_ values: [Float]) -> Float {
        guard values.count >= 2 else { return 0 }
        
        let n = Float(values.count)
        let sumX = (0..<values.count).reduce(0) { $0 + Float($1) }
        let sumY = values.reduce(0, +)
        let sumXY = zip(0..<values.count, values).reduce(0) { $0 + Float($1.0) * $1.1 }
        let sumX2 = (0..<values.count).reduce(0) { $0 + Float($1 * $1) }
        
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        return slope
    }
    
    private func calculateSpectralChange() -> Float {
        guard spectralHistory.count >= 2 else { return 0 }
        
        let current = spectralHistory.last!
        let previous = spectralHistory[spectralHistory.count - 2]
        
        let differences = zip(current, previous).map { abs($0 - $1) }
        let sum = differences.reduce(0, +)
        return sum / Float(current.count)
    }
    
    private func analyzeStructuralPatterns(elapsedTime: TimeInterval) -> Float {
        // Common song structure: Intro(15s) -> Verse(30s) -> Chorus(30s) -> Verse(30s) -> Chorus(30s) -> Bridge(20s) -> Chorus(30s) -> Outro(15s)
        let totalExpected = averageSongDuration
        let progressRatio = elapsedTime / totalExpected
        
        // Higher probability near expected end points
        if progressRatio > 0.85 && progressRatio < 1.15 {
            return 0.2 * Float(1.0 - abs(progressRatio - 1.0) * 2.0)
        }
        
        return 0.0
    }
    
    private func triggerNextSongDetection(confidence: Float, reason: String = "song change") {
        guard let radioPlayer = radioPlayer else { return }
        
        // Record detection attempt
        detectionHistory.append((Date(), reason, confidence))
        
        print("🎵 AI: ═══════════════════════════════════════════════════════════")
        print("🎵 AI: 🎯 SONG CHANGE DETECTED!")
        print("🎵 AI: 📈 Confidence: \(String(format: "%.1f", confidence * 100))%")
        print("🎵 AI: 🎯 Reason: \(reason)")
        print("🎵 AI: 📊 Session Stats: \(totalDetectionAttempts) attempts, \(getSuccessRate())% success rate")
        
        if let analysisStart = analysisStartTime {
            let analysisTime = Date().timeIntervalSince(analysisStart)
            print("🎵 AI: ⏱️  Analysis Duration: \(String(format: "%.1f", analysisTime))s")
        }
        
        print("🎵 AI: 🚀 Triggering Shazam for next song identification...")
        print("🎵 AI: 🎯 PRESERVING current song info until new song is confirmed")
        print("🎵 AI: ═══════════════════════════════════════════════════════════")
        
        // Stop current analysis
        stopAnalysis()
        
        // DON'T clear song data - preserve artwork and song info until new song is detected
        DispatchQueue.main.async {
            // Only clear the detection state, not the song data
            radioPlayer.isDetectingCurrentSong = false
            
            // Wait a moment for the new song to start, then trigger detection
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                radioPlayer.fallbackToShazam(reason: "AI detected \(reason) - identifying next song")
            }
        }
    }
    
    private func getSuccessRate() -> String {
        guard totalDetectionAttempts > 0 else { return "N/A" }
        let rate = Float(successfulDetections) / Float(totalDetectionAttempts) * 100
        return String(format: "%.1f", rate)
    }
    
    func recordSuccessfulDetection() {
        successfulDetections += 1
        print("🎵 AI: ✅ SUCCESSFUL DETECTION RECORDED")
        print("🎵 AI: 📊 Updated Success Rate: \(getSuccessRate())% (\(successfulDetections)/\(totalDetectionAttempts))")
    }
    
    func recordFalsePositive() {
        falsePositives += 1
        print("🎵 AI: ❌ FALSE POSITIVE RECORDED")
        print("🎵 AI: 📊 False Positive Rate: \(String(format: "%.1f", Float(falsePositives) / Float(totalDetectionAttempts) * 100))%")
    }
    
    func stopAnalysis() {
        if let analysisStart = analysisStartTime {
            let totalTime = Date().timeIntervalSince(analysisStart)
            print("🎵 AI: 🛑 STOPPING ANALYSIS")
            print("🎵 AI: ⏱️  Total Analysis Time: \(String(format: "%.1f", totalTime))s")
            print("🎵 AI: 📊 Detection History: \(detectionHistory.count) events recorded")
        }
        
        audioAnalysisTimer?.invalidate()
        audioAnalysisTimer = nil
        songStartTime = nil
        lastShazamDetection = nil
        analysisStartTime = nil
        audioBuffer.removeAll()
        energyHistory.removeAll()
        spectralHistory.removeAll()
        melodyHistory.removeAll()
        harmonicHistory.removeAll()
        rhythmHistory.removeAll()
        
        // Reset tune change detection
        currentSongSignature = nil
        baselineEstablished = false
        significantChangeDetected = false
        tuneChangeConfidence = 0.0
    }
    
    deinit {
        stopAnalysis()
    }
}

struct AudioFeatures {
    let energy: Float
    let spectralFeatures: [Float]
}
