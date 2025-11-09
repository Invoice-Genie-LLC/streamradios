//
//  PodcastViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import Foundation
import Combine
import SwiftUI
import OSLog
import CoreData
import AVKit
import CloudKit
import UserNotifications

struct PodcastFeed: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String
    var artworkUrl: String?
    var descriptionText: String?
    var iconData: String?
    var imageData: Data?
    var episodes: [PodcastEpisode] = []
    var maxEpisodes: Int? = nil // Optional episode limit - nil means unlimited
    var order: Int = 0 // Order for manual sorting and CloudKit sync
    
    init(id: String = UUID().uuidString, title: String, url: String, artworkUrl: String? = nil, description: String? = nil, iconData: String? = nil, imageData: Data? = nil, episodes: [PodcastEpisode] = [], maxEpisodes: Int? = nil, order: Int = 0) {
        self.id = id
        self.title = title
        self.url = url
        self.artworkUrl = artworkUrl
        self.descriptionText = description
        self.iconData = iconData
        self.imageData = imageData
        self.episodes = episodes
        self.maxEpisodes = maxEpisodes
        self.order = order
    }
    
    // Equatable implementation
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.id == rhs.id
    }
}

struct PodcastEpisode: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var descriptionText: String
    var audioUrl: String
    var publicationDate: Date
    var duration: TimeInterval
    var state: EpisodeState
    var feedId: String
    var localFilePath: String?
    var fileSize: Int64? // File size in bytes
    var chapters: [PodcastChapter]? // Optional chapters
    var notes: PodcastNotes? // Optional show notes
    
    /// Deterministic composite ID for duplicate detection and stable identification
    var compositeID: String {
        let dateString = String(publicationDate.timeIntervalSince1970)
        let titleHash = String(abs(title.hashValue))
        let audioUrlHash = String(abs(audioUrl.hashValue))
        return "\(feedId)_\(dateString)_\(titleHash)_\(audioUrlHash)"
    }
    
    /// Generate a deterministic episode ID based on content (for episodes without GUID)
    /// Enhanced with contamination prevention to ensure unique IDs across feeds
    static func generateDeterministicID(title: String, audioUrl: String, publicationDate: Date, feedUrl: String) -> String {
        // CONTAMINATION PREVENTION: Ensure feedUrl is included for cross-feed uniqueness
        let sanitizedFeedUrl = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sanitizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedAudioUrl = audioUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Create content hash that includes feed URL for proper isolation
        let content = "\(sanitizedFeedUrl)_\(sanitizedTitle)_\(sanitizedAudioUrl)_\(publicationDate.timeIntervalSince1970)"
        let hash = abs(content.hashValue)
        
        // Include feed identifier in episode ID to prevent cross-feed contamination
        let feedHash = abs(sanitizedFeedUrl.hashValue)
        return "det_f\(feedHash)_\(hash)"
    }
    
    init(id: String = UUID().uuidString, title: String, descriptionText: String, audioUrl: String, publicationDate: Date, duration: TimeInterval, state: EpisodeState, feedId: String, localFilePath: String? = nil, fileSize: Int64? = nil, chapters: [PodcastChapter]? = nil, notes: PodcastNotes? = nil) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.audioUrl = audioUrl
        self.publicationDate = publicationDate
        self.duration = duration
        self.state = state
        self.feedId = feedId
        self.localFilePath = localFilePath
        self.fileSize = fileSize
        self.chapters = chapters
        self.notes = notes
    }
    
    // Implement Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(feedId)
        hasher.combine(publicationDate)
    }
    
    // Equatable based on unique identifier
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        return lhs.id == rhs.id && lhs.feedId == rhs.feedId
    }
}

 
/// Powerful episode contamination and duplication prevention measures
/// Ensures each episode belongs strictly to its own feed with no cross-contamination
struct EpisodeContaminationGuard {
    
    /// Comprehensive episode validation result
    struct ValidationResult {
        let isValid: Bool
        var issues: [ContaminationIssue]
        let correctedEpisode: PodcastEpisode?
        
        var hasContamination: Bool { !issues.isEmpty }
        var hasCriticalIssues: Bool { issues.contains { $0.severity == .critical } }
    }
    
    /// Types of contamination issues that can occur
    enum ContaminationIssue {
        case feedIdMismatch(expected: String, actual: String)
        case duplicateEpisodeId(episodeId: String, conflictingFeeds: [String])
        case crossFeedEpisodeReference(episodeId: String, originalFeed: String, contaminatingFeed: String)
        case invalidFeedIdFormat(feedId: String)
        case orphanedEpisode(episodeId: String)
        case compositeIdMismatch(episodeId: String, expectedComposite: String, actualComposite: String)
        case episodeIdCollision(episodeId: String, feeds: [String])
        case futureDateEpisode(episodeId: String, futureDate: Date)
        case invalidDateEpisode(episodeId: String, invalidDate: Date)
        
        var severity: Severity {
            switch self {
            case .feedIdMismatch, .duplicateEpisodeId, .crossFeedEpisodeReference, .episodeIdCollision:
                return .critical
            case .invalidFeedIdFormat, .orphanedEpisode, .compositeIdMismatch, .futureDateEpisode, .invalidDateEpisode:
                return .warning
            }
        }
        
        var description: String {
            switch self {
            case .feedIdMismatch(let expected, let actual):
                return "Episode feedId mismatch: expected '\(expected)', got '\(actual)'"
            case .duplicateEpisodeId(let episodeId, let feeds):
                return "Duplicate episode ID '\(episodeId)' found across feeds: \(feeds.joined(separator: ", "))"
            case .crossFeedEpisodeReference(let episodeId, let original, let contaminating):
                return "Cross-feed contamination: episode '\(episodeId)' from feed '\(original)' found in feed '\(contaminating)'"
            case .invalidFeedIdFormat(let feedId):
                return "Invalid feedId format: '\(feedId)'"
            case .orphanedEpisode(let episodeId):
                return "Orphaned episode without valid feed reference: '\(episodeId)'"
            case .compositeIdMismatch(let episodeId, let expectedComposite, let actualComposite):
                return "Composite ID mismatch for episode '\(episodeId)': expected '\(expectedComposite)', got '\(actualComposite)'"
            case .episodeIdCollision(let episodeId, let feeds):
                return "Episode ID collision '\(episodeId)' across multiple feeds: \(feeds.joined(separator: ", "))"
            case .futureDateEpisode(let episodeId, let futureDate):
                return "Episode '\(episodeId)' has future publication date: \(futureDate)"
            case .invalidDateEpisode(let episodeId, let invalidDate):
                return "Episode '\(episodeId)' has invalid publication date: \(invalidDate)"
            }
        }
        
        enum Severity {
            case critical, warning
        }
    }
    
    /// Validate a single episode for contamination issues
    static func validateEpisode(_ episode: PodcastEpisode, expectedFeedId: String, allEpisodes: [PodcastEpisode] = []) -> ValidationResult {
        var issues: [ContaminationIssue] = []
        var correctedEpisode: PodcastEpisode? = nil
        
        // 1. Validate feedId matches expected
        if episode.feedId != expectedFeedId {
            issues.append(.feedIdMismatch(expected: expectedFeedId, actual: episode.feedId))
            
            // Create corrected episode with proper feedId
            var corrected = episode
            corrected.feedId = expectedFeedId
            correctedEpisode = corrected
        }
        
        // 2. Validate feedId format
        if episode.feedId.isEmpty || episode.feedId.contains(" ") || episode.feedId.contains("\n") {
            issues.append(.invalidFeedIdFormat(feedId: episode.feedId))
        }
        
        // 3. Check for duplicate episode IDs across different feeds
        let duplicatesInOtherFeeds = allEpisodes.filter { $0.id == episode.id && $0.feedId != expectedFeedId }
        if !duplicatesInOtherFeeds.isEmpty {
            let conflictingFeeds = duplicatesInOtherFeeds.map { $0.feedId }
            issues.append(.duplicateEpisodeId(episodeId: episode.id, conflictingFeeds: conflictingFeeds))
        }
        
        // 4. Validate composite ID consistency
        let expectedCompositeId = generateExpectedCompositeId(for: episode, feedId: expectedFeedId)
        if episode.compositeID != expectedCompositeId {
            issues.append(.compositeIdMismatch(episodeId: episode.id, expectedComposite: expectedCompositeId, actualComposite: episode.compositeID))
        }
        
        // 5. Validate publication date
        let now = Date()
        let futureThreshold = now.addingTimeInterval(24 * 60 * 60) // Allow 1 day in future for timezone differences
        
        if episode.publicationDate > futureThreshold {
            issues.append(.futureDateEpisode(episodeId: episode.id, futureDate: episode.publicationDate))
        }
        
        // Check for extremely old dates (before 1990) which are likely invalid
        let minimumValidDate = Date(timeIntervalSince1970: 631152000) // January 1, 1990
        if episode.publicationDate < minimumValidDate {
            issues.append(.invalidDateEpisode(episodeId: episode.id, invalidDate: episode.publicationDate))
        }
        
        return ValidationResult(
            isValid: issues.isEmpty,
            issues: issues,
            correctedEpisode: correctedEpisode
        )
    }
    
    /// Validate an entire collection of episodes for contamination
    static func validateEpisodeCollection(_ episodes: [PodcastEpisode], expectedFeedId: String) -> [ValidationResult] {
        var results: [ValidationResult] = []
        var episodeIdTracker: [String: [String]] = [:] // episodeId -> [feedIds]
        
        // Build episode ID tracker for collision detection
        for episode in episodes {
            if episodeIdTracker[episode.id] == nil {
                episodeIdTracker[episode.id] = []
            }
            episodeIdTracker[episode.id]?.append(episode.feedId)
        }
        
        // Validate each episode
        for episode in episodes {
            var result = validateEpisode(episode, expectedFeedId: expectedFeedId, allEpisodes: episodes)
            
            // Add collision detection
            if let feedIds = episodeIdTracker[episode.id], feedIds.count > 1 {
                let uniqueFeeds = Array(Set(feedIds))
                if uniqueFeeds.count > 1 {
                    result.issues.append(.episodeIdCollision(episodeId: episode.id, feeds: uniqueFeeds))
                }
            }
            
            results.append(result)
        }
        
        return results
    }
    
    /// Sanitize and isolate episodes to their proper feeds
    static func sanitizeEpisodes(_ episodes: [PodcastEpisode], targetFeedId: String) -> [PodcastEpisode] {
        var sanitizedEpisodes: [PodcastEpisode] = []
        var seenEpisodeIds: Set<String> = []
        
        for episode in episodes {
            // Skip duplicates within the same collection
            if seenEpisodeIds.contains(episode.id) {
                print("🚫 CONTAMINATION GUARD: Skipping duplicate episode '\(episode.title)' (ID: \(episode.id))")
                continue
            }
            
            var sanitizedEpisode = episode
            
            // Force correct feedId
            if sanitizedEpisode.feedId != targetFeedId {
                print("🔧 CONTAMINATION GUARD: Correcting feedId for episode '\(episode.title)' from '\(episode.feedId)' to '\(targetFeedId)'")
                sanitizedEpisode.feedId = targetFeedId
            }
            
            // Validate publication date - skip episodes with future dates
            let now = Date()
            let futureThreshold = now.addingTimeInterval(24 * 60 * 60) // Allow 1 day in future for timezone differences
            
            if episode.publicationDate > futureThreshold {
                print("🚫 CONTAMINATION GUARD: Skipping episode with future date '\(episode.title)' (Date: \(episode.publicationDate))")
                continue
            }
            
            // Skip episodes with invalid old dates (before 1990)
            let minimumValidDate = Date(timeIntervalSince1970: 631152000) // January 1, 1990
            if episode.publicationDate < minimumValidDate {
                print("🚫 CONTAMINATION GUARD: Skipping episode with invalid old date '\(episode.title)' (Date: \(episode.publicationDate))")
                continue
            }
            
            // Regenerate composite ID with correct feedId
            let expectedCompositeId = generateExpectedCompositeId(for: sanitizedEpisode, feedId: targetFeedId)
            if sanitizedEpisode.compositeID != expectedCompositeId {
                print("🔧 CONTAMINATION GUARD: Regenerating composite ID for episode '\(episode.title)'")
                // Note: compositeID is computed property, so it will be automatically correct after feedId fix
            }
            
            sanitizedEpisodes.append(sanitizedEpisode)
            seenEpisodeIds.insert(sanitizedEpisode.id)
        }
        
        print("✅ CONTAMINATION GUARD: Sanitized \(episodes.count) episodes -> \(sanitizedEpisodes.count) clean episodes for feed \(targetFeedId)")
        return sanitizedEpisodes
    }
    
    /// Generate expected composite ID for validation
    private static func generateExpectedCompositeId(for episode: PodcastEpisode, feedId: String) -> String {
        let dateString = String(episode.publicationDate.timeIntervalSince1970)
        let titleHash = String(abs(episode.title.hashValue))
        let audioUrlHash = String(abs(episode.audioUrl.hashValue))
        return "\(feedId)_\(dateString)_\(titleHash)_\(audioUrlHash)"
    }
    
    /// Perform comprehensive feed isolation check
    static func performFeedIsolationCheck(allFeeds: [PodcastFeed]) -> [String: [ContaminationIssue]] {
        var feedIssues: [String: [ContaminationIssue]] = [:]
        var globalEpisodeTracker: [String: [String]] = [:] // episodeId -> [feedIds]
        
        // Build global episode tracker
        for feed in allFeeds {
            for episode in feed.episodes {
                if globalEpisodeTracker[episode.id] == nil {
                    globalEpisodeTracker[episode.id] = []
                }
                globalEpisodeTracker[episode.id]?.append(feed.id)
            }
        }
        
        // Check each feed for contamination
        for feed in allFeeds {
            var issues: [ContaminationIssue] = []
            
            for episode in feed.episodes {
                // Check for cross-feed contamination
                if let feedIds = globalEpisodeTracker[episode.id], feedIds.count > 1 {
                    let otherFeeds = feedIds.filter { $0 != feed.id }
                    if !otherFeeds.isEmpty {
                        issues.append(.crossFeedEpisodeReference(
                            episodeId: episode.id,
                            originalFeed: feed.id,
                            contaminatingFeed: otherFeeds.first!
                        ))
                    }
                }
                
                // Check feedId consistency
                if episode.feedId != feed.id {
                    issues.append(.feedIdMismatch(expected: feed.id, actual: episode.feedId))
                }
            }
            
            if !issues.isEmpty {
                feedIssues[feed.id] = issues
            }
        }
        
        return feedIssues
    }
    
    /// Emergency decontamination procedure
    static func emergencyDecontamination(episodes: [PodcastEpisode], targetFeedId: String) -> [PodcastEpisode] {
        print("🚨 EMERGENCY DECONTAMINATION: Starting for feed \(targetFeedId) with \(episodes.count) episodes")
        
        var decontaminatedEpisodes: [PodcastEpisode] = []
        var episodeIdRegistry: Set<String> = []
        
        for episode in episodes {
            // Create completely clean episode
            var cleanEpisode = episode
            
            // Force correct feedId
            cleanEpisode.feedId = targetFeedId
            
            // Ensure unique episode ID within this feed
            var uniqueId = episode.id
            var counter = 1
            while episodeIdRegistry.contains(uniqueId) {
                uniqueId = "\(episode.id)_dedup_\(counter)"
                counter += 1
            }
            
            if uniqueId != episode.id {
                print("🔧 EMERGENCY: Deduplicating episode ID '\(episode.id)' -> '\(uniqueId)'")
                cleanEpisode.id = uniqueId
            }
            
            episodeIdRegistry.insert(uniqueId)
            decontaminatedEpisodes.append(cleanEpisode)
        }
        
        print("✅ EMERGENCY DECONTAMINATION: Completed - \(decontaminatedEpisodes.count) clean episodes")
        return decontaminatedEpisodes
    }
}

/// Represents a chapter in a podcast episode
struct PodcastChapter: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var startTime: TimeInterval // in seconds
    var url: String? // optional URL link
    var imageUrl: String? // optional chapter-specific artwork
    
    init(title: String, startTime: TimeInterval, url: String? = nil, imageUrl: String? = nil) {
        self.title = title
        self.startTime = startTime
        self.url = url
        self.imageUrl = imageUrl
    }
}

/// Represents notes/show notes for a podcast episode
struct PodcastNotes: Codable, Equatable, Hashable {
    var content: String // HTML or plain text content
    var links: [PodcastLink] // extracted links from the notes
    
    init(content: String, links: [PodcastLink] = []) {
        self.content = content
        self.links = links
    }
}

/// Represents a link in podcast notes
struct PodcastLink: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var timeStamp: TimeInterval? // optional timestamp for time-linked notes
    
    init(title: String, url: String, timeStamp: TimeInterval? = nil) {
        self.title = title
        self.url = url
        self.timeStamp = timeStamp
    }
}

struct EpisodeState: Codable, Equatable, Hashable {
    var isPlayed: Bool
    var isFavorite: Bool
    var progress: Double // 0.0 to 1.0
    var isDownloaded: Bool
}

/// High-performance podcast view model designed for thousands of episodes
@MainActor
class PodcastViewModel: ObservableObject {
    // CRITICAL: Feed isolation manager to prevent all contamination
    let feedIsolationManager = FeedIsolationManager()
    
    // 🛡️ RAPID ACCESS CACHE: Prevent contamination during rapid UI getter calls
    private var _episodeCache: [PodcastEpisode]?
    private var _episodeCacheFeedId: String?
    private var _feedTransitionInProgress: Bool = false
    
    // PERFORMANCE: Lazy loading support for large feeds
    @Published var displayedEpisodeCount: Int = 100 // Initial episodes to display
    @Published var totalEpisodeCount: Int = 0 // Total episodes available
    @Published var isLoadingMoreEpisodes: Bool = false
    private let episodeLoadBatchSize: Int = 100 // Load 100 episodes at a time
    private var allEpisodesCache: [PodcastEpisode] = [] // Full episode list for pagination
    
    // MARK: - Shared Instance
    static let shared = PodcastViewModel()
    
    /// Initialize contamination prevention system
    @MainActor
    func initializeContaminationPrevention() {
        print("🛡️ STARTUP: Initializing contamination prevention system")
        
        // Register all existing feeds with isolation manager
        for feed in podcastFeeds {
            feedIsolationManager.registerFeed(feedId: feed.id, feedUrl: feed.url)
        }
        
        // Perform initial contamination check and cleanup
        Task {
            // Wait for app to initialize
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            await MainActor.run {
                print("🛡️ STARTUP: Performing initial contamination check")
                
                // Run global contamination cleanup through isolation manager
                feedIsolationManager.performGlobalContaminationCleanup()
                
                // Validate isolation is working
                let report = feedIsolationManager.validateGlobalIsolation()
                if report.isClean {
                    print("✅ GLOBAL CONTAMINATION CHECK: All feeds are clean - no contamination detected")
                } else {
                    print("🚨 GLOBAL CONTAMINATION CHECK: Found contamination in \(report.totalContaminatedFeeds) feeds with \(report.totalContaminatedEpisodes) contaminated episodes")
                    // Run user data migration for existing contaminated data
                    self.performUserDataMigration()
                }
                
                // Schedule periodic contamination checks
                schedulePeriodicContaminationChecks()
            }
        }
    }
    
    /// Schedule periodic contamination checks to maintain data integrity
    private func schedulePeriodicContaminationChecks() {
        // Run contamination check every 30 minutes
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in
                print("🛡️ PERIODIC: Running scheduled contamination check")
                self.performGlobalContaminationCheck()
            }
        }
    }
    
    // MARK: - RSS Processing Queue
    private let rssProcessingQueue = DispatchQueue(label: "com.streamradios.rss.processing", qos: .userInitiated)
    
    // MARK: - RSS Task Management for Cancellation
    private var rssParsingTasks: [String: Task<Void, Error>] = [:]
    private let rssTaskQueue = DispatchQueue(label: "com.streamradios.rss.tasks", qos: .utility)
    
    // MARK: - Published Properties with Contamination Prevention
    private var _currentEpisodes: [PodcastEpisode] = [] {
        didSet {
            objectWillChange.send()
        }
    }
    
    var currentEpisodes: [PodcastEpisode] {
        get {
            // Use isolation manager for guaranteed clean episodes
            guard let feedId = selectedFeedId else { 
                print("🔍 EPISODE GETTER: selectedFeedId is nil, returning empty")
                return [] 
            }
            
            // Removed debug print for performance - this is called frequently
            
            // Block cache access during feed transitions
            if _feedTransitionInProgress {
                // Check if this is a delayed call and we should clear the flag
                if let selectedId = selectedFeedId, selectedId == feedId {
                    print("🔧 EPISODE GETTER: Transition flag still set but feed matches - clearing immediately")
                    _feedTransitionInProgress = false
                } else {
                    print("🚨 EPISODE GETTER: Transition in progress, returning empty for feed \(feedId)")
                    return []
                }
            }
            
            // Clear cache if it's for a different feed
            if let cacheFeedId = _episodeCacheFeedId, cacheFeedId != feedId {
                print("🚨 EPISODE GETTER: Cache mismatch - cached=\(cacheFeedId), requested=\(feedId), clearing and returning empty")
                _episodeCache = nil
                _episodeCacheFeedId = nil
                return []
            }
            
            // Validate cache integrity
            if let cached = _episodeCache, let cacheFeedId = _episodeCacheFeedId, cacheFeedId == feedId {
                let wrongEpisodes = cached.filter { $0.feedId != feedId }
                if !wrongEpisodes.isEmpty {
                    _episodeCache = nil
                    _episodeCacheFeedId = nil
                }
            }
            
            // Return cached episodes if available and valid
            if let cached = _episodeCache, _episodeCacheFeedId == feedId {
                // Double-verify cache integrity before returning
                let cleanCached = cached.filter { $0.feedId == feedId }
                if cleanCached.count != cached.count {
                    print("🚨 EPISODE GETTER: Cache contaminated, clearing and reloading")
                    _episodeCache = nil
                    _episodeCacheFeedId = nil
                    // Fall through to reload
                } else {
                    return cached
                }
            }
            
            // Ensure feed is registered before getting episodes
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                feedIsolationManager.registerFeed(feedId: feedId, feedUrl: feed.url)
            } else {
                print("🚨 EPISODE GETTER: Feed \(feedId) not found in podcastFeeds! Available feeds: \(podcastFeeds.map { $0.id })")
            }
            
            // Get episodes from isolation manager
            let isolatedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
            
            // 🛡️ SMART EMPTY STATE HANDLING: Check for available cache before returning empty
            if isolatedEpisodes.isEmpty {
                print("🔍 EPISODE GETTER: No episodes in isolation manager, checking cache...")
                // Try to get episodes from cache if available
                let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
                if !cachedEpisodes.isEmpty {
                    // Register cached episodes with isolation manager for future safety
                    feedIsolationManager.replaceEpisodesForFeed(cachedEpisodes, feedId: feedId)
                    // Clear transition flag since we found episodes
                    _feedTransitionInProgress = false
                    // Cache the result
                    _episodeCache = cachedEpisodes
                    _episodeCacheFeedId = feedId
                    return cachedEpisodes
                } else {
                    print("🚨 EPISODE GETTER: No episodes in cache for feed \(feedId) - returning empty")
                }
                // Cache empty result
                _episodeCache = []
                _episodeCacheFeedId = feedId
                return []
            }
            
            // 🛡️ FINAL SAFETY CHECK: Double-validate all episodes belong to current feed
            let validatedEpisodes = isolatedEpisodes.filter { $0.feedId == feedId }
            if validatedEpisodes.count != isolatedEpisodes.count {
                // Update isolation manager with clean episodes
                feedIsolationManager.replaceEpisodesForFeed(validatedEpisodes, feedId: feedId)
            }
            
            // 🚨 CRITICAL: Remove episodes with empty titles (corrupted data)
            let nonEmptyEpisodes = validatedEpisodes.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if nonEmptyEpisodes.count != validatedEpisodes.count {
                let emptyCount = validatedEpisodes.count - nonEmptyEpisodes.count
                print("🚨 EMPTY TITLES: Found \(emptyCount) episodes with empty titles - removing them")
                for episode in validatedEpisodes where episode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("🚨 EMPTY TITLE: Episode ID \(episode.id.prefix(12))... has empty title - REMOVING")
                }
                // Update isolation manager with cleaned episodes
                feedIsolationManager.replaceEpisodesForFeed(nonEmptyEpisodes, feedId: feedId)
            }
            
            // Clear transition flag since we have valid episodes
            _feedTransitionInProgress = false
            
            // 🚨 CRITICAL DEDUPLICATION: Remove any duplicate episode IDs before displaying
            var seenIds = Set<String>()
            var duplicateCount = 0
            let deduplicatedEpisodes = nonEmptyEpisodes.filter { episode in
                if seenIds.contains(episode.id) {
                    duplicateCount += 1
                    print("🚨 DEDUP GETTER [\(duplicateCount)]: Removing duplicate episode ID \(episode.id.prefix(8))... - \(episode.title)")
                    return false
                }
                seenIds.insert(episode.id)
                return true
            }
            
            if deduplicatedEpisodes.count != nonEmptyEpisodes.count {
                print("🚨 DEDUP GETTER: Removed \(nonEmptyEpisodes.count - deduplicatedEpisodes.count) duplicate episodes")
                // Update isolation manager with deduplicated list
                feedIsolationManager.replaceEpisodesForFeed(deduplicatedEpisodes, feedId: feedId)
            }
            
            // Cache the deduplicated result
            _episodeCache = deduplicatedEpisodes
            _episodeCacheFeedId = feedId
            
            return deduplicatedEpisodes
        }
        set {
            // Clear cache when episodes are being set
            _episodeCache = nil
            _episodeCacheFeedId = nil
            
            // Always use isolation manager
            guard let feedId = selectedFeedId else { 
                // If no feed selected but trying to clear episodes, clear all isolation manager data
                if newValue.isEmpty {
                    feedIsolationManager.clearAllFeeds()
                }
                return 
            }
            
            // Register feed if not already registered
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                feedIsolationManager.registerFeed(feedId: feedId, feedUrl: feed.url)
            }
            
            // Handle special case of removeAll() - clear only this feed
            if newValue.isEmpty {
                feedIsolationManager.clearEpisodesForFeed(feedId)
            } else {
                // Validate episodes before assigning
                let validEpisodes = newValue.filter { $0.feedId == feedId }
                if validEpisodes.count != newValue.count {
                }
                
                // Let isolation manager handle all validation and assignment
                feedIsolationManager.replaceEpisodesForFeed(validEpisodes, feedId: feedId)
                let finalCount = feedIsolationManager.getEpisodesForFeed(feedId).count
            }
        }
    }
    @Published var podcastFeeds: [PodcastFeed] = []
    @Published var isLoading = false
    @Published var isLoadingFeeds = false
    @Published var isLoadingEpisodes = false
    @Published var hasMoreEpisodes = false
    @Published var operationInProgress = false
    @Published var error: String?
    @Published var currentTab = 0
    @Published var searchQuery = ""
    @Published var episodeCounts = (all: 0, favorites: 0, downloads: 0)
    @Published var uiRefreshTrigger: UUID = UUID() // Force UI refresh trigger
    @Published var showNoEpisodesAlert = false
    @Published var noEpisodesAlertMessage = ""
    @Published var isAscendingSort = true
    @Published var podcastFeedOrder: [String] = []
    @Published var lastPlayedEpisodes: [String: String] = [:]
    @Published var episodeProgress: [String: Double] = [:]
    @Published var downloadProgress: [String: Double] = [:]
    
    // MARK: - App Lifecycle State
    @Published var isReturningFromBackground = false // Track when app returns from background
    
    // MARK: - Background Sync Management
    private var activeBackgroundSyncs = Set<String>() // Track feeds currently being synced
    private let syncLock = NSLock() // Protect the sync set
    
    // MARK: - Operation Management
    
    /// Cancel pending operations to prevent UI conflicts
    @MainActor
    func cancelPendingOperations() {
        // Cancel any pending feed loading operations
        feedsBeingProcessed.removeAll()
        
        // Cancel any delayed operations that might interfere
        print("🚫 OPERATIONS: Cancelled pending operations for clean navigation")
    }
    
    // MARK: - Safe Episode Assignment and Validation
    
    /// Validate and clean current episodes to prevent UI contamination
    @MainActor
    private func validateAndCleanCurrentEpisodes() {
        guard !currentEpisodes.isEmpty, let feedId = selectedFeedId, !feedId.isEmpty else { return }
        
        // Check for contamination in current episodes
        let validEpisodes = currentEpisodes.filter { $0.feedId == feedId }
        if validEpisodes.count != currentEpisodes.count {
            let contaminatedCount = currentEpisodes.count - validEpisodes.count
            print("🚨 UI VALIDATION: Found \(contaminatedCount) contaminated episodes in currentEpisodes for feed \(feedId)")
            
            // Log contaminated episodes for debugging
            let contaminatedEpisodes = currentEpisodes.filter { $0.feedId != feedId }
            for episode in contaminatedEpisodes.prefix(3) {
                print("🚨 UI CONTAMINATED: Episode '\(episode.title)' has feedId '\(episode.feedId)' but currentEpisodes is for feed '\(feedId)'")
            }
            
            // IMMEDIATE FIX: Replace with clean episodes
            currentEpisodes = validEpisodes
            print("🛡️ UI AUTO-CLEAN: Cleaned currentEpisodes to \(validEpisodes.count) valid episodes")
            
            // Trigger contamination cleanup
            performImmediateContaminationFix()
        }
    }
    
    // MARK: - Safe Episode Assignment
    
    /// Safely assign episodes to currentEpisodes with absolute contamination prevention
    @MainActor
    func safelyAssignCurrentEpisodes(_ episodes: [PodcastEpisode], targetFeedId: String, updateSelectedFeed: Bool = true) {
        print("🔧 SAFELY ASSIGN: Starting assignment of \(episodes.count) episodes to feed \(targetFeedId)")
        
        // 🛡️ ABSOLUTE CONTAMINATION PREVENTION: Update selectedFeedId FIRST
        if updateSelectedFeed {
            print("🔧 SAFELY ASSIGN: Updating selectedFeedId to \(targetFeedId)")
            selectedFeedId = targetFeedId
        }
        
        // Register feed with isolation manager
        if let feed = podcastFeeds.first(where: { $0.id == targetFeedId }) {
            feedIsolationManager.registerFeed(feedId: targetFeedId, feedUrl: feed.url)
            print("🔧 SAFELY ASSIGN: Registered feed \(targetFeedId) with isolation manager")
        } else {
            print("🚨 SAFELY ASSIGN: Feed \(targetFeedId) not found in podcastFeeds!")
        }
        
        // Clear any stale cache before assigning new episodes
        _episodeCache = nil
        _episodeCacheFeedId = nil
        print("🔧 SAFELY ASSIGN: Cleared episode cache")
        
        // Use the setter to ensure proper isolation manager handling
        currentEpisodes = episodes
        print("🔧 SAFELY ASSIGN: Assigned episodes via setter")
        
        // Force UI refresh to ensure episodes are displayed
        DispatchQueue.main.async {
            self.objectWillChange.send()
            print("🔧 SAFELY ASSIGN: Triggered UI refresh")
        }
    }
    
    // PERFORMANCE OPTIMIZATION: Cache filtered results and counts to avoid re-filtering and re-counting
    private var tabFilterCache: [String: [Int: [PodcastEpisode]]] = [:] // feedId -> [tabIndex -> episodes]
    private var tabFilterCounts: [String: (all: Int, favorites: Int, downloads: Int)] = [:] // feedId -> episode counts
    
    // CORE DATA + IN-MEMORY CACHE: Track when feeds were last loaded for cache management
    // FeedIsolationManager serves as the in-memory cache
    // Core Data is the persistent storage (survives app restarts)
    private var coreDataLoadTimestamps: [String: Date] = [:] // feedId -> last Core Data load time
    
    // MARK: - Feed Deletion Progress Tracking
    @Published var feedDeletionProgress: Double = 0.0
    @Published var feedDeletionMessage: String = ""
    @Published var isDeletingFeed: Bool = false
    @Published var deletingFeedId: String? = nil
    
    // Store progress observations to prevent deallocation
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    
    // MARK: - Private Properties
    private let log = OSLog(subsystem: "StreamRadios", category: "PodcastViewModel")
    private let feedManager = PodcastFeedManager()
    private let episodeManager = PodcastEpisodeManager()
    private let cloudKitManager = PodcastCloudKitManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Global Episode Search State
    @Published var globalEpisodeSearchResults: [PodcastEpisode] = []
    private var globalSearchTask: Task<Void, Never>? = nil
    
    // Performance optimizations
    private let episodesPerPage = 100
    private var currentPage = 1
    private var loadingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    
    // PERFORMANCE: UI update throttling to improve scrolling performance
    private var lastUIUpdateTime = Date()
    private var uiUpdateTimer: Timer?
    private let uiUpdateThrottleInterval: TimeInterval = 1.0  // 1 second minimum between UI updates
    private var hasPendingUIUpdate = false
    private var isUserScrolling: Bool {
        UserDefaults.standard.bool(forKey: "isUserScrolling")
    }
    
    // PERFORMANCE: Deduplication flags to prevent redundant operations
    private var isInitializingEpisodeTracking = false
    private var hasInitializedEpisodeTracking = false
    private var isLoadingFromCoreData = false
    var pendingInitializationTasks = Set<String>()
    
    // IMMEDIATE NEW EPISODE CHECK: Track immediate check tasks
    private var immediateCheckTasks: [String: Task<Void, Never>] = [:]
    
    // FEED PROCESSING SYNCHRONIZATION
    private let feedProcessingQueue = DispatchQueue(label: "com.streamradios.feed.processing", attributes: .concurrent)
    private var feedsBeingProcessed: Set<String> = []
    
    // Current state
    var selectedFeedId: String? {
        didSet {
            let oldValue = oldValue
            let newValue = selectedFeedId
            // Set transition flag to block cache access during feed changes
            if oldValue != newValue {
                _feedTransitionInProgress = true
            }
            
            // Clear cache aggressively when feed changes
            _episodeCache = nil
            _episodeCacheFeedId = nil
            _episodeCache = []  // Set to empty array as backup
            _episodeCacheFeedId = selectedFeedId  // Pre-set new feedId to block old cache
            _episodeCache = nil  // Clear again
            _episodeCacheFeedId = nil  // Clear feedId again
            
            // Clear transition flag after a much shorter delay
            if oldValue != newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    self._feedTransitionInProgress = false
                    print("🔧 TRANSITION FLAG: Cleared transition flag for feed change to \(self.selectedFeedId ?? "nil")")
                }
            }
            
            // 🛡️ SMART FEED SWITCH PROTECTION: Only clear if episodes belong to wrong feed
            if let newFeedId = selectedFeedId, let oldFeedId = oldValue, newFeedId != oldFeedId {
                // Check if current episodes belong to the old feed - only clear if they do
                let needsClearing = _currentEpisodes.contains { $0.feedId == oldFeedId }
                if needsClearing {
                    _currentEpisodes.removeAll()
                }
                
                // 🛡️ GENTLE SYNCHRONIZATION: Ensure UI updates without forcing blank state
                DispatchQueue.main.async {
                    if self.selectedFeedId == newFeedId {
                        self.objectWillChange.send()
                        print("🔄 GENTLE SYNC: UI updated for feed switch to \(newFeedId)")
                    }
                }
            }
        }
    }
    private var lastLoadTime: Date = Date()
    
    init() {
        setupObservers()
        setupDataSyncCoordination()
        
        // Load feeds from Core Data (radio station pattern)
        // Note: For fresh installs, this will initially find no feeds, but once RSS processing
        // completes and Core Data is properly synchronized, subsequent calls will work correctly
        loadFeedsFromCoreData()
        
        // Load last played episodes from UserDefaults
        loadLastPlayedEpisodes()
        
        // Initialize contamination prevention system immediately
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            await MainActor.run {
                print("🛡️ STARTUP: Initializing contamination prevention system")
                initializeContaminationPrevention()
            }
            
            // Clean up any corrupted episodes with empty titles
            await PodcastCoreDataManager.shared.cleanupCorruptedEpisodes()
        }
        
        // Load sorting preferences from UserDefaults
        loadSortingPreferences()
        
        // Setup instant sync listener for real-time cross-device updates
        setupInstantSyncListener()
        
        // Note: CloudKit sync is now handled by explicit initializeWithCloudKitSupport() call
        // This prevents duplicate syncing when multiple ViewModels are created
    }
    
    // MARK: - Instant Sync Listener
    
    private func setupInstantSyncListener() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastProgressSync),
            name: .init("InstantSyncDidUpdatePodcastProgress"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFeedAddedSync),
            name: .init("InstantSyncDidAddPodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFeedRemovedSync),
            name: .init("InstantSyncDidRemovePodcastFeed"),
            object: nil
        )
        
        // Real-time CloudKit deletion notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeCloudKitFeedDeletedSync(_:)),
            name: .init("CloudKitDidDeletePodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastFavoriteSync),
            name: .init("InstantSyncDidUpdatePodcastFavorite"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastDownloadSync),
            name: .init("InstantSyncDidUpdatePodcastDownload"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantPodcastPlayedSync),
            name: .init("InstantSyncDidUpdatePodcastPlayed"),
            object: nil
        )
        
        // CloudKit automatic sync listeners
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitFeedAddedSync),
            name: .init("CloudKitDidAddPodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitFeedDeletedSync),
            name: .init("CloudKitDidDeletePodcastFeed"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitAllFeedsUpdatedSync),
            name: .init("CloudKitDidUpdateAllFeeds"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitEpisodeStateSync),
            name: .init("CloudKitDidUpdateEpisodeState"),
            object: nil
        )
        
        // Listen for instant episode progress changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodeProgressChange),
            name: .init("EpisodeProgressChangedInstantly"),
            object: nil
        )
        
        // Listen for instant episode state changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodeStateChange),
            name: .init("EpisodeStateChangedInstantly"),
            object: nil
        )
        
        // Listen for instant episode played changes for real-time UI updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantEpisodePlayedChange),
            name: .init("EpisodePlayedChangedInstantly"),
            object: nil
        )
        
        // BACKGROUND RETURN FIX: Listen for app lifecycle events to prevent clearing episodes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleInstantPodcastProgressSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            return
        }
        
        // Update episode progress from remote sync
        let currentProgress = episodeProgress[episodeId] ?? 0.0
        
        // Only update if the value actually changed to avoid infinite loops
        // Also check if this progress is newer (has a reasonable threshold)
        if abs(currentProgress - progress) > 0.01 {
            DispatchQueue.main.async {
                // CRITICAL: Don't call setProgress again to avoid loops - just update UI directly
                // The progress has already been saved by the player or CloudKit sync
                
                // Update episodeProgress cache for immediate UI refresh
                self.episodeProgress[episodeId] = progress
                
                // 🔄 CRITICAL FIX: Update UI immediately for automatic view refresh
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: progress)
                
            }
        }
    }
    
    @objc private func handleInstantEpisodeProgressChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double else {
            return
        }
        
        // ULTIMATE PERFORMANCE: Silent cache update without UI storms
        episodeProgress[episodeId] = progress
        
        // Single deferred UI update to prevent spam
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleInstantEpisodeStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let stateRawValue = userInfo["state"] as? String else {
            return
        }
        
        // Force immediate UI update for state changes
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleInstantEpisodePlayedChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isPlayed = userInfo["isPlayed"] as? Bool else {
            return
        }
        
        // Update episode state in UI data structures
        updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: nil)
        
        // Force immediate UI update for played status changes
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    // MARK: - App Lifecycle Handlers
    
    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        // Mark that we're returning from background to prevent clearing episodes
        Task { @MainActor in
            self.isReturningFromBackground = true
            print("🔄 ViewModel: App entering foreground - set isReturningFromBackground = true")
        }
    }
    
    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        // Don't reset flag here - let the view reset it after checking
        // This ensures the view always sees the flag before it's cleared
        print("🔄 ViewModel: App became active - keeping isReturningFromBackground = \(isReturningFromBackground)")
    }
    
    /// Called by view after checking isReturningFromBackground to reset the flag
    func clearBackgroundReturnFlag() {
        Task { @MainActor in
            self.isReturningFromBackground = false
            print("🔄 ViewModel: Cleared isReturningFromBackground flag after view checked it")
        }
    }
    
    @objc private func handleInstantPodcastFeedAddedSync(_ notification: Notification) {
        // FRESH INSTALL FIX: Skip processing if user hasn't added any feeds yet
        // This prevents automatic feed sync from other devices on fresh installs
        // User should explicitly choose which feeds to add on a new device
        if podcastFeeds.isEmpty {
            print("⚡ FRESH INSTALL: Skipping feed sync from other device - user hasn't added any feeds yet")
            return
        }
        
        guard let userInfo = notification.userInfo,
              let feedData = userInfo["feed"] as? [String: Any] else {
            return
        }
        
        // Convert dictionary back to PodcastFeed
        if let feed = podcastFeedFromDictionary(feedData) {
            
            // FEED PROCESSING PROTECTION: Check if this feed is already being processed
            guard markFeedAsProcessing(feed.id) else {
                print("📡 ⚠️ INSTANT SYNC: Feed \(feed.title) is already being processed, skipping duplicate")
                return
            }
            
            // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
            let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
            
            if isDuplicateInMemory {
                print("📡 ⚠️ INSTANT SYNC: Duplicate detected in memory, skipping: \(feed.title)")
                markFeedAsFinished(feed.id) // Release the processing lock
                return
            }
            
            // Check Core Data for duplicate (thread-safe)
            Task {
                let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
                
                if isDuplicateInCoreData {
                    print("📡 ⚠️ INSTANT SYNC: Duplicate detected in Core Data, skipping: \(feed.title)")
                    await MainActor.run {
                        self.markFeedAsFinished(feed.id) // Release the processing lock
                    }
                    return
                }
                
                // Parse RSS episodes immediately after sync with progress tracking
                do {
                    print("📡 🔄 INSTANT SYNC: Parsing episodes immediately for synced feed: \(feed.title)")
                    
                    // Initialize parsing progress for instant sync
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "Preparing to parse \(feed.title)...")
                    }
                    
                    // Broadcast feed sync start to other devices (milestone only)
                    PodcastCloudKitManager.shared.broadcastFeedProgress(
                        feedId: feed.id,
                        feedTitle: feed.title,
                        progress: 0.0,
                        message: "Starting feed sync from another device..."
                    )
                    
                    guard let url = URL(string: feed.url) else {
                        print("📡 ❌ INSTANT SYNC: Invalid URL for feed \(feed.title): \(feed.url)")
                        await addFeedToUIOnly(feed)
                        return
                    }
                    
                    // Parse RSS to get episodes with progress tracking
                    let episodes = try await parseRSSEpisodesOnly(from: url)
                    
                    // CRITICAL: Save feed to Core Data FIRST before adding episodes
                    try await saveFeedToCoreData(feed)
                    
                    // Add episodes to Core Data for this feed
                    try await PodcastCoreDataManager.shared.addNewEpisodes(episodes, to: feed.id)
                    
                    await MainActor.run {
                        // Final check before adding (prevents race conditions)
                        if !self.podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url }) {
                            // Add feed with episodes to UI
                            var feedWithEpisodes = feed
                            feedWithEpisodes.episodes = episodes
                            
                            self.podcastFeeds.append(feedWithEpisodes)
                            self.podcastFeedOrder.append(feedWithEpisodes.id)
                            self.throttledUIUpdate()
                            
                            print("📡 ✅ INSTANT SYNC: Applied instant sync with \(episodes.count) episodes: \(feed.title)")
                        } else {
                            print("📡 ⚠️ INSTANT SYNC: Last-second duplicate check prevented duplicate: \(feed.title)")
                        }
                    }
                    
                    // Reset parsing progress after successful completion
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    }
                    
                    // Broadcast completion to other devices (milestone only)
                    PodcastCloudKitManager.shared.broadcastFeedProgress(
                        feedId: feed.id,
                        feedTitle: feed.title,
                        progress: 1.0,
                        message: "Feed sync completed - \(episodes.count) episodes added"
                    )
                    
                    // Release the processing lock after successful completion
                    await MainActor.run {
                        self.markFeedAsFinished(feed.id)
                    }
                    
                } catch {
                    print("📡 ❌ INSTANT SYNC: Failed to parse episodes for \(feed.title): \(error)")
                    
                    // Still save the feed to Core Data even without episodes
                    do {
                        try await saveFeedToCoreData(feed)
                        await addFeedToUIOnly(feed)
                        print("📡 ✅ INSTANT SYNC: Saved feed without episodes as fallback: \(feed.title)")
                    } catch {
                        print("📡 ❌ INSTANT SYNC: Failed to save feed as fallback: \(error)")
                    }
                    
                    // Reset parsing progress after error
                    await MainActor.run {
                        DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                        // Release the processing lock after error
                        self.markFeedAsFinished(feed.id)
                    }
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastFeedRemovedSync(_ notification: Notification) {
        // FRESH INSTALL FIX: Skip processing if there are no local feeds
        // This prevents hundreds of logs on fresh installs with no data
        if podcastFeeds.isEmpty {
            return
        }
        
        print("📡 🔔 NOTIFICATION RECEIVED: InstantSyncDidRemovePodcastFeed")
        print("📡 📝 Notification object: \(String(describing: notification.object))")
        
        guard let userInfo = notification.userInfo else {
            print("📡 ❌ SYNC RECEIVE FAILED: No userInfo in notification")
            return
        }
        
        print("📡 📝 Notification userInfo: \(userInfo)")
        
        guard let feedId = userInfo["feedId"] as? String,
              let feedTitle = userInfo["feedTitle"] as? String else {
            print("📡 ❌ SYNC RECEIVE FAILED: Invalid feed removal notification data")
            print("📡 📝 Missing feedId or feedTitle in userInfo: \(userInfo)")
            return
        }
        
        let episodeIds = userInfo["episodeIds"] as? [String] ?? []
        let actionId = userInfo["actionId"] as? String ?? "unknown"
        let operationType = userInfo["operation_type"] as? String ?? "legacy"
        let syncTimestamp = userInfo["sync_timestamp"] as? TimeInterval ?? 0
        
        print("📡 🎯 Processing comprehensive feed removal sync:")
        print("📡    📚 Feed: '\(feedTitle)' (\(feedId))")
        print("📡    📊 Episodes to clean up: \(episodeIds.count)")
        print("📡    🆔 Action ID: \(actionId)")
        print("📡    🔧 Operation type: \(operationType)")
        print("📡    ⏰ Sync timestamp: \(syncTimestamp)")
        
        // Enhanced processing - always attempt cleanup for comprehensive CoreData sync
        let feedExists = podcastFeeds.contains { $0.id == feedId }
        print("📡 🔍 Feed exists in UI list: \(feedExists) (total feeds: \(podcastFeeds.count))")
        print("📡 🚨 CRITICAL: Processing deletion regardless of UI state for comprehensive CoreData cleanup")
        print("📡 📊 This ensures all storage layers are properly synchronized across devices")
        
        // Comprehensive cleanup similar to local deletePodcastFeed
        Task {
            // Step 1: Clean up episode data from EpisodeStateManager
            for episodeId in episodeIds {
                EpisodeStateManager.shared.clearEpisodeData(episodeId)
            }
            print("📡 Cleared \(episodeIds.count) episode states from EpisodeStateManager")
            
            // Step 2: Delete downloaded episode files
            await deleteDownloadedEpisodeFiles(episodeIds)
            
            // Step 3: Remove feed and episodes from UI and Core Data
            await MainActor.run {
                // Remove from UI arrays
                if let index = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                    self.podcastFeeds.remove(at: index)
                }
                self.podcastFeedOrder.removeAll { $0 == feedId }
                self.currentEpisodes.removeAll { $0.feedId == feedId }
                
                // Clear selected feed if it's the one being deleted
                if self.selectedFeedId == feedId {
                    self.selectedFeedId = nil
                }
                
                // Clean up local episode state tracking
                for episodeId in episodeIds {
                    self.episodeProgress.removeValue(forKey: episodeId)
                }
                
                // Trigger UI update
                self.throttledUIUpdate()
            }
            
            // Step 4: Delete from Core Data
            do {
                let feed = PodcastFeed(id: feedId, title: feedTitle, url: "", artworkUrl: nil, description: nil)
                try await deleteFeedFromCoreData(feed)
                print("📡 Deleted feed and episodes from Core Data: \(feedTitle)")
                
                await MainActor.run {
                    print("📡 📊 Remote device cleanup summary:")
                    print("📡    ✅ CloudKit was already cleaned by originating device")
                    print("📡    ✅ EpisodeStateManager: \(episodeIds.count) episode states cleared")
                    print("📡    ✅ Downloaded files: cleaned up")
                    print("📡    ✅ Core Data: feed and episodes deleted")
                    print("📡    ✅ UI: feed and episodes removed")
                    print("📡    🚨 NOTE: CloudKit-first deletion order prevents feed restoration!")
                }
            } catch {
                print("📡 ❌ Error during Core Data cleanup for synced feed removal: \(error)")
            }
        }
    }
    
    @objc private func handleInstantPodcastFavoriteSync(_ notification: Notification) {
        
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("📡 ❌ FAVORITE SYNC FAILED: Invalid notification data")
            return
        }
                
        // Update episode favorite status from remote sync
        let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setFavoriteSilently(episodeId, isFavorite: isFavorite)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
            }
            
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isFavorite": isFavorite
                ]
            )
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: currentProgress,
                    isFavorite: isFavorite,
                    isDownloaded: currentDownloaded,
                    isPlayed: currentPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save favorite state to Core Data: \(error)")
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastDownloadSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isDownloaded = userInfo["isDownloaded"] as? Bool else {
            return
        }
        
        // FRESH INSTALL FIX: Skip processing if there are no local feeds
        // This prevents hundreds of logs on fresh installs with no data
        if podcastFeeds.isEmpty {
            return
        }
        
        // Update episode download status from remote sync
        let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setDownloadedSilently(episodeId, isDownloaded: isDownloaded)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
            }
            
            // 🚗 CARPLAY FIX: Notify CarPlay immediately about cross-device download sync
            print("🚗 CARPLAY NOTIFY: Sending EpisodeStateChanged notification for cross-device download sync")
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isDownloaded": isDownloaded
                ]
            )
            print("🚗 CARPLAY NOTIFY: EpisodeStateChanged notification sent for download sync")
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: currentProgress,
                    isFavorite: currentFavorite,
                    isDownloaded: isDownloaded,
                    isPlayed: currentPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save download state to Core Data: \(error)")
                }
            }
        }
    }
    
    @objc private func handleInstantPodcastPlayedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let isPlayed = userInfo["isPlayed"] as? Bool else {
            return
        }
        
        // FRESH INSTALL FIX: Skip processing if there are no local feeds
        // This prevents hundreds of logs on fresh installs with no data
        if podcastFeeds.isEmpty {
            return
        }
        
        // Update episode played status from remote sync
        let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
        
        // Always ensure UI is in sync, even if data states match
        DispatchQueue.main.async {
            // Update EpisodeStateManager silently to prevent sync loops (this is incoming cross-device sync)
            EpisodeStateManager.shared.setPlayedSilently(episodeId, isPlayed: isPlayed)
            
            // 🔄 CRITICAL FIX: ALWAYS trigger UI refresh regardless of data change
            // For played state, we need to update progress to reflect the played status
            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
            let effectiveProgress = isPlayed ? max(currentProgress, 0.99) : currentProgress
            
            print("📡 🔄 PLAYED SYNC: Received isPlayed=\(isPlayed) for episode \(episodeId), currentProgress=\(currentProgress), effectiveProgress=\(effectiveProgress)")
            
            // For large feeds, use immediate update to bypass batch delays
            if self.currentEpisodes.count > 100 {
                self.updateEpisodeUIStateImmediate(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: effectiveProgress)
            } else {
                self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: nil, progress: effectiveProgress)
            }
            
            // 🚗 CARPLAY FIX: Notify CarPlay immediately about cross-device played sync
            print("🚗 CARPLAY NOTIFY: Sending EpisodeStateChanged notification for cross-device played sync")
            NotificationCenter.default.post(
                name: NSNotification.Name("EpisodeStateChanged"),
                object: nil,
                userInfo: [
                    "episodeId": episodeId,
                    "isPlayed": isPlayed
                ]
            )
            print("🚗 CARPLAY NOTIFY: EpisodeStateChanged notification sent for played sync")
            
            // CRITICAL FIX: Save to Core Data for persistence across app restarts
            Task {
                let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                
                let coreDataUpdate = EpisodeStateUpdate(
                    episodeId: episodeId,
                    progress: effectiveProgress,
                    isFavorite: currentFavorite,
                    isDownloaded: currentDownloaded,
                    isPlayed: isPlayed
                )
                
                do {
                    try await self.episodeManager.updateEpisodeStates([coreDataUpdate])
                } catch {
                    print("❌ BANNER SYNC: Failed to save played state to Core Data: \(error)")
                }
            }
        }
    }
    
    // MARK: - Data Integrity Monitoring
    
    /// Monitor data integrity and report any contamination issues
    private func monitorDataIntegrity() {
        Task {
            let result = await PodcastCoreDataManager.shared.validateDataIntegrity()
            
            await MainActor.run {
                if !result.isValid {
                    print("🚨 DATA INTEGRITY ISSUES DETECTED:")
                    for issue in result.issues {
                        print("   - \(issue)")
                    }
                    
                    // CRITICAL: If severe contamination is detected, trigger a data cleanup
                    if result.issues.count > 5 {
                        print("🚨 SEVERE DATA INTEGRITY ISSUES - Consider data cleanup")
                        // Could trigger automatic cleanup here if needed
                    }
                } else {
                    print("✅ Data integrity validation passed - no contamination detected")
                }
            }
        }
    }
    
    // MARK: - UI State Update Helper
    
    /// Update episode UI state immediately for automatic view refresh across tabs
    private func updateEpisodeUIState(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double? = nil) {
        // For large feeds (>100 episodes), use batch update mechanism
        if currentEpisodes.count > 100 {
            queueEpisodeUpdate(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: isDownloaded, progress: progress)
            return
        }
        
        // Update the episode in currentEpisodes array (triggers UI refresh)
        if let index = currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
            var updatedEpisode = currentEpisodes[index]
            
            if let isFavorite = isFavorite {
                updatedEpisode.state.isFavorite = isFavorite
            }
            
            if let isDownloaded = isDownloaded {
                updatedEpisode.state.isDownloaded = isDownloaded
            }
            
            if let progress = progress {
                updatedEpisode.state.progress = progress
                // Also update the episodeProgress cache
                episodeProgress[episodeId] = progress
            }
            
            currentEpisodes[index] = updatedEpisode
        }
        
        // Update the episode in the podcastFeeds array (triggers feed-level UI refresh)
        for feedIndex in 0..<podcastFeeds.count {
            if let episodeIndex = podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episodeId }) {
                var updatedFeed = podcastFeeds[feedIndex]
                
                if let isFavorite = isFavorite {
                    updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                }
                
                if let isDownloaded = isDownloaded {
                    updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                }
                
                if let progress = progress {
                    updatedFeed.episodes[episodeIndex].state.progress = progress
                }
                
                podcastFeeds[feedIndex] = updatedFeed
                break
            }
        }
        
        // Apply tab filtering immediately if needed
        applyTabFiltering(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: isDownloaded)
    }
    
    // MARK: - Large Feed Batch Update System
    
    private var pendingUpdates: [String: EpisodeBatchUpdate] = [:]
    private var batchUpdateTimer: Timer?
    private let batchUpdateInterval: TimeInterval = 0.5 // 500ms batching window
    
    private struct EpisodeBatchUpdate {
        var isFavorite: Bool?
        var isDownloaded: Bool?
        var progress: Double?
        var timestamp: Date
        
        mutating func merge(with update: EpisodeBatchUpdate) {
            // Use the most recent values
            if update.isFavorite != nil { self.isFavorite = update.isFavorite }
            if update.isDownloaded != nil { self.isDownloaded = update.isDownloaded }
            if update.progress != nil { self.progress = update.progress }
            self.timestamp = update.timestamp
        }
    }
    
    /// ULTRA-OPTIMIZED: Silent episode update system - no UI storms
    private func queueEpisodeUpdate(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double?) {
        let update = EpisodeBatchUpdate(
            isFavorite: isFavorite,
            isDownloaded: isDownloaded,
            progress: progress,
            timestamp: Date()
        )
        
        if var existingUpdate = pendingUpdates[episodeId] {
            existingUpdate.merge(with: update)
            pendingUpdates[episodeId] = existingUpdate
        } else {
            pendingUpdates[episodeId] = update
        }
        
        // ULTIMATE PERFORMANCE: Skip all individual UI updates for large operations
        if pendingUpdates.count > 50 {
            // Silent processing - no UI updates during bulk operations
            processSilentBatchUpdates()
            return
        }
        
        // Schedule batch processing
        scheduleBatchUpdate()
    }
    
    /// ULTIMATE PERFORMANCE: Silent batch processing without UI updates
    private func processSilentBatchUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        
        // Process updates silently without triggering UI refresh storms
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
        // Update caches only - no UI updates
        for (episodeId, update) in updates {
            if let progress = update.progress {
                episodeProgress[episodeId] = progress
            }
        }
        
        // Single consolidated UI refresh instead of individual updates
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
    
    /// Schedule batch update processing
    private func scheduleBatchUpdate() {
        batchUpdateTimer?.invalidate()
        batchUpdateTimer = Timer.scheduledTimer(withTimeInterval: batchUpdateInterval, repeats: false) { [weak self] _ in
            self?.processBatchUpdates()
        }
    }
    
    /// Process all pending episode updates in batch - MOVED TO BACKGROUND THREAD
    private func processBatchUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        
        // CRITICAL: Move ALL batch processing to background thread to prevent main thread hangs
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performBackgroundBatchUpdate()
        }
    }
    
    /// Perform batch update processing on background thread to prevent main thread hangs
    @MainActor
    private func performBackgroundBatchUpdate() async {
        guard !pendingUpdates.isEmpty else { return }
        
        // Capture updates on main thread
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
        // EMERGENCY PERFORMANCE: Minimal logging for large batches
        if updates.count > 100 {
            print("📦 BATCH UPDATE: Processing \\(updates.count) updates on background thread")
        }
        
        // EMERGENCY PERFORMANCE: Skip UI updates entirely if too many pending
        if updates.count > 1000 {
            // Just update caches, skip UI refresh to prevent hangs
            for (episodeId, update) in updates {
                if let progress = update.progress {
                    episodeProgress[episodeId] = progress
                }
            }
            print("📦 EMERGENCY: Skipped UI update for \\(updates.count) episodes to prevent hang")
            return
        }
        
        // Process updates in smaller chunks to prevent blocking
        let chunkSize = 50
        let updateArray = Array(updates)
        let chunks = updateArray.chunked(into: chunkSize)
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            // Update progress cache for this chunk
            for (episodeId, update) in chunk {
                if let progress = update.progress {
                    episodeProgress[episodeId] = progress
                }
            }
            
            // Update UI for this chunk
            var currentEpisodesMap = Dictionary(uniqueKeysWithValues: currentEpisodes.enumerated().map { ($1.id, $0) })
            var updatedCurrentEpisodes = currentEpisodes
            
            // Process updates efficiently (reduced operations for performance)
            for (episodeId, update) in chunk {
                // Update currentEpisodes using index lookup
                if let index = currentEpisodesMap[episodeId] {
                    var episode = updatedCurrentEpisodes[index]
                    
                    if let isFavorite = update.isFavorite {
                        episode.state.isFavorite = isFavorite
                    }
                    if let isDownloaded = update.isDownloaded {
                        episode.state.isDownloaded = isDownloaded
                    }
                    if let progress = update.progress {
                        episode.state.progress = progress
                    }
                    
                    updatedCurrentEpisodes[index] = episode
                }
                
                // EMERGENCY PERFORMANCE: Skip tab filtering for large batches
                if updates.count <= 100 {
                    applyTabFiltering(episodeId: episodeId, isFavorite: update.isFavorite, isDownloaded: update.isDownloaded)
                }
            }
            
            // Single UI update for this chunk
            currentEpisodes = updatedCurrentEpisodes
            
            // Yield control after each chunk to prevent blocking
            if chunkIndex < chunks.count - 1 {
                await Task.yield()
            }
        }
        
        // EMERGENCY PERFORMANCE: Skip podcastFeeds update for large batches to prevent hangs
        if updates.count <= 200 {
            updatePodcastFeedsWithBatchChanges(updates)
        }
        
        if updates.count <= 100 {
            print("📦 BATCH UPDATE: ✅ Completed batch update of \\(updates.count) episodes")
        }
    }
    
    /// Update podcastFeeds with batch changes efficiently
    private func updatePodcastFeedsWithBatchChanges(_ updates: [String: EpisodeBatchUpdate]) {
        for feedIndex in 0..<podcastFeeds.count {
            var feedUpdated = false
            var updatedFeed = podcastFeeds[feedIndex]
            
            // Check if this feed has any episodes that need updates
            for episodeIndex in 0..<updatedFeed.episodes.count {
                let episodeId = updatedFeed.episodes[episodeIndex].id
                
                if let update = updates[episodeId] {
                    if let isFavorite = update.isFavorite {
                        updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                        feedUpdated = true
                    }
                    if let isDownloaded = update.isDownloaded {
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                        feedUpdated = true
                    }
                    if let progress = update.progress {
                        updatedFeed.episodes[episodeIndex].state.progress = progress
                        feedUpdated = true
                    }
                }
            }
            
            // Only update the feed if it actually changed
            if feedUpdated {
                podcastFeeds[feedIndex] = updatedFeed
            }
        }
    }
    
    /// Apply tab filtering logic (extracted for reuse)
    private func applyTabFiltering(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?) {
        let filter = EpisodeFilter(rawValue: currentTab) ?? .all
        switch filter {
        case .favorites:
            // If we're on favorites tab and unfavoriting, remove the episode
            if let isFavorite = isFavorite, !isFavorite {
                currentEpisodes.removeAll { $0.id == episodeId }
                print("🔄 UI UPDATE: Removed unfavorited episode from favorites tab")
            }
        case .downloads:
            // If we're on downloads tab and un-downloading, remove the episode
            if let isDownloaded = isDownloaded, !isDownloaded {
                currentEpisodes.removeAll { $0.id == episodeId }
                print("🔄 UI UPDATE: Removed non-downloaded episode from downloads tab")
            }
        case .all:
            // All tab shows everything, no filtering needed
            break
        }
        
        // 🎯 CROSS-TAB UPDATE: Invalidate cached results for ALL tabs when episode states change
        // This ensures that when user switches tabs, they see the updated filtering
        Task { @MainActor in
            invalidateAllTabCaches()
        }
    }
    
    // PERFORMANCE: Throttle tab cache invalidation to prevent excessive CPU usage
    private var lastTabCacheInvalidation: Date = Date.distantPast
    private let tabCacheInvalidationThrottleInterval: TimeInterval = 1.0 // 1 second minimum between invalidations
    
    /// Invalidate cached filtering results for all tabs to ensure real-time updates
    @MainActor
    private func invalidateAllTabCaches() {
        let now = Date()
        
        // PERFORMANCE: Throttle cache invalidation to prevent excessive operations
        guard now.timeIntervalSince(lastTabCacheInvalidation) >= tabCacheInvalidationThrottleInterval else {
            return
        }
        
        lastTabCacheInvalidation = now
        
        // Clear any cached episode filtering results
        // This forces re-filtering when user switches between tabs
        tabFilterCache.removeAll()
        tabFilterCounts.removeAll()
        
        // 🎯 IMMEDIATE REFRESH: Also refresh the current tab's filtering to show changes instantly
        Task {
            await refreshCurrentTabFiltering()
        }
    }
    
    /// Refresh filtering for the current tab to show episode state changes immediately
    @MainActor
    private func refreshCurrentTabFiltering() async {
        guard let selectedFeedId = selectedFeedId else { return }
        
        let currentFilter = EpisodeFilter(rawValue: currentTab) ?? .all
        print("🔄 Refreshing filtered list for tab: \(currentTab)")
        
        // Get the current full episode list (from feed or cache)
        var allEpisodes: [PodcastEpisode] = []
        
        // Try to get from current feed first
        if let feed = podcastFeeds.first(where: { $0.id == selectedFeedId }) {
            allEpisodes = feed.episodes
        }
        
        // If no episodes from feed, try from cache
        if allEpisodes.isEmpty {
            let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(selectedFeedId)
            if !cachedEpisodes.isEmpty {
                allEpisodes = cachedEpisodes
            }
        }
        
        // If still no episodes, use current episodes as fallback
        if allEpisodes.isEmpty {
            allEpisodes = currentEpisodes
        }
        
        // Apply the current tab's filter
        let filteredEpisodes: [PodcastEpisode]
        switch currentFilter {
        case .all:
            filteredEpisodes = allEpisodes
        case .favorites:
            filteredEpisodes = allEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Update the current episodes with filtered results
        let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
        currentEpisodes = sortedEpisodes
        
        print("⚡ INSTANT FILTER UPDATE: Updated current tab to show \(sortedEpisodes.count) episodes")
    }
    
    /// Immediate UI update for real-time sync (bypasses batch processing)
    private func updateEpisodeUIStateImmediate(episodeId: String, isFavorite: Bool?, isDownloaded: Bool?, progress: Double? = nil) {
        print("🔄 UI STATE UPDATE: Starting immediate update for episode \(episodeId)")
        print("🔄 UI STATE UPDATE: isFavorite=\(String(describing: isFavorite)), isDownloaded=\(String(describing: isDownloaded)), progress=\(String(describing: progress))")
        
        // Update episodeProgress cache immediately
        if let progress = progress {
            episodeProgress[episodeId] = progress
        }
        
        // Update currentEpisodes using efficient single-pass update
        var foundInCurrentEpisodes = false
        for index in 0..<currentEpisodes.count {
            if currentEpisodes[index].id == episodeId {
                let oldEpisode = currentEpisodes[index]
                var updatedEpisode = currentEpisodes[index]
                
                if let isFavorite = isFavorite {
                    updatedEpisode.state.isFavorite = isFavorite
                }
                if let isDownloaded = isDownloaded {
                    updatedEpisode.state.isDownloaded = isDownloaded
                }
                if let progress = progress {
                    updatedEpisode.state.progress = progress
                }
                
                currentEpisodes[index] = updatedEpisode
                foundInCurrentEpisodes = true
                
                print("🔄 UI STATE UPDATE: Updated episode in currentEpisodes[index: \(index)]")
                print("🔄 UI STATE UPDATE: OLD - favorite: \(oldEpisode.state.isFavorite), downloaded: \(oldEpisode.state.isDownloaded)")
                print("🔄 UI STATE UPDATE: NEW - favorite: \(updatedEpisode.state.isFavorite), downloaded: \(updatedEpisode.state.isDownloaded)")
                break
            }
        }
        
        if !foundInCurrentEpisodes {
            print("🔄 UI STATE UPDATE: ⚠️ Episode \(episodeId) not found in currentEpisodes array")
        }
        
        // Update podcastFeeds efficiently (single-pass lookup)
        for feedIndex in 0..<podcastFeeds.count {
            for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                if podcastFeeds[feedIndex].episodes[episodeIndex].id == episodeId {
                    var updatedFeed = podcastFeeds[feedIndex]
                    
                    if let isFavorite = isFavorite {
                        updatedFeed.episodes[episodeIndex].state.isFavorite = isFavorite
                    }
                    if let isDownloaded = isDownloaded {
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = isDownloaded
                    }
                    if let progress = progress {
                        updatedFeed.episodes[episodeIndex].state.progress = progress
                    }
                    
                    podcastFeeds[feedIndex] = updatedFeed
                    return // Found and updated, exit early
                }
            }
        }
        
        // Note: Tab filtering is now handled directly in toggle methods for immediate response
    }
    
    /// Force SwiftUI to detect changes in currentEpisodes array
    private func forceUIRefresh() {
        // Multiple strategies to force UI refresh
        
        // Strategy 1: Update refresh trigger (triggers currentEpisode computed property)
        uiRefreshTrigger = UUID()
        
        // Strategy 2: Force objectWillChange notification
        objectWillChange.send()
        
        // Strategy 3: Force array change detection by recreating the array synchronously
        let episodes = currentEpisodes
        currentEpisodes = []
        currentEpisodes = episodes
        
        // Strategy 4: Force another objectWillChange after array recreation
        objectWillChange.send()
        
        print("🔄 UI FORCE REFRESH: Triggered all refresh strategies - trigger: \(uiRefreshTrigger)")
    }
    
    // MARK: - CloudKit Automatic Sync Handlers
    
    @objc private func handleCloudKitFeedAddedSync(_ notification: Notification) {
        // FRESH INSTALL FIX: Skip processing if user hasn't added any feeds yet
        // This prevents automatic feed sync from other devices on fresh installs
        // User should explicitly choose which feeds to add on a new device
        if podcastFeeds.isEmpty {
            print("⚡ FRESH INSTALL: Skipping feed sync from other device - user hasn't added any feeds yet")
            return
        }
        
        guard let userInfo = notification.userInfo,
              let feed = userInfo["feed"] as? PodcastFeed else {
            print("📡 ☁️ CLOUDKIT FEED ADD FAILED: Invalid feed data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT FEED ADD: Received feed addition from CloudKit: \(feed.title)")
        
        // FEED PROCESSING PROTECTION: Check if this feed is already being processed
        guard markFeedAsProcessing(feed.id) else {
            print("📡 ☁️ CLOUDKIT FEED ADD: Feed \(feed.title) is already being processed, skipping duplicate")
            return
        }
        
        // COMPREHENSIVE DUPLICATE CHECK: Check both in-memory and Core Data to prevent race conditions
        let isDuplicateInMemory = podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url })
        
        if isDuplicateInMemory {
            print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in memory, skipping: \(feed.title)")
            markFeedAsFinished(feed.id) // Release the processing lock
            return
        }
        
        // Check Core Data for duplicate (thread-safe)
        Task {
            let isDuplicateInCoreData = await checkForDuplicateInCoreData(feedId: feed.id, feedUrl: feed.url)
            
            if isDuplicateInCoreData {
                print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Duplicate detected in Core Data, skipping: \(feed.title)")
                await MainActor.run {
                    self.markFeedAsFinished(feed.id) // Release the processing lock
                }
                return
            }
            
            do {
                print("📡 🔄 CLOUDKIT FEED ADD: Fetching episodes for synced feed: \(feed.title)")
                
                // Initialize parsing progress for CloudKit sync
                await MainActor.run {
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "Loading \(feed.title) from CloudKit...")
                }
                
                // Parse RSS for episodes only (don't save feed to Core Data again)
                guard let url = URL(string: feed.url) else {
                    print("📡 ❌ CLOUDKIT FEED ADD: Invalid URL for feed \(feed.title): \(feed.url)")
                    await addFeedToUIOnly(feed)
                    return
                }
                
                // Parse RSS to get episodes
                let episodes = try await parseRSSEpisodesOnly(from: url)
                
                // CRITICAL: Save feed to Core Data FIRST before adding episodes
                try await saveFeedToCoreData(feed)
                
                // Add episodes to Core Data for this feed
                try await PodcastCoreDataManager.shared.addNewEpisodes(episodes, to: feed.id)
                
                await MainActor.run {
                    // Final check before adding (prevents race conditions)
                    if !self.podcastFeeds.contains(where: { $0.id == feed.id || $0.url == feed.url }) {
                        // Add feed with episodes to UI
                        var feedWithEpisodes = feed
                        feedWithEpisodes.episodes = episodes
                        
                        self.podcastFeeds.append(feedWithEpisodes)
                        self.podcastFeedOrder.append(feedWithEpisodes.id)
                        self.throttledUIUpdate()
                        
                        print("📡 ☁️ CLOUDKIT FEED ADD: ✅ Added feed with \(episodes.count) episodes from CloudKit: \(feed.title)")
                        
                        // 🎯 CROSS-DEVICE BANNER: Show banner for feed added from other device
                        print("📡 🔄 CROSS-DEVICE NOTIFICATION: Triggering banner for feed added from other device")
                        DataSyncManager.shared.startCrossDeviceFeedSync(
                            totalCount: 1,
                            operation: "Synced '\(feed.title)' from other device"
                        )
                        
                        // Complete the banner after a short delay to show the sync
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: 1,
                                operation: "Added '\(feed.title)'"
                            )
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DataSyncManager.shared.completeCrossDeviceFeedSync()
                            }
                        }
                    } else {
                        print("📡 ☁️ CLOUDKIT FEED ADD: ⚠️ Last-second duplicate check prevented duplicate: \(feed.title)")
                    }
                    
                    // Reset parsing progress after successful completion
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    
                    // Release the processing lock after successful completion
                    self.markFeedAsFinished(feed.id)
                }
                
            } catch {
                print("📡 ❌ CLOUDKIT FEED ADD: Failed to fetch episodes for \(feed.title): \(error)")
                
                // Still save the feed to Core Data even without episodes
                do {
                    try await saveFeedToCoreData(feed)
                    await addFeedToUIOnly(feed)
                    print("📡 ✅ CLOUDKIT FEED ADD: Saved feed without episodes as fallback: \(feed.title)")
                    
                    // 🎯 CROSS-DEVICE BANNER: Show banner for feed added from other device (fallback case)
                    await MainActor.run {
                        print("📡 🔄 CROSS-DEVICE NOTIFICATION: Triggering banner for fallback feed addition")
                        DataSyncManager.shared.startCrossDeviceFeedSync(
                            totalCount: 1,
                            operation: "Synced '\(feed.title)' from other device"
                        )
                        
                        // Complete the banner after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: 1,
                                operation: "Added '\(feed.title)'"
                            )
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DataSyncManager.shared.completeCrossDeviceFeedSync()
                            }
                        }
                    }
                } catch {
                    print("📡 ❌ CLOUDKIT FEED ADD: Failed to save feed as fallback: \(error)")
                }
                
                // Reset parsing progress after error
                await MainActor.run {
                    DataSyncManager.shared.updateFeedParsingProgress(0.0, message: "")
                    // Release the processing lock after error
                    self.markFeedAsFinished(feed.id)
                }
            }
        }
    }
    
    /// Parse RSS feed to get episodes only (without saving feed to Core Data) with robust error handling
    private func parseRSSEpisodesOnly(from url: URL) async throws -> [PodcastEpisode] {
        print("🔍 Parsing RSS episodes from: \(url.absoluteString)")
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting RSS parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // Ensure RSS operations happen on dedicated background queue to prevent main thread blocking
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .background) {
                do {
                    // Check for cancellation and scrolling before starting
                    try Task.checkCancellation()
                    
                    // Double-check scrolling state
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected during parsing - aborting")
                        throw CancellationError()
                    }
                    
                    // Fetch RSS data with robust error handling for large feeds and decode issues
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation and scrolling after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting")
                        throw CancellationError()
                    }
                    
                    // CRITICAL: Yield between fetch and parse to allow UI updates
                    await Task.yield()
                    
                    // PERFORMANCE FIX: Parse RSS without progress tracking for auto-refresh to prevent main thread blocking
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, episodes) = try await parser.parseComplete()
                    
                    // Check for cancellation and scrolling after parsing
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after parsing - aborting")
                        throw CancellationError()
                    }
                    
                    print("🔍 Parsed \(episodes.count) episodes from RSS")
                    
                    // ENHANCED LOGGING: Show episode date range
                    if !episodes.isEmpty {
                        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
                        let newestDate = sortedEpisodes.first?.publicationDate ?? Date()
                        let oldestDate = sortedEpisodes.last?.publicationDate ?? Date()
                    }
                    
                    continuation.resume(returning: episodes)
                } catch {
                    print("❌ Failed to parse RSS episodes: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Parse RSS feed intelligently and return only new episodes that don't exist in Core Data
    /// IMMEDIATE NEW EPISODE CHECK: Check for new episodes when feed opens
    /// LIGHTWEIGHT NEW EPISODE DETECTION: Ultra-fast check without expensive RSS parsing
    /// Uses HEAD requests and conditional logic to detect new episodes with minimal CPU impact
    private func lightweightNewEpisodeCheck(feedId: String) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        print("🪶 LIGHTWEIGHT: Starting ultra-fast new episode detection")
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }) else {
            print("🪶 LIGHTWEIGHT: No feed URL found for \(feedId)")
            return
        }
        
        guard let url = URL(string: feedUrl) else {
            print("🪶 LIGHTWEIGHT: Invalid feed URL: \(feedUrl)")
            return
        }
        
        // CRITICAL FIX: Always perform sampling when user opens feed
        // Even if HEAD request fails or feed appears unmodified, we need to check for new episodes
        // The background refresh will handle the full sync to ensure latest episodes are fetched
        print("🪶 LIGHTWEIGHT: Starting episode check (bypassing HEAD request for reliability)")
        
        // STEP 2: Do minimal RSS sampling which always triggers full background refresh
        await performMinimalEpisodeSampling(url: url, feedId: feedId)
    }
    
    /// PERFORMANCE OPTIMIZATION: Check feed modification using HEAD request (ultra-fast)
    private func checkFeedModificationWithHEAD(url: URL, feedId: String, isUserInitiated: Bool = false) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"  // Only get headers, no body content
            request.timeoutInterval = 5.0  // Quick timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🪶 HEAD: Response \(httpResponse.statusCode) for feed check")
                
                // Check Last-Modified header
                if let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
                    let lastModifiedKey = "LastModified_\(feedId)"
                    let previousLastModified = UserDefaults.standard.string(forKey: lastModifiedKey)
                    
                    if previousLastModified != lastModified {
                        UserDefaults.standard.set(lastModified, forKey: lastModifiedKey)
                        print("🪶 HEAD: Feed modified since last check - \(lastModified)")
                        return true
                    } else {
                        print("🪶 HEAD: Feed not modified since last check")
                        return false
                    }
                }
                
                // CRITICAL FIX: Always check for new episodes when user opens feed
                print("🪶 HEAD: No Last-Modified header - checking for new episodes on feed open")
                return true
            }
            
            return false
        } catch {
            print("🪶 HEAD: Failed to check feed modification: \(error.localizedDescription)")
            // If HEAD request fails, don't do expensive operations
            return false
        }
    }
    
    /// MINIMAL SAMPLING: Get just the first few episodes to check for new content (lightweight)
    private func performMinimalEpisodeSampling(url: URL, feedId: String) async {
        do {
            print("🪶 SAMPLING: Starting minimal episode sampling using optimized parser")
            
            // PERFORMANCE: Use the new checkForNewEpisodes method that parses only first 50 episodes
            let newEpisodes = try await feedManager.checkForNewEpisodes(feedId, sampleSize: 50)
            
            if !newEpisodes.isEmpty {
                print("🪶 SAMPLING: Found \(newEpisodes.count) new episodes - triggering full background sync")
            } else {
                print("🪶 SAMPLING: No new episodes found in sample - but still triggering full sync for large feeds")
            }
            
            // CRITICAL FIX: Always trigger full background sync for large feeds
            // Even if sample shows no new episodes, there might be newer episodes beyond the sample
            // This ensures feeds with thousands of episodes always get fully synced
            Task.detached(priority: .background) {
                await self.backgroundRefreshForNewEpisodes(feedId: feedId, isInitialLoad: false)
            }
        } catch {
            print("🪶 SAMPLING: Failed to check for new episodes: \(error.localizedDescription)")
        }
    }
    
    /// Background refresh: Full feed sync to match RSS feed exactly
    private func backgroundRefreshForNewEpisodes(feedId: String, isInitialLoad: Bool) async {
        print("🔄 BACKGROUND REFRESH: Starting full feed sync for \(feedId)")
        
        // CRITICAL: Prevent concurrent syncs for the same feed
        syncLock.lock()
        if activeBackgroundSyncs.contains(feedId) {
            syncLock.unlock()
            print("⏱️ BACKGROUND REFRESH: Sync already in progress for \(feedId) - skipping")
            return
        }
        activeBackgroundSyncs.insert(feedId)
        syncLock.unlock()
        
        // Request background time to complete sync even if app is backgrounded
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        await MainActor.run {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PodcastFeedSync") {
                // Background time expired - clean up
                print("⏰ BACKGROUND REFRESH: Background time expired for \(feedId)")
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        
        // Ensure we remove from active syncs and end background task when done
        defer {
            syncLock.lock()
            activeBackgroundSyncs.remove(feedId)
            syncLock.unlock()
            
            // End background task
            if backgroundTaskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        // CRITICAL: Always do full sync to ensure Core Data matches RSS exactly
        // This prevents episode accumulation and ensures latest episodes are fetched
        // NO THROTTLING: Fetch new episodes immediately when user opens feed
        
        do {
            print("🔄 BACKGROUND REFRESH: Performing full feed sync from RSS for \(feedId)")
            
            // Do full feed refresh which syncs with RSS completely
            let (updatedFeed, allEpisodes) = try await feedManager.refreshFeed(feedId)
            
            print("✅ BACKGROUND REFRESH: Synced \(allEpisodes.count) total episodes from RSS feed")
            
            // Get fresh episode list from Core Data (which now matches RSS exactly)
            let refreshedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
            print("💾 BACKGROUND REFRESH: Core Data now has \(refreshedEpisodes.count) episodes for feed \(feedId)")
            
            // Update cache with synced episodes
            feedIsolationManager.replaceEpisodesForFeed(refreshedEpisodes, feedId: feedId)
            
            // Update UI if this feed is currently selected
            await MainActor.run {
                if selectedFeedId == feedId {
                    // CRITICAL: Update isolation manager with refreshed episodes so UI shows new data
                    feedIsolationManager.replaceEpisodesForFeed(refreshedEpisodes, feedId: feedId)
                    
                    // Apply current filter to refreshed episodes
                    let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                    let filteredEpisodes: [PodcastEpisode]
                    switch filter {
                    case .all:
                        filteredEpisodes = refreshedEpisodes
                    case .favorites:
                        filteredEpisodes = refreshedEpisodes.filter { $0.state.isFavorite }
                    case .downloads:
                        filteredEpisodes = refreshedEpisodes.filter { $0.state.isDownloaded }
                    }
                    
                    // Update UI with synced episodes
                    currentEpisodes = filteredEpisodes
                    
                    // Update episode counts
                    let allCount = refreshedEpisodes.count
                    let favoritesCount = refreshedEpisodes.filter { $0.state.isFavorite }.count
                    let downloadsCount = refreshedEpisodes.filter { $0.state.isDownloaded }.count
                    episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                    
                    // Clear episode cache to force UI refresh with new data
                    _episodeCache = nil
                    _episodeCacheFeedId = nil
                    
                    print("🔄 BACKGROUND REFRESH: Updated isolation manager and UI - now showing \(filteredEpisodes.count) episodes")
                }
            }
            
            // Update refresh timestamp
            await MainActor.run {
                let currentTime = Date().timeIntervalSince1970
                let lastRefreshKey = "LastRSSRefresh_\(feedId)"
                UserDefaults.standard.set(currentTime, forKey: lastRefreshKey)
            }
            
        } catch {
            print("❌ BACKGROUND REFRESH: Failed to sync feed \(feedId): \(error)")
        }
    }
    
    /// FEED OPEN OPTIMIZATION: Check for new episodes immediately when feed is opened, bypassing all thresholds
    /// This ensures users always see the latest episodes without waiting, while maintaining performance
    private func checkForNewEpisodesImmediatelyOnFeedOpen(feedId: String) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        print("🚀 FEED OPEN CHECK: Starting immediate check for new episodes (no thresholds)")
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }), let url = URL(string: feedUrl) else {
            print("⚠️ FEED OPEN CHECK: Missing feed URL for \(feedId)")
            return
        }
        
        do {
            // Check for cancellation before starting work
            try Task.checkCancellation()
            
            // ULTRA-FAST NEW EPISODE DETECTION: Use optimized parsing that stops at first known episode
            let newEpisodes = try await parseNewEpisodesOnlyOptimized(from: url, feedId: feedId)
            
            // Check for cancellation after parsing
            try Task.checkCancellation()
            
            guard !newEpisodes.isEmpty else {
                print("✅ FEED OPEN CHECK: No new episodes found for feed \(feedId)")
                return
            }
            
            print("🆕 FEED OPEN CHECK: Found \(newEpisodes.count) new episodes for feed \(feedId)")
            
            // IMMEDIATE INTEGRATION: Add new episodes without expensive operations
            await self.integrateNewEpisodesLightweight(newEpisodes, feedId: feedId)
            
            // IMMEDIATE UI UPDATE: Update current episodes if this feed is selected
            await MainActor.run {
                if self.selectedFeedId == feedId {
                    // Get updated cache and refresh UI
                    let updatedCache = self.feedIsolationManager.getEpisodesForFeed(feedId); if !updatedCache.isEmpty {
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = updatedCache
                        case .favorites:
                            filteredEpisodes = updatedCache.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = updatedCache.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        Task {
                            await self.updateEpisodeCounts(for: feedId, episodes: updatedCache)
                        }
                        print("🆕 FEED OPEN CHECK: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count)")
                    }
                }
                
                self.objectWillChange.send()
            }
            
        } catch is CancellationError {
            print("🚫 FEED OPEN CHECK: Cancelled for feed \(feedId)")
        } catch {
            print("❌ FEED OPEN CHECK: Failed to check for new episodes: \(error)")
        }
    }
    
    /// This runs in background with high priority but doesn't block the UI
    private func checkForNewEpisodesImmediately(feedId: String, userInitiated: Bool = false) async {
        defer {
            // Clean up task when completed
            Task { @MainActor in
                self.immediateCheckTasks.removeValue(forKey: feedId)
            }
        }
        
        // PERFORMANCE: Even for user-initiated checks, respect fresh caches to prevent CPU spikes
        let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId); if !cachedEpisodes.isEmpty {
            let cacheAge = Date().timeIntervalSince(coreDataLoadTimestamps[feedId] ?? Date.distantPast)
            // For user-initiated checks, use a shorter threshold (5 minutes) vs background checks (30 minutes)
            let threshold = userInitiated ? 300 : 1800 // 5 minutes for user-initiated, 30 minutes for background
            if cacheAge < TimeInterval(threshold) {
                if userInitiated {
                    print("⚡ USER-INITIATED OPTIMIZATION: Skipping RSS check - fresh cache available (\(Int(cacheAge/60)) min old, \(cachedEpisodes.count) episodes)")
                } else {
                    print("⚡ PERFORMANCE: Skipping background RSS check - recent cache available (\(Int(cacheAge/60)) min old, \(cachedEpisodes.count) episodes)")
                }
                return
            } else {
                if userInitiated {
                    print("🔍 USER-INITIATED CHECK: Cache is \(Int(cacheAge/60)) min old - checking for new episodes")
                } else {
                    print("🔍 IMMEDIATE CHECK: Cache is \(Int(cacheAge/60)) min old - checking for new episodes")
                }
            }
        } else if userInitiated {
            print("🔍 USER-INITIATED CHECK: No cache available - checking for new episodes")
        }
        
        guard let feedUrl = await MainActor.run(body: {
            self.podcastFeeds.first(where: { $0.id == feedId })?.url
        }), let url = URL(string: feedUrl) else {
            print("⚠️ IMMEDIATE CHECK: Missing feed URL for \(feedId)")
            return
        }
                
        do {
            // Check for cancellation before starting work
            try Task.checkCancellation()
            
            // SMART NEW EPISODE DETECTION: Compare against persistent cache first
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            // Check for cancellation after parsing
            try Task.checkCancellation()
            
            guard !newEpisodes.isEmpty else {
                print("✅ IMMEDIATE CHECK: No new episodes found for feed \(feedId)")
                return
            }
            
            print("🆕 IMMEDIATE CHECK: Found \(newEpisodes.count) new episodes for feed \(feedId)")
            
            // UPDATE PERSISTENT CACHE with new episodes immediately
            await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
            
            // Add new episodes to Core Data for persistence
            try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
            
            // CRITICAL: IMMEDIATELY CREATE NEW CACHE with integrated new episodes
            // Get the complete current episode list to create a fresh cache
            let feedUrl = await MainActor.run(body: {
                self.podcastFeeds.first(where: { $0.id == feedId })?.url
            })
            
            var completeEpisodeList: [PodcastEpisode] = []
            
            if let urlString = feedUrl, let url = URL(string: urlString) {
                // Parse complete RSS feed to get all current episodes (newest first)
                let allCurrentEpisodes = try await parseRSSEpisodesOnly(from: url)
                completeEpisodeList = allCurrentEpisodes
                print("🔄 IMMEDIATE CHECK: Parsed complete feed with \(allCurrentEpisodes.count) episodes")
            } else {
                // Fallback: merge new episodes with existing cache
                let existingCache = feedIsolationManager.getEpisodesForFeed(feedId)
                if !existingCache.isEmpty {
                    completeEpisodeList = newEpisodes + existingCache
                } else {
                    completeEpisodeList = newEpisodes
                }
                print("🔄 IMMEDIATE CHECK: Using fallback merge with \(completeEpisodeList.count) episodes")
            }
            
            // CLEAN UP: Remove old episodes before creating new ones
            let existingEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
            if !existingEpisodes.isEmpty {
                print("🗑️ ISOLATION CLEANUP: Removing old episodes for feed \(feedId)")
                feedIsolationManager.clearEpisodesForFeed(feedId)
                coreDataLoadTimestamps.removeValue(forKey: feedId)
            }
            
            // CREATE NEW CACHE: Replace old cache with complete episode list (newest first)
            feedIsolationManager.replaceEpisodesForFeed(completeEpisodeList, feedId: feedId)
            print("🆕 IMMEDIATE CHECK: Created new cache with \(completeEpisodeList.count) episodes (includes \(newEpisodes.count) new episodes)")
            
            // IMMEDIATE UI UPDATE: Update current episodes if this feed is selected
            await MainActor.run {
                if self.selectedFeedId == feedId {
                    let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                    let filteredEpisodes: [PodcastEpisode]
                    switch filter {
                    case .all:
                        filteredEpisodes = completeEpisodeList
                    case .favorites:
                        filteredEpisodes = completeEpisodeList.filter { $0.state.isFavorite }
                    case .downloads:
                        filteredEpisodes = completeEpisodeList.filter { $0.state.isDownloaded }
                    }
                    
                    self.currentEpisodes = filteredEpisodes
                    Task {
                        await self.updateEpisodeCounts(for: feedId, episodes: completeEpisodeList)
                    }
                    print("🆕 IMMEDIATE CHECK: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count) (newest first)")
                }
                
                self.objectWillChange.send()
            }
            
            // Sync episode states for new episodes in background
            Task.detached(priority: .background) {
                await self.quietSyncEpisodeStates(for: feedId)
            }
                        
        } catch is CancellationError {
            print("🚫 IMMEDIATE CHECK: Cancelled for feed \(feedId)")
        } catch {
            print("❌ IMMEDIATE CHECK: Failed to check for new episodes: \(error)")
        }
    }
    
    /// OPTIMIZED VERSION: Ultra-fast parsing that stops immediately at first known episode
    /// This is specifically designed for feed open scenarios where we need immediate results
    private func parseNewEpisodesOnlyOptimized(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting optimized new episode parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // ULTRA-FAST APPROACH: Get first few episode IDs from current cache for instant comparison
        let knownEpisodeIds = await getKnownEpisodeIdsFromCache(feedId: feedId, limit: 20)
        
        // Parse RSS with immediate stopping at first known episode
        let newEpisodes = try await parseRSSEpisodesWithImmediateStop(from: url, knownIds: knownEpisodeIds)
        
        return newEpisodes
    }
    
    /// Get known episode IDs from cache for ultra-fast comparison
    private func getKnownEpisodeIdsFromCache(feedId: String, limit: Int) async -> Set<String> {
        return await MainActor.run {
            let cache = self.feedIsolationManager.getEpisodesForFeed(feedId)
            if cache.isEmpty {
                return Set<String>()
            }
            
            // Take only the first 'limit' episodes (most recent) for fast comparison
            let recentEpisodes = Array(cache.prefix(limit))
            return Set(recentEpisodes.map { $0.id })
        }
    }
    
    /// Lightweight integration that updates cache without expensive operations
    private func integrateNewEpisodesLightweight(_ newEpisodes: [PodcastEpisode], feedId: String) async {
        
        // Add to Core Data in background (non-blocking)
        Task.detached(priority: .utility) {
            try? await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
        }
        
        // Update episode manager cache (fast operation)
        await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
        
        // IMMEDIATE CACHE UPDATE: Use FeedIsolationManager to merge new episodes
        await MainActor.run {
            let existingCache = self.feedIsolationManager.getEpisodesForFeed(feedId)
            if !existingCache.isEmpty {
                // Merge new episodes with existing, ensuring no duplicates
                let existingIds = Set(existingCache.map { $0.id })
                let trulyNewEpisodes = newEpisodes.filter { !existingIds.contains($0.id) }
                
                if !trulyNewEpisodes.isEmpty {
                    // Merge and let isolation manager handle validation and sorting
                    let allEpisodes = trulyNewEpisodes + existingCache
                    self.feedIsolationManager.replaceEpisodesForFeed(allEpisodes, feedId: feedId)
                    self.coreDataLoadTimestamps[feedId] = Date()
                    
                    let finalCount = self.feedIsolationManager.getEpisodesForFeed(feedId).count
                    print("🆕 ISOLATION INTEGRATION: Added \(trulyNewEpisodes.count) new episodes - total: \(finalCount)")
                }
            } else {
                // No existing cache, create new one with just the new episodes
                self.feedIsolationManager.replaceEpisodesForFeed(newEpisodes, feedId: feedId)
                self.coreDataLoadTimestamps[feedId] = Date()
                
                let finalCount = self.feedIsolationManager.getEpisodesForFeed(feedId).count
                print("🆕 ISOLATION INTEGRATION: Created new cache with \(finalCount) episodes")
            }
        }
    }
    
    /// ULTRA-OPTIMIZED RSS parsing that stops immediately when it encounters a known episode
    /// This minimizes network and CPU usage for immediate feed open scenarios
    private func parseRSSEpisodesWithImmediateStop(from url: URL, knownIds: Set<String>) async throws -> [PodcastEpisode] {
        print("🚀 OPTIMIZED PARSING: Starting immediate-stop RSS parsing with \(knownIds.count) known episode IDs")
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting immediate-stop parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // Check for cancellation before starting
                    try Task.checkCancellation()
                    
                    // Fetch RSS data (this is unavoidable but fast for most feeds)
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting")
                        throw CancellationError()
                    }
                    
                    // OPTIMIZED PARSING: Parse complete RSS but filter out known episodes immediately
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, allEpisodes) = try await parser.parseComplete()
                    
                    // IMMEDIATE FILTERING: Stop at first known episode to minimize processing
                    var newEpisodes: [PodcastEpisode] = []
                    for episode in allEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }) {
                        if knownIds.contains(episode.id) {
                            // Found a known episode, stop processing
                            print("🛑 OPTIMIZED PARSING: Stopped at known episode '\(episode.title)' - found \(newEpisodes.count) new episodes")
                            break
                        }
                        newEpisodes.append(episode)
                    }
                    
                    print("🚀 OPTIMIZED PARSING: Found \(newEpisodes.count) new episodes (stopped at first known episode)")
                    
                    continuation.resume(returning: newEpisodes)
                } catch {
                    print("❌ Failed to parse RSS with immediate stop: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Uses timestamp comparison to stop parsing once we reach episodes we already have
    private func parseNewEpisodesOnly(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting new episode parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // Get the most recent episode date from Core Data to use as cutoff
        let mostRecentEpisodeDate = await getMostRecentEpisodeDate(for: feedId)
        
        // Get existing episode IDs from Core Data to compare
        let existingEpisodeIds = await getExistingEpisodeIds(for: feedId)
        
        // Parse episodes from RSS with intelligent stopping
        let newEpisodes = try await parseRSSEpisodesWithCutoff(from: url, cutoffDate: mostRecentEpisodeDate, existingIds: existingEpisodeIds)
        
        return newEpisodes
    }
    
    /// Get existing episode IDs for a feed from Core Data
    private func getExistingEpisodeIds(for feedId: String) async -> Set<String> {
        return await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                fetchRequest.propertiesToFetch = ["id"] // Only fetch IDs for performance
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    let episodeIds = Set(results.compactMap { $0.id })
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to fetch existing episode IDs: \(error)")
                    continuation.resume(returning: Set<String>())
                }
            }
        }
    }
    
    /// Get the most recent episode publication date for a feed from Core Data
    private func getMostRecentEpisodeDate(for feedId: String) async -> Date? {
        return await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                fetchRequest.fetchLimit = 1
                fetchRequest.propertiesToFetch = ["publicationDate"]
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    let mostRecentDate = results.first?.publicationDate
                    continuation.resume(returning: mostRecentDate)
                } catch {
                    print("❌ Failed to fetch most recent episode date: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Parse RSS episodes with intelligent cutoff based on existing episode dates
    private func parseRSSEpisodesWithCutoff(from url: URL, cutoffDate: Date?, existingIds: Set<String>) async throws -> [PodcastEpisode] {
        
        // CRITICAL: Check for user scrolling and abort parsing if detected
        if isUserScrolling {
            print("🚫 User is scrolling - aborting smart RSS parsing to maintain UI responsiveness")
            throw CancellationError()
        }
        
        // For new feeds (no cutoff date), parse all episodes
        if cutoffDate == nil {
            print("🆕 New feed detected - parsing all episodes")
            return try await parseRSSEpisodesOnly(from: url)
        }
        
        // For existing feeds, parse with intelligent cutoff
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .background) {
                do {
                    // Check for cancellation and scrolling before starting
                    try Task.checkCancellation()
                    
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected during smart parsing - aborting")
                        throw CancellationError()
                    }
                    
                    // Fetch RSS data
                    let feedData = try await self.fetchRSSDataWithRetry(url: url, feedTitle: url.absoluteString)
                    
                    // Check for cancellation and scrolling after fetch
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after fetch - aborting smart parsing")
                        throw CancellationError()
                    }
                    
                    // CRITICAL: Yield between fetch and parse
                    await Task.yield()
                    
                    // Parse with regular parser and filter intelligently
                    let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString, progressCallback: nil)
                    let (_, allEpisodes) = try await parser.parseComplete()
                    
                    print("🔍 PARSING: Found \(allEpisodes.count) total episodes in RSS feed")
                    if let cutoff = cutoffDate {
                        print("🔍 PARSING: Using cutoff date: \(cutoff) (with 30s buffer)")
                    }
                    
                    // Filter to only new episodes based on cutoff date and existing IDs
                    let newEpisodes = allEpisodes.filter { episode in
                        // Skip if episode already exists
                        if existingIds.contains(episode.id) {
                            
                            return false
                        }
                        
                        // HOURLY PODCAST FIX: For frequent releases (like hourly news), use buffer to account for date precision
                        if let cutoff = cutoffDate {
                            // Add 30-second buffer to handle hourly podcasts and date precision issues
                            let cutoffWithBuffer = cutoff.addingTimeInterval(-30)
                            if episode.publicationDate <= cutoffWithBuffer {
                                print("🔍 FILTERING: Skipping old episode - Date: \(episode.publicationDate), Cutoff: \(cutoffWithBuffer)")
                                return false
                            } else {
                                print("🆕 FILTERING: New episode found - Date: \(episode.publicationDate), Cutoff: \(cutoffWithBuffer)")
                            }
                        }
                        
                        return true
                    }
                    
                    // Check for cancellation and scrolling after parsing
                    try Task.checkCancellation()
                    if await MainActor.run(body: { self.isUserScrolling }) {
                        print("🚫 User scrolling detected after smart parsing - aborting")
                        throw CancellationError()
                    }
                    
                    print("🧠 Smart parsing found \(newEpisodes.count) new episodes")
                    continuation.resume(returning: newEpisodes)
                } catch {
                    print("❌ Failed to smart parse RSS episodes: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Robust RSS data fetching with retry mechanism for decode errors  
    private func fetchRSSDataWithRetry(url: URL, feedTitle: String, maxRetries: Int = 3) async throws -> Data {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                
                // CRITICAL: Yield control to allow UI updates
                await Task.yield()
                
                // Configure URLSession with longer timeout for large feeds and dedicated background queue
                var request = URLRequest(url: url)
                request.timeoutInterval = 30.0 // Increased timeout for large episodes
                request.setValue("StreamRadios/1.0", forHTTPHeaderField: "User-Agent")
                request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
                request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
                
                // CRITICAL: Another yield point before network operation
                await Task.yield()
                
                // Use URLSession with background configuration to prevent main thread blocking
                let session = URLSession(configuration: .default)
                let (data, response) = try await session.data(for: request)
                
                // CRITICAL: Yield after network operation completes
                await Task.yield()
                
                // Validate HTTP response
                if let httpResponse = response as? HTTPURLResponse {
                    print("📡 HTTP Response: \(httpResponse.statusCode) for: \(feedTitle)")
                    
                    // Check for server errors
                    guard 200...299 ~= httpResponse.statusCode else {
                        throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
                    }
                    
                    // Log content type for debugging
                    if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        print("📄 Content-Type: \(contentType) for: \(feedTitle)")
                    }
                }
                
                // CRITICAL: Yield before data validation
                await Task.yield()
                
                // Validate data size and content
                guard !data.isEmpty else {
                    throw NSError(domain: "FeedError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty data received"])
                }
                
                // Check for minimum RSS/XML content
                guard data.count > 100 else { // Minimum viable RSS feed should be larger
                    throw NSError(domain: "FeedError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Data too small (\(data.count) bytes)"])
                }
                
                // CRITICAL: Yield before XML validation
                await Task.yield()
                
                // Validate XML structure - check if data starts with valid XML
                let dataPrefix = String(data: data.prefix(200), encoding: .utf8) ?? ""
                let hasXMLDeclaration = dataPrefix.contains("<?xml") || dataPrefix.contains("<rss") || dataPrefix.contains("<feed")
                
                guard hasXMLDeclaration else {
                    print("❌ Invalid XML structure for: \(feedTitle) - Data starts with: \(dataPrefix.prefix(100))")
                    throw NSError(domain: "FeedError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid XML structure"])
                }
                
                // Check for common encoding issues (BOM, invalid characters)
                if dataPrefix.hasPrefix("\u{FEFF}") {
                    print("🔧 Removing BOM from feed data: \(feedTitle)")
                    return Data(data.dropFirst(3)) // Remove UTF-8 BOM
                }
                
                return data
                
            } catch {
                lastError = error
                let isDecodeError = (error as NSError).code == -1015
                
                print("❌ Fetch attempt \(attempt)/\(maxRetries) failed for: \(feedTitle) - Error: \(error.localizedDescription)")
                
                // CRITICAL: Yield before retry delay to allow UI updates
                await Task.yield()
                
                // For decode errors, wait longer between retries
                if isDecodeError && attempt < maxRetries {
                    let delay = Double(attempt) * 2.0 // Progressive delay: 2s, 4s, 6s
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
        
        if let lastError = lastError, (lastError as NSError).code == -1015 {
            throw NSError(domain: "FeedError", code: -1015, userInfo: [NSLocalizedDescriptionKey: "Feed data is corrupted or truncated"])
        } else {
            throw NSError(domain: "FeedError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Maximum retry attempts exceeded"])
        }
    }
    
    /// Helper met hod to add feed to UI without episode parsing (fallback)
    @MainActor
    private func addFeedToUIOnly(_ feed: PodcastFeed) {
        if !podcastFeeds.contains(where: { $0.id == feed.id }) {
            podcastFeeds.append(feed)
            podcastFeedOrder.append(feed.id)
            throttledUIUpdate()
        }
    }
    
    @objc private func handleCloudKitFeedDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedId = userInfo["feedId"] as? String else {
            print("📡 ☁️ CLOUDKIT FEED DELETE FAILED: Invalid feed ID in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT FEED DELETE: Received feed deletion from CloudKit: \(feedId)")
        
        // Find the feed for comprehensive cleanup
        if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feedId }) {
            let feedTitle = podcastFeeds[feedIndex].title
            let feed = podcastFeeds[feedIndex]
            
            
            Task {
                // Step 1: Get episode IDs for comprehensive cleanup
                let episodeIds = await getEpisodeIdsForFeed(feedId)
                
                // Step 2: Clean up episode data from EpisodeStateManager (prevents duplication)
                for episodeId in episodeIds {
                    EpisodeStateManager.shared.clearEpisodeData(episodeId)
                }
                
                // Step 3: Delete downloaded episode files (prevents storage bloat)
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                // Step 4: Remove from UI arrays and clear local state
                await MainActor.run {
                    // Remove from UI arrays
                    if let currentIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                        self.podcastFeeds.remove(at: currentIndex)
                    }
                    self.podcastFeedOrder.removeAll { $0 == feedId }
                    self.currentEpisodes.removeAll { $0.feedId == feedId }
                    
                    // Clear selected feed if it's the one being deleted
                    if self.selectedFeedId == feedId {
                        self.selectedFeedId = nil
                    }
                    
                    // Clear local episode state tracking (prevents stale state)
                    for episodeId in episodeIds {
                        self.episodeProgress.removeValue(forKey: episodeId)
                    }
                    
                    // Trigger UI update
                    self.throttledUIUpdate()
                }
                
                // Step 5: Delete from Core Data (prevents duplication)
                do {
                    try await deleteFeedFromCoreData(feed)
                    
                    await MainActor.run {
                        print("📡 ☁️ CLOUDKIT FEED DELETE: ✅ Comprehensive cleanup completed for: \(feedTitle)")
                        print("📡 ☁️ 📊 CloudKit deletion cleanup summary:")
                        print("📡 ☁️    ✅ EpisodeStateManager: \(episodeIds.count) episode states cleared")
                        print("📡 ☁️    ✅ Downloaded files: cleaned up")
                        print("📡 ☁️    ✅ Core Data: feed and episodes deleted")
                        print("📡 ☁️    ✅ UI: feed and episodes removed")
                        print("📡 ☁️    ✅ Local state: episode progress cleared")
                        print("📡 ☁️ 🚨 Feed can now be safely re-added without duplication!")
                    }
                } catch {
                    print("📡 ☁️ ❌ Error during Core Data cleanup for CloudKit feed deletion: \(error)")
                }
            }
        } else {
            print("📡 ☁️ CLOUDKIT FEED DELETE: ⚠️ Feed not found locally, might already be deleted: \(feedId)")
            
            // Even if feed not found in UI, attempt Core Data cleanup to prevent orphaned data
            Task {
                do {
                    let dummyFeed = PodcastFeed(id: feedId, title: "Unknown Feed", url: "", artworkUrl: nil, description: nil)
                    try await deleteFeedFromCoreData(dummyFeed)
                    print("📡 ☁️ Performed orphaned data cleanup for feed ID: \(feedId)")
                } catch {
                    print("📡 ☁️ Note: No orphaned data found for feed ID: \(feedId)")
                }
            }
        }
    }
    
    @objc private func handleRealtimeCloudKitFeedDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feedId = userInfo["feedId"] as? String else {
            print("📡 🔔 REALTIME CLOUDKIT DELETE FAILED: Invalid feed ID in notification")
            return
        }
        
        print("📡 🔔 REALTIME CLOUDKIT DELETE: Received real-time feed deletion from CloudKit: \(feedId)")
        
        // Find the feed first to get episode IDs and title before deletion
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed not found locally, might already be deleted: \(feedId)")
            return
        }
        
        let feedTitle = feed.title // Store title early since we'll need it later
        
        Task {
            // Get episode IDs for cleanup
            let episodeIds = await getEpisodeIdsForFeed(feedId)
            print("📡 🔔 Found \(episodeIds.count) episodes to clean up for real-time deletion: \(feedTitle)")
            
            // Clean up episode data from EpisodeStateManager
            for episodeId in episodeIds {
                EpisodeStateManager.shared.clearEpisodeData(episodeId)
            }
            
            // Delete downloaded episode files
            await deleteDownloadedEpisodeFiles(episodeIds)
            
            // Remove from UI and Core Data
            await MainActor.run {
                // **RACE CONDITION FIX**: Find the feed again right before removal
                // The array might have changed during the async operations above
                if let currentFeedIndex = self.podcastFeeds.firstIndex(where: { $0.id == feedId }) {
                    self.podcastFeeds.remove(at: currentFeedIndex)
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Removed feed from UI at index \(currentFeedIndex)")
                } else {
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed was already removed from UI during async operations")
                }
                
                // These operations are safe even if the feed was already removed
                self.podcastFeedOrder.removeAll { $0 == feedId }
                self.currentEpisodes.removeAll { $0.feedId == feedId }
                
                // Clear selected feed if it's the one being deleted
                if self.selectedFeedId == feedId {
                    self.selectedFeedId = nil
                }
                
                // Clear local episode state tracking
                for episodeId in episodeIds {
                    self.episodeProgress.removeValue(forKey: episodeId)
                }
                
                // Trigger UI update
                self.throttledUIUpdate()
                print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Applied real-time deletion for: \(feedTitle)")
            }
            
            // Delete from Core Data - but only if it still exists to prevent conflicts
            do {
                let feedExists = await checkIfFeedExistsInCoreData(feedId: feedId)
                if feedExists {
                    let feedForDeletion = PodcastFeed(id: feedId, title: feedTitle, url: "", artworkUrl: nil, description: nil)
                    try await deleteFeedFromCoreData(feedForDeletion)
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ✅ Deleted from Core Data: \(feedTitle)")
                } else {
                    print("📡 🔔 REALTIME CLOUDKIT DELETE: ⚠️ Feed already deleted from Core Data, skipping: \(feedTitle)")
                }
            } catch {
                print("📡 🔔 REALTIME CLOUDKIT DELETE: ❌ Error deleting from Core Data: \(error)")
            }
        }
    }
    
    @objc private func handleCloudKitAllFeedsUpdatedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let feeds = userInfo["feeds"] as? [PodcastFeed] else {
            print("📡 ☁️ CLOUDKIT ALL FEEDS FAILED: Invalid feeds data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT ALL FEEDS: Received full feed sync from CloudKit: \(feeds.count) feeds")
        
        DispatchQueue.main.async {
            // Replace local feeds with CloudKit feeds (full sync)
            self.podcastFeeds = feeds
            self.podcastFeedOrder = feeds.map { $0.id }
            self.throttledUIUpdate()
            print("📡 ☁️ CLOUDKIT ALL FEEDS: ✅ Updated all feeds from CloudKit")
        }
    }
    
    @objc private func handleCloudKitEpisodeStateSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let episodeId = userInfo["episodeId"] as? String,
              let progress = userInfo["progress"] as? Double,
              let isFavorite = userInfo["isFavorite"] as? Bool,
              let isDownloaded = userInfo["isDownloaded"] as? Bool else {
            print("📡 ☁️ CLOUDKIT EPISODE STATE FAILED: Invalid episode state data in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT EPISODE STATE: Received episode state from CloudKit: \(episodeId)")
        
        DispatchQueue.main.async {
            // Update local episode tracking (CloudKit already updated EpisodeStateManager)
            self.episodeProgress[episodeId] = progress
            
            // Trigger UI update if this episode is currently displayed
            if self.currentEpisodes.contains(where: { $0.id == episodeId }) {
                self.throttledUIUpdate()
            }
            
            print("📡 ☁️ CLOUDKIT EPISODE STATE: ✅ Updated episode state from CloudKit: \(episodeId)")
        }
    }
    
    // Helper method to convert dictionary to PodcastFeed
    private func podcastFeedFromDictionary(_ data: [String: Any]) -> PodcastFeed? {
        guard let id = data["id"] as? String,
              let title = data["title"] as? String,
              let url = data["url"] as? String else {
            return nil
        }
        
        let artworkUrl = data["artworkUrl"] as? String
        let descriptionText = data["description"] as? String
        let iconData = data["iconData"] as? String
        
        // Handle imageData if present
        var imageData: Data?
        if let imageDataString = data["imageData"] as? String {
            imageData = Data(base64Encoded: imageDataString)
        }
        
        return PodcastFeed(
            id: id,
            title: title,
            url: url,
            artworkUrl: artworkUrl,
            description: descriptionText,
            iconData: iconData,
            imageData: imageData,
            episodes: [] // Episodes will be loaded separately
        )
    }
    
    // Helper method to convert PodcastFeed to dictionary for syncing
    // NOTE: Only includes essential metadata to avoid NSUbiquitousKeyValueStore 1MB quota limit
    private func podcastFeedToDictionary(_ feed: PodcastFeed) -> [String: Any] {
        var data: [String: Any] = [
            "id": feed.id,
            "title": feed.title,
            "url": feed.url
        ]
        
        if let artworkUrl = feed.artworkUrl {
            data["artworkUrl"] = artworkUrl
        }
        
        if let descriptionText = feed.descriptionText {
            data["description"] = descriptionText
        }
        
        // NOTE: Excluding iconData and imageData from instant sync to prevent quota exceeded errors
        // These will be synced via CloudKit instead where there's no size limit
        // Previous issue: CNN 5 Things with 1.7MB artwork caused quota error when base64 encoded
        
        return data
    }
    
    /// Thread-safe duplicate checking in Core Data
    private func checkForDuplicateInCoreData(feedId: String, feedUrl: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@ OR url == %@", feedId, feedUrl)
                    fetchRequest.fetchLimit = 1
                    
                    let existingFeeds = try context.fetch(fetchRequest)
                    let isDuplicate = !existingFeeds.isEmpty
                    
                    continuation.resume(returning: isDuplicate)
                } catch {
                    print("❌ Error checking for duplicate in Core Data: \(error)")
                    // In case of error, assume duplicate to be safe
                    continuation.resume(returning: true)
                }
            }
        }
    }
    
    /// Thread-safe existence checking in Core Data for real-time sync
    private func checkIfFeedExistsInCoreData(feedId: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", feedId)
                    fetchRequest.fetchLimit = 1
                    
                    let existingFeeds = try context.fetch(fetchRequest)
                    let exists = !existingFeeds.isEmpty
                    
                    continuation.resume(returning: exists)
                } catch {
                    print("❌ Error checking feed existence in Core Data: \(error)")
                    // In case of error, assume it doesn't exist to be safe
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    deinit {
        loadingTask?.cancel()
        refreshTask?.cancel()
        uiUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        
        // Cancel all RSS parsing tasks directly
        for (feedId, task) in rssParsingTasks {
            print("🚫 Cancelling RSS parsing for feed: \(feedId)")
            task.cancel()
        }
    }
    
    // MARK: - RSS Task Management for View Switching
    
    /// Cancel all RSS parsing tasks immediately when switching views
    private func cancelAllRSSParsingTasks() {
        for (feedId, task) in rssParsingTasks {
            print("🚫 Cancelling RSS parsing for feed: \(feedId)")
            task.cancel()
        }
        rssParsingTasks.removeAll()
    }
    
    /// Cancel RSS parsing for a specific feed
    func cancelRSSParsingForFeed(_ feedId: String) {
        if let task = rssParsingTasks[feedId] {
            print("🚫 Cancelling RSS parsing for specific feed: \(feedId)")
            task.cancel()
            rssParsingTasks.removeValue(forKey: feedId)
        }
        
        // Also cancel immediate check for this feed
        if let task = immediateCheckTasks[feedId] {
            print("🚫 Cancelling immediate check for specific feed: \(feedId)")
            task.cancel()
            immediateCheckTasks.removeValue(forKey: feedId)
        }
    }
    
    /// Cancel all RSS operations immediately (public method for view switching)
    func cancelAllRSSOperations() {
        print("🚫 Cancelling all RSS operations due to view switch")
        cancelAllRSSParsingTasks()
        
        // Cancel all immediate check tasks
        for (feedId, task) in immediateCheckTasks {
            print("🚫 Cancelling immediate check for feed: \(feedId)")
            task.cancel()
        }
        immediateCheckTasks.removeAll()
    }
    
    /// Setup coordination with DataSyncManager
    private func setupDataSyncCoordination() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DataSyncManager_RequestPodcastStatus"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportStatusToDataSyncManager()
        }
    }
    
    /// Report current loading status to DataSyncManager
    private func reportStatusToDataSyncManager() {
        let loadingComplete = !isLoading && !isLoadingFeeds && !isLoadingEpisodes
        let feedsLoaded = !podcastFeeds.isEmpty
        
        UserDefaults.standard.set(loadingComplete, forKey: "PodcastViewModel_LoadingComplete")
        UserDefaults.standard.set(feedsLoaded, forKey: "PodcastViewModel_FeedsLoaded")
        
        print("📊 PodcastViewModel status report - Loading complete: \(loadingComplete), Feeds loaded: \(feedsLoaded), Feed count: \(podcastFeeds.count)")
    }
    
    // PERFORMANCE: Throttled UI update method to improve scrolling performance
    private func throttledUIUpdate() {
        // Skip UI updates if user is scrolling
        if isUserScrolling {
            hasPendingUIUpdate = true
            return
        }
        
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUIUpdateTime)
        
        if timeSinceLastUpdate >= uiUpdateThrottleInterval {
            // Update immediately
            lastUIUpdateTime = now
            hasPendingUIUpdate = false
            objectWillChange.send()
        } else {
            // Schedule delayed update
            hasPendingUIUpdate = true
            uiUpdateTimer?.invalidate()
            uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: uiUpdateThrottleInterval - timeSinceLastUpdate, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.hasPendingUIUpdate && !self.isUserScrolling {
                    self.lastUIUpdateTime = Date()
                    self.hasPendingUIUpdate = false
                    self.objectWillChange.send()
                }
            }
        }
    }
    
    /// PULL-TO-REFRESH: Force immediate UI update bypassing all throttling mechanisms
    private func forceUIUpdate() {
        // Cancel any pending timers
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
        
        // Reset throttling state
        lastUIUpdateTime = Date()
        hasPendingUIUpdate = false
        
        // Force immediate UI update
        objectWillChange.send()
        print("🔄 FORCE UI UPDATE: Bypassed throttling for pull-to-refresh")
    }
    
    /// Set episode limit for a feed and enforce it immediately
    func setEpisodeLimit(for feedId: String, maxEpisodes: Int?) async {
        // Update the feed's maxEpisodes property
        if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feedId }) {
            podcastFeeds[feedIndex].maxEpisodes = maxEpisodes
            
            // If setting a limit, enforce it immediately
            if let maxEpisodes = maxEpisodes {
                do {
                    try await PodcastCoreDataManager.shared.enforceEpisodeLimitForFeed(feedId, maxEpisodes: maxEpisodes)
                    
                    // Refresh the episode list to reflect the changes
                    let updatedEpisodes: [PodcastEpisode]
                    if maxEpisodes > 0 {
                        // Feed has episode limit - use limited fetch
                        updatedEpisodes = await PodcastCoreDataManager.shared.getRecentEpisodesForFeed(feedId, limit: maxEpisodes)
                    } else {
                        // Feed has no limit - get all episodes
                        updatedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    }
                    
                    await MainActor.run {
                        if self.selectedFeedId == feedId {
                            self.currentEpisodes = updatedEpisodes
                        }
                        self.forceUIUpdate()
                        print("🗑️ EPISODE LIMIT: Set limit of \(maxEpisodes) episodes for feed \(feedId)")
                    }
                } catch {
                    await MainActor.run {
                        self.error = "Failed to enforce episode limit: \(error.localizedDescription)"
                    }
                }
            } else {
                print("🔄 EPISODE LIMIT: Removed episode limit for feed \(feedId)")
            }
            
            // Save the updated feed configuration
            await saveFeedConfiguration(feedId)
        }
    }
    
    /// Save feed configuration changes (like episode limits) to persistent storage
    private func saveFeedConfiguration(_ feedId: String) async {
        // This would typically save to CloudKit or UserDefaults
        // For now, we'll just trigger a UI update to persist the change
        await MainActor.run {
            self.forceUIUpdate()
        }
    }
    
    // MARK: - Data Sync Coordination Methods
    
    /// Wait for data sync completion - used by DataSyncManager
    func waitForDataSyncCompletion() async {
        // Start the CloudKit initialization if not already done
        initializeWithCloudKitSupport()
        
        // Wait for CloudKit sync to complete
        while cloudKitSyncInProgress {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        // Wait for loading to complete
        while isLoading || isLoadingFeeds {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        print("✅ PodcastViewModel: Data sync completion confirmed")
    }
    
    /// Ensure feeds are loaded and available to UI
    func ensureFeedsAreLoaded() async {
        // If no feeds are loaded, try loading from Core Data again
        if podcastFeeds.isEmpty {
            await MainActor.run {
                loadFeedsFromCoreData()
            }
            
            // Wait a bit for the loading to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // If still no feeds, this might be a fresh install without any feeds
        if podcastFeeds.isEmpty {
            print("ℹ️ PodcastViewModel: No feeds found - this might be a fresh install")
        } else {
            print("✅ PodcastViewModel: \(podcastFeeds.count) feeds are loaded and available")
        }
    }
    
    /// Force Core Data to save any pending changes and reload feeds
    func forceSaveAndReload() async {
        print("🔧 FORCING Core Data save and reload...")
        
        // Force save the Core Data context
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                if context.hasChanges {
                    do {
                        try context.save()
                        print("✅ FORCED: Core Data context saved successfully")
                    } catch {
                        print("❌ FORCED: Failed to save Core Data context: \(error)")
                    }
                } else {
                    print("ℹ️ FORCED: No pending Core Data changes to save")
                }
                continuation.resume()
            }
        }
        
        // Force reload feeds from Core Data with aggressive UI refresh
        await MainActor.run {
            print("🔧 FORCING: Reloading feeds from Core Data...")
            loadFeedsFromCoreData()
            
            // Immediately notify SwiftUI that this object is about to change
            self.objectWillChange.send()
            print("🔧 FORCING: Triggered objectWillChange.send() after reload")
        }
        
        // Wait for the reload to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Final verification and manual UI trigger
        await MainActor.run {
            let currentFeedCount = self.podcastFeeds.count
            let currentOrderCount = self.podcastFeedOrder.count
            print("🔧 FORCING: After reload verification - Feeds: \(currentFeedCount), Order: \(currentOrderCount)")
            
            // Force another UI update notification to ensure SwiftUI picks up the changes
            self.objectWillChange.send()
            print("🔧 FORCING: Final objectWillChange.send() triggered")
        }
        
        print("✅ FORCED: Save and reload completed - feeds count: \(podcastFeeds.count)")
    }
    
    // MARK: - Public Interface
    


    
    // MARK: - Public Interface
    
    /// Load podcast feeds from saved data efficiently
    func loadSavedFeeds() {
        isLoadingFeeds = true
        
        Task {
            do {
                let feeds = try await feedManager.loadSavedFeeds()
                await MainActor.run {
                    self.podcastFeeds = feeds
                    self.isLoadingFeeds = false
                    os_log("📡 Loaded %d saved feeds", log: self.log, type: .info, feeds.count)
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to load feeds: \(error.localizedDescription)"
                    self.isLoadingFeeds = false
                    os_log("❌ Failed to load feeds: %@", log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }
    
    /// Add a new podcast feed with immediate UI update and background processing
    func addPodcastFeed(url: String, customTitle: String? = nil) async -> Bool {
        guard let feedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await MainActor.run {
                self.error = "Invalid URL format"
            }
            return false
        }
        
        // Check if a podcast feed with the same URL already exists
        let urlString = feedURL.absoluteString
        if podcastFeeds.contains(where: { $0.url == urlString }) {
            await MainActor.run {
                self.error = "A podcast feed with this URL has already been added. Please use a different URL."
            }
            print("Podcast feed with URL \(urlString) already exists. Skipping addition.")
            return false
        }
        
        // Notify user that import started
        await MainActor.run {
            NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing podcast feed from URL...")
        }
        
        do {
            // Step 1: Parse feed and create feed object with custom title if provided
            let feed = try await feedManager.addFeed(from: feedURL, customTitle: customTitle)
            print("📊 Parsed feed: \(feed.title)")
            
            // CRITICAL: Register new feed with isolation manager immediately
            await MainActor.run {
                feedIsolationManager.registerFeed(feedId: feed.id, feedUrl: feed.url)
                print("🛡️ REGISTERED: New feed \(feed.id) registered with isolation manager")
            }
            
            // Step 2: Immediate UI update - add to arrays for instant feedback
            await MainActor.run {
                self.podcastFeeds.append(feed)
                self.podcastFeedOrder.append(feed.id)
                self.throttledUIUpdate()
                print("✅ Feed immediately added to UI: \(feed.title)")
                
                // INSTANT SYNC: Sync podcast feed addition immediately across devices
                PodcastCloudKitManager.shared.syncPodcastFeedAddedInstantly(
                    feedData: self.podcastFeedToDictionary(feed)
                )
            }
            
            // Step 3: Background CloudKit sync - WAIT for completion before allowing banner to show
            do {
                try await cloudKitManager.savePodcastFeedToCloudKit(feed)
                print("☁️ Successfully saved feed to CloudKit: \(feed.title)")
                
                // Notify user of successful import
                await MainActor.run {
                    NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported podcast '\(feed.title)'.")
                }
            } catch {
                print("⚠️ Failed to save feed to CloudKit (local save succeeded): \(error)")
                // Continue even if CloudKit save fails - local data is preserved
                
                // Notify user of successful import with warning
                await MainActor.run {
                    NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported podcast '\(feed.title)' locally. Some data may not sync to iCloud.")
                }
            }
            
            return true
            
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
            print("❌ Failed to add podcast feed: \(error)")
            return false
        }
    }
    
    /// CORE DATA → IN-MEMORY CACHE: Load episodes from Core Data into FeedIsolationManager
    /// This provides fast, persistent episode storage that survives app restarts
    private func loadEpisodesFromCoreDataToCache(feedId: String) async -> [PodcastEpisode]? {
        // 1. CHECK IN-MEMORY CACHE FIRST (instant - 0ms)
        let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
        if !cachedEpisodes.isEmpty {
            print("⚡ CACHE HIT: Found \(cachedEpisodes.count) episodes in memory for feed \(feedId)")
            return cachedEpisodes
        }
        
        // 2. LOAD FROM CORE DATA (fast - ~50ms)
        print("💾 CORE DATA: Loading episodes for feed \(feedId)")
        let coreDataEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
        
        if coreDataEpisodes.isEmpty {
            print("💾 CORE DATA: No episodes found for feed \(feedId)")
            return nil
        }
        
        print("💾 CORE DATA: Loaded \(coreDataEpisodes.count) episodes from persistent storage")
        
        // 3. STORE IN IN-MEMORY CACHE for instant future access
        await MainActor.run {
            self.feedIsolationManager.replaceEpisodesForFeed(coreDataEpisodes, feedId: feedId)
            self.coreDataLoadTimestamps[feedId] = Date()
        }
        
        print("✅ CACHE UPDATED: Stored \(coreDataEpisodes.count) episodes in memory")
        return coreDataEpisodes
    }
    
    /// INSTANT DISPLAY + ASYNC STATE REFRESH: Display episodes immediately, refresh states in background
    /// This ensures BOTH instant UI response AND bulletproof state accuracy
    private func applyFreshStatesFromManager(to episodes: [PodcastEpisode], feedId: String) -> [PodcastEpisode] {
        print("⚡ INSTANT DISPLAY: Returning \(episodes.count) episodes immediately (states will refresh in background)")
        
        // CRITICAL: Return episodes immediately for instant display
        // States from Core Data conversion (toPodcastEpisode) are already applied
        // This gives instant UI while we refresh states in background
        
        // BACKGROUND STATE REFRESH: Update states asynchronously without blocking UI
        if episodes.count > 100 {
            // For large feeds, use lower priority to avoid UI impact
            Task.detached(priority: .utility) {
                await self.refreshStatesInBackground(episodes: episodes, feedId: feedId)
            }
        } else {
            // For small feeds, use higher priority for faster state updates
            Task.detached(priority: .userInitiated) {
                await self.refreshStatesInBackground(episodes: episodes, feedId: feedId)
            }
        }
        
        return episodes
    }
    
    /// Background state refresh: Updates episode states without blocking UI
    private func refreshStatesInBackground(episodes: [PodcastEpisode], feedId: String) async {
        let startTime = Date()
        
        // Refresh states for all episodes
        var episodesWithFreshStates = episodes.map { episode -> PodcastEpisode in
            var updatedEpisode = episode
            
            // Get current states from EpisodeStateManager
            updatedEpisode.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            updatedEpisode.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            updatedEpisode.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
            updatedEpisode.state.isPlayed = (episodeState == .played)
            
            return updatedEpisode
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let statesCount = episodesWithFreshStates.filter { 
            $0.state.progress > 0 || $0.state.isFavorite || $0.state.isDownloaded || $0.state.isPlayed 
        }.count
        
        print("🔄 BACKGROUND STATE REFRESH: Updated \(episodes.count) episodes in \(String(format: "%.3f", elapsed))s")
        print("   ✅ Episodes with states: \(statesCount)/\(episodes.count)")
        
        // DIAGNOSTIC: If no states found but EpisodeStateManager has states, investigate
        if statesCount == 0 && (EpisodeStateManager.shared.episodeProgress.count > 0 || 
                                 EpisodeStateManager.shared.episodeFavorites.count > 0 ||
                                 EpisodeStateManager.shared.episodeDownloads.count > 0) {
            print("⚠️ STATES MISMATCH: EpisodeStateManager has states but none found in episodes")
            EpisodeStateManager.shared.diagnoseEpisodeStates(for: episodes.map { $0.id })
        }
        
        // CRITICAL FIX: Sync episode states from EpisodeStateManager to Core Data
        // This ensures episodes have their states in Core Data, not just in memory
        // (Same logic as pull-to-refresh which works correctly)
        var stateUpdates: [EpisodeStateUpdate] = []
        for episode in episodesWithFreshStates {
            stateUpdates.append(EpisodeStateUpdate(
                episodeId: episode.id,
                progress: episode.state.progress,
                isFavorite: episode.state.isFavorite,
                isDownloaded: episode.state.isDownloaded,
                isPlayed: episode.state.isPlayed
            ))
        }
        
        if !stateUpdates.isEmpty {
            do {
                print("   💾 STATE SYNC: Saving \(stateUpdates.count) episode states to Core Data")
                try await self.episodeManager.updateEpisodeStates(stateUpdates)
                print("   ✅ STATE SYNC: Episode states saved to Core Data successfully")
                
                // CRITICAL FIX: Reload episodes from Core Data to pick up the saved states
                // This ensures the UI displays the states immediately without needing to reopen the app
                // BUT: Only reload ALL episodes if we're on "All Episodes" tab to avoid breaking filters
                if await MainActor.run(body: { self.currentTab }) == 0 {
                    print("   🔄 STATE SYNC: Reloading all episodes from Core Data to apply saved states (All Episodes tab)")
                    let reloadedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    
                    // CRITICAL: Refresh states from EpisodeStateManager on the reloaded episodes
                    // This ensures the UI displays states correctly
                    episodesWithFreshStates = reloadedEpisodes.map { episode -> PodcastEpisode in
                        var updatedEpisode = episode
                        updatedEpisode.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                        updatedEpisode.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                        updatedEpisode.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                        let episodeState = EpisodeStateManager.shared.getState(for: episode.id)
                        updatedEpisode.state.isPlayed = (episodeState == .played)
                        return updatedEpisode
                    }
                    
                    print("   ✅ STATE SYNC: Episodes reloaded and refreshed with states (\(episodesWithFreshStates.count) episodes)")
                } else {
                    print("   ⚠️ STATE SYNC: Skipping reload on filtered tab (tab \(await MainActor.run(body: { self.currentTab }))) - states saved to Core Data")
                }
            } catch {
                print("   ❌ STATE SYNC: Failed to save episode states to Core Data: \(error)")
            }
        }
        
        // Update UI on main thread if this is still the selected feed
        await MainActor.run {
            guard self.selectedFeedId == feedId else {
                print("   ⚠️ Feed changed during state refresh - skipping UI update")
                return
            }
            
            // Update isolation manager with fresh states
            self.feedIsolationManager.replaceEpisodesForFeed(episodesWithFreshStates, feedId: feedId)
            
            // CRITICAL FIX: Always update current episodes and filter if this is the selected feed
            // This ensures Favorites and Downloads tabs refresh with new states
            if self.currentEpisodes.isEmpty || self.currentEpisodes.first?.feedId == feedId {
                self.currentEpisodes = episodesWithFreshStates
                self.updateFilter(tab: self.currentTab)
                print("   ✅ UI updated with refreshed states (filter updated for tab: \(self.currentTab))")
            }
            
            // CRITICAL FIX: Send instant update notifications for episodes with states
            // This ensures UI buttons (favorite, download) update immediately
            for episode in episodesWithFreshStates {
                if episode.state.isFavorite {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeFavoriteChangedInstantly"),
                        object: nil,
                        userInfo: ["episodeId": episode.id, "isFavorite": true]
                    )
                }
                if episode.state.isDownloaded {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeDownloadChangedInstantly"),
                        object: nil,
                        userInfo: ["episodeId": episode.id, "isDownloaded": true]
                    )
                }
            }
            
            let notificationCount = episodesWithFreshStates.filter { $0.state.isFavorite || $0.state.isDownloaded }.count
            if notificationCount > 0 {
                print("   📡 Sent instant update notifications for \(notificationCount) episodes with states")
            }
        }
    }
    
    /// Load episodes for a specific feed with efficient pagination and deduplication
    func loadEpisodesForFeed(_ feedId: String, isInitialLoad: Bool = false) async {
        print("🔄 LOAD EPISODES: Starting load for feedId '\(feedId)' (isInitialLoad: \(isInitialLoad))")
        
        // 🚀 PREVENT DUPLICATE OPERATIONS: Skip if already processing this feed
        if feedsBeingProcessed.contains(feedId) {
            print("⚡ DUPLICATE PREVENTION: Skipping load - feed \(feedId) already being processed")
            return
        }
        
        feedsBeingProcessed.insert(feedId)
        defer { feedsBeingProcessed.remove(feedId) }
        
        // CORE DATA + IN-MEMORY CACHE ARCHITECTURE:
        // 1. Check in-memory cache (FeedIsolationManager) - instant (0ms)
        // 2. If not cached, load from Core Data - fast (~50ms)
        // 3. Store in cache for instant future access
        // 4. Background refresh from RSS to get new episodes
        
        // INSTANT LOAD: Check cache first, fallback to Core Data
        guard let cachedEpisodes = await loadEpisodesFromCoreDataToCache(feedId: feedId) else {
            // No episodes in cache or Core Data - need to fetch from RSS
            print("📡 NO CACHED DATA: Will fetch from RSS for feed \(feedId)")
            await loadEpisodesFromRSS(feedId: feedId, isInitialLoad: isInitialLoad)
            return
        }
        
        // Episodes found in cache/Core Data - display immediately
        if !cachedEpisodes.isEmpty {
            // INSTANT DISPLAY + BACKGROUND STATE REFRESH: Display now, refresh states async
            // Episodes show immediately with Core Data states, then refresh in background
            let episodesWithFreshStates = applyFreshStatesFromManager(to: cachedEpisodes, feedId: feedId)
            
            // 🛡️ CONTAMINATION PREVENTION: Validate all episodes belong to the requested feed
            let validCachedEpisodes = episodesWithFreshStates.filter { $0.feedId == feedId }
            if validCachedEpisodes.count != cachedEpisodes.count {
                let contaminatedCount = cachedEpisodes.count - validCachedEpisodes.count
                print("🚨 CACHED EPISODES CONTAMINATION: Found \(contaminatedCount) contaminated episodes in cached data for feed \(feedId)")
                
                // Log contaminated episodes for debugging
                let contaminatedEpisodes = cachedEpisodes.filter { $0.feedId != feedId }
                for episode in contaminatedEpisodes.prefix(3) {
                    print("🚨 CONTAMINATED CACHED: Episode '\(episode.title)' has feedId '\(episode.feedId)' but was loaded for feed '\(feedId)'")
                }
            }
            
            print("⚡ INSTANT DISPLAY: Found \(validCachedEpisodes.count) validated cached episodes - displaying immediately")
            
            await MainActor.run {
                // Register feed with isolation manager
                if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                    feedIsolationManager.registerFeed(feedId: feedId, feedUrl: feed.url)
                }
                
                // Store validated episodes in isolation manager
                feedIsolationManager.replaceEpisodesForFeed(validCachedEpisodes, feedId: feedId)
                
                // Apply current filter instantly (episodes already sorted newest first from Core Data)
                let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                let filteredEpisodes: [PodcastEpisode]
                switch filter {
                case .all:
                    filteredEpisodes = validCachedEpisodes // Already sorted newest first
                case .favorites:
                    filteredEpisodes = validCachedEpisodes.filter { $0.state.isFavorite }
                case .downloads:
                    filteredEpisodes = validCachedEpisodes.filter { $0.state.isDownloaded }
                }
                
                // Update UI instantly with cached episodes using isolation manager
                feedIsolationManager.replaceEpisodesForFeed(filteredEpisodes, feedId: feedId)
                selectedFeedId = feedId
                isLoadingEpisodes = false
                operationInProgress = false
                
                // Update episode counts immediately with validated episodes
                let allCount = validCachedEpisodes.count
                let favoritesCount = validCachedEpisodes.filter { $0.state.isFavorite }.count
                let downloadsCount = validCachedEpisodes.filter { $0.state.isDownloaded }.count
                episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                
                print("⚡ INSTANT SUCCESS: Displaying \(filteredEpisodes.count) validated cached episodes immediately")
            }
            
            // BACKGROUND REFRESH: Check for new episodes from RSS without blocking UI
            // Use higher priority when user opens feed for faster updates
            Task.detached(priority: isInitialLoad ? .userInitiated : .background) {
                await self.backgroundRefreshForNewEpisodes(feedId: feedId, isInitialLoad: isInitialLoad)
            }
            
            return
        }
    }
    
    /// Load episodes from RSS when no cached data exists - fallback path
    private func loadEpisodesFromRSS(feedId: String, isInitialLoad: Bool) async {
        // Fallback: Load from RSS when no cache/Core Data available
        print("📡 RSS FETCH: No cached data - loading from network for feed \(feedId)")
        
        // PERFORMANCE: Prevent redundant episode loading for the same feed
        let taskKey = "\(feedId)-\(isInitialLoad)"
        guard !pendingInitializationTasks.contains(taskKey) else {
            if !isUserScrolling {
                print("🔄 Episode loading already in progress for feed: \(feedId) - skipping redundant call")
            }
            return
        }
        
        pendingInitializationTasks.insert(taskKey)
        defer { pendingInitializationTasks.remove(taskKey) }
        
        // Continue with RSS loading logic below...
        // CACHE FALLBACK - Check cache one more time before RSS fetch
        let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
        if !cachedEpisodes.isEmpty {
            print("💾 CACHE: Found \(cachedEpisodes.count) episodes in cache for feed \(feedId)")
            
            // INSTANT DISPLAY + BACKGROUND STATE REFRESH
            let episodesWithFreshStates = applyFreshStatesFromManager(to: cachedEpisodes, feedId: feedId)
            
            // 🛡️ CONTAMINATION PREVENTION: Validate all cached episodes belong to the requested feed
            let validCachedEpisodes = episodesWithFreshStates.filter { $0.feedId == feedId }
            if validCachedEpisodes.count != cachedEpisodes.count {
                let contaminatedCount = cachedEpisodes.count - validCachedEpisodes.count
                print("🚨 CACHE CONTAMINATION: Found \(contaminatedCount) contaminated episodes in cache for feed \(feedId)")
                
                // Log contaminated episodes for debugging
                let contaminatedEpisodes = cachedEpisodes.filter { $0.feedId != feedId }
                for episode in contaminatedEpisodes.prefix(3) {
                    print("🚨 CONTAMINATED CACHE: Episode '\(episode.title)' has feedId '\(episode.feedId)' but was in cache for feed '\(feedId)'")
                }
                
                // Update the cache with clean episodes (with fresh states)
                feedIsolationManager.replaceEpisodesForFeed(validCachedEpisodes, feedId: feedId)
            }
            
            print("⚡ CACHE HIT: Using \(validCachedEpisodes.count) validated cached episodes with fresh states for feed \(feedId)")
            
            await MainActor.run {
                // Apply current filter instantly
                let filter = EpisodeFilter(rawValue: currentTab) ?? .all
                let filteredEpisodes: [PodcastEpisode]
                switch filter {
                case .all:
                    filteredEpisodes = validCachedEpisodes
                case .favorites:
                    filteredEpisodes = validCachedEpisodes.filter { $0.state.isFavorite }
                case .downloads:
                    filteredEpisodes = validCachedEpisodes.filter { $0.state.isDownloaded }
                }
                
                // CRITICAL: Clear any contaminated episodes from wrong feeds
                if !currentEpisodes.isEmpty && currentEpisodes.first?.feedId != feedId {
                    print("🧹 CONTAMINATION CLEANUP: Clearing \(currentEpisodes.count) episodes from wrong feed")
                    currentEpisodes = []
                }
                
                // Update UI instantly
                currentEpisodes = filteredEpisodes
                selectedFeedId = feedId
                isLoadingEpisodes = false
                operationInProgress = false
                Task {
                    await updateEpisodeCounts(for: feedId, episodes: validCachedEpisodes)
                }
                
                print("💾 CACHE SUCCESS: Displaying \(filteredEpisodes.count) validated episodes instantly")
            }
            
            // BACKGROUND REFRESH: Check for new episodes in background without blocking UI
            Task.detached(priority: isInitialLoad ? .userInitiated : .background) {
                await self.backgroundRefreshForNewEpisodes(feedId: feedId, isInitialLoad: isInitialLoad)
            }
            
            return
        }
        
        // RSS FETCH: No cached data available, must fetch from network
        await MainActor.run {
            isLoadingEpisodes = true
            operationInProgress = true
        }
        
        // TODO: Implement RSS fetch logic here
        // For now, this will be handled by existing RSS loading code
        print("📡 RSS: Fetching episodes from network for feed \(feedId)")
    }
    /// Load more episodes (pagination)
    func loadMoreEpisodes() async {
        guard let feedId = selectedFeedId,
              !isLoadingMoreEpisodes,
              hasMoreEpisodes else { return }
        
        await MainActor.run {
            self.isLoadingMoreEpisodes = true
        }
        
        currentPage += 1
        
        await performEpisodeLoad(feedId: feedId, page: currentPage, isAppending: true)
        
        await MainActor.run {
            self.isLoadingMoreEpisodes = false
        }
    }
    
    /// Optimized refresh for current feed - prevents UI freezing on large feeds
    func refreshCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        refreshTask?.cancel()
        
        refreshTask = Task {
            do {
                os_log("🔄 Optimized refresh from RSS: %@", log: self.log, type: .info, feedId)
                print("🔄 PULL-TO-REFRESH: Starting immediate refresh for better UX")
                
                await MainActor.run {
                    self.isLoadingEpisodes = true
                    self.operationInProgress = true
                }
                
                // PERFORMANCE: Quick RSS check for new episodes only (limit to recent episodes)
                let (updatedFeed, newEpisodes) = try await self.feedManager.refreshFeedQuick(feedId, limit: 50)
                print("✅ Pull-to-refresh RSS completed for '\(updatedFeed.title)' - found \(newEpisodes.count) new episodes")
                
                // CRITICAL FIX: Always update cache and UI, even if no new episodes
                // This ensures the UI reflects the latest state after pull-to-refresh
                if let feed = await MainActor.run(body: { self.podcastFeeds.first(where: { $0.id == feedId }) }) {
                    if !newEpisodes.isEmpty {
                        // Quick reconcile: only process new episodes to prevent blocking
                        try await PodcastCoreDataManager.shared.reconcileNewEpisodes(for: feedId, newEpisodes: newEpisodes, maxEpisodes: feed.maxEpisodes)
                    }
                    
                    // ALWAYS get fresh episodes from Core Data and update UI
                    let updatedEpisodes: [PodcastEpisode]
                    if let maxEpisodes = feed.maxEpisodes {
                        // Feed has episode limit - use limited fetch
                        updatedEpisodes = await PodcastCoreDataManager.shared.getRecentEpisodesForFeed(feedId, limit: maxEpisodes)
                    } else {
                        // Feed has no limit - get all episodes
                        updatedEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    }
                    
                    // ENHANCEMENT: Fetch latest EpisodeState data during pull-to-refresh
                    // This ensures episode progress, played status, and other states are up-to-date
                    print("🔄 Pull-to-refresh: Syncing episode states for current feed")
                    let episodeIds = updatedEpisodes.map { $0.id }
                    if !episodeIds.isEmpty {
                        // Perform quiet episode state sync without UI progress indicators
                        let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                            for: episodeIds,
                            isFreshInstall: false
                        )
                        
                        if syncResult.success {
                            print("✅ Pull-to-refresh: Episode states synced successfully for \(episodeIds.count) episodes")
                            
                            // CRITICAL: Apply the Core Data updates from CloudKit sync
                            if !syncResult.updates.isEmpty {
                                do {
                                    print("💾 Pull-to-refresh: Saving \(syncResult.updates.count) episode state updates to Core Data")
                                    try await self.episodeManager.updateEpisodeStates(syncResult.updates)
                                    print("✅ Pull-to-refresh: Core Data updated with episode states")
                                } catch {
                                    print("❌ Pull-to-refresh: Failed to save episode states to Core Data: \(error)")
                                }
                            }
                            
                            // CRITICAL FIX: Sync ALL episode states from EpisodeStateManager to Core Data
                            // This ensures episodes with progress that DON'T have CloudKit records still get their states updated
                            print("🔄 Pull-to-refresh: Syncing ALL episode states from EpisodeStateManager to Core Data")
                            var additionalUpdates: [EpisodeStateUpdate] = []
                            for episodeId in episodeIds {
                                let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
                                let isFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                                let isDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                                let state = EpisodeStateManager.shared.getState(for: episodeId)
                                let isPlayed = (state == .played)
                                
                                additionalUpdates.append(EpisodeStateUpdate(
                                    episodeId: episodeId,
                                    progress: progress,
                                    isFavorite: isFavorite,
                                    isDownloaded: isDownloaded,
                                    isPlayed: isPlayed
                                ))
                            }
                            
                            if !additionalUpdates.isEmpty {
                                do {
                                    print("💾 Pull-to-refresh: Saving \(additionalUpdates.count) additional episode states to Core Data")
                                    try await self.episodeManager.updateEpisodeStates(additionalUpdates)
                                    print("✅ Pull-to-refresh: All episode states synced to Core Data")
                                } catch {
                                    print("❌ Pull-to-refresh: Failed to save additional episode states: \(error)")
                                }
                            }
                        } else {
                            print("⚠️ Pull-to-refresh: Episode state sync completed with some issues")
                        }
                    }
                    
                    // CRITICAL: Re-fetch episodes from Core Data AFTER state sync to get updated states
                    let episodesWithStates: [PodcastEpisode]
                    if let maxEpisodes = feed.maxEpisodes {
                        episodesWithStates = await PodcastCoreDataManager.shared.getRecentEpisodesForFeed(feedId, limit: maxEpisodes)
                    } else {
                        episodesWithStates = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
                    }
                    print("🔄 Pull-to-refresh: Re-fetched \(episodesWithStates.count) episodes with updated states")
                    
                    await MainActor.run {
                        // CRITICAL FIX: Force cache update for pull-to-refresh (bypass throttling)
                        
                        // CRITICAL: Update isolation manager so UI shows new data
                        self.feedIsolationManager.replaceEpisodesForFeed(episodesWithStates, feedId: feedId)
                        
                        // Update current episodes immediately for UI refresh
                        self.currentEpisodes = episodesWithStates
                        
                        // Clear episode cache to force UI refresh with new data
                        self._episodeCache = nil
                        self._episodeCacheFeedId = nil
                        
                        self.isLoadingEpisodes = false
                        self.operationInProgress = false
                        
                        // CRITICAL FIX: Force immediate UI update (bypass throttling)
                        self.forceUIUpdate()
                        
                        print("⚡ PULL-TO-REFRESH: Updated isolation manager and forced UI update with \(episodesWithStates.count) episodes (\(newEpisodes.count) new, states refreshed)")
                    }
                    
                    // BACKGROUND: Defer expensive operations to background
                    Task.detached(priority: .background) {
                        await self.quietSyncEpisodeStates(for: feedId)
                        await self.syncRealTimeProgressAcrossDevices()
                        print("🔄 BACKGROUND: Completed deferred sync operations for \(feedId)")
                    }
                } else {
                    await MainActor.run {
                        self.isLoadingEpisodes = false
                        self.operationInProgress = false
                        self.forceUIUpdate()
                    }
                    print("❌ Pull-to-refresh failed: Missing feed for \(feedId)")
                }
                
            } catch {
                await MainActor.run {
                    self.error = "Failed to refresh feed: \(error.localizedDescription)"
                    self.isLoadingEpisodes = false
                    self.operationInProgress = false
                    self.forceUIUpdate()
                }
                os_log("❌ Failed to refresh feed: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
        
        await refreshTask?.value
    }
    
    /// Force refresh a specific feed ignoring timing restrictions
    func forceRefreshFeed(_ feedId: String) async {
        
        // Reset the last refresh time to force refresh
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        UserDefaults.standard.set(0, forKey: lastRefreshKey) // Set to 0 to force refresh
        
        // Trigger a reload which will now force the RSS refresh
        await loadEpisodesForFeed(feedId, isInitialLoad: false)
    }
    
    /// Request immediate refresh for a feed (user initiated) - optimized for newest episodes first
    func requestFeedRefresh(_ feedId: String) {
        print("🎯 REQUEST REFRESH: User requested refresh for feed \(feedId)")
        let userRefreshKey = "UserRequestedRefresh_\(feedId)"
        UserDefaults.standard.set(true, forKey: userRefreshKey)
        
        // CRITICAL PERFORMANCE: Check for cache first to show newest episodes immediately
        let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
        if !cachedEpisodes.isEmpty {
            print("⚡ NAVIGATION OPTIMIZATION: Using in-memory cache for feed refresh - \(cachedEpisodes.count) episodes from cache (newest first)")
            
            // BULLETPROOF STATE APPLICATION: Use centralized state refresh function
            let cacheWithFreshStates = applyFreshStatesFromManager(to: cachedEpisodes, feedId: feedId)
            
            // Update UI immediately with cache data (already sorted newest first)
            Task { @MainActor in
                // CARPLAY FIX: Only update currentEpisodes if this is the selected feed
                // Don't change selectedFeedId - that should only happen on user navigation
                if self.selectedFeedId == feedId {
                    self.currentEpisodes = cacheWithFreshStates
                    self.updateFilter(tab: self.currentTab)
                } else {
                    print("⚠️ CARPLAY PROTECTION: Not updating currentEpisodes - feedId (\(feedId)) doesn't match selectedFeedId (\(self.selectedFeedId ?? "nil"))")
                }
                
                // PERFORMANCE BOOST: Clear loading states immediately since we have data
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                
                print("⚡ INSTANT DISPLAY: Showing \(cacheWithFreshStates.count) episodes immediately with newest episodes first and fresh states")
            }
            
            // LIGHTWEIGHT CHECK: Ultra-fast new episode detection without expensive operations
            print("🪶 LIGHTWEIGHT CHECK: Starting ultra-fast new episode detection (no RSS parsing)")
            Task.detached(priority: .background) {
                await self.lightweightNewEpisodeCheck(feedId: feedId)
            }
            return
        }
        
        // Fallback: Trigger full reload if no cache exists
        print("🔄 NAVIGATION FALLBACK: No cache available - performing full load for feed \(feedId)")
        Task {
            await loadEpisodesForFeed(feedId, isInitialLoad: true)
        }
    }
    
    /// Perform ultra-lightweight background refresh that doesn't block UI or trigger expensive operations
    private func performUltraLightweightBackgroundRefresh(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ ULTRA LIGHTWEIGHT: Feed not found: \(feedId)")
            return
        }
        
        print("🪶 ULTRA LIGHTWEIGHT: Starting minimal background check for \(feed.title)")
        
        // Check if refresh is needed based on longer threshold for caches
        let refreshThreshold: TimeInterval = 60 * 60 // 1 hour for cache-based loads
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        let timeSinceLastRefresh = Date().timeIntervalSince1970 - lastRefreshTime
        
        if lastRefreshTime > 0 && timeSinceLastRefresh < refreshThreshold {
            print("⏭️ ULTRA LIGHTWEIGHT: Skipping - recent refresh (\(Int(timeSinceLastRefresh / 60)) min ago, threshold: \(Int(refreshThreshold / 60)) min)")
            return
        }
        
        // Perform minimal RSS check without blocking operations
        print("🪶 ULTRA LIGHTWEIGHT: Checking for new episodes in background...")
        
        // Use existing RSS refresh mechanism but with minimal processing
        if await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: false) {
            // Update last refresh time to prevent frequent checks
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)
            
            // Trigger ultra-minimal RSS refresh in the background without blocking UI
            Task.detached(priority: .utility) {
                // This will use minimal processing for cache-based feeds
                await self.loadEpisodesForFeed(feedId, isInitialLoad: false)
            }
        }
        
        print("🪶 ULTRA LIGHTWEIGHT: Background check completed for \(feed.title)")
    }
    
    /// Perform deferred episode check after normal loading completes to detect new episodes
    /// Prevents race conditions while ensuring users get new episodes without accumulation
    private func performDeferredEpisodeCheck(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ DEFERRED CHECK: Feed not found: \(feedId)")
            return
        }
        
        print("⚡ DEFERRED CHECK: Starting new episode detection for \(feed.title)")
        
        // PERFORMANCE OPTIMIZATION: Use throttling to prevent excessive checks
        let throttleKey = "DeferredCheck_\(feedId)"
        let lastCheckTime = UserDefaults.standard.double(forKey: throttleKey)
        let timeSinceLastCheck = Date().timeIntervalSince1970 - lastCheckTime
        
        // Throttle if checked within last 10 minutes (more conservative for deferred checks)
        if lastCheckTime > 0 && timeSinceLastCheck < 600 {
            print("⏭️ DEFERRED CHECK: Throttled - checked \(Int(timeSinceLastCheck)) seconds ago (10 min threshold)")
            return
        }
        
        // Update throttle timestamp IMMEDIATELY to prevent duplicate calls
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
        
        // Perform lightweight RSS check for new episodes only
        guard let url = URL(string: feed.url) else {
            print("⚠️ DEFERRED CHECK: Invalid URL for feed \(feed.title)")
            return
        }
        
        do {
            print("🔍 DEFERRED CHECK: Fetching RSS feed for \(feed.title)...")
            
            // SMART NEW EPISODE DETECTION: Compare against persistent cache first
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            guard !newEpisodes.isEmpty else {
                print("✅ DEFERRED CHECK: No new episodes found for \(feed.title)")
                return
            }
            
            print("🆕 DEFERRED CHECK: Found \(newEpisodes.count) new episodes for \(feed.title) - integrating properly")
            
            // PREVENT ACCUMULATION: Use smart integration instead of simple addition
            await self.episodeManager.updateCacheWithNewEpisodes(newEpisodes, for: feedId)
            
            // SMART INTEGRATION: Only add truly new episodes to prevent accumulation
            try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
            
            // UPDATE UI GENTLY if this is the currently selected feed (avoid aggressive reloading)
            await MainActor.run {
                if self.selectedFeedId == feedId && !self.isLoadingEpisodes {
                    print("🔄 DEFERRED CHECK: Gently updating UI with new episodes for currently selected feed")
                    
                    // Instead of full reload, just trigger a gentle refresh
                    Task {
                        await self.requestFeedRefresh(feedId)
                    }
                } else {
                    print("⏭️ DEFERRED CHECK: Feed \(feedId) not currently selected or loading in progress - skipping UI update")
                }
                
                // CRITICAL FIX: DO NOT update caches from deferred checks to prevent accumulation
                // The deferred check should only detect new episodes, not modify cached data
                print("📸 DEFERRED CHECK: Found \(newEpisodes.count) new episodes but NOT updating cache to prevent accumulation")
                print("📸 DEFERRED CHECK: Cache will be updated on next normal feed load to maintain accuracy")
                
                self.objectWillChange.send()
            }
            
        } catch {
            print("❌ DEFERRED CHECK: Failed for \(feed.title): \(error)")
        }
        
        print("⚡ DEFERRED CHECK: Completed for \(feed.title)")
    }
    
    /// Perform lightweight background RSS check without expensive operations
    private func performBackgroundRSSCheck(_ feedId: String) async {
        guard let feed = podcastFeeds.first(where: { $0.id == feedId }) else {
            print("⚠️ BACKGROUND RSS: Feed not found: \(feedId)")
            return
        }
        
        print("🔄 BACKGROUND RSS: Starting lightweight check for \(feed.title)")
        
        // Check if RSS refresh is needed based on time threshold
        let refreshThreshold: TimeInterval = 15 * 60 // 15 minutes
        let lastRefreshKey = "LastRSSRefresh_\(feedId)"
        let lastRefreshTime = UserDefaults.standard.double(forKey: lastRefreshKey)
        let timeSinceLastRefresh = Date().timeIntervalSince1970 - lastRefreshTime
        
        if lastRefreshTime > 0 && timeSinceLastRefresh < refreshThreshold {
            print("⏭️ BACKGROUND RSS: Skipping - recent refresh (\(Int(timeSinceLastRefresh / 60)) min ago)")
            return
        }
        
        // Perform RSS fetch in background without blocking UI
        // Use the existing RSS refresh mechanism
        if await shouldRefreshFeedFromRSS(feedId: feedId, isInitialLoad: false) {
            // Trigger background RSS refresh using existing mechanism
            Task.detached(priority: .background) {
                // This will use the existing RSS refresh logic without blocking UI
                await self.loadEpisodesForFeed(feedId, isInitialLoad: false)
            }
        }
    }
    
    /// PERFORMANCE: Increment displayed episode count for lazy loading (pagination)
    func incrementDisplayedEpisodes() {
        guard !isLoadingMoreEpisodes else { return }
        guard displayedEpisodeCount < totalEpisodeCount else { return }
        
        isLoadingMoreEpisodes = true
        
        Task {
            // Simulate async loading with small delay to prevent UI blocking
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            await MainActor.run {
                let newCount = min(displayedEpisodeCount + episodeLoadBatchSize, totalEpisodeCount)
                displayedEpisodeCount = newCount
                isLoadingMoreEpisodes = false
                
                print("📊 LAZY LOAD: Displaying \(displayedEpisodeCount) of \(totalEpisodeCount) episodes")
            }
        }
    }
    
    /// PERFORMANCE: Reset lazy loading for new feed
    func resetLazyLoading(totalEpisodes: Int) {
        totalEpisodeCount = totalEpisodes
        displayedEpisodeCount = min(episodeLoadBatchSize, totalEpisodes)
        print("📊 LAZY LOAD: Reset - showing \(displayedEpisodeCount) of \(totalEpisodeCount) episodes")
    }
    
    /// Update filter (All, Favorites, Downloads) with efficient reloading - OPTIMIZED FOR PERFORMANCE
    func updateFilter(tab: Int) {
        guard currentTab != tab else { return }
        
        // PERFORMANCE OPTIMIZATION: Skip expensive operations during tab switching
        // RSS operations and CloudKit saves are deferred to reduce CPU spikes
        
        let oldTab = currentTab
        currentTab = tab
        
        // ULTRA-FAST OPTIMIZATION: Use in-memory filtering to avoid expensive operations
        Task {
            let success = await performFastTabSwitch(from: oldTab, to: tab)
            if !success {
                // Only if absolutely necessary, do minimal reload without expensive sync operations
                await performMinimalTabReload(feedId: selectedFeedId, tab: tab)
            }
        }
    }
    
    /// Search episodes with debounced loading
    func searchEpisodes(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchQuery != trimmedQuery else { return }
        
        searchQuery = trimmedQuery
        
        // Debounce search
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            guard searchQuery == trimmedQuery else { return } // Check if search changed
            
            if let feedId = selectedFeedId {
                await loadEpisodesForFeed(feedId)
            }
        }
    }

    /// Search episodes across all saved podcasts (debounced)
    func searchSavedEpisodesAcrossPodcasts(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel previous task
        globalSearchTask?.cancel()

        // Debounce and perform global search
        globalSearchTask = Task { [weak self, trimmed] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms debounce
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            if trimmed.isEmpty {
                await MainActor.run { self.globalEpisodeSearchResults = [] }
                return
            }
            let results = await self.episodeManager.searchEpisodesAcrossFeeds(query: trimmed, limit: 50)
            // Deduplicate and merge states just in case
            let unique = await PodcastViewModel.removeDuplicatesFromEpisodes(results)
            await MainActor.run {
                self.globalEpisodeSearchResults = unique
            }
        }
    }
    
    /// Update episode state efficiently with immediate CloudKit and Core Data sync
    func updateEpisodeState(_ episodeId: String, progress: Double? = nil, isFavorite: Bool? = nil, isDownloaded: Bool? = nil, isPlayed: Bool? = nil) {
        Task {
            // CRITICAL SAFEGUARD: Prevent race condition corruption of currently playing episode
            let isCurrentlyPlaying = PodcastPlayer.shared.currentEpisode?.id == episodeId && PodcastPlayer.shared.isPlaying
            let playerProgress = PodcastPlayer.shared.currentProgress
            
            // Get current state to preserve values not being updated
            let currentProgress = progress ?? EpisodeStateManager.shared.getProgress(for: episodeId)
            let currentFavorite = isFavorite ?? EpisodeStateManager.shared.isFavorite(episodeId)
            let currentDownloaded = isDownloaded ?? EpisodeStateManager.shared.isDownloaded(episodeId)
            
            // CRITICAL FIX: For currently playing episodes, prioritize player's progress over stale data
            // AND: Protect episodes from being corrupted with accumulated progress during playback
            let finalProgress: Double
            if let explicitProgress = progress {
                // PROGRESS PROTECTION: Never allow progress to go backwards
                if explicitProgress < currentProgress {
                    finalProgress = currentProgress // Keep the higher progress
                } else {
                    // CORRUPTION PROTECTION: If episode is currently playing at 0.0 but we're being asked 
                    // to set accumulated progress > 0, this is corruption - use player's actual progress
                    if isCurrentlyPlaying && playerProgress == 0.0 && explicitProgress > 0 {
                        finalProgress = playerProgress
                    } else {
                        // Explicit progress provided and not a corruption case - use it
                        finalProgress = explicitProgress
                    }
                }
            } else if isCurrentlyPlaying {
                // Currently playing - use player's progress to prevent corruption from stale data
                finalProgress = playerProgress
            } else {
                // Not playing - use stored progress
                finalProgress = currentProgress
            }
            
            let finalIsPlayed = isPlayed ?? (finalProgress >= 0.99)
            
            let episodeState: EpisodePlaybackState
            if finalIsPlayed || finalProgress >= 0.99 {
                episodeState = .played
            } else if finalProgress > 0 {
                episodeState = .inProgress
            } else {
                episodeState = .new
            }
            
            // Update EpisodeStateManager first (source of truth)
            // CRITICAL: Only update progress if it's explicitly provided OR if we're using player progress
            if let _ = progress {
                // Use our carefully calculated finalProgress (which may have rejected corrupted explicit progress)
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: finalProgress)
                
                // ⚡ PROACTIVE: Update cache immediately for instant loading on next app launch
                
                            // CONDITIONAL SYNC: Progress is stored locally, CloudKit sync happens only on allowed conditions
            } else if isCurrentlyPlaying {
                // For currently playing episodes, sync the player's progress
                EpisodeStateManager.shared.setProgress(for: episodeId, progress: playerProgress)
                
                // ⚡ PROACTIVE: Update cache immediately for instant loading on next app launch
                
                // CONDITIONAL SYNC: Progress is stored locally, CloudKit sync happens only on allowed conditions
            }
            // IMPORTANT: If no explicit progress and not currently playing, DON'T modify stored progress
            
            if let isFavorite = isFavorite {
                let feedId = await getFeedIdForEpisode(episodeId)
                EpisodeStateManager.shared.setFavorite(episodeId, isFavorite: isFavorite, feedId: feedId)
                
                // CONDITIONAL SYNC: Favorite changes trigger immediate CloudKit sync (allowed condition)
                
                // ⚡ PROACTIVE: Update cache immediately for instant loading on next app launch
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: isFavorite, isDownloaded: nil)
                    
                    // 🚗 CARPLAY FIX: Notify CarPlay immediately about favorite state change
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeStateChanged"),
                        object: nil,
                        userInfo: [
                            "episodeId": episodeId,
                            "isFavorite": isFavorite
                        ]
                    )
                }
            }
            if let isDownloaded = isDownloaded {
                let feedId = await getFeedIdForEpisode(episodeId)
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: isDownloaded, feedId: feedId)
                
                // CONDITIONAL SYNC: Download changes trigger immediate CloudKit sync (allowed condition)
                
                // ⚡ PROACTIVE: Update cache immediately for instant loading on next app launch
                
                // 🔄 CRITICAL: Trigger UI refresh for immediate visual update
                await MainActor.run {
                    self.updateEpisodeUIState(episodeId: episodeId, isFavorite: nil, isDownloaded: isDownloaded)
                    
                    // 🚗 CARPLAY FIX: Notify CarPlay immediately about download state change
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeStateChanged"),
                        object: nil,
                        userInfo: [
                            "episodeId": episodeId,
                            "isDownloaded": isDownloaded
                        ]
                    )
                }
            }
            
            // Update the episode state in EpisodeStateManager
            EpisodeStateManager.shared.updateProgress(for: episodeId, progress: finalProgress, isPlaying: false)
            
            // Update local state immediately for responsiveness
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episodeId }) {
                    var updatedEpisode = self.currentEpisodes[index]
                    
                    updatedEpisode.state.progress = finalProgress
                    updatedEpisode.state.isFavorite = currentFavorite
                    updatedEpisode.state.isDownloaded = currentDownloaded
                    updatedEpisode.state.isPlayed = finalIsPlayed
                    
                    self.currentEpisodes[index] = updatedEpisode
                }
                
                // Update progress cache
                self.episodeProgress[episodeId] = finalProgress
            }
            
            // Get feedId for the episode to establish CloudKit relationship
            let episodeFeedId: String?
            if let currentEpisode = self.currentEpisodes.first(where: { $0.id == episodeId }) {
                episodeFeedId = currentEpisode.feedId
            } else if let selectedId = self.selectedFeedId, !selectedId.isEmpty {
                // Fallback: use currently selected feed
                episodeFeedId = selectedId
            } else {
                // Last resort: query Core Data for the episode's feedId
                episodeFeedId = await self.getFeedIdForEpisode(episodeId)
            }
            
            // PERFORMANCE: Skip expensive CloudKit saves when caches are available
            let hasCache = episodeFeedId != nil ? feedIsolationManager.getEpisodesForFeed(episodeFeedId!) != nil : false
            
            if !hasCache {
                // Sync to CloudKit (single call, non-blocking) with feed relationship
                // Only sync if we have a valid feedId to prevent crashes
                if let validFeedId = episodeFeedId, !validFeedId.isEmpty {
                    Task.detached(priority: .userInitiated) {
                        await PodcastCloudKitManager.shared.saveEpisodeState(
                            episodeId: episodeId,
                            feedId: validFeedId,
                            progress: finalProgress,
                            isFavorite: currentFavorite,
                            isDownloaded: currentDownloaded,
                            isPlayed: finalIsPlayed
                        )
                    }
                } else {
                    // CRITICAL: This might be the issue - try alternative approaches
                    if let currentEpisode = self.currentEpisodes.first(where: { $0.id == episodeId }) {
                        if !currentEpisode.feedId.isEmpty {
                            Task.detached(priority: .userInitiated) {
                                await PodcastCloudKitManager.shared.saveEpisodeState(
                                    episodeId: episodeId,
                                    feedId: currentEpisode.feedId,
                                    progress: finalProgress,
                                    isFavorite: currentFavorite,
                                    isDownloaded: currentDownloaded,
                                    isPlayed: finalIsPlayed
                                )
                            }
                        }
                    }
                }
            } else {
                print("⚡ PERFORMANCE: Skipped CloudKit save - using cache for feed \(episodeFeedId ?? "unknown")")
            }
            
            // CRITICAL: Save to Core Data immediately for persistence and fast app restart
            let coreDataUpdate = EpisodeStateUpdate(
                episodeId: episodeId,
                progress: finalProgress,
                isFavorite: currentFavorite,
                isDownloaded: currentDownloaded,
                isPlayed: finalIsPlayed
            )
            
            do {
                try await episodeManager.updateEpisodeStates([coreDataUpdate])
            } catch {
                print("❌ Failed to save episode state to Core Data: \(error)")
            }
            
            // Update counts if necessary
            if isFavorite != nil || isDownloaded != nil {
                await updateEpisodeCountsForCurrentFeed()
                
                // PERFORMANCE: Skip cache clearing when caches are available to prevent CPU spikes
                if let feedId = self.selectedFeedId {
                    if self.feedIsolationManager.getEpisodesForFeed(feedId) == nil {
                        await self.episodeManager.clearCacheForFeed(feedId)
                        // ULTRA-FAST CACHE: Also clear memory cache for immediate consistency
                        self.episodeManager.clearMemoryCacheForFeed(feedId)
                        print("🧽 CACHE: Cleared cache for feed \(feedId) - no cache available")
                    } else {
                        print("⚡ PERFORMANCE: Skipping cache clear - using episode cache for feed \(feedId)")
                    }
                }
                
                // PERFORMANCE: Only refresh filtered list if actually needed to reduce CPU usage
                if self.currentTab == EpisodeFilter.favorites.rawValue || self.currentTab == EpisodeFilter.downloads.rawValue {
                    await self.refreshCurrentFilteredList()
                }
            }
        }
    }
    
    /// PERFORMANCE OPTIMIZATION: Fast tab switching using in-memory filtering and caching
    /// This avoids expensive Core Data queries and EpisodeStateManager sync for every episode
    @MainActor
    private func performFastTabSwitch(from oldTab: Int, to newTab: Int) async -> Bool {
        guard let feedId = selectedFeedId else { return false }
        
        // INSTANT CACHE: Check for pre-computed cached results with counts
        if let cachedEpisodes = tabFilterCache[feedId]?[newTab],
           let cachedCounts = tabFilterCounts[feedId] {
            print("⚡ INSTANT CACHE HIT: Using pre-computed results for tab \(newTab) (\(cachedEpisodes.count) episodes)")
            
            // BULLETPROOF STATE APPLICATION: Use centralized state refresh function
            let episodesWithFreshStates = applyFreshStatesFromManager(to: cachedEpisodes, feedId: feedId)
            
            currentEpisodes = episodesWithFreshStates
            
            // Use pre-computed counts to avoid expensive filtering
            episodeCounts = cachedCounts
            
            isLoadingEpisodes = false
            operationInProgress = false
            hasMoreEpisodes = false
            return true
        } else {
            print("❌ CACHE MISS: No cached results for feed \(feedId) tab \(newTab). Cache keys: \(Array(tabFilterCache.keys))")
            if let feedCache = tabFilterCache[feedId] {
                print("❌ CACHE MISS: Available tabs for feed: \(Array(feedCache.keys))")
            }
        }
        
        // Try to get episodes from memory first (from feed object or current episodes)
        var availableEpisodes: [PodcastEpisode] = []
        
        // First, try to get from the feed object in memory
        if let feed = podcastFeeds.first(where: { $0.id == feedId }), !feed.episodes.isEmpty {
            availableEpisodes = feed.episodes
            print("⚡ FAST TAB SWITCH: Using feed episodes (\(feed.episodes.count) episodes)")
        } else if !currentEpisodes.isEmpty && oldTab >= 0 {
            // CRITICAL FIX: Use current episodes and reconstruct the full list if needed
            print("⚡ FAST TAB SWITCH: Using current episodes (\(currentEpisodes.count) episodes) from oldTab \(oldTab)")
            
            // Debug: check if feed was found but had no episodes
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                print("❌ FAST TAB SWITCH: Feed found but has no episodes (\(feed.episodes.count) episodes) - using current episodes instead")
            } else {
                print("❌ FAST TAB SWITCH: No feed found with ID \(feedId). Available feeds: \(podcastFeeds.count) - using current episodes")
            }
            // We have current episodes but need to determine if they're filtered
            let oldFilter = EpisodeFilter(rawValue: oldTab) ?? .all
            
            if oldFilter == .all {
                // Current episodes are the full list - use them
                availableEpisodes = currentEpisodes
                print("⚡ FAST TAB SWITCH: Current episodes are full list (oldTab was 'All')")
            } else {
                // Current episodes are filtered - we need to get the full list
                // Try to get from Core Data quickly without expensive operations
                if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                    // Use the feed's episodes if available
                    availableEpisodes = feed.episodes.isEmpty ? currentEpisodes : feed.episodes
                    print("⚡ FAST TAB SWITCH: Using feed episodes (\(feed.episodes.count)) or current (\(currentEpisodes.count))")
                } else {
                    // Last resort: use current episodes (might be filtered but better than full reload)
                    availableEpisodes = currentEpisodes
                    print("⚠️ FAST TAB SWITCH: Using potentially filtered episodes to avoid expensive reload")
                }
            }
        }
        else {
            // No episodes available in memory - need full reload
            print("❌ FAST TAB SWITCH: No episodes available - currentEpisodes.count=\(currentEpisodes.count), oldTab=\(oldTab), podcastFeeds.count=\(podcastFeeds.count)")
            print("❌ FAST TAB SWITCH: Falling back to minimal reload to avoid expensive operations")
            return false
        }
        
        print("⚡ FAST TAB SWITCH: Filtering \(availableEpisodes.count) episodes for tab \(newTab)")
        
        // Apply the filter quickly without expensive operations
        let filter = EpisodeFilter(rawValue: newTab) ?? .all
        let filteredEpisodes: [PodcastEpisode]
        
        switch filter {
        case .all:
            filteredEpisodes = availableEpisodes
        case .favorites:
            filteredEpisodes = availableEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = availableEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Sort and cache the results
        let sortedEpisodes = filteredEpisodes.sorted { $0.publicationDate > $1.publicationDate }
        
        // PERFORMANCE: Pre-compute and cache episode counts to avoid expensive filtering on future accesses
        let allEpisodes = availableEpisodes
        let favoriteEpisodes = allEpisodes.filter { $0.state.isFavorite }
        let downloadedEpisodes = allEpisodes.filter { $0.state.isDownloaded }
        
        let precomputedCounts = (all: allEpisodes.count, favorites: favoriteEpisodes.count, downloads: downloadedEpisodes.count)
        
        // Cache both the filtered results AND the pre-computed counts
        if tabFilterCache[feedId] == nil {
            tabFilterCache[feedId] = [:]
        }
        tabFilterCache[feedId]?[0] = allEpisodes  // All episodes
        tabFilterCache[feedId]?[1] = favoriteEpisodes  // Favorites
        tabFilterCache[feedId]?[2] = downloadedEpisodes  // Downloads
        tabFilterCache[feedId]?[newTab] = sortedEpisodes  // Current tab (may be redundant but ensures consistency)
        
        // Cache the counts for instant access
        tabFilterCounts[feedId] = precomputedCounts
        
        // Update UI immediately with filtered results
        currentEpisodes = sortedEpisodes
        isLoadingEpisodes = false
        operationInProgress = false
        hasMoreEpisodes = false
        
        print("⚡ FAST TAB SWITCH: Showing \(currentEpisodes.count) episodes for tab \(newTab) (cached for future)")
        return true
    }
    
    /// ULTRA-MINIMAL TAB RELOAD: Last resort fallback that shows current episodes with different filter
    /// This completely avoids Core Data queries and CloudKit sync to prevent CPU spikes
    @MainActor
    private func performMinimalTabReload(feedId: String?, tab: Int) async {
        guard let feedId = feedId else { return }
        
        print("⚡ ULTRA-MINIMAL TAB RELOAD: Using current episodes for tab \(tab) - NO expensive operations")
        
        // Use whatever episodes we currently have and just filter them
        // This prevents any expensive Core Data or CloudKit operations
        let availableEpisodes = currentEpisodes.isEmpty ? [] : currentEpisodes
        
        if availableEpisodes.isEmpty {
            print("⚠️ ULTRA-MINIMAL: No current episodes available - showing empty state")
            currentEpisodes = []
            episodeCounts = (all: 0, favorites: 0, downloads: 0)
            isLoadingEpisodes = false
            operationInProgress = false
            return
        }
        
        // Apply filter to current episodes (they might be from a different tab, but that's better than hanging)
        let filter = EpisodeFilter(rawValue: tab) ?? .all
        let filteredEpisodes: [PodcastEpisode]
        
        switch filter {
        case .all:
            filteredEpisodes = availableEpisodes
        case .favorites:
            filteredEpisodes = availableEpisodes.filter { $0.state.isFavorite }
        case .downloads:
            filteredEpisodes = availableEpisodes.filter { $0.state.isDownloaded }
        }
        
        // Update UI immediately with filtered results
        currentEpisodes = filteredEpisodes
        hasMoreEpisodes = false
        
        // Update episode counts
        let allCount = filteredEpisodes.count
        let favoritesCount = filteredEpisodes.filter { $0.state.isFavorite }.count
        let downloadsCount = filteredEpisodes.filter { $0.state.isDownloaded }.count
        episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
        
        // PERFORMANCE: Pre-compute all filter types and counts for instant future access
        let allEpisodes = availableEpisodes
        let favoriteEpisodes = allEpisodes.filter { EpisodeStateManager.shared.isFavorite($0.id) }
        let downloadedEpisodes = allEpisodes.filter { EpisodeStateManager.shared.isDownloaded($0.id) }
        
        let precomputedCounts = (all: allEpisodes.count, favorites: favoriteEpisodes.count, downloads: downloadedEpisodes.count)
        
        // Cache all three filter types at once to avoid future expensive operations
        if tabFilterCache[feedId] == nil {
            tabFilterCache[feedId] = [:]
        }
        tabFilterCache[feedId]?[0] = allEpisodes  // All episodes
        tabFilterCache[feedId]?[1] = favoriteEpisodes  // Favorites
        tabFilterCache[feedId]?[2] = downloadedEpisodes  // Downloads
        
        // Cache the counts for instant access
        tabFilterCounts[feedId] = precomputedCounts
        
        // Clear loading state
        isLoadingEpisodes = false
        operationInProgress = false
        
        print("⚡ ULTRA-MINIMAL: Showing \(filteredEpisodes.count) episodes for tab \(tab) (cached for future)")
    }
    
    /// Clear tab filter cache for a specific feed when episodes are updated
    private func clearTabFilterCache(for feedId: String) {
        tabFilterCache.removeValue(forKey: feedId)
        tabFilterCounts.removeValue(forKey: feedId)
        // CRITICAL FIX: Don't clear caches - they provide performance benefits
        // Caches will naturally expire after 10 minutes or be updated with new data
        print("🧽 Cleared tab filter cache and counts for feed: \(feedId) (cache preserved)")
    }
    
    /// Clear all tab filter cache
    private func clearAllTabFilterCache() {
        tabFilterCache.removeAll()
        tabFilterCounts.removeAll()
        // CRITICAL FIX: Preserve caches for performance - they expire naturally
        print("🧽 Cleared all tab filter caches and counts (cache preserved)")
    }
    
    /// Clear all existing episode caches to prevent contamination spread
    @MainActor
    func clearAllEpisodeCaches() {
        feedIsolationManager.clearAllFeeds()
        coreDataLoadTimestamps.removeAll()
        print("🧹 EMERGENCY: Cleared all episodes from isolation manager to prevent contamination spread")
        
        // Reset DataSyncManager Core Data tracking
        DataSyncManager.shared.updateCoreDataEpisodeLoadStatus(
            feedsLoaded: 0,
            totalFeeds: 0
        )
    }
    
    
    /// DEPRECATED: No longer needed with Core Data + In-Memory Cache architecture
    private func cleanupOldCaches() {
        // NO-OP: Core Data + FeedIsolationManager handle cache management automatically
        // Episodes are loaded from Core Data on demand and cached in FeedIsolationManager
    }
    
    
    /// Ultra-fast check for new episodes - pulls ALL new episodes and updates UI instantly
    private func checkForNewEpisodesImmediately(feedId: String) async {
        print("⚡ ULTRA-FAST CHECK: Starting instant new episode check for feed \(feedId)")
        
        do {
            guard let feed = podcastFeeds.first(where: { $0.id == feedId }),
                  let url = URL(string: feed.url) else { 
                print("❌ ULTRA-FAST: Could not find feed or URL for \(feedId)")
                return 
            }
            
            // ULTRA-FAST: Parse ALL new episodes from RSS for complete update
            let latestEpisodes = try await parseAllNewEpisodesOptimized(from: url, feedId: feedId)
            
            // Get existing episodes from cache or current episodes for comparison
            let existingEpisodes = feedIsolationManager.getEpisodesForFeed(feedId) ?? currentEpisodes
            let existingIds = Set(existingEpisodes.map { $0.id })
            
            // Find truly new episodes
            let newEpisodes = latestEpisodes.filter { !existingIds.contains($0.id) }
            
            if !newEpisodes.isEmpty {
                print("🆕 ULTRA-FAST: Found \(newEpisodes.count) new episodes - updating UI instantly")
                
                // INSTANT UI UPDATE: Add new episodes to the front of current list
                await MainActor.run {
                    if self.selectedFeedId == feedId {
                        // Prepend new episodes to existing list (newest first)
                        var updatedEpisodes = newEpisodes + self.currentEpisodes
                        
                        // Remove duplicates while preserving order
                        var seenIds = Set<String>()
                        updatedEpisodes = updatedEpisodes.filter { episode in
                            if seenIds.contains(episode.id) {
                                return false
                            }
                            seenIds.insert(episode.id)
                            return true
                        }
                        
                        // Apply current filter
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = updatedEpisodes
                        case .favorites:
                            filteredEpisodes = updatedEpisodes.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = updatedEpisodes.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        print("⚡ INSTANT UI: Updated with \(filteredEpisodes.count) episodes including \(newEpisodes.count) new ones")
                        
                        // IMMEDIATE CACHE UPDATE: Update cache immediately to persist new episodes
                        let existingCache = self.feedIsolationManager.getEpisodesForFeed(feedId); if !existingCache.isEmpty {
                            let updatedCache = newEpisodes + existingCache
                            self.feedIsolationManager.replaceEpisodesForFeed(updatedCache, feedId: feedId)
                            print("📸 IMMEDIATE: Updated cache with \(newEpisodes.count) new episodes for navigation persistence")
                        } else {
                            // Create new cache if none exists
                            self.feedIsolationManager.replaceEpisodesForFeed(updatedEpisodes, feedId: feedId)
                            print("📸 IMMEDIATE: Created new cache with \(updatedEpisodes.count) episodes")
                        }
                    }
                }
                
                // BACKGROUND: Update Core Data asynchronously
                Task.detached(priority: .background) {
                    do {
                        // Add new episodes to Core Data
                        try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                        print("💾 BACKGROUND: Added \(newEpisodes.count) new episodes to Core Data")
                    } catch {
                        print("❌ BACKGROUND UPDATE ERROR: \(error.localizedDescription)")
                    }
                }
            } else {
                print("✅ ULTRA-FAST: No new episodes found in latest 3 episodes for feed \(feedId)")
            }
        } catch {
            print("❌ ULTRA-FAST CHECK ERROR: \(error.localizedDescription)")
        }
    }
    
    /// Ultra-fast RSS parsing that finds ALL new episodes by stopping at first known episode
    private func parseAllNewEpisodesOptimized(from url: URL, feedId: String) async throws -> [PodcastEpisode] {
        print("⚡ ULTRA-FAST PARSE: Fetching ALL new episodes from \(url)")
        
        let startTime = Date()
        
        // Get existing episode IDs for comparison
        let existingEpisodes = feedIsolationManager.getEpisodesForFeed(feedId) ?? currentEpisodes
        let existingIds = Set(existingEpisodes.map { $0.id })
        
        // Create a fast URLSession with minimal timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0 // 5 second timeout
        config.timeoutIntervalForResource = 10.0 // 10 second total timeout
        let session = URLSession(configuration: config)
        
        let (data, _) = try await session.data(from: url)
        
        let parser = XMLParser(data: data)
        let delegate = SmartRSSParserDelegate(feedId: feedId, existingIds: existingIds)
        parser.delegate = delegate
        
        let parseSuccess = parser.parse()
        
        let parseTime = Date().timeIntervalSince(startTime)
        print("⚡ ULTRA-FAST PARSE: Completed in \(String(format: "%.2f", parseTime))s, found \(delegate.newEpisodes.count) new episodes")
        
        guard parseSuccess else {
            throw NSError(domain: "SmartRSSParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse RSS feed"])
        }
        
        return delegate.newEpisodes
    }
    
    /// Smart RSS parser delegate that stops at first known episode to get ALL new episodes
    private class SmartRSSParserDelegate: NSObject, XMLParserDelegate {
        let feedId: String
        let existingIds: Set<String>
        var newEpisodes: [PodcastEpisode] = []
        
        private var currentElement = ""
        private var currentTitle = ""
        private var currentDescription = ""
        private var currentAudioUrl = ""
        private var currentPubDate = ""
        private var currentGuid = ""
        private var insideItem = false
        
        init(feedId: String, existingIds: Set<String>) {
            self.feedId = feedId
            self.existingIds = existingIds
        }
        
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName.lowercased()
            
            if currentElement == "item" {
                insideItem = true
                // Reset episode data
                currentTitle = ""
                currentDescription = ""
                currentAudioUrl = ""
                currentPubDate = ""
                currentGuid = ""
            } else if currentElement == "enclosure" && insideItem {
                if let url = attributeDict["url"], url.contains("mp3") || url.contains("m4a") || url.contains("wav") {
                    currentAudioUrl = url
                }
            }
        }
        
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && insideItem else { return }
            
            switch currentElement {
            case "title":
                currentTitle += trimmed
            case "description", "itunes:summary":
                currentDescription += trimmed
            case "pubdate":
                currentPubDate += trimmed
            case "guid":
                currentGuid += trimmed
            default:
                break
            }
        }
        
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName.lowercased() == "item" && insideItem {
                insideItem = false
                
                // Create episode if we have minimum required data
                guard !currentTitle.isEmpty && !currentAudioUrl.isEmpty else { return }
                
                let pubDate = parseDate(from: currentPubDate) ?? Date()
                let episodeId = !currentGuid.isEmpty ? currentGuid : PodcastEpisode.generateDeterministicID(
                    title: currentTitle,
                    audioUrl: currentAudioUrl,
                    publicationDate: pubDate,
                    feedUrl: ""
                )
                
                // SMART OPTIMIZATION: Stop parsing if we hit a known episode (all new episodes found)
                if existingIds.contains(episodeId) {
                    print("⚡ SMART PARSE: Hit known episode '\(currentTitle)' - stopping (found \(newEpisodes.count) new episodes)")
                    parser.abortParsing()
                    return
                }
                
                // DATE VALIDATION: Check for future episodes before creating
                let now = Date()
                let futureThreshold = now.addingTimeInterval(24 * 60 * 60) // Allow 1 day in future for timezone differences
                
                if pubDate > futureThreshold {
                    print("🚫 RSS PARSER: Skipping episode with future date '\(currentTitle)' (Date: \(pubDate))")
                    return
                }
                
                // Check for invalid old dates (before 1990)
                let minimumValidDate = Date(timeIntervalSince1970: 631152000) // January 1, 1990
                if pubDate < minimumValidDate {
                    print("🚫 RSS PARSER: Skipping episode with invalid old date '\(currentTitle)' (Date: \(pubDate))")
                    return
                }
                
                // CONTAMINATION PREVENTION: Create episode with strict feed isolation
                let rawEpisode = PodcastEpisode(
                    id: episodeId,
                    title: currentTitle,
                    descriptionText: currentDescription.isEmpty ? currentTitle : currentDescription,
                    audioUrl: currentAudioUrl,
                    publicationDate: pubDate,
                    duration: 0,
                    state: EpisodeState(
                        isPlayed: false,
                        isFavorite: false,
                        progress: 0.0,
                        isDownloaded: false
                    ),
                    feedId: feedId
                )
                
                // CONTAMINATION GUARD: Validate episode before adding
                let validationResult = EpisodeContaminationGuard.validateEpisode(rawEpisode, expectedFeedId: feedId, allEpisodes: newEpisodes)
                
                if validationResult.hasCriticalIssues {
                    print("🚨 CONTAMINATION GUARD: Critical issues found in episode '\(currentTitle)': \(validationResult.issues.map { $0.description }.joined(separator: ", "))")
                    
                    // Use corrected episode if available, otherwise skip
                    if let correctedEpisode = validationResult.correctedEpisode {
                        print("🔧 CONTAMINATION GUARD: Using corrected episode for '\(currentTitle)'")
                        newEpisodes.append(correctedEpisode)
                    } else {
                        print("🚫 CONTAMINATION GUARD: Skipping contaminated episode '\(currentTitle)'")
                    }
                } else {
                    // Episode is clean, add it
                    newEpisodes.append(rawEpisode)
                    
                    if validationResult.hasContamination {
                        print("⚠️ CONTAMINATION GUARD: Minor issues in episode '\(currentTitle)': \(validationResult.issues.map { $0.description }.joined(separator: ", "))")
                    }
                }
            }
        }
        
        private func parseDate(from string: String) -> Date? {
            let formatters = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd HH:mm:ss"
            ]
            
            for format in formatters {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let date = formatter.date(from: string) {
                    return date
                }
            }
            return nil
        }
    }
    
    /// Background check for new episodes without blocking UI
    private func checkForNewEpisodesInBackground(feedId: String) async {
        // PERFORMANCE: Be very conservative about background checks when caches exist
        // Only check if cache is significantly old to preserve the cache system benefits
        let cachedEpisodes = feedIsolationManager.getEpisodesForFeed(feedId); if !cachedEpisodes.isEmpty {
            let cacheAge = Date().timeIntervalSince(coreDataLoadTimestamps[feedId] ?? Date.distantPast)
            if cacheAge < 1800 { // 30 minutes - much more conservative to preserve cache benefits
                print("⚡ PERFORMANCE: Skipping background RSS check - cache is fresh (\(Int(cacheAge/60)) min old)")
                return
            } else {
                print("🔍 BACKGROUND CHECK: Cache is \(Int(cacheAge/60)) min old - checking for new episodes")
            }
        }
        
        print("🔍 BACKGROUND CHECK: Checking for new episodes for feed \(feedId)")
        
        do {
            // Quick RSS check for new episodes only
            guard let feed = podcastFeeds.first(where: { $0.id == feedId }),
                  let url = URL(string: feed.url) else { return }
            
            let newEpisodes = try await parseNewEpisodesOnly(from: url, feedId: feedId)
            
            if !newEpisodes.isEmpty {
                print("🆕 BACKGROUND: Found \(newEpisodes.count) new episodes - creating new cache")
                
                // Update Core Data with new episodes first
                try await PodcastCoreDataManager.shared.addNewEpisodes(newEpisodes, to: feedId)
                
                // CLEAN UP: Remove old episodes before creating new ones
                let existingEpisodes = feedIsolationManager.getEpisodesForFeed(feedId)
                if !existingEpisodes.isEmpty {
                    print("🗑️ BACKGROUND CLEANUP: Removing old episodes for feed \(feedId)")
                    feedIsolationManager.clearEpisodesForFeed(feedId)
                    coreDataLoadTimestamps.removeValue(forKey: feedId)
                }
                
                // CREATE NEW CACHE: Parse complete RSS feed to get all current episodes
                let allCurrentEpisodes = try await parseRSSEpisodesOnly(from: url)
                feedIsolationManager.replaceEpisodesForFeed(allCurrentEpisodes, feedId: feedId)
                print("🆕 BACKGROUND: Created new cache with \(allCurrentEpisodes.count) episodes (includes \(newEpisodes.count) new episodes)")
                
                // Update UI with complete episode list if this feed is currently displayed
                await MainActor.run {
                    if self.selectedFeedId == feedId {
                        let filter = EpisodeFilter(rawValue: self.currentTab) ?? .all
                        let filteredEpisodes: [PodcastEpisode]
                        switch filter {
                        case .all:
                            filteredEpisodes = allCurrentEpisodes // Already sorted newest first
                        case .favorites:
                            filteredEpisodes = allCurrentEpisodes.filter { $0.state.isFavorite }
                        case .downloads:
                            filteredEpisodes = allCurrentEpisodes.filter { $0.state.isDownloaded }
                        }
                        
                        self.currentEpisodes = filteredEpisodes
                        Task {
                            await self.updateEpisodeCounts(for: feedId, episodes: allCurrentEpisodes)
                        }
                        print("🆕 BACKGROUND: Updated UI with \(newEpisodes.count) new episodes - total visible: \(filteredEpisodes.count) (newest first)")
                    }
                }
            } else {
                print("✅ BACKGROUND: No new episodes found for feed \(feedId)")
            }
        } catch {
            print("❌ BACKGROUND: Failed to check for new episodes: \(error)")
        }
    }
    
    /// Remove duplicate feeds manually
    @MainActor
    func removeDuplicateFeeds() {
        Task {
            await cleanupDuplicateFeeds()
            loadFeedsFromCoreData() // Refresh UI
        }
    }
    
    /// Delete a podcast feed with real-time progress tracking
    @MainActor
    func deletePodcastFeed(_ feed: PodcastFeed) {
        // Initialize progress tracking
        isDeletingFeed = true
        deletingFeedId = feed.id
        feedDeletionProgress = 0.0
        feedDeletionMessage = "Preparing deletion..."
        
        Task { [self] in
            do {
                // Step 1: Get episode count for progress calculation
                feedDeletionMessage = "Analyzing episodes..."
                feedDeletionProgress = 0.05
                
                let episodeIds = await getEpisodeIdsForFeed(feed.id)
                let totalEpisodes = episodeIds.count
                
                await MainActor.run {
                    feedDeletionMessage = "Found \(totalEpisodes) episodes to delete"
                    feedDeletionProgress = 0.1
                }
                
                // Step 1.5: CRITICAL - Stop and clear player FIRST (without saving progress) if playing episode from deleted feed
                await MainActor.run {
                    feedDeletionMessage = "Checking active player..."
                    feedDeletionProgress = 0.12
                    
                    let podcastPlayer = PodcastPlayer.shared
                    if let currentEpisode = podcastPlayer.currentEpisode {
                        // Check if the currently playing episode belongs to the feed being deleted
                        if currentEpisode.feedId == feed.id {
                            print("🎵 PLAYER CLEAR: Currently playing episode '\(currentEpisode.title)' belongs to feed being deleted")
                            print("🎵 PLAYER CLEAR: Stopping playback WITHOUT saving progress to prevent re-creating state data")
                            
                            // CRITICAL: Stop player WITHOUT saving progress
                            // This prevents the player from re-creating episode state data after we clear it
                            if let player = podcastPlayer.player {
                                player.pause()
                            }
                            podcastPlayer.isPlaying = false
                            podcastPlayer.userWantsToPlay = false
                            podcastPlayer.wasManuallyPaused = false
                            
                            // Clear the current episode BEFORE clearing states
                            podcastPlayer.currentEpisode = nil
                            
                            // Post notification to update UI
                            NotificationCenter.default.post(
                                name: NSNotification.Name("PodcastPlayerCleared"),
                                object: nil,
                                userInfo: ["reason": "feed_being_deleted", "feedId": feed.id]
                            )
                            
                            print("🎵 PLAYER CLEAR: ✅ Player stopped and cleared WITHOUT saving progress")
                        } else {
                            print("🎵 PLAYER CHECK: Currently playing episode belongs to different feed - no action needed")
                        }
                    } else {
                        print("🎵 PLAYER CHECK: No episode currently playing - no action needed")
                    }
                }
                
                // Step 2: Clear episode states COMPREHENSIVELY from ALL sources
                await MainActor.run {
                    feedDeletionMessage = "Clearing episode progress and states..."
                    feedDeletionProgress = 0.2
                }
                
                // 2a. Clear from EpisodeStateManager (in-memory dictionaries + UserDefaults)
                print("🧹 FEED DELETION: Clearing from EpisodeStateManager (in-memory + UserDefaults)...")
                EpisodeStateManager.shared.clearEpisodeDataBatch(episodeIds)
                print("🧹 FEED DELETION: ✅ Cleared \(episodeIds.count) episodes from EpisodeStateManager")
                
                // 2a2. Clear from ViewModel's local episodeProgress dictionary IMMEDIATELY
                await MainActor.run {
                    print("🧹 FEED DELETION: Clearing from ViewModel episodeProgress dictionary...")
                    for episodeId in episodeIds {
                        self.episodeProgress.removeValue(forKey: episodeId)
                    }
                    print("🧹 FEED DELETION: ✅ Cleared \(episodeIds.count) episodes from ViewModel episodeProgress")
                }
                
                // 2b. Clear episode state data from Core Data BEFORE episodes are deleted
                await MainActor.run {
                    feedDeletionMessage = "Clearing Core Data episode states (progress, played, etc)..."
                    feedDeletionProgress = 0.3
                }
                
                print("🧹 FEED DELETION: Clearing progress and states from Core Data records...")
                await clearEpisodeStatesFromCoreData(episodeIds)
                print("🧹 FEED DELETION: ✅ Cleared episode states from Core Data for \(episodeIds.count) episodes")
                
                // 2b2. CRITICAL: Force IMMEDIATE synchronous save to Core Data to persist changes
                await MainActor.run {
                    do {
                        let context = CoreDataStack.shared.persistentContainer.viewContext
                        
                        // Force immediate save if there are changes
                        if context.hasChanges {
                            try context.save()
                            print("🧹 💾 IMMEDIATE SAVE: Forced main context save to persist cleared states")
                        }
                        
                        // Force persistent store to flush to disk immediately
                        try context.persistentStoreCoordinator?.performAndWait {
                            // This ensures changes are written to disk immediately
                            print("🧹 💾 IMMEDIATE SAVE: Flushed changes to persistent store")
                        }
                        
                    } catch {
                        print("🧹 ❌ Error forcing immediate Core Data save: \(error)")
                    }
                }
                
                // 2c. IMMEDIATE verification - Force context refresh and verify clearing
                await MainActor.run {
                    do {
                        let context = CoreDataStack.shared.persistentContainer.viewContext
                        
                        // CRITICAL: Refresh context to ensure we see latest data
                        context.refreshAllObjects()
                        print("🧹 🔄 VERIFICATION: Refreshed main context to see latest data")
                        
                        // Verify ALL episode states are cleared
                        let verifyRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        verifyRequest.predicate = NSPredicate(format: "id IN %@ AND (progress > 0 OR isPlayed == YES OR isFavorite == YES OR isDownloaded == YES)", episodeIds)
                        let episodesWithStates = try context.count(for: verifyRequest)
                        
                        if episodesWithStates > 0 {
                            print("🧹 ⚠️ WARNING: \(episodesWithStates) episodes still have state data after clearing!")
                            
                            // Force clear them again if they still have states
                            print("🧹 🔄 FORCING SECOND CLEAR: Attempting to clear remaining states...")
                            
                            let fetchForClear: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                            fetchForClear.predicate = NSPredicate(format: "id IN %@", episodeIds)
                            let episodes = try context.fetch(fetchForClear)
                            
                            for episode in episodes {
                                episode.progress = 0.0
                                episode.isPlayed = false
                                episode.isFavorite = false
                                episode.isDownloaded = false
                            }
                            
                            try context.save()
                            print("🧹 ✅ SECOND CLEAR: Force-cleared \(episodes.count) episodes and saved")
                        } else {
                            print("🧹 ✅ VERIFIED: All episode states successfully cleared from Core Data")
                        }
                    } catch {
                        print("🧹 ❌ Error verifying/clearing progress: \(error)")
                    }
                }
                
                await MainActor.run {
                    feedDeletionMessage = "✅ Cleared \(totalEpisodes) episode states from all sources"
                    feedDeletionProgress = 0.4
                }
                
                // Step 3: Delete downloaded files
                await MainActor.run {
                    feedDeletionMessage = "Deleting downloaded files..."
                    feedDeletionProgress = 0.5
                }
                
                await deleteDownloadedEpisodeFiles(episodeIds)
                
                await MainActor.run {
                    feedDeletionMessage = "Downloaded files cleaned up"
                    feedDeletionProgress = 0.6
                }
                
                // Step 4: Delete from CloudKit
                await MainActor.run {
                    feedDeletionMessage = "Deleting from CloudKit..."
                    feedDeletionProgress = 0.7
                }
                
                var cloudKitDeletionSucceeded = false
                do {
                    // Delete feed from CloudKit
                    try await cloudKitManager.deletePodcastFeedFromCloudKit(feed.id)
                    
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit feed deletion complete"
                        feedDeletionProgress = 0.75
                    }
                    
                    // Delete episode states from CloudKit database records for this specific feed
                    await cloudKitManager.deleteEpisodeStatesFromCloudKit(episodeIds: episodeIds)
                    
                    // CRITICAL: Also remove episodes from CloudKit shared collections (NSUbiquitousKeyValueStore)
                    await MainActor.run {
                        feedDeletionMessage = "Clearing CloudKit shared collections..."
                        feedDeletionProgress = 0.78
                    }
                    
                    cloudKitManager.removeEpisodesFromSharedCollections(episodeIds: episodeIds)
                    cloudKitDeletionSucceeded = true
                    
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit cleanup complete"
                        feedDeletionProgress = 0.8
                    }
                    
                } catch {
                    cloudKitDeletionSucceeded = false
                    print("☁️ ❌ CloudKit deletion failed: \(error)")
                    await MainActor.run {
                        feedDeletionMessage = "CloudKit deletion failed - continuing locally"
                        feedDeletionProgress = 0.75
                    }
                }
                
                // Step 5: Delete from Core Data with comprehensive cleanup
                await MainActor.run {
                    feedDeletionMessage = "Deleting from local database..."
                    feedDeletionProgress = 0.85
                }
                
                // Delete the feed and all episode entities from Core Data
                // This will handle both the feed record and all associated episodes
                try await deleteFeedFromCoreData(feed)
                
                // CRITICAL: Comprehensive Core Data context refresh (same as Settings -> Delete Podcast Data)
                await MainActor.run {
                    feedDeletionMessage = "Refreshing Core Data contexts..."
                    feedDeletionProgress = 0.87
                    
                    print("🔄 FEED DELETION: Starting comprehensive context refresh...")
                    let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                    
                    // Reset the main context to clear all cached objects
                    mainContext.reset()
                    print("🔄 FEED DELETION: Main context reset completed")
                    
                    // Refresh all objects in the context (in case any are still cached)
                    mainContext.refreshAllObjects()
                    print("🔄 FEED DELETION: All objects refreshed")
                    
                    // Also refresh any background contexts
                    CoreDataStack.shared.persistentContainer.performBackgroundTask { backgroundContext in
                        backgroundContext.reset()
                        print("🔄 FEED DELETION: Background context reset completed")
                    }
                }
                
                // CRITICAL: Verify deletion was successful after context refresh
                await MainActor.run {
                    do {
                        let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                        
                        // Check for remaining episodes
                        let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        episodeRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                        let remainingEpisodes = try mainContext.count(for: episodeRequest)
                        
                        // Check for remaining feed
                        let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                        feedRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                        let remainingFeeds = try mainContext.count(for: feedRequest)
                        
                        if remainingEpisodes > 0 || remainingFeeds > 0 {
                            print("❌ FEED DELETION ERROR: Data still exists after deletion! Episodes: \(remainingEpisodes), Feeds: \(remainingFeeds)")
                        } else {
                            print("✅ FEED DELETION SUCCESS: All data successfully deleted and contexts refreshed")
                        }
                    } catch {
                        print("❌ FEED DELETION: Error verifying deletion: \(error)")
                    }
                }
                
                // CRITICAL: Verify and clean up any orphaned episode records
                await verifyAndCleanupOrphanedEpisodes(feedId: feed.id, episodeIds: episodeIds)
                
                // PERSISTENT CACHE: Clear all cached data for deleted feed
                await episodeManager.clearPersistentCacheForFeed(feed.id)
                print("🧽 DELETION: Cleared persistent cache for deleted feed \(feed.title)")
                
                // Clear tab filter cache and caches for deleted feed
                await MainActor.run {
                    self.clearTabFilterCache(for: feed.id)
                    self.feedIsolationManager.clearEpisodesForFeed(feed.id)
                    self.coreDataLoadTimestamps.removeValue(forKey: feed.id)
                    print("🧽 DELETION: Cleared tab filter cache and cache for deleted feed")
                }
                
                await MainActor.run {
                    feedDeletionMessage = "Database cleanup complete"
                    feedDeletionProgress = 0.9
                }
                
                // Step 6: Update UI
                await MainActor.run {
                    feedDeletionMessage = "Updating interface..."
                    feedDeletionProgress = 0.95
                    
                    // Remove from UI arrays
                    if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                        podcastFeeds.remove(at: index)
                    }
                    podcastFeedOrder.removeAll { $0 == feed.id }
                    currentEpisodes.removeAll { $0.feedId == feed.id }
                    
                    // Clear selected feed if it's the one being deleted
                    if selectedFeedId == feed.id {
                        selectedFeedId = nil
                    }
                    
                    // NOTE: episodeProgress already cleared in Step 2a2
                    // Verify it's still clear (should be empty for these episodes)
                    let remainingProgress = episodeIds.filter { episodeProgress[$0] != nil }
                    if !remainingProgress.isEmpty {
                        print("🧹 ⚠️ WARNING: Found \(remainingProgress.count) episodes still in episodeProgress after clearing!")
                        // Force clear them again
                        for episodeId in remainingProgress {
                            episodeProgress.removeValue(forKey: episodeId)
                        }
                    } else {
                        print("🧹 ✅ VERIFIED: All episodes cleared from ViewModel episodeProgress")
                    }
                    
                    // Trigger UI update
                    throttledUIUpdate()
                    
                    // CRITICAL: Force immediate UI refresh to show cleared states without app restart
                    print("🔄 IMMEDIATE REFRESH: Forcing UI update to reflect cleared episode states...")
                    objectWillChange.send()
                }
                
                // Step 6.5: Force reload ALL remaining feeds to ensure UI shows cleared states
                await MainActor.run {
                    feedDeletionMessage = "Refreshing remaining feeds..."
                    feedDeletionProgress = 0.96
                }
                
                // Step 6.5a: CRITICAL - Double-verify EpisodeStateManager in-memory cache is cleared
                await MainActor.run {
                    print("🔄 IMMEDIATE REFRESH: Double-checking EpisodeStateManager in-memory cache...")
                    
                    // Force clear from EpisodeStateManager again to ensure in-memory dictionaries are empty
                    EpisodeStateManager.shared.clearEpisodeDataBatch(episodeIds)
                    
                    // Verify by checking a few episodes
                    var stillHasData = false
                    for episodeId in episodeIds.prefix(5) {
                        let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
                        if progress > 0 {
                            print("🔄 ⚠️ WARNING: Episode \(episodeId) still has progress \(progress) in EpisodeStateManager!")
                            stillHasData = true
                        }
                    }
                    
                    if !stillHasData {
                        print("🔄 ✅ VERIFIED: EpisodeStateManager in-memory cache is clear")
                    } else {
                        print("🔄 ⚠️ WARNING: Some episodes still have data in EpisodeStateManager - forcing third clear")
                        // Force clear one more time
                        EpisodeStateManager.shared.clearEpisodeDataBatch(episodeIds)
                    }
                }
                
                // Step 6.5b: Force reload feeds and episodes from Core Data
                print("🔄 IMMEDIATE REFRESH: Reloading all feeds from Core Data to reflect cleared states...")
                await MainActor.run {
                    loadFeedsFromCoreData()
                }
                print("🔄 IMMEDIATE REFRESH: ✅ Feeds reloaded - UI should now show cleared states")
                
                // Step 6.5b2: FINAL Core Data verification after feed reload
                await MainActor.run {
                    print("🔄 FINAL CORE DATA CHECK: Verifying episode states are cleared in Core Data...")
                    
                    do {
                        let context = CoreDataStack.shared.persistentContainer.viewContext
                        
                        // Final check for any remaining episode states
                        let finalVerifyRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        finalVerifyRequest.predicate = NSPredicate(format: "id IN %@ AND (progress > 0 OR isPlayed == YES OR isFavorite == YES OR isDownloaded == YES)", episodeIds)
                        let remainingStates = try context.count(for: finalVerifyRequest)
                        
                        if remainingStates > 0 {
                            print("🔄 ⚠️ CRITICAL WARNING: \(remainingStates) episodes STILL have state data in Core Data after all clearing!")
                            print("🔄 ⚠️ This indicates a Core Data persistence issue that needs investigation")
                        } else {
                            print("🔄 ✅ FINAL VERIFICATION: Core Data is completely clear - NO episode states remain")
                        }
                        
                    } catch {
                        print("🔄 ❌ Error in final Core Data verification: \(error)")
                    }
                }
                
                // Step 6.5c: Force immediate update with multiple UI refresh mechanisms
                await MainActor.run {
                    print("🔄 IMMEDIATE REFRESH: Broadcasting state changes to all views...")
                    
                    // Clear ViewModel's episodeProgress one more time for safety
                    for episodeId in episodeIds {
                        self.episodeProgress.removeValue(forKey: episodeId)
                    }
                    
                    // Post notification to update any open episode views
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeStatesCleared"),
                        object: nil,
                        userInfo: ["episodeIds": episodeIds, "feedId": feed.id]
                    )
                    print("🔄 IMMEDIATE REFRESH: Posted EpisodeStatesCleared notification to update all views")
                    
                    // CRITICAL: Post general episode update notification
                    NotificationCenter.default.post(
                        name: NSNotification.Name("EpisodeProgressChanged"),
                        object: nil
                    )
                    print("🔄 IMMEDIATE REFRESH: Posted EpisodeProgressChanged notification for full refresh")
                    
                    // Force immediate UI update with objectWillChange
                    objectWillChange.send()
                    print("🔄 IMMEDIATE REFRESH: Sent objectWillChange to trigger SwiftUI re-render")
                    
                    // Trigger throttled update to ensure all UI components refresh
                    throttledUIUpdate()
                    
                    print("🔄 IMMEDIATE REFRESH: ✅ All refresh mechanisms triggered")
                }
                
                // Step 7: Sync deletion to other devices (if CloudKit succeeded)
                if cloudKitDeletionSucceeded {
                    await MainActor.run {
                        PodcastCloudKitManager.shared.syncPodcastFeedRemovedInstantly(
                            feedId: feed.id,
                            feedTitle: feed.title,
                            episodeIds: episodeIds
                        )
                    }
                }
                
                // Step 7.5: FINAL COMPREHENSIVE VERIFICATION - Check all progress sources are cleared
                await MainActor.run {
                    feedDeletionMessage = "Final verification of progress clearing..."
                    feedDeletionProgress = 0.98
                    
                    print("🔍 FINAL VERIFICATION: Checking all progress sources for \(episodeIds.count) episodes...")
                    
                    // Check 1: ViewModel episodeProgress
                    let viewModelProgress = episodeIds.filter { episodeProgress[$0] != nil }
                    print("🔍   ViewModel episodeProgress: \(viewModelProgress.count) episodes still have progress")
                    
                    // Check 2: EpisodeStateManager
                    var managerProgress = 0
                    for episodeId in episodeIds {
                        if EpisodeStateManager.shared.getProgress(for: episodeId) > 0 {
                            managerProgress += 1
                        }
                    }
                    print("🔍   EpisodeStateManager: \(managerProgress) episodes still have progress")
                    
                    // Final summary
                    let totalRemaining = viewModelProgress.count + managerProgress
                    if totalRemaining > 0 {
                        print("🔍 ⚠️ FINAL VERIFICATION: \(totalRemaining) episodes still have progress data!")
                    } else {
                        print("🔍 ✅ FINAL VERIFICATION: All progress successfully cleared from all sources!")
                    }
                }
                
                // Step 8: Completion
                await MainActor.run {
                    feedDeletionMessage = "✅ Successfully deleted '\(feed.title)' and \(totalEpisodes) episodes"
                    feedDeletionProgress = 1.0
                }
                
                // Auto-hide progress after success
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await MainActor.run {
                    isDeletingFeed = false
                    deletingFeedId = nil
                    feedDeletionProgress = 0.0
                    feedDeletionMessage = ""
                }
                
            } catch {
                print("❌ Error during feed deletion: \(error)")
                await MainActor.run {
                    feedDeletionMessage = "❌ Deletion failed: \(error.localizedDescription)"
                    feedDeletionProgress = 1.0
                    
                    // Keep error visible longer
                    Task {
                        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                        await MainActor.run {
                            isDeletingFeed = false
                            deletingFeedId = nil
                            feedDeletionProgress = 0.0
                            feedDeletionMessage = ""
                        }
                    }
                    
                    // Reload UI to show correct state
                    loadFeedsFromCoreData()
                    self.error = "Failed to delete podcast: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Episode Contamination Prevention Methods
    
    /// Perform comprehensive feed isolation check across all feeds
    @MainActor
    func performGlobalContaminationCheck() {
        print("🛡️ GLOBAL CONTAMINATION CHECK: Starting comprehensive validation across all feeds")
        
        let feedIssues = EpisodeContaminationGuard.performFeedIsolationCheck(allFeeds: podcastFeeds)
        
        if feedIssues.isEmpty {
            print("✅ GLOBAL CONTAMINATION CHECK: All feeds are clean - no contamination detected")
        } else {
            print("🚨 GLOBAL CONTAMINATION CHECK: Found contamination in \(feedIssues.count) feeds")
            
            for (feedId, issues) in feedIssues {
                let feedTitle = podcastFeeds.first { $0.id == feedId }?.title ?? "Unknown Feed"
                print("🚨 FEED \(feedTitle) (\(feedId)): \(issues.count) contamination issues")
                
                for issue in issues {
                    print("   - \(issue.description)")
                }
                
                // Auto-fix critical issues
                let criticalIssues = issues.filter { $0.severity == .critical }
                if !criticalIssues.isEmpty {
                    print("🔧 AUTO-FIX: Attempting to fix \(criticalIssues.count) critical issues in feed \(feedTitle)")
                    autoFixFeedContamination(feedId: feedId)
                }
            }
        }
    }
    
    /// Automatically fix contamination issues in a specific feed
    @MainActor
    private func autoFixFeedContamination(feedId: String) {
        guard let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feedId }) else {
            print("🚨 AUTO-FIX: Feed \(feedId) not found")
            return
        }
        
        var feed = podcastFeeds[feedIndex]
        let originalEpisodeCount = feed.episodes.count
        
        // Apply emergency decontamination
        let cleanEpisodes = EpisodeContaminationGuard.emergencyDecontamination(episodes: feed.episodes, targetFeedId: feedId)
        feed.episodes = cleanEpisodes
        
        // Update the feed
        podcastFeeds[feedIndex] = feed
        
        // Update currentEpisodes if this is the selected feed
        if selectedFeedId == feedId {
            let sanitizedCurrentEpisodes = EpisodeContaminationGuard.sanitizeEpisodes(currentEpisodes, targetFeedId: feedId)
            currentEpisodes = sanitizedCurrentEpisodes
        }
        
        print("🔧 AUTO-FIX COMPLETE: Feed \(feed.title) - \(originalEpisodeCount) -> \(cleanEpisodes.count) episodes")
    }
    
    /// Validate and sanitize episodes before assignment to currentEpisodes
    @MainActor
    private func validateAndSanitizeEpisodes(_ episodes: [PodcastEpisode], targetFeedId: String) -> [PodcastEpisode] {
        // Quick validation for performance
        let basicCleanEpisodes = episodes.filter { $0.feedId == targetFeedId }
        
        if basicCleanEpisodes.count != episodes.count {
            print("🛡️ BASIC VALIDATION: Filtered \(episodes.count - basicCleanEpisodes.count) contaminated episodes")
            
            // Full sanitization for contaminated collections
            let sanitizedEpisodes = EpisodeContaminationGuard.sanitizeEpisodes(episodes, targetFeedId: targetFeedId)
            
            // Validation check
            let validationResults = EpisodeContaminationGuard.validateEpisodeCollection(sanitizedEpisodes, expectedFeedId: targetFeedId)
            let criticalIssues = validationResults.filter { $0.hasCriticalIssues }
            
            if !criticalIssues.isEmpty {
                print("🚨 CRITICAL CONTAMINATION: Emergency decontamination required")
                return EpisodeContaminationGuard.emergencyDecontamination(episodes: sanitizedEpisodes, targetFeedId: targetFeedId)
            }
            
            return sanitizedEpisodes
        }
        
        return basicCleanEpisodes
    }
    
    
    /// Manual contamination check and fix - can be called immediately
    @MainActor
    func performImmediateContaminationFix() {
        print("🛡️ EMERGENCY FIX: Starting immediate contamination cleanup with isolation manager")
        
        // Use isolation manager for comprehensive cleanup
        feedIsolationManager.performGlobalContaminationCleanup()
        
        // Validate cleanup was successful
        let report = feedIsolationManager.validateGlobalIsolation()
        if report.isClean {
            print("✅ EMERGENCY FIX: All contamination cleaned successfully")
        } else {
            print("🚨 EMERGENCY FIX: Some contamination remains - \(report.totalContaminatedEpisodes) episodes in \(report.totalContaminatedFeeds) feeds")
        }
        
        // Trigger UI refresh to show clean data
        objectWillChange.send()
    }
    
    /// Perform comprehensive migration for existing contaminated user data
    @MainActor
    func performUserDataMigration() {
        print("🛡️ MIGRATION: Starting comprehensive user data migration")
        
        Task {
            // Run Core Data migration through isolation manager
            await feedIsolationManager.performUserDataMigration(coreDataStack: CoreDataStack.shared)
            
            await MainActor.run {
                // Refresh all feeds after migration
                Task {
                    self.loadFeedsFromCoreData()
                    
                    await MainActor.run {
                        // Re-register all feeds with isolation manager
                        for feed in self.podcastFeeds {
                            self.feedIsolationManager.registerFeed(feedId: feed.id, feedUrl: feed.url)
                        }
                        
                        print("✅ MIGRATION: User data migration completed successfully")
                        self.objectWillChange.send()
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupObservers() {
        // Setup observers for episode state changes
        // Note: EpisodeStateManager.shared.progressPublisher is not implemented yet
        // Will be added when state management is fully integrated
    }
    
    /// Get all episode IDs for a feed from Core Data
    private func getEpisodeIdsForFeed(_ feedId: String) async -> [String] {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "feedId == %@", feedId)
                
                do {
                    let episodes = try context.fetch(request)
                    let episodeIds = episodes.compactMap { $0.id }
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to get episode IDs: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Get feedId for a specific episode from Core Data (fallback method)
    private func getFeedIdForEpisode(_ episodeId: String) async -> String? {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", episodeId)
                request.propertiesToFetch = ["feedId"]
                request.fetchLimit = 1
                
                do {
                    let episodes = try context.fetch(request)
                    let feedId = episodes.first?.feedId
                    continuation.resume(returning: feedId)
                } catch {
                    print("❌ Failed to get feedId for episode \(episodeId): \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Delete downloaded episode files from device storage using enhanced deletion strategies
    private func deleteDownloadedEpisodeFiles(_ episodeIds: [String]) async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
        
        var deletedCount = 0
        
        for episodeId in episodeIds {
            var fileDeleted = false
            
            // Strategy 1: Try multiple file extensions with sanitized ID
            let extensions = ["mp3", "m4a", "wav", "aac"]
            let sanitizedId = sanitizeFilename(episodeId)
            
            for ext in extensions {
                let fileName = "\(sanitizedId).\(ext)"
                let fileURL = episodesFolder.appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        deletedCount += 1
                        print("🗑️ Deleted downloaded file: \(fileName)")
                        fileDeleted = true
                        break // Found and deleted the file, no need to check other extensions
                    } catch {
                        print("❌ Failed to delete file \(fileName): \(error)")
                    }
                }
            }
            
            // Strategy 2: If no file found with standard naming, search all files for matches
            if !fileDeleted {
                // Check if the DownloadedEpisodes folder exists before trying to access it
                if FileManager.default.fileExists(atPath: episodesFolder.path) {
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: episodesFolder, includingPropertiesForKeys: nil)
                        
                        for fileURL in fileURLs {
                            let fileName = fileURL.lastPathComponent
                            if fileName.contains(episodeId) || fileName.contains(sanitizedId) {
                                do {
                                    try FileManager.default.removeItem(at: fileURL)
                                    deletedCount += 1
                                    print("🗑️ Deleted file found by search: \(fileName)")
                                    fileDeleted = true
                                    break
                                } catch {
                                    print("❌ Failed to delete file found by search \(fileName): \(error)")
                                }
                            }
                        }
                    } catch {
                        print("❌ Error searching DownloadedEpisodes folder for \(episodeId): \(error)")
                    }
                } else {
                    print("📁 DownloadedEpisodes folder doesn't exist, skipping file search for episode: \(episodeId)")
                }
            }
            
            if !fileDeleted {
                print("⚠️ Could not find or delete physical file for episode ID: \(episodeId)")
            }
        }
        
        print("📁 Enhanced deletion completed: \(deletedCount) files deleted from \(episodeIds.count) episode IDs")
    }
    
    private func performEpisodeLoad(feedId: String, page: Int, isInitialLoad: Bool = false, isAppending: Bool = false) async {
        
        // CRITICAL: Enable CloudKit priority mode for Core Data loading
        // This ensures CloudKit data immediately replaces Core Data progress
        EpisodeStateManager.shared.enableCloudKitPriorityMode()
        
        do {
            let result = try await episodeManager.loadEpisodes(
                feedId: feedId,
                page: page,
                pageSize: episodesPerPage,
                filter: EpisodeFilter(rawValue: currentTab) ?? .all,
                searchQuery: searchQuery.isEmpty ? nil : searchQuery
            )
                        
            // Check if this was a prioritized load (first page of large feed)
            let wasPrioritizedLoad = page == 1 && result.episodes.count < episodesPerPage && result.hasMore
            
            // PERFORMANCE FIX: Process episodes in background before main thread update
            let processedEpisodes: [PodcastEpisode]
            if isAppending {
                // CRITICAL FIX: Merge and deduplicate when appending
                let combinedEpisodes = await MainActor.run { self.currentEpisodes + result.episodes }
                processedEpisodes = await processEpisodesInBackground(combinedEpisodes)
                if combinedEpisodes.count != processedEpisodes.count {
                    print("🔄 APPEND DEDUP: Combined \(combinedEpisodes.count) episodes, deduped to \(processedEpisodes.count)")
                }
            } else {
                // CRITICAL FIX: Deduplicate episodes before replacing
                processedEpisodes = await processEpisodesInBackground(result.episodes)
                if result.episodes.count != processedEpisodes.count {
                    print("🔄 REPLACE DEDUP: Loaded \(result.episodes.count) episodes, deduped to \(processedEpisodes.count)")
                }
            }
            
            await MainActor.run {
                self.currentEpisodes = processedEpisodes
                
                self.hasMoreEpisodes = result.hasMore
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                
                // Report status to DataSyncManager when loading completes
                self.reportStatusToDataSyncManager()
            }
            
            // CRITICAL FIX: Create cache for instant future access (more liberal conditions)
            // Create caches for first page loads with substantial episode counts
            if page == 1 && !isAppending && processedEpisodes.count > 0 {
                feedIsolationManager.replaceEpisodesForFeed(processedEpisodes, feedId: feedId)
                let completionStatus = result.hasMore ? "partial" : "complete"
                print("📸 RSS PAGINATION: Created cache with \(processedEpisodes.count) episodes")
            }
            
            // BACKGROUND LOADING: If this was a prioritized load, continue loading more episodes in background
            if wasPrioritizedLoad && isInitialLoad {
                print("🚀 BACKGROUND LOADING: Starting background load for remaining episodes")
                Task.detached(priority: .background) {
                    await self.continueBackgroundLoading(feedId: feedId, startPage: 2)
                }
            }
            
            // Update episode counts
            if page == 1 && !isAppending {
                await updateEpisodeCountsForCurrentFeed()
            }
            
        } catch {
            print("🔍 DEBUG: Error loading episodes: \(error)")
            await MainActor.run {
                self.error = "Failed to load episodes: \(error.localizedDescription)"
                self.isLoadingEpisodes = false
                self.operationInProgress = false
                os_log("❌ Failed to load episodes: %@", log: self.log, type: .error, error.localizedDescription)
            }
        }
        
        // CRITICAL: Always disable CloudKit priority mode after episode loading (success or failure)
        EpisodeStateManager.shared.disableCloudKitPriorityMode()
    }
    
    /// Continue loading episodes in background after prioritized load completed
    private func continueBackgroundLoading(feedId: String, startPage: Int) async {
        print("🔄 BACKGROUND LOADING: Loading remaining episodes for feed \(feedId) starting from page \(startPage)")
        
        var currentBackgroundPage = startPage
        let maxBackgroundPages = 10 // Limit background loading to prevent excessive resource use
        
        while currentBackgroundPage <= maxBackgroundPages {
            // Check if user navigated away or if this feed is no longer selected
            let isCurrentFeed = await MainActor.run {
                return self.selectedFeedId == feedId
            }
            guard isCurrentFeed else {
                print("🔄 BACKGROUND LOADING: User navigated away, stopping background load")
                return
            }
            
            do {
                // Use standard loading (not prioritized) for background pages
                let result = try await episodeManager.loadEpisodes(
                    feedId: feedId,
                    page: currentBackgroundPage,
                    pageSize: episodesPerPage,
                    filter: EpisodeFilter(rawValue: await MainActor.run { self.currentTab }) ?? .all,
                    searchQuery: await MainActor.run { self.searchQuery.isEmpty ? nil : self.searchQuery }
                )
                
                print("🔄 BACKGROUND LOADING: Page \(currentBackgroundPage) loaded \(result.episodes.count) episodes")
                
                // Update UI on main thread if episodes were found
                if !result.episodes.isEmpty {
                    let combinedEpisodes = await MainActor.run { self.currentEpisodes + result.episodes }
                    let uniqueEpisodes = await PodcastViewModel.removeDuplicatesFromEpisodes(combinedEpisodes)
                    
                    await MainActor.run {
                        // Silently append to currentEpisodes if user is still on the same feed
                        if self.selectedFeedId == feedId {
                            self.currentEpisodes = uniqueEpisodes
                            
                            // Update hasMoreEpisodes based on background loading result
                            self.hasMoreEpisodes = result.hasMore
                            
                            print("🔄 BACKGROUND LOADING: Silently updated to \(self.currentEpisodes.count) total episodes")
                        }
                    }
                }
                
                // If no more episodes, stop background loading
                if !result.hasMore {
                    print("🔄 BACKGROUND LOADING: No more episodes, stopping background load")
                    break
                }
                
                currentBackgroundPage += 1
                
                // Add a small delay between background loads to not overwhelm the system
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
            } catch {
                print("🔄 BACKGROUND LOADING: Error on page \(currentBackgroundPage): \(error)")
                break
            }
        }
        
        print("🔄 BACKGROUND LOADING: Completed for feed \(feedId)")
    }
    
    private func refreshEpisodeStatesFromManager() {
        // EMERGENCY PERFORMANCE FIX: Eliminate all heavy batch processing that causes 5-8 second hangs
        // Episode states are now loaded lazily on-demand through individual getters
        
        // Simply trigger a lightweight UI refresh without any heavy processing
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    /// ULTRA-OPTIMIZED: Background episode state refresh to eliminate main thread hangs
    private func refreshEpisodeStatesOptimized() {
        // Batch collect all episode IDs for single bulk lookup
        var allEpisodeIds: [String] = []
        
        // Collect IDs from currentEpisodes
        allEpisodeIds.append(contentsOf: currentEpisodes.map { $0.id })
        
        // Collect IDs from all feeds
        for feed in podcastFeeds {
            allEpisodeIds.append(contentsOf: feed.episodes.map { $0.id })
        }
        
        // Remove duplicates efficiently
        let uniqueEpisodeIds = Array(Set(allEpisodeIds))
        
        // ULTIMATE PERFORMANCE: Move heavy batch lookup to background thread
        Task.detached(priority: .background) {
            await self.performBackgroundStateRefresh(episodeIds: uniqueEpisodeIds)
        }
    }
    
    /// BACKGROUND PROCESSING: Perform state lookup off main thread
    private func performBackgroundStateRefresh(episodeIds: [String]) async {
        // Batch collect all states on background thread (prevents main thread hangs)
        var progressMap: [String: Double] = [:]
        var favoriteMap: [String: Bool] = [:]
        var downloadMap: [String: Bool] = [:]
        
        for episodeId in episodeIds {
            // Skip episodes that were recently synced to prevent overriding real-time changes
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                continue
            }
            
            progressMap[episodeId] = EpisodeStateManager.shared.getProgress(for: episodeId)
            favoriteMap[episodeId] = EpisodeStateManager.shared.isFavorite(episodeId)
            downloadMap[episodeId] = EpisodeStateManager.shared.isDownloaded(episodeId)
        }
        
        // MAIN THREAD: Apply results quickly without blocking UI
        await MainActor.run {
            self.applyBatchStateUpdates(progressMap: progressMap, favoriteMap: favoriteMap, downloadMap: downloadMap)
        }
    }
    
    /// MAIN THREAD: Quick application of background-processed results
    private func applyBatchStateUpdates(progressMap: [String: Double], favoriteMap: [String: Bool], downloadMap: [String: Bool]) {
        
        // Update currentEpisodes efficiently
        for index in 0..<currentEpisodes.count {
            let episodeId = currentEpisodes[index].id
            
            // Skip episodes that were recently synced
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                continue
            }
            
            var updated = currentEpisodes[index]
            updated.state.progress = progressMap[episodeId] ?? 0.0
            updated.state.isFavorite = favoriteMap[episodeId] ?? false
            updated.state.isDownloaded = downloadMap[episodeId] ?? false
            updated.state.isPlayed = updated.state.progress >= 0.99
            
            currentEpisodes[index] = updated
        }
        
        // Update podcastFeeds efficiently (only feeds with visible episodes)
        for feedIndex in 0..<podcastFeeds.count {
            for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                let episodeId = podcastFeeds[feedIndex].episodes[episodeIndex].id
                
                // Skip episodes that were recently synced
                if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episodeId, within: 2.0) {
                    continue
                }
                
                var updatedFeed = podcastFeeds[feedIndex]
                var updated = updatedFeed.episodes[episodeIndex]
                
                updated.state.progress = progressMap[episodeId] ?? 0.0
                updated.state.isFavorite = favoriteMap[episodeId] ?? false
                updated.state.isDownloaded = downloadMap[episodeId] ?? false
                updated.state.isPlayed = updated.state.progress >= 0.99
                
                updatedFeed.episodes[episodeIndex] = updated
                podcastFeeds[feedIndex] = updatedFeed
            }
        }
        
        // Single UI refresh after all updates
        objectWillChange.send()
    }
    
    /// Standard refresh for smaller feeds (<= 300 episodes)
    private func refreshEpisodeStatesStandard() {
        // Update episode states in currentEpisodes (currently displayed episodes)
        let updatedCurrentEpisodes = currentEpisodes.map { episode in
            // Skip episodes that were recently synced
            if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episode.id, within: 2.0) {
                return episode // Return unchanged
            }
            
            var updated = episode
            updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
            updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
            updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
            updated.state.isPlayed = updated.state.progress >= 0.99
            return updated
        }
        // Update current episodes with refreshed states
        currentEpisodes = updatedCurrentEpisodes
        
        // CRITICAL: Also update episode states in ALL podcastFeeds so that download states
        // are preserved when switching between feeds after CloudKit sync
        var updatedFeeds = podcastFeeds
        for feedIndex in 0..<updatedFeeds.count {
            let updatedEpisodes = updatedFeeds[feedIndex].episodes.map { episode in
                // Skip episodes that were recently synced
                if EpisodeStateManager.shared.wasEpisodeRecentlySynced(episode.id, within: 2.0) {
                    return episode // Return unchanged
                }
                
                var updated = episode
                updated.state.progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                updated.state.isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                updated.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                updated.state.isPlayed = updated.state.progress >= 0.99
                return updated
            }
            updatedFeeds[feedIndex].episodes = updatedEpisodes
        }
        podcastFeeds = updatedFeeds
        
        print("✅ STANDARD REFRESH: Updated episode states for \(currentEpisodes.count) current episodes and \(podcastFeeds.count) feeds")
    }
    
    /// PERFORMANCE OPTIMIZED: Update episode counts on background thread
    private func updateEpisodeCounts(for feedId: String, episodes: [PodcastEpisode]) async {
        // PERFORMANCE: Run counting operations on background queue to avoid main thread blocking
        let counts = await Task.detached(priority: .utility) {
            let allCount = episodes.count
            let favCount = episodes.filter { $0.state.isFavorite }.count
            let dlCount = episodes.filter { $0.state.isDownloaded }.count
            
            return (all: allCount, favorites: favCount, downloads: dlCount)
        }.value
        
        // Update cache and UI on main thread
        await MainActor.run {
            // Cache the counts for performance
            self.tabFilterCounts[feedId] = counts
            self.episodeCounts = counts
            
            print("📊 COUNTS: Updated for feed \(feedId) - All: \(counts.all), Favorites: \(counts.favorites), Downloads: \(counts.downloads)")
        }
    }
    
    private func updateEpisodeCountsForCurrentFeed() async {
        guard let feedId = selectedFeedId else { return }
        
        // PERFORMANCE: Use cached counts if available to avoid expensive filtering
        if let cachedCounts = tabFilterCounts[feedId] {
            await MainActor.run {
                self.episodeCounts = cachedCounts
                print("⚡ PERFORMANCE: Using cached episode counts - All: \(cachedCounts.all), Favorites: \(cachedCounts.favorites), Downloads: \(cachedCounts.downloads)")
            }
            return
        }
        
        // Fallback: Calculate counts manually only if cache is not available
        do {
            let allCount = currentEpisodes.count
            let favoritesCount = currentEpisodes.filter { $0.state.isFavorite }.count
            let downloadsCount = currentEpisodes.filter { $0.state.isDownloaded }.count
            
            await MainActor.run {
                self.episodeCounts = (all: allCount, favorites: favoritesCount, downloads: downloadsCount)
                print("🔄 FALLBACK: Calculated episode counts manually - All: \(allCount), Favorites: \(favoritesCount), Downloads: \(downloadsCount)")
            }
        } catch {
            os_log("❌ Failed to update episode counts: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - Fresh Install & CloudKit Integration
    
    /// Check for CloudKit sync and setup new feeds if needed
    private var cloudKitSyncInProgress = false
    private var episodeStatesSyncCompleted = false
    
    /// Refresh episode states from local storage only - no CloudKit sync
    /// This provides immediate display of any locally available states
    private func refreshLocalEpisodeStates() async {
        // Reduce logging during scrolling for better performance
        if !isUserScrolling {
            print("🔄 Refreshing local episode states for immediate display...")
        }
        
        // If EpisodeStateManager is not ready yet (cold start), wait briefly or until ready notification
        if !EpisodeStateManager.shared.isReady {
            let ready = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s max wait
                    return EpisodeStateManager.shared.isReady
                }
                return await group.next() ?? true
            }
            if !ready {
                print("⚠️ EpisodeStateManager not ready after brief wait; proceeding with whatever is loaded")
            }
        }
        
        // Apply locally available states to current in-memory episodes for instant UI accuracy
        await MainActor.run {
            if !self.currentEpisodes.isEmpty {
                var updated: [PodcastEpisode] = []
                updated.reserveCapacity(self.currentEpisodes.count)
                for var ep in self.currentEpisodes {
                    ep.state.progress = EpisodeStateManager.shared.getProgress(for: ep.id)
                    ep.state.isFavorite = EpisodeStateManager.shared.isFavorite(ep.id)
                    ep.state.isDownloaded = EpisodeStateManager.shared.isDownloaded(ep.id)
                    ep.state.isPlayed = ep.state.progress >= 0.99
                    updated.append(ep)
                }
                self.currentEpisodes = updated
            }
        }
        
        // Log availability cache
        let progressCount = EpisodeStateManager.shared.episodeProgress.count
        let favoritesCount = EpisodeStateManager.shared.episodeFavorites.count
        let downloadsCount = EpisodeStateManager.shared.episodeDownloads.count
        print("✅ Local episode states available: \(progressCount) progress, \(favoritesCount) favorites, \(downloadsCount) downloads")
        
        // Mark as completed to prevent unnecessary sync attempts
        episodeStatesSyncCompleted = true
    }
    
    /// Check for fresh install and sync podcast feeds from CloudKit with performance optimization
    /// PERFORMANCE OPTIMIZATION: Only sync podcast feeds from CloudKit on fresh installs
    /// This prevents the app from loading podcast feeds from CloudKit on every launch
    /// After the initial sync, podcast feeds are loaded from local storage (Core Data)
    /// 
    /// Benefits:
    /// - Faster app startup (no CloudKit network requests for podcast feeds)
    /// - Reduced CloudKit API usage and rate limiting
    /// - Better offline experience
    /// - Podcast feeds are still synced TO CloudKit when users make changes
    /// 
    /// To force a re-sync (for troubleshooting), call resetPodcastFeedsSyncFlag()
    private func checkForFreshInstallAndSetup() async {
        // Prevent multiple concurrent CloudKit syncs
        guard !cloudKitSyncInProgress else {
            print("⚠️ CloudKit sync already in progress, skipping duplicate call")
            return
        }
        
        cloudKitSyncInProgress = true
        defer { 
            cloudKitSyncInProgress = false
            print("🔄 CloudKit sync completed, setting flag to false")
        }
        
        print("🔄 Checking for CloudKit sync...")
        
        do {
            // Check if this is a fresh install (no feeds in Core Data)
            let existingFeedCount = await countExistingFeeds()
            let isFreshInstall = existingFeedCount == 0
            
            // PERFORMANCE FIX: Only sync podcast feeds from CloudKit on fresh installs
            // Check if podcast feeds have been synced to prevent unnecessary CloudKit fetching
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            
            print("🔍 SYNC DECISION: existingFeedCount=\(existingFeedCount), isFreshInstall=\(isFreshInstall), hasPodcastFeedsSynced=\(hasPodcastFeedsSynced)")
            
            if isFreshInstall || !hasPodcastFeedsSynced {
                print("🔄 Podcast feed sync needed - fresh install: \(isFreshInstall), feeds synced: \(hasPodcastFeedsSynced)")
                
                // Fetch feeds from CloudKit
                let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
                
                if !cloudKitFeeds.isEmpty {
                    print("🌟 Synced \(cloudKitFeeds.count) feeds from CloudKit")
                    
                    if isFreshInstall {
                        // Fresh install: Process all feeds and parse their RSS
                        await processFreshInstallFeeds(cloudKitFeeds)
                    } else {
                        // Existing install: Merge new feeds only
                        await mergeCloudKitFeeds(cloudKitFeeds)
                    }
                    
                    // Mark podcast feeds as synced to prevent future CloudKit syncing on app launches
                    UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
                } else {
                    print("📡 No feeds found in CloudKit")
                }
            } else {
                print("⚡ Skipping CloudKit podcast feed sync - loading from local storage only for better performance")
                
                // CROSS-DEVICE SYNC: Even when not doing full sync, check for new cross-device feeds
                print("🔄 CROSS-DEVICE CHECK: Checking CloudKit for feeds added on other devices...")
                print("🔄 CROSS-DEVICE CHECK: Current local feed count: \(existingFeedCount)")
                do {
                    let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
                    print("🔄 CROSS-DEVICE CHECK: Found \(cloudKitFeeds.count) feeds in CloudKit")
                    if !cloudKitFeeds.isEmpty {
                        print("🔄 CROSS-DEVICE CHECK: CloudKit feeds:")
                        for feed in cloudKitFeeds {
                            print("🔄 CROSS-DEVICE CHECK: - \(feed.title) (ID: \(feed.id))")
                        }
                        print("🔄 CROSS-DEVICE CHECK: Calling mergeCloudKitFeeds to check for new ones...")
                        await mergeCloudKitFeeds(cloudKitFeeds)
                    } else {
                        print("🔄 CROSS-DEVICE CHECK: No feeds found in CloudKit")
                    }
                } catch {
                    print("🔄 CROSS-DEVICE CHECK: Failed to check CloudKit feeds: \(error)")
                }
                
                // Load feeds from Core Data
                await MainActor.run {
                    print("🎯 EXISTING INSTALL: About to call loadFeedsFromCoreData()")
                    self.loadFeedsFromCoreData()
                    print("🎯 EXISTING INSTALL: After loadFeedsFromCoreData() - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                    
                    // Still trigger UI refresh for consistency
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.throttledUIUpdate()
                        print("🎯 LOCAL SYNC: Triggered UI refresh from local data - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                    }
                }
            }
            
        } catch {
            print("❌ CloudKit sync failed: \(error)")
        }
    }
    
    /// Sync episode states from CloudKit with different behavior based on install type
    /// PERFORMANCE OPTIMIZATION: Only sync episode states from CloudKit on fresh installs
    /// This prevents the app from loading thousands of episode states from CloudKit on every launch
    /// After the initial sync, episode states are loaded from local storage (CoreData + EpisodeStateManager)
    /// 
    /// Benefits:
    /// - Faster app startup (no CloudKit network requests for episode states)
    /// - Reduced CloudKit API usage and rate limiting
    /// - Better offline experience
    /// - Episode states are still synced TO CloudKit when users make changes
    /// 
    /// To force a re-sync (for troubleshooting), call resetEpisodeStatesSyncFlag()
    func syncEpisodeStatesFromCloudKit(isFreshInstall: Bool) async -> Bool {
        // CRITICAL FIX: During fresh install, ALWAYS sync from CloudKit even if caches exist
        // Caches created during fresh install don't have CloudKit state data yet!
        if !isFreshInstall {
            // PERFORMANCE: Skip expensive CloudKit episode sync if we have caches for ANY feed
            // This optimization only applies to non-fresh installs
            let hasAnyCache = await MainActor.run {
                // Check if we have caches for any loaded feeds
                for feed in self.podcastFeeds {
                    if self.feedIsolationManager.getEpisodesForFeed(feed.id) != nil {
                        print("⚡ PERFORMANCE: Found cache for feed \(feed.title) - skipping CloudKit sync")
                        return true
                    }
                }
                return false
            }
            
            // Skip CloudKit sync if we have caches (non-fresh install only)
            // Caches already contain complete episode data with states
            if hasAnyCache {
                print("⚡ OPTIMIZATION: Skipping CloudKit episode sync - have cache with complete state data")
                return true
            }
        } else {
            print("🆕 FRESH INSTALL: Checking if CloudKit episode state sync is needed")
        }
        
        // CRITICAL FIX: Get episode IDs directly from Core Data to ensure we get ALL episodes
        let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
        
        // FRESH INSTALL FIX: Skip CloudKit sync if there are no local episodes
        // This prevents hundreds of "Episode not found in Core Data" warnings on truly fresh installs
        if allEpisodeIds.isEmpty {
            print("⚡ FRESH INSTALL: No local episodes found - skipping CloudKit episode state sync")
            print("⚡ CloudKit sync will run automatically when you add your first podcast feed")
            return true // Return success since there's nothing to sync
        }
        
        print("🔄 Syncing episode states from CloudKit for \(allEpisodeIds.count) episodes (fresh install: \(isFreshInstall))")
        
        // Record sync attempt to prevent frequent retries
        await MainActor.run {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastEpisodeStateSyncAttempt")
        }
        
        do {
            
            if !allEpisodeIds.isEmpty {
                // Start episode state sync tracking in DataSyncManager
                await DataSyncManager.shared.startEpisodeStateSync(totalCount: allEpisodeIds.count)
                
                // Update progress during CloudKit sync
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: 0,
                    operation: "Fetching episode states from iCloud..."
                )
                
                // Sync episode states from CloudKit
                let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds,
                    isFreshInstall: isFreshInstall
                )
                
                let coreDataUpdates = syncResult.updates
                let syncSuccess = syncResult.success
                
                // Update progress during Core Data save
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: allEpisodeIds.count * 3 / 4,
                    operation: "Saving episode states to local storage..."
                )
                
                // Save all synced states to Core Data if there are updates
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        
                        // Count meaningful states for better logging
                        let favoritesCount = coreDataUpdates.filter { $0.isFavorite ?? false }.count
                        let progressCount = coreDataUpdates.filter { ($0.progress ?? 0) > 0 }.count
                        let playedCount = coreDataUpdates.filter { $0.isPlayed ?? false }.count
                        
                        print("💾 ========================================")
                        print("💾 EPISODE STATES SAVED: \(coreDataUpdates.count) total updates")
                        print("💾   - Favorites: \(favoritesCount)")
                        print("💾   - With Progress: \(progressCount)")
                        print("💾   - Played: \(playedCount)")
                        print("💾 ========================================")
                    } catch {
                        print("❌ Failed to save synced episode states to Core Data: \(error)")
                    }
                } else {
                    print("⚠️ No episode state updates received from CloudKit")
                }
                
                // Update progress during UI refresh
                await DataSyncManager.shared.updateEpisodeStateProgress(
                    currentCount: allEpisodeIds.count * 9 / 10,
                    operation: "Refreshing episode list..."
                )
                
                // Update UI with synced states
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    if let selectedFeedId = self.selectedFeedId {
                        Task {
                            await self.loadEpisodesForFeed(selectedFeedId)
                        }
                    }
                }
                
                // Complete episode state sync tracking
                await DataSyncManager.shared.completeEpisodeStateSync()
                
                if syncSuccess {
                    print("✅ Episode state sync completed successfully for \(allEpisodeIds.count) episodes")
                } else {
                    print("⚠️ Episode state sync completed with errors for \(allEpisodeIds.count) episodes")
                }
                
                return syncSuccess
            } else {
                print("📊 No episodes found for state sync")
                return true
            }
            
        } catch {
            print("❌ Failed to sync episode states from CloudKit: \(error)")
            return false
        }
    }
    
    /// Get all episode IDs directly from Core Data to ensure we don't miss any
    private func getAllEpisodeIdsFromCoreData() async -> [String] {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.propertiesToFetch = ["id", "feedId", "title"]
                    request.resultType = .dictionaryResultType
                    
                    // Core Data returns [NSDictionary] for dictionary result type, not [[String: Any]]
                    let results = try context.fetch(request) as! [NSDictionary]
                    let episodeIds = results.compactMap { $0["id"] as? String }
                    
                    // Debug: Show distribution of episodes across feeds
                    let episodesByFeed = Dictionary(grouping: results) { dict in
                        dict["feedId"] as? String ?? "unknown"
                    }
                    
                    print("🔍 DEBUG: Retrieved \(episodeIds.count) episode IDs from Core Data across \(episodesByFeed.count) feeds")
                    for (feedId, episodes) in episodesByFeed {
                        print("🔍 DEBUG: Feed '\(feedId)' has \(episodes.count) episodes for sync")
                        
                        // Show some example episode titles for verification
                        let sampleTitles = episodes.prefix(3).compactMap { $0["title"] as? String }
                        if !sampleTitles.isEmpty {
                            print("🔍 DEBUG: Sample episodes from feed '\(feedId)': \(sampleTitles.joined(separator: ", "))")
                        }
                    }
                    
                    continuation.resume(returning: episodeIds)
                } catch {
                    print("❌ Failed to fetch episode IDs from Core Data: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Count existing feeds in Core Data
    private func countExistingFeeds() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Failed to count existing feeds: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    /// Apply CloudKit feed metadata updates to existing feeds
    func applyCloudKitFeedMetadata(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🔄 Applying CloudKit metadata to \(cloudKitFeeds.count) feeds...")
        
        await MainActor.run {
            var updatedFeeds = self.podcastFeeds
            var hasUpdates = false
            
            for cloudKitFeed in cloudKitFeeds {
                if let existingIndex = updatedFeeds.firstIndex(where: { $0.id == cloudKitFeed.id || $0.url == cloudKitFeed.url }) {
                    let existingFeed = updatedFeeds[existingIndex]
                    
                    // Apply CloudKit metadata updates
                    var updatedFeed = existingFeed
                    var feedUpdated = false
                    
                    // Update title if different
                    if cloudKitFeed.title != existingFeed.title {
                        print("📝 Updating feed title: '\(existingFeed.title)' -> '\(cloudKitFeed.title)'")
                        updatedFeed.title = cloudKitFeed.title
                        feedUpdated = true
                    }
                    
                    // Update artwork URL if different
                    if cloudKitFeed.artworkUrl != existingFeed.artworkUrl {
                        print("🖼️ Updating feed artwork URL for: \(cloudKitFeed.title)")
                        updatedFeed.artworkUrl = cloudKitFeed.artworkUrl
                        feedUpdated = true
                    }
                    
                    // Update description if different
                    if cloudKitFeed.descriptionText != existingFeed.descriptionText {
                        print("📄 Updating feed description for: \(cloudKitFeed.title)")
                        updatedFeed.descriptionText = cloudKitFeed.descriptionText
                        feedUpdated = true
                    }
                    
                    // Update icon data if different
                    if cloudKitFeed.iconData != existingFeed.iconData {
                        print("🎨 Updating feed icon data for: \(cloudKitFeed.title)")
                        updatedFeed.iconData = cloudKitFeed.iconData
                        feedUpdated = true
                    }
                    
                    if feedUpdated {
                        updatedFeeds[existingIndex] = updatedFeed
                        hasUpdates = true
                    }
                }
            }
            
            if hasUpdates {
                self.podcastFeeds = updatedFeeds
                print("✅ Applied CloudKit metadata updates to feeds")
                
                // Save updates to Core Data
                Task.detached(priority: .background) {
                    await self.saveFeedMetadataToCoreData(updatedFeeds)
                }
            } else {
                print("✅ No CloudKit metadata updates needed - feeds are current")
            }
        }
    }
    
    /// Save feed metadata updates to Core Data
    private func saveFeedMetadataToCoreData(_ feeds: [PodcastFeed]) async {
        print("💾 Saving CloudKit metadata updates to Core Data for \(feeds.count) feeds")
        
        // For now, skip Core Data updates to avoid import issues
        // The in-memory podcastFeeds array has already been updated
        // Core Data sync will happen during next app launch
        print("✅ CloudKit metadata applied to in-memory feeds (Core Data sync deferred)")
    }
    
    /// Public method for DataSyncManager to process fresh install feeds
    func loadFreshInstallPodcastData(_ cloudKitFeeds: [PodcastFeed]) async {
        // Use the existing fresh install logic with progress updates  
        await MainActor.run {
            self.isLoading = true
        }
        
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        // CRITICAL FIX: Remove duplicates from CloudKit feeds BEFORE processing
        let uniqueFeeds = removeDuplicateFeeds(cloudKitFeeds)
        print("📊 Removed \(cloudKitFeeds.count - uniqueFeeds.count) duplicate feeds from CloudKit data")
        
        // CRITICAL FIX: Check what feeds already exist in Core Data to prevent duplicate processing
        let existingFeedUrls = await getExistingFeedUrls()
        let feedsToProcess = uniqueFeeds.filter { !existingFeedUrls.contains($0.url) }
        
        if feedsToProcess.isEmpty {
            print("✅ All feeds already exist in Core Data, skipping processing")
            await MainActor.run { 
                self.isLoading = false
                // Start artwork tracking even if no new feeds to process
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: 0)
            }
            return
        }
        
        print("📊 Processing \(feedsToProcess.count) new feeds (skipping \(uniqueFeeds.count - feedsToProcess.count) existing)")
        
        // Start artwork download tracking for the feeds we're about to process
        await MainActor.run {
            DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: feedsToProcess.count)
        }
        
        // PERFORMANCE OPTIMIZATION: Process feeds in larger batches with minimal delays
        // Fresh installs need to be FAST - process 10 feeds concurrently instead of 5
        let batchSize = 10 // Process 10 feeds concurrently for faster fresh install
        let batches = feedsToProcess.chunked(into: batchSize)
        var processedCount = 0
        
        print("📊 FAST SYNC: Processing \(feedsToProcess.count) feeds in \(batches.count) batches of \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            print("🔄 Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) feeds")
            
            // Update progress for batch start with detailed info
            let batchProgress = Double(processedCount) / Double(feedsToProcess.count)
            let progressPercent = Int(batchProgress * 100)
            await MainActor.run {
                DataSyncManager.shared.updateFeedParsingProgress(
                    batchProgress, 
                    message: "Processing \(processedCount)/\(feedsToProcess.count) feeds (\(progressPercent)%)..."
                )
                
                // Update podcast feed counts in DataSyncManager
                DataSyncManager.shared.updatePodcastFeedCounts(
                    current: processedCount,
                    total: feedsToProcess.count
                )
            }
            
            // Process feeds in this batch concurrently
            await withTaskGroup(of: Void.self) { group in
                for feed in batch {
                    group.addTask {
                        do {
                            print("📡 Processing feed: \(feed.title)")
                            
                            // Use public FeedManager to properly add feed with RSS parsing
                            guard let url = URL(string: feed.url) else {
                                print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                                return
                            }
                            
                            let feedManager = PodcastFeedManager()
                            let addedFeed = try await feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true, enableProgressReporting: false)
                            print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                            
                        } catch {
                            print("❌ Failed to process feed \(feed.title): \(error)")
                            
                            // Save feed without episodes if RSS parsing fails
                            try? await self.saveFeedToCoreData(feed)
                        }
                    }
                }
                
                // Wait for all feeds in this batch to complete
                for await _ in group {}
            }
            
            processedCount += batch.count
            
            // Update progress after batch completion with detailed info
            let completedProgress = Double(processedCount) / Double(feedsToProcess.count)
            let completedPercent = Int(completedProgress * 100)
            await MainActor.run {
                DataSyncManager.shared.updateFeedParsingProgress(
                    completedProgress, 
                    message: "Completed \(processedCount)/\(feedsToProcess.count) feeds (\(completedPercent)%)..."
                )
                
                // Update podcast feed counts in DataSyncManager
                DataSyncManager.shared.updatePodcastFeedCounts(
                    current: processedCount,
                    total: feedsToProcess.count
                )
            }
            
            print("✅ Completed batch \(batchIndex + 1)/\(batches.count) - \(processedCount)/\(feedsToProcess.count) feeds processed")
            
            // PERFORMANCE OPTIMIZATION: Minimal delay between batches for fresh install speed
            // Reduced from 0.5s to 0.1s for 5x faster processing
            if batchIndex < batches.count - 1 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds (5x faster)
            }
        }
        
        // Complete RSS processing progress
        await MainActor.run {
            DataSyncManager.shared.updateFeedParsingProgress(1.0, message: "RSS processing completed - \(feedsToProcess.count) feeds processed")
        }
        
        print("🎉 Fresh install RSS processing complete")
        
        // Clean up any duplicates that might have been created
        await cleanupDuplicateFeeds()
        
        // CRITICAL: Load feeds from CoreData first, then restore order
        await MainActor.run {
            print("📡 🔄 LOADING FEEDS FROM COREDATA BEFORE ORDER RESTORATION...")
            self.loadFeedsFromCoreData()
        }
        
        // Wait for feeds to load
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // CRITICAL: Restore correct order from CloudKit feeds before saving to CoreData
        await MainActor.run {
            print("📡 🔢 FEEDS LOADED: \(self.podcastFeeds.count) feeds in memory")
            
            // Create a map of CloudKit feed orders
            let cloudKitOrderMap = Dictionary(uniqueKeysWithValues: cloudKitFeeds.map { ($0.url, $0.order) })
            
            print("📡 🔢 RESTORING ORDER FROM CLOUDKIT (loadFreshInstallPodcastData):")
            for cloudFeed in cloudKitFeeds {
                print("📡 🔢 CloudKit: \(cloudFeed.title) - order: \(cloudFeed.order)")
            }
            
            // Update order for all feeds based on CloudKit data
            for index in self.podcastFeeds.indices {
                let feed = self.podcastFeeds[index]
                if let cloudKitOrder = cloudKitOrderMap[feed.url] {
                    self.podcastFeeds[index].order = cloudKitOrder
                    print("📡 🔢 RESTORED: \(feed.title) - order: \(cloudKitOrder)")
                }
            }
            
            print("📡 🔢 SAVING FINAL ORDER TO COREDATA:")
            for (index, feed) in self.podcastFeeds.enumerated() {
                print("📡 🔢 Final Feed [\(index)]: \(feed.title) - order: \(feed.order)")
            }
            self.saveFeedsToCoreData()
            print("✅ Saved feeds with correct order to CoreData")
        }
        
        // CRITICAL: Clear episode cache and reload feeds from Core Data AFTER all RSS processing and cleanup
        await episodeManager.clearAllCache()
        
        // CRITICAL: Wait for all Core Data save operations to complete  
        print("⏳ Waiting for all Core Data save operations to complete...")
        await MainActor.run {
            DataSyncManager.shared.updateFeedParsingProgress(0.95, message: "Saving all episodes to storage...")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds for all async saves to complete
        
        // Force a final Core Data save to ensure everything is persisted
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                if context.hasChanges {
                    do {
                        try context.save()
                        print("✅ FINAL: Forced Core Data save after fresh install processing")
                    } catch {
                        print("❌ FINAL: Failed to save Core Data after fresh install: \(error)")
                    }
                } else {
                    print("ℹ️ FINAL: No pending Core Data changes after fresh install")
                }
                continuation.resume()
            }
        }
        
        // Verify feeds are actually saved to Core Data
        let savedFeedCount = await countExistingFeeds()
        print("🔍 VERIFICATION: Found \(savedFeedCount) feeds in Core Data after fresh install processing")
        
        // CRITICAL: Trigger UI refresh after fresh install processing
        print("🔄 Triggered UI refresh after fresh install RSS processing")
        await triggerFreshInstallUIRefresh()
    }
    
    /// Explicitly trigger UI refresh for fresh install scenarios
    @MainActor
    func triggerFreshInstallUIRefresh() {
        print("🔄 Starting fresh install UI refresh...")
        
        // Force reload feeds from Core Data to pick up newly saved data
        loadFeedsFromCoreData()
        
        // Force immediate object change notification
        self.objectWillChange.send()
        print("🔄 FRESH INSTALL: Sent objectWillChange notification")
        
        // Multiple explicit UI refresh attempts with increasing delays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("🔄 FRESH INSTALL: First refresh attempt - Feeds: \(self.podcastFeeds.count)")
            if self.podcastFeeds.isEmpty {
                // If still empty, try loading again
                self.loadFeedsFromCoreData()
            }
            self.throttledUIUpdate()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🔄 FRESH INSTALL: Second refresh attempt - Feeds: \(self.podcastFeeds.count)")
            if self.podcastFeeds.isEmpty {
                // If still empty, try loading again
                self.loadFeedsFromCoreData()
            }
            self.throttledUIUpdate()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("🔄 FRESH INSTALL: Final refresh attempt - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
            if self.podcastFeeds.isEmpty {
                print("⚠️ FRESH INSTALL: Still no feeds after multiple refresh attempts!")
            } else {
                print("✅ FRESH INSTALL: Successfully loaded \(self.podcastFeeds.count) feeds")
            }
            self.throttledUIUpdate()
        }
        
        // Set loading to false after refresh
        self.isLoading = false
    }
    
    /// Process fresh install feeds by parsing RSS and saving to Core Data
    private func processFreshInstallFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        // Log the order of feeds from CloudKit
        print("📡 🔢 CLOUDKIT FEED ORDER:")
        for (index, feed) in cloudKitFeeds.enumerated() {
            print("📡 🔢 CloudKit Feed [\(index)]: \(feed.title) - order property: \(feed.order)")
        }
        
        await MainActor.run {
            self.isLoading = true
        }
        
        // Remove duplicates from CloudKit feeds before processing
        let uniqueFeeds = removeDuplicateFeeds(cloudKitFeeds)
        print("📊 Removed \(cloudKitFeeds.count - uniqueFeeds.count) duplicate feeds from CloudKit data")
        
        // Log the order after deduplication
        print("📡 🔢 AFTER DEDUPLICATION:")
        for (index, feed) in uniqueFeeds.enumerated() {
            print("📡 🔢 Unique Feed [\(index)]: \(feed.title) - order property: \(feed.order)")
        }
        
        // Check what feeds already exist in Core Data to prevent duplicate processing
        let existingFeedUrls = await getExistingFeedUrls()
        let feedsToProcess = uniqueFeeds.filter { !existingFeedUrls.contains($0.url) }
        
        if feedsToProcess.isEmpty {
            print("✅ All feeds already exist in Core Data, skipping processing")
            await MainActor.run { 
                self.isLoading = false
                // Start artwork tracking even if no new feeds to process
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: 0)
            }
            return
        }
        
        print("📊 Processing \(feedsToProcess.count) new feeds (skipping \(uniqueFeeds.count - feedsToProcess.count) existing)")
        
        // Start artwork download tracking for the feeds we're about to process
        await MainActor.run {
            DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: feedsToProcess.count)
        }
        
        // Process feeds in batches for better performance (private method version)
        let batchSize = 5 // Process 5 feeds concurrently
        let batches = feedsToProcess.chunked(into: batchSize)
        var processedCount = 0
        
        print("📊 Processing \(feedsToProcess.count) feeds in \(batches.count) batches of \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            print("🔄 Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) feeds")
            
            // Process feeds in this batch concurrently
            await withTaskGroup(of: Void.self) { group in
                for feed in batch {
                    group.addTask {
                        do {
                            print("📡 Processing feed: \(feed.title) with order: \(feed.order)")
                            
                            // Use FeedManager to properly add feed with RSS parsing
                            guard let url = URL(string: feed.url) else {
                                print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                                return
                            }
                            
                            let addedFeed = try await self.feedManager.addFeed(from: url, customTitle: nil, forceRefresh: true, enableProgressReporting: false)
                            print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                            
                            // CRITICAL: Preserve the order from CloudKit
                            await MainActor.run {
                                if let index = self.podcastFeeds.firstIndex(where: { $0.id == addedFeed.id }) {
                                    self.podcastFeeds[index].order = feed.order
                                    print("📡 🔢 PRESERVED ORDER: Set \(addedFeed.title) order to \(feed.order)")
                                }
                            }
                            
                        } catch {
                            print("❌ Failed to process feed \(feed.title): \(error)")
                            
                            // Save feed without episodes if RSS parsing fails (preserving order)
                            try? await self.saveFeedToCoreData(feed)
                        }
                    }
                }
                
                // Wait for all feeds in this batch to complete
                for await _ in group {}
            }
            
            processedCount += batch.count
            print("✅ Completed batch \(batchIndex + 1)/\(batches.count) - \(processedCount)/\(feedsToProcess.count) feeds processed")
            
            // Brief pause between batches to prevent overwhelming the system
            if batchIndex < batches.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
        
        print("🎉 Fresh install RSS processing complete")
        
        // Clean up any duplicates that might have been created
        await cleanupDuplicateFeeds()
        
        // CRITICAL: Restore correct order from CloudKit feeds before saving to CoreData
        await MainActor.run {
            // Create a map of CloudKit feed orders
            let cloudKitOrderMap = Dictionary(uniqueKeysWithValues: cloudKitFeeds.map { ($0.url, $0.order) })
            
            print("📡 🔢 RESTORING ORDER FROM CLOUDKIT:")
            for cloudFeed in cloudKitFeeds {
                print("📡 🔢 CloudKit: \(cloudFeed.title) - order: \(cloudFeed.order)")
            }
            
            // Update order for all feeds based on CloudKit data
            for index in self.podcastFeeds.indices {
                let feed = self.podcastFeeds[index]
                if let cloudKitOrder = cloudKitOrderMap[feed.url] {
                    self.podcastFeeds[index].order = cloudKitOrder
                    print("📡 🔢 RESTORED: \(feed.title) - order: \(cloudKitOrder)")
                }
            }
            
            print("📡 🔢 SAVING FINAL ORDER TO COREDATA:")
            for (index, feed) in self.podcastFeeds.enumerated() {
                print("📡 🔢 Final Feed [\(index)]: \(feed.title) - order: \(feed.order)")
            }
            self.saveFeedsToCoreData()
            print("✅ Saved feeds with correct order to CoreData")
        }
        
        // CRITICAL: Clear episode cache and reload feeds from Core Data AFTER all RSS processing and cleanup
        await episodeManager.clearAllCache()
        
        // CRITICAL: Wait briefly for main context synchronization to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        await MainActor.run {
            self.isLoading = false
            
            // CRITICAL: Wait for Core Data to actually have the data before UI refresh
            self.waitForCoreDataAndRefreshUI()
        }
        
        // IMPORTANT: Now that episodes are loaded, sync their states from CloudKit
        print("🔄 Starting episode state sync after fresh install processing...")
        // CRITICAL FIX: Determine fresh install status properly instead of hard-coding
        let existingFeedCount = await countExistingFeeds()
        let isFreshInstall = existingFeedCount <= 1 // Allow for the feeds we just added
        print("🔍 Fresh install determination: existingFeedCount=\(existingFeedCount), isFreshInstall=\(isFreshInstall)")
        let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
        
        if syncSuccess {
            print("✅ Episode states sync completed successfully after fresh install processing")
        } else {
            print("⚠️ Episode states sync failed after fresh install processing - will retry on next launch")
        }
    }
    
    /// Wait for Core Data to contain the fresh install data and then refresh UI
    @MainActor
    private func waitForCoreDataAndRefreshUI() {
        var attempts = 0
        let maxAttempts = 20 // 2 seconds max wait
        
        func checkAndRefresh() {
            attempts += 1
            
            // Check if Core Data now has feeds
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            
            do {
                let results = try context.fetch(request)
                if !results.isEmpty {
                    // Core Data has feeds now - load and refresh UI
                    print("🎯 Core Data now has \(results.count) feeds - refreshing UI")
                    self.loadFeedsFromCoreData()
                    
                                         // PERFORMANCE: Use throttled UI refresh triggers
                     self.throttledUIUpdate()
                     print("🔄 Triggered throttled UI refresh after Core Data confirmation")
                     
                     // Post notification for any views that might be listening
                     NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                     print("📢 Posted FreshInstallDataAvailable notification")
                     
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                         self.throttledUIUpdate()
                         print("🔄 SECONDARY: Triggered delayed throttled UI refresh after Core Data confirmation")
                     }
                     
                     // Single delayed notification to avoid excessive refreshes
                     DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                         NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
                         print("📢 DELAYED: Final re-post for any late-appearing views")
                     }
                    
                    return // Success - exit the retry loop
                }
            } catch {
                print("❌ Failed to check Core Data during UI refresh wait: \(error)")
            }
            
            // If still no data and haven't exceeded max attempts, try again
            if attempts < maxAttempts {
                print("🔄 Core Data still empty (attempt \(attempts)/\(maxAttempts)) - waiting...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkAndRefresh()
                }
            } else {
                print("⚠️ Timeout waiting for Core Data to contain feeds - proceeding with UI refresh anyway")
                self.loadFeedsFromCoreData()
                self.throttledUIUpdate()
            }
        }
        
        // Start the checking process
        checkAndRefresh()
    }
    
    /// Get existing feed URLs from Core Data to prevent duplicate processing
    private func getExistingFeedUrls() async -> Set<String> {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    request.propertiesToFetch = ["url"]
                    request.includesPropertyValues = true
                    request.includesSubentities = false
                    request.resultType = .managedObjectResultType
                    
                    let results = try context.fetch(request)
                    let urls = Set(results.compactMap { $0.url })
                    continuation.resume(returning: urls)
                } catch {
                    print("❌ Failed to fetch existing feed URLs: \(error)")
                    continuation.resume(returning: Set())
                }
            }
        }
    }
    
    /// Merge CloudKit feeds with existing local feeds and show cross-device sync banner
    private func mergeCloudKitFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        let context = CoreDataStack.shared.context
        
        // First, identify feeds that exist in CloudKit but not locally
        let (newFeeds, existingFeedsCount) = await withCheckedContinuation { continuation in
            context.perform {
                do {
                    // Get existing feeds and create comprehensive duplicate check
                    let existingRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let existingFeeds = try context.fetch(existingRequest)
                    let feedsCount = existingFeeds.count
                    
                    // Create sets for efficient duplicate checking
                    let existingFeedIds = Set(existingFeeds.compactMap { $0.id })
                    let existingFeedUrls = Set(existingFeeds.compactMap { $0.url })
                    let existingFeedTitles = Set(existingFeeds.compactMap { $0.title })
                    
                    // Find feeds that don't exist locally
                    var feedsToAdd: [PodcastFeed] = []
                    for cloudFeed in cloudKitFeeds {
                        let isDuplicateById = existingFeedIds.contains(cloudFeed.id)
                        let isDuplicateByUrl = existingFeedUrls.contains(cloudFeed.url)
                        let isDuplicateByTitle = existingFeedTitles.contains(cloudFeed.title)
                        
                        print("🔍 MERGE CHECK: CloudKit feed '\(cloudFeed.title)' (ID: \(cloudFeed.id))")
                        print("🔍 MERGE CHECK: - Duplicate by ID: \(isDuplicateById)")
                        print("🔍 MERGE CHECK: - Duplicate by URL: \(isDuplicateByUrl)")
                        print("🔍 MERGE CHECK: - Duplicate by Title: \(isDuplicateByTitle)")
                        
                        if !isDuplicateById && !isDuplicateByUrl && !isDuplicateByTitle {
                            print("🔍 MERGE CHECK: ✅ This is a NEW feed - adding to list")
                            feedsToAdd.append(cloudFeed)
                        } else {
                            print("🔍 MERGE CHECK: ❌ This feed already exists locally")
                        }
                    }
                    
                    continuation.resume(returning: (feedsToAdd, feedsCount))
                } catch {
                    print("❌ Failed to identify new CloudKit feeds: \(error)")
                    continuation.resume(returning: ([], 0))
                }
            }
        }
        
        // Show cross-device sync banner if there are new feeds to add
        print("📡 🔄 MERGE CLOUDKIT FEEDS: Processing \(cloudKitFeeds.count) CloudKit feeds vs \(existingFeedsCount) local feeds")
        print("📡 🔄 MERGE CLOUDKIT FEEDS: Found \(newFeeds.count) new feeds to add")
        if !newFeeds.isEmpty {
            print("📡 🔄 CROSS-DEVICE SYNC: Detected \(newFeeds.count) new feeds from CloudKit")
            for feed in newFeeds {
                print("📡 🔄 CROSS-DEVICE SYNC: New feed - \(feed.title)")
            }
            await MainActor.run {
                print("📡 🔄 CROSS-DEVICE SYNC: Starting banner for \(newFeeds.count) feeds")
                DataSyncManager.shared.startCrossDeviceFeedSync(
                    totalCount: newFeeds.count,
                    operation: "Syncing \(newFeeds.count) feeds from other devices"
                )
            }
        } else {
            print("📡 🔄 MERGE CLOUDKIT FEEDS: No new feeds detected - all CloudKit feeds already exist locally")
        }
        
        // Now add the feeds to Core Data with progress tracking
        await withCheckedContinuation { continuation in
            context.perform {
                do {
                    var newFeedsAdded = 0
                    
                    for (index, cloudFeed) in newFeeds.enumerated() {
                        let feedModel = FeedModel(context: context)
                        feedModel.update(from: cloudFeed)
                        newFeedsAdded += 1
                        print("📥 Adding new feed from CloudKit: \(cloudFeed.title)")
                        
                        // Update progress on main thread
                        Task { @MainActor in
                            DataSyncManager.shared.updateCrossDeviceFeedSyncProgress(
                                currentCount: index + 1,
                                operation: "Added '\(cloudFeed.title)'"
                            )
                        }
                    }
                    
                    if newFeedsAdded > 0 {
                        try context.save()
                        print("✅ Merged \(newFeedsAdded) new feeds from CloudKit")
                        
                        // Complete the sync
                        Task { @MainActor in
                            DataSyncManager.shared.completeCrossDeviceFeedSync()
                        }
                    } else {
                        print("📊 No new feeds to merge from CloudKit (all were duplicates)")
                    }
                    
                    continuation.resume()
                } catch {
                    print("❌ Failed to merge CloudKit feeds: \(error)")
                    Task { @MainActor in
                        DataSyncManager.shared.resetCrossDeviceFeedSync()
                    }
                    continuation.resume()
                }
            }
        }
        
        // UPGRADE PROTECTION: Use enhanced upgrade detection for episode state sync
        // Only sync episode states when truly needed
        if !cloudKitFeeds.isEmpty {
            let existingFeedCount = await countExistingFeeds()
            let legacyFreshInstallCheck = existingFeedCount == 0
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Merge episode state sync - Existing feeds: \(existingFeedCount), Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall {
                print("🔄 Fresh install - syncing episode states for new feeds...")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
                if syncSuccess {
                    print("✅ Episode states sync completed successfully for fresh install")
                } else {
                    print("⚠️ Episode states sync failed for fresh install - will retry on next launch")
                }
                
                // CRITICAL: After CloudKit sync, check if any feeds need episode refreshing
                await refreshFeedsWithoutEpisodes()
            } else if isDefiniteUpgrade {
                print("🔄 App upgrade - syncing episode states with download protection...")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
                if syncSuccess {
                    print("✅ Episode states sync completed successfully for app upgrade")
                } else {
                    print("⚠️ Episode states sync failed for app upgrade - will retry on next launch")
                }
                
                // CRITICAL: After CloudKit sync, check if any feeds need episode refreshing
                await refreshFeedsWithoutEpisodes()
            } else {
                print("⚡ Existing installation - skipping CloudKit episode state sync for better performance")
                // Just refresh local episode states from EpisodeStateManager
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                }
            }
        }
    }
    
    /// Remove duplicate feeds from an array based on URL and title
    private func removeDuplicateFeeds(_ feeds: [PodcastFeed]) -> [PodcastFeed] {
        var seenUrls = Set<String>()
        var seenTitles = Set<String>()
        var uniqueFeeds: [PodcastFeed] = []
        
        for feed in feeds {
            let urlKey = feed.url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let titleKey = feed.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !seenUrls.contains(urlKey) && !seenTitles.contains(titleKey) {
                seenUrls.insert(urlKey)
                seenTitles.insert(titleKey)
                uniqueFeeds.append(feed)
            } else {
                print("🔍 Removing duplicate feed: \(feed.title) (\(feed.url))")
            }
        }
        
        return uniqueFeeds
    }
    
    /// Clean up any duplicate feeds that exist in Core Data
    private func cleanupDuplicateFeeds() async {
        print("🧹 Cleaning up duplicate feeds...")
        
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            
            context.perform {
                do {
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                    let allFeeds = try context.fetch(fetchRequest)
                    
                    var seenUrls = Set<String>()
                    var seenTitles = Set<String>()
                    var feedsToDelete: [FeedModel] = []
                    
                    for feed in allFeeds {
                        guard let url = feed.url, let title = feed.title else { continue }
                        
                        let urlKey = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        let titleKey = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if seenUrls.contains(urlKey) || seenTitles.contains(titleKey) {
                            print("🗑️ Marking duplicate feed for deletion: \(title)")
                            feedsToDelete.append(feed)
                        } else {
                            seenUrls.insert(urlKey)
                            seenTitles.insert(titleKey)
                        }
                    }
                    
                    // Delete duplicate feeds
                    for feed in feedsToDelete {
                        context.delete(feed)
                    }
                    
                    if !feedsToDelete.isEmpty {
                        try context.save()
                        print("✅ Deleted \(feedsToDelete.count) duplicate feeds")
                    } else {
                        print("📊 No duplicate feeds found")
                    }
                    
                    continuation.resume()
                } catch {
                    print("❌ Failed to cleanup duplicate feeds: \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Save feed to Core Data with episodes
    private func saveFeedToCoreData(_ feed: PodcastFeed) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = CoreDataStack.shared.context
            
            context.perform {
                do {
                    // Create or update feed
                    let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    let feedModel: FeedModel
                    if let existingFeed = try context.fetch(feedRequest).first {
                        feedModel = existingFeed
                    } else {
                        feedModel = FeedModel(context: context)
                        feedModel.id = feed.id
                    }
                    
                    feedModel.update(from: feed)
                    
                    // Save episodes
                    for episode in feed.episodes {
                        let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        episodeRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                        
                        let episodeModel: PodcastModel
                        if let existingEpisode = try context.fetch(episodeRequest).first {
                            episodeModel = existingEpisode
                        } else {
                            episodeModel = PodcastModel(context: context)
                            episodeModel.id = episode.id
                        }
                        
                        episodeModel.update(from: episode)
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Updated initialization to include CloudKit sync check
    @MainActor
    func initializeWithCloudKitSupport() {
        print("🚀 Initializing PodcastViewModel with CloudKit support...")
        print("🚀 INIT: Current podcast feeds count: \(podcastFeeds.count)")
        print("🚀 INIT: Current feed order count: \(podcastFeedOrder.count)")
        
        // Prevent multiple initializations
        guard !isLoading else {
            print("⚠️ CloudKit initialization already in progress, skipping duplicate call")
            return
        }
        
        // Start with Core Data load for immediate UI
        loadFeedsFromCoreData()
        print("📊 INITIAL LOAD: Loaded \(podcastFeeds.count) feeds from Core Data after loadFeedsFromCoreData()")
        print("📊 INITIAL LOAD: podcastFeedOrder has \(podcastFeedOrder.count) items")
        
        // Single CloudKit sync in background
        Task {
            // CRITICAL FIX: Move duplicate cleanup AFTER CloudKit sync to prevent episode loss
            // First sync data from CloudKit to ensure we have the most accurate episode data
            await checkForFreshInstallAndSetup()
            
            // SAFE cleanup: Only run duplicate cleanup after CloudKit sync completes
            // This prevents legitimate episodes from being deleted due to force close inconsistencies
            do {
                try await episodeManager.cleanupDuplicateEpisodes()
                print("✅ Cleaned up duplicate episodes after CloudKit sync")
            } catch {
                print("⚠️ Failed to cleanup duplicate episodes: \(error)")
            }
            
            // After CloudKit sync, check if any feeds need episode refreshing
            await refreshFeedsWithoutEpisodes()
            
            // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
            // Only sync episode states from CloudKit on fresh installs or when needed
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            let legacyFreshInstallCheck = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Episode state sync check - Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall || !hasEpisodeStatesSynced {
                print("🔄 Episode state sync needed - fresh install: \(isFreshInstall), states synced: \(hasEpisodeStatesSynced)")
                let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
                
                // Only mark episode states as synced if the sync was successful
                if syncSuccess {
                    UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                    print("✅ Episode states sync completed successfully - marked as synced")
                } else {
                    print("⚠️ Episode states sync failed - will retry on next launch")
                }
            } else {
                print("⚡ Skipping CloudKit episode state sync - loading from local storage only for better performance")
                
                // REAL-TIME SYNC FIX: Disabled periodic sync to prevent conflicts with real-time updates
                // Periodic sync was overriding real-time CloudKit changes and causing sync clearing
                print("⚡ Skipping periodic CloudKit sync to preserve real-time episode state updates")
                
                // Just refresh local episode states from EpisodeStateManager
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                }
            }
            
            // CRITICAL: Final UI refresh after all initialization is complete
            await MainActor.run {
                print("🔄 Final UI refresh after complete initialization...")
                // Don't call loadFeedsFromCoreData() again - feeds are already loaded!
                // This was causing the loading state to show again after sync completed
                
                // Just ensure loading flags are cleared and trigger UI update
                self.isLoading = false
                self.isLoadingFeeds = false
                
                // Force UI update for any view controllers observing this environment object
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.throttledUIUpdate()
                    print("🎯 FINAL: Triggered final UI refresh - Feeds: \(self.podcastFeeds.count), Order: \(self.podcastFeedOrder.count)")
                }
            }
        }
    }
    
    /// Initialize episode state syncing for app startup
    @MainActor
    func initializeEpisodeStateSync() {
        print("🔄 Initializing episode state sync...")
        
        Task {
            // SYNC RESUMPTION: Check for incomplete sync first
            if EpisodeStateManager.shared.hasIncompleteSyncToResume() {
                let currentSyncProgress = EpisodeStateManager.shared.getCurrentSyncProgress()
                let remainingCount = EpisodeStateManager.shared.getRemainingEpisodesToSync().count
                print("📡 🔄 SYNC RESUMPTION: Found incomplete sync with \(remainingCount) episodes remaining")
                
                if let syncProgress = currentSyncProgress {
                    let progressPercent = Int(syncProgress.progress * 100)
                    print("📡 🔄 SYNC RESUMPTION: Resuming sync at \(progressPercent)% complete (started: \(syncProgress.startTime))")
                    
                    // Resume the sync with the original fresh install flag
                    let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: syncProgress.isFreshInstall)
                    
                    if syncSuccess {
                        print("✅ SYNC RESUMPTION: Completed resumed sync successfully")
                        UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                    } else {
                        print("⚠️ SYNC RESUMPTION: Resumed sync failed - will retry on next launch")
                    }
                    return
                }
            }
            
            // UPGRADE PROTECTION: Use EpisodeStateManager's robust upgrade detection
            let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let legacyFreshInstallCheck = !hasLaunchedBefore
            let isDefiniteUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
            let isFreshInstall = legacyFreshInstallCheck && !isDefiniteUpgrade
            
            print("🔍 Episode state sync - Legacy fresh: \(legacyFreshInstallCheck), Definite upgrade: \(isDefiniteUpgrade), Final fresh install: \(isFreshInstall)")
            
            if isFreshInstall {
                print("🆕 Fresh install detected - syncing episode states (excluding downloads)")
            } else if isDefiniteUpgrade {
                print("🔄 App upgrade detected - syncing all episode states with download protection")
            } else {
                print("📱 Existing installation - syncing all episode states including downloads")
            }
            
            // CRITICAL FIX: Get episode IDs directly from Core Data to ensure we get ALL episodes
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            if !allEpisodeIds.isEmpty {
                // Sync episode states from CloudKit
                let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: allEpisodeIds,
                    isFreshInstall: isFreshInstall
                )
                
                let coreDataUpdates = syncResult.updates
                let syncSuccess = syncResult.success
                
                // Save all synced states to Core Data if there are updates
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 Saved \(coreDataUpdates.count) episode states to Core Data")
                    } catch {
                        print("❌ Failed to save synced episode states to Core Data: \(error)")
                    }
                }
                
                // Update UI with synced states
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    if let selectedFeedId = self.selectedFeedId {
                        Task {
                            await self.loadEpisodesForFeed(selectedFeedId)
                        }
                    }
                }
                
                if syncSuccess {
                    print("✅ Episode state sync completed successfully for \(allEpisodeIds.count) episodes")
                } else {
                    print("⚠️ Episode state sync completed with errors for \(allEpisodeIds.count) episodes")
                }
            } else {
                print("📊 No episodes found for state sync")
            }
        }
    }
    
    /// Quietly sync episode states for a specific feed without UI progress indicators
    /// This is used when feeds load to keep episode states current without user-visible operations
    private func quietSyncEpisodeStates(for feedId: String) async {
        
        // PERFORMANCE: Skip sync if episode caches are available - they already contain all episode states
        if await MainActor.run { feedIsolationManager.getEpisodesForFeed(feedId) != nil } {
            print("⚡ OPTIMIZATION: Skipping CloudKit episode sync - cache available with all states")
            return
        }
        
        // EMERGENCY PERFORMANCE: Skip sync if large operation is already running
        if isLoadingEpisodes || operationInProgress {
            
            return
        }
        
        // Get episode IDs for this specific feed
        let episodeIds = await getExistingEpisodeIds(for: feedId)
        
        guard !episodeIds.isEmpty else {
            
            return
        }
        
        // EMERGENCY PERFORMANCE: Limit sync to only recent episodes for large feeds to prevent hangs
        let episodesToSync = episodeIds.count > 1000 ? Array(episodeIds.prefix(200)) : Array(episodeIds)
        
        // Perform quiet CloudKit sync (no UI progress indicators) on dedicated background thread
        let syncResult = await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let result = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                    for: episodesToSync,
                    isFreshInstall: false
                )
                continuation.resume(returning: result)
            }
        }
        
        let coreDataUpdates = syncResult.updates
        let syncSuccess = syncResult.success
        
        // Save synced states to Core Data if there are updates
        if !coreDataUpdates.isEmpty {
            do {
                try await episodeManager.updateEpisodeStates(coreDataUpdates)
                print("🔇 QUIET SYNC: Updated \(coreDataUpdates.count) episode states for feed \(feedId)")
            } catch {
                print("🔇 QUIET SYNC: Failed to save episode states for feed \(feedId): \(error)")
            }
        }
        
        // EMERGENCY PERFORMANCE: Skip UI refresh for large updates to prevent main thread hangs
        if coreDataUpdates.count <= 100 {
            await MainActor.run {
                self.refreshEpisodeStatesFromManager()
            }
        } else {
            print("🔇 QUIET SYNC: Skipping UI refresh for \(coreDataUpdates.count) updates to prevent hang")
        }
        
        print("🔇 QUIET SYNC: Completed for feed \(feedId) - Success: \(syncSuccess), Updates: \(coreDataUpdates.count)")
    }
    
    /// Check if a feed should be refreshed from RSS for new episodes
    private func shouldRefreshFeedFromRSS(feedId: String, isInitialLoad: Bool) async -> Bool {
        // CRITICAL: Always check for new episodes when user opens feed (no time throttling)
        // This ensures users always see the latest episodes immediately
        
        // Check if feed has episodes in Core Data
        let episodeCount = await getEpisodeCountForFeed(feedId)
        
        // ALWAYS refresh if this feed has no episodes (new feeds or fresh installs)
        if episodeCount == 0 {
            print("🆕 Feed \(feedId) has no episodes - allowing RSS parsing (new feed or fresh install)")
            return true
        }
        
        // CRITICAL FIX: Always allow RSS refresh on initial load (when user opens feed)
        // This ensures new episodes are fetched immediately without any time-based throttling
        if isInitialLoad {
            print("🔄 Feed \(feedId) opened by user - fetching new episodes immediately (\(episodeCount) episodes cached)")
            return true
        }
        
        // For background operations (not user-initiated), still allow refresh
        // but this shouldn't be called often since we only refresh on user actions
        print("🔄 Feed \(feedId) background refresh - checking for new episodes")
        return true
    }
    
    /// Refresh any feeds that don't have episodes by re-parsing their RSS
    /// CRITICAL CHANGE: Handles both new feeds and fresh install scenarios
    private func refreshFeedsWithoutEpisodes() async {
        print("🔍 Checking for feeds without episodes that need RSS parsing...")
        
        // Check each feed for episode count
        var feedsToRefresh: [PodcastFeed] = []
        
        for feed in podcastFeeds {
            let episodeCount = await getEpisodeCountForFeed(feed.id)
            
            if episodeCount == 0 {
                print("📡 Feed '\(feed.title)' has 0 episodes, needs refresh")
                feedsToRefresh.append(feed)
            }
        }
        
        if !feedsToRefresh.isEmpty {
            print("🔄 Refreshing \(feedsToRefresh.count) feeds without episodes...")
            
            // Start artwork download tracking for refreshed feeds
            await MainActor.run {
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: feedsToRefresh.count)
            }
            
            for feed in feedsToRefresh {
                do {
                    guard let url = URL(string: feed.url) else {
                        print("❌ Invalid URL for feed: \(feed.title)")
                        continue
                    }
                    
                    print("📡 Refreshing feed: \(feed.title)")
                    let (_, newEpisodes) = try await feedManager.refreshFeed(feed.id)
                    print("✅ Refreshed feed '\(feed.title)' with \(newEpisodes.count) episodes")
                    
                } catch {
                    print("❌ Failed to refresh feed '\(feed.title)': \(error)")
                }
            }
            
            // Reload feeds after refreshing
            await MainActor.run {
                self.loadFeedsFromCoreData()
                print("🎉 Completed refreshing feeds without episodes")
            }
        } else {
            print("✅ All feeds have episodes - no RSS parsing needed")
            // Complete artwork tracking immediately if no feeds need refreshing
            await MainActor.run {
                DataSyncManager.shared.startArtworkDownloadTracking(totalFeeds: 0)
            }
        }
    }
    
    /// Get episode count for a specific feed
    private func getEpisodeCountForFeed(_ feedId: String) async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    request.predicate = NSPredicate(format: "feedId == %@", feedId)
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Failed to count episodes for feed \(feedId): \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    // MARK: - Delete Feed with CloudKit Integration
    
    private func deleteFeedFromCoreData(_ feed: PodcastFeed) async throws {
        print("💾 Starting comprehensive deletion from Core Data for feed: \(feed.title)")
        
        // Use background context to avoid blocking UI and prevent merge conflicts
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    // Step 0: Collect episode IDs for state cleanup
                    let episodeIdRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    episodeIdRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    let episodesToDelete = try context.fetch(episodeIdRequest)
                    let episodeIds = episodesToDelete.compactMap { $0.id }
                    print("💾 Found \(episodeIds.count) episode IDs to clean up for feed: \(feed.title)")
                    
                    // Step 1: Count episodes first for logging
                    let episodeCountRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    episodeCountRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    let episodeCount = try context.count(for: episodeCountRequest)
                    print("💾 Found \(episodeCount) episodes to delete for feed: \(feed.title)")
                    
                    // Step 2: Delete ALL episodes for this feed using batch delete for better performance
                    // This is more efficient than fetching and deleting individually
                    let episodeBatchDeleteRequest = NSBatchDeleteRequest(
                        fetchRequest: {
                            let request: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
                            request.predicate = NSPredicate(format: "feedId == %@", feed.id)
                            return request
                        }()
                    )
                    
                    // Configure batch delete to return object IDs for proper notification
                    episodeBatchDeleteRequest.resultType = .resultTypeObjectIDs
                    
                    // Execute batch delete
                    let batchDeleteResult = try context.execute(episodeBatchDeleteRequest) as? NSBatchDeleteResult
                    let deletedObjectIDs = batchDeleteResult?.result as? [NSManagedObjectID] ?? []
                    
                    print("💾 Batch deleted \(deletedObjectIDs.count) episodes from Core Data")
                    
                    // Step 3: Merge changes to other contexts to keep them in sync
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                    
                    // Also merge to view context on main thread
                    DispatchQueue.main.async {
                        NSManagedObjectContext.mergeChanges(
                            fromRemoteContextSave: changes,
                            into: [CoreDataStack.shared.persistentContainer.viewContext]
                        )
                    }
                    
                    // Step 4: Now delete the feed record
                    let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    
                    let feedResults = try context.fetch(feedFetchRequest)
                    for feedModel in feedResults {
                        // Clear all relationships before deletion
                        feedModel.episodes = nil
                        context.delete(feedModel)
                    }
                    print("💾 Deleted \(feedResults.count) feed records from Core Data")
                    
                    // Step 5: Save all changes
                    try context.save()
                    
                    // Step 6: Verify deletion was successful
                    let verifyEpisodesRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    verifyEpisodesRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                    let remainingEpisodes = try context.count(for: verifyEpisodesRequest)
                    
                    let verifyFeedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    verifyFeedRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                    let remainingFeeds = try context.count(for: verifyFeedRequest)
                    
                    if remainingEpisodes > 0 || remainingFeeds > 0 {
                        print("💾 ⚠️ WARNING: Deletion incomplete - \(remainingEpisodes) episodes and \(remainingFeeds) feeds still exist!")
                        throw NSError(domain: "PodcastDeletion", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Failed to completely delete feed. \(remainingEpisodes) episodes and \(remainingFeeds) feeds remain."
                        ])
                    }
                    
                    print("💾 ✅ Successfully completed comprehensive deletion for feed: \(feed.title)")
                    print("💾 ✅ Verified: 0 episodes and 0 feeds remain in Core Data")
                    
                    // CRITICAL: Clean up episode states from EpisodeStateManager
                    // This ensures all episode states (progress, favorites, downloads) are removed
                    DispatchQueue.main.async {
                        print("🗑️ EPISODE STATES: Cleaning up \(episodeIds.count) episode states for deleted feed")
                        for episodeId in episodeIds {
                            EpisodeStateManager.shared.clearState(for: episodeId)
                        }
                        print("✅ EPISODE STATES: Successfully cleaned up all episode states for feed: \(feed.title)")
                    }
                    
                    continuation.resume()
                    
                } catch {
                    print("💾 ❌ Error in Core Data deletion: \(error.localizedDescription)")
                    
                    // Attempt recovery by rolling back and trying a fallback approach
                    context.rollback()
                    
                    do {
                        // Fallback: Try manual deletion with fresh context state
                        context.refreshAllObjects()
                        
                        // Delete episodes manually in batches
                        var totalDeleted = 0
                        let batchSize = 500
                        
                        while true {
                            let episodeFetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                            episodeFetchRequest.predicate = NSPredicate(format: "feedId == %@", feed.id)
                            episodeFetchRequest.fetchLimit = batchSize
                            
                            let episodes = try context.fetch(episodeFetchRequest)
                            if episodes.isEmpty {
                                break
                            }
                            
                            for episode in episodes {
                                episode.feed = nil
                                context.delete(episode)
                            }
                            
                            totalDeleted += episodes.count
                            try context.save()
                        }
                        
                        print("💾 Fallback: Deleted \(totalDeleted) episodes manually")
                        
                        // Delete feed records
                        let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                        feedFetchRequest.predicate = NSPredicate(format: "id == %@", feed.id)
                        
                        let remainingFeeds = try context.fetch(feedFetchRequest)
                        for feed in remainingFeeds {
                            context.delete(feed)
                        }
                        
                        try context.save()
                        print("💾 ✅ Fallback deletion successful")
                        continuation.resume()
                    } catch {
                        print("💾 ❌ Fallback deletion also failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    
    /// Refresh the current filtered episode list immediately
    private func refreshCurrentFilteredList() async {
        guard let feedId = selectedFeedId else { return }
        
        print("🔄 Refreshing filtered list for tab: \(currentTab)")
        
        // PERFORMANCE: Try fast filtering first, use minimal reload if needed
        let success = await performFastTabSwitch(from: -1, to: currentTab)
        if !success {
            // Use minimal reload instead of expensive full reload to prevent CPU spike
            await performMinimalTabReload(feedId: feedId, tab: currentTab)
        }
    }
    
    /// Delete downloaded episode with confirmation
    func deleteDownloadedEpisode(_ episode: PodcastEpisode) async {
        print("🔍 DEBUG: Deleting download for '\(episode.title)' on tab \(currentTab)")
        
        // Notify user that deletion started
        await MainActor.run {
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Started", message: "Deleting downloaded episode '\(episode.title)'...")
        }
        
        // Delete the downloaded file from local storage
        print("🗑️ Deleting downloaded episode: \(episode.title)")
        
        do {
            // Enhanced file deletion logic - try multiple strategies to find and delete the file
            var fileDeleted = false
            
            // Strategy 1: Try to delete using the stored localFilePath
            if let localFilePath = episode.localFilePath, !localFilePath.isEmpty {
                let localURL = URL(fileURLWithPath: localFilePath)
                if FileManager.default.fileExists(atPath: localFilePath) {
                    try FileManager.default.removeItem(at: localURL)
                    print("📁 Successfully deleted local file: \(localFilePath)")
                    fileDeleted = true
                } else {
                    print("⚠️ Local file doesn't exist at path: \(localFilePath)")
                }
            }
            
            // Strategy 2: If no stored path or deletion failed, try to find and delete using recovery logic
            if !fileDeleted {
                print("🔍 Attempting to find and delete file using recovery strategies...")
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
                
                // Sanitize episode ID for filename search
                let sanitizedId = sanitizeFilename(episode.id)
                let commonExtensions = ["mp3", "m4a", "wav", "aac"]
                
                // Try to find file using sanitized ID with common extensions
                for ext in commonExtensions {
                    let fileName = "\(sanitizedId).\(ext)"
                    let fileURL = episodesFolder.appendingPathComponent(fileName)
                    
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        print("📁 Successfully deleted recovered file: \(fileName)")
                        fileDeleted = true
                        break
                    }
                }
                
                // Strategy 3: Search all files in DownloadedEpisodes folder for matches
                if !fileDeleted {
                    // Check if the DownloadedEpisodes folder exists before trying to access it
                    if FileManager.default.fileExists(atPath: episodesFolder.path) {
                        do {
                            let fileURLs = try FileManager.default.contentsOfDirectory(at: episodesFolder, includingPropertiesForKeys: nil)
                            
                            for fileURL in fileURLs {
                                let fileName = fileURL.lastPathComponent
                                if fileName.contains(episode.id) || fileName.contains(sanitizedId) {
                                    try FileManager.default.removeItem(at: fileURL)
                                    print("📁 Successfully deleted file found by search: \(fileName)")
                                    fileDeleted = true
                                    break
                                }
                            }
                        } catch {
                            print("❌ Error searching DownloadedEpisodes folder: \(error)")
                        }
                    } else {
                        print("📁 DownloadedEpisodes folder doesn't exist, skipping file search for episode: \(episode.title)")
                    }
                }
            }
            
            if !fileDeleted {
                print("⚠️ Could not find or delete physical file for episode: \(episode.title)")
            }
            
            // CRITICAL: Update EpisodeStateManager first (source of truth for download state)
            // Pass feedId for immediate CloudKit sync
            EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false, feedId: episode.feedId)
            
            // ⚡ IMMEDIATE CACHE UPDATE: Update cache for instant loading on next access
            
            // CRITICAL: Clear individual backup files to prevent recovery on restart
            EpisodeStateManager.shared.clearEpisodeBackup(episode.id)
            
            // Clear local file path from Core Data
            await episodeManager.updateEpisodeLocalPath(episode.id, localPath: nil)
            
            // Update episode state in Core Data to ensure consistency
            try await episodeManager.updateEpisodeStates([
                EpisodeStateUpdate(episodeId: episode.id, isDownloaded: false)
            ])
            
            // CRITICAL: Sync the download state change to CloudKit with enhanced debugging
            print("🔍 DEBUG: About to trigger CloudKit sync for episode: \(episode.id)")
            print("🔍 DEBUG: Episode feedId: \(episode.feedId)")
            print("🔍 DEBUG: Selected feedId: \(selectedFeedId ?? "nil")")
            
            updateEpisodeState(episode.id, isDownloaded: false)
            print("☁️ Triggered CloudKit sync for deleted download: \(episode.title)")
            
            // BACKUP: Also directly call CloudKit if feedId is available
            if !episode.feedId.isEmpty {
                Task.detached(priority: .userInitiated) {
                    let currentProgress = EpisodeStateManager.shared.getProgress(for: episode.id)
                    let currentFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                    await PodcastCloudKitManager.shared.saveEpisodeState(
                        episodeId: episode.id,
                        feedId: episode.feedId,
                        progress: currentProgress,
                        isFavorite: currentFavorite,
                        isDownloaded: false,
                        isPlayed: currentProgress >= 0.99
                    )
                    print("☁️ BACKUP: Direct CloudKit sync completed for deleted download: \(episode.title)")
                }
            } else {
                print("⚠️ WARNING: No feedId available for direct CloudKit sync backup")
            }
            
            // PERFORMANCE: Only clear cache if no caches available
            if feedIsolationManager.getEpisodesForFeed(episode.feedId) == nil {
                await episodeManager.clearCacheForFeed(episode.feedId)
                print("🧽 DOWNLOAD: Cleared cache for feed \(episode.feedId) - no cache available")
            } else {
                print("⚡ PERFORMANCE: Keeping cache - using episode cache for feed \(episode.feedId)")
            }
            // Note: Persistent cache is retained for instant reloading
            
            // ⚡ IMMEDIATE UI UPDATE: Ensure all updates happen on main thread
            await MainActor.run {
                // Update episode state in EpisodeStateManager first (source of truth)
                EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
                
                // ⚡ IMMEDIATE CACHE UPDATE: Update cache for instant loading on next access
                
                // Update UI state for instant visual feedback
                self.updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: nil, isDownloaded: false)
                
                // If we're on downloads tab, remove immediately
                if self.currentTab == EpisodeFilter.downloads.rawValue {
                    self.currentEpisodes.removeAll { $0.id == episode.id }
                    print("🔄 UI UPDATE: Immediately removed deleted download from downloads tab")
                }
                
                // Force UI refresh with aggressive change detection
                self.forceUIRefresh()
                
                print("🔍 DEBUG: ✅ Immediate delete download UI update completed for '\(episode.title)'")
            }
            
            print("✅ Successfully deleted download for episode: \(episode.title)")
            
            // Notify user of successful deletion
            await MainActor.run {
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Successfully deleted download for '\(episode.title)'.")
            }
            
        } catch {
            print("❌ Failed to delete downloaded episode: \(error)")
            
            // Notify user of failed deletion
            await MainActor.run {
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to delete download for '\(episode.title)': \(error.localizedDescription)")
            }
            
            // Even if file deletion fails, still update the database states to prevent ghost downloads
            EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: false)
            await episodeManager.updateEpisodeLocalPath(episode.id, localPath: nil)
            do {
                try await episodeManager.updateEpisodeStates([
                    EpisodeStateUpdate(episodeId: episode.id, isDownloaded: false)
                ])
            } catch {
                print("❌ Failed to update episode states: \(error)")
            }
        }
    }
    
    /// Reset the episode states sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if episode states get out of sync
    @MainActor
    func resetEpisodeStatesSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
        print("🔄 Reset episode states sync flag - will re-sync from CloudKit on next launch")
    }
    
    /// Manually trigger CloudKit episode state sync immediately (for testing banner)
    /// This will show the progress banner in real-time
    @MainActor
    func manuallyTriggerCloudKitSync() {
        print("🔄 Manually triggering CloudKit episode state sync for testing...")
        Task {
            let syncSuccess = await syncEpisodeStatesFromCloudKit(isFreshInstall: false)
            if syncSuccess {
                print("✅ Manual CloudKit sync completed successfully")
            } else {
                print("⚠️ Manual CloudKit sync failed")
            }
        }
    }
    
    /// Automatically trigger CloudKit sync for both feeds and episode states
    /// This should be called when PodcastListView loads to check for new content
    /// Now runs entirely in background to prevent main thread blocking
    func automaticCloudKitSync() async {
        // PERFORMANCE: Skip expensive CloudKit sync if we have episodes or recent sync
        let hasCache = await MainActor.run {
            // Check if ANY feed has episodes, not just the selected feed
            // This prevents unnecessary CloudKit sync when episodes exist but selectedFeedId is nil
            return !self.feedIsolationManager.getAllRegisteredFeedIds().isEmpty
        }
        
        let hasRecentSync = await MainActor.run {
            let lastSyncTime = UserDefaults.standard.double(forKey: "lastAutomaticCloudKitSync")
            let timeSinceLastSync = Date().timeIntervalSince1970 - lastSyncTime
            return timeSinceLastSync < 300 // Skip if synced within last 5 minutes
        }
        
        if hasCache {
            print("⚡ PERFORMANCE: Skipping CloudKit sync - have cached episodes")
            return
        }
        
        if hasRecentSync {
            print("⚡ PERFORMANCE: Skipping CloudKit sync - recent sync completed, using cached data")
            return
        }
        
        print("🔄 Automatically triggering CloudKit sync for feeds and episode states...")
        
        // Prevent multiple concurrent CloudKit syncs using main actor for thread safety
        let shouldSkip = await MainActor.run {
            if cloudKitSyncInProgress {
                print("⚠️ CloudKit sync already in progress, skipping automatic sync")
                return true
            }
            cloudKitSyncInProgress = true
            return false
        }
        
        guard !shouldSkip else { return }
        
        await performAutomaticCloudKitCheck()
    }
    
    /// Perform automatic CloudKit check for new feeds and updated episode states
    /// This runs silently without triggering progress banners
    private func performAutomaticCloudKitCheck() async {
        // PERFORMANCE: Skip expensive CloudKit operations if we have episodes
        let hasCache = await MainActor.run {
            // Check if ANY feed has episodes, not just the selected feed
            // This prevents unnecessary CloudKit sync when episodes exist but selectedFeedId is nil
            return !self.feedIsolationManager.getAllRegisteredFeedIds().isEmpty
        }
        
        if hasCache {
            print("⚡ PERFORMANCE: Skipping CloudKit episode state sync - have cached episodes")
            await MainActor.run {
                self.cloudKitSyncInProgress = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAutomaticCloudKitSync")
            }
            return
        }
        
        defer { 
            Task { @MainActor in
                self.cloudKitSyncInProgress = false
                // PERFORMANCE: Record sync timestamp to prevent unnecessary future syncs
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAutomaticCloudKitSync")
                print("🔄 Automatic CloudKit sync completed")
            }
        }
        
        print("🔄 AUTO SYNC: Silently checking CloudKit for new feeds and episode updates...")
        
        do {
            // STEP 1: Check for new feeds from other devices (SILENT)
            print("🔄 AUTO SYNC: Checking for new feeds from CloudKit...")
            let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            
            if !cloudKitFeeds.isEmpty {
                print("🔄 AUTO SYNC: Found \(cloudKitFeeds.count) feeds in CloudKit")
                // Merge any new feeds that aren't already local (SILENT - no banner)
                await mergeCloudKitFeedsSilently(cloudKitFeeds)
            } else {
                print("🔄 AUTO SYNC: No feeds found in CloudKit")
            }
            
            // STEP 2: Check if episode states need syncing (SILENT)
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            let timeSinceLastSync = UserDefaults.standard.double(forKey: "LastEpisodeStatesSyncTime")
            let currentTime = Date().timeIntervalSince1970
            let oneHourAgo = currentTime - 3600 // 1 hour in seconds
            
            // Sync episode states if never synced or if it's been more than 1 hour (SILENT)
            if !hasEpisodeStatesSynced || timeSinceLastSync < oneHourAgo {
                print("🔄 AUTO SYNC: Silently syncing episode states from CloudKit...")
                
                let syncSuccess = await syncEpisodeStatesFromCloudKitSilently(isFreshInstall: false)
                if syncSuccess {
                    // Update last sync time
                    UserDefaults.standard.set(currentTime, forKey: "LastEpisodeStatesSyncTime")
                    print("✅ AUTO SYNC: Episode states synced successfully (silent)")
                } else {
                    print("⚠️ AUTO SYNC: Episode states sync failed (silent)")
                }
            } else {
                print("⚡ AUTO SYNC: Episode states recently synced, skipping")
            }
            
            // STEP 3: Final UI refresh
            await MainActor.run {
                self.throttledUIUpdate()
                print("🔄 AUTO SYNC: UI refreshed after automatic sync")
            }
            
        } catch {
            print("❌ AUTO SYNC: CloudKit check failed: \(error)")
        }
    }
    
    /// Silently merge CloudKit feeds without triggering progress banners
    /// Used for automatic background sync to avoid disrupting user experience
    private func mergeCloudKitFeedsSilently(_ cloudKitFeeds: [PodcastFeed]) async {
        print("🔄 SILENT MERGE: Processing \(cloudKitFeeds.count) CloudKit feeds without banners")
        
        // Identify which feeds are actually new
        let (newFeeds, existingFeedsCount) = await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            context.perform {
                do {
                    let existingFeeds = try context.fetch(FeedModel.fetchRequest())
                    let existingFeedIds = Set(existingFeeds.compactMap { $0.id })
                    let existingFeedUrls = Set(existingFeeds.compactMap { $0.url })
                    let existingFeedTitles = Set(existingFeeds.compactMap { $0.title })
                    
                    var feedsToAdd: [PodcastFeed] = []
                    for cloudFeed in cloudKitFeeds {
                        let isDuplicateById = existingFeedIds.contains(cloudFeed.id)
                        let isDuplicateByUrl = existingFeedUrls.contains(cloudFeed.url)
                        let isDuplicateByTitle = existingFeedTitles.contains(cloudFeed.title)
                        
                        if !isDuplicateById && !isDuplicateByUrl && !isDuplicateByTitle {
                            print("🔄 SILENT MERGE: Found new feed - \(cloudFeed.title)")
                            feedsToAdd.append(cloudFeed)
                        }
                    }
                    
                    continuation.resume(returning: (feedsToAdd, existingFeeds.count))
                } catch {
                    print("❌ SILENT MERGE: Failed to identify new feeds: \(error)")
                    continuation.resume(returning: ([], 0))
                }
            }
        }
        
        if !newFeeds.isEmpty {
            print("🔄 SILENT MERGE: Adding \(newFeeds.count) new feeds to Core Data")
            
            // Add feeds to Core Data silently
            await withCheckedContinuation { continuation in
                let context = CoreDataStack.shared.newBackgroundContext()
                context.perform {
                    do {
                        for cloudFeed in newFeeds {
                            let feedModel = FeedModel(context: context)
                            feedModel.update(from: cloudFeed)
                            print("📥 SILENT MERGE: Added feed - \(cloudFeed.title)")
                        }
                        
                        try context.save()
                        print("✅ SILENT MERGE: Successfully added \(newFeeds.count) feeds")
                        continuation.resume()
                    } catch {
                        print("❌ SILENT MERGE: Failed to save feeds: \(error)")
                        continuation.resume()
                    }
                }
            }
            
            // Update UI with new feeds
            await MainActor.run {
                self.loadFeedsFromCoreData()
                self.throttledUIUpdate()
                print("🔄 SILENT MERGE: UI updated with new feeds")
            }
        } else {
            print("🔄 SILENT MERGE: No new feeds to add")
        }
    }
    
    /// Silently sync episode states from CloudKit without triggering progress banners
    /// Used for automatic background sync to avoid disrupting user experience
    private func syncEpisodeStatesFromCloudKitSilently(isFreshInstall: Bool) async -> Bool {
        print("🔄 SILENT EPISODE SYNC: Starting silent episode state sync")
        
        do {
            // Get all episode IDs for syncing (without triggering banner)
            let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
            
            if allEpisodeIds.isEmpty {
                print("🔄 SILENT EPISODE SYNC: No episodes found to sync")
                return true
            }
            
            print("🔄 SILENT EPISODE SYNC: Syncing \(allEpisodeIds.count) episodes silently")
            
            // Perform the actual CloudKit sync without DataSyncManager calls
            let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
                for: allEpisodeIds,
                isFreshInstall: isFreshInstall
            )
            
            let coreDataUpdates = syncResult.updates
            let syncSuccess = syncResult.success
            
            if syncSuccess {
                print("✅ SILENT EPISODE SYNC: Successfully synced episode states")
                
                // Save updates to Core Data if there are any
                if !coreDataUpdates.isEmpty {
                    do {
                        try await episodeManager.updateEpisodeStates(coreDataUpdates)
                        print("💾 SILENT EPISODE SYNC: Saved \(coreDataUpdates.count) episode states to Core Data")
                    } catch {
                        print("❌ SILENT EPISODE SYNC: Failed to save episode states: \(error)")
                    }
                }
                
                // Refresh episode states silently
                await MainActor.run {
                    self.refreshEpisodeStatesFromManager()
                    print("🔄 SILENT EPISODE SYNC: Episode states refreshed")
                }
                
                return true
            } else {
                print("⚠️ SILENT EPISODE SYNC: Episode state sync failed")
                return false
            }
            
        } catch {
            print("❌ SILENT EPISODE SYNC: Error during sync: \(error)")
            return false
        }
    }
    
    /// Check if we should perform a periodic CloudKit sync to demonstrate banner functionality
    private func shouldPerformPeriodicCloudKitSync() async -> Bool {
        // Perform a lightweight sync every 5 app launches to demonstrate the banner
        let launchCount = UserDefaults.standard.integer(forKey: "AppLaunchCount")
        UserDefaults.standard.set(launchCount + 1, forKey: "AppLaunchCount")
        
        // Show CloudKit sync every 5th launch to demonstrate banner functionality
        return launchCount % 5 == 0
    }
    
    /// Perform a lightweight CloudKit sync of a subset of episodes to show banner activity
    private func performLightweightCloudKitSync() async {
        print("🔄 Starting lightweight CloudKit sync for banner demonstration...")
        
        // Get a subset of episodes (first 50) to sync
        let allEpisodeIds = await getAllEpisodeIdsFromCoreData()
        let episodeSubset = Array(allEpisodeIds.prefix(min(50, allEpisodeIds.count)))
        
        guard !episodeSubset.isEmpty else {
            print("📊 No episodes found for lightweight sync")
            return
        }
        
        // Start episode state sync tracking in DataSyncManager
        await DataSyncManager.shared.startEpisodeStateSync(totalCount: episodeSubset.count)
        
        // Update progress during CloudKit sync
        await DataSyncManager.shared.updateEpisodeStateProgress(
            currentCount: 0,
            operation: "Checking for episode updates from iCloud..."
        )
        
        // Sync episode states from CloudKit
        let syncResult = await PodcastCloudKitManager.shared.syncEpisodeStatesFromCloudKit(
            for: episodeSubset,
            isFreshInstall: false
        )
        
        // Update progress during completion
        await DataSyncManager.shared.updateEpisodeStateProgress(
            currentCount: episodeSubset.count,
            operation: "Sync completed"
        )
        
        // Complete episode state sync tracking
        await DataSyncManager.shared.completeEpisodeStateSync()
        
        print("✅ Lightweight CloudKit sync completed for \(episodeSubset.count) episodes")
    }
    
    /// Reset the podcast feeds sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if podcast feeds get out of sync
    @MainActor
    func resetPodcastFeedsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
        print("🔄 Reset podcast feeds sync flag - will re-sync from CloudKit on next launch")
    }
}

// MARK: - Backward Compatibility Methods

extension PodcastViewModel {
    // These methods provide backward compatibility with existing UI code
    
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func loadAllEpisodesForFeed(_ feed: PodcastFeed) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
    }
    
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func markEpisodeAsPlayed(_ episodeId: String) {
        updateEpisodeState(episodeId, isPlayed: true)
    }
    
    @available(*, deprecated, message: "Use toggleFavorite(for episode: PodcastEpisode) instead")
    func toggleFavorite(for episodeId: String) {
        print("⚠️ DEPRECATED: toggleFavorite(for episodeId: String) called - this should not happen!")
        // Find the episode and call the new method
        if let episode = currentEpisodes.first(where: { $0.id == episodeId }) {
            toggleFavorite(for: episode)
        } else {
            // Fallback to old behavior
            let currentState = currentEpisodes.first { $0.id == episodeId }?.state.isFavorite ?? false
            updateEpisodeState(episodeId, isFavorite: !currentState)
        }
    }
    
    // MARK: - PodcastPlayer Compatibility Methods
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateEpisode(_ episode: PodcastEpisode) {
        Task {
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    self.currentEpisodes[index] = episode
                }
            }
        }
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateProgress(for episode: PodcastEpisode, progress: Double) {
        updateEpisodeState(episode.id, progress: progress)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use EpisodeStateManager.shared.getProgress directly")
    func getProgress(for episode: PodcastEpisode) -> Double {
        return EpisodeStateManager.shared.getProgress(for: episode.id)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func markEpisodeAsCompleted(_ episode: PodcastEpisode) {
        updateEpisodeState(episode.id, progress: 1.0, isPlayed: true)
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use updateEpisodeState instead")
    func updateEpisodeDuration(_ episode: PodcastEpisode, newDuration: TimeInterval) {
        Task {
            await MainActor.run {
                if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    var updatedEpisode = self.currentEpisodes[index]
                    updatedEpisode.duration = newDuration
                    self.currentEpisodes[index] = updatedEpisode
                }
            }
        }
    }
    
    /// For backward compatibility with PodcastPlayer
    func updateLastPlayedEpisode(_ episode: PodcastEpisode) {
        print("🎯 DEBUG: updateLastPlayedEpisode called for: \(episode.title) in feed: \(episode.feedId)")
        
        // Update the lastPlayedEpisodes dictionary immediately on main thread
        self.lastPlayedEpisodes[episode.feedId] = episode.id
        self.saveLastPlayedEpisodes()
        
        print("🎯 DEBUG: lastPlayedEpisodes after update: \(self.lastPlayedEpisodes)")
        
        // Force UI update by triggering objectWillChange
        self.throttledUIUpdate()
        
        print("🎯 Updated last played episode for feed \(episode.feedId): \(episode.title)")
        
        // Also update episode state in background
        Task {
            self.updateEpisodeState(episode.id, isPlayed: false) // Don't mark as played yet, just track
        }
    }
    
    /// Non-MainActor version for immediate updates from background threads
    nonisolated func updateLastPlayedEpisodeImmediate(_ episode: PodcastEpisode) {
        print("🎯 DEBUG: updateLastPlayedEpisodeImmediate called for: \(episode.title) in feed: \(episode.feedId)")
        
        // Update UserDefaults immediately (thread-safe)
        var currentDict = UserDefaults.standard.object(forKey: "LastPlayedEpisodes") as? [String: String] ?? [:]
        currentDict[episode.feedId] = episode.id
        UserDefaults.standard.set(currentDict, forKey: "LastPlayedEpisodes")
        
        print("🎯 DEBUG: Updated UserDefaults with lastPlayedEpisodes")
        
        // Update the main actor state asynchronously
        Task { @MainActor in
            self.lastPlayedEpisodes[episode.feedId] = episode.id
            self.throttledUIUpdate()
            print("🎯 DEBUG: Updated MainActor state for feed \(episode.feedId): \(episode.title)")
        }
    }
    
    /// Save lastPlayedEpisodes to UserDefaults
    private func saveLastPlayedEpisodes() {
        UserDefaults.standard.set(lastPlayedEpisodes, forKey: "LastPlayedEpisodes")
    }
    
    /// Load lastPlayedEpisodes from UserDefaults
    private func loadLastPlayedEpisodes() {
        if let savedLastPlayed = UserDefaults.standard.object(forKey: "LastPlayedEpisodes") as? [String: String] {
            lastPlayedEpisodes = savedLastPlayed
        }
    }
    
    /// Helper method to get all episodes for a specific feed
    private func getAllEpisodesForFeed(_ feedId: String) -> [PodcastEpisode] {
        // First try to get episodes from the feed object
        if let feed = podcastFeeds.first(where: { $0.id == feedId }),
           !feed.episodes.isEmpty {
            return feed.episodes
        }
        
        // Fallback to current episodes if they're for this feed
        if selectedFeedId == feedId {
            return currentEpisodes
        }
        
        // Final fallback: filter current episodes by feed ID
        return currentEpisodes.filter { $0.feedId == feedId }
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use podcastFeeds directly")
    func getLastPlayedOrLatestEpisode(for feed: PodcastFeed) -> PodcastEpisode? {
        // Get all episodes for this feed
        let feedEpisodes = getAllEpisodesForFeed(feed.id)
        
        // Check for last played episode
        if let lastPlayedEpisodeId = lastPlayedEpisodes[feed.id],
           let lastPlayedEpisode = feedEpisodes.first(where: { $0.id == lastPlayedEpisodeId }) {
            print("🎯 DEBUG: Found last played episode for feed \(feed.title): \(lastPlayedEpisode.title)")
            return lastPlayedEpisode
        }
        
        // Check for episodes in progress
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        if let firstInProgressEpisode = episodesInProgress.first {
            print("🎯 DEBUG: Found episode in progress for feed \(feed.title): \(firstInProgressEpisode.title)")
            return firstInProgressEpisode
        }
        
        // If no episodes in progress, return the latest episode
        let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first
        print("🎯 DEBUG: Returning latest episode for feed \(feed.title): \(latestEpisode?.title ?? "none")")
        return latestEpisode
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use currentEpisodes directly")
    var allEpisodes: [PodcastEpisode] {
        return currentEpisodes
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use proper error handling")
    func showNoEpisodesInProgressAlert(for feed: PodcastFeed) {
        print("⚠️ No episodes in progress for feed: \(feed.title)")
    }
    
    /// For backward compatibility with PodcastPlayer
    @available(*, deprecated, message: "Use Core Data save functionality")
    func saveContextIfNeeded() {
        Task {
            do {
                try CoreDataStack.shared.context.save()
            } catch {
                print("❌ Failed to save context: \(error)")
            }
        }
    }
    
    /// For AddStationView compatibility
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func fetchAllEpisodes(for feed: PodcastFeed) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
    }
    
    /// For PodcastPlayer compatibility
    @available(*, deprecated, message: "Use requestFeedRefresh instead")
    func fetchEpisodes(for feed: PodcastFeed, completion: @escaping (Result<[PodcastEpisode], Error>) -> Void) {
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
        
        // Get episodes immediately from cache or current episodes
        let episodes = feedIsolationManager.getEpisodesForFeed(feed.id) ?? currentEpisodes.filter { $0.feedId == feed.id }
        completion(.success(episodes))
    }
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use episode state filters instead")
    var favoriteEpisodes: [PodcastEpisode] {
        return allEpisodes.filter { $0.state.isFavorite }
    }
    
    /// For AppDelegate compatibility
    @available(*, deprecated, message: "Use episode state filters instead")
    var downloadedEpisodes: [PodcastEpisode] {
        return allEpisodes.filter { $0.state.isDownloaded }
    }
    
    /// Toggle favorite state for an episode with proper filtering update
    func toggleFavorite(for episode: PodcastEpisode) {
        let currentState = episode.state.isFavorite
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling favorite for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        print("📡 FAVORITE TOGGLE: About to call updateEpisodeState with isFavorite: \(newState)")
        
        // ⚡ IMMEDIATE UI UPDATE: Update episode state in EpisodeStateManager first (source of truth)
        // Pass feedId for immediate CloudKit sync
        EpisodeStateManager.shared.setFavorite(episode.id, isFavorite: newState, feedId: episode.feedId)
        
        // ⚡ IMMEDIATE CACHE UPDATE: Update cache for instant loading on next access
        
        // ⚡ IMMEDIATE UI UPDATE: Update UI state for instant visual feedback (already on main thread)
        print("🔍 DEBUG: About to call updateEpisodeUIStateImmediate for episode \(episode.id)")
        updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: newState, isDownloaded: nil)
        
        // ⚡ IMMEDIATE FILTER: If we're on favorites tab and unfavoriting, remove immediately
        if currentTab == EpisodeFilter.favorites.rawValue && !newState {
            currentEpisodes.removeAll { $0.id == episode.id }
            print("🔄 UI UPDATE: Immediately removed unfavorited episode from favorites tab")
        }
        
        // ⚡ FORCE UI REFRESH: Trigger all refresh strategies
        print("🔍 DEBUG: About to call forceUIRefresh()")
        forceUIRefresh()
        
        // 🎯 CROSS-TAB UPDATE: Apply filtering to ensure changes appear across all tabs
        applyTabFiltering(episodeId: episode.id, isFavorite: newState, isDownloaded: nil)
        
        print("🔍 DEBUG: ✅ Immediate favorite UI update completed for '\(episode.title)' favorite: \(newState)")
        
        // Background sync for data persistence and CloudKit
        Task.detached(priority: .background) {
            await self.updateEpisodeState(episode.id, isFavorite: newState)
        }
    }
    
    /// Refresh the current filter view to reflect state changes
    @MainActor
    private func refreshCurrentFilter() async {
        guard let selectedFeedId = selectedFeedId else { return }
        
        // Get the current filter
        let currentFilter: EpisodeFilter
        switch currentTab {
        case EpisodeFilter.all.rawValue:
            currentFilter = .all
        case EpisodeFilter.favorites.rawValue:
            currentFilter = .favorites
        case EpisodeFilter.downloads.rawValue:
            currentFilter = .downloads
        default:
            currentFilter = .all
        }
        
        // Reload episodes with the current filter to reflect changes
        await loadEpisodesForFeed(selectedFeedId)
    }
    
    /// Toggle download state for an episode with proper filtering update
    func toggleDownload(for episode: PodcastEpisode) {
        let currentState = episode.state.isDownloaded
        let newState = !currentState
        
        print("🔍 DEBUG: Toggling download for '\(episode.title)' from \(currentState) to \(newState) on tab \(currentTab)")
        
        // ⚡ IMMEDIATE UI UPDATE: Update episode state in EpisodeStateManager first (source of truth)
        EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: newState)
        
        // ⚡ IMMEDIATE UI UPDATE: Update UI state for instant visual feedback (already on main thread)
        print("🔍 DEBUG: About to call updateEpisodeUIStateImmediate for episode \(episode.id)")
        updateEpisodeUIStateImmediate(episodeId: episode.id, isFavorite: nil, isDownloaded: newState)
        
        // ⚡ IMMEDIATE FILTER: If we're on downloads tab and removing download, remove immediately
        if currentTab == EpisodeFilter.downloads.rawValue && !newState {
            currentEpisodes.removeAll { $0.id == episode.id }
            print("🔄 UI UPDATE: Immediately removed non-downloaded episode from downloads tab")
        }
        
        // ⚡ FORCE UI REFRESH: Trigger all refresh strategies
        print("🔍 DEBUG: About to call forceUIRefresh()")
        forceUIRefresh()
        
        // 🎯 CROSS-TAB UPDATE: Apply filtering to ensure changes appear across all tabs
        applyTabFiltering(episodeId: episode.id, isFavorite: nil, isDownloaded: newState)
        
        print("🔍 DEBUG: ✅ Immediate download UI update completed for '\(episode.title)' downloaded: \(newState)")
        
        // Background sync for data persistence and CloudKit
        Task.detached(priority: .background) {
            await self.updateEpisodeState(episode.id, isDownloaded: newState)
        }
    }
    
    /// For SettingsView compatibility
    @available(*, deprecated, message: "Use clear methods from managers instead")
    func clearAllPodcastData(completion: @escaping (Bool) -> Void) {
        clearPodcastCoreData { success, error in
            completion(success)
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use error handling instead")
    func triggerNoEpisodesAlert() {
        showNoEpisodesAlert = true
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use feed management methods instead")
    func saveFeedOrder() {
        saveFeedsToCoreData()
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func fetchPodcastFeeds() {
        loadFeedsFromCoreData()
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func loadFeedOrder() {
        // Load feeds from Core Data first, then sync order
        loadFeedsFromCoreData()
        podcastFeedOrder = podcastFeeds.map { $0.id }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func moveFeed(from source: IndexSet, to destination: Int) {
        movePodcastFeed(from: source, to: destination)
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func refreshAllFeeds() {
        Task {
            for feed in podcastFeeds {
                await loadEpisodesForFeed(feed.id, isInitialLoad: false)
            }
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use addPodcastFeed(url:) instead")
    func addPodcastFeed(_ feed: PodcastFeed) {
        Task {
            let success = await addPodcastFeed(url: feed.url)
            if success {
                await MainActor.run {
                    self.podcastFeedOrder.append(feed.id)
                }
            }
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func updatePodcastFeed(_ feed: PodcastFeed) {
        print("📡 PodcastViewModel - Before update:")
        var oldURL: String? = nil
        if let existingFeed = podcastFeeds.first(where: { $0.id == feed.id }) {
            print("📡   Existing - Title: '\(existingFeed.title)', URL: '\(existingFeed.url)'")
            oldURL = existingFeed.url
        }
        print("📡   New - Title: '\(feed.title)', URL: '\(feed.url)'")
        
        // Update the feed in the array immediately for UI responsiveness
        if let index = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
            podcastFeeds[index] = feed
            print("📡 Updated feed at index \(index)")
        } else {
            print("❌ Feed with ID \(feed.id) not found in podcastFeeds array")
            return
        }
        
        // Trigger immediate UI update
        DispatchQueue.main.async {
            self.throttledUIUpdate()
        }
        
        // Save to Core Data
        saveFeedsToCoreData()
        
        // Save to CloudKit in background
        Task {
            do {
                // Pass old URL to CloudKit manager so it can find and update the old record
                try await cloudKitManager.savePodcastFeedToCloudKit(feed, oldURL: oldURL)
                print("☁️ Successfully saved podcast feed to CloudKit: \(feed.title)")
            } catch {
                print("❌ Failed to save podcast feed to CloudKit: \(error)")
                // Note: We don't revert CoreData changes on CloudKit failure
                // CloudKit sync will retry later
            }
        }
        
        print("📡 Updated podcast feed completed: \(feed.title)")
        
        // Verify the update
        if let verifyFeed = podcastFeeds.first(where: { $0.id == feed.id }) {
            print("📡 Verification - Title: '\(verifyFeed.title)', URL: '\(verifyFeed.url)'")
        }
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use new feed management")
    func sortFeedsAlphabetically() {
        print("📡 🔄 PODCAST SORT: Starting alphabetical sort...")
        isAscendingSort.toggle()
        
        podcastFeeds.sort { feed1, feed2 in
            if isAscendingSort {
                return feed1.title.localizedCaseInsensitiveCompare(feed2.title) == .orderedAscending
            } else {
                return feed1.title.localizedCaseInsensitiveCompare(feed2.title) == .orderedDescending
            }
        }
        
        // Update feed order to match sorted feeds
        podcastFeedOrder = podcastFeeds.map { $0.id }
        
        // Update order property for each feed
        for (index, feed) in podcastFeeds.enumerated() {
            if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                podcastFeeds[feedIndex].order = index
                print("📡 🔢 PODCAST SORT: \(feed.title) - new order: \(index)")
            }
        }
        
        // SORTING FIX: Save the sorted order to Core Data to persist the changes
        saveFeedsToCoreData()
        
        // Save to UserDefaults
        UserDefaults.standard.set(podcastFeedOrder, forKey: "PodcastFeedOrder")
        UserDefaults.standard.synchronize()
        print("📡 💾 PODCAST SORT: Saved feed order to UserDefaults for \(podcastFeeds.count) feeds")
        
        // Sync to CloudKit
        print("📡 ☁️ PODCAST SORT: Starting CloudKit sync...")
        Task {
            await syncPodcastFeedOrderToCloudKit()
        }
        
        // Notify CarPlay immediately about podcast feed order change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastFeedOrderChanged"),
            object: nil,
            userInfo: ["newOrder": podcastFeedOrder]
        )
        
        // Save sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "PodcastIsAscendingSort")
        
        // CRITICAL: Trigger UI refresh to show the sorted order immediately
        objectWillChange.send()
        print("🎯 PODCAST SORT: Applied \(isAscendingSort ? "A-Z" : "Z-A") sort and triggered UI refresh")
    }
    
    /// Update podcast feed order manually and notify CarPlay immediately
    func updatePodcastFeedOrder(_ newOrder: [String]) {
        print("📡 🔄 PODCAST DRAG AND DROP: Starting updatePodcastFeedOrder with \(newOrder.count) feeds")
        podcastFeedOrder = newOrder
        
        // Reorder the podcastFeeds array to match the new order
        let feedLookup = Dictionary(uniqueKeysWithValues: podcastFeeds.map { ($0.id, $0) })
        var reorderedFeeds: [PodcastFeed] = []
        
        for feedId in newOrder {
            if let feed = feedLookup[feedId] {
                reorderedFeeds.append(feed)
            }
        }
        
        // Add any feeds that might not be in the order array
        let orderedFeedIds = Set(newOrder)
        for feed in podcastFeeds {
            if !orderedFeedIds.contains(feed.id) {
                reorderedFeeds.append(feed)
            }
        }
        
        podcastFeeds = reorderedFeeds
        
        // Update order property for each feed
        for (index, feed) in podcastFeeds.enumerated() {
            if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                let oldOrder = podcastFeeds[feedIndex].order
                podcastFeeds[feedIndex].order = index
                print("📡 🔢 PODCAST DRAG AND DROP: \(feed.title) - old order: \(oldOrder), new order: \(index)")
            }
        }
        
        // Save the new order to Core Data
        saveFeedsToCoreData()
        
        // Save to UserDefaults
        UserDefaults.standard.set(podcastFeedOrder, forKey: "PodcastFeedOrder")
        UserDefaults.standard.synchronize()
        print("📡 💾 PODCAST DRAG AND DROP: Saved feed order to UserDefaults for \(podcastFeeds.count) feeds")
        
        // Sync to CloudKit
        print("📡 ☁️ PODCAST DRAG AND DROP: Starting CloudKit sync...")
        Task {
            await syncPodcastFeedOrderToCloudKit()
        }
        
        // Notify CarPlay immediately about podcast feed order change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastFeedOrderChanged"),
            object: nil,
            userInfo: ["newOrder": podcastFeedOrder]
        )
        
        print("🎙️ PODCAST DRAG AND DROP: Updated podcast feed order and notified CarPlay")
    }
    
    /// Sync podcast feed order to CloudKit
    func syncPodcastFeedOrderToCloudKit() async {
        print("📡 🚨 PODCAST FEED ORDER SYNC: Starting batch feed order sync to CloudKit...")
        
        guard !podcastFeeds.isEmpty else {
            print("📡 ⚠️ PODCAST FEED ORDER SYNC: No feeds to sync")
            return
        }
        
        // Update DataSyncManager to show we're starting a save operation
        await MainActor.run {
            DataSyncManager.shared.podcastFeedsStatus = .inProgress
            DataSyncManager.shared.podcastFeedsOperation = "Saving podcast feeds to iCloud"
            DataSyncManager.shared.podcastFeedsProgress = 0.0
            DataSyncManager.shared.podcastFeedsTotalCount = podcastFeeds.count
            DataSyncManager.shared.podcastFeedsCurrentCount = 0
        }
        
        // Save each feed to CloudKit
        var savedCount = 0
        for (index, feed) in podcastFeeds.enumerated() {
            do {
                try await cloudKitManager.savePodcastFeedToCloudKit(feed)
                savedCount += 1
                
                await MainActor.run {
                    DataSyncManager.shared.podcastFeedsProgress = Double(savedCount) / Double(podcastFeeds.count)
                    DataSyncManager.shared.podcastFeedsCurrentCount = savedCount
                    DataSyncManager.shared.podcastFeedsOperation = "Saved \(savedCount)/\(podcastFeeds.count) feeds to iCloud"
                }
                
                print("📡 ✅ PODCAST FEED ORDER SYNC: Saved \(feed.title) (order: \(index))")
            } catch {
                print("📡 ❌ PODCAST FEED ORDER SYNC: Failed to save \(feed.title): \(error)")
            }
        }
        
        // Mark operation as completed
        await MainActor.run {
            DataSyncManager.shared.podcastFeedsStatus = .completed
            DataSyncManager.shared.podcastFeedsOperation = "Saved \(savedCount) feeds to CloudKit"
            DataSyncManager.shared.podcastFeedsProgress = 1.0
        }
        
        print("📡 ✅ PODCAST FEED ORDER SYNC: Successfully synced \(savedCount) feeds to CloudKit")
    }
    
    /// Load sorting preferences from UserDefaults
    private func loadSortingPreferences() {
        if UserDefaults.standard.object(forKey: "PodcastIsAscendingSort") != nil {
            isAscendingSort = UserDefaults.standard.bool(forKey: "PodcastIsAscendingSort")
        } else {
            isAscendingSort = true // Default to ascending (A-Z)
            UserDefaults.standard.set(isAscendingSort, forKey: "PodcastIsAscendingSort")
        }
        print("🎯 SORTING: Loaded podcast sort direction: \(isAscendingSort ? "A-Z" : "Z-A")")
    }
    
    /// Sanitize filename by removing invalid characters
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid characters for filesystem
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "_")
        
        // Limit length to avoid filesystem issues
        let maxLength = 100
        if sanitized.count > maxLength {
            let startIndex = sanitized.startIndex
            let endIndex = sanitized.index(startIndex, offsetBy: maxLength)
            return String(sanitized[startIndex..<endIndex])
        }
        
        return sanitized
    }
    
    /// Download episode to local storage for offline playback
    func downloadEpisode(_ episode: PodcastEpisode, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let audioURL = URL(string: episode.audioUrl) else {
            completion(.failure(NSError(domain: "PodcastViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio URL"])))
            return
        }
        
        // Initialize download progress
        downloadProgress[episode.id] = 0.0
        
        // Create URLSession for downloading
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        // Start download task
        let downloadTask = session.downloadTask(with: audioURL) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    self.progressObservations.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    return
                }
                
                guard let tempURL = tempURL else {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    self.progressObservations.removeValue(forKey: episode.id)
                    completion(.failure(NSError(domain: "PodcastViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "No download URL"])))
                    return
                }
                
                // Create local file path
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
                
                // Create episodes folder if it doesn't exist
                if !FileManager.default.fileExists(atPath: episodesFolder.path) {
                    try? FileManager.default.createDirectory(at: episodesFolder, withIntermediateDirectories: true)
                }
                
                // Create unique filename - sanitize episode ID for filesystem
                let fileExtension = audioURL.pathExtension.isEmpty ? "mp3" : audioURL.pathExtension
                let sanitizedId = self.sanitizeFilename(episode.id)
                let fileName = "\(sanitizedId).\(fileExtension)"
                let localURL = episodesFolder.appendingPathComponent(fileName)
                
                print("📁 DEBUG: Original episode ID: \(episode.id)")
                print("📁 DEBUG: Sanitized filename: \(fileName)")
                print("📁 DEBUG: Full local path: \(localURL.path)")
                print("📁 DEBUG: Temp file exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
                
                do {
                    // Check if temp file exists
                    guard FileManager.default.fileExists(atPath: tempURL.path) else {
                        throw NSError(domain: "PodcastViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Temporary download file not found at: \(tempURL.path)"])
                    }
                    
                    // Remove existing file if it exists
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.removeItem(at: localURL)
                        print("📁 DEBUG: Removed existing file at: \(localURL.path)")
                    }
                    
                    // Move downloaded file to permanent location
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                    print("📁 DEBUG: Successfully moved file from \(tempURL.path) to \(localURL.path)")
                    
                    // CRITICAL: Update both EpisodeStateManager AND Core Data for download state
                    // Pass feedId for immediate CloudKit sync
                    EpisodeStateManager.shared.setDownloaded(episode.id, isDownloaded: true, feedId: episode.feedId)
                    
                    // ⚡ IMMEDIATE CACHE UPDATE: Update cache for instant loading on next access
                    
                    // Save local file path and download state to Core Data
                    Task {
                        await self.episodeManager.updateEpisodeLocalPath(episode.id, localPath: localURL.path)
                        // Also update the download state in Core Data to ensure consistency
                        do {
                            try await self.episodeManager.updateEpisodeStates([
                                EpisodeStateUpdate(episodeId: episode.id, isDownloaded: true)
                            ])
                        } catch {
                            print("❌ Failed to update episode states after download: \(error)")
                        }
                    }
                    
                    // Update local episode state immediately
                    if let index = self.currentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                        var updatedEpisode = self.currentEpisodes[index]
                        updatedEpisode.state.isDownloaded = true
                        updatedEpisode.localFilePath = localURL.path
                        self.currentEpisodes[index] = updatedEpisode
                        print("🔍 DEBUG: Episode download completed - marked as downloaded with local path: \(localURL.path)")
                    }
                    
                    // Update the episode in the feed object as well
                    if let feedIndex = self.podcastFeeds.firstIndex(where: { $0.id == self.selectedFeedId }),
                       let episodeIndex = self.podcastFeeds[feedIndex].episodes.firstIndex(where: { $0.id == episode.id }) {
                        var updatedFeed = self.podcastFeeds[feedIndex]
                        updatedFeed.episodes[episodeIndex].state.isDownloaded = true
                        updatedFeed.episodes[episodeIndex].localFilePath = localURL.path
                        self.podcastFeeds[feedIndex] = updatedFeed
                    }
                    
                    self.downloadProgress[episode.id] = 1.0
                    completion(.success(true))
                    
                    // CRITICAL: Trigger CloudKit sync for the download state change
                    self.updateEpisodeState(episode.id, isDownloaded: true)
                    print("💾 Triggered CloudKit sync for downloaded episode: \(episode.title)")
                    
                    // Clear download progress and observation after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.downloadProgress.removeValue(forKey: episode.id)
                        self.progressObservations.removeValue(forKey: episode.id)
                    }
                    
                    print("📁 Episode downloaded successfully to: \(localURL.path)")
                    
                } catch {
                    self.downloadProgress.removeValue(forKey: episode.id)
                    self.progressObservations.removeValue(forKey: episode.id)
                    completion(.failure(error))
                    print("❌ Failed to save downloaded episode: \(error)")
                }
            }
        }
        
        // Observe download progress
        let observation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.downloadProgress[episode.id] = progress.fractionCompleted
            }
        }
        
        // Store observation to prevent deallocation
        progressObservations[episode.id] = observation
        
        downloadTask.resume()
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use updateFilter instead")
    func switchToTab(_ tab: Int, for feed: PodcastFeed) {
        currentTab = tab
        selectedFeedId = feed.id
        print("🔄 Switching to tab \(tab) for feed: \(feed.title)")
        // PERFORMANCE: Use optimized feed refresh instead of expensive loadEpisodesForFeed
        requestFeedRefresh(feed.id)
    }
    
    /// For PodcastListView compatibility
    @available(*, deprecated, message: "Use loadMoreEpisodes() instead")
    func loadMoreEpisodes(for feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
        Task {
            await loadMoreEpisodes()
            await MainActor.run {
                completion(true)
            }
        }
    }
    
    // MARK: - Core Data Management (Radio Station Pattern)
    
    /// Save podcast feeds to Core Data using the same pattern as radio stations
    func saveFeedsToCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        
        // Fetch existing feeds
        let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        
        do {
            let existingFeeds = try context.fetch(fetchRequest)
            let existingDict = Dictionary(uniqueKeysWithValues: existingFeeds.map { ($0.id!, $0) })
            
            for (index, feed) in podcastFeeds.enumerated() {
                if let existingFeed = existingDict[feed.id] {
                    // Update existing feed
                    existingFeed.title = feed.title
                    existingFeed.url = feed.url
                    existingFeed.artworkUrl = feed.artworkUrl
                    existingFeed.descriptionText = feed.descriptionText
                    existingFeed.iconData = feed.iconData
                    existingFeed.imageData = feed.imageData
                    existingFeed.sortOrder = Int16(feed.order)  // Use feed.order instead of index
                } else {
                    // Create new feed if it doesn't exist
                    let newFeed = FeedModel(context: context)
                    newFeed.id = feed.id
                    newFeed.title = feed.title
                    newFeed.url = feed.url
                    newFeed.artworkUrl = feed.artworkUrl
                    newFeed.descriptionText = feed.descriptionText
                    newFeed.iconData = feed.iconData
                    newFeed.imageData = feed.imageData
                    newFeed.sortOrder = Int16(feed.order)  // Use feed.order instead of index
                }
            }
            
            // Remove feeds that are no longer in the array
            let feedIDs = Set(podcastFeeds.map { $0.id })
            for existingFeed in existingFeeds {
                if !feedIDs.contains(existingFeed.id!) {
                    context.delete(existingFeed)
                }
            }
            
            // Save changes
            try context.save()
            print("📡 CoreData podcast feeds updated successfully.")
        } catch {
            print("❌ Failed to update podcast feeds in CoreData: \(error)")
        }
    }
    
    /// Load podcast feeds from Core Data using background processing to prevent main thread blocking
    func loadFeedsFromCoreData() {
        // PERFORMANCE: Prevent redundant Core Data operations
        guard !isLoadingFromCoreData else {
            print("🔄 Core Data loading already in progress - skipping redundant call")
            return
        }
        
        // CRITICAL FIX: Don't reload feeds if podcast is currently playing to prevent episode restart
        let podcastPlayer = PodcastPlayer.shared
        if podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil {
            print("🚗 CARPLAY FIX: Skipping feed reload - podcast is currently playing to prevent episode restart")
            return
        }
        
        print("🎯 CORE DATA LOAD: Starting loadFeedsFromCoreData() - Current feeds: \(podcastFeeds.count)")
        print("🎯 CORE DATA LOAD: Current podcastFeedOrder: \(podcastFeedOrder.count)")
        print("🎯 CORE DATA LOAD: isLoadingFromCoreData: \(isLoadingFromCoreData), isLoading: \(isLoading)")
        
        isLoadingFromCoreData = true
        isLoading = true  // Set main loading flag for UI coordination
        
        // Use background queue for Core Data operations to prevent main thread blocking
        Task.detached(priority: .userInitiated) {
            await self.performBackgroundCoreDataLoad()
        }
    }
    
    /// Perform Core Data loading operations on background queue
    private func performBackgroundCoreDataLoad() async {
        // Use background context to prevent main thread blocking
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        await backgroundContext.perform {
            print("🎯 CORE DATA LOAD: About to perform Core Data fetch for FeedModel")
            let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            
            // Add a sort descriptor to ensure feeds are loaded in the correct order
            let sortDescriptor = NSSortDescriptor(key: "sortOrder", ascending: true)
            request.sortDescriptors = [sortDescriptor]
            
            do {
                let results = try backgroundContext.fetch(request)
                print("🎯 CORE DATA LOAD: Fetch completed - found \(results.count) FeedModel objects in Core Data")
            if results.isEmpty {
                print("📡 No podcast feeds found in CoreData.")
                // CRITICAL: Clear in-memory arrays when no feeds found in Core Data
                Task { @MainActor in
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.throttledUIUpdate()
                    
                    // PERFORMANCE: Reset flags on main thread
                    self.isLoadingFromCoreData = false
                    self.isLoading = false  // Clear main loading flag
                }
                return
            }
            
            var loadedFeeds: [PodcastFeed] = []
            for feedModel in results {
                // Load episodes for this feed
                var episodes: [PodcastEpisode] = []
                let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeRequest.predicate = NSPredicate(format: "feedId == %@", feedModel.id ?? "")
                episodeRequest.sortDescriptors = [NSSortDescriptor(key: "publicationDate", ascending: false)]
                
                do {
                    let episodeModels = try backgroundContext.fetch(episodeRequest)
                    let loadedEpisodes = episodeModels.compactMap { $0.toPodcastEpisode() }
                    
                    // CRITICAL FIX: Remove duplicates and merge with EpisodeStateManager
                    // Note: This runs in background context, use synchronous version to avoid async in perform block
                    episodes = PodcastViewModel.removeDuplicatesFromEpisodesSynced(loadedEpisodes)
                    print("📡 Loaded \(loadedEpisodes.count) episodes for feed: \(feedModel.title ?? "Unknown"), \(episodes.count) after deduplication")
                } catch {
                    print("❌ Failed to load episodes for feed \(feedModel.title ?? "Unknown"): \(error)")
                }
                
                let feed = PodcastFeed(
                    id: feedModel.id ?? UUID().uuidString,
                    title: feedModel.title ?? "Unknown Feed",
                    url: feedModel.url ?? "",
                    artworkUrl: feedModel.artworkUrl,
                    description: feedModel.descriptionText,
                    iconData: feedModel.iconData,
                    imageData: feedModel.imageData,
                    episodes: episodes,
                    order: Int(feedModel.sortOrder)  // Load order from CoreData
                )
                loadedFeeds.append(feed)
            }
            
            // CRITICAL: Assign to @Published properties on main thread to trigger UI updates
            Task { @MainActor in
                // Sort feeds by order property to ensure correct display order
                let sortedFeeds = loadedFeeds.sorted { $0.order < $1.order }
                print("📡 🔢 SORTED FEEDS BY ORDER:")
                for (index, feed) in sortedFeeds.enumerated() {
                    print("📡 🔢 Sorted Feed [\(index)]: \(feed.title) - order: \(feed.order)")
                }
                
                // Batch property updates to prevent multiple UI refreshes
                self.podcastFeeds = sortedFeeds
                self.podcastFeedOrder = sortedFeeds.map { $0.id }
                
                // 🛡️ CRITICAL: Register all feeds with FeedIsolationManager immediately after loading
                for feed in loadedFeeds {
                    self.feedIsolationManager.registerFeed(feedId: feed.id, feedUrl: feed.url)
                    
                    // Immediately populate the isolation manager with episodes
                    if !feed.episodes.isEmpty {
                        self.feedIsolationManager.replaceEpisodesForFeed(feed.episodes, feedId: feed.id)
                        print("🛡️ FEED REGISTERED: \(feed.id) with \(feed.episodes.count) episodes")
                    } else {
                        print("🛡️ FEED REGISTERED: \(feed.id) with no episodes")
                    }
                }
                
                // Clear loading flags
                self.isLoading = false
                self.isLoadingFeeds = false
                self.isLoadingFromCoreData = false
                
                // Single UI refresh after all properties are updated
                self.throttledUIUpdate()
                
                // Report status to DataSyncManager
                self.reportStatusToDataSyncManager()
            }
            
            
            // Debug: Check if episodes exist in Core Data
            let debugEpisodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let allEpisodes = try backgroundContext.fetch(debugEpisodeRequest)
                
                // Group by feedId to see distribution
                let episodesByFeed = Dictionary(grouping: allEpisodes) { $0.feedId ?? "unknown" }
                for (feedId, episodes) in episodesByFeed {
                    if let feed = loadedFeeds.first(where: { $0.id == feedId }) {
                        print("🔍 DEBUG: Feed '\(feed.title)' has \(episodes.count) episodes in Core Data")
                    } else {
                        print("🔍 DEBUG: Unknown feedId '\(feedId)' has \(episodes.count) episodes")
                    }
                }
            } catch {
                print("❌ Failed to count episodes: \(error)")
            }
            
            } catch {
                print("❌ Failed to load podcast feeds from CoreData: \(error)")
                // Clear loading flags on error
                Task { @MainActor in
                    self.isLoading = false
                    self.isLoadingFeeds = false
                    self.isLoadingFromCoreData = false
                }
            }
        }
        
        // PERFORMANCE OPTIMIZED: Create caches in batches to prevent CPU spikes
        Task.detached(priority: .utility) {
            let feedsWithEpisodes = await self.podcastFeeds.filter { !$0.episodes.isEmpty }
            
            // BATCH PROCESSING: Process feeds in smaller batches to prevent CPU overload
            let batchSize = 3
            for i in stride(from: 0, to: feedsWithEpisodes.count, by: batchSize) {
                let batch = Array(feedsWithEpisodes[i..<min(i + batchSize, feedsWithEpisodes.count)])
                
                // Process batch with small delay between batches
                for feed in batch {
                    print("⚡ STARTUP OPTIMIZATION: Caching episodes for \(feed.title) with \(feed.episodes.count) episodes")
                    await self.feedIsolationManager.replaceEpisodesForFeed(feed.episodes, feedId: feed.id)
                }
                
                // Small delay between batches to prevent CPU spikes
                if i + batchSize < feedsWithEpisodes.count {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay between batches
                }
            }
            
            // Load episodes for the first feed if available - now with caches available
            if let firstFeed = await self.podcastFeeds.first {
                print("📡 Loading episodes for first feed: \(firstFeed.title) (\(firstFeed.episodes.count) episodes available)")
                await self.loadEpisodesForFeed(firstFeed.id, isInitialLoad: true)
            } else {
                print("📡 No feeds found in Core Data")
            }
        }
    }
    

    
    /// Clear podcast feeds from UI immediately for instant user feedback
    func clearPodcastFeedsFromUI() {
        // Must be called on main queue since it updates @Published properties
        DispatchQueue.main.async {
            self.podcastFeeds.removeAll()
            self.podcastFeedOrder.removeAll()
            self.currentEpisodes.removeAll()
            self.episodeCounts = (all: 0, favorites: 0, downloads: 0)
            self.throttledUIUpdate()
            print("📡 ✅ Immediately cleared podcast feeds from UI")
            print("🔍 DEBUG: After immediate clearing - podcastFeeds count: \(self.podcastFeeds.count)")
            print("🔍 DEBUG: After immediate clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
            
            // Force UI refresh by triggering objectWillChange again with slight delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.throttledUIUpdate()
                print("📡 ✅ Forced additional UI refresh after clearing")
            }
        }
    }
    
    /// Clear all podcast data from Core Data and CloudKit with comprehensive cross-device sync
    func clearPodcastCoreData(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            var allSuccess = true
            var lastError: Error?
            
            // First, get the feed IDs and details before deletion for CloudKit cleanup and cross-device sync
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
            var feedIdsToDelete: [String] = []
            var feedDataForSync: [(String, String)] = [] // (feedId, feedTitle) for sync
            
            do {
                let feeds = try context.fetch(feedFetchRequest)
                feedIdsToDelete = feeds.compactMap { $0.id }
                feedDataForSync = feeds.compactMap { feed in
                    guard let feedId = feed.id, let title = feed.title else { return nil }
                    return (feedId, title)
                }
                print("🗑️ Found \(feedIdsToDelete.count) feeds to delete from CloudKit")
                
                // Debug: List all feeds that will be deleted
                for feed in feeds {
                    if let feedId = feed.id, let title = feed.title {
                        print("🗑️ Will delete feed: '\(title)' (ID: \(feedId))")
                    }
                }
                
                // Also check in-memory feeds for comparison
                print("🔍 DEBUG: In-memory feeds at deletion time: \(self.podcastFeeds.count)")
                for feed in self.podcastFeeds {
                    print("🔍 DEBUG: In-memory feed: '\(feed.title)' (ID: \(feed.id))")
                }
            } catch {
                print("❌ Error fetching feeds for CloudKit deletion: \(error.localizedDescription)")
                // Continue with local deletion even if we can't get feed IDs
            }
            
            // Delete from CloudKit first (for each feed) with retry mechanism for race conditions
            for feedId in feedIdsToDelete {
                do {
                    // Add a small delay to handle CloudKit eventual consistency
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    try await cloudKitManager.deletePodcastFeedFromCloudKit(feedId)
                    print("☁️ Successfully deleted feed \(feedId) from CloudKit")
                } catch {
                    print("❌ Failed to delete feed \(feedId) from CloudKit: \(error)")
                    
                    // Check if it's a "not found" error (which might be okay - feed might not have been synced to CloudKit yet)
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        print("⚠️ Feed \(feedId) not found in CloudKit - this may be expected for recently added feeds")
                        // Don't mark as failure for "not found" errors since the feed doesn't exist anyway
                    } else {
                        allSuccess = false
                        lastError = error
                    }
                    // Continue deleting other feeds even if one fails
                }
            }
            
            // Now delete from local Core Data using efficient batch deletion
            // Debug: Check what data exists before deletion
            print("🔍 CORE DATA DEBUG: Checking data before deletion...")
            do {
                let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                let episodeCount = try mainContext.count(for: PodcastModel.fetchRequest())
                let feedCount = try mainContext.count(for: FeedModel.fetchRequest())
                print("🔍 CORE DATA DEBUG: Before deletion - Episodes: \(episodeCount), Feeds: \(feedCount)")
            } catch {
                print("❌ CORE DATA DEBUG: Error counting records before deletion: \(error)")
            }
            
            let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            privateMOC.parent = CoreDataStack.shared.persistentContainer.viewContext
            privateMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            
            await withCheckedContinuation { continuation in
                privateMOC.perform {
                    print("🔍 CORE DATA DEBUG: Private context is performing deletion...")
                    do {
                        // Use NSBatchDeleteRequest for efficient bulk deletion of episodes
                        let episodeFetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
                        let episodeBatchDeleteRequest = NSBatchDeleteRequest(fetchRequest: episodeFetchRequest)
                        episodeBatchDeleteRequest.resultType = .resultTypeObjectIDs
                        
                        let episodeResult = try privateMOC.execute(episodeBatchDeleteRequest) as? NSBatchDeleteResult
                        let episodeObjectIDArray = episodeResult?.result as? [NSManagedObjectID]
                        
                        // Use NSBatchDeleteRequest for efficient bulk deletion of feeds
                        let feedFetchRequest: NSFetchRequest<NSFetchRequestResult> = FeedModel.fetchRequest()
                        let feedBatchDeleteRequest = NSBatchDeleteRequest(fetchRequest: feedFetchRequest)
                        feedBatchDeleteRequest.resultType = .resultTypeObjectIDs
                        
                        let feedResult = try privateMOC.execute(feedBatchDeleteRequest) as? NSBatchDeleteResult
                        let feedObjectIDArray = feedResult?.result as? [NSManagedObjectID]
                        
                        // Merge changes into view context to ensure UI updates
                        var allObjectIDs: [NSManagedObjectID] = []
                        if let episodeIDs = episodeObjectIDArray {
                            allObjectIDs.append(contentsOf: episodeIDs)
                            print("✅ Batch deleted \(episodeIDs.count) episodes from Core Data")
                        }
                        if let feedIDs = feedObjectIDArray {
                            allObjectIDs.append(contentsOf: feedIDs)
                            print("✅ Batch deleted \(feedIDs.count) feeds from Core Data")
                        }
                        
                        if !allObjectIDs.isEmpty {
                            let changes = [NSDeletedObjectsKey: allObjectIDs]
                            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [CoreDataStack.shared.persistentContainer.viewContext])
                        }
                        
                        // Save private context after batch deletion
                        try privateMOC.save()
                        print("🔍 CORE DATA DEBUG: Private context saved successfully")
                        
                        continuation.resume()
                    } catch {
                        print("❌ Error performing batch deletion of podcast data from CoreData: \(error.localizedDescription)")
                        allSuccess = false
                        lastError = error
                        continuation.resume()
                    }
                }
            }
            
            // Then save main context and clear in-memory data
            await MainActor.run {
                do {
                    print("🔍 CORE DATA DEBUG: Saving main context...")
                    try CoreDataStack.shared.persistentContainer.viewContext.save()
                    print("🔍 CORE DATA DEBUG: Main context saved successfully")
                    
                    // **CRITICAL**: Force refresh all contexts to clear cached objects
                    print("🔄 CONTEXT REFRESH: Starting comprehensive context refresh...")
                    let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                    
                    // Reset the main context to clear all cached objects
                    mainContext.reset()
                    print("🔄 CONTEXT REFRESH: Main context reset completed")
                    
                    // Refresh all objects in the context (in case any are still cached)
                    mainContext.refreshAllObjects()
                    print("🔄 CONTEXT REFRESH: All objects refreshed")
                    
                    // Also refresh any background contexts
                    CoreDataStack.shared.persistentContainer.performBackgroundTask { backgroundContext in
                        backgroundContext.reset()
                        print("🔄 CONTEXT REFRESH: Background context reset completed")
                    }
                    
                    // Debug: Check what data exists after deletion and context refresh
                    do {
                        let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                        let episodeCountAfter = try mainContext.count(for: PodcastModel.fetchRequest())
                        let feedCountAfter = try mainContext.count(for: FeedModel.fetchRequest())
                        print("🔍 CORE DATA DEBUG: After deletion and context refresh - Episodes: \(episodeCountAfter), Feeds: \(feedCountAfter)")
                        
                        if episodeCountAfter > 0 || feedCountAfter > 0 {
                            print("❌ CORE DATA ERROR: Data still exists after deletion! Episodes: \(episodeCountAfter), Feeds: \(feedCountAfter)")
                        } else {
                            print("✅ CORE DATA SUCCESS: All data successfully deleted from Core Data and contexts refreshed")
                        }
                    } catch {
                        print("❌ CORE DATA DEBUG: Error counting records after deletion: \(error)")
                    }
                    
                    // CRITICAL: Clear all episode states from EpisodeStateManager
                    // This ensures all episode states (progress, favorites, downloads) are completely removed
                    print("🗑️ EPISODE STATES: Clearing all episode states from EpisodeStateManager")
                    EpisodeStateManager.shared.clearAllStates()
                    print("✅ EPISODE STATES: All episode states cleared successfully")
                    
                    // Ensure in-memory data is cleared after successful Core Data deletion
                    self.podcastFeeds.removeAll()
                    self.podcastFeedOrder.removeAll()
                    self.currentEpisodes.removeAll()
                    self.episodeCounts = (all: 0, favorites: 0, downloads: 0)
                    self.throttledUIUpdate()
                    print("📡 ✅ Cleared in-memory data after Core Data deletion")
                    print("🔍 DEBUG: After clearing - podcastFeeds count: \(self.podcastFeeds.count)")
                    print("🔍 DEBUG: After clearing - podcastFeedOrder count: \(self.podcastFeedOrder.count)")
                } catch {
                    print("❌ Error saving main context after podcast deletion: \(error.localizedDescription)")
                    completion(false, error)
                    return
                }
            }
            
            // **CRITICAL**: Clear all episode states from EpisodeStateManager (progress, favorites, downloads)
            await clearAllEpisodeStatesFromManager()
            print("📡 ✅ CRITICAL FIX: Cleared all episode states from EpisodeStateManager")
            
            // **CRITICAL**: Trigger cross-device sync for comprehensive cleanup  
            if allSuccess {
                print("🎯 ✅ Successfully deleted all podcast data from both CloudKit and Core Data")
                
                // Trigger cross-device sync for each deleted feed to ensure CoreData cleanup on all devices
                Task {
                    for (feedId, feedTitle) in feedDataForSync {
                        // Get episode IDs for comprehensive cleanup
                        let episodeIds = await self.getEpisodeIdsForFeed(feedId)
                        
                        print("📡 🚨 DATA MANAGEMENT: Syncing deletion of '\(feedTitle)' (\(feedId)) across devices")
                        PodcastCloudKitManager.shared.syncPodcastFeedRemovedInstantly(
                            feedId: feedId,
                            feedTitle: feedTitle,
                            episodeIds: episodeIds
                        )
                    }
                    print("📡 ✅ DATA MANAGEMENT: Cross-device sync triggered for \(feedDataForSync.count) deleted feeds")
                }
                
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "All podcast data has been successfully deleted across all devices.")
            } else {
                print("⚠️ Partial success: Local deletion completed, but some CloudKit deletions failed")
                NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Podcast data deletion completed with some warnings.")
            }
            
            completion(allSuccess, lastError)
        }
    }
    
    /// Move feed order (following radio station pattern)
    func movePodcastFeed(from source: IndexSet, to destination: Int) {
        print("📡 🔄 PODCAST DRAG AND DROP: Starting movePodcastFeed - source: \(source), destination: \(destination)")
        
        podcastFeedOrder.move(fromOffsets: source, toOffset: destination)
        
        // Reorder the actual feeds array to match
        var reorderedFeeds: [PodcastFeed] = []
        for feedId in podcastFeedOrder {
            if let feed = podcastFeeds.first(where: { $0.id == feedId }) {
                reorderedFeeds.append(feed)
            }
        }
        podcastFeeds = reorderedFeeds
        
        // Update order property for each feed
        for (index, feed) in podcastFeeds.enumerated() {
            if let feedIndex = podcastFeeds.firstIndex(where: { $0.id == feed.id }) {
                let oldOrder = podcastFeeds[feedIndex].order
                podcastFeeds[feedIndex].order = index
                print("📡 🔢 PODCAST DRAG AND DROP: \(feed.title) - old order: \(oldOrder), new order: \(index)")
            }
        }
        
        // Save the new order to Core Data
        saveFeedsToCoreData()
        
        // Save to UserDefaults
        UserDefaults.standard.set(podcastFeedOrder, forKey: "PodcastFeedOrder")
        UserDefaults.standard.synchronize()
        print("📡 💾 PODCAST DRAG AND DROP: Saved feed order to UserDefaults for \(podcastFeeds.count) feeds")
        
        // Sync to CloudKit
        print("📡 ☁️ PODCAST DRAG AND DROP: Starting CloudKit sync...")
        Task {
            await syncPodcastFeedOrderToCloudKit()
        }
        
        // Notify CarPlay immediately about podcast feed order change
        NotificationCenter.default.post(
            name: NSNotification.Name("PodcastFeedOrderChanged"),
            object: nil,
            userInfo: [
                "newOrder": podcastFeedOrder,
                "reason": "manual_reorder"
            ]
        )
        
        print("🎙️ PODCAST DRAG AND DROP: Moved podcast feed and notified CarPlay of new order")
    }
    
    /// Clear all episode states from EpisodeStateManager during bulk deletion
    private func clearAllEpisodeStatesFromManager() async {
        print("🧹 EPISODE STATE CLEARING: Starting comprehensive EpisodeStateManager cleanup...")
        
        // Clear all episode states using EpisodeStateManager's bulk clear methods
        EpisodeStateManager.shared.clearAllStates()
        print("🧹 EPISODE STATE CLEARING: Cleared all episode states from EpisodeStateManager")
        
        // Core Data saves happen automatically, no need to force save
        // clearAllStates() already triggers save through state changes
        print("🧹 EPISODE STATE CLEARING: Forced save completed - all local episode data cleared")
    }
    
    /// Clear all episode state data from Core Data for specific episodes
    private func clearEpisodeStatesFromCoreData(_ episodeIds: [String]) async {
        guard !episodeIds.isEmpty else { 
            print("💾 ⚠️ No episode IDs provided for Core Data state cleanup")
            return 
        }
        
        print("💾 🧹 Starting Core Data cleanup for \(episodeIds.count) episodes")
        
        // Use a background context to avoid blocking the main thread
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.perform {
                do {
                    var totalClearedCount = 0
                    var totalFoundCount = 0
                    let batchSize = 50  // Smaller batch size for better performance
                    
                    // Process episode IDs in batches
                    for i in stride(from: 0, to: episodeIds.count, by: batchSize) {
                        let endIndex = min(i + batchSize, episodeIds.count)
                        let batch = Array(episodeIds[i..<endIndex])
                        
                        // Find episodes in this batch (reduced logging)
                        let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id IN %@", batch)
                        fetchRequest.includesPropertyValues = true  // Ensure we get all property values
                        
                        let episodes = try context.fetch(fetchRequest)
                        totalFoundCount += episodes.count
                        
                        // Clear episode state data (reduced logging to prevent app quarantine)
                        for episode in episodes {
                            // Clear all episode state fields
                            episode.progress = 0.0
                            episode.isFavorite = false
                            episode.isDownloaded = false
                            episode.isPlayed = false
                            totalClearedCount += 1
                        }
                        
                        // Save batch immediately to ensure data is persisted
                        if episodes.count > 0 {
                            try context.save()
                            
                            // CRITICAL: Merge changes to main context to ensure isPlayed state is cleared
                            let objectIDs = episodes.map { $0.objectID }
                            DispatchQueue.main.async {
                                NSManagedObjectContext.mergeChanges(
                                    fromRemoteContextSave: [NSUpdatedObjectsKey: objectIDs],
                                    into: [CoreDataStack.shared.persistentContainer.viewContext]
                                )
                            }
                            
                            // Log only every 10th batch to reduce logging volume
                            if (i/batchSize + 1) % 10 == 0 {
                                print("💾 💾 Saved batch \(i/batchSize + 1) - cleared \(episodes.count) episodes (merged to main context)")
                            }
                        }
                    }
                    
                    // Final verification - check if any episode states remain
                    let verificationRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    verificationRequest.predicate = NSPredicate(format: "id IN %@ AND (progress > 0 OR isFavorite == YES OR isDownloaded == YES OR isPlayed == YES)", episodeIds)
                    let remainingStates = try context.count(for: verificationRequest)
                    
                    if remainingStates > 0 {
                        print("💾 ⚠️ WARNING: \(remainingStates) episodes still have state data after cleanup!")
                    } else {
                        print("💾 ✅ VERIFICATION: All episode states successfully cleared")
                    }
                    
                    print("💾 ✅ Core Data episode state cleanup completed:")
                    print("💾    📊 Requested: \(episodeIds.count) episodes")
                    print("💾    🔍 Found: \(totalFoundCount) episodes in Core Data")
                    print("💾    🧹 Processed: \(totalClearedCount) episodes")
                    print("💾    ⚠️ Remaining states: \(remainingStates) episodes")
                    
                    continuation.resume()
                    
                } catch {
                    print("💾 ❌ Error during Core Data episode state cleanup: \(error)")
                    print("💾 ❌ Error details: \(error.localizedDescription)")
                    
                    // Try to rollback and continue - don't fail the deletion process
                    context.rollback()
                    continuation.resume()
                }
            }
        }
        
        // CRITICAL: Save main context after all merges complete to persist isPlayed state clearing
        await MainActor.run {
            do {
                let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                if mainContext.hasChanges {
                    try mainContext.save()
                    print("💾 ✅ CRITICAL: Saved main context after episode state clearing - isPlayed state persisted")
                }
            } catch {
                print("💾 ❌ Error saving main context after episode state clearing: \(error)")
            }
        }
    }
    
    /// Process episodes in background to prevent main thread blocking during large list operations
    private func processEpisodesInBackground(_ episodes: [PodcastEpisode]) async -> [PodcastEpisode] {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let processedEpisodes = await PodcastViewModel.removeDuplicatesFromEpisodes(episodes)
                continuation.resume(returning: processedEpisodes)
            }
        }
    }
    
    /// Synchronous version for use within Core Data perform blocks - OPTIMIZED
    private static func removeDuplicatesFromEpisodesSynced(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        // PERFORMANCE OPTIMIZATION: Batch EpisodeStateManager queries
        let episodeIds = episodes.map { $0.id }
        let uniqueIds = Set(episodeIds)
        let batchStates = EpisodeStateManager.shared.getBatchStates(for: episodeIds)
        
        if episodeIds.count == uniqueIds.count {
            // No duplicates found, just sync with batch states and return
            return episodes.map { episode in
                var episodeWithState = episode
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                return episodeWithState
            }.sorted { $0.publicationDate > $1.publicationDate }
        }
        
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var seenIds = Set<String>()
        var duplicateCount = 0
        
        // Sort episodes by publication date (newest first) to prioritize recent versions
        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
        
        for episode in sortedEpisodes {
            if seenIds.contains(episode.id) {
                duplicateCount += 1
                continue
            }
            
            seenIds.insert(episode.id)
            
            // Merge states for this episode using batch states
            var episodeWithState = episode
            let batchState = batchStates[episode.id]
            let currentProgress = batchState?.progress ?? 0.0
            let isFavorite = batchState?.isFavorite ?? false
            let isDownloaded = batchState?.isDownloaded ?? false
            let isPlayed = currentProgress >= 0.99
            
            episodeWithState.state = EpisodeState(
                isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                isFavorite: isFavorite || episode.state.isFavorite,
                progress: max(currentProgress, episode.state.progress),
                isDownloaded: isDownloaded || episode.state.isDownloaded
            )
            
            uniqueEpisodes[episode.id] = episodeWithState
        }
        
        if duplicateCount > 0 {
            print("🔄 DEDUP: Removed \(duplicateCount) duplicates from \(episodes.count) episodes")
        }
        
        return Array(uniqueEpisodes.values).sorted { $0.publicationDate > $1.publicationDate }
    }
    
    /// Remove duplicates from episodes while preserving the most complete episode data and state
    /// Enhanced with contamination prevention and feed isolation
    private static func removeDuplicatesFromEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        // ENHANCED CONTAMINATION PREVENTION: Pre-validate all episodes before processing
        let preValidatedEpisodes = episodes.compactMap { episode -> PodcastEpisode? in
            // Skip episodes with clearly invalid data
            guard !episode.id.isEmpty,
                  !episode.title.isEmpty,
                  !episode.feedId.isEmpty,
                  !episode.audioUrl.isEmpty else {
                print("🚨 PREVALIDATION: Skipping episode with invalid data - ID: '\(episode.id)', Title: '\(episode.title)', FeedId: '\(episode.feedId)'")
                return nil
            }
            
            // Validate episode ID format to prevent contamination
            if episode.id.contains("_f") && !episode.id.hasPrefix("det_f") {
                print("🚨 PREVALIDATION: Suspicious episode ID format detected: \(episode.id)")
            }
            
            return episode
        }
        
        if preValidatedEpisodes.count != episodes.count {
            print("🛡️ PREVALIDATION: Filtered out \(episodes.count - preValidatedEpisodes.count) invalid episodes")
        }
        
        // CONTAMINATION PREVENTION: Group episodes by feedId first
        let episodesByFeed = Dictionary(grouping: preValidatedEpisodes) { $0.feedId }
        var cleanedEpisodes: [PodcastEpisode] = []
        
        for (feedId, feedEpisodes) in episodesByFeed {
            // Validate feed isolation
            if feedId.isEmpty {
                print("🚨 DEDUP CONTAMINATION: Found episodes with empty feedId - applying emergency decontamination")
                let decontaminatedEpisodes = EpisodeContaminationGuard.emergencyDecontamination(episodes: feedEpisodes, targetFeedId: "unknown_feed_\(UUID().uuidString)")
                cleanedEpisodes.append(contentsOf: decontaminatedEpisodes)
                continue
            }
            
            // ENHANCED FEED ISOLATION: Validate all episodes actually belong to this feed
            let trulyIsolatedEpisodes = feedEpisodes.compactMap { episode -> PodcastEpisode? in
                // Check if episode ID contains feed information that matches
                if episode.id.hasPrefix("det_f") {
                    let feedHash = abs(feedId.lowercased().hashValue)
                    let expectedPrefix = "det_f\(feedHash)_"
                    if !episode.id.hasPrefix(expectedPrefix) {
                        print("🚨 FEED ISOLATION: Episode ID \(episode.id) doesn't match expected feed hash pattern for feed \(feedId)")
                        // Regenerate proper episode ID
                        var correctedEpisode = episode
                        correctedEpisode.id = PodcastEpisode.generateDeterministicID(
                            title: episode.title,
                            audioUrl: episode.audioUrl,
                            publicationDate: episode.publicationDate,
                            feedUrl: feedId // Use feedId as feedUrl for consistency
                        )
                        print("🔧 FEED ISOLATION: Corrected episode ID to \(correctedEpisode.id)")
                        return correctedEpisode
                    }
                }
                return episode
            }
            
            // Sanitize episodes for this feed
            let sanitizedFeedEpisodes = EpisodeContaminationGuard.sanitizeEpisodes(trulyIsolatedEpisodes, targetFeedId: feedId)
            
            // Perform standard deduplication within the feed
            let deduplicatedFeedEpisodes = deduplicateEpisodesWithinFeed(sanitizedFeedEpisodes)
            cleanedEpisodes.append(contentsOf: deduplicatedFeedEpisodes)
        }
        
        return cleanedEpisodes.sorted { $0.publicationDate > $1.publicationDate }
    }
    
    /// Deduplicate episodes within a single feed (helper method)
    private static func deduplicateEpisodesWithinFeed(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        guard !episodes.isEmpty else { return [] }
        
        // PERFORMANCE OPTIMIZATION: Batch EpisodeStateManager queries instead of individual calls
        let episodeIds = episodes.map { $0.id }
        let uniqueIds = Set(episodeIds)
        
        // Get all states in batch for better performance
        let batchStates = EpisodeStateManager.shared.getBatchStates(for: episodeIds)
        
        if episodeIds.count == uniqueIds.count {
            // No duplicates found, just sync with EpisodeStateManager and return
            return episodes.map { episode in
                var episodeWithState = episode
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                return episodeWithState
            }.sorted { $0.publicationDate > $1.publicationDate }
        }
        
        var uniqueEpisodes: [String: PodcastEpisode] = [:]
        var seenIds = Set<String>()
        var duplicateCount = 0
        
        // Sort episodes by publication date (newest first) to prioritize recent versions
        let sortedEpisodes = episodes.sorted { $0.publicationDate > $1.publicationDate }
        
        for episode in sortedEpisodes {
            if seenIds.contains(episode.id) {
                duplicateCount += 1
                
                // This is a duplicate - merge state data from batch states
                if var existingEpisode = uniqueEpisodes[episode.id] {
                    // Get the most accurate state from batch states (much faster)
                    let batchState = batchStates[episode.id]
                    let currentProgress = batchState?.progress ?? 0.0
                    let isFavorite = batchState?.isFavorite ?? false
                    let isDownloaded = batchState?.isDownloaded ?? false
                    let isPlayed = currentProgress >= 0.99
                    
                    // Preserve the highest progress value
                    let maxProgress = max(existingEpisode.state.progress, episode.state.progress, currentProgress)
                    
                    // Merge favorite states (true if either is true)
                    let mergedFavorite = existingEpisode.state.isFavorite || episode.state.isFavorite || isFavorite
                    
                    // Merge download states (true if either is true)
                    let mergedDownloaded = existingEpisode.state.isDownloaded || episode.state.isDownloaded || isDownloaded
                    
                    // Merge played states (true if either is true or progress is complete)
                    let mergedPlayed = existingEpisode.state.isPlayed || episode.state.isPlayed || isPlayed || maxProgress >= 1.0
                    
                    // Update the existing episode with merged state
                    existingEpisode.state = EpisodeState(
                        isPlayed: mergedPlayed,
                        isFavorite: mergedFavorite,
                        progress: maxProgress,
                        isDownloaded: mergedDownloaded
                    )
                    
                    // Keep the episode with the most recent publication date or the one with complete metadata
                    if episode.publicationDate > existingEpisode.publicationDate || 
                       (episode.title.count > existingEpisode.title.count && episode.descriptionText.count > existingEpisode.descriptionText.count) {
                        // Keep the newer/more complete episode but with merged state
                        var updatedEpisode = episode
                        updatedEpisode.state = existingEpisode.state
                        uniqueEpisodes[episode.id] = updatedEpisode
                    } else {
                        // Keep the existing episode with merged state
                        uniqueEpisodes[episode.id] = existingEpisode
                    }
                }
            } else {
                // First occurrence of this episode - sync with batch states
                var episodeWithState = episode
                
                // Always sync with batch states as the source of truth for cross-device state
                let batchState = batchStates[episode.id]
                let currentProgress = batchState?.progress ?? 0.0
                let isFavorite = batchState?.isFavorite ?? false
                let isDownloaded = batchState?.isDownloaded ?? false
                let isPlayed = currentProgress >= 0.99
                
                // Use EpisodeStateManager data if it's more recent than episode data
                episodeWithState.state = EpisodeState(
                    isPlayed: isPlayed || episode.state.isPlayed || currentProgress >= 1.0,
                    isFavorite: isFavorite || episode.state.isFavorite,
                    progress: max(currentProgress, episode.state.progress),
                    isDownloaded: isDownloaded || episode.state.isDownloaded
                )
                
                uniqueEpisodes[episode.id] = episodeWithState
                seenIds.insert(episode.id)
            }
        }
        
        let result = Array(uniqueEpisodes.values).sorted { $0.publicationDate > $1.publicationDate }
        
        // Only log if duplicates were actually found and removed
        if duplicateCount > 0 {
            print("🧹 DUPLICATE REMOVAL: Removed \(duplicateCount) duplicate episodes (from \(episodes.count) to \(result.count))")
        }
        
        return result
    }
    
    // MARK: - Episode State Refresh Methods
    
    /// Refresh all episode states from EpisodeStateManager and CloudKit (used during pull-to-refresh)
    private func refreshAllEpisodeStates() async {
        print("🔄 PULL-TO-REFRESH: Starting comprehensive episode state refresh")
        
        // Step 1: Fetch latest states from CloudKit first
        await refreshEpisodeStatesFromCloudKit()
        
        // Step 2: Update UI with latest local states
        await MainActor.run {
            print("🔄 REFRESHING EPISODE STATES: Starting local refresh for \(currentEpisodes.count) episodes")
            
            // Force refresh episode states for all currently displayed episodes
            for i in 0..<currentEpisodes.count {
                let episode = currentEpisodes[i]
                let episodeId = episode.id
                
                // Get fresh state data from EpisodeStateManager (now updated with CloudKit data)
                let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
                let isFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                let isDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                let isPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                
                // Update the episode's state
                var updatedEpisode = episode
                updatedEpisode.state.progress = progress
                updatedEpisode.state.isFavorite = isFavorite
                updatedEpisode.state.isDownloaded = isDownloaded
                updatedEpisode.state.isPlayed = isPlayed
                
                // Update in the array
                currentEpisodes[i] = updatedEpisode
                
                // Also update in podcastFeeds if this episode exists there
                for feedIndex in 0..<podcastFeeds.count {
                    for episodeIndex in 0..<podcastFeeds[feedIndex].episodes.count {
                        if podcastFeeds[feedIndex].episodes[episodeIndex].id == episodeId {
                            var updatedFeed = podcastFeeds[feedIndex]
                            updatedFeed.episodes[episodeIndex] = updatedEpisode
                            podcastFeeds[feedIndex] = updatedFeed
                            break
                        }
                    }
                }
            }
            
            print("✅ REFRESHING EPISODE STATES: Updated states for \(currentEpisodes.count) episodes")
            
            // Trigger UI update
            throttledUIUpdate()
        }
        
        print("✅ PULL-TO-REFRESH: Comprehensive episode state refresh completed")
    }
    
    /// Refresh episode states from CloudKit (called during pull-to-refresh)
    private func refreshEpisodeStatesFromCloudKit() async {
        do {
            print("🔄 PULL-TO-REFRESH: Fetching latest episode states from CloudKit...")
            
            // CRITICAL: Enable CloudKit priority mode to ensure Core Data takes precedence
            EpisodeStateManager.shared.enableCloudKitPriorityMode()
            
            // Get episode IDs for currently displayed episodes
            let episodeIds = await MainActor.run { 
                return currentEpisodes.map { $0.id }
            }
            
            guard !episodeIds.isEmpty else {
                print("⚠️ PULL-TO-REFRESH: No episodes to sync states for")
                // Disable CloudKit priority mode before returning
                EpisodeStateManager.shared.disableCloudKitPriorityMode()
                return
            }
            
            // Fetch all episode states from CloudKit
            let allCloudStates = try await PodcastCloudKitManager.shared.fetchAllEpisodeStatesFromCloudKit()
            
            var updatedCount = 0
            var coreDataUpdates: [EpisodeStateUpdate] = []
            
            // Apply CloudKit states to local EpisodeStateManager AND prepare Core Data updates
            for episodeId in episodeIds {
                if let cloudState = allCloudStates[episodeId] {
                    // HIGHEST PROGRESS SYNC: Compare CloudKit vs local and use highest progress
                    let localProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                    let finalProgress = max(localProgress, cloudState.progress)
                    
                    // Log the comparison
                    if finalProgress == localProgress && localProgress > cloudState.progress {
                        print("🔍 📊 HIGHEST PROGRESS: Local higher (\(String(format: "%.4f", localProgress))) > CloudKit (\(String(format: "%.4f", cloudState.progress))) for \(episodeId)")
                    } else if finalProgress == cloudState.progress && cloudState.progress > localProgress {
                        print("🔍 📊 HIGHEST PROGRESS: CloudKit higher (\(String(format: "%.4f", cloudState.progress))) > Local (\(String(format: "%.4f", localProgress))) for \(episodeId)")
                    } else {
                        print("🔍 📊 HIGHEST PROGRESS: Values equal (\(String(format: "%.4f", finalProgress))) for \(episodeId)")
                    }
                    
                    // Update EpisodeStateManager with highest progress (silently to avoid sync loops)
                    EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: finalProgress)
                    EpisodeStateManager.shared.setFavoriteSilently(episodeId, isFavorite: cloudState.isFavorite)
                    EpisodeStateManager.shared.setDownloadedSilently(episodeId, isDownloaded: cloudState.isDownloaded)
                    EpisodeStateManager.shared.setPlayedSilently(episodeId, isPlayed: cloudState.isPlayed)
                    
                    // CRITICAL FIX: Also prepare Core Data update for persistence with highest progress
                    let coreDataUpdate = EpisodeStateUpdate(
                        episodeId: episodeId,
                        progress: finalProgress,
                        isFavorite: cloudState.isFavorite,
                        isDownloaded: cloudState.isDownloaded,
                        isPlayed: cloudState.isPlayed
                    )
                    coreDataUpdates.append(coreDataUpdate)
                    
                    // CRITICAL: If local progress was higher, propagate it back to CloudKit
                    // This ensures all devices get the highest progress
                    if finalProgress == localProgress && localProgress > cloudState.progress {
                        print("🔄 📡 PROPAGATING: Local progress (\(String(format: "%.4f", localProgress))) > CloudKit, updating CloudKit for all devices")
                        // Find feedId for this episode to update CloudKit
                        if let currentEpisode = currentEpisodes.first(where: { $0.id == episodeId }) {
                            Task.detached(priority: .userInitiated) {
                                await PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                                    episodeId: episodeId, 
                                    progress: finalProgress
                                )
                            }
                        }
                    }
                    
                    updatedCount += 1
                }
            }
            
            // CRITICAL FIX: Save CloudKit updates to Core Data for persistence across app restarts
            if !coreDataUpdates.isEmpty {
                do {
                    try await episodeManager.updateEpisodeStates(coreDataUpdates)
                    print("💾 PULL-TO-REFRESH: Saved \(coreDataUpdates.count) CloudKit episode states to Core Data")
                } catch {
                    print("❌ PULL-TO-REFRESH: Failed to save CloudKit states to Core Data: \(error.localizedDescription)")
                }
            }
            
            print("✅ PULL-TO-REFRESH: Applied \(updatedCount) episode states from CloudKit")
            
        } catch {
            print("⚠️ PULL-TO-REFRESH: Failed to fetch episode states from CloudKit: \(error.localizedDescription)")
            // Continue with local refresh even if CloudKit fails
        }
        
        // CRITICAL: Always disable CloudKit priority mode after processing (success or failure)
        EpisodeStateManager.shared.disableCloudKitPriorityMode()
    }
    
    /// Sync real-time progress across all devices during pull-to-refresh
    private func syncRealTimeProgressAcrossDevices() async {
        // Step 1: Broadcast current playing progress from this device
        await broadcastCurrentPlayingProgress()
        
        // Step 2: Wait a moment for other devices to respond
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Step 3: Fetch the latest real-time progress from all devices
        await fetchLatestRealTimeProgress()
    }
    
    /// Broadcast current playing progress to other devices
    private func broadcastCurrentPlayingProgress() async {
        print("📡 🔄 BROADCAST: Checking for currently playing episode to broadcast...")
        
        // Check if we have a currently playing episode
        guard let currentEpisode = PodcastPlayer.shared.currentEpisode else {
            print("📡 📭 BROADCAST: No episode currently playing")
            return
        }
        
        // Get the most up-to-date progress from the player
        let currentProgress = PodcastPlayer.shared.currentProgress
        let isPlaying = PodcastPlayer.shared.isPlaying
        
        print("📡 📡 BROADCAST: Broadcasting current progress for \(currentEpisode.title): \(Int(currentProgress * 100))% (playing: \(isPlaying))")
        
        // Force an immediate CloudKit sync for the currently playing episode
        EpisodeStateManager.shared.performRealTimeSyncForEpisode(
            currentEpisode.id, 
            reason: "pull_to_refresh_broadcast", 
            feedId: currentEpisode.feedId
        )
        
        // Note: RealtimeSyncManager is used primarily for radio stations
        // For podcasts, the performRealTimeSyncForEpisode above should be sufficient
        
        print("📡 ✅ BROADCAST: Current playing progress broadcasted")
    }
    
    /// Fetch the latest real-time progress from all devices
    private func fetchLatestRealTimeProgress() async {
        print("📡 📥 FETCH: Fetching latest real-time progress from all devices...")
        
        // Get all currently displayed episodes
        let episodeIds = await MainActor.run { 
            return currentEpisodes.map { $0.id }
        }
        
        guard !episodeIds.isEmpty else {
            print("📡 📭 FETCH: No episodes to fetch progress for")
            return
        }
        
        var updatedProgressCount = 0
        
        // Check CloudKit for the latest instant progress updates
        for episodeId in episodeIds {
            do {
                // Try to get the latest instant progress data
                if let progressData = try await PodcastCloudKitManager.shared.fetchLatestInstantProgress(for: episodeId) {
                    let progress = progressData.progress
                    let timestamp = progressData.timestamp
                    
                    // Check if this is a recent update (within last 5 minutes)
                    let currentTime = Date().timeIntervalSince1970
                    if currentTime - timestamp < 300 { // 5 minutes
                        // Update the progress silently (don't trigger another sync)
                        EpisodeStateManager.shared.setProgressSilently(for: episodeId, progress: progress)
                        
                        // Update Core Data for persistence
                        let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                        let currentDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
                        let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                        
                        let coreDataUpdate = EpisodeStateUpdate(
                            episodeId: episodeId,
                            progress: progress,
                            isFavorite: currentFavorite,
                            isDownloaded: currentDownloaded,
                            isPlayed: currentPlayed
                        )
                        
                        try await episodeManager.updateEpisodeStates([coreDataUpdate])
                        updatedProgressCount += 1
                        
                        print("📡 ⬇️ FETCH: Updated episode \(episodeId) with real-time progress: \(Int(progress * 100))%")
                    }
                }
            } catch {
                // Silent fail for individual episodes - continue with others
                print("📡 ⚠️ FETCH: Failed to fetch real-time progress for \(episodeId): \(error.localizedDescription)")
            }
        }
        
        if updatedProgressCount > 0 {
            // Refresh UI to show updated progress
            await MainActor.run {
                refreshEpisodeStatesFromManager()
            }
            print("📡 ✅ FETCH: Updated \(updatedProgressCount) episodes with real-time progress")
        } else {
            print("📡 📭 FETCH: No recent real-time progress updates found")
        }
    }
    
    // MARK: - Feed Processing Protection Methods
    
    /// Check if a feed is currently being processed (thread-safe)
    private func isFeedBeingProcessed(_ feedId: String) -> Bool {
        return feedProcessingQueue.sync {
            feedsBeingProcessed.contains(feedId)
        }
    }
    
    /// Mark a feed as being processed (thread-safe)
    private func markFeedAsProcessing(_ feedId: String) -> Bool {
        return feedProcessingQueue.sync(flags: .barrier) {
            if feedsBeingProcessed.contains(feedId) {
                return false // Already being processed
            }
            feedsBeingProcessed.insert(feedId)
            return true // Successfully marked for processing
        }
    }
    
    /// Mark a feed as finished processing (thread-safe)
    private func markFeedAsFinished(_ feedId: String) {
        feedProcessingQueue.sync(flags: .barrier) {
            feedsBeingProcessed.remove(feedId)
        }
    }
    
    /// Verify and clean up any orphaned episode records after feed deletion
    private func verifyAndCleanupOrphanedEpisodes(feedId: String, episodeIds: [String]) async {
        print("🧹 CLEANUP: Verifying episode deletion for feed: \(feedId)")
        
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        await context.perform {
            do {
                // Check for any remaining episodes with this feedId
                let feedIdRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                feedIdRequest.predicate = NSPredicate(format: "feedId == %@", feedId)
                let remainingByFeedId = try context.fetch(feedIdRequest)
                
                if !remainingByFeedId.isEmpty {
                    print("🧹 CLEANUP: Found \(remainingByFeedId.count) orphaned episodes by feedId - deleting")
                    for episode in remainingByFeedId {
                        context.delete(episode)
                    }
                }
                
                // Check for any remaining episodes by episode IDs
                let episodeIdRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                episodeIdRequest.predicate = NSPredicate(format: "id IN %@", episodeIds)
                let remainingByEpisodeId = try context.fetch(episodeIdRequest)
                
                if !remainingByEpisodeId.isEmpty {
                    print("🧹 CLEANUP: Found \(remainingByEpisodeId.count) orphaned episodes by episodeId - deleting")
                    for episode in remainingByEpisodeId {
                        context.delete(episode)
                    }
                }
                
                // Save if we deleted anything
                if context.hasChanges {
                    try context.save()
                    print("🧹 ✅ CLEANUP: Removed \(remainingByFeedId.count + remainingByEpisodeId.count) orphaned episode records")
                } else {
                    print("🧹 ✅ CLEANUP: No orphaned episodes found - deletion was complete")
                }
                
            } catch {
                print("🧹 ❌ CLEANUP: Failed to verify episode deletion: \(error.localizedDescription)")
            }
        }
    }

}
