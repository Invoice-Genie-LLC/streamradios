//
//  EpisodeStateManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 11/11/24.
//

// EpisodeStateManager.swift

import Foundation
import Combine
import SwiftUI

enum EpisodePlaybackState: String, Codable, Equatable {
    case new
    case playing
    case inProgress
    case played
    
    var statusText: String {
        switch self {
        case .new: return "New"
        case .playing: return "Playing"
        case .inProgress: return "In Progress"
        case .played: return "Played"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .new: return .blue // New episodes in blue
        case .playing: return .blue
        case .inProgress: return .orange // In Progress episodes in orange
        case .played: return .gray
        }
    }
    
    var buttonImage: String {
        switch self {
        case .new:
            return "play.circle.fill"
        case .playing:
            return "pause.fill"
        case .inProgress:
            return "play.circle.fill"
        case .played:
            return "arrow.counterclockwise.circle.fill" // Rewind icon for played episodes
        }
    }
    
    var buttonColor: Color {
        switch self {
        case .new:
            return .blue
        case .playing:
            return .blue
        case .inProgress:
            return .orange // Orange color for in progress
        case .played:
            return .gray // Gray color for played episodes
        }
    }
}

struct EpisodeProgress: Codable {
    var state: EpisodePlaybackState
    var progress: Double
    var currentTime: Double?
    var duration: Double?
    
    // Initialize with legacy support
    init(state: EpisodePlaybackState, progress: Double, currentTime: Double? = nil, duration: Double? = nil) {
        self.state = state
        self.progress = progress
        self.currentTime = currentTime
        self.duration = duration
    }
}

class EpisodeStateManager: ObservableObject {
    static let shared = EpisodeStateManager()
    
    @Published private(set) var episodeStates: [String: EpisodePlaybackState] = [:]
    @Published private(set) var currentlyPlayingEpisodeId: String?
    private var episodeProgress: [String: Double] = [:]
    private var episodeCurrentTime: [String: Double] = [:]
    
    // Use shared app group UserDefaults instead of standard UserDefaults
    private let userDefaults = UserDefaults(suiteName: "group.streamradios") ?? UserDefaults.standard
    private let statesKey = "EpisodeStates"
    private let progressKey = "EpisodeProgress"
    private let currentTimeKey = "EpisodeCurrentTime"
    
    // Throttling for UI updates to prevent CPU spikes
    private var lastUpdateTime = Date()
    private let updateThrottleInterval: TimeInterval = 3.0 // 3 seconds between updates
    
    private init() {
        loadSavedStates()
        setupAppTerminationObserver()
    }
    
    private func setupAppTerminationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveStateOnTermination),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    @objc private func saveStateOnTermination() {
        saveCurrentStates()
    }
    
    private func loadSavedStates() {
        if let savedData = userDefaults.data(forKey: statesKey),
           let savedProgress = userDefaults.data(forKey: progressKey) {
            do {
                var states = try JSONDecoder().decode([String: EpisodePlaybackState].self, from: savedData)
                let progress = try JSONDecoder().decode([String: Double].self, from: savedProgress)
                
                // Load current times if available
                var currentTimes: [String: Double] = [:]
                if let savedCurrentTimes = userDefaults.data(forKey: currentTimeKey) {
                    currentTimes = try JSONDecoder().decode([String: Double].self, from: savedCurrentTimes)
                }
                
                // Convert any playing state to in progress on app launch
                for (episodeId, state) in states {
                    if state == .playing {
                        if let episodeProgress = progress[episodeId] {
                            if episodeProgress >= 0.99 {
                                states[episodeId] = .played
                            } else if episodeProgress > 0 {
                                states[episodeId] = .inProgress
                            } else {
                                states[episodeId] = .new
                            }
                        } else {
                            states[episodeId] = .new
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.episodeStates = states
                    self.episodeProgress = progress
                    self.episodeCurrentTime = currentTimes
                    self.currentlyPlayingEpisodeId = nil // Clear any playing episode
                    self.sendThrottledUpdate()
                }
            } catch {
                print("Error loading saved states: \(error)")
            }
        }
    }
    
    private func saveCurrentStates() {
        do {
            let statesData = try JSONEncoder().encode(episodeStates)
            let progressData = try JSONEncoder().encode(episodeProgress)
            let currentTimeData = try JSONEncoder().encode(episodeCurrentTime)
            
            userDefaults.set(statesData, forKey: statesKey)
            userDefaults.set(progressData, forKey: progressKey)
            userDefaults.set(currentTimeData, forKey: currentTimeKey)
        } catch {
            print("Error saving states: \(error)")
        }
    }
    
    // Throttled update method to prevent excessive UI updates
    private func sendThrottledUpdate() {
        let now = Date()
        
        // Skip update if user is scrolling or if we updated too recently
        if UserDefaults.standard.bool(forKey: "isUserScrolling") {
            return
        }
        
        if now.timeIntervalSince(lastUpdateTime) < updateThrottleInterval {
            return
        }
        
        lastUpdateTime = now
        objectWillChange.send()
    }
    
    func getState(for episodeId: String) -> EpisodePlaybackState {
        return episodeStates[episodeId] ?? .new
    }
    
    func getProgress(for episodeId: String) -> Double {
        let progress = episodeProgress[episodeId] ?? 0.0
        print("🔍 EpisodeStateManager: Getting progress \(progress) for episode \(episodeId)")
        return progress
    }
    
    func getCurrentTime(for episodeId: String) -> Double {
        let currentTime = episodeCurrentTime[episodeId] ?? 0.0
        print("🔍 EpisodeStateManager: Getting currentTime \(currentTime)s for episode \(episodeId)")
        return currentTime
    }
    
    func startPlaying(episodeId: String) {
        // If there's a currently playing episode, mark it as "In Progress" before switching
        if let currentPlayingId = currentlyPlayingEpisodeId, currentPlayingId != episodeId {
            let currentProgress = episodeProgress[currentPlayingId] ?? 0.0
            if currentProgress > 0 {
                let currentState = episodeStates[currentPlayingId] ?? .new
                if currentState != .played {
                    // Only update to inProgress if it wasn't already marked as played
                    if currentProgress >= 0.99 {
                        episodeStates[currentPlayingId] = .played
                    } else {
                        episodeStates[currentPlayingId] = .inProgress
                    }
                }
            }
        }
        
        episodeStates[episodeId] = .playing
        currentlyPlayingEpisodeId = episodeId
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func pausePlayback(episodeId: String, progress: Double) {
        episodeProgress[episodeId] = progress
        
        if progress >= 0.99 {
            episodeStates[episodeId] = .played
        } else if progress > 0 {
            episodeStates[episodeId] = .inProgress
        }
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func switchToEpisode(newEpisodeId: String, previousEpisodeId: String, previousProgress: Double) {
        // Mark previous episode as "In Progress" only if it wasn't already marked as "Played"
        if previousProgress > 0 {
            let currentState = episodeStates[previousEpisodeId] ?? .new
            if currentState != .played {
                // Only update to inProgress if it wasn't already marked as played
                if previousProgress >= 0.99 {
                    episodeStates[previousEpisodeId] = .played
                } else {
                    episodeStates[previousEpisodeId] = .inProgress
                }
            }
            episodeProgress[previousEpisodeId] = previousProgress
        }
        
        // Start playing new episode
        episodeStates[newEpisodeId] = .playing
        currentlyPlayingEpisodeId = newEpisodeId
        
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func completeEpisode(episodeId: String) {
        episodeStates[episodeId] = .played
        episodeProgress[episodeId] = 1.0
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func rewindAndPlay(episodeId: String) {
        // Stop any currently playing episode first
        if let currentPlayingId = currentlyPlayingEpisodeId, currentPlayingId != episodeId {
            let currentProgress = episodeProgress[currentPlayingId] ?? 0.0
            if currentProgress > 0 {
                let currentState = episodeStates[currentPlayingId] ?? .new
                if currentState != .played {
                    // Only update to inProgress if it wasn't already marked as played
                    if currentProgress >= 0.99 {
                        episodeStates[currentPlayingId] = .played
                    } else {
                        episodeStates[currentPlayingId] = .inProgress
                    }
                }
            }
        }
        
        // Reset the episode to beginning and start playing
        episodeStates[episodeId] = .playing
        episodeProgress[episodeId] = 0.0
        currentlyPlayingEpisodeId = episodeId
        
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func updateProgress(for episodeId: String, progress: Double, isPlaying: Bool, currentTime: Double? = nil) {
        let newState: EpisodePlaybackState
        
        // Prevent overwriting existing progress with 0.0 unless it's a genuine reset
        let existingProgress = episodeProgress[episodeId] ?? 0.0
        let existingState = episodeStates[episodeId] ?? .new
        let shouldUpdateProgress: Bool
        
        if progress > 0 {
            // Always update when we have positive progress
            shouldUpdateProgress = true
            episodeProgress[episodeId] = progress
        } else if existingProgress == 0.0 {
            // Update to 0.0 only if there's no existing progress
            shouldUpdateProgress = true
            episodeProgress[episodeId] = progress
        } else if currentTime != nil {
            // Update if we have explicit currentTime (from episode switch)
            shouldUpdateProgress = true
            episodeProgress[episodeId] = progress
        } else if !isPlaying && existingState == .inProgress && progress == 0.0 {
            // CRITICAL: Don't overwrite in-progress episodes with 0.0 during loading
            shouldUpdateProgress = false
            print("🔍 EpisodeStateManager: Protecting in-progress episode \(episodeId) from 0.0 reset (existing: \(existingProgress))")
        } else {
            // Don't overwrite existing progress with 0.0
            shouldUpdateProgress = false
            print("🔍 EpisodeStateManager: Skipping 0.0 progress update for episode \(episodeId) (existing: \(existingProgress))")
        }
        
        // Store current time if provided
        if let currentTime = currentTime {
            episodeCurrentTime[episodeId] = currentTime
            print("🔍 EpisodeStateManager: Storing currentTime \(currentTime)s for episode \(episodeId)")
        }
        
        if shouldUpdateProgress && progress > 0 {
            print("🔍 EpisodeStateManager: Updating progress \(String(format: "%.3f", progress)) for episode \(episodeId)")
        }
        
        // Use the actual progress value for state determination
        let effectiveProgress = shouldUpdateProgress ? progress : existingProgress
        
        if isPlaying {
            newState = .playing
            currentlyPlayingEpisodeId = episodeId
        } else if effectiveProgress >= 0.99 {
            newState = .played
            currentlyPlayingEpisodeId = nil
        } else if effectiveProgress > 0 {
            newState = .inProgress
            currentlyPlayingEpisodeId = nil
        } else if existingState == .inProgress && !shouldUpdateProgress {
            // CRITICAL: Preserve in-progress state when protecting from 0.0 updates
            newState = .inProgress
        } else {
            newState = .new
        }
        
        if episodeStates[episodeId] != newState || shouldUpdateProgress || currentTime != nil {
            let oldState = episodeStates[episodeId] ?? .new
            episodeStates[episodeId] = newState
            
            if oldState != newState {
                print("🔄 EpisodeStateManager: State changed for \(episodeId): \(oldState) -> \(newState) (progress: \(String(format: "%.4f", effectiveProgress)))")
            }
            
            saveCurrentStates()
            sendThrottledUpdate()
        }
    }
    
    func setProgress(for episodeId: String, progress: Double) {
        episodeProgress[episodeId] = progress
        
        // Update state based on progress
        let newState: EpisodePlaybackState
        if progress >= 0.99 {
            newState = .played
        } else if progress > 0 {
            newState = .inProgress
        } else {
            newState = .new
        }
        
        episodeStates[episodeId] = newState
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    /// Force save current states immediately (for critical saves)
    func forceSave() {
        saveCurrentStates()
        userDefaults.synchronize()
    }
    
    func isDownloaded(_ episodeId: String) -> Bool {
        // For now, return false as download functionality isn't implemented
        // This can be extended later when download feature is added
        return false
    }
    
    func setFavorite(_ episodeId: String, isFavorite: Bool) {
        // For now, just log the action as favorite functionality isn't fully implemented
        // This can be extended later when favorite feature is added
        print("🔍 EpisodeStateManager: Setting favorite for \(episodeId): \(isFavorite)")
    }
    
    func setDownloaded(_ episodeId: String, isDownloaded: Bool) {
        // For now, just log the action as download functionality isn't implemented
        // This can be extended later when download feature is added
        print("🔍 EpisodeStateManager: Setting downloaded for \(episodeId): \(isDownloaded)")
    }
    
    func clearAllStates() {
        episodeStates.removeAll()
        episodeProgress.removeAll()
        currentlyPlayingEpisodeId = nil
        
        userDefaults.removeObject(forKey: statesKey)
        userDefaults.removeObject(forKey: progressKey)
        
        sendThrottledUpdate()
    }
    
}
