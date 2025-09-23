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
        print("🔍 EPISODE MANAGER: Loading episodes for feedId '\(feedId)' (page: \(page), filter: \(filter))")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // INSTANT CACHE: Always check persistent cache first for immediate loading
        if let cachedResult = await cacheManager.getCachedEpisodes(
            feedId: feedId,
            page: page,
            pageSize: pageSize,
            filter: filter,
            searchQuery: searchQuery
        ) {
            os_log("⚡ INSTANT CACHE HIT: %d episodes in %.4f seconds", log: log, type: .info, cachedResult.episodes.count, CFAbsoluteTimeGetCurrent() - startTime)
            return cachedResult
        }
        
        // ULTRA-FAST MEMORY CACHE CHECK: Secondary cache for immediate responses
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
        
        // For filtering operations (Favorites/Downloads), always load fresh to ensure current state
        let shouldUseCache = (filter == .all && searchQuery == nil)
        
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
        
        // FINAL SAFETY CHECK: Ensure all episodes belong to the correct feed
        let safeEpisodes = result.episodes.filter { $0.feedId == feedId }
        if safeEpisodes.count != result.episodes.count {
            print("🚨 FINAL ISOLATION: Filtered out \(result.episodes.count - safeEpisodes.count) episodes that didn't belong to feed \(feedId) at final return")
        }
        let finalResult = EpisodeLoadResult(
            episodes: safeEpisodes,
            hasMore: result.hasMore,
            totalCount: result.totalCount
        )
        
        let endTime = CFAbsoluteTimeGetCurrent()
        os_log("⚡ Loaded %d episodes in %.3f seconds (filter: %@, cached: %@)", log: log, type: .info, finalResult.episodes.count, endTime - startTime, filter.displayName, shouldUseCache ? "yes" : "no")
        
        return finalResult
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
                let episodes = self.convertToEpisodesAcrossFeeds(managed)
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
    
    /// Force clear persistent cache (only use when feed is deleted)
    func clearPersistentCacheForFeed(_ feedId: String) async {
        await cacheManager.clearPersistentCacheForFeed(feedId)
        // Also clear memory cache
        clearMemoryCacheForFeed(feedId)
    }
    
    /// Check if episodes are cached for instant loading
    func hasInstantCache(feedId: String) async -> Bool {
        return await cacheManager.hasCachedEpisodes(feedId: feedId)
    }
    
    /// Update cache with new episodes detected from RSS
    func updateCacheWithNewEpisodes(_ newEpisodes: [PodcastEpisode], for feedId: String) async {
        await cacheManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
        
        // Also update memory cache if it exists
        let memoryCacheKey = "\(feedId)_all"
        if let existingMemoryCache = getFromMemoryCache(key: memoryCacheKey) {
            // Merge with memory cache
            let existingIds = Set(existingMemoryCache.map { $0.id })
            let uniqueNewEpisodes = newEpisodes.filter { !existingIds.contains($0.id) }
            
            if !uniqueNewEpisodes.isEmpty {
                var updatedCache = existingMemoryCache
                updatedCache.insert(contentsOf: uniqueNewEpisodes, at: 0)
                updatedCache.sort { $0.publicationDate > $1.publicationDate }
                storeInMemoryCache(key: memoryCacheKey, episodes: updatedCache)
            }
        }
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
                    let newestEpisodes = self.convertToEpisodes(newestManagedEpisodes, feedId: feedId)
                    
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
        
        // CRITICAL CONTAMINATION PREVENTION: Multiple safety checks for feedId
        let predicates = [
            NSPredicate(format: "feedId == %@", feedId),
            NSPredicate(format: "feedId != nil"),
            NSPredicate(format: "feedId != ''")
        ]
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        print("🔍 CORE DATA QUERY (Prioritized): Fetching episodes for feedId '\(feedId)'")
        
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
                    let allEpisodes = self.convertToEpisodes(managedEpisodes, feedId: feedId)
                    
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
        
        // CRITICAL CONTAMINATION PREVENTION: Build strict predicate with multiple safety checks
        var predicates = [
            NSPredicate(format: "feedId == %@", feedId),
            NSPredicate(format: "feedId != nil"),
            NSPredicate(format: "feedId != ''")
        ]
        
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(
                format: "title CONTAINS[cd] %@ OR descriptionText CONTAINS[cd] %@",
                query, query
            ))
        }
        
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
        
        // CONTAMINATION PREVENTION: Log query details for debugging
        print("🔍 CORE DATA QUERY (Base): feedId=\(feedId), searchQuery=\(searchQuery ?? "none")")
        
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
    
    private func convertToEpisodesAcrossFeeds(_ managedEpisodes: [PodcastModel]) -> [PodcastEpisode] {
        // PERFORMANCE: Early exit for empty arrays
        guard !managedEpisodes.isEmpty else { return [] }
        
        // BATCH OPTIMIZATION: Get all episode IDs at once for batch state lookup
        let episodeIds = managedEpisodes.compactMap { $0.id }
        
        // BATCH STATE LOADING: Get all episode states in one operation
        let episodeStatesData = EpisodeStateManager.shared.getBatchEpisodeData(for: episodeIds)
        let isCloudKitPriorityMode = EpisodeStateManager.shared.isCloudKitPriorityMode()
        
        // PARALLEL PROCESSING: Use concurrent map for conversion
        let convertedEpisodes: [PodcastEpisode] = managedEpisodes.compactMap { managedEpisode -> PodcastEpisode? in
            guard let episodeId = managedEpisode.id else { return nil }
            
            var episode = managedEpisode.toPodcastEpisode()
            
            // CROSS-FEED SEARCH: No feedId validation since we're searching across all feeds
            // Just validate episode has required fields
            guard !episode.feedId.isEmpty,
                  !episode.id.isEmpty,
                  !episode.title.isEmpty else {
                print("🚨 INVALID EPISODE DATA: Episode missing required fields - ID=\(episode.id), Title=\(episode.title), FeedId=\(episode.feedId)")
                return nil
            }
            
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
                // CloudKit data takes priority - use immediately
                finalProgress = stateData.progress
                finalState = stateData.state
                finalFavorite = stateData.isFavorite
                finalDownloaded = stateData.isDownloaded
            } else {
                // Use Core Data with EpisodeStateManager fallback
                finalProgress = max(coreDataProgress, stateData.progress) // Always take highest progress
                finalState = coreDataProgress > 0.01 ? (episode.state.isPlayed ? .played : .inProgress) : stateData.state
                finalFavorite = episode.state.isFavorite || stateData.isFavorite
                finalDownloaded = episode.state.isDownloaded || stateData.isDownloaded
            }
            
            // Create optimized EpisodeState
            episode.state = EpisodeState(
                isPlayed: finalState == .played,
                isFavorite: finalFavorite,
                progress: finalProgress,
                isDownloaded: finalDownloaded
            )
            
            return episode
        }
        
        return convertedEpisodes
    }
    
    private func convertToEpisodes(_ managedEpisodes: [PodcastModel], feedId: String) -> [PodcastEpisode] {
        // PERFORMANCE: Early exit for empty arrays
        guard !managedEpisodes.isEmpty else { return [] }
        
        // BATCH OPTIMIZATION: Get all episode IDs at once for batch state lookup
        let episodeIds = managedEpisodes.compactMap { $0.id }
        
        // BATCH STATE LOADING: Get all episode states in one operation
        let episodeStatesData = EpisodeStateManager.shared.getBatchEpisodeData(for: episodeIds)
        let isCloudKitPriorityMode = EpisodeStateManager.shared.isCloudKitPriorityMode()
        
        // PARALLEL PROCESSING: Use concurrent map for conversion
        let convertedEpisodes: [PodcastEpisode] = managedEpisodes.compactMap { managedEpisode in
            guard let episodeId = managedEpisode.id else { return nil }
            
            var episode = managedEpisode.toPodcastEpisode()
            
            // ENHANCED CONTAMINATION PREVENTION: Multi-layer validation
            if episode.feedId != feedId {
                print("🚨 CORE DATA CONTAMINATION: Episode '\(episode.title)' has feedId '\(episode.feedId)' but query was for '\(feedId)'")
                print("🚨 CONTAMINATION DETAILS: EpisodeID=\(episode.id), AudioURL=\(episode.audioUrl)")
                
                // CRITICAL: Report contamination to crash reporting or analytics
                // This should never happen if Core Data queries are working correctly
                assertionFailure("Episode contamination detected - this indicates a critical data integrity issue")
                return nil // Filter out contaminated episodes
            }
            
            // ADDITIONAL VALIDATION: Check episode ID integrity for deterministic IDs
            if episode.id.hasPrefix("det_f") {
                let expectedFeedHash = abs(feedId.lowercased().hashValue)
                let expectedPrefix = "det_f\(expectedFeedHash)_"
                if !episode.id.hasPrefix(expectedPrefix) {
                    print("🚨 EPISODE ID CONTAMINATION: Episode '\(episode.title)' has ID '\(episode.id)' that doesn't match feed hash pattern for feed '\(feedId)'")
                    
                    // CORRECTIVE ACTION: Regenerate proper episode ID
                    var correctedEpisode = episode
                    correctedEpisode.id = PodcastEpisode.generateDeterministicID(
                        title: episode.title,
                        audioUrl: episode.audioUrl,
                        publicationDate: episode.publicationDate,
                        feedUrl: feedId
                    )
                    correctedEpisode.feedId = feedId // Ensure feedId is correct
                    print("🔧 EPISODE ID CORRECTION: Corrected episode ID from '\(episode.id)' to '\(correctedEpisode.id)'")
                    episode = correctedEpisode
                }
            }
            
            // ADDITIONAL SAFETY: Validate episode has required fields
            guard !episode.feedId.isEmpty,
                  !episode.id.isEmpty,
                  !episode.title.isEmpty else {
                print("🚨 INVALID EPISODE DATA: Episode missing required fields - ID=\(episode.id), Title=\(episode.title), FeedId=\(episode.feedId)")
                return nil
            }
            
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
        
        print("🔍 EPISODE MANAGER: Converted \(convertedEpisodes.count) episodes for feedId '\(feedId)'")
        return convertedEpisodes
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
            let episodes = convertToEpisodes(managedEpisodes, feedId: feedId)
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

// MARK: - Persistent Cache Manager

actor PodcastCacheManager {
    private var episodeCache: [String: EpisodeLoadResult] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheTimeout: TimeInterval = 300 // 5 minutes
    private let maxCacheSize = 50 // Maximum cached results
    
    // PERSISTENT EPISODE CACHE: Always load from cache, never timeout
    private var persistentEpisodeCache: [String: [PodcastEpisode]] = [:]
    private var persistentCacheTimestamps: [String: Date] = [:]
    private var feedEpisodeCounts: [String: Int] = [:] // Track episode counts for new episode detection
    
    /// INSTANT CACHE: Always return cached episodes immediately, never timeout
    func getCachedEpisodes(
        feedId: String,
        page: Int,
        pageSize: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async -> EpisodeLoadResult? {
        // PERSISTENT CACHE: Check for full episode list first (for instant loading)
        if filter == .all && searchQuery == nil && page == 1 {
            if let allEpisodes = persistentEpisodeCache[feedId], !allEpisodes.isEmpty {
                let paginatedEpisodes = Array(allEpisodes.prefix(pageSize))
                let hasMore = allEpisodes.count > pageSize
                return EpisodeLoadResult(episodes: paginatedEpisodes, hasMore: hasMore, totalCount: allEpisodes.count)
            }
        }
        
        // Fallback to regular cache with timeout
        let key = cacheKey(feedId: feedId, page: page, filter: filter, searchQuery: searchQuery)
        
        guard let timestamp = cacheTimestamps[key],
              Date().timeIntervalSince(timestamp) < cacheTimeout,
              let cachedResult = episodeCache[key] else {
            return nil
        }
        
        return cachedResult
    }
    
    /// PERSISTENT CACHE: Store episodes permanently with new episode detection
    func cacheEpisodes(
        _ result: EpisodeLoadResult,
        for feedId: String,
        page: Int,
        filter: EpisodeFilter,
        searchQuery: String?
    ) async {
        // PERSISTENT CACHE: Store full episode list for instant future access
        if filter == .all && searchQuery == nil && page == 1 {
            let previousCount = feedEpisodeCounts[feedId] ?? 0
            let currentCount = result.totalCount
            
            // Store the full episode list persistently
            persistentEpisodeCache[feedId] = result.episodes
            persistentCacheTimestamps[feedId] = Date()
            feedEpisodeCounts[feedId] = currentCount
            
            // Log new episode detection
            if currentCount > previousCount {
                let newEpisodeCount = currentCount - previousCount
                print("🆕 PERSISTENT CACHE: Detected \(newEpisodeCount) new episodes for feed \(feedId) (\(previousCount) -> \(currentCount))")
            }
        }
        
        // Regular cache with timeout for filtered results
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
    
    // PERFORMANCE: Throttle cache clearing per feed to prevent excessive operations
    private var lastCacheClearTime: [String: Date] = [:]
    private let cacheClearThrottleInterval: TimeInterval = 2.0 // 2 seconds minimum between cache clears per feed
    
    /// SMART CACHE CLEARING: Only clear when new episodes are detected and no snapshots are available
    func clearCacheForFeed(_ feedId: String) async {
        // CRITICAL PERFORMANCE: Skip cache clearing entirely to prevent CPU spikes
        // Snapshots handle data consistency automatically, making cache clearing unnecessary
        print("⚡ PERFORMANCE: Skipping cache clear for feed \(feedId) - snapshots handle consistency")
        return
        
        // NOTE: Original cache clearing logic preserved but disabled for performance
        /*
        let now = Date()
        let lastClearTime = lastCacheClearTime[feedId] ?? Date.distantPast
        
        // PERFORMANCE: Throttle cache clearing to prevent excessive operations during batch updates
        guard now.timeIntervalSince(lastClearTime) >= cacheClearThrottleInterval else {
            return
        }
        
        lastCacheClearTime[feedId] = now
        
        // Clear regular cache
        let keysToRemove = episodeCache.keys.filter { $0.hasPrefix(feedId) }
        for key in keysToRemove {
            episodeCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
        }
        
        // PERSISTENT CACHE: Only clear if explicitly requested (rare)
        // Normally we keep persistent cache and just update it
        print("🧽 CACHE CLEAR: Cleared regular cache for feed \(feedId), persistent cache retained")
        */
    }
    
    /// Force clear persistent cache (only use when feed is deleted or corrupted)
    func clearPersistentCacheForFeed(_ feedId: String) async {
        persistentEpisodeCache.removeValue(forKey: feedId)
        persistentCacheTimestamps.removeValue(forKey: feedId)
        feedEpisodeCounts.removeValue(forKey: feedId)
        print("⚠️ PERSISTENT CACHE: Force cleared for feed \(feedId)")
    }
    
    func clearAllCache() async {
        episodeCache.removeAll()
        cacheTimestamps.removeAll()
        // Keep persistent cache unless explicitly cleared
        print("🧽 CACHE CLEAR: Cleared regular cache, persistent cache retained")
    }
    
    /// Check if feed has cached episodes available for instant loading
    func hasCachedEpisodes(feedId: String) async -> Bool {
        return persistentEpisodeCache[feedId] != nil
    }
    
    /// Get episode count from cache without loading episodes
    func getCachedEpisodeCount(feedId: String) async -> Int? {
        return feedEpisodeCounts[feedId]
    }
    
    /// Update persistent cache with new episodes (merge, don't replace)
    func updateCacheWithNewEpisodes(_ newEpisodes: [PodcastEpisode], for feedId: String) async {
        guard !newEpisodes.isEmpty else { return }
        
        if var existingEpisodes = persistentEpisodeCache[feedId] {
            // Merge new episodes with existing ones, avoiding duplicates
            let existingIds = Set(existingEpisodes.map { $0.id })
            let uniqueNewEpisodes = newEpisodes.filter { !existingIds.contains($0.id) }
            
            if !uniqueNewEpisodes.isEmpty {
                // Add new episodes at the beginning (newest first)
                existingEpisodes.insert(contentsOf: uniqueNewEpisodes, at: 0)
                
                // Sort by publication date (newest first)
                existingEpisodes.sort { $0.publicationDate > $1.publicationDate }
                
                persistentEpisodeCache[feedId] = existingEpisodes
                persistentCacheTimestamps[feedId] = Date()
                feedEpisodeCounts[feedId] = existingEpisodes.count
                
                print("🆕 PERSISTENT CACHE: Added \(uniqueNewEpisodes.count) new episodes to cache for feed \(feedId) (total: \(existingEpisodes.count))")
            }
        } else {
            // No existing cache, create new one
            let sortedEpisodes = newEpisodes.sorted { $0.publicationDate > $1.publicationDate }
            persistentEpisodeCache[feedId] = sortedEpisodes
            persistentCacheTimestamps[feedId] = Date()
            feedEpisodeCounts[feedId] = sortedEpisodes.count
            
            print("🆕 PERSISTENT CACHE: Created new cache for feed \(feedId) with \(sortedEpisodes.count) episodes")
        }
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
                    let episodes = self.convertToEpisodes(managedEpisodes, feedId: feedId)
                    
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