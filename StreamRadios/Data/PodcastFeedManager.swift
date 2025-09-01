import Foundation
import CoreData
import os.log

/// High-performance podcast feed manager with efficient background processing
class PodcastFeedManager {
    private let log = OSLog(subsystem: "StreamRadios", category: "FeedManager")
    private let context = CoreDataStack.shared.context
    
    // MARK: - Artwork Download Optimization
    
    /// Concurrent artwork downloads semaphore (limit to 5 simultaneous downloads)
    private static let artworkSemaphore = DispatchSemaphore(value: 5)
    
    /// Download artwork with timeout to prevent hanging
    private func downloadArtworkWithTimeout(from url: URL, timeout: TimeInterval) async throws -> Data {
        // Wait for semaphore to limit concurrent downloads
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                PodcastFeedManager.artworkSemaphore.wait()
                continuation.resume()
            }
        }
        
        defer {
            // Always release the semaphore
            PodcastFeedManager.artworkSemaphore.signal()
        }
        
        // Create URLRequest with timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad // Use cache when available
        
        // Use async timeout to ensure we don't hang
        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Add download task
            group.addTask {
                let (data, _) = try await URLSession.shared.data(for: request)
                return data
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            
            // Return first completed task and cancel others
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    

    

    

    
    // MARK: - Public Interface
    
    /// Load all saved feeds efficiently
    func loadSavedFeeds() async throws -> [PodcastFeed] {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    fetchRequest.includesPropertyValues = true
                    fetchRequest.returnsObjectsAsFaults = false
                    
                    let managedFeeds = try self.context.fetch(fetchRequest)
                    let feeds = managedFeeds.map { $0.toPodcastFeed() }
                    
                    os_log("📡 Loaded %d feeds from Core Data", log: self.log, type: .info, feeds.count)
                    continuation.resume(returning: feeds)
                } catch {
                    os_log("❌ Failed to load feeds: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Add new feed with background processing and episode parsing
    func addFeed(from url: URL, customTitle: String? = nil, forceRefresh: Bool = false, enableProgressReporting: Bool = true) async throws -> PodcastFeed {
        os_log("🆕 Adding new feed from: %@", log: log, type: .info, url.absoluteString)
        
        // Parse RSS feed in background with robust error handling and retry mechanism - use detached task to prevent main thread blocking
        let (parsedFeed, episodes) = try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: customTitle ?? "New Feed")
                    // PERFORMANCE FIX: Only use progress callback for user-initiated operations
                    let progressCallback: ((Double, String) -> Void)? = enableProgressReporting ? { progress, message in
                        Task { @MainActor in
                            DataSyncManager.shared.updateFeedParsingProgress(progress, message: message)
                        }
                    } : nil
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: progressCallback)
                    let result = try await parser.parseComplete()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        
        // Report episode parsing progress only for user-initiated operations
        if enableProgressReporting {
            Task { @MainActor in
                DataSyncManager.shared.updateFeedParsingProgress(0.8, message: "Saving \(episodes.count) episodes to database...")
            }
        }
        
        // Use custom title if provided, otherwise use RSS feed title
        var feed = parsedFeed
        if let customTitle = customTitle, !customTitle.isEmpty {
            feed.title = customTitle
            os_log("🏷️ Using custom title: %@ (RSS title was: %@)", log: log, type: .info, customTitle, parsedFeed.title)
        }
        
        // Download artwork with timeout and optimization
        var feedWithArtwork = feed
        if let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty,
           let artworkUrl = URL(string: artworkUrlString) {
            os_log("🖼️ Downloading artwork for feed: %@", log: log, type: .info, feed.title)
            
            do {
                // Use optimized download with 5 second timeout
                let artworkData = try await downloadArtworkWithTimeout(from: artworkUrl, timeout: 5.0)
                feedWithArtwork.imageData = artworkData
                os_log("✅ Downloaded artwork (%d bytes) for feed: %@", log: log, type: .info, artworkData.count, feed.title)
                
                // Report artwork download completion to DataSyncManager
                await MainActor.run {
                    DataSyncManager.shared.reportArtworkDownloadCompleted(feedTitle: feed.title)
                }
            } catch {
                os_log("⚠️ Failed to download artwork for feed: %@ - %@", log: log, type: .error, feed.title, error.localizedDescription)
                
                // Report artwork download failure to DataSyncManager
                await MainActor.run {
                    DataSyncManager.shared.reportArtworkDownloadFailed(feedTitle: feed.title, error: error)
                }
            }
        } else {
            // No artwork to download, still report completion
            await MainActor.run {
                DataSyncManager.shared.reportArtworkDownloadCompleted(feedTitle: feed.title)
            }
        }
        
        return try await saveFeedWithEpisodes(feed: feedWithArtwork, episodes: episodes, forceRefresh: forceRefresh)
    }
    
    /// Refresh feed and parse new episodes
    func refreshFeed(_ feedId: String) async throws -> (PodcastFeed, [PodcastEpisode]) {
        // Get existing feed
        guard let existingFeed = try await getExistingFeed(feedId: feedId) else {
            throw FeedError.feedNotFound
        }
        
        os_log("🔄 Refreshing feed: %@", log: log, type: .info, existingFeed.title)
        
        // Parse RSS feed with robust error handling and retry mechanism - use detached task to prevent main thread blocking
        // PERFORMANCE FIX: No progress reporting for auto-refresh to prevent main thread blocking
        let (updatedFeed, newEpisodes) = try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let feedData = try await self.fetchRSSDataWithRetry(url: URL(string: existingFeed.url)!, feedTitle: existingFeed.title)
                    // Use parser without progress callback to prevent main thread blocking during auto-refresh
                    let parser = RSSFeedParser(data: feedData, feedUrl: existingFeed.url, progressCallback: nil)
                    let result = try await parser.parseComplete()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        
        // Download artwork if URL changed or if we don't have artwork yet (original implementation)
        var feedWithArtwork = updatedFeed
        if let artworkUrlString = updatedFeed.artworkUrl, !artworkUrlString.isEmpty,
           let artworkUrl = URL(string: artworkUrlString),
           (existingFeed.artworkUrl != artworkUrlString || existingFeed.imageData == nil) {
            os_log("🖼️ Downloading updated artwork for feed: %@", log: log, type: .info, updatedFeed.title)
            
            do {
                // Use optimized download with 5 second timeout
                let artworkData = try await downloadArtworkWithTimeout(from: artworkUrl, timeout: 5.0)
                feedWithArtwork.imageData = artworkData
                os_log("✅ Downloaded updated artwork (%d bytes) for feed: %@", log: log, type: .info, artworkData.count, updatedFeed.title)
                
                // Report artwork download completion to DataSyncManager
                await MainActor.run {
                    DataSyncManager.shared.reportArtworkDownloadCompleted(feedTitle: updatedFeed.title)
                }
            } catch {
                os_log("⚠️ Failed to download updated artwork for feed: %@ - %@", log: log, type: .error, updatedFeed.title, error.localizedDescription)
                // Keep existing artwork if download fails
                feedWithArtwork.imageData = existingFeed.imageData
                
                // Report artwork download failure to DataSyncManager
                await MainActor.run {
                    DataSyncManager.shared.reportArtworkDownloadFailed(feedTitle: updatedFeed.title, error: error)
                }
            }
        } else {
            // Keep existing artwork if URL hasn't changed
            feedWithArtwork.imageData = existingFeed.imageData
            
            // Still report completion even if no download was needed
            await MainActor.run {
                DataSyncManager.shared.reportArtworkDownloadCompleted(feedTitle: updatedFeed.title)
            }
        }
        
        // Update feed metadata first
        let result = try await updateFeedWithNewEpisodes(
            existingFeed: existingFeed,
            updatedFeed: feedWithArtwork,
            newEpisodes: newEpisodes
        )
        
        // Reconcile Core Data to exactly match the latest parsed feed content to prevent accumulation
        // Use the parsed episodes from the RSS (complete set) as the source of truth
        try await PodcastCoreDataManager.shared.reconcileEpisodes(for: existingFeed.id, parsedEpisodes: newEpisodes)
        
        return result
    }
    
    // MARK: - Private Methods
    
    private func getExistingFeed(feedId: String) async throws -> PodcastFeed? {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", feedId)
                    fetchRequest.fetchLimit = 1
                    
                    let managedFeeds = try self.context.fetch(fetchRequest)
                    let feed = managedFeeds.first?.toPodcastFeed()
                    
                    continuation.resume(returning: feed)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func saveFeedWithEpisodes(feed: PodcastFeed, episodes: [PodcastEpisode], forceRefresh: Bool = false) async throws -> PodcastFeed {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Check if feed already exists by URL (primary check) or ID (secondary check)
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "url == %@ OR id == %@", feed.url, feed.id)
                    fetchRequest.fetchLimit = 1
                    
                    if let existingFeed = try backgroundContext.fetch(fetchRequest).first {
                        // If forceRefresh is true (e.g., during fresh install), skip duplicate check and parse episodes
                        if forceRefresh {
                            os_log("🔄 Feed exists but forceRefresh=true, will parse episodes: %@", log: self.log, type: .info, feed.title)
                        } else {
                            os_log("⚠️ Feed already exists, loading episodes for existing feed: %@", log: self.log, type: .info, feed.title)
                            
                            // Load episodes for the existing feed
                            let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                            episodeRequest.predicate = NSPredicate(format: "feedId == %@", existingFeed.id ?? "")
                            episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                            
                            let existingEpisodes = try backgroundContext.fetch(episodeRequest)
                            let episodes = existingEpisodes.compactMap { $0.toPodcastEpisode() }
                            
                            var feedWithEpisodes = existingFeed.toPodcastFeed()
                            feedWithEpisodes.episodes = episodes
                            
                            os_log("✅ Loaded existing feed with %d episodes: %@", log: self.log, type: .info, episodes.count, feedWithEpisodes.title)
                            continuation.resume(returning: feedWithEpisodes)
                            return
                        }
                    }
                    
                    // Double-check with a more comprehensive search to prevent any duplicates
                    let titleCheckRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    titleCheckRequest.predicate = NSPredicate(format: "title == %@ AND url == %@", feed.title, feed.url)
                    titleCheckRequest.fetchLimit = 1
                    
                    if let duplicateFeed = try backgroundContext.fetch(titleCheckRequest).first {
                        // If forceRefresh is true (e.g., during fresh install), skip duplicate check and parse episodes
                        if forceRefresh {
                            os_log("🔄 Duplicate feed detected but forceRefresh=true, will parse episodes: %@", log: self.log, type: .info, feed.title)
                        } else {
                            os_log("⚠️ Duplicate feed detected by title+URL, loading episodes for existing feed: %@", log: self.log, type: .info, feed.title)
                            
                            // Load episodes for the existing feed
                            let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                            episodeRequest.predicate = NSPredicate(format: "feedId == %@", duplicateFeed.id ?? "")
                            episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                            
                            let existingEpisodes = try backgroundContext.fetch(episodeRequest)
                            let episodes = existingEpisodes.compactMap { $0.toPodcastEpisode() }
                            
                            var feedWithEpisodes = duplicateFeed.toPodcastFeed()
                            feedWithEpisodes.episodes = episodes
                            
                            os_log("✅ Loaded duplicate feed with %d episodes: %@", log: self.log, type: .info, episodes.count, feedWithEpisodes.title)
                            continuation.resume(returning: feedWithEpisodes)
                            return
                        }
                    }
                    
                    // Create new feed
                    let managedFeed = FeedModel(context: backgroundContext)
                    managedFeed.update(from: feed)
                    
                    // Save episodes using optimized batch insert for maximum performance
                    try self.saveEpisodesOptimized(episodes, for: managedFeed, in: backgroundContext)
                    
                    try backgroundContext.save()
                    
                    // Report completion of episode saving
                    Task { @MainActor in
                        DataSyncManager.shared.updateFeedParsingProgress(0.95, message: "✅ Saved \(episodes.count) episodes for \(feed.title)")
                    }
                    
                    // CRITICAL: Ensure main context sees the changes immediately for fresh install
                    DispatchQueue.main.async {
                        do {
                            try CoreDataStack.shared.context.save()
                            print("✅ Synchronized main context after feed save for: \(feed.title)")
                            
                            // Check if this is a fresh install before posting notification
                            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
                            if isFreshInstall {
                                print("🚀 IMMEDIATE FEED SAVE: Triggering UI refresh for fresh install")
                                NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                                print("📢 IMMEDIATE FEED SAVE: Posted notification for feed: \(feed.title)")
                            }
                            
                        } catch {
                            print("⚠️ Failed to sync main context: \(error)")
                        }
                    }
                    
                    // Create feed with episodes for return
                    var feedWithEpisodes = feed
                    feedWithEpisodes.episodes = episodes
                    
                    // Report final completion - this will trigger banner dismissal
                    Task { @MainActor in
                        DataSyncManager.shared.updateFeedParsingProgress(1.0, message: "✅ Completed processing \(feed.title)")
                        // Brief delay then reset to dismiss the banner
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                        }
                    }
                    
                    os_log("✅ Saved new feed with %d episodes: %@", log: self.log, type: .info, episodes.count, feed.title)
                    continuation.resume(returning: feedWithEpisodes)
                    
                } catch {
                    os_log("❌ Failed to save feed: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func updateFeedWithNewEpisodes(
        existingFeed: PodcastFeed,
        updatedFeed: PodcastFeed,
        newEpisodes: [PodcastEpisode]
    ) async throws -> (PodcastFeed, [PodcastEpisode]) {
        
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Get managed feed
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", existingFeed.id)
                    
                    guard let managedFeed = try backgroundContext.fetch(fetchRequest).first else {
                        throw FeedError.feedNotFound
                    }
                    
                    // Update feed metadata
                    managedFeed.title = updatedFeed.title
                    managedFeed.descriptionText = updatedFeed.descriptionText
                    managedFeed.artworkUrl = updatedFeed.artworkUrl
                    
                    // Filter truly new episodes (not already in database)
                    let existingEpisodeIds = try self.getExistingEpisodeIds(for: existingFeed.id, in: backgroundContext)
                    let actuallyNewEpisodes = newEpisodes.filter { !existingEpisodeIds.contains($0.id) }
                    let parsedExistingEpisodes = newEpisodes.filter { existingEpisodeIds.contains($0.id) }
                    
                    // Save new episodes
                    try self.saveEpisodesInBatches(actuallyNewEpisodes, for: managedFeed, in: backgroundContext)
                    
                    // Update existing episodes with newly parsed metadata (chapters/notes)
                    if !parsedExistingEpisodes.isEmpty {
                        try self.updateExistingEpisodes(parsedExistingEpisodes, feedId: existingFeed.id, in: backgroundContext)
                    }
                    
                    // Clean up any duplicates that might have been created during the refresh
                    try self.cleanupDuplicateEpisodes(in: backgroundContext)
                    
                    try backgroundContext.save()
                    
                    // CRITICAL: Ensure main context sees the changes immediately
                    DispatchQueue.main.async {
                        do {
                            try CoreDataStack.shared.context.save()
                            print("✅ Synchronized main context after feed update for: \(updatedFeed.title)")
                        } catch {
                            print("⚠️ Failed to sync main context: \(error)")
                        }
                    }
                    
                    os_log("🔄 Updated feed with %d new episodes and %d updated episodes", log: self.log, type: .info, actuallyNewEpisodes.count, parsedExistingEpisodes.count)
                    continuation.resume(returning: (updatedFeed, actuallyNewEpisodes))
                    
                } catch {
                    os_log("❌ Failed to update feed: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func getExistingEpisodeIds(for feedId: String, in context: NSManagedObjectContext) throws -> Set<String> {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        fetchRequest.propertiesToFetch = ["id"]
        fetchRequest.resultType = .managedObjectResultType
        
        let episodes = try context.fetch(fetchRequest)
        return Set(episodes.compactMap { $0.id })
    }
    
    /// Optimized episode saving using batch operations for maximum performance
    private func saveEpisodesOptimized(
        _ episodes: [PodcastEpisode],
        for feed: FeedModel,
        in context: NSManagedObjectContext
    ) throws {
        guard !episodes.isEmpty else { return }
        
        let feedId = feed.id ?? ""
        
        // Get all existing episode IDs in one batch query (much faster than individual queries)
        let episodeIds = episodes.map { $0.id }
        let existingEpisodeIds = try getExistingEpisodeIdsBatch(episodeIds, in: context)
        
        // Separate new and existing episodes
        let newEpisodes = episodes.filter { !existingEpisodeIds.contains($0.id) }
        let existingEpisodes = episodes.filter { existingEpisodeIds.contains($0.id) }
        
        // Batch insert new episodes using NSBatchInsertRequest (fastest method)
        if !newEpisodes.isEmpty {
            try batchInsertNewEpisodes(newEpisodes, feedId: feedId, in: context)
        }
        
        // Update existing episodes to preserve download data (only if there are any)
        if !existingEpisodes.isEmpty {
            try updateExistingEpisodes(existingEpisodes, feedId: feedId, in: context)
        }
        
        os_log("📦 Episode save completed: %d new, %d updated", log: log, type: .info, newEpisodes.count, existingEpisodes.count)
    }
    
    /// Batch insert new episodes using NSBatchInsertRequest for maximum performance
    private func batchInsertNewEpisodes(
        _ episodes: [PodcastEpisode],
        feedId: String,
        in context: NSManagedObjectContext
    ) throws {
        guard !episodes.isEmpty else { return }
        
        // CRITICAL FIX: Double-check for duplicates before batch insert
        // This prevents the duplicate issue that causes crashes
        let episodeIds = episodes.map { $0.id }
        let existingIds = try getExistingEpisodeIdsBatch(episodeIds, in: context)
        let trulyNewEpisodes = episodes.filter { !existingIds.contains($0.id) }
        
        guard !trulyNewEpisodes.isEmpty else {
            os_log("⚡ No new episodes to batch insert - all %d episodes already exist", log: log, type: .debug, episodes.count)
            return
        }
        
        var insertIndex = 0
        
        let batchInsert = NSBatchInsertRequest(entity: PodcastModel.entity()) { (managedObject: NSManagedObject) -> Bool in
            guard let episodeModel = managedObject as? PodcastModel else { return true }
            
            if insertIndex < trulyNewEpisodes.count {
                let episode = trulyNewEpisodes[insertIndex]
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
                // Persist chapters and notes on first insert so they survive app relaunch
                if let chapters = episode.chapters, let data = try? JSONEncoder().encode(chapters) {
                    episodeModel.chaptersData = data
                }
                if let notes = episode.notes, let data = try? JSONEncoder().encode(notes) {
                    episodeModel.notesData = data
                }
                
                insertIndex += 1
                return false
            }
            return true
        }
        
        batchInsert.resultType = .objectIDs
        try context.execute(batchInsert)
        
        os_log("⚡ Batch inserted %d new episodes (filtered from %d)", log: log, type: .info, trulyNewEpisodes.count, episodes.count)
    }
    
    /// Update existing episodes while preserving download data
    private func updateExistingEpisodes(
        _ episodes: [PodcastEpisode],
        feedId: String,
        in context: NSManagedObjectContext
    ) throws {
        // Fetch existing episodes in one batch query
        let episodeIds = episodes.map { $0.id }
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", episodeIds)
        
        let existingEpisodes = try context.fetch(fetchRequest)
        
        // CRITICAL FIX: Handle duplicate episode IDs gracefully
        // Use the first occurrence of each ID and log duplicates
        var existingEpisodesById: [String: PodcastModel] = [:]
        var duplicateCount = 0
        
        for episode in existingEpisodes {
            guard let id = episode.id else { continue }
            
            if existingEpisodesById[id] != nil {
                // Found duplicate - log it and skip
                duplicateCount += 1
                os_log("⚠️ Duplicate episode ID found in Core Data: %@", log: log, type: .error, id)
                continue
            }
            
            existingEpisodesById[id] = episode
        }
        
        if duplicateCount > 0 {
            os_log("⚠️ Found %d duplicate episodes in Core Data - using first occurrence only", log: log, type: .error, duplicateCount)
        }
        
        // Update episodes while preserving download data
        for episode in episodes {
            guard let managedEpisode = existingEpisodesById[episode.id] else { continue }
            
            // Preserve download data
            let preservedLocalFilePath = managedEpisode.localFilePath
            let preservedFileSize = managedEpisode.fileSize
            
            // Update episode data
            var episodeWithFeedId = episode
            episodeWithFeedId.feedId = feedId
            managedEpisode.update(from: episodeWithFeedId)
            
            // Restore preserved download data
            managedEpisode.localFilePath = preservedLocalFilePath
            managedEpisode.fileSize = preservedFileSize
        }
        
        os_log("🔄 Updated %d existing episodes", log: log, type: .info, episodes.count)
    }
    
    /// Clean up duplicate episodes in Core Data (removes all but the most recent for each ID)
    private func cleanupDuplicateEpisodes(in context: NSManagedObjectContext) throws {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        let allEpisodes = try context.fetch(fetchRequest)
        var seenIds = Set<String>()
        var duplicatesToDelete: [PodcastModel] = []
        
        for episode in allEpisodes {
            guard let id = episode.id else { continue }
            
            if seenIds.contains(id) {
                // This is a duplicate - mark for deletion
                duplicatesToDelete.append(episode)
                os_log("🗑️ Marking duplicate episode for deletion: %@", log: log, type: .info, id)
            } else {
                seenIds.insert(id)
            }
        }
        
        // Delete duplicates
        for duplicate in duplicatesToDelete {
            context.delete(duplicate)
        }
        
        if !duplicatesToDelete.isEmpty {
            try context.save()
            os_log("✅ Cleaned up %d duplicate episodes", log: log, type: .info, duplicatesToDelete.count)
        }
    }

    /// Get existing episode IDs in a single batch query
    private func getExistingEpisodeIdsBatch(
        _ episodeIds: [String],
        in context: NSManagedObjectContext
    ) throws -> Set<String> {
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", episodeIds)
        fetchRequest.propertiesToFetch = ["id"]
        fetchRequest.resultType = .managedObjectResultType
        
        let episodes = try context.fetch(fetchRequest)
        return Set(episodes.compactMap { $0.id })
    }
    
    private func saveEpisodesInBatches(
        _ episodes: [PodcastEpisode],
        for feed: FeedModel,
        in context: NSManagedObjectContext,
        batchSize: Int = 100
    ) throws {
        let totalBatches = Int(ceil(Double(episodes.count) / Double(batchSize)))
        
        for batchIndex in 0..<totalBatches {
            let start = batchIndex * batchSize
            let end = min(start + batchSize, episodes.count)
            let batch = Array(episodes[start..<end])
            
            autoreleasepool {
                for episode in batch {
                    // Check if episode already exists to preserve download data
                    let existingRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                    existingRequest.fetchLimit = 1
                    
                    let managedEpisode: PodcastModel
                    if let existingEpisode = try? context.fetch(existingRequest).first {
                        // Update existing episode but preserve download data
                        managedEpisode = existingEpisode
                        let preservedLocalFilePath = existingEpisode.localFilePath
                        let preservedFileSize = existingEpisode.fileSize
                        
                        var episodeWithFeedId = episode
                        episodeWithFeedId.feedId = feed.id ?? ""
                        managedEpisode.update(from: episodeWithFeedId)
                        
                        // Restore preserved download data
                        managedEpisode.localFilePath = preservedLocalFilePath
                        managedEpisode.fileSize = preservedFileSize
                        
                        if let localPath = preservedLocalFilePath, !localPath.isEmpty {
                            print("📁 DEBUG: Preserved localFilePath for existing episode: \(episode.title) -> \(localPath)")
                        }
                    } else {
                        // Create new episode
                        managedEpisode = PodcastModel(context: context)
                        var episodeWithFeedId = episode
                        episodeWithFeedId.feedId = feed.id ?? ""
                        managedEpisode.update(from: episodeWithFeedId)
                        managedEpisode.feed = feed
                    }
                }
            }
        }
    }
}

// MARK: - Feed Errors

enum FeedError: Error, LocalizedError {
    case invalidURL
    case feedNotFound
    case parsingFailed
    case networkError
    case feedDataCorrupted
    case retryLimitExceeded
    case missingRequiredData
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid feed URL"
        case .feedNotFound:
            return "Feed not found"
        case .parsingFailed:
            return "Failed to parse feed"
        case .networkError:
            return "Network error"
        case .feedDataCorrupted:
            return "Feed data is corrupted or truncated"
        case .retryLimitExceeded:
            return "Maximum retry attempts exceeded"
        case .missingRequiredData:
            return "Feed is missing required data (title, episodes, etc.)"
        }
    }
}

// MARK: - Robust RSS Data Fetching

extension PodcastFeedManager {
    /// Fetch RSS data with retry mechanism and robust error handling for decode issues
    private func fetchRSSDataWithRetry(url: URL, feedTitle: String, maxRetries: Int = 3) async throws -> Data {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                
                // CRITICAL: Yield control to allow UI updates
                await Task.yield()
                
                // Configure URLSession with longer timeout for large feeds
                var request = URLRequest(url: url)
                request.timeoutInterval = 30.0 // Increased timeout for large episodes
                request.setValue("StreamRadios/1.0", forHTTPHeaderField: "User-Agent")
                request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
                request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
                
                // CRITICAL: Another yield point before network operation
                await Task.yield()
                
                // Use URLSession with dedicated configuration to prevent main thread blocking
                let session = URLSession(configuration: .default)
                let (data, response) = try await session.data(for: request)
                
                // CRITICAL: Yield after network operation completes
                await Task.yield()
                
                // Validate HTTP response
                if let httpResponse = response as? HTTPURLResponse {
                    os_log("📡 HTTP Response: %d for feed: %@", log: log, type: .info, httpResponse.statusCode, feedTitle)
                    
                    // Check for server errors
                    guard 200...299 ~= httpResponse.statusCode else {
                        throw FeedError.networkError
                    }
                    
                    // Log content type for debugging
                    if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        os_log("📄 Content-Type: %@ for feed: %@", log: log, type: .info, contentType, feedTitle)
                    }
                }
                
                // CRITICAL: Yield before data validation
                await Task.yield()
                
                // Validate data size and content
                guard !data.isEmpty else {
                    os_log("❌ Empty data received for feed: %@", log: log, type: .error, feedTitle)
                    throw FeedError.feedDataCorrupted
                }
                
                // Check for minimum RSS/XML content
                guard data.count > 100 else { // Minimum viable RSS feed should be larger
                    os_log("❌ Data too small (%d bytes) for feed: %@", log: log, type: .error, data.count, feedTitle)
                    throw FeedError.feedDataCorrupted
                }
                
                // CRITICAL: Yield before XML validation
                await Task.yield()
                
                // Validate XML structure - check if data starts with valid XML
                let dataPrefix = String(data: data.prefix(200), encoding: .utf8) ?? ""
                let hasXMLDeclaration = dataPrefix.contains("<?xml") || dataPrefix.contains("<rss") || dataPrefix.contains("<feed")
                
                guard hasXMLDeclaration else {
                    os_log("❌ Invalid XML structure for feed: %@ - Data starts with: %@", log: log, type: .error, feedTitle, String(dataPrefix.prefix(100)))
                    throw FeedError.feedDataCorrupted
                }
                
                // Check for common encoding issues (BOM, invalid characters)
                if dataPrefix.hasPrefix("\u{FEFF}") {
                    os_log("🔧 Removing BOM from feed data: %@", log: log, type: .info, feedTitle)
                    return Data(data.dropFirst(3)) // Remove UTF-8 BOM
                }
                
                return data
                
            } catch {
                lastError = error
                let isDecodeError = (error as NSError).code == -1015
                
                os_log("❌ Fetch attempt %d/%d failed for feed: %@ - Error: %@", log: log, type: .error, attempt, maxRetries, feedTitle, error.localizedDescription)
                
                // CRITICAL: Yield before retry delay to allow UI updates
                await Task.yield()
                
                // For decode errors, wait longer between retries
                if isDecodeError && attempt < maxRetries {
                    let delay = Double(attempt) * 2.0 // Progressive delay: 2s, 4s, 6s
                    os_log("⏳ Waiting %.1f seconds before retry due to decode error...", log: log, type: .info, delay)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else if attempt < maxRetries {
                    // Standard retry delay for other errors
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
                
                // CRITICAL: Yield after retry delay before next attempt
                await Task.yield()
            }
        }
        
        // All retries failed
        os_log("💥 All %d fetch attempts failed for feed: %@ - Final error: %@", log: log, type: .error, maxRetries, feedTitle, lastError?.localizedDescription ?? "Unknown error")
        
        if let lastError = lastError, (lastError as NSError).code == -1015 {
            throw FeedError.feedDataCorrupted
        } else {
            throw FeedError.retryLimitExceeded
        }
    }
}

// MARK: - RSS Parser

class RSSFeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let feedUrl: String
    private let totalDataSize: Int
    
    // Feed-level properties
    private var feedTitle: String?
    private var feedDescription: String?
    private var feedArtworkUrl: String?
    
    // Episode parsing
    private var episodes: [PodcastEpisode] = []
    private var currentElement = ""
    private var currentEpisode: EpisodeBuilder?
    private var isParsingItem = false
    private var characterBuffer = ""
    
    // Progress tracking
    private var bytesProcessed: Int = 0
    private var progressCallback: ((Double, String) -> Void)?
    private var lastReportedProgress: Double?
    
    init(data: Data, feedUrl: String, progressCallback: ((Double, String) -> Void)? = nil) {
        self.parser = XMLParser(data: data)
        self.feedUrl = feedUrl
        self.totalDataSize = data.count
        self.progressCallback = progressCallback
        super.init()
        self.parser.delegate = self
    }
    
    func parseComplete() async throws -> (PodcastFeed, [PodcastEpisode]) {
        return try await withCheckedThrowingContinuation { continuation in
            // Move XML parsing to background queue to prevent main thread blocking
            DispatchQueue.global(qos: .userInitiated).async {
                self.progressCallback?(0.1, "Starting RSS parsing...")
                
                // CRITICAL: Process in smaller chunks to allow cooperative multitasking
                Task {
                    await Task.yield() // Allow UI updates before starting parsing
                }
                
                // Enhanced error handling for RSS parsing
                guard self.parser.parse() else {
                    if let parserError = self.parser.parserError {
                        os_log("❌ RSS Parser failed with error: %@", log: OSLog.default, type: .error, parserError.localizedDescription)
                        // Try to provide more specific error information
                        if (parserError as NSError).code == 4 {
                            continuation.resume(throwing: FeedError.feedDataCorrupted)
                        } else {
                            continuation.resume(throwing: FeedError.parsingFailed)
                        }
                    } else {
                        os_log("❌ RSS Parser failed with unknown error", log: OSLog.default, type: .error)
                        continuation.resume(throwing: FeedError.parsingFailed)
                    }
                    return
                }
                
                do {
                    let result = try self.buildResult()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func buildResult() throws -> (PodcastFeed, [PodcastEpisode]) {
        
        // Validate we have essential feed data
        guard let title = feedTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            os_log("❌ RSS Feed missing title or title is empty", log: OSLog.default, type: .error)
            throw FeedError.missingRequiredData
        }
        
        // CRITICAL: Use deterministic feedId that matches episode feedId generation
        let feedId = generateFeedIdFromUrl(feedUrl)
        
        let feed = PodcastFeed(
            id: feedId,
            title: title,
            url: feedUrl,
            artworkUrl: feedArtworkUrl,
            description: feedDescription ?? ""
        )
        
        // Report completion
        progressCallback?(1.0, "Parsing complete - \(episodes.count) episodes found")
        
        return (feed, episodes)
    }
    
    /// Generate deterministic feedId from feedUrl to ensure consistency with episodes
    private func generateFeedIdFromUrl(_ feedUrl: String) -> String {
        // Create a deterministic hash of the feed URL for consistent feed IDs
        let content = feedUrl.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = abs(content.hashValue)
        return "feed_\(hash)"
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        characterBuffer = ""
        
        switch elementName {
        case "item":
            isParsingItem = true
            currentEpisode = EpisodeBuilder(feedUrl: feedUrl)
        case "enclosure":
            if isParsingItem, let url = attributeDict["url"] {
                currentEpisode?.audioUrl = url
                if let lengthString = attributeDict["length"], let length = Int64(lengthString) {
                    currentEpisode?.fileSize = length
                }
            }
        case "podcast:chapters":
            // Podcasting 2.0 external chapters reference
            if isParsingItem, let url = attributeDict["url"], !url.isEmpty {
                currentEpisode?.chaptersJSONURL = url
            }
        case "psc:chapters":
            // Some feeds use "psc" namespace
            if isParsingItem, let url = attributeDict["url"], !url.isEmpty {
                currentEpisode?.chaptersJSONURL = url
            }
        case "itunes:image":
            if !isParsingItem, let href = attributeDict["href"] {
                feedArtworkUrl = href
            }
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterBuffer += string
        
        // Update progress tracking
        bytesProcessed += string.utf8.count
        updateProgress()
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedContent = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { characterBuffer = "" }
        
        if !isParsingItem {
            // Feed-level elements
            switch elementName {
            case "title":
                if feedTitle == nil {
                    feedTitle = trimmedContent
                }
            case "description":
                if feedDescription == nil {
                    feedDescription = trimmedContent
                }
            default:
                break
            }
        } else {
            // Episode-level elements
            switch elementName {
            case "title":
                currentEpisode?.title = trimmedContent
            case "description":
                currentEpisode?.description = trimmedContent
            case "content:encoded":
                currentEpisode?.contentEncoded = trimmedContent
            case "itunes:summary":
                currentEpisode?.itunesSummary = trimmedContent
            case "pubDate":
                currentEpisode?.pubDate = trimmedContent
            case "guid":
                currentEpisode?.guid = trimmedContent
            case "itunes:duration":
                currentEpisode?.duration = trimmedContent
            case "item":
                if let episode = currentEpisode?.build() {
                    episodes.append(episode)
                    // Report episode parsing progress with more granular updates
                    let baseProgress = Double(bytesProcessed) / Double(totalDataSize)
                    let episodeProgress = min(0.9, baseProgress)
                    
                    // Update progress every 50 episodes or every 10% to avoid UI spam
                    if episodes.count % 50 == 0 || episodeProgress - (lastReportedProgress ?? 0) >= 0.1 {
                        progressCallback?(episodeProgress, "Parsed \(episodes.count) episodes...")
                        lastReportedProgress = episodeProgress
                    }
                }
                isParsingItem = false
                currentEpisode = nil
            default:
                break
            }
        }
    }
    
    // MARK: - Progress Tracking
    
    private func updateProgress() {
        guard let progressCallback = progressCallback else { return }
        
        let bytesProgress = min(0.8, Double(bytesProcessed) / Double(totalDataSize))
        let episodeCount = episodes.count
        
        if episodeCount == 0 {
            progressCallback(bytesProgress, "Parsing feed structure...")
        } else {
            progressCallback(bytesProgress, "Parsing episodes (\(episodeCount) found)...")
        }
    }
}

// MARK: - Episode Builder

private class EpisodeBuilder {
    var title: String?
    var description: String?
    var audioUrl: String?
    var pubDate: String?
    var guid: String?
    var duration: String?
    var fileSize: Int64?
    var contentEncoded: String? // For richer show notes
    var itunesSummary: String? // iTunes-specific summary
    var chapters: [PodcastChapter] = []
    var chaptersJSONURL: String?
    let feedUrl: String
    
    init(feedUrl: String) {
        self.feedUrl = feedUrl
    }
    
    func build() -> PodcastEpisode? {
        guard let title = title,
              let description = description,
              let audioUrl = audioUrl,
              let pubDateString = pubDate else {
            return nil
        }
        
        let publicationDate = DateFormatter.rfc2822.date(from: pubDateString) ?? Date()
        let episodeDuration = parseDuration(duration ?? "0")
        
        // CRITICAL FIX: Generate deterministic IDs to prevent duplicates
        let episodeId: String
        if let guid = guid, !guid.isEmpty {
            // Use existing GUID if available
            episodeId = guid
        } else {
            // Generate deterministic ID based on content to prevent duplicates
            // This ensures the same episode always gets the same ID across RSS parses
            episodeId = PodcastEpisode.generateDeterministicID(
                title: title,
                audioUrl: audioUrl,
                publicationDate: publicationDate,
                feedUrl: feedUrl // Use feedUrl for uniqueness across different feeds
            )
        }
        
        // Create show notes from available content and try to extract chapters
        let (showNotes, extractedChapters) = createShowNotesAndChapters(
            description: description,
            contentEncoded: contentEncoded,
            itunesSummary: itunesSummary
        )
        
        // Use extracted chapters if no explicit chapters were found
        if chapters.isEmpty && !extractedChapters.isEmpty {
            chapters = extractedChapters
        }
        
        // Try Podcasting 2.0 external JSON if still empty
        if chapters.isEmpty, let jsonURL = chaptersJSONURL, !jsonURL.isEmpty {
            if let external = fetchChaptersFromJSON(urlString: jsonURL), !external.isEmpty {
                chapters = external
            }
        }
        

        // CRITICAL: Generate feedId from feedUrl for proper episode-to-feed mapping
        let feedId = generateFeedIdFromUrl(feedUrl)
        
        return PodcastEpisode(
            id: episodeId,
            title: title,
            descriptionText: description,
            audioUrl: audioUrl,
            publicationDate: publicationDate,
            duration: episodeDuration,
            state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
            feedId: feedId, // Properly assigned feedId for CloudKit sync
            fileSize: fileSize,
            chapters: chapters.isEmpty ? nil : chapters,
            notes: showNotes
        )
    }
    
    /// Generate deterministic feedId from feedUrl to ensure consistency
    private func generateFeedIdFromUrl(_ feedUrl: String) -> String {
        // Create a deterministic hash of the feed URL for consistent feed IDs
        let content = feedUrl.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = abs(content.hashValue)
        return "feed_\(hash)"
    }
    
    // MARK: - Show Notes Creation
    
    private func createShowNotesAndChapters(description: String, contentEncoded: String?, itunesSummary: String?) -> (PodcastNotes?, [PodcastChapter]) {
        // Use the richest content available: content:encoded > itunes:summary > description
        let content = contentEncoded?.isEmpty == false ? contentEncoded! :
                     itunesSummary?.isEmpty == false ? itunesSummary! : description
        
        guard !content.isEmpty else { return (nil, []) }
        
        // Extract links from the content
        var links = extractLinksFromHTML(content)
        
        // Try to extract chapters from the content
        var extractedChapters = parseChapters(from: content)
        
        // Heuristically assign links to chapters and set timestamps on links
        let (enrichedChapters, timestampedLinks) = enrichChaptersWithLinks(chapters: extractedChapters, links: links)
        extractedChapters = enrichedChapters
        links = timestampedLinks
        
        let notes = PodcastNotes(content: content, links: links)
        return (notes, extractedChapters)
    }
    
    // MARK: - Link Extraction
    
    private func extractLinksFromHTML(_ html: String) -> [PodcastLink] {
        var links: [PodcastLink] = []
        
        // Simple regex to find <a href="url">text</a> patterns
        let pattern = #"<a\s+[^>]*href=["\']([^"\']+)["\'][^>]*>([^<]+)</a>"#
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsString = html as NSString
            let results = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for result in results {
                if result.numberOfRanges >= 3 {
                    let urlRange = result.range(at: 1)
                    let titleRange = result.range(at: 2)
                    
                    if urlRange.location != NSNotFound && titleRange.location != NSNotFound {
                        let url = nsString.substring(with: urlRange)
                        let title = nsString.substring(with: titleRange)
                        
                        // Skip empty or invalid URLs
                        if !url.isEmpty && !title.isEmpty {
                            links.append(PodcastLink(title: title, url: url))
                        }
                    }
                }
            }
        } catch {
            print("Error extracting links: \(error)")
        }
        
        return links
    }
    
    // MARK: - Chapter-Link Enrichment
    
    private func enrichChaptersWithLinks(chapters: [PodcastChapter], links: [PodcastLink]) -> ([PodcastChapter], [PodcastLink]) {
        guard !chapters.isEmpty, !links.isEmpty else { return (chapters, links) }
        // Build simple lookup of normalized chapter titles
        func norm(_ s: String) -> String {
            return s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var chapterByIndex: [Int: PodcastChapter] = [:]
        for (idx, ch) in chapters.enumerated() { chapterByIndex[idx] = ch }
        
        // For each link, try to find the best matching chapter by title similarity, then assign link URL to that chapter if it lacks one
        func score(_ linkTitle: String, _ chapterTitle: String) -> Int {
            let a = norm(linkTitle)
            let b = norm(chapterTitle)
            if a == b { return 100 }
            if a.isEmpty || b.isEmpty { return 0 }
            if b.contains(a) { return 90 }
            if a.contains(b) { return 80 }
            // Token overlap
            let at = Set(a.split{ !$0.isLetter && !$0.isNumber })
            let bt = Set(b.split{ !$0.isLetter && !$0.isNumber })
            let inter = at.intersection(bt)
            return inter.count * 10
        }
        
        var updatedChapters = chapters
        var updatedLinks: [PodcastLink] = []
        
        for link in links {
            var bestIndex: Int? = nil
            var bestScore = 0
            for (idx, ch) in chapters.enumerated() {
                let s = score(link.title, ch.title)
                if s > bestScore { bestScore = s; bestIndex = idx }
            }
            if let idx = bestIndex, bestScore >= 20 { // reasonable heuristic
                // Assign link to chapter if chapter has no url yet
                if updatedChapters[idx].url == nil || updatedChapters[idx].url?.isEmpty == true {
                    updatedChapters[idx].url = link.url
                }
                // Also timestamp the link with the chapter start time if it doesn't already have one
                var tsLink = link
                if tsLink.timeStamp == nil { tsLink.timeStamp = updatedChapters[idx].startTime }
                updatedLinks.append(tsLink)
            } else {
                updatedLinks.append(link)
            }
        }
        return (updatedChapters, updatedLinks)
    }
    
    // MARK: - Chapter Parsing
    
    private func parseChapters(from content: String) -> [PodcastChapter] {
        var chapters: [PodcastChapter] = []
        
        // Normalize HTML into plain text lines
        var normalized = content
        let lineBreakTags = ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"]
        for tag in lineBreakTags {
            normalized = normalized.replacingOccurrences(of: tag, with: "\n", options: [.caseInsensitive])
        }
        normalized = normalized.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        normalized = normalized
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        
        // Enhanced patterns to detect various chapter formats
        let patterns = [
            // Timestamp at end: "Chapter Title 4:12"
            #"(.+?)\s+(\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
            // Timestamp at end with negative time: "Chapter Title -0:38"
            #"(.+?)\s+(-?\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
            // Traditional formats: [MM:SS] or (MM:SS)
            #"\[(\d{1,2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
            #"\((\d{1,2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
            // HH:MM:SS formats
            #"\[(\d{1,2}):(\d{2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
            #"\((\d{1,2}):(\d{2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
            // Time at beginning: "4:12 Chapter Title"
            #"^(\d{1,2}):(\d{2})\s+(.+?)(?=\n|$)"#,
            // Time at beginning with hours: "1:23:45 Chapter Title"
            #"^(\d{1,2}):(\d{2}):(\d{2})\s+(.+?)(?=\n|$)"#
        ]
        
        for (patternIndex, pattern) in patterns.enumerated() {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
                let nsString = normalized as NSString
                let results = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: nsString.length))
                
                for result in results {
                    var startTime: TimeInterval = 0
                    var title: String = ""
                    
                    // Pattern specific parsing
                    if patternIndex == 0 || patternIndex == 1 { // "Chapter Title 4:12" or "Chapter Title -0:38"
                        if result.numberOfRanges == 4 {
                            let titleRange = result.range(at: 1)
                            let minutesRange = result.range(at: 2)
                            let secondsRange = result.range(at: 3)
                            
                            if titleRange.location != NSNotFound && minutesRange.location != NSNotFound && secondsRange.location != NSNotFound {
                                title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                                let minutes = Double(nsString.substring(with: minutesRange)) ?? 0
                                let seconds = Double(nsString.substring(with: secondsRange)) ?? 0
                                startTime = abs(minutes * 60 + seconds) // Handle negative times
                            }
                        }
                    } else if patternIndex >= 2 && patternIndex <= 5 { // Traditional formats and HH:MM:SS
                        if result.numberOfRanges == 4 { // MM:SS format
                            let minutesRange = result.range(at: 1)
                            let secondsRange = result.range(at: 2)
                            let titleRange = result.range(at: 3)
                            
                            if minutesRange.location != NSNotFound && secondsRange.location != NSNotFound && titleRange.location != NSNotFound {
                                let minutes = Double(nsString.substring(with: minutesRange)) ?? 0
                                let seconds = Double(nsString.substring(with: secondsRange)) ?? 0
                                title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                                startTime = minutes * 60 + seconds
                            }
                        } else if result.numberOfRanges == 5 { // HH:MM:SS format
                            let hoursRange = result.range(at: 1)
                            let minutesRange = result.range(at: 2)
                            let secondsRange = result.range(at: 3)
                            let titleRange = result.range(at: 4)
                            
                            if hoursRange.location != NSNotFound && minutesRange.location != NSNotFound && 
                               secondsRange.location != NSNotFound && titleRange.location != NSNotFound {
                                let hours = Double(nsString.substring(with: hoursRange)) ?? 0
                                let minutes = Double(nsString.substring(with: minutesRange)) ?? 0
                                let seconds = Double(nsString.substring(with: secondsRange)) ?? 0
                                title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                                startTime = hours * 3600 + minutes * 60 + seconds
                            }
                        }
                    } else { // Time at beginning formats
                        if result.numberOfRanges == 4 { // MM:SS format
                            let minutesRange = result.range(at: 1)
                            let secondsRange = result.range(at: 2)
                            let titleRange = result.range(at: 3)
                            
                            if minutesRange.location != NSNotFound && secondsRange.location != NSNotFound && titleRange.location != NSNotFound {
                                let minutes = Double(nsString.substring(with: minutesRange)) ?? 0
                                let seconds = Double(nsString.substring(with: secondsRange)) ?? 0
                                title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                                startTime = minutes * 60 + seconds
                            }
                        } else if result.numberOfRanges == 5 { // HH:MM:SS format
                            let hoursRange = result.range(at: 1)
                            let minutesRange = result.range(at: 2)
                            let secondsRange = result.range(at: 3)
                            let titleRange = result.range(at: 4)
                            
                            if hoursRange.location != NSNotFound && minutesRange.location != NSNotFound && 
                               secondsRange.location != NSNotFound && titleRange.location != NSNotFound {
                                let hours = Double(nsString.substring(with: hoursRange)) ?? 0
                                let minutes = Double(nsString.substring(with: minutesRange)) ?? 0
                                let seconds = Double(nsString.substring(with: secondsRange)) ?? 0
                                title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                                startTime = hours * 3600 + minutes * 60 + seconds
                            }
                        }
                    }
                    
                    // Clean up title and add chapter
                    if !title.isEmpty {
                        // Remove common prefixes and clean up
                        title = title.replacingOccurrences(of: "^\\d+\\.", with: "", options: .regularExpression)
                        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Skip very short titles that are likely false positives
                        if title.count > 2 {
                            chapters.append(PodcastChapter(title: title, startTime: startTime))
                        }
                    }
                }
                
                // If we found chapters with this pattern, stop trying other patterns
                if !chapters.isEmpty { break }
            } catch {
                print("Error parsing chapters with pattern \(pattern): \(error)")
            }
        }
        
        // Sort chapters by start time
        chapters.sort { $0.startTime < $1.startTime }
        

        return chapters
    }
}

// MARK: - Podcasting 2.0 external chapters helpers
private extension EpisodeBuilder {
    func fetchChaptersFromJSON(urlString: String) -> [PodcastChapter]? {
        guard let url = URL(string: urlString) else { return nil }
        var result: [PodcastChapter]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil, let data = data else { return }
            result = self.decodeChaptersJSON(data: data)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5.0)
        return result
    }
    
    struct ChaptersJSONRoot: Decodable { let chapters: [ChaptersJSONItem]? }
    struct ChaptersJSONItem: Decodable {
        let startTime: Double?
        let start: String?
        let title: String?
        let url: String?
        let img: String?
        let imageUrl: String?
    }
    
    func decodeChaptersJSON(data: Data) -> [PodcastChapter]? {
        if let root = try? JSONDecoder().decode(ChaptersJSONRoot.self, from: data), let items = root.chapters {
            let mapped: [PodcastChapter] = items.compactMap { item in
                let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                var startSeconds: TimeInterval = 0
                if let s = item.startTime { startSeconds = s }
                else if let startStr = item.start, !startStr.isEmpty { startSeconds = parseDuration(startStr) }
                return PodcastChapter(title: title, startTime: startSeconds, url: item.url, imageUrl: item.img ?? item.imageUrl)
            }
            return mapped.isEmpty ? nil : mapped.sorted { $0.startTime < $1.startTime }
        }
        if let items = try? JSONDecoder().decode([ChaptersJSONItem].self, from: data) {
            let mapped: [PodcastChapter] = items.compactMap { item in
                let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                var startSeconds: TimeInterval = 0
                if let s = item.startTime { startSeconds = s }
                else if let startStr = item.start, !startStr.isEmpty { startSeconds = parseDuration(startStr) }
                return PodcastChapter(title: title, startTime: startSeconds, url: item.url, imageUrl: item.img ?? item.imageUrl)
            }
            return mapped.isEmpty ? nil : mapped.sorted { $0.startTime < $1.startTime }
        }
        return nil
    }
}

// MARK: - Helper Extensions

extension DateFormatter {
    static let rfc2822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

func parseDuration(_ durationString: String) -> TimeInterval {
    let components = durationString.components(separatedBy: ":")
    
    if components.count == 3 {
        // HH:MM:SS format
        let hours = Double(components[0]) ?? 0
        let minutes = Double(components[1]) ?? 0
        let seconds = Double(components[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    } else if components.count == 2 {
        // MM:SS format
        let minutes = Double(components[0]) ?? 0
        let seconds = Double(components[1]) ?? 0
        return minutes * 60 + seconds
    } else {
        // Just seconds
        return Double(durationString) ?? 0
    }
} 
