import Foundation
import CloudKit
import OSLog
import CoreData

/// Enhanced CloudKit manager for podcasts with optimized performance
class PodcastCloudKitManager {
    static let shared = PodcastCloudKitManager()
    
    private let container = CKContainer.default()
    private let privateDatabase: CKDatabase
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastCloudKit")
    
    // CloudKit Record Types
    private enum RecordType {
        static let podcastFeed = "PodcastFeed"
        static let podcastEpisode = "PodcastEpisode"
    }
    
    // Batch size limits for CloudKit operations
    private enum BatchLimits {
        static let maxRecordsPerOperation = 400
        static let maxEpisodesPerFeed = 100 // Limit episodes per feed for performance
        static let artworkCacheExpiration: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    }
    
    private init() {
        self.privateDatabase = container.privateCloudDatabase
    }
    
    // MARK: - Fresh Install Setup
    
    /// Complete fresh install setup - fetches all podcasts and preload episodes
    func performFreshInstallSetup() async throws -> [PodcastFeed] {
        os_log("🌟 Starting fresh install CloudKit setup", log: log, type: .info)
        
        // Step 1: Fetch all podcast feeds from CloudKit
        let feeds = try await fetchAllPodcastFeeds()
        os_log("🌟 Fetched %d podcast feeds from CloudKit", log: log, type: .info, feeds.count)
        
        // Step 2: For each feed, fetch and preload episodes in parallel
        let preloadedFeeds = try await preloadEpisodesForFeeds(feeds)
        os_log("🌟 Preloaded episodes for %d feeds", log: log, type: .info, preloadedFeeds.count)
        
        // Step 3: Cache artwork for all feeds in parallel
        let fullyLoadedFeeds = await cacheArtworkForFeeds(preloadedFeeds)
        os_log("🌟 Cached artwork for %d feeds", log: log, type: .info, fullyLoadedFeeds.count)
        
        return fullyLoadedFeeds
    }
    
    // MARK: - Podcast Feed Operations
    
    /// Fetch all podcast feeds from CloudKit efficiently
    private func fetchAllPodcastFeeds() async throws -> [PodcastFeed] {
        let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
        return try await withCheckedThrowingContinuation { continuation in
            var allFeeds: [PodcastFeed] = []
            var cursor: CKQueryOperation.Cursor?
            
            func fetchBatch() {
                let operation: CKQueryOperation
                
                if let cursor = cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    operation = CKQueryOperation(query: query)
                }
                
                operation.resultsLimit = BatchLimits.maxRecordsPerOperation
                operation.qualityOfService = .userInitiated
                
                operation.recordFetchedBlock = { record in
                    if let feed = self.podcastFeedFromRecord(record) {
                        allFeeds.append(feed)
                    }
                }
                
                operation.queryCompletionBlock = { cursor, error in
                    if let error = error {
                        os_log("❌ Error fetching podcast feeds: %@", log: self.log, type: .error, error.localizedDescription)
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    if let cursor = cursor {
                        self.cursor = cursor
                        fetchBatch() // Fetch next batch
                    } else {
                        // All batches fetched
                        continuation.resume(returning: allFeeds)
                    }
                }
                
                privateDatabase.add(operation)
            }
            
            fetchBatch()
        }
    }
    
    /// Save podcast feed to CloudKit with optimized data handling
    func savePodcastFeed(_ feed: PodcastFeed) async throws {
        let record = CKRecord(recordType: RecordType.podcastFeed, recordID: CKRecord.ID(recordName: feed.id))
        
        // Basic feed information
        record["title"] = feed.title as CKRecordValue
        record["url"] = feed.url as CKRecordValue
        record["artworkUrl"] = feed.artworkUrl as CKRecordValue?
        record["descriptionText"] = feed.descriptionText as CKRecordValue?
        record["lastUpdated"] = Date() as CKRecordValue
        
        // Handle artwork efficiently
        if let imageData = feed.imageData {
            let asset = try await createAssetFromImageData(imageData, identifier: "artwork_\(feed.id)")
            record["artwork"] = asset
        }
        
        try await privateDatabase.save(record)
        os_log("✅ Saved podcast feed to CloudKit: %@", log: log, type: .info, feed.title)
    }
    
    // MARK: - Episode Preloading
    
    /// Preload episodes for all feeds in parallel for optimal performance
    private func preloadEpisodesForFeeds(_ feeds: [PodcastFeed]) async throws -> [PodcastFeed] {
        return try await withThrowingTaskGroup(of: PodcastFeed.self) { group in
            var preloadedFeeds: [PodcastFeed] = []
            
            for feed in feeds {
                group.addTask {
                    return try await self.preloadEpisodesForFeed(feed)
                }
            }
            
            for try await preloadedFeed in group {
                preloadedFeeds.append(preloadedFeed)
            }
            
            return preloadedFeeds
        }
    }
    
    /// Preload episodes for a specific feed
    private func preloadEpisodesForFeed(_ feed: PodcastFeed) async throws -> PodcastFeed {
        // Check if episodes are already cached in CloudKit
        let cachedEpisodes = try await fetchCachedEpisodes(for: feed.id)
        
        var updatedFeed = feed
        
        if !cachedEpisodes.isEmpty {
            // Use cached episodes from CloudKit
            updatedFeed.episodes = Array(cachedEpisodes.prefix(BatchLimits.maxEpisodesPerFeed))
            os_log("📦 Using %d cached episodes for feed: %@", log: log, type: .debug, updatedFeed.episodes.count, feed.title)
        } else {
            // Fetch fresh episodes from RSS and cache them
            updatedFeed = try await fetchAndCacheEpisodesFromRSS(feed)
            os_log("🔄 Fetched and cached %d episodes for feed: %@", log: log, type: .debug, updatedFeed.episodes.count, feed.title)
        }
        
        return updatedFeed
    }
    
    /// Fetch cached episodes from CloudKit
    private func fetchCachedEpisodes(for feedId: String) async throws -> [PodcastEpisode] {
        let predicate = NSPredicate(format: "feedId == %@", feedId)
        let query = CKQuery(recordType: RecordType.podcastEpisode, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        let records = try await performQuery(query, limit: BatchLimits.maxEpisodesPerFeed)
        return records.compactMap { podcastEpisodeFromRecord($0, feedId: feedId) }
    }
    
    /// Fetch episodes from RSS and cache them to CloudKit
    private func fetchAndCacheEpisodesFromRSS(_ feed: PodcastFeed) async throws -> PodcastFeed {
        // Fetch from RSS
        guard let url = URL(string: feed.url) else {
            throw PodcastError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Parse RSS on background queue
        let updatedFeed = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rssParser = RSSParser(data: data, feedId: feed.id)
                rssParser.parse()
                
                var parsedFeed = feed
                parsedFeed.title = rssParser.podcastTitle ?? feed.title
                parsedFeed.descriptionText = rssParser.podcastDescription ?? feed.descriptionText
                parsedFeed.artworkUrl = rssParser.artworkUrl ?? feed.artworkUrl
                parsedFeed.episodes = Array(rssParser.episodes.prefix(BatchLimits.maxEpisodesPerFeed))
                
                continuation.resume(returning: parsedFeed)
            }
        }
        
        // Cache episodes to CloudKit in background
        Task.detached(priority: .utility) {
            try? await self.cacheEpisodesToCloudKit(updatedFeed.episodes, feedId: feed.id)
        }
        
        return updatedFeed
    }
    
    /// Cache episodes to CloudKit for future fast loading
    private func cacheEpisodesToCloudKit(_ episodes: [PodcastEpisode], feedId: String) async throws {
        guard !episodes.isEmpty else { return }
        
        let records = episodes.map { episode in
            let record = CKRecord(recordType: RecordType.podcastEpisode, recordID: CKRecord.ID(recordName: episode.id))
            record["feedId"] = feedId as CKRecordValue
            record["title"] = episode.title as CKRecordValue
            record["audioUrl"] = episode.audioUrl as CKRecordValue?
            record["descriptionText"] = episode.descriptionText as CKRecordValue?
            record["publicationDate"] = episode.publicationDate as CKRecordValue?
            record["duration"] = episode.duration as CKRecordValue
            record["fileSize"] = episode.fileSize as CKRecordValue
            record["cachedAt"] = Date() as CKRecordValue
            return record
        }
        
        // Save in batches
        try await saveBatchRecords(records)
        os_log("💾 Cached %d episodes to CloudKit for feed: %@", log: log, type: .debug, episodes.count, feedId)
    }
    
    // MARK: - Artwork Caching
    
    /// Cache artwork for all feeds in parallel
    private func cacheArtworkForFeeds(_ feeds: [PodcastFeed]) async -> [PodcastFeed] {
        return await withTaskGroup(of: PodcastFeed.self) { group in
            var cachedFeeds: [PodcastFeed] = []
            
            for feed in feeds {
                group.addTask {
                    return await self.cacheArtworkForFeed(feed)
                }
            }
            
            for await cachedFeed in group {
                cachedFeeds.append(cachedFeed)
            }
            
            return cachedFeeds
        }
    }
    
    /// Cache artwork for a specific feed
    private func cacheArtworkForFeed(_ feed: PodcastFeed) async -> PodcastFeed {
        var updatedFeed = feed
        
        // Skip if artwork is already cached
        if feed.imageData != nil {
            return updatedFeed
        }
        
        // Try to download artwork
        if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
            do {
                let (imageData, _) = try await URLSession.shared.data(from: url)
                updatedFeed.imageData = imageData
                os_log("🖼️ Cached artwork for feed: %@", log: log, type: .debug, feed.title)
            } catch {
                os_log("❌ Failed to cache artwork for feed %@: %@", log: log, type: .error, feed.title, error.localizedDescription)
            }
        }
        
        return updatedFeed
    }
    
    // MARK: - Utility Methods
    
    /// Create CloudKit asset from image data
    private func createAssetFromImageData(_ imageData: Data, identifier: String) async throws -> CKAsset {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier)
            .appendingPathExtension("jpg")
        
        try imageData.write(to: tempURL)
        return CKAsset(fileURL: tempURL)
    }
    
    /// Perform CloudKit query with proper pagination
    private func performQuery(_ query: CKQuery, limit: Int) async throws -> [CKRecord] {
        return try await withCheckedThrowingContinuation { continuation in
            var allRecords: [CKRecord] = []
            var cursor: CKQueryOperation.Cursor?
            
            func fetchBatch() {
                let operation: CKQueryOperation
                
                if let cursor = cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    operation = CKQueryOperation(query: query)
                }
                
                operation.resultsLimit = min(limit - allRecords.count, BatchLimits.maxRecordsPerOperation)
                operation.qualityOfService = .userInitiated
                
                operation.recordFetchedBlock = { record in
                    allRecords.append(record)
                }
                
                operation.queryCompletionBlock = { cursor, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    if let cursor = cursor, allRecords.count < limit {
                        self.cursor = cursor
                        fetchBatch()
                    } else {
                        continuation.resume(returning: Array(allRecords.prefix(limit)))
                    }
                }
                
                privateDatabase.add(operation)
            }
            
            fetchBatch()
        }
    }
    
    /// Save records in batches to CloudKit
    private func saveBatchRecords(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        
        let batches = records.chunked(into: BatchLimits.maxRecordsPerOperation)
        
        for batch in batches {
            let operation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            operation.qualityOfService = .utility
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsCompletionBlock = { _, _, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                
                privateDatabase.add(operation)
            }
        }
    }
    
    // MARK: - Record Conversion
    
    private func podcastFeedFromRecord(_ record: CKRecord) -> PodcastFeed? {
        guard let id = record.recordID.recordName as String?,
              let title = record["title"] as? String,
              let url = record["url"] as? String else {
            return nil
        }
        
        let artworkUrl = record["artworkUrl"] as? String
        let descriptionText = record["descriptionText"] as? String
        
        // Get cached artwork if available
        var imageData: Data?
        if let asset = record["artwork"] as? CKAsset,
           let artworkURL = asset.fileURL {
            imageData = try? Data(contentsOf: artworkURL)
        }
        
        return PodcastFeed(
            id: id,
            title: title,
            url: url,
            artworkUrl: artworkUrl,
            description: descriptionText,
            iconData: nil,
            imageData: imageData,
            episodes: []
        )
    }
    
    private func podcastEpisodeFromRecord(_ record: CKRecord, feedId: String) -> PodcastEpisode? {
        guard let id = record.recordID.recordName as String?,
              let title = record["title"] as? String else {
            return nil
        }
        
        let audioUrl = record["audioUrl"] as? String
        let descriptionText = record["descriptionText"] as? String
        let publicationDate = record["publicationDate"] as? Date
        let duration = record["duration"] as? Double ?? 0.0
        let fileSize = record["fileSize"] as? Int64 ?? 0
        
        return PodcastEpisode(
            id: id,
            title: title,
            audioUrl: audioUrl,
            descriptionText: descriptionText,
            publicationDate: publicationDate,
            duration: duration,
            fileSize: fileSize,
            feedId: feedId
        )
    }
}

// MARK: - Error Types

enum PodcastError: Error {
    case invalidURL
    case noData
    case parsingFailed
    case cloudKitError(Error)
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
} 