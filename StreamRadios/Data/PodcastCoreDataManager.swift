import Foundation
import CoreData
import OSLog

/// Enhanced Core Data manager specifically for podcast operations with optimal performance
class PodcastCoreDataManager {
    static let shared = PodcastCoreDataManager()
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastCoreData")
    private let coreDataStack = CoreDataStack.shared
    
    // Performance optimization settings
    private enum BatchSettings {
        static let feedBatchSize = 100
        static let episodeBatchSize = 500
        static let prefetchRelationships = ["episodes", "feed"]
    }
    
    private init() {}
    
    // MARK: - Fresh Install Storage
    
    /// Store all podcast data efficiently for fresh install
    func storeFreshInstallData(_ feeds: [PodcastFeed]) async throws {
        os_log("💾 Storing fresh install data for %d feeds", log: log, type: .info, feeds.count)
        
        let backgroundContext = coreDataStack.newBackgroundContext()
        backgroundContext.automaticallyMergesChangesFromParent = true
        
        try await backgroundContext.perform {
            // Clear existing data first
            try self.clearAllPodcastData(in: backgroundContext)
            
            // Use batch insert for maximum performance
            try self.batchInsertFeeds(feeds, in: backgroundContext)
            try self.batchInsertEpisodes(from: feeds, in: backgroundContext)
            
            // Save with proper error handling
            try backgroundContext.save()
            
            os_log("✅ Successfully stored fresh install data", log: self.log, type: .info)
        }
    }
    
    /// Clear all existing podcast data
    private func clearAllPodcastData(in context: NSManagedObjectContext) throws {
        // Delete episodes first (child objects)
        let episodeDeleteRequest = NSBatchDeleteRequest(fetchRequest: PodcastModel.fetchRequest())
        try context.execute(episodeDeleteRequest)
        
        // Delete feeds
        let feedDeleteRequest = NSBatchDeleteRequest(fetchRequest: FeedModel.fetchRequest())
        try context.execute(feedDeleteRequest)
        
        os_log("🗑️ Cleared existing podcast data", log: log, type: .debug)
    }
    
    /// Batch insert feeds for optimal performance
    private func batchInsertFeeds(_ feeds: [PodcastFeed], in context: NSManagedObjectContext) throws {
        guard !feeds.isEmpty else { return }
        
        let batchInsert = NSBatchInsertRequest(entity: FeedModel.entity()) { (managedObject: NSManagedObject) -> Bool in
            guard let feedModel = managedObject as? FeedModel else { return true }
            
            var index = 0
            defer { index += 1 }
            
            if index < feeds.count {
                let feed = feeds[index]
                feedModel.id = feed.id
                feedModel.title = feed.title
                feedModel.url = feed.url
                feedModel.artworkUrl = feed.artworkUrl
                feedModel.descriptionText = feed.descriptionText
                feedModel.imageData = feed.imageData
                feedModel.sortOrder = Int16(index)
                return false
            }
            return true
        }
        
        batchInsert.resultType = NSBatchInsertRequestResultType.objectIDs
        try context.execute(batchInsert)
        
        os_log("📦 Batch inserted %d feeds", log: log, type: .debug, feeds.count)
    }
    
    /// Batch insert episodes with duplicate checking for optimal performance
    private func batchInsertEpisodes(from feeds: [PodcastFeed], in context: NSManagedObjectContext) throws {
        let allEpisodes = feeds.flatMap { feed in
            feed.episodes.map { episode in (episode, feed.id) }
        }
        
        guard !allEpisodes.isEmpty else { return }
        
        // CRITICAL FIX: Check for existing episodes to prevent duplicates
        let episodeIds = allEpisodes.map { $0.0.id }
        let existingEpisodeIds = try getExistingEpisodeIds(episodeIds: episodeIds, in: context)
        
        // Filter out episodes that already exist
        let newEpisodes = allEpisodes.filter { !existingEpisodeIds.contains($0.0.id) }
        
        guard !newEpisodes.isEmpty else {
            os_log("📦 No new episodes to insert - all %d episodes already exist", log: log, type: .debug, allEpisodes.count)
            return
        }
        
        // Batch insert only new episodes
        var insertIndex = 0
        let batchInsert = NSBatchInsertRequest(entity: PodcastModel.entity()) { (managedObject: NSManagedObject) -> Bool in
            guard let episodeModel = managedObject as? PodcastModel else { return true }
            
            if insertIndex < newEpisodes.count {
                let (episode, feedId) = newEpisodes[insertIndex]
                episodeModel.id = episode.id
                episodeModel.title = episode.title
                episodeModel.audioUrl = episode.audioUrl
                episodeModel.descriptionText = episode.descriptionText
                episodeModel.publicationDate = episode.publicationDate
                episodeModel.duration = episode.duration
                episodeModel.fileSize = episode.fileSize ?? 0
                episodeModel.feedId = feedId
                episodeModel.progress = 0.0
                episodeModel.isPlayed = false
                episodeModel.isFavorite = false
                episodeModel.isDownloaded = false
                insertIndex += 1
                return false
            }
            return true
        }
        
        batchInsert.resultType = NSBatchInsertRequestResultType.objectIDs
        try context.execute(batchInsert)
        
        os_log("📦 Batch inserted %d new episodes (skipped %d duplicates)", log: log, type: .info, newEpisodes.count, existingEpisodeIds.count)
    }
    
    /// Get existing episode IDs for multiple episodes (batch duplicate checking)
    private func getExistingEpisodeIds(episodeIds: [String], in context: NSManagedObjectContext) throws -> Set<String> {
        let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", episodeIds)
        request.propertiesToFetch = ["id"]
        request.resultType = .managedObjectResultType
        
        let episodes = try context.fetch(request)
        return Set(episodes.compactMap { $0.id })
    }
    
    // MARK: - Fast Loading for App Launch
    
    /// Load all podcast feeds instantly with preloaded episodes
    func loadAllPodcastsInstantly() async throws -> [PodcastFeed] {
        os_log("⚡ Loading all podcasts instantly", log: log, type: .info)
        
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        return try await backgroundContext.perform {
            let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            feedRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
            feedRequest.fetchBatchSize = BatchSettings.feedBatchSize
            feedRequest.relationshipKeyPathsForPrefetching = BatchSettings.prefetchRelationships
            
            let managedFeeds = try backgroundContext.fetch(feedRequest)
            
            // Convert to PodcastFeed objects with preloaded episodes
            var podcastFeeds: [PodcastFeed] = []
            
            for managedFeed in managedFeeds {
                var feed = managedFeed.toPodcastFeed()
                
                // Load episodes for this feed
                let episodes = try self.loadEpisodesForFeed(feedId: feed.id, in: backgroundContext)
                feed.episodes = episodes
                
                podcastFeeds.append(feed)
            }
            
            os_log("⚡ Loaded %d feeds with %d total episodes instantly", 
                   log: self.log, type: .info, 
                   podcastFeeds.count, 
                   podcastFeeds.reduce(0) { $0 + $1.episodes.count })
            
            return podcastFeeds
        }
    }
    
    /// Load episodes for a specific feed efficiently with contamination prevention
    func loadEpisodesForFeed(feedId: String, in context: NSManagedObjectContext) throws -> [PodcastEpisode] {
        let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        episodeRequest.fetchBatchSize = BatchSettings.episodeBatchSize
        
        let managedEpisodes = try context.fetch(episodeRequest)
        let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
        
        os_log("📊 CORE DATA: Loaded %d episodes from database for feed %@", log: self.log, type: .info, episodes.count, feedId)
        
        // Log first few episode titles to check formatting
        if !episodes.isEmpty {
            os_log("📋 CORE DATA TITLES (first 3):", log: self.log, type: .info)
            for (index, episode) in episodes.prefix(3).enumerated() {
                let titlePreview = String(episode.title.prefix(60))
                os_log("   [%d] ID: %@... Title: %@", log: self.log, type: .info, index, String(episode.id.prefix(8)), titlePreview)
            }
        }
        
        // 🛡️ CONTAMINATION PREVENTION: Double-check all episodes belong to the requested feed
        let safeEpisodes = episodes.filter { $0.feedId == feedId }
        
        // 🚨 CORRUPTION DETECTION: Check for episodes with empty titles
        let validEpisodes = safeEpisodes.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if validEpisodes.count != safeEpisodes.count {
            let corruptedCount = safeEpisodes.count - validEpisodes.count
            os_log("🚨 CORE DATA CORRUPTION: Found %d episodes with empty titles for feed %@", log: self.log, type: .error, corruptedCount, feedId)
            
            // Log the corrupted episodes
            let corruptedEpisodes = safeEpisodes.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for episode in corruptedEpisodes.prefix(5) {
                os_log("🚨 CORRUPTED EPISODE: ID '%@' has empty title", log: self.log, type: .error, episode.id)
            }
            
            // Trigger immediate cleanup of corrupted episodes
            Task.detached(priority: .background) {
                await self.deleteCorruptedEpisodes(feedId: feedId, corruptedEpisodeIds: corruptedEpisodes.map { $0.id })
            }
        }
        
        if safeEpisodes.count != episodes.count {
            let contaminatedCount = episodes.count - safeEpisodes.count
            print("🚨 CORE DATA CONTAMINATION: Found \(contaminatedCount) episodes with wrong feedId in Core Data for feed \(feedId)")
            
            // Log the contaminated episodes for debugging
            let contaminatedEpisodes = episodes.filter { $0.feedId != feedId }
            for episode in contaminatedEpisodes.prefix(3) {
                print("🚨 CONTAMINATED EPISODE: '\(episode.title)' has feedId '\(episode.feedId)' but was fetched for feed '\(feedId)'")
            }
            
            // Trigger immediate Core Data cleanup for this feed
            Task.detached(priority: .background) {
                await self.cleanupContaminatedEpisodes(targetFeedId: feedId, contaminatedEpisodes: contaminatedEpisodes)
            }
        }
        
        return validEpisodes
    }
    
    /// Get episodes for a specific feed (optimized for UI access)
    func getEpisodesForFeed(_ feedId: String) async -> [PodcastEpisode] {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        return await backgroundContext.perform {
            do {
                return try self.loadEpisodesForFeed(feedId: feedId, in: backgroundContext)
            } catch {
                os_log("❌ Error loading episodes for feed %@: %@", 
                       log: self.log, type: .error, feedId, error.localizedDescription)
                return []
            }
        }
    }
    
    // MARK: - Performance Optimized Queries
    
    /// Get feed count without loading data (for performance metrics)
    func getFeedCount() async -> Int {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        return await backgroundContext.perform {
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            request.includesPropertyValues = false
            request.includesSubentities = false
            
            do {
                return try backgroundContext.count(for: request)
            } catch {
                os_log("❌ Error counting feeds: %@", log: self.log, type: .error, error.localizedDescription)
                return 0
            }
        }
    }
    
    /// Get episode count for a feed without loading data
    func getEpisodeCount(for feedId: String) async -> Int {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        return await backgroundContext.perform {
            let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            request.predicate = NSPredicate(format: "feedId == %@", feedId)
            request.includesPropertyValues = false
            request.includesSubentities = false
            
            do {
                return try backgroundContext.count(for: request)
            } catch {
                os_log("❌ Error counting episodes for feed %@: %@", 
                       log: self.log, type: .error, feedId, error.localizedDescription)
                return 0
            }
        }
    }
    
    // MARK: - Data Integrity Validation
    
    /// Validate data integrity and detect any episode contamination across feeds
    func validateDataIntegrity() async -> (isValid: Bool, issues: [String]) {
        let backgroundContext = coreDataStack.newBackgroundContext()
        var issues: [String] = []
        
        return await backgroundContext.perform {
            do {
                // Check for episodes with invalid feedIds
                let invalidFeedIdRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                invalidFeedIdRequest.predicate = NSPredicate(format: "feedId == nil OR feedId == ''")
                let invalidFeedIdEpisodes = try backgroundContext.fetch(invalidFeedIdRequest)
                
                if !invalidFeedIdEpisodes.isEmpty {
                    issues.append("Found \(invalidFeedIdEpisodes.count) episodes with invalid/empty feedIds")
                }
                
                // Check for episodes with mismatched feed relationships
                let allEpisodesRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                let allEpisodes = try backgroundContext.fetch(allEpisodesRequest)
                
                var feedIdMismatches = 0
                for episode in allEpisodes {
                    if let feed = episode.feed,
                       let episodeFeedId = episode.feedId,
                       let feedId = feed.id,
                       episodeFeedId != feedId {
                        feedIdMismatches += 1
                    }
                }
                
                if feedIdMismatches > 0 {
                    issues.append("Found \(feedIdMismatches) episodes with feedId/feed relationship mismatches")
                }
                
                // Check for duplicate episode IDs across different feeds
                let episodesByFeed = Dictionary(grouping: allEpisodes) { $0.feedId }
                var duplicateIds: Set<String> = []
                
                for (feedId, episodes) in episodesByFeed {
                    let episodeIds = episodes.compactMap { $0.id }
                    let uniqueIds = Set(episodeIds)
                    
                    if episodeIds.count != uniqueIds.count {
                        issues.append("Feed \(feedId ?? "unknown") has duplicate episode IDs")
                    }
                    
                    // Check if any episode IDs appear in other feeds
                    for otherId in episodesByFeed.keys {
                        guard otherId != feedId else { continue }
                        let otherEpisodes = episodesByFeed[otherId] ?? []
                        let otherIds = Set(otherEpisodes.compactMap { $0.id })
                        let intersection = uniqueIds.intersection(otherIds)
                        
                        if !intersection.isEmpty {
                            issues.append("Episode IDs shared between feeds \(feedId ?? "unknown") and \(otherId ?? "unknown"): \(intersection.count) episodes")
                        }
                    }
                }
                
                os_log("🔍 Data integrity check completed: %d issues found", log: self.log, type: .info, issues.count)
                return (isValid: issues.isEmpty, issues: issues)
                
            } catch {
                issues.append("Failed to validate data integrity: \(error.localizedDescription)")
                return (isValid: false, issues: issues)
            }
        }
    }
    
    // MARK: - Incremental Updates
    
    /// Add new episodes to existing feed (for pull-to-refresh)
    func addNewEpisodes(_ episodes: [PodcastEpisode], to feedId: String) async throws {
        guard !episodes.isEmpty else { return }
        
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            // Check which episodes are actually new
            let existingEpisodeIds = try self.getExistingEpisodeIds(for: feedId, in: backgroundContext)
            let newEpisodes = episodes.filter { !existingEpisodeIds.contains($0.id) }
            
            guard !newEpisodes.isEmpty else {
                os_log("📝 No new episodes to add for feed %@", log: self.log, type: .debug, feedId)
                return
            }
            
            // Add new episodes with contamination prevention
            for episode in newEpisodes {
                // ENHANCED CONTAMINATION PREVENTION: Multi-layer episode validation
                guard !episode.id.isEmpty,
                      !episode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !episode.audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !feedId.isEmpty else {
                    print("🚨 INVALID EPISODE DATA: Skipping episode with empty/invalid fields - ID='\(episode.id)', Title='\(episode.title)', AudioUrl='\(episode.audioUrl)', FeedId='\(feedId)'")
                    continue
                }
                
                // ENHANCED SAFETY CHECK: Ensure episode belongs to this feed
                if !episode.feedId.isEmpty && episode.feedId != feedId {
                    print("🚨 EPISODE FEEDID MISMATCH: Episode feedId='\(episode.feedId)' but adding to feed='\(feedId)'")
                    continue
                }
                
                // EPISODE ID INTEGRITY CHECK: Validate deterministic IDs match expected pattern
                if episode.id.hasPrefix("det_f") {
                    let expectedFeedHash = abs(feedId.lowercased().hashValue)
                    let expectedPrefix = "det_f\(expectedFeedHash)_"
                    if !episode.id.hasPrefix(expectedPrefix) {
                        print("🚨 CORE DATA SAVE: Episode ID '\(episode.id)' doesn't match feed hash pattern for feed '\(feedId)'")
                        print("🚨 Expected prefix: '\(expectedPrefix)', Episode title: '\(episode.title)'")
                        continue // Skip contaminated episode
                    }
                }
                
                let managedEpisode = PodcastModel(context: backgroundContext)
                var safeEpisode = episode
                safeEpisode.feedId = feedId  // CRITICAL: Always use the correct feedId
                managedEpisode.update(from: safeEpisode)
                managedEpisode.feedId = feedId  // Double-ensure the feedId is correct
            }
            
            try backgroundContext.save()
            os_log("✅ Added %d new episodes to feed %@", log: self.log, type: .info, newEpisodes.count, feedId)
        }
    }
    
    /// Reconcile episodes for a feed to match exactly the parsed feed items (no accumulation)
    /// - Ensures Core Data contains exactly the set of episodes from the latest RSS parse
    /// - Upserts parsed episodes and deletes any that are no longer present in the feed
    /// - Uses optimized processing to prevent duplicates and avoid main thread blocking
    func reconcileEpisodes(for feedId: String, parsedEpisodes: [PodcastEpisode], maxEpisodes: Int? = nil) async throws {
        // CRITICAL: Check for user scrolling and abort reconciliation if detected
        let isScrolling = UserDefaults.standard.bool(forKey: "isUserScrolling")
        if isScrolling {
            os_log("🚫 User is scrolling - aborting episode reconciliation to maintain UI responsiveness", log: self.log, type: .info)
            throw CancellationError()
        }
        
        // Ensure all episodes have unique IDs to prevent duplicates from the start
        let uniqueEpisodes = removeDuplicatesFromParsedEpisodes(parsedEpisodes)
        let totalEpisodes = uniqueEpisodes.count
        let duplicatesFound = parsedEpisodes.count - totalEpisodes
        
        
        // Log first few parsed episode titles to check formatting from RSS
        if !uniqueEpisodes.isEmpty {
            for (index, episode) in uniqueEpisodes.prefix(3).enumerated() {
                let titlePreview = String(episode.title.prefix(60))
            }
        }
        
        // Use Task.detached to ensure complete background processing and prevent main thread blocking
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    try await self.performBackgroundReconciliation(feedId: feedId, episodes: uniqueEpisodes, maxEpisodes: maxEpisodes)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Remove duplicates from parsed episodes before Core Data processing
    private func removeDuplicatesFromParsedEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var duplicatesRemoved = 0
        
        for episode in episodes {
            if let existingEpisode = uniqueEpisodes[episode.id] {
                duplicatesRemoved += 1
                let titlePreview1 = String(existingEpisode.title.prefix(50))
                let titlePreview2 = String(episode.title.prefix(50))
                os_log("🗑️ RSS DUPLICATE [%d]: ID %@...", log: self.log, type: .info, duplicatesRemoved, String(episode.id.prefix(8)))
                os_log("   First:  %@", log: self.log, type: .info, titlePreview1)
                os_log("   Second: %@", log: self.log, type: .info, titlePreview2)
                continue
            }
            uniqueEpisodes[episode.id] = episode
        }
        
        if duplicatesRemoved > 0 {
            os_log("✅ Removed %d duplicate episodes from parsed data", log: self.log, type: .info, duplicatesRemoved)
        }
        
        return Array(uniqueEpisodes.values).sorted { $0.publicationDate > $1.publicationDate }
    }
    
    /// Perform the actual reconciliation on a background context with optimized processing
    private func performBackgroundReconciliation(feedId: String, episodes: [PodcastEpisode], maxEpisodes: Int? = nil) async throws {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await withCheckedThrowingContinuation { continuation in
            backgroundContext.perform {
                do {
            // Fetch existing episodes for this feed
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
            
            let existingManaged = try backgroundContext.fetch(fetchRequest)
            var existingById: [String: PodcastModel] = [:]
            
            // Build existing episodes dictionary and detect Core Data duplicates
            var coreDataDuplicates: [PodcastModel] = []
            for episode in existingManaged {
                guard let id = episode.id else { continue }
                
                if existingById[id] != nil {
                    // Found Core Data duplicate - mark for deletion
                    coreDataDuplicates.append(episode)
                    os_log("🗑️ Core Data duplicate detected: %@", log: self.log, type: .debug, id)
                } else {
                    existingById[id] = episode
                }
            }
            
            // Remove Core Data duplicates immediately
            for duplicate in coreDataDuplicates {
                backgroundContext.delete(duplicate)
            }
            
            if !coreDataDuplicates.isEmpty {
                os_log("✅ Removed %d Core Data duplicates", log: self.log, type: .info, coreDataDuplicates.count)
            }
            
            // Process episodes in smaller chunks to avoid blocking
            let chunkSize = 50  // Further reduced chunk size for better performance during playback
            var parsedIds = Set<String>()
            var processed = 0
            var insertedCount = 0
            var updatedCount = 0
            var rejectedCount = 0  // Track rejected episodes with empty titles
            
            for chunk in episodes.chunked(into: chunkSize) {
                // Check for user scrolling before processing each chunk
                let isScrolling = UserDefaults.standard.bool(forKey: "isUserScrolling")
                if isScrolling {
                    os_log("🚫 User scrolling detected during reconciliation - aborting", log: self.log, type: .info)
                    throw CancellationError()
                }
                
                for episode in chunk {
                    // 🚨 COMPREHENSIVE VALIDATION: Reject episodes with ANY empty/invalid required fields
                    let trimmedId = episode.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedTitle = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedDescription = episode.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedAudioUrl = episode.audioUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Validate ALL required fields are present and non-empty
                    if trimmedId.isEmpty || trimmedId.count == 0 {
                        os_log("🚫 VALIDATION REJECTED: Episode has empty ID - skipping insertion", log: self.log, type: .error)
                        rejectedCount += 1
                        continue
                    }
                    
                    if trimmedTitle.isEmpty || trimmedTitle.count == 0 {
                        os_log("🚫 VALIDATION REJECTED: Episode ID %@ has empty title - skipping insertion", log: self.log, type: .error, episode.id)
                        rejectedCount += 1
                        continue
                    }
                    
                    if trimmedDescription.isEmpty || trimmedDescription.count == 0 {
                        os_log("🚫 VALIDATION REJECTED: Episode ID %@ ('%@') has empty description - skipping insertion", log: self.log, type: .error, episode.id, String(trimmedTitle.prefix(30)))
                        rejectedCount += 1
                        continue
                    }
                    
                    if trimmedAudioUrl.isEmpty || trimmedAudioUrl.count == 0 {
                        os_log("🚫 VALIDATION REJECTED: Episode ID %@ ('%@') has empty audio URL - skipping insertion", log: self.log, type: .error, episode.id, String(trimmedTitle.prefix(30)))
                        rejectedCount += 1
                        continue
                    }
                    
                    parsedIds.insert(episode.id)
                    
                    if let existing = existingById[episode.id] {
                        // Update existing episode while preserving download data
                        let preservedLocalPath = existing.localFilePath
                        let preservedFileSize = existing.fileSize
                        existing.update(from: episode)
                        existing.feedId = feedId
                        existing.localFilePath = preservedLocalPath
                        existing.fileSize = preservedFileSize
                        updatedCount += 1
                    } else {
                        // Insert new episode and add to tracking dictionary to prevent duplicates
                        let managed = PodcastModel(context: backgroundContext)
                        managed.update(from: episode)
                        managed.feedId = feedId
                        existingById[episode.id] = managed  // Track new episodes to prevent duplicates
                        insertedCount += 1
                    }
                }
                
                processed += chunk.count
                
                // Save frequently to avoid large transactions and provide progress
                if processed % chunkSize == 0 {
                    try backgroundContext.save()
                }
            }
            
            // Delete episodes that are no longer present in the feed
            let toDelete = existingManaged.filter { model in
                guard let id = model.id else { return false }
                return !parsedIds.contains(id) && !coreDataDuplicates.contains(model)  // Don't double-count duplicates
            }
            var deletedCount = 0
            for model in toDelete { 
                backgroundContext.delete(model)
                deletedCount += 1
            }
            
            // EPISODE LIMIT ENFORCEMENT: Remove excess episodes if limit is set
            if let maxEpisodes = maxEpisodes {
                try self.enforceEpisodeLimit(for: feedId, maxEpisodes: maxEpisodes, in: backgroundContext)
            }
            
            // Final save
            try backgroundContext.save()
            
            // Log rejection summary if any episodes were rejected
            if rejectedCount > 0 {
                os_log("⛔ VALIDATION: Rejected %d episodes with empty/invalid required fields during reconciliation", log: self.log, type: .error, rejectedCount)
            }
            
            os_log("🔄 Reconciled episodes for feed %@: kept %d, inserted %d, updated %d, deleted %d, rejected %d (limit: %@)", log: self.log, type: .info, feedId, parsedIds.count, insertedCount, updatedCount, deletedCount + coreDataDuplicates.count, rejectedCount, maxEpisodes?.description ?? "unlimited")
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Get existing episode IDs for deduplication
    private func getExistingEpisodeIds(for feedId: String, in context: NSManagedObjectContext) throws -> Set<String> {
        let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        request.predicate = NSPredicate(format: "feedId == %@", feedId)
        request.propertiesToFetch = ["id"]
        request.resultType = .managedObjectResultType
        
        let episodes = try context.fetch(request)
        return Set(episodes.compactMap { $0.id })
    }
    
    // MARK: - Artwork Caching
    
    /// Update artwork for a feed
    func updateFeedArtwork(_ feedId: String, imageData: Data) async throws {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", feedId)
            request.fetchLimit = 1
            
            guard let feedModel = try backgroundContext.fetch(request).first else {
                throw CoreDataError.feedNotFound
            }
            
            feedModel.imageData = imageData
            try backgroundContext.save()
            
            os_log("🖼️ Updated artwork for feed: %@", log: self.log, type: .debug, feedId)
        }
    }
    
    // MARK: - Background Sync
    
    /// Sync episode progress and states from EpisodeStateManager
    func syncEpisodeStates(_ episodeStates: [String: EpisodeState]) async throws {
        guard !episodeStates.isEmpty else { return }
        
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            let episodeIds = Array(episodeStates.keys)
            let batches = episodeIds.chunked(into: 100) // Avoid IN clause limits
            
            for batch in batches {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", batch)
                
                let episodes = try backgroundContext.fetch(request)
                
                for episode in episodes {
                    if let id = episode.id, let state = episodeStates[id] {
                        episode.progress = state.progress
                        episode.isPlayed = state.isPlayed
                        episode.isFavorite = state.isFavorite
                        episode.isDownloaded = state.isDownloaded
                    }
                }
            }
            
            try backgroundContext.save()
            os_log("🔄 Synced states for %d episodes", log: self.log, type: .debug, episodeStates.count)
        }
    }
    
    // MARK: - Memory Management
    
    /// Clean up old cached episodes (keep only recent 200 per feed)
    func cleanupOldEpisodes() async throws {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            // Get all feeds
            let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            let feeds = try backgroundContext.fetch(feedRequest)
            
            for feed in feeds {
                guard let feedId = feed.id else { continue }
                
                // Get episodes sorted by publication date
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                let episodes = try backgroundContext.fetch(episodeRequest)
                
                // Keep only the first 200, delete the rest
                if episodes.count > 200 {
                    let episodesToDelete = Array(episodes.dropFirst(200))
                    for episode in episodesToDelete {
                        backgroundContext.delete(episode)
                    }
                    
                    os_log("🧹 Cleaned up %d old episodes for feed %@", 
                           log: self.log, type: .debug, episodesToDelete.count, feedId)
                }
            }
            
            try backgroundContext.save()
        }
    }
    
    // MARK: - Quick Refresh Methods
    
    /// Reconcile only new episodes for quick refresh performance with episode limit enforcement
    func reconcileNewEpisodes(for feedId: String, newEpisodes: [PodcastEpisode], maxEpisodes: Int? = nil) async throws {
        guard !newEpisodes.isEmpty else { return }
        
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            // Check which episodes are actually new
            let episodeIds = newEpisodes.map { $0.id }
            let existingEpisodeIds = try self.getExistingEpisodeIds(episodeIds: episodeIds, in: backgroundContext)
            let trulyNewEpisodes = newEpisodes.filter { !existingEpisodeIds.contains($0.id) }
            
            guard !trulyNewEpisodes.isEmpty else {
                os_log("📝 No new episodes to reconcile for feed %@", log: self.log, type: .debug, feedId)
                return
            }
            
            // Add new episodes efficiently
            var addedCount = 0
            var rejectedCount = 0
            for episode in trulyNewEpisodes {
                // 🚨 COMPREHENSIVE VALIDATION: Reject episodes with ANY empty/invalid required fields
                let trimmedId = episode.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedTitle = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedDescription = episode.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAudioUrl = episode.audioUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Validate ALL required fields are present and non-empty
                if trimmedId.isEmpty || trimmedId.count == 0 {
                    os_log("🚫 QUICK RECONCILE REJECTED: Episode has empty ID - skipping insertion", log: self.log, type: .error)
                    rejectedCount += 1
                    continue
                }
                
                if trimmedTitle.isEmpty || trimmedTitle.count == 0 {
                    os_log("🚫 QUICK RECONCILE REJECTED: Episode ID %@ has empty title - skipping insertion", log: self.log, type: .error, episode.id)
                    rejectedCount += 1
                    continue
                }
                
                if trimmedDescription.isEmpty || trimmedDescription.count == 0 {
                    os_log("🚫 QUICK RECONCILE REJECTED: Episode ID %@ ('%@') has empty description - skipping insertion", log: self.log, type: .error, episode.id, String(trimmedTitle.prefix(30)))
                    rejectedCount += 1
                    continue
                }
                
                if trimmedAudioUrl.isEmpty || trimmedAudioUrl.count == 0 {
                    os_log("🚫 QUICK RECONCILE REJECTED: Episode ID %@ ('%@') has empty audio URL - skipping insertion", log: self.log, type: .error, episode.id, String(trimmedTitle.prefix(30)))
                    rejectedCount += 1
                    continue
                }
                
                let managedEpisode = PodcastModel(context: backgroundContext)
                managedEpisode.update(from: episode)
                managedEpisode.feedId = feedId
                addedCount += 1
            }
            
            // Log rejection summary if any episodes were rejected
            if rejectedCount > 0 {
                os_log("⛔ QUICK RECONCILE: Rejected %d episodes with empty/invalid required fields", log: self.log, type: .error, rejectedCount)
            }
            
            // EPISODE LIMIT ENFORCEMENT: Remove excess episodes if limit is set
            if let maxEpisodes = maxEpisodes {
                try self.enforceEpisodeLimit(for: feedId, maxEpisodes: maxEpisodes, in: backgroundContext)
            }
            
            try backgroundContext.save()
            os_log("⚡ Reconciled %d new episodes for feed %@ (rejected: %d, limit: %@)", log: self.log, type: .info, addedCount, feedId, rejectedCount, maxEpisodes?.description ?? "unlimited")
        }
    }
    
    /// Enforce episode limit for a feed by removing oldest episodes
    private func enforceEpisodeLimit(for feedId: String, maxEpisodes: Int, in context: NSManagedObjectContext) throws {
        // Get all episodes for this feed, sorted by publication date (newest first)
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        let allEpisodes = try context.fetch(fetchRequest)
        
        // If we have more episodes than the limit, delete the oldest ones
        if allEpisodes.count > maxEpisodes {
            let episodesToDelete = Array(allEpisodes.dropFirst(maxEpisodes))
            
            for episode in episodesToDelete {
                context.delete(episode)
            }
            
            os_log("🗑️ EPISODE LIMIT: Removed %d excess episodes for feed %@ (limit: %d)", 
                   log: self.log, type: .info, episodesToDelete.count, feedId, maxEpisodes)
        }
    }
    
    /// Enforce episode limit for a specific feed (can be called independently)
    func enforceEpisodeLimitForFeed(_ feedId: String, maxEpisodes: Int) async throws {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        try await backgroundContext.perform {
            try self.enforceEpisodeLimit(for: feedId, maxEpisodes: maxEpisodes, in: backgroundContext)
            try backgroundContext.save()
        }
    }
    
    /// Get recent episodes for a feed (optimized for quick refresh UI updates)
    func getRecentEpisodesForFeed(_ feedId: String, limit: Int = 100) async -> [PodcastEpisode] {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        return await backgroundContext.perform {
            do {
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                episodeRequest.fetchLimit = limit
                episodeRequest.fetchBatchSize = min(limit, BatchSettings.episodeBatchSize)
                
                let managedEpisodes = try backgroundContext.fetch(episodeRequest)
                let episodes = managedEpisodes.map { $0.toPodcastEpisode() }
                
                // 🛡️ CONTAMINATION PREVENTION: Ensure all episodes belong to the requested feed
                let safeEpisodes = episodes.filter { $0.feedId == feedId }
                if safeEpisodes.count != episodes.count {
                    print("🚨 RECENT EPISODES CONTAMINATION: Found \(episodes.count - safeEpisodes.count) contaminated episodes for feed \(feedId)")
                }
                
                return safeEpisodes
            } catch {
                os_log("❌ Error loading recent episodes for feed %@: %@", 
                       log: self.log, type: .error, feedId, error.localizedDescription)
                return []
            }
        }
    }
    
    /// Clean up contaminated episodes in Core Data
    private func cleanupContaminatedEpisodes(targetFeedId: String, contaminatedEpisodes: [PodcastEpisode]) async {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        await backgroundContext.perform {
            do {
                print("🧹 CLEANUP: Starting Core Data cleanup for \(contaminatedEpisodes.count) contaminated episodes")
                
                for episode in contaminatedEpisodes {
                    // Find the contaminated episode in Core Data
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", episode.id)
                    
                    let results = try backgroundContext.fetch(request)
                    for managedEpisode in results {
                        if managedEpisode.feedId != targetFeedId {
                            print("🧹 CLEANUP: Correcting episode '\(episode.title)' feedId from '\(managedEpisode.feedId ?? "nil")' to '\(episode.feedId)'")
                            managedEpisode.feedId = episode.feedId
                        }
                    }
                }
                
                // Save the corrections
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    print("🧹 CLEANUP: Successfully corrected contaminated episodes in Core Data")
                }
                
            } catch {
                print("❌ CLEANUP ERROR: Failed to clean contaminated episodes: \(error)")
            }
        }
    }
    
    /// Delete corrupted episodes with empty titles from Core Data
    private func deleteCorruptedEpisodes(feedId: String, corruptedEpisodeIds: [String]) async {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        await backgroundContext.perform {
            do {
                os_log("🧽 CORRUPTION CLEANUP: Starting deletion of %d corrupted episodes with empty titles", log: self.log, type: .info, corruptedEpisodeIds.count)
                
                var deletedCount = 0
                for episodeId in corruptedEpisodeIds {
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@ AND feedId == %@", episodeId, feedId)
                    
                    let results = try backgroundContext.fetch(request)
                    for managedEpisode in results {
                        os_log("🧽 CORRUPTION CLEANUP: Deleting corrupted episode with ID %@", log: self.log, type: .info, episodeId)
                        backgroundContext.delete(managedEpisode)
                        deletedCount += 1
                    }
                }
                
                // Save the deletions
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    os_log("✅ CORRUPTION CLEANUP: Successfully deleted %d corrupted episodes from Core Data", log: self.log, type: .info, deletedCount)
                }
                
            } catch {
                os_log("❌ CORRUPTION CLEANUP ERROR: Failed to delete corrupted episodes: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
    
    /// Clean up all corrupted episodes with empty titles from Core Data
    func cleanupCorruptedEpisodes() async {
        let backgroundContext = coreDataStack.newBackgroundContext()
        
        await backgroundContext.perform {
            do {
                // Fetch all episodes with empty titles
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "title == nil OR title == %@", "")
                
                let corruptedEpisodes = try backgroundContext.fetch(fetchRequest)
                
                if !corruptedEpisodes.isEmpty {
                    os_log("🧽 GLOBAL CLEANUP: Found %d corrupted episodes with empty titles", log: self.log, type: .info, corruptedEpisodes.count)
                    
                    var deletedCount = 0
                    for episode in corruptedEpisodes {
                        os_log("🗑️ CLEANUP: Deleting corrupted episode ID %@ from feed %@", log: self.log, type: .debug, episode.id ?? "unknown", episode.feedId ?? "unknown")
                        backgroundContext.delete(episode)
                        deletedCount += 1
                    }
                    
                    // Save deletions
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        os_log("✅ GLOBAL CLEANUP: Successfully deleted %d corrupted episodes", log: self.log, type: .info, deletedCount)
                    }
                } else {
                    os_log("✨ GLOBAL CLEANUP: No corrupted episodes found", log: self.log, type: .info)
                }
                
            } catch {
                os_log("❌ GLOBAL CLEANUP ERROR: Failed to clean corrupted episodes: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
    
}

// MARK: - Error Types

enum CoreDataError: Error {
    case feedNotFound
    case batchInsertFailed
    case contextSaveFailed
}
