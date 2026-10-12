import Foundation
import Testing
@testable import StreamRadiosCore

@MainActor
struct SRSyncJournalTests {
    @Test func phoneLaunchDoesNotReplayOldLocalProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phone.json")
        let phone = SRSyncJournal(url: url)
        let oldCheckpoint = try #require(try await phone.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", progress: 0.2))))
        let restarted = SRSyncJournal(url: url)
        var savedPhoneProgress = 0.6
        for change in restarted.changesRequiringApplication {
            if case .episodeProgress(let value) = change.mutation { savedPhoneProgress = value.progress }
        }
        try #require(savedPhoneProgress == 0.6)
        try await restarted.receive(oldCheckpoint, requiringApplication: true)
        try #require(restarted.changesRequiringApplication.isEmpty)
    }

    @Test func legacyJournalDoesNotReplayHistoricalProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phone.json")
        let journal = SRSyncJournal(url: url)
        let checkpoint = try #require(try await journal.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", progress: 0.1))))
        var legacy = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy.removeValue(forKey: "unapplied")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)
        let migrated = SRSyncJournal(url: url)
        try #require(migrated.changes == [checkpoint])
        try #require(migrated.pending == [checkpoint])
        try #require(migrated.changesRequiringApplication.isEmpty)
        try await migrated.receive(checkpoint, requiringApplication: true)
        try #require(migrated.changesRequiringApplication.isEmpty)
    }

    @Test func incomingRewindReplaysOnlyUntilApplied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phone.json")
        let watch = SRSyncJournal(url: directory.appendingPathComponent("watch.json"))
        let rewind = try #require(try await watch.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", progress: 0.1))))
        let phone = SRSyncJournal(url: url)
        try await phone.receive(rewind, requiringApplication: true)
        let restarted = SRSyncJournal(url: url)
        try #require(restarted.changesRequiringApplication == [rewind])
        restarted.markApplied(rewind)
        try await restarted.flush()
        let appliedRestart = SRSyncJournal(url: url)
        try await appliedRestart.receive(rewind, requiringApplication: true)
        try #require(appliedRestart.changesRequiringApplication.isEmpty)
        let next = try #require(try await watch.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", progress: 0))))
        try await appliedRestart.receive(next, requiringApplication: true)
        try #require(appliedRestart.changesRequiringApplication == [next])
        _ = appliedRestart.stage(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", progress: 0.7)))
        try #require(appliedRestart.changesRequiringApplication.isEmpty)
    }

    @Test func reorderedChangesAndRewindsConverge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = SRSyncJournal(url: directory.appendingPathComponent("phone.json"))
        let watch = SRSyncJournal(url: directory.appendingPathComponent("watch.json"))
        let first = try #require(try await phone.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", audioURL: "https://example.com/audio", progress: 0.8))))
        try await watch.receive(first)
        let rewind = try #require(try await watch.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "episode", feedID: "feed", audioURL: "https://example.com/audio", progress: 0.2))))
        try await phone.receive(rewind)
        try await phone.receive(first)
        try await watch.receive(first)
        try #require(phone.latest(for: first) == rewind)
        try #require(watch.latest(for: first) == rewind)
        let favorite = try #require(try await phone.record(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "episode", feedID: "feed", audioURL: "https://example.com/audio", isFavorite: true))))
        try await watch.receive(favorite)
        try #require(watch.latest(for: rewind) == rewind)
        try #require(watch.latest(for: favorite) == favorite)
        let reopened = SRSyncJournal(url: directory.appendingPathComponent("watch.json"))
        try #require(reopened.latest(for: rewind) == rewind)
        try #require(reopened.pending.contains { $0.id == rewind.id })
    }

    @Test func acknowledgementsDoNotRemoveNewerUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        let favorite = try #require(try await journal.record(.stationFavorite(SRStationFavoriteMutation(
            stationID: "station", streamURL: "https://example.com/Live", isFavorite: true))))
        let removal = try #require(try await journal.record(.stationFavorite(SRStationFavoriteMutation(
            stationID: "station", streamURL: "https://example.com/Live", isFavorite: false))))
        try await journal.acknowledge(favorite.id)
        try #require(journal.pending.map(\.id) == [removal.id])
        try await journal.receive(favorite)
        try #require(journal.latest(for: favorite) == removal)
        try await journal.acknowledge(removal.id)
        try #require(journal.pending.isEmpty)
        try #require(SRWatchMutation.stationIdentity("https://EXAMPLE.com/Live") == "https://example.com/Live")
    }

    @Test func equalCountersHaveDeterministicWinner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        let mutation = SRWatchMutation.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "episode", feedID: "feed", isFavorite: true))
        let first = SRSyncChange(revision: SRSyncRevision(counter: 100, deviceID: "a"), mutation: mutation)
        let second = SRSyncChange(revision: SRSyncRevision(counter: 100, deviceID: "b"), mutation: mutation)
        try await journal.receive(second)
        try await journal.receive(first)
        try await journal.receive(second)
        try #require(journal.latest(for: first) == second)
    }

    @Test func episodeAliasesKeepOneWinnerAndPrecisePosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        let initial = try #require(try await journal.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "phone-id", feedID: "feed", progress: 0.5))))
        let enriched = try #require(try await journal.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "phone-id", feedID: "feed", audioURL: "https://example.com/audio", progress: 0.6,
            positionSeconds: 360, durationSeconds: 600))))
        let rewind = try #require(try await journal.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "watch-id", feedID: "feed", audioURL: "https://example.com/audio", progress: 0.2,
            positionSeconds: 120, durationSeconds: 600))))
        try await journal.receive([enriched, initial])
        try #require(journal.changes == [rewind])
        try #require(journal.latest(for: enriched) == rewind)
        try await journal.acknowledge(rewind.id)
        let echo = try await journal.record(.episodeProgress(SREpisodeProgressMutation(
            episodeID: "phone-id", feedID: "feed", audioURL: "https://example.com/audio", progress: 0.2)))
        try #require(echo == nil)
        let reopened = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        try #require(reopened.changes == [rewind])
        try #require(reopened.pending.isEmpty)
    }

    @Test func stagedTapBeatsDelayedSnapshotBeforeFlush() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        let original = try #require(try await journal.record(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "episode", feedID: "feed", isFavorite: true))))
        let removal = try #require(journal.stage(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "episode", feedID: "feed", isFavorite: false))))
        try #require(journal.latest(for: original) == removal)
        try await journal.receive(original)
        try await journal.acknowledge(original.id)
        let reopened = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        try #require(reopened.latest(for: original) == removal)
        try #require(reopened.pending == [removal])
    }

    @Test func stationPathsAndEpisodeFieldsStayIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SRSyncJournal(url: directory.appendingPathComponent("journal.json"))
        _ = try await journal.record(.stationFavorite(SRStationFavoriteMutation(
            stationID: "upper", streamURL: "https://example.com/Live?token=A", isFavorite: true)))
        _ = try await journal.record(.stationFavorite(SRStationFavoriteMutation(
            stationID: "lower", streamURL: "https://example.com/live?token=A", isFavorite: false)))
        _ = try await journal.record(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "same-id", feedID: "first-feed", isFavorite: true)))
        _ = try await journal.record(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: "same-id", feedID: "second-feed", isFavorite: false)))
        try #require(journal.changes.count == 4)
    }
}