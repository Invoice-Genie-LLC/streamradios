import Foundation
import CloudKit
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
        } catch {
            os_log("❌ Failed to save episode state to CloudKit: %@", log: log, type: .error, error.localizedDescription)
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
            // Episode state doesn't exist in CloudKit yet
            return nil
        }
    }
    
    /// Sync episode states from CloudKit with different behavior for fresh install vs upgrade
    /// - For fresh install: sync isFavorite but NOT isDownloaded (files don't exist)
    /// - For upgrade: sync both isFavorite and isDownloaded (files might still exist)
    /// - Returns: Array of episode state updates that should be saved to Core Data
    func syncEpisodeStatesFromCloudKit(for episodeIds: [String], isFreshInstall: Bool) async -> [EpisodeStateUpdate] {
        os_log("🔄 Starting episode state sync from CloudKit for %d episodes (fresh install: %@)", 
               log: log, type: .info, episodeIds.count, isFreshInstall ? "YES" : "NO")
        
        var syncedCount = 0
        var skippedDownloadsCount = 0
        var coreDataUpdates: [EpisodeStateUpdate] = []
        
        do {
            // PERFORMANCE FIX: Use bulk fetch instead of individual requests to avoid rate limits
            os_log("📡 Fetching all episode states from CloudKit in bulk to avoid rate limits", log: log, type: .info)
            let allCloudStates = try await fetchAllEpisodeStatesFromCloudKit()
            
            os_log("📊 Retrieved %d episode states from CloudKit, filtering for %d local episodes", 
                   log: log, type: .info, allCloudStates.count, episodeIds.count)
            
            // Convert episodeIds to a Set for faster lookup
            let episodeIdSet = Set(episodeIds)
            
            // Process only the episode states we care about
            for (episodeId, cloudState) in allCloudStates {
                // Only process if this episode exists locally
                guard episodeIdSet.contains(episodeId) else { continue }
                
                // Always sync progress, isFavorite, and isPlayed to EpisodeStateManager
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: cloudState.progress)
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: cloudState.isFavorite)
                
                // Handle isDownloaded based on install type
                let finalIsDownloaded: Bool
                if isFreshInstall {
                    // Fresh install: Don't sync isDownloaded because download files don't exist
                    finalIsDownloaded = false
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                    if cloudState.isDownloaded {
                        skippedDownloadsCount += 1
                        os_log("📱 Fresh install: Skipped download state for episode %@ (file doesn't exist)", 
                               log: log, type: .debug, episodeId)
                    }
                } else {
                    // Upgrade: Sync isDownloaded because files might still exist locally
                    finalIsDownloaded = cloudState.isDownloaded
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: cloudState.isDownloaded)
                    os_log("📱 Upgrade: Synced download state for episode %@ (isDownloaded: %@)", 
                           log: log, type: .debug, episodeId, cloudState.isDownloaded ? "YES" : "NO")
                }
                
                // Prepare Core Data update
                coreDataUpdates.append(EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: cloudState.progress,
                    isFavorite: cloudState.isFavorite,
                    isDownloaded: finalIsDownloaded,
                    isPlayed: cloudState.isPlayed
                ))
                
                syncedCount += 1
                
                // Log progress sync for debugging
                if cloudState.progress > 0 {
                    os_log("📊 Synced progress for episode %@: %.3f", log: log, type: .debug, episodeId, cloudState.progress)
                }
            }
            
        } catch {
            os_log("❌ Failed to bulk fetch episode states from CloudKit: %@", log: log, type: .error, error.localizedDescription)
            
            // Fallback to individual fetches with batching to avoid overwhelming CloudKit
            os_log("🔄 Falling back to batched individual fetches", log: log, type: .info)
            let batchSize = 50 // Smaller batches to avoid rate limits
            let batches = episodeIds.chunked(into: batchSize)
            
            for (batchIndex, batch) in batches.enumerated() {
                os_log("📦 Processing batch %d/%d (%d episodes)", log: log, type: .debug, batchIndex + 1, batches.count, batch.count)
                
                for episodeId in batch {
                    do {
                        if let cloudState = try await fetchEpisodeStateFromCloudKit(episodeId) {
                            // Process the same way as bulk fetch
                            EpisodeStateManager.shared.setProgress(for: episodeId, progress: cloudState.progress)
                            EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: cloudState.isFavorite)
                            
                            let finalIsDownloaded: Bool
                            if isFreshInstall {
                                finalIsDownloaded = false
                                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                if cloudState.isDownloaded { skippedDownloadsCount += 1 }
                            } else {
                                finalIsDownloaded = cloudState.isDownloaded
                                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: cloudState.isDownloaded)
                            }
                            
                            coreDataUpdates.append(EpisodeStateUpdate(
                                episodeId: episodeId,
                                progress: cloudState.progress,
                                isFavorite: cloudState.isFavorite,
                                isDownloaded: finalIsDownloaded,
                                isPlayed: cloudState.isPlayed
                            ))
                            
                            syncedCount += 1
                        }
                    } catch {
                        os_log("❌ Failed to sync episode state for %@: %@", log: log, type: .error, episodeId, error.localizedDescription)
                    }
                }
                
                // Add small delay between batches to respect rate limits
                if batchIndex < batches.count - 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                }
            }
        }
        
        // Save all synced states to Core Data immediately for fast app restart
        if !coreDataUpdates.isEmpty {
            os_log("📦 Prepared %d episode state updates for Core Data saving", 
                   log: log, type: .info, coreDataUpdates.count)
        }
        
        os_log("✅ Episode state sync completed: %d synced, %d downloads skipped (fresh install), %d prepared for Core Data", 
               log: log, type: .info, syncedCount, skippedDownloadsCount, coreDataUpdates.count)
        
        // Return the updates so the caller can save them to Core Data
        return coreDataUpdates
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
    
    /// Delete podcast feed from CloudKit
    func deletePodcastFeedFromCloudKit(_ feedId: String) async throws {
        let recordID = CKRecord.ID(recordName: feedId)
        
        os_log("🔄 CloudKit: Starting deletion of feed record: %@", log: log, type: .info, feedId)
        
        do {
            // First check if the record exists
            do {
                let existingRecord = try await privateDatabase.record(for: recordID)
                os_log("✅ CloudKit: Found existing feed record to delete: %@", log: log, type: .info, existingRecord["title"] as? String ?? feedId)
            } catch CKError.unknownItem {
                os_log("⚠️ CloudKit: Feed record not found, already deleted: %@", log: log, type: .default, feedId)
                return // Consider this a success - record is already gone
            }
            
            // Delete the record (this will cascade delete all episode states with .deleteSelf references)
            let deletedRecordID = try await privateDatabase.deleteRecord(withID: recordID)
            os_log("✅ CloudKit: Successfully deleted podcast feed: %@ (recordID: %@)", log: log, type: .info, feedId, deletedRecordID.recordName)
            os_log("🗑️ CloudKit: Cascade deletion should have removed all related episode states", log: log, type: .info)
            
        } catch {
            os_log("❌ CloudKit: Failed to delete podcast feed %@: %@", log: log, type: .error, feedId, error.localizedDescription)
            
            if let ckError = error as? CKError {
                os_log("❌ CloudKit: Error code %ld: %@", log: log, type: .error, ckError.code.rawValue, ckError.localizedDescription)
                
                switch ckError.code {
                case .networkUnavailable:
                    os_log("📶 CloudKit: Network unavailable - feed deletion will be retried when network is restored", log: log, type: .default)
                case .quotaExceeded:
                    os_log("💾 CloudKit: Quota exceeded - deletion failed", log: log, type: .error)
                case .requestRateLimited:
                    os_log("⏱️ CloudKit: Rate limited - deletion will be retried", log: log, type: .default)
                default:
                    os_log("❓ CloudKit: Unexpected error during deletion", log: log, type: .error)
                }
            }
            
            throw error
        }
    }
    

}
