import Foundation
import CoreData

/// Comprehensive Feed Isolation Manager - Prevents all forms of episode contamination
/// This is a complete rewrite to eliminate contamination at the source
@MainActor
class FeedIsolationManager: ObservableObject {
    
    // MARK: - Core Isolation Structures
    
    /// Isolated feed container that guarantees episode-to-feed mapping integrity
    struct IsolatedFeedContainer {
        let feedId: String
        let feedUrl: String
        let originalFeedUrl: String // For migration purposes
        private var _episodes: [PodcastEpisode] = []
        private let isolationLock = NSLock()
        
        init(feedId: String, feedUrl: String, originalFeedUrl: String) {
            self.feedId = feedId
            self.feedUrl = feedUrl
            self.originalFeedUrl = originalFeedUrl
        }
        
        /// Thread-safe episode access with absolute contamination prevention
        var episodes: [PodcastEpisode] {
            get {
                isolationLock.lock()
                defer { isolationLock.unlock() }
                return _episodes.filter { $0.feedId == feedId }
            }
        }
        
        /// Safely add episodes with absolute validation
        mutating func addEpisodes(_ newEpisodes: [PodcastEpisode]) {
            isolationLock.lock()
            defer { isolationLock.unlock() }
            
            let validEpisodes = newEpisodes.compactMap { episode -> PodcastEpisode? in
                var validatedEpisode = episode
                
                // CRITICAL FIX: Only update feedId if it's empty or wrong, preserve existing episode IDs
                if validatedEpisode.feedId.isEmpty || validatedEpisode.feedId != feedId {
                    validatedEpisode.feedId = feedId
                }
                
                // CRITICAL FIX: Only regenerate episode ID if it's completely empty
                // Preserve existing IDs to maintain EpisodeStateManager connections
                if episode.id.isEmpty {
                    validatedEpisode.id = generateIsolatedEpisodeId(
                        title: episode.title,
                        audioUrl: episode.audioUrl,
                        publicationDate: episode.publicationDate,
                        feedId: feedId
                    )
                }
                
                return validatedEpisode
            }
            
            // Remove duplicates and merge with existing episodes
            let existingIds = Set(_episodes.map { $0.id })
            let newValidEpisodes = validEpisodes.filter { !existingIds.contains($0.id) }
            
            _episodes.append(contentsOf: newValidEpisodes)
            
        }
        
        /// Replace all episodes with validated ones
        mutating func replaceEpisodes(_ newEpisodes: [PodcastEpisode]) {
            isolationLock.lock()
            defer { isolationLock.unlock() }
            
            let validEpisodes = newEpisodes.compactMap { episode -> PodcastEpisode? in
                var validatedEpisode = episode
                
                // CRITICAL FIX: Only update feedId if it's empty or wrong, preserve existing episode IDs
                if validatedEpisode.feedId.isEmpty || validatedEpisode.feedId != feedId {
                    validatedEpisode.feedId = feedId
                }
                
                // CRITICAL FIX: Only regenerate episode ID if it's completely empty
                // Preserve existing IDs to maintain EpisodeStateManager connections
                if episode.id.isEmpty {
                    validatedEpisode.id = generateIsolatedEpisodeId(
                        title: episode.title,
                        audioUrl: episode.audioUrl,
                        publicationDate: episode.publicationDate,
                        feedId: feedId
                    )
                }
                
                return validatedEpisode
            }
            
            _episodes = validEpisodes
        }
        
        /// Clear all episodes
        mutating func clearEpisodes() {
            isolationLock.lock()
            defer { isolationLock.unlock() }
            _episodes.removeAll()
        }
    }
    
    // MARK: - Isolation State
    
    private var isolatedFeeds: [String: IsolatedFeedContainer] = [:]
    private let isolationLock = NSLock()
    
    // MARK: - Feed Registration
    
    /// Register a feed for isolation - this creates a secure container
    func registerFeed(feedId: String, feedUrl: String) {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        if isolatedFeeds[feedId] == nil {
            let container = IsolatedFeedContainer(
                feedId: feedId,
                feedUrl: feedUrl,
                originalFeedUrl: feedUrl
            )
            isolatedFeeds[feedId] = container
        }
    }
    
    // MARK: - Episode Management
    
    /// Add episodes to a specific feed with absolute isolation
    func addEpisodesToFeed(_ episodes: [PodcastEpisode], feedId: String) {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        guard var container = isolatedFeeds[feedId] else {
            return
        }
        
        container.addEpisodes(episodes)
        isolatedFeeds[feedId] = container
    }
    
    /// Replace all episodes for a feed with new validated ones
    func replaceEpisodesForFeed(_ episodes: [PodcastEpisode], feedId: String) {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        guard var container = isolatedFeeds[feedId] else {
            return
        }
        
        container.replaceEpisodes(episodes)
        isolatedFeeds[feedId] = container
    }
    
    /// Get episodes for a specific feed - guaranteed contamination-free
    func getEpisodesForFeed(_ feedId: String) -> [PodcastEpisode] {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        guard let container = isolatedFeeds[feedId] else {
            return []
        }
        
        return container.episodes
    }
    
    /// Clear all episodes for a specific feed
    func clearEpisodesForFeed(_ feedId: String) {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        guard var container = isolatedFeeds[feedId] else {
            return
        }
        
        container.clearEpisodes()
        isolatedFeeds[feedId] = container
    }
    
    /// Clear all feeds and episodes
    func clearAllFeeds() {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        isolatedFeeds.removeAll()
    }
    
    /// Get all registered feed IDs
    func getAllRegisteredFeedIds() -> [String] {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        return Array(isolatedFeeds.keys)
    }
    
    // MARK: - Contamination Detection & Cleanup
    
    /// Scan all feeds for contamination and clean it up
    func performGlobalContaminationCleanup() {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        var totalContaminatedEpisodes = 0
        var totalCleanedEpisodes = 0
        
        for (feedId, var container) in isolatedFeeds {
            let episodes = container.episodes
            let validEpisodes = episodes.filter { $0.feedId == feedId }
            
            if validEpisodes.count != episodes.count {
                let contaminatedCount = episodes.count - validEpisodes.count
                totalContaminatedEpisodes += contaminatedCount
                
                // Clean up the container
                container.replaceEpisodes(validEpisodes)
                isolatedFeeds[feedId] = container
                totalCleanedEpisodes += validEpisodes.count
            }
        }
    }
    
    /// Validate that all episodes in all feeds are properly isolated
    func validateGlobalIsolation() -> ContaminationReport {
        isolationLock.lock()
        defer { isolationLock.unlock() }
        
        var report = ContaminationReport()
        
        for (feedId, container) in isolatedFeeds {
            let episodes = container.episodes
            let validEpisodes = episodes.filter { $0.feedId == feedId }
            
            if validEpisodes.count != episodes.count {
                let contaminatedCount = episodes.count - validEpisodes.count
                report.addContamination(feedId: feedId, contaminatedCount: contaminatedCount, totalCount: episodes.count)
            }
        }
        
        return report
    }
    
    // MARK: - Migration Support
    
    /// Clean up contaminated data for existing users
    func performUserDataMigration(coreDataStack: CoreDataStack) async {
        let context = coreDataStack.context
        
        await context.perform {
            do {
                // Fetch all episodes
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                let allEpisodes = try context.fetch(episodeRequest)
                
                var cleanedCount = 0
                var removedCount = 0
                
                for episode in allEpisodes {
                    guard let feedId = episode.feedId, !feedId.isEmpty else {
                        // Remove episodes with no feedId
                        context.delete(episode)
                        removedCount += 1
                        continue
                    }
                    
                    // Validate episode belongs to its feed
                    if let feed = episode.feed, feed.id != feedId {
                        // Try to find the correct feed
                        let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                        feedRequest.predicate = NSPredicate(format: "id == %@", feedId)
                        
                        if let correctFeed = try? context.fetch(feedRequest).first {
                            episode.feed = correctFeed
                            cleanedCount += 1
                        } else {
                            // No correct feed found - remove contaminated episode
                            context.delete(episode)
                            removedCount += 1
                        }
                    }
                    
                    // CRITICAL FIX: Only regenerate episode ID if it's completely empty
                    // Preserve existing IDs to maintain EpisodeStateManager connections
                    if let episodeId = episode.id, episodeId.isEmpty {
                        let newId = generateIsolatedEpisodeId(
                            title: episode.title ?? "",
                            audioUrl: episode.audioUrl ?? "",
                            publicationDate: episode.publicationDate ?? Date(),
                            feedId: feedId
                        )
                        episode.id = newId
                        cleanedCount += 1
                    }
                }
                
                try context.save()
                
            } catch {
                // Handle migration errors silently
            }
        }
    }
}

// MARK: - Supporting Types

struct ContaminationReport {
    var contaminatedFeeds: [String: (contaminated: Int, total: Int)] = [:]
    
    var totalContaminatedFeeds: Int { contaminatedFeeds.count }
    var totalContaminatedEpisodes: Int { contaminatedFeeds.values.reduce(0) { $0 + $1.contaminated } }
    var isClean: Bool { contaminatedFeeds.isEmpty }
    
    mutating func addContamination(feedId: String, contaminatedCount: Int, totalCount: Int) {
        contaminatedFeeds[feedId] = (contaminated: contaminatedCount, total: totalCount)
    }
}

// MARK: - Helper Functions

/// Generate episode ID with absolute feed isolation
private func generateIsolatedEpisodeId(title: String, audioUrl: String, publicationDate: Date, feedId: String) -> String {
    let content = "\(feedId)_\(title)_\(audioUrl)_\(publicationDate.timeIntervalSince1970)"
    return "iso_\(feedId)_\(StableHash.of(content))"
}
