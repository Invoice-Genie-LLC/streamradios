import Foundation
import Testing
@testable import StreamRadiosCore

struct SRLibraryModelsTests {
    @Test func chapterDeliveryRoundTripsAndMatchesOnlyTheRequestedAudio() throws {
        let request = SRChapterRequest(feedID: "feed", episodeID: "episode", audioURL: "https://example.com/episode.mp3")
        let chapters = [SRPodcastChapterRecord(title: "Opening", startTime: 0),
                        SRPodcastChapterRecord(title: "Discussion", startTime: 120)]
        let delivery = SRChapterDelivery(request: request, chapters: chapters)
        let decoded = try JSONDecoder().decode(SRChapterDelivery.self, from: JSONEncoder().encode(delivery))
        #expect(decoded.chapters == chapters)
        #expect(decoded.matches(request))
        #expect(decoded.matches(SRChapterRequest(feedID: "feed", episodeID: "alternate-id", audioURL: request.audioURL)))
        #expect(!decoded.matches(SRChapterRequest(feedID: "other-feed", episodeID: "episode", audioURL: request.audioURL)))
        #expect(!decoded.matches(SRChapterRequest(feedID: "feed", episodeID: "episode", audioURL: "https://example.com/other.mp3")))
    }

    @Test func radioArtworkParsesMetadataAndRejectsStationLabels() throws {
        let standard = SRRadioArtworkLookup.Track(metadata: "Queen - Bohemian Rhapsody", stationName: "Test FM")
        #expect(standard?.artist == "Queen")
        #expect(standard?.title == "Bohemian Rhapsody")
        let icy = SRRadioArtworkLookup.Track(metadata: "StreamTitle='Queen - Bohemian Rhapsody';", stationName: "Test FM")
        #expect(icy == standard)
        let timestamped = SRRadioArtworkLookup.Track(metadata: "Queen~Bohemian Rhapsody~12345", stationName: "Test FM")
        #expect(timestamped?.key == standard?.key)
        #expect(SRRadioArtworkLookup.Track(metadata: "Test FM", stationName: "Test FM") == nil)
        #expect(SRRadioArtworkLookup.Track(metadata: "Test FM - Test FM", stationName: "Test FM") == nil)
        #expect(SRRadioArtworkLookup.Track(metadata: " - ", stationName: "Test FM") == nil)
    }

    @Test func radioArtworkMatchesTrackNotFirstSearchResult() throws {
        let data = Data("""
        [
          {"artistName":"Queen","trackName":"Another Song","artworkUrl100":"https://example.com/wrong/100x100bb.jpg"},
          {"artistName":"Karaoke Tribute","trackName":"Bohemian Rhapsody","artworkUrl100":"https://example.com/cover/100x100bb.jpg"},
          {"artistName":"Queen","trackName":"Bohemian Rhapsody","artworkUrl100":"https://example.com/right/100x100bb.jpg"}
        ]
        """.utf8)
        let results = try JSONDecoder().decode([SRRadioArtworkLookup.Result].self, from: data)
        let track = SRRadioArtworkLookup.Track(metadata: "Queen - Bohemian Rhapsody", stationName: "Test FM")!
        let reversed = SRRadioArtworkLookup.Track(metadata: "Bohemian Rhapsody - Queen", stationName: "Test FM")!
        let expected = URL(string: "https://example.com/right/300x300bb.jpg")
        #expect(SRRadioArtworkLookup.bestArtworkURL(for: track, results: results) == expected)
        #expect(SRRadioArtworkLookup.bestArtworkURL(for: reversed, results: results) == expected)
        #expect(SRRadioArtworkLookup.bestArtworkURL(for: track, results: Array(results.prefix(2))) == nil)
        #expect(SRRadioArtworkLookup.bestArtworkURL(for: track, results: []) == nil)
    }

    @Test func artworkBatchesRetainEveryThumbnailBeyondInlineBudget() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var artwork = SRLibraryArtworkBatch(generatedAt: date)
        for index in 0..<27 {
            artwork.stations["https://example.com/station/\(index)"] = Data(repeating: UInt8(index), count: 8 * 1_024)
        }
        for index in 0..<24 {
            artwork.feeds["feed-\(index)"] = Data(repeating: UInt8(index), count: 8 * 1_024)
        }
        let batches = artwork.batches()
        #expect(batches.count == 3)
        var recovered = SRLibraryArtworkBatch(generatedAt: date)
        for batch in batches {
            #expect(batch.stations.count + batch.feeds.count <= 20)
            let data = try JSONEncoder().encode(batch)
            #expect(data.count < 240_000)
            let decoded = try JSONDecoder().decode(SRLibraryArtworkBatch.self, from: data)
            #expect(decoded == batch)
            #expect(decoded.generatedAt == date)
            recovered.stations.merge(decoded.stations) { _, incoming in incoming }
            recovered.feeds.merge(decoded.feeds) { _, incoming in incoming }
        }
        #expect(recovered == artwork)
        #expect(SRLibraryArtworkBatch().batches().isEmpty)
    }

    @Test func snapshotRoundTripsWithoutDeviceLocalDownloadPaths() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = SRLibrarySnapshot(
            generatedAt: date,
            selectedCountryName: "United States",
            selectedCountryCode: "US",
            stations: [
                SRRadioStationRecord(
                    id: "station-1",
                    name: "Radio One",
                    streamURL: "https://example.com/live.mp3",
                    artworkData: Data([0x01, 0x02, 0x03]),
                    isFavorite: true,
                    lastPlayed: date,
                    modifiedAt: date
                )
            ],
            feeds: [
                SRPodcastFeedRecord(
                    id: "feed-1",
                    title: "Podcast One",
                    feedURL: "https://example.com/feed.xml",
                    artworkData: Data([0x04, 0x05, 0x06]),
                    modifiedAt: date
                )
            ],
            episodeStates: [
                SREpisodeStateRecord(
                    episodeID: "episode-1",
                    feedID: "feed-1",
                    audioURL: "https://example.com/episode-1.mp3",
                    progress: 0.25,
                    modifiedAt: date
                )
            ]
        )

        let data = try SRLibrarySnapshotTransport.encode(snapshot)
        let decoded = try SRLibrarySnapshotTransport.decode(data)

        #expect(decoded == snapshot)
        #expect(SRLibrarySnapshotTransport.applicationContextKey == "librarySnapshot")
        #expect(String(decoding: data, as: UTF8.self).contains("localFilePath") == false)
    }

    @Test func episodeProgressIsClampedToValidRange() {
        let belowRange = SREpisodeStateRecord(
            episodeID: "episode-1",
            feedID: "feed-1",
            progress: -0.5
        )
        let aboveRange = SREpisodeStateRecord(
            episodeID: "episode-2",
            feedID: "feed-1",
            progress: 1.5
        )

        #expect(belowRange.progress == 0)
        #expect(aboveRange.progress == 1)
        #expect(belowRange.id != aboveRange.id)
    }

    @Test func episodeStateUpdateRoundTrips() throws {
        let state = SREpisodeStateRecord(
            episodeID: "episode-1",
            feedID: "feed-1",
            audioURL: "https://example.com/episode-1.mp3",
            progress: 0.625,
            isPlayed: false
        )

        let data = try SRLibrarySnapshotTransport.encode(state)
        let decoded = try SRLibrarySnapshotTransport.decodeEpisodeState(data)

        #expect(decoded == state)
        #expect(SRLibrarySnapshotTransport.episodeStateUpdateKey == "episodeStateUpdate")
    }

    @Test func independentWatchMutationsRoundTrip() throws {
        let mutations: [SRWatchMutation] = [
            .stationFavorite(SRStationFavoriteMutation(
                stationID: "station-1",
                streamURL: "https://example.com/live.mp3",
                isFavorite: true
            )),
            .episodeProgress(SREpisodeProgressMutation(
                episodeID: "episode-1",
                feedID: "feed-1",
                progress: 0.4
            )),
            .episodeFavorite(SREpisodeFavoriteMutation(
                episodeID: "episode-1",
                feedID: "feed-1",
                isFavorite: true
            ))
        ]

        for mutation in mutations {
            let data = try SRLibrarySnapshotTransport.encode(mutation)
            #expect(try SRLibrarySnapshotTransport.decodeMutation(data) == mutation)
        }
    }

    @Test func watchBootstrapRoundTripsEpisodeSeeds() throws {
        let episode = SRPodcastEpisodeRecord(
            id: "episode-1",
            feedID: "feed-1",
            title: "Episode One",
            descriptionText: "Notes",
            audioURL: "https://example.com/episode.mp3",
            publicationDate: .distantPast,
            duration: 120,
            chapters: [SRPodcastChapterRecord(title: "Opening", startTime: 0)]
        )
        let bootstrap = SRWatchLibraryBootstrap(
            snapshot: SRLibrarySnapshot(),
            episodes: [episode]
        )

        let data = try SRLibrarySnapshotTransport.encode(bootstrap)
        #expect(try SRLibrarySnapshotTransport.decodeBootstrap(data) == bootstrap)
        #expect(try SRLibrarySnapshotTransport.decodeBootstrap(data).episodes[0].chapters?.count == 1)
    }
}