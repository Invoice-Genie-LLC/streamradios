import Foundation
import CloudKit
import CoreData
import os
import Combine
import CryptoKit

// Import required types and models
import SwiftUI // For MainActor


// MARK: - Array Extension for Batching
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct CloudEpisodeIdentity: Hashable {
    let episodeId: String
    let feedId: String

    var storageKey: String {
        "\(feedId)\u{1F}\(episodeId)"
    }
}

struct CloudEpisodeState {
    let episodeId: String
    let feedId: String?
    let progress: Double
    let isFavorite: Bool
    let isDownloaded: Bool
    let isPlayed: Bool
    let isLegacyRecord: Bool
}

/// CloudKit manager for podcast feeds and episode states with proper conflict resolution
class PodcastCloudKitManager: ObservableObject {
    static let shared = PodcastCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "PodcastCloudKit")
    private let episodeManager = PodcastEpisodeManager()
    private let feedIdAliasLock = NSLock()
    private var localFeedIdByCloudFeedId: [String: String] = [:]
    
    // Instant sync using NSUbiquitousKeyValueStore for immediate cross-device data sharing
    private let ubiquitousStore = NSUbiquitousKeyValueStore()
    
    @Published var lastInstantSyncDate: Date?

    func registerFeedIdAlias(cloudFeedId: String, localFeedId: String) {
        guard !cloudFeedId.isEmpty, !localFeedId.isEmpty, cloudFeedId != localFeedId else { return }
        feedIdAliasLock.lock()
        localFeedIdByCloudFeedId[cloudFeedId] = localFeedId
        feedIdAliasLock.unlock()
    }

    private func canonicalLocalFeedId(for cloudFeedId: String) -> String {
        feedIdAliasLock.lock()
        defer { feedIdAliasLock.unlock() }
        return localFeedIdByCloudFeedId[cloudFeedId] ?? cloudFeedId
    }
    
    // MARK: - Shared Data Structure Keys (to prevent quota exceeded)
    enum SharedDataKeys {
        static let episodeProgress = "podcast_episodes_progress"
        static let episodeFavorites = "podcast_episodes_favorites"
        static let episodeDownloads = "podcast_episodes_downloads"
        static let episodePlayed = "podcast_episodes_played"
        static let lastCleanupDate = "ubiquitous_store_last_cleanup"
    }
    
    // Maximum entries per shared collection to prevent size issues
    private let maxEntriesPerCollection = 200
    
    // Cleanup interval (7 days)
    private let cleanupInterval: TimeInterval = 7 * 24 * 60 * 60
    
    // CloudKit Record Types
    private enum RecordType {
        static let episodeState = "EpisodeState"
        static let podcastFeed = "PodcastFeed"
    }

    private static func episodeStateRecordID(for identity: CloudEpisodeIdentity) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(identity.storageKey.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "episode_state_v2_\(hash)")
    }

    private static func legacyEpisodeStateRecordID(for episodeId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "episode_state_\(episodeId)")
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
        setupInstantSync()
        setupCloudKitSubscriptions()
        
        // Perform cleanup asynchronously to avoid blocking app startup
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            self.performUbiquitousStoreCleanup()
        }
    }
    
    // MARK: - Instant Sync Setup
    
    private func setupInstantSync() {
        
        // Test iCloud availability first
        testICloudAvailability()
        
        // Start observing changes from other devices via NSUbiquitousKeyValueStore
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore
        )
        
        // Note: synchronize() is deprecated and unnecessary - NSUbiquitousKeyValueStore syncs automatically
        // Removed to fix Swift Concurrency warning
    }
    
    /// Test if iCloud is available and properly configured
    private func testICloudAvailability() {
        
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return
        }
        
        // Test writing to ubiquitous store
        let testKey = "test_connectivity"
        let testValue = ["timestamp": Date().timeIntervalSince1970, "test": true] as [String: Any]
        
        ubiquitousStore.set(testValue, forKey: testKey)
        // Note: synchronize() is deprecated and unnecessary - syncs automatically
        
        // Clean up test data
        ubiquitousStore.removeObject(forKey: testKey)
        // Note: synchronize() is deprecated and unnecessary
    }
    
    // MARK: - Account Validation
    
    /// Gets the current iCloud account identifier to prevent cross-account sync contamination
    private func getCurrentiCloudAccountID() -> String? {
        if let token = FileManager.default.ubiquityIdentityToken,
           let tokenData = token as? Data {
            return tokenData.base64EncodedString()
        }
        return nil
    }
    
    /// Debug flag to bypass account validation for testing
    private let debugBypassAccountValidation = false
    
    /// Validates that sync data is from the same iCloud account
    private func validateSyncAccount(syncData: [String: Any]) -> Bool {
        
        // DEBUG: Temporarily bypass validation for testing
        if debugBypassAccountValidation {
            print("📡 🧪 DEBUG: Bypassing account validation for testing")
            return true
        }
        guard let currentAccountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ ACCOUNT VALIDATION: No current iCloud account available")
            return false
        }
        
        // Check if sync data has account ID (new feature)
        if let syncAccountID = syncData["icloud_account_id"] as? String {
            let isValid = syncAccountID == currentAccountID
            // Silently reject cross-account data without logging spam
            return isValid
        }
        
        return true
    }
    

    
    // MARK: - Ubiquitous Store Cleanup
    
    /// Perform cleanup of old ubiquitous store keys to prevent quota exceeded
    private func performUbiquitousStoreCleanup() {
        let now = Date().timeIntervalSince1970
        let lastCleanup = ubiquitousStore.double(forKey: SharedDataKeys.lastCleanupDate)
        
        // CRITICAL: Force cleanup if test data exists (performance fix)
        let hasTestData = checkForTestDataPollution()
        
        // CRITICAL: Force cleanup if cross-account data exists (fixes spam errors)
        let hasCrossAccountData = checkForCrossAccountData()
        
        // Only cleanup if it's been more than cleanup interval since last cleanup, UNLESS we have issues
        guard hasTestData || hasCrossAccountData || lastCleanup == 0 || (now - lastCleanup) > cleanupInterval else {
            print("📡 🧹 CLEANUP: Skipping cleanup - last cleanup was recent")
            return
        }
        
        if hasTestData {
            print("📡 🧹 CLEANUP: ⚠️ FORCING CLEANUP - Test data pollution detected causing performance issues!")
        }
        
        if hasCrossAccountData {
            print("📡 🧹 CLEANUP: ⚠️ FORCING CLEANUP - Cross-account data detected causing sync errors!")
        }
        
        print("📡 🧹 CLEANUP: Starting ubiquitous store cleanup to prevent quota exceeded")
        
        // Clean up old per-episode keys that may exist from previous versions
        let allKeys = ubiquitousStore.dictionaryRepresentation.keys
        var removedCount = 0
        
        for key in allKeys {
            // Remove old unique episode keys
            if key.hasPrefix("instant_podcast_progress_") ||
               key.hasPrefix("instant_podcast_favorite_") ||
               key.hasPrefix("instant_podcast_download_") ||
               key.hasPrefix("instant_podcast_played_") {
                ubiquitousStore.removeObject(forKey: key)
                removedCount += 1
            }
        }
        
        if removedCount > 0 {
            print("📡 🧹 CLEANUP: Removed \(removedCount) old episode-specific keys")
            // Note: synchronize() is deprecated and unnecessary
        }
        
        // Clean up oversized collections
        cleanupSharedDataCollections()
        
        // CRITICAL: Clean up test data pollution that's causing performance issues
        cleanupTestDataPollution()
        
        // Record cleanup date
        ubiquitousStore.set(now, forKey: SharedDataKeys.lastCleanupDate)
        // Note: synchronize() is deprecated and unnecessary
        
        print("📡 🧹 CLEANUP: Completed ubiquitous store cleanup")
    }
    
    /// Clean up shared data collections to keep them under size limits
    private func cleanupSharedDataCollections() {
        cleanupCollection(key: SharedDataKeys.episodeProgress, maxEntries: maxEntriesPerCollection)
        cleanupCollection(key: SharedDataKeys.episodeFavorites, maxEntries: maxEntriesPerCollection)
        cleanupCollection(key: SharedDataKeys.episodeDownloads, maxEntries: maxEntriesPerCollection)
        cleanupCollection(key: SharedDataKeys.episodePlayed, maxEntries: maxEntriesPerCollection)
    }
    
    /// Clean up a specific collection by removing oldest entries AND cross-account data
    private func cleanupCollection(key: String, maxEntries: Int) {
        guard let collection = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] else {
            return
        }
        
        guard let currentAccountID = getCurrentiCloudAccountID() else {
            print("📡 🧹 CLEANUP: No iCloud account - skipping \(key) cleanup")
            return
        }
        
        var crossAccountCount = 0
        var cleanedCollection: [String: [String: Any]] = [:]
        
        // CRITICAL: Remove all episodes from other iCloud accounts
        for (episodeId, episodeData) in collection {
            if let syncAccountID = episodeData["icloud_account_id"] as? String {
                if syncAccountID == currentAccountID {
                    // Keep this episode - it belongs to current account
                    cleanedCollection[episodeId] = episodeData
                } else {
                    // Remove cross-account episode
                    crossAccountCount += 1
                }
            } else {
                // No account ID - keep for backward compatibility but mark for future cleanup
                cleanedCollection[episodeId] = episodeData
            }
        }
        
        if crossAccountCount > 0 {
            print("📡 🧹 CLEANUP: Removed \(crossAccountCount) cross-account episodes from \(key)")
        }
        
        // Now trim by size if still too large
        if cleanedCollection.count > maxEntries {
            print("📡 🧹 CLEANUP: Collection \(key) has \(cleanedCollection.count) entries, trimming to \(maxEntries)")
            
            // Sort by timestamp and keep only the most recent entries
            let sortedEntries = cleanedCollection.sorted { entry1, entry2 in
                let timestamp1 = (entry1.value["timestamp"] as? Double) ?? 0
                let timestamp2 = (entry2.value["timestamp"] as? Double) ?? 0
                return timestamp1 > timestamp2
            }
            
            let trimmedArray = Array(sortedEntries.prefix(maxEntries))
            cleanedCollection = Dictionary(trimmedArray, uniquingKeysWith: { _, second in second })
            
            print("📡 🧹 CLEANUP: Trimmed \(key) from \(collection.count) to \(cleanedCollection.count) entries")
        }
        
        // Save cleaned collection back
        if crossAccountCount > 0 || cleanedCollection.count != collection.count {
            ubiquitousStore.set(cleanedCollection, forKey: key)
            print("📡 🧹 CLEANUP: Updated \(key) - removed \(collection.count - cleanedCollection.count) total entries")
        }
    }
    
    /// Check if cross-account data exists that would cause sync errors
    private func checkForCrossAccountData() -> Bool {
        guard let currentAccountID = getCurrentiCloudAccountID() else {
            return false
        }
        
        let collectionsToCheck = [
            SharedDataKeys.episodeProgress,
            SharedDataKeys.episodeFavorites,
            SharedDataKeys.episodeDownloads,
            SharedDataKeys.episodePlayed
        ]
        
        for key in collectionsToCheck {
            if let data = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] {
                for (_, episodeData) in data {
                    if let syncAccountID = episodeData["icloud_account_id"] as? String {
                        if syncAccountID != currentAccountID {
                            // Found cross-account data
                            return true
                        }
                    }
                }
            }
        }
        
        return false
    }
    
    /// Check if test data pollution exists that would cause performance issues
    private func checkForTestDataPollution() -> Bool {
        // Check favorites for test episodes
        if let favoritesData = ubiquitousStore.object(forKey: SharedDataKeys.episodeFavorites) as? [String: [String: Any]] {
            for episodeId in favoritesData.keys {
                if episodeId.hasPrefix("test-episode-") {
                    return true
                }
            }
        }
        
        // Check other collections too
        let collectionsToCheck = [
            SharedDataKeys.episodeDownloads,
            SharedDataKeys.episodePlayed,
            SharedDataKeys.episodeProgress
        ]
        
        for key in collectionsToCheck {
            if let data = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] {
                for episodeId in data.keys {
                    if episodeId.hasPrefix("test-episode-") {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    /// Clean up test data pollution that causes massive sync operations and performance issues
    private func cleanupTestDataPollution() {
        print("📡 🧹 TEST CLEANUP: Starting comprehensive test data cleanup...")
        var totalRemoved = 0
        
        // Remove test episodes from favorites
        if let favoritesData = ubiquitousStore.object(forKey: SharedDataKeys.episodeFavorites) as? [String: [String: Any]] {
            var cleanedFavorites = favoritesData
            var removedCount = 0
            
            for (episodeId, _) in favoritesData {
                if episodeId.hasPrefix("test-episode-") {
                    cleanedFavorites.removeValue(forKey: episodeId)
                    removedCount += 1
                }
            }
            
            if removedCount > 0 {
                ubiquitousStore.set(cleanedFavorites, forKey: SharedDataKeys.episodeFavorites)
                totalRemoved += removedCount
                print("📡 🧹 TEST CLEANUP: Removed \(removedCount) test episodes from favorites")
            }
        }
        
        // Remove test episodes from downloads
        if let downloadsData = ubiquitousStore.object(forKey: SharedDataKeys.episodeDownloads) as? [String: [String: Any]] {
            var cleanedDownloads = downloadsData
            var removedCount = 0
            
            for (episodeId, _) in downloadsData {
                if episodeId.hasPrefix("test-episode-") {
                    cleanedDownloads.removeValue(forKey: episodeId)
                    removedCount += 1
                }
            }
            
            if removedCount > 0 {
                ubiquitousStore.set(cleanedDownloads, forKey: SharedDataKeys.episodeDownloads)
                totalRemoved += removedCount
                print("📡 🧹 TEST CLEANUP: Removed \(removedCount) test episodes from downloads")
            }
        }
        
        // Remove test episodes from played states
        if let playedData = ubiquitousStore.object(forKey: SharedDataKeys.episodePlayed) as? [String: [String: Any]] {
            var cleanedPlayed = playedData
            var removedCount = 0
            
            for (episodeId, _) in playedData {
                if episodeId.hasPrefix("test-episode-") {
                    cleanedPlayed.removeValue(forKey: episodeId)
                    removedCount += 1
                }
            }
            
            if removedCount > 0 {
                ubiquitousStore.set(cleanedPlayed, forKey: SharedDataKeys.episodePlayed)
                totalRemoved += removedCount
                print("📡 🧹 TEST CLEANUP: Removed \(removedCount) test episodes from played states")
            }
        }
        
        // Remove test episodes from progress data
        if let progressData = ubiquitousStore.object(forKey: SharedDataKeys.episodeProgress) as? [String: [String: Any]] {
            var cleanedProgress = progressData
            var removedCount = 0
            
            for (episodeId, _) in progressData {
                if episodeId.hasPrefix("test-episode-") {
                    cleanedProgress.removeValue(forKey: episodeId)
                    removedCount += 1
                }
            }
            
            if removedCount > 0 {
                ubiquitousStore.set(cleanedProgress, forKey: SharedDataKeys.episodeProgress)
                totalRemoved += removedCount
                print("📡 🧹 TEST CLEANUP: Removed \(removedCount) test episodes from progress data")
            }
        }
        
        // Clean up other test keys
        let testKeys = [
            "test_connectivity",
            "sync_test", 
            "debug_sync"
        ]
        
        for key in testKeys {
            ubiquitousStore.removeObject(forKey: key)
        }
        
        if totalRemoved > 0 {
        // Note: synchronize() is deprecated and unnecessary            print("📡 🧹 TEST CLEANUP: ✅ CRITICAL PERFORMANCE FIX - Removed \(totalRemoved) test episodes that were causing massive sync operations and app hangs!")
        } else {
            print("📡 🧹 TEST CLEANUP: No test data found to clean up")
        }
    }
    
    // MARK: - Shared Collection Management
    
    /// Update episode data in a shared collection
    private func updateEpisodeInSharedCollection(key: String, episodeId: String, data: [String: Any]) {
        var collection = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] ?? [:]
        collection[episodeId] = data
        
        // Trim collection if it gets too large
        if collection.count > maxEntriesPerCollection {
            print("📡 🧹 AUTO-TRIM: Collection \(key) has \(collection.count) entries, auto-trimming")
            
            // Sort by timestamp and keep most recent entries
            let sortedEntries = collection.sorted { entry1, entry2 in
                let timestamp1 = (entry1.value["timestamp"] as? Double) ?? 0
                let timestamp2 = (entry2.value["timestamp"] as? Double) ?? 0
                return timestamp1 > timestamp2
            }
            
            let trimmedArray = Array(sortedEntries.prefix(maxEntriesPerCollection))
            collection = Dictionary(trimmedArray, uniquingKeysWith: { _, second in second })
            print("📡 🧹 AUTO-TRIM: Trimmed to \(collection.count) entries")
        }
        
        ubiquitousStore.set(collection, forKey: key)
    }
    
    /// Get episode data from a shared collection
    private func getEpisodeFromSharedCollection(key: String, episodeId: String) -> [String: Any]? {
        guard let collection = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] else {
            return nil
        }
        return collection[episodeId]
    }
    
    /// Remove episode data from a shared collection
    private func removeEpisodeFromSharedCollection(key: String, episodeId: String) {
        var collection = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] ?? [:]
        collection.removeValue(forKey: episodeId)
        ubiquitousStore.set(collection, forKey: key)
        
        // CRITICAL: Synchronize to ensure deletion is persisted to iCloud immediately
        ubiquitousStore.synchronize()
    }
    
    /// Remove multiple episodes from all shared collections (for feed deletion)
    func removeEpisodesFromSharedCollections(episodeIds: [String], feedId: String) {
        print("📡 🧹 FEED DELETION: Removing \(episodeIds.count) episodes from CloudKit shared collections")
        
        // OPTIMIZED: Load all collections once, modify them, then save once
        var progressCollection = ubiquitousStore.object(forKey: SharedDataKeys.episodeProgress) as? [String: [String: Any]] ?? [:]
        var favoritesCollection = ubiquitousStore.object(forKey: SharedDataKeys.episodeFavorites) as? [String: [String: Any]] ?? [:]
        var downloadsCollection = ubiquitousStore.object(forKey: SharedDataKeys.episodeDownloads) as? [String: [String: Any]] ?? [:]
        var playedCollection = ubiquitousStore.object(forKey: SharedDataKeys.episodePlayed) as? [String: [String: Any]] ?? [:]
        
        print("📡 🧹 BEFORE DELETION: Progress=\(progressCollection.count), Favorites=\(favoritesCollection.count), Downloads=\(downloadsCollection.count), Played=\(playedCollection.count)")
        
        // Remove all episodes from all collections
        var removedFromProgress = 0
        var removedFromFavorites = 0
        var removedFromDownloads = 0
        var removedFromPlayed = 0
        
        for episodeId in episodeIds {
                let qualifiedKey = CloudEpisodeIdentity(episodeId: episodeId, feedId: feedId).storageKey
                if progressCollection.removeValue(forKey: qualifiedKey) != nil { removedFromProgress += 1 }
                if favoritesCollection.removeValue(forKey: qualifiedKey) != nil { removedFromFavorites += 1 }
                if downloadsCollection.removeValue(forKey: qualifiedKey) != nil { removedFromDownloads += 1 }
                if playedCollection.removeValue(forKey: qualifiedKey) != nil { removedFromPlayed += 1 }

                if progressCollection[episodeId]?["feedId"] as? String == feedId,
                    progressCollection.removeValue(forKey: episodeId) != nil { removedFromProgress += 1 }
                if favoritesCollection[episodeId]?["feedId"] as? String == feedId,
                    favoritesCollection.removeValue(forKey: episodeId) != nil { removedFromFavorites += 1 }
                if downloadsCollection[episodeId]?["feedId"] as? String == feedId,
                    downloadsCollection.removeValue(forKey: episodeId) != nil { removedFromDownloads += 1 }
                if playedCollection[episodeId]?["feedId"] as? String == feedId,
                    playedCollection.removeValue(forKey: episodeId) != nil { removedFromPlayed += 1 }
        }
        
        print("📡 🧹 REMOVED: Progress=\(removedFromProgress), Favorites=\(removedFromFavorites), Downloads=\(removedFromDownloads), Played=\(removedFromPlayed)")
        
        // Save all collections at once
        ubiquitousStore.set(progressCollection, forKey: SharedDataKeys.episodeProgress)
        ubiquitousStore.set(favoritesCollection, forKey: SharedDataKeys.episodeFavorites)
        ubiquitousStore.set(downloadsCollection, forKey: SharedDataKeys.episodeDownloads)
        ubiquitousStore.set(playedCollection, forKey: SharedDataKeys.episodePlayed)
        
        // CRITICAL: Synchronize once at the end to persist all deletions to iCloud
        let syncSuccess = ubiquitousStore.synchronize()
        
        print("📡 🧹 AFTER DELETION: Progress=\(progressCollection.count), Favorites=\(favoritesCollection.count), Downloads=\(downloadsCollection.count), Played=\(playedCollection.count)")
        print("📡 ✅ FEED DELETION: Removed \(episodeIds.count) episodes from CloudKit shared collections (sync: \(syncSuccess ? "SUCCESS" : "FAILED"))")
    }
    
    /// Delete episode states from CloudKit database for specific episodes (batch operation)
    func deleteEpisodeStatesFromCloudKit(episodeIds: [String], feedId: String) async {
        print("📡 🗑️ Starting CloudKit database deletion for \(episodeIds.count) episode states")
        
        guard !episodeIds.isEmpty else {
            print("📡 ⚠️ No episode IDs provided for CloudKit deletion")
            return
        }
        
        var recordIDsToDelete: [CKRecord.ID] = []
        
        // Process episodes in batches to avoid query size limits
        let batchSize = 100
        let batches = episodeIds.chunked(into: batchSize)
        
        for (batchIndex, batch) in batches.enumerated() {
            print("📡 🔍 Processing batch \(batchIndex + 1)/\(batches.count): \(batch.count) episodes")
            
            // Query for records matching these episode IDs
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "episodeId IN %@", batch),
                NSPredicate(format: "feedId == %@", feedId)
            ])
            let query = CKQuery(recordType: RecordType.episodeState, predicate: predicate)
            
            do {
                let (matchResults, _) = try await privateDatabase.records(matching: query)
                
                for (recordID, recordResult) in matchResults {
                    switch recordResult {
                    case .success(let record):
                        recordIDsToDelete.append(record.recordID)
                        if let episodeId = record["episodeId"] as? String {
                            print("📡 🗑️ Found episode state to delete: \(episodeId)")
                        }
                    case .failure(let error):
                        print("📡 ⚠️ Failed to process episode state record \(recordID.recordName): \(error.localizedDescription)")
                    }
                }
            } catch {
                print("📡 ❌ Failed to query episode states for batch \(batchIndex + 1): \(error.localizedDescription)")
            }
        }
        
        // Delete the found records in batches
        if !recordIDsToDelete.isEmpty {
            print("📡 🗑️ Deleting \(recordIDsToDelete.count) episode state records from CloudKit")
            do {
                try await deleteRecordsInBatches(recordIDsToDelete)
                print("📡 ✅ Successfully deleted \(recordIDsToDelete.count) episode states from CloudKit database")
            } catch {
                print("📡 ❌ Failed to delete episode states from CloudKit database: \(error.localizedDescription)")
            }
        } else {
            print("📡 📊 No episode state records found in CloudKit database for the provided episodes")
        }
    }
    
    /// Diagnostic method to help troubleshoot account validation issues
    func diagnoseiCloudAccountIssues() {
        print("📡 🔍 DIAGNOSTICS: iCloud Account Validation Status")
        print("📡 " + String(repeating: "=", count: 50))
        
        // Check current account status
        if let currentAccountID = getCurrentiCloudAccountID() {
            print("📡 ✅ Current iCloud account ID: \(currentAccountID.prefix(16))...")
            print("📡 📊 Account ID length: \(currentAccountID.count) characters")
            
            if let token = FileManager.default.ubiquityIdentityToken {
                print("📡 ✅ Ubiquity identity token available")
                print("📡 📊 Token type: \(type(of: token))")
            } else {
                print("📡 ❌ No ubiquity identity token available")
            }
        } else {
            print("📡 ❌ No current iCloud account ID available")
            print("📡 💡 Possible causes:")
            print("📡    - Not signed into iCloud")
            print("📡    - iCloud Drive not enabled")
            print("📡    - CloudKit not available")
        }
        
        // Check pending sync data
        let syncKeys = ["instant_podcast_feed_removed", "instant_podcast_feed_added"]
        for key in syncKeys {
            if let data = ubiquitousStore.object(forKey: key) as? [String: Any] {
                print("📡 📝 Found pending sync data for key: \(key)")
                if let syncAccountID = data["icloud_account_id"] as? String {
                    print("📡 🆔 Sync data account ID: \(syncAccountID.prefix(16))...")
                } else {
                    print("📡 ⚠️ Sync data missing account ID")
                }
            }
        }
        
        print("📡 " + String(repeating: "=", count: 50))
        print("📡 💡 TROUBLESHOOTING TIPS:")
        print("📡    1. Ensure same iCloud account on all devices")
        print("📡    2. Ensure iCloud Drive is enabled")
        print("📡    3. Check Settings > [Your Name] > iCloud > iCloud Drive")
        print("📡    4. Try signing out and back into iCloud if issues persist")
        print("📡    5. Call clearStaleAccountSyncData() to remove old sync data")
    }
    
    /// Clears stale sync data that might be from a different account
    func clearStaleAccountSyncData() {
        print("📡 🧹 Clearing stale account sync data...")
        
        let allSyncKeys = [
            "instant_podcast_feed_removed",
            "instant_podcast_feed_added", 
            "instant_podcast_progress",
            "instant_podcast_episode_favorite",
            "instant_podcast_episode_download",
            "instant_radio_favorite",
            "instant_radio_station_added",
            "instant_radio_station_removed"
        ]
        
        var clearedCount = 0
        for key in allSyncKeys {
            if let data = ubiquitousStore.object(forKey: key) as? [String: Any] {
                if !validateSyncAccount(syncData: data) {
                    print("📡 🗑️ Removing stale sync data for key: \(key)")
                    ubiquitousStore.removeObject(forKey: key)
                    clearedCount += 1
                } else {
                    print("📡 ✅ Keeping valid sync data for key: \(key)")
                }
            }
        }
        
        if clearedCount > 0 {
        // Note: synchronize() is deprecated and unnecessary            print("📡 ✅ Cleared \(clearedCount) stale sync data entries")
        } else {
            print("📡 ✅ No stale sync data found to clear")
        }
    }
    
    // MARK: - CloudKit Push Notifications Setup
    
    /// Set up CloudKit subscriptions for automatic cross-device sync notifications
    private func setupCloudKitSubscriptions() {
        Task {
            await setupPodcastFeedSubscription()
            await setupEpisodeStateSubscription()
            os_log("🔔 CloudKit subscriptions setup completed", log: log, type: .info)
        }
    }
    
    private func setupPodcastFeedSubscription() async {
        let subscriptionID = "PodcastFeedSubscription"
        
        do {
            // Check if subscription already exists
            let existingSubscriptions = try await privateDatabase.allSubscriptions()
            if existingSubscriptions.contains(where: { $0.subscriptionID == subscriptionID }) {
                os_log("✅ PodcastFeed subscription already exists", log: log, type: .info)
                return
            }
            
            // Create new subscription
            let subscription = CKQuerySubscription(
                recordType: RecordType.podcastFeed,
                predicate: NSPredicate(value: true),
                subscriptionID: subscriptionID,
                options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
            )
            
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            notificationInfo.category = "PODCAST_FEED_SYNC"
            subscription.notificationInfo = notificationInfo
            
            _ = try await privateDatabase.save(subscription)
            os_log("✅ CloudKit PodcastFeed subscription created", log: log, type: .info)
        } catch {
            os_log("❌ Failed to create PodcastFeed subscription: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func setupEpisodeStateSubscription() async {
        let subscriptionID = "EpisodeStateSubscription"
        
        do {
            // Check if subscription already exists
            let existingSubscriptions = try await privateDatabase.allSubscriptions()
            if existingSubscriptions.contains(where: { $0.subscriptionID == subscriptionID }) {
                os_log("✅ EpisodeState subscription already exists", log: log, type: .info)
                return
            }
            
            // Create new subscription
            let subscription = CKQuerySubscription(
                recordType: RecordType.episodeState,
                predicate: NSPredicate(value: true),
                subscriptionID: subscriptionID,
                options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
            )
            
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            notificationInfo.category = "EPISODE_STATE_SYNC"
            subscription.notificationInfo = notificationInfo
            
            _ = try await privateDatabase.save(subscription)
            os_log("✅ CloudKit EpisodeState subscription created", log: log, type: .info)
        } catch {
            os_log("❌ Failed to create EpisodeState subscription: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    /// Handle CloudKit push notifications for cross-device sync
    func handleCloudKitSubscriptionNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("❌ Invalid CloudKit notification", log: log, type: .error)
            return
        }
        
        os_log("🔔 Received CloudKit notification: %@", log: log, type: .info, String(describing: notification.notificationType))
        
        switch notification.notificationType {
        case .query:
            await handleQueryNotification(notification as! CKQueryNotification)
        case .database:
            await handleDatabaseNotification(notification as! CKDatabaseNotification)
        default:
            os_log("🔔 Unhandled CloudKit notification type: %@", log: log, type: .info, String(describing: notification.notificationType))
        }
    }
    
    private func handleQueryNotification(_ notification: CKQueryNotification) async {
        guard let recordID = notification.recordID else {
            os_log("❌ Query notification missing recordID", log: log, type: .error)
            return
        }
        
        os_log("🔔 Handling query notification for record: %@", log: log, type: .info, recordID.recordName)
        
        // **FIX**: Use subscription ID to determine record type instead of unreliable record name patterns
        let recordType: String
        if let subscriptionID = notification.subscriptionID {
            os_log("🔔 Notification from subscription: %@", log: log, type: .info, subscriptionID)
            switch subscriptionID {
            case "PodcastFeedSubscription":
                recordType = RecordType.podcastFeed
            case "EpisodeStateSubscription":
                recordType = RecordType.episodeState
            case "RadioStationSubscription":
                // This is a radio station notification - ignore it gracefully as it should be handled by RadioStationCloudKitManager
                os_log("📻 Ignoring radio station notification in PodcastCloudKitManager (handled by RadioStationCloudKitManager)", log: log, type: .debug)
                return
            default:
                os_log("⚠️ Unknown subscription ID: %@", log: log, type: .debug, subscriptionID)
                recordType = "Unknown"
            }
        } else {
            // Fallback to old pattern matching if subscription ID is not available
            os_log("⚠️ No subscription ID in notification, falling back to record name pattern matching", log: log, type: .debug)
            if recordID.recordName.contains("Episode") || recordID.recordName.hasPrefix("ES_") {
                recordType = RecordType.episodeState
            } else if recordID.recordName.contains("Feed") || recordID.recordName.hasPrefix("PF_") {
                recordType = RecordType.podcastFeed
            } else {
                recordType = "Unknown"
            }
        }
        
        os_log("🔔 Determined record type: %@", log: log, type: .info, recordType)
        
        switch recordType {
        case RecordType.podcastFeed:
            await handlePodcastFeedChange(recordID: recordID, changeType: notification.queryNotificationReason)
        case RecordType.episodeState:
            await handleEpisodeStateChange(recordID: recordID, changeType: notification.queryNotificationReason)
        default:
            os_log("❌ Unknown record type in notification: %@", log: log, type: .error, recordType)
        }
    }
    
    private func handleDatabaseNotification(_ notification: CKDatabaseNotification) async {
        os_log("🔔 Handling database notification - triggering full sync", log: log, type: .info)
        // Trigger a full sync from CloudKit
        do {
            let feeds = try await syncFromCloudKit()
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .init("CloudKitDidUpdateAllFeeds"),
                    object: nil,
                    userInfo: ["feeds": feeds]
                )
            }
        } catch {
            os_log("❌ Failed to perform full sync after database notification: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func handlePodcastFeedChange(recordID: CKRecord.ID, changeType: CKQueryNotification.Reason) async {
        switch changeType {
        case .recordCreated, .recordUpdated:
            await syncPodcastFeedFromCloudKit(recordID: recordID)
        case .recordDeleted:
            await handlePodcastFeedDeletion(recordID: recordID)
        @unknown default:
            os_log("Unknown podcast feed change type", log: log, type: .debug)
        }
    }
    
    private func handleEpisodeStateChange(recordID: CKRecord.ID, changeType: CKQueryNotification.Reason) async {
        switch changeType {
        case .recordCreated, .recordUpdated:
            await syncEpisodeStateFromCloudKit(recordID: recordID)
        case .recordDeleted:
            await handleEpisodeStateDeletion(recordID: recordID)
        @unknown default:
            os_log("Unknown episode state change type", log: log, type: .debug)
        }
    }
    
    private func syncPodcastFeedFromCloudKit(recordID: CKRecord.ID) async {
        do {
            let record = try await privateDatabase.record(for: recordID)
            if let feed = try await self.parsePodcastFeedRecord(record) {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .init("CloudKitDidAddPodcastFeed"),
                        object: nil,
                        userInfo: ["feed": feed]
                    )
                }
                os_log("✅ Synced podcast feed from CloudKit: %@", log: log, type: .info, feed.title)
            }
        } catch {
            os_log("❌ Failed to sync podcast feed %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
        }
    }
    
    private func syncEpisodeStateFromCloudKit(recordID: CKRecord.ID) async {
        do {
            let record = try await privateDatabase.record(for: recordID)
            guard let episodeId = record["episodeId"] as? String else { return }
            
            let progress = record["progress"] as? Double ?? 0.0
            let isFavorite = record["isFavorite"] as? Bool ?? false
            let isDownloaded = record["isDownloaded"] as? Bool ?? false
            let isPlayed = record["isPlayed"] as? Bool ?? false
            let feedId = record["feedId"] as? String

            try await episodeManager.updateEpisodeStates([
                EpisodeStateUpdate(
                    episodeId: episodeId,
                    feedId: feedId,
                    progress: progress,
                    isFavorite: isFavorite,
                    isDownloaded: isDownloaded,
                    isPlayed: isPlayed
                )
            ])
            
            EpisodeStateManager.shared.applyStateSilently(
                for: episodeId,
                progress: progress,
                isFavorite: isFavorite,
                isDownloaded: isDownloaded,
                isPlayed: isPlayed,
                feedId: feedId,
                persistImmediately: false
            )
            
            await MainActor.run {
                var userInfo: [String: Any] = [
                    "episodeId": episodeId,
                    "progress": progress,
                    "isFavorite": isFavorite,
                    "isDownloaded": isDownloaded,
                    "isPlayed": isPlayed
                ]
                if let feedId {
                    userInfo["feedId"] = feedId
                }
                NotificationCenter.default.post(
                    name: .init("CloudKitDidUpdateEpisodeState"),
                    object: nil,
                    userInfo: userInfo
                )
            }
            
            os_log("✅ Synced episode state from CloudKit: %@", log: log, type: .info, episodeId)
        } catch {
            os_log("❌ Failed to sync episode state %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
        }
    }

    private func handlePodcastFeedDeletion(recordID: CKRecord.ID) async {
        os_log("🗑️ CloudKit: Handling podcast feed deletion for record: %@", log: log, type: .info, recordID.recordName)
        
        await MainActor.run {
            // Post the CloudKit deletion notification
            NotificationCenter.default.post(
                name: .init("CloudKitDidDeletePodcastFeed"),
                object: nil,
                userInfo: ["feedId": recordID.recordName]
            )
            
            // Also post the instant sync notification for cross-device compatibility
            NotificationCenter.default.post(
                name: .init("InstantSyncDidRemovePodcastFeed"),
                object: nil,
                userInfo: [
                    "feedId": recordID.recordName,
                    "feedTitle": "Deleted Feed", // We don't have the title from CloudKit deletion
                    "episodeIds": [], // Will be populated by the handler
                    "actionId": "cloudkit-realtime-\(Date().timeIntervalSince1970)"
                ]
            )
        }
        
        os_log("✅ Posted cross-device sync notifications for feed deletion: %@", log: log, type: .info, recordID.recordName)
    }
    
    private func handleEpisodeStateDeletion(recordID: CKRecord.ID) async {
        // Query deletion notifications provide only the record ID. Neither legacy raw IDs nor
        // hashed v2 IDs safely identify a feed-owned local row, so reconciliation handles this.
        os_log("ℹ️ Episode state deleted; waiting for feed-aware reconciliation: %@", log: log, type: .info, recordID.recordName)
    }
    
    @objc private func ubiquitousKeyValueStoreDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }
        
        guard let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        
        // FRESH INSTALL GUARD: Skip episode state sync logging on fresh installs
        // Check if we have any local feeds before processing episode state changes
        let context = CoreDataStack.shared.newBackgroundContext()
        let feedCountRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedCountRequest.fetchLimit = 1
        
        var hasFeedsLocally = false
        do {
            let feedCount = try context.count(for: feedCountRequest)
            hasFeedsLocally = feedCount > 0
        } catch {
            // If we can't determine, assume we might have feeds
            hasFeedsLocally = true
        }
        
        // Only log sync activity if we have local feeds or if it's a feed-related sync
        let feedRelatedKeys = keys.filter { $0.hasPrefix("instant_podcast_feed") }
        if hasFeedsLocally || !feedRelatedKeys.isEmpty {
            print("📡 🔔 CloudKit sync: \(keys.count) key(s) changed")
        }
        
        // Use background queue for sync processing to prevent main thread blocking
        DispatchQueue.global(qos: .userInitiated).async {
            let syncDate = Date()
            
            // Filter out radio-related keys early to prevent processing conflicts
            let podcastKeys = keys.filter { key in
                key.hasPrefix("instant_podcast_") || 
                key.hasPrefix("StreamRadios_Episode") ||
                key == SharedDataKeys.episodeProgress ||
                key == SharedDataKeys.episodeFavorites ||
                key == SharedDataKeys.episodeDownloads ||
                key == SharedDataKeys.episodePlayed
            }
            
            // Only process if we have podcast-related keys
            guard !podcastKeys.isEmpty else {
                return // Silently ignore radio-only notifications
            }
            
            for key in podcastKeys {
                // Handle shared collection keys for episode data
                if key == SharedDataKeys.episodeProgress {
                    if hasFeedsLocally {
                        print("📡 🔔 Processing shared episode progress collection sync")
                    }
                    self.handleSharedCollectionSync(key: key, dataType: "progress")
                } else if key == SharedDataKeys.episodeFavorites {
                    if hasFeedsLocally {
                        print("📡 🔔 Processing shared episode favorites collection sync")
                    }
                    self.handleSharedCollectionSync(key: key, dataType: "favorites")
                } else if key == SharedDataKeys.episodeDownloads {
                    if hasFeedsLocally {
                        print("📡 🔔 Processing shared episode downloads collection sync")
                    }
                    self.handleSharedCollectionSync(key: key, dataType: "downloads")
                } else if key == SharedDataKeys.episodePlayed {
                    if hasFeedsLocally {
                        print("📡 🔔 Processing shared episode played collection sync")
                    }
                    self.handleSharedCollectionSync(key: key, dataType: "played")
                } else if key.hasPrefix("instant_podcast_progress_") ||
                          key.hasPrefix("instant_podcast_favorite_") ||
                          key.hasPrefix("instant_podcast_download_") ||
                          key.hasPrefix("instant_podcast_played_") {
                    // Legacy unique episode keys - silently ignore (will be cleaned up)
                } else if key.hasPrefix("StreamRadios_Episode") {
                    // Individual episode state keys are handled by shared collection sync - silently skip
                } else {
                    // Handle legacy global keys and other types
                    switch key {
                    case "instant_podcast_progress":
                        print("📡 🔔 Processing legacy instant podcast progress sync")
                        Task { @MainActor in self.handleInstantPodcastProgressSync() }
                    case "instant_podcast_feed_added":
                        print("📡 🔔 Processing instant podcast feed added sync")
                        Task { @MainActor in self.handleInstantPodcastFeedAddedSync() }
                    case "instant_podcast_feed_progress":
                        print("📡 🔔 Processing instant podcast feed progress sync")
                        Task { @MainActor in self.handleInstantPodcastFeedProgressSync() }
                    case "instant_podcast_feed_removed":
                        print("📡 🔔 CRITICAL: Processing instant podcast feed DELETION sync")
                        Task { @MainActor in self.handleInstantPodcastFeedRemovedSync() }
                    case "instant_podcast_episode_favorite":
                        print("📡 🔔 LEGACY FAVORITE SYNC: Processing old format favorite sync")
                        Task { @MainActor in self.handleInstantPodcastFavoriteSync() }
                    case "instant_podcast_episode_download":
                        print("📡 🔔 LEGACY DOWNLOAD SYNC: Processing old format download sync")
                        Task { @MainActor in self.handleInstantPodcastDownloadSync() }
                    default:
                        // Silently ignore unknown podcast keys to prevent log spam
                        break
                    }
                }
            }
            
            // Update sync date on main actor
            Task { @MainActor in
                self.lastInstantSyncDate = syncDate
            }
        }
    }
    
    // MARK: - Shared Collection Sync Handlers
    
    /// Handle sync for shared collections
    private func handleSharedCollectionSync(key: String, dataType: String) {
        // FRESH INSTALL GUARD: Skip episode state sync if there are no feeds
        // This prevents loading orphaned episode states from other devices on fresh installs
        let context = CoreDataStack.shared.newBackgroundContext()
        let feedCountRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedCountRequest.fetchLimit = 1
        
        do {
            let feedCount = try context.count(for: feedCountRequest)
            if feedCount == 0 {
                return // Silently skip - no feeds, so no need to sync episode states
            }
        } catch {
            // Continue if we can't determine feed count
        }
        
        guard let collection = ubiquitousStore.object(forKey: key) as? [String: [String: Any]] else {
            return
        }
        
        var processedCount = 0
        var skippedCount = 0
        
        // Process each episode in the collection
        for (_, episodeData) in collection {
            // Validate iCloud account to prevent cross-account contamination
            if !validateSyncAccount(syncData: episodeData) {
                skippedCount += 1
                continue
            }
            guard let episodeId = episodeData["episodeId"] as? String else {
                skippedCount += 1
                continue
            }
            processedCount += 1
            
            switch dataType {
            case "progress":
                if let progress = episodeData["progress"] as? Double {
                    processProgressDataFromSharedCollection(episodeData, expectedEpisodeId: episodeId)
                }
            case "favorites":
                if let isFavorite = episodeData["isFavorite"] as? Bool {
                    processFavoriteData(episodeData, expectedEpisodeId: episodeId)
                }
            case "downloads":
                if let isDownloaded = episodeData["isDownloaded"] as? Bool {
                    processDownloadData(episodeData, expectedEpisodeId: episodeId)
                }
            case "played":
                if let isPlayed = episodeData["isPlayed"] as? Bool {
                    processPlayedData(episodeData, expectedEpisodeId: episodeId)
                }
            default:
                break
            }
        }
        
        // Only log summary if there's something meaningful to report
        if processedCount > 0 || skippedCount > 5 {
            print("📡 📊 SYNC SUMMARY: Processed \(processedCount) \(dataType) updates, skipped \(skippedCount) cross-account items")
        }
    }
    
    /// Process progress data from shared collection
    private func processProgressDataFromSharedCollection(_ episodeData: [String: Any], expectedEpisodeId: String) {
        guard let progress = episodeData["progress"] as? Double,
              let timestamp = episodeData["timestamp"] as? Double else {
            return
        }
        
        self.processProgressSync(
            episodeId: expectedEpisodeId,
            feedId: episodeData["feedId"] as? String,
            progress: progress,
            timestamp: timestamp
        )
    }
    
    // New unique-key handler for progress sync
    private func handleInstantPodcastProgressSync(for episodeId: String, uniqueKey: String) {
        guard let progressData = ubiquitousStore.object(forKey: uniqueKey) as? [String: Any],
              let progress = progressData["progress"] as? Double,
              let timestamp = progressData["timestamp"] as? Double else {
            return
        }
        
        // Validate account to prevent cross-account contamination
        if !validateSyncAccount(syncData: progressData) {
            return
        }
        
        self.processProgressSync(
            episodeId: episodeId,
            feedId: progressData["feedId"] as? String,
            progress: progress,
            timestamp: timestamp
        )
    }
    
    // Legacy handler for backward compatibility  
    private func handleInstantPodcastProgressSync() {
        guard let progressData = ubiquitousStore.object(forKey: "instant_podcast_progress") as? [String: Any],
              let episodeId = progressData["episodeId"] as? String,
              let progress = progressData["progress"] as? Double,
              let timestamp = progressData["timestamp"] as? Double else {
            return
        }
        
        self.processProgressSync(
            episodeId: episodeId,
            feedId: progressData["feedId"] as? String,
            progress: progress,
            timestamp: timestamp
        )
    }
    
    // Common progress processing logic
    private func processProgressSync(episodeId: String, feedId: String? = nil, progress: Double, timestamp: Double) {
        // Check if this is a newer update than what we have locally
        let currentTime = Date().timeIntervalSince1970
        if currentTime - timestamp > 30 { // Ignore updates older than 30 seconds
            return
        }
        
        // Get current local progress to avoid unnecessary updates
        let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: feedId)
        
        // HIGHEST PROGRESS SYNC: Compare CloudKit vs local and propagate highest to all devices
        if progress < currentProgress {
            // Propagate the higher local progress back to CloudKit for all devices
            Task.detached(priority: .userInitiated) {
                await self.syncPodcastProgressInstantly(episodeId: episodeId, feedId: feedId, progress: currentProgress)
            }
            return
        }
        
        let progressDiff = abs(progress - currentProgress)
        
        // Only update if there's a meaningful difference (> 1% or significant time change)
        if progressDiff < 0.01 {
            return
        }
        
        // Update local episode state immediately SILENTLY (this will trigger UI updates but not CloudKit sync)
        EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: progress, feedId: feedId)
        
        os_log("📡 ✅ Received instant podcast progress sync: %@ (%.2f)", log: log, type: .info, episodeId, progress)
        
        // CRITICAL: Update active player if this episode is currently playing
        DispatchQueue.main.async {
            var userInfo: [String: Any] = [
                "episodeId": episodeId,
                "progress": progress,
                "timestamp": timestamp,
                "source": "remote_device"
            ]
            if let feedId {
                userInfo["feedId"] = feedId
            }
            NotificationCenter.default.post(
                name: .init("CrossDeviceProgressUpdate"),
                object: nil,
                userInfo: userInfo
            )
            
            // Also notify UI components for immediate visual updates
            NotificationCenter.default.post(
                name: .init("InstantSyncDidUpdatePodcastProgress"),
                object: nil,
                userInfo: userInfo
            )
        }
    }
    
    private func handleInstantRadioFavoriteSync() {
        guard let favoriteData = ubiquitousStore.object(forKey: "instant_radio_favorite") as? [String: Any],
              let stationId = favoriteData["stationId"] as? String,
              let isFavorite = favoriteData["isFavorite"] as? Bool else {
            return
        }
        
        os_log("📡 Received instant radio favorite sync: %@ (favorite: %@)", log: log, type: .info, stationId, isFavorite ? "YES" : "NO")
        
        // Notify RadioStationViewModel to update the station
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdateRadioFavorite"),
            object: nil,
            userInfo: ["stationId": stationId, "isFavorite": isFavorite]
        )
    }
    
    private func handleInstantRadioStationAddedSync() {
        guard let stationData = ubiquitousStore.object(forKey: "instant_radio_station_added") as? [String: Any],
              let station = stationData["station"] as? [String: Any] else {
            return
        }
        
        os_log("📡 Received instant radio station addition sync", log: log, type: .info)
        
        // Notify RadioStationViewModel to add the station
        NotificationCenter.default.post(
            name: .init("InstantSyncDidAddRadioStation"),
            object: nil,
            userInfo: ["station": station]
        )
    }
    
    private func handleInstantRadioStationRemovedSync() {
        guard let removalData = ubiquitousStore.object(forKey: "instant_radio_station_removed") as? [String: Any],
              let stationId = removalData["stationId"] as? String,
              let stationName = removalData["stationName"] as? String else {
            return
        }
        
        os_log("📡 Received instant radio station removal sync: %@ (%@)", log: log, type: .info, stationName, stationId)
        
        // Notify RadioStationViewModel to remove the station
        NotificationCenter.default.post(
            name: .init("InstantSyncDidRemoveRadioStation"),
            object: nil,
            userInfo: ["stationId": stationId, "stationName": stationName]
        )
    }
    
    private func handleInstantPodcastFeedAddedSync() {
        guard let podcastData = ubiquitousStore.object(forKey: "instant_podcast_feed_added") as? [String: Any],
              let feed = podcastData["feed"] as? [String: Any] else {
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: podcastData) {
            return
        }
        
        os_log("📡 Received instant podcast feed addition sync", log: log, type: .info)
        
        // Notify PodcastViewModel to add the feed
        NotificationCenter.default.post(
            name: .init("InstantSyncDidAddPodcastFeed"),
            object: nil,
            userInfo: ["feed": feed]
        )
    }
    
    private func handleInstantPodcastFeedProgressSync() {
        // FRESH INSTALL GUARD: Skip feed progress sync if there are no feeds
        let context = CoreDataStack.shared.newBackgroundContext()
        let feedCountRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedCountRequest.fetchLimit = 1
        
        do {
            let feedCount = try context.count(for: feedCountRequest)
            if feedCount == 0 {
                return // Silently skip - no feeds to sync progress for
            }
        } catch {
            // Continue if we can't determine feed count
        }
        
        guard let progressData = ubiquitousStore.object(forKey: "instant_podcast_feed_progress") as? [String: Any] else {
            print("📡 ⚠️ No progress data found for instant_podcast_feed_progress")
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: progressData) {
            return
        }
        
        guard let feedId = progressData["feedId"] as? String,
              let progress = progressData["progress"] as? Double,
              let message = progressData["message"] as? String,
              let feedTitle = progressData["feedTitle"] as? String else {
            print("📡 ❌ Invalid progress data format")
            return
        }
        
        os_log("📡 📊 Received feed progress update: %@ - %.1f%% - %@", log: log, type: .info, feedTitle, progress * 100, message)
        print("📡 📊 REAL-TIME PROGRESS: \(feedTitle) - \(Int(progress * 100))% - \(message)")
        
        // Update DataSyncManager with cross-device progress
        DispatchQueue.main.async {
            DataSyncManager.shared.updateCrossDeviceFeedProgress(
                feedId: feedId,
                feedTitle: feedTitle,
                progress: progress,
                message: message
            )
        }
    }
    
    private func handleInstantPodcastFeedRemovedSync() {
        // FRESH INSTALL GUARD: Skip feed deletion sync if there are no feeds
        // This prevents logging deletion notifications from other devices when nothing local exists
        let context = CoreDataStack.shared.newBackgroundContext()
        let feedCountRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        feedCountRequest.fetchLimit = 1
        
        do {
            let feedCount = try context.count(for: feedCountRequest)
            if feedCount == 0 {
                return // Silently skip - no feeds to delete
            }
        } catch {
            // Continue if we can't determine feed count
        }
        
        print("📡 🔄 FEED DELETION RECEIVE: Handling incoming feed removal sync")
        
        guard let removalData = ubiquitousStore.object(forKey: "instant_podcast_feed_removed") as? [String: Any] else {
            os_log("📡 SYNC RECEIVE FAILED: No data found for instant_podcast_feed_removed", log: log, type: .error)
            print("📡 SYNC RECEIVE FAILED: No data found for instant_podcast_feed_removed")
            
            // Debug: Check what keys are actually available
            let allKeys = Array(ubiquitousStore.dictionaryRepresentation.keys)
            print("📡 🔍 DEBUG: Available NSUbiquitousKeyValueStore keys: \(allKeys)")
            return
        }
        
        print("📡 📝 Raw removal data: \(removalData)")
        
        // Enhanced debugging for account validation
        print("📡 🆔 Checking account validation...")
        if let syncAccountID = removalData["icloud_account_id"] as? String {
            print("📡 🆔 Sync data contains account ID: \(String(syncAccountID.prefix(16)))...")
        } else {
            print("📡 ⚠️ Sync data missing icloud_account_id field")
        }
        
        if let currentAccountID = getCurrentiCloudAccountID() {
            print("📡 🆔 Current device account ID: \(String(currentAccountID.prefix(16)))...")
        } else {
            print("📡 ❌ Cannot get current device account ID")
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: removalData) {
            print("📡 ❌ Account validation failed - aborting cross-device deletion")
            return
        } else {
            print("📡 ✅ Account validation passed")
        }
        
        guard let feedId = removalData["feedId"] as? String,
              let feedTitle = removalData["feedTitle"] as? String else {
            os_log("📡 SYNC RECEIVE FAILED: Invalid podcast feed removal data", log: log, type: .error)
            print("📡 SYNC RECEIVE FAILED: Invalid podcast feed removal data")
            print("📡 📝 Missing feedId or feedTitle in data: \(removalData)")
            return
        }
        
        let episodeIds = removalData["episodeIds"] as? [String] ?? []
        let actionId = removalData["actionId"] as? String ?? "unknown"
        
        // Enhanced validation and logging
        let operationType = removalData["operation_type"] as? String ?? "legacy"
        
        os_log("📡 SYNC RECEIVED: Feed removal %@ (%@) with %d episodes, actionId: %@, operation: %@", log: log, type: .info, feedTitle, feedId, episodeIds.count, actionId, operationType)
        print("📡 🎯 COMPREHENSIVE SYNC RECEIVED: Feed removal '\(feedTitle)' (\(feedId)) with \(episodeIds.count) episodes")
        print("📡 🆔 Action ID: \(actionId)")
        print("📡 🔧 Operation type: \(operationType)")
        print("📡 🚨 CRITICAL: Processing deletion to ensure comprehensive CoreData cleanup")
        
        // Notify PodcastViewModel to remove the feed and clean up episodes comprehensively
        NotificationCenter.default.post(
            name: .init("InstantSyncDidRemovePodcastFeed"),
            object: nil,
            userInfo: [
                "feedId": feedId, 
                "feedTitle": feedTitle, 
                "episodeIds": episodeIds, 
                "actionId": actionId,
                "operation_type": operationType,
                "sync_timestamp": Date().timeIntervalSince1970
            ]
        )
        
        print("📡 📨 Posted enhanced InstantSyncDidRemovePodcastFeed notification")
        print("📡 🔄 This will trigger comprehensive CoreData cleanup on receiving device")
    }
    
    // New unique-key handler for favorite sync
    private func handleInstantPodcastFavoriteSync(for episodeId: String, uniqueKey: String) {
        
        // Try to read data with retry mechanism to handle iCloud KV Store timing issues
        attemptToReadFavoriteData(for: episodeId, uniqueKey: uniqueKey, attempt: 1, maxAttempts: 3)
    }
    
    // Legacy handler for backward compatibility
    private func handleInstantPodcastFavoriteSync() {
        print("📡 🔔 LEGACY FAVORITE SYNC HANDLER: Starting legacy podcast favorite sync processing...")
        
        // Try to read data with retry mechanism to handle iCloud KV Store timing issues
        attemptToReadFavoriteData(attempt: 1, maxAttempts: 3)
    }
    
    // New unique-key retry method
    private func attemptToReadFavoriteData(for episodeId: String, uniqueKey: String, attempt: Int, maxAttempts: Int) {
        print("📡 🔄 FAVORITE SYNC ATTEMPT \(attempt)/\(maxAttempts): Trying to read data from '\(uniqueKey)'...")
        
        guard let favoriteData = ubiquitousStore.object(forKey: uniqueKey) as? [String: Any] else {
            if attempt < maxAttempts {
                print("📡 ⏳ FAVORITE SYNC RETRY: Data not ready, retrying in 0.5 seconds...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptToReadFavoriteData(for: episodeId, uniqueKey: uniqueKey, attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                return
            } else {
                print("📡 ❌ FAVORITE SYNC FAILED: No data found for \(uniqueKey) after \(maxAttempts) attempts")
                return
            }
        }
                
        // Process the favorite data
        processFavoriteData(favoriteData, expectedEpisodeId: episodeId)
    }
    
    // Legacy retry method for backward compatibility
    private func attemptToReadFavoriteData(attempt: Int, maxAttempts: Int) {
        print("📡 🔄 LEGACY FAVORITE SYNC ATTEMPT \(attempt)/\(maxAttempts): Trying to read legacy data...")
        
        guard let favoriteData = ubiquitousStore.object(forKey: "instant_podcast_episode_favorite") as? [String: Any] else {
            if attempt < maxAttempts {
                print("📡 ⏳ FAVORITE SYNC RETRY: Data not ready, retrying in 0.5 seconds...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptToReadFavoriteData(attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                return
            } else {
                print("📡 ❌ FAVORITE SYNC FAILED: No data found for instant_podcast_episode_favorite after \(maxAttempts) attempts")
                return
            }
        }
                
        // Process the favorite data
        processFavoriteData(favoriteData)
    }
    
    // Updated processFavoriteData with optional episode ID validation
    private func processFavoriteData(_ favoriteData: [String: Any], expectedEpisodeId: String? = nil) {
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: favoriteData) {
            print("📡 ❌ FAVORITE SYNC BLOCKED: Cross-account sync validation failed")
            return
        }
        
        guard let episodeId = favoriteData["episodeId"] as? String,
              let isFavorite = favoriteData["isFavorite"] as? Bool else {
            print("📡 ❌ FAVORITE SYNC FAILED: Missing episodeId or isFavorite in data")
            return
        }
        
        // Validate episode ID matches expected (for unique key sync)
        if let expected = expectedEpisodeId, episodeId != expected {
            print("📡 ❌ FAVORITE SYNC FAILED: Episode ID mismatch - expected: \(expected), got: \(episodeId)")
            return
        }
        
        // Notify PodcastViewModel to update the episode favorite status
        var userInfo: [String: Any] = ["episodeId": episodeId, "isFavorite": isFavorite]
        if let feedId = favoriteData["feedId"] as? String {
            userInfo["feedId"] = feedId
        }
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastFavorite"),
            object: nil,
            userInfo: userInfo
        )
    }
    
    // New unique-key handler for download sync
    private func handleInstantPodcastDownloadSync(for episodeId: String, uniqueKey: String) {
        
        // Try to read data with retry mechanism to handle iCloud KV Store timing issues
        attemptToReadDownloadData(for: episodeId, uniqueKey: uniqueKey, attempt: 1, maxAttempts: 3)
    }
    
    // New unique-key handler for played sync
    private func handleInstantPodcastPlayedSync(for episodeId: String, uniqueKey: String) {
        
        // Try to read data with retry mechanism to handle iCloud KV Store timing issues
        attemptToReadPlayedData(for: episodeId, uniqueKey: uniqueKey, attempt: 1, maxAttempts: 3)
    }
    
    // Legacy handler for backward compatibility
    private func handleInstantPodcastDownloadSync() {
        
        // Try to read data with retry mechanism to handle iCloud KV Store timing issues
        attemptToReadDownloadData(attempt: 1, maxAttempts: 3)
    }
    
    // New unique-key retry method for downloads
    private func attemptToReadDownloadData(for episodeId: String, uniqueKey: String, attempt: Int, maxAttempts: Int) {
        
        guard let downloadData = ubiquitousStore.object(forKey: uniqueKey) as? [String: Any] else {
            if attempt < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptToReadDownloadData(for: episodeId, uniqueKey: uniqueKey, attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                return
            } else {
                return
            }
        }
        
        
        // Process the download data
        processDownloadData(downloadData, expectedEpisodeId: episodeId)
    }
    
    // Legacy retry method for backward compatibility
    private func attemptToReadDownloadData(attempt: Int, maxAttempts: Int) {
        
        guard let downloadData = ubiquitousStore.object(forKey: "instant_podcast_episode_download") as? [String: Any] else {
            if attempt < maxAttempts {
                print("📡 ⏳ DOWNLOAD SYNC RETRY: Data not ready, retrying in 0.5 seconds...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptToReadDownloadData(attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                return
            } else {
                return
            }
        }
        
        print("📡 🔔 DOWNLOAD SYNC DATA: Raw data received: \(downloadData)")
        
        // Process the download data
        processDownloadData(downloadData)
    }
    
    // New unique-key retry method for played sync
    private func attemptToReadPlayedData(for episodeId: String, uniqueKey: String, attempt: Int, maxAttempts: Int) {
        
        guard let playedData = ubiquitousStore.object(forKey: uniqueKey) as? [String: Any] else {
            if attempt < maxAttempts {
                print("📡 ⏳ PLAYED SYNC RETRY: Data not ready, retrying in 0.5 seconds...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptToReadPlayedData(for: episodeId, uniqueKey: uniqueKey, attempt: attempt + 1, maxAttempts: maxAttempts)
                }
                return
            } else {
                print("📡 ❌ PLAYED SYNC FAILED: No data found for key '\(uniqueKey)' after \(maxAttempts) attempts")
                return
            }
        }
        
        print("📡 🔔 PLAYED SYNC DATA: Raw data received: \(playedData)")
        
        // Process the played data
        processPlayedData(playedData, expectedEpisodeId: episodeId)
    }
    
    // Updated processDownloadData with optional episode ID validation
    private func processDownloadData(_ downloadData: [String: Any], expectedEpisodeId: String? = nil) {
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: downloadData) {
            print("📡 ❌ DOWNLOAD SYNC REJECTED: Invalid iCloud account")
            return
        }
        
        guard let episodeId = downloadData["episodeId"] as? String,
              let isDownloaded = downloadData["isDownloaded"] as? Bool else {
            print("📡 ❌ DOWNLOAD SYNC FAILED: Missing required data fields")
            return
        }
        
        // Validate episode ID matches expected (for unique key sync)
        if let expected = expectedEpisodeId, episodeId != expected {
            print("📡 ❌ DOWNLOAD SYNC FAILED: Episode ID mismatch - expected: \(expected), got: \(episodeId)")
            return
        }
        
        // Notify PodcastViewModel to update the episode download status
        print("📡 🔔 DOWNLOAD SYNC NOTIFICATION: Sending InstantSyncDidUpdatePodcastDownload notification...")
        var userInfo: [String: Any] = ["episodeId": episodeId, "isDownloaded": isDownloaded]
        if let feedId = downloadData["feedId"] as? String {
            userInfo["feedId"] = feedId
        }
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastDownload"),
            object: nil,
            userInfo: userInfo
        )
        print("📡 ✅ DOWNLOAD SYNC NOTIFICATION SENT: Notification posted successfully")
    }
    
    // Process played data with optional episode ID validation
    private func processPlayedData(_ playedData: [String: Any], expectedEpisodeId: String? = nil) {
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: playedData) {
            print("📡 ❌ PLAYED SYNC REJECTED: Invalid iCloud account")
            return
        }
        
        guard let episodeId = playedData["episodeId"] as? String,
              let isPlayed = playedData["isPlayed"] as? Bool else {
            print("📡 ❌ PLAYED SYNC FAILED: Missing required data fields")
            return
        }
        
        // Validate episode ID matches expected (for unique key sync)
        if let expected = expectedEpisodeId, episodeId != expected {
            print("📡 ❌ PLAYED SYNC FAILED: Episode ID mismatch - expected: \(expected), got: \(episodeId)")
            return
        }
        
        print("📡 🔔 PLAYED SYNC VALID: Episode \(episodeId) played \(isPlayed)")
        
        os_log("📡 Received instant podcast played sync: %@ (played: %@)", log: log, type: .info, episodeId, isPlayed ? "YES" : "NO")
        
        // Notify PodcastViewModel to update the episode played status
        print("📡 🔔 PLAYED SYNC NOTIFICATION: Sending InstantSyncDidUpdatePodcastPlayed notification...")
        var userInfo: [String: Any] = ["episodeId": episodeId, "isPlayed": isPlayed]
        if let feedId = playedData["feedId"] as? String {
            userInfo["feedId"] = feedId
        }
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastPlayed"),
            object: nil,
            userInfo: userInfo
        )
        print("📡 ✅ PLAYED SYNC NOTIFICATION SENT: Notification posted successfully")
    }
    
    // MARK: - Public Instant Sync Methods
    
    /// Instantly sync podcast progress across devices with enhanced validation
    func syncPodcastProgressInstantly(episodeId: String, feedId explicitFeedId: String? = nil, progress: Double, persistToCloudKit: Bool = true) {
        // Validate inputs
        guard !episodeId.isEmpty, progress >= 0, progress <= 1.0 else {
            print("📡 ❌ SYNC REJECTED: Invalid progress data - Episode: '\(episodeId)', Progress: \(progress)")
            return
        }
        
        // Get account ID for validation
        guard let accountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ SYNC REJECTED: No iCloud account available")
            return
        }
        
        // Check if we're already syncing this exact progress to avoid loops
        let sharedKey = explicitFeedId.map { CloudEpisodeIdentity(episodeId: episodeId, feedId: $0).storageKey } ?? episodeId
        if let existingProgress = getEpisodeFromSharedCollection(key: SharedDataKeys.episodeProgress, episodeId: sharedKey),
           let existingProgressValue = existingProgress["progress"] as? Double,
           abs(existingProgressValue - progress) < 0.001 {
            print("📡 📊 SYNC SKIP: Already synced this exact progress for \(episodeId)")
            return
        }
        
        let timestamp = Date().timeIntervalSince1970
        var progressData: [String: Any] = [
            "episodeId": episodeId,
            "progress": progress,
            "timestamp": timestamp,
            "icloud_account_id": accountID,
            "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        ]
        if let explicitFeedId {
            progressData["feedId"] = explicitFeedId
        }
        
        // STEP 1: Store in shared collection to prevent quota exceeded
        updateEpisodeInSharedCollection(key: SharedDataKeys.episodeProgress, episodeId: sharedKey, data: progressData)
        // Note: synchronize() is deprecated and unnecessary
        
        print("📡 🔑 PROGRESS SYNC: Using shared collection for episode \(episodeId)")
        print("📡 ⏰ PROGRESS SYNC: Storing progress \(String(format: "%.1f", progress * 100))% for episode \(episodeId)")
        
        // STEP 2: Persist to CloudKit for permanent storage across devices
        if persistToCloudKit {
            Task.detached(priority: .userInitiated) {
            // Prefer explicit ownership; legacy callers fall back to a local lookup.
                if let feedId = await self.resolveFeedId(explicitFeedId, for: episodeId) {
                    let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId, feedId: feedId)
                    let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId, feedId: feedId)
                    let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId, feedId: feedId)
                    await self.saveEpisodeState(
                        episodeId: episodeId,
                        feedId: feedId,
                        progress: progress,
                        isFavorite: currentFavorite,
                        isDownloaded: currentDownloaded,
                        isPlayed: currentPlayed
                    )
                    print("📡 ✅ PROGRESS SYNC: Saved to CloudKit - Episode: \(episodeId), Progress: \(Int(progress * 100))%")
                } else {
                    print("📡 ⚠️ PROGRESS SYNC: Could not find feedId for episode \(episodeId), CloudKit save skipped")
                }
            }
        }
        
        os_log("📡 ⚡ REALTIME SYNC OUT: Episode %@ progress %.1f%% synced", log: log, type: .info, episodeId, progress * 100)
        print("📡 ⚡ REALTIME SYNC OUT: Episode \(episodeId) progress \(Int(progress * 100))% synced")
        
        // Store the timestamp for rate limiting if needed
        lastInstantSyncDate = Date()
    }
    
    /// Check for latest progress from other devices for a specific episode
    func checkForLatestProgress(for episodeId: String, completion: @escaping (Double) -> Void) async {
        // Check if there's any pending cross-device progress update for this episode
        if let progressData = ubiquitousStore.object(forKey: "instant_podcast_progress") as? [String: Any],
           let remoteEpisodeId = progressData["episodeId"] as? String,
           let remoteProgress = progressData["progress"] as? Double,
           let timestamp = progressData["timestamp"] as? Double,
           remoteEpisodeId == episodeId {
            
            // Check if this update is recent (within last 5 minutes)
            let currentTime = Date().timeIntervalSince1970
            if currentTime - timestamp < 300 { // 5 minutes
                print("📡 📋 RESUME SYNC: Found recent remote progress data for episode \(episodeId): \(Int(remoteProgress * 100))%")
                await MainActor.run {
                    completion(remoteProgress)
                }
                return
            } else {
                print("📡 ⏰ RESUME SYNC: Remote progress data too old (\(Int(currentTime - timestamp))s)")
            }
        }
        
        print("📡 📋 RESUME SYNC: No recent remote progress data for episode \(episodeId)")
    }
    
    /// Fetch the latest instant progress data for an episode from shared collection (used by pull-to-refresh)
    func fetchLatestInstantProgress(for episodeId: String, feedId: String? = nil) async throws -> (progress: Double, timestamp: Double)? {
        // Get progress from shared collection
        let sharedKey = feedId.map { CloudEpisodeIdentity(episodeId: episodeId, feedId: $0).storageKey } ?? episodeId
        let qualifiedData = getEpisodeFromSharedCollection(key: SharedDataKeys.episodeProgress, episodeId: sharedKey)
        let legacyData = getEpisodeFromSharedCollection(key: SharedDataKeys.episodeProgress, episodeId: episodeId)
        guard let progressData = qualifiedData ?? legacyData,
              let progress = progressData["progress"] as? Double,
              let timestamp = progressData["timestamp"] as? Double else {
            return nil
        }

        if qualifiedData == nil, let feedId {
            if let storedFeedId = progressData["feedId"] as? String {
                guard storedFeedId == feedId else { return nil }
            } else {
                guard await findFeedIdForEpisode(episodeId) == feedId else { return nil }
            }
        }
        
        print("📡 📥 FETCHED: Latest instant progress for \(episodeId): \(Int(progress * 100))% at timestamp \(timestamp)")
        return (progress: progress, timestamp: timestamp)
    }
    
    /// Broadcast feed parsing progress to all devices in real-time
    func broadcastFeedProgress(feedId: String, feedTitle: String, progress: Double, message: String) {
        guard let currentAccountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ Cannot broadcast progress - no iCloud account available")
            return
        }
        
        let progressData: [String: Any] = [
            "feedId": feedId,
            "feedTitle": feedTitle,
            "progress": progress,
            "message": message,
            "timestamp": Date().timeIntervalSince1970,
            "icloud_account_id": currentAccountID
        ]
        
        ubiquitousStore.set(progressData, forKey: "instant_podcast_feed_progress")
        // Note: synchronize() is deprecated and unnecessary        
        print("📡 📊 BROADCAST PROGRESS: \(feedTitle) - \(Int(progress * 100))% - \(message)")
        os_log("📡 📊 Broadcasting feed progress: %@ - %.1f%% - %@", log: log, type: .info, feedTitle, progress * 100, message)
    }
    
    /// Instantly sync radio station favorite status across devices
    func syncRadioFavoriteInstantly(stationId: String, isFavorite: Bool) {
        let favoriteData: [String: Any] = [
            "stationId": stationId,
            "isFavorite": isFavorite,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(favoriteData, forKey: "instant_radio_favorite")
        // Note: synchronize() is deprecated and unnecessary
        
        os_log("📡 SYNC ATTEMPT: Radio favorite for %@ (%@) synced", log: log, type: .info, stationId, isFavorite ? "YES" : "NO")
        print("📡 SYNC ATTEMPT: Radio favorite for \(stationId) (\(isFavorite)) synced")
    }
    
    /// Instantly sync radio station addition across devices
    func syncRadioStationAddedInstantly(station: [String: Any]) {
        let stationData: [String: Any] = [
            "station": station,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(stationData, forKey: "instant_radio_station_added")
        // Note: synchronize() is deprecated and unnecessary        
        if let stationName = station["name"] as? String {
            os_log("📡 Instantly synced radio station addition: %@", log: log, type: .info, stationName)
        }
    }
    
    /// Instantly sync radio station removal across devices
    func syncRadioStationRemovedInstantly(stationId: String, stationName: String) {
        let removalData: [String: Any] = [
            "stationId": stationId,
            "stationName": stationName,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(removalData, forKey: "instant_radio_station_removed")
        // Note: synchronize() is deprecated and unnecessary        
        os_log("📡 Instantly synced radio station removal: %@ (%@)", log: log, type: .info, stationName, stationId)
    }
    
    /// Instantly sync podcast feed addition across devices
    func syncPodcastFeedAddedInstantly(feedData: [String: Any]) {
        guard let accountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ Cannot sync feed addition - no iCloud account available")
            return
        }
        
        let podcastData: [String: Any] = [
            "feed": feedData,
            "timestamp": Date().timeIntervalSince1970,
            "icloud_account_id": accountID
        ]
        
        ubiquitousStore.set(podcastData, forKey: "instant_podcast_feed_added")
        // Note: synchronize() is deprecated and unnecessary        
        if let feedTitle = feedData["title"] as? String {
            os_log("📡 Instantly synced podcast feed addition: %@", log: log, type: .info, feedTitle)
        }
    }
    
    /// Instantly sync podcast feed removal across devices with enhanced reliability
    func syncPodcastFeedRemovedInstantly(feedId: String, feedTitle: String, episodeIds: [String]) {
        guard let accountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ Cannot sync feed removal - no iCloud account available")
            os_log("📡 SYNC FAILED: No iCloud account for cross-device deletion sync", log: log, type: .error)
            return
        }
        
        let removalData: [String: Any] = [
            "feedId": feedId,
            "feedTitle": feedTitle,
            "episodeIds": episodeIds,
            "timestamp": Date().timeIntervalSince1970,
            "actionId": UUID().uuidString,  // Unique action ID to prevent conflicts
            "icloud_account_id": accountID,
            "operation_type": "comprehensive_feed_deletion" // Enhanced operation tracking
        ]
        
        print("📡 🚀 ENHANCED FEED DELETION SYNC: Starting comprehensive sync for feed '\(feedTitle)' (\(feedId))")
        print("📡 📊 Episode count: \(episodeIds.count)")
        print("📡 🆔 Account ID: \(String(accountID.prefix(16)))...")
        print("📡 📝 Data to sync: \(removalData)")
        
        // Enhanced sync with retry logic for better reliability
        var syncAttempt = 0
        let maxAttempts = 3
        var syncSucceeded = false
        
        while syncAttempt < maxAttempts && !syncSucceeded {
            syncAttempt += 1
            print("📡 🔄 Sync attempt \(syncAttempt)/\(maxAttempts)")
            
            ubiquitousStore.set(removalData, forKey: "instant_podcast_feed_removed")
            // Note: synchronize() is deprecated and unnecessary - syncs automatically
            
            // Verify sync by attempting to read back
            if let readBack = ubiquitousStore.object(forKey: "instant_podcast_feed_removed") as? [String: Any],
               let syncedFeedId = readBack["feedId"] as? String,
               syncedFeedId == feedId {
                syncSucceeded = true
                print("📡 ✅ ENHANCED SYNC SUCCESS: Feed removal synced on attempt \(syncAttempt)")
                os_log("📡 SYNC SUCCESS: Feed removal %@ (%@) with %d episodes synced successfully", log: log, type: .info, feedTitle, feedId, episodeIds.count)
            } else {
                print("📡 ⚠️ Verification failed on attempt \(syncAttempt)")
            }
            
            if !syncSucceeded && syncAttempt < maxAttempts {
                // Brief delay before retry
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        
        if syncSucceeded {
            print("📡 🎉 FINAL SUCCESS: Cross-device deletion sync completed for '\(feedTitle)'")
            print("📡 🔄 Other devices will now receive notification to delete CoreData for this feed")
        } else {
            print("📡 ❌ FINAL FAILURE: Failed to sync feed removal after \(maxAttempts) attempts")
            os_log("📡 SYNC FAILED: Could not sync feed removal %@ (%@) after %d attempts", log: log, type: .error, feedTitle, feedId, maxAttempts)
            
            // TODO: Consider adding this to a retry queue for later attempts
        }
    }
    
    /// Instantly sync podcast episode favorite status across devices
    func syncPodcastFavoriteInstantly(episodeId: String, feedId explicitFeedId: String? = nil, isFavorite: Bool, persistToCloudKit: Bool = true) {
        print("📡 🚀 FAVORITE SYNC SEND: Starting favorite sync for episode \(episodeId) -> \(isFavorite)")
        
        // Add iCloud account info for validation
        let currentToken = FileManager.default.ubiquityIdentityToken
        let accountInfo = currentToken != nil ? "\(type(of: currentToken!))" : "nil"
        
        let sharedKey = explicitFeedId.map { CloudEpisodeIdentity(episodeId: episodeId, feedId: $0).storageKey } ?? episodeId
        var favoriteData: [String: Any] = [
            "episodeId": episodeId,
            "isFavorite": isFavorite,
            "timestamp": Date().timeIntervalSince1970,
            "accountId": accountInfo
        ]
        if let explicitFeedId {
            favoriteData["feedId"] = explicitFeedId
        }
        
        print("📡 🚀 FAVORITE SYNC DATA: Sending data: \(favoriteData)")
        
        // STEP 1: Store in shared collection to prevent quota exceeded
        updateEpisodeInSharedCollection(key: SharedDataKeys.episodeFavorites, episodeId: sharedKey, data: favoriteData)
        // Note: synchronize() is deprecated and unnecessary
        
        print("📡 🔑 FAVORITE SYNC: Using shared collection for episode \(episodeId)")
        print("📡 ⭐ FAVORITE SYNC: Storing favorite=\(isFavorite) for episode \(episodeId)")
        
        print("📡 🚀 FAVORITE SYNC RESULT: iCloud sync completed")
        
        // STEP 2: Persist to CloudKit for permanent storage across devices
        if persistToCloudKit {
            Task.detached(priority: .userInitiated) {
                if let feedId = await self.resolveFeedId(explicitFeedId, for: episodeId) {
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: feedId)
                    let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId, feedId: feedId)
                    let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId, feedId: feedId)
                    await self.saveEpisodeState(
                        episodeId: episodeId,
                        feedId: feedId,
                        progress: currentProgress,
                        isFavorite: isFavorite,
                        isDownloaded: currentDownloaded,
                        isPlayed: currentPlayed
                    )
                    print("📡 ✅ FAVORITE SYNC: Saved to CloudKit - Episode: \(episodeId), Favorite: \(isFavorite)")
                } else {
                    print("📡 ⚠️ FAVORITE SYNC: Could not find feedId for episode \(episodeId), CloudKit save skipped")
                }
            }
        }
        
        os_log("📡 Instantly synced podcast favorite: %@ (favorite: %@)", log: log, type: .info, episodeId, isFavorite ? "YES" : "NO")
        
        // Verify data was stored in shared collection
        if let storedData = getEpisodeFromSharedCollection(key: SharedDataKeys.episodeFavorites, episodeId: sharedKey) {
            print("📡 🚀 FAVORITE SYNC VERIFY: Data successfully stored in shared collection: \(storedData)")
        } else {
            print("📡 ❌ FAVORITE SYNC ERROR: Failed to verify data storage in shared collection")
        }
    }
    
    /// Instantly sync podcast episode download status across devices
    func syncPodcastDownloadInstantly(episodeId: String, feedId explicitFeedId: String? = nil, isDownloaded: Bool, persistToCloudKit: Bool = true) {
        print("📡 🚀 DOWNLOAD SYNC SEND: Starting download sync for episode \(episodeId) -> \(isDownloaded)")
        
        // Add iCloud account info for validation
        let currentToken = FileManager.default.ubiquityIdentityToken
        let accountInfo = currentToken != nil ? "\(type(of: currentToken!))" : "nil"
        
        let sharedKey = explicitFeedId.map { CloudEpisodeIdentity(episodeId: episodeId, feedId: $0).storageKey } ?? episodeId
        var downloadData: [String: Any] = [
            "episodeId": episodeId,
            "isDownloaded": isDownloaded,
            "timestamp": Date().timeIntervalSince1970,
            "accountId": accountInfo
        ]
        if let explicitFeedId {
            downloadData["feedId"] = explicitFeedId
        }
        
        print("📡 🚀 DOWNLOAD SYNC DATA: Sending data: \(downloadData)")
        
        // STEP 1: Store in shared collection to prevent quota exceeded
        updateEpisodeInSharedCollection(key: SharedDataKeys.episodeDownloads, episodeId: sharedKey, data: downloadData)
        // Note: synchronize() is deprecated and unnecessary
        
        print("📡 🔑 DOWNLOAD SYNC: Using shared collection for episode \(episodeId)")
        print("📡 📥 DOWNLOAD SYNC: Storing downloaded=\(isDownloaded) for episode \(episodeId)")
        
        print("📡 🚀 DOWNLOAD SYNC RESULT: iCloud sync completed")
        
        // Verify data was stored in shared collection
        if let storedData = getEpisodeFromSharedCollection(key: SharedDataKeys.episodeDownloads, episodeId: sharedKey) {
            print("📡 🚀 DOWNLOAD SYNC VERIFY: Data successfully stored in shared collection: \(storedData)")
        } else {
            print("📡 ❌ DOWNLOAD SYNC ERROR: Failed to verify data storage in shared collection")
        }
        
        // STEP 2: Persist to CloudKit for permanent storage across devices
        if persistToCloudKit {
            Task.detached(priority: .userInitiated) {
                if let feedId = await self.resolveFeedId(explicitFeedId, for: episodeId) {
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: feedId)
                    let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId, feedId: feedId)
                    let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId, feedId: feedId)
                    await self.saveEpisodeState(
                        episodeId: episodeId,
                        feedId: feedId,
                        progress: currentProgress,
                        isFavorite: currentFavorite,
                        isDownloaded: isDownloaded,
                        isPlayed: currentPlayed
                    )
                    print("📡 ✅ DOWNLOAD SYNC: Saved to CloudKit - Episode: \(episodeId), Downloaded: \(isDownloaded)")
                } else {
                    print("📡 ⚠️ DOWNLOAD SYNC: Could not find feedId for episode \(episodeId), CloudKit save skipped")
                }
            }
        }
        
        os_log("📡 Instantly synced podcast download: %@ (downloaded: %@)", log: log, type: .info, episodeId, isDownloaded ? "YES" : "NO")
    }
    
    /// Instantly sync podcast episode played status across devices
    func syncPodcastPlayedInstantly(episodeId: String, feedId explicitFeedId: String? = nil, isPlayed: Bool, persistToCloudKit: Bool = true) {
        print("📡 🚀 PLAYED SYNC SEND: Starting played sync for episode \(episodeId) -> \(isPlayed)")
        
        // Add iCloud account info for validation
        let currentToken = FileManager.default.ubiquityIdentityToken
        let accountInfo = currentToken != nil ? "\(type(of: currentToken!))" : "nil"
        
        let sharedKey = explicitFeedId.map { CloudEpisodeIdentity(episodeId: episodeId, feedId: $0).storageKey } ?? episodeId
        var playedData: [String: Any] = [
            "episodeId": episodeId,
            "isPlayed": isPlayed,
            "timestamp": Date().timeIntervalSince1970,
            "accountId": accountInfo
        ]
        if let explicitFeedId {
            playedData["feedId"] = explicitFeedId
        }
        
        print("📡 🚀 PLAYED SYNC DATA: Sending data: \(playedData)")
        
        // STEP 1: Store in shared collection to prevent quota exceeded
        updateEpisodeInSharedCollection(key: SharedDataKeys.episodePlayed, episodeId: sharedKey, data: playedData)
        // Note: synchronize() is deprecated and unnecessary
        
        print("📡 🔑 PLAYED SYNC: Using shared collection for episode \(episodeId)")
        print("📡 ✅ PLAYED SYNC: Storing played=\(isPlayed) for episode \(episodeId)")
        
        print("📡 🚀 PLAYED SYNC RESULT: iCloud sync completed")
        
        // Verify data was stored in shared collection
        if let storedData = getEpisodeFromSharedCollection(key: SharedDataKeys.episodePlayed, episodeId: sharedKey) {
            print("📡 🚀 PLAYED SYNC VERIFY: Data successfully stored in shared collection: \(storedData)")
        } else {
            print("📡 ❌ PLAYED SYNC ERROR: Failed to verify data storage in shared collection")
        }
        
        // STEP 2: Persist to CloudKit for permanent storage across devices
        if persistToCloudKit {
            Task.detached(priority: .userInitiated) {
                if let feedId = await self.resolveFeedId(explicitFeedId, for: episodeId) {
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: feedId)
                    let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId, feedId: feedId)
                    let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId, feedId: feedId)
                    await self.saveEpisodeState(
                        episodeId: episodeId,
                        feedId: feedId,
                        progress: currentProgress,
                        isFavorite: currentFavorite,
                        isDownloaded: currentDownloaded,
                        isPlayed: isPlayed
                    )
                    print("📡 ✅ PLAYED SYNC: Saved to CloudKit - Episode: \(episodeId), Played: \(isPlayed)")
                } else {
                    print("📡 ⚠️ PLAYED SYNC: Could not find feedId for episode \(episodeId), CloudKit save skipped")
                }
            }
        }
        
        os_log("📡 Instantly synced podcast played: %@ (played: %@)", log: log, type: .info, episodeId, isPlayed ? "YES" : "NO")
    }
    
    // MARK: - Episode State CloudKit Sync

    private func resolveFeedId(_ explicitFeedId: String?, for episodeId: String) async -> String? {
        if let explicitFeedId, !explicitFeedId.isEmpty {
            return explicitFeedId
        }
        return await findFeedIdForEpisode(episodeId)
    }
    
    /// Resolve a legacy raw episode ID only when it has one local owner.
    private func findFeedIdForEpisode(_ episodeId: String) async -> String? {
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", episodeId)
                request.propertiesToFetch = ["feedId"]
                request.fetchLimit = 2

                do {
                    let feedIds = Set(try context.fetch(request).compactMap { $0.feedId }.filter { !$0.isEmpty })
                    continuation.resume(returning: feedIds.count == 1 ? feedIds.first : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Save episode state to CloudKit with proper conflict resolution
    func saveEpisodeState(episodeId: String, feedId: String, progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool) async {

        
        do {
            try await saveEpisodeStateToCloudKit(episodeId, feedId: feedId, progress: progress, isFavorite: isFavorite, isDownloaded: isDownloaded, isPlayed: isPlayed)
            os_log("💾 ✅ Successfully saved episode state to CloudKit: %@", log: log, type: .info, episodeId)
            
            // Show minimal sync indicator for individual CloudKit saves
            await MainActor.run {
                DataSyncManager.shared.showMinimalCloudKitSync()
            }
        } catch {
            os_log("❌ Failed to save episode state to CloudKit: %@", log: log, type: .error, error.localizedDescription)
            if let ckError = error as? CKError {
                os_log("❌ CloudKit error code: %d", log: log, type: .error, ckError.code.rawValue)
            }
        }
    }
    
    /// Save episode state to CloudKit with proper update/insert logic and feed relationship
    private func saveEpisodeStateToCloudKit(_ episodeId: String, feedId: String, progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool) async throws {
        // Validate inputs to prevent crashes
        guard !episodeId.isEmpty else {
            os_log("❌ Cannot save episode state: episodeId is empty", log: log, type: .error)
            throw CKError(.invalidArguments)
        }
        
        guard !feedId.isEmpty else {
            os_log("❌ Cannot save episode state: feedId is empty for episode %@", log: log, type: .error, episodeId)
            throw CKError(.invalidArguments)
        }
        
        let identity = CloudEpisodeIdentity(episodeId: episodeId, feedId: feedId)
        let recordID = Self.episodeStateRecordID(for: identity)
        
        // First try to fetch existing record
        var record: CKRecord
        do {
            record = try await privateDatabase.record(for: recordID)
            // Record exists, update it
        } catch CKError.unknownItem {
            // Record doesn't exist, create new one
            record = CKRecord(recordType: RecordType.episodeState, recordID: recordID)
        } catch {
            // Other error, rethrow
            throw error
        }
        
        // Update record fields
        record["episodeId"] = episodeId as CKRecordValue
        record["feedId"] = feedId as CKRecordValue  // Add feed reference for relationship
        record["progress"] = progress as CKRecordValue
        record["isFavorite"] = isFavorite as CKRecordValue
        record["isDownloaded"] = isDownloaded as CKRecordValue
        record["isPlayed"] = isPlayed as CKRecordValue
        record["lastUpdated"] = Date() as CKRecordValue
        
        // .none, not .deleteSelf: removing a feed record must never destroy the user's progress.
        let feedRecordID = CKRecord.ID(recordName: feedId)
        record["podcastFeed"] = CKRecord.Reference(recordID: feedRecordID, action: .none) as CKRecordValue
        
        do {
            try await modify(record)
        } catch let error as CKError where error.code == .referenceViolation {
            // Feed record isn't in CloudKit yet - the state matters more than the relationship.
            os_log("⚠️ Feed record %@ missing - saving episode state without reference", log: log, type: .info, feedId)
            record["podcastFeed"] = nil
            try await modify(record)
        }
        
        os_log("✅ Saved episode state to CloudKit: %@ -> %@", log: log, type: .info, episodeId, feedId)
    }
    
    private func modify(_ record: CKRecord) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys // Only update changed fields
        operation.qualityOfService = .userInitiated
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            privateDatabase.add(operation)
        }
    }
    
    /// Fetch episode state from CloudKit
    func fetchEpisodeStateFromCloudKit(_ episodeId: String, feedId: String? = nil) async throws -> (progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool, feedId: String?)? {
        var recordIDs: [CKRecord.ID] = []
        if let feedId, !feedId.isEmpty {
            recordIDs.append(Self.episodeStateRecordID(for: CloudEpisodeIdentity(episodeId: episodeId, feedId: feedId)))
        }
        recordIDs.append(Self.legacyEpisodeStateRecordID(for: episodeId))

        for recordID in recordIDs {
            do {
                let record = try await privateDatabase.record(for: recordID)
                let recordFeedId = record["feedId"] as? String

                // A legacy raw-ID record may belong to another feed. Never import it across feeds.
                if let feedId, let recordFeedId, !recordFeedId.isEmpty, recordFeedId != feedId {
                    continue
                }
                if let feedId, recordID == Self.legacyEpisodeStateRecordID(for: episodeId), recordFeedId?.isEmpty != false {
                    guard await findFeedIdForEpisode(episodeId) == feedId else { continue }
                }

                return (
                    progress: record["progress"] as? Double ?? 0.0,
                    isFavorite: record["isFavorite"] as? Bool ?? false,
                    isDownloaded: record["isDownloaded"] as? Bool ?? false,
                    isPlayed: record["isPlayed"] as? Bool ?? false,
                    feedId: recordFeedId ?? feedId
                )
            } catch let error as CKError where error.code == .unknownItem {
                continue
            } catch let error as CKError where error.code == .networkUnavailable || error.code == .networkFailure {
                throw error
            } catch {
                os_log("⚠️ CloudKit error fetching episode state for %@: %@", log: log, type: .default, episodeId, error.localizedDescription)
                return nil
            }
        }

        return nil
    }
    
    /// Sync episode states from CloudKit with different behavior for fresh install vs upgrade
    /// - For fresh install: sync isFavorite but NOT isDownloaded (files don't exist)
    /// - For upgrade: sync both isFavorite and isDownloaded (files might still exist)
    /// - Returns: Tuple of (Array of episode state updates that should be saved to Core Data, Boolean indicating success)
    func syncEpisodeStatesFromCloudKit(for episodeIdentities: [CloudEpisodeIdentity], isFreshInstall: Bool) async -> (updates: [EpisodeStateUpdate], success: Bool) {
        // Ensure CloudKit operations run on dedicated background queue to prevent main thread blocking
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let result = await self.performEpisodeStateSync(episodeIdentities: episodeIdentities, isFreshInstall: isFreshInstall)
                continuation.resume(returning: result)
            }
        }
    }

    private func resolveCloudStates(
        _ records: [CloudEpisodeState],
        for localIdentities: [CloudEpisodeIdentity]
    ) -> [CloudEpisodeIdentity: CloudEpisodeState] {
        let localIdentitySet = Set(localIdentities)
        let localByEpisodeId = Dictionary(grouping: localIdentities, by: \.episodeId)
        var resolved: [CloudEpisodeIdentity: CloudEpisodeState] = [:]

        for record in records {
            let identity: CloudEpisodeIdentity?
            if let feedId = record.feedId, !feedId.isEmpty {
                let exactIdentity = CloudEpisodeIdentity(
                    episodeId: record.episodeId,
                    feedId: canonicalLocalFeedId(for: feedId)
                )
                identity = localIdentitySet.contains(exactIdentity) ? exactIdentity : nil
            } else if let candidates = localByEpisodeId[record.episodeId], candidates.count == 1 {
                identity = candidates[0]
            } else {
                identity = nil
            }

            guard let identity else { continue }
            if let existing = resolved[identity], !existing.isLegacyRecord {
                continue
            }
            if resolved[identity] == nil || !record.isLegacyRecord {
                resolved[identity] = record
            }
        }

        return resolved
    }

    func fetchEpisodeStatesFromCloudKit(
        for identities: [CloudEpisodeIdentity]
    ) async throws -> [CloudEpisodeIdentity: CloudEpisodeState] {
        let records = try await fetchAllEpisodeStatesFromCloudKit()
        return resolveCloudStates(records, for: identities)
    }
    
    private func performEpisodeStateSync(episodeIdentities: [CloudEpisodeIdentity], isFreshInstall: Bool) async -> (updates: [EpisodeStateUpdate], success: Bool) {
        // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
        let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
        let finalIsFreshInstall = isFreshInstall && !isDefiniteUpgrade
        let identityKeys = episodeIdentities.map(\.storageKey)
        
        os_log("🔄 Starting episode state sync from CloudKit for %d episodes (fresh install: %@, definite upgrade: %@)", 
             log: log, type: .info, episodeIdentities.count, finalIsFreshInstall ? "YES" : "NO", isDefiniteUpgrade ? "YES" : "NO")
        
        // SYNC RESUMPTION: Check if we have incomplete sync to resume
        var identitiesToSync = episodeIdentities
        if EpisodeStateManager.shared.hasIncompleteSyncToResume() {
            let remainingIdentityKeys = Set(EpisodeStateManager.shared.getRemainingEpisodesToSync())
            // Filter to only include episodes that still exist locally
            identitiesToSync = episodeIdentities.filter { remainingIdentityKeys.contains($0.storageKey) }
            if identitiesToSync.isEmpty && !remainingIdentityKeys.isEmpty {
                EpisodeStateManager.shared.startCloudKitSyncProgress(totalEpisodeIds: identityKeys, isFreshInstall: finalIsFreshInstall)
                identitiesToSync = episodeIdentities
                os_log("📡 Reset incompatible legacy sync checkpoint", log: log, type: .info)
            } else {
                os_log("📡 🔄 SYNC RESUMPTION: Resuming sync with %d remaining episodes out of %d total",
                       log: log, type: .info, identitiesToSync.count, episodeIdentities.count)
            }
        } else {
            // Start new sync tracking
            EpisodeStateManager.shared.startCloudKitSyncProgress(totalEpisodeIds: identityKeys, isFreshInstall: finalIsFreshInstall)
        }
        
        var syncedCount = 0
        var coreDataUpdates: [EpisodeStateUpdate] = []
        var syncSuccess = false
        
        let identitySet = Set(identitiesToSync)
        
        do {
            // Use bulk fetch for better performance
            let allCloudRecords = try await fetchAllEpisodeStatesFromCloudKit()
            let allCloudStates = resolveCloudStates(allCloudRecords, for: episodeIdentities)
            
            // Process CloudKit states
            let totalCloudStates = allCloudStates.keys.filter { identitySet.contains($0) }.count
            var processedCount = 0
            
            for (identity, cloudState) in allCloudStates {
                // Only process if this episode exists locally
                guard identitySet.contains(identity) else { continue }
                let episodeId = identity.episodeId

                // PERFORMANCE OPTIMIZATION: Update progress tracking MUCH less frequently
                // Reduced from every 50 to every 100 for better performance
                processedCount += 1
                if processedCount % 100 == 0 || processedCount == totalCloudStates {
                    // Use Task to avoid blocking current background processing
                    Task { @MainActor in
                        await DataSyncManager.shared.updateEpisodeStateProgress(
                            currentCount: processedCount * episodeIdentities.count / max(totalCloudStates, 1) / 2,
                            operation: "Processing \(processedCount)/\(totalCloudStates) episode states..."
                        )
                    }
                }

                // Always sync progress, isFavorite, and isPlayed to EpisodeStateManager SILENTLY
                // Apply CloudKit progress when it exists - this is the user's data from other devices
                let finalIsDownloaded: Bool
                if cloudState.isDownloaded {
                    finalIsDownloaded = !finalIsFreshInstall
                } else if isDefiniteUpgrade && EpisodeStateManager.shared.isDownloaded(episodeId, feedId: identity.feedId) {
                    finalIsDownloaded = true
                    os_log("⚠️ Upgrade: Local download state exists but CloudKit shows not downloaded for %@ - preserving local state",
                           log: log, type: .info, episodeId)
                } else {
                    finalIsDownloaded = false
                }

                EpisodeStateManager.shared.applyStateSilently(
                    for: episodeId,
                    progress: cloudState.progress,
                    isFavorite: cloudState.isFavorite,
                    isDownloaded: finalIsDownloaded,
                    isPlayed: cloudState.isPlayed,
                    feedId: identity.feedId,
                    persistImmediately: false
                )
                if cloudState.progress > 0 {
                    os_log("🔄 Applying CloudKit progress %.2f for episode %@", 
                           log: log, type: .info, cloudState.progress, episodeId)
                }
                // DEBUG: Log CloudKit states being applied (for fresh install debugging)
                if cloudState.progress > 0 || cloudState.isFavorite || cloudState.isPlayed {
                    print("☁️ CLOUDKIT DEBUG: Applied state to episode \(episodeId) - Progress: \(String(format: "%.2f", cloudState.progress)), Favorite: \(cloudState.isFavorite), Played: \(cloudState.isPlayed)")
                }
                
                // Prepare Core Data update - always apply CloudKit progress when it exists
                coreDataUpdates.append(EpisodeStateUpdate(
                    episodeId: episodeId,
                    feedId: identity.feedId,
                    progress: cloudState.progress,
                    isFavorite: cloudState.isFavorite,
                    isDownloaded: finalIsDownloaded,
                    isPlayed: cloudState.isPlayed
                ))
                
                syncedCount += 1
                
                // SYNC RESUMPTION: Mark this episode as processed
                EpisodeStateManager.shared.markEpisodeProcessed(identity.storageKey)
            }
            
            // The query succeeded; having no matching remote state is a valid completed sync.
            syncSuccess = true
            
            // Core Data saves happen automatically, no need to force save
            // EpisodeStateManager automatically saves to Core Data on state changes
            
            os_log("✅ Bulk CloudKit sync completed: %d synced, %d prepared for Core Data",
                   log: log, type: .info, syncedCount, coreDataUpdates.count)

        } catch {
            os_log("❌ Failed to bulk fetch episode states from CloudKit: %@", log: log, type: .error, error.localizedDescription)
            
            // Fallback to individual fetches with batching to avoid overwhelming CloudKit
            os_log("🔄 Falling back to batched individual fetches", log: log, type: .info)
            let batchSize = 50 // Smaller batches to avoid rate limits
            let batches = identitiesToSync.chunked(into: batchSize)
            
            var individualSyncErrors = 0
            
            for (batchIndex, batch) in batches.enumerated() {
                
                for (episodeIndex, identity) in batch.enumerated() {
                    let episodeId = identity.episodeId
                    // Update progress tracking for fallback sync
                    let totalProcessed = batchIndex * batchSize + episodeIndex + 1
                    if totalProcessed % 20 == 0 || totalProcessed == identitiesToSync.count {
                        await DataSyncManager.shared.updateEpisodeStateProgress(
                            currentCount: totalProcessed / 3,
                            operation: "Syncing \(totalProcessed)/\(identitiesToSync.count) episode states (fallback mode)..."
                        )
                    }
                    do {
                        if let cloudState = try await fetchEpisodeStateFromCloudKit(episodeId, feedId: identity.feedId) {
                            // Always sync progress, isFavorite, and isPlayed to EpisodeStateManager SILENTLY
                            // Apply CloudKit progress when it exists - this is the user's data from other devices
                            let finalIsDownloaded: Bool
                            if cloudState.isDownloaded {
                                finalIsDownloaded = !finalIsFreshInstall
                            } else if isDefiniteUpgrade && EpisodeStateManager.shared.isDownloaded(episodeId, feedId: identity.feedId) {
                                finalIsDownloaded = true
                                os_log("⚠️ Upgrade: Local download state exists but CloudKit shows not downloaded for %@ - preserving local state",
                                       log: log, type: .info, episodeId)
                            } else {
                                finalIsDownloaded = false
                            }

                            EpisodeStateManager.shared.applyStateSilently(
                                for: episodeId,
                                progress: cloudState.progress,
                                isFavorite: cloudState.isFavorite,
                                isDownloaded: finalIsDownloaded,
                                isPlayed: cloudState.isPlayed,
                                feedId: identity.feedId,
                                persistImmediately: false
                            )
                            if cloudState.progress > 0 {
                                os_log("🔄 Applying CloudKit progress %.2f for episode %@",
                                       log: log, type: .info, cloudState.progress, episodeId)
                            }
                            // Prepare Core Data update - always apply CloudKit progress when it exists
                            
                            coreDataUpdates.append(EpisodeStateUpdate(
                                episodeId: episodeId,
                                feedId: identity.feedId,
                                progress: cloudState.progress,
                                isFavorite: cloudState.isFavorite,
                                isDownloaded: finalIsDownloaded,
                                isPlayed: cloudState.isPlayed
                            ))
                            
                            syncedCount += 1
                            
                            // SYNC RESUMPTION: Mark this episode as processed (fallback mode)
                            EpisodeStateManager.shared.markEpisodeProcessed(identity.storageKey)
                        } else {
                            // Episode has no CloudKit state yet - this is normal for new episodes
                            // SYNC RESUMPTION: Still mark as processed since we checked CloudKit
                            EpisodeStateManager.shared.markEpisodeProcessed(identity.storageKey)
                        }
                    } catch CKError.unknownItem {
                        // Episode doesn't exist in CloudKit - this is normal, not an error
                        // SYNC RESUMPTION: Mark as processed since we confirmed it doesn't exist
                        EpisodeStateManager.shared.markEpisodeProcessed(identity.storageKey)
                    } catch {
                        // Only log actual errors (network issues, permissions, etc.)
                        os_log("❌ Failed to sync episode state for %@: %@", log: log, type: .error, episodeId, error.localizedDescription)
                        individualSyncErrors += 1
                        // SYNC RESUMPTION: Mark as processed even on error to avoid infinite retry
                        EpisodeStateManager.shared.markEpisodeProcessed(identity.storageKey)
                    }
                }
                
                // Add small delay between batches to respect rate limits
                if batchIndex < batches.count - 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                }
            }
            
            // Consider sync successful if we managed to sync some episodes despite errors
            let totalEpisodesAttempted = identitiesToSync.count
            let errorRate = Double(individualSyncErrors) / Double(totalEpisodesAttempted)
            syncSuccess = errorRate < 0.5 // Success if less than 50% of episodes failed
            
            // Core Data saves happen automatically, no need to force save
            // EpisodeStateManager automatically saves to Core Data on state changes
            
            os_log("✅ Individual CloudKit sync completed: %d synced, %d errors, success: %@",
                   log: log, type: .info, syncedCount, individualSyncErrors, syncSuccess ? "YES" : "NO")
        }
        
        os_log("✅ Episode state sync completed: %d synced, %d prepared for Core Data, success: %@", 
               log: log, type: .info, syncedCount, coreDataUpdates.count, syncSuccess ? "YES" : "NO")
        
        // SYNC RESUMPTION: Complete the sync progress if successful
        if syncSuccess {
            EpisodeStateManager.shared.completeSyncProgress()
        }
        
        // Return the updates and success status
        return (updates: coreDataUpdates, success: syncSuccess)
    }
    
    /// Fetch all episode states from CloudKit using batched queries (200 records per batch)
    func fetchAllEpisodeStatesFromCloudKit() async throws -> [CloudEpisodeState] {
        os_log("🔄 FAST SYNC: Fetching all episode states from CloudKit in batches of 200", log: log, type: .info)
        
        let query = CKQuery(recordType: RecordType.episodeState, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "lastUpdated", ascending: false)]
        
        var episodeStates: [CloudEpisodeState] = []
        var cursor: CKQueryOperation.Cursor? = nil
        var batchNumber = 1
        let batchSize = 200
        
        repeat {
            os_log("📦 FAST SYNC: Fetching batch %d of episode states (batch size: %d)", log: log, type: .info, batchNumber, batchSize)
            
            let operation = CKQueryOperation(query: query)
            operation.resultsLimit = batchSize
            operation.cursor = cursor
            operation.database = privateDatabase
            
            let (batchResults, nextCursor) = try await performBatchedQuery(operation: operation)
            cursor = nextCursor
            
            // PERFORMANCE OPTIMIZATION: If first batch is empty, skip remaining batches
            // This is common for truly fresh installs with no prior data
            if batchNumber == 1 && batchResults.isEmpty {
                os_log("⚡ FAST SYNC: No episode states found in CloudKit - skipping sync for fresh install", log: log, type: .info)
                print("⚡ FAST SYNC: No episode states in CloudKit - instant sync complete!")
                return [] // Return empty array immediately
            }
            
            // Process this batch
            for (recordID, recordResult) in batchResults {
                switch recordResult {
                case .success(let record):
                    if let episodeId = record["episodeId"] as? String {
                        let progress = record["progress"] as? Double ?? 0.0
                        let isFavorite = record["isFavorite"] as? Bool ?? false
                        let isDownloaded = record["isDownloaded"] as? Bool ?? false
                        let isPlayed = record["isPlayed"] as? Bool ?? false
                        let feedId = record["feedId"] as? String
                        
                        episodeStates.append(CloudEpisodeState(
                            episodeId: episodeId,
                            feedId: feedId,
                            progress: progress,
                            isFavorite: isFavorite,
                            isDownloaded: isDownloaded,
                            isPlayed: isPlayed,
                            isLegacyRecord: !recordID.recordName.hasPrefix("episode_state_v2_")
                        ))
                    }
                case .failure(let error):
                    os_log("❌ Failed to fetch episode state record %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
                }
            }
            
            os_log("✅ FAST SYNC: Processed batch %d: %d episode states total so far", log: log, type: .info, batchNumber, episodeStates.count)
            
            // Update progress tracking for batched fetching (less frequently for better performance)
            if batchNumber % 2 == 0 || cursor == nil {
                Task { @MainActor in
                    await DataSyncManager.shared.updateEpisodeStateProgress(
                        currentCount: episodeStates.count,
                        operation: "Fetched batch \(batchNumber) of episode states (\(episodeStates.count) total)..."
                    )
                }
            }
            
            batchNumber += 1
            
        } while cursor != nil
        
        os_log("✅ FAST SYNC: Completed fetching all episode states from CloudKit: %d total records in %d batches", log: log, type: .info, episodeStates.count, batchNumber - 1)
        
        // DEBUG: Log summary of fetched states for fresh install debugging
        let statesWithProgress = episodeStates.filter { $0.progress > 0 }.count
        let statesWithFavorites = episodeStates.filter { $0.isFavorite }.count
        let statesWithPlayed = episodeStates.filter { $0.isPlayed }.count
        print("☁️ FAST SYNC: Fetched \(episodeStates.count) episode states - Progress: \(statesWithProgress), Favorites: \(statesWithFavorites), Played: \(statesWithPlayed)")
        
        return episodeStates
    }
    
    /// Helper method to perform batched CloudKit queries
    private func performBatchedQuery(operation: CKQueryOperation) async throws -> ([CKRecord.ID: Result<CKRecord, Error>], CKQueryOperation.Cursor?) {
        return try await withCheckedThrowingContinuation { continuation in
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            var cursor: CKQueryOperation.Cursor? = nil
            
            operation.recordMatchedBlock = { recordID, recordResult in
                results[recordID] = recordResult
            }
            
            operation.queryResultBlock = { result in
                switch result {
                case .success(let queryCursor):
                    cursor = queryCursor
                    continuation.resume(returning: (results, cursor))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            privateDatabase.add(operation)
        }
    }
    
    // MARK: - Podcast Feed CloudKit Sync
    
    /// Sync from CloudKit to local storage - fetch all podcast feeds
    func syncFromCloudKit() async throws -> [PodcastFeed] {
        os_log("🔄 Starting CloudKit sync for podcast feeds", log: log, type: .info)
        
        let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        
        do {
            let (matchResults, _) = try await privateDatabase.records(matching: query)
            var feeds: [PodcastFeed] = []
            
            for (recordID, recordResult) in matchResults {
                switch recordResult {
                case .success(let record):
                    if let feed = try? await parsePodcastFeedRecord(record) {
                        feeds.append(feed)
                        os_log("✅ Parsed feed: %@", log: log, type: .debug, feed.title)
                    } else {
                        os_log("⚠️ Failed to parse feed record: %@", log: log, type: .default, recordID.recordName)
                    }
                case .failure(let error):
                    os_log("❌ Failed to fetch record %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
                }
            }
            
            os_log("🌟 Successfully synced %d podcast feeds from CloudKit", log: log, type: .info, feeds.count)
            return feeds
            
        } catch {
            os_log("❌ CloudKit sync failed: %@", log: log, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    /// Parse a CloudKit record into a PodcastFeed
    private func parsePodcastFeedRecord(_ record: CKRecord) async throws -> PodcastFeed? {
        guard let title = record["title"] as? String,
              let url = record["url"] as? String else {
            os_log("⚠️ Missing required fields in record: %@", log: log, type: .default, record.recordID.recordName)
            return nil
        }
        
        let artworkUrl = record["artworkUrl"] as? String
        let descriptionText = record["descriptionText"] as? String
        let order = record["order"] as? Int ?? 0
        
        // Handle artwork/icon data
        var iconData: String?
        var imageData: Data?
        
        if let iconAsset = record["iconData"] as? CKAsset,
           let iconURL = iconAsset.fileURL {
            imageData = try? Data(contentsOf: iconURL)
            iconData = imageData?.base64EncodedString()
        }
        
        if let imageAsset = record["image"] as? CKAsset,
           let imageURL = imageAsset.fileURL,
           imageData == nil { // Only use if iconData wasn't found
            imageData = try? Data(contentsOf: imageURL)
        }
        
        return PodcastFeed(
            id: record.recordID.recordName,
            title: title,
            url: url,
            artworkUrl: artworkUrl,
            description: descriptionText,
            iconData: iconData,
            imageData: imageData,
            episodes: [], // Episodes will be loaded separately via RSS
            order: order
        )
    }
    
    /// Save podcast feed to CloudKit with best-effort duplicate prevention
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed, oldURL: String? = nil) async throws {
        let recordID = CKRecord.ID(recordName: feed.id)
        os_log("💾 SAVE: Attempting to save feed '%@' with ID: %@", log: log, type: .info, feed.title, feed.id)
        
        if let oldURL = oldURL, oldURL != feed.url {
            os_log("🔄 URL CHANGED: Old URL: %@ → New URL: %@", log: log, type: .info, oldURL, feed.url)
        }
        
        // Step 1: Try to fetch record by ID first (this is the primary way to update existing feeds)
        var record: CKRecord
        var isExistingRecord = false
        
        do {
            record = try await privateDatabase.record(for: recordID)
            isExistingRecord = true
            let cloudKitURL = record["url"] as? String
            
            // Log URL change if applicable
            if let cloudKitURL = cloudKitURL, cloudKitURL != feed.url {
                os_log("🔄 EDIT: Found existing feed by ID, updating URL: %@ → %@", log: log, type: .info, cloudKitURL, feed.url)
                os_log("🔄 EDIT: Updating feed '%@' (ID: %@) - URL changed but keeping same record", log: log, type: .info, feed.title, feed.id)
            } else {
                os_log("🔄 EDIT: Found existing feed by ID, updating: %@ (ID: %@)", log: log, type: .info, feed.title, feed.id)
            }
        } catch CKError.unknownItem {
            os_log("✅ NEW: Record doesn't exist yet by ID: %@ (ID: %@)", log: log, type: .info, feed.title, feed.id)
            
            // Step 2: If we have an old URL, search for a record with that URL
            if let oldURL = oldURL {
                do {
                    os_log("🔍 Searching for existing record with old URL: %@", log: log, type: .info, oldURL)
                    
                    let urlPredicate = NSPredicate(format: "url == %@", oldURL)
                    let query = CKQuery(recordType: RecordType.podcastFeed, predicate: urlPredicate)
                    
                    let (matchResults, _) = try await privateDatabase.records(matching: query)
                    
                    // If we found a record with the old URL, update it with the new URL
                    if let existingMatch = matchResults.first,
                       case .success(let existingRecord) = existingMatch.1 {
                        os_log("🔄 FOUND OLD RECORD: Found record with old URL, will update it with new URL", log: log, type: .info)
                        os_log("🔄 FOUND OLD RECORD: Updating record ID %@ with new URL: %@", log: log, type: .info, existingRecord.recordID.recordName, feed.url)
                        record = existingRecord
                        isExistingRecord = true
                    } else {
                        os_log("⚠️ OLD URL NOT FOUND: No record found with old URL, will create new record", log: log, type: .info)
                        record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
                    }
                } catch {
                    os_log("⚠️ Old URL search failed, creating new record: %@", log: log, type: .default, error.localizedDescription)
                    record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
                }
            } else {
                // Step 3: No old URL provided, check for duplicate with current URL
                do {
                    os_log("🔍 Checking for duplicate feeds by current URL: %@", log: log, type: .info, feed.url)
                    
                    let urlPredicate = NSPredicate(format: "url == %@", feed.url)
                    let query = CKQuery(recordType: RecordType.podcastFeed, predicate: urlPredicate)
                    
                    let (matchResults, _) = try await privateDatabase.records(matching: query)
                    
                    // If we found existing feeds with the same URL, update that one instead
                    if let existingMatch = matchResults.first,
                       case .success(let existingRecord) = existingMatch.1,
                       existingRecord.recordID.recordName != feed.id {
                        os_log("🔄 DUPLICATE: Found existing feed with same URL but different ID, updating that one: %@", log: log, type: .info, feed.title)
                        record = existingRecord
                        isExistingRecord = true
                    } else {
                        os_log("✅ No duplicates found, creating new record: %@", log: log, type: .info, feed.title)
                        record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
                    }
                } catch {
                    os_log("⚠️ Duplicate check failed, creating new record: %@", log: log, type: .default, error.localizedDescription)
                    record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
                }
            }
        } catch {
            os_log("⚠️ Error fetching record by ID: %@", log: log, type: .default, error.localizedDescription)
            record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
        }
        
        // Update record fields
        record["title"] = feed.title as CKRecordValue
        record["url"] = feed.url as CKRecordValue
        record["artworkUrl"] = feed.artworkUrl as CKRecordValue?
        record["descriptionText"] = feed.descriptionText as CKRecordValue?
        record["order"] = feed.order as CKRecordValue
        record["lastUpdated"] = Date() as CKRecordValue
        
        // Handle image data
        if let imageData = feed.imageData {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try imageData.write(to: tempURL)
            record["iconData"] = CKAsset(fileURL: tempURL)
        }
        
        // Save the record
        _ = try await privateDatabase.save(record)
        
        if isExistingRecord {
            os_log("✅ UPDATED existing podcast feed in CloudKit: %@ (ID: %@)", log: log, type: .info, feed.title, feed.id)
        } else {
            os_log("✅ CREATED new podcast feed in CloudKit: %@ (ID: %@)", log: log, type: .info, feed.title, feed.id)
        }
    }
    
    /// Delete podcast feed and all associated episode states from CloudKit
    func deletePodcastFeedFromCloudKit(_ feedId: String) async throws {
        os_log("🔄 CloudKit: Starting comprehensive deletion of feed: %@", log: log, type: .info, feedId)
        
        var deletedEpisodeCount = 0
        var feedDeletionSucceeded = false
        var episodeDeletionError: Error?
        var feedDeletionError: Error?
        
        // Step 1: Delete all episode states for this feed first
        do {
            os_log("🗑️ CloudKit: Deleting all episode states for feed: %@", log: log, type: .info, feedId)
            deletedEpisodeCount = try await deleteAllEpisodeStatesForFeed(feedId)
            os_log("✅ CloudKit: Deleted %d episode states for feed %@", log: log, type: .info, deletedEpisodeCount, feedId)
        } catch {
            episodeDeletionError = error
            os_log("⚠️ CloudKit: Failed to delete episode states for feed %@ (will still try to delete feed): %@", log: log, type: .default, feedId, error.localizedDescription)
            // Continue to feed deletion even if episode deletion fails
        }
        
        // Step 2: Delete the feed record using multiple strategies
        do {
            let deletedFeedId = try await deleteFeedRecord(feedId)
            feedDeletionSucceeded = true
            os_log("✅ CloudKit: Successfully deleted podcast feed: %@", log: log, type: .info, deletedFeedId)
        } catch {
            feedDeletionError = error
            os_log("❌ CloudKit: Failed to delete feed record %@: %@", log: log, type: .error, feedId, error.localizedDescription)
        }
        
        // Step 3: Report results and handle errors
        if feedDeletionSucceeded && episodeDeletionError == nil {
            os_log("🎉 CloudKit: Successfully completed comprehensive deletion of feed %@ and %d episode states", log: log, type: .info, feedId, deletedEpisodeCount)
            
            // **CRITICAL FIX**: Trigger cross-device sync notifications after successful CloudKit deletion
            await triggerCrossDeviceDeletionSync(feedId: feedId)
            
        } else if feedDeletionSucceeded && episodeDeletionError != nil {
            os_log("⚠️ CloudKit: Feed deleted but some episode states may remain for %@: %@", log: log, type: .default, feedId, episodeDeletionError!.localizedDescription)
            
            // **CRITICAL FIX**: Still trigger sync even if some episode states failed - feed is gone
            await triggerCrossDeviceDeletionSync(feedId: feedId)
            
        } else if !feedDeletionSucceeded {
            // Feed deletion failed - this is the critical error
            let finalError = feedDeletionError ?? CKError(.internalError)
            
            if let ckError = finalError as? CKError {
                os_log("❌ CloudKit: Feed deletion error code %ld: %@", log: log, type: .error, ckError.code.rawValue, ckError.localizedDescription)
                
                switch ckError.code {
                case .networkUnavailable:
                    os_log("📶 CloudKit: Network unavailable - feed deletion will be retried when network is restored", log: log, type: .default)
                case .quotaExceeded:
                    os_log("💾 CloudKit: Quota exceeded - deletion failed", log: log, type: .error)
                case .requestRateLimited:
                    os_log("⏱️ CloudKit: Rate limited - deletion will be retried", log: log, type: .default)
                default:
                    os_log("❓ CloudKit: Unexpected error during feed deletion", log: log, type: .error)
                }
            }
            
            throw finalError
        }
    }
    
    /// **CRITICAL**: Trigger cross-device sync notifications after CloudKit deletion
    private func triggerCrossDeviceDeletionSync(feedId: String) async {
        os_log("📡 🚨 CRITICAL: Triggering cross-device deletion sync for feed: %@", log: log, type: .info, feedId)
        
        // Get current iCloud account ID to ensure proper account validation
        guard let accountID = getCurrentiCloudAccountID() else {
            os_log("📡 ❌ Cannot get iCloud account ID - aborting cross-device sync", log: log, type: .error)
            print("📡 ❌ SYNC ABORT: No iCloud account ID available for cross-device deletion sync")
            return
        }
        
        // Get episode IDs for this feed before we lose the ability to query them
        let episodeIds = await getEpisodeIdsForDeletedFeed(feedId)
        
        await MainActor.run {
            // Post instant sync notification for immediate cross-device sync
            let syncData: [String: Any] = [
                "feedId": feedId,
                "feedTitle": "Deleted Feed", // We don't have access to the title after deletion
                "episodeIds": episodeIds,
                "actionId": "cloudkit-deletion-\(Date().timeIntervalSince1970)",
                "timestamp": Date().timeIntervalSince1970,
                "icloud_account_id": accountID // **FIX**: Add account ID for validation
            ]
            
            ubiquitousStore.set(syncData, forKey: "instant_podcast_feed_removed")
            // Note: synchronize() is deprecated and unnecessary
            
            os_log("📡 ✅ Posted instant sync notification for cross-device deletion: %@ (account: %@)", log: log, type: .info, feedId, String(accountID.prefix(16)))
            print("📡 🚨 CROSS-DEVICE SYNC: Posted instant deletion notification for feed: \(feedId)")
            print("📡 🆔 iCloud Account ID: \(String(accountID.prefix(16)))...")
            print("📡 📊 Episode IDs to clean up on other devices: \(episodeIds.count)")
        }
    }
    
    /// Get episode IDs for a feed that might be deleted (best effort)
    private func getEpisodeIdsForDeletedFeed(_ feedId: String) async -> [String] {
        // Since we can't easily map episode ID to feed ID from EpisodeStateManager alone,
        // we return an empty array and let the receiving devices handle cleanup through other means
        // (e.g., through CloudKit episode state cleanup or Core Data cascade deletion)
        
        os_log("📡 Cannot determine episode IDs for deleted feed %@ from EpisodeStateManager alone - relying on other cleanup mechanisms", log: log, type: .info, feedId)
        return []
    }
    
    /// Delete feed record using multiple strategies to handle ID mismatches
    private func deleteFeedRecord(_ feedId: String) async throws -> String {
        os_log("🔍 CloudKit: Starting feed deletion strategies for ID: %@", log: log, type: .info, feedId)
        
        // Strategy 1: Try direct deletion by feedId
        os_log("🔍 CloudKit: Strategy 1 - Attempting direct deletion by feedId: %@", log: log, type: .info, feedId)
        do {
            let recordID = CKRecord.ID(recordName: feedId)
            
            // First verify the record exists before trying to delete it
            do {
                let existingRecord = try await privateDatabase.record(for: recordID)
                os_log("✅ CloudKit: Record verified to exist before deletion: %@", log: log, type: .info, existingRecord["title"] as? String ?? feedId)
            } catch CKError.unknownItem {
                os_log("⚠️ CloudKit: Feed not found by ID %@ during verification, trying alternative search", log: log, type: .default, feedId)
                throw CKError(.unknownItem) // Re-throw to trigger Strategy 2
            }
            
            let deletedRecordID = try await privateDatabase.deleteRecord(withID: recordID)
            os_log("✅ CloudKit: Deleted feed by direct ID match: %@", log: log, type: .info, feedId)
            return deletedRecordID.recordName
        } catch CKError.unknownItem {
            os_log("⚠️ CloudKit: Feed not found by ID %@, trying alternative search", log: log, type: .default, feedId)
        } catch {
            os_log("❌ CloudKit: Error during direct feed deletion: %@", log: log, type: .error, error.localizedDescription)
            throw error
        }
        
        // Strategy 2: Search for feed by URL and title from Core Data, then delete
        os_log("🔍 CloudKit: Strategy 2 - Getting feed info from Core Data for alternative search", log: log, type: .info)
        let feedInfo = await getFeedInfoFromCoreData(feedId)
        
        if let url = feedInfo.url, let title = feedInfo.title {
            os_log("🔍 CloudKit: Found feed info - URL: '%@', Title: '%@'", log: log, type: .info, url, title)
            os_log("🔍 CloudKit: Searching CloudKit for feed by URL: '%@'", log: log, type: .info, url)
            
            // Search for feed by URL
            let urlPredicate = NSPredicate(format: "url == %@", url)
            let urlQuery = CKQuery(recordType: RecordType.podcastFeed, predicate: urlPredicate)
            
            do {
                let (matchResults, _) = try await privateDatabase.records(matching: urlQuery)
                os_log("🔍 CloudKit: URL search returned %d results", log: log, type: .info, matchResults.count)
                
                for (recordID, recordResult) in matchResults {
                    switch recordResult {
                    case .success(let record):
                        let recordTitle = record["title"] as? String ?? "Unknown"
                        let recordUrl = record["url"] as? String ?? "Unknown"
                        os_log("🔍 CloudKit: Checking feed - ID: %@, Title: '%@', URL: '%@'", log: log, type: .info, recordID.recordName, recordTitle, recordUrl)
                        
                        if recordTitle == title {
                            // Found matching feed by URL and title
                            os_log("✅ CloudKit: Title match found! Deleting feed with CloudKit ID: %@", log: log, type: .info, recordID.recordName)
                            let deletedRecordID = try await privateDatabase.deleteRecord(withID: record.recordID)
                            os_log("✅ CloudKit: Deleted feed by URL/title match: %@ (CloudKit ID: %@)", log: log, type: .info, title, deletedRecordID.recordName)
                            os_log("⚠️ CloudKit: Feed ID mismatch - Local: %@, CloudKit: %@", log: log, type: .default, feedId, deletedRecordID.recordName)
                            return deletedRecordID.recordName
                        } else {
                            os_log("⚠️ CloudKit: Title mismatch - Expected: '%@', Found: '%@'", log: log, type: .default, title, recordTitle)
                        }
                    case .failure(let error):
                        os_log("⚠️ CloudKit: Failed to read feed record %@: %@", log: log, type: .default, recordID.recordName, error.localizedDescription)
                    }
                }
                
                os_log("⚠️ CloudKit: No feed found matching URL '%@' and title '%@'", log: log, type: .default, url, title)
            } catch {
                os_log("❌ CloudKit: Failed to search for feed by URL: %@", log: log, type: .error, error.localizedDescription)
                throw error
            }
        } else {
            os_log("⚠️ CloudKit: No URL/title found in Core Data for feed %@ (URL: %@, Title: %@)", log: log, type: .default, feedId, feedInfo.url ?? "nil", feedInfo.title ?? "nil")
        }
        
        // Strategy 3: Last resort - search all feeds and try to match by title only
        os_log("🔍 CloudKit: Strategy 3 - Last resort search by title only", log: log, type: .info)
        if let title = feedInfo.title {
            let titlePredicate = NSPredicate(format: "title == %@", title)
            let titleQuery = CKQuery(recordType: RecordType.podcastFeed, predicate: titlePredicate)
            
            do {
                let (matchResults, _) = try await privateDatabase.records(matching: titleQuery)
                os_log("🔍 CloudKit: Title search returned %d results", log: log, type: .info, matchResults.count)
                
                for (recordID, recordResult) in matchResults {
                    switch recordResult {
                    case .success(let record):
                        let recordTitle = record["title"] as? String ?? "Unknown"
                        let recordUrl = record["url"] as? String ?? "Unknown"
                        os_log("🔍 CloudKit: Found feed by title - ID: %@, Title: '%@', URL: '%@'", log: log, type: .info, recordID.recordName, recordTitle, recordUrl)
                        
                        // Delete the first matching title (assuming titles are unique)
                        let deletedRecordID = try await privateDatabase.deleteRecord(withID: record.recordID)
                        os_log("✅ CloudKit: Deleted feed by title match: %@ (CloudKit ID: %@)", log: log, type: .info, title, deletedRecordID.recordName)
                        os_log("⚠️ CloudKit: Feed ID mismatch - Local: %@, CloudKit: %@", log: log, type: .default, feedId, deletedRecordID.recordName)
                        return deletedRecordID.recordName
                    case .failure(let error):
                        os_log("⚠️ CloudKit: Failed to read feed record %@: %@", log: log, type: .default, recordID.recordName, error.localizedDescription)
                    }
                }
            } catch {
                os_log("❌ CloudKit: Failed to search for feed by title: %@", log: log, type: .error, error.localizedDescription)
            }
        }
        
        // If we get here, no feed was found to delete
        os_log("❌ CloudKit: All deletion strategies failed - no feed found to delete", log: log, type: .error)
        throw CKError(.unknownItem)
    }
    
    /// Get feed information from Core Data for alternative searching
    private func getFeedInfoFromCoreData(_ feedId: String) async -> (url: String?, title: String?) {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", feedId)
                request.propertiesToFetch = ["url", "title"]
                request.fetchLimit = 1
                
                do {
                    let feeds = try context.fetch(request)
                    if let feed = feeds.first {
                        os_log("✅ Found feed info in Core Data - URL: %@, Title: %@", log: self.log, type: .info, feed.url ?? "nil", feed.title ?? "nil")
                        continuation.resume(returning: (url: feed.url, title: feed.title))
                    } else {
                        os_log("⚠️ No feed found in Core Data with ID: %@", log: self.log, type: .default, feedId)
                        continuation.resume(returning: (url: nil, title: nil))
                    }
                } catch {
                    os_log("❌ Failed to get feed info from Core Data for %@: %@", log: self.log, type: .error, feedId, error.localizedDescription)
                    continuation.resume(returning: (url: nil, title: nil))
                }
            }
        }
    }
    
    /// Delete all episode states associated with a specific feed from CloudKit
    /// This handles cases where episode states might have different feed IDs than expected
    private func deleteAllEpisodeStatesForFeed(_ feedId: String) async throws -> Int {
        os_log("🔍 CloudKit: Searching for episode states to delete for feed: %@", log: log, type: .info, feedId)
        
        var totalDeletedCount = 0
        
        // Strategy 1: Delete by exact feedId match
        do {
            let exactMatches = try await deleteEpisodeStatesByFeedId(feedId)
            totalDeletedCount += exactMatches
            os_log("✅ CloudKit: Deleted %d episode states with exact feedId match: %@", log: log, type: .info, exactMatches, feedId)
        } catch {
            os_log("⚠️ CloudKit: Failed to delete by exact feedId %@: %@", log: log, type: .default, feedId, error.localizedDescription)
        }
        
        // Strategy 2: If no exact matches found, try to find episode states by episode IDs
        // Get all episode IDs for this feed from Core Data and delete their states
        if totalDeletedCount == 0 {
            os_log("🔍 CloudKit: No exact feedId matches found, searching by episode IDs", log: log, type: .info)
            do {
                let episodeBasedDeletes = try await deleteEpisodeStatesByEpisodeIds(feedId)
                totalDeletedCount += episodeBasedDeletes
                os_log("✅ CloudKit: Deleted %d episode states by episode ID lookup for feed: %@", log: log, type: .info, episodeBasedDeletes, feedId)
            } catch {
                os_log("⚠️ CloudKit: Failed to delete by episode IDs for feed %@: %@", log: log, type: .default, feedId, error.localizedDescription)
            }
        }
        
        return totalDeletedCount
    }
    
    /// Delete episode states by exact feedId match
    private func deleteEpisodeStatesByFeedId(_ feedId: String) async throws -> Int {
        let predicate = NSPredicate(format: "feedId == %@", feedId)
        let query = CKQuery(recordType: RecordType.episodeState, predicate: predicate)
        
        let (matchResults, _) = try await privateDatabase.records(matching: query)
        var recordIDsToDelete: [CKRecord.ID] = []
        
        for (recordID, recordResult) in matchResults {
            switch recordResult {
            case .success(let record):
                recordIDsToDelete.append(record.recordID)
                if let episodeId = record["episodeId"] as? String {
                    os_log("🗑️ CloudKit: Will delete episode state by feedId: %@ (feed: %@)", log: log, type: .debug, episodeId, feedId)
                }
            case .failure(let error):
                os_log("⚠️ CloudKit: Failed to process episode state record %@: %@", log: log, type: .default, recordID.recordName, error.localizedDescription)
            }
        }
        
        if !recordIDsToDelete.isEmpty {
            try await deleteRecordsInBatches(recordIDsToDelete)
        }
        
        return recordIDsToDelete.count
    }
    
    /// Delete episode states by finding episode IDs from Core Data and looking them up in CloudKit
    private func deleteEpisodeStatesByEpisodeIds(_ feedId: String) async throws -> Int {
        // Get episode IDs for this feed from Core Data
        let episodeIds = await getEpisodeIdsForFeedFromCoreData(feedId)
        
        if episodeIds.isEmpty {
            os_log("📊 CloudKit: No episode IDs found in Core Data for feed %@", log: log, type: .info, feedId)
            return 0
        }
        
        os_log("🔍 CloudKit: Found %d episode IDs in Core Data for feed %@, using batch queries", log: log, type: .info, episodeIds.count, feedId)
        
        var recordIDsToDelete: [CKRecord.ID] = []
        var actualFeedIds: Set<String> = []
        
        // Batch the episode lookups to avoid individual queries
        let batchSize = 200 // Conservative batch size for individual record lookups
        let batches = episodeIds.chunked(into: batchSize)
        
        for (batchIndex, batch) in batches.enumerated() {
            os_log("🔍 CloudKit: Processing episode lookup batch %d/%d (%d episode IDs)", log: log, type: .debug, batchIndex + 1, batches.count, batch.count)
            
            // Create record IDs for this batch
            let batchRecordIDs = batch.map {
                Self.episodeStateRecordID(for: CloudEpisodeIdentity(episodeId: $0, feedId: feedId))
            }
            
            // Use batch fetch operation
            do {
                let results = try await privateDatabase.records(for: batchRecordIDs)
                
                for (recordID, recordResult) in results {
                    switch recordResult {
                    case .success(let record):
                        recordIDsToDelete.append(record.recordID)
                        
                        // Track what feedIds these episode states actually have
                        if let actualFeedId = record["feedId"] as? String {
                            actualFeedIds.insert(actualFeedId)
                        }
                        
                        if let episodeId = record["episodeId"] as? String {
                            os_log("🗑️ CloudKit: Will delete episode state by episodeId: %@ (actual feedId: %@)", log: log, type: .debug, episodeId, record["feedId"] as? String ?? "unknown")
                        }
                        
                    case .failure(let error):
                        if let ckError = error as? CKError, ckError.code == .unknownItem {
                            // Episode state doesn't exist - that's fine
                            continue
                        } else {
                            os_log("⚠️ CloudKit: Error fetching episode state %@: %@", log: log, type: .default, recordID.recordName, error.localizedDescription)
                        }
                    }
                }
                
                os_log("✅ CloudKit: Processed batch %d/%d - found %d existing episode states", log: log, type: .debug, batchIndex + 1, batches.count, results.keys.count)
                
            } catch {
                os_log("⚠️ CloudKit: Error in batch episode lookup %d/%d: %@", log: log, type: .default, batchIndex + 1, batches.count, error.localizedDescription)
                // Continue with next batch on error
                continue
            }
        }
        
        // Log the feed ID mismatch for debugging
        if actualFeedIds.count > 0 && !actualFeedIds.contains(feedId) {
            os_log("⚠️ CloudKit: Feed ID mismatch detected! Deleting feed %@ but episode states have feedIds: %@", log: log, type: .default, feedId, Array(actualFeedIds).joined(separator: ", "))
        }
        
        if !recordIDsToDelete.isEmpty {
            os_log("🗑️ CloudKit: Starting batch deletion of %d episode states", log: log, type: .info, recordIDsToDelete.count)
            try await deleteRecordsInBatches(recordIDsToDelete)
        }
        
        return recordIDsToDelete.count
    }
    
    /// Get episode IDs for a feed from Core Data
    private func getEpisodeIdsForFeedFromCoreData(_ feedId: String) async -> [String] {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "feedId == %@", feedId)
                request.propertiesToFetch = ["id"]
                
                do {
                    let episodes = try context.fetch(request)
                    let episodeIds = episodes.compactMap { $0.id }
                    continuation.resume(returning: episodeIds)
                } catch {
                    os_log("❌ Failed to get episode IDs from Core Data for feed %@: %@", log: self.log, type: .error, feedId, error.localizedDescription)
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Delete records in batches to respect CloudKit limits
    private func deleteRecordsInBatches(_ recordIDs: [CKRecord.ID]) async throws {
        let batchSize = 400 // CloudKit limit is 400 records per operation
        let batches = recordIDs.chunked(into: batchSize)
        
        for (batchIndex, batch) in batches.enumerated() {
            os_log("🗑️ CloudKit: Deleting batch %d/%d (%d records)", log: log, type: .debug, batchIndex + 1, batches.count, batch.count)
            
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)
            operation.savePolicy = .allKeys
            operation.qualityOfService = .userInitiated
            
            privateDatabase.add(operation)
            
            os_log("✅ CloudKit: Deleted batch %d/%d (%d records)", log: log, type: .debug, batchIndex + 1, batches.count, batch.count)
        }
    }
    
    // MARK: - Debug Methods
    
    /// Debug method to verify a feed exists in CloudKit
    func debugCheckFeedExists(_ feedId: String) async {
        let recordID = CKRecord.ID(recordName: feedId)
        
        do {
            let record = try await privateDatabase.record(for: recordID)
            os_log("🔍 DEBUG: Feed exists in CloudKit: %@ - Title: %@", log: log, type: .info, feedId, record["title"] as? String ?? "Unknown")
        } catch CKError.unknownItem {
            os_log("🔍 DEBUG: Feed NOT found in CloudKit: %@", log: log, type: .info, feedId)
        } catch {
            os_log("🔍 DEBUG: Error checking feed in CloudKit %@: %@", log: log, type: .error, feedId, error.localizedDescription)
        }
    }
    
    /// Debug method to list all feeds in CloudKit
    func debugListAllFeeds() async {
        do {
            let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
            let (matchResults, _) = try await privateDatabase.records(matching: query)
            
            os_log("🔍 DEBUG: Found %d feeds in CloudKit:", log: log, type: .info, matchResults.count)
            for (recordID, recordResult) in matchResults {
                switch recordResult {
                case .success(let record):
                    let title = record["title"] as? String ?? "Unknown"
                    os_log("🔍 DEBUG: - Feed ID: %@, Title: %@", log: log, type: .info, recordID.recordName, title)
                case .failure(let error):
                    os_log("🔍 DEBUG: - Failed to read feed %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
                }
            }
        } catch {
            os_log("🔍 DEBUG: Failed to list feeds: %@", log: log, type: .error, error.localizedDescription)
        }
    }

}
