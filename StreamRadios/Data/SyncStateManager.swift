// SyncStateManager.swift
// StreamRadios
//
// Created by AI Assistant
//

import Foundation
import os.log

/// Manages persistent sync state for resumable CloudKit operations
class SyncStateManager {
    static let shared = SyncStateManager()
    
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "SyncState")
    private let userDefaults = UserDefaults(suiteName: "group.streamradios") ?? UserDefaults.standard
    
    // MARK: - Keys
    private enum Keys {
        static let radioStationSyncState = "radioStationSyncState"
        static let radioStationSyncProgress = "radioStationSyncProgress"
        static let radioStationSyncMetadata = "radioStationSyncMetadata"
    }
    
    // MARK: - Data Structures
    
    struct RadioStationSyncState: Codable {
        let totalStations: Int
        let processedStations: [String] // Station IDs that have been synced
        let failedStations: [String] // Station IDs that failed to sync
        let startTime: Date
        let lastUpdateTime: Date
        let country: String?
        let operationType: String // "batch_save", "country_add", etc.
        
        var remainingCount: Int {
            return totalStations - processedStations.count
        }
        
        var completedCount: Int {
            return processedStations.count
        }
        
        var progress: Double {
            guard totalStations > 0 else { return 0.0 }
            return Double(completedCount) / Double(totalStations)
        }
    }
    
    struct SyncMetadata: Codable {
        let averageTimePerStation: Double
        let estimatedTimeRemaining: TimeInterval
        let syncSpeed: Double // stations per second
        let lastPerformanceUpdate: Date
    }
    
    private init() {}
    
    // MARK: - Radio Station Sync State Management
    
    /// Start tracking a new radio station sync operation
    func startRadioStationSync(totalStations: Int, country: String?, operationType: String) {
        let syncState = RadioStationSyncState(
            totalStations: totalStations,
            processedStations: [],
            failedStations: [],
            startTime: Date(),
            lastUpdateTime: Date(),
            country: country,
            operationType: operationType
        )
        
        saveRadioStationSyncState(syncState)
        
        // Reset metadata for new sync
        let metadata = SyncMetadata(
            averageTimePerStation: 0.0,
            estimatedTimeRemaining: 0.0,
            syncSpeed: 0.0,
            lastPerformanceUpdate: Date()
        )
        saveSyncMetadata(metadata)
        
        os_log("🔄 Started tracking radio station sync: %d stations, country: %@, type: %@", 
               log: log, type: .info, totalStations, country ?? "All", operationType)
    }
    
    /// Mark a station as successfully processed
    func markStationProcessed(_ stationId: String) {
        guard let syncState = getRadioStationSyncState() else { return }
        
        if !syncState.processedStations.contains(stationId) {
            var updatedProcessedStations = syncState.processedStations
            updatedProcessedStations.append(stationId)
            
            // Remove from failed stations if it was there
            var updatedFailedStations = syncState.failedStations
            if let failedIndex = updatedFailedStations.firstIndex(of: stationId) {
                updatedFailedStations.remove(at: failedIndex)
            }
            
            // Update timing
            let updatedState = RadioStationSyncState(
                totalStations: syncState.totalStations,
                processedStations: updatedProcessedStations,
                failedStations: updatedFailedStations,
                startTime: syncState.startTime,
                lastUpdateTime: Date(),
                country: syncState.country,
                operationType: syncState.operationType
            )
            
            saveRadioStationSyncState(updatedState)
            updateSyncPerformanceMetrics(updatedState)
        }
    }
    
    /// Mark a station as failed
    func markStationFailed(_ stationId: String) {
        guard let syncState = getRadioStationSyncState() else { return }
        
        if !syncState.failedStations.contains(stationId) && !syncState.processedStations.contains(stationId) {
            var updatedFailedStations = syncState.failedStations
            updatedFailedStations.append(stationId)
            
            let updatedState = RadioStationSyncState(
                totalStations: syncState.totalStations,
                processedStations: syncState.processedStations,
                failedStations: updatedFailedStations,
                startTime: syncState.startTime,
                lastUpdateTime: Date(),
                country: syncState.country,
                operationType: syncState.operationType
            )
            
            saveRadioStationSyncState(updatedState)
        }
    }
    
    /// Complete the radio station sync
    func completeRadioStationSync() {
        clearRadioStationSyncState()
        os_log("✅ Completed radio station sync tracking", log: log, type: .info)
    }
    
    /// Check if there's an incomplete radio station sync to resume
    func hasIncompleteRadioStationSync() -> Bool {
        return getRadioStationSyncState() != nil
    }
    
    /// Get the current radio station sync state
    func getRadioStationSyncState() -> RadioStationSyncState? {
        guard let data = userDefaults.data(forKey: Keys.radioStationSyncState) else { return nil }
        return try? JSONDecoder().decode(RadioStationSyncState.self, from: data)
    }
    
    /// Get sync metadata for performance tracking
    func getSyncMetadata() -> SyncMetadata? {
        guard let data = userDefaults.data(forKey: Keys.radioStationSyncMetadata) else { return nil }
        return try? JSONDecoder().decode(SyncMetadata.self, from: data)
    }
    
    /// Get stations that still need to be processed
    func getStationsToProcess(from allStationIds: [String]) -> [String] {
        guard let syncState = getRadioStationSyncState() else { return allStationIds }
        
        let processedSet = Set(syncState.processedStations)
        let failedSet = Set(syncState.failedStations)
        
        return allStationIds.filter { stationId in
            !processedSet.contains(stationId) && !failedSet.contains(stationId)
        }
    }
    
    /// Force clear sync state (for debugging or reset)
    func clearRadioStationSyncState() {
        userDefaults.removeObject(forKey: Keys.radioStationSyncState)
        userDefaults.removeObject(forKey: Keys.radioStationSyncMetadata)
        os_log("🔄 Cleared radio station sync state", log: log, type: .info)
    }
    
    // MARK: - Private Methods
    
    private func saveRadioStationSyncState(_ state: RadioStationSyncState) {
        if let data = try? JSONEncoder().encode(state) {
            userDefaults.set(data, forKey: Keys.radioStationSyncState)
        }
    }
    
    private func saveSyncMetadata(_ metadata: SyncMetadata) {
        if let data = try? JSONEncoder().encode(metadata) {
            userDefaults.set(data, forKey: Keys.radioStationSyncMetadata)
        }
    }
    
    private func updateSyncPerformanceMetrics(_ syncState: RadioStationSyncState) {
        let currentTime = Date()
        let elapsedTime = currentTime.timeIntervalSince(syncState.startTime)
        let processedCount = syncState.processedStations.count
        
        guard processedCount > 0 && elapsedTime > 0 else { return }
        
        let averageTimePerStation = elapsedTime / Double(processedCount)
        let syncSpeed = Double(processedCount) / elapsedTime
        let remainingStations = syncState.remainingCount
        let estimatedTimeRemaining = Double(remainingStations) * averageTimePerStation
        
        let metadata = SyncMetadata(
            averageTimePerStation: averageTimePerStation,
            estimatedTimeRemaining: estimatedTimeRemaining,
            syncSpeed: syncSpeed,
            lastPerformanceUpdate: currentTime
        )
        
        saveSyncMetadata(metadata)
    }
    
    // MARK: - Debug Methods
    
    /// Get debug information about current sync state
    func getDebugInfo() -> String {
        var info = "=== Sync State Debug Info ===\n"
        
        if let syncState = getRadioStationSyncState() {
            info += "Active Sync:\n"
            info += "  Total: \(syncState.totalStations)\n"
            info += "  Processed: \(syncState.processedStations.count)\n"
            info += "  Failed: \(syncState.failedStations.count)\n"
            info += "  Remaining: \(syncState.remainingCount)\n"
            info += "  Progress: \(String(format: "%.1f", syncState.progress * 100))%\n"
            info += "  Country: \(syncState.country ?? "All")\n"
            info += "  Type: \(syncState.operationType)\n"
            info += "  Started: \(syncState.startTime)\n"
            info += "  Last Update: \(syncState.lastUpdateTime)\n"
            
            if let metadata = getSyncMetadata() {
                info += "Performance:\n"
                info += "  Avg Time/Station: \(String(format: "%.2f", metadata.averageTimePerStation))s\n"
                info += "  Speed: \(String(format: "%.2f", metadata.syncSpeed)) stations/sec\n"
                info += "  ETA: \(String(format: "%.0f", metadata.estimatedTimeRemaining))s\n"
            }
        } else {
            info += "No active sync\n"
        }
        
        return info
    }
}
