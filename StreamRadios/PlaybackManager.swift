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
    
    /// The playback category already supports AirPlay and Bluetooth A2DP output routes.
    /// Supplying those play-and-record-oriented options causes OSStatus -50 on some devices.
    static let playbackCategoryOptions: AVAudioSession.CategoryOptions = []
    
    @Published var activePlayer: ActivePlayer = .none
    private var backgroundInterruptionTimer: Timer?
    // State tracking for logging optimization
    private var lastLoggedActivePlayer: ActivePlayer?
    private var lastAudioSessionActivation: (ActivePlayer, Date)?
    
    // PHONE CALL FIX: Prevent concurrent audio session activations causing OSStatus -50
    private var isActivatingAudioSession = false
    private var pendingAudioSessionActivations: [(player: ActivePlayer, completion: ((Bool) -> Void)?)] = []
    private var audioSessionRetryCount = 0
    private let maxAudioSessionRetries = 3
    private let audioSessionQueue = DispatchQueue(label: "com.streamradios.audioSession", qos: .userInitiated)
    
    // Interruption state tracking
    // PHONE CALL FIX: Made internal so individual players can coordinate state
    internal var radioWasPlayingBeforeInterruption = false
    internal var podcastWasPlayingBeforeInterruption = false

    /// True between an interruption's `.began` and its `.ended`. While it is set another app
    /// (Camera video recording, a call, an alarm) owns the audio session, so no timer, route
    /// change or reconnect path may reactivate the session and restart playback.
    private(set) var isInterruptionActive = false
    
    private init() {
        setupAudioInterruptionHandling()
    }
    
    func setActivePlayer(
        _ player: ActivePlayer,
        shouldActivateSession: Bool = false,
        activationCompletion: ((Bool) -> Void)? = nil
    ) {
        let previousPlayer = activePlayer
        activePlayer = player
        
        // Save the last active player to UserDefaults for app restart restoration
        UserDefaults.standard.set(player.rawValue, forKey: "LastActivePlayer")
        
        // FIRST-TIME PLAYBACK TRACKING: Mark that content has been played for TabView hiding behavior
        if player != .none && !hasEverPlayedContent() {
            markContentAsPlayed()
        }
        
        lastLoggedActivePlayer = player
        
        // Only activate audio session if requested (i.e., when actually starting playback)
        // Don't activate during startup restoration to avoid conflicts
        if shouldActivateSession {
            activateAudioSessionForPlayer(player, completion: activationCompletion)
        } else {
            activationCompletion?(true)
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
        print("🎵 PlaybackManager: Marked content as played - TabView hiding on scroll now enabled")
    }
    
    func activateAudioSessionForPlayer(_ player: ActivePlayer, completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.activateAudioSessionForPlayer(player, completion: completion)
            }
            return
        }

        // CarPlay route changes can overlap a station tap. Dropping the second request leaves the
        // UI in a playing state without ever starting its AVPlayer, so complete it after the shared
        // playback session finishes activating instead.
        guard !isActivatingAudioSession else {
            let superseded = pendingAudioSessionActivations.filter { $0.player == player }
            pendingAudioSessionActivations.removeAll { $0.player == player }
            superseded.forEach { $0.completion?(false) }
            pendingAudioSessionActivations.append((player, completion))
            print("🔒 PlaybackManager: Audio session activation already in progress, queued request for \(player)")
            return
        }
        
        isActivatingAudioSession = true

        // Rate limit audio session activation logging - only log once per 3 seconds per player
        let now = Date()
        let shouldLog = lastAudioSessionActivation == nil || 
                       lastAudioSessionActivation!.0 != player || 
                       now.timeIntervalSince(lastAudioSessionActivation!.1) > 3.0

        let activationDelay = CarPlayManager.shared.isCarPlayConnected ? 0.2 : 0
        audioSessionQueue.asyncAfter(deadline: .now() + activationDelay) { [weak self] in
            guard let self else { return }

            let audioSession = AVAudioSession.sharedInstance()
            do {
                let desiredOptions = PlaybackManager.playbackCategoryOptions
                if audioSession.category != .playback || audioSession.categoryOptions != desiredOptions {
                    try audioSession.setCategory(.playback, mode: .default, options: desiredOptions)
                    do {
                        try audioSession.setPreferredIOBufferDuration(0.1)
                    } catch {
                        print("⚠️ PlaybackManager: Preferred buffer duration unavailable; continuing activation: \(error)")
                    }
                }

                try audioSession.setActive(true, options: [])
                let hasCarPlayRoute = audioSession.currentRoute.outputs.contains { $0.portType == .carAudio }

                DispatchQueue.main.async {
                    self.audioSessionRetryCount = 0
                    self.isActivatingAudioSession = false

                    if shouldLog {
                        print("✅ PlaybackManager: Audio session activated for \(player)")
                        self.lastAudioSessionActivation = (player, now)
                    }

                    let isInterruptionResume = self.radioWasPlayingBeforeInterruption || self.podcastWasPlayingBeforeInterruption ||
                        RadioPlayer.shared.wasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption

                    if !hasCarPlayRoute && !CarPlayManager.shared.isCarPlayConnected && !isInterruptionResume {
                        print("🔄 PlaybackManager: Clearing Now Playing info for player switch")
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                    } else if isInterruptionResume {
                        print("🎵 PlaybackManager: Preserving Now Playing info during interruption resume")
                    } else {
                        print("🚗 PlaybackManager: Preserving Now Playing info during CarPlay transition")
                    }

                    let hasNewerRequest = self.pendingAudioSessionActivations.contains { $0.player == player }
                    completion?(self.activePlayer == player && !hasNewerRequest)
                    self.completePendingAudioSessionActivations(success: true)
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ PlaybackManager: Failed to activate audio session for \(player): \(error)")

                    let nsError = error as NSError
                    if nsError.code == -50 {
                        self.audioSessionRetryCount += 1
                        if self.audioSessionRetryCount <= self.maxAudioSessionRetries {
                            print("🔄 PlaybackManager: Retrying audio session activation after conflict... (attempt \(self.audioSessionRetryCount)/\(self.maxAudioSessionRetries))")
                            let baseDelay = CarPlayManager.shared.isCarPlayConnected ? 1.0 : 0.5
                            let retryDelay = baseDelay * Double(self.audioSessionRetryCount)
                            self.isActivatingAudioSession = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                                self.activateAudioSessionForPlayer(player, completion: completion)
                            }
                        } else {
                            print("❌ PlaybackManager: Max audio session retry attempts reached (\(self.maxAudioSessionRetries)). Stopping retries to prevent infinite loop.")
                            self.audioSessionRetryCount = 0
                            self.isActivatingAudioSession = false
                            completion?(false)
                            self.completePendingAudioSessionActivations(success: false)
                        }
                    } else {
                        self.audioSessionRetryCount = 0
                        self.isActivatingAudioSession = false
                        completion?(false)
                        self.completePendingAudioSessionActivations(success: false)
                    }
                }
            }
        }
    }

    private func completePendingAudioSessionActivations(success: Bool) {
        let pending = pendingAudioSessionActivations
        pendingAudioSessionActivations.removeAll()

        for request in pending {
            request.completion?(success && request.player == activePlayer)
        }
    }
    
    func deactivateAudioSession() {
        audioSessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                print("✅ PlaybackManager: Audio session deactivated")

                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                }
            } catch {
                print("❌ PlaybackManager: Failed to deactivate audio session: \(error)")
            }
        }
    }

    private func resumeAfterInterruption(
        _ player: ActivePlayer,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isInterruptionActive else {
            print("🔇 PlaybackManager: Interruption still active - not resuming \(player)")
            completion?(false)
            return
        }

        setActivePlayer(player, shouldActivateSession: true) { activated in
            guard activated else {
                completion?(false)
                return
            }

            if player == .radio {
                RadioPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
            } else if player == .podcast {
                PodcastPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
            }
            completion?(true)
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

            // An interruption reported only because iOS suspended the app has no matching
            // `.ended`, so it must not latch the "another app owns the session" state.
            let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt
            let wasSuspendedBySystem = reasonValue.flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) == .appWasSuspended
            if !wasSuspendedBySystem {
                isInterruptionActive = true
                // Any resume polling left over from an earlier interruption must not fire now.
                stopBackgroundInterruptionTimer()
            }
            
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
                audioSessionQueue.async {
                    do {
                        try AVAudioSession.sharedInstance().setActive(false, options: [])
                        print("✅ PlaybackManager: Audio session deactivated for interruption")
                    } catch {
                        print("⚠️ PlaybackManager: Could not deactivate audio session: \(error)")
                    }
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
            
            // Do NOT start the resume timer here. The interruption has only just begun: the
            // interrupting app (e.g. Camera recording video) plays no audio, so the timer's
            // `isOtherAudioPlaying` check passed and playback restarted over the recording.
            // Resume is decided when the system reports `.ended`.
            
        case .ended:
            print("🔊 PlaybackManager: Audio interruption ended, background: \(isInBackground)")
            
            // PHONE CALL FIX: For phone calls, iOS doesn't always provide shouldResume correctly
            // We need to be more intelligent about when to resume
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            print("📞 PlaybackManager: Interruption end - shouldResume: \(shouldResume)")
            isInterruptionActive = false

            // The interruption is over. Resume when the system says so, and also when it omits
            // `.shouldResume` (Camera does after a video recording, and so do some phone calls)
            // as long as nothing else is using audio. Otherwise stay paused until the user
            // presses play.
            let sessionIsFree = !AVAudioSession.sharedInstance().isOtherAudioPlaying && !isPhoneCallActive()
            guard shouldResume || sessionIsFree else {
                print("🔇 PlaybackManager: Interruption ended without shouldResume and audio session is busy - staying paused")
                stopBackgroundInterruptionTimer()
                resetInterruptionState()
                return
            }
            
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
            } else if shouldAttemptRadioResume || shouldAttemptPodcastResume {
                print("🌅 PlaybackManager: Foreground interruption end - attempting resume")
                
                // Resume with delay to ensure audio session is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // PHONE CALL FIX: Resume whichever player was actually playing, regardless of activePlayer
                    if shouldAttemptRadioResume {
                        print("✅ PlaybackManager: Resuming radio playback after phone call")
                        self.resumeAfterInterruption(.radio) { activated in
                            guard activated else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.resetInterruptionState()
                            }
                        }
                    } else if shouldAttemptPodcastResume {
                        print("✅ PlaybackManager: Resuming podcast playback after phone call")
                        self.resumeAfterInterruption(.podcast) { activated in
                            guard activated else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.resetInterruptionState()
                            }
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
            
            // Resume playback with longer delay for background scenarios. The active-player
            // transition owns the single serialized audio-session activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("🔄 PlaybackManager: Background resume attempt for activePlayer: \(self.activePlayer)")
                if radioNeedsBackgroundResume {
                    print("✅ PlaybackManager: Background resuming radio playback after phone call")
                    self.resumeAfterInterruption(.radio) { activated in
                        self.finishBackgroundResumeAttempt(backgroundTaskID, activated: activated)
                    }
                } else if podcastNeedsBackgroundResume {
                    print("✅ PlaybackManager: Background resuming podcast playback after phone call")
                    self.resumeAfterInterruption(.podcast) { activated in
                        self.finishBackgroundResumeAttempt(backgroundTaskID, activated: activated)
                    }
                } else if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    print("✅ PlaybackManager: Background resume task completed")
                }
            }
        }
    }

    private func finishBackgroundResumeAttempt(_ backgroundTaskID: UIBackgroundTaskIdentifier, activated: Bool) {
        if activated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.resetInterruptionState()
            }
        }

        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            print("✅ PlaybackManager: Background resume task completed")
        }
    }
    
    /// Handles app becoming active - check for interrupted playback that needs resume
    @objc private func handleAppDidBecomeActive() {
        // Stop any background timer since we're now in foreground
        stopBackgroundInterruptionTimer()

        // The user is back in the app. iOS does not guarantee an `.ended` for every `.began`,
        // so do not leave resume blocked by an interruption that may never be closed.
        isInterruptionActive = false
        
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
            // Resume with delay to ensure audio session is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if shouldResumeRadio {
                    self.resumeAfterInterruption(.radio)
                } else if shouldResumePodcast {
                    self.resumeAfterInterruption(.podcast)
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

            if self.isInterruptionActive {
                print("⏰ PlaybackManager: Timer - interruption active, stopping timer")
                timer.invalidate()
                self.backgroundInterruptionTimer = nil
                return
            }
            
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
                if self.isActivatingAudioSession {
                    print("⏰ PlaybackManager: Timer - audio session activation in progress, skipping")
                    return
                }

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

                print("⏰ PlaybackManager: Timer - audio session available, attempting resume")
                
                // PHONE CALL FIX: Resume whichever player was actually playing
                if radioStillNeedsResume {
                    print("📻 PlaybackManager: Timer resuming radio playback after phone call")
                    self.resumeAfterInterruption(.radio) { activated in
                        guard activated else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if RadioPlayer.shared.isPlaying {
                                print("✅ PlaybackManager: Timer - radio resume successful, stopping timer")
                                timer.invalidate()
                                self.backgroundInterruptionTimer = nil
                            } else {
                                print("❌ PlaybackManager: Timer - radio resume failed, will retry")
                            }
                        }
                    }
                } else if podcastStillNeedsResume {
                    print("🎧 PlaybackManager: Timer resuming podcast playback after phone call")
                    self.resumeAfterInterruption(.podcast) { activated in
                        guard activated else { return }
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
    }
    
    /// Stops the background interruption timer
    private func stopBackgroundInterruptionTimer() {
        backgroundInterruptionTimer?.invalidate()
        backgroundInterruptionTimer = nil
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
        
        if !shouldAttemptResume || isInterruptionActive {
            return
        }
        
        print("⚡ PlaybackManager: Attempting immediate resume after audio session change")
        
        if isActivatingAudioSession {
            print("⚡ PlaybackManager: Audio session activation in progress, skipping immediate resume")
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        let otherAudioPlaying = audioSession.isOtherAudioPlaying
        
        // PHONE CALL FIX: Never attempt immediate resume during phone calls
        let isInPhoneCall = isPhoneCallActive()
        
        if isInPhoneCall {
            print("⚡ PlaybackManager: Phone call detected, skipping immediate resume")
            return
        }
        
        if !otherAudioPlaying {
            print("⚡ PlaybackManager: Audio session available - resuming through activation coordinator")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if radioNeedsImmediateResume {
                    self.resumeAfterInterruption(.radio) { activated in
                        guard activated else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if RadioPlayer.shared.isPlaying {
                                self.stopBackgroundInterruptionTimer()
                            }
                        }
                    }
                } else if podcastNeedsImmediateResume {
                    self.resumeAfterInterruption(.podcast) { activated in
                        guard activated else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if PodcastPlayer.shared.isPlaying {
                                self.stopBackgroundInterruptionTimer()
                            }
                        }
                    }
                }
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
        
        let shouldAttemptResume = (radioNeedsDelayedResume || podcastNeedsDelayedResume) && !isInterruptionActive
        
        if !shouldAttemptResume {
            print("🔄 PlaybackManager: No longer need delayed resume")
            UserDefaults.standard.removeObject(forKey: "AppleMusicConflictActive")
            return
        }
        
        let player: ActivePlayer = radioNeedsDelayedResume ? .radio : .podcast
        setActivePlayer(player, shouldActivateSession: true) { [weak self] activated in
            guard let self else { return }
            guard activated else {
                print("🔄 PlaybackManager: Delayed resume failed - audio session unavailable")
                return
            }

            print("✅ PlaybackManager: Delayed resume successful - Apple Music released session")
            UserDefaults.standard.removeObject(forKey: "AppleMusicConflictActive")

            if player == .radio {
                RadioPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
            } else {
                PodcastPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.resetInterruptionState()
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("AppleMusicConflictResolved"),
                object: nil
            )
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
        
        let radioNeedsResume = (radioWasPlayingBeforeInterruption || RadioPlayer.shared.wasPlayingBeforeInterruption) &&
                              RadioPlayer.shared.userWantsToPlay &&
                              !RadioPlayer.shared.wasManuallyPaused
        let podcastNeedsResume = (podcastWasPlayingBeforeInterruption || PodcastPlayer.shared.wasPlayingBeforeInterruption) &&
                                PodcastPlayer.shared.userWantsToPlay &&
                                !PodcastPlayer.shared.wasManuallyPaused

        guard !isInterruptionActive, radioNeedsResume || podcastNeedsResume else { return }

        let player: ActivePlayer = radioNeedsResume ? .radio : .podcast
        setActivePlayer(player, shouldActivateSession: true) { [weak self] activated in
            guard let self else { return }
            guard activated else {
                print("🛰️ PlaybackManager: Single gentle resume failed - manual resume required")
                UserDefaults.standard.set(true, forKey: "NetworkInterruptionActive")
                return
            }

            print("🛰️ PlaybackManager: Single gentle resume - audio session activated")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if player == .radio {
                    print("🛰️ PlaybackManager: Single gentle resume - attempting radio playback")
                    RadioPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
                } else {
                    print("🛰️ PlaybackManager: Single gentle resume - attempting podcast playback")
                    PodcastPlayer.shared.resumeAfterInterruption(audioSessionActivated: true)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.resetInterruptionState()
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        backgroundInterruptionTimer?.invalidate()
    }
}
