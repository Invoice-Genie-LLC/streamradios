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
        
        // Load from Core Data
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
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        os_log("⚡ Loaded %d episodes in %.3f seconds (filter: %@, cached: %@)", log: log, type: .info, result.episodes.count, filter.displayName, shouldUseCache ? "yes" : "no")
        
        return result
    }
    
    /// Clear cache for a feed when episode states change
    func clearCacheForFeed(_ feedId: String) async {
        await cacheManager.clearCacheForFeed(feedId)
    }
    
    /// Clear all cache - useful for debugging
    func clearAllCache() async {
        await cacheManager.clearAllCache()
    }
    
    /// Clean up duplicate episodes in Core Data
    func cleanupDuplicateEpisodes() async throws {
        os_log("🧹 Starting cleanup of duplicate episodes in Core Data", log: log, type: .info)
        
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
                    
                    for episode in allEpisodes {
                        guard let episodeId = episode.id else {
                            // Delete episodes without IDs
                            duplicatesToDelete.append(episode)
                            continue
                        }
                        
                        if seenIds.contains(episodeId) {
                            // This is a duplicate, mark for deletion
                            duplicatesToDelete.append(episode)
                            os_log("🗑️ Marking duplicate episode for deletion: %@", log: self.log, type: .debug, episodeId)
                        } else {
                            seenIds.insert(episodeId)
                        }
                    }
                    
                    // Delete duplicates
                    for duplicate in duplicatesToDelete {
                        backgroundContext.delete(duplicate)
                    }
                    
                    if !duplicatesToDelete.isEmpty {
                        try backgroundContext.save()
                        os_log("✅ Cleaned up %d duplicate episodes", log: self.log, type: .info, duplicatesToDelete.count)
                    } else {
                        os_log("✅ No duplicate episodes found", log: self.log, type: .info)
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
        
        // Performance optimizations
        fetchRequest.fetchBatchSize = min(pageSize, batchSize)
        fetchRequest.includesPropertyValues = true
        fetchRequest.returnsObjectsAsFaults = false
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
        
        // Performance optimizations
        fetchRequest.fetchBatchSize = batchSize
        fetchRequest.includesPropertyValues = true
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.relationshipKeyPathsForPrefetching = ["feed"]
        
        return fetchRequest
    }
    
    private func convertToEpisodes(_ managedEpisodes: [PodcastModel]) -> [PodcastEpisode] {
        return managedEpisodes.compactMap { managedEpisode in
            var episode = managedEpisode.toPodcastEpisode()
            
            // Sync with EpisodeStateManager for latest state (source of truth)
            let stateManagerProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
            let stateManagerFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            let stateManagerDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            
            // Use EpisodeStateManager as the source of truth for all states
            episode.state.progress = stateManagerProgress
            episode.state.isFavorite = stateManagerFavorite
            episode.state.isDownloaded = stateManagerDownloaded
            
            // Determine isPlayed based on progress
            episode.state.isPlayed = stateManagerProgress >= 0.99
            

            
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