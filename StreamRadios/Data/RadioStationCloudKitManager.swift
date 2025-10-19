import Foundation
import CloudKit
import CoreData
import os
import Combine

// Import required types and models
import SwiftUI // For MainActor

/// CloudKit manager for radio stations with comprehensive real-time sync capabilities
class RadioStationCloudKitManager: ObservableObject {
    static let shared = RadioStationCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "RadioStationCloudKit")
    
    // Instant sync using NSUbiquitousKeyValueStore for immediate cross-device data sharing
    private let ubiquitousStore = NSUbiquitousKeyValueStore()
    
    @Published var lastInstantSyncDate: Date?
    
    // Prevent concurrent batch save operations
    private var isBatchSaveInProgress = false
    private let batchSaveLock = NSLock()
    
    // CloudKit Record Types
    private enum RecordType {
        static let radioStation = "streamingRadios"
    }
    
    // Instant sync keys for NSUbiquitousKeyValueStore
    private enum InstantSyncKeys {
        static let stationUpdated = "instant_station_updated"
        static let stationDeleted = "instant_station_deleted"
        static let stationAdded = "instant_station_added"
        static let favoriteChanged = "instant_favorite_changed"
        static let orderChanged = "instant_order_changed"
        static let bulkStationUpdated = "instant_bulk_station_updated"
        static let bulkStationDeleted = "instant_bulk_station_deleted"
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
        setupInstantSync()
        setupCloudKitSubscriptions()
    }
    
    // MARK: - Instant Sync Setup
    
    private func setupInstantSync() {
        os_log("📡 RADIO SYNC: Setting up instant sync for radio stations", log: log, type: .info)
        
        // Note: synchronize() is deprecated and unnecessary - NSUbiquitousKeyValueStore syncs automatically
        // Removed to fix Swift Concurrency warning
        
        // Listen for changes from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore
        )
        
        print("📡 RADIO SYNC: Instant sync setup completed")
    }
    
    @objc private func ubiquitousKeyValueStoreDidChange(_ notification: Notification) {
        // CRITICAL: Defer processing during fresh install sync to prevent race conditions
        if DataSyncManager.shared.isFreshInstallSyncInProgress {
            print("🚨 RADIO DEFERRED: Fresh install sync in progress - deferring CloudKit notification processing")
            return
        }
        
        guard let userInfo = notification.userInfo,
              let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No keys in notification", log: log, type: .error)
            return
        }
        
        // Filter out podcast-related keys early to prevent processing
        let radioKeys = keys.filter { key in
            !key.hasPrefix("instant_podcast_") && 
            !key.hasPrefix("StreamRadios_Episode") && 
            !key.hasPrefix("podcast_episodes_") &&
            !key.contains("podcast")
        }
        
        // Only process if we have radio-related keys
        guard !radioKeys.isEmpty else {
            return // Silently ignore podcast-only notifications
        }
        
        os_log("📡 🚨 RADIO SYNC NOTIFICATION RECEIVED: Keys changed: %@", log: log, type: .info, radioKeys.joined(separator: ", "))
        
        // Use background queue for sync processing to prevent main thread blocking
        DispatchQueue.global(qos: .userInitiated).async {
            let syncDate = Date()
            
            for key in radioKeys {
                switch key {
                case InstantSyncKeys.stationUpdated:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantStationUpdatedSync()
                    }
                case InstantSyncKeys.stationDeleted:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantStationDeletedSync()
                    }
                case InstantSyncKeys.stationAdded:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantStationAddedSync()
                    }
                case InstantSyncKeys.favoriteChanged:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantFavoriteChangedSync()
                    }
                case InstantSyncKeys.orderChanged:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantOrderChangedSync()
                    }
                case InstantSyncKeys.bulkStationUpdated:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantBulkStationUpdatedSync()
                    }
                case InstantSyncKeys.bulkStationDeleted:
                    Task { @MainActor in
                        self.lastInstantSyncDate = syncDate
                        self.handleInstantBulkStationDeletedSync()
                    }
                default:
                    os_log("📡 RADIO SYNC: Unknown radio sync key: %@", log: self.log, type: .debug, key)
                }
            }
        }
    }
    
    // MARK: - CloudKit Push Notifications Setup
    
    /// Set up CloudKit subscriptions for automatic cross-device sync notifications
    private func setupCloudKitSubscriptions() {
        Task {
            await setupRadioStationSubscription()
            os_log("🔔 RADIO CloudKit subscriptions setup completed", log: log, type: .info)
        }
    }
    
    private func setupRadioStationSubscription() async {
        let subscriptionID = "RadioStationSubscription"
        
        // Check if subscription already exists
        do {
            let existingSubscription = try await privateDatabase.subscription(for: subscriptionID)
            os_log("🔔 RADIO CloudKit subscription already exists: %@", log: log, type: .info, subscriptionID)
            return
        } catch CKError.unknownItem {
            // Subscription doesn't exist, create it
            os_log("🔔 RADIO Creating new CloudKit subscription: %@", log: log, type: .info, subscriptionID)
        } catch {
            os_log("🔔 RADIO Error checking for existing subscription: %@", log: log, type: .error, error.localizedDescription)
            return
        }
        
        // Create subscription for radio station changes
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: RecordType.radioStation,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.category = "RADIO_STATION_SYNC"
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await privateDatabase.save(subscription)
            os_log("✅ RADIO CloudKit subscription created successfully: %@", log: log, type: .info, subscriptionID)
        } catch {
            os_log("❌ RADIO Failed to create CloudKit subscription: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - CloudKit Notification Handling
    
    func handleCloudKitSubscriptionNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("❌ RADIO Invalid CloudKit notification format", log: log, type: .error)
            return
        }
        
        os_log("🔔 RADIO Received CloudKit notification: %@", log: log, type: .info, String(describing: ckNotification.notificationType))
        
        switch ckNotification.notificationType {
        case .query:
            if let queryNotification = ckNotification as? CKQueryNotification {
                await handleQueryNotification(queryNotification)
            }
        default:
            os_log("🔔 RADIO Unhandled notification type: %@", log: log, type: .debug, String(describing: ckNotification.notificationType))
        }
    }
    
    private func handleQueryNotification(_ notification: CKQueryNotification) async {
        guard let recordID = notification.recordID else {
            os_log("❌ RADIO Query notification missing recordID", log: log, type: .error)
            return
        }
        
        os_log("🔔 RADIO Handling query notification for station: %@", log: log, type: .info, recordID.recordName)
        
        // Determine record type from subscription ID
        let recordType: String
        if let subscriptionID = notification.subscriptionID {
            switch subscriptionID {
            case "RadioStationSubscription":
                recordType = RecordType.radioStation
            case "PodcastFeedSubscription", "EpisodeStateSubscription":
                // This is a podcast notification - ignore it gracefully as it should be handled by PodcastCloudKitManager
                os_log("🎧 RADIO Ignoring podcast notification in RadioStationCloudKitManager (handled by PodcastCloudKitManager)", log: log, type: .debug)
                return
            default:
                recordType = "Unknown"
            }
        } else {
            recordType = "Unknown"
        }
        
        switch recordType {
        case RecordType.radioStation:
            await handleRadioStationNotification(recordID: recordID, reason: notification.queryNotificationReason)
        default:
            os_log("❌ RADIO Unknown record type in notification: %@", log: log, type: .error, recordType)
        }
    }
    
    private func handleRadioStationNotification(recordID: CKRecord.ID, reason: CKQueryNotification.Reason) async {
        os_log("📻 RADIO Processing station notification: %@ for reason: %@", log: log, type: .info, recordID.recordName, String(describing: reason))
        
        switch reason {
        case .recordCreated:
            await handleRadioStationAdded(recordID: recordID)
        case .recordUpdated:
            await handleRadioStationUpdated(recordID: recordID)
        case .recordDeleted:
            await handleRadioStationDeleted(recordID: recordID)
        @unknown default:
            os_log("❌ RADIO Unknown notification reason: %@", log: log, type: .error, String(describing: reason))
        }
    }
    
    private func handleRadioStationAdded(recordID: CKRecord.ID) async {
        os_log("➕ RADIO CloudKit: Handling station addition for record: %@", log: log, type: .info, recordID.recordName)
        
        await MainActor.run {
            NotificationCenter.default.post(
                name: .init("CloudKitDidAddRadioStation"),
                object: nil,
                userInfo: ["stationId": recordID.recordName]
            )
        }
    }
    
    private func handleRadioStationUpdated(recordID: CKRecord.ID) async {
        os_log("🔄 RADIO CloudKit: Handling station update for record: %@", log: log, type: .info, recordID.recordName)
        
        await MainActor.run {
            NotificationCenter.default.post(
                name: .init("CloudKitDidUpdateRadioStation"),
                object: nil,
                userInfo: ["stationId": recordID.recordName]
            )
        }
    }
    
    private func handleRadioStationDeleted(recordID: CKRecord.ID) async {
        os_log("🗑️ RADIO CloudKit: Handling station deletion for record: %@", log: log, type: .info, recordID.recordName)
        
        await MainActor.run {
            // Post the CloudKit deletion notification
            NotificationCenter.default.post(
                name: .init("CloudKitDidDeleteRadioStation"),
                object: nil,
                userInfo: ["stationId": recordID.recordName]
            )
            
            // Also trigger instant sync notification for immediate cross-device sync
            let iCloudAccountID = getCurrentiCloudAccountID()
            
            self.ubiquitousStore.set(
                [
                    "stationId": recordID.recordName,
                    "actionId": "cloudkit-deletion-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID
                ],
                forKey: InstantSyncKeys.stationDeleted
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO CRITICAL: Posted deletion sync notification for station: %@", log: self.log, type: .info, recordID.recordName)
        }
    }
    
    // MARK: - Instant Sync Handlers
    
    private func handleInstantStationUpdatedSync() {
        print("📡 🔄 RADIO STATION UPDATE RECEIVE: Handling incoming station update sync")
        
        guard let updateData = ubiquitousStore.object(forKey: InstantSyncKeys.stationUpdated) as? [String: Any] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No data found for station update", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: updateData) {
            return
        }
        
        guard let stationId = updateData["stationId"] as? String else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: Missing station ID", log: log, type: .error)
            return
        }
        
        NotificationCenter.default.post(
            name: .init("InstantSyncDidUpdateRadioStation"),
            object: nil,
            userInfo: ["stationId": stationId, "updateData": updateData]
        )
        
        os_log("✅ RADIO Handled station update sync for: %@", log: log, type: .info, stationId)
    }
    
    private func handleInstantStationDeletedSync() {
        print("📡 🔄 RADIO STATION DELETE RECEIVE: Handling incoming station deletion sync")
        
        guard let deletionData = ubiquitousStore.object(forKey: InstantSyncKeys.stationDeleted) as? [String: Any] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No data found for station deletion", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: deletionData) {
            return
        }
        
        guard let stationId = deletionData["stationId"] as? String else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: Missing station ID", log: log, type: .error)
            return
        }
        
        NotificationCenter.default.post(
            name: .init("InstantSyncDidDeleteRadioStation"),
            object: nil,
            userInfo: ["stationId": stationId]
        )
        
        os_log("✅ RADIO Handled station deletion sync for: %@", log: log, type: .info, stationId)
    }
    
    private func handleInstantStationAddedSync() {
        print("📡 🔄 RADIO STATION ADD RECEIVE: Handling incoming station addition sync")
        
        guard let addData = ubiquitousStore.object(forKey: InstantSyncKeys.stationAdded) as? [String: Any] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No data found for station addition", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: addData) {
            return
        }
        
        guard let stationId = addData["stationId"] as? String else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: Missing station ID", log: log, type: .error)
            return
        }
        
        NotificationCenter.default.post(
            name: .init("InstantSyncDidAddRadioStation"),
            object: nil,
            userInfo: ["stationId": stationId]
        )
        
        os_log("✅ RADIO Handled station addition sync for: %@", log: log, type: .info, stationId)
    }
    
    private func handleInstantFavoriteChangedSync() {
        print("📡 🔄 RADIO FAVORITE CHANGE RECEIVE: Handling incoming favorite change sync")
        
        guard let favoriteData = ubiquitousStore.object(forKey: InstantSyncKeys.favoriteChanged) as? [String: Any] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No data found for favorite change", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: favoriteData) {
            return
        }
        
        guard let stationId = favoriteData["stationId"] as? String,
              let isFavorite = favoriteData["isFavorite"] as? Bool else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: Missing favorite data", log: log, type: .error)
            return
        }
        
        NotificationCenter.default.post(
            name: .init("InstantSyncDidChangeFavorite"),
            object: nil,
            userInfo: [
                "stationId": stationId,
                "isFavorite": isFavorite,
                "favoritedAt": favoriteData["favoritedAt"] as? Date,
                "favoriteOrder": favoriteData["favoriteOrder"] as? Int
            ]
        )
        
        os_log("✅ RADIO Handled favorite change sync for: %@ (favorite: %@)", log: log, type: .info, stationId, String(isFavorite))
    }
    
    private func handleInstantOrderChangedSync() {
        print("📡 🔄 RADIO ORDER CHANGE RECEIVE: Handling incoming order change sync")
        
        guard let orderData = ubiquitousStore.object(forKey: InstantSyncKeys.orderChanged) as? [String: Any] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No data found for order change", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: orderData) {
            return
        }
        
        NotificationCenter.default.post(
            name: .init("InstantSyncDidChangeOrder"),
            object: nil,
            userInfo: orderData
        )
        
        os_log("✅ RADIO Handled order change sync", log: log, type: .info)
    }
    
    /// Handle bulk station update sync notifications from other devices
    private func handleInstantBulkStationUpdatedSync() {
        guard let bulkData = ubiquitousStore.object(forKey: InstantSyncKeys.bulkStationUpdated) as? [String: Any] else {
            os_log("📡 RADIO BULK SYNC RECEIVE FAILED: No data found for bulk station update", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: bulkData) {
            return
        }
        
        guard let stationIds = bulkData["stationIds"] as? [String], let action = bulkData["action"] as? String else {
            os_log("📡 RADIO BULK SYNC RECEIVE FAILED: Invalid bulk update data format", log: log, type: .error)
            return
        }
        
        os_log("📡 🚨 RADIO BULK SYNC RECEIVED: %d stations with action: %@", log: log, type: .info, stationIds.count, action)
        
        NotificationCenter.default.post(
            name: .init("InstantBulkSyncDidUpdateStations"),
            object: nil,
            userInfo: bulkData
        )
        
        os_log("✅ RADIO Handled bulk station update sync for %d stations", log: log, type: .info, stationIds.count)
    }
    
    /// Handle bulk station deletion sync notifications from other devices  
    private func handleInstantBulkStationDeletedSync() {
        guard let bulkData = ubiquitousStore.object(forKey: InstantSyncKeys.bulkStationDeleted) as? [String: Any] else {
            os_log("📡 RADIO BULK SYNC RECEIVE FAILED: No data found for bulk station deletion", log: log, type: .error)
            return
        }
        
        // Validate iCloud account to prevent cross-account contamination
        if !validateSyncAccount(syncData: bulkData) {
            return
        }
        
        guard let stationIds = bulkData["stationIds"] as? [String] else {
            os_log("📡 RADIO BULK SYNC RECEIVE FAILED: Invalid bulk deletion data format", log: log, type: .error)
            return
        }
        
        os_log("📡 🚨 RADIO BULK DELETION SYNC RECEIVED: %d stations", log: log, type: .info, stationIds.count)
        
        NotificationCenter.default.post(
            name: .init("InstantBulkSyncDidDeleteStations"),
            object: nil,
            userInfo: bulkData
        )
        
        os_log("✅ RADIO Handled bulk station deletion sync for %d stations", log: log, type: .info, stationIds.count)
    }
    
    // MARK: - Artwork Data Conversion Helpers
    
    /// Convert Base64 string to CKAsset for CloudKit storage
    private func base64StringToCKAsset(_ base64String: String?, fieldName: String) throws -> CKAsset? {
        guard let base64String = base64String, !base64String.isEmpty else {
            return nil
        }
        
        guard let imageData = Data(base64Encoded: base64String) else {
            os_log("⚠️ RADIO Failed to decode Base64 string for %@", log: log, type: .default, fieldName)
            return nil
        }
        
        // Create a temporary file for the CKAsset
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "\(fieldName)_\(UUID().uuidString).dat"
        let tempFileURL = tempDirectory.appendingPathComponent(fileName)
        
        do {
            try imageData.write(to: tempFileURL)
            let asset = CKAsset(fileURL: tempFileURL)
            os_log("✅ RADIO Created CKAsset for %@ (size: %d bytes)", log: log, type: .info, fieldName, imageData.count)
            return asset
        } catch {
            os_log("❌ RADIO Failed to create temp file for %@: %@", log: log, type: .error, fieldName, error.localizedDescription)
            throw error
        }
    }
    
    /// Convert CKAsset to Base64 string for app usage
    private func ckAssetToBase64String(_ asset: CKAsset?, fieldName: String) -> String? {
        guard let asset = asset,
              let fileURL = asset.fileURL,
              let imageData = try? Data(contentsOf: fileURL) else {
            return nil
        }
        
        let base64String = imageData.base64EncodedString()
        os_log("✅ RADIO Converted CKAsset to Base64 for %@ (size: %d bytes)", log: log, type: .info, fieldName, imageData.count)
        return base64String
    }
    
    // MARK: - Private Batch Processing Methods
    
    /// Process CloudKit records in batches for optimal performance
    private func processBatchRecords(_ records: [CKRecord], batchSize: Int) async throws {
        guard !records.isEmpty else { return }
        
        let totalBatches = (records.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, records.count)
            let batchRecords = Array(records[startIndex..<endIndex])
            
            let batchNumber = batchIndex + 1
            os_log("📡 🔄 RADIO Processing CloudKit batch %d/%d (%d records)", log: log, type: .info, batchNumber, totalBatches, batchRecords.count)
            
            // Use async/await for the batch operation
            let savedRecords = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
                let modifyOperation = CKModifyRecordsOperation(recordsToSave: batchRecords, recordIDsToDelete: nil)
                
                // Set save policy to handle conflicts gracefully
                modifyOperation.savePolicy = .changedKeys
                modifyOperation.qualityOfService = .userInitiated
                modifyOperation.isLongLived = records.count > 1000
                
                modifyOperation.modifyRecordsCompletionBlock = { savedRecords, _, error in
                    if let error = error {
                        os_log("❌ RADIO Error in CloudKit batch %d save: %@", log: self.log, type: .error, batchNumber, error.localizedDescription)
                        
                        // Handle rate limiting errors with exponential backoff
                        if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                            if let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
                                os_log("⏱️ RADIO Rate limited. Will retry batch %d after %f seconds", log: self.log, type: .info, batchNumber, retryAfter)
                                // For rate limiting, we should retry, but for now we'll just fail
                                continuation.resume(throwing: error)
                                return
                            }
                        }
                        continuation.resume(throwing: error)
                    } else {
                        os_log("✅ RADIO Successfully saved batch %d/%d (%d records)", log: self.log, type: .info, batchNumber, totalBatches, savedRecords?.count ?? 0)
                        continuation.resume(returning: savedRecords ?? [])
                    }
                }
                
                // Add the operation to the database
                privateDatabase.add(modifyOperation)
            }
            
            os_log("📡 ✅ RADIO Completed batch %d/%d with %d saved records", log: log, type: .info, batchNumber, totalBatches, savedRecords.count)
        }
        
        os_log("🎉 RADIO Successfully completed all %d batches for %d total records", log: log, type: .info, totalBatches, records.count)
    }
    
    /// Process CloudKit records in batches with progress tracking
    private func processBatchRecordsWithProgress(_ records: [CKRecord], batchSize: Int, totalStations: Int, progressCallback: @escaping (Double, Int, String) -> Void) async throws {
        guard !records.isEmpty else { return }
        
        let totalBatches = (records.count + batchSize - 1) / batchSize
        var totalSavedRecords = 0
        
        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, records.count)
            let batchRecords = Array(records[startIndex..<endIndex])
            
            let batchNumber = batchIndex + 1
            os_log("📡 🔄 RADIO Processing CloudKit batch %d/%d (%d records)", log: log, type: .info, batchNumber, totalBatches, batchRecords.count)
            
            // Report batch start progress (20% preparation + 80% saving)
            let batchStartProgress = 0.2 + (Double(batchIndex) / Double(totalBatches)) * 0.8
            await MainActor.run {
                progressCallback(batchStartProgress, totalSavedRecords, "Saving batch \(batchNumber) of \(totalBatches) to iCloud")
            }
            
            // Use async/await for the batch operation
            let savedRecords = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
                let modifyOperation = CKModifyRecordsOperation(recordsToSave: batchRecords, recordIDsToDelete: nil)
                
                // Set save policy to handle conflicts gracefully
                modifyOperation.savePolicy = .changedKeys
                modifyOperation.qualityOfService = .userInitiated
                modifyOperation.isLongLived = records.count > 1000
                
                modifyOperation.modifyRecordsCompletionBlock = { savedRecords, _, error in
                    if let error = error {
                        os_log("❌ RADIO Error in CloudKit batch %d save: %@", log: self.log, type: .error, batchNumber, error.localizedDescription)
                        
                        // Handle rate limiting errors with exponential backoff
                        if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                            if let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
                                os_log("⏱️ RADIO Rate limited. Will retry batch %d after %f seconds", log: self.log, type: .info, batchNumber, retryAfter)
                                // For rate limiting, we should retry, but for now we'll just fail
                                continuation.resume(throwing: error)
                                return
                            }
                        }
                        continuation.resume(throwing: error)
                    } else {
                        os_log("✅ RADIO Successfully saved batch %d/%d (%d records)", log: self.log, type: .info, batchNumber, totalBatches, savedRecords?.count ?? 0)
                        continuation.resume(returning: savedRecords ?? [])
                    }
                }
                
                // Add the operation to the database
                privateDatabase.add(modifyOperation)
            }
            
            totalSavedRecords += savedRecords.count
            
            // Report batch completion progress
            let batchCompleteProgress = 0.2 + (Double(batchNumber) / Double(totalBatches)) * 0.8
            await MainActor.run {
                progressCallback(batchCompleteProgress, totalSavedRecords, "Saved \(totalSavedRecords) of \(totalStations) stations to iCloud")
            }
            
            os_log("📡 ✅ RADIO Completed batch %d/%d with %d saved records (total: %d)", log: log, type: .info, batchNumber, totalBatches, savedRecords.count, totalSavedRecords)
        }
        
        // Final completion progress
        await MainActor.run {
            progressCallback(1.0, totalSavedRecords, "Successfully saved \(totalSavedRecords) stations to iCloud")
        }
        
        os_log("🎉 RADIO Successfully completed all %d batches for %d total records", log: log, type: .info, totalBatches, records.count)
    }
    
    /// Process CloudKit records in batches with progress tracking and resumable support
    private func processBatchRecordsWithProgressResumable(_ records: [CKRecord], stationsToProcess: [RadioStation], batchSize: Int, totalStations: Int, alreadyProcessed: Int, country: String?, progressCallback: @escaping (Double, Int, String) -> Void) async throws {
        guard !records.isEmpty else { return }
        
        let totalBatches = (records.count + batchSize - 1) / batchSize
        var totalSavedRecords = 0
        var stationIndex = 0
        
        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, records.count)
            let batchRecords = Array(records[startIndex..<endIndex])
            
            let batchNumber = batchIndex + 1
            os_log("📡 🔄 RADIO Processing CloudKit batch %d/%d (%d records)", log: log, type: .info, batchNumber, totalBatches, batchRecords.count)
            
            // Report batch start progress
            let baseProgress = Double(alreadyProcessed) / Double(totalStations)
            let batchStartProgress = baseProgress + (Double(batchIndex) / Double(totalBatches)) * (Double(stationsToProcess.count) / Double(totalStations)) * 0.9
            await MainActor.run {
                progressCallback(batchStartProgress, alreadyProcessed + totalSavedRecords, "Saving batch \(batchNumber) of \(totalBatches) to iCloud")
            }
            
            // Use async/await for the batch operation
            let savedRecords = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
                let modifyOperation = CKModifyRecordsOperation(recordsToSave: batchRecords, recordIDsToDelete: nil)
                
                // Set conservative CloudKit operation settings to prevent rate limiting
                // Use .allKeys for favorite order updates (when country is nil) to force update all fields
                modifyOperation.savePolicy = (country == nil) ? .allKeys : .changedKeys
                modifyOperation.qualityOfService = .utility // Lower priority to reduce rate limiting
                modifyOperation.isLongLived = false // Keep operations short for better rate limiting behavior
                
                // Minimal per-record progress tracking (reduced logging to prevent confusion)
                modifyOperation.perRecordProgressBlock = { record, progress in
                    // Only log significant progress milestones to reduce log noise
                    if progress >= 1.0 {
                        os_log("📡 ✅ RADIO Record saved: %@", log: self.log, type: .debug, record.recordID.recordName)
                    }
                }
                
                modifyOperation.perRecordCompletionBlock = { record, error in
                    // Only log errors, not successful saves to reduce log noise
                    if let error = error {
                        if let ckError = error as? CKError {
                            switch ckError.code {
                            case .serverRecordChanged:
                                os_log("⚠️ RADIO Record conflict (will be resolved): %@", log: self.log, type: .info, record.recordID.recordName)
                            case .batchRequestFailed:
                                // This is expected in batch operations, don't log
                                break
                            default:
                                os_log("❌ RADIO Error saving record %@: %@", log: self.log, type: .error, record.recordID.recordName, error.localizedDescription)
                            }
                        }
                    }
                    // Successful saves are logged at batch level, not individual record level
                }
                
                modifyOperation.modifyRecordsCompletionBlock = { savedRecords, _, error in
                    if let error = error {
                        os_log("❌ RADIO Error in CloudKit batch %d save: %@", log: self.log, type: .error, batchNumber, error.localizedDescription)
                        
                        // Handle rate limiting errors with exponential backoff
                        if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                            if let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
                                os_log("⏱️ RADIO Rate limited. Will retry batch %d after %f seconds", log: self.log, type: .info, batchNumber, retryAfter)
                                // For rate limiting, we should retry, but for now we'll just fail
                                continuation.resume(throwing: error)
                                return
                            }
                        }
                        continuation.resume(throwing: error)
                    } else {
                        os_log("✅ RADIO Successfully saved batch %d/%d (%d records)", log: self.log, type: .info, batchNumber, totalBatches, savedRecords?.count ?? 0)
                        continuation.resume(returning: savedRecords ?? [])
                    }
                }
                
                // Add the operation to the database
                privateDatabase.add(modifyOperation)
            }
            
            // Mark individual stations as processed for resumable sync
            let stationsInThisBatch = min(batchRecords.count, stationsToProcess.count - stationIndex)
            for i in 0..<stationsInThisBatch {
                if stationIndex + i < stationsToProcess.count {
                    let station = stationsToProcess[stationIndex + i]
                    SyncStateManager.shared.markStationProcessed(station.id)
                }
            }
            stationIndex += stationsInThisBatch
            
            totalSavedRecords += savedRecords.count
            
            // Report batch completion progress
            let batchCompleteProgress = baseProgress + (Double(batchNumber) / Double(totalBatches)) * (Double(stationsToProcess.count) / Double(totalStations)) * 0.9
            await MainActor.run {
                progressCallback(batchCompleteProgress, alreadyProcessed + totalSavedRecords, "Saved \(alreadyProcessed + totalSavedRecords) of \(totalStations) stations to iCloud")
            }
            
            os_log("📡 ✅ RADIO Completed batch %d/%d with %d saved records (total processed: %d)", log: log, type: .info, batchNumber, totalBatches, savedRecords.count, alreadyProcessed + totalSavedRecords)
            
            // Add small delay between batches to prevent CloudKit rate limiting
            if batchIndex < totalBatches - 1 { // Don't delay after the last batch
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                os_log("📡 ⏱️ RADIO Added 0.5s delay before next batch to prevent rate limiting", log: log, type: .debug)
            }
        }
        
        // Final completion progress
        await MainActor.run {
            progressCallback(1.0, totalStations, "Successfully saved \(totalStations) stations to iCloud")
        }
        
        os_log("🎉 RADIO Successfully completed all %d batches for %d total records (resumable)", log: log, type: .info, totalBatches, records.count)
    }
    
    /// Process CloudKit record deletions in batches for optimal performance
    private func processBatchDeletion(_ recordIDs: [CKRecord.ID], batchSize: Int) async throws {
        guard !recordIDs.isEmpty else { return }
        
        let totalBatches = (recordIDs.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, recordIDs.count)
            let batchRecordIDs = Array(recordIDs[startIndex..<endIndex])
            
            let batchNumber = batchIndex + 1
            os_log("📡 🗑️ RADIO Processing iCloud deletion batch %d/%d (%d records)", log: log, type: .info, batchNumber, totalBatches, batchRecordIDs.count)
            
            // Use async/await for the batch deletion operation
            let deletedRecordIDs = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                let modifyOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batchRecordIDs)
                
                // Set policies for deletion operations
                modifyOperation.savePolicy = .changedKeys
                modifyOperation.qualityOfService = .userInitiated
                modifyOperation.isLongLived = recordIDs.count > 1000
                
                modifyOperation.modifyRecordsCompletionBlock = { _, deletedRecordIDs, error in
                    if let error = error {
                        os_log("❌ RADIO Error in CloudKit deletion batch %d: %@", log: self.log, type: .error, batchNumber, error.localizedDescription)
                        
                        // Handle rate limiting errors with exponential backoff
                        if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                            if let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
                                os_log("⏱️ RADIO Rate limited. Will retry deletion batch %d after %f seconds", log: self.log, type: .info, batchNumber, retryAfter)
                                // For rate limiting, we should retry, but for now we'll just fail
                                continuation.resume(throwing: error)
                                return
                            }
                        }
                        continuation.resume(throwing: error)
                    } else {
                        os_log("✅ RADIO Successfully deleted batch %d/%d (%d records)", log: self.log, type: .info, batchNumber, totalBatches, deletedRecordIDs?.count ?? 0)
                        continuation.resume(returning: deletedRecordIDs ?? [])
                    }
                }
                
                // Add the operation to the database
                privateDatabase.add(modifyOperation)
            }
            
            os_log("📡 ✅ RADIO Completed deletion batch %d/%d with %d deleted records", log: log, type: .info, batchNumber, totalBatches, deletedRecordIDs.count)
        }
        
        os_log("🎉 RADIO Successfully completed all %d deletion batches for %d total records", log: log, type: .info, totalBatches, recordIDs.count)
    }
    
    /// Trigger cross-device sync for bulk station operations
    private func triggerCrossDeviceBulkStationSync(stations: [RadioStation], action: String) async {
        let stationIds = stations.map { $0.id }
        os_log("📡 🚨 RADIO Triggering cross-device bulk sync for %d stations (action: %@)", log: log, type: .info, stationIds.count, action)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        await MainActor.run {
            self.ubiquitousStore.set(
                [
                    "stationIds": stationIds,
                    "action": action,
                    "actionId": "cloudkit-bulk-\(action)-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID
                ],
                forKey: InstantSyncKeys.bulkStationUpdated
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO Posted bulk sync notification for %d stations", log: log, type: .info, stationIds.count)
        }
    }
    
    // MARK: - CloudKit Change Detection Methods
    
    /// Get the count of radio stations in CloudKit with proper pagination
    func getCloudKitStationCount() async throws -> Int {
        let query = CKQuery(recordType: RecordType.radioStation, predicate: NSPredicate(value: true))
        
        do {
            // Use paginated approach to get accurate count
            var totalCount = 0
            var cursor: CKQueryOperation.Cursor? = nil
            
            repeat {
                let operation = CKQueryOperation(query: query)
                operation.cursor = cursor
                operation.resultsLimit = 400 // CloudKit's default limit
                operation.desiredKeys = ["recordID"] // Only fetch record ID to minimize data transfer
                
                let (records, nextCursor) = try await withCheckedThrowingContinuation { continuation in
                    var fetchedRecords: [CKRecord] = []
                    
                    operation.recordMatchedBlock = { recordID, result in
                        switch result {
                        case .success(let record):
                            fetchedRecords.append(record)
                        case .failure(let error):
                            print("⚠️ Error fetching record \(recordID): \(error)")
                        }
                    }
                    
                    operation.queryResultBlock = { result in
                        switch result {
                        case .success(let nextCursor):
                            continuation.resume(returning: (fetchedRecords, nextCursor))
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                    
                    privateDatabase.add(operation)
                }
                
                totalCount += records.count
                cursor = nextCursor
                print("📊 CloudKit batch: \(records.count) records (total so far: \(totalCount))")
                
            } while cursor != nil
            
            print("📊 CloudKit station count (final): \(totalCount)")
            return totalCount
            
        } catch {
            print("❌ Failed to get CloudKit station count: \(error)")
            throw error
        }
    }
    
    /// Check for station modifications by comparing timestamps
    func checkForStationModifications(localStations: [RadioStation]) async throws -> Bool {
        let query = CKQuery(recordType: RecordType.radioStation, predicate: NSPredicate(value: true))
        
        do {
            let (records, _) = try await privateDatabase.records(matching: query)
            
            // Get the most recent modification date from CloudKit
            var mostRecentCloudKitModification: Date?
            
            for (_, recordResult) in records {
                switch recordResult {
                case .success(let record):
                    if let modificationDate = record.modificationDate {
                        if mostRecentCloudKitModification == nil || modificationDate > mostRecentCloudKitModification! {
                            mostRecentCloudKitModification = modificationDate
                        }
                    }
                case .failure:
                    continue
                }
            }
            
            // Get the timestamp of the last known CloudKit sync
            let lastSyncTime = UserDefaults.standard.object(forKey: "LastCloudKitSyncTime") as? Date ?? Date.distantPast
            
            // Only update sync time if we're not just checking (we'll update after successful sync)
            // This prevents false positives on subsequent checks
            
            // Check if CloudKit has newer modifications than our last sync
            if let cloudKitDate = mostRecentCloudKitModification, cloudKitDate > lastSyncTime {
                print("📝 CloudKit modifications detected - CloudKit: \(cloudKitDate), Last Sync: \(lastSyncTime)")
                return true
            }
            
            print("✅ No recent CloudKit modifications detected")
            return false
            
        } catch {
            print("❌ Failed to check CloudKit modifications: \(error)")
            throw error
        }
    }
    
    // MARK: - Private Helper Methods
    
    /// Filter out stations that already exist in CloudKit to prevent unnecessary saves
    private func filterOutExistingCloudKitStations(_ stations: [RadioStation]) async -> [RadioStation] {
        guard !stations.isEmpty else {
            return []
        }
        
        do {
            // Fetch ALL existing station IDs from CloudKit with proper pagination
            let query = CKQuery(recordType: RecordType.radioStation, predicate: NSPredicate(value: true))
            print("📡 🔍 CLOUDKIT QUERY: Starting paginated query for ALL existing stations...")
            
            var allMatchResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
            var currentCursor: CKQueryOperation.Cursor? = nil
            var pageCount = 0
            
            // Fetch all pages of results using proper CloudKit cursor API
            repeat {
                pageCount += 1
                let (matchResults, cursor): ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)
                
                if let currentCursor = currentCursor {
                    // Continue from cursor
                    (matchResults, cursor) = try await privateDatabase.records(continuingMatchFrom: currentCursor)
                } else {
                    // Initial query
                    (matchResults, cursor) = try await privateDatabase.records(matching: query)
                }
                
                allMatchResults.append(contentsOf: matchResults)
                currentCursor = cursor
                
                print("📡 📊 CLOUDKIT PAGE \(pageCount): Retrieved \(matchResults.count) records (total: \(allMatchResults.count))")
                
                if cursor != nil {
                    print("📡 ➡️ CLOUDKIT PAGINATION: More records available, fetching next page...")
                }
            } while currentCursor != nil
            
            print("📡 ✅ CLOUDKIT QUERY COMPLETE: Retrieved \(allMatchResults.count) total records from CloudKit in \(pageCount) pages")
            
            let existingIds = Set(allMatchResults.compactMap { (recordID, result) -> String? in
                switch result {
                case .success:
                    return recordID.recordName
                case .failure:
                    return nil
                }
            })
            
            // Also fetch existing URLs for URL-based duplicate detection
            var existingURLs = Set<String>()
            for (_, result) in allMatchResults {
                switch result {
                case .success(let record):
                    if let url = record["url"] as? String {
                        existingURLs.insert(url.lowercased())
                    }
                case .failure:
                    continue
                }
            }
            
            print("📡 🔍 CLOUDKIT CHECK: Found \(existingIds.count) existing station IDs and \(existingURLs.count) existing URLs in CloudKit")
            
            if existingIds.count > 0 {
                print("📡 📋 Sample existing station IDs: \(Array(existingIds.prefix(3)).joined(separator: ", "))")
            }
            
            // Filter out stations that already exist by ID or URL
            let newStations = stations.filter { station in
                // Check if station ID already exists
                if existingIds.contains(station.id) {
                    print("📻 🚫 CLOUDKIT DUPLICATE ID: Station \(station.name) (ID: \(station.id)) already exists in CloudKit")
                    return false
                }
                
                // Check if station URL already exists (with normalization)
                let normalizedURL = station.url.lowercased()
                let urlWithoutProtocol = normalizedURL
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                
                let hasURLDuplicate = existingURLs.contains(normalizedURL) ||
                                    existingURLs.contains { existingURL in
                                        let existingWithoutProtocol = existingURL
                                            .replacingOccurrences(of: "https://", with: "")
                                            .replacingOccurrences(of: "http://", with: "")
                                        return existingWithoutProtocol == urlWithoutProtocol
                                    }
                
                if hasURLDuplicate {
                    print("📻 🚫 CLOUDKIT DUPLICATE URL: Station \(station.name) (URL: \(station.url)) has duplicate URL in CloudKit")
                    return false
                }
                
                return true
            }
            
            let duplicatesFiltered = stations.count - newStations.count
            if duplicatesFiltered > 0 {
                print("📡 📊 CLOUDKIT FILTERING: Filtered out \(duplicatesFiltered) stations that already exist in CloudKit")
            }
            
            if newStations.isEmpty {
                print("📡 ✅ NO NEW STATIONS: All \(stations.count) stations already exist in CloudKit - batch save skipped")
            } else {
                print("📡 🆕 PROCEEDING: \(newStations.count) new stations will be saved to CloudKit (from \(stations.count) candidates)")
            }
            
            return newStations
            
        } catch {
            print("📡 ❌ Failed to check existing CloudKit stations: \(error)")
            // On error, proceed with all stations to avoid losing data
            return stations
        }
    }
    
    // MARK: - Public API Methods
    
    /// Save multiple radio stations to CloudKit in batches for improved performance with resumable support
    func saveRadioStationsBatchToCloudKit(_ stations: [RadioStation], country: String? = nil, progressCallback: @escaping (Double, Int, String) -> Void = { _, _, _ in }) async throws {
        guard !stations.isEmpty else {
            os_log("⚠️ RADIO No stations to save in batch", log: log, type: .info)
            return
        }
        
        // ⚡ CRITICAL: Only save MANUAL stations to CloudKit (not API stations)
        let manualStations = stations.filter { station in
            let isManual = station.id.hasPrefix("manual_")
            if !isManual {
                print("📻 🚫 API STATION EXCLUSION: API station \(station.name) (ID: \(station.id)) excluded from CloudKit save")
            }
            return isManual
        }
        
        if manualStations.count != stations.count {
            print("📻 ⚠️ RADIO CLOUDKIT MANAGER: Filtered out \(stations.count - manualStations.count) API stations from CloudKit save (only saving manual stations)")
        }
        
        if manualStations.isEmpty {
            print("📡 ✅ NO MANUAL STATIONS: All \(stations.count) stations are from API, nothing to save to CloudKit")
            await MainActor.run {
                progressCallback(1.0, 0, "No manual stations to sync - API stations are not saved to iCloud")
            }
            return
        }
        
        print("📡 🔄 RADIO CLOUDKIT MANAGER: Proceeding with \(manualStations.count) manual stations (filtered from \(stations.count) total)")
        
        // Use filtered manual stations for the rest of the method
        let stationsToSave = manualStations
        
        // Prevent concurrent batch save operations
        batchSaveLock.lock()
        defer { batchSaveLock.unlock() }
        
        if isBatchSaveInProgress {
            print("📡 🚫 BATCH SAVE BLOCKED: Another batch save operation is already in progress")
            os_log("📡 🚫 BATCH SAVE BLOCKED: Concurrent batch save prevented", log: log, type: .info)
            await MainActor.run {
                progressCallback(1.0, 0, "Batch save already in progress - skipped duplicate operation")
            }
            return
        }
        
        isBatchSaveInProgress = true
        defer { isBatchSaveInProgress = false }
        
        os_log("📡 🔄 RADIO Starting batch save for %d manual stations (country: %@)", log: log, type: .info, stationsToSave.count, country ?? "nil")
        print("📡 🔄 RADIO Starting batch save for \(stationsToSave.count) manual stations (country: \(country ?? "nil"))")
        
        // Debug: Print first few station IDs and names for verification
        let debugStations = stationsToSave.prefix(3)
        for (index, station) in debugStations.enumerated() {
            print("📡 🔍 RADIO Station \(index + 1): ID=\(station.id), Name=\(station.name), Country=\(station.country)")
        }
        
        let stationIds = stationsToSave.map { $0.id }
        
        // Check for resumable sync
        let stationsToProcess: [RadioStation]
        if SyncStateManager.shared.hasIncompleteRadioStationSync() {
            let remainingIds = SyncStateManager.shared.getStationsToProcess(from: stationIds)
            stationsToProcess = stationsToSave.filter { remainingIds.contains($0.id) }
            os_log("📡 🔄 RADIO Resuming batch CloudKit save: %d remaining out of %d total manual stations", 
                   log: log, type: .info, stationsToProcess.count, stationsToSave.count)
        } else {
            stationsToProcess = stationsToSave
            // Start new sync tracking
            SyncStateManager.shared.startRadioStationSync(
                totalStations: stationsToSave.count,
                country: country,
                operationType: "batch_save"
            )
            os_log("📡 🔄 RADIO Starting new batch CloudKit save for %d manual stations", 
                   log: log, type: .info, stationsToSave.count)
        }
        
        // Enhanced duplicate prevention: Check for URL duplicates within the batch
        print("📡 🔍 BATCH DUPLICATE CHECK: Checking for URL duplicates within \(stationsToProcess.count) stations")
        var urlToStationMap = [String: RadioStation]()
        var deduplicatedStations = [RadioStation]()
        
        for station in stationsToProcess {
            let normalizedURL = station.url.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            
            if let existingStation = urlToStationMap[normalizedURL] {
                print("📻 🚫 BATCH URL DUPLICATE: Skipping \(station.name) (URL: \(station.url)) - duplicate of \(existingStation.name)")
                continue
            }
            
            urlToStationMap[normalizedURL] = station
            deduplicatedStations.append(station)
        }
        
        let duplicatesRemovedFromBatch = stationsToProcess.count - deduplicatedStations.count
        if duplicatesRemovedFromBatch > 0 {
            print("📡 📊 BATCH CLEANUP: Removed \(duplicatesRemovedFromBatch) URL duplicates from batch before CloudKit save")
        }
        
        // Update stationsToProcess with deduplicated list
        let batchDeduplicatedStations = deduplicatedStations
        
        // For favorite order updates, we need to UPDATE existing records, not skip them
        // Only skip duplicate checking for new station additions
        let finalStationsToProcess: [RadioStation]
        if country == nil {
            // When country is nil, this is likely a favorite order sync - process all stations
            print("📡 🔄 FAVORITE ORDER SYNC: Processing all \(batchDeduplicatedStations.count) stations (will update existing records)")
            finalStationsToProcess = batchDeduplicatedStations
        } else {
            // For country-specific saves, check for duplicates
            print("📡 🔍 CLOUDKIT DUPLICATE CHECK: Checking \(batchDeduplicatedStations.count) stations against existing CloudKit records")
            finalStationsToProcess = await filterOutExistingCloudKitStations(batchDeduplicatedStations)
            
            // Early return if no stations need to be saved
            guard !finalStationsToProcess.isEmpty else {
                print("📡 🚫 BATCH SAVE COMPLETELY SKIPPED: All \(stationsToSave.count) manual stations already exist in CloudKit")
                print("📡 ✅ DUPLICATE PREVENTION SUCCESSFUL: No expensive CloudKit operations performed")
                os_log("📡 🚫 BATCH SAVE COMPLETELY SKIPPED: All %d manual stations already exist in CloudKit", log: log, type: .info, stationsToSave.count)
                
                // Complete the sync state as successful
                SyncStateManager.shared.completeRadioStationSync()
                
                // Report completion with clear messaging
                await MainActor.run {
                    progressCallback(1.0, 0, "All \(stationsToSave.count) manual stations already exist - no CloudKit operations needed")
                }
                
                print("📡 🏁 BATCH SAVE TERMINATION: Returning early to prevent expensive operations")
                return
            }
        }
        
        // Additional safety check: If we're trying to save a very high percentage of existing stations, 
        // this might indicate a duplicate detection failure
        let duplicatePercentage = Double(stationsToSave.count - finalStationsToProcess.count) / Double(stationsToSave.count)
        if duplicatePercentage > 0.8 && finalStationsToProcess.count > 50 {
            print("📡 ⚠️ DUPLICATE WARNING: \(Int(duplicatePercentage * 100))% of manual stations were duplicates (\(stationsToSave.count - finalStationsToProcess.count) out of \(stationsToSave.count))")
            print("📡 🔍 DUPLICATE ANALYSIS: This might indicate an issue with duplicate detection")
        }
        
        print("📡 🔄 PROCEEDING with batch save for \(finalStationsToProcess.count) truly new stations")
        
        // Report initial progress
        let syncState = SyncStateManager.shared.getRadioStationSyncState()
        let totalStations = syncState?.totalStations ?? stationsToSave.count
        let alreadyProcessed = syncState?.completedCount ?? 0
        
        await MainActor.run {
            let progressText = alreadyProcessed > 0 ? 
                "Resuming: \(stationsToProcess.count) remaining of \(totalStations) stations..." :
                "Preparing \(totalStations) stations for CloudKit..."
            progressCallback(Double(alreadyProcessed) / Double(totalStations), alreadyProcessed, progressText)
        }
        
        // Convert stations to CKRecords efficiently (no individual CloudKit calls)
        var recordsToSave = [CKRecord]()
        
        print("📡 🏗️ BATCH PREPARATION: Creating \(finalStationsToProcess.count) CKRecords for optimized batch save")
        
        // Process stations in chunks to minimize memory usage and provide progress updates
        let preparationChunkSize = 100
        let totalChunks = (finalStationsToProcess.count + preparationChunkSize - 1) / preparationChunkSize
        
        // For favorite order updates (country == nil), fetch existing records first
        var existingRecordsMap: [String: CKRecord] = [:]
        if country == nil {
            print("📡 🔍 FAVORITE ORDER: Fetching existing records to update favoriteOrder...")
            let recordIDs = finalStationsToProcess.map { CKRecord.ID(recordName: $0.id) }
            
            // Fetch existing records in batches
            let fetchBatchSize = 100
            for batchStart in stride(from: 0, to: recordIDs.count, by: fetchBatchSize) {
                let batchEnd = min(batchStart + fetchBatchSize, recordIDs.count)
                let batchIDs = Array(recordIDs[batchStart..<batchEnd])
                
                do {
                    let fetchedRecords = try await privateDatabase.records(for: batchIDs)
                    for (recordID, result) in fetchedRecords {
                        switch result {
                        case .success(let record):
                            existingRecordsMap[recordID.recordName] = record
                        case .failure(let error):
                            print("📡 ⚠️ FAVORITE ORDER: Could not fetch record \(recordID.recordName): \(error)")
                        }
                    }
                } catch {
                    print("📡 ❌ FAVORITE ORDER: Error fetching batch: \(error)")
                }
            }
            print("📡 ✅ FAVORITE ORDER: Fetched \(existingRecordsMap.count) existing records")
        }
        
        for chunkIndex in 0..<totalChunks {
            let startIndex = chunkIndex * preparationChunkSize
            let endIndex = min(startIndex + preparationChunkSize, finalStationsToProcess.count)
            let stationChunk = Array(finalStationsToProcess[startIndex..<endIndex])
            
            for station in stationChunk {
                let recordID = CKRecord.ID(recordName: station.id)
                
                // Use existing record if available, otherwise create new
                let record: CKRecord
                if let existingRecord = existingRecordsMap[station.id] {
                    record = existingRecord
                    print("📡 🔄 FAVORITE ORDER: Updating existing record for \(station.name)")
                } else {
                    record = CKRecord(recordType: RecordType.radioStation, recordID: recordID)
                }
                
                // Update record fields
                record["name"] = station.name as CKRecordValue
                record["url"] = station.url as CKRecordValue
                record["country"] = station.country as CKRecordValue
                record["isFavorite"] = station.isFavorite ? "true" : "false"
                record["favoritedAt"] = station.favoritedAt as CKRecordValue?
                record["favoriteOrder"] = station.favoriteOrder as CKRecordValue?
                record["order"] = station.order as CKRecordValue
                record["lastPlayed"] = station.lastPlayed as CKRecordValue?
                
                do {
                    // CRITICAL FIX: Convert Base64 artwork data to CKAsset for CloudKit compatibility
                    record["iconData"] = try base64StringToCKAsset(station.iconData, fieldName: "iconData")
                    record["iTunesArtworkData"] = try base64StringToCKAsset(station.iTunesArtworkData, fieldName: "iTunesArtworkData")
                    
                    record["lastUpdated"] = Date() as CKRecordValue
                    
                    recordsToSave.append(record)
                } catch {
                    print("📡 ⚠️ RADIO Warning: Failed to convert artwork for station \(station.name), continuing without artwork: \(error)")
                    // Continue without artwork data
                    record["lastUpdated"] = Date() as CKRecordValue
                    recordsToSave.append(record)
                }
            }
            
            // Report preparation progress only for chunks (reduced logging)
            let preparedCount = min(endIndex, finalStationsToProcess.count)
            let prepareProgress = 0.2 * (Double(preparedCount) / Double(finalStationsToProcess.count))
            await MainActor.run {
                progressCallback(
                    prepareProgress,
                    preparedCount,
                    "Prepared \(preparedCount)/\(finalStationsToProcess.count) records..."
                )
            }
        }
        
        // Process in smaller batches to prevent CloudKit rate limiting
        let batchSize = 50 // Reduced batch size for better CloudKit performance
        print("📡 🚀 OPTIMIZED BATCH SAVE: Starting batch save of \(recordsToSave.count) records in batches of \(batchSize)")
        try await processBatchRecordsWithProgressResumable(recordsToSave, stationsToProcess: finalStationsToProcess, batchSize: batchSize, totalStations: totalStations, alreadyProcessed: alreadyProcessed, country: country, progressCallback: progressCallback)
        
        // Mark sync as complete
        SyncStateManager.shared.completeRadioStationSync()
        
        os_log("✅ RADIO Successfully saved %d stations to CloudKit in batches", log: log, type: .info, totalStations)
        
        // Trigger bulk cross-device sync notification
        await triggerCrossDeviceBulkStationSync(stations: stationsToSave, action: "batch_updated")
    }
    
    /// Delete multiple radio stations from CloudKit in batches for improved performance
    func deleteRadioStationsBatchFromCloudKit(_ stationIds: [String]) async throws {
        guard !stationIds.isEmpty else {
            os_log("⚠️ RADIO No stations to delete in batch", log: log, type: .info)
            return
        }
        
        os_log("📡 🗑️ RADIO Starting batch CloudKit deletion for %d stations", log: log, type: .info, stationIds.count)
        
        // Convert station IDs to CKRecord.IDs for deletion
        let recordIDsToDelete = stationIds.map { CKRecord.ID(recordName: $0) }
        
        // Process in batches for optimal CloudKit performance
        let batchSize = 200 // CloudKit recommended batch size
        try await processBatchDeletion(recordIDsToDelete, batchSize: batchSize)
        
        os_log("✅ RADIO Successfully deleted %d stations from CloudKit in batches", log: log, type: .info, stationIds.count)
        
        // Trigger bulk cross-device deletion sync notification
        await triggerCrossDeviceBulkDeletionSync(stationIds: stationIds)
    }
    
    /// Save radio station to CloudKit and trigger cross-device sync
    func saveRadioStationToCloudKit(_ station: RadioStation) async throws {
        // ⚡ CRITICAL: Only save MANUAL stations to CloudKit (not API stations)
        guard station.id.hasPrefix("manual_") else {
            print("📻 🚫 API STATION EXCLUSION: API station \(station.name) (ID: \(station.id)) excluded from CloudKit save")
            return
        }
        
        let recordID = CKRecord.ID(recordName: station.id)
        
        // Try to fetch existing record first
        var record: CKRecord
        do {
            record = try await privateDatabase.record(for: recordID)
        } catch CKError.unknownItem {
            record = CKRecord(recordType: RecordType.radioStation, recordID: recordID)
        }
        
        // Update record fields
        record["name"] = station.name as CKRecordValue
        record["url"] = station.url as CKRecordValue
        record["country"] = station.country as CKRecordValue
        record["isFavorite"] = station.isFavorite ? "true" : "false" // Store as string for compatibility
        record["favoritedAt"] = station.favoritedAt as CKRecordValue?
        record["favoriteOrder"] = station.favoriteOrder as CKRecordValue?
        record["order"] = station.order as CKRecordValue
        record["lastPlayed"] = station.lastPlayed as CKRecordValue?
        
        // CRITICAL FIX: Convert Base64 artwork data to CKAsset for CloudKit compatibility
        record["iconData"] = try base64StringToCKAsset(station.iconData, fieldName: "iconData")
        record["iTunesArtworkData"] = try base64StringToCKAsset(station.iTunesArtworkData, fieldName: "iTunesArtworkData")
        
        record["lastUpdated"] = Date() as CKRecordValue
        
        // Save the record
        _ = try await privateDatabase.save(record)
        os_log("✅ RADIO Saved station to CloudKit: %@", log: log, type: .info, station.name)
        
        // Trigger cross-device sync notification
        await triggerCrossDeviceStationSync(station: station, action: "updated")
    }
    
    /// Fetch radio station from CloudKit by ID
    func fetchRadioStationFromCloudKit(stationId: String) async throws -> RadioStation? {
        let recordID = CKRecord.ID(recordName: stationId)
        
        do {
            let record = try await privateDatabase.record(for: recordID)
            return convertCloudKitRecordToRadioStation(record)
        } catch CKError.unknownItem {
            os_log("⚠️ RADIO Station not found in CloudKit: %@", log: log, type: .default, stationId)
            return nil
        }
    }
    
    /// Convert CloudKit record to RadioStation object
    private func convertCloudKitRecordToRadioStation(_ record: CKRecord) -> RadioStation? {
        guard let name = record["name"] as? String,
              let url = record["url"] as? String,
              let country = record["country"] as? String else {
            os_log("❌ RADIO Essential data missing in CloudKit record", log: log, type: .error)
            return nil
        }
        
        // Convert artwork data from CKAsset to Base64 string
        let iconData = ckAssetToBase64String(record["iconData"] as? CKAsset, fieldName: "iconData")
        let iTunesArtworkData = ckAssetToBase64String(record["iTunesArtworkData"] as? CKAsset, fieldName: "iTunesArtworkData")
        
        let isFavorite = (record["isFavorite"] as? String)?.lowercased() == "true"
        let favoritedAt = record["favoritedAt"] as? Date
        let favoriteOrder = record["favoriteOrder"] as? Int
        let order = record["order"] as? Int ?? 0
        let lastPlayed = record["lastPlayed"] as? Date
        let id = record.recordID.recordName
        
        return RadioStation(
            id: id,
            name: name,
            url: url,
            iconData: iconData,
            iTunesArtworkData: iTunesArtworkData,
            country: country,
            isFavorite: isFavorite,
            favoritedAt: favoritedAt,
            favoriteOrder: favoriteOrder,
            order: order,
            lastPlayed: lastPlayed
        )
    }
    
    /// Delete radio station from CloudKit and trigger cross-device sync
    func deleteRadioStationFromCloudKit(_ stationId: String) async throws {
        let recordID = CKRecord.ID(recordName: stationId)
        
        do {
            _ = try await privateDatabase.deleteRecord(withID: recordID)
            os_log("✅ RADIO Deleted station from CloudKit: %@", log: log, type: .info, stationId)
            
            // Trigger cross-device sync notification
            await triggerCrossDeviceDeletionSync(stationId: stationId)
        } catch CKError.unknownItem {
            os_log("⚠️ RADIO Station not found in CloudKit (already deleted): %@", log: log, type: .default, stationId)
            // Still trigger sync to ensure all devices are updated
            await triggerCrossDeviceDeletionSync(stationId: stationId)
        }
    }
    
    /// Delete multiple radio stations from CloudKit in batches without individual sync notifications
    /// Used for bulk deletion operations like "Delete All Station Data"
    func deleteRadioStationsFromCloudKitBatch(_ stationIds: [String]) async throws {
        guard !stationIds.isEmpty else {
            os_log("🗑️ RADIO Batch deletion called with empty station list", log: log, type: .debug)
            return
        }
        
        os_log("🗑️ RADIO Starting batch deletion of %d stations from CloudKit", log: log, type: .info, stationIds.count)
        
        // Convert station IDs to CloudKit record IDs
        let recordIDs = stationIds.map { CKRecord.ID(recordName: $0) }
        
        // Use DataStore's optimized batch deletion
        let dataStore = DataStore.shared
        
        try await dataStore.deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
            os_log("🗑️ RADIO Batch deletion progress: %d%%", log: self.log, type: .debug, Int(progress * 100))
        }
        
        os_log("✅ RADIO Completed batch deletion of %d stations from CloudKit", log: log, type: .info, stationIds.count)
        
        // Send a single bulk deletion notification instead of individual ones
        await triggerCrossDeviceBulkDeletionSync(stationIds: stationIds)
    }
    
    /// Update favorite status and trigger cross-device sync
    func updateFavoriteStatus(stationId: String, isFavorite: Bool, favoritedAt: Date?, favoriteOrder: Int?) async throws {
        let recordID = CKRecord.ID(recordName: stationId)
        
        do {
            let record = try await privateDatabase.record(for: recordID)
            record["isFavorite"] = isFavorite ? "true" : "false"
            record["favoritedAt"] = favoritedAt as CKRecordValue?
            record["favoriteOrder"] = favoriteOrder as CKRecordValue?
            record["lastUpdated"] = Date() as CKRecordValue
            
            _ = try await privateDatabase.save(record)
            os_log("✅ RADIO Updated favorite status in CloudKit: %@ (favorite: %@)", log: log, type: .info, stationId, String(isFavorite))
            
            // Trigger cross-device sync notification
            await triggerCrossDeviceFavoriteSync(stationId: stationId, isFavorite: isFavorite, favoritedAt: favoritedAt, favoriteOrder: favoriteOrder)
        } catch {
            os_log("❌ RADIO Failed to update favorite status in CloudKit: %@", log: log, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Cross-Device Sync Triggers
    
    private func triggerCrossDeviceStationSync(station: RadioStation, action: String) async {
        os_log("📡 🚨 RADIO CRITICAL: Triggering cross-device sync for station: %@", log: log, type: .info, station.name)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        await MainActor.run {
            self.ubiquitousStore.set(
                [
                    "stationId": station.id,
                    "stationName": station.name,
                    "action": action,
                    "actionId": "cloudkit-update-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID
                ],
                forKey: InstantSyncKeys.stationUpdated
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO CRITICAL: Posted station sync notification for: %@", log: self.log, type: .info, station.name)
        }
    }
    
    private func triggerCrossDeviceDeletionSync(stationId: String) async {
        os_log("📡 🚨 RADIO CRITICAL: Triggering cross-device deletion sync for station: %@", log: log, type: .info, stationId)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        await MainActor.run {
            self.ubiquitousStore.set(
                [
                    "stationId": stationId,
                    "actionId": "cloudkit-deletion-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID
                ],
                forKey: InstantSyncKeys.stationDeleted
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO CRITICAL: Posted deletion sync notification for station: %@", log: self.log, type: .info, stationId)
        }
    }
    
    /// Trigger cross-device sync for bulk station deletion (sends one notification for all stations)
    public func triggerCrossDeviceBulkDeletionSync(stationIds: [String]) async {
        os_log("📡 🚨 RADIO BULK DELETION: Triggering cross-device bulk deletion sync for %d stations", log: log, type: .info, stationIds.count)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        await MainActor.run {
            self.ubiquitousStore.set(
                [
                    "stationIds": stationIds,
                    "actionId": "cloudkit-bulk-deletion-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID,
                    "type": "bulk_deletion"
                ],
                forKey: "instant_stations_bulk_deleted"
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO BULK DELETION: Posted bulk deletion sync notification for %d stations", log: self.log, type: .info, stationIds.count)
        }
    }
    
    func triggerCrossDeviceOrderSync(action: String) async {
        os_log("📡 🚨 RADIO ORDER CRITICAL: Triggering cross-device order sync (action: %@)", log: log, type: .info, action)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        await MainActor.run {
            self.ubiquitousStore.set(
                [
                    "action": action,
                    "actionId": "radio-order-\(Date().timeIntervalSince1970)",
                    "timestamp": Date().timeIntervalSince1970,
                    "icloud_account_id": iCloudAccountID
                ],
                forKey: InstantSyncKeys.orderChanged
            )
            
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 ✅ RADIO ORDER: Posted order sync notification (action: %@)", log: self.log, type: .info, action)
        }
    }
    
    private func triggerCrossDeviceFavoriteSync(stationId: String, isFavorite: Bool, favoritedAt: Date?, favoriteOrder: Int?) async {
        os_log("📡 🚨 RADIO CRITICAL: Triggering cross-device favorite sync for station: %@", log: log, type: .info, stationId)
        
        let iCloudAccountID = getCurrentiCloudAccountID()
        
        var syncData: [String: Any] = [
            "stationId": stationId,
            "isFavorite": isFavorite,
            "actionId": "cloudkit-favorite-\(Date().timeIntervalSince1970)",
            "timestamp": Date().timeIntervalSince1970,
            "icloud_account_id": iCloudAccountID
        ]
        
        if let favoritedAt = favoritedAt {
            syncData["favoritedAt"] = favoritedAt
        }
        
        if let favoriteOrder = favoriteOrder {
            syncData["favoriteOrder"] = favoriteOrder
        }
        
        await MainActor.run {
            self.ubiquitousStore.set(syncData, forKey: InstantSyncKeys.favoriteChanged)
            // Note: synchronize() is deprecated and unnecessary
            os_log("📡 🚨 RADIO CRITICAL: Posted favorite sync notification for station: %@", log: self.log, type: .info, stationId)
        }
    }
    
    // MARK: - Utility Methods
    
    private func getCurrentiCloudAccountID() -> String {
        // Get a consistent identifier for the current iCloud account
        return container.containerIdentifier ?? "unknown_account"
    }
    
    private func validateSyncAccount(syncData: [String: Any]) -> Bool {
        guard let syncAccountId = syncData["icloud_account_id"] as? String else {
            os_log("📡 RADIO SYNC VALIDATION: Missing account ID in sync data", log: log, type: .default)
            return true // Allow sync if no account ID (backward compatibility)
        }
        
        let currentAccountId = getCurrentiCloudAccountID()
        let isValid = syncAccountId == currentAccountId
        
        if !isValid {
            os_log("📡 RADIO SYNC VALIDATION: Account mismatch - sync: %@, current: %@", log: log, type: .default, syncAccountId, currentAccountId)
        }
        
        return isValid
    }
}
