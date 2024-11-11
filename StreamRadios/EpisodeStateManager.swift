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
        case .new: return .green
        case .playing: return .blue
        case .inProgress: return .orange
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
            return "arrow.counterclockwise.circle.fill"
        }
    }
    
    var buttonColor: Color {
        switch self {
        case .new:
            return .green
        case .playing:
            return .blue
        case .inProgress:
            return .green
        case .played:
            return .blue
        }
    }
}

struct EpisodeProgress: Codable {
    var state: EpisodePlaybackState
    var progress: Double
}

class EpisodeStateManager: ObservableObject {
    static let shared = EpisodeStateManager()
    
    @Published private(set) var episodeStates: [String: EpisodePlaybackState] = [:]
    @Published private(set) var currentlyPlayingEpisodeId: String?
    private var episodeProgress: [String: Double] = [:]
    
    private let userDefaults = UserDefaults.standard
    private let statesKey = "EpisodeStates"
    private let progressKey = "EpisodeProgress"
    
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
                    self.currentlyPlayingEpisodeId = nil // Clear any playing episode
                    self.objectWillChange.send()
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
            
            userDefaults.set(statesData, forKey: statesKey)
            userDefaults.set(progressData, forKey: progressKey)
        } catch {
            print("Error saving states: \(error)")
        }
    }
    
    func getState(for episodeId: String) -> EpisodePlaybackState {
        return episodeStates[episodeId] ?? .new
    }
    
    func getProgress(for episodeId: String) -> Double {
        return episodeProgress[episodeId] ?? 0.0
    }
    
    func startPlaying(episodeId: String) {
        // If there's a currently playing episode, mark it as "In Progress" before switching
        if let currentPlayingId = currentlyPlayingEpisodeId, currentPlayingId != episodeId {
            let currentProgress = episodeProgress[currentPlayingId] ?? 0.0
            if currentProgress > 0 {
                episodeStates[currentPlayingId] = .inProgress
            }
        }
        
        episodeStates[episodeId] = .playing
        currentlyPlayingEpisodeId = episodeId
        saveCurrentStates()
        objectWillChange.send()
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
        objectWillChange.send()
    }
    
    func switchToEpisode(newEpisodeId: String, previousEpisodeId: String, previousProgress: Double) {
        // Mark previous episode as "In Progress"
        if previousProgress > 0 {
            episodeStates[previousEpisodeId] = .inProgress
            episodeProgress[previousEpisodeId] = previousProgress
        }
        
        // Start playing new episode
        episodeStates[newEpisodeId] = .playing
        currentlyPlayingEpisodeId = newEpisodeId
        
        saveCurrentStates()
        objectWillChange.send()
    }
    
    func completeEpisode(episodeId: String) {
        episodeStates[episodeId] = .played
        episodeProgress[episodeId] = 1.0
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        saveCurrentStates()
        objectWillChange.send()
    }
    
    func rewindAndPlay(episodeId: String) {
        episodeStates[episodeId] = .playing
        episodeProgress[episodeId] = 0.0
        currentlyPlayingEpisodeId = episodeId
        
        saveCurrentStates()
        objectWillChange.send()
    }
    
    func updateProgress(for episodeId: String, progress: Double, isPlaying: Bool) {
        let newState: EpisodePlaybackState
        episodeProgress[episodeId] = progress
        
        if isPlaying {
            newState = .playing
            currentlyPlayingEpisodeId = episodeId
        } else if progress >= 0.99 {
            newState = .played
            currentlyPlayingEpisodeId = nil
        } else if progress > 0 {
            newState = .inProgress
            currentlyPlayingEpisodeId = nil
        } else {
            newState = .new
        }
        
        if episodeStates[episodeId] != newState {
            episodeStates[episodeId] = newState
            saveCurrentStates()
            objectWillChange.send()
        }
    }
    
    func clearAllStates() {
        episodeStates.removeAll()
        episodeProgress.removeAll()
        currentlyPlayingEpisodeId = nil
        
        userDefaults.removeObject(forKey: statesKey)
        userDefaults.removeObject(forKey: progressKey)
        
        objectWillChange.send()
    }
}
