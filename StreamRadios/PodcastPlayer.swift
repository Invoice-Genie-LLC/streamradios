//
//  PodcastPlayer.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/9/24.
//

import AVFoundation
import Combine
import CoreData
import MediaPlayer
import os
import Reachability
import SwiftUI

// Connection state for podcast player
enum PodcastConnectionState {
    case connected
    case connecting
    case disconnected
    case buffering
    case loading
    case error
}

public class PodcastPlayer: ObservableObject, AudioPlayerProtocol {
    @Published var currentEpisode: PodcastEpisode?
    @Published var isPlaying: Bool = false
    @Published var userWantsToPlay: Bool = false  // CRITICAL: Persistent user intent flag like RadioPlayer
    @Published var wasManuallyPaused: Bool = false  // Track if user manually paused to prevent auto-resume
    @Published var wasPlayingBeforeInterruption: Bool = false  // Track playback state before interruption
    @Published var loadingEpisodeId: String? = nil  // Track which episode is currently loading
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0.01
    @Published var currentFeed: PodcastFeed?
    @Published var currentProgress: Double = 0
    @Published var isInitialProgressLoad: Bool = false  // Tracks if this is initial progress loading vs active playback
    @Published var connectionState: PodcastConnectionState = .disconnected
    
    // Audio Settings
    @Published var playbackSpeed: Double = 1.0
    @Published var feedSpecificSettingsEnabled: Bool = false
    
    static let shared = PodcastPlayer()
    weak var radioPlayer: RadioPlayer?
    var player: AVPlayer?
    private let saveThreshold: Double = 0.05
    private var lastSavedProgress: Double = 0.0
    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastPlayer")
    weak var viewModel: PodcastViewModel?
    private var reachability: Reachability?
    @Published var isAttemptingReconnection: Bool = false
    private var reconnectionTimer: Timer?
    private let maxReconnectionAttempts = 5
    private var currentReconnectionAttempt = 0
    private var remoteCommandCenter: MPRemoteCommandCenter?
    @Published var currentEpisodeIndex: Int?
    private var allEpisodesInFeed: [PodcastEpisode] = []
    @Published var isPodcastActive: Bool = false
    private var nowPlayingUpdateTimer: Timer?
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 2.0
    private var lastReportedProgress: Double = 0
    private let stateManager = EpisodeStateManager.shared
    private var shouldStartFromBeginning: Bool = false
    private var lastCarPlayProgress: Double?
    
    // Track if position has been restored to prevent repeated calls during scrolling
    private var hasRestoredPositionForCurrentEpisode: Bool = false
    private var currentEpisodeIdForRestoration: String?

    // MARK: - Performance Optimization Properties
    private var isUserScrolling = false
    private var scrollDetectionTimer: Timer?
    private var lastScrollNotificationTime = Date()
    
    // Optimized update intervals for better performance
    private let lightUpdateInterval: TimeInterval = 1.0  // Set to 1.0s for smooth elapsed time display
    private let heavyUpdateInterval: TimeInterval = 15.0 // Increased from 10.0s to 15.0s to reduce CPU usage
    private let scrollingPauseInterval: TimeInterval = 30.0 // Pause heavy updates longer during scrolling
    
    // SELECTIVE CROSS-DEVICE SYNC: Only sync on pause, background, or app termination
    private var lastCrossDeviceSyncTime = Date.distantPast

    // Performance optimization flags
    private var isCarPlayActive: Bool {
        return CarPlayManager.shared.isCarPlayConnected
    }

    var remainingTime: Double {
            max(0, duration - currentTime)
        }
    
    private init() {
        // Load audio settings from UserDefaults
        playbackSpeed = UserDefaults.standard.double(forKey: "podcastPlaybackSpeed") != 0 ? 
                       UserDefaults.standard.double(forKey: "podcastPlaybackSpeed") : 1.0
        feedSpecificSettingsEnabled = false // Will be loaded per-feed when needed
        
        setupAudioSession()
               setupReachability()
               setupRemoteCommandCenter()
               // setupInterruptionHandling() - REMOVED: Now handled in setupCarPlayRouteChangeHandling
               setupTerminationHandling()
               setupCarPlayRouteChangeHandling()
               setupCrossDeviceProgressSync()
               
               // CRITICAL: Add comprehensive background audio session management like RadioPlayer
               setupBackgroundAudioObservers()
       }
    
    private func setupAudioSession() {
        // Audio session is now managed centrally by PlaybackManager
        // This method is kept for backward compatibility
        print("✅ Podcast: Audio session management delegated to PlaybackManager")
    }
    
    // CRITICAL: Add comprehensive background audio observers like RadioPlayer
    private func setupBackgroundAudioObservers() {
        // CRITICAL: Add app lifecycle observers for background audio session maintenance
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        // CRITICAL: Add memory warning observer to prevent termination during podcast playback
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        
        print("✅ PodcastPlayer: Background audio observers configured")
    }
    
    @objc private func handleAppDidEnterBackground() {
        // Simplified background handling to prevent deadlocks and main thread blocking
        if isPlaying && userWantsToPlay {
            print("🔧 PodcastPlayer: App entering background - podcast playback active")
            DebugLogger.logInfo("App entering background with active podcast playback - delegating to AppDelegate for centralized background task management", category: "BackgroundAudio")
            DebugLogger.setUserAction("Podcast Background Transition")
            
            // Log current episode context for debugging
            let episodeTitle = currentEpisode?.title ?? "Unknown"
            let currentProgress = self.currentProgress
            DebugLogger.logInfo("Background transition context - Episode: \(episodeTitle), Progress: \(currentProgress)%, Duration: \(duration)s", category: "BackgroundAudio")
            
            // Don't create competing background tasks - let AppDelegate handle this centrally
            // Move audio session configuration to background queue to avoid main thread IPC delays
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // MAIN THREAD FIX: Configure audio session on background queue to avoid IPC delays
                    try audioSession.setCategory(.playback, 
                                               mode: .default, 
                                               options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    
                    DispatchQueue.main.async {
                        print("✅ PodcastPlayer: Background transition handled - audio session category set")
                        DebugLogger.logInfo("Podcast background transition completed - centralized task management active", category: "BackgroundAudio")
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("❌ PodcastPlayer: Audio session check failed: \(error)")
                        DebugLogger.logError("Audio session verification failed during podcast background transition: \(error.localizedDescription)", category: "BackgroundAudio")
                    }
                }
            }
        } else {
            DebugLogger.logInfo("App entering background with no active podcast playback - no background maintenance needed", category: "BackgroundAudio")
        }
    }
    
    @objc private func handleAppWillEnterForeground() {
        // CRITICAL FIX: Only restore playback if it was interrupted by the system, not if user paused
        // We should only resume if:
        // 1. User wants to play (userWantsToPlay = true)
        // 2. Player is not currently playing (was interrupted)
        // 3. Was NOT manually paused by user
        if userWantsToPlay && !isPlaying && !wasManuallyPaused {
            print("🔧 PodcastPlayer: App entering foreground - restoring podcast playback if needed")
            DebugLogger.logInfo("App entering foreground with podcast playback intent - checking restoration needs", category: "BackgroundAudio")
            DebugLogger.setUserAction("Podcast Foreground Transition")
            
            // Check if we need to restart playback (only if it was system-interrupted, not user-paused)
            if player != nil {
                DebugLogger.logWarning("Podcast playback was interrupted during background - attempting restoration", category: "BackgroundAudio")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { 
                        DebugLogger.logError("PodcastPlayer instance lost during foreground restoration", category: "BackgroundAudio")
                        return 
                    }
                    
                    do {
                        // Reactivate audio session
                        PlaybackManager.shared.setActivePlayer(.podcast)
                        
                        // Resume playback only if user wants it and it wasn't manually paused
                        if self.userWantsToPlay && !self.wasManuallyPaused {
                            self.player?.play()
                            print("✅ PodcastPlayer: Podcast playback resumed after foreground transition")
                            DebugLogger.logInfo("Podcast playback successfully restored after foreground transition", category: "BackgroundAudio")
                        }
                    } catch {
                        DebugLogger.logError("Failed to restore podcast playback during foreground transition: \(error.localizedDescription)", category: "BackgroundAudio")
                    }
                }
            }
        } else if isPlaying {
            DebugLogger.logInfo("Podcast playback continued seamlessly during background/foreground transition", category: "BackgroundAudio")
        } else if wasManuallyPaused {
            DebugLogger.logInfo("Podcast was manually paused by user - not resuming automatically", category: "BackgroundAudio")
        } else {
            DebugLogger.logInfo("App entering foreground with no podcast playback intent", category: "BackgroundAudio")
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        // CRITICAL: Handle lock screen alarm scenarios where interruption end notifications may be missed
        // This catches cases where alarms interrupt audio during lock screen and app becomes active after snooze
        if wasPlayingBeforeInterruption && userWantsToPlay && !isPlaying && !wasManuallyPaused {
            print("🔧 PodcastPlayer: App became active after potential lock screen interruption - checking resume")
            DebugLogger.logInfo("App became active with interrupted podcast playback - attempting lock screen alarm resume", category: "LockScreenAudio")
            DebugLogger.setUserAction("Lock Screen Alarm Resume")
            
            // Delay to ensure system is ready after alarm dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { 
                    DebugLogger.logError("PodcastPlayer instance lost during lock screen resume", category: "LockScreenAudio")
                    return 
                }
                
                // Double-check conditions are still valid
                if self.wasPlayingBeforeInterruption && self.userWantsToPlay && !self.isPlaying && !self.wasManuallyPaused {
                    print("🔄 PodcastPlayer: Attempting lock screen alarm resume")
                    DebugLogger.logInfo("Executing lock screen alarm resume for podcast", category: "LockScreenAudio")
                    
                    // Use the existing resume method
                    self.resumeAfterInterruption()
                } else {
                    DebugLogger.logInfo("Lock screen resume conditions no longer met - skipping resume", category: "LockScreenAudio")
                }
            }
        } else {
            // Log why we're not resuming for debugging
            if !wasPlayingBeforeInterruption {
                DebugLogger.logInfo("App became active but podcast was not playing before interruption", category: "LockScreenAudio")
            } else if !userWantsToPlay {
                DebugLogger.logInfo("App became active but user does not want podcast playback", category: "LockScreenAudio")
            } else if isPlaying {
                DebugLogger.logInfo("App became active and podcast is already playing", category: "LockScreenAudio")
            } else if wasManuallyPaused {
                DebugLogger.logInfo("App became active but podcast was manually paused by user", category: "LockScreenAudio")
            }
        }
    }
    
    @objc private func handleMemoryWarning() {
        // CRITICAL FIX: Handle memory warnings to prevent app termination during podcast playback
        print("⚠️ PodcastPlayer: Memory warning received - optimizing for background audio")
        
        let memoryUsage = ProcessInfo.processInfo.physicalMemory
        let availableMemory = ProcessInfo.processInfo.systemUptime
        
        DebugLogger.logWarning("CRITICAL: Memory warning received during podcast playback - System Memory: \(memoryUsage / 1024 / 1024)MB, Uptime: \(availableMemory)s", category: "MemoryPressure")
        DebugLogger.setUserAction("Memory Warning During Podcast Playback")
        
        // Log current playback state for debugging
        let episodeTitle = currentEpisode?.title ?? "None"
        DebugLogger.logInfo("Memory warning context - Podcast playing: \(isPlaying), User wants playback: \(userWantsToPlay), Current episode: \(episodeTitle)", category: "MemoryPressure")
        
        // Clear non-essential data to free memory
        clearNonEssentialPodcastData()
        
        // Force garbage collection
        DispatchQueue.global(qos: .background).async {
            // Perform heavy cleanup on background queue
            self.optimizePodcastMemoryUsage()
            DebugLogger.logInfo("Background podcast memory optimization completed", category: "MemoryPressure")
        }
    }
    
    private func clearNonEssentialPodcastData() {
        // Clear cached metadata that can be refetched (but preserve playback state)
        if !isPlaying {
            // Only clear if not actively playing
            allEpisodesInFeed.removeAll()
            print("🧹 PodcastPlayer: Cleared episode cache due to memory pressure")
            DebugLogger.logInfo("Cleared episode cache due to memory pressure (podcast not playing)", category: "MemoryPressure")
        } else {
            DebugLogger.logWarning("Memory warning during active podcast playback - limited cleanup to preserve audio", category: "MemoryPressure")
        }
    }
    
    private func optimizePodcastMemoryUsage() {
        // Perform memory optimization on background thread
        print("🧹 PodcastPlayer: Optimizing memory usage for background stability")
        DebugLogger.logInfo("Starting background podcast memory optimization to prevent app termination", category: "MemoryPressure")
        
        // Clear any cached network responses or temporary data
        let cacheSize = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        URLCache.shared.removeAllCachedResponses()
        DebugLogger.logInfo("Cleared URL cache during podcast memory optimization - freed \(cacheSize / 1024)KB of memory", category: "MemoryPressure")
        
        // Force memory cleanup
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            DebugLogger.logInfo("Podcast memory optimization completed - UI state refreshed", category: "MemoryPressure")
        }
    }
    
    private func setupReachability() {
           do {
               reachability = try Reachability()
               reachability?.whenReachable = { [weak self] reachability in
                   os_log("🌐 PodcastPlayer: Network became reachable", log: self?.log ?? OSLog.default, type: .info)
                   self?.handleNetworkReconnection()
               }
               reachability?.whenUnreachable = { [weak self] _ in
                   os_log("🌐 PodcastPlayer: Network became unreachable", log: self?.log ?? OSLog.default, type: .info)
                   self?.handleNetworkDisconnection()
               }
               try reachability?.startNotifier()
           } catch {
               os_log("Unable to start reachability notifier: %@", log: log, type: .error, error.localizedDescription)

           }
       }
       
           private func handleNetworkDisconnection() {
        os_log("🌐 PodcastPlayer: Handling network disconnection", log: log, type: .info)
        
        // Stop any ongoing reconnection attempts
        stopReconnectionAttempts()
        
        // Pause playback if we're playing from a remote URL (not local file)
        if isPlaying && userWantsToPlay {
            if let currentEpisode = currentEpisode {
                // Check if we're playing from a local file (offline) or streaming
                let isPlayingLocalFile = currentEpisode.localFilePath != nil && !currentEpisode.localFilePath!.isEmpty
                if !isPlayingLocalFile {
                    os_log("🌐 PodcastPlayer: Network lost during streaming, pausing playback", log: log, type: .info)
                    player?.pause()
                    isPlaying = false
                    // Keep userWantsToPlay = true so we can resume when network returns
                    // Show connecting state to indicate we're waiting to reconnect (spinning button)
                    connectionState = .connecting
                } else {
                    os_log("🌐 PodcastPlayer: Network lost but playing local file, continuing playback", log: log, type: .info)
                    // For local files, we can continue playing even without network
                    connectionState = .connected
                }
            }
        } else if userWantsToPlay && currentEpisode != nil {
            // User wants to play but isn't currently playing - show connecting state (spinning button)
            os_log("🌐 PodcastPlayer: Network lost while user wants to play, showing connecting state", log: log, type: .info)
            connectionState = .connecting
        } else {
            // User doesn't want to play or no episode - show disconnected state
            connectionState = .disconnected
        }
    }
    
    // REMOVED: Old setupInterruptionHandling - now handled in setupCarPlayRouteChangeHandling with better CarPlay support
    
    private func setupTerminationHandling() {
        // Listen for app termination notifications
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.willTerminateNotification,
                                             object: nil)
        
        // Also listen for when app goes to background (force close might trigger this first)
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.didEnterBackgroundNotification,
                                             object: nil)
        
        // Listen for when app resigns active state
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppTermination),
                                             name: UIApplication.willResignActiveNotification,
                                             object: nil)
    }
    
    private func setupCarPlayRouteChangeHandling() {
        // Listen for audio session route changes (CarPlay connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // CRITICAL: Handle audio interruptions to prevent CarPlay disconnection from pausing podcast
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        print("🚗 PodcastPlayer: CarPlay route change and audio interruption monitoring setup complete")
    }
    
    private func setupCrossDeviceProgressSync() {
        // Listen for real-time progress changes from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCrossDeviceProgressSync(_:)),
            name: .init("EpisodeProgressChangedInstantly"),
            object: nil
        )
        
        // Listen for enhanced cross-device progress updates via CloudKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCrossDeviceProgressUpdate(_:)),
            name: .init("CrossDeviceProgressUpdate"),
            object: nil
        )
        
        print("🔄 PodcastPlayer: Cross-device progress sync monitoring setup complete")
    }
    
    // REMOVED: Old handleInterruption method replaced with handleAudioInterruption for better CarPlay support
    
    @objc private func handleCrossDeviceProgressSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let newProgress = userInfo["progress"] as? Double,
              let currentEpisode = currentEpisode,
              currentEpisode.id == episodeId,
              isPlaying else {
            return
        }
        
        // Get the current progress threshold for sync
        let currentPlayerProgress = currentProgress
        let progressDifference = abs(newProgress - currentPlayerProgress)
        
        // Only sync if the difference is significant (more than 5 seconds worth of content)
        let significantDifferenceThreshold = duration > 0 ? (5.0 / duration) : 0.05
        
        if progressDifference > significantDifferenceThreshold {
            let newTime = newProgress * duration
            
            // CRITICAL FIX: Check if we're in chapter protection period before allowing CloudKit sync
            let isChapterProtected = isInChapterProtectionPeriod()
            
            if isChapterProtected {
                os_log("🛡️ CLOUDKIT SYNC BLOCKED: Skipping cross-device sync during chapter protection (%.2f%% -> %.2f%% blocked)", 
                       log: log, type: .info, currentPlayerProgress * 100, newProgress * 100)
                return // Block CloudKit sync during chapter seeks
            }
            
            // CRITICAL FIX: Check if we're in navigation protection period before allowing CloudKit sync
            let isNavigationProtected = isInNavigationProtectionPeriod()
            
            print("🔍 DEBUG: CloudKit sync check - chapter protected: \(isChapterProtected), navigation protected: \(isNavigationProtected)")
            if let lastNavTime = lastNavigationTime {
                let timeSinceNav = Date().timeIntervalSince(lastNavTime)
                print("🔍 DEBUG: Time since navigation: \(timeSinceNav) seconds (protection: \(navigationProtectionInterval) seconds)")
            } else {
                print("🔍 DEBUG: No navigation time recorded")
            }
            
            if isNavigationProtected {
                print("🛡️ DEBUG: CLOUDKIT SYNC BLOCKED due to navigation protection")
                os_log("🛡️ CLOUDKIT SYNC BLOCKED: Skipping cross-device sync during navigation protection (%.2f%% -> %.2f%% blocked)", 
                       log: log, type: .info, currentPlayerProgress * 100, newProgress * 100)
                return // Block CloudKit sync during app navigation
            }
            
            os_log("🔄 Cross-device sync: Updating playback position from %.2f%% to %.2f%% (%.1f seconds)", 
                   log: log, type: .info, currentPlayerProgress * 100, newProgress * 100, newTime)
            
            // Update the player position to match the new progress from other device
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.currentTime = newTime
                self.currentProgress = newProgress
                
                // Seek to the new position
                self.player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 1), 
                                toleranceBefore: .zero, 
                                toleranceAfter: .zero) { completed in
                    if completed {
                        DispatchQueue.main.async {
                            self.updateNowPlayingInfo()
                            os_log("✅ Cross-device sync: Successfully synced to %.2f%% (%.1f seconds)", 
                                   log: self.log, type: .info, newProgress * 100, newTime)
                        }
                    }
                }
            }
        }
    }
    
    /// Check for the latest progress from other devices when resuming playback
    private func checkForLatestCrossDeviceProgress(for episodeId: String) async {
        // Use CloudKit manager to check for latest progress
        await PodcastCloudKitManager.shared.checkForLatestProgress(for: episodeId) { [weak self] remoteProgress in
            guard let self = self else { return }
            
            // Get current local progress
            let localProgress = self.stateManager.getProgress(for: episodeId)
            let progressDiff = abs(remoteProgress - localProgress)
            
            // If remote progress is significantly different, use it
            if progressDiff > 0.01 { // 1% difference
                
                // Update local state with the latest progress
                self.stateManager.setProgress(for: episodeId, progress: remoteProgress)
            } else {
            }
        }
    }
    
    /// Enhanced cross-device progress sync handler for real-time CloudKit updates
    @objc private func handleCrossDeviceProgressUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let newProgress = userInfo["progress"] as? Double,
              let timestamp = userInfo["timestamp"] as? Double,
              let source = userInfo["source"] as? String,
              source == "remote_device" else {
            return
        }
        
        
        // Check if this update is for the currently loaded episode (whether playing or paused)
        guard let currentEpisode = currentEpisode, currentEpisode.id == episodeId else {
            // Not the current episode - just log and return
            return
        }
        
        // Check if update is recent enough (within last 60 seconds)
        let currentTime = Date().timeIntervalSince1970
        if currentTime - timestamp > 60 {
            return
        }
        
        // Calculate time difference to determine if we should sync
        let currentPlayerProgress = currentProgress
        let progressDifference = abs(newProgress - currentPlayerProgress)
        let timeDifference = progressDifference * duration
        
        // ENHANCED: Sync if difference is more than 3 seconds OR if other device is significantly ahead
        let shouldSync = timeDifference > 3.0 || (newProgress > currentPlayerProgress && progressDifference > 0.01)
        
        if shouldSync {
            let newTime = newProgress * duration
            
            os_log("📡 ⚡ REALTIME SYNC: Player position %.2f%% -> %.2f%% (%.1fs)", 
                   log: log, type: .info, currentPlayerProgress * 100, newProgress * 100, newTime)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Update local state first
                self.currentTime = newTime
                self.currentProgress = newProgress
                
                // If we have an active player, seek to the new position
                if let player = self.player {
                    player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1000), 
                              toleranceBefore: .zero, 
                              toleranceAfter: .zero) { completed in
                        if completed {
                            DispatchQueue.main.async {
                                self.updateNowPlayingInfo()
                            }
                        } else {
                        }
                    }
                } else {
                    // No active player, just update the state for when playback resumes
                }
            }
        } else {
        }
    }
    
    @objc private func handleAppTermination(notification: Notification) {
        // Handle different app lifecycle events to ensure progress is saved
        os_log("App lifecycle event detected: %@", log: log, type: .info, notification.name.rawValue)
        
        if notification.name == UIApplication.willTerminateNotification ||
           notification.name == UIApplication.didEnterBackgroundNotification ||
           notification.name == UIApplication.willResignActiveNotification {
            
            // REAL-TIME SYNC: Sync when app goes to background or terminates
            let reason: String
            switch notification.name {
            case UIApplication.willTerminateNotification:
                reason = "app_closed"
            case UIApplication.didEnterBackgroundNotification:
                reason = "app_background"
            case UIApplication.willResignActiveNotification:
                reason = "app_background"
            default:
                reason = "app_background"
            }
            
            // REAL-TIME SYNC: Trigger immediate sync for app lifecycle events
            if let currentEpisode = currentEpisode {
                // CRITICAL FIX: Use currentProgress instead of recalculating to preserve chapter seek progress
                let progress = currentProgress > 0 ? currentProgress : (duration > 0 ? currentTime / duration : 0)
                stateManager.setProgressWithRealTimeSync(for: currentEpisode.id, progress: progress, reason: reason, feedId: currentEpisode.feedId)
                

            }
            
            // Ensure progress is saved when app is force closed or goes to background
            handleAppWillTerminate()
            
            // Additional safety: Force save to UserDefaults
            UserDefaults.standard.synchronize()
        }
    }
    
    /// Handles audio session route changes to detect CarPlay connection/disconnection
    @objc private func audioSessionRouteChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let _ = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        
        // Check if CarPlay is in the current route
        let isCarPlayCurrentlyConnected = currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
        
        let wasCarPlayConnected = CarPlayManager.shared.isCarPlayConnected
        
        // CARPLAY CONNECTION DETECTION
        if isCarPlayCurrentlyConnected && !wasCarPlayConnected {
            print("🚗 PodcastPlayer: CarPlay CONNECTED - enhancing experience")
            CarPlayManager.shared.isCarPlayConnected = true
        }
        
        // CARPLAY DISCONNECTION DETECTION - CRITICAL FIX
        else if !isCarPlayCurrentlyConnected && wasCarPlayConnected {
            print("🚗 PodcastPlayer: CarPlay DISCONNECTED - ensuring seamless transition to main app")
            CarPlayManager.shared.isCarPlayConnected = false
            
            // CRITICAL: Ensure seamless playback transition when CarPlay disconnects
            if player != nil && currentEpisode != nil {
                let wasPlayingBeforeDisconnect = isPlaying || player?.timeControlStatus == .playing
                print("🔄 CarPlay Disconnect: Podcast was playing: \(wasPlayingBeforeDisconnect)")
                
                // AGGRESSIVE: Always try to maintain podcast playback during CarPlay disconnection
                // Even if it wasn't playing, if there's a current episode, keep it visible
                print("🔄 CarPlay Disconnect: Ensuring seamless podcast transition to main app")
                
                // IMMEDIATE: Force audio session to remain active and continue playback
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // CRITICAL: Set podcast as active player FIRST to maintain UI visibility
                    PlaybackManager.shared.setActivePlayer(.podcast)
                    print("🚗 CarPlay Disconnect: Set podcast as active player immediately")
                    
                    // Aggressively maintain audio session for seamless transition
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: [])
                        print("✅ CarPlay Disconnect: Audio session kept active for main app podcast")
                    } catch {
                        print("⚠️ CarPlay Disconnect: Failed to maintain audio session: \(error)")

                    }
                    
                    // CRITICAL: Force player to continue/resume playback if it was playing
                    if wasPlayingBeforeDisconnect {
                        if self.player?.timeControlStatus != .playing {
                            print("🔄 CarPlay Disconnect: Force resuming podcast playback in main app")
                            self.player?.play()
                        }
                        
                        // AGGRESSIVE: Ensure isPlaying state is correct and maintained
                        self.isPlaying = true
                    }
                    
                    // Force update Now Playing info for main app immediately
                    self.updateNowPlayingInfo()
                    
                    // Force UI refresh to show podcast player
                    self.objectWillChange.send()
                    
                    print("✅ CarPlay Disconnect: Aggressive podcast transition to main app completed")
                }
                
                // BACKUP: Multiple checks to ensure everything is maintained
                for delay in [0.3, 0.8, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        
                        // Ensure PlaybackManager still has podcast as active player
                        if PlaybackManager.shared.activePlayer != .podcast && self.currentEpisode != nil {
                            print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Restoring podcast as active player")
                            PlaybackManager.shared.setActivePlayer(.podcast)
                        }
                        
                        // Resume playback if it was playing and got stopped
                        if wasPlayingBeforeDisconnect && self.player?.timeControlStatus != .playing && self.currentEpisode != nil {
                            print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Force resuming podcast playback")
                            self.player?.play()
                            self.isPlaying = true
                        }
                        
                        // Ensure UI state is maintained for current episode
                        if self.currentEpisode != nil && PlaybackManager.shared.activePlayer == .podcast {
                            if wasPlayingBeforeDisconnect && !self.isPlaying {
                                print("🔄 CarPlay Disconnect BACKUP (\(delay)s): Restoring playing state")
                                self.isPlaying = true
                                self.objectWillChange.send()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func handleNetworkReconnection() {
        // Only attempt reconnection if the user wants to play and we have an episode
        guard userWantsToPlay, let currentEpisode = currentEpisode else {
            os_log("Network reconnection skipped - user doesn't want to play or no current episode", log: log, type: .info)
            connectionState = .connected
            return
        }
        
        // Check if we're playing from a remote URL (not local file)
        let isPlayingLocalFile = currentEpisode.localFilePath != nil && !currentEpisode.localFilePath!.isEmpty
        
        // If we're not currently playing and not playing a local file, attempt to resume
        if !isPlaying && !isPlayingLocalFile {
            os_log("🌐 PodcastPlayer: Network reconnected, attempting to resume streaming playback", log: log, type: .info)
            connectionState = .connecting
            isAttemptingReconnection = true
            currentReconnectionAttempt = 0
            attemptReconnection()
        } else if isPlayingLocalFile {
            os_log("🌐 PodcastPlayer: Network reconnected, local file playback continuing", log: log, type: .info)
            connectionState = .connected
        } else {
            // Already playing, just update state
            connectionState = .connected
        }
    }
    
    private func attemptReconnection() {
        guard currentReconnectionAttempt < maxReconnectionAttempts else {
            stopReconnectionAttempts()
            return
        }
        
        guard let currentEpisode = currentEpisode else {
            os_log("No current episode available for reconnection", log: log, type: .error)
            stopReconnectionAttempts()
            return
        }
        
        currentReconnectionAttempt += 1
        os_log("🔄 PodcastPlayer: Attempting reconnection %d of %d for episode: %@", 
               log: log, type: .info, currentReconnectionAttempt, maxReconnectionAttempts, currentEpisode.title)
        
        // Try to resume playback
        play()
        
        // Check if reconnection was successful after a delay
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.checkReconnectionStatus()
        }
    }
    
    private func checkReconnectionStatus() {
        if player?.timeControlStatus == .playing && isPlaying {
            os_log("✅ PodcastPlayer: Network reconnection successful", log: log, type: .info)
            connectionState = .connected
            stopReconnectionAttempts()
        } else {
            os_log("⚠️ PodcastPlayer: Reconnection attempt failed, trying again...", log: log, type: .info)
            attemptReconnection()
        }
    }
    
    private func stopReconnectionAttempts() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        isAttemptingReconnection = false
        currentReconnectionAttempt = 0
        
        if player?.timeControlStatus != .playing {
            os_log("❌ PodcastPlayer: Failed to reconnect after %d attempts", log: log, type: .error, maxReconnectionAttempts)
            connectionState = .error
            // Don't clear userWantsToPlay so they can try again manually
        } else {
            connectionState = .connected
        }
    }
    
    func setupRemoteCommandCenter() {
        configurePodcastRemoteCommands()
        os_log("Podcast Remote Command Center configured for CarPlay", log: log, type: .info)
    }
    
    // MARK: - Force Remote Command Center Configuration for Podcast
    func configurePodcastRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear any existing targets first
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        
        // Clear navigation command targets for episode list navigation
        commandCenter.bookmarkCommand.removeTarget(nil)
        if #available(iOS 16.0, *) {
            commandCenter.likeCommand.removeTarget(nil)
        }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.play()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.pause()
                return .success
            }
            return .commandFailed
        }
        
        // REMOVED: Episode skip functionality - only time scrubbing allowed
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        
        // Enable skip forward command (for seeking within episodes)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipForward()
                return .success
            }
            return .commandFailed
        }
        
        // Enable skip backward command (for seeking within episodes)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.skipBackward()
                return .success
            }
            return .commandFailed
        }
        
        // CRITICAL: Enable toggle play/pause command for CarPlay
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.togglePlayPause()
                os_log("Remote Command: Toggle play/pause executed", log: self?.log ?? OSLog.default, type: .info)
                return .success
            }
            return .commandFailed
        }
        
        // Enable navigation to episode list via bookmark button in lock screen
        commandCenter.bookmarkCommand.isEnabled = true
        commandCenter.bookmarkCommand.localizedTitle = "Episodes"
        commandCenter.bookmarkCommand.addTarget { [weak self] _ in
            if PlaybackManager.shared.activePlayer == .podcast {
                self?.navigateToFeedEpisodeList()
                os_log("Remote Command: Navigate to episode list via bookmark button", log: self?.log ?? OSLog.default, type: .info)
                return .success
            }
            return .commandFailed
        }
        
        // Disable commands that don't make sense for podcasts
        commandCenter.stopCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        
        os_log("✅ Remote Command Center configured for Podcast - Skip Forward/Backward enabled, Station navigation disabled", log: log, type: .info)
    }
    
    // MARK: - Navigation Handler
    
    /// Navigates to the podcast episode list for the currently playing feed
    /// This is triggered when the user taps on the feed description in the lock screen
    private func navigateToFeedEpisodeList() {
        guard let currentEpisode = currentEpisode,
              let currentFeed = currentFeed else {
            os_log("Cannot navigate: no current episode or feed", log: log, type: .error)
            return
        }
        
        os_log("🧭 Navigating to feed episode list from lock screen: %@", log: log, type: .info, currentFeed.title)
        
        // Handle navigation on the main thread
        DispatchQueue.main.async { [weak self] in
            // Save current progress before navigating
            self?.handleNavigationAway()
            
            // Post notification to navigate to podcast tab and select the current feed
            NotificationCenter.default.post(
                name: .navigateToPodcastFeed, 
                object: nil, 
                userInfo: [
                    "feedId": currentFeed.id,
                    "episodeId": currentEpisode.id
                ]
            )
        }
    }
    
        private func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
        guard let viewModel = viewModel else {
                os_log("ViewModel is not set", log: log, type: .error)
                return
            }
            
            // PERFORMANCE: Use optimized feed refresh instead of expensive operations
            Task { @MainActor in
                viewModel.requestFeedRefresh(feed.id)
            }
            
            Task { @MainActor in
                // PERFORMANCE: Get episodes from snapshot if available, otherwise use current episodes
                let episodes = viewModel.getEpisodeSnapshot(for: feed.id) ?? viewModel.currentEpisodes.filter { $0.feedId == feed.id }
                allEpisodesInFeed = episodes
                allEpisodesInFeed.sort { $0.publicationDate > $1.publicationDate } // Sort by newest first
                os_log("Loaded %d episodes for feed: %{public}@", log: log, type: .info, allEpisodesInFeed.count, feed.title)
                
                // Update currentEpisodeIndex after episodes are loaded
                if let currentEpisode = currentEpisode {
                    updateCurrentEpisodeIndex(for: currentEpisode)
                }
                
                // Verify that all episodes are loaded
                if allEpisodesInFeed.isEmpty {
                    os_log("No episodes loaded for feed. Attempting to fetch episodes.", log: log, type: .error)
                    Task { @MainActor in
                        fetchEpisodesForFeed(feed)
                    }
                }
            }
        }
    
    private func fetchEpisodesForFeed(_ feed: PodcastFeed) {
            Task { @MainActor in
                viewModel?.fetchEpisodes(for: feed) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let episodes):
                        self.allEpisodesInFeed = episodes.sorted { $0.publicationDate > $1.publicationDate }
                        os_log("Fetched and sorted %d episodes for feed: %{public}@", log: self.log, type: .info, self.allEpisodesInFeed.count, feed.title)
                        
                        // Update currentEpisodeIndex after fetching episodes
                        if let currentEpisode = self.currentEpisode {
                            self.updateCurrentEpisodeIndex(for: currentEpisode)
                        }
                        
                        DispatchQueue.main.async {
                            self.objectWillChange.send()
                        }
                    case .failure(let error):
                        os_log("Failed to fetch episodes: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    }
                }
            }
        }
    
    private func updateCurrentEpisodeIndex(for episode: PodcastEpisode) {
        if let index = allEpisodesInFeed.firstIndex(where: { $0.id == episode.id }) {
            currentEpisodeIndex = index
            os_log("Set current episode index to %d", log: log, type: .info, index)
        } else {
            os_log("Failed to find index for current episode", log: log, type: .error)
            currentEpisodeIndex = nil
        }
    }
    
    // REMOVED: Episode skip functionality - users can only scrub through current episode
    func skipToNextEpisode() {
        os_log("⚠️ Episode skip disabled - use episode list to change episodes", log: log, type: .info)
        // No-op: Episode skipping removed for better UX
    }
    
    func skipToPreviousEpisode() {
        os_log("⚠️ Episode skip disabled - use episode list to change episodes", log: log, type: .info)
        // No-op: Episode skipping removed for better UX
        }
    
    private func changeToEpisode(_ episode: PodcastEpisode, in feed: PodcastFeed) {
        os_log("Changing to episode: %@", log: log, type: .info, episode.title)
        saveProgressIfNeeded() // Save progress of the current episode
        playEpisode(episode, feed: feed)
        updateNowPlayingInfo()
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    
    // PERFORMANCE: Optimized for better threading and Main Thread safety
    private func updatePlaybackInfo() {
        guard let player = player else { return }
        
        // Skip all updates if user is scrolling to prevent CPU spikes
        if isUserScrolling {
            return
        }
        
        // MAIN THREAD FIX: Check app state on main thread to prevent violations
        Task { @MainActor in
            // Skip updates if app is in background to save battery
            guard UIApplication.shared.applicationState == .active else { return }
            
            // Heavy operations only (time updates are handled separately in updateCurrentTimeOnly())
            // OPTIMIZE: Only update progress every 10 seconds to minimize CPU usage
            Task {
                await self.updateProgressThrottled()
            }
            
            // OPTIMIZE: Update Now Playing info very infrequently (every 5s)
            self.updateNowPlayingInfoDebounced()
        }
    }
    
    // PERFORMANCE: Async throttled progress update method
    private func updateProgressThrottled() async {
        // OPTIMIZE: Only update progress every 15 seconds during playback to drastically reduce CPU usage
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) < heavyUpdateInterval {
            return
        }
        lastProgressUpdate = now
        
        await updateProgress()
    }
    
    // Track last progress update time
    private var lastProgressUpdate = Date()
    
    // PERFORMANCE: Removed old method, now using isUserScrolling property directly
    
    func rewindAndPlay(episode: PodcastEpisode) {
        print("🔄 REWIND DEBUG: rewindAndPlay called for episode: \(episode.title)")
        // IMMEDIATE USER FEEDBACK: Set loading state as soon as user taps rewind and play
        loadingEpisodeId = episode.id
        
        // Find the correct feed for this episode
        Task { @MainActor in
            guard let feed = viewModel?.podcastFeeds.first(where: { $0.id == episode.feedId }) else {
                os_log("Feed not found for episode: %@", log: log, type: .error, episode.title)
                return
            }
            
            self.performRewindAndPlay(episode: episode, feed: feed)
        }
    }
    
    private func performRewindAndPlay(episode: PodcastEpisode, feed: PodcastFeed) {
        print("🔄 REWIND DEBUG: performRewindAndPlay called for episode: \(episode.title)")
        // REWIND PROTECTION: Set rewind protection time and episode ID to allow progress reset
        lastRewindTime = Date()
        lastRewindEpisodeId = episode.id
        print("🔄 REWIND PROTECTION: Started rewind protection period for episode \(episode.id) for \(rewindProtectionInterval) seconds")
        os_log("🔄 REWIND PROTECTION: Started rewind protection period for episode %@ for %.1f seconds", log: log, type: .info, episode.id, rewindProtectionInterval)
        
        if currentEpisode?.id == episode.id {
            // Same episode - rewind to beginning and play
            seek(to: 0)
            currentTime = 0
            currentProgress = 0
            
            // CRITICAL FIX: Use rewindAndPlay to properly reset episode state
            // This method handles all the necessary state resets including played status
            stateManager.rewindAndPlay(episodeId: episode.id)
            
            // Reset progress in view model by updating cache directly
            Task { @MainActor in
                viewModel?.episodeProgress[episode.id] = 0.0
                
                // REWIND CORE DATA FIX: Always reset isPlayed state in both EpisodeStateManager and Core Data
                // This ensures the episode shows as unplayed in all parts of the system
                viewModel?.updateEpisodeState(episode.id, progress: 0.0, isPlayed: false)
                
                // CORE DATA IMMEDIATE SYNC: Force immediate Core Data sync for the rewound episode
                // This ensures the Core Data state is updated right away, not just in memory
                Task.detached(priority: .userInitiated) {
                    let episodeStates = [episode.id: EpisodeState(
                        isPlayed: false,
                        isFavorite: EpisodeStateManager.shared.isFavorite(episode.id),
                        progress: 0.0,
                        isDownloaded: EpisodeStateManager.shared.isDownloaded(episode.id)
                    )]
                    
                    do {
                        try await PodcastCoreDataManager.shared.syncEpisodeStates(episodeStates)
                        os_log("✅ REWIND: Core Data synced for episode %@", log: self.log, type: .info, episode.id)
                    } catch {
                        os_log("❌ REWIND: Core Data sync failed for episode %@: %@", log: self.log, type: .error, episode.id, error.localizedDescription)
                    }
                }
            }
            
            // IMMEDIATE PLAYBACK FIX: Ensure playback starts immediately for finished episodes
            if !isPlaying {
                play()
            }
            
            os_log("Rewound and playing episode: %@ - reset from finished state", log: log, type: .info, episode.title)
        } else {
            // Different episode - but this was called from rewindAndPlay, so the user wants to restart this episode too
            // Force start from beginning since rewindAndPlay was explicitly called
            shouldStartFromBeginning = true
            playEpisode(episode, feed: feed)
            os_log("Loaded different episode with rewind - starting from beginning: %@", log: log, type: .info, episode.title)
        }
        
        isPlaying = true
        
        // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
        // UI will update naturally through other mechanisms
    }
    
    func configure(with viewModel: PodcastViewModel) {
        self.viewModel = viewModel
    }
    
    func setRadioPlayer(_ player: RadioPlayer) {
        self.radioPlayer = player
    }
    
    // PERFORMANCE: Robust throttling for handleNavigationAway to prevent excessive calls and main thread hangs
    private var lastNavigationAwayTime: Date = Date.distantPast
    private var isNavigationAwayInProgress: Bool = false
    private let navigationAwayThrottleInterval: TimeInterval = 2.0 // 2 seconds minimum between calls to prevent loops
    
    func handleNavigationAway() {
        let now = Date()
        
        // CRITICAL: Prevent concurrent navigation away operations that cause hangs
        if isNavigationAwayInProgress {
            print("🚫 handleNavigationAway blocked - already in progress")
            return
        }
        
        // PERFORMANCE: Throttle navigation away calls to prevent excessive progress saving
        guard now.timeIntervalSince(lastNavigationAwayTime) >= navigationAwayThrottleInterval else {
            print("🚫 handleNavigationAway throttled - too soon since last call (\(String(format: "%.1f", now.timeIntervalSince(lastNavigationAwayTime)))s < \(navigationAwayThrottleInterval)s)")
            return
        }
        
        isNavigationAwayInProgress = true
        lastNavigationAwayTime = now
        
        guard let currentEpisode = currentEpisode, isPlaying else {
            isNavigationAwayInProgress = false
            return
        }
        
        // PERFORMANCE: Move heavy operations to background thread to prevent main thread hangs
        Task.detached(priority: .background) {
            // Save current progress immediately (lightweight operation)
            await MainActor.run {
                self.saveProgressIfNeeded()
            }
            
            // Update episode state to reflect "In Progress"
            var updatedEpisode = currentEpisode
            // CRITICAL FIX: Use currentProgress instead of recalculating to preserve chapter seek progress
            let progress = await MainActor.run { 
                self.currentProgress > 0 ? self.currentProgress : (self.duration > 0 ? self.currentTime / self.duration : 0)
            }
            updatedEpisode.state.progress = progress
            
            // Save to CloudKit when user navigates away (background operation)
            self.saveProgressWithCoreDataPriority(for: currentEpisode, progress: progress, reason: "user navigated away from episode")
            
            // Preserve existing "finished" status - only mark as finished if progress >= 0.99
            // but don't unmark episodes that were already marked as finished
            if progress >= 0.99 {
                updatedEpisode.state.isPlayed = true
            } else if !currentEpisode.state.isPlayed {
                // Only update isPlayed to false if it wasn't already marked as finished
                updatedEpisode.state.isPlayed = false
            }
            
            // Update the current episode reference and ViewModel on main thread
            await MainActor.run {
                self.currentEpisode = updatedEpisode
                
                // PERFORMANCE: Throttle ViewModel updates to reduce CPU usage
                let isPlayed = progress >= 0.99 ? true : (currentEpisode.state.isPlayed ? true : false)
                self.viewModel?.updateEpisodeState(currentEpisode.id, progress: progress, isPlayed: isPlayed)
                
                os_log("Updated episode status on navigation away: %@, Progress: %.2f", log: self.log, type: .info, currentEpisode.title, progress)
                
                // Reset the in-progress flag
                self.isNavigationAwayInProgress = false
            }
        }
    }
    
    func ensureProgressTracking(for episode: PodcastEpisode) {
        // If this episode was ever played, ensure it shows as "In Progress"
        if currentEpisode?.id == episode.id && currentTime > 0 {
            let progress = currentTime / duration
            if progress > 0 && progress < 0.99 {
                Task { @MainActor in
                    // Update cache directly without triggering CloudKit saves
                    viewModel?.episodeProgress[episode.id] = progress
                    
                    // Update the episode state
                    let isPlayed = episode.state.isPlayed ? true : false
                    viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: isPlayed)
                }
                
                // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
            }
        }
    }
    
    func playEpisode(_ episode: PodcastEpisode, feed: PodcastFeed) {
        os_log("Starting playback for episode: %@ (ID: %@)", log: log, type: .info, episode.title, episode.id)
        
        // IMMEDIATE USER FEEDBACK: Set loading state as soon as user taps play
        loadingEpisodeId = episode.id
        connectionState = .loading
        
        // CRITICAL: Set user intent to play podcast (like RadioPlayer)
        userWantsToPlay = true
        
        // Load appropriate playback speed for this feed
        currentFeed = feed
        loadPlaybackSpeedForCurrentContext()
        
        // CRITICAL FIX: Stop current playback FIRST to prevent multiple episodes showing as playing
        let previousEpisode = currentEpisode
        
        // If there's a currently playing episode, stop it immediately and save progress
        if let previousEpisode = previousEpisode, previousEpisode.id != episode.id {
            // IMMEDIATE: Stop playing state to prevent UI showing multiple episodes as playing
            isPlaying = false
            player?.pause()
            
            // Get the most accurate current time from the player before stopping
            let actualCurrentTime = player?.currentItem?.currentTime().seconds ?? currentTime
            let actualDuration = player?.currentItem?.duration.seconds ?? duration
            
            // Calculate progress with the most up-to-date values
            let currentProgress = actualDuration > 0 ? actualCurrentTime / actualDuration : 0
            
            // Update our internal state to match the actual player state
            if actualCurrentTime.isFinite && actualCurrentTime >= 0 {
                currentTime = actualCurrentTime
            }
            if actualDuration.isFinite && actualDuration > 0 {
                duration = actualDuration
            }
            
            // Save progress immediately when switching episodes
            saveProgressForEpisodeSwitch(previousEpisode, progress: currentProgress, actualTime: actualCurrentTime)
            
            // Update state manager immediately to stop showing previous episode as playing
            stateManager.switchToEpisode(
                newEpisodeId: episode.id,
                previousEpisodeId: previousEpisode.id,
                previousProgress: currentProgress
            )
        }
        
        // NOW set the new episode information
        currentEpisode = episode
        currentFeed = feed
        isPodcastActive = true
        
        // Initialize time and duration for the new episode
        duration = episode.duration
        
        // ENHANCED PROTECTION: Don't reset progress to 0 during episode switch - preserve existing progress
        // Only reset if this is a completely new episode or explicitly requested
        if currentEpisode?.id != episode.id {
            // Different episode - initialize to 0, will be set correctly from Core Data below
            currentProgress = 0
            currentTime = 0
        }
        // If same episode, preserve current progress to prevent reset during reconnection/reload
        
        // Reset position restoration flag for the new episode
        hasRestoredPositionForCurrentEpisode = false
        currentEpisodeIdForRestoration = nil
        
        // Reset network state when loading a new episode
        resetNetworkState()
        
        // Completely stop radio playback to prevent it from getting stuck in "connecting" state
        RadioPlayer.shared.stop()
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // CRITICAL: Configure Remote Command Center for podcast to show skip buttons
        configurePodcastRemoteCommands()
        
        // Load all episodes for the feed
        loadAllEpisodesForFeed(feed)
        
        var playUrl: URL?
        

        
        if let localFilePath = episode.localFilePath, !localFilePath.isEmpty {
            let fileExists = FileManager.default.fileExists(atPath: localFilePath)
            if fileExists {
                playUrl = URL(fileURLWithPath: localFilePath)
                os_log("Using local file for playback: %@", log: log, type: .info, localFilePath)
            } else {
                os_log("Local file missing, falling back to streaming URL", log: log, type: .info)
            }
        }
        
        if playUrl == nil {
            if let url = URL(string: episode.audioUrl) {
                playUrl = url
                os_log("Using streaming URL: %@", log: log, type: .info, episode.audioUrl)
            } else {
                os_log("Failed to get playable URL for episode: %@", log: log, type: .error, episode.title)
                return
            }
        }
        
        guard let url = playUrl else { return }
        
        let playerItem = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        // Save last played episode in the view model immediately (thread-safe)
        viewModel?.updateLastPlayedEpisodeImmediate(episode)
        
        // Add to CarPlay recently played list for CarPlay integration
        CarPlayManager.shared.addEpisodeToRecentlyPlayed(episode)
        
        // Reset CarPlay progress tracking for new episode
        lastCarPlayProgress = nil
        
        // Update currentEpisodeIndex (this will be updated again when episodes load asynchronously)
        updateCurrentEpisodeIndex(for: episode)
        
        // Initialize progress from Core Data first (primary source), then sync with CloudKit in background
        if !shouldStartFromBeginning {
            // CRITICAL FIX: Load progress ONLY from Core Data, completely bypassing EpisodeStateManager
            // This eliminates all race conditions during app startup
            
            // STEP 1: Load progress ONLY from Core Data (authoritative source)
            let coreDataProgress = loadProgressFromCoreData(episodeId: episode.id)
            
            // STEP 2: Use Core Data progress as the ONLY source of truth
            let primaryProgress = coreDataProgress
            
            // STEP 3: Sync EpisodeStateManager in background (non-blocking)
            if coreDataProgress > 0 {
                Task.detached(priority: .utility) { 
                    EpisodeStateManager.shared.setProgressSilently(for: episode.id, progress: coreDataProgress)
                }
            }
            
            // STEP 4: Start CloudKit sync in background to keep data in sync (non-blocking)
            Task {
                await syncWithCloudKitInBackground(for: episode.id, currentProgress: primaryProgress)
            }
            
                            // CORE DATA PRIORITY: Use Core Data progress if available, as it's the authoritative source
                // This ensures we respect the Core Data progress which contains the most reliable data
                if primaryProgress > 0 {
                    // CRITICAL: Set initial load flag to prevent UI animation
                    isInitialProgressLoad = true
                    currentProgress = primaryProgress
                    currentTime = primaryProgress * duration
                    os_log("Progress loaded - Setting currentProgress to: %.4f (%.1f seconds) for episode: %@", log: log, type: .info, currentProgress, currentTime, episode.title)
                    
                    // Reset the flag after a brief delay to allow UI to render without animation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.isInitialProgressLoad = false
                    }
                } else {
                    // ENHANCED PROTECTION: Only reset to 0 if we're sure there's no progress anywhere
                    // Check EpisodeStateManager as backup before resetting
                    let stateManagerProgress = stateManager.getProgress(for: episode.id)
                    let episodeStateProgress = episode.state.progress
                    let maxProgress = max(stateManagerProgress, episodeStateProgress)
                    
                    if maxProgress > 0 {
                        // Found progress from alternate source - use it instead of resetting
                        isInitialProgressLoad = true
                        currentProgress = maxProgress
                        currentTime = maxProgress * duration
                        os_log("PROTECTION: Found progress %.4f from alternate source for episode: %@", log: log, type: .info, maxProgress, episode.title)
                    } else {
                        // No progress found anywhere - safe to reset
                        isInitialProgressLoad = true
                        currentProgress = 0
                        currentTime = 0
                        os_log("No progress found - Setting currentProgress to 0 for episode: %@", log: log, type: .info, episode.title)
                    }
                    
                    // Reset the flag after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.isInitialProgressLoad = false
                    }
                }
        } else {
            // ENHANCED PROTECTION: Even when shouldStartFromBeginning is true, double-check this is intentional
            // Only reset if this is a rewind action, not a reconnection or reload
            if shouldStartFromBeginning {
                currentProgress = 0
                currentTime = 0
                os_log("Intentional reset - Starting from beginning for episode: %@", log: log, type: .info, episode.title)
            } else {
                // Preserve current progress for reconnections/reloads
                os_log("PROTECTION: Preserving current progress %.4f for episode reload: %@", log: log, type: .info, currentProgress, episode.title)
            }
        }
        
        // Set up observers first so we can properly seek when ready
        setupPlayerItemObserver()
        setupTimeObserver()
        
        if let playerItem = player?.currentItem {
            duration = playerItem.asset.duration.seconds
        }
        
        // Only start playing the new episode after we've handled the previous one
        if currentEpisode?.id == episode.id {
            stateManager.startPlaying(episodeId: episode.id)
        }
        
        play()
        isPlaying = true
        updateNowPlayingInfo()
        setupBackgroundPlayback()
        
        // Ensure remote command center is configured for CarPlay
        setupRemoteCommandCenter()

        os_log("Started playing episode: %@", log: log, type: .info, episode.title)
        
        // OPTIMIZE: Eliminate excessive UI updates to reduce CPU usage
    }
    
    // REMOVED: setupUpdateTimer() - redundant with setupTimeObserver()
    // This eliminates duplicate timer causing CPU spikes
    
    func playLastEpisodeForFeed(_ feed: PodcastFeed) {
            Task { @MainActor in
                if let episode = viewModel?.getLastPlayedOrLatestEpisode(for: feed) {
                    let feedEpisodes = viewModel?.allEpisodes.filter { $0.feedId == feed.id } ?? []
                    let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
                    
                    if episodesInProgress.isEmpty {
                        viewModel?.showNoEpisodesInProgressAlert(for: feed)
                    }
                    
                    playEpisode(episode, feed: feed)
                } else {
                    print("No episodes available for this feed")
                    viewModel?.showNoEpisodesInProgressAlert(for: feed)
                }
            }
        }
    
    private func setupBackgroundPlayback() {
        // Background audio is handled by the centralized PlaybackManager
        // This ensures consistent audio session configuration
        os_log("Background playback configured via PlaybackManager", log: log, type: .info)
    }
    
    private func updateDuration() {
            guard let currentItem = player?.currentItem else { return }
            let newDuration = currentItem.asset.duration.seconds
            if newDuration.isFinite && newDuration > 0 {
                duration = newDuration
                if let currentEpisode = currentEpisode {
                    Task { @MainActor in
                        viewModel?.updateEpisodeDuration(currentEpisode, newDuration: newDuration)
                    }
                }
            }
        }
    
    private func setupPlayerItemObserver() {
            playerItemObserver?.invalidate()
            playerItemObserver = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
                guard let self = self else { return }
                if playerItem.status == .readyToPlay {
                    self.duration = playerItem.duration.seconds
                    self.updatePlaybackInfo()
                    Task {
                        await self.seekToSavedProgress()
                    }
                    
                    // Clear loading state when player item is ready to play
                    if let currentEpisode = self.currentEpisode, 
                       self.loadingEpisodeId == currentEpisode.id {
                        self.loadingEpisodeId = nil
                    }
                }
            }

            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
                guard let self = self, let currentEpisode = self.currentEpisode else { return }
                
                os_log("🎵 Episode finished playing (AVPlayerItemDidPlayToEndTime): %@", log: self.log, type: .info, currentEpisode.title)
                
                // Update current time and progress to reflect completion
                self.currentTime = self.duration
                self.currentProgress = 1.0
                
                // Mark episode as completed in EpisodeStateManager
                self.stateManager.completeEpisode(episodeId: currentEpisode.id)
                
                // Save to CloudKit when episode completes
                self.saveProgressWithCoreDataPriority(for: currentEpisode, progress: 1.0, reason: "episode completed")
                
                // Mark episode as completed (deprecated method for compatibility)
                self.viewModel?.markEpisodeAsCompleted(currentEpisode)

                // Determine behavior based on user preference
                let stopAfter = UserDefaults.standard.bool(forKey: "stopAfterEpisode")

                if stopAfter {
                    // Stop playback entirely
                    self.pause()
                    self.updatePlaybackInfo()
                    self.updateNowPlayingInfo()
                    
                    // Notify CarPlay of episode completion
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeCompleted"),
                        object: nil,
                        userInfo: [
                            "episodeId": currentEpisode.id,
                            "isCompleted": true
                        ]
                    )
                    os_log("⏹️ Stopped after episode as per setting", log: self.log, type: .info)
                } else {
                    // Try to advance to next episode in the feed sequence
                    if let currentIndex = self.currentEpisodeIndex,
                       currentIndex + 1 < self.allEpisodesInFeed.count,
                       let feed = self.currentFeed {
                        let nextEpisode = self.allEpisodesInFeed[currentIndex + 1]
                        os_log("▶️ Auto-advancing to next episode: %@", log: self.log, type: .info, nextEpisode.title)
                        self.playEpisode(nextEpisode, feed: feed)
                    } else {
                        // No next episode; just pause and update
                        self.pause()
                        self.updatePlaybackInfo()
                        self.updateNowPlayingInfo()
                        os_log("⏹️ No next episode available; stopping", log: self.log, type: .info)
                    }
                    
                    // Notify CarPlay of episode completion regardless
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeCompleted"),
                        object: nil,
                        userInfo: [
                            "episodeId": currentEpisode.id,
                            "isCompleted": true
                        ]
                    )
                    os_log("🚗 Episode completion notification sent to CarPlay: %@", log: self.log, type: .info, currentEpisode.title)
                }
            }
        }
    
    
    private func seekToSavedProgress() async {
        guard let currentEpisode = currentEpisode else { return }
        
        // Prevent repeated restoration calls for the same episode to improve scrolling performance
        if hasRestoredPositionForCurrentEpisode && currentEpisodeIdForRestoration == currentEpisode.id {
            print("💾 DEBUG: Skipping position restoration - already restored for episode")
            os_log("⚡ Skipping position restoration - already restored for episode: %@", log: log, type: .debug, currentEpisode.title)
            return
        }
        
        // CRITICAL FIX: Prevent seeking if audio is already playing and we're close to the expected position
        // This prevents the "first sentence repeats twice" issue after sync
        // BUT: Only check this for already-playing episodes, NOT during app startup
        let actualPlayerTime = player?.currentTime().seconds ?? 0
        let isAppStartup = !isPlaying && (currentEpisodeIdForRestoration != currentEpisode.id)
        
        if isPlaying && currentTime > 0 && !isAppStartup {
            let expectedProgress = max(
                stateManager.getProgress(for: currentEpisode.id),
                currentEpisode.state.progress
            )
            let expectedTime = expectedProgress * duration
            let timeDifference = abs(actualPlayerTime - expectedTime)  // Use actual player time, not currentTime variable
            
            // If we're within 3 seconds of the expected position and audio is playing, don't seek
            if timeDifference <= 3.0 {
                os_log("Skip seek: Already playing at correct position (%.1fs vs expected %.1fs)", 
                       log: log, type: .info, actualPlayerTime, expectedTime)
                hasRestoredPositionForCurrentEpisode = true
                currentEpisodeIdForRestoration = currentEpisode.id
                return
            }
        }
        
        // If this is a replay action, always start from the beginning
        if shouldStartFromBeginning {
            os_log("Replay requested - starting from the beginning", log: log, type: .info)
            await player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            
            // MAIN THREAD FIX: Update @Published properties on main thread
            await MainActor.run {
                currentTime = 0
                currentProgress = 0
                shouldStartFromBeginning = false  // Reset the flag
                hasRestoredPositionForCurrentEpisode = true
                currentEpisodeIdForRestoration = currentEpisode.id
            }
            
            // Update Now Playing info immediately with correct elapsed time
            updateNowPlayingInfo()
            return
        }
        
        // CORE DATA PRIORITY: Don't override progress based on EpisodeStateManager state
        // The currentProgress was already set from Core Data in playEpisode() method
        // We respect that as the authoritative source
        
        // ENHANCEMENT: Check for latest progress from other devices before resuming
        // But only if we're not already playing to prevent interrupting playback
        if !isPlaying {
            await checkForLatestCrossDeviceProgress(for: currentEpisode.id)
        }
        
        // CORE DATA PRIORITY: Use the progress already loaded from Core Data in playEpisode
        // This ensures consistency with our Core Data priority approach
        let savedProgress: Double = currentProgress
        let progressSource = "Core Data (from playEpisode)"
        
        os_log("🔍 SEEK DEBUG - Episode: %@", log: log, type: .info, currentEpisode.title)
        os_log("🔍 SEEK DEBUG - currentProgress from playEpisode: %.4f", log: log, type: .info, currentProgress)
        os_log("🔍 SEEK DEBUG - savedProgress: %.4f", log: log, type: .info, savedProgress)
        os_log("🔍 SEEK DEBUG - duration: %.4f", log: log, type: .info, duration)
        
        // Use the Core Data progress already loaded in playEpisode method
        if savedProgress > 0 && duration > 0 {
            let targetTime = savedProgress * duration
            
            os_log("🔍 SEEK DEBUG - Will seek to targetTime: %.4f seconds (%.4f progress)", log: log, type: .info, targetTime, savedProgress)
            
            await MainActor.run {
                currentTime = targetTime
                currentProgress = savedProgress
                os_log("🔍 SEEK DEBUG - Set currentTime: %.4f, currentProgress: %.4f", log: self.log, type: .info, currentTime, currentProgress)
            }
            
            // Seek to the Core Data progress position
            player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                if completed {
                    DispatchQueue.main.async {
                        self?.currentTime = targetTime
                        self?.currentProgress = savedProgress
                        self?.updatePlaybackInfo()
                        self?.updateNowPlayingInfo()
                        self?.hasRestoredPositionForCurrentEpisode = true
                        self?.currentEpisodeIdForRestoration = currentEpisode.id
                        os_log("🔍 ✅ SEEK DEBUG - RESTORED Core Data position to %.4f seconds (%.4f progress)", log: self?.log ?? OSLog.default, type: .info, targetTime, savedProgress)
                    }
                } else {
                    os_log("🔍 ❌ SEEK DEBUG - Seek failed", log: self?.log ?? OSLog.default, type: .error)
                }
            }
            return
        }
        else {
            // ENHANCED PROTECTION: Before resetting to beginning, check all possible progress sources
            let stateManagerProgress = stateManager.getProgress(for: currentEpisode.id)
            let episodeStateProgress = currentEpisode.state.progress
            let maxAlternateProgress = max(stateManagerProgress, episodeStateProgress)
            
            if maxAlternateProgress > 0 && duration > 0 {
                // Found progress from alternate source - use it instead of resetting
                let targetTime = maxAlternateProgress * duration
                os_log("🔍 PROTECTION: Found alternate progress %.4f, seeking to %.4f seconds", log: log, type: .info, maxAlternateProgress, targetTime)
                
                await MainActor.run {
                    currentTime = targetTime
                    currentProgress = maxAlternateProgress
                }
                
                player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                    if completed {
                        DispatchQueue.main.async {
                            self?.hasRestoredPositionForCurrentEpisode = true
                            self?.currentEpisodeIdForRestoration = currentEpisode.id
                            self?.updatePlaybackInfo()
                            self?.updateNowPlayingInfo()
                        }
                    }
                }
            } else {
                // No progress found anywhere - safe to start from beginning
                os_log("🔍 SEEK DEBUG - No progress found anywhere (saved: %.4f, state: %.4f, episode: %.4f) - starting from beginning", log: log, type: .info, savedProgress, stateManagerProgress, episodeStateProgress)
                await player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                await MainActor.run {
                    currentTime = 0
                    currentProgress = 0
                    hasRestoredPositionForCurrentEpisode = true
                    currentEpisodeIdForRestoration = currentEpisode.id
                }
                updateNowPlayingInfo()
                os_log("🔍 SEEK DEBUG - Set to beginning: currentTime=0, currentProgress=0", log: log, type: .info)
            }
        }
    }
    
    func play() {
        // CRITICAL: Set user intent when resuming playback
        userWantsToPlay = true
        
        // CRITICAL FIX: Clear manual pause flag when user explicitly plays
        wasManuallyPaused = false
        
        stopRadioPlayback()
        
        guard let player = player, let currentEpisode = currentEpisode, let _ = currentFeed else {
                os_log("No current episode or feed available", log: OSLog.default, type: .error)
                return
            }
        
        // CRITICAL FIX: Clear loading state and set proper connection state when resuming
        if loadingEpisodeId == currentEpisode.id {
            loadingEpisodeId = nil
        }
        connectionState = .connected
        
        // Set podcast as the active player - this will handle audio session activation
        PlaybackManager.shared.setActivePlayer(.podcast)
        
        // CRITICAL: Configure Remote Command Center for podcast to show skip buttons
        configurePodcastRemoteCommands()
        
        // Ensure progress is tracked when playing starts
           ensureProgressTracking(for: currentEpisode)
        
        // Skip progress check for now to avoid main actor issues
        
        player.play()
               isPlaying = true
        
        // Apply current audio settings
        applyCurrentAudioSettings()
        
        // SELECTIVE CROSS-DEVICE SYNC: Enable deferred sync mode during playback
        stateManager.enableDeferredCloudKitSync()
        
        // NOTE: Don't clear loading state here - it should only be cleared when playback actually starts
        // This will be handled by the time observer when playback begins
        
        // Update connection state when starting playback
        connectionState = .connected
        
        // Update StateManager when starting playback
        stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: true)
        stateManager.startPlaying(episodeId: currentEpisode.id)
        
        // CRITICAL FIX: Update Now Playing info immediately for lock screen sync
        updateNowPlayingInfoElapsedTimeOnly()
        updateNowPlayingInfo()
        setupTimeObserver()
        
        // Reset heavy update timer when starting playback
        lastHeavyUpdate = Date()
        
        // Reset network state on manual play (like radio player)
        if !isAttemptingReconnection {
            resetNetworkState()
        }
        
        // Notify CarPlay of playback state change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastPlaybackStateChanged"),
            object: nil,
            userInfo: [
                "episodeId": currentEpisode.id,
                "isPlaying": true
            ]
        )
        
        // Disable all UI updates during playback to prevent CPU spikes
        // objectWillChange.send()
    }
    
    /// Reset network state to prepare for fresh connection assessment
    private func resetNetworkState() {
        os_log("🌐 PodcastPlayer: Resetting network state for fresh connection", log: log, type: .info)
        
        // Clear any pending reconnection attempts
        stopReconnectionAttempts()
        
        // Reset connection state based on current network availability
        if let reachability = reachability {
            connectionState = reachability.connection != .unavailable ? .connected : .disconnected
        } else {
            connectionState = .connected
        }
        
        // Reset reachability state if needed
        if let reachability = reachability {
            do {
                try reachability.startNotifier()
                os_log("🌐 PodcastPlayer: Reachability monitoring restarted", log: log, type: .info)
            } catch {
                os_log("🌐 PodcastPlayer: Failed to restart reachability monitoring: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    }
    
    
    func pause() {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        player.pause()
        isPlaying = false
        
        // CRITICAL FIX: Mark as manually paused to prevent auto-resume
        wasManuallyPaused = true
        
        // CRITICAL FIX: Clear loading state when user pauses to prevent stuck buffering spinner
        if loadingEpisodeId == currentEpisode.id {
            loadingEpisodeId = nil
        }
        
        // CRITICAL FIX: Update connection state when pausing
        connectionState = .connected
        
        // Calculate current progress using the most accurate values
        let actualCurrentTime = player.currentTime().seconds
        let progress = duration > 0 ? actualCurrentTime / duration : 0
        let finalProgress = max(progress, currentProgress) // Use the higher value to prevent progress loss
        
        // Detect if this pause is likely from lock screen (app is in background)
        let isLockScreenPause = UIApplication.shared.applicationState != .active
        let pauseSource = isLockScreenPause ? "lock screen controls" : "in-app controls"
        
        os_log("⏸️ User paused episode from %@ - saving progress: %@, Progress: %.2f%%", 
               log: log, type: .info, pauseSource, currentEpisode.title, finalProgress * 100)
        
        // Save progress to persistent storage when user pauses
        saveProgressIfNeeded()
        
        // Save to CloudKit when user pauses - enhanced for lock screen pauses
        let pauseReason = isLockScreenPause ? "user paused from lock screen" : "user paused episode"
        saveProgressWithCoreDataPriority(for: currentEpisode, progress: finalProgress, reason: pauseReason)
        
        // Update StateManager with current progress when pausing
        // CRITICAL FIX: Only mark as played if progress is actually >= 99%, not during regular pause
        let isActuallyCompleted = finalProgress >= 0.99
        stateManager.updateProgress(for: currentEpisode.id, progress: finalProgress, isPlaying: false, currentTime: actualCurrentTime)
        
        // Don't mark as "played" during regular pause unless actually completed
        if isActuallyCompleted {
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: finalProgress)
        } else {
            // Just update the progress without changing played status
            stateManager.setProgress(for: currentEpisode.id, progress: finalProgress)
        }
        
        // REAL-TIME SYNC: Use the new real-time sync method for episode pause with known feedId
        stateManager.setProgressWithRealTimeSync(for: currentEpisode.id, progress: finalProgress, reason: "episode_paused", feedId: currentEpisode.feedId)
        
        // ⚡ PROACTIVE: Update snapshot immediately for instant loading on next app launch
        Task {
            await PodcastViewModel.shared.updateSnapshotForEpisodeStateChange(episodeId: currentEpisode.id, feedId: currentEpisode.feedId)
        }
        
        // REAL-TIME LOCAL SYNC: Trigger immediate local sync notification for instant UI updates
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastProgress"),
            object: nil,
            userInfo: ["episodeId": currentEpisode.id, "progress": finalProgress]
        )
        
        // CRITICAL FIX: For lock screen pauses, ensure UserDefaults are synchronized immediately
        if isLockScreenPause {
            UserDefaults.standard.synchronize()
            os_log("🔒 Lock screen pause detected - forced UserDefaults synchronization", log: log, type: .info)
        }

        ensureProgressTracking(for: currentEpisode)

        // CRITICAL FIX: Update Now Playing info immediately for lock screen sync
        updateNowPlayingInfoElapsedTimeOnly()
        updateNowPlayingInfo()
        
        // Notify CarPlay of playback state change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastPlaybackStateChanged"),
            object: nil,
            userInfo: [
                "episodeId": currentEpisode.id,
                "isPlaying": false
            ]
        )
        
        // Disable all UI updates during playback to prevent CPU spikes
        // UI will update only when playback state changes (play/pause/stop)
        // objectWillChange.send()
        
        // Use centralized audio session management - only deactivate if no other audio is playing
        if !isPlaying && PlaybackManager.shared.activePlayer == .podcast {
            PlaybackManager.shared.deactivateAudioSession()
        }
    }
    
    /// Stops podcast and clears user intent (like RadioPlayer stop functionality)
    func stop() {
        guard let player = player else { return }
        
        // CRITICAL FIX: Clear user intent and manual pause flags when stopping
        userWantsToPlay = false
        wasManuallyPaused = false
        
        // Save progress before stopping if we have a current episode
        if let currentEpisode = currentEpisode {
            let progress = duration > 0 ? currentTime / duration : 0
            
            // Save progress when stopping
            saveProgressIfNeeded()
            saveProgressWithCoreDataPriority(for: currentEpisode, progress: progress, reason: "user stopped episode")
            
            // Update StateManager
            let actualCurrentTime = player.currentTime().seconds
            stateManager.updateProgress(for: currentEpisode.id, progress: currentProgress, isPlaying: false, currentTime: actualCurrentTime)
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: currentProgress)
            
            // REAL-TIME SYNC: Use the new real-time sync method for episode stop with known feedId
            stateManager.setProgressWithRealTimeSync(for: currentEpisode.id, progress: progress, reason: "app_closed", feedId: currentEpisode.feedId)
            
            // REAL-TIME LOCAL SYNC: Trigger immediate local sync notification for instant UI updates
            NotificationCenter.default.post(
                name: .init("InstantSyncDidUpdatePodcastProgress"),
                object: nil,
                userInfo: ["episodeId": currentEpisode.id, "progress": progress]
            )
        }
        
        player.pause()
        isPlaying = false
        userWantsToPlay = false  // Clear user intent
        
        // Note: Real-time sync already handled above for episode stop
        
        // Connection state should reflect network availability, not playback state
        // Don't change connection state when stopping
        
        // Clear current episode and feed
        self.currentEpisode = nil
        self.currentFeed = nil
        
        updateNowPlayingInfo()
        print("⏹️ Podcast stopped and user intent cleared")
    }
    
    /// Handles audio interruptions to prevent CarPlay disconnection from pausing podcast
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔇 PodcastPlayer: Audio interruption began - pausing playback immediately")
            DebugLogger.logWarning("Audio interruption began - pausing podcast playbook (likely phone call or other audio)", category: "AudioInterruption")
            
            // PHONE CALL FIX: Multiple interruption protection with PlaybackManager state coordination
            let isFirstInterruption = !wasPlayingBeforeInterruption
            if isFirstInterruption {
                // Check both our state AND PlaybackManager state (in case PlaybackManager captured it first)
                let actuallyWasPlaying = isPlaying || (PlaybackManager.shared.activePlayer == .podcast && PlaybackManager.shared.podcastWasPlayingBeforeInterruption)
                wasPlayingBeforeInterruption = actuallyWasPlaying
                print("🎧 PodcastPlayer: Set wasPlayingBeforeInterruption = \(wasPlayingBeforeInterruption) (FIRST interruption - coordinated with PlaybackManager)")
            } else {
                print("🎧 PodcastPlayer: State unchanged (subsequent interruption) = \(wasPlayingBeforeInterruption)")
            }
            
            // PHONE CALL FIX: Force immediate pause to prevent ANY audio mixing with phone calls
            // This must happen synchronously and immediately
            player?.pause()
            isPlaying = false
            
            // CRITICAL: Immediately deactivate audio session to prevent mixing - DO NOT make async
            // This MUST be synchronous to ensure no audio mixing with phone calls
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Immediately deactivate to ensure complete audio stop for phone calls
                try audioSession.setActive(false, options: [])
                print("✅ PodcastPlayer: Audio session immediately deactivated for phone call")
            } catch {
                print("⚠️ PodcastPlayer: Could not deactivate audio session: \(error)")
                // Even if deactivation fails, the player.pause() above should stop the audio
            }
            
            print("✅ PodcastPlayer: Playback paused and audio session deactivated due to interruption")
            
            DebugLogger.logInfo("Podcast audio interruption handled - Was playing: \(wasPlayingBeforeInterruption), Episode: \(currentEpisode?.title ?? "None")", category: "AudioInterruption")
            
        case .ended:
            print("🔊 PodcastPlayer: Audio interruption ended - letting PlaybackManager handle resume")
            DebugLogger.logInfo("Podcast audio interruption ended - PlaybackManager will handle resume", category: "AudioInterruption")
            
            // PHONE CALL FIX: Reset interruption state after a delay to allow for resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if let self = self, !self.isPlaying {
                    // Only reset if we're still not playing after resume attempts
                    self.wasPlayingBeforeInterruption = false
                    print("🎧 PodcastPlayer: Reset interruption state for next phone call")
                }
            }
            
        @unknown default:
            break
        }
    }
    
    /// Resumes playback after an audio interruption (e.g., alarm, phone call, other apps)
    func resumeAfterInterruption() {
        print("🔊 PodcastPlayer: Attempting to resume playback after interruption")
        DebugLogger.logInfo("Resuming podcast playback after audio interruption", category: "AudioInterruption")
        
        guard let player = player, 
              wasPlayingBeforeInterruption,
              userWantsToPlay else {
            print("⚠️ PodcastPlayer: Cannot resume - conditions not met")
            DebugLogger.logWarning("Cannot resume after interruption - player: \(player != nil), wasPlaying: \(wasPlayingBeforeInterruption), userWants: \(userWantsToPlay)", category: "AudioInterruption")
            return
        }
        
        // CRITICAL: For various interruption scenarios, currentEpisode might be temporarily nil
        // but we should still attempt resume if we have a valid player and were playing before
        if currentEpisode == nil {
            print("⚠️ PodcastPlayer: No current episode - this might be an app interruption scenario")
            DebugLogger.logWarning("Attempting resume without current episode (possible app interruption)", category: "AudioInterruption")
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
                
                print("✅ PodcastPlayer: Audio session reactivated, attempting playback resume")
            } catch {
                print("❌ PodcastPlayer: Failed to activate audio session: \(error)")
                DebugLogger.logError("Failed to activate audio session for podcast resume: \(error.localizedDescription)", category: "AudioInterruption")
                
                // Continue anyway - PlaybackManager might have already activated it
                print("🔄 PodcastPlayer: Continuing with resume despite session activation error")
            }
        } else {
            print("✅ PodcastPlayer: Audio session already active, proceeding with resume")
        }
        
        // Resume playback with small delay to ensure session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Resume playback
                player.play()
                self.isPlaying = true
                self.wasPlayingBeforeInterruption = false // Reset the flag
                
                // Update Now Playing info
                self.updateNowPlayingInfo()
                
                print("✅ PodcastPlayer: Successfully resumed playback after interruption")
                DebugLogger.logInfo("Podcast playback successfully resumed after interruption", category: "AudioInterruption")
                
            } catch {
                print("❌ PodcastPlayer: Failed to resume playback: \(error)")
                DebugLogger.logError("Failed to resume podcast playback after interruption: \(error.localizedDescription)", category: "AudioInterruption")
                
                // Retry with more aggressive approach and longer delay for stubborn cases (other apps holding audio)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self else { return }
                    
                    do {
                        let audioSession = AVAudioSession.sharedInstance()
                        // Force reactivation without notifying others to aggressively reclaim audio
                        try audioSession.setActive(false)
                        try audioSession.setActive(true, options: [])
                        player.play()
                        self.isPlaying = true
                        self.wasPlayingBeforeInterruption = false
                        self.updateNowPlayingInfo()
                        print("✅ PodcastPlayer: Successfully resumed playback after aggressive retry")
                    } catch {
                        print("❌ PodcastPlayer: Final aggressive retry failed: \(error)")
                    }
                }
            }
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            // Pause without clearing current episode/feed so GlobalPlayer remains visible
            pause()
        } else {
            stopRadioPlayback()
            play()
        }
    }
    
    private func stopRadioPlayback() {
        // Completely stop radio playback to prevent it from getting stuck in "connecting" state
        RadioPlayer.shared.stop()
        os_log("🛑 Radio playback completely stopped for podcast playback", log: log, type: .info)
    }
    
    // Track when we last did a chapter seek to prevent time observer from overriding
    private var lastChapterSeekTime: Date?
    private let chapterSeekProtectionInterval: TimeInterval = 5.0 // 5 seconds protection
    
    // CRITICAL FIX: Navigation protection mechanism - prevents CloudKit from overriding live progress during app navigation
    private var lastNavigationTime: Date?
    private let navigationProtectionInterval: TimeInterval = 30.0 // 30 seconds protection after navigation
    
    // Track when we last did a rewind to prevent progress protection from blocking
    private var lastRewindTime: Date?
    private var lastRewindEpisodeId: String?
    private let rewindProtectionInterval: TimeInterval = 10.0 // 10 seconds protection (extended for CloudKit sync)
    
    /// Check if we're currently in the chapter protection period
    func isInChapterProtectionPeriod() -> Bool {
        guard let lastSeekTime = lastChapterSeekTime else { return false }
        let now = Date()
        return now.timeIntervalSince(lastSeekTime) < chapterSeekProtectionInterval
    }
    
    /// Check if we're currently in the navigation protection period
    func isInNavigationProtectionPeriod() -> Bool {
        guard let lastNavTime = lastNavigationTime else { return false }
        let now = Date()
        return now.timeIntervalSince(lastNavTime) < navigationProtectionInterval
    }
    
    /// Mark that navigation just occurred to protect live progress from CloudKit override
    func markNavigationEvent() {
        lastNavigationTime = Date()
        os_log("🧭 NAVIGATION PROTECTION: Started 30-second protection period", log: log, type: .info)
    }
    
    /// Check if we're currently in the rewind protection period
    func isInRewindProtectionPeriod() -> Bool {
        guard let lastRewindTime = lastRewindTime else { 
            return false
        }
        let now = Date()
        let timeSinceRewind = now.timeIntervalSince(lastRewindTime)
        let isProtected = timeSinceRewind < rewindProtectionInterval
        return isProtected
    }
    
    /// Check if a specific episode is currently in the rewind protection period
    func isEpisodeInRewindProtectionPeriod(_ episodeId: String) -> Bool {
        guard let lastRewindTime = lastRewindTime,
              let lastRewindEpisodeId = lastRewindEpisodeId,
              lastRewindEpisodeId == episodeId else { 
            print("🔄 REWIND PROTECTION CHECK (Episode \(episodeId)): No protection set or different episode")
            return false 
        }
        let now = Date()
        let timeSinceRewind = now.timeIntervalSince(lastRewindTime)
        let isProtected = timeSinceRewind < rewindProtectionInterval
        print("🔄 REWIND PROTECTION CHECK (Episode \(episodeId)): Time since rewind: \(String(format: "%.2f", timeSinceRewind)) seconds, protected: \(isProtected ? "YES" : "NO")")
        os_log("🔄 REWIND PROTECTION CHECK (Episode %@): Time since rewind: %.2f seconds, protected: %@", log: log, type: .debug, episodeId, timeSinceRewind, isProtected ? "YES" : "NO")
        return isProtected
    }
    
    func seek(to time: Double) {
        guard let player = player, let currentEpisode = currentEpisode else { return }
        
        // CRITICAL FIX: Update time and progress IMMEDIATELY before seeking to prevent race conditions
        // Calculate progress before the actual seek operation
        let newProgress = duration > 0 ? min(max(time / duration, 0), 1.0) : 0
        
        // Update state immediately to prevent background save operations from using stale values
        currentTime = time
        currentProgress = newProgress
        
        // CRITICAL: Mark when we did a chapter seek to protect from time observer override
        lastChapterSeekTime = Date()
        
        os_log("🎯 SEEK PROTECTION: Starting seek to %.1fs (%.2f%%) in episode: %@ - protected for %.1fs", 
               log: log, type: .info, time, newProgress * 100, currentEpisode.title, chapterSeekProtectionInterval)
        
        // Save progress immediately BEFORE seeking to prevent race conditions with background operations
        saveProgressToCoreDataSync(episodeId: currentEpisode.id, progress: newProgress)
        
        // Update EpisodeStateManager immediately
        stateManager.updateProgress(
            for: currentEpisode.id, 
            progress: newProgress, 
            isPlaying: isPlaying, 
            currentTime: time
        )
        
        // Update view model cache immediately
        Task { @MainActor in
            viewModel?.episodeProgress[currentEpisode.id] = newProgress
        }
        
        let targetTime = CMTime(seconds: time, preferredTimescale: 1)
        player.seek(to: targetTime) { [weak self] completed in
            guard let self = self, completed else { return }
            
            DispatchQueue.main.async {
                // CRITICAL FIX: Reconfirm the seek position after completion to prevent reversion
                // The time observer might have slightly different values due to seek tolerances
                self.currentTime = time
                self.currentProgress = newProgress
                
                // CRITICAL FIX: Re-save progress after seek completion to prevent reversion
                // This ensures the backwards seek position is permanently saved
                self.saveProgressToCoreDataSync(episodeId: currentEpisode.id, progress: newProgress)
                self.stateManager.updateProgress(
                    for: currentEpisode.id, 
                    progress: newProgress, 
                    isPlaying: self.isPlaying, 
                    currentTime: time
                )
                
                // CRITICAL FIX: Update Now Playing info immediately after seek for lock screen sync
                self.updateNowPlayingInfoElapsedTimeOnly()
                
                // Update full Now Playing info after successful seek (debounced)
                self.updateNowPlayingInfoDebounced()
                
                os_log("✅ CHAPTER SEEK: Successfully completed seek to %.1fs (%.2f%%) in episode: %@ - position reconfirmed", 
                       log: self.log, type: .info, time, newProgress * 100, currentEpisode.title)
            }
        }
    }
    
    // MARK: - Audio Settings Methods
    
    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        player?.rate = Float(speed)
        
        // Save based on feed-specific settings
        if feedSpecificSettingsEnabled, let currentFeed = currentFeed {
            UserDefaults.standard.set(speed, forKey: "playbackSpeed_\(currentFeed.id ?? "unknown")")
        } else {
            UserDefaults.standard.set(speed, forKey: "podcastPlaybackSpeed")
        }
        UserDefaults.standard.synchronize()
        
        os_log("🎵 Playback speed set to %.2fx", log: log, type: .info, speed)
    }
    
    func setFeedSpecificSettingsEnabled(_ enabled: Bool) {
        feedSpecificSettingsEnabled = enabled
        
        // Save to UserDefaults per feed
        if let currentFeed = currentFeed {
            let feedToggleKey = "feedSpecificSettings_\(currentFeed.id ?? "unknown")"
            UserDefaults.standard.set(enabled, forKey: feedToggleKey)
        }
        UserDefaults.standard.synchronize()
        
        // Load appropriate speed setting
        loadPlaybackSpeedForCurrentContext()
        
        os_log("🎵 Feed-specific settings %@ for feed %@", log: log, type: .info, enabled ? "enabled" : "disabled", currentFeed?.title ?? "unknown")
    }
    
    private func loadPlaybackSpeedForCurrentContext() {
        if let currentFeed = currentFeed {
            // Check if this specific feed has feed-specific settings enabled
            let feedToggleKey = "feedSpecificSettings_\(currentFeed.id ?? "unknown")"
            let isFeedSpecific = UserDefaults.standard.bool(forKey: feedToggleKey)
            
            if isFeedSpecific {
                // Load feed-specific speed if available
                let feedSpecificSpeed = UserDefaults.standard.double(forKey: "playbackSpeed_\(currentFeed.id ?? "unknown")")
                playbackSpeed = feedSpecificSpeed != 0 ? feedSpecificSpeed : 1.0
                feedSpecificSettingsEnabled = true
            } else {
                // Load global speed for this feed
                let globalSpeed = UserDefaults.standard.double(forKey: "podcastPlaybackSpeed")
                playbackSpeed = globalSpeed != 0 ? globalSpeed : 1.0
                feedSpecificSettingsEnabled = false
            }
        } else {
            // Load global speed as fallback
            let globalSpeed = UserDefaults.standard.double(forKey: "podcastPlaybackSpeed")
            playbackSpeed = globalSpeed != 0 ? globalSpeed : 1.0
            feedSpecificSettingsEnabled = false
        }
        applyCurrentAudioSettings()
    }
    
    private func applyCurrentAudioSettings() {
        // Apply playback speed if player is available
        if let player = player {
            player.rate = isPlaying ? Float(playbackSpeed) : 0.0
        }
        
        // Apply other audio settings would go here in a full implementation
    }
    
    func saveProgressIfNeeded() {
        guard let currentEpisode = currentEpisode, duration > 0 else { return }
        // CRITICAL FIX: Use currentProgress instead of recalculating to preserve chapter seek progress
        let progress = currentProgress > 0 ? currentProgress : (currentTime / duration)
        
        // Save progress to persistent storage
        stateManager.updateProgress(for: currentEpisode.id, progress: progress, isPlaying: isPlaying, currentTime: currentTime)
        // Core Data saves happen automatically in updateProgress
        
        // Update local cache
        Task { @MainActor in
            viewModel?.episodeProgress[currentEpisode.id] = progress
        }
        
        // Force UserDefaults sync for additional safety
        UserDefaults.standard.synchronize()
        
        os_log("💾 Progress saved to disk for episode: %@, Progress: %.2f%%, Reason: Manual save", 
               log: log, type: .info, currentEpisode.title, progress * 100)
    }
    
    /// Save episode progress to CloudKit only when specific user actions occur
    /// - When user navigates away by tapping another episode to play
    /// - When user pauses the episode  
    /// - When user switches to other tabs like Favorites or Downloads
    /// - When user puts the app in the background
    /// - When user force closes the app
    private func saveProgressToCloudKit(for episode: PodcastEpisode, progress: Double, reason: String) {
        os_log("💾 Saving episode progress to CloudKit due to: %@ - Episode: %@, Progress: %.2f", 
               log: log, type: .info, reason, episode.title, progress)
        
        Task.detached(priority: .userInitiated) { [self] in
            await self.viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: progress >= 0.99)
        }
    }
    
    /// Save progress with Core Data priority: Core Data first, then CloudKit (fully async to prevent hangs)
    private func saveProgressWithCoreDataPriority(for episode: PodcastEpisode, progress: Double, reason: String) {
        os_log("💾 Saving episode progress (Core Data priority) due to: %@ - Episode: %@, Progress: %.2f", 
               log: log, type: .info, reason, episode.title, progress)
        
        // PERFORMANCE: Move all operations to background thread to prevent main thread hangs
        Task.detached(priority: .background) { [self] in
            // STEP 1: Save to Core Data (background operation)
            self.saveProgressToCoreDataSync(episodeId: episode.id, progress: progress)
            
            // STEP 2: Update EpisodeStateManager to stay in sync (background operation)
            EpisodeStateManager.shared.updateProgress(for: episode.id, progress: progress, isPlaying: self.isPlaying, currentTime: self.currentTime)
            
            // STEP 3: Save to CloudKit as backup/sync (asynchronous)
            self.saveProgressToCloudKit(for: episode, progress: progress, reason: reason)
        }
    }
    
    /// Save progress directly to Core Data for immediate persistence
    private func saveProgressToCoreDataSync(episodeId: String, progress: Double) {
        // PERFORMANCE FIX: Use background context to prevent main thread I/O hangs
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        backgroundContext.perform {
            do {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                if let episode = try backgroundContext.fetch(fetchRequest).first {
                    episode.progress = progress
                    episode.isPlayed = progress >= 0.99
                    try backgroundContext.save()
                } else {
                    os_log("Episode not found in Core Data: %@", log: self.log, type: .default, episodeId)
                }
            } catch {
                os_log("Failed to save progress to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
    
    /// Load progress from Core Data (primary source of truth) - SYNCHRONOUS with enhanced validation
    private func loadProgressFromCoreData(episodeId: String) -> Double {
        let context = CoreDataStack.shared.context
        var progress: Double = 0.0
        
        // CRITICAL FIX: Use performAndWait to ensure synchronous execution
        // This prevents race conditions during app startup
        context.performAndWait {
            do {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                let episodes = try context.fetch(fetchRequest)
                
                if let episode = episodes.first {
                    progress = episode.progress
                    os_log("Core Data synchronous load: Episode %@ has progress %.4f", 
                           log: log, type: .info, episodeId, progress)
                    
                    // ENHANCED VALIDATION: If Core Data shows 0 but other sources have progress, investigate
                    if progress == 0.0 {
                        let stateManagerProgress = stateManager.getProgress(for: episodeId)
                        if stateManagerProgress > 0.0 {
                            os_log("VALIDATION WARNING: Core Data shows 0 but EpisodeStateManager has %.4f for episode %@", 
                                   log: log, type: .info, stateManagerProgress, episodeId)
                            // Use the higher value as a safety measure
                            progress = stateManagerProgress
                        }
                    }
                }
            } catch {
                os_log("Failed to load progress from Core Data for episode %@: %@", 
                       log: log, type: .error, episodeId, error.localizedDescription)
                
                // FALLBACK PROTECTION: If Core Data fails, try EpisodeStateManager as backup
                let fallbackProgress = stateManager.getProgress(for: episodeId)
                if fallbackProgress > 0.0 {
                    os_log("FALLBACK: Using EpisodeStateManager progress %.4f for episode %@", 
                           log: log, type: .info, fallbackProgress, episodeId)
                    progress = fallbackProgress
                }
            }
        }
        
        return progress
    }
    
    /// ENHANCED PROTECTION: Validate and recover progress if accidentally reset
    private func validateAndRecoverProgress(for episodeId: String) -> Double {
        let playerProgress = currentProgress
        let stateManagerProgress = stateManager.getProgress(for: episodeId)
        let coreDataProgress = loadProgressFromCoreData(episodeId: episodeId)
        
        // Find the highest reliable progress value
        let maxProgress = max(playerProgress, max(stateManagerProgress, coreDataProgress))
        
        // If current progress is significantly lower than stored progress, recover it
        if playerProgress < maxProgress - 0.01 { // More than 1% difference
            os_log("PROGRESS RECOVERY: Player progress %.4f is lower than stored progress %.4f for episode %@", 
                   log: log, type: .info, playerProgress, maxProgress, episodeId)
            
            // Update current progress to the recovered value
            DispatchQueue.main.async { [weak self] in
                self?.currentProgress = maxProgress
                self?.currentTime = maxProgress * (self?.duration ?? 0)
            }
            
            return maxProgress
        }
        
        return playerProgress
    }
    
    /// Sync with CloudKit in background while ensuring Core Data stays authoritative
    private func syncWithCloudKitInBackground(for episodeId: String, currentProgress: Double) async {
        os_log("Background CloudKit sync for episode: %@", log: log, type: .info, episodeId)
        
        do {
            // Fetch latest from CloudKit
            if let cloudState = try await PodcastCloudKitManager.shared.fetchEpisodeStateFromCloudKit(episodeId) {
                let cloudProgress = cloudState.progress
                
                // Compare Core Data (authoritative) vs CloudKit
                if cloudProgress > currentProgress {
                    // CloudKit has newer data - update Core Data and EpisodeStateManager
                    os_log("☁️ CloudKit has newer progress (%.2f%%) vs Core Data (%.2f%%) - updating Core Data", 
                           log: log, type: .info, cloudProgress * 100, currentProgress * 100)
                    
                    // Update Core Data (primary storage)
                    updateProgressInCoreData(episodeId: episodeId, progress: cloudProgress, isPlayed: cloudState.isPlayed)
                    
                    // Update EpisodeStateManager to stay in sync
                    EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: cloudProgress)
                    EpisodeStateManager.shared.setFavoriteSilently(episodeId, isFavorite: cloudState.isFavorite)
                    EpisodeStateManager.shared.setPlayedSilently(episodeId, isPlayed: cloudState.isPlayed)
                    
                    // If this episode is currently playing, update the player progress
                    await MainActor.run {
                        if self.currentEpisode?.id == episodeId {
                            // CRITICAL FIX: Check chapter protection before updating playing episode
                            let isChapterProtected = self.isInChapterProtectionPeriod()
                            
                            if isChapterProtected {
                                os_log("🛡️ CLOUDKIT BACKGROUND SYNC BLOCKED: Skipping progress update during chapter protection (%.2f%% blocked)", 
                                       log: self.log, type: .info, cloudProgress * 100)
                                return // Block CloudKit background sync during chapter seeks
                            }
                            
                            // CRITICAL FIX: Check navigation protection before updating playing episode
                            let isNavigationProtected = self.isInNavigationProtectionPeriod()
                            
                            print("🔍 DEBUG: Background CloudKit sync for currently playing episode - navigation protected: \(isNavigationProtected)")
                            if let lastNavTime = self.lastNavigationTime {
                                let timeSinceNav = Date().timeIntervalSince(lastNavTime)
                                print("🔍 DEBUG: Background sync - Time since navigation: \(timeSinceNav) seconds")
                            }
                            
                            if isNavigationProtected {
                                print("🛡️ DEBUG: BACKGROUND CLOUDKIT SYNC BLOCKED due to navigation protection")
                                os_log("🛡️ CLOUDKIT BACKGROUND SYNC BLOCKED: Skipping progress update during navigation protection (%.2f%% blocked)", 
                                       log: self.log, type: .info, cloudProgress * 100)
                                return // Block CloudKit background sync during app navigation
                            }
                            
                            self.currentProgress = cloudProgress
                            
                            // Seek to the new position if we haven't restored position yet
                            if self.hasRestoredPositionForCurrentEpisode == false && self.duration > 0 {
                                let seekTime = CMTime(seconds: cloudProgress * self.duration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                                Task {
                                    await self.player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                                    await MainActor.run {
                                        self.currentTime = cloudProgress * self.duration
                                    }
                                }
                            }
                            
                            os_log("🎯 Updated playing episode progress to CloudKit value: %.2f%%", 
                                   log: self.log, type: .info, cloudProgress * 100)
                        }
                    }
                } else if currentProgress > cloudProgress {
                    // Core Data has newer data - update CloudKit
                    os_log("📱 Core Data has newer progress (%.2f%%) vs CloudKit (%.2f%%) - updating CloudKit", 
                           log: log, type: .info, currentProgress * 100, cloudProgress * 100)
                    
                    // Update CloudKit to match Core Data
                    if let currentEpisode = self.currentEpisode, currentEpisode.id == episodeId {
                        self.saveProgressToCloudKit(for: currentEpisode, progress: currentProgress, reason: "Core Data has newer progress")
                    }
                } else {
                    os_log("✅ Core Data and CloudKit are in sync (%.2f%%) for episode: %@", 
                           log: log, type: .info, currentProgress * 100, episodeId)
                }
            } else {
                // No CloudKit data - push Core Data to CloudKit if we have progress
                if currentProgress > 0, let currentEpisode = self.currentEpisode, currentEpisode.id == episodeId {
                    os_log("📤 No CloudKit data found - pushing Core Data progress to CloudKit: %.2f%%", 
                           log: log, type: .info, currentProgress * 100)
                    self.saveProgressToCloudKit(for: currentEpisode, progress: currentProgress, reason: "Initial CloudKit sync from Core Data")
                }
            }
        } catch {
            // Don't fail if CloudKit is unavailable - Core Data remains authoritative
            os_log("⚠️ CloudKit sync failed for episode %@: %@ - Core Data remains authoritative", 
                   log: log, type: .default, episodeId, error.localizedDescription)
        }
    }
    
    /// Update progress in Core Data synchronously
    private func updateProgressInCoreData(episodeId: String, progress: Double, isPlayed: Bool) {
        let context = CoreDataStack.shared.context
        context.performAndWait {
            do {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                if let episode = try context.fetch(fetchRequest).first {
                    episode.progress = progress
                    episode.isPlayed = isPlayed || progress >= 0.99
                    try context.save()
                    
                    os_log("✅ Updated Core Data with CloudKit progress %.2f%% for episode: %@", 
                           log: log, type: .info, progress * 100, episodeId)
                } else {
                    os_log("⚠️ Episode not found in Core Data for CloudKit sync: %@", log: log, type: .default, episodeId)
                }
            } catch {
                os_log("❌ Failed to update Core Data with CloudKit progress: %@", log: log, type: .default, error.localizedDescription)
            }
        }
    }
    

    
    private func saveProgressForEpisodeSwitch(_ episode: PodcastEpisode, progress: Double, actualTime: Double? = nil) {
        // Ensure progress is saved immediately when switching episodes
        guard duration > 0 else { return }
        
        let timeToSave = actualTime ?? currentTime
        os_log("🔄 Saving progress immediately for episode switch: %@ (%.2f%% | %.1fs)", log: log, type: .info, episode.title, progress * 100, timeToSave)
        
        // Save to Core Data first, then CloudKit when switching episodes
        saveProgressWithCoreDataPriority(for: episode, progress: progress, reason: "user switched to another episode")
        
        // 1. Update progress in state manager FIRST (highest priority for seeking)
        stateManager.updateProgress(for: episode.id, progress: progress, isPlaying: false, currentTime: timeToSave)
        
        // 2. Update progress in view model (in-memory cache)
        Task { @MainActor in
            viewModel?.episodeProgress[episode.id] = progress
            
            // 3. Update the episode state using the new method
            let isPlayed = progress >= 0.99
            viewModel?.updateEpisodeState(episode.id, progress: progress, isPlayed: isPlayed)
        }
        
        // 4. Core Data saves happen automatically, no need to force save
        // Data is already persisted through saveCurrentStates()
        
        // 5. Force synchronize UserDefaults for additional safety
        UserDefaults.standard.synchronize()
        
        os_log("✅ Progress saved successfully for episode: %@ at %.2f%% to all storage locations", log: log, type: .info, episode.title, progress * 100)
    }
    
    func skipForward() {
        os_log("⏭️ SKIP FORWARD: Button pressed - seeking 30s forward", log: log, type: .info)
        
        guard let player = player else {
            os_log("⚠️ SKIP FORWARD: No player available", log: log, type: .error)
            return
        }
        
        guard let currentEpisode = currentEpisode else {
            os_log("⚠️ SKIP FORWARD: No current episode", log: log, type: .error)
            return
        }
        
        let currentTime = player.currentTime().seconds
        os_log("⏭️ SKIP FORWARD: Current time %.1fs, duration %.1fs", log: log, type: .info, currentTime, duration)
        
        seek(by: 30)
        os_log("⏭️ SKIP FORWARD: 30s forward seek command completed", log: log, type: .info)
    }
    
    func skipBackward() {
        os_log("⏪ SKIP BACKWARD: Button pressed - seeking 15s backward", log: log, type: .info)
        
        guard let player = player else {
            os_log("⚠️ SKIP BACKWARD: No player available", log: log, type: .error)
            return
        }
        
        guard let currentEpisode = currentEpisode else {
            os_log("⚠️ SKIP BACKWARD: No current episode", log: log, type: .error)
            return
        }
        
        let currentTime = player.currentTime().seconds
        os_log("⏪ SKIP BACKWARD: Current time %.1fs, duration %.1fs", log: log, type: .info, currentTime, duration)
        
        seek(by: -15)
        os_log("⏪ SKIP BACKWARD: 15s backward seek command completed", log: log, type: .info)
    }
    
    private func seek(by seconds: Double) {
        // CRITICAL FIX: Get actual current time from player for accurate skip operations
        // Don't rely on cached currentTime which might be stale or protected
        guard let player = player else {
            os_log("⚠️ SEEK BY: No player available", log: log, type: .error)
            return
        }
        
        guard duration > 0 else {
            os_log("⚠️ SEEK BY: Invalid duration %.1fs", log: log, type: .error, duration)
            return
        }
        
        let actualCurrentTime = max(0, player.currentTime().seconds)
        let newTime = min(max(actualCurrentTime + seconds, 0), duration)
        
        os_log("🎯 SKIP SEEK: From actual time %.1fs %@ %.1fs to %.1fs (duration: %.1fs)", 
               log: log, type: .info, actualCurrentTime, seconds > 0 ? "+" : "", seconds, newTime, duration)
        
        // Ensure we're actually seeking to a different time
        if abs(newTime - actualCurrentTime) < 0.1 {
            os_log("⚠️ SKIP SEEK: New time %.1fs too close to current time %.1fs, skipping", 
                   log: log, type: .info, newTime, actualCurrentTime)
            return
        }
        
        seek(to: newTime)
    }
    
    private func setupTimeObserver() {
        if let existingObserver = timeObserver {
            player?.removeTimeObserver(existingObserver)
        }
        
        // PERFORMANCE OPTIMIZATION: Reduce update frequency from 1s to 2s to improve scrolling
        // This dramatically reduces CPU usage while maintaining acceptable UI responsiveness
        let interval = CMTime(seconds: lightUpdateInterval, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .global(qos: .utility)) { [weak self] _ in
            // Use background queue for time updates to avoid blocking main thread
            DispatchQueue.main.async { [weak self] in
                self?.updateCurrentTimeOnly()
            }
        }
        
        // Set up scroll detection to pause heavy updates during user interaction
        setupScrollDetection()
    }
    
    // PERFORMANCE: Setup scroll detection to pause expensive updates during scrolling
    private func setupScrollDetection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollStart),
            name: .userIsScrolling,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollEnd),
            name: .userStoppedScrolling,
            object: nil
        )
    }
    
    @objc private func handleScrollStart() {
        isUserScrolling = true
        lastScrollNotificationTime = Date()
        
        // Cancel any pending scroll detection timer
        scrollDetectionTimer?.invalidate()
        
        // Reduce logging during scrolling for better performance
        // os_log("🏃‍♂️ User started scrolling - pausing heavy updates for performance", log: log, type: .debug)
    }
    
    @objc private func handleScrollEnd() {
        // Use a timer to detect when scrolling has truly stopped
        scrollDetectionTimer?.invalidate()
        scrollDetectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.isUserScrolling = false
            // Reduce logging during scrolling for better performance
            // os_log("🛑 User stopped scrolling - resuming normal updates", log: self?.log ?? OSLog.default, type: .debug)
        }
    }
    
    // MARK: - Selective Cross-Device Sync Management
    
    /// Perform cross-device sync only on specific events (pause, background, termination)
    private func performCrossDeviceSync(reason: String) {
        guard let currentEpisode = currentEpisode else { return }
        
        // Only sync if enough time has passed since last sync to avoid spam
        let timeSinceLastSync = Date().timeIntervalSince(lastCrossDeviceSyncTime)
        guard timeSinceLastSync >= 2.0 else { return } // Minimum 2 seconds between syncs
        
        let progress = duration > 0 ? min(max(currentTime / duration, 0), 1.0) : 0
        
        
        // Use conditional sync system
        let syncReason = mapReasonToSyncCondition(reason)
        EpisodeStateManager.shared.performInstantSyncForEpisode(currentEpisode.id, reason: syncReason)
        
        lastCrossDeviceSyncTime = Date()
    }
    
    /// Map player sync reasons to EpisodeStateManager sync conditions
    private func mapReasonToSyncCondition(_ reason: String) -> String {
        switch reason {
        case "pause":
            return "episode_paused"
        case "stop":
            return "app_closed"
        case "background", "willTerminate", "didEnterBackground", "willResignActive":
            return "app_background"
        default:
            return "episode_paused" // Default fallback
        }
    }
    
    // Lightweight method that only updates time values without heavy operations
    private func updateCurrentTimeOnly() {
        guard let player = player else { return }
        
        // PERFORMANCE: Skip all updates during scrolling to prevent hangs
        if isUserScrolling {
            return
        }
        
            // MAIN THREAD FIX: Check app state on main thread to prevent violations
    Task { @MainActor in
        // Skip updates if app is in background to save battery and resources
        guard UIApplication.shared.applicationState == .active else { return }
        
        Task { [weak self] in
                guard let self = self else { return }
                
                // Only update the time values - no heavy operations
                await MainActor.run {
                    // CRITICAL FIX: Check chapter protection before updating ANY time values
                    let now = Date()
                    let isProtectedFromChapterSeek = self.lastChapterSeekTime != nil && 
                        now.timeIntervalSince(self.lastChapterSeekTime!) < self.chapterSeekProtectionInterval
                    
                    // Only update currentTime if we're not in chapter protection period
                    if !isProtectedFromChapterSeek {
                        self.currentTime = max(0, player.currentTime().seconds)
                    } else {
                        os_log("🛡️ TIME PROTECTION: Skipping currentTime update during chapter protection (%.1fs remaining)", 
                               log: self.log, type: .debug, self.chapterSeekProtectionInterval - now.timeIntervalSince(self.lastChapterSeekTime!))
                    }
                    
                    if let currentItem = player.currentItem {
                        let newDuration = currentItem.duration.seconds
                        if newDuration.isFinite && newDuration > 0 {
                            self.duration = newDuration
                        }
                    }
                    
                    if !isProtectedFromChapterSeek {
                        // CRITICAL FIX: Only recalculate progress if the time difference is significant
                        // This prevents minor time observer fluctuations from overriding precise seek positions
                        let calculatedProgress = self.duration > 0 ? min(self.currentTime / self.duration, 1) : 0
                        let progressDifference = abs(calculatedProgress - self.currentProgress)
                        
                        // Only update if the difference is significant (more than 1 second of content)
                        let significantThreshold = self.duration > 0 ? (1.0 / self.duration) : 0.01
                        
                        if progressDifference > significantThreshold {
                            self.currentProgress = calculatedProgress
                            
                            // ENHANCED PROTECTION: Validate progress every few seconds during playback
                            if let currentEpisode = self.currentEpisode, Int(self.currentTime) % 10 == 0 {
                                let validatedProgress = self.validateAndRecoverProgress(for: currentEpisode.id)
                                if validatedProgress != self.currentProgress {
                                    os_log("CONTINUOUS PROTECTION: Recovered progress from %.4f to %.4f during playback", 
                                           log: self.log, type: .info, self.currentProgress, validatedProgress)
                                }
                            }
                        }
                    } else {
                        // Protected mode: Keep the chapter-seek progress, just log that we're protecting it
                        os_log("🛡️ TIME OBSERVER: Protected chapter seek progress %.2f%% from override (%.1fs remaining)", 
                               log: self.log, type: .debug, self.currentProgress * 100, 
                               self.chapterSeekProtectionInterval - now.timeIntervalSince(self.lastChapterSeekTime!))
                    }
                }
                
                // CRITICAL FIX: Update Now Playing Info Center immediately for lock screen sync
                // This ensures lock screen controls show real-time progress
                self.updateNowPlayingInfoElapsedTimeOnly()
                
                // PERFORMANCE: Only trigger heavy operations if user is not scrolling
                if !self.isUserScrolling {
                    self.updatePlaybackInfoThrottled()
                }
            }
        }
    }
    
    // Throttled heavy operations to prevent CPU spikes - optimized for better performance
    private var lastHeavyUpdate = Date()
    private func updatePlaybackInfoThrottled() {
        let now = Date()
        
        // PERFORMANCE: Increase throttle interval and skip during scrolling
        let throttleInterval = isUserScrolling ? scrollingPauseInterval : heavyUpdateInterval
        
        if now.timeIntervalSince(lastHeavyUpdate) >= throttleInterval {
            lastHeavyUpdate = now
            
            // Run heavy operations on background queue to avoid blocking UI
            Task.detached(priority: .utility) { [weak self] in
                self?.updatePlaybackInfo()
            }
        }
    }
    
    private func updateNowPlayingInfoDebounced() {
        nowPlayingUpdateTimer?.invalidate()
        
        // PERFORMANCE: Increase debounce interval based on scroll state
        let debounceInterval: TimeInterval = isUserScrolling ? 30.0 : 10.0
        
        nowPlayingUpdateTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            // Skip if user is actively scrolling
            guard let self = self, !self.isUserScrolling else { return }
            
            Task.detached(priority: .utility) { [weak self] in
                self?.updateNowPlayingInfo()
            }
        }
    }
    
    // PERFORMANCE: Track last lock screen update time for throttling
    private var lastLockScreenUpdate = Date(timeIntervalSince1970: 0)
    
    // CRITICAL FIX: Lightweight method to update only elapsed time for real-time lock screen sync
    private func updateNowPlayingInfoElapsedTimeOnly() {
        // Only update if podcast is the active player
        guard PlaybackManager.shared.activePlayer == .podcast else { return }
        
        let now = Date()
        
        // 🎯 SNAPSHOT PERFORMANCE: Reduce lock screen update frequency when using snapshots
        // For now, assume no snapshot to be safe - this will default to 1 second updates
        let throttleInterval: TimeInterval = 1.0 // Always use 1 second for now to avoid main actor issues
        
        // Skip if we've updated too recently
        guard now.timeIntervalSince(lastLockScreenUpdate) >= throttleInterval else { return }
        lastLockScreenUpdate = now
        
        // Get current Now Playing info and update only the elapsed time
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingCenter.nowPlayingInfo ?? [:]
        
        // Update only the elapsed time - this is lightweight and prevents lock screen rewind
        let elapsedTime = max(0, currentTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Set the updated info immediately - no debouncing for elapsed time
        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
        
        // 📊 PERFORMANCE LOG: Show throttling status
        os_log("🔄 Lock Screen Sync: Updated elapsed time to %.1fs (throttled to %.1fs intervals)", 
               log: log, type: .debug, elapsedTime, throttleInterval)
    }
    

    
    func updateNowPlayingInfo() {
        // Only update Now Playing info if podcast is the active player
        guard PlaybackManager.shared.activePlayer == .podcast else {
            os_log("Podcast is not the active player, skipping Now Playing update", log: log, type: .info)
            return
        }
        
        guard let currentEpisode = currentEpisode,
              let currentFeed = currentFeed else {
            os_log("Unable to update now playing info: current episode or feed is nil", log: log, type: .error)
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentEpisode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentFeed.title
        // Use feed description as album title for lock screen navigation
        // This enables users to tap on the description to navigate to the episode list
        if let feedDescription = currentFeed.descriptionText, !feedDescription.isEmpty {
            // Truncate description if too long for display
            let truncatedDescription = feedDescription.count > 100 ? 
                String(feedDescription.prefix(97)) + "..." : feedDescription
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = truncatedDescription
        } else {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentFeed.title
        }
        
        // CRITICAL: Ensure elapsed time is correctly set for CarPlay progress bar
        let elapsedTime = max(0, currentTime)
        let totalDuration = max(0.01, duration)
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        os_log("Podcast Now Playing: Elapsed=%.1fs, Duration=%.1fs, Rate=%.1f", log: log, type: .debug, elapsedTime, totalDuration, isPlaying ? 1.0 : 0.0)
        
        // Optimized artwork handling - use cached artwork to reduce CPU overhead
        var artworkSet = false
        
        // First priority: Direct image data (most efficient)
        if let imageData = currentFeed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Now Playing: Using imageData for artwork (%d bytes)", log: log, type: .debug, imageData.count)
            }
        }
        
        // Second priority: Base64 encoded icon data (efficient)
        if !artworkSet, let iconData = currentFeed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Now Playing: Using iconData for artwork (%d bytes)", log: log, type: .debug, data.count)
            } else {
                os_log("Podcast Now Playing: Failed to decode iconData base64", log: log, type: .error)
            }
        }
        
        // OPTIMIZATION: Skip artwork URL downloads to reduce CPU and network overhead
        // Artwork URL downloads are expensive and not critical for CarPlay functionality
        // CarPlay will use the feed artwork or system defaults if no artwork is available
        if !artworkSet {
            os_log("Podcast Now Playing: No cached artwork available, skipping download to optimize CPU usage", log: log, type: .debug)
        }
        
        // Third priority: Download from artwork URL (async)
        if !artworkSet, let artworkUrlString = currentFeed.artworkUrl, !artworkUrlString.isEmpty {
            if let artworkUrl = URL(string: artworkUrlString) {
                os_log("Podcast Now Playing: Downloading artwork from URL: %@", log: log, type: .info, artworkUrlString)
                
                URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        var updatedInfo = nowPlayingInfo
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        
                        DispatchQueue.main.async {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            os_log("Podcast Now Playing: Successfully set artwork from URL (%d bytes, %dx%d)", 
                                   log: self.log, type: .info, data.count, Int(image.size.width), Int(image.size.height))
                            
                            // CRITICAL: Save artwork to Core Data immediately for fast app restart and podcast player display
                            Task {
                                do {
                                    try await PodcastCoreDataManager.shared.updateFeedArtwork(currentFeed.id, imageData: data)
                                    os_log("📦 Saved downloaded artwork to Core Data for feed: %@", log: self.log, type: .info, currentFeed.title)
                                    
                                    // Update the viewModel's feed with the downloaded artwork for immediate UI update
                                    await MainActor.run {
                                        if let viewModel = self.viewModel {
                                            if let feedIndex = viewModel.podcastFeeds.firstIndex(where: { $0.id == currentFeed.id }) {
                                                viewModel.podcastFeeds[feedIndex].imageData = data
                                                os_log("🔄 Updated in-memory feed artwork for immediate display: %@", log: self.log, type: .info, currentFeed.title)
                                            }
                                        }
                                    }
                                } catch {
                                    os_log("❌ Failed to save artwork to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                                }
                            }
                        }
                    } else {
                        os_log("Podcast Now Playing: Failed to load artwork from URL: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                    }
                }.resume()
            }
        }
        
        // Set the now playing info (with or without artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        if !artworkSet {
            os_log("Podcast Now Playing: No artwork available for feed '%@'", log: log, type: .info, currentFeed.title)
        }
        
        os_log("Podcast Now Playing: Update complete for episode '%@' from feed '%@'", log: log, type: .debug, currentEpisode.title, currentFeed.title)
    }
    
    func getCurrentProgress(for episode: PodcastEpisode) -> Double {
           if currentEpisode?.id == episode.id {
               return min(max(currentProgress, 0), 1)
           } else {
               // Skip viewModel getProgress call to avoid main actor issues
               return min(max(episode.state.progress, 0), 1)
           }
       }
    
    // PERFORMANCE: Async progress update with optimized UI updates
    private func updateProgress() async {
        guard let currentEpisode = currentEpisode, duration > 0 else { return }
        // CRITICAL FIX: Clamp progress between 0 and 1 to prevent progress bar showing 100% while still playing
        let progress = min(max(currentTime / duration, 0), 1.0)
        
        await MainActor.run {
            self.currentProgress = progress
        }
        
        // Calculate remaining time
        let remainingTime = max(duration - currentTime, 0)
        
        // PERFORMANCE: Only update in-memory progress during playback - NO saves or StateManager updates
        // Progress will only be saved when:
        // 1. App is force closed (handleAppWillTerminate)
        // 2. App goes to background (handleAppTermination)  
        // 3. User pauses episode (pause function)
        // 4. User switches episodes (playEpisode function)
        
        // OPTIMIZE: Reduce in-memory cache updates to every 10% to minimize CPU usage (was 25%)
        let progressPercent = Int(progress * 100)
        let lastProgressPercent = Int((lastCarPlayProgress ?? 0) * 100)
        
        // Only update memory and CarPlay every 10% to drastically reduce CPU usage
        if progressPercent != lastProgressPercent && progressPercent % 10 == 0 {
            lastCarPlayProgress = progress
            
            // PERFORMANCE: Update cache only when not scrolling
            if !isUserScrolling {
                await MainActor.run {
                    viewModel?.episodeProgress[currentEpisode.id] = progress
                }
                
                // OPTIMIZE: Reduce CarPlay notifications to minimum (every 10%)
                NotificationCenter.default.post(
                    name: NSNotification.Name("PodcastProgressUpdated"),
                    object: nil,
                    userInfo: [
                        "episodeId": currentEpisode.id,
                        "progress": progress,
                        "isPlaying": isPlaying,
                        "currentTime": currentTime,
                        "duration": duration
                    ]
                )
                
                // PERFORMANCE: Skip expensive CloudKit sync when snapshots are available
                let hasSnapshot = await MainActor.run {
                    viewModel?.getEpisodeSnapshot(for: currentEpisode.feedId) != nil
                }
                
                if hasSnapshot != true {
                    // REAL-TIME CROSS-DEVICE SYNC: Sync progress every 10% during playback for cross-device sync
                    PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                        episodeId: currentEpisode.id,
                        progress: progress
                    )
                } else {
                    print("⚡ PERFORMANCE: Skipped playback CloudKit sync - using snapshot for feed \(currentEpisode.feedId)")
                }
                
                os_log("🚗 CarPlay progress update sent: %@, Progress: %.1f%% (CPU optimized)", log: log, type: .debug, currentEpisode.title, progress * 100)
            }
        }
        
        // REMOVED: Premature completion logic that was cutting off the last few seconds
        // Episodes should only be marked complete when AVPlayerItemDidPlayToEndTime fires
        // This ensures 100% of the audio is played before marking as complete
        
        // PERFORMANCE: Completely disable objectWillChange.send() to eliminate scrolling lag
        // UI updates will happen naturally through @Published properties and SwiftUI's observation system
        // This is the most critical optimization for smooth scrolling during playback
    }
    
    private func formatRemainingTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func handleAppWillTerminate() {
        if let currentEpisode = currentEpisode {
            // CRITICAL FIX: Prioritize currentTime over player time to prevent 3-4 second loss during force close
            // The time observer (currentTime) is more accurate than AVPlayer's currentTime() during force close
            let actualCurrentTime = currentTime // Use time observer value instead of player?.currentTime().seconds
            let calculatedProgress = duration > 0 ? actualCurrentTime / duration : 0
            
            os_log("🛑 FORCE CLOSE: Using currentTime=%.1fs instead of AVPlayer time to prevent progress loss", 
                   log: log, type: .info, currentTime)
            
            // CRITICAL: Preserve maximum progress to prevent reset during force close
            // Get existing progress from StateManager and use the maximum value
            let existingProgress = stateManager.getProgress(for: currentEpisode.id)
            
            // CHAPTER SEEK FIX: If we're in chapter protection period, use currentProgress directly
            let now = Date()
            let isProtectedFromChapterSeek = lastChapterSeekTime != nil && 
                now.timeIntervalSince(lastChapterSeekTime!) < chapterSeekProtectionInterval
            
            // CRITICAL FIX: Always prioritize currentProgress over calculated progress during force close
            // currentProgress is updated by time observer and is more reliable than AVPlayer time
            let preferredProgress = currentProgress > 0 ? currentProgress : calculatedProgress
            
            os_log("🛑 FORCE CLOSE PROGRESS: currentProgress=%.2f%%, calculatedProgress=%.2f%%, using preferredProgress=%.2f%%", 
                   log: log, type: .info, currentProgress * 100, calculatedProgress * 100, preferredProgress * 100)
            
            let maxProgress: Double
            if isProtectedFromChapterSeek {
                // During chapter protection: Use the chapter-jumped progress directly, don't use max()
                maxProgress = preferredProgress
                os_log("🛡️ CHAPTER PROTECTION: Using chapter seek progress %.2f%% instead of max with existing %.2f%%", 
                       log: log, type: .info, preferredProgress * 100, existingProgress * 100)
            } else {
                // Normal operation: Use maximum progress to prevent reset during force close
                maxProgress = max(preferredProgress, existingProgress)
            }
            
            // Use the most accurate current time, but preserve progress if it's higher
            let finalCurrentTime = max(actualCurrentTime, currentTime)
            
            os_log("🛑 App force close/background - saving progress for episode: %@ (calculated: %.2f%%, existing: %.2f%%, current: %.2f%% -> final: %.2f%%)", 
                   log: log, type: .info, currentEpisode.title, calculatedProgress * 100, existingProgress * 100, currentProgress * 100, maxProgress * 100)
            
            // CRITICAL FIX: Use Core Data priority approach for force close
            // This ensures Core Data is saved first, then CloudKit syncs afterward
            saveProgressWithCoreDataPriority(for: currentEpisode, progress: maxProgress, reason: "app force closed")
            
            // Save to StateManager with maximum progress (synchronous and reliable)
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: maxProgress)
            
            // Force synchronize UserDefaults immediately
            UserDefaults.standard.synchronize()
            
            // Update in-memory cache directly
            Task { @MainActor in
                viewModel?.episodeProgress[currentEpisode.id] = maxProgress
            }
            
            os_log("✅ Progress saved for app force close/background: %@, Progress: %.2f%%", log: log, type: .info, currentEpisode.title, maxProgress * 100)
        }
    }
    
    private func setupNowPlaying(for episode: PodcastEpisode, feed: PodcastFeed) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = episode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = feed.title
        // Use feed description as album title for lock screen navigation
        if let feedDescription = feed.descriptionText, !feedDescription.isEmpty {
            let truncatedDescription = feedDescription.count > 100 ? 
                String(feedDescription.prefix(97)) + "..." : feedDescription
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = truncatedDescription
        } else {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = feed.title
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Enhanced artwork priority: imageData -> iconData -> artworkUrl (same as CarPlay)
        var artworkSet = false
        
        // First priority: Direct image data
        if let imageData = feed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Setup: Using imageData for artwork (%d bytes)", log: log, type: .debug, imageData.count)
            }
        }
        
        // Second priority: Base64 encoded icon data
        if !artworkSet, let iconData = feed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                artworkSet = true
                os_log("Podcast Setup: Using iconData for artwork (%d bytes)", log: log, type: .debug, data.count)
            } else {
                os_log("Podcast Setup: Failed to decode iconData base64", log: log, type: .error)
            }
        }
        
        // Third priority: Download from artwork URL (async)
        if !artworkSet, let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty {
            if let artworkUrl = URL(string: artworkUrlString) {
                os_log("Podcast Setup: Downloading artwork from URL: %@", log: log, type: .info, artworkUrlString)
                
                URLSession.shared.dataTask(with: artworkUrl) { data, _, error in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        var updatedInfo = nowPlayingInfo
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        
                        DispatchQueue.main.async {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            os_log("Podcast Setup: Successfully set artwork from URL (%d bytes, %dx%d)", 
                                   log: self.log, type: .info, data.count, Int(image.size.width), Int(image.size.height))
                            
                            // CRITICAL: Save artwork to Core Data immediately for fast app restart and podcast player display
                            Task {
                                do {
                                    try await PodcastCoreDataManager.shared.updateFeedArtwork(feed.id, imageData: data)
                                    os_log("📦 Saved downloaded artwork to Core Data for feed: %@", log: self.log, type: .info, feed.title)
                                    
                                    // Update the viewModel's feed with the downloaded artwork for immediate UI update
                                    await MainActor.run {
                                        if let viewModel = self.viewModel {
                                            if let feedIndex = viewModel.podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                                                viewModel.podcastFeeds[feedIndex].imageData = data
                                                os_log("🔄 Updated in-memory feed artwork for immediate display: %@", log: self.log, type: .info, feed.title)
                                            }
                                        }
                                    }
                                } catch {
                                    os_log("❌ Failed to save artwork to Core Data: %@", log: self.log, type: .error, error.localizedDescription)
                                }
                            }
                        }
                    } else {
                        os_log("Podcast Setup: Failed to load artwork from URL: %@", log: self.log, type: .error, error?.localizedDescription ?? "Unknown error")
                    }
                }.resume()
            }
        }
        
        // Set the now playing info (with or without artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        if !artworkSet {
            os_log("Podcast Setup: No artwork available for feed '%@'", log: log, type: .info, feed.title)
        }
        
        os_log("Podcast Setup: Setup complete for episode '%@' from feed '%@'", log: log, type: .debug, episode.title, feed.title)
    }
    
    deinit {
        // Ensure progress is saved even if the object is deallocated unexpectedly
        if let currentEpisode = currentEpisode, isPlaying {
            let calculatedProgress = duration > 0 ? currentTime / duration : 0
            
            // CRITICAL: Preserve maximum progress during deallocation
            let existingProgress = stateManager.getProgress(for: currentEpisode.id)
            let maxProgress = max(calculatedProgress, existingProgress, currentProgress)
            
            // Update in-memory cache directly without triggering CloudKit saves
            Task { @MainActor in
                viewModel?.episodeProgress[currentEpisode.id] = maxProgress
            }
            stateManager.pausePlayback(episodeId: currentEpisode.id, progress: maxProgress)
            os_log("Saved maximum progress on deinit for episode: %@, Progress: %.2f", log: log, type: .info, currentEpisode.title, maxProgress)
        }
        
        // Clean up network reconnection resources
        stopReconnectionAttempts()
        
        // Stop reachability monitoring
        reachability?.stopNotifier()
        
        playerItemObserver?.invalidate()
        updateTimer?.invalidate()
        nowPlayingUpdateTimer?.invalidate()
        
        // Remove observers to prevent memory leaks
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Notification Extensions
// Note: Notification names are declared in RadioStationListView.swift to avoid duplication

struct UserDefaultsKeys {
    static func progressKey(for episodeId: String) -> String {
        return "PodcastProgress_\(episodeId)"
    }
}
