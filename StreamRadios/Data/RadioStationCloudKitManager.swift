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
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
        setupInstantSync()
        setupCloudKitSubscriptions()
    }
    
    // MARK: - Instant Sync Setup
    
    private func setupInstantSync() {
        os_log("📡 RADIO SYNC: Setting up instant sync for radio stations", log: log, type: .info)
        
        // Enable sync across devices for the ubiquitous store
        ubiquitousStore.synchronize()
        
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
        guard let userInfo = notification.userInfo,
              let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            os_log("📡 RADIO SYNC RECEIVE FAILED: No keys in notification", log: log, type: .error)
            return
        }
        
        os_log("📡 🚨 RADIO SYNC NOTIFICATION RECEIVED: Keys changed: %@", log: log, type: .info, keys.joined(separator: ", "))
        print("📡 🚨 RADIO SYNC NOTIFICATION RECEIVED: Keys changed: \(keys.joined(separator: ", "))")
        print("📡 📝 Full notification userInfo: \(userInfo)")
        
        DispatchQueue.main.async {
            self.lastInstantSyncDate = Date()
            
            for key in keys {
                switch key {
                case InstantSyncKeys.stationUpdated:
                    self.handleInstantStationUpdatedSync()
                case InstantSyncKeys.stationDeleted:
                    self.handleInstantStationDeletedSync()
                case InstantSyncKeys.stationAdded:
                    self.handleInstantStationAddedSync()
                case InstantSyncKeys.favoriteChanged:
                    self.handleInstantFavoriteChangedSync()
                case InstantSyncKeys.orderChanged:
                    self.handleInstantOrderChangedSync()
                default:
                    os_log("📡 RADIO SYNC: Unknown sync key: %@", log: self.log, type: .debug, key)
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
            
            self.ubiquitousStore.synchronize()
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
    
    // MARK: - Public API Methods
    
    /// Save radio station to CloudKit and trigger cross-device sync
    func saveRadioStationToCloudKit(_ station: RadioStation) async throws {
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
            
            self.ubiquitousStore.synchronize()
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
            
            self.ubiquitousStore.synchronize()
            os_log("📡 🚨 RADIO CRITICAL: Posted deletion sync notification for station: %@", log: self.log, type: .info, stationId)
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
            
            self.ubiquitousStore.synchronize()
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
            self.ubiquitousStore.synchronize()
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