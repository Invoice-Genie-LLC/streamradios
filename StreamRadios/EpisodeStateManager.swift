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
import CoreData

enum EpisodePlaybackState: String, Codable, Equatable {
    case new
    case playing
    case inProgress
    case played
    
    var statusText: String {
        switch self {
        case .new: return "New"
        case .playing: return "Playing"
        case .inProgress: return "IN PROGRESS"
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
    
    // MARK: - Published Properties
    @Published var episodeStates: [String: EpisodePlaybackState] = [:]
    @Published var episodeProgress: [String: Double] = [:]
    @Published var episodeFavorites: [String: Bool] = [:] // New: Track favorite states
    @Published var episodeDownloads: [String: Bool] = [:] // New: Track download states
    
    // MARK: - Private Properties
    private let userDefaults: UserDefaults
    private let isUsingAppGroup: Bool // Track if we're using app group UserDefaults
    private let statesKey = "EpisodeStates"
    private let progressKey = "EpisodeProgress"
    private let favoritesKey = "EpisodeFavorites" // New: Favorites storage key
    private let downloadsKey = "EpisodeDownloads" // New: Downloads storage key
    private let currentlyPlayingKey = "CurrentlyPlayingEpisode"
    
    // UPGRADE PROTECTION: Keys for tracking app version and preventing data loss
    private let appVersionKey = "EpisodeStateManagerAppVersion"
    private let downloadStateBackupKey = "DownloadStateBackup"
    private let lastSuccessfulInitKey = "LastSuccessfulEpisodeStateInit"
    
    private var currentlyPlayingEpisodeId: String?
    private var episodeCurrentTime: [String: Double] = [:]
    
    // Throttled update properties
    private var updateTimer: Timer?
    private let updateDelay: TimeInterval = 0.1
    
    private init() {
        // Try to use app group UserDefaults, fallback to standard if not available
        if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
            self.userDefaults = appGroupDefaults
            self.isUsingAppGroup = true
            print("✅ EpisodeStateManager: Using app group UserDefaults")
        } else {
            self.userDefaults = UserDefaults.standard
            self.isUsingAppGroup = false
            print("⚠️ EpisodeStateManager: App group not available, using standard UserDefaults")
        }
        
        // UPGRADE PROTECTION: Check for app version changes and migrate data if needed
        handleAppVersionUpgrade()
        
        loadSavedStates()
        
        // CRITICAL: Sync download states from Core Data on startup to recover from force close scenarios
        syncDownloadStatesFromCoreData()
        
        setupDebugLogging()
        
        // Mark successful initialization
        userDefaults.set(Date(), forKey: lastSuccessfulInitKey)
    }
    
    // MARK: - Upgrade Protection Methods
    
    /// Handle app version upgrades and migrate data to prevent loss
    private func handleAppVersionUpgrade() {
        guard let infoDictionary = Bundle.main.infoDictionary,
              let currentVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            print("⚠️ EpisodeStateManager: Could not get app version")
            return
        }
        
        let storedVersion = userDefaults.string(forKey: appVersionKey)
        
        if storedVersion == nil {
            // First time running this version or fresh install
            print("🆕 EpisodeStateManager: First run - version \(currentVersion)")
            
            // Check if this is actually an upgrade (has existing episode data)
            if hasExistingEpisodeData() {
                print("🔄 EpisodeStateManager: Detected upgrade scenario - preserving existing data")
                performUpgradeMigration(from: storedVersion, to: currentVersion)
            } else {
                print("🆕 EpisodeStateManager: Fresh install detected")
            }
        } else if storedVersion != currentVersion {
            // App version changed - this is an upgrade
            print("🔄 EpisodeStateManager: App upgraded from \(storedVersion ?? "unknown") to \(currentVersion)")
            performUpgradeMigration(from: storedVersion, to: currentVersion)
        } else {
            print("✅ EpisodeStateManager: Same version (\(currentVersion)) - no migration needed")
        }
        
        // Always update the stored version
        userDefaults.set(currentVersion, forKey: appVersionKey)
    }
    
    /// Check if there's existing episode data to help determine if this is an upgrade
    private func hasExistingEpisodeData() -> Bool {
        // Check multiple sources for existing data
        let hasProgressData = userDefaults.data(forKey: progressKey) != nil
        let hasFavoritesData = userDefaults.data(forKey: favoritesKey) != nil
        let hasDownloadsData = userDefaults.data(forKey: downloadsKey) != nil
        let hasStatesData = userDefaults.data(forKey: statesKey) != nil
        
        // Also check for any legacy keys that might indicate existing data
        let hasLegacyData = userDefaults.dictionaryRepresentation().keys.contains { key in
            key.lowercased().contains("episode") || key.lowercased().contains("podcast")
        }
        
        let hasAnyData = hasProgressData || hasFavoritesData || hasDownloadsData || hasStatesData || hasLegacyData
        
        print("📊 EpisodeStateManager: Existing data check - Progress: \(hasProgressData), Favorites: \(hasFavoritesData), Downloads: \(hasDownloadsData), States: \(hasStatesData), Legacy: \(hasLegacyData)")
        
        return hasAnyData
    }
    
    /// Perform upgrade migration to preserve download states
    private func performUpgradeMigration(from oldVersion: String?, to newVersion: String) {
        print("🔄 EpisodeStateManager: Performing upgrade migration")
        
        // CRITICAL: Create backup of current download states before any migration
        backupDownloadStates()
        
        // Migrate from different UserDefaults if needed
        migrateFromStandardUserDefaults()
        
        // Restore download states from backup if main data is missing
        restoreDownloadStatesFromBackup()
        
        print("✅ EpisodeStateManager: Upgrade migration completed")
    }
    
    /// Backup current download states to prevent loss
    private func backupDownloadStates() {
        var backupData: [String: Any] = [:]
        
        // Backup all episode-related data
        if let progressData = userDefaults.data(forKey: progressKey) {
            backupData["progress"] = progressData
        }
        
        if let favoritesData = userDefaults.data(forKey: favoritesKey) {
            backupData["favorites"] = favoritesData
        }
        
        if let downloadsData = userDefaults.data(forKey: downloadsKey) {
            backupData["downloads"] = downloadsData
        }
        
        if let statesData = userDefaults.data(forKey: statesKey) {
            backupData["states"] = statesData
        }
        
        // Store backup with timestamp
        backupData["timestamp"] = Date().timeIntervalSince1970  // Convert Date to TimeInterval for JSON serialization
        backupData["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        if let backupDataEncoded = try? JSONSerialization.data(withJSONObject: backupData) {
            userDefaults.set(backupDataEncoded, forKey: downloadStateBackupKey)
            print("💾 EpisodeStateManager: Created backup of episode states")
        }
    }
    
    /// Migrate data from standard UserDefaults to app group UserDefaults if needed
    private func migrateFromStandardUserDefaults() {
        // Only migrate if we're using app group UserDefaults but data might be in standard
        guard isUsingAppGroup else { return }
        
        let standardDefaults = UserDefaults.standard
        var migratedCount = 0
        
        // Check each key and migrate if data exists in standard but not in app group
        let keysToMigrate = [progressKey, favoritesKey, downloadsKey, statesKey, currentlyPlayingKey]
        
        for key in keysToMigrate {
            if userDefaults.data(forKey: key) == nil, let data = standardDefaults.data(forKey: key) {
                userDefaults.set(data, forKey: key)
                migratedCount += 1
                print("🔄 EpisodeStateManager: Migrated \(key) from standard to app group UserDefaults")
            }
        }
        
        if migratedCount > 0 {
            print("✅ EpisodeStateManager: Migrated \(migratedCount) keys from standard UserDefaults")
        }
    }
    
    /// Restore download states from backup if main data is missing
    private func restoreDownloadStatesFromBackup() {
        // Check if current download data is missing but backup exists
        guard userDefaults.data(forKey: downloadsKey) == nil,
              let backupData = userDefaults.data(forKey: downloadStateBackupKey),
              let backup = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any] else {
            return
        }
        
        print("🔄 EpisodeStateManager: Restoring download states from backup")
        
        // Restore each data type from backup
        if let progressData = backup["progress"] as? Data {
            userDefaults.set(progressData, forKey: progressKey)
        }
        
        if let favoritesData = backup["favorites"] as? Data {
            userDefaults.set(favoritesData, forKey: favoritesKey)
        }
        
        if let downloadsData = backup["downloads"] as? Data {
            userDefaults.set(downloadsData, forKey: downloadsKey)
            print("✅ EpisodeStateManager: Restored download states from backup")
        }
        
        if let statesData = backup["states"] as? Data {
            userDefaults.set(statesData, forKey: statesKey)
        }
    }
    
    /// Check if this is a definite upgrade scenario (not fresh install)
    func isUpgradeScenario() -> Bool {
        // Multiple indicators that this is an upgrade:
        // 1. Has existing episode data
        // 2. Has app version stored (ran before)
        // 3. Has successful initialization timestamp
        // 4. Has Core Data with episodes
        
        let hasStoredVersion = userDefaults.string(forKey: appVersionKey) != nil
        let hasInitTimestamp = userDefaults.object(forKey: lastSuccessfulInitKey) != nil
        let hasEpisodeData = hasExistingEpisodeData()
        
        let isUpgrade = hasStoredVersion || hasInitTimestamp || hasEpisodeData
        
        print("📊 EpisodeStateManager: Upgrade check - HasVersion: \(hasStoredVersion), HasInit: \(hasInitTimestamp), HasData: \(hasEpisodeData) = \(isUpgrade)")
        
        return isUpgrade
    }
    
    // MARK: - Public Methods
    
    private func loadSavedStates() {
        // Load episode states
        if let statesData = userDefaults.data(forKey: statesKey),
           let decodedStates = try? JSONDecoder().decode([String: String].self, from: statesData) {
            self.episodeStates = decodedStates.compactMapValues { EpisodePlaybackState(rawValue: $0) }
            print("✅ EpisodeStateManager: Loaded \(episodeStates.count) episode states")
        }
        
        // Load episode progress
        if let progressData = userDefaults.data(forKey: progressKey),
           let decodedProgress = try? JSONDecoder().decode([String: Double].self, from: progressData) {
            self.episodeProgress = decodedProgress
            print("✅ EpisodeStateManager: Loaded \(episodeProgress.count) episode progress entries")
        }
        
        // Load episode favorites
        if let favoritesData = userDefaults.data(forKey: favoritesKey),
           let decodedFavorites = try? JSONDecoder().decode([String: Bool].self, from: favoritesData) {
            self.episodeFavorites = decodedFavorites
            print("✅ EpisodeStateManager: Loaded \(episodeFavorites.count) episode favorites")
        }
        
        // Load episode downloads
        if let downloadsData = userDefaults.data(forKey: downloadsKey),
           let decodedDownloads = try? JSONDecoder().decode([String: Bool].self, from: downloadsData) {
            self.episodeDownloads = decodedDownloads
            print("✅ EpisodeStateManager: Loaded \(episodeDownloads.count) episode downloads")
        }
        
        // UPGRADE PROTECTION: Recover any missing download states from backups
        if episodeDownloads.isEmpty || isUpgradeScenario() {
            print("🔄 EpisodeStateManager: Attempting to recover download states from backups")
            restoreDownloadStatesFromBackup()
            recoverDownloadStatesFromIndividualBackups()
        }
        
        // Load currently playing episode
        currentlyPlayingEpisodeId = userDefaults.string(forKey: currentlyPlayingKey)
        if let playingId = currentlyPlayingEpisodeId {
            print("✅ EpisodeStateManager: Currently playing episode: \(playingId)")
        }
    }
    
    private func saveCurrentStates() {
        // Save episode states
        let statesForSaving = episodeStates.mapValues { $0.rawValue }
        if let statesData = try? JSONEncoder().encode(statesForSaving) {
            userDefaults.set(statesData, forKey: statesKey)
        }
        
        // Save episode progress
        if let progressData = try? JSONEncoder().encode(episodeProgress) {
            userDefaults.set(progressData, forKey: progressKey)
        }
        
        // Save episode favorites
        if let favoritesData = try? JSONEncoder().encode(episodeFavorites) {
            userDefaults.set(favoritesData, forKey: favoritesKey)
        }
        
        // Save episode downloads
        if let downloadsData = try? JSONEncoder().encode(episodeDownloads) {
            userDefaults.set(downloadsData, forKey: downloadsKey)
        }
        
        // Save currently playing episode
        if let playingId = currentlyPlayingEpisodeId {
            userDefaults.set(playingId, forKey: currentlyPlayingKey)
        } else {
            userDefaults.removeObject(forKey: currentlyPlayingKey)
        }
    }
    
    // Throttled update method to prevent excessive UI updates
    private var lastUpdateTime = Date()
    private let updateThrottleInterval: TimeInterval = 3.0 // 3 seconds between updates
    
    func getState(for episodeId: String) -> EpisodePlaybackState {
        return episodeStates[episodeId] ?? .new
    }
    
    func getProgress(for episodeId: String) -> Double {
        let progress = episodeProgress[episodeId] ?? 0.0
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
        
        // CRITICAL: Send immediate update for playing state changes to prevent UI lag
        sendImmediateUpdate()
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
        // CRITICAL: Immediately stop the previous episode from showing as playing
        if currentlyPlayingEpisodeId == previousEpisodeId {
            currentlyPlayingEpisodeId = nil
        }
        
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
        
        // CRITICAL: Send immediate update to refresh UI immediately, then follow with throttled update
        sendImmediateUpdate()
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
        } else {
            // Don't overwrite existing progress with 0.0
            shouldUpdateProgress = false
        }
        
        // Store current time if provided
        if let currentTime = currentTime {
            episodeCurrentTime[episodeId] = currentTime
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
            episodeStates[episodeId] = newState
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
        
        // CRITICAL FIX: Force synchronize UserDefaults immediately for CloudKit synced progress to prevent loss
        userDefaults.synchronize()
        
        sendThrottledUpdate()
    }
    
    /// Force save current states immediately (for critical saves)
    func forceSave() {
        saveCurrentStates()
        userDefaults.synchronize()
    }
    
    /// Get favorite state for an episode
    func isFavorite(_ episodeId: String) -> Bool {
        return episodeFavorites[episodeId] ?? false
    }
    
    /// Set favorite state for an episode
    func setFavorite(_ episodeId: String, isFavorite: Bool) {
        episodeFavorites[episodeId] = isFavorite
        saveCurrentStates()
        userDefaults.synchronize() // Force immediate sync
        sendThrottledUpdate()
        print("🔍 EpisodeStateManager: Set favorite for \(episodeId): \(isFavorite)")
    }
    
    /// Get download state for an episode
    func isDownloaded(_ episodeId: String) -> Bool {
        return episodeDownloads[episodeId] ?? false
    }
    
    /// Set download state for an episode
    func setDownloaded(_ episodeId: String, isDownloaded: Bool) {
        episodeDownloads[episodeId] = isDownloaded
        saveCurrentStates()
        userDefaults.synchronize() // Force immediate sync
        sendThrottledUpdate()
        print("🔍 EpisodeStateManager: Set downloaded for \(episodeId): \(isDownloaded)")
    }
    
    /// UPGRADE PROTECTION: Enhanced download state setting with backup
    func setDownloadedWithProtection(_ episodeId: String, isDownloaded: Bool, reason: String = "normal") {
        let previousState = episodeDownloads[episodeId] ?? false
        
        // If we're setting to false but it was true, check if this is during an upgrade
        if previousState && !isDownloaded && isUpgradeScenario() {
            print("⚠️ EpisodeStateManager: Preventing download state reset during upgrade for \(episodeId) (reason: \(reason))")
            // Don't change the state during upgrades unless explicitly forced
            return
        }
        
        episodeDownloads[episodeId] = isDownloaded
        saveCurrentStates()
        userDefaults.synchronize() // Force immediate sync
        sendThrottledUpdate()
        print("🔍 EpisodeStateManager: Set downloaded for \(episodeId): \(isDownloaded) (reason: \(reason))")
        
        // Create additional backup if setting to true
        if isDownloaded {
            backupSingleDownloadState(episodeId: episodeId)
        }
    }
    
    /// Backup a single download state for recovery
    private func backupSingleDownloadState(episodeId: String) {
        let backupKey = "DownloadBackup_\(episodeId)"
        let backupData: [String: Any] = [
            "isDownloaded": true,
            "timestamp": Date().timeIntervalSince1970,  // Convert Date to TimeInterval for JSON serialization
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]
        
        if let encoded = try? JSONSerialization.data(withJSONObject: backupData) {
            userDefaults.set(encoded, forKey: backupKey)
        }
    }
    
    /// Recover download states from individual backups
    private func recoverDownloadStatesFromIndividualBackups() {
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let backupKeys = allKeys.filter { $0.hasPrefix("DownloadBackup_") }
        
        var recoveredCount = 0
        
        for backupKey in backupKeys {
            let episodeId = String(backupKey.dropFirst("DownloadBackup_".count))
            
            // Only recover if current state is false but backup exists
            if !(episodeDownloads[episodeId] ?? false),
               let backupData = userDefaults.data(forKey: backupKey),
               let backup = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any],
               let wasDownloaded = backup["isDownloaded"] as? Bool,
               wasDownloaded {
                
                episodeDownloads[episodeId] = true
                recoveredCount += 1
                print("🔄 EpisodeStateManager: Recovered download state for \(episodeId)")
            }
        }
        
        if recoveredCount > 0 {
            print("✅ EpisodeStateManager: Recovered \(recoveredCount) download states from individual backups")
            saveCurrentStates()
        }
    }
    
    /// Clear individual backup file for a specific episode (used when deleting downloads)
    func clearEpisodeBackup(_ episodeId: String) {
        let backupKey = "DownloadBackup_\(episodeId)"
        userDefaults.removeObject(forKey: backupKey)
        userDefaults.synchronize()
        print("🗑️ EpisodeStateManager: Cleared backup for episode \(episodeId)")
    }
    
    /// Clear all data for a specific episode (used when deleting podcasts)
    func clearEpisodeData(_ episodeId: String) {
        episodeStates.removeValue(forKey: episodeId)
        episodeProgress.removeValue(forKey: episodeId)
        episodeFavorites.removeValue(forKey: episodeId)
        episodeDownloads.removeValue(forKey: episodeId)
        episodeCurrentTime.removeValue(forKey: episodeId)
        
        // Clear currently playing if this is the episode
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        // Clear individual backup file
        clearEpisodeBackup(episodeId)
        
        saveCurrentStates()
        sendThrottledUpdate()
        print("🗑️ EpisodeStateManager: Cleared all data for episode \(episodeId)")
    }
    
    func clearAllStates() {
        episodeStates.removeAll()
        episodeProgress.removeAll()
        episodeFavorites.removeAll()
        episodeDownloads.removeAll()
        currentlyPlayingEpisodeId = nil
        
        userDefaults.removeObject(forKey: statesKey)
        userDefaults.removeObject(forKey: progressKey)
        userDefaults.removeObject(forKey: favoritesKey)
        userDefaults.removeObject(forKey: downloadsKey)
        userDefaults.removeObject(forKey: currentlyPlayingKey)
        
        sendThrottledUpdate()
    }
    
    /// Synchronize download states from Core Data on startup to recover from force close scenarios
    /// UPGRADE PROTECTION: Enhanced to prevent download state loss during upgrades
    private func syncDownloadStatesFromCoreData() {
        DispatchQueue.global(qos: .utility).async {
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    // Get all downloaded episodes from Core Data
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
                    
                    let downloadedEpisodes = try context.fetch(fetchRequest)
                    
                    var syncedCount = 0
                    var cleanedCount = 0
                    let isUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
                    
                    print("🔄 EpisodeStateManager: Syncing \(downloadedEpisodes.count) downloaded episodes from Core Data (upgrade: \(isUpgrade))")
                    
                    for managedEpisode in downloadedEpisodes {
                        guard let episodeId = managedEpisode.id else { continue }
                        
                        // Verify file still exists
                        var fileExists = false
                        if let localPath = managedEpisode.localFilePath, !localPath.isEmpty {
                            fileExists = FileManager.default.fileExists(atPath: localPath)
                        }
                        
                        if fileExists {
                            // File exists, ensure EpisodeStateManager knows about it
                            DispatchQueue.main.async {
                                EpisodeStateManager.shared.setDownloadedWithProtection(episodeId, isDownloaded: true, reason: "core_data_sync")
                            }
                            syncedCount += 1
                        } else {
                            // UPGRADE PROTECTION: During upgrades, be more conservative about cleaning up missing files
                            if isUpgrade {
                                print("⚠️ EpisodeStateManager: File missing during upgrade - preserving download state for \(episodeId)")
                                // Keep the download state in EpisodeStateManager but clean up Core Data
                                managedEpisode.localFilePath = nil
                                // Don't change the isDownloaded flag in Core Data during upgrades
                            } else {
                                // Not an upgrade, safe to clean up normally
                                managedEpisode.isDownloaded = false
                                managedEpisode.localFilePath = nil
                                DispatchQueue.main.async {
                                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                    EpisodeStateManager.shared.clearEpisodeBackup(episodeId)  // Clear backup to prevent recovery
                                    
                                    // CRITICAL: Sync the download state change to CloudKit
                                    if let feedId = managedEpisode.feedId, !feedId.isEmpty {
                                        Task.detached(priority: .utility) {
                                            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                                            let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                                            await PodcastCloudKitManager.shared.saveEpisodeState(
                                                episodeId: episodeId,
                                                feedId: feedId,
                                                progress: currentProgress,
                                                isFavorite: currentFavorite,
                                                isDownloaded: false,
                                                isPlayed: currentProgress >= 0.99
                                            )
                                            print("☁️ Synced download state cleanup to CloudKit from EpisodeStateManager: \(episodeId)")
                                        }
                                    }
                                }
                                cleanedCount += 1
                            }
                        }
                    }
                    
                    // Save Core Data changes if needed
                    if cleanedCount > 0 {
                        try context.save()
                    }
                    
                    print("🔄 EpisodeStateManager startup sync: \(syncedCount) downloads synced, \(cleanedCount) cleaned up")
                    
                } catch {
                    print("❌ EpisodeStateManager startup sync error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDebugLogging() {
        // Set up app termination observer to save state
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.saveCurrentStates()
            self.userDefaults.synchronize()
        }
    }
    
    private func sendThrottledUpdate() {
        // Cancel any existing timer
        updateTimer?.invalidate()
        
        // Create a new timer that will fire after the delay
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateDelay, repeats: false) { _ in
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    private func sendImmediateUpdate() {
        // Send immediate update to refresh UI without throttling
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}
