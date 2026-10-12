import Foundation
import Observation
import StreamRadiosCore
import WatchConnectivity

extension SREpisodeStateRecord {
    /// Matches the iPhone's 99% completion threshold.
    var isFinished: Bool { isPlayed || progress >= 0.99 }
}

@MainActor
@Observable
final class WatchLibraryStore {
    enum SyncState: Equatable {
        case needsInitialSync
        case syncing
        case ready(Date)
        case failed(String)
    }

    private(set) var favoriteStations: [SRRadioStationRecord] = []
    private(set) var recentStations: [SRRadioStationRecord] = []
    private(set) var podcastFeeds: [SRPodcastFeedRecord] = []
    private(set) var bootstrapEpisodes: [SRPodcastEpisodeRecord] = []
    private(set) var episodeStates: [String: SREpisodeStateRecord] = [:]
    private(set) var selectedCountryName = "United States"
    private(set) var selectedCountryCode = "US"
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var syncState: SyncState = .needsInitialSync
    private(set) var isPhoneReachable = false
    private(set) var hasCompletedInitialSync = false
    private(set) var hasPhoneSnapshotAvailable = false
    private(set) var phoneEntitlement: Bool? = UserDefaults.standard.object(forKey: "watchPhoneEntitlement") as? Bool
    private(set) var isManualSyncing = false
    private(set) var manualSyncResult: ManualSyncResult?

    enum ManualSyncResult: Equatable {
        case synced
        case alreadyInSync
        case failed(String)

        var message: String {
            switch self {
            case .synced: "Synced"
            case .alreadyInSync: "Everything is in sync"
            case .failed(let message): message
            }
        }
    }

    var canRequestInitialSync: Bool { isPhoneReachable || hasPhoneSnapshotAvailable }

    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let connectivity = WatchLibraryConnectivity()
    @ObservationIgnored private let cachedSnapshotKey = "cachedPhoneLibrarySnapshot"
    @ObservationIgnored private let cachedEpisodeStatesKey = "cachedWatchEpisodeStates"
    @ObservationIgnored private var pendingMutations: [SRWatchMutation] = []
    @ObservationIgnored private let localRecentStationsKey = "watchLocalRecentStations"
    @ObservationIgnored private var localRecentStations: [SRRadioStationRecord] = []
    @ObservationIgnored private var acceptsIncomingSnapshots = false
    @ObservationIgnored private let lastFullSyncKey = "watchLastFullSyncAt"
    @ObservationIgnored private var lastFullSyncRequestAt = Date.distantPast
    @ObservationIgnored private var appliedSnapshotCount = 0
    @ObservationIgnored private var manualSyncError: String?
    @ObservationIgnored private var manualSyncResultClearTask: Task<Void, Never>?
    // The phone pushes its library when it opens; keep it until the user taps Sync.
    @ObservationIgnored private var pendingInitialSnapshot: Data?
    @ObservationIgnored private var pendingInitialBootstraps: [SRWatchLibraryBootstrap] = []
    @ObservationIgnored private var receivedArtwork = SRLibraryArtworkBatch()
    @ObservationIgnored private var stationArtworkDates: [String: Date] = [:]
    @ObservationIgnored private var feedArtworkDates: [String: Date] = [:]
    @ObservationIgnored private let journal = SRSyncJournal(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamRadios/watch-sync-journal.json")
    )

    init() {
        if let data = UserDefaults.standard.data(forKey: localRecentStationsKey),
           let stations = try? JSONDecoder().decode([SRRadioStationRecord].self, from: data) {
            localRecentStations = stations
        }
        pendingMutations = WatchLibraryPersistence.loadMutations()
        if let data = WatchLibraryPersistence.loadSnapshotData() {
            acceptsIncomingSnapshots = true
            applyPhoneSnapshot(data, persist: false)
        } else if let legacyData = UserDefaults.standard.data(forKey: cachedSnapshotKey) {
            acceptsIncomingSnapshots = true
            applyPhoneSnapshot(legacyData, persist: true)
            UserDefaults.standard.removeObject(forKey: cachedSnapshotKey)
        }
        if let data = UserDefaults.standard.data(forKey: cachedEpisodeStatesKey),
           let states = try? JSONDecoder().decode([SREpisodeStateRecord].self, from: data) {
            mergeEpisodeStates(states, persist: true)
            UserDefaults.standard.removeObject(forKey: cachedEpisodeStatesKey)
        }

        connectivity.onSnapshot = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                guard self.acceptsIncomingSnapshots else {
                    self.pendingInitialSnapshot = data
                    self.markPhoneSnapshotAvailable()
                    return
                }
                await self.receiveSnapshot(data)
            }
        }
        connectivity.onArtwork = { [weak self] batch in
            Task { @MainActor in
                guard let self else { return }
                for (key, data) in batch.stations where batch.generatedAt >= (self.stationArtworkDates[key] ?? .distantPast) {
                    self.receivedArtwork.stations[key] = data
                    self.stationArtworkDates[key] = batch.generatedAt
                }
                for (key, data) in batch.feeds where batch.generatedAt >= (self.feedArtworkDates[key] ?? .distantPast) {
                    self.receivedArtwork.feeds[key] = data
                    self.feedArtworkDates[key] = batch.generatedAt
                }
                self.applyReceivedArtwork()
                if self.hasCompletedInitialSync { self.persistCurrentSnapshot() }
                print("[WatchArtwork] received stations=\(batch.stations.count) feeds=\(batch.feeds.count)")
            }
        }
        connectivity.onBootstrap = { [weak self] bootstrap in
            Task { @MainActor in
                guard let self else { return }
                guard self.acceptsIncomingSnapshots else {
                    self.pendingInitialBootstraps.append(bootstrap)
                    self.markPhoneSnapshotAvailable()
                    return
                }
                await self.applyBootstrap(bootstrap)
            }
        }
        connectivity.onReachabilityChange = { [weak self] isReachable in
            Task { @MainActor in
                self?.isPhoneReachable = isReachable
                if isReachable {
                    if case .failed = self?.syncState { self?.syncState = .needsInitialSync }
                    self?.flushPendingMutations()
                    self?.requestFullSyncIfDue()
                    if self?.syncState == .syncing { self?.connectivity.requestSnapshot() }
                }
            }
        }
        connectivity.onMutationAcknowledged = { [weak self] mutationID in
            Task { @MainActor in self?.acknowledgeMutation(mutationID) }
        }
        connectivity.onMutation = { [weak self] mutation in
            Task { @MainActor in self?.applyRemoteMutation(mutation) }
        }
        connectivity.onVersionedChange = { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.journal.receive(change)
                    self.applyRemoteMutation(self.journal.latest(for: change).mutation, versioned: true)
                    self.connectivity.acknowledge(change.id)
                } catch { self.errorMessage = "Unable to save sync update: \(error.localizedDescription)" }
            }
        }
        connectivity.onVersionedAcknowledgement = { [weak self] id in
            Task { @MainActor in
                do { try await self?.journal.acknowledge(id) }
                catch { self?.errorMessage = error.localizedDescription }
            }
        }
        connectivity.onActivated = { [weak self] in
            Task { @MainActor in self?.flushPendingMutations() }
        }
        replayJournal(persist: true)
        connectivity.activate()
    }

    private func receiveSnapshot(_ data: Data) async {
        guard let snapshot = try? SRLibrarySnapshotTransport.decode(data) else { return }
        do {
            try await journal.receive(snapshot.syncChanges ?? [])
            applyPhoneSnapshot(data, persist: true)
        } catch { errorMessage = error.localizedDescription }
    }

    func flushSync() {
        flushPendingMutations()
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        requestFullSyncIfDue()
    }

    /// Catches up on changes that were never sent individually (e.g. made before the iPhone app launched).
    func requestFullSyncIfDue() {
        guard hasCompletedInitialSync, connectivity.isReachableNow,
              Date().timeIntervalSince(lastFullSyncRequestAt) > 5 * 60 else { return }
        let lastFullSync = UserDefaults.standard.object(forKey: lastFullSyncKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastFullSync) > 6 * 60 * 60 else { return }
        lastFullSyncRequestAt = .now
        connectivity.requestSnapshot()
    }

    func reload() async {
        guard hasCompletedInitialSync else {
            await requestInitialSync()
            return
        }
        guard !isManualSyncing else { return }
        isManualSyncing = true
        manualSyncResult = nil
        manualSyncResultClearTask?.cancel()
        manualSyncError = nil
        let before = libraryFingerprint
        let startCount = appliedSnapshotCount
        let result: ManualSyncResult
        if !connectivity.requestSnapshot(onError: { [weak self] message in
            Task { @MainActor in self?.manualSyncError = message }
        }) {
            result = .failed("Sync isn't available yet. Try again in a moment.")
        } else {
            // Small libraries arrive in the reply; larger ones (or a still-syncing iPhone) follow later.
            let deadline = Date().addingTimeInterval(20)
            while appliedSnapshotCount == startCount, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if appliedSnapshotCount != startCount {
                result = libraryFingerprint == before ? .alreadyInSync : .synced
            } else {
                // The request stays queued and is delivered when the iPhone connects or finishes setting up.
                result = .failed("Sync requested. It will finish when your iPhone is connected and set up.")
            }
        }
        isManualSyncing = false
        manualSyncResult = result
        manualSyncResultClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.manualSyncResult = nil
        }
    }

    private var libraryFingerprint: [String] {
        // Int(Double) traps on NaN/infinity (e.g. progress from a zero-length episode), so format instead.
        func rounded(_ value: Double, places: Int) -> String {
            value.isFinite ? String(format: "%.\(places)f", value) : "nan"
        }
        return favoriteStations.map { "f|\($0.streamURL)|\($0.name)|\($0.favoriteOrder ?? -1)" }
            + recentStations.map { "r|\($0.streamURL)|\(rounded($0.lastPlayed?.timeIntervalSince1970 ?? 0, places: 0))" }
            + podcastFeeds.map { "p|\($0.id)|\($0.title)|\($0.feedURL)|\($0.order)" }
            + episodeStates.keys.sorted().compactMap { key in
                episodeStates[key].map { "e|\(key)|\(rounded($0.progress, places: 3))|\($0.isFavorite)|\($0.isPlayed)" }
            }
            + ["c|\(selectedCountryCode)"]
    }

    private func applyBootstrap(_ bootstrap: SRWatchLibraryBootstrap) async {
        guard let data = try? SRLibrarySnapshotTransport.encode(bootstrap.snapshot) else { return }
        bootstrapEpisodes = bootstrap.episodes
        await receiveSnapshot(data)
        await WatchPodcastLibrary.seedEpisodes(bootstrap.episodes)
    }

    private func markPhoneSnapshotAvailable() {
        hasPhoneSnapshotAvailable = true
        if case .failed = syncState { syncState = .needsInitialSync }
        errorMessage = nil
    }

    /// Reachability callbacks can lag behind the iPhone app opening, so read the live session on demand.
    func refreshConnectionState() {
        isPhoneReachable = connectivity.isReachableNow
        if pendingInitialSnapshot == nil, connectivity.receivedSnapshotData() != nil {
            hasPhoneSnapshotAvailable = true
        }
    }

    func requestInitialSync() async {
        guard !isLoading else { return }
        isLoading = true
        acceptsIncomingSnapshots = true
        syncState = .syncing
        errorMessage = nil
        if let data = pendingInitialSnapshot ?? connectivity.receivedSnapshotData(),
           let stashed = try? SRLibrarySnapshotTransport.decode(data),
           !stashed.stations.isEmpty || !stashed.feeds.isEmpty {
            await receiveSnapshot(data)
        }
        let bootstraps = pendingInitialBootstraps
        pendingInitialSnapshot = nil
        pendingInitialBootstraps = []
        for bootstrap in bootstraps { await applyBootstrap(bootstrap) }
        connectivity.requestSnapshot()
        if case .ready = syncState { return }
        // A background-launched iPhone may need several seconds to load its library before answering.
        try? await Task.sleep(for: .seconds(20))
        guard case .syncing = syncState else { return }
        isLoading = false
        let message = isPhoneReachable
            ? "No response. Unlock your iPhone and try again."
            : "iPhone not reachable. Make sure it's on and nearby, then try again."
        syncState = .failed(message)
        errorMessage = message
    }

    private func applyPhoneSnapshot(_ data: Data, persist: Bool) {
        guard let snapshot = try? SRLibrarySnapshotTransport.decode(data) else { return }
        let existingStations = favoriteStations + recentStations
        let existingFeeds = podcastFeeds
        applyStations(snapshot.stations)
        mergeExistingArtwork(from: existingStations)
        var seenFeedIDs = Set<String>()
        // Routine pushes from a still-loading iPhone can carry no feeds; only a full sync may clear the list.
        if !snapshot.feeds.isEmpty || snapshot.syncChanges != nil || existingFeeds.isEmpty {
            podcastFeeds = snapshot.feeds.sorted { $0.order < $1.order }.filter { seenFeedIDs.insert($0.id).inserted }
        }
        mergeExistingFeedArtwork(from: existingFeeds)
        applyReceivedArtwork()
        mergeEpisodeStates(snapshot.episodeStates)
        if let name = snapshot.selectedCountryName, !name.isEmpty, name != "Select Country" {
            selectedCountryName = name
        }
        if let code = snapshot.selectedCountryCode, !code.isEmpty {
            selectedCountryCode = code
        }
        if let isEntitled = snapshot.isEntitled, isEntitled != phoneEntitlement {
            phoneEntitlement = isEntitled
            UserDefaults.standard.set(isEntitled, forKey: "watchPhoneEntitlement")
        }
        errorMessage = nil
        isLoading = false
        hasCompletedInitialSync = true
        appliedSnapshotCount += 1
        // Only full snapshots (request replies/bootstrap) carry the journal; routine pushes don't.
        if snapshot.syncChanges != nil { UserDefaults.standard.set(Date(), forKey: lastFullSyncKey) }
        syncState = .ready(snapshot.generatedAt)
        reapplyPendingMutations()
        replayJournal(persist: false)
        if persist { persistCurrentSnapshot() }
    }

    /// The iPhone's snapshot already reflects every station favourite it has acknowledged; replaying those
    /// would resurrect stale values (and re-insert them at the top, breaking the phone's order).
    private func replayJournal(persist: Bool) {
        let unacknowledged = Set(journal.pending.map(\.id))
        for change in journal.changes {
            if case .stationFavorite = change.mutation, !unacknowledged.contains(change.id) { continue }
            applyRemoteMutation(change.mutation, versioned: true, persist: persist)
        }
    }

    private func applyReceivedArtwork() {
        favoriteStations = favoriteStations.map { station in
            var station = station
            station.artworkData = receivedArtwork.stations[normalizedStreamURL(station.streamURL)] ?? station.artworkData
            return station
        }
        recentStations = recentStations.map { station in
            var station = station
            station.artworkData = receivedArtwork.stations[normalizedStreamURL(station.streamURL)] ?? station.artworkData
            return station
        }
        podcastFeeds = podcastFeeds.map { feed in
            var feed = feed
            feed.artworkData = receivedArtwork.feeds[feed.id] ?? feed.artworkData
            return feed
        }
    }

    func episodeState(for episode: SRPodcastEpisodeRecord) -> SREpisodeStateRecord? {
        // The same episode can be stored under the iPhone's ID and the Watch's RSS ID; use the newest.
        let key = episodeStateKey(feedID: episode.feedID, episodeID: episode.id)
        let byAudioURL = episode.audioURL.isEmpty ? [] : episodeStates.values.filter {
            $0.feedID == episode.feedID && $0.audioURL == episode.audioURL
        }
        return ([episodeStates[key]].compactMap { $0 } + byAudioURL).max { $0.modifiedAt < $1.modifiedAt }
    }

    func applyLocalEpisodeState(_ state: SREpisodeStateRecord) {
        let key = episodeStateKey(feedID: state.feedID, episodeID: state.episodeID)
        let existing = episodeStates[key]
        var updated = state
        updated.isFavorite = existing?.isFavorite ?? state.isFavorite
        episodeStates[key] = updated
        persistCurrentSnapshot()
        enqueueMutation(.episodeProgress(SREpisodeProgressMutation(
            episodeID: updated.episodeID,
            feedID: updated.feedID,
            audioURL: updated.audioURL,
            progress: updated.progress,
            modifiedAt: updated.modifiedAt,
            positionSeconds: updated.positionSeconds,
            durationSeconds: updated.durationSeconds
        )))
    }

    func isStationFavorite(_ station: SRRadioStationRecord) -> Bool {
        favoriteStations.contains { normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL) }
    }

    func recordPlayedStation(_ station: SRRadioStationRecord) {
        let identity = normalizedStreamURL(station.streamURL)
        var updated = (favoriteStations + recentStations).first {
            normalizedStreamURL($0.streamURL) == identity
        } ?? station
        updated.isFavorite = isStationFavorite(station)
        updated.lastPlayed = .now
        localRecentStations.removeAll { normalizedStreamURL($0.streamURL) == identity }
        localRecentStations.insert(updated, at: 0)
        localRecentStations = Array(localRecentStations.prefix(50))
        if let data = try? JSONEncoder().encode(localRecentStations) {
            UserDefaults.standard.set(data, forKey: localRecentStationsKey)
        }
        applyStations(favoriteStations + recentStations)
        persistCurrentSnapshot()
        enqueueMutation(.stationPlayed(SRStationPlayedMutation(
            stationID: updated.id,
            streamURL: updated.streamURL,
            name: updated.name,
            country: updated.country,
            artworkURL: updated.artworkURL,
            playedAt: updated.lastPlayed ?? .now
        )))
    }

    func toggleFavorite(_ station: SRRadioStationRecord) {
        let newValue = !isStationFavorite(station)
        var updated = station
        updated.isFavorite = newValue
        updated.modifiedAt = .now
        updated.favoriteOrder = newValue ? 0 : nil
        updated.lastPlayed = recentStations.first {
            normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL)
        }?.lastPlayed ?? station.lastPlayed

        favoriteStations.removeAll {
            normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL)
        }
        if newValue { favoriteStations.insert(updated, at: 0) }
        recentStations = recentStations.map {
            normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL) ? updated : $0
        }
        persistCurrentSnapshot()
        enqueueMutation(.stationFavorite(SRStationFavoriteMutation(
            stationID: station.id,
            streamURL: station.streamURL,
            name: station.name,
            country: station.country,
            artworkURL: station.artworkURL,
            artworkData: station.artworkData,
            isFavorite: newValue,
            modifiedAt: updated.modifiedAt
        )))
    }

    func toggleFavorite(_ episode: SRPodcastEpisodeRecord) {
        let key = episodeStateKey(feedID: episode.feedID, episodeID: episode.id)
        let existing = episodeState(for: episode)
        let newValue = !(existing?.isFavorite ?? false)
        episodeStates[key] = SREpisodeStateRecord(
            episodeID: episode.id,
            feedID: episode.feedID,
            audioURL: episode.audioURL,
            progress: existing?.progress ?? 0,
            isFavorite: newValue,
            isPlayed: existing?.isPlayed ?? false,
            modifiedAt: .now,
            positionSeconds: existing?.positionSeconds,
            durationSeconds: existing?.durationSeconds
        )
        persistCurrentSnapshot()
        enqueueMutation(.episodeFavorite(SREpisodeFavoriteMutation(
            episodeID: episode.id,
            feedID: episode.feedID,
            audioURL: episode.audioURL,
            isFavorite: newValue
        )))
    }

    private func enqueueMutation(_ mutation: SRWatchMutation) {
        let change = journal.stage(mutation)
        Task { @MainActor in
            do {
                try await journal.flush()
                if let change, journal.latest(for: change).id == change.id {
                    applyRemoteMutation(journal.latest(for: change).mutation, versioned: true)
                    connectivity.sendChange(change)
                }
            } catch { errorMessage = "Unable to save change: \(error.localizedDescription)" }
        }
    }

    private func flushPendingMutations() {
        let legacy = pendingMutations
        Task { @MainActor in
            do {
                for mutation in legacy { _ = try await journal.record(mutation) }
                pendingMutations.removeAll()
                WatchLibraryPersistence.saveMutations(pendingMutations)
                try await journal.flush()
                for change in journal.pending { connectivity.sendChange(change) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func acknowledgeMutation(_ mutationID: String) {
        pendingMutations.removeAll { $0.id == mutationID }
        WatchLibraryPersistence.saveMutations(pendingMutations)
    }

    private func reapplyPendingMutations() {
        for mutation in pendingMutations {
            switch mutation {
            case .stationFavorite(let value):
                let station = (favoriteStations + recentStations).first {
                    $0.id == value.stationID
                        || normalizedStreamURL($0.streamURL) == normalizedStreamURL(value.streamURL)
                } ?? SRRadioStationRecord(
                    id: value.stationID,
                    name: value.name,
                    streamURL: value.streamURL,
                    artworkURL: value.artworkURL,
                    artworkData: value.artworkData,
                    country: value.country
                )
                if isStationFavorite(station) != value.isFavorite {
                    toggleFavoriteLocally(station, value: value.isFavorite)
                }
            case .episodeProgress(let value):
                let key = episodeStateKey(feedID: value.feedID, episodeID: value.episodeID)
                let existing = episodeStates[key]
                episodeStates[key] = SREpisodeStateRecord(
                    episodeID: value.episodeID,
                    feedID: value.feedID,
                    audioURL: value.audioURL ?? existing?.audioURL,
                    progress: value.progress,
                    isFavorite: existing?.isFavorite ?? false,
                    isPlayed: value.progress >= 0.99,
                    modifiedAt: value.modifiedAt
                )
            case .episodeFavorite(let value):
                let key = episodeStateKey(feedID: value.feedID, episodeID: value.episodeID)
                let existing = episodeStates[key]
                episodeStates[key] = SREpisodeStateRecord(
                    episodeID: value.episodeID,
                    feedID: value.feedID,
                    audioURL: value.audioURL ?? existing?.audioURL,
                    progress: existing?.progress ?? 0,
                    isFavorite: value.isFavorite,
                    isPlayed: existing?.isPlayed ?? false,
                    modifiedAt: value.modifiedAt
                )
            case .stationPlayed:
                break
            }
        }
    }

    private func applyRemoteMutation(_ mutation: SRWatchMutation, versioned: Bool = false, persist: Bool = true) {
        guard versioned || !journal.contains(mutation) else { return }
        switch mutation {
        case .stationFavorite(let value):
            let candidates = deduplicated(favoriteStations + recentStations)
            let station = candidates.first(where: {
                $0.id == value.stationID
                    || normalizedStreamURL($0.streamURL) == normalizedStreamURL(value.streamURL)
            }) ?? SRRadioStationRecord(id: value.stationID, name: value.name,
                streamURL: value.streamURL, artworkURL: value.artworkURL,
                artworkData: value.artworkData, country: value.country)
            if isStationFavorite(station) != value.isFavorite {
                toggleFavoriteLocally(station, value: value.isFavorite, persist: persist)
            }

        case .episodeProgress(let value):
            let key = episodeStates.first(where: {
                $0.value.feedID == value.feedID && value.audioURL != nil && $0.value.audioURL == value.audioURL
            })?.key ?? episodeStateKey(feedID: value.feedID, episodeID: value.episodeID)
            let existing = episodeStates[key]
            guard versioned || existing == nil || value.modifiedAt >= existing!.modifiedAt else { return }
            episodeStates[key] = SREpisodeStateRecord(
                episodeID: existing?.episodeID ?? value.episodeID,
                feedID: value.feedID,
                audioURL: value.audioURL ?? existing?.audioURL,
                progress: value.progress,
                isFavorite: existing?.isFavorite ?? false,
                isPlayed: value.progress >= 0.99,
                modifiedAt: value.modifiedAt,
                positionSeconds: value.positionSeconds,
                durationSeconds: value.durationSeconds
            )
            if persist { persistCurrentSnapshot() }

        case .episodeFavorite(let value):
            let key = episodeStates.first(where: {
                $0.value.feedID == value.feedID && value.audioURL != nil && $0.value.audioURL == value.audioURL
            })?.key ?? episodeStateKey(feedID: value.feedID, episodeID: value.episodeID)
            let existing = episodeStates[key]
            guard versioned || existing == nil || value.modifiedAt >= existing!.modifiedAt else { return }
            episodeStates[key] = SREpisodeStateRecord(
                episodeID: existing?.episodeID ?? value.episodeID,
                feedID: value.feedID,
                audioURL: value.audioURL ?? existing?.audioURL,
                progress: existing?.progress ?? 0,
                isFavorite: value.isFavorite,
                isPlayed: existing?.isPlayed ?? false,
                modifiedAt: value.modifiedAt,
                positionSeconds: existing?.positionSeconds,
                durationSeconds: existing?.durationSeconds
            )
            if persist { persistCurrentSnapshot() }

        case .stationPlayed:
            // Watch-local recents already record the play; this change exists for the iPhone.
            break
        }
    }

    private func toggleFavoriteLocally(_ station: SRRadioStationRecord, value: Bool, persist: Bool = true) {
        var updated = station
        updated.isFavorite = value
        updated.modifiedAt = .now
        updated.favoriteOrder = value ? 0 : nil
        favoriteStations.removeAll {
            normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL)
        }
        if value { favoriteStations.insert(updated, at: 0) }
        recentStations = recentStations.map {
            normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL) ? updated : $0
        }
        if persist { persistCurrentSnapshot() }
    }

    private func mutationScope(_ mutation: SRWatchMutation) -> String {
        switch mutation {
        case .stationFavorite(let value): "station:\(normalizedStreamURL(value.streamURL))"
        case .episodeProgress(let value): "progress:\(value.feedID):\(value.episodeID)"
        case .episodeFavorite(let value): "favorite:\(value.feedID):\(value.episodeID)"
        case .stationPlayed(let value): "played:\(normalizedStreamURL(value.streamURL))"
        }
    }

    private func mergeEpisodeStates(_ states: [SREpisodeStateRecord], persist: Bool = false) {
        for incoming in states {
            let key = episodeStateKey(feedID: incoming.feedID, episodeID: incoming.episodeID)
            if var existing = episodeStates[key] {
                existing.progress = max(existing.progress, incoming.progress)
                existing.isPlayed = existing.isPlayed || incoming.isPlayed
                if incoming.modifiedAt >= existing.modifiedAt {
                    existing.isFavorite = incoming.isFavorite
                    existing.modifiedAt = incoming.modifiedAt
                    existing.audioURL = incoming.audioURL ?? existing.audioURL
                }
                episodeStates[key] = existing
            } else if let audioURL = incoming.audioURL,
                      let existingEntry = episodeStates.first(where: {
                          $0.value.feedID == incoming.feedID && $0.value.audioURL == audioURL
                      }) {
                var existing = existingEntry.value
                existing.progress = max(existing.progress, incoming.progress)
                existing.isPlayed = existing.isPlayed || incoming.isPlayed
                existing.modifiedAt = max(existing.modifiedAt, incoming.modifiedAt)
                episodeStates[existingEntry.key] = existing
            } else {
                episodeStates[key] = incoming
            }
        }
        if persist { persistCurrentSnapshot() }
    }

    private func episodeStateKey(feedID: String, episodeID: String) -> String {
        "\(feedID)\u{1F}\(episodeID)"
    }

    private func normalizedStreamURL(_ value: String) -> String {
        SRWatchMutation.stationIdentity(value)
    }

    private func sortedFavorites(_ stations: [SRRadioStationRecord]) -> [SRRadioStationRecord] {
        stations.sorted {
            let leftOrder = $0.favoriteOrder ?? .max
            let rightOrder = $1.favoriteOrder ?? .max
            return leftOrder == rightOrder
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : leftOrder < rightOrder
        }
    }

    private func applyStations(_ stations: [SRRadioStationRecord]) {
        let incoming = deduplicated(stations)
        let localHistory = localRecentStations.map { station in
            var station = station
            let current = incoming.first {
                normalizedStreamURL($0.streamURL) == normalizedStreamURL(station.streamURL)
            }
            station.isFavorite = current?.isFavorite ?? false
            station.favoriteOrder = current?.favoriteOrder
            return station
        }
        let stations = deduplicated(incoming + localHistory)
        favoriteStations = sortedFavorites(stations.filter(\.isFavorite))
        recentStations = stations
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    private func persistCurrentSnapshot() {
        let snapshot = SRLibrarySnapshot(
            selectedCountryName: selectedCountryName,
            selectedCountryCode: selectedCountryCode,
            stations: deduplicated(favoriteStations + recentStations),
            feeds: podcastFeeds,
            episodeStates: Array(episodeStates.values)
        )
        WatchLibraryPersistence.saveSnapshot(snapshot)
    }

    private func deduplicated(_ stations: [SRRadioStationRecord]) -> [SRRadioStationRecord] {
        var result: [SRRadioStationRecord] = []
        var indexByStreamURL: [String: Int] = [:]

        for station in stations {
            let key = normalizedStreamURL(station.streamURL)
            if let index = indexByStreamURL[key] {
                var existing = result[index]
                existing.isFavorite = existing.isFavorite || station.isFavorite
                existing.favoriteOrder = [existing.favoriteOrder, station.favoriteOrder]
                    .compactMap { $0 }
                    .min()
                existing.lastPlayed = [existing.lastPlayed, station.lastPlayed]
                    .compactMap { $0 }
                    .max()
                existing.artworkData = existing.artworkData ?? station.artworkData
                existing.artworkURL = existing.artworkURL ?? station.artworkURL
                result[index] = existing
            } else {
                indexByStreamURL[key] = result.count
                result.append(station)
            }
        }
        return result
    }

    private func mergeExistingArtwork(from stations: [SRRadioStationRecord]) {
        var artworkByStreamURL: [String: Data] = [:]
        for station in stations {
            let key = normalizedStreamURL(station.streamURL)
            if artworkByStreamURL[key] == nil {
                artworkByStreamURL[key] = station.artworkData
            }
        }
        favoriteStations = favoriteStations.map { station in
            var station = station
            let key = normalizedStreamURL(station.streamURL)
            station.artworkData = station.artworkData ?? artworkByStreamURL[key]
            return station
        }
        recentStations = recentStations.map { station in
            var station = station
            let key = normalizedStreamURL(station.streamURL)
            station.artworkData = station.artworkData ?? artworkByStreamURL[key]
            return station
        }
    }

    private func mergeExistingFeedArtwork(from feeds: [SRPodcastFeedRecord]) {
        let existingByID = Dictionary(feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        podcastFeeds = podcastFeeds.map { feed in
            guard let existing = existingByID[feed.id] else { return feed }
            var merged = feed
            merged.artworkData = merged.artworkData ?? existing.artworkData
            merged.artworkURL = merged.artworkURL ?? existing.artworkURL
            merged.supportsChapters = merged.supportsChapters ?? existing.supportsChapters
            return merged
        }
    }

}

private enum WatchLibraryPersistence {
    private static let writeQueue = DispatchQueue(label: "StreamRadios.watch-library-writes")
    private static let fileName = "watch-library-v1.json"
    private static let mutationsFileName = "watch-mutation-outbox-v1.json"

    static func loadSnapshotData() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    static func saveSnapshotData(_ data: Data) {
        writeQueue.async { writeSnapshotData(data) }
    }

    static func saveSnapshot(_ snapshot: SRLibrarySnapshot) {
        writeQueue.async {
            guard let data = try? SRLibrarySnapshotTransport.encode(snapshot) else { return }
            writeSnapshotData(data)
        }
    }

    private static func writeSnapshotData(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Unable to persist Watch library: \(error.localizedDescription)")
        }
    }

    static func loadMutations() -> [SRWatchMutation] {
        guard let data = try? Data(contentsOf: mutationsFileURL) else { return [] }
        return (try? JSONDecoder().decode([SRWatchMutation].self, from: data)) ?? []
    }

    static func saveMutations(_ mutations: [SRWatchMutation]) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(mutations)
            try data.write(to: mutationsFileURL, options: .atomic)
        } catch {
            print("Unable to persist Watch changes: \(error.localizedDescription)")
        }
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamRadios", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    private static var mutationsFileURL: URL {
        directoryURL.appendingPathComponent(mutationsFileName)
    }
}

private final class WatchLibraryConnectivity: NSObject, WCSessionDelegate {
    var onArtwork: ((SRLibraryArtworkBatch) -> Void)?
    var onSnapshot: ((Data) -> Void)?
    var onBootstrap: ((SRWatchLibraryBootstrap) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onMutationAcknowledged: ((String) -> Void)?
    var onMutation: ((SRWatchMutation) -> Void)?
    var onVersionedChange: ((SRSyncChange) -> Void)?
    var onVersionedAcknowledgement: ((String) -> Void)?
    var onActivated: (() -> Void)?

    func sendChange(_ change: SRSyncChange) {
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(change) else { return }
        let message = [SRSyncJournal.messageKey: data]
        var alreadyQueued = false
        for transfer in session.outstandingUserInfoTransfers {
            guard let payload = transfer.userInfo[SRSyncJournal.messageKey] as? Data,
                  let queued = try? JSONDecoder().decode(SRSyncChange.self, from: payload),
                  queued.mutation.refersToSameField(as: change.mutation) else { continue }
            if queued.revision < change.revision { transfer.cancel() }
            else { alreadyQueued = true }
        }
        if !alreadyQueued { session.transferUserInfo(message) }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    func acknowledge(_ id: String) {
        let session = WCSession.default
        let reply = [SRSyncJournal.acknowledgementKey: id]
        if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo[SRSyncJournal.acknowledgementKey] as? String == id }) {
            session.transferUserInfo(reply)
        }
        if session.isReachable { session.sendMessage(reply, replyHandler: nil, errorHandler: nil) }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        onReachabilityChange?(session.isReachable)

        if let data = session.receivedApplicationContext[
            SRLibrarySnapshotTransport.applicationContextKey
        ] as? Data {
            onSnapshot?(data)
        }
    }

    func requestSnapshot() {
        guard WCSession.isSupported() else { return }
        requestSnapshot(from: WCSession.default)
    }

    func receivedSnapshotData() -> Data? {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return nil }
        return WCSession.default.receivedApplicationContext[SRLibrarySnapshotTransport.applicationContextKey] as? Data
    }

    var isReachableNow: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// Returns false only when WatchConnectivity isn't activated; unreachable requests are queued for delivery.
    func requestSnapshot(onError: @escaping (String) -> Void) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated else { return false }
        guard session.isReachable else {
            queueSnapshotRequest(on: session)
            return true
        }
        session.sendMessage(
            [SRLibrarySnapshotTransport.snapshotRequestKey: true],
            replyHandler: { [weak self] reply in self?.receive(reply) },
            errorHandler: { [weak self] error in
                self?.queueSnapshotRequest(on: session)
                onError(error.localizedDescription)
            }
        )
        return true
    }

    /// Delivered whenever the iPhone next runs (including background launches), unlike sendMessage.
    private func queueSnapshotRequest(on session: WCSession) {
        guard !session.outstandingUserInfoTransfers.contains(where: {
            $0.userInfo[SRLibrarySnapshotTransport.snapshotRequestKey] as? Bool == true
        }) else { return }
        session.transferUserInfo([SRLibrarySnapshotTransport.snapshotRequestKey: true])
    }

    func sendMutation(_ mutation: SRWatchMutation) {
        guard WCSession.isSupported(),
              let data = try? SRLibrarySnapshotTransport.encode(mutation) else { return }
        let session = WCSession.default
        let message = [SRLibrarySnapshotTransport.mutationKey: data]
        session.transferUserInfo(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: { [weak self] reply in
                if let mutationID = reply[SRLibrarySnapshotTransport.mutationAcknowledgementKey] as? String {
                    self?.onMutationAcknowledged?(mutationID)
                }
            }, errorHandler: nil)
        }
    }

    private func receive(_ message: [String: Any]) {
        if let data = message[SRChapterDelivery.messageKey] as? Data,
           let delivery = try? JSONDecoder().decode(SRChapterDelivery.self, from: data) {
            Task { @MainActor in await WatchChapterLoader.receive(delivery) }
            return
        }
        if let id = message[SRSyncJournal.acknowledgementKey] as? String { onVersionedAcknowledgement?(id) }
        if let data = message[SRSyncJournal.messageKey] as? Data,
           let change = try? JSONDecoder().decode(SRSyncChange.self, from: data) {
            onVersionedChange?(change)
        }
        if let mutationID = message[
            SRLibrarySnapshotTransport.mutationAcknowledgementKey
        ] as? String {
            onMutationAcknowledged?(mutationID)
        }
        if let data = message[SRLibrarySnapshotTransport.mutationKey] as? Data,
           let mutation = try? SRLibrarySnapshotTransport.decodeMutation(data) {
            onMutation?(mutation)
        }
        guard let data = message[SRLibrarySnapshotTransport.applicationContextKey] as? Data else {
            return
        }
        onSnapshot?(data)
    }

    private func requestSnapshot(from session: WCSession) {
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            queueSnapshotRequest(on: session)
            return
        }
        session.sendMessage(
            [SRLibrarySnapshotTransport.snapshotRequestKey: true],
            replyHandler: { [weak self] reply in
                self?.receive(reply)
            },
            errorHandler: { [weak self] _ in self?.queueSnapshotRequest(on: session) }
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated { onActivated?() }
        onReachabilityChange?(session.isReachable)
        if let data = session.receivedApplicationContext[
            SRLibrarySnapshotTransport.applicationContextKey
        ] as? Data {
            onSnapshot?(data)
        }
        requestSnapshot(from: session)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if file.metadata?[SRLibraryArtworkBatch.fileKey] as? Bool == true {
            guard let data = try? Data(contentsOf: file.fileURL),
                  let batch = try? JSONDecoder().decode(SRLibraryArtworkBatch.self, from: data) else { return }
            onArtwork?(batch)
            return
        }
        guard file.metadata?[SRLibrarySnapshotTransport.bootstrapFileKey] as? Bool == true,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        if let bootstrap = try? SRLibrarySnapshotTransport.decodeBootstrap(data) {
            onBootstrap?(bootstrap)
        } else {
            onSnapshot?(data)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachabilityChange?(session.isReachable)
    }
}