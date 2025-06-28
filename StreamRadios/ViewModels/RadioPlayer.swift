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
import Foundation

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusCancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var retryCount = 0
    private var monitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private var wasPlayingBeforeNetworkLoss = false
    @Published var isBuffering = false
    @Published var isPlaying: Bool = false

    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String?
    @Published var iTunesAlbumArt: UIImage?
    @Published var isHandlingAlarm = false
    @Published var currentlyPlayingStation: RadioStation?
    @Published var alarmStation: RadioStation?
    private var reachability: Reachability?
    private var isOnCellularNetwork = false
    weak var podcastPlayer: PodcastPlayer?
    
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    
    var bitrateSubject = CurrentValueSubject<String, Never>("Playing at high bitrate: 256 kbps")
    private let userDefaultsSuiteName = "group.streamradios"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }
    
    var viewModel: RadioStationViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    // Cache for storing last iTunes artwork per station
    private var stationArtworkCache: [String: (artwork: UIImage, metadata: String)] = [:]
    
    override init() {
        monitor = NWPathMonitor()
        
        super.init()
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
        
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkAvailable = (path.status == .satisfied)
                self?.isOnCellularNetwork = path.usesInterfaceType(.cellular)
            }
        }
        
        // Initialize Now Playing and CarPlay support
        configureAudioSession()
        setupRemoteCommandCenter()
        addInterruptionObserver()
        
        // CRITICAL: Enhanced CarPlay artwork fetching using audio session events
        setupCarPlayArtworkObservation()
        
        print("✅ RadioPlayer initialized with CarPlay and Now Playing support")
        
        DispatchQueue.main.async {
            self.podcastPlayer = PodcastPlayer.shared
            self.podcastPlayer?.setRadioPlayer(self)
        }
        
        autoPlayLastStationSetup()
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
                    self.restoreLastPlayedStation()
                }
            }
        } else {
            // Even if auto-play is disabled, still restore the UI state for manual play
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !self.isHandlingAlarm {
                    self.restoreLastPlayedStationUIOnly()
                }
            }
        }
    }
    
    private func restoreLastPlayedStation() {
        // Use shared UserDefaults consistently for CarPlay compatibility
        if let lastStationID = self.userDefaults?.string(forKey: "LastPlayedStationID") {
            print("🔍 Auto-play: Found LastPlayedStationID: \(lastStationID)")
            
            if let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) {
                print("✅ Auto-play: Found matching station: \(lastStation.name)")
                print("🌍 Auto-play: Station from \(lastStation.country), current country picker: \(self.viewModel?.selectedCountry ?? "unknown")")
                print("📍 Auto-play: Country picker will remain unchanged")
            
                // Play the last played station using the proper playStation method
                if let index = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                    print("🎵 Auto-play: Playing last station using playStation method to ensure Recent tab update")
                    self.playStation(at: index, from: self.viewModel?.stations ?? [])
                } else {
                    // Fallback to manual setup if index not found
                    print("⚠️ Auto-play: Station index not found, using fallback method")
                    self.currentlyPlayingStation = lastStation
                    if let url = URL(string: lastStation.url) {
                        self.setStationURL(url)
                        self.play()
                        // Manually update lastPlayed for Recent tab
                        self.updateLastPlayed(lastStation)
                    }
                }
            } else {
                print("❌ Auto-play: Station with ID \(lastStationID) not found in stations array")
            }
        } else {
            print("❌ Auto-play: No LastPlayedStationID found in UserDefaults")
        }
        
        if let lastStationURL = self.userDefaults?.url(forKey: "lastStationURL") {
            // Fall back to the old method if LastPlayedStationID is not available
            let storedIndex = self.userDefaults?.integer(forKey: "lastStationIndex") ?? 0
            if storedIndex < self.viewModel?.stations.count ?? 0,
               let stations = self.viewModel?.stations, !stations.isEmpty {
                let station = stations[storedIndex]
                
                print("🌍 Auto-play (fallback): Station from \(station.country), current country picker: \(self.viewModel?.selectedCountry ?? "unknown")")
                print("📍 Auto-play (fallback): Country picker will remain unchanged")
                
                // Use proper playStation method to ensure Recent tab update
                print("🎵 Auto-play (fallback): Playing last station using playStation method")
                self.playStation(at: storedIndex, from: stations)
            } else {
                // Ultimate fallback - manual setup
                self.setStationURL(lastStationURL)
                self.currentStationIndex = storedIndex
                self.play()
            }
        }
    }
    
    private func restoreLastPlayedStationUIOnly() {
        // Restore UI state without auto-playing
        if let lastStationID = self.userDefaults?.string(forKey: "LastPlayedStationID") {
            print("🔍 Restore UI: Found LastPlayedStationID: \(lastStationID)")
            
            if let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }),
               let index = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                print("✅ Restore UI: Found matching station: \(lastStation.name)")
                
                // Set up the UI state without playing
                self.currentStationIndex = index
                self.currentlyPlayingStation = lastStation
                
                // Set up the player URL so play button will work
                if let url = URL(string: lastStation.url) {
                    self.setStationURL(url)
                    print("🔄 Restore UI: Set station URL for \(lastStation.name)")
                }
            } else {
                print("❌ Restore UI: Station with ID \(lastStationID) not found in stations array")
            }
        }
    }
    
    func resetAlarmState() {
        isHandlingAlarm = false
    }
    
    func restoreStateAfterStationsLoaded() {
        print("🔄 Restoring radio player state after stations loaded")
        
        if autoPlayLastStation {
            restoreLastPlayedStation()
        } else {
            restoreLastPlayedStationUIOnly()
        }
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
    
    private func configureAudioSession() {
        // Audio session is now managed centrally by PlaybackManager
        // This method is kept for backward compatibility but delegates to PlaybackManager
        PlaybackManager.shared.activateAudioSessionForPlayer(.radio)
        print("✅ RadioPlayer: Audio session management delegated to PlaybackManager")
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
            // Interruption ended - let PlaybackManager handle audio session reactivation
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && PlaybackManager.shared.activePlayer == .radio {
                // Resume playback if it should resume and radio is the active player
                player?.play()
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
    
    func setStationURL(_ url: URL) {
        // Stop any existing player and clear status observer
        player?.pause()
        statusCancellable?.cancel()
        
        // Create new player item and player
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Add metadata output immediately
        addMetadataOutput()
        
        // Observe player status
        statusCancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                DispatchQueue.main.async {
                    switch status {
                    case .playing:
                        self?.isPlaying = true
                        self?.isBuffering = false
                        self?.updateNowPlayingInfo()
                        
                        // Enhanced metadata fetching when starting to play
                        if let metadata = self?.metadata, !metadata.isEmpty {
                            // If we have metadata, fetch iTunes artwork
                            self?.fetchITunesAlbumArt(for: metadata)
                        } else {
                            // If no metadata, proactively check for current metadata
                            // This is especially useful when resuming from pause
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self?.checkForCurrentMetadata()
                            }
                        }
                        
                    case .waitingToPlayAtSpecifiedRate:
                        self?.isBuffering = true
                    case .paused:
                        self?.isPlaying = false
                        self?.isBuffering = false
                    @unknown default:
                        break
                    }
                }
            }
        
        // Set up periodic time observer for metadata updates
        setupPeriodicTimeObserver()
        
        adjustForNetworkConditions()
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
        
        // Remove any existing metadata outputs
        for output in currentItem.outputs {
            if output is AVPlayerItemMetadataOutput {
                currentItem.remove(output)
            }
        }
        
        // Create new metadata output
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        currentItem.add(metadataOutput)
        
        // Also observe timed metadata for immediate response
        currentItem.addObserver(self, forKeyPath: "timedMetadata", options: [.new], context: nil)
        
        print("Metadata observation configured for player item")
    }
    
    func playPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            // Use our main pause() method to ensure metadata and artwork clearing
            pause()
        } else {
            // Use our main play() method to ensure proper startup
            play()
        }
        // Note: updateNowPlayingInfo() and updateWidget() are called within pause() and play()
    }
    
    func play() {
        stopPodcastPlayback()
        
        // Set radio as the active player FIRST - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.radio)
        print("📻 Play: Set radio as active player")
        
        // Ensure we have a player
        guard let player = player else { 
            print("❌ Play: No player available")
            return 
        }
        
        // Ensure the player is properly set up with the current station URL
        if player.currentItem?.asset as? AVURLAsset == nil,
           let lastStationURL = userDefaults?.url(forKey: "lastStationURL") {
            setStationURL(lastStationURL)
            print("🔄 Play: Restored last station URL")
        }
        
        // Start playback
        player.play()
        isPlaying = true
        resetRetryCount()
        
        print("▶️ Play: Player started, isPlaying: \(isPlaying)")
        
        // Update Now Playing immediately since audio session is already activated
        updateNowPlayingInfo()
        
        // Trigger immediate metadata checking when resuming from pause
        // This ensures fresh metadata and iTunes artwork are fetched
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkForCurrentMetadata()
        }
        
        // Add verification after a brief delay to ensure everything is set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyNowPlayingSetup()
        }
        
        updateWidget()
        scheduleAppRefresh()
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
            
            // Clear all song metadata and iTunes artwork when pausing
            // This immediately removes song info while keeping the station active
            metadata = nil
            iTunesAlbumArt = nil
            albumArt = nil
            songTitle = ""
            artistName = ""
            lastMetadataSearched = ""
            
            // Cancel any pending iTunes searches when paused
            artworkSearchTimer?.invalidate()
            
            // Note: We keep currentlyPlayingStation and currentStationIndex intact
            // This allows the user to resume playing the same station easily
            
            updateNowPlayingInfo()
            updateWidget()
            
            print("⏸️ Radio paused - song metadata and iTunes artwork cleared, station remains active")
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
           
           // Clear all song metadata and iTunes artwork completely
           metadata = nil
           iTunesAlbumArt = nil
           albumArt = nil
           songTitle = ""
           artistName = ""
           lastMetadataSearched = ""
           
           // Cancel any pending iTunes searches
           artworkSearchTimer?.invalidate()
           
           // Clear the current station to fully reset player state
           currentlyPlayingStation = nil
           
           // Update all UI elements - this will now show default app info with no station artwork
           updateNowPlayingInfo()
           updateWidget()
           
           print("🛑 Radio player stopped - all metadata and iTunes artwork cleared")
       }
    
    func playStation(at index: Int, from stations: [RadioStation]) {
        // Ensure PlaybackManager knows radio is the active player
        PlaybackManager.shared.setActivePlayer(.radio)
        
        guard index >= 0 && index < stations.count else {
            print("Invalid station index: \(index)")
            return
        }
        
        let station = stations[index]
        print("Playing station: \(station.name) at index \(index)")
        
        // Set the current station index and station immediately
        currentStationIndex = index
        currentlyPlayingStation = station
        
        // Clear all metadata and iTunes artwork when switching stations
        // This ensures old song artwork doesn't carry over to the new station
        metadata = nil
        iTunesAlbumArt = nil
        albumArt = nil
        songTitle = ""
        artistName = ""
        lastMetadataSearched = ""
        artworkSearchTimer?.invalidate()
        
        guard let url = URL(string: station.url) else {
            print("Invalid URL for station: \(station.name)")
            return
        }
        
        setStationURL(url)
        
        // Always start playing when a station is selected
        play()
        
        // If we already have metadata for this station, fetch iTunes artwork immediately
        if let currentMetadata = metadata, !currentMetadata.isEmpty {
            fetchITunesAlbumArt(for: currentMetadata)
        }
    }
    
    func playStationForAlarm(station: RadioStation) {
        print("Playing station for alarm: \(station.name)")
        guard let url = URL(string: station.url) else {
            print("Invalid URL for station: \(station.name)")
            return
        }

        // Clear all metadata and iTunes artwork when playing alarm station
        metadata = nil
        iTunesAlbumArt = nil
        albumArt = nil
        songTitle = ""
        artistName = ""
        lastMetadataSearched = ""
        artworkSearchTimer?.invalidate()
        
        setStationURL(url)
        play()
        alarmStation = station
        
        // Update UI elements
        updateNowPlayingInfo()
        updateWidget()
    }
    
    func stopCurrentStation() {
        player?.pause()
        player = nil
        isPlaying = false
        
        // Clear all song metadata and iTunes artwork completely
        metadata = nil
        iTunesAlbumArt = nil
        albumArt = nil
        songTitle = ""
        artistName = ""
        lastMetadataSearched = ""
        
        // Cancel any pending iTunes searches
        artworkSearchTimer?.invalidate()
        
        // Clear the current station reference
        currentlyPlayingStation = nil
        
        // Update all UI elements - will show default station artwork only (no song info)
        updateNowPlayingInfo()
        updateWidget()
        
        print("⏹️ Current station stopped - all song metadata and iTunes artwork cleared, showing station artwork only")
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
            // Use shared UserDefaults consistently for CarPlay compatibility
            userDefaults?.set(currentStation.id, forKey: "LastPlayedStationID")
            if let index = viewModel?.stations.firstIndex(where: { $0.id == currentStation.id }) {
                userDefaults?.set(index, forKey: "lastStationIndex")
            }
            print("💾 Saved last played station: \(currentStation.name) (ID: \(currentStation.id))")
        }
    }

    private func loadLastPlayedStation() {
        // Use shared UserDefaults consistently for CarPlay compatibility
        if let lastStationID = userDefaults?.string(forKey: "LastPlayedStationID"),
           let lastStation = viewModel?.stations.first(where: { $0.id == lastStationID }) {
            currentlyPlayingStation = lastStation
            if let url = URL(string: lastStation.url) {
                setStationURL(url)
                play()
            }
            print("📻 Loaded last played station: \(lastStation.name) (ID: \(lastStationID))")
        }
    }
    
    func updateNowPlayingInfo() {
        // Audio session is managed centrally by PlaybackManager
        // Check if we're the active player, but allow override if we're actually playing
        if PlaybackManager.shared.activePlayer != .radio {
            // If radio is actually playing but not set as active player, force set it
            if isPlaying && player?.timeControlStatus == .playing {
                print("⚠️ Now Playing: Radio is playing but not active player - forcing active state")
                PlaybackManager.shared.activePlayer = .radio
            } else {
                print("❌ Now Playing: Radio is not the active player and not playing")
                return
            }
        }
        
        guard let viewModel = viewModel else { 
            print("❌ Now Playing: No viewModel available")
            return 
        }
        
        var nowPlayingInfo = [String: Any]()
        
        // Determine current station
        let currentStation: RadioStation?
        if isHandlingAlarm {
            currentStation = alarmStation
            print("🎵 Now Playing: Using alarm station")
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < viewModel.stations.count {
            currentStation = viewModel.stations[currentStationIndex]
            print("🎵 Now Playing: Using station at index \(currentStationIndex)")
        } else {
            currentStation = nil
            print("❌ Now Playing: No current station available")
        }
        
        // Set basic metadata
        if let station = currentStation {
            let stationName = station.name
            let trackTitle = songTitle.isEmpty ? stationName : songTitle
            let artistInfo = artistName.isEmpty ? (metadata ?? stationName) : artistName
            
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistInfo
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = stationName
            
            print("🎵 Now Playing Info - Title: '\(trackTitle)', Artist: '\(artistInfo)', Station: '\(stationName)'")
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "StreamRadios"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "No Station Playing"
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "StreamRadios"
            print("⚠️ Now Playing: Using default info as no station is available")
        }
        
        // Set stream properties
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        // Add artwork if available (enhanced priority order)
        var artworkSet = false
        
        // When paused, skip iTunes artwork and show only station icon
        if !isPlaying {
            // When paused, only show station icon (no iTunes artwork)
            if let station = currentStation,
               let iconData = station.iconData,
               let imageData = Data(base64Encoded: iconData),
               let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("🎨 Now Playing: Using station icon only (paused state)")
            }
        } else {
            // When playing, use full priority system
            // PRIORITY 1: Current track iTunes artwork (highest priority)
            if let iTunesArt = iTunesAlbumArt {
                let artwork = MPMediaItemArtwork(boundsSize: iTunesArt.size) { size in
                    return iTunesArt
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("🎨 Now Playing: Using live iTunes artwork")
            }
            // PRIORITY 2: Current track artwork from metadata
            else if let currentTrackArtwork = currentTrackArtwork {
                let artwork = MPMediaItemArtwork(boundsSize: currentTrackArtwork.size) { size in
                    return currentTrackArtwork
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("🎨 Now Playing: Using current track artwork")
            }
            // PRIORITY 3: Station's saved iTunes artwork (from previous tracks)
            else if let station = currentStation,
                      let iTunesData = station.iTunesArtworkData,
                      !iTunesData.isEmpty,
                      let imageData = Data(base64Encoded: iTunesData),
                      let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("🎨 Now Playing: Using station's saved iTunes artwork")
            }
            // PRIORITY 4: Station icon (fallback)
            else if let station = currentStation,
                      let iconData = station.iconData,
                      let imageData = Data(base64Encoded: iconData),
                      let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("🎨 Now Playing: Using station icon artwork")
            }
        }
        
        if !artworkSet {
            print("⚠️ Now Playing: No artwork available")
        }
        
        // Set the now playing info
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
        
        print("✅ Now Playing: Successfully updated info center with \(nowPlayingInfo.count) items")
        print("🎵 Now Playing State - isPlaying: \(isPlaying), playback rate: \(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0.0)")
        
        // CRITICAL: Ensure remote command center is set up after updating Now Playing info
        // This is especially important after app force close scenarios
        setupRemoteCommandCenter()
    }
    
    // Force update Now Playing info regardless of active player state (for CarPlay restoration)
    func forceUpdateNowPlayingInfo() {
        print("🚗 Force updating Now Playing info for CarPlay restoration")
        
        // Temporarily override the active player check
        let originalActivePlayer = PlaybackManager.shared.activePlayer
        PlaybackManager.shared.activePlayer = .radio
        
        // Update Now Playing info
        updateNowPlayingInfo()
        
        // Restore original active player if it was different (shouldn't be, but safety)
        if originalActivePlayer != .radio {
            PlaybackManager.shared.activePlayer = originalActivePlayer
        }
    }
    
    func updateWidget() {
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
        
        // Clear any existing targets first
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        
        // Enable and configure play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                self.play()
                print("🎮 Remote Command: Play executed")
                return .success
            }
            return .commandFailed
        }
        
        // Enable and configure pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                self.pause()
                print("🎮 Remote Command: Pause executed")
                return .success
            }
            return .commandFailed
        }
        
        // Enable and configure next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                if let viewModel = self.viewModel {
                    self.nextStation(from: viewModel.stations)
                    print("🎮 Remote Command: Next station executed")
                    return .success
                }
            }
            return .commandFailed
        }
        
        // Enable and configure previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                if let viewModel = self.viewModel {
                    self.previousStation(from: viewModel.stations)
                    print("🎮 Remote Command: Previous station executed")
                    return .success
                }
            }
            return .commandFailed
        }
        
        // CRITICAL: Enable toggle play/pause command for Now Playing display
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                if self.isPlaying {
                    self.pause()
                    print("🎮 Remote Command: Toggle - Paused")
                } else {
                    self.play()
                    print("🎮 Remote Command: Toggle - Playing")
                }
                return .success
            }
            return .commandFailed
        }
        
        // Disable commands that don't make sense for radio
        commandCenter.stopCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        
        print("✅ Remote Command Center configured for Now Playing")
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
    
    var lastMetadataSearched: String = ""
    private var lastArtworkFetched: UIImage?
    private var artworkSearchTimer: Timer?
    private var artworkCache: [String: UIImage?] = [:]
    
    // Artwork persistence tracking
    private var currentTrackArtwork: UIImage?
    private var currentTrackKey: String?
    private var previousStationID: String?
    
    private func clearPreviousStationArtwork(previousID: String) {
        guard let viewModel = viewModel else { return }
        
        // Find the previous station and clear its iTunes artwork data
        if let previousStationIndex = viewModel.stations.firstIndex(where: { $0.id == previousID }) {
            var previousStation = viewModel.stations[previousStationIndex]
            previousStation.iTunesArtworkData = nil
            viewModel.stations[previousStationIndex] = previousStation
            viewModel.saveStationsToCoreData()
            print("Cleared artwork from previous station: \(previousStation.name)")
        }
    }
    
    private func generateTrackKey(from metadata: String) -> String {
        // Create a unique key for the track by extracting core artist and track info
        let parsed = parseComplexMetadata(metadata)
        let artist = parsed.artist?.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        let track = parsed.track?.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        
        // Combine artist and track to create unique key
        return "\(artist)|\(track)".replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    private func normalizeTrackName(_ trackName: String) -> String {
        return trackName
            .lowercased()
            .replacingOccurrences(of: "^the\\s+", with: "", options: .regularExpression) // Remove leading "the"
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) // Remove all spaces
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression) // Keep only alphanumeric
    }
    private var cacheOrder: [String] = []
    private let maxCacheSize = 50
    
    func fetchITunesAlbumArt(for metadata: String) {
        guard !metadata.isEmpty && metadata != "No song or album title available" else {
            DispatchQueue.main.async { [weak self] in
                self?.iTunesAlbumArt = nil
            }
            return
        }
        
        // Parse metadata to get core song information (ignore timestamps)
        let parsedData = parseComplexMetadata(metadata)
        
        // Create a normalized cache key based on artist and track (ignore timestamps and other varying data)
        var cacheKey = ""
        if let artist = parsedData.artist, let track = parsedData.track {
            cacheKey = "\(artist.lowercased()) - \(track.lowercased())"
        } else {
            // Fallback: use first two components for tilde-separated metadata
            let components = metadata.components(separatedBy: "~")
            if components.count >= 2 {
                cacheKey = "\(components[0].lowercased()) - \(components[1].lowercased())"
            } else {
                cacheKey = metadata.lowercased()
            }
        }
        
        // Prevent duplicate searches for the same song (ignore timestamp differences)
        if cacheKey == lastMetadataSearched {
            return
        }
        
        // Check cache first using normalized key
        if let cachedImage = artworkCache[cacheKey] {
            // Move to end of cache order (most recently used)
            if let index = cacheOrder.firstIndex(of: cacheKey) {
                cacheOrder.remove(at: index)
            }
            cacheOrder.append(cacheKey)
            
            DispatchQueue.main.async { [weak self] in
                self?.iTunesAlbumArt = cachedImage
                self?.updateNowPlayingInfo()
                self?.updateWidget()
                print("iTunes album art loaded from cache for: \(cacheKey)")
            }
            return
        }
        
        // Cancel any existing timer to debounce rapid metadata changes
        artworkSearchTimer?.invalidate()
        
        // Debounce the search to prevent rapid successive API calls
        artworkSearchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            self.lastMetadataSearched = cacheKey
            
            print("Fetching iTunes album art for song: \(cacheKey)")
            
            // Search iTunes for album artwork
            self.searchITunesForArtwork(metadata: metadata) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    // Cache the result using normalized key (even if nil)
                    self.cacheImage(image, for: cacheKey)
                    
                    // Only update if we're still on the same song
                    if cacheKey == self.lastMetadataSearched {
                        self.iTunesAlbumArt = image
                        
                        // Save iTunes artwork to current station if image was found
                        if let image = image {
                            self.saveITunesArtworkToCurrentStation(image)
                        }
                        
                        self.updateNowPlayingInfo()
                        self.updateWidget()
                        print("iTunes album art fetched successfully: \(image != nil) for song: \(cacheKey)")
                    }
                }
            }
        }
    }
    
    func searchITunesForArtwork(metadata: String, completion: @escaping (UIImage?) -> Void) {
        let parsedData = parseComplexMetadata(metadata)
        
        // Try multiple search strategies
        let searchQueries = buildSearchQueries(parsedData: parsedData, originalMetadata: metadata)
        
        // Use enhanced network session for CarPlay if connected
        if CarPlayManager.shared.isCarPlayConnected {
            searchWithQueriesUsingCarPlaySession(searchQueries, completion: completion)
        } else {
            searchWithQueries(searchQueries, completion: completion)
        }
    }
    
    private func parseComplexMetadata(_ metadata: String) -> (artist: String?, track: String?, album: String?) {
        var artist: String?
        var track: String?
        var album: String?
        
        // Preprocessing: Remove common radio prefixes and noise
        let cleanedMetadata = metadata
            .replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "NOW PLAYING:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CURRENT:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "ON AIR:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "LIVE:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Complex radio metadata formats with detailed parsing
        
        // Format 1: Tilde-separated with timestamps and IDs
        // "Quanti Anni Hai~Vasco Rossi~~1998~~260~2025-06-16T13:51:31~2025-06-16T13:51:34~United Music Vasco Rossi~3.19~dbeca8a2-f14e-43e8-9081-95f3c9810890"
        if cleanedMetadata.contains("~") {
            let components = cleanedMetadata.components(separatedBy: "~")
            if components.count >= 2 {
                track = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                artist = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Look for album/year in remaining components (skip timestamps and IDs)
                for (_, component) in components[2...].enumerated() {
                    let cleaned = component.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && 
                       !cleaned.contains("-") && 
                       !cleaned.contains(":") && 
                       !cleaned.contains("2025") && 
                       !cleaned.contains("2024") &&
                       !cleaned.contains("United Music") &&
                       !cleaned.matches("^[0-9]+$") && // Skip pure numbers
                       !cleaned.matches(".*[0-9]{4}-[0-9]{2}-[0-9]{2}.*") && // Skip dates
                       !cleaned.matches(".*[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}.*") && // Skip UUIDs
                       cleaned.count > 2 && cleaned.count < 50 {
                        album = cleaned
                        break
                    }
                }
            }
        }
        
        // Format 2: Standard artist-title with various separators (prioritize dash separation)
        // "MODA' - COME UN PITTORE", "Artist: Track", "Artist | Track"
        else if cleanedMetadata.containsAnyOf([" - ", " – ", " — ", " | ", " / ", ": ", " by "]) {
            // Prioritize dash separators since they create the best phrase groups
            let dashSeparators = [" - ", " – ", " — "]
            let otherSeparators = [" | ", " / ", ": ", " by "]
            let allSeparators = dashSeparators + otherSeparators
            
            for separator in allSeparators {
                if cleanedMetadata.contains(separator) {
                    let components = cleanedMetadata.components(separatedBy: separator)
                    if components.count >= 2 {
                        // Extract the first two main components as phrase groups
                        let artistPart = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let trackPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Clean and preserve phrase groups
                        artist = cleanAndPreservePhraseGroup(artistPart)
                        
                        // Handle parenthetical content while preserving main phrase group
                        if trackPart.contains("(") && trackPart.contains(")") {
                            // Extract year if present: "Spaccacuore (2007)"
                            if let yearRange = trackPart.range(of: "\\([0-9]{4}\\)", options: .regularExpression) {
                                track = cleanAndPreservePhraseGroup(String(trackPart[..<yearRange.lowerBound]))
                                let yearMatch = String(trackPart[yearRange])
                                album = yearMatch.replacingOccurrences(of: "[()]", with: "", options: .regularExpression)
                            }
                            // Remove features and remixes while preserving main phrase: "Song (feat. Artist)", "Song (Remix)"
                            else if trackPart.matches(".*\\((feat\\.|featuring|remix|radio edit|extended|acoustic).*\\).*", options: .caseInsensitive) {
                                track = cleanAndPreservePhraseGroup(
                                    trackPart.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
                                )
                            } else {
                                track = cleanAndPreservePhraseGroup(trackPart)
                            }
                        } else {
                            track = cleanAndPreservePhraseGroup(trackPart)
                        }
                        break
                    }
                }
            }
        }
        
        // Format 3: Track "by" Artist (reverse order)
        // "Beautiful Song by Amazing Artist"
        else if cleanedMetadata.lowercased().contains(" by ") {
            let components = cleanedMetadata.components(separatedBy: CharacterSet(charactersIn: " by "))
            if components.count >= 2 {
                track = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                artist = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Format 4: Quoted tracks or artists
        // "\"Track Name\" - Artist" or "Artist - \"Track Name\""
        else if cleanedMetadata.contains("\"") {
            let quotedParts = cleanedMetadata.extractQuotedStrings()
            if quotedParts.count > 0 {
                let nonQuotedParts = cleanedMetadata.removeQuotedStrings().components(separatedBy: " - ")
                if nonQuotedParts.count >= 1 {
                    track = quotedParts[0]
                    artist = nonQuotedParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Format 5: Comma-separated (some international formats)
        // "Artist, Track" or "Track, Artist"
        else if cleanedMetadata.contains(", ") {
            let components = cleanedMetadata.components(separatedBy: ", ")
            if components.count >= 2 {
                // Try both orders and determine which makes more sense
                let first = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let second = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // If first part is short and second is longer, likely "Artist, Long Track Name"
                if first.count < Int(Double(second.count) * 0.7) {
                    artist = first
                    track = second
                } else {
                    track = first
                    artist = second
                }
            }
        }
        
        // Format 6: Single string without separators (try to extract meaningful parts)
        else {
            // Look for common patterns in single strings
            if cleanedMetadata.count > 10 {
                // Try to find artist names in parentheses at the end
                if let artistRange = cleanedMetadata.range(of: "\\([^)]+\\)$", options: .regularExpression) {
                    artist = String(cleanedMetadata[artistRange])
                        .replacingOccurrences(of: "[()]", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    track = String(cleanedMetadata[..<artistRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // Use the whole string as track title for single-word searches
                    track = cleanedMetadata
                }
            }
        }
        
        // Clean up extracted values
        artist = cleanArtistName(artist)
        track = cleanTrackName(track)
        album = cleanAlbumName(album)
        
        return (artist: artist, track: track, album: album)
    }
    
    private func cleanArtistName(_ artist: String?) -> String? {
        guard var cleaned = artist else { return nil }
        
        cleaned = cleaned
            .replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "Now Playing:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Current Song:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Playing:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "feat\\.", with: "", options: [.caseInsensitive, .regularExpression])
            .replacingOccurrences(of: "featuring", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "&", with: "and")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
    
    private func cleanTrackName(_ track: String?) -> String? {
        guard var cleaned = track else { return nil }
        
        cleaned = cleaned
            .replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression) // Remove [Radio Edit], [Clean], etc.
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) // Normalize whitespace
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
    
    private func cleanAlbumName(_ album: String?) -> String? {
        guard var cleaned = album else { return nil }
        
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
    
    private func cleanAndPreservePhraseGroup(_ text: String) -> String {
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) // Normalize whitespace but preserve phrases
    }
    
    private func cacheImage(_ image: UIImage?, for metadata: String) {
        // Add to cache
        artworkCache[metadata] = image
        
        // Update cache order
        if let index = cacheOrder.firstIndex(of: metadata) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.append(metadata)
        
        // Maintain cache size
        while cacheOrder.count > maxCacheSize {
            let oldestKey = cacheOrder.removeFirst()
            artworkCache.removeValue(forKey: oldestKey)
        }
    }
    
    func saveITunesArtworkToCurrentStation(_ image: UIImage) {
        guard let currentIndex = currentStationIndex,
              let viewModel = viewModel,
              currentIndex < viewModel.stations.count else {
            return
        }
        
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            return
        }
        let base64String = imageData.base64EncodedString()
        
        // Store artwork for current track persistence
        currentTrackArtwork = image
        
        // Update the station
        var updatedStation = viewModel.stations[currentIndex]
        updatedStation.iTunesArtworkData = base64String
        viewModel.stations[currentIndex] = updatedStation
        
        // Save to Core Data
        viewModel.saveStationsToCoreData()
        
        print("iTunes artwork saved to station: \(updatedStation.name)")
        
        // CRITICAL: Cache artwork for CarPlay independent operation
        cacheITunesArtworkForCarPlay(image: image, station: updatedStation)
        
        // CRITICAL: Immediately update Now Playing with new artwork
        updateNowPlayingInfo()
        
        // CRITICAL: Notify CarPlay of station data changes for real-time artwork update
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("StationArtworkUpdated"), 
                object: nil, 
                userInfo: ["stationId": updatedStation.id, "hasArtwork": true]
            )
            
            // ENHANCED: Specific iTunes artwork update notification for immediate CarPlay response
            NotificationCenter.default.post(
                name: NSNotification.Name("iTunesArtworkUpdated"),
                object: nil,
                userInfo: ["stationId": updatedStation.id, "artworkUpdated": true]
            )
            
            // ENHANCED: Also trigger CarPlay playback change to force artwork refresh
            NotificationCenter.default.post(
                name: NSNotification.Name("CarPlayPlaybackChanged"),
                object: nil,
                userInfo: ["artworkUpdated": true, "stationId": updatedStation.id]
            )
        }
        
        // Also update widget with new artwork
        updateWidget()
        
        print("✅ iTunes artwork updated in real-time - Now Playing, CarPlay cache, and Widget refreshed")
    }
    
    /// Caches iTunes artwork for CarPlay independent operation
    private func cacheITunesArtworkForCarPlay(image: UIImage, station: RadioStation) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to compress iTunes artwork for CarPlay cache")
            return
        }
        
        let userDefaults = UserDefaults.standard
        
        // Cache by station name for easy lookup
        let stationKey = station.name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "", options: .regularExpression)
        
        userDefaults.set(imageData, forKey: "CarPlayArtwork_\(stationKey)")
        
        // Also cache by current metadata if available
        if let currentMetadata = self.metadata, !currentMetadata.isEmpty {
            let metadataComponents = currentMetadata.components(separatedBy: " - ")
            if metadataComponents.count >= 2 {
                let artist = metadataComponents[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = metadataComponents[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                let metadataKey = "\(artist.lowercased())_\(title.lowercased())"
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "", options: .regularExpression)
                
                userDefaults.set(imageData, forKey: "iTunesArtwork_\(metadataKey)")
                
                print("🚗 Cached iTunes artwork for CarPlay - Station: \(stationKey), Metadata: \(metadataKey)")
            }
        }
        
        userDefaults.synchronize()
        print("🚗 iTunes artwork cached for CarPlay independent operation")
    }
    
    private func buildSearchQueries(parsedData: (artist: String?, track: String?, album: String?), originalMetadata: String) -> [String] {
        var queries: [String] = []
        
        // Check if this is regional/local content that might need special handling
        let originalGroups = extractPhraseGroups(from: originalMetadata)
        let isRegionalContent = detectRegionalContent(query: originalMetadata, queryGroups: originalGroups)
        
        // Enhanced search strategy: PRIORITY 1 - Two-group matches, PRIORITY 2 - Single groups
        
        // PRIORITY 1: Two-group combination searches (highest priority)
        var twoGroupQueries: [String] = []
        
        if let artist = parsedData.artist, let track = parsedData.track {
            let artistGroups = extractPhraseGroups(from: artist)
            let trackGroups = extractPhraseGroups(from: track)
            
            // PRIORITY A: Track name focused queries (highest priority)
            twoGroupQueries.append("\"\(track)\" \(artist)") // Track first with quotes
            twoGroupQueries.append("\(track) \(artist)") // Track first without quotes
            twoGroupQueries.append("\(artist) \(track)") // Traditional artist-track
            
            // PRIORITY B: Cross-group combinations for enhanced matching
            for artistGroup in artistGroups.prefix(2) {
                for trackGroup in trackGroups.prefix(2) {
                    twoGroupQueries.append("\"\(trackGroup)\" \(artistGroup)") // Track-focused
                    twoGroupQueries.append("\(artistGroup) \(trackGroup)") // Artist-focused
                }
            }
        }
        
        // Additional two-group combinations from original metadata with track name detection
        if originalGroups.count >= 2 {
            // Smart track detection: last group is often the track name
            let potentialTrack = originalGroups.last!
            let potentialArtist = originalGroups.first!
            
            // Prioritize combinations with potential track name
            twoGroupQueries.append("\"\(potentialTrack)\" \(potentialArtist)")
            twoGroupQueries.append("\(potentialArtist) \(potentialTrack)")
            
            // Additional combinations
            let twoGroupCombinations = generateGroupCombinations(groups: originalGroups, maxGroups: 2)
            twoGroupQueries.append(contentsOf: twoGroupCombinations.prefix(2))
        }
        
        // Add all two-group queries with highest priority
        queries.append(contentsOf: twoGroupQueries.prefix(5))
        
        // PRIORITY 2: Single-group fallback searches (only if two-group matches might fail)
        var singleGroupQueries: [String] = []
        
        // For regional content, focus on the main artist/group names only
        if isRegionalContent {
            // Extract main artist names, avoiding very long collaborative titles
            if let artist = parsedData.artist {
                let artistGroups = extractPhraseGroups(from: artist)
                for group in artistGroups {
                    // Focus on shorter, more specific artist names for regional content
                    if group.count > 3 && group.count < 15 && !group.contains("(") {
                        singleGroupQueries.append(group)
                    }
                }
            }
            
            // For regional content, also try just the first word/name as artist queries
            if let artist = parsedData.artist {
                let words = artist.components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .filter { !$0.isEmpty && $0.count > 3 }
                for word in words.prefix(2) {
                    singleGroupQueries.append(word)
                }
            }
        } else {
            // Standard single group handling for non-regional content
            
            // Single artist groups
            if let artist = parsedData.artist {
                let artistGroups = extractPhraseGroups(from: artist)
                for group in artistGroups.prefix(2) {
                    if group.count > 3 {
                        singleGroupQueries.append(group)
                    }
                }
                singleGroupQueries.append(artist) // Full artist as single group
            }
            
            // Single track groups
            if let track = parsedData.track {
                let trackGroups = extractPhraseGroups(from: track)
                for group in trackGroups.prefix(2) {
                    if group.count > 3 {
                        singleGroupQueries.append(group)
                    }
                }
                singleGroupQueries.append(track) // Full track as single group
            }
            
            // Album-based single groups
            if let album = parsedData.album, album.count > 3 {
                singleGroupQueries.append(album)
            }
        }
        
        // Add single-group queries as fallback
        queries.append(contentsOf: singleGroupQueries.prefix(3))
        
        // Smart fallback searches: Extract meaningful phrase groups from original metadata
        if !isRegionalContent {
            let smartFallback = generateSmartGroupFallbackQueries(from: originalMetadata)
            queries.append(contentsOf: smartFallback.prefix(2))
        }
        
        // Remove duplicates and filter out very short queries
        queries = Array(Set(queries))
            .filter { $0.count > 2 && !$0.matches("^[0-9]+$") }
        
        // Sort by priority: two-group queries first, then single-group queries
        queries = prioritizeQueriesByGroupCount(queries)
        
        // For regional content, limit queries more aggressively to avoid poor matches
        let queryLimit = isRegionalContent ? 5 : 8
        return Array(queries.prefix(queryLimit))
    }
    
    private func extractPhraseGroups(from text: String) -> [String] {
        // Split text by enhanced separators but preserve phrase groups
        var groups: [String] = []
        
        // Enhanced separators based on user specification: -, ~, ~~, --, _
        let primarySeparators = [" - ", " -- ", "~", "~~", "_"]
        let secondarySeparators = [" | ", " / ", " : ", " by ", " – ", " — "]
        let allSeparators = primarySeparators + secondarySeparators
        
        var foundSeparator = false
        
        // Try separators in priority order
        for separator in allSeparators {
            if text.contains(separator) {
                let components = text.components(separatedBy: separator)
                if components.count > 1 {
                    // Multiple groups found
                    for component in components {
                        let cleaned = cleanPhraseGroup(component)
                        if !cleaned.isEmpty {
                            groups.append(cleaned)
                        }
                    }
                    foundSeparator = true
                    break
                }
            }
        }
        
        if !foundSeparator {
            // Single phrase, break into meaningful chunks by parentheses or length
            groups = extractMeaningfulChunks(from: text)
        }
        
        // Filter out stop-word-only groups and very short groups
        return groups.filter { group in
            let words = group.components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            
            return group.count > 2 && 
                   !group.matches("^[0-9]+$") && 
                   !isStopWordOnlyGroup(group) &&
                   words.count <= 6 // Avoid overly long groups
        }
    }
    
    private func cleanPhraseGroup(_ group: String) -> String {
        return group
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^(feat\\.|featuring|ft\\.|with)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+(feat\\.|featuring|ft\\.).*$", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression) // Remove parenthetical content
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression) // Remove bracketed content
            .replacingOccurrences(of: "\\r\\n|\\r|\\n", with: " ", options: .regularExpression) // Remove line breaks
            .replacingOccurrences(of: "[(){}\\[\\]]", with: "", options: .regularExpression) // Remove special chars
            .replacingOccurrences(of: "\\s*-\\s*$", with: "", options: .regularExpression) // Remove trailing dashes
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    private func extractMeaningfulChunks(from text: String) -> [String] {
        var chunks: [String] = []
        let cleaned = cleanPhraseGroup(text)
        
        if cleaned.count > 20 {
            // Long text, try to break into meaningful chunks
            let words = cleaned.components(separatedBy: CharacterSet.whitespacesAndNewlines)
            
            if words.count >= 4 {
                // Create 2-3 word chunks
                for i in 0..<words.count-1 {
                    let twoWordChunk = "\(words[i]) \(words[i+1])"
                    if !isStopWordOnlyGroup(twoWordChunk) {
                        chunks.append(twoWordChunk)
                    }
                }
                
                if words.count >= 6 {
                    // Create 3-word chunks for longer phrases
                    for i in 0..<words.count-2 {
                        let threeWordChunk = "\(words[i]) \(words[i+1]) \(words[i+2])"
                        if !isStopWordOnlyGroup(threeWordChunk) {
                            chunks.append(threeWordChunk)
                        }
                    }
                }
            }
        }
        
        if chunks.isEmpty {
            chunks.append(cleaned)
        }
        
        return chunks
    }
    
    private func isStopWordOnlyGroup(_ group: String) -> Bool {
        let stopWords = Set(["the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "feat", "featuring", "ft", "vs", "version", "remix", "edit", "radio", "new", "live", "official"])
        
        let words = group.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        return words.allSatisfy { stopWords.contains($0) }
    }
    
    private func generateGroupCombinations(groups: [String], maxGroups: Int) -> [String] {
        guard groups.count >= maxGroups else { return [] }
        
        var combinations: [String] = []
        
        if maxGroups == 2 && groups.count >= 2 {
            for i in 0..<groups.count-1 {
                for j in i+1..<groups.count {
                    combinations.append("\(groups[i]) \(groups[j])")
                }
            }
            // Also include consecutive pairs
            for i in 0..<groups.count-1 {
                combinations.append("\(groups[i]) \(groups[i+1])")
            }
        } else if maxGroups == 3 && groups.count >= 3 {
            for i in 0..<groups.count-2 {
                for j in i+1..<groups.count-1 {
                    for k in j+1..<groups.count {
                        combinations.append("\(groups[i]) \(groups[j]) \(groups[k])")
                    }
                }
            }
            // Also include consecutive triplets
            for i in 0..<groups.count-2 {
                combinations.append("\(groups[i]) \(groups[i+1]) \(groups[i+2])")
            }
        }
        
        return combinations
    }
    
    private func prioritizeQueriesByGroupCount(_ queries: [String]) -> [String] {
        var twoGroupQueries: [String] = []
        var singleGroupQueries: [String] = []
        
        for query in queries {
            let groups = extractPhraseGroups(from: query)
            if groups.count >= 2 {
                twoGroupQueries.append(query)
            } else {
                singleGroupQueries.append(query)
            }
        }
        
        // Sort each category by length (longer queries tend to be more specific)
        twoGroupQueries.sort { $0.count > $1.count }
        singleGroupQueries.sort { $0.count > $1.count }
        
        // Return two-group queries first, then single-group queries
        return twoGroupQueries + singleGroupQueries
    }
    
    private func generateSmartGroupFallbackQueries(from metadata: String) -> [String] {
        var fallbackQueries: [String] = []
        
        // Clean the metadata
        let cleaned = metadata
            .replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "~.*~.*~.*", with: "", options: .regularExpression) // Remove timestamp patterns
            .replacingOccurrences(of: "Now Playing:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Current Song:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleaned.count > 5 {
            // Extract phrase groups and create meaningful combinations
            let phraseGroups = extractPhraseGroups(from: cleaned)
            
            if phraseGroups.count >= 2 {
                // Best 2-group combination
                let first2Groups = Array(phraseGroups.prefix(2)).joined(separator: " ")
                fallbackQueries.append(first2Groups)
                
                // Individual significant groups
                for group in phraseGroups.prefix(2) {
                    if group.count > 3 {
                        fallbackQueries.append(group)
                    }
                }
                
                // Enhanced fallback: Simplified queries for complex cases
                for group in phraseGroups.prefix(3) {
                    let simplified = group
                        .replacingOccurrences(of: "\\b(19|20)\\d{2}\\b", with: "", options: .regularExpression) // Remove years
                        .replacingOccurrences(of: "\\b(feat|ft|featuring|with|remix|mix|edit|version|vs|popullore|veriu|potpuri|kolazh)\\b.*", with: "", options: [.regularExpression, .caseInsensitive]) // Remove features and common noise
                        .replacingOccurrences(of: "[\\(\\)\\[\\]{}\\-\\_]", with: " ", options: .regularExpression) // Replace special chars with spaces
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) // Normalize spaces
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if simplified.count > 3 && simplified != group && !simplified.isEmpty {
                        fallbackQueries.append(simplified)
                    }
                }
            }
            
            if phraseGroups.count >= 3 {
                // Best 3-group combination
                let first3Groups = Array(phraseGroups.prefix(3)).joined(separator: " ")
                fallbackQueries.append(first3Groups)
            }
            
            // Original cleaned metadata as last resort (if not too long)
            if cleaned.count < 50 && !phraseGroups.isEmpty {
                fallbackQueries.append(cleaned)
            }
        }
        
        return fallbackQueries
    }
    
    private func searchWithQueries(_ queries: [String], completion: @escaping (UIImage?) -> Void) {
        guard !queries.isEmpty else {
            // Check if we should use station artwork as fallback for regional content
            print("iTunes Enhanced AI: No queries available - using graceful fallback")
            completion(nil)
            return
        }
        
        // Check smart cache for successful matches first
        for query in queries.prefix(3) { // Check first 3 queries for cache hits
            let cacheKey = "success_\(query.lowercased())"
            if let cachedImage = artworkCache[cacheKey] {
                print("Smart cache hit for: \(query)")
                DispatchQueue.main.async {
                    completion(cachedImage)
                }
                return
            }
        }
        
        searchWithQuery(queries[0], remainingQueries: Array(queries.dropFirst()), completion: completion)
    }
    
    /// Enhanced iTunes search using CarPlay's active audio session network privileges
    private func searchWithQueriesUsingCarPlaySession(_ queries: [String], completion: @escaping (UIImage?) -> Void) {
        guard !queries.isEmpty else {
            print("🚗 CarPlay iTunes: No queries available - using graceful fallback")
            completion(nil)
            return
        }
        
        print("🚗 CarPlay iTunes: Using enhanced network session for independent operation")
        
        // Check smart cache for successful matches first
        for query in queries.prefix(3) {
            let cacheKey = "success_\(query.lowercased())"
            if let cachedImage = artworkCache[cacheKey] {
                print("🚗 CarPlay iTunes: Smart cache hit for: \(query)")
                DispatchQueue.main.async {
                    completion(cachedImage)
                }
                return
            }
        }
        
        // Create enhanced network session for CarPlay
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0  // Extended timeout for CarPlay
        config.timeoutIntervalForResource = 30.0 // Extended resource timeout
        config.waitsForConnectivity = false      // Don't wait - try immediately
        config.networkServiceType = .responsiveData // High priority networking
        
        let carPlaySession = URLSession(configuration: config)
        
        searchWithQueryUsingCarPlaySession(queries[0], 
                                         remainingQueries: Array(queries.dropFirst()), 
                                         session: carPlaySession, 
                                         completion: completion)
    }
    
    private func searchWithQuery(_ query: String, remainingQueries: [String], completion: @escaping (UIImage?) -> Void) {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&media=music&entity=song&limit=10") else {
            
            // Try next query if available
            if !remainingQueries.isEmpty {
                searchWithQuery(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), completion: completion)
            } else {
                completion(nil)
            }
            return
        }
        
        print("iTunes search query: \(query)")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                
                // Try next query if available
                if !remainingQueries.isEmpty {
                    self?.searchWithQuery(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), completion: completion)
                } else {
                    completion(nil)
                }
                return
            }
            
            // Enhanced result evaluation - find best match based on word similarity
            let bestMatch = self?.findBestMatch(query: query, results: results)
            
            if let bestResult = bestMatch,
               let artworkUrl = bestResult["artworkUrl100"] as? String {
                
                print("iTunes best match found: \(bestResult["trackName"] ?? "Unknown") by \(bestResult["artistName"] ?? "Unknown")")
                
                // Get higher resolution artwork
                let highResArtworkUrl = artworkUrl.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                
                guard let imageUrl = URL(string: highResArtworkUrl) else {
                    completion(nil)
                    return
                }
                
                URLSession.shared.dataTask(with: imageUrl) { imageData, _, _ in
                    guard let imageData = imageData,
                          let image = UIImage(data: imageData) else {
                        // Try next query if available
                        if !remainingQueries.isEmpty {
                            self?.searchWithQuery(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), completion: completion)
                        } else {
                            completion(nil)
                        }
                        return
                    }
                    
                    // Cache successful match for future use
                    let successCacheKey = "success_\(query.lowercased())"
                    self?.artworkCache[successCacheKey] = image
                    
                    completion(image)
                }.resume()
            } else {
                // No good match found, try next query
                if !remainingQueries.isEmpty {
                    self?.searchWithQuery(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), completion: completion)
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }
    
    /// Enhanced CarPlay search method using privileged network session
    private func searchWithQueryUsingCarPlaySession(_ query: String, remainingQueries: [String], session: URLSession, completion: @escaping (UIImage?) -> Void) {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&media=music&entity=song&limit=10") else {
            
            // Try next query if available
            if !remainingQueries.isEmpty {
                searchWithQueryUsingCarPlaySession(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), session: session, completion: completion)
            } else {
                completion(nil)
            }
            return
        }
        
        print("🚗 CarPlay iTunes search query: \(query)")
        
        session.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                print("🚗 CarPlay iTunes: Network error - \(error.localizedDescription)")
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                
                print("🚗 CarPlay iTunes: No results for query - \(query)")
                
                // Try next query if available
                if !remainingQueries.isEmpty {
                    self?.searchWithQueryUsingCarPlaySession(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), session: session, completion: completion)
                } else {
                    completion(nil)
                }
                return
            }
            
            print("🚗 CarPlay iTunes: Found \(results.count) results for query")
            
            // Enhanced result evaluation - find best match based on word similarity
            let bestMatch = self?.findBestMatch(query: query, results: results)
            
            if let bestResult = bestMatch,
               let artworkUrl = bestResult["artworkUrl100"] as? String {
                
                print("🚗 CarPlay iTunes: Best match found - \(bestResult["trackName"] ?? "Unknown") by \(bestResult["artistName"] ?? "Unknown")")
                
                // Get higher resolution artwork
                let highResArtworkUrl = artworkUrl.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                
                guard let imageUrl = URL(string: highResArtworkUrl) else {
                    completion(nil)
                    return
                }
                
                // Use the same enhanced session for artwork download
                session.dataTask(with: imageUrl) { imageData, _, imageError in
                    if let imageError = imageError {
                        print("🚗 CarPlay iTunes: Image download error - \(imageError.localizedDescription)")
                    }
                    
                    guard let imageData = imageData,
                          let image = UIImage(data: imageData) else {
                        // Try next query if available
                        if !remainingQueries.isEmpty {
                            self?.searchWithQueryUsingCarPlaySession(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), session: session, completion: completion)
                        } else {
                            completion(nil)
                        }
                        return
                    }
                    
                    print("🚗 CarPlay iTunes: Artwork downloaded successfully - \(imageData.count) bytes")
                    
                    // Cache successful match for future use
                    let successCacheKey = "success_\(query.lowercased())"
                    self?.artworkCache[successCacheKey] = image
                    
                    completion(image)
                }.resume()
            } else {
                print("🚗 CarPlay iTunes: No suitable match found for query")
                
                // No good match found, try next query
                if !remainingQueries.isEmpty {
                    self?.searchWithQueryUsingCarPlaySession(remainingQueries[0], remainingQueries: Array(remainingQueries.dropFirst()), session: session, completion: completion)
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }
    
    private func findBestMatch(query: String, results: [[String: Any]]) -> [String: Any]? {
        guard !results.isEmpty else { return nil }
        
        let queryGroups = extractPhraseGroups(from: query)
        var bestScore = 0.0
        var bestMatch: [String: Any]?
        var bestAccuracy = 0.0
        
        // Check if this appears to be a regional/local song that might not be in iTunes
        let isRegionalContent = detectRegionalContent(query: query, queryGroups: queryGroups)
        
        // Enhanced AI-based scoring system with smarter thresholds
        for result in results {
            let trackName = result["trackName"] as? String ?? ""
            let artistName = result["artistName"] as? String ?? ""
            let albumName = result["collectionName"] as? String ?? ""
            
            // Fast exact match detection (highest priority)
            let exactMatchScore = calculateExactMatchScore(query: query, 
                                                         trackName: trackName, 
                                                         artistName: artistName)
            
            // Extract phrase groups from iTunes result
            let trackGroups = extractPhraseGroups(from: trackName)
            let artistGroups = extractPhraseGroups(from: artistName)
            let albumGroups = extractPhraseGroups(from: albumName)
            
            // PRIORITY 1: Two-group matching (highest weight)
            let twoGroupScore = calculateEnhancedTwoGroupScore(queryGroups: queryGroups, 
                                                             trackGroups: trackGroups, 
                                                             artistGroups: artistGroups,
                                                             albumGroups: albumGroups)
            
            // PRIORITY 2: Single-group fallback matching (medium weight)
            let singleGroupScore = calculateEnhancedSingleGroupScore(queryGroups: queryGroups,
                                                                   trackGroups: trackGroups,
                                                                   artistGroups: artistGroups,
                                                                   albumGroups: albumGroups)
            
            // Enhanced AI confidence scoring with fuzzy matching
            let (aiScore, confidence) = calculateEnhancedAIScore(query: query,
                                                               trackName: trackName,
                                                               artistName: artistName,
                                                               albumName: albumName,
                                                               queryGroups: queryGroups,
                                                               resultGroups: trackGroups + artistGroups + albumGroups)
            
            // Rebalanced scoring weights for better single-group recognition
            let baseScore = (twoGroupScore * 0.35) + (singleGroupScore * 0.45) + (aiScore * 0.2)
            let totalScore = baseScore + (exactMatchScore * 0.3) // Boost for exact matches
            let accuracy = min(confidence * 100, 100.0)
            
            // Special override for obvious perfect matches
            var finalAccuracy = accuracy
            if exactMatchScore >= 1.0 && accuracy < 60.0 {
                finalAccuracy = max(accuracy, 70.0) // Override low accuracy for perfect matches
                print("  - PERFECT MATCH DETECTED: Accuracy boosted to \(String(format: "%.1f", finalAccuracy))%")
            }
            
            print("iTunes Enhanced AI: \(trackName) by \(artistName)")
            print("  - Exact: \(String(format: "%.2f", exactMatchScore)), Two-group: \(String(format: "%.2f", twoGroupScore))")
            print("  - Single: \(String(format: "%.2f", singleGroupScore)), AI: \(String(format: "%.2f", aiScore))")
            print("  - Total: \(String(format: "%.2f", totalScore)), Accuracy: \(String(format: "%.1f", finalAccuracy))%")
            
            // Enhanced acceptance criteria with regional content awareness
            var acceptanceThreshold = 0.35
            var accuracyThreshold = 60.0
            
            // For regional content, be more strict to avoid false matches
            if isRegionalContent {
                acceptanceThreshold = 0.5 // Higher threshold for regional content
                accuracyThreshold = 75.0 // Much higher accuracy requirement
                print("  - REGIONAL CONTENT DETECTED: Using stricter thresholds")
            }
            
            let isAcceptable = (totalScore >= 0.25 && finalAccuracy >= 85.0) || // Very high accuracy override
                              (totalScore >= 0.3 && finalAccuracy >= 80.0) || // High accuracy standard
                              (totalScore >= acceptanceThreshold && finalAccuracy >= accuracyThreshold) || // Dynamic threshold
                              (exactMatchScore >= 0.9 && finalAccuracy >= 50.0) || // Perfect match override
                              (exactMatchScore >= 0.8 && finalAccuracy >= 55.0) || // High exact match
                              (twoGroupScore >= 0.8 && finalAccuracy >= 60.0) || // Two-group match override
                              (twoGroupScore >= 1.0 && finalAccuracy >= 40.0) || // Perfect two-group override
                              (singleGroupScore >= 0.6 && finalAccuracy >= 90.0 && !isRegionalContent) || // High single match (non-regional only)
                              (singleGroupScore >= 0.5 && finalAccuracy >= 95.0) // Ultra high accuracy single match
            
            if totalScore > bestScore && isAcceptable {
                bestScore = totalScore
                bestMatch = result
                bestAccuracy = finalAccuracy
            }
        }
        
        if bestMatch != nil {
            print("iTunes Enhanced AI: Match selected with score \(String(format: "%.2f", bestScore)) and \(String(format: "%.1f", bestAccuracy))% accuracy")
            return bestMatch
        } else {
            print("iTunes Enhanced AI: No suitable match found (best score: \(String(format: "%.2f", bestScore)), best accuracy: \(String(format: "%.1f", bestAccuracy))%)")
            
            // For regional content, return nothing rather than a poor match
            if isRegionalContent {
                print("iTunes Enhanced AI: Regional content detected - rejecting low-quality matches to avoid incorrect artwork")
                return nil
            }
            
            return nil
        }
    }
    
    private func detectRegionalContent(query: String, queryGroups: [String]) -> Bool {
        let queryLower = query.lowercased()
        
        // Albanian language/cultural indicators
        let albanianIndicators = [
            "popullore", "veriu", "kolazh", "aurela", "gace", "fatmira", 
            "brecani", "therret", "prizreni", "lumi", "buta"
        ]
        
        // Check for regional indicators
        for indicator in albanianIndicators {
            if queryLower.contains(indicator) {
                return true
            }
        }
        
        // Check for complex multi-artist collaborations (often regional)
        let hasMultipleArtists = queryLower.contains("-") && 
                                (queryLower.components(separatedBy: "-").count > 2 ||
                                 queryGroups.count > 4)
        
        // Check for very long artist names (often regional compilations)
        let hasVeryLongComponents = queryGroups.contains { $0.count > 25 }
        
        // Check for parenthetical regional descriptors
        let hasRegionalDescriptors = queryLower.contains("(") && 
                                   (queryLower.contains("popullore") || 
                                    queryLower.contains("folk") ||
                                    queryLower.contains("traditional"))
        
        return hasMultipleArtists || hasVeryLongComponents || hasRegionalDescriptors
    }
    
    private func calculateExactMatchScore(query: String, trackName: String, artistName: String) -> Double {
        let queryLower = query.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let trackLower = trackName.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let artistLower = artistName.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let fullResultLower = "\(trackLower) \(artistLower)".trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Enhanced track name matching with normalization (handles "Love Cats" vs "Lovecats")
        let normalizedQuery = normalizeTrackName(queryLower)
        let normalizedTrack = normalizeTrackName(trackLower)
        _ = normalizeTrackName(artistLower)
        
        // Check for normalized track name match (highest priority)
        if normalizedQuery == normalizedTrack || 
           normalizedQuery.contains(normalizedTrack) && normalizedTrack.count > 3 {
            return 1.2 // Highest score for normalized track match
        }
        
        // Check for exact matches with various combinations
        if queryLower == fullResultLower || 
           queryLower == "\(artistLower) \(trackLower)" ||
           queryLower.contains(trackLower) && queryLower.contains(artistLower) {
            return 1.0
        }
        
        // Check for high similarity with Levenshtein
        let similarity1 = calculateLevenshteinSimilarity(queryLower, fullResultLower)
        let similarity2 = calculateLevenshteinSimilarity(queryLower, "\(artistLower) \(trackLower)")
        
        let maxSimilarity = max(similarity1, similarity2)
        return maxSimilarity >= 0.9 ? maxSimilarity : 0.0
    }
    
    private func calculateEnhancedTwoGroupScore(queryGroups: [String], 
                                              trackGroups: [String], 
                                              artistGroups: [String],
                                              albumGroups: [String]) -> Double {
        guard queryGroups.count >= 2 else { return 0.0 }
        
        var twoGroupScore = 0.0
        
        // Enhanced two-group matching with fuzzy logic
        for i in 0..<queryGroups.count-1 {
            for j in i+1..<queryGroups.count {
                let group1 = queryGroups[i].lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let group2 = queryGroups[j].lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                
                // Check artist-track combinations
                for artistGroup in artistGroups {
                    for trackGroup in trackGroups {
                        let artistLower = artistGroup.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        let trackLower = trackGroup.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        
                        // Perfect match with track name bonus
                        if (group1 == artistLower && group2 == trackLower) || 
                           (group1 == trackLower && group2 == artistLower) {
                            // Extra bonus if track name is specifically mentioned
                            return group1 == trackLower || group2 == trackLower ? 1.3 : 1.0
                        }
                        
                        // Fuzzy match with high threshold
                        let similarity1 = (calculateLevenshteinSimilarity(group1, artistLower) + 
                                         calculateLevenshteinSimilarity(group2, trackLower)) / 2.0
                        let similarity2 = (calculateLevenshteinSimilarity(group1, trackLower) + 
                                         calculateLevenshteinSimilarity(group2, artistLower)) / 2.0
                        
                        let maxSimilarity = max(similarity1, similarity2)
                        if maxSimilarity >= 0.8 {
                            twoGroupScore += maxSimilarity
                        }
                    }
                }
            }
        }
        
        return min(twoGroupScore, 1.0)
    }
    
    private func calculateEnhancedSingleGroupScore(queryGroups: [String],
                                                 trackGroups: [String],
                                                 artistGroups: [String],
                                                 albumGroups: [String]) -> Double {
        var singleGroupScore = 0.0
        let allResultGroups = trackGroups + artistGroups + albumGroups
        
        for queryGroup in queryGroups {
            let queryLower = queryGroup.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            var bestGroupScore = 0.0
            
            // Check against artist groups first (higher priority)
            for artistGroup in artistGroups {
                let artistLower = artistGroup.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                if queryLower == artistLower {
                    bestGroupScore = max(bestGroupScore, 1.0) // Perfect artist match
                } else if queryLower.contains(artistLower) || artistLower.contains(queryLower) {
                    let lengthRatio = Double(min(queryLower.count, artistLower.count)) / 
                                    Double(max(queryLower.count, artistLower.count))
                    bestGroupScore = max(bestGroupScore, 0.8 * lengthRatio)
                } else {
                    let similarity = calculateLevenshteinSimilarity(queryLower, artistLower)
                    if similarity >= 0.75 {
                        bestGroupScore = max(bestGroupScore, 0.7 * similarity)
                    }
                }
            }
            
            // Check against track groups
            for trackGroup in trackGroups {
                let trackLower = trackGroup.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Enhanced track name matching with article normalization
                let normalizedQuery = normalizeTrackName(queryLower)
                let normalizedTrack = normalizeTrackName(trackLower)
                
                if normalizedQuery == normalizedTrack {
                    bestGroupScore = max(bestGroupScore, 1.3) // Perfect normalized track match gets highest priority
                } else if queryLower == trackLower {
                    bestGroupScore = max(bestGroupScore, 1.2) // Perfect exact match
                } else if queryLower.contains(trackLower) || trackLower.contains(queryLower) {
                    let lengthRatio = Double(min(queryLower.count, trackLower.count)) / 
                                    Double(max(queryLower.count, trackLower.count))
                    bestGroupScore = max(bestGroupScore, 0.7 * lengthRatio)
                } else {
                    let similarity = calculateLevenshteinSimilarity(queryLower, trackLower)
                    if similarity >= 0.75 {
                        bestGroupScore = max(bestGroupScore, 0.6 * similarity)
                    }
                }
            }
            
            // Check against album groups (lowest priority)
            for albumGroup in albumGroups {
                let albumLower = albumGroup.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                if queryLower == albumLower {
                    bestGroupScore = max(bestGroupScore, 0.6) // Perfect album match
                } else if queryLower.contains(albumLower) || albumLower.contains(queryLower) {
                    let lengthRatio = Double(min(queryLower.count, albumLower.count)) / 
                                    Double(max(queryLower.count, albumLower.count))
                    bestGroupScore = max(bestGroupScore, 0.4 * lengthRatio)
                } else {
                    let similarity = calculateLevenshteinSimilarity(queryLower, albumLower)
                    if similarity >= 0.75 {
                        bestGroupScore = max(bestGroupScore, 0.3 * similarity)
                    }
                }
            }
            
            singleGroupScore += bestGroupScore
        }
        
        return min(singleGroupScore, 1.0)
    }
    
    private func calculateEnhancedAIScore(query: String,
                                        trackName: String,
                                        artistName: String,
                                        albumName: String,
                                        queryGroups: [String],
                                        resultGroups: [String]) -> (score: Double, confidence: Double) {
        let fullResultText = "\(trackName) \(artistName) \(albumName)".lowercased()
        let queryText = query.lowercased()
        
        // Enhanced semantic similarity
        let semanticScore = calculateEnhancedSemanticSimilarity(queryText, fullResultText)
        
        // Smart length comparison (penalize extreme differences less)
        let lengthDiff = abs(Double(queryText.count - fullResultText.count))
        let maxLength = Double(max(queryText.count, fullResultText.count))
        let lengthSimilarity = max(0.0, 1.0 - (lengthDiff / maxLength) * 0.5) // Less penalty for length differences
        
        // Group coverage with bonus for exact matches
        var groupCoverage = 0.0
        if !queryGroups.isEmpty && !resultGroups.isEmpty {
            var matches = 0
            for queryGroup in queryGroups {
                for resultGroup in resultGroups {
                    if areGroupsMatchingEnhanced(queryGroup, resultGroup) {
                        matches += 1
                        break
                    }
                }
            }
            groupCoverage = Double(matches) / Double(queryGroups.count)
        }
        
        // Enhanced character overlap with word boundary awareness
        let wordOverlap = calculateWordOverlap(queryText, fullResultText)
        
        // Word order similarity
        let orderSimilarity = calculateWordOrderSimilarity(queryText, fullResultText)
        
        // Enhanced AI weighted scoring
        let aiScore = (semanticScore * 0.3) + 
                     (lengthSimilarity * 0.15) + 
                     (groupCoverage * 0.25) + 
                     (wordOverlap * 0.2) + 
                     (orderSimilarity * 0.1)
        
        // Intelligent confidence calculation with bonus for obvious matches
        var confidence = (aiScore * 0.6) + (semanticScore * 0.25) + (groupCoverage * 0.15)
        
        // Boost confidence for obvious exact matches
        if queryText.contains(trackName.lowercased()) && queryText.contains(artistName.lowercased()) {
            confidence = min(confidence + 0.3, 1.0) // +30% boost for containing both artist and track
        } else if queryText.contains(trackName.lowercased()) || queryText.contains(artistName.lowercased()) {
            confidence = min(confidence + 0.15, 1.0) // +15% boost for containing either
        }
        
        // Boost for short, exact queries
        if queryText.count <= 20 && (semanticScore >= 0.7 || groupCoverage >= 0.8) {
            confidence = min(confidence + 0.2, 1.0) // +20% boost for short, precise queries
        }
        
        return (aiScore, confidence)
    }
    
    private func calculateEnhancedSemanticSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = text1.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count > 2 }
        let words2 = text2.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count > 2 }
        
        let set1 = Set(words1)
        let set2 = Set(words2)
        
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    private func calculateWordOverlap(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 })
        let words2 = Set(text2.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 })
        
        let intersection = words1.intersection(words2)
        let maxCount = max(words1.count, words2.count)
        
        return maxCount > 0 ? Double(intersection.count) / Double(maxCount) : 0.0
    }
    
    private func calculateWordOrderSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = text1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let words2 = text2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        let minCount = min(words1.count, words2.count)
        guard minCount > 0 else { return 0.0 }
        
        var matches = 0
        for i in 0..<minCount {
            if words1[i].lowercased() == words2[i].lowercased() {
                matches += 1
            }
        }
        
        return Double(matches) / Double(minCount)
    }
    
    private func areGroupsMatchingEnhanced(_ query: String, _ result: String) -> Bool {
        let queryLower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let resultLower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Exact match
        if queryLower == resultLower {
            return true
        }
        
        // Substring match with reasonable length
        if queryLower.contains(resultLower) || resultLower.contains(queryLower) {
            let minLength = min(queryLower.count, resultLower.count)
            let maxLength = max(queryLower.count, resultLower.count)
            return Double(minLength) / Double(maxLength) >= 0.6
        }
        
        // Fuzzy match
        return calculateLevenshteinSimilarity(queryLower, resultLower) >= 0.8
    }
    
    private func areGroupPairsMatching(_ query: String, _ result: String) -> Bool {
        let queryLower = query.lowercased()
        let resultLower = result.lowercased()
        
        // Check for substantial overlap between two-group pairs
        let queryWords = Set(queryLower.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty })
        let resultWords = Set(resultLower.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty })
        
        let overlap = queryWords.intersection(resultWords)
        return Double(overlap.count) / Double(max(queryWords.count, 1)) >= 0.6
    }
    
    private func areGroupsMatching(_ query: String, _ result: String) -> Bool {
        let queryLower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let resultLower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        return queryLower.contains(resultLower) || 
               resultLower.contains(queryLower) || 
               calculateLevenshteinSimilarity(queryLower, resultLower) >= 0.7
    }
    
    private func calculateSemanticSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty })
        let words2 = Set(text2.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty })
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    private func calculateCharacterOverlap(_ text1: String, _ text2: String) -> Double {
        let chars1 = Set(text1.lowercased())
        let chars2 = Set(text2.lowercased())
        
        let intersection = chars1.intersection(chars2)
        let union = chars1.union(chars2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    private func calculateLevenshteinSimilarity(_ str1: String, _ str2: String) -> Double {
        let len1 = str1.count
        let len2 = str2.count
        
        if len1 == 0 { return len2 == 0 ? 1.0 : 0.0 }
        if len2 == 0 { return 0.0 }
        
        var matrix = Array(repeating: Array(repeating: 0, count: len2 + 1), count: len1 + 1)
        
        for i in 0...len1 { matrix[i][0] = i }
        for j in 0...len2 { matrix[0][j] = j }
        
        let str1Array = Array(str1)
        let str2Array = Array(str2)
        
        for i in 1...len1 {
            for j in 1...len2 {
                let cost = str1Array[i-1] == str2Array[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,
                    matrix[i][j-1] + 1,
                    matrix[i-1][j-1] + cost
                )
            }
        }
        
        let distance = matrix[len1][len2]
        return 1.0 - Double(distance) / Double(max(len1, len2))
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            // Clean up any resources before the task expires.
        }
        
        checkNetworkAndRetry()
        
        task.setTaskCompleted(success: true)
    }
    
    deinit {
        artworkSearchTimer?.invalidate()
        player?.pause()
        retryTimer?.invalidate()
    }
    
    // MARK: - Now Playing Debug Helper
    func debugNowPlayingState() {
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        let currentInfo = nowPlayingCenter.nowPlayingInfo
        
        print("🔍 Now Playing Debug State:")
        print("  - Audio session active: \(AVAudioSession.sharedInstance().isOtherAudioPlaying == false)")
        print("  - Player exists: \(player != nil)")
        print("  - Is playing: \(isPlaying)")
        print("  - Current station index: \(currentStationIndex ?? -1)")
        print("  - Now playing info count: \(currentInfo?.count ?? 0)")
        
        if let info = currentInfo {
            print("  - Title: \(info[MPMediaItemPropertyTitle] as? String ?? "nil")")
            print("  - Artist: \(info[MPMediaItemPropertyArtist] as? String ?? "nil")")
            print("  - Artwork: \(info[MPMediaItemPropertyArtwork] != nil ? "present" : "missing")")
            print("  - Playback rate: \(info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber ?? 0)")
        }
        
        print("  - Metadata: '\(metadata ?? "nil")'")
        print("  - Song title: '\(songTitle)'")
        print("  - Artist name: '\(artistName)'")
        print("  - iTunes artwork: \(iTunesAlbumArt != nil ? "present" : "missing")")
    }
    
    // MARK: - Now Playing Verification Helper
    func verifyNowPlayingSetup() {
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        let commandCenter = MPRemoteCommandCenter.shared()
        let audioSession = AVAudioSession.sharedInstance()
        
        print("🔍 === NOW PLAYING VERIFICATION ===")
        
        // Audio Session Check
        print("🔍 Audio Session:")
        print("  - Category: \(audioSession.category.rawValue)")
        print("  - Mode: \(audioSession.mode.rawValue)")
        print("  - Options: \(audioSession.categoryOptions.rawValue)")
        print("  - Is Active: \(audioSession.isOtherAudioPlaying == false)")
        
        // Now Playing Info Check
        let currentInfo = nowPlayingCenter.nowPlayingInfo
        print("🔍 Now Playing Info:")
        print("  - Info Count: \(currentInfo?.count ?? 0)")
        if let info = currentInfo {
            print("  - Title: \(info[MPMediaItemPropertyTitle] as? String ?? "nil")")
            print("  - Artist: \(info[MPMediaItemPropertyArtist] as? String ?? "nil")")
            print("  - Playback Rate: \(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0.0)")
            print("  - Has Artwork: \(info[MPMediaItemPropertyArtwork] != nil)")
            print("  - Is Live Stream: \(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool ?? false)")
        }
        
        // Command Center Check
        print("🔍 Remote Command Center:")
        print("  - Play Enabled: \(commandCenter.playCommand.isEnabled)")
        print("  - Pause Enabled: \(commandCenter.pauseCommand.isEnabled)")
        print("  - Next Enabled: \(commandCenter.nextTrackCommand.isEnabled)")
        print("  - Previous Enabled: \(commandCenter.previousTrackCommand.isEnabled)")
        print("  - Toggle Play/Pause Enabled: \(commandCenter.togglePlayPauseCommand.isEnabled)")
        
        // Player State Check
        print("🔍 Player State:")
        print("  - Player Exists: \(player != nil)")
        print("  - Is Playing: \(isPlaying)")
        print("  - Current Station Index: \(currentStationIndex ?? -1)")
        print("  - Active Player: \(PlaybackManager.shared.activePlayer)")
        
        // Force Now Playing Update
        print("🔍 Forcing Now Playing Update...")
        updateNowPlayingInfo()
        
        print("🔍 === VERIFICATION COMPLETE ===")
    }

    // Maximum number of stations to cache artwork for
    private let maxArtworkCacheSize = 10
    
    private func cleanupArtworkCache() {
        // If cache exceeds max size, remove oldest entries
        while stationArtworkCache.count > maxArtworkCacheSize {
            let oldestKey = stationArtworkCache.keys.first
            if let key = oldestKey {
                stationArtworkCache.removeValue(forKey: key)
            }
        }
    }
    
    func clearITunesArtwork() {
        iTunesAlbumArt = nil
        lastMetadataSearched = ""
        artworkSearchTimer?.invalidate()
        updateNowPlayingInfo()
        updateWidget()
    }
    
    /// Actively checks for current metadata when resuming from pause
    /// This ensures fresh metadata and iTunes artwork are fetched immediately
    private func checkForCurrentMetadata() {
        guard isPlaying, let player = player, let playerItem = player.currentItem else {
            print("🔍 Metadata Check: Player not available or not playing")
            return
        }
        
        print("🔍 Checking for current metadata after resume...")
        
        // Check if we have timed metadata available
        if let timedMetadata = playerItem.timedMetadata, !timedMetadata.isEmpty {
            for metadataItem in timedMetadata {
                if let commonKey = metadataItem.commonKey,
                   commonKey.rawValue == "title" || commonKey.rawValue == "streamTitle",
                   let stringValue = metadataItem.stringValue,
                   !stringValue.isEmpty {
                    
                    print("🔍 Found current metadata: \(stringValue)")
                    
                    // Update metadata and fetch iTunes artwork
                    DispatchQueue.main.async { [weak self] in
                        self?.metadata = stringValue
                        self?.fetchITunesAlbumArt(for: stringValue)
                        self?.updateNowPlayingInfo()
                        self?.updateWidget()
                    }
                    return
                }
            }
        }
        
        // If no immediate metadata found, set up enhanced monitoring for new metadata
        print("🔍 No immediate metadata found, setting up enhanced monitoring...")
        
        // Reset metadata search state to allow fresh searches
        lastMetadataSearched = ""
        
        // If we still don't have metadata after a short delay, try refreshing the stream connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            
            // If still no metadata after 3 seconds, force a metadata output refresh
            if self.metadata == nil || self.metadata?.isEmpty == true {
                print("🔍 Still no metadata after 3 seconds, refreshing metadata output...")
                self.refreshMetadataOutput()
            }
        }
    }
    
    /// Refreshes the metadata output to ensure we capture new metadata
    private func refreshMetadataOutput() {
        guard let playerItem = player?.currentItem else { return }
        
        print("🔄 Refreshing metadata output for fresh metadata capture...")
        
        // Remove existing metadata outputs
        for output in playerItem.outputs {
            if output is AVPlayerItemMetadataOutput {
                playerItem.remove(output)
            }
        }
        
        // Add fresh metadata output
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        playerItem.add(metadataOutput)
        
        print("✅ Metadata output refreshed - ready to capture new metadata")
    }
}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        guard let group = groups.first,
              let metadataItem = group.items.first,
              let value = metadataItem.value as? String else {
            return
        }
        
        // Update metadata and trigger artwork fetch
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.metadata = value
            
            // Always attempt to fetch artwork for new metadata
            if !value.isEmpty {
                self.fetchITunesAlbumArt(for: value)
            }
            
            self.updateNowPlayingInfo()
            self.updateWidget()
        }
    }
}

extension Notification.Name {
    static let NetworkReconnectNotification = Notification.Name("NetworkReconnectNotification")
}

// String extensions for enhanced metadata parsing
extension String {
    func containsAnyOf(_ substrings: [String]) -> Bool {
        return substrings.contains { self.contains($0) }
    }
    
    func matches(_ pattern: String, options: NSString.CompareOptions = []) -> Bool {
        var searchOptions: NSString.CompareOptions = [.regularExpression]
        searchOptions.formUnion(options)
        return self.range(of: pattern, options: searchOptions) != nil
    }
    
    func extractQuotedStrings() -> [String] {
        var results: [String] = []
        let pattern = "\"([^\"]*)\""
        
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))
            
            for match in matches {
                if let range = Range(match.range(at: 1), in: self) {
                    results.append(String(self[range]))
                }
            }
        } catch {
            print("Regex error in extractQuotedStrings: \(error)")
        }
        
        return results
    }
    
    func removeQuotedStrings() -> String {
        return self.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
    
    // MARK: - Enhanced CarPlay Artwork Observation
    
    /// Sets up CarPlay artwork observation using audio session events and metadata notifications
    private func setupCarPlayArtworkObservation() {
        print("🚗 RadioPlayer: Setting up enhanced CarPlay artwork observation")
        
        // Listen for audio session route changes (CarPlay connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // Listen for audio session interruptions that might indicate CarPlay state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        print("🚗 RadioPlayer: CarPlay artwork observation setup complete")
    }
    
    /// Enhanced metadata observation for CarPlay artwork fetching
    private func setupEnhancedMetadataObservation() {
        guard let playerItem = self.playerItem else { return }
        
        print("🚗 RadioPlayer: Setting up enhanced metadata observation for CarPlay")
        
        // Remove existing metadata output if any
        for output in playerItem.outputs {
            if output is AVPlayerItemMetadataOutput {
                playerItem.remove(output)
            }
        }
        
        // Create enhanced metadata output for CarPlay
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: DispatchQueue.main)
        metadataOutput.advanceIntervalForDelegateInvocation = 0.1 // More frequent updates for CarPlay
        
        playerItem.add(metadataOutput)
        
        // Also observe timed metadata groups for immediate response
        playerItem.addObserver(self, forKeyPath: "timedMetadata", options: [.new], context: nil)
        
        print("🚗 RadioPlayer: Enhanced metadata observation configured")
    }
    
    /// Sets up periodic time observer for the player
    private func setupPeriodicTimeObserver() {
        guard let player = self.player else { return }
        
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: 1.0, preferredTimescale: timeScale)
        
        player.addPeriodicTimeObserver(forInterval: time, queue: .main) { [weak self] time in
            // This can be used for any periodic updates during playback
            // Currently just ensuring player state is maintained
            guard let self = self else { return }
            
            // Trigger artwork fetch if we have metadata but no artwork during CarPlay
            if CarPlayManager.shared.isCarPlayConnected,
               self.isPlaying,
               self.iTunesAlbumArt == nil,
               let metadata = self.metadata,
               !metadata.isEmpty,
               metadata != self.lastMetadataSearched {
                
                print("🚗 RadioPlayer: Periodic check found new metadata during CarPlay playback")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.fetchCarPlayArtworkDuringPlayback(metadata: metadata)
                }
            }
        }
    }
    
    /// Triggers CarPlay artwork fetch when playback starts - this leverages audio session privileges
    private func triggerCarPlayArtworkFetchOnPlayback() {
        guard CarPlayManager.shared.isCarPlayConnected else { return }
        
        print("🚗 RadioPlayer: Triggering CarPlay artwork fetch on playback start")
        
        // Use the fact that we just started playback to attempt immediate artwork fetch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self,
                  self.isPlaying,
                  let metadata = self.metadata,
                  !metadata.isEmpty,
                  self.iTunesAlbumArt == nil else { return }
            
            print("🚗 RadioPlayer: Attempting iTunes artwork fetch during active playback")
            self.fetchCarPlayArtworkDuringPlayback(metadata: metadata)
        }
    }
    
    /// Fetches iTunes artwork during active CarPlay playback when network privileges are highest
    private func fetchCarPlayArtworkDuringPlayback(metadata: String) {
        print("🚗 RadioPlayer: Fetching iTunes artwork during CarPlay playback")
        
        // Create a background task to keep network access alive during the request
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "CarPlayArtworkFetch") {
            // Clean up if the task expires
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        
        // Perform the search with high priority
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.searchITunesForArtwork(metadata: metadata) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let image = image {
                        print("🚗 RadioPlayer: iTunes artwork fetched successfully during CarPlay playback")
                        
                        self.iTunesAlbumArt = image
                        self.saveITunesArtworkToCurrentStation(image)
                        self.updateNowPlayingInfo()
                        self.updateWidget()
                        
                        // Notify CarPlay of artwork update
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CarPlayArtworkUpdated"),
                            object: nil,
                            userInfo: ["metadata": metadata, "hasArtwork": true]
                        )
                    } else {
                        print("🚗 RadioPlayer: No iTunes artwork found during CarPlay playback")
                    }
                    
                    // End the background task
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }
                }
            }
        }
    }
    
    /// Handles audio session route changes to detect CarPlay connection
    @objc private func audioSessionRouteChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        
        // Check if CarPlay is in the current route
        let isCarPlayConnected = currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
        
        if isCarPlayConnected && isPlaying && iTunesAlbumArt == nil {
            print("🚗 RadioPlayer: CarPlay connected during playback - triggering artwork fetch")
            
            if let metadata = self.metadata, !metadata.isEmpty {
                // Use a delay to ensure CarPlay is fully initialized
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.fetchCarPlayArtworkDuringPlayback(metadata: metadata)
                }
            }
        }
    }
    
    /// Handles audio session interruptions to trigger artwork fetching when session resumes
    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .ended,
           CarPlayManager.shared.isCarPlayConnected,
           isPlaying,
           iTunesAlbumArt == nil,
           let metadata = self.metadata,
           !metadata.isEmpty {
            
            print("🚗 RadioPlayer: Audio session resumed - checking for artwork fetch opportunity")
            
            // This fires when audio session resumes - good time to attempt artwork fetch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.fetchCarPlayArtworkDuringPlayback(metadata: metadata)
            }
        }
    }
    
    /// KVO observer for timed metadata changes
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timedMetadata" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let playerItem = self.playerItem,
                      CarPlayManager.shared.isCarPlayConnected,
                      self.isPlaying else { return }
                
                // Check if we have new metadata and no artwork
                if let timedMetadata = playerItem.timedMetadata,
                   !timedMetadata.isEmpty,
                   self.iTunesAlbumArt == nil {
                    
                    // Extract metadata and trigger artwork fetch
                    for metadataItem in timedMetadata {
                        if let commonKey = metadataItem.commonKey,
                           commonKey.rawValue == "title",
                           let stringValue = metadataItem.stringValue,
                           !stringValue.isEmpty {
                            
                            print("🚗 RadioPlayer: New timed metadata detected during CarPlay playback: \(stringValue)")
                            
                            // Trigger artwork fetch for new metadata
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.fetchCarPlayArtworkDuringPlayback(metadata: stringValue)
                            }
                            break
                        }
                    }
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
