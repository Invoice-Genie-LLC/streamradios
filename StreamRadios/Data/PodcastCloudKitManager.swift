import Foundation
import CloudKit
import CoreData
import os

// MARK: - Array Extension for Batching
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// CloudKit manager for podcast feeds and episode states with proper conflict resolution
class PodcastCloudKitManager {
    static let shared = PodcastCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.radio.streamradios", category: "PodcastCloudKit")
    
    // CloudKit Record Types
    private enum RecordType {
        static let episodeState = "EpisodeState"
        static let podcastFeed = "PodcastFeed"
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
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
        
        try await privateDatabase.add(operation)
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
            
            os_log("✅ Bulk CloudKit sync completed: %d synced, %d prepared for Core Data", 
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
            
            os_log("✅ Individual CloudKit sync completed: %d synced, %d errors, success: %@", 
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
    
    /// Save podcast feed to CloudKit
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed) async throws {
        let recordID = CKRecord.ID(recordName: feed.id)
        
        // Try to fetch existing record first
        var record: CKRecord
        do {
            record = try await privateDatabase.record(for: recordID)
        } catch CKError.unknownItem {
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
        let savedRecord = try await privateDatabase.save(record)
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
        } else if feedDeletionSucceeded && episodeDeletionError != nil {
            os_log("⚠️ CloudKit: Feed deleted but some episode states may remain for %@: %@", log: log, type: .default, feedId, episodeDeletionError!.localizedDescription)
            // Don't throw - feed is gone which is the main goal
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
        
        os_log("🔍 CloudKit: Found %d episode IDs in Core Data for feed %@, searching CloudKit", log: log, type: .info, episodeIds.count, feedId)
        
        var recordIDsToDelete: [CKRecord.ID] = []
        var actualFeedIds: Set<String> = []
        
        // Search for episode states by episode ID
        for episodeId in episodeIds {
            let recordID = CKRecord.ID(recordName: "episode_state_\(episodeId)")
            
            do {
                let record = try await privateDatabase.record(for: recordID)
                recordIDsToDelete.append(record.recordID)
                
                // Track what feedIds these episode states actually have
                if let actualFeedId = record["feedId"] as? String {
                    actualFeedIds.insert(actualFeedId)
                }
                
                os_log("🗑️ CloudKit: Will delete episode state by episodeId: %@ (actual feedId: %@)", log: log, type: .debug, episodeId, record["feedId"] as? String ?? "unknown")
            } catch CKError.unknownItem {
                // Episode state doesn't exist - that's fine
                continue
            } catch {
                os_log("⚠️ CloudKit: Error checking episode state %@: %@", log: log, type: .default, episodeId, error.localizedDescription)
                continue
            }
        }
        
        // Log the feed ID mismatch for debugging
        if actualFeedIds.count > 0 && !actualFeedIds.contains(feedId) {
            os_log("⚠️ CloudKit: Feed ID mismatch detected! Deleting feed %@ but episode states have feedIds: %@", log: log, type: .default, feedId, Array(actualFeedIds).joined(separator: ", "))
        }
        
        if !recordIDsToDelete.isEmpty {
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
            
            try await privateDatabase.add(operation)
            
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
