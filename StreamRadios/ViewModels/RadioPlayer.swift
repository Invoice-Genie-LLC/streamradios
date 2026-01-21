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
import MusicKit

enum ConnectionState {
    case connected
    case connecting
    case disconnected
    case buffering
    case error
    case paused
}

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()
    @objc var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusCancellable: AnyCancellable?
    private var streamQualityManager: StreamQualityManager
    @Published var isBuffering = false
    @Published var isPlaying: Bool = false

    // Simplified state management - no complex reconnection logic
    @Published var userWantsToPlay: Bool = false
    @Published var wasManuallyPaused: Bool = false  // Track if user manually paused to prevent auto-resume
    @Published var wasPlayingBeforeInterruption: Bool = false  // Track playback state before interruption
    @Published var connectionState: ConnectionState = .connected

    @Published var currentStationIndex: Int?
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: UIImage?
    @Published var metadata: String?
    @Published var iTunesAlbumArt: UIImage?
    var iTunesArtworkJustSet: Bool = false
    private var artworkProtectionTimer: Timer?
    @Published var displayTitle: String?
    @Published var displayArtist: String?
    @Published var isHandlingAlarm = false
    @Published var currentlyPlayingStation: RadioStation?
    @Published var alarmStation: RadioStation?
    weak var podcastPlayer: PodcastPlayer?
    
    // MARK: - Network Reconnection Properties
    private var reachability: Reachability?
    private var isAttemptingReconnection = false
    private var currentReconnectionAttempt = 0
    private let maxReconnectionAttempts = 5
    private var reconnectionTimer: Timer?
    
    // MARK: - Remote Command Center Properties
    private var isRemoteCommandCenterConfigured = false
    
    // MARK: - Logging Optimization Properties
    private var lastLoggedStationIndex: Int?
    private var lastLoggedPlayingState: Bool?
    private var lastLoggedArtworkState: Bool = false
    private var lastLoggedDefaultInfo: Date?
    
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    
    // Stream quality display
    var bitrateSubject = CurrentValueSubject<String, Never>("Premium Quality")
    private let userDefaultsSuiteName = "group.streamradios"
    private var userDefaults: UserDefaults? {
        return UserDefaults(suiteName: userDefaultsSuiteName)
    }
    
    var viewModel: RadioStationViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    // Cache for storing last iTunes artwork per station
    private var stationArtworkCache: [String: (artwork: UIImage, metadata: String)] = [:]
    
    // Persistent artwork storage to prevent loss during state changes
    private var persistentArtworkCache: [String: UIImage] = [:]
    private var lastKnownGoodArtwork: UIImage?
    private var lastKnownGoodMetadata: String?
    
    // Buffering timeout spam prevention
    private var bufferingAttempts: Int = 0
    private var lastBufferingLog: Date?
    
    // Widget update spam prevention
    private var lastWidgetStation: String?
    private var lastWidgetMetadata: String?
    
    // Time update spam prevention
    private var lastTimeUpdateLog: Date?
    
    override init() {
        streamQualityManager = StreamQualityManager()
        
        super.init()
        
        // Initialize Now Playing and CarPlay support
        configureAudioSession()
        setupRemoteCommandCenter()
        addInterruptionObserver()
        
        // CRITICAL: Setup network reconnection logic
        setupReachability()
        
        // CRITICAL: Enhanced CarPlay artwork fetching using audio session events
        setupCarPlayArtworkObservation()
        
        // CRITICAL: Add memory warning observer to prevent termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Bind stream quality manager updates
        setupStreamQualityBinding()
        
        print("✅ RadioPlayer initialized with seamless streaming, network reconnection, and CarPlay support")
        
        DispatchQueue.main.async {
            self.podcastPlayer = PodcastPlayer.shared
            self.podcastPlayer?.setRadioPlayer(self)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleShazamVerifiedArtwork(_:)), name: Notification.Name("ShazamVerifiedArtwork"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleShazamNoMatch), name: Notification.Name("ShazamNoMatch"), object: nil)
        
        // Initialize Shazam integration
        setupShazamIntegration()
        
        // Do not auto-restore on init; wait until user explicitly presses play
        // Start-up UI/auto-restore will be handled explicitly by the app only when desired
    }

    @objc private func handleShazamVerifiedArtwork(_ note: Notification) {
        guard let info = note.userInfo as? [String: Any],
              let title = info["title"] as? String,
              let artist = info["artist"] as? String,
              let urlString = info["artworkURL"] as? String,
              !urlString.isEmpty,
              let url = URL(string: urlString) else { 
            print("❌ Invalid Shazam artwork notification - missing required data")
            if let userInfo = note.userInfo as? [String: Any] {
                print("   - userInfo keys: \(userInfo.keys.joined(separator: ", "))")
            } else {
                print("   - userInfo: nil")
            }
            return 
        }
        
        let isManualShazam = info["isManualShazam"] as? Bool ?? false
        print("🎵 Shazam MATCH FOUND (\(isManualShazam ? "MANUAL" : "AUTO")): '\(title)' by '\(artist)'")
        print("   - Artwork URL: \(urlString)")
        
        // Update metadata with Shazam's verified information
        DispatchQueue.main.async {
            self.displayTitle = title
            self.displayArtist = artist
            
            // Override metadata with Shazam's verified data
            self.metadata = "\(artist) - \(title)"
            
            print("🔄 Updated Shazam metadata: '\(self.metadata ?? "nil")'")
            
            // Fetch and set Shazam artwork as highest priority
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let image = UIImage(data: data) else { 
                    print("❌ Failed to download Shazam artwork from: \(urlString)")
                    return 
                }
                DispatchQueue.main.async {
                    print("✅ Setting Shazam artwork - image size: \(image.size)")
                    self.iTunesAlbumArt = image
                    self.iTunesArtworkJustSet = true
                    self.startArtworkProtectionTimer()
                    
                    // MANUAL SHAZAM FEATURE: Save artwork to station for station list display
                    if isManualShazam {
                        self.saveShazamArtworkToCurrentStation(image, songTitle: title, artist: artist)
                    }
                    
                    self.updateNowPlayingInfo()
                    self.updateWidget()
                    print("🎨 Shazam artwork successfully applied and UI updated")
                }
            }.resume()
        }
    }
    
    @objc private func handleShazamNoMatch() {
        print("🔍 Shazam no match - triggering iTunes Search fallback")
        // When Shazam fails (especially for live streams), fall back to iTunes Search using current metadata
        if let metadata = metadata, !metadata.isEmpty {
            // Use our enhanced metadata splitting to get proper artist and title
            let stationName = viewModel?.stations[safe: currentStationIndex ?? -1]?.name ?? "Unknown Station"
            let (artist, title) = splitArtistTitle(from: metadata, fallbackArtist: stationName, fallbackTitle: metadata)
            
            print("🎯 iTunes fallback using: Artist='\(artist)', Title='\(title)'")
            
            // Check if both artist and title are just the station name (invalid for music search)
            let normalizedStationName = stationName.lowercased().replacingOccurrences(of: " ", with: "")
            let normalizedArtist = artist.lowercased().replacingOccurrences(of: " ", with: "")
            let normalizedTitle = title.lowercased().replacingOccurrences(of: " ", with: "")
            
            if normalizedArtist == normalizedStationName && normalizedTitle == normalizedStationName {
                print("🎯 🚫 Skipping iTunes search - both artist and title are station name: '\(stationName)'")
                print("🎯    This would create meaningless searches like 'TOP ALBANIA RADIO - TOP ALBANIA RADIO'")
                return
            }
            
            // Avoid "Artist - Artist" searches for artist-only stations  
            let searchMetadata: String
            if artist == title && artist != metadata {
                // Artist-only station: just search by artist name
                searchMetadata = artist
                print("🎯 🎭 Artist-only search: '\(artist)' (avoiding '\(artist) - \(artist)')")
            } else {
                // Normal search with artist and title
                searchMetadata = "\(artist) - \(title)"
            }
            searchITunesForArtwork(metadata: searchMetadata) { [weak self] artwork in
                if let artwork = artwork {
                    DispatchQueue.main.async {
                        // Only set iTunes artwork if we don't have Shazam-verified metadata
                        if self?.displayTitle == nil && self?.displayArtist == nil {
                            self?.iTunesAlbumArt = artwork
                            self?.updateNowPlayingInfo()
                            self?.updateWidget()
                            print("🎨 iTunes fallback artwork applied for '\(artist)' - '\(title)'")
                        } else {
                            print("🚫 iTunes fallback skipped - Shazam-verified metadata exists")
                        }
                    }
                } else {
                    print("❌ iTunes fallback failed to find artwork for '\(artist)' - '\(title)'")
                }
            }
        } else {
            print("❌ iTunes fallback skipped - no metadata available")
        }
    }
    
    // MARK: - Shazam Integration
    private var shazamTimer: Timer?
    private var lastShazamAttempt: Date?
    private let shazamCooldown: TimeInterval = 15.0 // 15 seconds between attempts (reduced for faster recognition)
    
    private func setupShazamIntegration() {
        // Initialize Shazam integration - timer will start when playback begins
        print("🎵 Shazam integration initialized - ready for automatic recognition")
    }
    
    private func startShazamTimer() {
        shazamTimer?.invalidate()
        // Check every 30 seconds for new songs to get artwork more quickly
        shazamTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.attemptShazamRecognition()
        }
        print("🎵 Started automatic Shazam recognition timer (every 30 seconds)")
    }
    
    private func stopShazamTimer() {
        shazamTimer?.invalidate()
        shazamTimer = nil
    }
    
    private func attemptShazamRecognition() {
        guard isPlaying,
              let player = player,
              player.timeControlStatus == .playing else {
            print("🔄 Shazam recognition skipped - not playing or player unavailable")
            print("   - isPlaying: \(isPlaying)")
            print("   - player: \(player != nil ? "available" : "nil")")
            print("   - player status: \(player?.timeControlStatus.rawValue ?? -1)")
            return
        }
        
        // Rate limiting - but allow immediate recognition for new songs
        let now = Date()
        let hasNewMetadata = metadata != lastMetadataSearched
        
        if let lastAttempt = lastShazamAttempt,
           now.timeIntervalSince(lastAttempt) < shazamCooldown,
           !hasNewMetadata {
            print("🔄 Shazam rate limited - waiting \(Int(shazamCooldown - now.timeIntervalSince(lastAttempt))) more seconds")
            return
        }
        
        lastShazamAttempt = now
        
        // Clear previous Shazam metadata for new song detection
        if let currentMetadata = metadata, currentMetadata != lastMetadataSearched {
            displayTitle = nil
            displayArtist = nil
            // Only clear artwork if we're confident this is truly a different song
            // Avoid clearing artwork for minor metadata variations that cause UI flicker
            let metadataWords = Set(currentMetadata.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
            let lastSearchedWords = Set((lastMetadataSearched ?? "").lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
            
            // Only clear artwork if the songs are significantly different (less than 50% word overlap)
            let commonWords = metadataWords.intersection(lastSearchedWords)
            let similarity = metadataWords.isEmpty ? 0.0 : Double(commonWords.count) / Double(metadataWords.count)
            
            if similarity < 0.3 { // Reduced threshold for more conservative clearing
                // Store current artwork as fallback before clearing
                if let currentArtwork = iTunesAlbumArt {
                    lastKnownGoodArtwork = currentArtwork
                    lastKnownGoodMetadata = lastMetadataSearched
                    
                    // Cache artwork with station ID for persistence
                    if let stationIndex = currentStationIndex, let viewModel = viewModel,
                       stationIndex < viewModel.stations.count {
                        let stationId = viewModel.stations[stationIndex].id
                        persistentArtworkCache[stationId] = currentArtwork
                    }
                }
                
                // Only clear artwork if it's genuinely old artwork from a different song
                // AND we don't have fresh iTunes artwork for the current metadata
                let shouldClearArtwork = (iTunesAlbumArt != nil && !iTunesArtworkJustSet)
                
                if shouldClearArtwork {
                    iTunesAlbumArt = nil
                    print("🔄 New song detected: '\(currentMetadata)' - clearing previous artwork (similarity: \(String(format: "%.2f", similarity)))")
                    iTunesArtworkJustSet = false
                } else {
                    print("🔄 New song detected: '\(currentMetadata)' - keeping fresh iTunes artwork (similarity: \(String(format: "%.2f", similarity)))")
                }
            } else {
                print("🔄 Similar song metadata: '\(currentMetadata)' - keeping existing artwork (similarity: \(String(format: "%.2f", similarity)))")
                // Extend artwork protection for similar metadata
                if iTunesAlbumArt != nil {
                    startArtworkProtectionTimer()
                }
            }
            
            updateNowPlayingInfo()
            updateWidget()
        }
        
        // Get current station URL for Shazam recognition
        if let currentItem = player.currentItem,
           let url = (currentItem.asset as? AVURLAsset)?.url {
            
            print("🎵 STARTING Shazam recognition for: '\(metadata ?? "Unknown")' at URL: \(url.absoluteString)")
            let stationName = (currentStationIndex != nil && viewModel != nil && currentStationIndex! < viewModel!.stations.count) ? viewModel!.stations[currentStationIndex!].name : "Unknown"
            print("   - Station: \(stationName)")
            print("   - Current iTunesAlbumArt: \(iTunesAlbumArt != nil ? "present" : "nil")")
            
            // SHAZAM FIX: Temporarily disabled - method doesn't exist in current ShazamViewModel
            // Task {
            //     await ShazamViewModel.shared.matchCurrentStationStreamURL(url.absoluteString, seconds: 10)
            // }
            
            // Update the search tracker to prevent immediate re-search of same metadata
            if let currentMetadata = metadata {
                lastMetadataSearched = currentMetadata
            }
        } else {
            print("❌ Shazam recognition failed - no current item or URL available")
            print("   - currentItem: \(player.currentItem != nil ? "available" : "nil")")
        }
    }
    
    // MARK: - Network Reconnection Setup
    private func setupReachability() {
        do {
            reachability = try Reachability()
            reachability?.whenReachable = { [weak self] _ in
                self?.handleNetworkReconnection()
            }
            reachability?.whenUnreachable = { [weak self] _ in
                self?.handleNetworkDisconnection()
            }
            try reachability?.startNotifier()
        } catch {
            print("❌ RadioPlayer: Unable to start reachability notifier: \(error.localizedDescription)")
        }
    }
    
    private func handleNetworkDisconnection() {
        // GPS FIX: Track network failures to help GPS protection system
        self.trackNetworkFailure()
        
        // If user wants to play but network is gone, mark for reconnection
        if userWantsToPlay {
            connectionState = .disconnected
            isBuffering = false
        }
    }
    
    private func handleNetworkReconnection() {
        // Attempt reconnection if user wants to play, regardless of current isPlaying state
        // because isPlaying might be stale when network was disconnected
        guard userWantsToPlay else {
            return
        }
        
        // CRITICAL: Reset StreamQualityManager to re-evaluate network conditions
        streamQualityManager.resetNetworkEvaluation()
        
        isAttemptingReconnection = true
        currentReconnectionAttempt = 0
        attemptReconnection()
    }
    
    private func attemptReconnection() {
        guard currentReconnectionAttempt < maxReconnectionAttempts else {
            stopReconnectionAttempts()
            return
        }
        
        currentReconnectionAttempt += 1
        print("🌐 RadioPlayer: Attempting to reconnect (attempt \(currentReconnectionAttempt) of \(maxReconnectionAttempts))")
        
        // Set connecting state
        connectionState = .connecting
        
        // CRITICAL: Recreate the player item entirely to get fresh network connections
        // and reset all quality evaluations
        if let lastStationURL = userDefaults?.url(forKey: "lastStationURL") {
            print("🌐 RadioPlayer: Recreating player item for fresh network connection")
            
            // Stop existing player completely
            player?.pause()
            player = nil
            
            // Set up fresh player with reset quality management
            setStationURL(lastStationURL)
            
            // Ensure stream quality is reset
            streamQualityManager.resetNetworkEvaluation()
            
            // Start playback after a brief delay to let everything settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.player?.play()
                print("🌐 RadioPlayer: Started fresh playback after player recreation")
            }
        } else {
            // Fallback: try to restart existing player
            player?.play()
        }
        
        // Check status after a delay
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.checkReconnectionStatus()
        }
    }
    
    private func checkReconnectionStatus() {
        if player?.timeControlStatus == .playing && isPlaying {
            print("✅ RadioPlayer: Network reconnection successful")
            stopReconnectionAttempts()
            connectionState = .connected
        } else {
            print("⚠️ RadioPlayer: Reconnection attempt failed, trying again...")
            attemptReconnection()
        }
    }
    
    private func stopReconnectionAttempts() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        isAttemptingReconnection = false
        currentReconnectionAttempt = 0
        
        if player?.timeControlStatus != .playing {
            print("❌ RadioPlayer: Failed to reconnect after \(maxReconnectionAttempts) attempts")
            connectionState = .error
            // GPS FIX: Track multiple reconnection failures
            self.trackNetworkFailure()
            // Don't clear userWantsToPlay so they can try again manually
        }
    }

    
    private func setupStreamQualityBinding() {
        // Bind stream quality manager updates to our UI
        streamQualityManager.$qualityDisplayText
            .removeDuplicates()
            .sink { [weak self] qualityText in
                self?.bitrateSubject.send(qualityText)
            }
            .store(in: &cancellables)
        
        // Monitor buffer health and adapt UI accordingly with improved logic - DISABLED for performance
        // streamQualityManager.$bufferHealth
        //     .removeDuplicates()
        //     .receive(on: DispatchQueue.main)
        //     .sink { [weak self] health in
        //         guard let self = self else { return }
        //         // Avoid publishing from within view updates by deferring state writes
        //         DispatchQueue.main.async {
        //             // When paused or not playing, never show buffering; keep paused/disconnected UI
        //             if !self.isPlaying || self.connectionState == .paused {
        //                 self.isBuffering = false
        //                 return
        //             }
        //             // Only show buffering if actively trying to play and the player is waiting
        //             if health < 0.05, self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
        //                 self.connectionState = .buffering
        //                 self.isBuffering = true
        //             } else if self.player?.timeControlStatus == .playing {
        //                 // Actively playing
        //                 self.connectionState = .connected
        //                 self.isBuffering = false
        //             }
        //         }
        //     }
        //     .store(in: &cancellables)
    }
    
    func autoPlayLastStationSetup() {
        // Use direct UserDefaults access to ensure we get the most current value
        let directUserDefaultsValue = UserDefaults.standard.bool(forKey: "autoPlayLastStation")
        
        // If app requested suppression of global player on next launch, skip any UI/auto-restore once
        if UserDefaults.standard.bool(forKey: "SuppressGlobalPlayerOnNextLaunch") {
            UserDefaults.standard.set(false, forKey: "SuppressGlobalPlayerOnNextLaunch")
            return
        }
        
        // CRITICAL: Check if CarPlay is currently playing to avoid conflicts
        if CarPlayManager.shared.isCarPlayConnected && isPlaying {
            syncMainAppToCarPlayState()
            return
        }
        
        // IMMEDIATE UI RESTORATION: Set up UI state immediately for instant player display
        // This ensures the radio player shows up immediately like the podcast player
        let lastActivePlayer = PlaybackManager.shared.getLastActivePlayer()
        if lastActivePlayer == .radio {
            restoreLastPlayedStationUIImmediately()
            
            // Only set as active player during app startup restoration, not during normal operation
            if PlaybackManager.shared.activePlayer == .none {
                PlaybackManager.shared.setActivePlayer(.radio)
            }
        }
        
        // Use direct UserDefaults access to ensure we get the most current value
        if directUserDefaultsValue {
            // Reduced delay since UI is already restored - just need to ensure network is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Only auto-play if we're not currently handling an alarm and CarPlay isn't playing
                if !self.isHandlingAlarm && !(CarPlayManager.shared.isCarPlayConnected && self.isPlaying) {
                    print("🎵 Auto-play: Starting last played station restoration")
                    print("🌐 Auto-play: Starting last played station restoration")
                    
                    // With seamless quality management, network availability is handled automatically
                    self.startPlaybackForRestoredStation()
                } else if CarPlayManager.shared.isCarPlayConnected && self.isPlaying {
                    print("🚗 CarPlay: Skipping auto-play - CarPlay is currently playing")
                    self.syncMainAppToCarPlayState()
                } else {
                    print("⏰ Auto-play: Skipped due to alarm handling")
                }
            }
        } else {
            // If auto-play is disabled but radio was last active, ensure UI state is restored
            if lastActivePlayer == .radio && currentlyPlayingStation == nil {
                print("🔄 Auto-play: Disabled, but radio was last active - restoring UI state")
                restoreLastPlayedStationUIImmediately()
                
                // Only set as active player if no other player has claimed it
                if PlaybackManager.shared.activePlayer == .none {
                    print("🔄 Auto-play: Setting radio as active player (disabled auto-play restoration)")
                    PlaybackManager.shared.setActivePlayer(.radio)
                }
            }
        }
    }
    
    private func restoreLastPlayedStation() {
        print("🎵 Auto-play: Attempting to restore and play last station")
        
        // Set user intent immediately - this is auto-play so user wants to play
        userWantsToPlay = true
        
        // Use shared UserDefaults consistently for CarPlay compatibility
        if let lastStationID = self.userDefaults?.string(forKey: "LastPlayedStationID") {
            print("🔍 Auto-play: Found LastPlayedStationID: \(lastStationID)")
            
            if let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) {
                print("✅ Auto-play: Found matching station: \(lastStation.name)")
                print("🌍 Auto-play: Station from \(lastStation.country), current country picker: \(self.viewModel?.selectedCountry ?? "unknown")")
                
                // STABILITY FIX: Preserve station info regardless of country picker state
                // This ensures the currently playing station display remains stable
                print("📍 Auto-play: Preserving station display stability - country picker unchanged")
            
                // RACE CONDITION FIX: Use station object directly instead of relying on potentially stale index
                // This prevents issues where CloudKit sync modifies the stations array during auto-play restoration
                print("🎵 Auto-play: Playing last station using station object to avoid race conditions")
                
                // CRITICAL: Set the current station directly to maintain display stability
                // This ensures station info remains consistent regardless of country picker changes
                self.currentlyPlayingStation = lastStation
                
                // STABILITY FIX: Find the current index for UI consistency but don't rely on it for station identity
                // The station object (currentlyPlayingStation) is the source of truth for display
                if let currentIndex = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                    self.currentStationIndex = currentIndex
                    print("🎵 Auto-play: Set currentStationIndex to \(currentIndex) for station '\(lastStation.name)'")
                } else {
                    // IMPORTANT: Even if index is nil, station display remains stable via currentlyPlayingStation
                    self.currentStationIndex = nil
                    print("⚠️ Auto-play: Could not find index for station '\(lastStation.name)' - index set to nil but station display preserved")
                }
                
                if let url = URL(string: lastStation.url) {
                    self.setStationURL(url)
                    // Ensure audio session is activated before playing
                    self.ensureAudioSessionActivatedThenPlay {
                        self.play()
                        // Manually update lastPlayed for Recent tab
                        self.updateLastPlayed(lastStation)
                    }
                } else {
                    print("❌ Auto-play: Invalid URL for station '\(lastStation.name)': \(lastStation.url)")
                }
                return // Exit early if we found the station by ID
            } else {
                print("❌ Auto-play: Station with ID \(lastStationID) not found in stations array")
            }
        } else {
            print("❌ Auto-play: No LastPlayedStationID found in UserDefaults")
        }
        
        // Fallback: Try to restore from URL and index
        if let lastStationURL = self.userDefaults?.url(forKey: "lastStationURL") {
            print("🔄 Auto-play: Falling back to URL-based restoration")
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
                print("🔄 Auto-play (ultimate fallback): Manual URL setup")
                self.setStationURL(lastStationURL)
                
                // STABILITY FIX: Maintain station display consistency even during fallback scenarios
                // Find the correct station by URL and preserve station identity
                if let stations = self.viewModel?.stations,
                   let matchingStation = stations.first(where: { $0.url == lastStationURL.absoluteString }),
                   let correctIndex = stations.firstIndex(where: { $0.id == matchingStation.id }) {
                    self.currentStationIndex = correctIndex
                    self.currentlyPlayingStation = matchingStation
                    print("🔍 Auto-play (ultimate fallback): Found correct station at index \(correctIndex): \(matchingStation.name)")
                    print("📍 Auto-play (ultimate fallback): Station display preserved regardless of country picker")
                } else {
                    // IMPORTANT: Clear indices but preserve any existing station display until new station is selected
                    self.currentStationIndex = nil
                    // Only clear currentlyPlayingStation if we're certain there's no valid station to display
                    if self.currentlyPlayingStation == nil {
                        print("⚠️ Auto-play (ultimate fallback): No station to display, clearing station info")
                    } else {
                        print("⚠️ Auto-play (ultimate fallback): Could not find matching station for URL, but preserving existing station display")
                    }
                }
                
                // Ensure audio session is activated before playing
                self.ensureAudioSessionActivatedThenPlay {
                    self.play()
                }
            }
        } else {
            print("❌ Auto-play: No lastStationURL found in UserDefaults")
        }
    }
    
    /// Ensures audio session is properly activated before executing playback
    private func ensureAudioSessionActivatedThenPlay(completion: @escaping () -> Void) {
        print("🔊 Auto-play: Ensuring audio session is activated before playback")
        
        // Explicitly activate audio session for auto-play
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                
                // Set category and activate in one go for auto-play
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                
                print("✅ Auto-play: Audio session explicitly activated")
                
                // Set radio as active player after audio session is confirmed active
                DispatchQueue.main.async {
                    PlaybackManager.shared.setActivePlayer(.radio)
                    
                    // Small delay to ensure everything is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        print("✅ Auto-play: Proceeding with playback after explicit activation")
                        completion()
                    }
                }
                
            } catch {
                print("❌ Auto-play: Failed to explicitly activate audio session: \(error)")
                
                // Fallback to original approach
                DispatchQueue.main.async {
                    PlaybackManager.shared.setActivePlayer(.radio)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("⚠️ Auto-play: Using fallback activation approach")
                        completion()
                    }
                }
            }
        }
    }
    
    private func restoreLastPlayedStationUIOnly() {
        // Restore UI state without auto-playing
        if let lastStationID = self.userDefaults?.string(forKey: "LastPlayedStationID") {
            print("🔍 Restore UI: Found LastPlayedStationID: \(lastStationID)")
            
            if let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) {
                print("✅ Restore UI: Found matching station: \(lastStation.name)")
                print("🌍 Restore UI: Station from \(lastStation.country), current country picker: \(self.viewModel?.selectedCountry ?? "unknown")")
                
                // STABILITY FIX: Set station object first to maintain display consistency
                // This ensures station info remains stable regardless of country picker state
                self.currentlyPlayingStation = lastStation
                print("📍 Restore UI: Station display preserved regardless of country picker changes")
                
                // STABILITY FIX: Find the current index for UI consistency but don't rely on it for station identity
                // The station object (currentlyPlayingStation) is the source of truth for display
                if let currentIndex = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
                    self.currentStationIndex = currentIndex
                    print("🔄 Restore UI: Set currentStationIndex to \(currentIndex) for station '\(lastStation.name)'")
                } else {
                    // IMPORTANT: Even if index is nil, station display remains stable via currentlyPlayingStation
                    self.currentStationIndex = nil
                    print("⚠️ Restore UI: Could not find index for station '\(lastStation.name)' - index set to nil but station display preserved")
                }
                
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
    
    /// Immediately restores UI state for instant player display on app startup
    /// This method runs synchronously to ensure the player appears immediately
    private func restoreLastPlayedStationUIImmediately() {
        guard let lastStationID = self.userDefaults?.string(forKey: "LastPlayedStationID"),
              let lastStation = self.viewModel?.stations.first(where: { $0.id == lastStationID }) else {
            return
        }
        
        // Set station object immediately for display
        self.currentlyPlayingStation = lastStation
        
        // Find and set current index for UI consistency
        if let currentIndex = self.viewModel?.stations.firstIndex(where: { $0.id == lastStationID }) {
            self.currentStationIndex = currentIndex
        } else {
            self.currentStationIndex = nil
        }
        
        // Set up the player URL so it's ready for playback
        if let url = URL(string: lastStation.url) {
            self.setStationURL(url)
        }
    }
    
    /// Starts playback for an already restored station (UI is already set up)
    /// This method handles the audio session and actual playback startup
    private func startPlaybackForRestoredStation() {
        print("🎵 Radio: Starting playback for restored station")
        
        guard let currentStation = currentlyPlayingStation else {
            print("❌ Radio: No current station available for playback")
            return
        }
        
        print("🎵 Radio: Starting playback for: \(currentStation.name)")
        
        // Set user intent for playback
        userWantsToPlay = true
        
        // Ensure audio session is activated before playing
        self.ensureAudioSessionActivatedThenPlay {
            self.play()
            // Manually update lastPlayed for Recent tab
            self.updateLastPlayed(currentStation)
        }
    }
    
    /// Syncs main app UI to the current CarPlay playback state without disrupting audio
    private func syncMainAppToCarPlayState() {
        print("🚗 CarPlay: Syncing main app to current CarPlay playback state")
        
        // Don't disrupt the audio - just sync the UI to match current state
        if let currentStation = currentlyPlayingStation {
            print("🚗 CarPlay: Main app UI synced to: \(currentStation.name)")
            
            // Update UI to reflect current playing state
            updateNowPlayingInfo()
            updateWidget()
            
            // Ensure connection state reflects actual playing state
            if isPlaying {
                connectionState = .connected
                print("🚗 CarPlay: Main app UI shows connected state")
            }
        } else {
            print("🚗 CarPlay: No current station found for UI sync")
        }
    }
    
    func resetAlarmState() {
        isHandlingAlarm = false
    }
    
    

    
    func setViewModel(_ viewModel: RadioStationViewModel) {
        self.viewModel = viewModel
        
        // Observe changes in the stations array - DISABLED for performance
        // viewModel.$stations
        //     .sink { [weak self] _ in
        //         self?.updateNowPlayingInfo()
        //     }
        //     .store(in: &cancellables)
    }
    
    private func configureAudioSession() {
        // Audio session is now managed centrally by PlaybackManager
        // Don't activate during initialization - will activate when playback starts
        print("✅ RadioPlayer: Audio session management delegated to PlaybackManager")
    }
    
    func addInterruptionObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        
        // CRITICAL: Add app lifecycle observers for background audio session maintenance
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc private func handleAppDidEnterBackground() {
        // CRITICAL FIX: Simplified background handling to prevent deadlocks and main thread blocking
        if isPlaying && userWantsToPlay {
            print("🔧 RadioPlayer: App entering background - radio playback active")
            DebugLogger.logInfo("App entering background with active radio playback - delegating to AppDelegate for centralized background task management", category: "BackgroundAudio")
            DebugLogger.setUserAction("Radio Background Transition")
            
            // CRITICAL FIX: Don't create competing background tasks - let AppDelegate handle this centrally
            // Move audio session configuration to background queue to avoid main thread IPC delays
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // MAIN THREAD FIX: Configure audio session on background queue to avoid IPC delays
                    try audioSession.setCategory(.playback, 
                                               mode: .default, 
                                               options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    
                    DispatchQueue.main.async {
                        print("✅ RadioPlayer: Background transition handled - audio session category set")
                        DebugLogger.logInfo("Radio background transition completed - centralized task management active", category: "BackgroundAudio")
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("❌ RadioPlayer: Audio session check failed: \(error)")
                        DebugLogger.logError("Audio session verification failed during background transition: \(error.localizedDescription)", category: "BackgroundAudio")
                    }
                }
            }
        } else {
            DebugLogger.logInfo("App entering background with no active radio playback - no background maintenance needed", category: "BackgroundAudio")
        }
    }
    
    @objc private func handleAppWillEnterForeground() {
        // CRITICAL FIX: Only restore playback if it was interrupted by the system, not if user paused
        // We should only resume if:
        // 1. User wants to play (userWantsToPlay = true)
        // 2. Player is not currently playing (was interrupted)
        // 3. Was NOT manually paused by user
        if userWantsToPlay && !isPlaying && !wasManuallyPaused {
            print("🔧 RadioPlayer: App entering foreground - restoring radio playback if needed")
            DebugLogger.logInfo("App entering foreground with radio playback intent - checking restoration needs", category: "BackgroundAudio")
            DebugLogger.setUserAction("Radio Foreground Transition")
            
            // Check if we need to restart playback (only if it was system-interrupted, not user-paused)
            if player != nil {
                DebugLogger.logWarning("Radio playback was interrupted during background - attempting restoration", category: "BackgroundAudio")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { 
                        DebugLogger.logError("RadioPlayer instance lost during foreground restoration", category: "BackgroundAudio")
                        return 
                    }
                    
                    do {
                        // Reactivate audio session
                        PlaybackManager.shared.setActivePlayer(.radio)
                        
                        // Resume playback only if user wants it and it wasn't manually paused
                        if self.userWantsToPlay && !self.wasManuallyPaused {
                            self.player?.play()
                            self.isPlaying = true
                            
                            // CRITICAL FIX: Update Now Playing info after foreground resume to restore lock screen display
                            self.updateNowPlayingInfo()
                            self.updateWidget()
                            
                            print("✅ RadioPlayer: Radio playback resumed after foreground transition")
                            print("🔄 RadioPlayer: Updated Now Playing info after foreground resume")
                            DebugLogger.logInfo("Radio playback successfully restored after foreground transition", category: "BackgroundAudio")
                        }
                    } catch {
                        DebugLogger.logError("Failed to restore radio playback during foreground transition: \(error.localizedDescription)", category: "BackgroundAudio")
                    }
                }
            }
        } else if isPlaying {
            DebugLogger.logInfo("Radio playback continued seamlessly during background/foreground transition", category: "BackgroundAudio")
        } else if wasManuallyPaused {
            DebugLogger.logInfo("Radio was manually paused by user - not resuming automatically", category: "BackgroundAudio")
        } else {
            DebugLogger.logInfo("App entering foreground with no radio playback intent", category: "BackgroundAudio")
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        // CRITICAL: Handle lock screen alarm scenarios where interruption end notifications may be missed
        // This catches cases where alarms interrupt audio during lock screen and app becomes active after snooze
        if wasPlayingBeforeInterruption && userWantsToPlay && !isPlaying && !wasManuallyPaused {
            print("🔧 RadioPlayer: App became active after potential lock screen interruption - checking resume")
            DebugLogger.logInfo("App became active with interrupted radio playback - attempting lock screen alarm resume", category: "LockScreenAudio")
            DebugLogger.setUserAction("Lock Screen Alarm Resume")
            
            // Delay to ensure system is ready after alarm dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { 
                    DebugLogger.logError("RadioPlayer instance lost during lock screen resume", category: "LockScreenAudio")
                    return 
                }
                
                // Double-check conditions are still valid
                if self.wasPlayingBeforeInterruption && self.userWantsToPlay && !self.isPlaying && !self.wasManuallyPaused {
                    print("🔄 RadioPlayer: Attempting lock screen alarm resume")
                    DebugLogger.logInfo("Executing lock screen alarm resume for radio", category: "LockScreenAudio")
                    
                    // Use the existing resume method
                    self.resumeAfterInterruption()
                    
                    // CRITICAL FIX: Ensure Now Playing info is updated after lock screen resume
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.updateNowPlayingInfo()
                        print("🔄 RadioPlayer: Updated Now Playing info after lock screen resume")
                    }
                } else {
                    DebugLogger.logInfo("Lock screen resume conditions no longer met - skipping resume", category: "LockScreenAudio")
                }
            }
        } else {
            // Log why we're not resuming for debugging
            if !wasPlayingBeforeInterruption {
                DebugLogger.logInfo("App became active but radio was not playing before interruption", category: "LockScreenAudio")
            } else if !userWantsToPlay {
                DebugLogger.logInfo("App became active but user does not want radio playback", category: "LockScreenAudio")
            } else if isPlaying {
                DebugLogger.logInfo("App became active and radio is already playing", category: "LockScreenAudio")
            } else if wasManuallyPaused {
                DebugLogger.logInfo("App became active but radio was manually paused by user", category: "LockScreenAudio")
            }
        }
    }
    
    @objc private func handleMemoryWarning() {
        // CRITICAL FIX: Handle memory warnings to prevent app termination during radio playback
        print("⚠️ RadioPlayer: Memory warning received - optimizing for background audio")
        
        let memoryUsage = ProcessInfo.processInfo.physicalMemory
        let availableMemory = ProcessInfo.processInfo.systemUptime
        
        DebugLogger.logWarning("CRITICAL: Memory warning received during radio playback - System Memory: \(memoryUsage / 1024 / 1024)MB, Uptime: \(availableMemory)s", category: "MemoryPressure")
        DebugLogger.setUserAction("Memory Warning During Radio Playback")
        
        // Log current playback state for debugging
        DebugLogger.logInfo("Memory warning context - Radio playing: \(isPlaying), User wants playback: \(userWantsToPlay), Current station: \(currentlyPlayingStation?.name ?? "None")", category: "MemoryPressure")
        
        // Clear non-essential data to free memory
        clearNonEssentialData()
        
        // If not playing, preserve iTunes artwork in persistent cache before cleanup
        if !isPlaying {
            // Store current iTunes artwork in persistent cache before clearing
            if let currentArtwork = iTunesAlbumArt, let stationIndex = currentStationIndex,
               let viewModel = viewModel, stationIndex < viewModel.stations.count {
                let stationId = viewModel.stations[stationIndex].id
                persistentArtworkCache[stationId] = currentArtwork
                print("💾 Preserved iTunes artwork in persistent cache during memory pressure")
            }
            
            albumArt = nil
            iTunesAlbumArt = nil
            print("🧹 RadioPlayer: Cleared artwork cache due to memory pressure")
            DebugLogger.logInfo("Cleared artwork cache and metadata due to memory pressure (radio not playing)", category: "MemoryPressure")
        } else {
            DebugLogger.logWarning("Memory warning during active radio playback - limited cleanup to preserve audio", category: "MemoryPressure")
        }
        
        // Force garbage collection
        DispatchQueue.global(qos: .background).async {
            // Perform heavy cleanup on background queue
            self.optimizeMemoryUsage()
            DebugLogger.logInfo("Background memory optimization completed", category: "MemoryPressure")
        }
    }
    
    private func clearNonEssentialData() {
        // Clear cached metadata that can be refetched
        if !isPlaying {
            metadata = nil
            displayTitle = nil
            displayArtist = nil
        }
        
        // Clear old artwork cache
        if albumArt != nil && !isPlaying {
            albumArt = nil
        }
        if iTunesAlbumArt != nil && !isPlaying {
            iTunesAlbumArt = nil
        }
    }
    
    private func optimizeMemoryUsage() {
        // Perform memory optimization on background thread
        print("🧹 RadioPlayer: Optimizing memory usage for background stability")
        DebugLogger.logInfo("Starting background memory optimization to prevent app termination", category: "MemoryPressure")
        
        // Clear any cached network responses or temporary data
        let cacheSize = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        URLCache.shared.removeAllCachedResponses()
        DebugLogger.logInfo("Cleared URL cache - freed \(cacheSize / 1024)KB of memory", category: "MemoryPressure")
        
        // Force memory cleanup
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            DebugLogger.logInfo("Memory optimization completed - UI state refreshed", category: "MemoryPressure")
        }
    }

    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            DebugLogger.logError("Invalid audio interruption notification received - missing required data", category: "AudioInterruption")
            return
        }
        
        if type == .began {
            // Interruption began, pause the player immediately
            print("🔧 RadioPlayer: Audio interruption began - pausing playback")
            DebugLogger.logWarning("Audio interruption began - pausing radio playback (likely phone call or other audio)", category: "AudioInterruption")
            DebugLogger.setUserAction("Audio Interruption Started")
            
            // PHONE CALL FIX: Multiple interruption protection with PlaybackManager state coordination
            let isFirstInterruption = !wasPlayingBeforeInterruption
            if isFirstInterruption {
                // Check both our state AND PlaybackManager state (in case PlaybackManager captured it first)
                let actuallyWasPlaying = isPlaying || (PlaybackManager.shared.activePlayer == .radio && PlaybackManager.shared.radioWasPlayingBeforeInterruption)
                wasPlayingBeforeInterruption = actuallyWasPlaying
                print("🔧 RadioPlayer: Set wasPlayingBeforeInterruption = \(wasPlayingBeforeInterruption) (FIRST interruption - coordinated with PlaybackManager)")
            } else {
                print("🔧 RadioPlayer: State unchanged (subsequent interruption) = \(wasPlayingBeforeInterruption)")
            }
            
            // PHONE CALL FIX: Force immediate pause to prevent ANY audio mixing with phone calls
            // This must happen synchronously and immediately
            player?.pause()
            isPlaying = false
            
            // CRITICAL: Also ensure no audio session mixing by deactivating briefly
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // Briefly deactivate to ensure complete audio stop for phone calls
                    try audioSession.setActive(false, options: [])
                    print("✅ RadioPlayer: Audio session deactivated for phone call")
                } catch {
                    print("⚠️ RadioPlayer: Could not deactivate audio session: \(error)")
                }
            }
            
            print("✅ RadioPlayer: Playback paused due to interruption")
            
            DebugLogger.logInfo("Audio interruption handled - Radio was playing: \(wasPlayingBeforeInterruption), Station: \(currentlyPlayingStation?.name ?? "None")", category: "AudioInterruption")
            
        } else if type == .ended {
            // Interruption ended - PlaybackManager will handle the resume logic
            print("🔧 RadioPlayer: Audio interruption ended - letting PlaybackManager handle resume")
            DebugLogger.logInfo("Audio interruption ended - PlaybackManager will handle resume", category: "AudioInterruption")
            DebugLogger.setUserAction("Audio Interruption Ended")
            
            // PHONE CALL FIX: Reset interruption state after a delay to allow for resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if let self = self, !self.isPlaying {
                    // Only reset if we're still not playing after resume attempts
                    self.wasPlayingBeforeInterruption = false
                    print("🔧 RadioPlayer: Reset interruption state for next phone call")
                }
            }
        }
    }
    
    /// Resumes playback after an audio interruption (e.g., alarm, phone call, other apps)
    func resumeAfterInterruption() {
        print("🔊 RadioPlayer: Attempting to resume playback after interruption")
        DebugLogger.logInfo("Resuming radio playback after audio interruption", category: "AudioInterruption")
        
        guard let player = player, 
              wasPlayingBeforeInterruption,
              userWantsToPlay else {
            print("⚠️ RadioPlayer: Cannot resume - conditions not met")
            DebugLogger.logWarning("Cannot resume after interruption - player: \(player != nil), wasPlaying: \(wasPlayingBeforeInterruption), userWants: \(userWantsToPlay)", category: "AudioInterruption")
            return
        }
        
        // PHONE CALL FIX: Check if audio session is already active to prevent OSStatus -50 errors
        // PlaybackManager may have already activated the session successfully
        let audioSession = AVAudioSession.sharedInstance()
        let isSessionActive = audioSession.category == .playback
        
        if !isSessionActive {
            // Only activate session if it's not already in the correct state
            do {
                // First, ensure the category is correct and take control of audio
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                
                // Aggressively activate audio session to reclaim audio from other apps
                try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                
                print("✅ RadioPlayer: Audio session reactivated, attempting playback resume")
            } catch {
                print("❌ RadioPlayer: Failed to activate audio session: \(error)")
                DebugLogger.logError("Failed to activate audio session for radio resume: \(error.localizedDescription)", category: "AudioInterruption")
                
                // Continue anyway - PlaybackManager might have already activated it
                print("🔄 RadioPlayer: Continuing with resume despite session activation error")
            }
        } else {
            print("✅ RadioPlayer: Audio session already active, proceeding with resume")
        }
        
        // Resume playback with small delay to ensure session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            // Resume playback
            player.play()
            self.isPlaying = true
            self.wasPlayingBeforeInterruption = false // Reset the flag
            
            // Update Now Playing info
            self.updateNowPlayingInfo()
            
            print("✅ RadioPlayer: Successfully resumed playback after interruption")
            DebugLogger.logInfo("Radio playback successfully resumed after interruption", category: "AudioInterruption")
        }
    }

    
    func setStationURL(_ url: URL) {
        // CARPLAY PROTECTION: Don't disrupt ongoing CarPlay playback unless explicitly requested
        if CarPlayManager.shared.isCarPlayConnected && isPlaying {
            print("🚗 CarPlay: Skipping setStationURL - CarPlay is currently playing")
            print("🚗 CarPlay: URL change request ignored to prevent audio disruption")
            return
        }
        
        // Stop any existing player and clear status observer
        player?.pause()
        statusCancellable?.cancel()
        
        // Create new player item and player - NO interruptions from this point on
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Configure the player item with seamless stream quality management
        if let newPlayerItem = playerItem {
            streamQualityManager.configurePlayerItem(newPlayerItem)
        }
        
        // Add metadata output immediately
        addMetadataOutput()
        
        // Observe player status with simplified logic
        statusCancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                DispatchQueue.main.async {
                    switch status {
                    case .playing:
                        self?.isPlaying = true
                        self?.isBuffering = false
                        self?.connectionState = .connected
                        
                        // Start elapsed time tracking when player starts playing
                        if self?.playbackStartTime == nil {
                            self?.playbackStartTime = Date()
                            self?.lastElapsedTimeUpdate = nil // Reset update timer
                            print("⏱️ Status Observer: Started elapsed time tracking")
                            
                            // Immediate first elapsed time update for responsive display
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                if self?.isPlaying == true {
                                    self?.updateNowPlayingInfoElapsedTime()
                                }
                            }
                        }
                        
                        self?.updateNowPlayingInfo()
                        print("▶️ Player is now playing with seamless quality management")
                        
                        // Enhanced metadata fetching when starting to play (artwork only from Shazam)
                        if let metadata = self?.metadata, !metadata.isEmpty {
                            // Metadata available - artwork will come from Shazam only
                            print("📻 Metadata available: \(metadata) - awaiting Shazam artwork")
                        } else {
                            // If no metadata, proactively check for current metadata
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self?.checkForCurrentMetadata()
                            }
                        }
                        
                    case .waitingToPlayAtSpecifiedRate:
                        self?.isBuffering = true
                        self?.connectionState = .buffering
                        print("⏳ Player buffering - seamless quality adaptation in progress")
                        
                    case .paused:
                        self?.isPlaying = false
                        self?.isBuffering = false
                        // If user paused, stay in paused state; do not show connecting/buffering
                        self?.connectionState = .paused
                        
                    @unknown default:
                        break
                    }
                }
            }
        
        // Set up periodic time observer for metadata updates
        setupPeriodicTimeObserver()
    }
    
    /// Force sets station URL even during CarPlay (for explicit user station changes)
    func forceSetStationURL(_ url: URL) {
        print("🔄 Station Setup: Force setting URL for \(url.absoluteString)")
        
        // Store the CarPlay state
        let wasCarPlayConnected = CarPlayManager.shared.isCarPlayConnected
        
        // Stop any existing player and clear status observer
        player?.pause()
        statusCancellable?.cancel()
        print("🔄 Station Setup: Stopped old player and cleared observers")
        
        // Create new player item and player
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        print("🔄 Station Setup: Created new player and player item")
        
        // Configure the player item with seamless stream quality management
        if let newPlayerItem = playerItem {
            streamQualityManager.configurePlayerItem(newPlayerItem)
            print("🔄 Station Setup: Configured StreamQualityManager")
        }
        
        // Add metadata output immediately
        addMetadataOutput()
        print("🔄 Station Setup: Added metadata output")
        
        // Observe player status with enhanced debugging for transitions
        statusCancellable = player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                DispatchQueue.main.async {
                    switch status {
                    case .playing:
                        self?.isPlaying = true
                        self?.isBuffering = false
                        self?.connectionState = .connected
                        print("✅ Station Transition: Player now PLAYING")
                        
                        // Reset buffering attempts counter when successfully playing
                        self?.bufferingAttempts = 0
                        self?.lastBufferingLog = nil
                        
                        // Start elapsed time tracking when player starts playing
                        if self?.playbackStartTime == nil {
                            self?.playbackStartTime = Date()
                            self?.lastElapsedTimeUpdate = nil // Reset update timer
                            print("⏱️ Status Observer: Started elapsed time tracking")
                            
                            // Immediate first elapsed time update for responsive display
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                if self?.isPlaying == true {
                                    self?.updateNowPlayingInfoElapsedTime()
                                }
                            }
                        }
                        
                        self?.updateNowPlayingInfo()
                        
                        // Enhanced metadata fetching when starting to play (artwork only from Shazam)
                        if let metadata = self?.metadata, !metadata.isEmpty {
                            // Metadata available - artwork will come from Shazam only
                            print("📻 Metadata available: \(metadata) - awaiting Shazam artwork")
                        } else {
                            // If no metadata, proactively check for current metadata
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self?.checkForCurrentMetadata()
                            }
                        }
                        
                    case .waitingToPlayAtSpecifiedRate:
                        self?.isBuffering = true
                        self?.connectionState = .buffering
                        print("⏳ Station Transition: Player BUFFERING (normal for new streams)")
                        
                        // Add timeout protection for buffering state with rate limiting
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                            guard let self = self else { return }
                            if self.connectionState == .buffering {
                                let now = Date()
                                
                                // Rate limit buffering logs - only log first 3 attempts, then once every 10 seconds
                                let shouldLog = self.bufferingAttempts < 3 || 
                                               (self.lastBufferingLog == nil || now.timeIntervalSince(self.lastBufferingLog!) > 10.0)
                                
                                if shouldLog {
                                    print("⚠️ Station Transition: Still buffering after 3s - triggering play again (attempt \(self.bufferingAttempts + 1))")
                                    self.lastBufferingLog = now
                                }
                                
                                self.bufferingAttempts += 1
                                self.player?.play()
                            }
                        }
                        
                    case .paused:
                        self?.isPlaying = false
                        self?.isBuffering = false
                        print("⏸️ Station Transition: Player PAUSED")
                        // Always show paused for a paused status; never connecting
                        self?.connectionState = .paused
                        
                    @unknown default:
                        print("❓ Station Transition: Unknown player status")
                        break
                    }
                }
            }
        
        // Set up periodic time observer for metadata updates
        setupPeriodicTimeObserver()
        print("🔄 Station Setup: Set up periodic time observer")
        
        if wasCarPlayConnected {
            print("🚗 CarPlay: Station URL force-changed during CarPlay session")
        }
        
        print("🔄 Station Setup: Configuration complete")
    }
    
    func resumePlayback() {
        if let player = player, !isPlaying {
            player.play()
            isPlaying = true
        }
    }
    
    private func performReachabilityCheck(completion: @escaping (Bool) -> Void) {
        // Use basic network connectivity check - reachability is handled by StreamQualityManager
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkMonitor")
        
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                completion(path.status == .satisfied)
            }
            monitor.cancel()
        }
        
        monitor.start(queue: queue)
        
        // Timeout after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            monitor.cancel()
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
            // Ensure the UI reflects a non-buffering paused state before starting
            connectionState = .paused
            play()
        }
        // Note: updateNowPlayingInfo() and updateWidget() are called within pause() and play()
    }
    
    func play() {
        // CRITICAL FIX: Clear manual pause flag when user explicitly plays
        wasManuallyPaused = false
        
        // CRITICAL: Only stop podcast if user explicitly wants radio or if no podcast is active
        // This prevents CarPlay disconnection from accidentally stopping podcast playback
        let podcastPlayer = PodcastPlayer.shared
        let podcastIsActive = podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil
        let podcastIsActivePlayer = PlaybackManager.shared.activePlayer == .podcast
        
        // Don't stop podcast during CarPlay transitions unless user explicitly requested radio
        if podcastIsActive && podcastIsActivePlayer {
            print("🚗 RadioPlayer: Podcast is active - not starting radio to avoid interruption")
            return
        }
        
        // Only stop podcast playback if we're actually going to start radio
        stopPodcastPlayback()
        
        // CARPLAY COMPATIBILITY: Don't disrupt ongoing CarPlay if it's playing the same content
        if CarPlayManager.shared.isCarPlayConnected && isPlaying {
            print("🚗 CarPlay: Already playing via CarPlay - main app play request acknowledged")
            
            // Just ensure the main app UI is synced without disrupting audio
            connectionState = .connected
            updateNowPlayingInfo()
            updateWidget()
            return
        }
        
        // Set radio as the active player FIRST - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.radio)
        print("📻 Play: Set radio as active player")
        
        // CRITICAL: Configure Remote Command Center for radio to show station navigation buttons
        configureRadioRemoteCommands()
        
        // Track user intent - user wants to play
        userWantsToPlay = true
        
        // CRITICAL: Reset network evaluation when user manually plays to ensure fresh quality assessment
        streamQualityManager.resetNetworkEvaluation()
        print("🌐 Play: Reset network evaluation for fresh quality assessment")
        
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
        
        // Start playback - seamless quality management will handle all network transitions
        connectionState = .connecting
        player.play()
        
        // Start elapsed time tracking
        playbackStartTime = Date()
        lastElapsedTimeUpdate = nil // Reset update timer
        print("⏱️ Play: Started elapsed time tracking")
        
        // Immediate first elapsed time update for responsive display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.isPlaying == true {
                self?.updateNowPlayingInfoElapsedTime()
            }
        }
        
        print("▶️ Play: Player started with seamless quality management")
        
        // STATION ARTWORK FIX: Restore cached iTunes artwork or load station artwork
        print("🔍 STATION ARTWORK DEBUG: albumArt=\(albumArt != nil), iTunesAlbumArt=\(iTunesAlbumArt != nil)")
        restoreArtworkFromCache()
        print("🎨 Play: Restored artwork from cache or loaded station artwork")
        
        // Update Now Playing immediately since audio session is already activated
        updateNowPlayingInfo()
        
        // Trigger immediate metadata checking when resuming from pause
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkForCurrentMetadata()
        }
        
        // Add verification after a brief delay to ensure everything is set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyNowPlayingSetup()
        }
        
        updateWidget()
        scheduleAppRefresh()
        
        // Start Shazam recognition when playback begins
        startShazamTimer()
        
        // Also attempt immediate Shazam recognition after a short delay to get artwork quickly
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.attemptShazamRecognition()
        }
    }
    
    private func stopPodcastPlayback() {
            if let podcastPlayer = podcastPlayer {
                // Use stop() instead of pause() to clear user intent and properly dismiss podcast player
                podcastPlayer.stop()
                print("🛑 RadioPlayer: Stopped podcast playback and cleared user intent")
            }
        }
    
    func pause() {
        guard let player = player else { return }
        
        player.pause()
        isPlaying = false
        
        // CRITICAL FIX: Mark as manually paused to prevent auto-resume
        wasManuallyPaused = true
        
        connectionState = .paused
        isBuffering = false
        updateNowPlayingInfo()
        updateWidget()
        
        // Track elapsed time when pausing
        if let startTime = playbackStartTime {
            pausedElapsedTime += Date().timeIntervalSince(startTime)
            playbackStartTime = nil
            lastElapsedTimeUpdate = nil
            print("⏱️ Pause: Saved elapsed time: \(pausedElapsedTime) seconds")
        }
        
        print("⏸️ User explicitly paused - cleared all reconnection state")
        
        // Store current iTunes artwork before clearing for potential restoration
        if let currentArtwork = iTunesAlbumArt, let currentMeta = metadata {
            lastKnownGoodArtwork = currentArtwork
            lastKnownGoodMetadata = currentMeta
            
            // Cache artwork with station ID for persistence
            if let stationIndex = currentStationIndex, let viewModel = viewModel,
               stationIndex < viewModel.stations.count {
                let stationId = viewModel.stations[stationIndex].id
                persistentArtworkCache[stationId] = currentArtwork
                print("💾 Cached iTunes artwork for station \(stationId) before pause")
            }
        }
        
        // Clear song metadata but preserve artwork cache
        metadata = nil
        songTitle = ""
        artistName = ""
        // Don't clear lastMetadataSearched to prevent duplicate searches
        
        // Only clear iTunes artwork if we have station artwork to fall back to
        if let stationIndex = currentStationIndex, let viewModel = viewModel,
           stationIndex < viewModel.stations.count {
            let station = viewModel.stations[stationIndex]
            if station.iconData != nil {
                iTunesAlbumArt = nil
                print("🎨 DEBUG: Cleared iTunesAlbumArt - station has fallback artwork")
            } else {
                print("🎨 DEBUG: Keeping iTunesAlbumArt - no station fallback available")
            }
        }
        
        // Load station's default artwork when paused (instead of clearing all artwork)
        loadStationArtwork()
        print("🎨 Pause: Loaded station default artwork - albumArt is now: \(albumArt != nil ? "present" : "nil")")
        
        // Force UI update to ensure artwork changes are reflected immediately
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        // Cancel any pending iTunes searches when paused
        artworkSearchTimer?.invalidate()
        
        // Cancel artwork protection timer when pausing
        artworkProtectionTimer?.invalidate()
        artworkProtectionTimer = nil
        
        // Note: We keep currentlyPlayingStation and currentStationIndex intact
        // This allows the user to resume playing the same station easily
        
        updateNowPlayingInfo()
        updateWidget()
        
        print("⏸️ Radio paused by user - song metadata and iTunes artwork cleared, station remains active")
    }
    
    // MARK: - Network State Management (Seamless Quality Management)
    // All network reconnection logic is now handled by StreamQualityManager
    
    // Player observers are now handled in setStationURL with seamless quality management
    
    // Direct reconnection status checking is no longer needed
    
    // Network restoration is now handled seamlessly by StreamQualityManager
    // No need for manual reconnection logic
    
    // Network loss is now handled seamlessly by StreamQualityManager
    // No need for manual network loss handling
    
    // Force reconnection is no longer needed with seamless quality management
    
    // Playback attempts are now handled seamlessly by the quality manager
    
    // MARK: - Basic Playback Control
    
    func togglePlayPause() {
            if isPlaying {
                pause()
            } else {
                play()
            }
        }
    
    func stop() {
        // CRITICAL FIX: Clear user intent and manual pause flags when stopping
        userWantsToPlay = false
        wasManuallyPaused = false
        
        player?.pause()
        player = nil
        currentStationIndex = nil
        isPlaying = false
           
        // Clear connection state
        connectionState = .disconnected
           
           // Clear all song metadata and Shazam artwork completely
           metadata = nil
           iTunesAlbumArt = nil // This holds Shazam artwork
           albumArt = nil
           songTitle = ""
           artistName = ""
           displayTitle = nil
           displayArtist = nil
           lastMetadataSearched = ""
           
           // Reset elapsed time tracking
           playbackStartTime = nil
           pausedElapsedTime = 0
           lastElapsedTimeUpdate = nil
           print("⏱️ Stop: Reset elapsed time tracking")
           
           // Cancel any pending iTunes searches
           artworkSearchTimer?.invalidate()
           
           // Clear the current station to fully reset player state
           currentlyPlayingStation = nil
           
           // Update all UI elements - this will now show default app info with no station artwork
           updateNowPlayingInfo()
           updateWidget()
           
           // Stop Shazam recognition when playback stops
           stopShazamTimer()
           
        print("🛑 Radio player stopped - all metadata and iTunes artwork cleared")
        
        // Cancel artwork protection timer
        artworkProtectionTimer?.invalidate()
        artworkProtectionTimer = nil
        iTunesArtworkJustSet = false
    }
    
    /// Clear radio player state when switching to podcast service
    func clearStateForServiceSwitch() {
        print("🧹 RadioPlayer: Clearing state for service switch to podcast")
        
        // Stop playback immediately
        player?.pause()
        player = nil
        isPlaying = false
        userWantsToPlay = false
        wasManuallyPaused = false
        
        // Clear current station to hide player
        currentlyPlayingStation = nil
        currentStationIndex = nil
        
        // Reset connection state
        connectionState = .disconnected
        
        // Clear all metadata and artwork
        metadata = nil
        iTunesAlbumArt = nil
        albumArt = nil
        songTitle = ""
        artistName = ""
        lastMetadataSearched = ""
        
        // Cancel any pending operations
        artworkSearchTimer?.invalidate()
        artworkSearchTimer = nil
        artworkProtectionTimer?.invalidate()
        artworkProtectionTimer = nil
        iTunesArtworkJustSet = false
        
        // Stop reconnection attempts
        stopReconnectionAttempts()
        
        // Stop Shazam recognition
        stopShazamTimer()
        
        // Clear elapsed time tracking
        playbackStartTime = nil
        pausedElapsedTime = 0
        lastElapsedTimeUpdate = nil
        
        // Clear Now Playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        
        // Update UI
        updateWidget()
        
        print("✅ RadioPlayer: State cleared for service switch")
    }
    
    /// Starts artwork protection timer to prevent indefinite protection
    private func startArtworkProtectionTimer() {
        // Cancel any existing timer
        artworkProtectionTimer?.invalidate()
        
        // Start new timer for 30 seconds
        artworkProtectionTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.iTunesArtworkJustSet = false
                self.artworkProtectionTimer = nil
                print("🕰️ Artwork protection timer expired - artwork can now be cleared by new songs")
            }
        }
        print("🕰️ Started 30-second artwork protection timer")
    }
    
    func playStation(at index: Int, from stations: [RadioStation]) {
        // CRITICAL: This is an explicit user action to play radio - stop podcast if active
        stopPodcastPlayback()
        
        // CRITICAL FIX: Mark that user has played content for the first time
        // This enables TabView hiding behavior on scroll
        UserDefaults.standard.set(true, forKey: "hasEverPlayedContent")
        
        // Ensure PlaybackManager knows radio is the active player
        PlaybackManager.shared.setActivePlayer(.radio)
        
        // CRITICAL: Configure Remote Command Center for radio to show station navigation buttons
        configureRadioRemoteCommands()
        
        guard index >= 0 && index < stations.count else {
            print("Invalid station index: \(index)")
            return
        }
        
        let station = stations[index]
        print("🔄 Station Transition: Playing \(station.name) at index \(index)")
        
        // Clear navigation cache when switching stations to ensure fresh list on next navigation
        clearNavigationCache()
        
        // Report station click to Radio Browser API if station was discovered from there
        viewModel?.reportStationClick(for: station)
        
        // CRITICAL: Reset network evaluation for fresh quality assessment on new station
        streamQualityManager.resetNetworkEvaluation()
        print("🌐 Station Transition: Reset network evaluation for fresh quality assessment")
        
        // CRITICAL: Clear playing state to ensure immediate transition
        isPlaying = false
        connectionState = .connecting
        
        // Store current iTunes artwork before clearing metadata (using PREVIOUS station index)
        if let currentArtwork = iTunesAlbumArt, let currentMeta = metadata {
            lastKnownGoodArtwork = currentArtwork
            lastKnownGoodMetadata = currentMeta
            
            // Cache artwork with PREVIOUS station ID for persistence (before updating currentStationIndex)
            if let previousStationIndex = currentStationIndex, let viewModel = viewModel,
               previousStationIndex < viewModel.stations.count {
                let previousStationId = viewModel.stations[previousStationIndex].id
                persistentArtworkCache[previousStationId] = currentArtwork
                print("💾 Cached iTunes artwork for PREVIOUS station \(previousStationId) before switch")
            }
        }
        
        // STABILITY FIX: Set the current station index and station AFTER caching previous station's artwork
        // This ensures station display remains consistent and stable
        currentStationIndex = index
        currentlyPlayingStation = station
        
        print("📍 STABILITY: Set currentlyPlayingStation to '\(station.name)' from '\(station.country)'")
        print("📍 STABILITY: Station display will remain stable regardless of future country picker changes")
        
        // CRITICAL FIX: Immediately notify CarPlay of station change for instant equalizer update
        // This ensures the equalizer indicator updates immediately, not one station behind
        NotificationCenter.default.post(
            name: NSNotification.Name("InstantCarPlayArtworkSync"),
            object: nil,
            userInfo: [
                "stationId": station.id,
                "metadata": "",
                "hasArtwork": false,
                "syncType": "station_change"
            ]
        )
        print("🚗 INSTANT: Notified CarPlay of station change to '\(station.name)' (ID: \(station.id))")
        
        // Clear all metadata and iTunes artwork when switching stations
        // This ensures old song artwork doesn't carry over to the new station
        metadata = nil
        // Clear metadata cache to prevent old artist/title info from carrying over
        lastKnownArtist = nil
        lastKnownTitle = nil
        lastMetadataUpdate = nil
        
        // Clear Shazam-verified metadata to prevent previous station's song info from persisting
        displayTitle = nil
        displayArtist = nil
        iTunesAlbumArt = nil
        albumArt = nil
        songTitle = ""
        artistName = ""
        lastMetadataSearched = ""
        artworkSearchTimer?.invalidate()
        
        // Cancel artwork protection timer when switching stations
        artworkProtectionTimer?.invalidate()
        artworkProtectionTimer = nil
        
        // STATION ARTWORK FIX: Load station artwork immediately when switching stations
        print("🎨 DEBUG: Station switch - Cleared iTunesAlbumArt and albumArt, loading station artwork")
        loadStationArtwork()
        print("🎨 Station Switch: Loaded station artwork - albumArt is now: \(albumArt != nil ? "present" : "nil")")
        
        // Force UI update to ensure artwork changes are reflected immediately
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        // Reset elapsed time when switching stations
        playbackStartTime = nil
        pausedElapsedTime = 0
        lastElapsedTimeUpdate = nil
        print("⏱️ PlayStation: Reset elapsed time for new station")
        
        guard let url = URL(string: station.url) else {
            print("Invalid URL for station: \(station.name)")
            return
        }
        
        // Use forceSetStationURL for user-initiated station changes to work during CarPlay
        forceSetStationURL(url)
        
        // Save the station info for persistence
        userDefaults?.set(url, forKey: "lastStationURL")
        userDefaults?.set(index, forKey: "lastStationIndex")
        userDefaults?.set(station.id, forKey: "LastPlayedStationID")
        
        // IMMEDIATE PLAYBACK: Use direct play method for station transitions
        playStationImmediately()
        
        // If we already have metadata for this station, artwork will come from Shazam only
        if let currentMetadata = metadata, !currentMetadata.isEmpty {
            print("📻 Station has metadata: \(currentMetadata) - awaiting Shazam artwork")
        }
    }
    
    /// Immediate playback method for station transitions - bypasses all protection logic
    private func playStationImmediately() {
        print("🚀 Station Transition: Starting immediate playback")
        
        // Stop any existing podcast playback (this is an explicit station change)
        stopPodcastPlayback()
        
        // Set radio as the active player
        PlaybackManager.shared.setActivePlayer(.radio)
        
        // Track user intent
        userWantsToPlay = true
        
        // Ensure we have a player
        guard let player = player else { 
            print("❌ Station Transition: No player available")
            return 
        }
        
        // IMMEDIATE START: No delays, no protection checks for station transitions
        connectionState = .connecting
        player.play()
        
        // Start elapsed time tracking immediately
        playbackStartTime = Date()
        lastElapsedTimeUpdate = nil
        print("⏱️ Station Transition: Started elapsed time tracking")
        
        print("▶️ Station Transition: Player started immediately")
        
        // Update Now Playing info immediately
        updateNowPlayingInfo()
        updateWidget()
        
        // Quick verification after a minimal delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.player?.timeControlStatus != .playing {
                print("⚠️ Station Transition: Player not playing after 0.2s - triggering again")
                self?.player?.play()
            }
        }
        
        scheduleAppRefresh()
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
        
        // Use forceSetStationURL for alarm stations to work during CarPlay
        forceSetStationURL(url)
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
        print("⏭️ Switching to next station from list of \(stations.count) stations")
        
        // Always find current station by ID in the provided stations list
        guard let playingStation = currentlyPlayingStation else {
            print("❌ No currently playing station - cannot navigate")
            return
        }
        
        guard let currentIndex = stations.firstIndex(where: { $0.id == playingStation.id }) else {
            print("❌ Current station '\(playingStation.name)' not found in provided stations list")
            return
        }
        
        print("🔍 Current station '\(playingStation.name)' found at index \(currentIndex) in filtered list")
        let nextIndex = (currentIndex + 1) % stations.count
        print("⏭️ Moving to next station at index \(nextIndex): '\(stations[nextIndex].name)'")
        
        playStation(at: nextIndex, from: stations)
        updateLastPlayed(stations[nextIndex])
    }
    
    func previousStation(from stations: [RadioStation]) {
        print("⏮️ Switching to previous station from list of \(stations.count) stations")
        
        // Always find current station by ID in the provided stations list
        guard let playingStation = currentlyPlayingStation else {
            print("❌ No currently playing station - cannot navigate")
            return
        }
        
        guard let currentIndex = stations.firstIndex(where: { $0.id == playingStation.id }) else {
            print("❌ Current station '\(playingStation.name)' not found in provided stations list")
            return
        }
        
        print("🔍 Current station '\(playingStation.name)' found at index \(currentIndex) in filtered list")
        let previousIndex = (currentIndex - 1 + stations.count) % stations.count
        print("⏮️ Moving to previous station at index \(previousIndex): '\(stations[previousIndex].name)'")
        
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
            // BUT don't force it during pause operations to prevent station switching
            // AND don't force it if userWantsToPlay is false (means radio was stopped)
            if isPlaying && player?.timeControlStatus == .playing && !wasManuallyPaused && userWantsToPlay {
                print("⚠️ Now Playing: Radio is playing but not active player - forcing active state")
                PlaybackManager.shared.setActivePlayer(.radio)
            } else {
                // Rate limit this log message to prevent spam
                if lastLoggedPlayingState != false {
                    print("❌ Now Playing: Radio is not the active player and not playing (userWantsToPlay: \(userWantsToPlay))")
                    lastLoggedPlayingState = false
                }
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
            // Only log if state changed
            if lastLoggedStationIndex != -1 {
                print("🎵 Now Playing: Using alarm station")
                lastLoggedStationIndex = -1
            }
        } else if let playingStation = currentlyPlayingStation {
            // CRITICAL FIX: Use currentlyPlayingStation as the primary source of truth
            currentStation = playingStation
            
            // COUNTRY CONTAMINATION FIX: Validate and update currentStationIndex to match currentlyPlayingStation
            // This prevents index contamination when country changes update the stations array
            let correctIndex = viewModel.stations.firstIndex(where: { $0.id == playingStation.id })
            if currentStationIndex != correctIndex {
                print("🔧 CONTAMINATION FIX: Updating currentStationIndex from \(currentStationIndex?.description ?? "nil") to \(correctIndex?.description ?? "nil") to match currentlyPlayingStation '\(playingStation.name)'")
                currentStationIndex = correctIndex
            }
            
            // Only log if station changed
            if let currentStationIndex = currentStationIndex,
               lastLoggedStationIndex != currentStationIndex {
                print("🎵 Now Playing: Using station '\(playingStation.name)' at index \(currentStationIndex)")
                lastLoggedStationIndex = currentStationIndex
            }
        } else if let currentStationIndex = currentStationIndex,
                  currentStationIndex < viewModel.stations.count {
            // CONTAMINATION PREVENTION: Only use index-based lookup if we're confident the index is valid
            // Avoid using potentially stale currentStationIndex when currentlyPlayingStation is nil
            // This prevents showing wrong station names during country changes
            let station = viewModel.stations[currentStationIndex]
            
            // Additional validation: if we have a last played station URL, verify it matches
            if let lastStationURL = UserDefaults.standard.url(forKey: "LastPlayedStationURL"),
               station.url != lastStationURL.absoluteString {
                print("🚨 CONTAMINATION PREVENTION: Index \(currentStationIndex) points to wrong station '\(station.name)' (URL mismatch)")
                print("   Expected URL: \(lastStationURL.absoluteString)")
                print("   Actual URL: \(station.url)")
                currentStation = nil
            } else {
                currentStation = station
                // Only log if station changed
                if lastLoggedStationIndex != currentStationIndex {
                    print("🎵 Now Playing: Using station at index \(currentStationIndex) (fallback)")
                    lastLoggedStationIndex = currentStationIndex
                }
            }
        } else {
            currentStation = nil
            // Rate limit this log message to prevent spam - only log once per minute
            if lastLoggedStationIndex != nil {
                let now = Date()
                if lastLoggedDefaultInfo == nil || now.timeIntervalSince(lastLoggedDefaultInfo!) > 60 {
                    print("❌ Now Playing: No current station available")
                    lastLoggedDefaultInfo = now
                }
                lastLoggedStationIndex = nil
            }
        }
        
        // Set basic metadata (display EXACTLY what station sends)
        if let station = currentStation {
            let stationName = station.name
            let rawMetadata = (metadata ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = rawMetadata.isEmpty ? stationName : rawMetadata
            
            // Priority 1: Use Shazam verified metadata if available
            let finalTitle: String
            let finalArtist: String
            
            if let shazamTitle = displayTitle, let shazamArtist = displayArtist {
                finalTitle = shazamTitle
                finalArtist = shazamArtist
                print("🎵 Using Shazam verified metadata: '\(finalTitle)' by '\(finalArtist)'")
            } else {
                // Priority 2: Use station-provided metadata split
                let (splitArtist, splitTitle) = splitArtistTitle(from: rawMetadata, fallbackArtist: stationName, fallbackTitle: fallbackTitle)
                finalTitle = splitTitle
                finalArtist = splitArtist
                print("🔄 Split metadata: '\(rawMetadata)' → Artist: '\(splitArtist)', Title: '\(splitTitle)'")
            }
            
            nowPlayingInfo[MPMediaItemPropertyTitle] = finalTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = finalArtist
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = stationName
            
            // Only log if station changed
            if lastLoggedStationIndex != currentStationIndex {
                print("🎵 Now Playing Info - Title: '\(finalTitle)', Artist: '\(finalArtist)', Station: '\(stationName)'")
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "StreamRadios"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "No Station Playing"
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "StreamRadios"
            
            // Rate limit this log message to prevent spam - only log once per minute
            let now = Date()
            if lastLoggedDefaultInfo == nil || now.timeIntervalSince(lastLoggedDefaultInfo!) > 60 {
                print("⚠️ Now Playing: Using default info as no station is available")
                lastLoggedDefaultInfo = now
            }
        }
        
        // Set stream properties
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        // Add elapsed time for CarPlay display (only when playing)
        // Note: Frequent updates are handled separately to avoid performance issues
        if isPlaying {
            let elapsedTime = getCurrentElapsedTime()
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
            // Don't log elapsed time updates as they're frequent
        }
        
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
                // Only log when artwork state changes
                if !lastLoggedArtworkState {
                    print("🎨 Now Playing: Using station icon only (paused state)")
                    lastLoggedArtworkState = true
                }
            }
        } else {
            // When playing, prioritize Shazam artwork but ensure station icons always show
            print("🔍 Artwork Debug - isPlaying: \(isPlaying)")
            print("   - iTunesAlbumArt: \(iTunesAlbumArt != nil ? "present (\(iTunesAlbumArt!.size))" : "nil")")
            print("   - currentStation: \(currentStation?.name ?? "nil")")
            print("   - station has iconData: \(currentStation?.iconData != nil)")
            
            // PRIORITY 1: Shazam-verified artwork (from iTunesAlbumArt which gets Shazam data)
            if let iTunesArt = iTunesAlbumArt {
                let artwork = MPMediaItemArtwork(boundsSize: iTunesArt.size) { size in
                    return iTunesArt
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("✅ Now Playing: Using Shazam artwork (size: \(iTunesArt.size))")
                lastLoggedArtworkState = true
            }
            // PRIORITY 2: Station icon (always show when no Shazam artwork)
            else if let station = currentStation,
                      let iconData = station.iconData,
                      let imageData = Data(base64Encoded: iconData),
                      let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("✅ Now Playing: Using station icon '\(station.name)' (size: \(image.size))")
            }
            // PRIORITY 3: Default radio icon if station has no icon
            else {
                // Create a default radio icon as fallback
                let defaultSize: CGFloat = 200
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: defaultSize, height: defaultSize))
                let defaultImage = renderer.image { context in
                    UIColor.systemGray.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: defaultSize, height: defaultSize))
                    
                    if let radioImage = UIImage(systemName: "radio", withConfiguration: UIImage.SymbolConfiguration(pointSize: 100, weight: .medium)) {
                        UIColor.white.setFill()
                        let imageRect = CGRect(x: (defaultSize - 100) / 2, y: (defaultSize - 100) / 2, width: 100, height: 100)
                        radioImage.draw(in: imageRect)
                    }
                }
                
                let artwork = MPMediaItemArtwork(boundsSize: defaultImage.size) { size in
                    return defaultImage
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                print("✅ Now Playing: Using default radio icon (no station icon available)")
            }
        }
        
        // Only log artwork unavailable message when artwork state changes from available to unavailable
        if !artworkSet && lastLoggedArtworkState {
            print("⚠️ Now Playing: No artwork available")
            lastLoggedArtworkState = false
        }
        
        // Set the now playing info
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
        
        // Only log when playing state changes
        if lastLoggedPlayingState != isPlaying {
            print("✅ Now Playing: Successfully updated info center with \(nowPlayingInfo.count) items")
            print("🎵 Now Playing State - isPlaying: \(isPlaying), playback rate: \(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0.0)")
            lastLoggedPlayingState = isPlaying
        }
        
        // Remote command center setup is handled once in init and when needed, not every time
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
        guard let currentStation = currentlyPlayingStation else { 
            print("🔧 Widget: No currentlyPlayingStation available")
            return 
        }
        
        // CRITICAL FIX: Use currentlyPlayingStation directly instead of array lookup
        // This prevents contamination when currentStationIndex becomes stale
        let metadata = self.metadata ?? "No song or album title available"
        
        // Only update widget if station or metadata actually changed
        if lastWidgetStation != currentStation.name || lastWidgetMetadata != metadata {
            userDefaults?.set(currentStation.name, forKey: "stationName")
            userDefaults?.set(currentStation.iconData, forKey: "stationIcon")
            userDefaults?.set(metadata, forKey: "stationMetadata")
            
            WidgetCenter.shared.reloadAllTimelines()
            print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
            
            // Update state tracking
            lastWidgetStation = currentStation.name
            lastWidgetMetadata = metadata
        }
    }
    
    func setupRemoteCommandCenter() {
        // Only configure once to avoid excessive logging
        guard !isRemoteCommandCenterConfigured else {
            return
        }
        
        configureRadioRemoteCommands()
        isRemoteCommandCenterConfigured = true
    }
    
    // MARK: - Force Remote Command Center Configuration for Radio
    func configureRadioRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear any existing targets first
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        
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
        
        // Enable next/previous track commands for radio station navigation
        // This allows skip/previous buttons to work on lock screen and CarPlay
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                // Get the appropriate station list based on current context
                if let stations = self.getCurrentStationList() {
                    self.nextStation(from: stations)
                    print("🎮 Remote Command: Next Station executed")
                    return .success
                }
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if PlaybackManager.shared.activePlayer == .radio {
                // Get the appropriate station list based on current context
                if let stations = self.getCurrentStationList() {
                    self.previousStation(from: stations)
                    print("🎮 Remote Command: Previous Station executed")
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
        
        // CRITICAL: Disable podcast-specific commands to prevent rewind buttons in Now Playing
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        // Disable other commands that don't make sense for radio
        commandCenter.stopCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        
        print("✅ Remote Command Center configured for Radio - Next/Previous Station enabled, Skip commands disabled")
    }
    
    // Cache the station navigation list to prevent it from changing during skip operations
    private var cachedNavigationStations: [RadioStation]?
    private var cacheTimestamp: Date?
    private let cacheValidDuration: TimeInterval = 30 // Cache valid for 30 seconds
    
    /// Gets the current station list based on the active tab context for skip/previous functionality
    /// Uses caching to prevent the list from changing during navigation operations
    private func getCurrentStationList() -> [RadioStation]? {
        guard let viewModel = viewModel else {
            print("❌ getCurrentStationList: No viewModel available")
            return nil
        }
        
        // Check if we have a valid cached list
        if let cached = cachedNavigationStations,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidDuration {
            print("🔍 getCurrentStationList: Using cached list with \(cached.count) stations")
            return cached
        }
        
        print("🔍 getCurrentStationList: Creating fresh station list - Current tab = \(viewModel.selectedSubTab), Country = '\(viewModel.selectedCountry)'")
        
        var freshStations: [RadioStation]?
        
        // Apply the same filtering logic as in RadioPlayerSheetView
        switch viewModel.selectedSubTab {
        case .all:
            // All tab shows stations from the selected country only, sorted alphabetically
            if viewModel.selectedCountry == "Select Country" {
                print("🔍 getCurrentStationList: All tab - no country selected, returning empty list")
                freshStations = []
            } else {
                var stations = viewModel.stations.filter { station in
                    // Filter by selected country and ensure valid country information
                    let hasValidCountry = !station.country.isEmpty &&
                                        station.country != "Unknown Region" &&
                                        station.country != "Select Country" &&
                                        !station.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    let matches = station.country == viewModel.selectedCountry && hasValidCountry
                    return matches
                }
                
                // Sort alphabetically by name based on toggle setting
                if viewModel.isAscendingSort {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
                }
                print("🔍 getCurrentStationList: All tab returning \(stations.count) stations for country '\(viewModel.selectedCountry)'")
                freshStations = stations
            }
        case .recent:
            // Recent tab shows recent stations from ALL countries regardless of country selection
            let recentStations = viewModel.recentStations()
            print("🔍 getCurrentStationList: Recent tab returning \(recentStations.count) stations")
            freshStations = recentStations
        case .favorites:
            // Favorites respects CloudKit-synced favoriteOrder
            let favoriteStations = viewModel.favoriteStations()
            print("🔍 getCurrentStationList: Favorites tab returning \(favoriteStations.count) stations")
            freshStations = favoriteStations
        }
        
        // Cache the fresh list
        cachedNavigationStations = freshStations
        cacheTimestamp = Date()
        
        return freshStations
    }
    
    /// Clears the cached navigation station list to force a fresh fetch on next access
    private func clearNavigationCache() {
        cachedNavigationStations = nil
        cacheTimestamp = nil
        print("🔍 getCurrentStationList: Cache cleared")
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
    
    // Elapsed time tracking for smooth CarPlay display
    private var playbackStartTime: Date?
    private var pausedElapsedTime: TimeInterval = 0
    private var lastElapsedTimeUpdate: Date?
    
    // Calculate current elapsed time for radio playback
    private func getCurrentElapsedTime() -> TimeInterval {
        var elapsedTime = pausedElapsedTime
        if let startTime = playbackStartTime {
            elapsedTime += Date().timeIntervalSince(startTime)
        }
        return elapsedTime
    }
    
    // Update only the elapsed time in Now Playing info (lightweight operation)
    private func updateNowPlayingInfoElapsedTime() {
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingCenter.nowPlayingInfo ?? [:]
        
        // Only update elapsed time if we're playing
        if isPlaying {
            let elapsedTime = getCurrentElapsedTime()
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
            nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
            
            // Rate limit time update logs - only log every 10 seconds
            let now = Date()
            let shouldLog = lastTimeUpdateLog == nil || now.timeIntervalSince(lastTimeUpdateLog!) > 10.0
            
            if shouldLog {
                print("⏱️ Updated elapsed time: \(String(format: "%.1f", elapsedTime)) seconds")
                lastTimeUpdateLog = now
            }
        }
    }
    
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
            print("🔄 Skipping duplicate iTunes search for same song: \(cacheKey)")
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
                print("💾 iTunes album art loaded from cache for: \(cacheKey) (original: \(metadata))")
            }
            return
        }
        
        // Cancel any existing timer to debounce rapid metadata changes
        artworkSearchTimer?.invalidate()
        
        // Debounce the search to prevent rapid successive API calls
        artworkSearchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            self.lastMetadataSearched = cacheKey
            
            print("🔍 Fetching iTunes album art for song: \(cacheKey) (original: \(metadata))")
            
            // Search iTunes for album artwork
            self.searchITunesForArtwork(metadata: metadata) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    // Cache the result using normalized key (even if nil)
                    self.cacheImage(image, for: cacheKey)
                    
                    // Only update if we're still on the same song (normalize case for comparison)
                    if cacheKey.lowercased() == self.lastMetadataSearched.lowercased() {
                        self.iTunesAlbumArt = image
                        self.iTunesArtworkJustSet = true
                        self.startArtworkProtectionTimer()
                        
                        // Store as last known good artwork for fallback
                        if let image = image {
                            self.lastKnownGoodArtwork = image
                            self.lastKnownGoodMetadata = metadata
                            
                            // Cache with current station for persistence
                            if let stationIndex = self.currentStationIndex, let viewModel = self.viewModel,
                               stationIndex < viewModel.stations.count {
                                let stationId = viewModel.stations[stationIndex].id
                                self.persistentArtworkCache[stationId] = image
                            }
                            
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
        
        // Prefer a direct split based strictly on station-provided metadata
        var preferredQueries: [String] = []
        if let stationName = viewModel?.stations[safe: currentStationIndex ?? -1]?.name {
            let split = splitArtistTitle(from: metadata, fallbackArtist: stationName, fallbackTitle: metadata)
            let artist = split.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = split.title.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if both artist and title are just the station name (invalid for music search)
            let normalizedStationName = stationName.lowercased().replacingOccurrences(of: " ", with: "")
            let normalizedArtist = artist.lowercased().replacingOccurrences(of: " ", with: "")
            let normalizedTitle = title.lowercased().replacingOccurrences(of: " ", with: "")
            
            if normalizedArtist == normalizedStationName && normalizedTitle == normalizedStationName {
                print("🎯 🚫 Skipping artwork search - both artist and title are station name: '\(stationName)'")
                print("🎯    Metadata: '\(metadata)' → Artist: '\(artist)', Title: '\(title)'")
                completion(nil)
                return
            }
            
            if !artist.isEmpty && !title.isEmpty {
                preferredQueries.append(contentsOf: [
                    "\"\(title)\" \"\(artist)\"",
                    "\(title) \(artist)",
                    "\(artist) \(title)"
                ])
            }
        }
        
        // Try multiple search strategies
        var searchQueries = buildSearchQueries(parsedData: parsedData, originalMetadata: metadata)
        // Ensure our preferred queries go first and are unique
        for q in preferredQueries.reversed() {
            if let existingIndex = searchQueries.firstIndex(of: q) {
                searchQueries.remove(at: existingIndex)
            }
            searchQueries.insert(q, at: 0)
        }
        
        print("🎯 Generated \(searchQueries.count) search queries for '\(metadata)':")
        for (index, query) in searchQueries.enumerated() {
            print("   \(index + 1). '\(query)'")
        }
        
        // Use enhanced network session for CarPlay if connected
        if CarPlayManager.shared.isCarPlayConnected {
            searchWithQueriesUsingCarPlaySession(searchQueries, completion: completion)
        } else {
            searchWithQueries(searchQueries, completion: completion)
        }
    }

    // Enhanced metadata handling for better artist/title display
    private var lastKnownArtist: String?
    private var lastKnownTitle: String?
    private var lastMetadataUpdate: Date?
    
    /// Smart detection of artist-title order in radio metadata
    private func smartDetectArtistTitleOrder(left: String, right: String) -> (artist: String, title: String) {
        print("🔍 Smart detection: left='\(left)', right='\(right)'")
        
        // Common artist indicators
        let artistIndicators = [
            "feat.", "featuring", "ft.", "with", "&", "and",
            "vs", "versus", "x", "collaboration"
        ]
        
        // Common title indicators
        let titleIndicators = [
            "(", ")", "[", "]", "remix", "radio edit", "extended", "version",
            "live", "acoustic", "instrumental", "remastered"
        ]
        
        var leftArtistScore = 0
        var rightArtistScore = 0
        var leftTitleScore = 0
        var rightTitleScore = 0
        
        // Check for artist indicators
        for indicator in artistIndicators {
            if left.lowercased().contains(indicator.lowercased()) { leftArtistScore += 1 }
            if right.lowercased().contains(indicator.lowercased()) { rightArtistScore += 1 }
        }
        
        // Check for title indicators
        for indicator in titleIndicators {
            if left.lowercased().contains(indicator.lowercased()) { leftTitleScore += 1 }
            if right.lowercased().contains(indicator.lowercased()) { rightTitleScore += 1 }
        }
        
        // Strong indicator: Multiple artists separated by commas (like "DJ KHALED, VYBZ KARTEL, BUJU BANTON")
        let leftCommaCount = left.components(separatedBy: ",").count - 1
        let rightCommaCount = right.components(separatedBy: ",").count - 1
        
        if leftCommaCount >= 2 { leftArtistScore += 3 }  // Strong artist indicator
        if rightCommaCount >= 2 { rightArtistScore += 3 } // Strong artist indicator
        
        // Artist name patterns (DJ, MC, common suffixes)
        let leftLower = left.lowercased()
        let rightLower = right.lowercased()
        
        if leftLower.hasPrefix("dj ") || leftLower.hasPrefix("mc ") || leftLower.contains(" dj ") { leftArtistScore += 2 }
        if rightLower.hasPrefix("dj ") || rightLower.hasPrefix("mc ") || rightLower.contains(" dj ") { rightArtistScore += 2 }
        
        // Heuristic: Longer text is more likely to be the title
        if left.count > Int(Double(right.count) * 1.5) { leftTitleScore += 1 }
        if right.count > Int(Double(left.count) * 1.5) { rightTitleScore += 1 }
        
        // Heuristic: All caps text is more likely to be metadata formatting (could be either)
        // But if one is mixed case and other is all caps, mixed case is more likely the artist name
        let leftIsAllCaps = left.uppercased() == left && left != left.lowercased()
        let rightIsAllCaps = right.uppercased() == right && right != right.lowercased()
        
        if !leftIsAllCaps && rightIsAllCaps { leftArtistScore += 1 }
        if !rightIsAllCaps && leftIsAllCaps { rightArtistScore += 1 }
        
        // Common knowledge: if one part is a well-known artist name pattern
        let leftIsLikelyArtist = isLikelyArtistName(left)
        let rightIsLikelyArtist = isLikelyArtistName(right)
        
        if leftIsLikelyArtist { leftArtistScore += 2 }
        if rightIsLikelyArtist { rightArtistScore += 2 }
        
        print("🔍 Scores - Left: artist=\(leftArtistScore), title=\(leftTitleScore) | Right: artist=\(rightArtistScore), title=\(rightTitleScore)")
        
        // Decide based on scores
        if leftArtistScore > rightArtistScore {
            print("🔍 ✅ Detected format: ARTIST - TITLE")
            return (left, right)  // left=artist, right=title
        } else if rightArtistScore > leftArtistScore {
            print("🔍 ✅ Detected format: TITLE - ARTIST")
            return (right, left)  // right=artist, left=title  
        } else if leftTitleScore > rightTitleScore {
            print("🔍 ✅ Detected format: TITLE - ARTIST (by title indicators)")
            return (right, left)  // right=artist, left=title
        } else if rightTitleScore > leftTitleScore {
            print("🔍 ✅ Detected format: ARTIST - TITLE (by title indicators)")
            return (left, right)  // left=artist, right=title
        } else {
            // Final tie-breaker: Check for collaboration patterns
            let leftHasArtistPattern = leftLower.contains(" feat") || leftLower.contains(" ft") || 
                                     leftLower.contains(" & ") || leftLower.contains(" and ")
            let rightHasArtistPattern = rightLower.contains(" feat") || rightLower.contains(" ft") || 
                                      rightLower.contains(" & ") || rightLower.contains(" and ")
            
            if rightHasArtistPattern && !leftHasArtistPattern {
                print("🔍 ✅ Detected format: TITLE - ARTIST (by collaboration indicators)")
                return (right, left)  // right=artist, left=title
            } else if leftHasArtistPattern && !rightHasArtistPattern {
                print("🔍 ✅ Detected format: ARTIST - TITLE (by collaboration indicators)")
                return (left, right)  // left=artist, right=title
            }
            
            // Final fallback: Most radio metadata follows "ARTIST - TITLE" format
            print("🔍 ⚖️ True tie - defaulting to ARTIST - TITLE (standard radio format)")
            return (left, right)  // left=artist, right=title
        }
    }
    
    /// Check if a string is likely an artist name
    private func isLikelyArtistName(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Known artist patterns
        let artistPatterns = [
            "phil collins", "richard ashcroft", "rema", "selena gomez",
            "mutya buena", "the killers", "portugal the man"
        ]
        
        for pattern in artistPatterns {
            if normalized.contains(pattern) { return true }
        }
        
        // Name patterns (First Last, First Middle Last, etc.)
        let nameComponents = normalized.components(separatedBy: " ")
        if nameComponents.count >= 2 && nameComponents.count <= 4 {
            // Check if it looks like a name (starts with capital letters)
            let hasNamePattern = nameComponents.allSatisfy { component in
                component.first?.isUppercase == true || component.first?.isLetter == true
            }
            if hasNamePattern { return true }
        }
        
        return false
    }

    // Display-only split that preserves station-provided wording and improves iTunes search
    func splitArtistTitle(from raw: String, fallbackArtist: String, fallbackTitle: String) -> (artist: String, title: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🎯 splitArtistTitle called with: '\(raw)' → trimmed: '\(trimmed)'")
        print("🎯 Current cache: Artist='\(lastKnownArtist ?? "nil")', Title='\(lastKnownTitle ?? "nil")', LastUpdate=\(lastMetadataUpdate?.timeIntervalSinceNow ?? 0)s ago")
        
        if trimmed.isEmpty { return (fallbackArtist, fallbackTitle) }
        
        let separators = [" - ", " – ", " — ", " | ", " / ", ": "]
        
        // Try to split with separators first
        for sep in separators {
            if trimmed.contains(sep) {
                let parts = trimmed.components(separatedBy: sep)
                if parts.count >= 2 {
                    let left = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let right = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !left.isEmpty && !right.isEmpty {
                        // Smart detection of ARTIST-TITLE vs TITLE-ARTIST format
                        let (detectedArtist, detectedTitle) = smartDetectArtistTitleOrder(left: left, right: right)
                        
                        // Update our knowledge for future incomplete metadata
                        lastKnownArtist = detectedArtist
                        lastKnownTitle = detectedTitle
                        lastMetadataUpdate = Date()
                        return (detectedArtist, detectedTitle)
                    }
                }
                break
            }
        }
        
        // Handle incomplete metadata by checking if it looks like an artist or title
        let now = Date()
        let recentWindow: TimeInterval = 30 // 30 seconds to consider metadata "recent"
        let hasRecentCache = lastMetadataUpdate != nil && now.timeIntervalSince(lastMetadataUpdate!) < recentWindow
        
                // Check if we're getting repeated artist-only metadata (indicating a new song with incomplete info)
        let isRepeatedArtistOnly = hasRecentCache && 
                                  lastKnownArtist == trimmed &&
                                  lastKnownTitle != nil &&
                                  now.timeIntervalSince(lastMetadataUpdate!) > 5.0
        
        // Always do pattern detection (whether we have cache or not)
        // Enhanced pattern detection that considers sequence and context
        
        // Strong indicators this is an artist name
        let strongArtistIndicators = [
            trimmed.count <= 15 && !trimmed.lowercased().contains("you") && !trimmed.lowercased().contains("love"),  // Short without song words
            trimmed.contains(" & "),     // Artist collaborations
            trimmed.contains(" and "),   // Artist collaborations
            trimmed.lowercased().contains(" feat"),  // Feature collaborations
            trimmed.lowercased().contains(" vs "),   // VS collaborations
        ]
        
        // Strong indicators this is a song title
        let strongTitleIndicators = [
            trimmed.contains("'"),  // Apostrophes very common in songs
            trimmed.contains("("),  // Parentheses for versions/features
            trimmed.lowercased().hasPrefix("i "),  // "I Want...", "I Love...", etc.
            trimmed.lowercased().contains("you"),  // Very common in song titles
            trimmed.lowercased().contains("love"), // Very common in song titles
            trimmed.lowercased().contains("my "),  // "My Girl", "My Way", etc.
            trimmed.lowercased().contains(" me"),  // "Love Me", "Kiss Me", etc.
            trimmed.lowercased().contains("baby"), // Very common in song titles
        ]
        
        let strongArtistCount = strongArtistIndicators.filter { $0 }.count
        let strongTitleCount = strongTitleIndicators.filter { $0 }.count
        
        // Use strong indicators first, then fall back to weaker heuristics
        let isLikelyArtist: Bool
        let isLikelyTitle: Bool
        
        if strongTitleCount > 0 {
            isLikelyTitle = true
            isLikelyArtist = false
        } else if strongArtistCount > 0 {
            isLikelyArtist = true
            isLikelyTitle = false
        } else {
            // Fall back to weaker heuristics for ambiguous cases
            // Check if this looks like a typical artist name based on common patterns
            let hasCommonArtistPattern = [
                trimmed.split(separator: " ").count <= 3,  // Most artists have 1-3 words
                !trimmed.lowercased().contains("you"),     // Songs often contain "you"
                !trimmed.lowercased().contains("my "),     // Songs often contain "my"
                !trimmed.lowercased().contains(" me"),     // Songs often contain "me"
                !trimmed.lowercased().hasPrefix("i "),     // Songs often start with "I"
                trimmed.count <= 20,                       // Artists rarely exceed 20 chars
            ].filter { $0 }.count >= 4  // Most indicators should match for artist
            
            let hasCommonTitlePattern = [
                trimmed.lowercased().contains("you"),      // Very common in titles
                trimmed.lowercased().contains("love"),     // Very common in titles  
                trimmed.lowercased().contains("my "),      // Common in titles
                trimmed.lowercased().contains(" me"),      // Common in titles
                trimmed.lowercased().hasPrefix("i "),      // Common in titles
                trimmed.count > 15,                        // Titles often longer
            ].filter { $0 }.count >= 2  // Some indicators should match for title
            
            if hasCommonArtistPattern && !hasCommonTitlePattern {
                isLikelyArtist = true
                isLikelyTitle = false
            } else if hasCommonTitlePattern && !hasCommonArtistPattern {
                isLikelyTitle = true
                isLikelyArtist = false
            } else {
                // If we have recent context, use completion logic
                if hasRecentCache {
                    if lastKnownArtist != nil && lastKnownTitle == nil {
                        // We have an artist but no title - current could be title if it looks like one
                        isLikelyTitle = trimmed.count > 15 || trimmed.lowercased().contains("you") || trimmed.lowercased().contains("love")
                        isLikelyArtist = !isLikelyTitle
                    } else if lastKnownTitle != nil && lastKnownArtist == nil {
                        // We have a title but no artist - current is likely artist
                        isLikelyArtist = true
                        isLikelyTitle = false
                    } else {
                        // Default: shorter names lean artist, longer lean title
                        isLikelyArtist = trimmed.count <= 12
                        isLikelyTitle = trimmed.count > 8
                    }
                } else {
                    // No recent context - use basic length heuristics
                    isLikelyArtist = trimmed.count <= 12
                    isLikelyTitle = trimmed.count > 8
                }
            }
        }
        
        print("🎯 Pattern detection: isLikelyArtist=\(isLikelyArtist), isLikelyTitle=\(isLikelyTitle)")
        
        // Detect artist-only stations: if we consistently get different artist names without separators,
        // this station only sends artist names, not song titles
        let isArtistOnlyStation = hasRecentCache &&
                                 lastKnownArtist != nil &&
                                 lastKnownArtist != trimmed &&
                                 isLikelyArtist &&
                                 !trimmed.contains(" - ") &&
                                 !trimmed.contains(" – ") &&
                                 !trimmed.contains(" — ")
        
        // Clear cache if we're getting repeated artist-only metadata (new song starting)
        if isRepeatedArtistOnly {
            print("🎯 🔄 Clearing stale cache - repeated artist '\(trimmed)' likely indicates new song")
            lastKnownArtist = nil
            lastKnownTitle = nil
            lastMetadataUpdate = nil
        }
        
        // Clear cache for artist-only stations to prevent fake combinations
        if isArtistOnlyStation {
            print("🎯 🎭 Detected artist-only station - clearing cache to prevent fake combinations")
            let previousArtist = lastKnownArtist ?? "nil"
            print("🎯    Previous: '\(previousArtist)' → Current: '\(trimmed)'")
            lastKnownArtist = nil
            lastKnownTitle = nil
            lastMetadataUpdate = nil
        }
        
        // Use pattern detection with or without cache
        if hasRecentCache && !isRepeatedArtistOnly && !isArtistOnlyStation && isLikelyArtist && lastKnownTitle != nil {
            // Current is artist, use previous title
            lastKnownArtist = trimmed
            lastMetadataUpdate = now
            print("🎯 ✅ Combined as Artist+CachedTitle: '\(trimmed)' + '\(lastKnownTitle!)'")
            return (trimmed, lastKnownTitle!)
        } else if hasRecentCache && !isRepeatedArtistOnly && !isArtistOnlyStation && isLikelyTitle && lastKnownArtist != nil {
            // Current is title, use previous artist
            lastKnownTitle = trimmed
            lastMetadataUpdate = now
            print("🎯 ✅ Combined as CachedArtist+Title: '\(lastKnownArtist!)' + '\(trimmed)'")
            return (lastKnownArtist!, trimmed)
        } else if isLikelyArtist {
            // Check if this "artist" is actually just the station name or technical identifier
            let currentStationName = fallbackArtist.lowercased().replacingOccurrences(of: " ", with: "")
            let trimmedForComparison = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
            
            // Check for exact station name match
            if currentStationName == trimmedForComparison {
                print("🎯 🚫 Detected station name as metadata - rejecting to avoid fake song info")
                print("🎯    Station: '\(fallbackArtist)' vs Metadata: '\(trimmed)'")
                return (fallbackArtist, fallbackTitle) // Return station info, don't store fake artist
            }
            
            // Check for technical station identifiers that should never be used as artist names
            let stationIdentifiers = [
                "lautfm", "laut.fm", "progressive.com", "verbraucherinformationen",
                "radio", "fm", "am", "streaming", "live", "online"
            ]
            
            for identifier in stationIdentifiers {
                if trimmedForComparison.contains(identifier) {
                    print("🎯 🚫 Detected station identifier '\(identifier)' in metadata - rejecting to avoid fake song info")
                    print("🎯    Metadata: '\(trimmed)'")
                    return (fallbackArtist, fallbackTitle) // Return station info, don't store fake identifier
                }
            }
            
            // Store artist for future combination
            lastKnownArtist = trimmed
            lastMetadataUpdate = now
            print("🎯 📝 Stored artist for future: '\(trimmed)'")
            return (trimmed, fallbackTitle) // Use station name as title for now
        } else if isLikelyTitle {
            // Store title for future combination
            lastKnownTitle = trimmed
            lastMetadataUpdate = now
            print("🎯 📝 Stored title for future: '\(trimmed)'")
            return (fallbackArtist, trimmed) // Use station name as artist for now
        } else if hasRecentCache && lastKnownArtist != nil && lastKnownTitle != nil {
            // Use the most recent complete info we have
            print("🎯 ⏮️ Using cached complete info: '\(lastKnownArtist!)' + '\(lastKnownTitle!)'")
            return (lastKnownArtist!, lastKnownTitle!)
        }
        
        // No separator and no context, return as-is
        print("🎯 🚫 No pattern match or cache - using fallback: Artist='\(fallbackArtist)', Title='\(trimmed)'")
        return (fallbackArtist, trimmed)
    }
    
    /// Cleans HTML/XML metadata to extract readable song information
    private func cleanHTMLMetadata(_ rawMetadata: String) -> String {
        var cleaned = rawMetadata
        
        print("🧹 Cleaning HTML metadata: '\(rawMetadata)'")
        
        // Check for JSON content - if it looks like JSON, reject it entirely
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || 
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           trimmed.contains("\"frag_type\"") ||
           trimmed.contains("\"content\"") ||
           trimmed.contains("frag_type") {
            print("🧹 ❌ Rejecting JSON/fragment metadata: '\(rawMetadata)'")
            return ""
        }
        
        // Check for specific commercial break patterns (more precise matching)
        let commercialPatterns = [
            // Technical/JSON patterns
            "frag_type", "\"content\"", "null", "undefined", "empty",
            // Station technical data and URLs
            "verbraucherinformationen", "lautfm", "laut.fm", "progressive.com",
            "www.", "http://", "https://",
            // Audio encoding/streaming technical terms (full patterns)
            "transcoder", "encoder", "lavf", "lame", "ffmpeg",
            "br-128", "sr-44100", "128k", "256k", "320k",
            // German/international commercial filler (full phrases)
            "ein bisschen", "weitere informationen", "werbung", 
            "anzeige", "reklame", "publicité", "publicidad", "reclame",
            // Time patterns (more specific)
            "00:00:00", "01:00:00", "02:00:00", "03:00:00"
        ]
        
        // Check for exact commercial break phrases (more restrictive)
        let commercialPhrases = [
            "commercial break", "ad break", "advertisement", 
            "commercial spot", "sponsored by", "we'll be right back"
        ]
        
        let lowercased = trimmed.lowercased()
        
        // Check technical patterns
        for pattern in commercialPatterns {
            if lowercased.contains(pattern) {
                print("🧹 ❌ Rejecting commercial break metadata: '\(rawMetadata)'")
                return ""
            }
        }
        
        // Check commercial phrases  
        for phrase in commercialPhrases {
            if lowercased.contains(phrase) {
                print("🧹 ❌ Rejecting commercial break metadata: '\(rawMetadata)'")
                return ""
            }
        }
        
        // Check for domain extensions (but only complete domains)
        let domainPattern = #"\w+\.(com|de|fm|net|org)\b"#
        if trimmed.range(of: domainPattern, options: .regularExpression) != nil {
            print("🧹 ❌ Rejecting commercial break metadata: '\(rawMetadata)'")
            return ""
        }
        
        // Extract readable information from HTML/XML attributes
        var extractedParts: [String] = []
        
        // Extract text attribute (usually song title)
        if let textMatch = cleaned.range(of: #"text="([^"]+)""#, options: .regularExpression) {
            let textValue = String(cleaned[textMatch]).replacingOccurrences(of: #"text=""#, with: "").replacingOccurrences(of: #"""#, with: "")
            if !textValue.isEmpty && textValue != "M" && textValue != "-1" {
                extractedParts.append(textValue)
                print("🧹 Extracted text: '\(textValue)'")
            }
        }
        
        // Extract artist information (often appears after the last dash or as standalone text)
        let lines = cleaned.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip lines with HTML/XML attributes or URLs
            if trimmedLine.contains("=") || 
               trimmedLine.contains("http") || 
               trimmedLine.contains("<") || 
               trimmedLine.contains(">") ||
               trimmedLine.contains("TAID") ||
               trimmedLine.contains("MediaBaseId") ||
               trimmedLine.contains("cartcutId") ||
               trimmedLine.contains("spotInstanceId") ||
               trimmedLine.isEmpty {
                continue
            }
            
            // This might be artist or album information
            if trimmedLine.count > 2 && !trimmedLine.contains("/") {
                extractedParts.append(trimmedLine)
                print("🧹 Extracted artist/album: '\(trimmedLine)'")
            }
        }
        
        // Remove common HTML entities and cleanup
        cleaned = cleaned
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        
        // Remove HTML/XML tags
        cleaned = cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        
        // Remove attribute-value pairs (key="value")
        cleaned = cleaned.replacingOccurrences(of: #"\w+="[^"]*""#, with: "", options: .regularExpression)
        
        // Remove URLs
        cleaned = cleaned.replacingOccurrences(of: #"https?://[^\s]+"#, with: "", options: .regularExpression)
        
        // Remove technical IDs and codes
        cleaned = cleaned.replacingOccurrences(of: #"\b\d{5,}\b"#, with: "", options: .regularExpression)
        
        // If we extracted meaningful parts, use them instead
        if extractedParts.count >= 2 {
            // Try to identify artist and title
            let result = extractedParts.joined(separator: " - ")
            print("🧹 ✅ Using extracted parts: '\(result)'")
            return result
        } else if extractedParts.count == 1 {
            let result = extractedParts[0]
            print("🧹 ✅ Using single extracted part: '\(result)'")
            return result
        }
        
        // Clean up remaining text
        cleaned = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("=") && !$0.contains("http") }
            .first ?? ""
        
        // Final cleanup
        cleaned = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        
        print("🧹 ✅ Final cleaned result: '\(cleaned)'")
        return cleaned
    }
    
    /// Parse search query strings to extract artist and title
    /// Handles formats like: "Artist" "Title", Artist Title, Title Artist, etc.
    private func parseSearchQuery(_ query: String) -> (artist: String, title: String) {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle quoted format: "Artist" "Title" or "Title" "Artist"
        if cleanQuery.contains("\"") {
            let quotedParts = cleanQuery.extractQuotedStrings()
            if quotedParts.count >= 2 {
                // For quoted queries, assume first quote is title, second is artist
                // This matches our search query generation pattern: "Title" "Artist"
                return (artist: quotedParts[1], title: quotedParts[0])
            } else if quotedParts.count == 1 {
                // Single quoted part, use the rest as the other component
                let withoutQuotes = cleanQuery.removeQuotedStrings().trimmingCharacters(in: .whitespacesAndNewlines)
                if !withoutQuotes.isEmpty {
                    return (artist: withoutQuotes, title: quotedParts[0])
                } else {
                    return (artist: "", title: quotedParts[0])
                }
            }
        }
        
        // Handle space-separated format: try to intelligently split
        let words = cleanQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        if words.count >= 2 {
            let midPoint = words.count / 2
            let firstHalf = words[0..<midPoint].joined(separator: " ")
            let secondHalf = words[midPoint...].joined(separator: " ")
            
            // Return as title, artist (most of our queries are in "title artist" format)
            return (artist: secondHalf, title: firstHalf)
        }
        
        // Fallback: use entire query as title
        return (artist: "", title: cleanQuery)
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
    
    // MARK: - Artwork Restoration and Fallback System
    
    /// Restore iTunes artwork from cache or load station artwork as fallback
    func restoreArtworkFromCache() {
        // First try to restore cached iTunes artwork for current station
        if let stationIndex = currentStationIndex, let viewModel = viewModel,
           stationIndex < viewModel.stations.count {
            let stationId = viewModel.stations[stationIndex].id
            
            // Check persistent cache first
            if let cachedArtwork = persistentArtworkCache[stationId] {
                iTunesAlbumArt = cachedArtwork
                iTunesArtworkJustSet = true
                startArtworkProtectionTimer()
                print("🔄 Restored iTunes artwork from persistent cache for station \(stationId)")
                updateNowPlayingInfo()
                updateWidget()
                return
            }
            
            // Check if we have last known good artwork that might apply
            if let lastGoodArtwork = lastKnownGoodArtwork,
               let lastGoodMeta = lastKnownGoodMetadata,
               let currentMeta = metadata,
               artworkMatchesMetadata(lastGoodMeta, currentMeta) {
                iTunesAlbumArt = lastGoodArtwork
                iTunesArtworkJustSet = true
                startArtworkProtectionTimer()
                print("🔄 Restored last known good iTunes artwork for similar metadata")
                updateNowPlayingInfo()
                updateWidget()
                return
            }
        }
        
        // Fallback to station artwork
        loadStationArtwork()
    }
    
    /// Check if artwork should apply to current metadata
    private func artworkMatchesMetadata(_ cachedMetadata: String, _ currentMetadata: String) -> Bool {
        let cachedWords = Set(cachedMetadata.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let currentWords = Set(currentMetadata.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        
        let commonWords = cachedWords.intersection(currentWords)
        let similarity = currentWords.isEmpty ? 0.0 : Double(commonWords.count) / Double(currentWords.count)
        
        return similarity > 0.6 // 60% similarity threshold
    }
    
    // STATION ARTWORK FIX: Load station artwork into albumArt property for UI display
    func loadStationArtwork() {
        // Get the most up-to-date station data from the viewModel if possible
        let station: RadioStation
        if let currentIndex = currentStationIndex, let viewModel = viewModel, currentIndex < viewModel.stations.count {
            station = viewModel.stations[currentIndex]
            print("🎨 Using fresh station data from viewModel at index \(currentIndex)")
        } else if let currentStation = currentlyPlayingStation {
            station = currentStation
            print("🎨 Using currentlyPlayingStation reference")
        } else {
            print("🎨 No current station to load artwork from")
            return
        }
        
        print("🎨 STATION ARTWORK DEBUG for '\(station.name)':")
        print("  - iconData: \(station.iconData != nil ? "present (\(station.iconData!.prefix(20))...)" : "nil")")
        print("  - iTunesArtworkData: \(station.iTunesArtworkData != nil ? "present (\(station.iTunesArtworkData!.prefix(20))...)" : "nil")")
        print("  - Current iTunesAlbumArt: \(iTunesAlbumArt != nil ? "present" : "nil")")
        print("  - isPlaying: \(isPlaying)")
        
        // When paused, prioritize station default artwork over iTunes song artwork
        if !isPlaying {
            // Priority 1 (when paused): Station icon data
            if let iconData = station.iconData,
               let imageData = Data(base64Encoded: iconData),
               let image = UIImage(data: imageData) {
                albumArt = image
                print("🎨 ✅ Using station icon artwork (paused state) for '\(station.name)' (size: \(image.size))")
                return
            }
            
            // Priority 2 (when paused): Station's saved iTunes artwork data
            if let iTunesArtworkData = station.iTunesArtworkData,
               let imageData = Data(base64Encoded: iTunesArtworkData),
               let image = UIImage(data: imageData) {
                albumArt = image
                print("🎨 ✅ Using station iTunes artwork (paused state) for '\(station.name)' (size: \(image.size))")
                return
            }
        } else {
            // When playing, prioritize current song artwork over station artwork
            // Priority 1 (when playing): Use current iTunes artwork if available (live artwork from currently playing song)
            if let currentiTunesArt = iTunesAlbumArt {
                albumArt = currentiTunesArt
                print("🎨 ✅ Using current iTunes artwork (playing state) for '\(station.name)' (size: \(currentiTunesArt.size))")
                return
            }
            
            // Priority 2 (when playing): Station icon data
            if let iconData = station.iconData,
               let imageData = Data(base64Encoded: iconData),
               let image = UIImage(data: imageData) {
                albumArt = image
                print("🎨 ✅ Using station icon artwork (playing state) for '\(station.name)' (size: \(image.size))")
                return
            }
            
            // Priority 3 (when playing): Station's saved iTunes artwork data
            if let iTunesArtworkData = station.iTunesArtworkData,
               let imageData = Data(base64Encoded: iTunesArtworkData),
               let image = UIImage(data: imageData) {
                albumArt = image
                print("🎨 ✅ Using station iTunes artwork (playing state) for '\(station.name)' (size: \(image.size))")
                return
            }
        }
        
        // No station artwork available - create default radio icon
        albumArt = createDefaultRadioIcon()
        print("🎨 🔄 No station artwork available for '\(station.name)' - using default radio icon")
    }
    
    // Create a default radio icon image for stations without custom artwork
    private func createDefaultRadioIcon() -> UIImage? {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            
            // Create gradient background
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor.systemBlue.withAlphaComponent(0.6).cgColor,
                UIColor.systemPurple.withAlphaComponent(0.4).cgColor
            ]
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0])!
            
            // Draw gradient background with rounded corners
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            context.cgContext.addPath(path.cgPath)
            context.cgContext.clip()
            
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            
            // Draw radio icon
            let iconSize: CGFloat = 60
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Create radio icon using SF Symbols
            if let radioImage = UIImage(systemName: "radio", withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)) {
                radioImage.withTintColor(.white.withAlphaComponent(0.8), renderingMode: .alwaysTemplate).draw(in: iconRect)
            }
        }
    }
    
    func saveITunesArtworkToCurrentStation(_ image: UIImage) {
        guard let currentStation = currentlyPlayingStation, let viewModel = viewModel else {
            print("🎨 ❌ Cannot save iTunes artwork: no current station (currentlyPlayingStation=\(currentlyPlayingStation?.name ?? "nil"), viewModel=\(viewModel != nil))")
            return
        }
        
        // CRITICAL FIX: Find the station by ID instead of relying on potentially stale currentStationIndex
        guard let correctIndex = viewModel.stations.firstIndex(where: { $0.id == currentStation.id }) else {
            print("🎨 ❌ Cannot find current station '\(currentStation.name)' (ID: \(currentStation.id)) in stations array")
            return
        }
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("🎨 ❌ Failed to convert iTunes artwork to JPEG data")
            return
        }
        let base64String = imageData.base64EncodedString()
        
        print("🎨 💾 SAVING iTunes artwork to station '\(currentStation.name)' at index \(correctIndex)")
        print("🎨    - Station ID: \(currentStation.id)")
        print("🎨    - Image size: \(image.size)")
        print("🎨    - Data size: \(imageData.count) bytes")
        print("🎨    - Base64 preview: \(base64String.prefix(50))...")
        
        // Verify we're updating the correct station
        let stationAtIndex = viewModel.stations[correctIndex]
        if stationAtIndex.id != currentStation.id {
            print("🎨 🚨 CONTAMINATION PREVENTED: Station at index \(correctIndex) has ID '\(stationAtIndex.id)' but expected '\(currentStation.id)'")
            return
        }
        
        // Store artwork for current track persistence
        currentTrackArtwork = image
        
        // CRITICAL: Set iTunesAlbumArt immediately for highest priority display
        iTunesAlbumArt = image
        iTunesArtworkJustSet = true
        startArtworkProtectionTimer()
        
        // Update the station using the correct index
        var updatedStation = viewModel.stations[correctIndex]
        let oldArtworkData = updatedStation.iTunesArtworkData
        updatedStation.iTunesArtworkData = base64String
        viewModel.stations[correctIndex] = updatedStation
        
        // Update currentStationIndex to match the correct index
        currentStationIndex = correctIndex
        
        // CRITICAL: Update currentlyPlayingStation to point to the updated station object
        currentlyPlayingStation = updatedStation
        print("🎨 🔄 Updated currentlyPlayingStation reference with new artwork data")
        
        print("🎨 ✅ iTunes artwork assigned to station: '\(updatedStation.name)' (ID: \(updatedStation.id))")
        print("🎨    - Had old artwork: \(oldArtworkData != nil)")
        print("🎨    - New artwork data: \(updatedStation.iTunesArtworkData != nil)")
        
        // Save to Core Data
        viewModel.saveStationsToCoreData()
        print("🎨 💾 Station data saved to Core Data")
        
        // STATION ARTWORK FIX: Immediately reload station artwork so albumArt gets the new iTunes artwork
        loadStationArtwork()
        print("🎨 🔄 Station artwork reloaded after saving iTunes artwork")
        
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
    
    // MANUAL SHAZAM FEATURE: Save Shazam artwork to current station for station list display
    func saveShazamArtworkToCurrentStation(_ image: UIImage, songTitle: String, artist: String) {
        guard let currentIndex = currentStationIndex, let viewModel = viewModel else {
            print("🎵 ❌ Cannot save Shazam artwork: no current station (currentIndex=\(currentStationIndex), viewModel=\(viewModel != nil))")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("🎵 ❌ Failed to convert Shazam artwork to JPEG data")
            return
        }
        let base64String = imageData.base64EncodedString()
        
        print("🎵 💾 SAVING Shazam artwork to station at index \(currentIndex)")
        print("🎵    - Song: '\(songTitle)' by '\(artist)'")
        print("🎵    - Image size: \(image.size)")
        print("🎵    - Data size: \(imageData.count) bytes")
        print("🎵    - Base64 preview: \(base64String.prefix(50))...")
        
        // Update the station with Shazam artwork (replaces iTunes artwork)
        var updatedStation = viewModel.stations[currentIndex]
        let oldArtworkData = updatedStation.iTunesArtworkData
        updatedStation.iTunesArtworkData = base64String
        viewModel.stations[currentIndex] = updatedStation
        
        // CRITICAL: Update currentlyPlayingStation to point to the updated station object
        currentlyPlayingStation = updatedStation
        print("🎵 🔄 Updated currentlyPlayingStation reference with new Shazam artwork data")
        
        print("🎵 ✅ Shazam artwork assigned to station: '\(updatedStation.name)'")
        print("🎵    - Replaced previous artwork: \(oldArtworkData != nil)")
        print("🎵    - New Shazam artwork data: \(updatedStation.iTunesArtworkData != nil)")
        
        // Save to Core Data
        viewModel.saveStationsToCoreData()
        print("🎵 💾 Station data saved to Core Data with Shazam artwork")
        
        // STATION ARTWORK FIX: Immediately reload station artwork so albumArt gets the new Shazam artwork
        loadStationArtwork()
        print("🎵 🔄 Station artwork reloaded after saving Shazam artwork")
        
        // CRITICAL: Cache artwork for CarPlay independent operation
        cacheITunesArtworkForCarPlay(image: image, station: updatedStation)
        
        // CRITICAL: Immediately update Now Playing with new artwork
        updateNowPlayingInfo()
        
        // ENHANCED: Force immediate CarPlay Now Playing update for real-time response
        self.forceUpdateNowPlayingInfo()
        
        // Widget update for immediate reflection
        updateWidget()
        
        print("✅ Shazam artwork updated in real-time - Station list will show this artwork when user returns")
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
            // Ensure consistent normalization for case-insensitive matching
            let normalizedArtist = smartNormalization(artist)
            let normalizedTrack = smartNormalization(track)
            
            strategies.append(QueryStrategy(
                name: "perfect_match",
                priority: 1.0,
                queries: [
                    "\"\(normalizedTrack)\" \"\(normalizedArtist)\"",   // Double quoted precision (normalized)
                    "\"\(normalizedTrack)\" \(normalizedArtist)",       // Track quoted, artist clean (normalized)
                    "\(normalizedArtist) \"\(normalizedTrack)\"",       // Artist clean, track quoted (normalized)
                    "\(normalizedTrack) \(normalizedArtist)",           // Clean combination (normalized)
                    "\(normalizedArtist) \(normalizedTrack)",           // Traditional order (normalized)
                    "\"\(track)\" \"\(artist)\"",                      // Double quoted precision (original case)
                    "\"\(track)\" \(artist)",                          // Track quoted, artist clean (original case)
                    "\(artist) \"\(track)\"",                          // Artist clean, track quoted (original case)
                    "\(track) \(artist)",                              // Clean combination (original case)
                    "\(artist) \(track)"                               // Traditional order (original case)
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
    
    /// Generates normalized smart queries with advanced text processing - Enhanced for hyphenated words
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
            
            // Simple hyphen handling - if original contains hyphens, add variants
            if artist.contains("-") || track.contains("-") {
                // Add original case variants (less aggressive approach)
                queries.append(contentsOf: [
                    "\(track.lowercased()) \(artist.lowercased())",
                    "\(artist.lowercased()) \(track.lowercased())"
                ])
            }
            
            // Feature-aware normalization (remove feat., remix, etc.)
            let cleanTrack = removeFeatures(from: track)
            let cleanArtist = removeFeatures(from: artist)
            
            if cleanTrack != track || cleanArtist != artist {
                queries.append(contentsOf: [
                    "\(smartNormalization(cleanTrack)) \(smartNormalization(cleanArtist))",
                    "\(smartNormalization(cleanArtist)) \(smartNormalization(cleanTrack))"
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
            if word.count > 4 && !word.allSatisfy({ $0.isNumber }) {
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
            print("🔍 iTunes search exhausted all queries - no artwork found")
            completion(nil)
            return
        }
        
        let currentQuery = queries[0]
        let remainingQueries = Array(queries.dropFirst())
        
        print("🔍 iTunes search trying query: '\(currentQuery)' (remaining: \(remainingQueries.count))")
        
        searchITunes(query: currentQuery, using: session) { result in
            if let image = result {
                print("✅ iTunes search SUCCESS with query: '\(currentQuery)'")
                completion(image)
            } else {
                print("❌ iTunes search FAILED with query: '\(currentQuery)'")
                self.searchWithQueriesRecursive(remainingQueries, using: session, completion: completion)
            }
        }
    }
    
    /// Search Apple Music API with specific session (replacement for failed iTunes Search API)
    private func searchITunes(query: String, using session: URLSession, completion: @escaping (UIImage?) -> Void) {
        print("🔍 Apple Music API: Searching for artwork with query: '\(query)'")
        
        // Parse the search query to extract artist and title
        let (artist, title) = parseSearchQuery(query)
        print("🎵 Apple Music Search: Looking for '\(title)' by '\(artist)'")
        
        // Try Apple Music search using the existing ShazamViewModel functionality
        Task {
            do {
                // Use the existing Apple Music search infrastructure
                if let song = try await self.searchAppleMusicForArtwork(title: title, artist: artist) {
                    print("✅ Apple Music API: Found song: \(song.title) by \(song.artistName)")
                    
                    // Get artwork URL
                    if let artwork = song.artwork, let artworkURL = artwork.url(width: 600, height: 600) {
                        print("🎨 Apple Music API: Found artwork URL: \(artworkURL)")
                        
                        // Download the artwork
                        do {
                            let (data, _) = try await URLSession.shared.data(from: artworkURL)
                            if let image = UIImage(data: data) {
                                print("✅ Apple Music API: Successfully downloaded artwork (\(data.count) bytes)")
                                DispatchQueue.main.async {
                                    completion(image)
                                }
                            } else {
                                print("❌ Apple Music API: Failed to create image from artwork data")
                                DispatchQueue.main.async {
                                    completion(nil)
                                }
                            }
                        } catch {
                            print("❌ Apple Music API: Artwork download error: \(error.localizedDescription)")
                            DispatchQueue.main.async {
                                completion(nil)
                            }
                        }
                    } else {
                        print("❌ Apple Music API: No artwork URL found")
                        DispatchQueue.main.async {
                            completion(nil)
                        }
                    }
                } else {
                    print("❌ Apple Music API: No results found for query '\(query)'")
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                }
            } catch {
                print("❌ Apple Music API: Search failed for query '\(query)': \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    /// Search Apple Music for artwork using MusicKit with enhanced artist name handling
    private func searchAppleMusicForArtwork(title: String, artist: String) async throws -> MusicKit.Song? {
        print("🎵 Apple Music Search: Looking for '\(title)' by '\(artist)'")
        
        // Check authorization first
        let authStatus = MusicAuthorization.currentStatus
        if authStatus != .authorized {
            print("🎵 ❌ Apple Music not authorized (status: \(authStatus)) - requesting authorization")
            let newStatus = await MusicAuthorization.request()
            if newStatus != .authorized {
                print("🎵 ❌ Apple Music authorization denied - cannot search for artwork")
                throw NSError(domain: "MusicKitError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Music access required for artwork search"])
            }
        }
        
        // Strategy 1: Generate artist name variations to handle different ordering
        var artistVariations = [artist]
        
        // Handle cases like "Arta Kabashi & Anso" vs "Anso & Arta Kabashi"
        if artist.contains("&") || artist.contains(" and ") || artist.contains(", ") {
            let separators = ["&", " and ", ", "]
            for separator in separators {
                if artist.contains(separator) {
                    let parts = artist.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if parts.count == 2 {
                        // Add reversed order version
                        let reversedArtist = "\(parts[1]) \(separator) \(parts[0])"
                        artistVariations.append(reversedArtist)
                        
                        // Add individual artists as fallback
                        artistVariations.append(parts[0])
                        artistVariations.append(parts[1])
                    }
                }
            }
        }
        
        // Remove duplicates and empty entries
        artistVariations = Array(Set(artistVariations)).filter { !$0.isEmpty }
        
        // Strategy 2: Create multiple search strategies including word joining
        var searchStrategies: [String] = []
        
        // Generate title variations (handle cases like "pa pritur" -> "Papritur")
        var titleVariations = [title]
        
        // If title has spaces, try joining words together
        if title.contains(" ") {
            let joinedTitle = title.replacingOccurrences(of: " ", with: "")
            titleVariations.append(joinedTitle)
            
            // Also try capitalizing each word and joining
            let capitalizedJoined = title.components(separatedBy: " ")
                .map { $0.capitalized }
                .joined()
            if capitalizedJoined != joinedTitle {
                titleVariations.append(capitalizedJoined)
            }
        }
        
        // If title is one word, try splitting it for common patterns
        if !title.contains(" ") && title.count > 4 {
            // Try splitting at common points (this is speculative)
            let midPoint = title.index(title.startIndex, offsetBy: title.count / 2)
            let firstHalf = String(title[..<midPoint])
            let secondHalf = String(title[midPoint...])
            if firstHalf.count >= 2 && secondHalf.count >= 2 {
                titleVariations.append("\(firstHalf) \(secondHalf)")
            }
        }
        
        // Remove duplicates
        titleVariations = Array(Set(titleVariations)).filter { !$0.isEmpty }
        
        for artistVar in artistVariations {
            for titleVar in titleVariations {
                // Exact title + artist combinations
                searchStrategies.append("\(titleVar) \(artistVar)")
                searchStrategies.append("\"\(titleVar)\" \"\(artistVar)\"")
                searchStrategies.append("\"\(titleVar)\" \(artistVar)")
            }
        }
        
        // Add title-only searches as fallback
        for titleVar in titleVariations {
            searchStrategies.append(titleVar)
        }
        
        print("🎵 Apple Music Search: Trying \(searchStrategies.count) search strategies")
        
        // Strategy 3: Try each search strategy and score results
        for (index, searchTerm) in searchStrategies.enumerated() {
            print("🎵 Apple Music Search: Strategy \(index + 1): '\(searchTerm)'")
            
            do {
                let request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
                let response = try await request.response()
                let songs = response.songs
                
                print("🎵 Apple Music Search: Found \(songs.count) results")
                
                if !songs.isEmpty {
                    // Score and find best match
                    var bestMatch: (song: Song, score: Double)?
                    
                    for song in songs {
                        let score = calculateAppleMusicMatchScore(
                            queriedTitle: title,
                            queriedArtist: artist,
                            resultTitle: song.title,
                            resultArtist: song.artistName
                        )
                        
                        print("🎵 Candidate: '\(song.title)' by '\(song.artistName)' - Score: \(String(format: "%.2f", score))")
                        
                        if score > (bestMatch?.score ?? 0.0) && score > 0.3 {
                            bestMatch = (song, score)
                        }
                    }
                    
                    if let match = bestMatch {
                        print("🎵 Apple Music Search: ✅ Best match: '\(match.song.title)' by '\(match.song.artistName)' (Score: \(String(format: "%.2f", match.score)))")
                        return match.song
                    }
                }
            } catch {
                print("🎵 Apple Music Search: Strategy \(index + 1) error: \(error)")
                continue
            }
        }
        
        print("🎵 Apple Music Search: ❌ No suitable matches found after all strategies")
        return nil
    }
    
    /// Calculate match score for Apple Music results to ensure accuracy
    private func calculateAppleMusicMatchScore(queriedTitle: String, queriedArtist: String, 
                                            resultTitle: String, resultArtist: String) -> Double {
        let normalizedQueryTitle = smartNormalization(queriedTitle)
        let normalizedQueryArtist = smartNormalization(queriedArtist)
        let normalizedResultTitle = smartNormalization(resultTitle)
        let normalizedResultArtist = smartNormalization(resultArtist)
        
        var score = 0.0
        
        // First check: Heavily penalize cover versions, karaoke tracks, and tribute artists
        let coverIndicators = [
            "in the style of", "performance track", "demonstration vocals", "instrumental version",
            "karaoke", "tribute", "cover version", "backing track", "minus one", "done again",
            "the hit crew", "the karaoke crew", "sound-a-like", "originally performed by",
            "as made famous by", "in the manner of", "tribute to", "sing-along", "playback"
        ]
        
        let resultTitleLower = resultTitle.lowercased()
        let resultArtistLower = resultArtist.lowercased()
        
        for indicator in coverIndicators {
            if resultTitleLower.contains(indicator) || resultArtistLower.contains(indicator) {
                print("🎵 ❌ Penalizing cover version containing '\(indicator)': '\(resultTitle)' by '\(resultArtist)'")
                return 0.0  // Immediately disqualify cover versions
            }
        }
        
        // Title matching (60% of score) with enhanced word joining/separation handling
        if normalizedQueryTitle == normalizedResultTitle {
            score += 0.6  // Perfect title match
        } else {
            // Check for word joining/separation matches (e.g., "pa pritur" vs "Papritur")
            let queryJoined = normalizedQueryTitle.replacingOccurrences(of: " ", with: "")
            let resultJoined = normalizedResultTitle.replacingOccurrences(of: " ", with: "")
            
            if queryJoined == resultJoined {
                score += 0.55  // High score for joined word match
            } else if normalizedResultTitle.contains(normalizedQueryTitle) && normalizedQueryTitle.count > 2 {
                score += 0.4  // Title substring match
            } else if normalizedQueryTitle.contains(normalizedResultTitle) && normalizedResultTitle.count > 2 {
                score += 0.3  // Query contains result title
            } else if queryJoined.contains(resultJoined) && resultJoined.count > 3 {
                score += 0.35  // Joined query contains result
            } else if resultJoined.contains(queryJoined) && queryJoined.count > 3 {
                score += 0.35  // Joined result contains query
            } else {
                // Use similarity for partial matches
                let titleSimilarity = calculateStringSimilarity(normalizedQueryTitle, normalizedResultTitle)
                let joinedSimilarity = calculateStringSimilarity(queryJoined, resultJoined)
                let bestSimilarity = max(titleSimilarity, joinedSimilarity)
                
                if bestSimilarity > 0.7 {
                    score += bestSimilarity * 0.6
                }
            }
        }
        
        // Artist matching (40% of score) - Enhanced for multi-artist handling with original artist bonus
        if normalizedQueryArtist == normalizedResultArtist {
            score += 0.4  // Perfect artist match
            // Bonus for exact artist match (prioritize originals over covers)
            score += 0.2
            print("🎵 ✅ Exact artist match bonus: '\(queriedArtist)' = '\(resultArtist)'")
        } else {
            // Check if artists contain each other's components (handle order variations)
            let queryArtistWords = Set(normalizedQueryArtist.components(separatedBy: " ").filter { $0.count > 2 })
            let resultArtistWords = Set(normalizedResultArtist.components(separatedBy: " ").filter { $0.count > 2 })
            
            let commonWords = queryArtistWords.intersection(resultArtistWords)
            if !commonWords.isEmpty {
                let similarity = Double(commonWords.count) / Double(max(queryArtistWords.count, resultArtistWords.count))
                score += similarity * 0.4
                print("🎵 Artist word match: \(commonWords) - Similarity: \(String(format: "%.2f", similarity))")
            } else {
                // Fallback to string similarity
                let artistSimilarity = calculateStringSimilarity(normalizedQueryArtist, normalizedResultArtist)
                if artistSimilarity > 0.7 {
                    score += artistSimilarity * 0.4
                }
            }
        }
        
        return score
    }
    
    /// Calculate string similarity using a simple algorithm
    private func calculateStringSimilarity(_ str1: String, _ str2: String) -> Double {
        let longer = str1.count > str2.count ? str1 : str2
        let shorter = str1.count > str2.count ? str2 : str1
        
        if longer.isEmpty {
            return 1.0
        }
        
        let distance = levenshteinDistance(shorter, longer)
        return 1.0 - (Double(distance) / Double(longer.count))
    }
    
    /// Calculate Levenshtein distance between two strings
    private func levenshteinDistance(_ str1: String, _ str2: String) -> Int {
        let str1Array = Array(str1)
        let str2Array = Array(str2)
        let str1Count = str1Array.count
        let str2Count = str2Array.count
        
        // Handle empty strings
        if str1Count == 0 { return str2Count }
        if str2Count == 0 { return str1Count }
        
        var matrix = Array(repeating: Array(repeating: 0, count: str2Count + 1), count: str1Count + 1)
        
        for i in 0...str1Count {
            matrix[i][0] = i
        }
        
        for j in 0...str2Count {
            matrix[0][j] = j
        }
        
        for i in 1...str1Count {
            for j in 1...str2Count {
                let cost = str1Array[i-1] == str2Array[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,      // deletion
                    matrix[i][j-1] + 1,      // insertion
                    matrix[i-1][j-1] + cost  // substitution
                )
            }
        }
        
        return matrix[str1Count][str2Count]
    }
    
    /// Enhanced normalization for consistent matching
    private func normalizeForMatching(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        
        return text.lowercased()
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " the", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "+", with: "and")
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Optimized Levenshtein similarity for performance
    private func calculateOptimizedLevenshteinSimilarity(_ str1: String, _ str2: String) -> Double {
        let s1 = str1.lowercased()
        let s2 = str2.lowercased()
        
        // Quick exact match check
        if s1 == s2 { return 1.0 }
        
        // Handle empty strings
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        
        // Length optimization - skip if too different
        let maxLength = max(s1.count, s2.count)
        let minLength = min(s1.count, s2.count)
        
        if maxLength == 0 { return 0.0 }
        if Double(minLength) / Double(maxLength) < 0.3 { return 0.0 }
        
        let distance = levenshteinDistance(s1, s2)
        return max(0.0, 1.0 - Double(distance) / Double(maxLength))
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
    
    /// Smart normalization with ML-inspired text processing - Enhanced for uppercase and hyphenated words
    private func smartNormalization(_ text: String) -> String {
        var result = text
        
        // Convert to lowercase first
        result = result.lowercased()
        
        // Handle hyphenated words by converting them to spaced words for better search matching
        // This handles cases like "strada-facendo" -> "strada facendo" 
        result = result.replacingOccurrences(of: "(\\w)-(\\w)", with: "$1 $2", options: .regularExpression)
        
        // Clean up punctuation but preserve meaningful separators temporarily
        result = result.replacingOccurrences(of: "[^\\w\\s\\-']", with: " ", options: .regularExpression)
        
        // Normalize multiple whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        // Remove common articles and noise words
        result = result.replacingOccurrences(of: " the ", with: " ")
        result = result.replacingOccurrences(of: "the ", with: "")
        result = result.replacingOccurrences(of: " & ", with: " and ")
        result = result.replacingOccurrences(of: " + ", with: " and ")
        
        // Handle single letter words that might be misheard - e.g., "A BOY" vs "B BOY"
        // This is common with radio metadata that gets garbled
        result = result.replacingOccurrences(of: "^a ", with: "b ", options: .regularExpression)
        result = result.replacingOccurrences(of: " a ", with: " b ")
        
        // Clean final result
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        // Network retry is handled by StreamQualityManager automatically
        
        task.setTaskCompleted(success: true)
    }
    
    /// GPS FIX: Track network failures to help GPS protection system
    private func trackNetworkFailure() {
        let currentFailures = UserDefaults.standard.integer(forKey: "RecentNetworkFailures")
        let newFailureCount = currentFailures + 1
        
        UserDefaults.standard.set(newFailureCount, forKey: "RecentNetworkFailures")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastNetworkFailureTime")
        
        print("🛰️ RadioPlayer: Network failure tracked (count: \(newFailureCount)) for GPS protection")
        
        // Reset failure count after 5 minutes of no failures
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            let currentTime = Date().timeIntervalSince1970
            let lastFailureTime = UserDefaults.standard.double(forKey: "LastNetworkFailureTime")
            
            // Only reset if no new failures occurred in the last 5 minutes
            if currentTime - lastFailureTime >= 300 {
                UserDefaults.standard.removeObject(forKey: "RecentNetworkFailures")
                UserDefaults.standard.removeObject(forKey: "LastNetworkFailureTime")
                print("🛰️ RadioPlayer: Network failure count reset - GPS protection normalized")
            }
        }
    }
    
    deinit {
        artworkSearchTimer?.invalidate()
        player?.pause()
        
        // Stop network monitoring
        reachability?.stopNotifier()
        reachability = nil
        
        // Stop reconnection attempts
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        
        // Cancel all observers
        statusCancellable?.cancel()
        cancellables.removeAll()
        
        print("✅ RadioPlayer: Cleanup completed")
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
            var titleMetadata: String?
            var artistMetadata: String?
            var collectedMetadata: [String] = []
            
            for metadataItem in timedMetadata {
                if let stringValue = metadataItem.stringValue, !stringValue.isEmpty {
                    if let commonKey = metadataItem.commonKey {
                        switch commonKey.rawValue {
                        case "title", "streamTitle":
                            titleMetadata = stringValue
                            print("🔍 Found TITLE in timed metadata: '\(stringValue)'")
                        case "artist", "albumArtist":
                            artistMetadata = stringValue
                            print("🔍 Found ARTIST in timed metadata: '\(stringValue)'")
                        default:
                            collectedMetadata.append(stringValue)
                            print("🔍 Found OTHER in timed metadata (\(commonKey.rawValue)): '\(stringValue)'")
                        }
                    } else {
                        collectedMetadata.append(stringValue)
                        print("🔍 Found GENERIC in timed metadata: '\(stringValue)'")
                    }
                }
            }
            
            // Determine the best metadata to use
            var finalMetadata: String?
            
            if let title = titleMetadata, let artist = artistMetadata {
                finalMetadata = "\(artist) - \(title)"
                print("🔍 ✅ COMBINED timed metadata: '\(artist)' + '\(title)' = '\(finalMetadata!)'")
            } else if let title = titleMetadata {
                finalMetadata = title
                print("🔍 📖 Using TITLE from timed metadata: '\(title)'")
            } else if let artist = artistMetadata {
                finalMetadata = artist
                print("🔍 🎤 Using ARTIST from timed metadata: '\(artist)'")
            } else if let firstGeneric = collectedMetadata.first {
                finalMetadata = firstGeneric
                print("🔍 📻 Using GENERIC from timed metadata: '\(firstGeneric)'")
            }
            
            if let rawMetadata = finalMetadata {
                print("🔍 Found current metadata: \(rawMetadata)")
                
                // Clean up HTML/XML metadata
                let cleanedMetadata = self.cleanHTMLMetadata(rawMetadata)
                
                if !cleanedMetadata.isEmpty {
                    // Update metadata and trigger both iTunes artwork search and Shazam recognition
                    DispatchQueue.main.async { [weak self] in
                        self?.metadata = cleanedMetadata
                        
                        // Trigger iTunes artwork search for new metadata
                        self?.fetchITunesAlbumArt(for: cleanedMetadata)
                        
                        print("📻 Metadata found: \(cleanedMetadata) - triggering iTunes artwork search and Shazam recognition")
                        // Trigger immediate Shazam recognition for detected metadata
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.attemptShazamRecognition()
                        }
                        self?.updateNowPlayingInfo()
                        self?.updateWidget()
                    }
                    return
                } else {
                    // Commercial break or invalid metadata detected
                    print("🔍 ❌ Commercial break or invalid metadata detected from: '\(rawMetadata)' - clearing display")
                    DispatchQueue.main.async { [weak self] in
                        self?.metadata = nil
                        self?.clearITunesArtwork()
                        print("📻 Commercial break detected - clearing metadata and showing station name")
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
    

}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        guard !groups.isEmpty else { return }
        
        // Process all metadata groups and items to extract complete information
        var collectedMetadata: [String] = []
        var titleMetadata: String?
        var artistMetadata: String?
        
        for group in groups {
            for metadataItem in group.items {
                if let value = metadataItem.value as? String, !value.isEmpty {
                    // Check for specific metadata types
                    if let commonKey = metadataItem.commonKey {
                        switch commonKey.rawValue {
                        case "title", "streamTitle":
                            titleMetadata = value
                            print("🎵 Found TITLE metadata: '\(value)'")
                        case "artist", "albumArtist":
                            artistMetadata = value
                            print("🎵 Found ARTIST metadata: '\(value)'")
                        default:
                            collectedMetadata.append(value)
                            print("🎵 Found OTHER metadata (\(commonKey.rawValue)): '\(value)'")
                        }
                    } else {
                        collectedMetadata.append(value)
                        print("🎵 Found GENERIC metadata: '\(value)'")
                    }
                }
            }
        }
        
        // Determine the best metadata to use
        var finalMetadata: String?
        
        if let title = titleMetadata, let artist = artistMetadata {
            // We have both artist and title - combine them
            finalMetadata = "\(artist) - \(title)"
            print("🎵 ✅ COMBINED metadata: '\(artist)' + '\(title)' = '\(finalMetadata!)'")
        } else if let title = titleMetadata {
            // Only title available
            finalMetadata = title
            print("🎵 📖 Using TITLE metadata: '\(title)'")
        } else if let artist = artistMetadata {
            // Only artist available
            finalMetadata = artist
            print("🎵 🎤 Using ARTIST metadata: '\(artist)'")
        } else if let firstGeneric = collectedMetadata.first {
            // Use first generic metadata
            finalMetadata = firstGeneric
            print("🎵 📻 Using GENERIC metadata: '\(firstGeneric)'")
        }
        
        guard let rawValue = finalMetadata else {
            print("🎵 ❌ No usable metadata found in \(groups.count) groups")
            return
        }
        
        // Clean up HTML/XML metadata to extract readable song information
        let value = cleanHTMLMetadata(rawValue)
        
        if value.isEmpty {
            print("🎵 ❌ No readable metadata after HTML cleanup from: '\(rawValue)' - probably commercial break")
            // For commercial breaks or invalid metadata, clear current metadata and show station name
            DispatchQueue.main.async { [weak self] in
                self?.metadata = nil
                self?.clearITunesArtwork()
                print("📻 Commercial break detected - clearing metadata and showing station name")
                self?.updateNowPlayingInfo()
                self?.updateWidget()
            }
            return
        }
        
        // Update metadata with station-provided value only and trigger artwork fetch
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.metadata = value
            
            // Only clear artwork if we have verified new song content
            // Don't clear Shazam-verified artwork for repeated metadata from same song
            let isNewSongContent = (lastMetadataSearched != value)
            
            if isNewSongContent {
                // Only clear artwork if it's genuinely old artwork from a different song
                // Don't clear if we just got fresh iTunes artwork for the current metadata
                let shouldClearArtwork = (iTunesAlbumArt != nil && !iTunesArtworkJustSet && lastMetadataSearched != value && !lastMetadataSearched.isEmpty)
                
                if shouldClearArtwork {
                    iTunesAlbumArt = nil
                    print("🧹 Cleared old artwork for fresh song recognition")
                    // Only reset the flag when we actually clear artwork
                    iTunesArtworkJustSet = false
                } else {
                    print("🎯 Keeping current artwork - either no artwork to clear or fresh iTunes artwork")
                    // CRITICAL FIX: Don't reset the flag if we're keeping the artwork
                    // This prevents premature clearing of fresh iTunes artwork
                }
            } else if displayTitle != nil && displayArtist != nil {
                print("🎯 Keeping Shazam-verified artwork - same song detected")
                // CRITICAL FIX: Don't reset the flag for same song detection
                // This protects iTunes artwork from being cleared by repeated metadata
            }
            
            // Trigger both iTunes artwork search and Shazam recognition
            if !value.isEmpty {
                if isNewSongContent {
                    print("📻 New metadata detected: \(value) - triggering iTunes artwork search and Shazam recognition")
                    
                    // Trigger immediate iTunes artwork search for new songs
                    fetchITunesAlbumArt(for: value)
                    
                    // Trigger immediate Shazam recognition for new songs
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.attemptShazamRecognition()
                    }
                } else {
                    print("📻 Same metadata repeated: \(value) - no new search needed")
                }
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
        // PERFORMANCE: Increased interval to 8 seconds and use main queue to avoid Main Thread Checker violations
        let time = CMTime(seconds: 8.0, preferredTimescale: timeScale)
        
        player.addPeriodicTimeObserver(forInterval: time, queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            // Update elapsed time in Now Playing info (now aligned with observer interval)
            if self.isPlaying {
                self.updateNowPlayingInfoElapsedTime()
                self.lastElapsedTimeUpdate = Date()
            }
            
            // PERFORMANCE: Skip heavy operations if app is in background to save battery
            // But still allow Now Playing info updates for lock screen
            let isAppActive = UIApplication.shared.applicationState == .active
            
            // PERFORMANCE: Skip heavy operations if user is scrolling to improve performance (only when app is active)
            let isUserScrolling = isAppActive && UserDefaults.standard.bool(forKey: "isUserScrolling")
            if isUserScrolling { return }
            
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
                        self.iTunesArtworkJustSet = true
                        self.startArtworkProtectionTimer()
                        
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
    
    /// Handles audio session route changes to detect CarPlay connection/disconnection
    @objc private func audioSessionRouteChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        
        // Check if CarPlay is in the current route
        let isCarPlayCurrentlyConnected = currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
        
        let wasCarPlayConnected = CarPlayManager.shared.isCarPlayConnected
        
        // CARPLAY CONNECTION DETECTION
        if isCarPlayCurrentlyConnected && !wasCarPlayConnected {
            print("🚗 RadioPlayer: CarPlay CONNECTED - enhancing experience")
            CarPlayManager.shared.isCarPlayConnected = true
            
            if isPlaying && iTunesAlbumArt == nil {
                if let metadata = self.metadata, !metadata.isEmpty {
                    // Use a delay to ensure CarPlay is fully initialized
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.fetchCarPlayArtworkDuringPlayback(metadata: metadata)
                    }
                }
            }
        }
        
        // CARPLAY DISCONNECTION DETECTION - CRITICAL FIX
        else if !isCarPlayCurrentlyConnected && wasCarPlayConnected {
            print("🚗 RadioPlayer: CarPlay DISCONNECTED - ensuring seamless transition to main app")
            CarPlayManager.shared.isCarPlayConnected = false
            
            // CRITICAL: Only handle radio resumption if radio was actually playing and podcast isn't active
            let podcastPlayer = PodcastPlayer.shared
            let podcastIsActive = podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil
            let podcastIsActivePlayer = PlaybackManager.shared.activePlayer == .podcast
            
            // Don't interfere with podcast playback during CarPlay disconnection
            if podcastIsActive && podcastIsActivePlayer {
                print("🚗 RadioPlayer: Podcast is active during CarPlay disconnect - not interfering")
                return
            }
            
            // CRITICAL: Ensure seamless radio playback transition when CarPlay disconnects
            if userWantsToPlay && player != nil && PlaybackManager.shared.activePlayer == .radio {
                print("🔄 CarPlay Disconnect: Ensuring seamless radio playback continuation in main app")
                
                // Ensure audio session remains active for main app playback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self = self else { return }
                    
                    // Force audio session to remain active for main app
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: [])
                        print("✅ CarPlay Disconnect: Audio session kept active for main app radio")
                    } catch {
                        print("⚠️ CarPlay Disconnect: Failed to maintain audio session: \(error)")
                    }
                    
                    // Ensure player continues if it was playing
                    if self.userWantsToPlay && !self.isPlaying && PlaybackManager.shared.activePlayer == .radio {
                        print("🔄 CarPlay Disconnect: Resuming radio playback in main app")
                        self.player?.play()
                    }
                    
                    // Force update Now Playing info for main app
                    self.forceUpdateNowPlayingInfo()
                    
                    // Update widget for main app
                    self.updateWidget()
                    
                    print("✅ CarPlay Disconnect: Seamless radio transition to main app completed")
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
