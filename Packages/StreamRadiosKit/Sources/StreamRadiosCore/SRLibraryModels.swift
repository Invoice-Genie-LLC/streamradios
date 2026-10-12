import Foundation

public struct SRRadioStationRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var streamURL: String
    public var artworkURL: String?
    public var artworkData: Data?
    public var country: String
    public var isFavorite: Bool
    public var favoriteOrder: Int?
    public var lastPlayed: Date?
    public var modifiedAt: Date

    public init(
        id: String,
        name: String,
        streamURL: String,
        artworkURL: String? = nil,
        artworkData: Data? = nil,
        country: String = "Unknown Region",
        isFavorite: Bool = false,
        favoriteOrder: Int? = nil,
        lastPlayed: Date? = nil,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.country = country
        self.isFavorite = isFavorite
        self.favoriteOrder = favoriteOrder
        self.lastPlayed = lastPlayed
        self.modifiedAt = modifiedAt
    }
}

public struct SRPodcastFeedRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var feedURL: String
    public var artworkURL: String?
    public var artworkData: Data?
    public var descriptionText: String?
    public var supportsChapters: Bool?
    public var order: Int
    public var modifiedAt: Date

    public init(
        id: String,
        title: String,
        feedURL: String,
        artworkURL: String? = nil,
        artworkData: Data? = nil,
        descriptionText: String? = nil,
        supportsChapters: Bool? = nil,
        order: Int = 0,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.descriptionText = descriptionText
        self.supportsChapters = supportsChapters
        self.order = order
        self.modifiedAt = modifiedAt
    }
}

public struct SRPodcastEpisodeRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var feedID: String
    public var title: String
    public var descriptionText: String
    public var audioURL: String
    public var publicationDate: Date
    public var duration: TimeInterval
    public var chaptersURL: String?
    public var chapters: [SRPodcastChapterRecord]?

    public init(
        id: String,
        feedID: String,
        title: String,
        descriptionText: String,
        audioURL: String,
        publicationDate: Date,
        duration: TimeInterval,
        chaptersURL: String? = nil,
        chapters: [SRPodcastChapterRecord]? = nil
    ) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.descriptionText = descriptionText
        self.audioURL = audioURL
        self.publicationDate = publicationDate
        self.duration = duration
        self.chaptersURL = chaptersURL
        self.chapters = chapters
    }
}

public struct SRPodcastChapterRecord: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var startTime: TimeInterval

    public var id: String { "\(startTime)-\(title)" }

    public init(title: String, startTime: TimeInterval) {
        self.title = title
        self.startTime = startTime
    }
}

public struct SREpisodeStateRecord: Codable, Hashable, Identifiable, Sendable {
    public var episodeID: String
    public var feedID: String
    public var audioURL: String?
    public var progress: Double
    public var isFavorite: Bool
    public var isPlayed: Bool
    public var modifiedAt: Date
    public var positionSeconds: Double?
    public var durationSeconds: Double?

    public var id: String { "\(feedID)\u{1F}\(episodeID)" }

    public init(
        episodeID: String,
        feedID: String,
        audioURL: String? = nil,
        progress: Double,
        isFavorite: Bool = false,
        isPlayed: Bool = false,
        modifiedAt: Date = .now,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) {
        self.episodeID = episodeID
        self.feedID = feedID
        self.audioURL = audioURL
        self.progress = min(max(progress, 0), 1)
        self.isFavorite = isFavorite
        self.isPlayed = isPlayed
        self.modifiedAt = modifiedAt
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct SRLibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var selectedCountryName: String?
    public var selectedCountryCode: String?
    public var stations: [SRRadioStationRecord]
    public var feeds: [SRPodcastFeedRecord]
    public var episodeStates: [SREpisodeStateRecord]
    public var syncChanges: [SRSyncChange]?
    /// The iPhone's resolved StreamRadios Pro status; nil when unknown or sent by an older iPhone build.
    public var isEntitled: Bool?

    public init(
        schemaVersion: Int = SRLibrarySnapshot.currentSchemaVersion,
        generatedAt: Date = .now,
        selectedCountryName: String? = nil,
        selectedCountryCode: String? = nil,
        stations: [SRRadioStationRecord] = [],
        feeds: [SRPodcastFeedRecord] = [],
        episodeStates: [SREpisodeStateRecord] = [],
        syncChanges: [SRSyncChange]? = nil,
        isEntitled: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.selectedCountryName = selectedCountryName
        self.selectedCountryCode = selectedCountryCode
        self.stations = stations
        self.feeds = feeds
        self.episodeStates = episodeStates
        self.syncChanges = syncChanges
        self.isEntitled = isEntitled
    }
}

public struct SRLibraryArtworkBatch: Codable, Equatable, Sendable {
    public static let fileKey = "libraryArtworkBatch"
    public var generatedAt: Date
    public var stations: [String: Data]
    public var feeds: [String: Data]

    public init(generatedAt: Date = .now, stations: [String: Data] = [:], feeds: [String: Data] = [:]) {
        self.generatedAt = generatedAt
        self.stations = stations
        self.feeds = feeds
    }

    public func batches() -> [Self] {
        var result: [Self] = []
        var batch = Self(generatedAt: generatedAt)
        for key in stations.keys.sorted() {
            batch.stations[key] = stations[key]
            if batch.stations.count + batch.feeds.count == 20 {
                result.append(batch)
                batch = Self(generatedAt: generatedAt)
            }
        }
        for key in feeds.keys.sorted() {
            batch.feeds[key] = feeds[key]
            if batch.stations.count + batch.feeds.count == 20 {
                result.append(batch)
                batch = Self(generatedAt: generatedAt)
            }
        }
        if !batch.stations.isEmpty || !batch.feeds.isEmpty { result.append(batch) }
        return result
    }
}

/// watchOS can't compose email, so the Watch hands support requests off to the iPhone.
public enum SRSupportContact {
    public static let email = "support@streamradios.app"
    /// Must also be listed under NSUserActivityTypes in the iPhone Info.plist.
    public static let handoffActivityType = "com.radio.streamradios.contactSupport"
    public static var mailtoURL: URL? { URL(string: "mailto:\(email)?subject=StreamRadios%20Support") }
}

public struct SRChapterRequest: Codable, Sendable {
    public static let messageKey = "episodeChapterRequest"
    public static let responseKey = "episodeChapterResponse"
    public var feedID: String
    public var episodeID: String
    public var audioURL: String

    public init(feedID: String, episodeID: String, audioURL: String) {
        self.feedID = feedID
        self.episodeID = episodeID
        self.audioURL = audioURL
    }
}

public struct SRChapterDelivery: Codable, Sendable {
    public static let messageKey = "episodeChapterDelivery"
    public static let deferredRequestKey = "deferredChapterReply"
    public let request: SRChapterRequest
    public let chapters: [SRPodcastChapterRecord]

    public init(request: SRChapterRequest, chapters: [SRPodcastChapterRecord]) {
        self.request = request
        self.chapters = chapters
    }

    public func matches(_ other: SRChapterRequest) -> Bool {
        request.feedID == other.feedID && request.audioURL == other.audioURL
    }
}

public struct SRWatchLibraryBootstrap: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var snapshot: SRLibrarySnapshot
    public var episodes: [SRPodcastEpisodeRecord]

    public init(
        schemaVersion: Int = SRWatchLibraryBootstrap.currentSchemaVersion,
        snapshot: SRLibrarySnapshot,
        episodes: [SRPodcastEpisodeRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
        self.episodes = episodes
    }
}

public struct SRStationFavoriteMutation: Codable, Equatable, Sendable {
    public var stationID: String
    public var streamURL: String
    public var name: String
    public var country: String
    public var artworkURL: String?
    public var artworkData: Data?
    public var isFavorite: Bool
    public var modifiedAt: Date

    public init(
        stationID: String,
        streamURL: String,
        name: String = "Radio Station",
        country: String = "Unknown Region",
        artworkURL: String? = nil,
        artworkData: Data? = nil,
        isFavorite: Bool,
        modifiedAt: Date = .now
    ) {
        self.stationID = stationID
        self.streamURL = streamURL
        self.name = name
        self.country = country
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.isFavorite = isFavorite
        self.modifiedAt = modifiedAt
    }
}

public struct SREpisodeProgressMutation: Codable, Equatable, Sendable {
    public var episodeID: String
    public var feedID: String
    public var audioURL: String?
    public var progress: Double
    public var modifiedAt: Date
    public var positionSeconds: Double?
    public var durationSeconds: Double?

    public init(
        episodeID: String,
        feedID: String,
        audioURL: String? = nil,
        progress: Double,
        modifiedAt: Date = .now,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) {
        self.episodeID = episodeID
        self.feedID = feedID
        self.audioURL = audioURL
        self.progress = min(max(progress, 0), 1)
        self.modifiedAt = modifiedAt
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct SREpisodeFavoriteMutation: Codable, Equatable, Sendable {
    public var episodeID: String
    public var feedID: String
    public var audioURL: String?
    public var isFavorite: Bool
    public var modifiedAt: Date

    public init(
        episodeID: String,
        feedID: String,
        audioURL: String? = nil,
        isFavorite: Bool,
        modifiedAt: Date = .now
    ) {
        self.episodeID = episodeID
        self.feedID = feedID
        self.audioURL = audioURL
        self.isFavorite = isFavorite
        self.modifiedAt = modifiedAt
    }
}

public struct SRStationPlayedMutation: Codable, Equatable, Sendable {
    public var stationID: String
    public var streamURL: String
    public var name: String
    public var country: String
    public var artworkURL: String?
    public var playedAt: Date

    public init(
        stationID: String,
        streamURL: String,
        name: String = "Radio Station",
        country: String = "Unknown Region",
        artworkURL: String? = nil,
        playedAt: Date = .now
    ) {
        self.stationID = stationID
        self.streamURL = streamURL
        self.name = name
        self.country = country
        self.artworkURL = artworkURL
        self.playedAt = playedAt
    }
}

public enum SRWatchMutation: Codable, Equatable, Identifiable, Sendable {
    case stationFavorite(SRStationFavoriteMutation)
    case episodeProgress(SREpisodeProgressMutation)
    case episodeFavorite(SREpisodeFavoriteMutation)
    case stationPlayed(SRStationPlayedMutation)

    public var id: String {
        switch self {
        case .stationFavorite(let value):
            "station-favorite:\(value.stationID):\(value.modifiedAt.timeIntervalSince1970)"
        case .episodeProgress(let value):
            "episode-progress:\(value.feedID):\(value.episodeID):\(value.modifiedAt.timeIntervalSince1970)"
        case .episodeFavorite(let value):
            "episode-favorite:\(value.feedID):\(value.episodeID):\(value.modifiedAt.timeIntervalSince1970)"
        case .stationPlayed(let value):
            "station-played:\(value.stationID):\(value.playedAt.timeIntervalSince1970)"
        }
    }
}