//
//  AudioSettingsSheet.swift
//  StreamRadios
//
//  Created by Assistant on 8/15/25.
//

import SwiftUI

struct AudioSettingsSheet: View {
    @ObservedObject var podcastPlayer: PodcastPlayer
    @Environment(\.presentationMode) var presentationMode
    
    // Audio settings - we'll manage these manually for feed-specific functionality
    @AppStorage("customSettingsEnabled") private var customSettingsEnabled: Bool = false
    
    // Local state for current playback speed, slider interaction, and feed-specific toggle
    @State private var playbackSpeed: Double = 1.0
    @State private var tempPlaybackSpeed: Double = 1.0
    @State private var feedSpecificSettingsEnabled: Bool = false
    
    // Speed options matching common podcast player standards
    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    // Drag indicator
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                    
                    Text("Audio Settings")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Playback Speed Section
                        VStack(spacing: 16) {
                            // Speed selector with buttons
                            VStack(spacing: 12) {
                                HStack {
                                    Text("Playback Speed")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                
                                // Speed buttons row
                                HStack(spacing: 8) {
                                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { speed in
                                        Button(action: {
                                            setPlaybackSpeed(speed)
                                        }) {
                                            Text(formatSpeedText(speed))
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(playbackSpeed == speed ? .white : .primary)
                                                .frame(minWidth: 40, minHeight: 36)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(playbackSpeed == speed ? Color.blue : Color.gray.opacity(0.15))
                                                )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                
                                // Fine-tune slider
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("−")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                        
                                        Slider(value: $tempPlaybackSpeed, in: 0.5...3.0, step: 0.05) { editing in
                                            if !editing {
                                                setPlaybackSpeed(tempPlaybackSpeed)
                                            }
                                        }
                                        .onChange(of: tempPlaybackSpeed) { newValue in
                                            playbackSpeed = newValue
                                        }
                                        .tint(.blue)
                                        
                                        Text("+")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Text("Current: \(formatSpeedText(playbackSpeed))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(12)
                        
                        // Settings Scope
                        VStack(spacing: 16) {
                            HStack {
                                Text("Settings Scope")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            
                            // Feed-Specific Settings toggle
                            VStack(spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Feed-Specific Settings")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(feedSpecificSettingsEnabled ? "APPLIES TO CURRENT FEED ONLY" : "APPLIES TO ALL PODCASTS")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Toggle("", isOn: $feedSpecificSettingsEnabled)
                                        .onChange(of: feedSpecificSettingsEnabled) { newValue in
                                            handleFeedSpecificToggleChange(newValue)
                                        }
                                }
                            }
                            
                            if !feedSpecificSettingsEnabled {
                                HStack {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    Text("Playback speed will apply to all podcasts")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.top, 4)
                            } else {
                                HStack {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                    Text("Speed setting is unique to this podcast feed")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100) // Extra padding for bottom safe area
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            loadCurrentPlaybackSpeed()
            tempPlaybackSpeed = playbackSpeed
        }
    }
    
    private func formatSpeedText(_ speed: Double) -> String {
        if speed == 1.0 {
            return "1×"
        } else if speed.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(speed))×"
        } else {
            return String(format: "%.2g×", speed)
        }
    }
    
    private func loadCurrentPlaybackSpeed(loadToggleState: Bool = true) {
        // Load feed-specific toggle state first (only when needed)
        if loadToggleState, let currentFeed = podcastPlayer.currentFeed {
            let feedToggleKey = "feedSpecificSettings_\(currentFeed.id ?? "unknown")"
            feedSpecificSettingsEnabled = UserDefaults.standard.bool(forKey: feedToggleKey)
        }
        
        // Then load the appropriate speed based on toggle state
        if feedSpecificSettingsEnabled, let currentFeed = podcastPlayer.currentFeed {
            // Load feed-specific speed
            let feedSpecificKey = "playbackSpeed_\(currentFeed.id ?? "unknown")"
            let savedSpeed = UserDefaults.standard.double(forKey: feedSpecificKey)
            playbackSpeed = savedSpeed != 0 ? savedSpeed : 1.0
        } else {
            // Load global speed
            let savedSpeed = UserDefaults.standard.double(forKey: "podcastPlaybackSpeed")
            playbackSpeed = savedSpeed != 0 ? savedSpeed : 1.0
        }
    }
    
    private func handleFeedSpecificToggleChange(_ newValue: Bool) {
        // Save the toggle state for this feed
        if let currentFeed = podcastPlayer.currentFeed {
            let feedToggleKey = "feedSpecificSettings_\(currentFeed.id ?? "unknown")"
            UserDefaults.standard.set(newValue, forKey: feedToggleKey)
        }
        
        // Update PodcastPlayer state
        podcastPlayer.feedSpecificSettingsEnabled = newValue
        
        // Load the appropriate speed based on new toggle state
        loadCurrentPlaybackSpeed(loadToggleState: false)
        tempPlaybackSpeed = playbackSpeed
        
        // Apply the current speed setting
        setPlaybackSpeed(playbackSpeed)
        
        UserDefaults.standard.synchronize()
    }
    
    private func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        tempPlaybackSpeed = speed
        
        // Save to appropriate storage location
        if feedSpecificSettingsEnabled, let currentFeed = podcastPlayer.currentFeed {
            let feedSpecificKey = "playbackSpeed_\(currentFeed.id ?? "unknown")"
            UserDefaults.standard.set(speed, forKey: feedSpecificKey)
            // For feed-specific, apply immediately to current player
            podcastPlayer.player?.rate = Float(speed)
            podcastPlayer.playbackSpeed = speed
        } else {
            UserDefaults.standard.set(speed, forKey: "podcastPlaybackSpeed")
            // For global, use the PodcastPlayer's method which handles global state
            podcastPlayer.setPlaybackSpeed(speed)
        }
        
        UserDefaults.standard.synchronize()
    }
    
    private func applyAudioSettings() {
        // Save feed-specific setting toggle per feed
        if let currentFeed = podcastPlayer.currentFeed {
            let feedToggleKey = "feedSpecificSettings_\(currentFeed.id ?? "unknown")"
            UserDefaults.standard.set(feedSpecificSettingsEnabled, forKey: feedToggleKey)
        }
        
        // Update PodcastPlayer settings
        podcastPlayer.feedSpecificSettingsEnabled = feedSpecificSettingsEnabled
        
        // Apply the speed using our setPlaybackSpeed method which handles the storage logic
        setPlaybackSpeed(playbackSpeed)
    }
}

#Preview {
    AudioSettingsSheet(podcastPlayer: PodcastPlayer.shared)
}
