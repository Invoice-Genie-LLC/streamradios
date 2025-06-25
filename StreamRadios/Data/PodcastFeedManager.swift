import Foundation
import CoreData
import os.log

/// High-performance podcast feed manager with efficient background processing
class PodcastFeedManager {
    private let log = OSLog(subsystem: "StreamRadios", category: "FeedManager")
    private let context = CoreDataStack.shared.context
    
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
    func addFeed(from url: URL) async throws -> PodcastFeed {
        os_log("🆕 Adding new feed from: %@", log: log, type: .info, url.absoluteString)
        
        // Parse RSS feed in background
        let feedData = try await URLSession.shared.data(from: url).0
        let parser = RSSFeedParser(data: feedData, feedUrl: url.absoluteString)
        let (feed, episodes) = try parser.parseComplete()
        
        // CRITICAL: Download artwork immediately and save to Core Data for fast app restart
        var feedWithArtwork = feed
        if let artworkUrlString = feed.artworkUrl, !artworkUrlString.isEmpty,
           let artworkUrl = URL(string: artworkUrlString) {
            os_log("🖼️ Downloading artwork for feed: %@", log: log, type: .info, feed.title)
            
            do {
                let (artworkData, _) = try await URLSession.shared.data(from: artworkUrl)
                feedWithArtwork.imageData = artworkData
                os_log("✅ Downloaded artwork (%d bytes) for feed: %@", log: log, type: .info, artworkData.count, feed.title)
            } catch {
                os_log("⚠️ Failed to download artwork for feed: %@ - %@", log: log, type: .error, feed.title, error.localizedDescription)
            }
        }
        
        // Save feed and episodes in background context (with artwork if downloaded)
        return try await saveFeedWithEpisodes(feed: feedWithArtwork, episodes: episodes)
    }
    
    /// Refresh feed and parse new episodes
    func refreshFeed(_ feedId: String) async throws -> (PodcastFeed, [PodcastEpisode]) {
        // Get existing feed
        guard let existingFeed = try await getExistingFeed(feedId: feedId) else {
            throw FeedError.feedNotFound
        }
        
        os_log("🔄 Refreshing feed: %@", log: log, type: .info, existingFeed.title)
        
        // Parse RSS feed
        let feedData = try await URLSession.shared.data(from: URL(string: existingFeed.url)!).0
        let parser = RSSFeedParser(data: feedData, feedUrl: existingFeed.url)
        let (updatedFeed, newEpisodes) = try parser.parseComplete()
        
        // CRITICAL: Download artwork if URL changed or if we don't have artwork yet
        var feedWithArtwork = updatedFeed
        if let artworkUrlString = updatedFeed.artworkUrl, !artworkUrlString.isEmpty,
           let artworkUrl = URL(string: artworkUrlString),
           (existingFeed.artworkUrl != artworkUrlString || existingFeed.imageData == nil) {
            os_log("🖼️ Downloading updated artwork for feed: %@", log: log, type: .info, updatedFeed.title)
            
            do {
                let (artworkData, _) = try await URLSession.shared.data(from: artworkUrl)
                feedWithArtwork.imageData = artworkData
                os_log("✅ Downloaded updated artwork (%d bytes) for feed: %@", log: log, type: .info, artworkData.count, updatedFeed.title)
            } catch {
                os_log("⚠️ Failed to download updated artwork for feed: %@ - %@", log: log, type: .error, updatedFeed.title, error.localizedDescription)
                // Keep existing artwork if download fails
                feedWithArtwork.imageData = existingFeed.imageData
            }
        } else {
            // Keep existing artwork if URL hasn't changed
            feedWithArtwork.imageData = existingFeed.imageData
        }
        
        // Update feed and add new episodes
        return try await updateFeedWithNewEpisodes(
            existingFeed: existingFeed,
            updatedFeed: feedWithArtwork,
            newEpisodes: newEpisodes
        )
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
    
    private func saveFeedWithEpisodes(feed: PodcastFeed, episodes: [PodcastEpisode]) async throws -> PodcastFeed {
        return try await withCheckedThrowingContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            
            backgroundContext.perform {
                do {
                    // Check if feed already exists by URL (primary check) or ID (secondary check)
                    let fetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "url == %@ OR id == %@", feed.url, feed.id)
                    fetchRequest.fetchLimit = 1
                    
                    if let existingFeed = try backgroundContext.fetch(fetchRequest).first {
                        os_log("⚠️ Feed already exists, skipping duplicate: %@", log: self.log, type: .info, feed.title)
                        let podcastFeed = existingFeed.toPodcastFeed()
                        continuation.resume(returning: podcastFeed)
                        return
                    }
                    
                    // Double-check with a more comprehensive search to prevent any duplicates
                    let titleCheckRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    titleCheckRequest.predicate = NSPredicate(format: "title == %@ AND url == %@", feed.title, feed.url)
                    titleCheckRequest.fetchLimit = 1
                    
                    if let duplicateFeed = try backgroundContext.fetch(titleCheckRequest).first {
                        os_log("⚠️ Duplicate feed detected by title+URL, skipping: %@", log: self.log, type: .info, feed.title)
                        let podcastFeed = duplicateFeed.toPodcastFeed()
                        continuation.resume(returning: podcastFeed)
                        return
                    }
                    
                    // Create new feed
                    let managedFeed = FeedModel(context: backgroundContext)
                    managedFeed.update(from: feed)
                    
                    // Save episodes in batches for performance
                    try self.saveEpisodesInBatches(episodes, for: managedFeed, in: backgroundContext)
                    
                    try backgroundContext.save()
                    
                    os_log("✅ Saved new feed with %d episodes: %@", log: self.log, type: .info, episodes.count, feed.title)
                    continuation.resume(returning: feed)
                    
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
                    
                    // Save new episodes
                    try self.saveEpisodesInBatches(actuallyNewEpisodes, for: managedFeed, in: backgroundContext)
                    
                    try backgroundContext.save()
                    
                    os_log("🔄 Updated feed with %d new episodes", log: self.log, type: .info, actuallyNewEpisodes.count)
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
        fetchRequest.resultType = .dictionaryResultType
        
        let results = try context.fetch(fetchRequest) as! [[String: Any]]
        return Set(results.compactMap { $0["id"] as? String })
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
        }
    }
}

// MARK: - RSS Parser

class RSSFeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let feedUrl: String
    
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
    
    init(data: Data, feedUrl: String) {
        self.parser = XMLParser(data: data)
        self.feedUrl = feedUrl
        super.init()
        self.parser.delegate = self
    }
    
    func parseComplete() throws -> (PodcastFeed, [PodcastEpisode]) {
        guard parser.parse() else {
            throw FeedError.parsingFailed
        }
        
        guard let title = feedTitle else {
            throw FeedError.parsingFailed
        }
        
        let feed = PodcastFeed(
            id: UUID().uuidString,
            title: title,
            url: feedUrl,
            artworkUrl: feedArtworkUrl,
            description: feedDescription ?? ""
        )
        
        return (feed, episodes)
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        characterBuffer = ""
        
        switch elementName {
        case "item":
            isParsingItem = true
            currentEpisode = EpisodeBuilder()
        case "enclosure":
            if isParsingItem, let url = attributeDict["url"] {
                currentEpisode?.audioUrl = url
                if let lengthString = attributeDict["length"], let length = Int64(lengthString) {
                    currentEpisode?.fileSize = length
                }
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
            case "pubDate":
                currentEpisode?.pubDate = trimmedContent
            case "guid":
                currentEpisode?.guid = trimmedContent
            case "itunes:duration":
                currentEpisode?.duration = trimmedContent
            case "item":
                if let episode = currentEpisode?.build() {
                    episodes.append(episode)
                }
                isParsingItem = false
                currentEpisode = nil
            default:
                break
            }
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
    
    func build() -> PodcastEpisode? {
        guard let title = title,
              let description = description,
              let audioUrl = audioUrl,
              let pubDateString = pubDate else {
            return nil
        }
        
        let publicationDate = DateFormatter.rfc2822.date(from: pubDateString) ?? Date()
        let episodeDuration = parseDuration(duration ?? "0")
        let episodeId = guid ?? UUID().uuidString
        
        return PodcastEpisode(
            id: episodeId,
            title: title,
            descriptionText: description,
            audioUrl: audioUrl,
            publicationDate: publicationDate,
            duration: episodeDuration,
            state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.0, isDownloaded: false),
            feedId: "", // Will be set when saving
            fileSize: fileSize
        )
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