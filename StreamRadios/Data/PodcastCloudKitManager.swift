import Foundation
import CloudKit
import CoreData
import os
import Combine

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

/// CloudKit manager for podcast feeds and episode states with proper conflict resolution
class PodcastCloudKitManager: ObservableObject {
    static let shared = PodcastCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "PodcastCloudKit")
    
    // Instant sync using NSUbiquitousKeyValueStore for immediate cross-device data sharing
    private let ubiquitousStore = NSUbiquitousKeyValueStore()
    
    @Published var lastInstantSyncDate: Date?
    
    // CloudKit Record Types
    private enum RecordType {
        static let episodeState = "EpisodeState"
        static let podcastFeed = "PodcastFeed"
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
        setupInstantSync()
        setupCloudKitSubscriptions()
    }
    
    // MARK: - Instant Sync Setup
    
    private func setupInstantSync() {
        print("📡 🔧 SETUP: Starting instant sync setup...")
        
        // Test iCloud availability first
        testICloudAvailability()
        
        // Start observing changes from other devices via NSUbiquitousKeyValueStore
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore
        )
        
        print("📡 🔧 SETUP: Added notification observer for NSUbiquitousKeyValueStore")
        
        // Start syncing with iCloud immediately
        let syncResult = ubiquitousStore.synchronize()
        print("📡 🔧 SETUP: Initial synchronize() result: \(syncResult)")
        
        os_log("📡 Instant sync setup completed", log: log, type: .info)
        
        // Clear any existing test data from previous debug sessions
        clearTestData()
        
        // Run a test sync to verify everything works
        testInstantSync()
    }
    
    /// Test if iCloud is available and properly configured
    private func testICloudAvailability() {
        print("📡 🧪 ICLOUD TEST: Checking iCloud availability...")
        
        if let token = FileManager.default.ubiquityIdentityToken {
            print("📡 ✅ ICLOUD TEST: iCloud account found - token: \(type(of: token))")
        } else {
            print("📡 ❌ ICLOUD TEST: No iCloud account found - user not signed in!")
            return
        }
        
        // Test writing to ubiquitous store
        let testKey = "test_connectivity"
        let testValue = ["timestamp": Date().timeIntervalSince1970, "test": true] as [String: Any]
        
        print("📡 🧪 ICLOUD TEST: Writing test data...")
        ubiquitousStore.set(testValue, forKey: testKey)
        let syncResult = ubiquitousStore.synchronize()
        print("📡 🧪 ICLOUD TEST: Write sync result: \(syncResult)")
        
        // Try to read it back
        if let readBack = ubiquitousStore.object(forKey: testKey) as? [String: Any] {
            print("📡 ✅ ICLOUD TEST: Successfully read back test data: \(readBack)")
        } else {
            print("📡 ❌ ICLOUD TEST: Failed to read back test data!")
        }
        
        // Clean up test data
        ubiquitousStore.removeObject(forKey: testKey)
        ubiquitousStore.synchronize()
    }
    
    /// Test the instant sync mechanism with a dummy sync
    private func testInstantSync() {
        print("📡 🧪 SYNC TEST: Testing instant sync mechanism...")
        
        let testEpisodeId = "test-episode-\(Date().timeIntervalSince1970)"
        
        // This should trigger the sync and we should see logs
        print("📡 🧪 SYNC TEST: Calling syncPodcastFavoriteInstantly with test data...")
        syncPodcastFavoriteInstantly(episodeId: testEpisodeId, isFavorite: true)
        
        // Wait a moment and check if we can read it back
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let storedData = self.ubiquitousStore.object(forKey: "instant_podcast_episode_favorite") as? [String: Any],
               let storedEpisodeId = storedData["episodeId"] as? String,
               storedEpisodeId == testEpisodeId {
                print("📡 ✅ SYNC TEST: Test sync data found in store!")
            } else {
                print("📡 ❌ SYNC TEST: Test sync data NOT found in store!")
            }
            
            // Clean up test data
            self.ubiquitousStore.removeObject(forKey: "instant_podcast_episode_favorite")
            self.ubiquitousStore.synchronize()
        }
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
            if !isValid {
                print("📡 ❌ ACCOUNT VALIDATION: Cross-account sync detected - ignoring data from different account")
                print("📡 🆔 Current account: \(currentAccountID.prefix(16))...")
                print("📡 🆔 Sync account: \(syncAccountID.prefix(16))...")
                
                // Additional debugging: Check if it's potentially the same account with different tokens
                if let currentToken = FileManager.default.ubiquityIdentityToken {
                    print("📡 🔍 DEBUG: Current ubiquity token available: \(type(of: currentToken))")
                    print("📡 🔍 DEBUG: Full current account ID length: \(currentAccountID.count)")
                    print("📡 🔍 DEBUG: Full sync account ID length: \(syncAccountID.count)")
                }
                
                // For debugging: Allow admin override (remove in production)
                if let allowCrossAccount = syncData["allow_cross_account"] as? Bool, allowCrossAccount {
                    print("📡 ⚠️ ADMIN OVERRIDE: Allowing cross-account sync due to debug flag")
                    return true
                }
            } else {
                print("📡 ✅ ACCOUNT VALIDATION: Same account confirmed")
            }
            return isValid
        }
        
        // For backward compatibility, allow sync data without account ID but log warning
        print("📡 ⚠️ ACCOUNT VALIDATION: Sync data missing account ID - allowing for backward compatibility")
        return true
    }
    
    /// Clears any test/debug data from ubiquitous key-value store
    private func clearTestData() {
        print("📡 🧹 Clearing all test sync data...")
        
        // Remove any test feed data
        ubiquitousStore.removeObject(forKey: "instant_podcast_feed_removed")
        ubiquitousStore.removeObject(forKey: "instant_podcast_feed_added")
        ubiquitousStore.removeObject(forKey: "sync_test")
        
        // Clear any other potential test keys
        let testKeys = ["test_feed", "test_podcast", "debug_sync", "test_deletion", "test_addition"]
        for key in testKeys {
            ubiquitousStore.removeObject(forKey: key)
        }
        
        ubiquitousStore.synchronize()
        print("📡 ✅ All test sync data cleared")
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
            ubiquitousStore.synchronize()
            print("📡 ✅ Cleared \(clearedCount) stale sync data entries")
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
            
            // Update local episode state
            EpisodeStateManager.shared.setProgress(for: episodeId, progress: progress)
            EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
            EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
            
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .init("CloudKitDidUpdateEpisodeState"),
                    object: nil,
                    userInfo: [
                        "episodeId": episodeId,
                        "progress": progress,
                        "isFavorite": isFavorite,
                        "isDownloaded": isDownloaded
                    ]
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
        // Extract episode ID from record name
        let episodeId = recordID.recordName
        
        // Clear local episode state
        EpisodeStateManager.shared.setProgress(for: episodeId, progress: 0.0)
        EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: false)
        EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
        
        await MainActor.run {
            NotificationCenter.default.post(
                name: .init("CloudKitDidDeleteEpisodeState"),
                object: nil,
                userInfo: ["episodeId": episodeId]
            )
        }
        os_log("✅ Handled episode state deletion from CloudKit: %@", log: log, type: .info, episodeId)
    }
    
    @objc private func ubiquitousKeyValueStoreDidChange(_ notification: Notification) {
        print("📡 🔔 NOTIFICATION TRIGGERED: ubiquitousKeyValueStoreDidChange called!")
        print("📡 🔔 NOTIFICATION INFO: \(notification)")
        
        guard let userInfo = notification.userInfo else {
            print("📡 ❌ NOTIFICATION: No userInfo in notification")
            return
        }
        
        print("📡 🔔 NOTIFICATION: UserInfo keys: \(userInfo.keys)")
        
        guard let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            os_log("📡 SYNC RECEIVE FAILED: No keys in notification", log: log, type: .error)
            print("📡 SYNC RECEIVE FAILED: No keys in notification")
            print("📡 SYNC RECEIVE FAILED: UserInfo: \(userInfo)")
            return
        }
        
        os_log("📡 🚨 SYNC NOTIFICATION RECEIVED: Keys changed: %@", log: log, type: .info, keys.joined(separator: ", "))
        print("📡 🚨 SYNC NOTIFICATION RECEIVED: Keys changed: \(keys.joined(separator: ", "))")
        print("📡 📝 Full notification userInfo: \(userInfo)")
        
        // Log what data is available for each key
        for key in keys {
            if let data = ubiquitousStore.object(forKey: key) {
                print("📡 📂 DATA FOR KEY '\(key)': \(data)")
            } else {
                print("📡 ❌ NO DATA FOR KEY '\(key)'")
            }
        }
        
        // Check if we have the critical deletion key
        if keys.contains("instant_podcast_feed_removed") {
            print("📡 🎯 CRITICAL DELETION KEY DETECTED: instant_podcast_feed_removed")
        }
        
        DispatchQueue.main.async {
            self.lastInstantSyncDate = Date()
            
            for key in keys {
                switch key {
                case "instant_podcast_progress":
                    print("📡 🔔 Processing instant podcast progress sync")
                    self.handleInstantPodcastProgressSync()
                case "instant_radio_favorite":
                    print("📡 🔔 Processing instant radio favorite sync")
                    self.handleInstantRadioFavoriteSync()
                case "instant_radio_station_added":
                    print("📡 🔔 Processing instant radio station added sync")
                    self.handleInstantRadioStationAddedSync()
                case "instant_radio_station_removed":
                    print("📡 🔔 Processing instant radio station removed sync")
                    self.handleInstantRadioStationRemovedSync()
                case "instant_podcast_feed_added":
                    print("📡 🔔 Processing instant podcast feed added sync")
                    self.handleInstantPodcastFeedAddedSync()
                case "instant_podcast_feed_progress":
                    print("📡 🔔 Processing instant podcast feed progress sync")
                    self.handleInstantPodcastFeedProgressSync()
                case "instant_podcast_feed_removed":
                    print("📡 🔔 CRITICAL: Processing instant podcast feed DELETION sync")
                    self.handleInstantPodcastFeedRemovedSync()
                case "instant_podcast_episode_favorite":
                    print("📡 🔔 FAVORITE SYNC TRIGGER: Processing instant podcast episode favorite sync")
                    print("📡 🔔 FAVORITE SYNC TRIGGER: This device received a favorite change from another device")
                    self.handleInstantPodcastFavoriteSync()
                case "instant_podcast_episode_download":
                    print("📡 🔔 Processing instant podcast episode download sync")
                    self.handleInstantPodcastDownloadSync()
                default:
                    print("📡 ⚠️ Unknown sync key received: \(key)")
                    break
                }
            }
        }
    }
    
    private func handleInstantPodcastProgressSync() {
        guard let progressData = ubiquitousStore.object(forKey: "instant_podcast_progress") as? [String: Any],
              let episodeId = progressData["episodeId"] as? String,
              let progress = progressData["progress"] as? Double else {
            return
        }
        
        // Update local episode state immediately
        EpisodeStateManager.shared.setProgress(for: episodeId, progress: progress)
        
        os_log("📡 Received instant podcast progress sync: %@ (%.2f)", log: log, type: .info, episodeId, progress)
        
        // Notify other parts of the app
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastProgress"),
            object: nil,
            userInfo: ["episodeId": episodeId, "progress": progress]
        )
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
        
        os_log("📡 SYNC RECEIVED: Feed removal %@ (%@) with %d episodes, actionId: %@", log: log, type: .info, feedTitle, feedId, episodeIds.count, actionId)
        print("📡 🎯 SYNC RECEIVED: Feed removal '\(feedTitle)' (\(feedId)) with \(episodeIds.count) episodes")
        print("📡 🆔 Action ID: \(actionId)")
        
        // Notify PodcastViewModel to remove the feed and clean up episodes
        NotificationCenter.default.post(
            name: .init("InstantSyncDidRemovePodcastFeed"),
            object: nil,
            userInfo: ["feedId": feedId, "feedTitle": feedTitle, "episodeIds": episodeIds, "actionId": actionId]
        )
        
        print("📡 📨 Posted InstantSyncDidRemovePodcastFeed notification")
    }
    
    private func handleInstantPodcastFavoriteSync() {
        print("📡 🔔 FAVORITE SYNC HANDLER: Starting podcast favorite sync processing...")
        
        guard let favoriteData = ubiquitousStore.object(forKey: "instant_podcast_episode_favorite") as? [String: Any] else {
            print("📡 ❌ FAVORITE SYNC FAILED: No data found for instant_podcast_episode_favorite")
            return
        }
        
        print("📡 🔔 FAVORITE SYNC DATA: Raw data received: \(favoriteData)")
        
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
        
        print("📡 🔔 FAVORITE SYNC VALID: Episode \(episodeId) favorite \(isFavorite)")
        
        os_log("📡 Received instant podcast favorite sync: %@ (favorite: %@)", log: log, type: .info, episodeId, isFavorite ? "YES" : "NO")
        
        // Notify PodcastViewModel to update the episode favorite status
        print("📡 🔔 FAVORITE SYNC NOTIFICATION: Sending InstantSyncDidUpdatePodcastFavorite notification...")
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastFavorite"),
            object: nil,
            userInfo: ["episodeId": episodeId, "isFavorite": isFavorite]
        )
        print("📡 ✅ FAVORITE SYNC NOTIFICATION SENT: Notification posted successfully")
    }
    
    private func handleInstantPodcastDownloadSync() {
        guard let downloadData = ubiquitousStore.object(forKey: "instant_podcast_episode_download") as? [String: Any],
              let episodeId = downloadData["episodeId"] as? String,
              let isDownloaded = downloadData["isDownloaded"] as? Bool else {
            return
        }
        
        os_log("📡 Received instant podcast download sync: %@ (downloaded: %@)", log: log, type: .info, episodeId, isDownloaded ? "YES" : "NO")
        
        // Notify PodcastViewModel to update the episode download status
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdatePodcastDownload"),
            object: nil,
            userInfo: ["episodeId": episodeId, "isDownloaded": isDownloaded]
        )
    }
    
    // MARK: - Public Instant Sync Methods
    
    /// Instantly sync podcast progress across devices
    func syncPodcastProgressInstantly(episodeId: String, progress: Double) {
        let progressData: [String: Any] = [
            "episodeId": episodeId,
            "progress": progress,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(progressData, forKey: "instant_podcast_progress")
        let syncResult = ubiquitousStore.synchronize()
        
        os_log("📡 SYNC ATTEMPT: Podcast progress for %@ (%.2f) - Sync result: %@", log: log, type: .info, episodeId, progress, syncResult ? "SUCCESS" : "FAILED")
        print("📡 SYNC ATTEMPT: Podcast progress for \(episodeId) (\(progress)) - Sync result: \(syncResult)")
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
        ubiquitousStore.synchronize()
        
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
        let syncResult = ubiquitousStore.synchronize()
        
        os_log("📡 SYNC ATTEMPT: Radio favorite for %@ (%@) - Sync result: %@", log: log, type: .info, stationId, isFavorite ? "YES" : "NO", syncResult ? "SUCCESS" : "FAILED")
        print("📡 SYNC ATTEMPT: Radio favorite for \(stationId) (\(isFavorite)) - Sync result: \(syncResult)")
    }
    
    /// Instantly sync radio station addition across devices
    func syncRadioStationAddedInstantly(station: [String: Any]) {
        let stationData: [String: Any] = [
            "station": station,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(stationData, forKey: "instant_radio_station_added")
        ubiquitousStore.synchronize()
        
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
        ubiquitousStore.synchronize()
        
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
        ubiquitousStore.synchronize()
        
        if let feedTitle = feedData["title"] as? String {
            os_log("📡 Instantly synced podcast feed addition: %@", log: log, type: .info, feedTitle)
        }
    }
    
    /// Instantly sync podcast feed removal across devices
    func syncPodcastFeedRemovedInstantly(feedId: String, feedTitle: String, episodeIds: [String]) {
        guard let accountID = getCurrentiCloudAccountID() else {
            print("📡 ❌ Cannot sync feed removal - no iCloud account available")
            return
        }
        
        let removalData: [String: Any] = [
            "feedId": feedId,
            "feedTitle": feedTitle,
            "episodeIds": episodeIds,
            "timestamp": Date().timeIntervalSince1970,
            "actionId": UUID().uuidString,  // Unique action ID to prevent conflicts
            "icloud_account_id": accountID
        ]
        
        print("📡 🚀 FEED DELETION SYNC: Starting sync for feed '\(feedTitle)' (\(feedId))")
        print("📡 📊 Episode count: \(episodeIds.count)")
        print("📡 📝 Data to sync: \(removalData)")
        
        ubiquitousStore.set(removalData, forKey: "instant_podcast_feed_removed")
        let syncResult = ubiquitousStore.synchronize()
        
        os_log("📡 SYNC SEND: Feed removal %@ (%@) with %d episodes, result: %@", log: log, type: .info, feedTitle, feedId, episodeIds.count, syncResult ? "SUCCESS" : "FAILED")
        print("📡 SYNC SEND: Feed removal \(feedTitle) (\(feedId)) with \(episodeIds.count) episodes, result: \(syncResult)")
        
        // Test: try to read back immediately to verify
        if let readBack = ubiquitousStore.object(forKey: "instant_podcast_feed_removed") as? [String: Any] {
            print("📡 ✅ VERIFICATION: Successfully read back data: \(readBack)")
        } else {
            print("📡 ❌ VERIFICATION: Failed to read back data immediately")
        }
    }
    
    /// Instantly sync podcast episode favorite status across devices
    func syncPodcastFavoriteInstantly(episodeId: String, isFavorite: Bool) {
        print("📡 🚀 FAVORITE SYNC SEND: Starting favorite sync for episode \(episodeId) -> \(isFavorite)")
        
        // Add iCloud account info for validation
        let currentToken = FileManager.default.ubiquityIdentityToken
        let accountInfo = currentToken != nil ? "\(type(of: currentToken!))" : "nil"
        
        let favoriteData: [String: Any] = [
            "episodeId": episodeId,
            "isFavorite": isFavorite,
            "timestamp": Date().timeIntervalSince1970,
            "accountId": accountInfo
        ]
        
        print("📡 🚀 FAVORITE SYNC DATA: Sending data: \(favoriteData)")
        
        ubiquitousStore.set(favoriteData, forKey: "instant_podcast_episode_favorite")
        let syncResult = ubiquitousStore.synchronize()
        
        print("📡 🚀 FAVORITE SYNC RESULT: iCloud sync result: \(syncResult ? "✅ SUCCESS" : "❌ FAILED")")
        
        os_log("📡 Instantly synced podcast favorite: %@ (favorite: %@) - Result: %@", log: log, type: .info, episodeId, isFavorite ? "YES" : "NO", syncResult ? "SUCCESS" : "FAILED")
        
        // Also log the ubiquitous store status
        if let storedData = ubiquitousStore.object(forKey: "instant_podcast_episode_favorite") as? [String: Any] {
            print("📡 🚀 FAVORITE SYNC VERIFY: Data successfully stored in iCloud: \(storedData)")
        } else {
            print("📡 ❌ FAVORITE SYNC ERROR: Failed to verify data storage in iCloud")
        }
    }
    
    /// Instantly sync podcast episode download status across devices
    func syncPodcastDownloadInstantly(episodeId: String, isDownloaded: Bool) {
        let downloadData: [String: Any] = [
            "episodeId": episodeId,
            "isDownloaded": isDownloaded,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        ubiquitousStore.set(downloadData, forKey: "instant_podcast_episode_download")
        ubiquitousStore.synchronize()
        
        os_log("📡 Instantly synced podcast download: %@ (downloaded: %@)", log: log, type: .info, episodeId, isDownloaded ? "YES" : "NO")
        print("📡 SYNC ATTEMPT: Podcast download for \(episodeId) (\(isDownloaded))")
    }
    
    // MARK: - Episode State CloudKit Sync
    
    /// Save episode state to CloudKit with proper conflict resolution
    func saveEpisodeState(episodeId: String, feedId: String, progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool) async {

        
        do {
            try await saveEpisodeStateToCloudKit(episodeId, feedId: feedId, progress: progress, isFavorite: isFavorite, isDownloaded: isDownloaded, isPlayed: isPlayed)
            os_log("💾 ✅ Successfully saved episode state to CloudKit: %@", log: log, type: .info, episodeId)
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
        
        let recordID = CKRecord.ID(recordName: "episode_state_\(episodeId)")
        
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
        
        // Create CloudKit reference to the podcast feed for automatic deletion
        let feedRecordID = CKRecord.ID(recordName: feedId)
        let feedReference = CKRecord.Reference(recordID: feedRecordID, action: .deleteSelf)
        record["podcastFeed"] = feedReference as CKRecordValue
        
        // Save with proper policy
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys // Only update changed fields
        operation.qualityOfService = .userInitiated
        
        privateDatabase.add(operation)
        os_log("✅ Saved episode state to CloudKit with feed reference: %@ -> %@", log: log, type: .info, episodeId, feedId)
    }
    
    /// Fetch episode state from CloudKit
    func fetchEpisodeStateFromCloudKit(_ episodeId: String) async throws -> (progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool, feedId: String?)? {
        let recordID = CKRecord.ID(recordName: "episode_state_\(episodeId)")
        
        do {
            let record = try await privateDatabase.record(for: recordID)
            
            let progress = record["progress"] as? Double ?? 0.0
            let isFavorite = record["isFavorite"] as? Bool ?? false
            let isDownloaded = record["isDownloaded"] as? Bool ?? false
            let isPlayed = record["isPlayed"] as? Bool ?? false
            let feedId = record["feedId"] as? String  // Extract feedId for reference
            
            return (progress: progress, isFavorite: isFavorite, isDownloaded: isDownloaded, isPlayed: isPlayed, feedId: feedId)
        } catch CKError.unknownItem {
            // Episode state doesn't exist in CloudKit yet - this is normal
            return nil
        } catch let networkError where networkError is CKError && (networkError as! CKError).code == .networkUnavailable || (networkError as! CKError).code == .networkFailure {
            // Network issues - rethrow so caller can handle retries
            throw networkError
        } catch {
            // For other CloudKit errors, log and return nil instead of crashing
            os_log("⚠️ CloudKit error fetching episode state for %@: %@", log: log, type: .default, episodeId, error.localizedDescription)
            return nil
        }
    }
    
    /// Sync episode states from CloudKit with different behavior for fresh install vs upgrade
    /// - For fresh install: sync isFavorite but NOT isDownloaded (files don't exist)
    /// - For upgrade: sync both isFavorite and isDownloaded (files might still exist)
    /// - Returns: Tuple of (Array of episode state updates that should be saved to Core Data, Boolean indicating success)
    func syncEpisodeStatesFromCloudKit(for episodeIds: [String], isFreshInstall: Bool) async -> (updates: [EpisodeStateUpdate], success: Bool) {
        // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
        let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
        let finalIsFreshInstall = isFreshInstall && !isDefiniteUpgrade
        
        os_log("🔄 Starting episode state sync from CloudKit for %d episodes (fresh install: %@, definite upgrade: %@)", 
               log: log, type: .info, episodeIds.count, finalIsFreshInstall ? "YES" : "NO", isDefiniteUpgrade ? "YES" : "NO")
        
        var syncedCount = 0
        var coreDataUpdates: [EpisodeStateUpdate] = []
        var syncSuccess = false
        
        let episodeIdSet = Set(episodeIds)
        
        do {
            // Use bulk fetch for better performance
            let allCloudStates = try await fetchAllEpisodeStatesFromCloudKit()
            
            // Process CloudKit states
            for (episodeId, cloudState) in allCloudStates {
                // Only process if this episode exists locally
                guard episodeIdSet.contains(episodeId) else { continue }

                // Always sync progress, isFavorite, and isPlayed to EpisodeStateManager
                // Apply CloudKit progress when it exists - this is the user's data from other devices
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: cloudState.progress)
                if cloudState.progress > 0 {
                    os_log("🔄 Applying CloudKit progress %.2f for episode %@", 
                           log: log, type: .info, cloudState.progress, episodeId)
                }
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: cloudState.isFavorite)
                
                // Handle isDownloaded - ENHANCED with upgrade protection
                let finalIsDownloaded: Bool
                if cloudState.isDownloaded {
                    if finalIsFreshInstall {
                        // Fresh install: don't restore download state as files don't exist
                        finalIsDownloaded = false
                        EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                    } else {
                        // Upgrade: restore download state as files might exist
                        finalIsDownloaded = true
                        EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: true)
                    }
                } else {
                    // CloudKit shows not downloaded
                    if isDefiniteUpgrade {
                        // During upgrades, check local state before clearing
                        let localDownloadState = EpisodeStateManager.shared.isDownloaded(episodeId)
                        if localDownloadState {
                            os_log("⚠️ Upgrade: Local download state exists but CloudKit shows not downloaded for %@ - preserving local state", 
                                   log: log, type: .info, episodeId)
                            finalIsDownloaded = true
                        } else {
                            finalIsDownloaded = false
                            EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                        }
                    } else {
                        // Fresh install or normal operation - safe to set to false
                        finalIsDownloaded = false
                        EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                    }
                }
                
                // Prepare Core Data update - always apply CloudKit progress when it exists
                coreDataUpdates.append(EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: cloudState.progress,
                    isFavorite: cloudState.isFavorite,
                    isDownloaded: finalIsDownloaded,
                    isPlayed: cloudState.isPlayed
                ))
                
                syncedCount += 1
            }
            
            // Consider sync successful if we processed at least some episodes from CloudKit
            syncSuccess = syncedCount > 0 || allCloudStates.isEmpty
            
            // CRITICAL FIX: Force save all episode states immediately after CloudKit sync to prevent loss on force close
            EpisodeStateManager.shared.forceSave()
            
            os_log("✅ Bulk CloudKit sync completed: %d synced, %d prepared for Core Data, states force-saved", 
                   log: log, type: .info, syncedCount, coreDataUpdates.count)

        } catch {
            os_log("❌ Failed to bulk fetch episode states from CloudKit: %@", log: log, type: .error, error.localizedDescription)
            
            // Fallback to individual fetches with batching to avoid overwhelming CloudKit
            os_log("🔄 Falling back to batched individual fetches", log: log, type: .info)
            let batchSize = 50 // Smaller batches to avoid rate limits
            let batches = episodeIds.chunked(into: batchSize)
            
            var individualSyncErrors = 0
            
            for (batchIndex, batch) in batches.enumerated() {
                
                for episodeId in batch {
                    do {
                        if let cloudState = try await fetchEpisodeStateFromCloudKit(episodeId) {
                            // Always sync progress, isFavorite, and isPlayed to EpisodeStateManager
                            // Apply CloudKit progress when it exists - this is the user's data from other devices
                            EpisodeStateManager.shared.setProgress(for: episodeId, progress: cloudState.progress)
                            if cloudState.progress > 0 {
                                os_log("🔄 Applying CloudKit progress %.2f for episode %@", 
                                       log: log, type: .info, cloudState.progress, episodeId)
                            }
                            EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: cloudState.isFavorite)
                            
                            let finalIsDownloaded: Bool
                            if cloudState.isDownloaded {
                                if finalIsFreshInstall {
                                    // Fresh install: don't restore download state as files don't exist
                                    finalIsDownloaded = false
                                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                } else {
                                    // Upgrade: restore download state as files might exist
                                    finalIsDownloaded = true
                                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: true)
                                }
                            } else {
                                // CloudKit shows not downloaded
                                if isDefiniteUpgrade {
                                    // During upgrades, check local state before clearing
                                    let localDownloadState = EpisodeStateManager.shared.isDownloaded(episodeId)
                                    if localDownloadState {
                                        os_log("⚠️ Upgrade: Local download state exists but CloudKit shows not downloaded for %@ - preserving local state", 
                                               log: log, type: .info, episodeId)
                                        finalIsDownloaded = true
                                    } else {
                                        finalIsDownloaded = false
                                        EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                    }
                                } else {
                                    // Fresh install or normal operation - safe to set to false
                                    finalIsDownloaded = false
                                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                }
                            }
                            
                            // Prepare Core Data update - always apply CloudKit progress when it exists
                            
                            coreDataUpdates.append(EpisodeStateUpdate(
                                episodeId: episodeId,
                                progress: cloudState.progress,
                                isFavorite: cloudState.isFavorite,
                                isDownloaded: finalIsDownloaded,
                                isPlayed: cloudState.isPlayed
                            ))
                            
                            syncedCount += 1
                        } else {
                            // Episode has no CloudKit state yet - this is normal for new episodes
                        }
                    } catch CKError.unknownItem {
                        // Episode doesn't exist in CloudKit - this is normal, not an error
                    } catch {
                        // Only log actual errors (network issues, permissions, etc.)
                        os_log("❌ Failed to sync episode state for %@: %@", log: log, type: .error, episodeId, error.localizedDescription)
                        individualSyncErrors += 1
                    }
                }
                
                // Add small delay between batches to respect rate limits
                if batchIndex < batches.count - 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                }
            }
            
            // Consider sync successful if we managed to sync some episodes despite errors
            let totalEpisodesAttempted = episodeIds.count
            let errorRate = Double(individualSyncErrors) / Double(totalEpisodesAttempted)
            syncSuccess = errorRate < 0.5 // Success if less than 50% of episodes failed
            
            // CRITICAL FIX: Force save all episode states after individual fallback sync to prevent loss on force close
            EpisodeStateManager.shared.forceSave()
            
            os_log("✅ Individual CloudKit sync completed: %d synced, %d errors, success: %@, states force-saved", 
                   log: log, type: .info, syncedCount, individualSyncErrors, syncSuccess ? "YES" : "NO")
        }
        
        os_log("✅ Episode state sync completed: %d synced, %d prepared for Core Data, success: %@", 
               log: log, type: .info, syncedCount, coreDataUpdates.count, syncSuccess ? "YES" : "NO")
        
        // Return the updates and success status
        return (updates: coreDataUpdates, success: syncSuccess)
    }
    
    /// Fetch all episode states from CloudKit (for bulk sync operations)
    func fetchAllEpisodeStatesFromCloudKit() async throws -> [String: (progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool, feedId: String?)] {
        os_log("🔄 Fetching all episode states from CloudKit", log: log, type: .info)
        
        let query = CKQuery(recordType: RecordType.episodeState, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "lastUpdated", ascending: false)]
        
        var episodeStates: [String: (progress: Double, isFavorite: Bool, isDownloaded: Bool, isPlayed: Bool, feedId: String?)] = [:]
        
        do {
            let (matchResults, _) = try await privateDatabase.records(matching: query)
            
            for (recordID, recordResult) in matchResults {
                switch recordResult {
                case .success(let record):
                    if let episodeId = record["episodeId"] as? String {
                        let progress = record["progress"] as? Double ?? 0.0
                        let isFavorite = record["isFavorite"] as? Bool ?? false
                        let isDownloaded = record["isDownloaded"] as? Bool ?? false
                        let isPlayed = record["isPlayed"] as? Bool ?? false
                        let feedId = record["feedId"] as? String
                        
                        episodeStates[episodeId] = (progress: progress, isFavorite: isFavorite, isDownloaded: isDownloaded, isPlayed: isPlayed, feedId: feedId)
                    }
                case .failure(let error):
                    os_log("❌ Failed to fetch episode state record %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
                }
            }
            
            os_log("✅ Fetched %d episode states from CloudKit", log: log, type: .info, episodeStates.count)
            return episodeStates
            
        } catch {
            os_log("❌ Failed to fetch episode states from CloudKit: %@", log: log, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Podcast Feed CloudKit Sync
    
    /// Sync from CloudKit to local storage - fetch all podcast feeds
    func syncFromCloudKit() async throws -> [PodcastFeed] {
        os_log("🔄 Starting CloudKit sync for podcast feeds", log: log, type: .info)
        
        let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
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
            episodes: [] // Episodes will be loaded separately via RSS
        )
    }
    
    /// Save podcast feed to CloudKit with best-effort duplicate prevention
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed) async throws {
        let recordID = CKRecord.ID(recordName: feed.id)
        
        // Step 1: Best-effort duplicate check - if successful and finds duplicates, update instead
        // If duplicate check fails due to network issues, proceed with normal save
        do {
            os_log("🔍 Checking for duplicate feeds by URL: %@", log: log, type: .info, feed.url)
            
            let urlPredicate = NSPredicate(format: "url == %@", feed.url)
            let query = CKQuery(recordType: RecordType.podcastFeed, predicate: urlPredicate)
            // Note: Removed sortDescriptors because modificationDate is not marked as sortable in CloudKit schema
            
            let (matchResults, _) = try await privateDatabase.records(matching: query)
            
            // If we found existing feeds with the same URL, update the first one instead
            if let existingMatch = matchResults.first,
               case .success(let existingRecord) = existingMatch.1 {
                os_log("🔄 Found existing feed with same URL, updating instead of creating: %@", log: log, type: .info, feed.title)
                
                // Update the existing record
                existingRecord["title"] = feed.title as CKRecordValue
                existingRecord["url"] = feed.url as CKRecordValue
                existingRecord["artworkUrl"] = feed.artworkUrl as CKRecordValue?
                existingRecord["descriptionText"] = feed.descriptionText as CKRecordValue?
                existingRecord["lastUpdated"] = Date() as CKRecordValue
                
                // Handle image data
                if let imageData = feed.imageData {
                    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                    try imageData.write(to: tempURL)
                    existingRecord["iconData"] = CKAsset(fileURL: tempURL)
                }
                
                // Save the updated existing record
                _ = try await privateDatabase.save(existingRecord)
                os_log("✅ Updated existing podcast feed in CloudKit: %@", log: log, type: .info, feed.title)
                return
            }
            
            os_log("✅ No duplicate feeds found by URL, proceeding with new record: %@", log: log, type: .info, feed.title)
            
        } catch {
            // If duplicate check fails (network issues, etc.), proceed with normal save
            // This ensures feeds can still be saved even if CloudKit is having issues
            os_log("⚠️ Duplicate check failed, proceeding with normal save anyway: %@", log: log, type: .default, error.localizedDescription)
        }
        
        // Step 2: Try to fetch record by ID or create new
        var record: CKRecord
        do {
            record = try await privateDatabase.record(for: recordID)
            os_log("🔄 Found existing feed by ID, updating: %@", log: log, type: .info, feed.title)
        } catch CKError.unknownItem {
            os_log("✅ Creating new feed record: %@", log: log, type: .info, feed.title)
            record = CKRecord(recordType: RecordType.podcastFeed, recordID: recordID)
        }
        
        // Update record fields
        record["title"] = feed.title as CKRecordValue
        record["url"] = feed.url as CKRecordValue
        record["artworkUrl"] = feed.artworkUrl as CKRecordValue?
        record["descriptionText"] = feed.descriptionText as CKRecordValue?
        record["lastUpdated"] = Date() as CKRecordValue
        
        // Handle image data
        if let imageData = feed.imageData {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try imageData.write(to: tempURL)
            record["iconData"] = CKAsset(fileURL: tempURL)
        }
        
        // Save the record
        _ = try await privateDatabase.save(record)
        os_log("✅ Saved podcast feed to CloudKit: %@", log: log, type: .info, feed.title)
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
            ubiquitousStore.synchronize()
            
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
            let batchRecordIDs = batch.map { CKRecord.ID(recordName: "episode_state_\($0)") }
            
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
