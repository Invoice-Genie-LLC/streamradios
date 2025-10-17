import Foundation
import CloudKit
import Combine
import os

// Add missing import for CKError
#if canImport(CloudKit)
import CloudKit
#endif

/// Manages real-time syncing across devices using CloudKit push notifications and NSUbiquitousKeyValueStore
class RealtimeSyncManager: ObservableObject {
    static let shared = RealtimeSyncManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let ubiquitousStore = NSUbiquitousKeyValueStore()
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "RealtimeSync")
    
    // Notification names for sync events
    static let syncDidUpdateNotification = Notification.Name("RealtimeSyncDidUpdate")
    static let syncDidFailNotification = Notification.Name("RealtimeSyncDidFail")
    
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle
    @Published var pendingSyncOperations: Int = 0
    
    enum SyncStatus {
        case idle
        case syncing
        case failed(Error)
        case success
    }
    
    // Keys for NSUbiquitousKeyValueStore (for instant sync of simple values)
    private enum UbiquitousKeys {
        static let currentlyPlayingRadioStation = "currentlyPlayingRadioStation"
        static let podcastPlaybackProgress = "podcastPlaybackProgress"
        static let lastActiveTab = "lastActiveTab"
        static let favoriteStationsOrder = "favoriteStationsOrder"
        static let appSettings = "appSettings"
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
        setupCloudKitSubscriptions()
        setupUbiquitousKeyValueStoreObserver()
        startPeriodicSync()
    }
    
    deinit {
        syncTimer?.invalidate()
        cancellables.removeAll()
    }
    
    // MARK: - CloudKit Push Notifications Setup
    
    /// Set up CloudKit subscriptions for real-time notifications
    func setupCloudKitSubscriptions() {
        Task {
            await setupPodcastFeedSubscription()
            await setupEpisodeStateSubscription()
            await setupRadioStationSubscription()
        }
    }
    
    private func setupPodcastFeedSubscription() async {
        do {
            let subscription = CKQuerySubscription(
                recordType: "PodcastFeed",
                predicate: NSPredicate(value: true),
                subscriptionID: "PodcastFeedSubscription",
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
        do {
            let subscription = CKQuerySubscription(
                recordType: "EpisodeState",
                predicate: NSPredicate(value: true),
                subscriptionID: "EpisodeStateSubscription",
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
    
    private func setupRadioStationSubscription() async {
        do {
            let subscription = CKQuerySubscription(
                recordType: "streamingRadios",
                predicate: NSPredicate(value: true),
                subscriptionID: "RadioStationSubscription",
                options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
            )
            
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            notificationInfo.category = "RADIO_STATION_SYNC"
            subscription.notificationInfo = notificationInfo
            
            _ = try await privateDatabase.save(subscription)
            os_log("✅ CloudKit RadioStation subscription created", log: log, type: .info)
        } catch {
            os_log("❌ Failed to create RadioStation subscription: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - NSUbiquitousKeyValueStore for Instant Sync
    
    private func setupUbiquitousKeyValueStoreObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore
        )
        
        // Start syncing with iCloud
        ubiquitousStore.synchronize()
    }
    
    @objc private func ubiquitousKeyValueStoreDidChange(_ notification: Notification) {
        // CRITICAL: Defer processing during fresh install sync to prevent race conditions
        if DataSyncManager.shared.isFreshInstallSyncInProgress {
            os_log("🚨 REALTIME DEFERRED: Fresh install sync in progress - deferring notification processing", log: log, type: .info)
            return
        }
        
        guard let userInfo = notification.userInfo,
              let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        
        os_log("📡 NSUbiquitousKeyValueStore changed for keys: %@", log: log, type: .info, keys.joined(separator: ", "))
        
        DispatchQueue.main.async {
            for key in keys {
                self.handleUbiquitousValueChange(for: key)
            }
        }
    }
    
    private func handleUbiquitousValueChange(for key: String) {
        switch key {
        case UbiquitousKeys.currentlyPlayingRadioStation:
            handleCurrentlyPlayingRadioStationChange()
        case UbiquitousKeys.podcastPlaybackProgress:
            handlePodcastPlaybackProgressChange()
        case UbiquitousKeys.lastActiveTab:
            handleLastActiveTabChange()
        case UbiquitousKeys.favoriteStationsOrder:
            handleFavoriteStationsOrderChange()
        case UbiquitousKeys.appSettings:
            handleAppSettingsChange()
        default:
            os_log("Unknown ubiquitous key changed: %@", log: log, type: .debug, key)
        }
    }
    
    // MARK: - Instant Sync Methods for Simple Values
    
    func syncCurrentlyPlayingRadioStation(_ stationId: String?) {
        if let stationId = stationId {
            ubiquitousStore.set(stationId, forKey: UbiquitousKeys.currentlyPlayingRadioStation)
        } else {
            ubiquitousStore.removeObject(forKey: UbiquitousKeys.currentlyPlayingRadioStation)
        }
        ubiquitousStore.synchronize()
    }
    
    func syncPodcastPlaybackProgress(episodeId: String, progress: Double, timestamp: Date = Date()) {
        let progressData: [String: Any] = [
            "episodeId": episodeId,
            "progress": progress,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        ubiquitousStore.set(progressData, forKey: UbiquitousKeys.podcastPlaybackProgress)
        ubiquitousStore.synchronize()
    }
    
    func syncLastActiveTab(_ tabIndex: Int) {
        ubiquitousStore.set(tabIndex, forKey: UbiquitousKeys.lastActiveTab)
        ubiquitousStore.synchronize()
    }
    
    func syncFavoriteStationsOrder(_ stationIds: [String]) {
        ubiquitousStore.set(stationIds, forKey: UbiquitousKeys.favoriteStationsOrder)
        ubiquitousStore.synchronize()
    }
    
    func syncAppSettings(_ settings: [String: Any]) {
        ubiquitousStore.set(settings, forKey: UbiquitousKeys.appSettings)
        ubiquitousStore.synchronize()
    }
    
    // MARK: - Handle Changes from Other Devices
    
    private func handleCurrentlyPlayingRadioStationChange() {
        guard let stationId = ubiquitousStore.string(forKey: UbiquitousKeys.currentlyPlayingRadioStation) else {
            // Station stopped on another device
            NotificationCenter.default.post(
                name: .init("SyncDidStopRadioStation"),
                object: nil
            )
            return
        }
        
        NotificationCenter.default.post(
            name: .init("SyncDidStartRadioStation"),
            object: nil,
            userInfo: ["stationId": stationId]
        )
    }
    
    private func handlePodcastPlaybackProgressChange() {
        guard let progressData = ubiquitousStore.dictionary(forKey: UbiquitousKeys.podcastPlaybackProgress),
              let episodeId = progressData["episodeId"] as? String,
              let progress = progressData["progress"] as? Double,
              let timestamp = progressData["timestamp"] as? TimeInterval else {
            return
        }
        
        // Only apply if this is more recent than our local data
        let changeDate = Date(timeIntervalSince1970: timestamp)
        let localProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
        let localDate = EpisodeStateManager.shared.getLastUpdated(for: episodeId) ?? Date.distantPast
        
        if changeDate > localDate {
            NotificationCenter.default.post(
                name: .init("SyncDidUpdatePodcastProgress"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "progress": progress,
                    "timestamp": changeDate
                ]
            )
        }
    }
    
    private func handleLastActiveTabChange() {
        guard let tabIndex = ubiquitousStore.object(forKey: UbiquitousKeys.lastActiveTab) as? Int else {
            return
        }
        
        NotificationCenter.default.post(
            name: .init("SyncDidChangeActiveTab"),
            object: nil,
            userInfo: ["tabIndex": tabIndex]
        )
    }
    
    private func handleFavoriteStationsOrderChange() {
        guard let stationIds = ubiquitousStore.array(forKey: UbiquitousKeys.favoriteStationsOrder) as? [String] else {
            return
        }
        
        NotificationCenter.default.post(
            name: .init("SyncDidUpdateFavoriteStationsOrder"),
            object: nil,
            userInfo: ["stationIds": stationIds]
        )
    }
    
    private func handleAppSettingsChange() {
        guard let settings = ubiquitousStore.dictionary(forKey: UbiquitousKeys.appSettings) else {
            return
        }
        
        NotificationCenter.default.post(
            name: .init("SyncDidUpdateAppSettings"),
            object: nil,
            userInfo: ["settings": settings]
        )
    }
    
    // MARK: - CloudKit Remote Change Handling
    
    func handleCloudKitRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("❌ Invalid CloudKit notification", log: log, type: .error)
            return
        }
        
        DispatchQueue.main.async {
            self.syncStatus = .syncing
            self.pendingSyncOperations += 1
        }
        
        do {
            switch notification.notificationType {
            case .query:
                await handleQueryNotification(notification as! CKQueryNotification)
            case .database:
                await handleDatabaseNotification(notification as! CKDatabaseNotification)
            default:
                os_log("🔔 Received CloudKit notification of type: %@", log: log, type: .info, String(describing: notification.notificationType))
            }
            
            DispatchQueue.main.async {
                self.syncStatus = .success
                self.lastSyncDate = Date()
                self.pendingSyncOperations = max(0, self.pendingSyncOperations - 1)
            }
            
            NotificationCenter.default.post(
                name: Self.syncDidUpdateNotification,
                object: nil,
                userInfo: ["notification": notification]
            )
            
        } catch {
            os_log("❌ Failed to handle CloudKit notification: %@", log: log, type: .error, error.localizedDescription)
            
            DispatchQueue.main.async {
                self.syncStatus = .failed(error)
                self.pendingSyncOperations = max(0, self.pendingSyncOperations - 1)
            }
            
            NotificationCenter.default.post(
                name: Self.syncDidFailNotification,
                object: nil,
                userInfo: ["error": error]
            )
        }
    }
    
    private func handleQueryNotification(_ notification: CKQueryNotification) async {
        guard let recordID = notification.recordID else {
            os_log("❌ Query notification missing recordID", log: log, type: .error)
            return
        }
        
        os_log("🔔 Handling query notification for record: %@", log: log, type: .info, recordID.recordName)
        
        switch notification.recordType {
        case "PodcastFeed":
            await handlePodcastFeedChange(recordID: recordID, changeType: notification.queryNotificationReason)
        case "EpisodeState":
            await handleEpisodeStateChange(recordID: recordID, changeType: notification.queryNotificationReason)
        case "streamingRadios":
            await handleRadioStationChange(recordID: recordID, changeType: notification.queryNotificationReason)
        default:
            os_log("Unknown record type in notification: %@", log: log, type: .debug, notification.recordType ?? "nil")
        }
    }
    
    private func handleDatabaseNotification(_ notification: CKDatabaseNotification) async {
        os_log("🔔 Handling database notification - triggering full sync", log: log, type: .info)
        await performFullSync()
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
    
    private func handleRadioStationChange(recordID: CKRecord.ID, changeType: CKQueryNotification.Reason) async {
        switch changeType {
        case .recordCreated, .recordUpdated:
            await syncRadioStationFromCloudKit(recordID: recordID)
        case .recordDeleted:
            await handleRadioStationDeletion(recordID: recordID)
        @unknown default:
            os_log("Unknown radio station change type", log: log, type: .debug)
        }
    }
    
    // MARK: - Individual Sync Methods
    
    private func syncPodcastFeedFromCloudKit(recordID: CKRecord.ID) async {
        do {
            let record = try await privateDatabase.record(for: recordID)
            // Parse and update local podcast feed
            if let feed = try await PodcastCloudKitManager.shared.parsePodcastFeedRecordForSync(record) {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .init("SyncDidUpdatePodcastFeed"),
                        object: nil,
                        userInfo: ["feed": feed]
                    )
                }
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
            
            // Update local episode state
            EpisodeStateManager.shared.setProgress(for: episodeId, progress: progress)
            EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite)
            EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded)
            
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .init("SyncDidUpdateEpisodeState"),
                    object: nil,
                    userInfo: [
                        "episodeId": episodeId,
                        "progress": progress,
                        "isFavorite": isFavorite,
                        "isDownloaded": isDownloaded,
                        "isPlayed": isPlayed
                    ]
                )
            }
        } catch {
            os_log("❌ Failed to sync episode state %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
        }
    }
    
    private func syncRadioStationFromCloudKit(recordID: CKRecord.ID) async {
        do {
            let record = try await privateDatabase.record(for: recordID)
            // Parse and update local radio station
            // Implementation depends on your radio station data structure
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .init("SyncDidUpdateRadioStation"),
                    object: nil,
                    userInfo: ["recordID": recordID.recordName, "record": record]
                )
            }
        } catch {
            os_log("❌ Failed to sync radio station %@: %@", log: log, type: .error, recordID.recordName, error.localizedDescription)
        }
    }
    
    private func handlePodcastFeedDeletion(recordID: CKRecord.ID) async {
        os_log("📡 🗑️ REALTIME SYNC: Handling podcast feed deletion for ID: %@", log: log, type: .info, recordID.recordName)
        
        await MainActor.run {
            // Post notification that PodcastViewModel is listening for
            NotificationCenter.default.post(
                name: .init("CloudKitDidDeletePodcastFeed"),
                object: nil,
                userInfo: ["feedId": recordID.recordName]
            )
        }
    }
    
    private func handleEpisodeStateDeletion(recordID: CKRecord.ID) async {
        // Extract episode ID from record name (assuming format "episode_state_<episodeId>")
        let episodeId = String(recordID.recordName.dropFirst("episode_state_".count))
        
        await MainActor.run {
            NotificationCenter.default.post(
                name: .init("SyncDidDeleteEpisodeState"),
                object: nil,
                userInfo: ["episodeId": episodeId]
            )
        }
    }
    
    private func handleRadioStationDeletion(recordID: CKRecord.ID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .init("SyncDidDeleteRadioStation"),
                object: nil,
                userInfo: ["stationId": recordID.recordName]
            )
        }
    }
    
    // MARK: - Full Sync Operations
    
    func performFullSync() async {
        os_log("🔄 Starting full sync from CloudKit", log: log, type: .info)
        
        DispatchQueue.main.async {
            self.syncStatus = .syncing
            self.pendingSyncOperations += 1
        }
        
        do {
            // Sync podcast feeds
            let podcastFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .init("SyncDidUpdateAllPodcastFeeds"),
                    object: nil,
                    userInfo: ["feeds": podcastFeeds]
                )
            }
            
            // Sync radio stations
            await syncRadioStationsFromCloudKit()
            
            DispatchQueue.main.async {
                self.syncStatus = .success
                self.lastSyncDate = Date()
                self.pendingSyncOperations = max(0, self.pendingSyncOperations - 1)
            }
            
            os_log("✅ Full sync completed successfully", log: log, type: .info)
            
        } catch {
            os_log("❌ Full sync failed: %@", log: log, type: .error, error.localizedDescription)
            
            DispatchQueue.main.async {
                self.syncStatus = .failed(error)
                self.pendingSyncOperations = max(0, self.pendingSyncOperations - 1)
            }
        }
    }
    
    private func syncRadioStationsFromCloudKit() async {
        await withCheckedContinuation { continuation in
            DataStore.shared.fetchRadioStations { stations, error in
                if let stations = stations {
                    NotificationCenter.default.post(
                        name: .init("SyncDidUpdateAllRadioStations"),
                        object: nil,
                        userInfo: ["stations": stations]
                    )
                }
                continuation.resume()
            }
        }
    }
    
    // MARK: - Periodic Sync
    
    private func startPeriodicSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task {
                await self.performLightweightSync()
            }
        }
    }
    
    private func performLightweightSync() async {
        // Sync only essential data every 5 minutes
        ubiquitousStore.synchronize()
        
        // Check for any missed CloudKit changes
        if let lastSync = lastSyncDate, Date().timeIntervalSince(lastSync) > 1800 { // 30 minutes
            await performFullSync()
        }
    }
    
    // MARK: - Public API
    
    func forceSync() async {
        await performFullSync()
    }
    
    func syncNow() {
        ubiquitousStore.synchronize()
    }
    
    func getLastSyncDate() -> Date? {
        return lastSyncDate
    }
    
    func getSyncStatus() -> SyncStatus {
        return syncStatus
    }
}

// MARK: - Extensions for Private Methods Access

extension PodcastCloudKitManager {
    internal func parsePodcastFeedRecordForSync(_ record: CKRecord) async throws -> PodcastFeed? {
        // Parse CloudKit record into PodcastFeed for sync purposes
        guard let title = record["title"] as? String,
              let url = record["url"] as? String else {
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
}