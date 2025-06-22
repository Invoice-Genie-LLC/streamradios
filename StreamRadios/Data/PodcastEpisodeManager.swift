import Foundation
import CoreData
import os.log

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
        
        // Try cache first
        if let cachedResult = await cacheManager.getCachedEpisodes(
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
        
        // Cache the result
        await cacheManager.cacheEpisodes(result, for: feedId, page: page, filter: filter, searchQuery: searchQuery)
        
        let endTime = CFAbsoluteTimeGetCurrent()
        os_log("⚡ Loaded %d episodes in %.3f seconds", log: log, type: .info, result.episodes.count, endTime - startTime)
        
        return result
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
                    let episodeDict = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id!, $0) })
                    
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
                    
                    // Clear relevant caches
                    let feedIds = Set(episodes.compactMap { $0.feedId })
                    for feedId in feedIds {
                        await self.cacheManager.clearCacheForFeed(feedId)
                    }
                    
                    continuation.resume()
                    
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
                    // Build optimized fetch request
                    let fetchRequest = self.buildFetchRequest(
                        feedId: feedId,
                        page: page,
                        pageSize: pageSize,
                        filter: filter,
                        searchQuery: searchQuery
                    )
                    
                    // Fetch episodes
                    let managedEpisodes = try backgroundContext.fetch(fetchRequest)
                    
                    // Convert to domain models efficiently in batch
                    let episodes = self.convertToEpisodes(managedEpisodes)
                    
                    // Get total count efficiently
                    let totalCount = try self.getTotalCount(
                        feedId: feedId,
                        filter: filter,
                        searchQuery: searchQuery,
                        in: backgroundContext
                    )
                    
                    let hasMore = totalCount > (page * pageSize)
                    
                    let result = EpisodeLoadResult(
                        episodes: episodes,
                        hasMore: hasMore,
                        totalCount: totalCount
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
    
    private func convertToEpisodes(_ managedEpisodes: [PodcastModel]) -> [PodcastEpisode] {
        return managedEpisodes.compactMap { managedEpisode in
            var episode = managedEpisode.toPodcastEpisode()
            
            // Sync with EpisodeStateManager for latest progress
            episode.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            episode.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            episode.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            episode.state.isPlayed = managedEpisode.isPlayed
            
            return episode
        }
    }
    
    private func getTotalCount(
        feedId: String,
        filter: EpisodeFilter,
        searchQuery: String?,
        in context: NSManagedObjectContext
    ) throws -> Int {
        
        let countRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        
        // Build same predicate as fetch request (without pagination)
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
        
        countRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        countRequest.includesSubentities = false
        
        return try context.count(for: countRequest)
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
            await evictOldestCacheEntry()
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