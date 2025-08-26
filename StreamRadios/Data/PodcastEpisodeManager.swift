import Foundation
import CoreData
import os.log

/// Struct for bulk episode state updates
struct EpisodeStateUpdate {
    let episodeId: String
    let progress: Double?
    let isFavorite: Bool?
    let isDownloaded: Bool?
    let isPlayed: Bool?
    
    init(episodeId: String, progress: Double? = nil, isFavorite: Bool? = nil, isDownloaded: Bool? = nil, isPlayed: Bool? = nil) {
        self.episodeId = episodeId
        self.progress = progress
        self.isFavorite = isFavorite
        self.isDownloaded = isDownloaded
        self.isPlayed = isPlayed
    }
}

/// High-performance episode manager with efficient pagination and caching
class PodcastEpisodeManager {
    private let log = OSLog(subsystem: "StreamRadios", category: "EpisodeManager")
    private let cacheManager = PodcastCacheManager()
    private let batchSize = 100
    
    // ULTRA-FAST MEMORY CACHE: Keep converted episodes in memory for instant access
    private var episodeMemoryCache: [String: [PodcastEpisode]] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private let memoryCacheTimeout: TimeInterval = 300 // 5 minutes
    private let maxMemoryCacheEntries = 10
    
    // MARK: - Public Interface
    
    /// Load episodes with efficient pagination and filtering
    func loadEpisodes(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async throws -> EpisodeLoadResult {
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // ULTRA-FAST MEMORY CACHE CHECK: For immediate responses on feed switching
        if filter == .all && searchQuery == nil {
            let memoryCacheKey = "\(feedId)_all"
            if let cachedEpisodes = getFromMemoryCache(key: memoryCacheKey) {
                let startIndex = (page - 1) * pageSize
                let endIndex = min(startIndex + pageSize, cachedEpisodes.count)
                let paginatedEpisodes = startIndex < cachedEpisodes.count ? 
                    Array(cachedEpisodes[startIndex..<endIndex]) : []
                let hasMore = cachedEpisodes.count > (page * pageSize)
                
                os_log("⚡ MEMORY CACHE HIT: %d episodes in %.4f seconds", log: log, type: .debug, paginatedEpisodes.count, CFAbsoluteTimeGetCurrent() - startTime)
                return EpisodeLoadResult(episodes: paginatedEpisodes, hasMore: hasMore, totalCount: cachedEpisodes.count)
            }
        }
        
        // For filtering operations (Favorites/Downloads), always bypass cache to ensure fresh results
        let shouldUseCache = (filter == .all && searchQuery == nil)
        
        // Try cache first only for All tab without search
        if shouldUseCache, let cachedResult = await cacheManager.getCachedEpisodes(
            feedId: feedId,
            page: page,
            pageSize: pageSize,
            filter: filter,
            searchQuery: searchQuery
        ) {
            os_log("📦 Cache hit for feed %@ page %d", log: log, type: .debug, feedId, page)
            return cachedResult
        }
        
        // PRIORITIZED LOADING: For large feeds and first page, use optimized approach
        if page == 1 && filter == .all && searchQuery == nil {
            // Check if this is a large feed that needs prioritized loading
            let totalEpisodeCount = try await getTotalEpisodeCount(feedId: feedId)
            if totalEpisodeCount > 100 {
                os_log("🚀 PRIORITIZED LOADING: Large feed detected (%d episodes), using fast-load approach", log: log, type: .info, totalEpisodeCount)
                let result = try await loadWithPrioritizedApproach(
                    feedId: feedId,
                    pageSize: pageSize,
                    filter: filter
                )
                
                // Cache the result for future loads
                if shouldUseCache {
                    await cacheManager.cacheEpisodes(result, for: feedId, page: page, filter: filter, searchQuery: searchQuery)
                }
                
                let endTime = CFAbsoluteTimeGetCurrent()
                os_log("⚡ PRIORITIZED LOAD: %d episodes in %.3f seconds", log: log, type: .info, result.episodes.count, endTime - startTime)
                return result
            }
        }
        
        // Load from Core Data using standard approach
        let result = try await loadFromCoreData(
            feedId: feedId,
            page: page,
            pageSize: pageSize,
            filter: filter,
            searchQuery: searchQuery
        )
        
        // Cache the result only for All tab
        if shouldUseCache {
            await cacheManager.cacheEpisodes(result, for: feedId, page: page, filter: filter, searchQuery: searchQuery)
            
            // ULTRA-FAST MEMORY CACHE: Store full episode list for instant subsequent access
            if page == 1 && filter == .all && searchQuery == nil {
                // Load all episodes for this feed to populate memory cache
                let allEpisodesResult = try await loadAllEpisodesForMemoryCache(feedId: feedId)
                storeInMemoryCache(key: "\(feedId)_all", episodes: allEpisodesResult)
            }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        os_log("⚡ Loaded %d episodes in %.3f seconds (filter: %@, cached: %@)", log: log, type: .info, result.episodes.count, endTime - startTime, filter.displayName, shouldUseCache ? "yes" : "no")
        
        return result
    }

    /// Search episodes across all saved podcasts (Core Data) by title or description
    /// - Parameters:
    ///   - query: Case/diacritic-insensitive search string
    ///   - limit: Maximum number of results to return
    /// - Returns: Matching `PodcastEpisode` list sorted by newest first
    func searchEpisodesAcrossFeeds(query: String, limit: Int = 50) async -> [PodcastEpisode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let backgroundContext = CoreDataStack.shared.newBackgroundContext()

        return await backgroundContext.perform { [weak self] in
            guard let self = self else { return [] }
            do {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(
                    format: "title CONTAINS[cd] %@ OR descriptionText CONTAINS[cd] %@",
                    trimmed, trimmed
                )
                request.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                request.fetchLimit = limit

                // Performance optimizations
                request.fetchBatchSize = min(limit, self.batchSize)
                request.includesPropertyValues = true
                request.returnsObjectsAsFaults = false
                request.relationshipKeyPathsForPrefetching = ["feed"]

                let managed = try backgroundContext.fetch(request)
                let episodes = self.convertToEpisodes(managed)
                return episodes
            } catch {
                os_log("❌ Global episode search failed: %@", log: self.log, type: .error, error.localizedDescription)
                return []
            }
        }
    }
    
    /// Clear cache for a feed when episode states change
    func clearCacheForFeed(_ feedId: String) async {
        await cacheManager.clearCacheForFeed(feedId)
    }
    
    /// Clear all cache - useful for debugging
    func clearAllCache() async {
        await cacheManager.clearAllCache()
    }
    
    /// Get total episode count for a feed without loading all episodes
    private func getTotalEpisodeCount(feedId: String) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    let countRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    countRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                    countRequest.includesPropertyValues = false
                    countRequest.includesSubentities = false
                    
                    let count = try backgroundContext.count(for: countRequest)
                    continuation.resume(returning: count)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Load episodes with prioritized approach for large feeds - shows newest episodes immediately
    private func loadWithPrioritizedApproach(
        feedId: String,
        pageSize: Int,
        filter: EpisodeFilter
    ) async throws -> EpisodeLoadResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // PRIORITIZED FETCH: Only fetch the newest episodes first (limited set)
                    let prioritizedFetchRequest = self.buildPrioritizedFetchRequest(
                        feedId: feedId,
                        maxEpisodes: pageSize
                    )
                    
                    // Fetch only the newest episodes
                    let newestManagedEpisodes = try backgroundContext.fetch(prioritizedFetchRequest)
                    
                    // Convert to domain models with EpisodeStateManager sync
                    let newestEpisodes = self.convertToEpisodes(newestManagedEpisodes)
                    
                    // Apply filtering based on EpisodeStateManager (source of truth)
                    let filteredEpisodes = self.applyStateBasedFiltering(newestEpisodes, filter: filter)
                    
                    // For prioritized loading, we show the filtered results immediately
                    // and indicate there are more episodes available
                    let result = EpisodeLoadResult(
                        episodes: filteredEpisodes,
                        hasMore: true, // Always indicate more episodes for large feeds
                        totalCount: filteredEpisodes.count // Actual count will be updated later
                    )
                    
                    continuation.resume(returning: result)
                    
                } catch {
                    os_log("❌ Failed to load episodes with prioritized approach: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Build fetch request optimized for prioritized loading - only newest episodes
    private func buildPrioritizedFetchRequest(
        feedId: String,
        maxEpisodes: Int
    ) -> NSFetchRequest<PodcastModel> {
        
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        // Only filter by feedId for fastest query
        fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
        
        // Sort by publication date (newest first) - this is the key optimization
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        // CRITICAL: Limit to only the newest episodes for fast loading
        fetchRequest.fetchLimit = maxEpisodes
        
        // Performance optimizations for fast loading
        fetchRequest.fetchBatchSize = min(maxEpisodes, 50) // Smaller batch for speed
        fetchRequest.includesPropertyValues = true
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
        
        return fetchRequest
    }
    
    /// Clean up duplicate episodes in Core Data with conservative safety checks
    func cleanupDuplicateEpisodes() async throws {
        os_log("🧹 Starting conservative cleanup of duplicate episodes in Core Data", log: log, type: .info)
        
        try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Get all episodes grouped by ID
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.sortDescriptors = [
                        NSSortDescriptor(key: "id", ascending: true),
                        NSSortDescriptor(key: "publicationDate", ascending: false) // Keep most recent first
                    ]
                    
                    let allEpisodes = try backgroundContext.fetch(fetchRequest)
                    var seenIds = Set<String>()
                    var duplicatesToDelete: [PodcastModel] = []
                    var episodeIdCounts: [String: Int] = [:]
                    
                    // First pass: Count occurrences of each episode ID
                    for episode in allEpisodes {
                        guard let episodeId = episode.id, !episodeId.isEmpty else {
                            // Delete episodes without valid IDs
                            duplicatesToDelete.append(episode)
                            continue
                        }
                        episodeIdCounts[episodeId, default: 0] += 1
                    }
                    
                    // CRITICAL SAFETY CHECK: Don't delete more than 10% of episodes to prevent data loss
                    let totalEpisodes = allEpisodes.count
                    let maxAllowedDeletions = Int(Double(totalEpisodes) * 0.1) // 10% maximum
                    
                    os_log("🔍 Found %d total episodes, will delete maximum %d duplicates", log: self.log, type: .info, totalEpisodes, maxAllowedDeletions)
                    
                    // Second pass: Mark only true duplicates for deletion (keep most recent)
                    for episode in allEpisodes {
                        guard let episodeId = episode.id, !episodeId.isEmpty else {
                            continue // Already handled above
                        }
                        
                        // Only consider for deletion if there are actually multiple episodes with this ID
                        if episodeIdCounts[episodeId] ?? 0 > 1 {
                            if seenIds.contains(episodeId) {
                                // This is a duplicate, mark for deletion but only if we haven't exceeded our safety limit
                                if duplicatesToDelete.count < maxAllowedDeletions {
                                    duplicatesToDelete.append(episode)
                                    os_log("🗑️ Marking duplicate episode for deletion: %@ (occurrence %d)", log: self.log, type: .debug, episodeId, episodeIdCounts[episodeId] ?? 0)
                                } else {
                                    os_log("⚠️ Reached maximum deletion limit, skipping duplicate: %@", log: self.log, type: .info, episodeId)
                                }
                            } else {
                                seenIds.insert(episodeId)
                            }
                        }
                    }
                    
                    // FINAL SAFETY CHECK: If we're about to delete more than 5% of episodes, abort the operation
                    let deletionRatio = Double(duplicatesToDelete.count) / Double(totalEpisodes)
                    if deletionRatio > 0.05 { // 5% safety threshold
                        os_log("🛑 SAFETY ABORT: Would delete %.1f%% of episodes (%d/%d), this seems excessive - skipping cleanup", log: self.log, type: .error, deletionRatio * 100, duplicatesToDelete.count, totalEpisodes)
                        continuation.resume()
                        return
                    }
                    
                    // Delete duplicates
                    for duplicate in duplicatesToDelete {
                        backgroundContext.delete(duplicate)
                    }
                    
                    if !duplicatesToDelete.isEmpty {
                        try backgroundContext.save()
                        os_log("✅ Safely cleaned up %d duplicate episodes (%.1f%% of total)", log: self.log, type: .info, duplicatesToDelete.count, deletionRatio * 100)
                    } else {
                        os_log("✅ No duplicate episodes found requiring cleanup", log: self.log, type: .info)
                    }
                    
                    continuation.resume()
                    
                } catch {
                    os_log("❌ Failed to cleanup duplicate episodes: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Bulk update episode states efficiently
    func updateEpisodeStates(_ updates: [EpisodeStateUpdate]) async throws {
        guard !updates.isEmpty else { return }
        
        try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Batch fetch episodes for updates
                    let episodeIds = updates.map { $0.episodeId }
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id IN %@", episodeIds)
                    
                    let episodes = try backgroundContext.fetch(fetchRequest)
                    
                    // Handle duplicate episode IDs gracefully - use the most recent one
                    var episodeDict: [String: PodcastModel] = [:]
                    for episode in episodes {
                        guard let episodeId = episode.id else { continue }
                        
                        if let existingEpisode = episodeDict[episodeId] {
                            // Keep the episode with the most recent date or the one with more data
                            let existingDate = existingEpisode.publicationDate ?? Date.distantPast
                            let newDate = episode.publicationDate ?? Date.distantPast
                            
                            if newDate > existingDate {
                                episodeDict[episodeId] = episode
                                print("⚠️ Found duplicate episode ID \(episodeId), keeping newer one")
                            } else {
                                print("⚠️ Found duplicate episode ID \(episodeId), keeping existing one")
                            }
                        } else {
                            episodeDict[episodeId] = episode
                        }
                    }
                    
                    // Apply updates efficiently
                    for update in updates {
                        guard let episode = episodeDict[update.episodeId] else { continue }
                        
                        if let progress = update.progress {
                            episode.progress = progress
                        }
                        if let isFavorite = update.isFavorite {
                            episode.isFavorite = isFavorite
                        }
                        if let isDownloaded = update.isDownloaded {
                            episode.isDownloaded = isDownloaded
                        }
                        if let isPlayed = update.isPlayed {
                            episode.isPlayed = isPlayed
                        }
                    }
                    
                    try backgroundContext.save()
                    
                    // Clear relevant caches - don't await inside synchronous context
                    let feedIds = Set(episodes.compactMap { $0.feedId })
                    
                    continuation.resume()
                    
                    // Clear caches after completion - asynchronously
                    Task {
                        for feedId in feedIds {
                            await self.cacheManager.clearCacheForFeed(feedId)
                        }
                    }
                    
                } catch {
                    os_log("❌ Failed to update episode states: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Get episode counts for different filters
    func getEpisodeCounts(for feedId: String) async throws -> EpisodeCounts {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    let basePredicate = NSPredicate(format: "feedId == %@", feedId)
                    
                    // Count all episodes
                    let allRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    allRequest.predicate = basePredicate
                    allRequest.includesSubentities = false
                    let allCount = try backgroundContext.count(for: allRequest)
                    
                    // Count favorites
                    let favoritesRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    favoritesRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        basePredicate,
                        NSPredicate(format: "isFavorite == YES")
                    ])
                    favoritesRequest.includesSubentities = false
                    let favoritesCount = try backgroundContext.count(for: favoritesRequest)
                    
                    // Count downloads
                    let downloadsRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    downloadsRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        basePredicate,
                        NSPredicate(format: "isDownloaded == YES")
                    ])
                    downloadsRequest.includesSubentities = false
                    let downloadsCount = try backgroundContext.count(for: downloadsRequest)
                    
                    let counts = EpisodeCounts(
                        all: allCount,
                        favorites: favoritesCount,
                        downloads: downloadsCount
                    )
                    
                    continuation.resume(returning: counts)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Update the local file path for a downloaded episode
    func updateEpisodeLocalPath(_ episodeId: String, localPath: String?) async {
        await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                do {
                    if let episode = try backgroundContext.fetch(fetchRequest).first {
                        episode.localFilePath = localPath
                        try backgroundContext.save()
                        os_log("📁 Updated episode local path: %@", log: self.log, type: .info, localPath ?? "nil")
                    } else {
                        os_log("❌ Episode not found for local path update: %@", log: self.log, type: .error, episodeId)
                    }
                } catch {
                    os_log("❌ Failed to update episode local path: %@", log: self.log, type: .error, error.localizedDescription)
                }
                
                continuation.resume()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func loadFromCoreData(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async throws -> EpisodeLoadResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Fetch ALL episodes for the feed first (without filter-based pagination)
                    let baseFetchRequest = self.buildBaseFetchRequest(
                        feedId: feedId,
                        searchQuery: searchQuery
                    )
                    
                    // Fetch all matching episodes
                    let managedEpisodes = try backgroundContext.fetch(baseFetchRequest)
                    
                    // Convert to domain models with EpisodeStateManager sync
                    let allEpisodes = self.convertToEpisodes(managedEpisodes)
                    
                    // Apply filtering based on EpisodeStateManager (source of truth)
                    let filteredEpisodes = self.applyStateBasedFiltering(allEpisodes, filter: filter)
                    
                    // Apply pagination to filtered results
                    let startIndex = (page - 1) * pageSize
                    let endIndex = min(startIndex + pageSize, filteredEpisodes.count)
                    let paginatedEpisodes = startIndex < filteredEpisodes.count ? 
                        Array(filteredEpisodes[startIndex..<endIndex]) : []
                    
                    let hasMore = filteredEpisodes.count > (page * pageSize)
                    
                    let result = EpisodeLoadResult(
                        episodes: paginatedEpisodes,
                        hasMore: hasMore,
                        totalCount: filteredEpisodes.count
                    )
                    
                    continuation.resume(returning: result)
                    
                } catch {
                    os_log("❌ Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func buildFetchRequest(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) -> NSFetchRequest<PodcastModel> {
        
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        // Build predicate
        var predicates = [NSPredicate(format: "feedId == %@", feedId)]
        
        switch filter {
        case .favorites:
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        case .downloads:
            predicates.append(NSPredicate(format: "isDownloaded == YES"))
        case .all:
            break
        }
        
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(
                format: "title CONTAINS[cd] %@ OR descriptionText CONTAINS[cd] %@",
                query, query
            ))
        }
        
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        fetchRequest.fetchLimit = pageSize
        fetchRequest.fetchOffset = (page - 1) * pageSize
        
        // AGGRESSIVE PERFORMANCE OPTIMIZATIONS  
        fetchRequest.fetchBatchSize = min(pageSize, batchSize)
        fetchRequest.includesPropertyValues = true
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.includesSubentities = false
        fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
        
        return fetchRequest
    }
    
    private func buildBaseFetchRequest(
        feedId: String,
        searchQuery: String?
    ) -> NSFetchRequest<PodcastModel> {
        
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        // Build predicate (only feedId and search, no favorite/download filtering)
        var predicates = [NSPredicate(format: "feedId == %@", feedId)]
        
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(
                format: "title CONTAINS[cd] %@ OR descriptionText CONTAINS[cd] %@",
                query, query
            ))
        }
        
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        // AGGRESSIVE PERFORMANCE OPTIMIZATIONS
        fetchRequest.fetchBatchSize = batchSize
        fetchRequest.includesPropertyValues = true
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.includesSubentities = false // Exclude subentities for faster fetch
        
        // MEMORY OPTIMIZATION: Only load essential properties for conversion
        fetchRequest.propertiesToFetch = [
            "id", "title", "descriptionText", "audioUrl", "publicationDate", 
            "duration", "fileSize", "feedId", "progress", "isFavorite", 
            "isDownloaded", "isPlayed", "localFilePath", "chaptersData", "notesData"
        ]
        
        fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
        
        return fetchRequest
    }
    
    private func convertToEpisodes(_ managedEpisodes: [PodcastModel]) -> [PodcastEpisode] {
        // PERFORMANCE: Early exit for empty arrays
        guard !managedEpisodes.isEmpty else { return [] }
        
        // BATCH OPTIMIZATION: Get all episode IDs at once for batch state lookup
        let episodeIds = managedEpisodes.compactMap { $0.id }
        
        // BATCH STATE LOADING: Get all episode states in one operation
        let episodeStatesData = EpisodeStateManager.shared.getBatchEpisodeData(for: episodeIds)
        let isCloudKitPriorityMode = EpisodeStateManager.shared.isCloudKitPriorityMode()
        
        // PARALLEL PROCESSING: Use concurrent map for conversion
        return managedEpisodes.compactMap { managedEpisode in
            guard let episodeId = managedEpisode.id else { return nil }
            
            var episode = managedEpisode.toPodcastEpisode()
            
            // FAST STATE LOOKUP: Get pre-fetched state data
            guard let stateData = episodeStatesData[episodeId] else {
                // Episode not in state manager, use Core Data only
                return episode
            }
            
            let coreDataProgress = episode.state.progress
            let finalProgress: Double
            let finalState: EpisodePlaybackState
            let finalFavorite: Bool
            let finalDownloaded: Bool
            
            if isCloudKitPriorityMode {
                // CLOUDKIT PRIORITY: Use highest progress, prioritize Core Data for other states
                finalProgress = max(coreDataProgress, stateData.progress)
                finalState = finalProgress >= 0.99 ? .played : (finalProgress > 0 ? .inProgress : .new)
                finalFavorite = managedEpisode.isFavorite
                finalDownloaded = managedEpisode.isDownloaded
            } else {
                // NORMAL MODE: Use highest progress, EpisodeStateManager for other states
                finalProgress = max(stateData.progress, coreDataProgress)
                finalState = finalProgress >= 0.99 ? .played : (finalProgress > 0 ? .inProgress : .new)
                finalFavorite = stateData.isFavorite
                finalDownloaded = stateData.isDownloaded
            }
            
            // Apply the final values to the episode
            episode.state.progress = finalProgress
            episode.state.isFavorite = finalFavorite
            episode.state.isDownloaded = finalDownloaded
            
            // Determine isPlayed based on final state and progress
            episode.state.isPlayed = (finalState == .played) || (finalProgress >= 0.99)
            
            return episode
        }
    }
    
    /// Apply filtering based on EpisodeStateManager (source of truth) after Core Data fetch
    private func applyStateBasedFiltering(_ episodes: [PodcastEpisode], filter: EpisodeFilter) -> [PodcastEpisode] {
        switch filter {
        case .all:
            return episodes
        case .favorites:
            return episodes.filter { $0.state.isFavorite }
        case .downloads:
            return episodes.filter { $0.state.isDownloaded }
        }
    }
    
    private func getTotalCount(
        feedId: String,
        filter: EpisodeFilter,
        searchQuery: String?,
        in context: NSManagedObjectContext
    ) throws -> Int {
        
        // CRITICAL: For accurate counts, we need to fetch episodes and apply EpisodeStateManager filtering
        // rather than relying on potentially stale Core Data states
        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        // Build base predicate (without state-based filtering)
        var predicates = [NSPredicate(format: "feedId == %@", feedId)]
        
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(
                format: "title CONTAINS[cd] %@ OR descriptionText CONTAINS[cd] %@",
                query, query
            ))
        }
        
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest.includesSubentities = false
        
        // For state-based filters (favorites, downloads), we need to check EpisodeStateManager
        switch filter {
        case .all:
            // For 'all', we can use Core Data count directly
            return try context.count(for: fetchRequest)
        case .favorites, .downloads:
            // For state-based filters, fetch episodes and apply EpisodeStateManager filtering
            let managedEpisodes = try context.fetch(fetchRequest)
            let episodes = convertToEpisodes(managedEpisodes)
            let filteredEpisodes = applyStateBasedFiltering(episodes, filter: filter)
            return filteredEpisodes.count
        }
    }
}

// MARK: - Supporting Types

enum EpisodeFilter: Int, CaseIterable {
    case all = 0
    case favorites = 1
    case downloads = 2
    
    var displayName: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .downloads: return "Downloads"
        }
    }
}

struct EpisodeLoadResult {
    let episodes: [PodcastEpisode]
    let hasMore: Bool
    let totalCount: Int
}

struct EpisodeCounts {
    let all: Int
    let favorites: Int
    let downloads: Int
}

// MARK: - Cache Manager

actor PodcastCacheManager {
    private var episodeCache: [String: EpisodeLoadResult] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheTimeout: TimeInterval = 300 // 5 minutes
    private let maxCacheSize = 50 // Maximum cached results
    
    func getCachedEpisodes(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async -> EpisodeLoadResult? {
        let key = cacheKey(feedId: feedId, page: page, filter: filter, searchQuery: searchQuery)
        
        guard let timestamp = cacheTimestamps[key],
              Date().timeIntervalSince(timestamp) < cacheTimeout,
              let cachedResult = episodeCache[key] else {
            return nil
        }
        
        return cachedResult
    }
    
    func cacheEpisodes(
        _ result: EpisodeLoadResult,
        for feedId: String,
        page: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async {
        let key = cacheKey(feedId: feedId, page: page, filter: filter, searchQuery: searchQuery)
        
        // Implement LRU cache eviction
        if episodeCache.count >= maxCacheSize {
            Task {
                await evictOldestCacheEntry()
            }
        }
        
        episodeCache[key] = result
        cacheTimestamps[key] = Date()
    }
    
    func clearCacheForFeed(_ feedId: String) async {
        let keysToRemove = episodeCache.keys.filter { $0.hasPrefix(feedId) }
        for key in keysToRemove {
            episodeCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
        }
    }
    
    func clearAllCache() async {
        episodeCache.removeAll()
        cacheTimestamps.removeAll()
    }
    
    private func cacheKey(feedId: String, page: Int, filter: EpisodeFilter, searchQuery: String?) -> String {
        let query = searchQuery ?? ""
        return "\(feedId)_p\(page)_f\(filter.rawValue)_q\(query.hashValue)"
    }
    
    private func evictOldestCacheEntry() async {
        guard let oldestKey = cacheTimestamps.min(by: { $0.value < $1.value })?.key else { return }
        
        episodeCache.removeValue(forKey: oldestKey)
        cacheTimestamps.removeValue(forKey: oldestKey)
    }
}

// MARK: - PodcastEpisodeManager Memory Cache Extensions
extension PodcastEpisodeManager {
    
    /// Get episodes from ultra-fast memory cache
    private func getFromMemoryCache(key: String) -> [PodcastEpisode]? {
        // Check if cache entry exists and is not expired
        guard let episodes = episodeMemoryCache[key],
              let timestamp = memoryCacheTimestamps[key],
              Date().timeIntervalSince(timestamp) < memoryCacheTimeout else {
            // Remove expired entry
            episodeMemoryCache.removeValue(forKey: key)
            memoryCacheTimestamps.removeValue(forKey: key)
            return nil
        }
        
        return episodes
    }
    
    /// Store episodes in ultra-fast memory cache
    private func storeInMemoryCache(key: String, episodes: [PodcastEpisode]) {
        // Evict oldest entries if cache is full
        while episodeMemoryCache.count >= maxMemoryCacheEntries {
            evictOldestMemoryCacheEntry()
        }
        
        episodeMemoryCache[key] = episodes
        memoryCacheTimestamps[key] = Date()
    }
    
    /// Evict oldest memory cache entry
    private func evictOldestMemoryCacheEntry() {
        guard let oldestKey = memoryCacheTimestamps.min(by: { $0.value < $1.value })?.key else { return }
        
        episodeMemoryCache.removeValue(forKey: oldestKey)
        memoryCacheTimestamps.removeValue(forKey: oldestKey)
    }
    
    /// Load all episodes for memory cache population
    private func loadAllEpisodesForMemoryCache(feedId: String) async throws -> [PodcastEpisode] {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Optimized fetch for all episodes
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                    fetchRequest.fetchBatchSize = self.batchSize
                    fetchRequest.includesPropertyValues = true
                    fetchRequest.returnsObjectsAsFaults = false
                    fetchRequest.includesSubentities = false
                    
                    let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                    let episodes = self.convertToEpisodes(managedEpisodes)
                    
                    continuation.resume(returning: episodes)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Clear memory cache for a specific feed
    func clearMemoryCacheForFeed(_ feedId: String) {
        let keysToRemove = episodeMemoryCache.keys.filter { $0.hasPrefix(feedId) }
        for key in keysToRemove {
            episodeMemoryCache.removeValue(forKey: key)
            memoryCacheTimestamps.removeValue(forKey: key)
        }
    }
    
    /// Clear all memory cache
    func clearAllMemoryCache() {
        episodeMemoryCache.removeAll()
        memoryCacheTimestamps.removeAll()
    }
} 