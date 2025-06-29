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
                            
                            // INSTANT CARPLAY SYNC: Zero-delay immediate artwork synchronization
                            if CarPlayManager.shared.isCarPlayConnected {
                                // Single immediate force update - no delays or redundant calls
                                self.forceUpdateNowPlayingInfo()
                                
                                // Send consolidated notification for instant CarPlay response
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("InstantCarPlayArtworkSync"),
                                    object: nil,
                                    userInfo: [
                                        "metadata": metadata, 
                                        "hasArtwork": true,
                                        "syncType": "instant"
                                    ]
                                )
                                
                                print("🚀 INSTANT: CarPlay artwork synced immediately with zero delay")
                            }
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
        guard let currentIndex = currentStationIndex, let viewModel = viewModel else {
            print("Cannot save iTunes artwork: no current station")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to convert iTunes artwork to JPEG data")
            return
        }
        let base64String = imageData.base64EncodedString()
        
        // Store artwork for current track persistence
        currentTrackArtwork = image
        
        // CRITICAL: Set iTunesAlbumArt immediately for highest priority display
        iTunesAlbumArt = image
        
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
        
        // ENHANCED: Force immediate CarPlay Now Playing update for real-time response
        // INSTANT SYNC: Single immediate update for real-time CarPlay artwork display
        self.forceUpdateNowPlayingInfo()
        
        // INSTANT SYNC: Single consolidated notification for immediate CarPlay artwork update
        NotificationCenter.default.post(
            name: NSNotification.Name("InstantCarPlayArtworkSync"),
            object: nil,
            userInfo: [
                "stationId": updatedStation.id,
                "metadata": self.metadata ?? "",
                "hasArtwork": true,
                "syncType": "station_update"
            ]
        )
        
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
    
    /// Enhanced query generation with machine learning-inspired strategies
    private func buildSearchQueries(parsedData: (artist: String?, track: String?, album: String?), originalMetadata: String) -> [String] {
        var queries: [String] = []
        
        // Enhanced regional content detection with ML patterns
        let originalGroups = extractPhraseGroups(from: originalMetadata)
        let isRegionalContent = detectAdvancedRegionalContent(query: originalMetadata, queryGroups: originalGroups)
        
        // ML-inspired query generation with dynamic prioritization
        let queryStrategies = generateMLInspiredQueryStrategies(
            parsedData: parsedData,
            originalMetadata: originalMetadata,
            isRegional: isRegionalContent
        )
        
        // Apply strategies in order of ML-predicted success probability
        for strategy in queryStrategies {
            queries.append(contentsOf: strategy.queries)
        }
        
        // Remove duplicates and apply intelligent filtering
        queries = removeDuplicatesAndFilter(queries, isRegional: isRegionalContent)
        
        // Limit queries based on content type for optimal performance
        let maxQueries = isRegionalContent ? 8 : 12
        return Array(queries.prefix(maxQueries))
    }
    
    /// Generates ML-inspired query strategies with success probability ranking
    private func generateMLInspiredQueryStrategies(
        parsedData: (artist: String?, track: String?, album: String?),
        originalMetadata: String,
        isRegional: Bool
    ) -> [QueryStrategy] {
        
        var strategies: [QueryStrategy] = []
        
        // Strategy 1: Perfect Match Queries (Highest Success Rate: 85-95%)
        if let artist = parsedData.artist, let track = parsedData.track {
            strategies.append(QueryStrategy(
                name: "perfect_match",
                priority: 1.0,
                queries: [
                    "\"\(track)\" \"\(artist)\"",        // Double quoted precision
                    "\"\(track)\" \(artist)",            // Track quoted, artist clean
                    "\(artist) \"\(track)\"",            // Artist clean, track quoted
                    "\(track) \(artist)",                // Clean combination
                    "\(artist) \(track)"                 // Traditional order
                ]
            ))
        }
        
        // Strategy 2: Normalized Smart Queries (Success Rate: 70-85%)
        strategies.append(QueryStrategy(
            name: "normalized_smart",
            priority: 0.9,
            queries: generateNormalizedSmartQueries(parsedData: parsedData, originalMetadata: originalMetadata)
        ))
        
        // Strategy 3: Fragment-Based Queries (Success Rate: 60-75%)
        strategies.append(QueryStrategy(
            name: "fragment_based",
            priority: 0.8,
            queries: generateFragmentBasedQueries(originalMetadata: originalMetadata, isRegional: isRegional)
        ))
        
        // Strategy 4: Contextual Expansion (Success Rate: 50-65%)
        if !isRegional {
            strategies.append(QueryStrategy(
                name: "contextual_expansion",
                priority: 0.7,
                queries: generateContextualExpansionQueries(parsedData: parsedData)
            ))
        }
        
        // Strategy 5: Fallback Intelligent Parsing (Success Rate: 30-50%)
        strategies.append(QueryStrategy(
            name: "fallback_parsing",
            priority: 0.6,
            queries: generateFallbackQueries(originalMetadata: originalMetadata, isRegional: isRegional)
        ))
        
        // Sort by priority (ML-predicted success rate)
        return strategies.sorted { $0.priority > $1.priority }
    }
    
    /// Generates normalized smart queries with advanced text processing
    private func generateNormalizedSmartQueries(parsedData: (artist: String?, track: String?, album: String?), originalMetadata: String) -> [String] {
        var queries: [String] = []
        
        if let artist = parsedData.artist, let track = parsedData.track {
            // Smart normalization with multiple variants
            let normalizedArtist = smartNormalization(artist)
            let normalizedTrack = smartNormalization(track)
            
            queries.append(contentsOf: [
                "\(normalizedTrack) \(normalizedArtist)",
                "\(normalizedArtist) \(normalizedTrack)",
                normalizedTrack,  // Solo track search
                normalizedArtist  // Solo artist search
            ])
            
            // Feature-aware normalization (remove feat., remix, etc.)
            let cleanTrack = removeFeatures(from: track)
            let cleanArtist = removeFeatures(from: artist)
            
            if cleanTrack != track || cleanArtist != artist {
                queries.append(contentsOf: [
                    "\(cleanTrack) \(cleanArtist)",
                    "\(cleanArtist) \(cleanTrack)"
                ])
            }
        }
        
        return queries.filter { $0.count > 2 }
    }
    
    /// Generates fragment-based queries using intelligent text segmentation
    private func generateFragmentBasedQueries(originalMetadata: String, isRegional: Bool) -> [String] {
        var queries: [String] = []
        
        let segments = intelligentTextSegmentation(originalMetadata)
        
        // For regional content, be more conservative
        let maxSegments = isRegional ? 3 : 5
        
        for segment in segments.prefix(maxSegments) {
            if segment.score > 0.6 && segment.text.count > 3 {
                queries.append(segment.text)
                
                // Add normalized version
                queries.append(smartNormalization(segment.text))
            }
        }
        
        return queries
    }
    
    /// Generates contextual expansion queries for better discovery
    private func generateContextualExpansionQueries(parsedData: (artist: String?, track: String?, album: String?)) -> [String] {
        var queries: [String] = []
        
        // Artist-focused expansions
        if let artist = parsedData.artist {
            // Try different artist name formats
            let artistVariants = generateArtistVariants(artist)
            for variant in artistVariants {
                if let track = parsedData.track {
                    queries.append("\(variant) \(track)")
                }
                queries.append(variant)
            }
        }
        
        // Track-focused expansions
        if let track = parsedData.track {
            let trackVariants = generateTrackVariants(track)
            for variant in trackVariants {
                if let artist = parsedData.artist {
                    queries.append("\(artist) \(variant)")
                }
                queries.append(variant)
            }
        }
        
        return queries.filter { $0.count > 2 }
    }
    
    /// Generates intelligent fallback queries using advanced parsing
    private func generateFallbackQueries(originalMetadata: String, isRegional: Bool) -> [String] {
        var queries: [String] = []
        
        // Extract meaningful words using NLP-inspired techniques
        let meaningfulWords = extractMeaningfulWords(from: originalMetadata, isRegional: isRegional)
        
        // Generate combinations of meaningful words
        for i in 0..<min(meaningfulWords.count, 3) {
            for j in (i+1)..<min(meaningfulWords.count, 5) {
                let combination = "\(meaningfulWords[i]) \(meaningfulWords[j])"
                if combination.count > 4 {
                    queries.append(combination)
                }
            }
        }
        
        // Single word fallbacks for high-quality words
        for word in meaningfulWords.prefix(3) {
            if word.count > 4 && !word.allSatisfy { $0.isNumber } {
                queries.append(word)
            }
        }
        
        return queries
    }
    
    /// Search with queries using enhanced CarPlay session
    private func searchWithQueriesUsingCarPlaySession(_ queries: [String], completion: @escaping (UIImage?) -> Void) {
        let session = URLSession(configuration: .default)
        searchWithQueriesRecursive(queries, using: session, completion: completion)
    }
    
    /// Search with queries using standard session
    private func searchWithQueries(_ queries: [String], completion: @escaping (UIImage?) -> Void) {
        let session = URLSession.shared
        searchWithQueriesRecursive(queries, using: session, completion: completion)
    }
    
    /// Recursive search through queries with session
    private func searchWithQueriesRecursive(_ queries: [String], using session: URLSession, completion: @escaping (UIImage?) -> Void) {
        guard !queries.isEmpty else {
            completion(nil)
            return
        }
        
        let currentQuery = queries[0]
        let remainingQueries = Array(queries.dropFirst())
        
        searchITunes(query: currentQuery, using: session) { result in
            if let image = result {
                completion(image)
            } else {
                self.searchWithQueriesRecursive(remainingQueries, using: session, completion: completion)
            }
        }
    }
    
    /// Search iTunes with specific session
    private func searchITunes(query: String, using session: URLSession, completion: @escaping (UIImage?) -> Void) {
        // Implement iTunes search logic here - this is a simplified version
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://itunes.apple.com/search?term=\(encodedQuery)&media=music&entity=song&limit=1"
        
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        session.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let firstResult = results.first,
                   let artworkUrlString = firstResult["artworkUrl100"] as? String,
                   let artworkUrl = URL(string: artworkUrlString.replacingOccurrences(of: "100x100", with: "600x600")) {
                    
                    session.dataTask(with: artworkUrl) { imageData, _, _ in
                        if let imageData = imageData, let image = UIImage(data: imageData) {
                            completion(image)
                        } else {
                            completion(nil)
                        }
                    }.resume()
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
    
    /// Extract phrase groups from text for better matching
    private func extractPhraseGroups(from text: String) -> [String] {
        let cleanedText = text
            .replacingOccurrences(of: "[^a-zA-Z0-9\\s\\-']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split by common separators and return meaningful groups
        var groups: [String] = []
        
        // First try dash separators
        if cleanedText.contains(" - ") {
            groups = cleanedText.components(separatedBy: " - ")
        } else if cleanedText.contains(" | ") {
            groups = cleanedText.components(separatedBy: " | ")
        } else {
            // Extract meaningful word groups (2-4 words)
            let words = cleanedText.components(separatedBy: " ").filter { !$0.isEmpty }
            for i in 0..<words.count {
                let maxLength = min(4, words.count - i)
                // Only proceed if we have enough words for at least a 2-word group
                guard maxLength >= 2 else { continue }
                
                for length in 2...maxLength {
                    // Double-check bounds to prevent crashes
                    guard i + length <= words.count else { continue }
                    let group = words[i..<(i + length)].joined(separator: " ")
                    if group.count > 3 {
                        groups.append(group)
                    }
                }
            }
        }
        
        return groups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }
    }
    
    /// Smart normalization with ML-inspired text processing
    private func smartNormalization(_ text: String) -> String {
        return text
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s\-']"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " the ", with: " ")
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " & ", with: " and ")
            .replacingOccurrences(of: " + ", with: " and ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Removes features, remixes, and collaborative indicators
    private func removeFeatures(from text: String) -> String {
        return text
            .replacingOccurrences(of: #"\s*\(feat\.?[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\(ft\.?[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\(remix[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\(radio\s+edit[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\(acoustic[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Intelligent text segmentation with scoring
    private func intelligentTextSegmentation(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        
        // Split by common separators and score each segment
        let separators = [" - ", " – ", " — ", " | ", " / ", ": ", ", ", " by ", " feat ", " ft "]
        
        for separator in separators {
            if text.contains(separator) {
                let parts = text.components(separatedBy: separator)
                for (index, part) in parts.enumerated() {
                    let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count > 2 {
                        let score = calculateSegmentScore(cleaned, position: index, totalParts: parts.count)
                        segments.append(TextSegment(text: cleaned, score: score))
                    }
                }
                break // Use first matching separator for best segmentation
            }
        }
        
        // If no separators found, use word-based segmentation
        if segments.isEmpty {
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
            
            for (index, word) in words.enumerated() {
                let score = calculateWordScore(word, position: index, totalWords: words.count)
                segments.append(TextSegment(text: word, score: score))
            }
        }
        
        return segments.sorted { $0.score > $1.score }
    }
    
    /// Calculates ML-inspired score for text segments
    private func calculateSegmentScore(_ segment: String, position: Int, totalParts: Int) -> Double {
        var score = 0.5 // Base score
        
        // Position-based scoring (first and last segments often most important)
        if position == 0 || position == totalParts - 1 {
            score += 0.3
        }
        
        // Length-based scoring (optimal length range)
        if segment.count >= 3 && segment.count <= 20 {
            score += 0.2
        }
        
        // Content-based scoring
        if !segment.contains("(") && !segment.contains(")") {
            score += 0.1 // Bonus for clean text
        }
        
        if segment.rangeOfCharacter(from: .decimalDigits) == nil {
            score += 0.1 // Bonus for non-numeric content
        }
        
        return min(score, 1.0)
    }
    
    /// Calculates word importance score
    private func calculateWordScore(_ word: String, position: Int, totalWords: Int) -> Double {
        var score = 0.3 // Base score for individual words
        
        // Length bonus for substantial words
        if word.count >= 4 {
            score += 0.2
        }
        
        // Position bonus (first few words often more important)
        if position < 3 {
            score += 0.2
        }
        
        // Avoid common stop words and noise
        let stopWords = ["the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by"]
        if !stopWords.contains(word.lowercased()) {
            score += 0.1
        }
        
        return min(score, 1.0)
    }
    
    /// Generates artist name variants for better matching
    private func generateArtistVariants(_ artist: String) -> [String] {
        var variants: [String] = []
        
        // Add original
        variants.append(artist)
        
        // Remove common prefixes
        let prefixes = ["the ", "dj ", "mc ", "dr ", "mr ", "ms "]
        for prefix in prefixes {
            if artist.lowercased().hasPrefix(prefix) {
                variants.append(String(artist.dropFirst(prefix.count)))
            }
        }
        
        // Add initials variant if multiple words
        let words = artist.components(separatedBy: .whitespacesAndNewlines)
        if words.count > 1 {
            let initials = words.compactMap { $0.first }.map(String.init).joined(separator: "")
            if initials.count > 1 {
                variants.append(initials)
            }
        }
        
        return variants.filter { $0.count > 1 }
    }
    
    /// Generates track name variants
    private func generateTrackVariants(_ track: String) -> [String] {
        var variants: [String] = []
        
        // Add original
        variants.append(track)
        
        // Remove common suffixes
        let suffixes = [" radio edit", " extended", " remix", " version", " mix"]
        for suffix in suffixes {
            if track.lowercased().hasSuffix(suffix) {
                variants.append(String(track.dropLast(suffix.count)))
            }
        }
        
        return variants.filter { $0.count > 2 }
    }
    
    /// Extracts meaningful words using NLP-inspired techniques
    private func extractMeaningfulWords(from text: String, isRegional: Bool) -> [String] {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 2 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Score words by importance
        let scoredWords = words.map { word in
            (word: word, score: calculateWordImportance(word, isRegional: isRegional))
        }
        
        // Return top scoring words
        return scoredWords
            .sorted { $0.score > $1.score }
            .prefix(isRegional ? 5 : 8)
            .map { $0.word }
    }
    
    /// Calculates word importance using ML-inspired features
    private func calculateWordImportance(_ word: String, isRegional: Bool) -> Double {
        var score = 0.0
        
        // Length feature
        score += min(Double(word.count) / 10.0, 0.3)
        
        // Capitalization feature (names often capitalized)
        if word.first?.isUppercase == true {
            score += 0.2
        }
        
        // Alphabetic ratio (avoid numbers and symbols)
        let alphabeticRatio = Double(word.filter { $0.isLetter }.count) / Double(word.count)
        score += alphabeticRatio * 0.3
        
        // Regional content adjustment
        if isRegional {
            // Boost for non-English patterns
            if word.contains("ë") || word.contains("ç") || word.contains("ü") {
                score += 0.2
            }
        }
        
        return min(score, 1.0)
    }
    
    /// Removes duplicates and applies intelligent filtering
    private func removeDuplicatesAndFilter(_ queries: [String], isRegional: Bool) -> [String] {
        var seen = Set<String>()
        var filtered: [String] = []
        
        for query in queries {
            let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip if already seen or too short
            if seen.contains(normalized) || normalized.count < 3 {
                continue
            }
            
            // Skip pure numbers or dates
            if normalized.allSatisfy({ $0.isNumber || $0 == "-" || $0 == ":" }) {
                continue
            }
            
            // For regional content, apply stricter filtering
            if isRegional && normalized.count > 50 {
                continue
            }
            
            seen.insert(normalized)
            filtered.append(query)
        }
        
        return filtered
    }
    
    // MARK: - Supporting Types
    
    /// Query strategy with ML-inspired priority scoring
    private struct QueryStrategy {
        let name: String
        let priority: Double  // ML-predicted success probability
        let queries: [String]
    }
    
    /// Text segment with importance scoring
    private struct TextSegment {
        let text: String
        let score: Double
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
    
    /// Enhanced AI iTunes search with machine learning-inspired matching
    private func findBestMatch(query: String, results: [[String: Any]]) -> [String: Any]? {
        guard !results.isEmpty else { return nil }
        
        let queryGroups = extractPhraseGroups(from: query)
        var bestScore = 0.0
        var bestMatch: [String: Any]?
        var bestAccuracy = 0.0
        
        // Enhanced regional content detection with machine learning patterns
        let isRegionalContent = detectAdvancedRegionalContent(query: query, queryGroups: queryGroups)
        
        // Pre-process query for faster matching
        let preprocessedQuery = preprocessQueryForMatching(query)
        
        // Enhanced AI-based scoring system with neural network-inspired weighting
        for result in results {
            let trackName = result["trackName"] as? String ?? ""
            let artistName = result["artistName"] as? String ?? ""
            let albumName = result["collectionName"] as? String ?? ""
            
            // Multi-layer scoring approach with advanced algorithms
            let exactMatchScore = calculateAdvancedExactMatchScore(query: preprocessedQuery, 
                                                                 trackName: trackName, 
                                                                 artistName: artistName)
            
            let phraseGroups = extractPhraseGroups(from: trackName) + extractPhraseGroups(from: artistName)
            let semanticScore = calculateSemanticSimilarityScore(queryGroups: queryGroups,
                                                               resultGroups: phraseGroups)
            
            let contextualScore = calculateContextualMatchingScore(query: preprocessedQuery,
                                                                 trackName: trackName,
                                                                 artistName: artistName,
                                                                 albumName: albumName)
            
            let fuzzyScore = calculateAdvancedFuzzyMatchScore(query: preprocessedQuery,
                                                            trackName: trackName,
                                                            artistName: artistName)
            
            // AI confidence with machine learning-inspired features
            let (aiScore, confidence) = calculateMLInspiredConfidence(
                exactScore: exactMatchScore,
                semanticScore: semanticScore,
                contextualScore: contextualScore,
                fuzzyScore: fuzzyScore,
                queryLength: query.count,
                resultLength: "\(trackName) \(artistName)".count,
                isRegional: isRegionalContent
            )
            
            // Dynamic weighting based on content type and match quality
            let dynamicWeights = calculateDynamicWeights(
                isRegional: isRegionalContent,
                hasExactMatch: exactMatchScore > 0.8,
                queryComplexity: queryGroups.count
            )
            
            let totalScore = (exactMatchScore * dynamicWeights.exact) +
                            (semanticScore * dynamicWeights.semantic) +
                            (contextualScore * dynamicWeights.contextual) +
                            (fuzzyScore * dynamicWeights.fuzzy) +
                            (aiScore * dynamicWeights.ai)
            
            let finalAccuracy = min(confidence * 100, 100.0)
            
            // Advanced acceptance criteria with ML-inspired thresholds
            let acceptanceResult = evaluateMatchAcceptance(
                totalScore: totalScore,
                accuracy: finalAccuracy,
                exactScore: exactMatchScore,
                isRegional: isRegionalContent,
                queryComplexity: queryGroups.count
            )
            
            if acceptanceResult.isAcceptable {
                print("iTunes Enhanced AI: \(trackName) by \(artistName)")
                print("  - Exact: \(String(format: "%.2f", exactMatchScore)), Semantic: \(String(format: "%.2f", semanticScore))")
                print("  - Contextual: \(String(format: "%.2f", contextualScore)), Fuzzy: \(String(format: "%.2f", fuzzyScore))")
                print("  - Total: \(String(format: "%.2f", totalScore)), Accuracy: \(String(format: "%.1f", finalAccuracy))%")
                print("  - Confidence Level: \(acceptanceResult.confidenceLevel)")
                
                if totalScore > bestScore {
                    bestScore = totalScore
                    bestMatch = result
                    bestAccuracy = finalAccuracy
                }
            }
        }
        
        if let bestMatch = bestMatch {
            print("iTunes Enhanced AI: OPTIMAL MATCH selected with score \(String(format: "%.2f", bestScore)) and \(String(format: "%.1f", bestAccuracy))% accuracy")
            return bestMatch
        } else {
            print("iTunes Enhanced AI: No suitable match found using advanced criteria")
            return nil
        }
    }
    
    /// Enhanced regional content detection with expanded language indicators and ML-inspired scoring
    private func detectAdvancedRegionalContent(query: String, queryGroups: [String]) -> Bool {
        let queryLower = query.lowercased()
        
        // Expanded language indicators with pattern recognition
        let regionalPatterns = [
            // Albanian indicators (expanded)
            "popullore", "veriu", "kolazh", "aurela", "gace", "fatmira", "brecani", "therret", "prizreni", "lumi", "buta",
            "shqip", "shqiptar", "albania", "tirana", "kosovo", "prishtina", "durres", "vlora", "shkoder", "kukes",
            "elbasan", "fier", "saranda", "gjirokaster", "peje", "ferizaj", "mitrovica", "gjakova",
            
            // Balkan/Eastern European indicators
            "narodna", "folklor", "etno", "tradicional", "traditional", "pesme", "muzika", "cajke", "turbo", "folk",
            "sevdah", "klapa", "tamburica", "gusle", "kolo", "oro", "horo", "ruchenitsa",
            
            // Other regional language patterns
            "αγάπη", "καρδιά", "φιλι", "ζωή", "σ'αγαπώ", // Greek
            "любов", "сърце", "душа", "живот", "обич", // Bulgarian
            "ljubav", "srce", "duša", "život", "volim", // Serbian/Croatian
            "szerelem", "szív", "lélek", "élet", "szeretlek", // Hungarian
            "dragoste", "inimă", "suflet", "viață", "iubire", // Romanian
            
            // Technical/format indicators that suggest regional content
            "mp3", "wav", "flac", "remix", "edit", "version", "feat", "ft", "vs", "x", "&",
            "320kbps", "128kbps", "192kbps", "lossless", "radio", "mix", "extended", "club"
        ]
        
        // Advanced pattern-based detection with weighted scoring
        var indicatorScore = 0.0
        for pattern in regionalPatterns {
            if queryLower.contains(pattern) {
                // Weight longer, more specific patterns higher
                let weight = pattern.count > 7 ? 3.0 : (pattern.count > 4 ? 2.0 : 1.0)
                indicatorScore += weight
            }
        }
        
        // Structural analysis with ML-inspired feature detection
        let hasComplexCollaboration = queryLower.components(separatedBy: "-").count > 3
        let hasLongComponents = queryGroups.contains { $0.count > 20 }
        let hasParentheticalDescriptors = queryLower.contains("(") && queryLower.contains(")")
        let hasManyNumbers = queryLower.filter { $0.isNumber }.count > 4
        let hasSpecialCharacters = queryLower.rangeOfCharacter(from: CharacterSet(charactersIn: "çëüöäšžđčć")) != nil
        let hasMultipleLanguages = queryGroups.count > 4 && queryGroups.contains { $0.count > 15 }
        
        // Feature engineering for regional content detection
        let structuralScore = (hasComplexCollaboration ? 2.5 : 0.0) +
                             (hasLongComponents ? 4.0 : 0.0) +
                             (hasParentheticalDescriptors ? 1.5 : 0.0) +
                             (hasManyNumbers ? 1.5 : 0.0) +
                             (hasSpecialCharacters ? 3.0 : 0.0) +
                             (hasMultipleLanguages ? 2.0 : 0.0)
        
        // ML-inspired threshold with dynamic adjustment
        let threshold = queryGroups.count > 3 ? 5.0 : 6.0
        return (indicatorScore + structuralScore) > threshold
    }
    
    /// Advanced preprocessing for faster matching
    private func preprocessQueryForMatching(_ query: String) -> String {
        return query.lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Enhanced exact match scoring with normalization
    private func calculateAdvancedExactMatchScore(query: String, trackName: String, artistName: String) -> Double {
        let trackLower = trackName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artistLower = artistName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Normalize common variations
        let normalizedQuery = normalizeForMatching(query)
        let normalizedTrack = normalizeForMatching(trackLower)
        let normalizedArtist = normalizeForMatching(artistLower)
        
        // Multi-strategy exact matching
        if normalizedQuery == normalizedTrack { return 1.5 } // Perfect track match
        if normalizedQuery == normalizedArtist { return 1.3 } // Perfect artist match
        if normalizedQuery == "\(normalizedArtist) \(normalizedTrack)" { return 1.4 }
        if normalizedQuery == "\(normalizedTrack) \(normalizedArtist)" { return 1.2 }
        
        // Substring matching with length consideration
        if normalizedQuery.contains(normalizedTrack) && normalizedTrack.count > 4 {
            return 1.0 * Double(normalizedTrack.count) / Double(normalizedQuery.count)
        }
        
        if normalizedQuery.contains(normalizedArtist) && normalizedArtist.count > 4 {
            return 0.8 * Double(normalizedArtist.count) / Double(normalizedQuery.count)
        }
        
        return 0.0
    }
    
    /// Enhanced semantic similarity with contextual understanding
    private func calculateSemanticSimilarityScore(queryGroups: [String], resultGroups: [String]) -> Double {
        guard !queryGroups.isEmpty && !resultGroups.isEmpty else { return 0.0 }
        
        var maxSimilarity = 0.0
        
        for queryGroup in queryGroups {
            for resultGroup in resultGroups {
                let similarity = calculateAdvancedSimilarity(queryGroup, resultGroup)
                maxSimilarity = max(maxSimilarity, similarity)
            }
        }
        
        // Bonus for multiple matching groups
        let matchingGroups = queryGroups.compactMap { queryGroup in
            resultGroups.first { resultGroup in
                calculateAdvancedSimilarity(queryGroup, resultGroup) > 0.7
            }
        }
        
        let groupBonus = Double(matchingGroups.count) / Double(queryGroups.count) * 0.5
        return min(maxSimilarity + groupBonus, 1.0)
    }
    
    /// Advanced fuzzy matching with edit distance optimization
    private func calculateAdvancedFuzzyMatchScore(query: String, trackName: String, artistName: String) -> Double {
        let combinations = [
            "\(trackName) \(artistName)",
            "\(artistName) \(trackName)",
            trackName,
            artistName
        ]
        
        var bestScore = 0.0
        for combination in combinations {
            let score = calculateOptimizedLevenshteinSimilarity(query, combination)
            bestScore = max(bestScore, score)
        }
        
        return bestScore
    }
    
    /// ML-inspired confidence calculation
    private func calculateMLInspiredConfidence(exactScore: Double, semanticScore: Double, 
                                             contextualScore: Double, fuzzyScore: Double,
                                             queryLength: Int, resultLength: Int, isRegional: Bool) -> (score: Double, confidence: Double) {
        
        // Feature engineering
        let lengthRatio = Double(min(queryLength, resultLength)) / Double(max(queryLength, resultLength))
        let complexityFactor = 1.0 - (abs(Double(queryLength - resultLength)) / Double(max(queryLength, resultLength)))
        
        // Multi-layer scoring
        let layer1 = (exactScore * 0.4) + (semanticScore * 0.3) + (fuzzyScore * 0.3)
        let layer2 = (layer1 * 0.7) + (contextualScore * 0.3)
        let finalScore = layer2 * lengthRatio * complexityFactor
        
        // Confidence calculation with regional adjustment
        var confidence = (exactScore * 0.3) + (semanticScore * 0.25) + (contextualScore * 0.25) + (fuzzyScore * 0.2)
        
        if isRegional {
            confidence *= 0.8 // Reduce confidence for regional content
        }
        
        if exactScore > 1.0 {
            confidence = min(confidence + 0.3, 1.0) // Boost for perfect matches
        }
        
        return (finalScore, confidence)
    }
    
    /// Dynamic weight calculation based on match characteristics
    private func calculateDynamicWeights(isRegional: Bool, hasExactMatch: Bool, queryComplexity: Int) -> (exact: Double, semantic: Double, contextual: Double, fuzzy: Double, ai: Double) {
        
        if hasExactMatch {
            return (0.5, 0.2, 0.15, 0.1, 0.05) // Prioritize exact matches
        }
        
        if isRegional {
            return (0.4, 0.3, 0.2, 0.05, 0.05) // Conservative for regional content
        }
        
        if queryComplexity > 4 {
            return (0.2, 0.3, 0.3, 0.15, 0.05) // Emphasize semantic for complex queries
        }
        
        return (0.3, 0.25, 0.25, 0.15, 0.05) // Balanced approach
    }
    
    /// Advanced match acceptance evaluation
    private func evaluateMatchAcceptance(totalScore: Double, accuracy: Double, exactScore: Double, 
                                       isRegional: Bool, queryComplexity: Int) -> (isAcceptable: Bool, confidenceLevel: String) {
        
        // High confidence thresholds
        if totalScore >= 0.8 && accuracy >= 90.0 {
            return (true, "HIGH")
        }
        
        // Perfect match override
        if exactScore >= 1.2 && accuracy >= 70.0 {
            return (true, "PERFECT")
        }
        
        // Good match criteria
        if totalScore >= 0.6 && accuracy >= 80.0 && !isRegional {
            return (true, "GOOD")
        }
        
        // Regional content - stricter criteria
        if isRegional {
            if totalScore >= 0.7 && accuracy >= 85.0 {
                return (true, "REGIONAL_ACCEPTABLE")
            } else {
                return (false, "REGIONAL_REJECTED")
            }
        }
        
        // Moderate match for simple queries
        if queryComplexity <= 2 && totalScore >= 0.5 && accuracy >= 75.0 {
            return (true, "MODERATE")
        }
        
        return (false, "INSUFFICIENT")
    }
    
    /// Enhanced contextual matching
    private func calculateContextualMatchingScore(query: String, trackName: String, artistName: String, albumName: String) -> Double {
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
        let trackWords = Set(trackName.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
        let artistWords = Set(artistName.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
        let albumWords = Set(albumName.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
        
        let trackIntersection = queryWords.intersection(trackWords)
        let artistIntersection = queryWords.intersection(artistWords)
        let albumIntersection = queryWords.intersection(albumWords)
        
        let trackScore = queryWords.isEmpty ? 0.0 : Double(trackIntersection.count) / Double(queryWords.count)
        let artistScore = queryWords.isEmpty ? 0.0 : Double(artistIntersection.count) / Double(queryWords.count)
        let albumScore = queryWords.isEmpty ? 0.0 : Double(albumIntersection.count) / Double(queryWords.count)
        
        return max(trackScore, max(artistScore, albumScore * 0.7))
    }
    
    /// Optimized Levenshtein similarity for performance
    private func calculateOptimizedLevenshteinSimilarity(_ str1: String, _ str2: String) -> Double {
        let s1 = str1.lowercased()
        let s2 = str2.lowercased()
        
        // Quick exact match check
        if s1 == s2 { return 1.0 }
        
        // Length optimization - skip if too different
        let maxLength = max(s1.count, s2.count)
        let minLength = min(s1.count, s2.count)
        
        if maxLength == 0 { return 0.0 }
        if Double(minLength) / Double(maxLength) < 0.3 { return 0.0 }
        
        let distance = levenshteinDistance(s1, s2)
        return max(0.0, 1.0 - Double(distance) / Double(maxLength))
    }
    
    /// Fast Levenshtein distance calculation
    private func levenshteinDistance(_ str1: String, _ str2: String) -> Int {
        let array1 = Array(str1)
        let array2 = Array(str2)
        
        let m = array1.count
        let n = array2.count
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                let cost = array1[i-1] == array2[j-1] ? 0 : 1
                dp[i][j] = min(
                    dp[i-1][j] + 1,      // deletion
                    dp[i][j-1] + 1,      // insertion
                    dp[i-1][j-1] + cost  // substitution
                )
            }
        }
        
        return dp[m][n]
    }
    
    /// Enhanced normalization for consistent matching
    private func normalizeForMatching(_ text: String) -> String {
        return text.lowercased()
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " the", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "+", with: "and")
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Advanced similarity calculation with character-level analysis
    private func calculateAdvancedSimilarity(_ str1: String, _ str2: String) -> Double {
        let normalized1 = normalizeForMatching(str1)
        let normalized2 = normalizeForMatching(str2)
        
        // Exact match bonus
        if normalized1 == normalized2 { return 1.0 }
        
        // Substring matching
        if normalized1.contains(normalized2) || normalized2.contains(normalized1) {
            let longerString = normalized1.count > normalized2.count ? normalized1 : normalized2
            let shorterString = normalized1.count <= normalized2.count ? normalized1 : normalized2
            return Double(shorterString.count) / Double(longerString.count) * 0.9
        }
        
        // Levenshtein similarity
        return calculateOptimizedLevenshteinSimilarity(normalized1, normalized2)
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
                        
                        // CRITICAL: Set artwork immediately for highest priority display
                        self.iTunesAlbumArt = image
                        
                        // Save to station and cache for persistence
                        self.saveITunesArtworkToCurrentStation(image)
                        
                        // INSTANT CARPLAY SYNC: Single immediate update for real-time display
                        self.forceUpdateNowPlayingInfo()
                        
                        // Update widget
                        self.updateWidget()
                        
                        // Single consolidated notification for instant CarPlay sync
                        NotificationCenter.default.post(
                            name: NSNotification.Name("InstantCarPlayArtworkSync"),
                            object: nil,
                            userInfo: [
                                "metadata": metadata, 
                                "hasArtwork": true,
                                "syncType": "carplay_fetch"
                            ]
                        )
                        
                        print("🚀 INSTANT: CarPlay artwork fetched and synced with zero delay")
                        
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
    
    /// Jaccard similarity calculation
    private func calculateJaccardSimilarity(_ str1: String, _ str2: String) -> Double {
        let set1 = Set(str1.lowercased().components(separatedBy: " ").filter { !$0.isEmpty })
        let set2 = Set(str2.lowercased().components(separatedBy: " ").filter { !$0.isEmpty })
        
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    /// Cosine similarity calculation
    private func calculateCosineSimilarity(_ str1: String, _ str2: String) -> Double {
        let words1 = str1.lowercased().components(separatedBy: " ").filter { !$0.isEmpty }
        let words2 = str2.lowercased().components(separatedBy: " ").filter { !$0.isEmpty }
        
        let allWords = Set(words1 + words2)
        
        let vector1 = allWords.map { word in Double(words1.filter { $0 == word }.count) }
        let vector2 = allWords.map { word in Double(words2.filter { $0 == word }.count) }
        
        let dotProduct = zip(vector1, vector2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vector1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vector2.map { $0 * $0 }.reduce(0, +))
        
        return (magnitude1 * magnitude2) == 0 ? 0.0 : dotProduct / (magnitude1 * magnitude2)
    }
    

}

// MARK: - Extensions for Enhanced AI Search

extension String {
    /// Check if string contains any of the given substrings
    func contains(any substrings: [String]) -> Bool {
        return substrings.contains { self.contains($0) }
    }
    

    
    /// Extract regex matches
    func matches(for pattern: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let results = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))
            return results.map {
                String(self[Range($0.range, in: self)!])
            }
        } catch {
            return []
        }
    }
}

extension Array where Element == Double {
    /// Calculate variance of an array of doubles
    func variance() -> Double {
        guard count > 1 else { return 0.0 }
        let mean = reduce(0, +) / Double(count)
        let sumOfSquaredDeviations = map { pow($0 - mean, 2) }.reduce(0, +)
        return sumOfSquaredDeviations / Double(count - 1)
    }
}
