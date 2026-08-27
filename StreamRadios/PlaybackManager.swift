//
//  PlaybackManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 9/10/24.
//

import SwiftUI
import AVFoundation
import MediaPlayer

enum ActivePlayer: String {
    case radio = "radio"
    case podcast = "podcast"
    case none = "none"
}

class PlaybackManager: ObservableObject {
    static let shared = PlaybackManager()
    
    /// `.allowBluetooth` is the HFP (call) profile and is rejected with OSStatus -50 on the
    /// `.playback` category. A2DP is what Bluetooth audio streaming actually uses.
    static let playbackCategoryOptions: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]
    
    @Published var activePlayer: ActivePlayer = .none
    private var audioSessionConfigured = false
    private var backgroundInterruptionTimer: Timer?
    // State tracking for logging optimization
    private var lastLoggedActivePlayer: ActivePlayer?
    private var lastAudioSessionActivation: (ActivePlayer, Date)?
    
    // PHONE CALL FIX: Prevent concurrent audio session activations causing OSStatus -50
    private var isActivatingAudioSession = false
    private var audioSessionRetryCount = 0
    private let maxAudioSessionRetries = 3
    
    // Interruption state tracking
    // PHONE CALL FIX: Made internal so individual players can coordinate state
    internal var radioWasPlayingBeforeInterruption = false
    internal var podcastWasPlayingBeforeInterruption = false
    
    private init() {
        setupCentralizedAudioSession()
        setupAudioInterruptionHandling()
    }
    
    func setActivePlayer(_ player: ActivePlayer, shouldActivateSession: Bool = false) {
        let previousPlayer = activePlayer
        activePlayer = player
        
        // Save the last active player to UserDefaults for app restart restoration
        UserDefaults.standard.set(player.rawValue, forKey: "LastActivePlayer")
        UserDefaults.standard.synchronize() // Force immediate save
        
        // FIRST-TIME PLAYBACK TRACKING: Mark that content has been played for TabView hiding behavior
        if player != .none && !hasEverPlayedContent() {
            markContentAsPlayed()
        }
        
        lastLoggedActivePlayer = player
        
        // Only activate audio session if requested (i.e., when actually starting playback)
        // Don't activate during startup restoration to avoid conflicts
        if shouldActivateSession {
            activateAudioSessionForPlayer(player)
        }
    }
    
    /// Get the last active player from UserDefaults for app startup restoration
    func getLastActivePlayer() -> ActivePlayer? {
        let rawValue = UserDefaults.standard.string(forKey: "LastActivePlayer")
        
        guard let rawValue = rawValue,
              let player = ActivePlayer(rawValue: rawValue) else {
            return nil
        }
        return player
    }
    
    // MARK: - First-Time Playback Tracking
    
    /// Check if user has ever played any content (radio or podcast)
    func hasEverPlayedContent() -> Bool {
        return UserDefaults.standard.bool(forKey: "HasEverPlayedContent")
    }
    
    /// Mark that content has been played for the first time
    private func markContentAsPlayed() {
        UserDefaults.standard.set(true, forKey: "HasEverPlayedContent")
        UserDefaults.standard.synchronize()
        print("🎵 PlaybackManager: Marked content as played - TabView hiding on scroll now enabled")
    }
    
    private func setupCentralizedAudioSession() {
        // Configure audio session synchronously on main thread to prevent startup race conditions
        // This ensures the session is configured before any player tries to use it
        let audioSession = AVAudioSession.sharedInstance()
        
        // Check if audio session is already configured by another component
        // SHAZAM FIX: Don't interfere if another component needs .playAndRecord (like Shazam)
        if audioSession.category == .playAndRecord {
            print("🎤 PlaybackManager: Audio session is .playAndRecord (likely Shazam recording) - skipping configuration")
            self.audioSessionConfigured = true
            return
        }
        
        // Check if already configured with .playback category
        let desiredOptions = PlaybackManager.playbackCategoryOptions
        let isAlreadyPlayback = audioSession.category == .playback
        let hasCorrectOptions = audioSession.categoryOptions.contains(desiredOptions)
        
        if isAlreadyPlayback && hasCorrectOptions {
            print("✅ PlaybackManager: Audio session already configured with .playback and correct options")
            self.audioSessionConfigured = true
            return
        }
        
        // Need to configure or update the audio session
        do {
            // If session is active and we need to change it, deactivate first to avoid error -50
            if audioSession.isOtherAudioPlaying || (isAlreadyPlayback && !hasCorrectOptions) {
                // Try to deactivate first, but don't fail if it's in use
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
            
            // Use optimized audio session configuration for background stability
            // This configuration is essential for preventing app termination during lock screen playback
            // CRITICAL: NO mixing options to ensure phone calls completely interrupt our audio
            // PHONE CALL FIX: Explicitly exclude .mixWithOthers and .duckOthers to prevent audio mixing
            try audioSession.setCategory(.playback, 
                                       mode: .default, 
                                       options: desiredOptions)
            
            // Set preferred buffer duration for better background performance
            try audioSession.setPreferredIOBufferDuration(0.1) // 100ms buffer for stability
            
            print("✅ PlaybackManager: Centralized audio session configured for background stability")
            self.audioSessionConfigured = true
            
        } catch let error as NSError {
            // If we get error -50, it means parameters are invalid or session is in use
            // Try a gentler approach without deactivating
            if error.code == -50 {
                print("⚠️ PlaybackManager: Audio session in use (error -50), will configure on first activation")
                // Don't try to force it during init - wait until actual activation
                self.audioSessionConfigured = true
                return
            }
            
            print("❌ PlaybackManager: Failed to configure centralized audio session: \(error)")
            DebugLogger.logError("Audio session configuration failed: \(error.localizedDescription)", category: "AudioSession")
            
            // Log additional context for debugging
            DebugLogger.logInfo("Audio session failure context - Category: \(audioSession.category.rawValue), Options: \(audioSession.categoryOptions.rawValue), Active: \(audioSession.isOtherAudioPlaying)", category: "AudioSession")
            
            // Mark as configured even on error to prevent repeated attempts
            self.audioSessionConfigured = true
        }
    }
    
    func activateAudioSessionForPlayer(_ player: ActivePlayer) {
        guard audioSessionConfigured else {
            setupCentralizedAudioSession()
            return
        }
        
        // CRITICAL: Prevent concurrent audio session activations
        guard !isActivatingAudioSession else {
            print("🔒 PlaybackManager: Audio session activation already in progress, skipping duplicate request for \(player)")
            return
        }
        
        // CRITICAL: Use a more robust activation flag that persists through async operations
        isActivatingAudioSession = true
        
        // Ensure flag is reset after a maximum timeout to prevent permanent blocking
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isActivatingAudioSession = false
        }
        
        // Rate limit audio session activation logging - only log once per 3 seconds per player
        let now = Date()
        let shouldLog = lastAudioSessionActivation == nil || 
                       lastAudioSessionActivation!.0 != player || 
                       now.timeIntervalSince(lastAudioSessionActivation!.1) > 3.0
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // For CarPlay scenarios, implement a more robust waiting mechanism
            if CarPlayManager.shared.isCarPlayConnected {
                print("🚗 PlaybackManager: CarPlay detected - implementing careful audio session handover")
                
                // Don't reset flag here - let the timeout handle it
                
                // Use a more patient approach with multiple attempts
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.attemptCarPlayAudioSessionActivation(for: player, attempt: 1)
                }
                return // Exit early to avoid immediate activation
            }
            
            // Ensure audio session has correct configuration before activating
            let desiredOptions = PlaybackManager.playbackCategoryOptions
            if audioSession.category != .playback || !audioSession.categoryOptions.contains(desiredOptions) {
                // Need to reconfigure before activating
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: desiredOptions)
            }
            
            // Activate the audio session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Reset retry count on successful activation
            audioSessionRetryCount = 0
            // Reset activation flag on success
            isActivatingAudioSession = false
            
            // Only log if enough time has passed or player changed
            if shouldLog {
                print("✅ PlaybackManager: Audio session activated for \(player)")
                lastAudioSessionActivation = (player, now)
            }
            
            // CRITICAL: Only clear Now Playing info when explicitly switching between different players
            // Don't clear during CarPlay transitions, interruption resume, or when reactivating the same player
            let currentRoute = audioSession.currentRoute
            let hasCarPlayRoute = currentRoute.outputs.contains { $0.portType == .carAudio }
            
            // Check if we're in an interruption resume scenario
            let isInterruptionResume = radioWasPlayingBeforeInterruption || podcastWasPlayingBeforeInterruption ||
                                     RadioPlayer.shared.wasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption
            
            // Only clear Now Playing if we're not in a CarPlay transition, not resuming from interruption, and the player actually changed
            if !hasCarPlayRoute && !CarPlayManager.shared.isCarPlayConnected && !isInterruptionResume {
                print("🔄 PlaybackManager: Clearing Now Playing info for player switch")
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            } else if isInterruptionResume {
                print("🎵 PlaybackManager: Preserving Now Playing info during interruption resume")
            } else {
                print("🚗 PlaybackManager: Preserving Now Playing info during CarPlay transition")
            }
            
        } catch {
            print("❌ PlaybackManager: Failed to activate audio session for \(player): \(error)")
            
            // Don't reset the activation flag immediately - let the timeout handle it to prevent rapid retries
            
            // Retry with a brief delay if the error is related to conflicts, but limit retries
            if let nsError = error as NSError?, nsError.code == -50 {
                audioSessionRetryCount += 1
                if audioSessionRetryCount <= maxAudioSessionRetries {
                    print("🔄 PlaybackManager: Retrying audio session activation after conflict... (attempt \(audioSessionRetryCount)/\(maxAudioSessionRetries))")
                    
                    // Use longer delays for CarPlay scenarios to allow proper audio session handover
                    let isCarPlayActive = CarPlayManager.shared.isCarPlayConnected
                    let baseDelay = isCarPlayActive ? 1.0 : 0.5  // Increased delays to prevent conflicts
                    let retryDelay = baseDelay * Double(audioSessionRetryCount)
                    
                    if isCarPlayActive {
                        print("🚗 PlaybackManager: Using extended CarPlay retry delay: \(retryDelay)s")
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                        // Reset the flag before retry to allow the retry attempt
                        self.isActivatingAudioSession = false
                        self.activateAudioSessionForPlayer(player)
                    }
                } else {
                    print("❌ PlaybackManager: Max audio session retry attempts reached (\(maxAudioSessionRetries)). Stopping retries to prevent infinite loop.")
                    audioSessionRetryCount = 0 // Reset for next time
                    isActivatingAudioSession = false // Reset flag when giving up
                }
            } else {
                // For non -50 errors, also reset retry count and flag
                audioSessionRetryCount = 0
                isActivatingAudioSession = false
            }
        }
    }
    
    func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ PlaybackManager: Audio session deactivated")
            
            // Clear Now Playing info when deactivating
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            
        } catch {
            print("❌ PlaybackManager: Failed to deactivate audio session: \(error)")
        }
    }
    
    private func setupAudioInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // Add app lifecycle observers for background resume scenarios
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        let isInBackground = UIApplication.shared.applicationState == .background
        print("📱 PlaybackManager: App state during interruption: \(isInBackground ? "background" : "foreground")")
        
        switch type {
        case .began:
            print("🔇 PlaybackManager: Audio interruption began - activePlayer: \(activePlayer), background: \(isInBackground)")
            
            // PHONE CALL FIX: Multiple interruption protection - only capture state on FIRST interruption
            // Subsequent interruptions should not overwrite the original state
            let isFirstRadioInterruption = !radioWasPlayingBeforeInterruption
            let isFirstPodcastInterruption = !podcastWasPlayingBeforeInterruption
            
            // PHONE CALL FIX: Race condition fix - individual players may have already paused themselves
            // Use their stored state as the primary source of truth
            let radioWasPlaying = RadioPlayer.shared.wasPlayingBeforeInterruption || RadioPlayer.shared.isPlaying
            let podcastWasPlaying = PodcastPlayer.shared.wasPlayingBeforeInterruption || PodcastPlayer.shared.isPlaying
            
            print("🔍 PlaybackManager: State check - Radio isPlaying: \(RadioPlayer.shared.isPlaying), wasPlayingBeforeInterruption: \(RadioPlayer.shared.wasPlayingBeforeInterruption)")
            print("🔍 PlaybackManager: State check - Podcast isPlaying: \(PodcastPlayer.shared.isPlaying), wasPlayingBeforeInterruption: \(PodcastPlayer.shared.wasPlayingBeforeInterruption)")
            print("🔍 PlaybackManager: First interruption check - Radio: \(isFirstRadioInterruption), Podcast: \(isFirstPodcastInterruption)")
            
            // Force immediate pause of all audio to prevent mixing with phone calls
            if radioWasPlaying {
                print("📻 PlaybackManager: Force pausing radio for interruption")
                RadioPlayer.shared.player?.pause()
                RadioPlayer.shared.isPlaying = false
            }
            
            if podcastWasPlaying {
                print("🎧 PlaybackManager: Force pausing podcast for interruption")
                PodcastPlayer.shared.player?.pause()
                PodcastPlayer.shared.isPlaying = false
            }
            
            // CRITICAL: Immediately deactivate audio session to prevent ANY mixing with phone calls
            if radioWasPlaying || podcastWasPlaying {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setActive(false, options: [])
                    print("✅ PlaybackManager: Audio session immediately deactivated to prevent phone call mixing")
                } catch {
                    print("⚠️ PlaybackManager: Could not deactivate audio session: \(error)")
                    // Players are still paused above, so audio should be stopped
                }
            }
            
            // PHONE CALL FIX: Store state for BOTH players regardless of active player
            // BUT only on FIRST interruption to prevent overwriting by subsequent interruptions
            if isFirstRadioInterruption && radioWasPlaying {
                radioWasPlayingBeforeInterruption = true
                print("📻 PlaybackManager: Radio wasPlayingBeforeInterruption = \(radioWasPlayingBeforeInterruption) (FIRST interruption)")
            } else if isFirstRadioInterruption {
                print("📻 PlaybackManager: Radio was NOT playing before interruption (FIRST interruption)")
            } else {
                print("📻 PlaybackManager: Radio state unchanged (subsequent interruption) = \(radioWasPlayingBeforeInterruption)")
            }
            
            if isFirstPodcastInterruption && podcastWasPlaying {
                podcastWasPlayingBeforeInterruption = true
                print("🎧 PlaybackManager: Podcast wasPlayingBeforeInterruption = \(podcastWasPlayingBeforeInterruption) (FIRST interruption)")
            } else if isFirstPodcastInterruption {
                print("🎧 PlaybackManager: Podcast was NOT playing before interruption (FIRST interruption)")
            } else {
                print("🎧 PlaybackManager: Podcast state unchanged (subsequent interruption) = \(podcastWasPlayingBeforeInterruption)")
            }
            
            if isInBackground {
                print("🌙 PlaybackManager: Background interruption detected - checking network conditions")
                // GPS FIX: Check network conditions before starting aggressive timer
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    let shouldMonitor = (self.activePlayer == .radio && self.radioWasPlayingBeforeInterruption) ||
                                      (self.activePlayer == .podcast && self.podcastWasPlayingBeforeInterruption)
                    if shouldMonitor {
                        // GPS FIX: Only start timer if network conditions are good
                        if self.isNetworkConditionGoodForTimer() {
                            self.startBackgroundInterruptionTimer()
                        } else {
                            print("🛰️ PlaybackManager: Poor network detected - skipping timer to protect GPS")
                            UserDefaults.standard.set(true, forKey: "NetworkInterruptionActive")
                        }
                    }
                }
            }
            
        case .ended:
            print("🔊 PlaybackManager: Audio interruption ended, background: \(isInBackground)")
            
            // PHONE CALL FIX: For phone calls, iOS doesn't always provide shouldResume correctly
            // We need to be more intelligent about when to resume
            let shouldResume = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt == AVAudioSession.InterruptionOptions.shouldResume.rawValue
            print("📞 PlaybackManager: Interruption end - shouldResume: \(shouldResume)")
            
            // PHONE CALL FIX: Log current state for debugging
            print("📞 PlaybackManager: Current interruption state - Radio: \(radioWasPlayingBeforeInterruption), Podcast: \(podcastWasPlayingBeforeInterruption)")
            
            // PHONE CALL FIX: Check BOTH PlaybackManager state AND individual player state
            // Use whichever indicates there was playback before interruption
            let radioNeedsResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                  RadioPlayer.shared.userWantsToPlay && 
                                  !RadioPlayer.shared.wasManuallyPaused
            let podcastNeedsResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                    PodcastPlayer.shared.userWantsToPlay && 
                                    !PodcastPlayer.shared.wasManuallyPaused
            
            let shouldAttemptRadioResume = radioNeedsResume
            let shouldAttemptPodcastResume = podcastNeedsResume
            
            print("📞 PlaybackManager: Resume conditions - Radio: \(shouldAttemptRadioResume), Podcast: \(shouldAttemptPodcastResume)")
            
            // CRITICAL: For background interruptions, use more aggressive resume approach
            if isInBackground {
                print("🌙 PlaybackManager: Background interruption end - using aggressive resume strategy")
                handleBackgroundInterruptionEnd()
            } else if shouldResume || shouldAttemptRadioResume || shouldAttemptPodcastResume {
                print("🌅 PlaybackManager: Foreground interruption end - attempting resume")
                
                // Reactivate audio session first
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // PHONE CALL FIX: Ensure proper category and options for resume
                    try audioSession.setCategory(.playback, 
                                               mode: .default, 
                                               options: PlaybackManager.playbackCategoryOptions)
                    try audioSession.setActive(true, options: [])
                    print("✅ PlaybackManager: Audio session reactivated for foreground resume")
                } catch {
                    print("❌ PlaybackManager: Failed to reactivate audio session: \(error)")
                }
                
                // Resume with delay to ensure audio session is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // PHONE CALL FIX: Resume whichever player was actually playing, regardless of activePlayer
                    if shouldAttemptRadioResume {
                        print("✅ PlaybackManager: Resuming radio playback after phone call")
                        PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                        RadioPlayer.shared.resumeAfterInterruption()
                        
                        // Reset interruption state after successful resume attempt
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.resetInterruptionState()
                        }
                    } else if shouldAttemptPodcastResume {
                        print("✅ PlaybackManager: Resuming podcast playback after phone call")
                        PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                        PodcastPlayer.shared.resumeAfterInterruption()
                        
                        // Reset interruption state after successful resume attempt
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.resetInterruptionState()
                        }
                    } else {
                        // No resume needed, reset state immediately
                        self.resetInterruptionState()
                    }
                }
            } else {
                print("🔇 PlaybackManager: Interruption ended but conditions not met for resume")
                print("🔇 PlaybackManager: shouldResume: \(shouldResume), radioResume: \(shouldAttemptRadioResume), podcastResume: \(shouldAttemptPodcastResume)")
                // Reset interruption state since no resume is happening
                resetInterruptionState()
            }
            
        @unknown default:
            break
        }
    }
    
    /// Handles audio interruption end when app is in background - more aggressive approach needed
    private func handleBackgroundInterruptionEnd() {
        print("🌙 PlaybackManager: Handling background interruption end")
        
        // In background, iOS may not deliver proper interruption options
        // PHONE CALL FIX: Check BOTH PlaybackManager state AND individual player state for any player that needs resume
        let radioNeedsBackgroundResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                         RadioPlayer.shared.userWantsToPlay && 
                                         !RadioPlayer.shared.wasManuallyPaused
        let podcastNeedsBackgroundResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                          PodcastPlayer.shared.userWantsToPlay && 
                                          !PodcastPlayer.shared.wasManuallyPaused
        
        let shouldAttemptResume = radioNeedsBackgroundResume || podcastNeedsBackgroundResume
        
        if shouldAttemptResume {
            print("🌙 PlaybackManager: Background resume needed - checking network conditions")
            
            // GPS FIX: Only start timer if network conditions are acceptable
            if isNetworkConditionGoodForTimer() {
                print("🌙 PlaybackManager: Network conditions acceptable - starting background timer")
                startBackgroundInterruptionTimer()
            } else {
                print("🛰️ PlaybackManager: Poor network detected - using single resume attempt to protect GPS")
                // Single gentle resume attempt instead of aggressive timer
                attemptSingleGentleResume()
                return
            }
            
            // Request background execution time for resume
            let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AudioInterruptionResume") {
                print("⚠️ PlaybackManager: Background resume task expired")
            }
            
            // Use background queue to avoid main thread issues
            DispatchQueue.global(qos: .userInitiated).async {
                // Reactivate audio session aggressively
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // PHONE CALL FIX: Ensure proper category for background resume after phone calls
                    try audioSession.setCategory(.playback, 
                                               mode: .default, 
                                               options: PlaybackManager.playbackCategoryOptions)
                    try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                    print("✅ PlaybackManager: Background audio session reactivated after phone call")
                } catch {
                    print("❌ PlaybackManager: Background audio session reactivation failed: \(error)")
                }
                
                // Resume playback with longer delay for background scenarios
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("🔄 PlaybackManager: Background resume attempt for activePlayer: \(self.activePlayer)")
                    // PHONE CALL FIX: Resume whichever player was actually playing, regardless of activePlayer
                    if radioNeedsBackgroundResume {
                        print("✅ PlaybackManager: Background resuming radio playback after phone call")
                        PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                        RadioPlayer.shared.resumeAfterInterruption()
                        
                        // Reset interruption state after background resume
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.resetInterruptionState()
                        }
                    } else if podcastNeedsBackgroundResume {
                        print("✅ PlaybackManager: Background resuming podcast playback after phone call")
                        PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                        PodcastPlayer.shared.resumeAfterInterruption()
                        
                        // Reset interruption state after background resume
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.resetInterruptionState()
                        }
                    }
                    
                    // End background task
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        print("✅ PlaybackManager: Background resume task completed")
                    }
                }
            }
        }
    }
    
    /// Handles app becoming active - check for interrupted playback that needs resume
    @objc private func handleAppDidBecomeActive() {
        // Stop any background timer since we're now in foreground
        stopBackgroundInterruptionTimer()
        
        // PHONE CALL FIX: Check if we have interrupted playback that should resume for ANY player
        let shouldResumeRadio = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                               RadioPlayer.shared.userWantsToPlay &&
                               !RadioPlayer.shared.wasManuallyPaused &&
                               !RadioPlayer.shared.isPlaying
        
        let shouldResumePodcast = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                 PodcastPlayer.shared.userWantsToPlay &&
                                 !PodcastPlayer.shared.wasManuallyPaused &&
                                 !PodcastPlayer.shared.isPlaying
        
        if shouldResumeRadio || shouldResumePodcast {
            // Reactivate audio session first
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // PHONE CALL FIX: Ensure proper category for app active resume after phone calls
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: PlaybackManager.playbackCategoryOptions)
                try audioSession.setActive(true, options: [])
            } catch {
                print("❌ PlaybackManager: Failed to reactivate audio session: \(error)")
            }
            
            // Resume with delay to ensure audio session is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if shouldResumeRadio {
                    PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                    RadioPlayer.shared.resumeAfterInterruption()
                } else if shouldResumePodcast {
                    PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                    PodcastPlayer.shared.resumeAfterInterruption()
                }
            }
        }
    }
    
    /// Handles app entering foreground - prepare for potential resume
    @objc private func handleAppWillEnterForeground() {
        // PHONE CALL FIX: Prepare for potential resume for ANY player that was interrupted
        // Audio session will be reactivated by handleAppDidBecomeActive if needed
    }
    
    /// Starts a timer to periodically check if other audio has stopped and we can resume
    /// GPS FIX: Reduced frequency and resource usage to prevent GPS interference
    private func startBackgroundInterruptionTimer() {
        // Cancel any existing timer
        backgroundInterruptionTimer?.invalidate()
        
        // Also listen for audio session route changes for immediate detection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // GPS FIX: Reduced retry attempts and increased intervals to prevent system resource conflicts
        var retryCount = 0
        let maxRetries = 8  // Reduced from 20 to 8
        
        print("⏰ PlaybackManager: Starting background interruption timer with GPS-safe intervals")
        
        // GPS FIX: Increased interval from 0.5s to 3.0s to reduce system load
        backgroundInterruptionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                print("⏰ PlaybackManager: Timer - self deallocated, stopping")
                timer.invalidate()
                return
            }
            
            retryCount += 1
            
            // GPS FIX: Implement GPS-safe exponential backoff with longer intervals
            let backoffInterval = min(pow(2.0, Double(retryCount / 2)), 15.0) // Max 15 seconds between attempts
            let shouldSkipThisCycle = (retryCount % Int(backoffInterval)) != 0
            
            if shouldSkipThisCycle && retryCount > 2 {
                print("⏰ PlaybackManager: Timer cycle \(retryCount) - GPS-safe backoff active")
                return
            }
            
            print("⏰ PlaybackManager: Timer tick \(retryCount) - checking resume conditions")
            
            // PHONE CALL FIX: Check if we should still be trying to resume ANY player
            let radioStillNeedsResume = (self.radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                       RadioPlayer.shared.userWantsToPlay && 
                                       !RadioPlayer.shared.wasManuallyPaused && 
                                       !RadioPlayer.shared.isPlaying
            let podcastStillNeedsResume = (self.podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                         PodcastPlayer.shared.userWantsToPlay && 
                                         !PodcastPlayer.shared.wasManuallyPaused && 
                                         !PodcastPlayer.shared.isPlaying
            
            let shouldStillTryResume = radioStillNeedsResume || podcastStillNeedsResume
            
            if !shouldStillTryResume {
                print("⏰ PlaybackManager: Timer - no longer need to resume, stopping timer")
                timer.invalidate()
                self.backgroundInterruptionTimer = nil
                return
            }
            
            // GPS FIX: Stop trying after reduced max retries to prevent GPS interference
            if retryCount >= maxRetries {
                print("⏰ PlaybackManager: Timer - max retries (\(maxRetries)) reached, stopping to prevent GPS interference")
                print("🛰️ PlaybackManager: GPS PROTECTION - Stopping aggressive audio session attempts")
                
                // GPS FIX: Skip system audio reset to prevent GPS interference
                print("🛰️ PlaybackManager: Skipping system audio reset to protect GPS functionality")
                
                timer.invalidate()
                self.backgroundInterruptionTimer = nil
                
                // GPS FIX: Set flag to enable manual resume instead of aggressive retries
                UserDefaults.standard.set(true, forKey: "NetworkInterruptionActive")
                return
            }
            
            // Check if audio session is actually available before attempting resume
            print("⏰ PlaybackManager: Timer - checking audio session availability")
            
            DispatchQueue.main.async {
                // PHONE CALL FIX: Prevent concurrent audio session activations
                if self.isActivatingAudioSession {
                    print("⏰ PlaybackManager: Timer - audio session activation in progress, skipping")
                    return
                }
                
                self.isActivatingAudioSession = true
                defer { self.isActivatingAudioSession = false }
                
                // Check if other audio is still playing by examining the audio session
                let audioSession = AVAudioSession.sharedInstance()
                
                // First check if other apps are using audio
                let otherAudioPlaying = audioSession.isOtherAudioPlaying
                
                // PHONE CALL FIX: Enhanced phone call detection
                let isInPhoneCall = self.isPhoneCallActive()
                
                print("⏰ PlaybackManager: Timer - otherAudioPlaying: \(otherAudioPlaying), phoneCall: \(isInPhoneCall)")
                
                // PHONE CALL FIX: Never resume during active phone calls
                if isInPhoneCall {
                    print("⏰ PlaybackManager: Timer - phone call detected, waiting for call to end...")
                    return
                }
                
                // APPLE MUSIC FIX: Apple Music may keep audio session reserved even when stopped
                // We need to be more aggressive in detecting when it's actually available
                if otherAudioPlaying {
                    print("⏰ PlaybackManager: Timer - other audio detected, waiting for session release...")
                    return
                }
                
                // Even when isOtherAudioPlaying is false, Apple Music may still hold the session
                // Try progressively more aggressive session activation approaches
                var sessionActivated = false
                
                // GPS FIX: Simplified approach to prevent GPS interference
                // Only attempt gentle activation to avoid system resource conflicts
                do {
                    try audioSession.setCategory(.playback, mode: .default, options: PlaybackManager.playbackCategoryOptions)
                    try audioSession.setActive(true, options: [])
                    print("⏰ PlaybackManager: Timer - GPS-safe audio session activation succeeded")
                    sessionActivated = true
                } catch let error as NSError {
                    if error.code == -50 {
                        print("⏰ PlaybackManager: Timer - session conflict detected, will retry in next cycle (GPS-safe mode)")
                        return
                    } else {
                        print("⏰ PlaybackManager: Timer - session error: \(error)")
                        return
                    }
                }
                
                if !sessionActivated {
                    print("⏰ PlaybackManager: Timer - failed to activate audio session, skipping resume attempt")
                    return
                }
                
                // Only attempt resume if we successfully got the audio session
                print("⏰ PlaybackManager: Timer - audio session available, attempting resume")
                
                // PHONE CALL FIX: Resume whichever player was actually playing
                if radioStillNeedsResume {
                    print("📻 PlaybackManager: Timer resuming radio playback after phone call")
                    PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                    RadioPlayer.shared.resumeAfterInterruption()
                    
                    // Check if resume was successful after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if RadioPlayer.shared.isPlaying {
                            print("✅ PlaybackManager: Timer - radio resume successful, stopping timer")
                            timer.invalidate()
                            self.backgroundInterruptionTimer = nil
                        } else {
                            print("❌ PlaybackManager: Timer - radio resume failed, will retry")
                        }
                    }
                } else if podcastStillNeedsResume {
                    print("🎧 PlaybackManager: Timer resuming podcast playback after phone call")
                    PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                    PodcastPlayer.shared.resumeAfterInterruption()
                    
                    // Check if resume was successful after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if PodcastPlayer.shared.isPlaying {
                            print("✅ PlaybackManager: Timer - podcast resume successful, stopping timer")
                            timer.invalidate()
                            self.backgroundInterruptionTimer = nil
                        } else {
                            print("❌ PlaybackManager: Timer - podcast resume failed, will retry")
                        }
                    }
                }
            }
        }
    }
    
    /// Stops the background interruption timer
    private func stopBackgroundInterruptionTimer() {
        backgroundInterruptionTimer?.invalidate()
        backgroundInterruptionTimer = nil
    }
    
    private func reactivateAudioSessionWithoutClearing() {
        guard audioSessionConfigured else {
            setupCentralizedAudioSession()
            return
        }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // MAIN THREAD FIX: Always set category to avoid IPC delays from category check
            // Checking audioSession.category on main thread causes non-deterministic delays
            try audioSession.setCategory(.playback, 
                                       mode: .default, 
                                       options: PlaybackManager.playbackCategoryOptions)
            
            // Reactivate without clearing Now Playing info during CarPlay transitions
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ PlaybackManager: Audio session reactivated without clearing Now Playing")
            
        } catch {
            print("❌ PlaybackManager: Failed to reactivate audio session: \(error)")
        }
    }
    
    /// Handles audio session route changes for immediate resume detection
    @objc private func handleAudioSessionRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        print("🔄 PlaybackManager: Audio route change - reason: \(reason.rawValue)")
        
        // Check if this indicates other audio has stopped
        if reason == .oldDeviceUnavailable || reason == .categoryChange {
            print("🔄 PlaybackManager: Route change suggests audio session may be available - checking immediately")
            
            // Trigger immediate resume check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.attemptImmediateResume()
            }
        }
    }
    
    /// Attempts immediate resume when audio session becomes available
    private func attemptImmediateResume() {
        // PHONE CALL FIX: Check for immediate resume for ANY player
        let radioNeedsImmediateResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                       RadioPlayer.shared.userWantsToPlay && 
                                       !RadioPlayer.shared.wasManuallyPaused && 
                                       !RadioPlayer.shared.isPlaying
        let podcastNeedsImmediateResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                         PodcastPlayer.shared.userWantsToPlay && 
                                         !PodcastPlayer.shared.wasManuallyPaused && 
                                         !PodcastPlayer.shared.isPlaying
        
        let shouldAttemptResume = radioNeedsImmediateResume || podcastNeedsImmediateResume
        
        if !shouldAttemptResume {
            return
        }
        
        print("⚡ PlaybackManager: Attempting immediate resume after audio session change")
        
        // PHONE CALL FIX: Prevent concurrent audio session activations
        if isActivatingAudioSession {
            print("⚡ PlaybackManager: Audio session activation in progress, skipping immediate resume")
            return
        }
        
        isActivatingAudioSession = true
        defer { isActivatingAudioSession = false }
        
        let audioSession = AVAudioSession.sharedInstance()
        let otherAudioPlaying = audioSession.isOtherAudioPlaying
        
        // PHONE CALL FIX: Never attempt immediate resume during phone calls
        let isInPhoneCall = isPhoneCallActive()
        
        if isInPhoneCall {
            print("⚡ PlaybackManager: Phone call detected, skipping immediate resume")
            return
        }
        
        if !otherAudioPlaying {
            // Try immediate session activation
            do {
                try audioSession.setCategory(.playback, mode: .default, options: PlaybackManager.playbackCategoryOptions)
                try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                
                print("⚡ PlaybackManager: Immediate session activation successful - resuming playback")
                
                // PHONE CALL FIX: Add small delay to prevent race conditions with individual players
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Resume whichever player was actually playing
                    if radioNeedsImmediateResume {
                        PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                        RadioPlayer.shared.resumeAfterInterruption()
                        
                        // Stop the background timer since we successfully resumed
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if RadioPlayer.shared.isPlaying {
                                self.stopBackgroundInterruptionTimer()
                            }
                        }
                    } else if podcastNeedsImmediateResume {
                        PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                        PodcastPlayer.shared.resumeAfterInterruption()
                        
                        // Stop the background timer since we successfully resumed
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if PodcastPlayer.shared.isPlaying {
                                self.stopBackgroundInterruptionTimer()
                            }
                        }
                    }
                }
                
            } catch {
                print("⚡ PlaybackManager: Immediate session activation failed: \(error)")
            }
        }
    }
    
    /// System-level audio reset as last resort for Apple Music conflicts
    private func attemptSystemAudioReset() {
        print("🚨 PlaybackManager: Apple Music has created unbreakable system lock - implementing workaround")
        
        // Apple Music creates locks that persist across all session manipulation
        // The only reliable solution is to enable manual resume and stop automatic attempts
        
        print("🚨 PlaybackManager: Stopping automatic resume attempts - enabling manual resume mode")
        
        // Stop the timer to prevent further resource waste
        stopBackgroundInterruptionTimer()
        
        // Set a flag to indicate manual resume is needed
        UserDefaults.standard.set(true, forKey: "AppleMusicConflictActive")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "AppleMusicConflictTimestamp")
        
        // Notify UI to show manual resume option
        DispatchQueue.main.async {
            self.notifyUserOfAppleMusicConflict()
        }
        
        // Schedule a delayed retry in case Apple Music releases the session later
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            self.attemptDelayedResume()
        }
    }
    
    /// Attempts a delayed resume after Apple Music conflict
    private func attemptDelayedResume() {
        print("🔄 PlaybackManager: Attempting delayed resume after Apple Music conflict")
        
        // PHONE CALL FIX: Check for delayed resume for ANY player
        let radioNeedsDelayedResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                     RadioPlayer.shared.userWantsToPlay && 
                                     !RadioPlayer.shared.wasManuallyPaused && 
                                     !RadioPlayer.shared.isPlaying
        let podcastNeedsDelayedResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                       PodcastPlayer.shared.userWantsToPlay && 
                                       !PodcastPlayer.shared.wasManuallyPaused && 
                                       !PodcastPlayer.shared.isPlaying
        
        let shouldAttemptResume = radioNeedsDelayedResume || podcastNeedsDelayedResume
        
        if !shouldAttemptResume {
            print("🔄 PlaybackManager: No longer need delayed resume")
            UserDefaults.standard.removeObject(forKey: "AppleMusicConflictActive")
            return
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        
        // Try a single gentle activation attempt
        do {
            try audioSession.setCategory(.playback, mode: .default, options: PlaybackManager.playbackCategoryOptions)
            try audioSession.setActive(true, options: [])
            
            print("✅ PlaybackManager: Delayed resume successful - Apple Music released session")
            
            // Clear conflict flag
            UserDefaults.standard.removeObject(forKey: "AppleMusicConflictActive")
            
            // PHONE CALL FIX: Attempt resume for whichever player was actually playing
            if radioNeedsDelayedResume {
                PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                RadioPlayer.shared.resumeAfterInterruption()
                
                // Reset interruption state after delayed resume
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.resetInterruptionState()
                }
            } else if podcastNeedsDelayedResume {
                PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                PodcastPlayer.shared.resumeAfterInterruption()
                
                // Reset interruption state after delayed resume
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.resetInterruptionState()
                }
            }
            
            // Notify UI that automatic resume worked
            NotificationCenter.default.post(
                name: NSNotification.Name("AppleMusicConflictResolved"),
                object: nil
            )
            
        } catch {
            print("🔄 PlaybackManager: Delayed resume failed - Apple Music still holding session: \(error)")
            // Keep the manual resume option available
        }
    }
    
    /// Notifies user when Apple Music conflicts cannot be resolved automatically
    private func notifyUserOfAppleMusicConflict() {
        print("🚨 PlaybackManager: Notifying user of unresolvable Apple Music conflict")
        
        // Post notification that UI can observe
        NotificationCenter.default.post(
            name: NSNotification.Name("AppleMusicConflictDetected"),
            object: nil,
            userInfo: [
                "message": "Apple Music is preventing automatic resume. Tap the play button to restart playback.",
                "activePlayer": String(describing: activePlayer),
                "showManualResumeButton": true
            ]
        )
    }
    
    /// PHONE CALL FIX: Enhanced phone call detection to prevent audio mixing
    private func isPhoneCallActive() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Method 1: Check audio session category - phone calls force specific categories
        let currentCategory = audioSession.category
        let phoneCallCategories: [AVAudioSession.Category] = [.playAndRecord, .record]
        
        // Method 2: Check audio route for phone call characteristics
        let currentRoute = audioSession.currentRoute
        
        // Check for phone call input types
        let hasPhoneCallInputs = currentRoute.inputs.contains { input in
            input.portType == .builtInMic || 
            input.portType == .bluetoothHFP ||
            input.portType == .headsetMic
        }
        
        // Check for phone call output types
        let hasPhoneCallOutputs = currentRoute.outputs.contains { output in
            output.portType == .builtInReceiver || 
            output.portType == .bluetoothHFP ||
            (output.portType == .builtInSpeaker && currentCategory == .playAndRecord)
        }
        
        // Method 3: Check if secondary audio should be silenced (strong indicator of phone call)
        let secondaryAudioShouldBeSilenced = audioSession.secondaryAudioShouldBeSilencedHint
        
        let categoryIndicatesCall = phoneCallCategories.contains(currentCategory)
        let routeIndicatesCall = hasPhoneCallInputs && hasPhoneCallOutputs
        
        let isPhoneCall = categoryIndicatesCall || routeIndicatesCall || secondaryAudioShouldBeSilenced
        
        if isPhoneCall {
            print("📞 PlaybackManager: Phone call detected - category: \(currentCategory), route: inputs=\(currentRoute.inputs.map(\.portType)), outputs=\(currentRoute.outputs.map(\.portType)), silenceHint: \(secondaryAudioShouldBeSilenced)")
        }
        
        return isPhoneCall
    }
    
    /// PHONE CALL FIX: Reset interruption state after phone call handling is complete
    private func resetInterruptionState() {
        print("🔄 PlaybackManager: Resetting interruption state for next phone call")
        radioWasPlayingBeforeInterruption = false
        podcastWasPlayingBeforeInterruption = false
    }
    
    /// GPS FIX: Check if network conditions are good enough to run aggressive background timer
    private func isNetworkConditionGoodForTimer() -> Bool {
        // Check if there have been recent network failures that suggest poor connectivity
        let recentNetworkFailures = UserDefaults.standard.integer(forKey: "RecentNetworkFailures")
        let lastFailureTime = UserDefaults.standard.double(forKey: "LastNetworkFailureTime")
        let timeSinceLastFailure = Date().timeIntervalSince1970 - lastFailureTime
        
        // If there have been multiple recent failures, avoid aggressive timer
        if recentNetworkFailures > 3 && timeSinceLastFailure < 60 {
            print("🛰️ PlaybackManager: Recent network failures detected - avoiding timer to protect GPS")
            return false
        }
        
        // Check if we're currently in airplane mode or have no network
        // This is a simple check that doesn't require additional frameworks
        let networkFlags = UserDefaults.standard.bool(forKey: "NetworkUnavailable")
        if networkFlags {
            print("🛰️ PlaybackManager: Network unavailable - timer would cause GPS interference")
            return false
        }
        
        return true
    }
    
    /// GPS FIX: Attempt a single gentle resume without aggressive timer
    private func attemptSingleGentleResume() {
        print("🛰️ PlaybackManager: Attempting single gentle resume to protect GPS")
        
        let audioSession = AVAudioSession.sharedInstance()
        
        // Single gentle attempt without retries
        do {
            try audioSession.setCategory(.playback, mode: .default, options: PlaybackManager.playbackCategoryOptions)
            try audioSession.setActive(true, options: [])
            
            print("🛰️ PlaybackManager: Single gentle resume - audio session activated")
            
            // Determine which player needs resume
            let radioNeedsResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) && 
                                  RadioPlayer.shared.userWantsToPlay && 
                                  !RadioPlayer.shared.wasManuallyPaused
            let podcastNeedsResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) && 
                                    PodcastPlayer.shared.userWantsToPlay && 
                                    !PodcastPlayer.shared.wasManuallyPaused
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if radioNeedsResume {
                    print("🛰️ PlaybackManager: Single gentle resume - attempting radio playback")
                    PlaybackManager.shared.setActivePlayer(.radio, shouldActivateSession: true)
                    RadioPlayer.shared.resumeAfterInterruption()
                } else if podcastNeedsResume {
                    print("🛰️ PlaybackManager: Single gentle resume - attempting podcast playback")
                    PlaybackManager.shared.setActivePlayer(.podcast, shouldActivateSession: true)
                    PodcastPlayer.shared.resumeAfterInterruption()
                }
                
                // Reset interruption state after single attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.resetInterruptionState()
                }
            }
            
        } catch {
            print("🛰️ PlaybackManager: Single gentle resume failed: \(error) - manual resume required")
            UserDefaults.standard.set(true, forKey: "NetworkInterruptionActive")
        }
    }
    
    /// CarPlay-specific audio session activation with careful handover detection
    private func attemptCarPlayAudioSessionActivation(for player: ActivePlayer, attempt: Int) {
        let maxAttempts = 5
        
        guard attempt <= maxAttempts else {
            print("🚗 PlaybackManager: Max CarPlay audio session attempts reached (\(maxAttempts))")
            return
        }
        
        print("🚗 PlaybackManager: CarPlay audio session attempt \(attempt)/\(maxAttempts)")
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Test if we can configure the audio session
            try audioSession.setCategory(.playback, 
                                       mode: .default, 
                                       options: PlaybackManager.playbackCategoryOptions)
            
            print("🚗 PlaybackManager: CarPlay audio session category configured successfully")
            
            // Now try to activate
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            print("✅ PlaybackManager: CarPlay audio session activated successfully for \(player)")
            
            // Reset retry count and update state
            audioSessionRetryCount = 0
            isActivatingAudioSession = false
            lastAudioSessionActivation = (player, Date())
            
        } catch {
            print("🚗 PlaybackManager: CarPlay audio session attempt \(attempt) failed: \(error)")
            
            // Calculate progressive delay: 0.3s, 0.6s, 1.0s, 1.5s, 2.0s
            let delay = 0.3 + (0.3 * Double(attempt - 1))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.attemptCarPlayAudioSessionActivation(for: player, attempt: attempt + 1)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        backgroundInterruptionTimer?.invalidate()
    }
}
