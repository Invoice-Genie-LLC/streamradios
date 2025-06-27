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
    
    /// Batch insert episodes for optimal performance
    private func batchInsertEpisodes(from feeds: [PodcastFeed], in context: NSManagedObjectContext) throws {
        let allEpisodes = feeds.flatMap { feed in
            feed.episodes.map { episode in (episode, feed.id) }
        }
        
        guard !allEpisodes.isEmpty else { return }
        
        let batchInsert = NSBatchInsertRequest(entity: PodcastModel.entity()) { (managedObject: NSManagedObject) -> Bool in
            guard let episodeModel = managedObject as? PodcastModel else { return true }
            
            var index = 0
            defer { index += 1 }
            
            if index < allEpisodes.count {
                let (episode, feedId) = allEpisodes[index]
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
                return false
            }
            return true
        }
        
        batchInsert.resultType = NSBatchInsertRequestResultType.objectIDs
        try context.execute(batchInsert)
        
        os_log("📦 Batch inserted %d episodes", log: log, type: .debug, allEpisodes.count)
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
    
    /// Load episodes for a specific feed efficiently
    func loadEpisodesForFeed(feedId: String, in context: NSManagedObjectContext) throws -> [PodcastEpisode] {
        let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        episodeRequest.fetchBatchSize = BatchSettings.episodeBatchSize
        
        let managedEpisodes = try context.fetch(episodeRequest)
        return managedEpisodes.map { $0.toPodcastEpisode() }
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
            
            // Add new episodes
            for episode in newEpisodes {
                let managedEpisode = PodcastModel(context: backgroundContext)
                managedEpisode.update(from: episode)
                managedEpisode.feedId = feedId
            }
            
            try backgroundContext.save()
            os_log("✅ Added %d new episodes to feed %@", log: self.log, type: .info, newEpisodes.count, feedId)
        }
    }
    
    /// Get existing episode IDs for deduplication
    private func getExistingEpisodeIds(for feedId: String, in context: NSManagedObjectContext) throws -> Set<String> {
        let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "PodcastModel")
        request.predicate = NSPredicate(format: "feedId == %@", feedId)
        request.propertiesToFetch = ["id"]
        request.resultType = .dictionaryResultType
        
        let results = try context.fetch(request) as? [[String: Any]] ?? []
        return Set(results.compactMap { $0["id"] as? String })
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
}

// MARK: - Error Types

enum CoreDataError: Error {
    case feedNotFound
    case batchInsertFailed
    case contextSaveFailed
}
