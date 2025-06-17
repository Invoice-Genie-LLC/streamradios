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

class PlaybackManager {
    static let shared = PlaybackManager()
    
    @Published var activePlayer: ActivePlayer = .radio
    private var audioSessionConfigured = false
    
    private init() {
        setupCentralizedAudioSession()
        setupAudioInterruptionHandling()
    }
    
    func setActivePlayer(_ player: ActivePlayer) {
        activePlayer = player
        print("🎵 PlaybackManager: Active player set to \(player)")
        
        // Ensure audio session is properly configured for the active player
        activateAudioSessionForPlayer(player)
    }
    
    private func setupCentralizedAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Use a unified audio session configuration that works for both radio and podcasts
            // and ensures proper "Playing Now" functionality
            try audioSession.setCategory(.playback, 
                                       mode: .default, 
                                       options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
            
            print("✅ PlaybackManager: Centralized audio session configured")
            audioSessionConfigured = true
            
        } catch {
            print("❌ PlaybackManager: Failed to configure centralized audio session: \(error)")
        }
    }
    
    func activateAudioSessionForPlayer(_ player: ActivePlayer) {
        guard audioSessionConfigured else {
            setupCentralizedAudioSession()
            return
        }
        
        do {
            // Always activate with notifyOthersOnDeactivation to ensure proper handoff
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ PlaybackManager: Audio session activated for \(player)")
            
            // Clear any existing Now Playing info when switching players
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            
        } catch {
            print("❌ PlaybackManager: Failed to activate audio session for \(player): \(error)")
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
            // Reactivate the audio session for the current active player
            activateAudioSessionForPlayer(activePlayer)
            
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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
