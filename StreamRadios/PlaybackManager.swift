//
//  PlaybackManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 9/10/24.
//

import SwiftUI
import AVFoundation
import MediaPlayer

enum ActivePlayer {
    case radio
    case podcast
}

class PlaybackManager: ObservableObject {
    static let shared = PlaybackManager()
    
    @Published var activePlayer: ActivePlayer = .radio
    private var audioSessionConfigured = false
    
    // State tracking for logging optimization
    private var lastLoggedActivePlayer: ActivePlayer?
    private var lastAudioSessionActivation: (ActivePlayer, Date)?
    
    private init() {
        setupCentralizedAudioSession()
        setupAudioInterruptionHandling()
    }
    
    func setActivePlayer(_ player: ActivePlayer) {
        activePlayer = player
        
        // Only log if the active player actually changed
        if lastLoggedActivePlayer != player {
            print("🎵 PlaybackManager: Active player set to \(player)")
            lastLoggedActivePlayer = player
        }
        
        // Ensure audio session is properly configured for the active player
        activateAudioSessionForPlayer(player)
    }
    
    private func setupCentralizedAudioSession() {
        // CRITICAL FIX: Move audio session configuration to background queue to prevent main thread blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let audioSession = AVAudioSession.sharedInstance()
                
                // Check if audio session is already configured by another component
                if audioSession.category != .ambient {
                    print("⚠️ PlaybackManager: Audio session already configured with category: \(audioSession.category.rawValue)")
                    DispatchQueue.main.async {
                        self.audioSessionConfigured = true
                    }
                    return
                }
                
                // Use optimized audio session configuration for background stability
                // This configuration is essential for preventing app termination during lock screen playback
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP, .mixWithOthers])
                
                // Set preferred buffer duration for better background performance
                try audioSession.setPreferredIOBufferDuration(0.1) // 100ms buffer for stability
                
                print("✅ PlaybackManager: Centralized audio session configured for background stability")
                DispatchQueue.main.async {
                    self.audioSessionConfigured = true
                }
                
            } catch {
                print("❌ PlaybackManager: Failed to configure centralized audio session: \(error)")
                DebugLogger.logError("CRITICAL: Audio session configuration failed - this may cause background termination: \(error.localizedDescription)", category: "AudioSession")
                DebugLogger.setUserAction("Audio Session Configuration Failure")
                
                // Log additional context for debugging
                let currentCategory = AVAudioSession.sharedInstance().category
                let currentOptions = AVAudioSession.sharedInstance().categoryOptions
                DebugLogger.logInfo("Audio session failure context - Current category: \(currentCategory.rawValue), Options: \(currentOptions.rawValue)", category: "AudioSession")
                
                // Mark as configured even on error to prevent repeated attempts
                DispatchQueue.main.async {
                    self.audioSessionConfigured = true
                }
            }
        }
    }
    
    func activateAudioSessionForPlayer(_ player: ActivePlayer) {
        guard audioSessionConfigured else {
            setupCentralizedAudioSession()
            return
        }
        
        // Rate limit audio session activation logging - only log once per 3 seconds per player
        let now = Date()
        let shouldLog = lastAudioSessionActivation == nil || 
                       lastAudioSessionActivation!.0 != player || 
                       now.timeIntervalSince(lastAudioSessionActivation!.1) > 3.0
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Ensure the category is correct for our use case
            if audioSession.category != .playback {
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                print("🔄 PlaybackManager: Corrected audio session category to playback")
            }
            
            // Always activate with notifyOthersOnDeactivation to ensure proper handoff
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Only log if enough time has passed or player changed
            if shouldLog {
                print("✅ PlaybackManager: Audio session activated for \(player)")
                lastAudioSessionActivation = (player, now)
            }
            
            // CRITICAL: Only clear Now Playing info when explicitly switching between different players
            // Don't clear during CarPlay transitions or when reactivating the same player
            let currentRoute = audioSession.currentRoute
            let hasCarPlayRoute = currentRoute.outputs.contains { $0.portType == .carAudio }
            
            // Only clear Now Playing if we're not in a CarPlay transition and the player actually changed
            if !hasCarPlayRoute && !CarPlayManager.shared.isCarPlayConnected {
                print("🔄 PlaybackManager: Clearing Now Playing info for player switch")
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            } else {
                print("🚗 PlaybackManager: Preserving Now Playing info during CarPlay transition")
            }
            
        } catch {
            print("❌ PlaybackManager: Failed to activate audio session for \(player): \(error)")
            
            // Retry with a brief delay if the error is related to conflicts
            if let nsError = error as NSError?, nsError.code == -50 {
                print("🔄 PlaybackManager: Retrying audio session activation after conflict...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.activateAudioSessionForPlayer(player)
                }
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
    }
    
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔇 PlaybackManager: Audio interruption began")
            // Let individual players handle their own pause logic
            
        case .ended:
            print("🔊 PlaybackManager: Audio interruption ended")
            
            // CRITICAL: Don't interfere with CarPlay disconnection scenarios
            // Check if this is a CarPlay-related interruption by looking at current route
            let audioSession = AVAudioSession.sharedInstance()
            let currentRoute = audioSession.currentRoute
            let hasCarPlayRoute = currentRoute.outputs.contains { $0.portType == .carAudio }
            
            // If CarPlay is not in the route but we had it before, this might be a disconnection
            if !hasCarPlayRoute && CarPlayManager.shared.isCarPlayConnected {
                print("🚗 PlaybackManager: Detected potential CarPlay disconnection - letting players handle audio session")
                // Don't reactivate audio session here, let individual players handle it
                return
            }
            
            // For non-CarPlay interruptions, reactivate normally but don't clear Now Playing
            reactivateAudioSessionWithoutClearing()
            
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🔊 PlaybackManager: Should resume playback after interruption")
                    // Let individual players handle their own resume logic
                }
            }
            
        @unknown default:
            break
        }
    }
    
    private func reactivateAudioSessionWithoutClearing() {
        guard audioSessionConfigured else {
            setupCentralizedAudioSession()
            return
        }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Ensure the category is correct for our use case
            if audioSession.category != .playback {
                try audioSession.setCategory(.playback, 
                                           mode: .default, 
                                           options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                print("🔄 PlaybackManager: Corrected audio session category to playback")
            }
            
            // Reactivate without clearing Now Playing info during CarPlay transitions
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ PlaybackManager: Audio session reactivated without clearing Now Playing")
            
        } catch {
            print("❌ PlaybackManager: Failed to reactivate audio session: \(error)")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
