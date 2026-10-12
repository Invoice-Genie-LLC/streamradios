//
// RadioStreamApp.swift
// RadioStreamApp
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import WidgetKit
import UIKit
import MusicKit
import AVFoundation
import Combine
import CoreData
import StreamRadiosCore
import WatchConnectivity

@main
struct RadioStreamApp: App {
    // Declared first: load the Core Data store on the main thread before singletons spawn background work,
    // so no thread ever waits on a lower-QoS store load (priority inversion).
    private let coreDataWarmUp: Void = { _ = CoreDataStack.shared.persistentContainer }()
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var alertManager = AlertManager()
    @StateObject private var podcastViewModel = PodcastViewModel.shared
    @StateObject private var episodeStateManager = EpisodeStateManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel.shared
    private let watchSync = PhoneWatchSyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PermissionManager())
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel.shared)
                .environmentObject(notificationManager)
                .environmentObject(alertManager)
                .environmentObject(podcastViewModel)
                .environmentObject(podcastPlayer)
                .environmentObject(subscriptionManager)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onContinueUserActivity(SRSupportContact.handoffActivityType) { _ in
                    SupportEmailHandoff.openComposer()
                }
                .onAppear {
                    setupApp()
                    watchSync.activate()
                    watchSync.publish(stations: viewModel.stations, feeds: podcastViewModel.podcastFeeds)
                    // Configure podcast player immediately - PodcastViewModel is already initialized
                    PodcastPlayer.shared.configure(with: podcastViewModel)
                    // CarPlay is now configured via CarPlaySceneDelegate
                    
                    // Clear notifications and badge when app launches
                    NotificationManager.shared.clearAllNotificationsAndBadge()
                    
                    // Check for incomplete syncs on app startup
                    Task { @MainActor in
                        DataSyncManager.shared.checkAndResumeRadioStationSync()
                    }
                    
                    // Warm every feed now so opening one already shows the newest episodes
                    Task { @MainActor in
                        // Must finish first, or the refresh re-inserts legacy IDs as duplicates.
                        await PodcastCoreDataManager.shared.migrateUnstableEpisodeIDs()
                        await podcastViewModel.prefetchNewEpisodesForAllFeeds()
                    }
                    
                    // Initialize comprehensive debug logging system
                    // DebugLogger.logInfo will be added when import is fixed
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    watchSync.publish(stations: viewModel.stations, feeds: podcastViewModel.podcastFeeds)
                    // CRITICAL FIX: Only reconfigure if podcast player doesn't already have an active episode
                    // This prevents progress reset when returning from lock screen with current episode
                    
                    if PodcastPlayer.shared.currentEpisode == nil {
                        PodcastPlayer.shared.configure(with: podcastViewModel)
                    }
                    
                    Task { @MainActor in
                        await podcastViewModel.prefetchNewEpisodesForAllFeeds()
                    }
                }
                .onReceive(viewModel.$stations.debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { stations in
                    watchSync.publish(stations: stations, feeds: podcastViewModel.podcastFeeds)
                }
                .onReceive(podcastViewModel.$podcastFeeds.debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { feeds in
                    watchSync.publish(stations: viewModel.stations, feeds: feeds)
                }
                .onReceive(podcastViewModel.$podcastFeedOrder.removeDuplicates().debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
                    watchSync.publish(stations: viewModel.stations, feeds: podcastViewModel.podcastFeeds)
                }
                .onReceive(subscriptionManager.$subscriptionStatus.removeDuplicates().debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
                    // The Watch gates playback on this status, so push it as soon as it resolves or changes.
                    watchSync.publish(stations: viewModel.stations, feeds: podcastViewModel.podcastFeeds, force: true)
                }
                .onDisappear {
                            appDelegate.updatePodcastStateAndSave()
                            podcastViewModel.saveContextIfNeeded()
                        }
        }
    }

    private func setupApp() {
        
        // Audio session configuration is handled by PlaybackManager to prevent conflicts
        // This ensures centralized management and proper retry logic
        
        // Set up the remote command center
        radioPlayer.setupRemoteCommandCenter()

        // Set the ViewModel for RadioPlayer
        radioPlayer.setViewModel(viewModel)
        
        // Handle initial dark mode setup
        if !UserDefaults.standard.bool(forKey: "isDarkModeSet") {
            UserDefaults.standard.set(true, forKey: "isDarkMode")
            UserDefaults.standard.set(true, forKey: "isDarkModeSet")
        }
                
        if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
            notificationManager.requestAuthorization()
            UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
        }
        
        // Request Apple Music authorization for station artwork search
        Task {
            await MusicAuthorizationManager.shared.requestAuthorization()
            print("🎵 Apple Music authorization requested for artwork search")
        }
        
        // PERFORMANCE FIX: Check for radio station sync status instead of empty stations
        // This prevents CloudKit fetching on every app launch after initial sync
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
        
        if isFreshInstall || !hasRadioStationsSynced {
            // NOTE: Radio station sync is now handled by DataSyncManager in sequence to prevent CloudKit rate limiting
        } else {
            // RadioStationViewModel already loaded stations in its init, no need to reload
            // Setup auto-play functionality with proper setting checks
            radioPlayer.autoPlayLastStationSetup()
        }
        
        // Initialize podcast system with CloudKit support
        podcastViewModel.initializeWithCloudKitSupport()
        
        // Initialize subscription system - this will load products and check subscription status
        Task {
            await subscriptionManager.initialize()
        }
    }

    private func fetchStationsFromCloudKit() {
        DataStore.shared.fetchRadioStations { [weak viewModel] stations, error in
            if let stations = stations {
                DispatchQueue.main.async {
                    viewModel?.stations = stations
                    viewModel?.saveStationsToCoreData()
                    print("Fetched and populated \(stations.count) stations from CloudKit.")
                    
                    // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                    UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                    
                    // Notify that stations have been updated
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    
                    // After loading stations from CloudKit, setup auto-play with proper setting checks
                    RadioPlayer.shared.autoPlayLastStationSetup()
                }
            } else if let error = error {
                print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
            }
            // CRITICAL FIX: Do NOT set HasLaunchedBefore here!
            // This flag should ONLY be set by DataSyncManager AFTER fresh install sync completes
        }
    }
}

final class PhoneWatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSyncManager()

    private let syncQueue = DispatchQueue(label: "com.radio.streamradios.watch-sync")
    private let artworkCache = NSCache<NSString, NSData>()
    private var pendingSnapshotData: Data?
    private var bootstrapFileURLs: [URL] = []
    private var lastEpisodeProgress: [String: Double]?
    private var lastEpisodeFavorites: [String: Bool]?
    private var lastPlayedEpisodeKeys: Set<String>?
    @MainActor private var lastStationFavorites: [String: SRRadioStationRecord] = [:]
    @MainActor private var replayedJournal = false
    @MainActor private var lastPublishedSnapshotKey: Data?
    @MainActor private var watchProgressCloudSyncTasks: [String: Task<Void, Never>] = [:]
    @MainActor private var watchProgressCloudSyncDates: [String: Date] = [:]
    @MainActor private var lastQueuedArtwork: SRLibraryArtworkBatch?
    @MainActor private var chapterFetches: [String: Task<[SRPodcastChapterRecord], Never>] = [:]
    @MainActor private var chapterResults: [String: [SRPodcastChapterRecord]] = [:]
    @MainActor private lazy var journal = SRSyncJournal(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamRadios/phone-watch-sync-journal.json")
    )

    func activate() {
        guard WCSession.isSupported() else { return }
        if episodeStateSubscriptions.isEmpty { observeEpisodeStates() }
        let session = WCSession.default
        guard session.delegate !== self || session.activationState == .notActivated else { return }
        session.delegate = self
        session.activate()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FreshInstallSyncCompleted"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverLibraryAfterPhoneSync() }
        }
    }

    @MainActor private var pendingLibraryRequest = false
    // Owned here, not by the SwiftUI scene: CarPlay-only and Watch background launches have no phone UI.
    private var episodeStateSubscriptions = Set<AnyCancellable>()

    private func observeEpisodeStates() {
        let states = EpisodeStateManager.shared
        states.$episodeProgress
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishEpisodeProgressChanges(states.episodeProgress) }
            }
            .store(in: &episodeStateSubscriptions)
        states.$episodeFavorites
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishEpisodeFavoriteChanges(states.episodeFavorites) }
            }
            .store(in: &episodeStateSubscriptions)
        states.$episodeStates
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishEpisodePlayedChanges(states.episodeStates) }
            }
            .store(in: &episodeStateSubscriptions)
    }

    /// During the iPhone's own first sync it only has built-in stations; a snapshot then would complete a
    /// fresh Watch's first sync with an empty library.
    @MainActor private var hasLibraryData: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "HasLaunchedBefore"), defaults.bool(forKey: "DataSyncCompleted") else { return false }
        let stations = RadioStationViewModel.shared.stations
        let feeds = PodcastViewModel.shared.podcastFeeds
        guard !stations.isEmpty || !feeds.isEmpty else { return false }
        // Each view model loads asynchronously; an empty list with rows on disk means "not loaded yet",
        // and the Watch replaces its whole list with whatever we send.
        let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        let stationRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        if feeds.isEmpty, !Self.isStoreEmpty(feedRequest) { return false }
        if stations.isEmpty, !Self.isStoreEmpty(stationRequest) { return false }
        return true
    }

    @MainActor
    private static func isStoreEmpty<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>) -> Bool {
        ((try? CoreDataStack.shared.context.count(for: request)) ?? 1) == 0
    }

    @MainActor
    private func deliverLibraryAfterPhoneSync() {
        guard hasLibraryData, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if pendingLibraryRequest {
            pendingLibraryRequest = false
            sendFullLibrary(using: WCSession.default)
        } else {
            publish(stations: RadioStationViewModel.shared.stations, feeds: PodcastViewModel.shared.podcastFeeds, force: true)
        }
    }

    /// After a background launch the view models are still loading from Core Data.
    @MainActor
    private func waitForLibrary(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasLibraryData, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return hasLibraryData
    }

    @MainActor
    private func sendFullLibrary(using session: WCSession, reply: (([String: Any]) -> Void)? = nil) {
        lastQueuedArtwork = nil
        let bootstrap = makeBootstrap(
            stations: RadioStationViewModel.shared.stations,
            feeds: PodcastViewModel.shared.podcastFeeds
        )
        guard let snapshotData = try? SRLibrarySnapshotTransport.encode(bootstrap.snapshot),
              let bootstrapData = try? SRLibrarySnapshotTransport.encode(bootstrap) else {
            reply?([:])
            return
        }
        reply?(snapshotData.count <= 55_000 ? [SRLibrarySnapshotTransport.applicationContextKey: snapshotData] : [:])
        syncQueue.async { self.transferBootstrapFile(bootstrapData, using: session) }
        publish(stations: RadioStationViewModel.shared.stations, feeds: PodcastViewModel.shared.podcastFeeds, force: true)
    }

    @MainActor
    private func answerLibraryRequest(using session: WCSession, reply: (([String: Any]) -> Void)? = nil) {
        Task { @MainActor in
            if await waitForLibrary(timeout: 5) {
                sendFullLibrary(using: session, reply: reply)
                return
            }
            // Reply now so the Watch isn't left waiting, then deliver once loading or the first sync finishes.
            reply?([:])
            if await waitForLibrary(timeout: 25) {
                sendFullLibrary(using: session)
            } else {
                pendingLibraryRequest = true
            }
        }
    }

    @MainActor
    func publish(stations: [RadioStation], feeds: [PodcastFeed], force: Bool = false) {
        // An empty snapshot from a still-loading launch would complete a fresh Watch's first sync with nothing.
        guard hasLibraryData else { return }
        if pendingLibraryRequest, WCSession.default.activationState == .activated {
            pendingLibraryRequest = false
            sendFullLibrary(using: WCSession.default)
            return
        }
        if !replayedJournal, !feeds.isEmpty || !stations.isEmpty {
            replayedJournal = true
            applyPendingJournalChanges()
            Task { @MainActor in
                do { try await journal.flush() }
                catch { print("[PhoneWatchSync] replay persistence failed: \(error)") }
            }
        }
        publishEpisodeProgressChanges(EpisodeStateManager.shared.episodeProgress)
        publishEpisodeFavoriteChanges(EpisodeStateManager.shared.episodeFavorites)
        publishStationChanges(RadioStationViewModel.shared.stations)
        var snapshot = makeSnapshot(
            stations: RadioStationViewModel.shared.stations,
            feeds: feeds,
            includeEpisodeStates: false
        )
        publishArtwork(stations: RadioStationViewModel.shared.stations, feeds: feeds, snapshot: snapshot)

        // Episode-state edits also change `podcastFeeds`; don't resend an identical library for them.
        var keySnapshot = snapshot
        keySnapshot.generatedAt = .distantPast
        let keyEncoder = JSONEncoder()
        keyEncoder.outputFormatting = .sortedKeys
        let snapshotKey = try? keyEncoder.encode(keySnapshot)
        if !force, snapshotKey != nil, snapshotKey == lastPublishedSnapshotKey { return }
        lastPublishedSnapshotKey = snapshotKey

        guard var data = try? SRLibrarySnapshotTransport.encode(snapshot) else { return }
        if data.count > 55_000 {
            snapshot.stations = snapshot.stations.map { var value = $0; value.artworkData = nil; return value }
            snapshot.feeds = snapshot.feeds.map { var value = $0; value.artworkData = nil; return value }
            guard let compact = try? SRLibrarySnapshotTransport.encode(snapshot) else { return }
            data = compact
        }
        if data.count > 55_000 {
            let bootstrap = SRWatchLibraryBootstrap(snapshot: snapshot)
            if let fileData = try? SRLibrarySnapshotTransport.encode(bootstrap) {
                syncQueue.async { self.transferBootstrapFile(fileData, using: WCSession.default) }
            }
            return
        }
        syncQueue.async { [weak self] in
            self?.pendingSnapshotData = data
            self?.sendPendingSnapshot()
        }
    }

    @MainActor
    func publishEpisodeProgressChanges(_ values: [String: Double]) {
        guard replayedJournal, isEpisodeStateSettled else { return }
        let previous = lastEpisodeProgress ?? [:]
        lastEpisodeProgress = values
        for key in Set(previous.keys).union(values.keys) {
            let progress = values[key] ?? 0
            guard previous[key] != progress,
                  let identity = episodeIdentity(from: key) else { continue }
            sendMutationToWatch(.episodeProgress(SREpisodeProgressMutation(
                episodeID: identity.episodeID,
                feedID: identity.feedID,
                audioURL: episodeAudioURL(episodeID: identity.episodeID, feedID: identity.feedID),
                progress: progress
            )))
        }
    }

    @MainActor
    func publishEpisodePlayedChanges(_ states: [String: EpisodePlaybackState]) {
        guard replayedJournal, isEpisodeStateSettled else { return }
        let played = Set(states.compactMap { $0.value == .played ? $0.key : nil })
        // First pass only records a baseline; the bootstrap snapshot already carries existing played states.
        guard let previous = lastPlayedEpisodeKeys else {
            lastPlayedEpisodeKeys = played
            return
        }
        lastPlayedEpisodeKeys = played
        // Marking played/unplayed can leave saved progress unchanged, so send it as progress explicitly.
        for key in played.symmetricDifference(previous) {
            guard let identity = episodeIdentity(from: key) else { continue }
            let saved = EpisodeStateManager.shared.episodeProgress[key] ?? 0
            let progress = played.contains(key) ? 1.0 : (saved >= 0.99 ? 0 : saved)
            sendMutationToWatch(.episodeProgress(SREpisodeProgressMutation(
                episodeID: identity.episodeID,
                feedID: identity.feedID,
                audioURL: episodeAudioURL(episodeID: identity.episodeID, feedID: identity.feedID),
                progress: progress
            )))
        }
    }

    @MainActor
    func publishEpisodeFavoriteChanges(_ values: [String: Bool]) {
        guard replayedJournal, isEpisodeStateSettled else { return }
        let previous = lastEpisodeFavorites ?? [:]
        lastEpisodeFavorites = values
        for key in Set(previous.keys).union(values.keys) {
            let isFavorite = values[key] ?? false
            guard previous[key] != isFavorite,
                  let identity = episodeIdentity(from: key) else { continue }
            sendMutationToWatch(.episodeFavorite(SREpisodeFavoriteMutation(
                episodeID: identity.episodeID,
                feedID: identity.feedID,
                audioURL: episodeAudioURL(episodeID: identity.episodeID, feedID: identity.feedID),
                isFavorite: isFavorite
            )))
        }
    }

    private func episodeIdentity(from key: String) -> (feedID: String, episodeID: String)? {
        let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    @MainActor
    private func sendMutationToWatch(_ mutation: SRWatchMutation) {
        let change = journal.stage(mutation)
        Task { @MainActor in
            do {
                try await journal.flush()
                if let change, journal.latest(for: change).id == change.id { sendChange(change) }
            } catch { print("[PhoneWatchSync] persist failed: \(error)") }
        }
    }

    /// The debounced publisher never fires during `willTerminate`; transferUserInfo is delivered after we exit.
    @MainActor
    func sendEpisodeProgressBeforeTermination(episodeID: String, feedID: String, progress: Double) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        lastEpisodeProgress?["\(feedID)\u{1F}\(episodeID)"] = progress
        guard let change = journal.stage(.episodeProgress(SREpisodeProgressMutation(
            episodeID: episodeID,
            feedID: feedID,
            audioURL: episodeAudioURL(episodeID: episodeID, feedID: feedID),
            progress: progress
        ))), let data = try? JSONEncoder().encode(change) else { return }
        journal.flushSynchronously()
        WCSession.default.transferUserInfo([SRSyncJournal.messageKey: data])
    }

    private func sendChange(_ change: SRSyncChange) {
        guard let data = try? JSONEncoder().encode(change) else { return }
        syncQueue.async {
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let message = [SRSyncJournal.messageKey: data]
            var queued = false
            for transfer in session.outstandingUserInfoTransfers {
                guard let payload = transfer.userInfo[SRSyncJournal.messageKey] as? Data,
                    let existing = try? JSONDecoder().decode(SRSyncChange.self, from: payload),
                    existing.mutation.refersToSameField(as: change.mutation) else { continue }
                if existing.revision < change.revision { transfer.cancel() }
                else { queued = true }
            }
            if !queued { session.transferUserInfo(message) }
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    @MainActor
    private func episodeAudioURL(episodeID: String, feedID: String) -> String? {
        PodcastViewModel.shared.podcastFeeds.first { $0.id == feedID }?
            .episodes.first { $0.id == episodeID }?.audioUrl
    }

    @MainActor
    private func publishStationChanges(_ stations: [RadioStation]) {
        var current: [String: SRRadioStationRecord] = [:]
        for station in stations {
            let key = SRWatchMutation.stationIdentity(station.url)
            let record = SRRadioStationRecord(id: station.id, name: station.name,
                streamURL: station.url, country: station.country, isFavorite: station.isFavorite)
            current[key] = record
            if lastStationFavorites[key]?.isFavorite != station.isFavorite,
               station.isFavorite || lastStationFavorites[key]?.isFavorite == true {
                sendMutationToWatch(.stationFavorite(SRStationFavoriteMutation(
                    stationID: station.id, streamURL: station.url, name: station.name,
                    country: station.country, isFavorite: station.isFavorite)))
            }
        }
        for (key, station) in lastStationFavorites where current[key] == nil && station.isFavorite {
            sendMutationToWatch(.stationFavorite(SRStationFavoriteMutation(
                stationID: station.id, streamURL: station.streamURL, name: station.name,
                country: station.country, isFavorite: false)))
        }
        lastStationFavorites = current
    }

    @MainActor
    private func makeSnapshot(
        stations: [RadioStation],
        feeds: [PodcastFeed],
        includeEpisodeStates: Bool
    ) -> SRLibrarySnapshot {
        let favorites = stations.filter(\.isFavorite).sorted(by: RadioStationViewModel.favoriteSortPrecedes)
        // Explicit positions so the Watch can't tie-break differently from the phone.
        let favoritePositions = Dictionary(
            favorites.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let feedOrder = PodcastViewModel.shared.podcastFeedOrder
        let feedPositions = Dictionary(
            (feedOrder.isEmpty ? feeds.map(\.id) : feedOrder).enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let recents = stations
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(25)
        var seenStreamURLs = Set<String>()
        let watchStations = (Array(recents) + favorites).filter { station in
            let key = SRWatchMutation.stationIdentity(station.url)
            return seenStreamURLs.insert(key).inserted
        }
        let selectedCountryName = RadioStationViewModel.shared.selectedCountry
        let selectedCountryCode = RadioStationViewModel.shared.countries.first {
            $0.name == selectedCountryName
        }?.apiCountryCode
        var remainingStationArtworkBytes = 32 * 1_024
        var remainingFeedArtworkBytes = 16 * 1_024

        return SRLibrarySnapshot(
            selectedCountryName: selectedCountryName,
            selectedCountryCode: selectedCountryCode,
            stations: watchStations.map { station in
                let candidateArtwork = remainingStationArtworkBytes > 0
                    ? watchArtworkData(for: station)
                    : nil
                let artworkData: Data?
                if let candidateArtwork, candidateArtwork.count <= remainingStationArtworkBytes {
                    artworkData = candidateArtwork
                    remainingStationArtworkBytes -= candidateArtwork.count
                } else {
                    artworkData = nil
                }
                return SRRadioStationRecord(
                    id: station.id,
                    name: station.name,
                    streamURL: station.url,
                    artworkData: artworkData,
                    country: station.country,
                    isFavorite: station.isFavorite,
                    favoriteOrder: station.isFavorite ? favoritePositions[station.id] : nil,
                    lastPlayed: station.lastPlayed,
                    modifiedAt: station.favoritedAt ?? .now
                )
            },
            feeds: feeds.map { feed in
                let candidateArtwork = remainingFeedArtworkBytes > 0
                    ? watchArtworkData(for: feed)
                    : nil
                let artworkData: Data?
                if let candidateArtwork, candidateArtwork.count <= remainingFeedArtworkBytes {
                    artworkData = candidateArtwork
                    remainingFeedArtworkBytes -= candidateArtwork.count
                } else {
                    artworkData = nil
                }
                return SRPodcastFeedRecord(
                    id: feed.id,
                    title: feed.title,
                    feedURL: feed.url,
                    artworkURL: feed.artworkUrl,
                    artworkData: artworkData,
                    descriptionText: nil,
                    supportsChapters: feed.episodes.contains {
                        $0.chapters?.isEmpty == false
                    },
                    order: feedPositions[feed.id] ?? feedPositions.count + feed.order
                )
            },
            episodeStates: includeEpisodeStates ? makeEpisodeStates(feeds: feeds) : [],
            syncChanges: includeEpisodeStates ? journal.changes : nil,
            isEntitled: SubscriptionManager.entitlementSnapshot.isResolved
                ? SubscriptionManager.entitlementSnapshot.isEntitled
                : nil
        )
    }

    @MainActor
    private func makeBootstrap(
        stations: [RadioStation],
        feeds: [PodcastFeed]
    ) -> SRWatchLibraryBootstrap {
        var episodes: [SRPodcastEpisodeRecord] = []
        let sortedFeeds = feeds.sorted(by: { $0.order < $1.order })
        for feed in sortedFeeds where episodes.count < 400 {
            episodes.append(contentsOf: feed.episodes
                .filter { !$0.audioUrl.isEmpty }
                .sorted {
                    let states = EpisodeStateManager.shared
                    let leftProgress = states.getProgress(for: $0.id, feedId: feed.id)
                    let rightProgress = states.getProgress(for: $1.id, feedId: feed.id)
                    let leftPriority = states.isFavorite($0.id, feedId: feed.id) || (leftProgress > 0 && leftProgress < 0.99)
                    let rightPriority = states.isFavorite($1.id, feedId: feed.id) || (rightProgress > 0 && rightProgress < 0.99)
                    return leftPriority == rightPriority ? $0.publicationDate > $1.publicationDate : leftPriority
                }
                .prefix(min(3, 400 - episodes.count))
                .map { episode in
                    SRPodcastEpisodeRecord(
                        id: episode.id,
                        feedID: feed.id,
                        title: episode.title,
                        descriptionText: String(
                            (episode.notes?.content ?? episode.descriptionText).prefix(4_000)
                        ),
                        audioURL: episode.audioUrl,
                        publicationDate: episode.publicationDate,
                        duration: episode.duration,
                        chapters: episode.chapters?.map {
                            SRPodcastChapterRecord(
                                title: $0.title,
                                startTime: $0.startTime
                            )
                        }
                    )
                })
        }
        for feed in sortedFeeds where episodes.count < 400 {
            let remainingCapacity = min(7, 400 - episodes.count)
            let included = Set(episodes.filter { $0.feedID == feed.id }.map(\.id))
            episodes.append(contentsOf: feed.episodes
                .filter { !$0.audioUrl.isEmpty && !included.contains($0.id) }
                .sorted { $0.publicationDate > $1.publicationDate }
                .prefix(remainingCapacity)
                .map { episode in
                    SRPodcastEpisodeRecord(
                        id: episode.id,
                        feedID: feed.id,
                        title: episode.title,
                        descriptionText: String(
                            (episode.notes?.content ?? episode.descriptionText).prefix(4_000)
                        ),
                        audioURL: episode.audioUrl,
                        publicationDate: episode.publicationDate,
                        duration: episode.duration,
                        chapters: episode.chapters?.map {
                            SRPodcastChapterRecord(
                                title: $0.title,
                                startTime: $0.startTime
                            )
                        }
                    )
                })
        }
        return SRWatchLibraryBootstrap(
            snapshot: makeSnapshot(
                stations: stations,
                feeds: feeds,
                includeEpisodeStates: true
            ),
            episodes: episodes
        )
    }

    private func watchArtworkData(for station: RadioStation) -> Data? {
        for encoded in [station.iTunesArtworkData, station.iconData].compactMap({ $0 }) {
            guard let sourceData = Data(base64Encoded: encoded), !sourceData.isEmpty else { continue }
            let cacheKey = "\(station.id)-\(encoded.hashValue)" as NSString
            if let thumbnail = watchArtworkData(sourceData: sourceData, cacheKey: cacheKey) { return thumbnail }
        }
        return nil
    }

    private func watchArtworkData(for feed: PodcastFeed) -> Data? {
        for sourceData in [feed.imageData, feed.iconData.flatMap { Data(base64Encoded: $0) }].compactMap({ $0 }) {
            if let thumbnail = watchArtworkData(sourceData: sourceData,
                cacheKey: "feed-\(feed.id)-\(sourceData.hashValue)" as NSString) { return thumbnail }
        }
        return nil
    }

    @MainActor
    private func publishArtwork(stations: [RadioStation], feeds: [PodcastFeed], snapshot: SRLibrarySnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let selected = Set(snapshot.stations.map { SRWatchMutation.stationIdentity($0.streamURL) })
        var artwork = SRLibraryArtworkBatch()
        for station in stations {
            let key = SRWatchMutation.stationIdentity(station.url)
            if selected.contains(key), let data = watchArtworkData(for: station) { artwork.stations[key] = data }
        }
        for feed in feeds {
            if let data = watchArtworkData(for: feed) { artwork.feeds[feed.id] = data }
        }
        guard artwork.stations != lastQueuedArtwork?.stations || artwork.feeds != lastQueuedArtwork?.feeds else { return }
        lastQueuedArtwork = artwork
        let pendingArtwork = artwork
        syncQueue.async {
            for batch in pendingArtwork.batches() {
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("streamradios-artwork-\(UUID().uuidString).json")
                do {
                    try JSONEncoder().encode(batch).write(to: fileURL, options: .atomic)
                    self.bootstrapFileURLs.append(fileURL)
                    WCSession.default.transferFile(fileURL, metadata: [SRLibraryArtworkBatch.fileKey: true])
                    print("[PhoneWatchArtwork] queued stations=\(batch.stations.count) feeds=\(batch.feeds.count)")
                } catch {
                    print("[PhoneWatchArtwork] transfer creation failed: \(error)")
                    Task { @MainActor in self.lastQueuedArtwork = nil }
                }
            }
        }
    }

    private func watchArtworkData(sourceData: Data, cacheKey: NSString) -> Data? {
        let maximumBytes = 8 * 1_024
        if let cached = artworkCache.object(forKey: cacheKey), cached.length <= maximumBytes {
            return cached as Data
        }
        guard let sourceImage = UIImage(data: sourceData) else { return nil }

        for (dimension, quality) in [(72.0, 0.58), (56.0, 0.48), (44.0, 0.38)] {
            let size = CGSize(width: dimension, height: dimension)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIColor.black.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
                sourceImage.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = image.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                artworkCache.setObject(data as NSData, forKey: cacheKey)
                return data
            }
        }
        return nil
    }

    private func makeEpisodeStates(feeds: [PodcastFeed]) -> [SREpisodeStateRecord] {
        let stateManager = EpisodeStateManager.shared
        var audioURLs: [String: String] = [:]
        for feed in feeds {
            for episode in feed.episodes where !episode.audioUrl.isEmpty {
                audioURLs["\(feed.id)\u{1F}\(episode.id)"] = episode.audioUrl
            }
        }
        let keys = Set(stateManager.episodeProgress.keys)
            .union(stateManager.episodeFavorites.keys)
            .union(stateManager.episodeStates.keys)
        return keys.compactMap { key in
            guard let identity = episodeIdentity(from: key) else { return nil }
            let progress = stateManager.episodeProgress[key] ?? 0
            let isFavorite = stateManager.episodeFavorites[key] ?? false
            let isPlayed = stateManager.episodeStates[key] == .played || progress >= 0.99
            guard progress > 0 || isFavorite || isPlayed else { return nil }
            // The Watch keys guid-less episodes by audio URL, so it needs the URL to match them.
            return SREpisodeStateRecord(
                episodeID: identity.episodeID,
                feedID: identity.feedID,
                audioURL: audioURLs[key],
                progress: isPlayed ? max(progress, 1.0) : progress,
                isFavorite: isFavorite,
                isPlayed: isPlayed
            )
        }
    }

    private func sendPendingSnapshot() {
        guard let data = pendingSnapshotData, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let context = [SRLibrarySnapshotTransport.applicationContextKey: data]
        do {
            try session.updateApplicationContext(context)
            pendingSnapshotData = nil
        } catch {
            print("Watch favorites sync failed: \(error.localizedDescription)")
        }

        if session.isReachable {
            session.sendMessage(context, replyHandler: nil) { error in
                print("Immediate Watch favorites sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func transferBootstrapFile(_ data: Data, using session: WCSession) {
        guard session.activationState == .activated else { return }
        guard let bootstrap = try? SRLibrarySnapshotTransport.decodeBootstrap(data) else { return }
        var base = bootstrap.snapshot
        base.episodeStates = []
        base.syncChanges = []
        var chunk = SRWatchLibraryBootstrap(snapshot: base)
        func flush() {
            guard let payload = try? SRLibrarySnapshotTransport.encode(chunk) else { return }
            transferBootstrapChunk(payload, using: session)
            chunk = SRWatchLibraryBootstrap(snapshot: base)
        }
        for state in bootstrap.snapshot.episodeStates {
            chunk.snapshot.episodeStates.append(state)
            if (try? SRLibrarySnapshotTransport.encode(chunk).count) ?? 0 > 240_000 { flush() }
        }
        for change in bootstrap.snapshot.syncChanges ?? [] {
            chunk.snapshot.syncChanges?.append(change)
            if (try? SRLibrarySnapshotTransport.encode(chunk).count) ?? 0 > 240_000 { flush() }
        }
        for episode in bootstrap.episodes {
            chunk.episodes.append(episode)
            if (try? SRLibrarySnapshotTransport.encode(chunk).count) ?? 0 > 240_000 { flush() }
        }
        flush()
    }

    private func transferBootstrapChunk(_ data: Data, using session: WCSession) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamradios-watch-\(UUID().uuidString).json")
        do {
            try data.write(to: fileURL, options: .atomic)
            bootstrapFileURLs.append(fileURL)
            session.transferFile(
                fileURL,
                metadata: [SRLibrarySnapshotTransport.bootstrapFileKey: true]
            )
        } catch {
            print("Watch bootstrap file creation failed: \(error.localizedDescription)")
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            Task { @MainActor in
                for change in journal.pending { sendChange(change) }
                if await waitForLibrary(timeout: 25) {
                    publish(stations: RadioStationViewModel.shared.stations, feeds: PodcastViewModel.shared.podcastFeeds, force: true)
                }
            }
        }
        syncQueue.async { [weak self] in
            self?.sendPendingSnapshot()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        if error != nil, fileTransfer.file.metadata?[SRLibraryArtworkBatch.fileKey] as? Bool == true {
            Task { @MainActor in self.lastQueuedArtwork = nil }
        }
        syncQueue.async { [weak self] in
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            self?.bootstrapFileURLs.removeAll { $0 == fileTransfer.file.fileURL }
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if receiveMutation(message, session: session) { return }
        if receiveEpisodeState(message) { return }
        guard message[SRLibrarySnapshotTransport.snapshotRequestKey] as? Bool == true else { return }
        DispatchQueue.main.async {
            self.answerLibraryRequest(using: session)
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if let data = message[SRChapterRequest.messageKey] as? Data,
           let request = try? JSONDecoder().decode(SRChapterRequest.self, from: data) {
            let deferred = message[SRChapterDelivery.deferredRequestKey] as? Bool == true
            if deferred { replyHandler([SRChapterDelivery.deferredRequestKey: true]) }
            Task { @MainActor in
                let started = Date()
                print("[PhoneWatchChapters] request episode=\(request.episodeID)")
                let chapters = await requestedChapters(for: request)
                guard !chapters.isEmpty, let payload = try? JSONEncoder().encode(chapters),
                      payload.count <= 55_000 else {
                                        print("[PhoneWatchChapters] no usable chapters elapsed=\(Date().timeIntervalSince(started))")
                    if !deferred { replyHandler([:]) }
                    return
                }
                                print("[PhoneWatchChapters] reply chapters=\(chapters.count) elapsed=\(Date().timeIntervalSince(started))")
                if deferred {
                    let delivery = SRChapterDelivery(request: request, chapters: chapters)
                    guard let data = try? JSONEncoder().encode(delivery), data.count <= 60_000 else { return }
                    let message: [String: Any] = [SRChapterDelivery.messageKey: data]
                    for transfer in session.outstandingUserInfoTransfers {
                        guard let previous = transfer.userInfo[SRChapterDelivery.messageKey] as? Data,
                              let queued = try? JSONDecoder().decode(SRChapterDelivery.self, from: previous),
                              queued.matches(request) else { continue }
                        transfer.cancel()
                    }
                    session.transferUserInfo(message)
                    if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
                } else {
                    replyHandler([SRChapterRequest.responseKey: payload])
                }
            }
            return
        }
        if let data = message[SRLibrarySnapshotTransport.mutationKey] as? Data,
           let mutation = try? SRLibrarySnapshotTransport.decodeMutation(data) {
            DispatchQueue.main.async {
                self.apply(mutation)
                replyHandler([
                    SRLibrarySnapshotTransport.mutationAcknowledgementKey: mutation.id
                ])
            }
            return
        }
        guard message[SRLibrarySnapshotTransport.snapshotRequestKey] as? Bool == true else {
            replyHandler([:])
            return
        }
        DispatchQueue.main.async {
            self.answerLibraryRequest(using: session, reply: replyHandler)
        }
    }

    @MainActor
    private func requestedChapters(for request: SRChapterRequest) async -> [SRPodcastChapterRecord] {
        let key = "\(request.feedID)\u{1F}\(request.audioURL)"
        if let cached = chapterResults[key] { return cached }
        if let pending = chapterFetches[key] { return await pending.value }
        let pending = Task { @MainActor in
            let episode = PodcastViewModel.shared.podcastFeeds.first { $0.id == request.feedID }?
                .episodes.first { $0.audioUrl == request.audioURL }
            let supplied = episode?.chapters?.map {
                SRPodcastChapterRecord(title: $0.title, startTime: $0.startTime)
            } ?? []
            if !supplied.isEmpty { return supplied }
            guard let url = URL(string: request.audioURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [] }
            print("[PhoneWatchChapters] fetching host=\(url.host ?? "unknown") local=\(episode?.localFilePath != nil)")
            return await ID3ChapterReader.loadChapters(remoteURL: url, localPath: episode?.localFilePath).map {
                SRPodcastChapterRecord(title: $0.title, startTime: $0.startTime)
            }
        }
        chapterFetches[key] = pending
        let chapters = await pending.value
        chapterFetches[key] = nil
        if !chapters.isEmpty {
            if chapterResults.count >= 100 { chapterResults.removeAll() }
            chapterResults[key] = chapters
        }
        return chapters
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo[SRChapterRequest.messageKey] is Data {
            var request = userInfo
            request[SRChapterDelivery.deferredRequestKey] = true
            print("[PhoneWatchChapters] received queued request")
            self.session(session, didReceiveMessage: request, replyHandler: { _ in })
            return
        }
        if userInfo[SRLibrarySnapshotTransport.snapshotRequestKey] as? Bool == true {
            DispatchQueue.main.async { self.answerLibraryRequest(using: session) }
            return
        }
        if receiveMutation(userInfo, session: session) { return }
        _ = receiveEpisodeState(userInfo)
    }

    private func receiveMutation(_ message: [String: Any], session: WCSession) -> Bool {
        if let id = message[SRSyncJournal.acknowledgementKey] as? String {
            Task { @MainActor in
                do { try await journal.acknowledge(id) }
                catch { print("[PhoneWatchSync] acknowledgement failed: \(error)") }
            }
            return true
        }
        if let data = message[SRSyncJournal.messageKey] as? Data,
           let change = try? JSONDecoder().decode(SRSyncChange.self, from: data) {
            Task { @MainActor in
                do {
                    try await journal.receive(change, requiringApplication: true)
                    applyPendingJournalChanges()
                    try await journal.flush()
                    let reply = [SRSyncJournal.acknowledgementKey: change.id]
                    if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo[SRSyncJournal.acknowledgementKey] as? String == change.id }) {
                        session.transferUserInfo(reply)
                    }
                    if session.isReachable { session.sendMessage(reply, replyHandler: nil, errorHandler: nil) }
                } catch { print("[PhoneWatchSync] receive failed: \(error)") }
            }
            return true
        }
        guard let data = message[SRLibrarySnapshotTransport.mutationKey] as? Data,
              let mutation = try? SRLibrarySnapshotTransport.decodeMutation(data) else {
            return false
        }
        DispatchQueue.main.async {
            self.apply(mutation)
            session.transferUserInfo([
                SRLibrarySnapshotTransport.mutationAcknowledgementKey: mutation.id
            ])
        }
        return true
    }

    @MainActor private var isAwaitingLaunchStateLoad = false

    /// Diffing before this would send pre-load (stale) values to the Watch as new changes.
    @MainActor private var isEpisodeStateSettled: Bool {
        EpisodeStateManager.shared.hasLoadedSavedStates && !isAwaitingLaunchStateLoad
    }

    @MainActor
    private func applyPendingJournalChanges() {
        // At cold launch the Watch's queued changes arrive before EpisodeStateManager's Core Data load, which
        // would then overwrite them in memory (and echo the stale progress back to the Watch).
        guard EpisodeStateManager.shared.hasLoadedSavedStates, !PodcastViewModel.shared.podcastFeeds.isEmpty else {
            guard !isAwaitingLaunchStateLoad else { return }
            isAwaitingLaunchStateLoad = true
            Task { @MainActor in
                await EpisodeStateManager.shared.waitUntilSavedStatesLoaded()
                // Feeds are needed to resolve Watch episode IDs by audio URL.
                let deadline = Date().addingTimeInterval(10)
                while PodcastViewModel.shared.podcastFeeds.isEmpty, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                isAwaitingLaunchStateLoad = false
                applyJournalChangesNow()
                do { try await journal.flush() }
                catch { print("[PhoneWatchSync] deferred apply persistence failed: \(error)") }
            }
            return
        }
        applyJournalChangesNow()
    }

    @MainActor
    private func applyJournalChangesNow() {
        for change in journal.changesRequiringApplication {
            apply(change.mutation, versioned: true)
            journal.markApplied(change)
        }
    }

    @MainActor
    private func apply(_ mutation: SRWatchMutation, versioned: Bool = false) {
        guard versioned || !journal.contains(mutation) else { return }
        switch mutation {
        case .stationFavorite(let value):
            let normalizedURL = SRWatchMutation.stationIdentity(value.streamURL)
            let viewModel = RadioStationViewModel.shared
            var station = viewModel.stations.first(where: {
                $0.id == value.stationID
                    || SRWatchMutation.stationIdentity($0.url) == normalizedURL
            })
            if station == nil, value.isFavorite {
                let newStation = RadioStation(
                    id: value.stationID,
                    name: value.name,
                    url: value.streamURL,
                    iconData: value.artworkData?.base64EncodedString(),
                    country: value.country
                )
                viewModel.stations.append(newStation)
                station = newStation
            }
            guard let station, station.isFavorite != value.isFavorite else { return }
            viewModel.toggleFavorite(for: station)
            // The radio list renders a Core Data snapshot, so it only changes once this is on disk.
            viewModel.saveStationsToCoreData {
                NotificationCenter.default.post(name: .stationDetailsUpdated, object: nil)
            }

        case .episodeProgress(let value):
            let episodeID = matchingEpisodeID(value.episodeID, feedID: value.feedID, audioURL: value.audioURL)
            let key = "\(value.feedID)\u{1F}\(episodeID)"
            lastEpisodeProgress = lastEpisodeProgress ?? EpisodeStateManager.shared.episodeProgress
            lastEpisodeProgress?[key] = value.progress
            if value.progress >= 0.99 { lastPlayedEpisodeKeys?.insert(key) } else { lastPlayedEpisodeKeys?.remove(key) }
            if versioned {
                PodcastViewModel.shared.applyWatchEpisodeState(episodeID, feedID: value.feedID, progress: value.progress)
            } else {
                PodcastViewModel.shared.updateEpisodeState(episodeID, feedId: value.feedID,
                    progress: value.progress, isPlayed: value.progress >= 0.99)
            }
            scheduleWatchProgressCloudSync(episodeID: episodeID, feedID: value.feedID, progress: value.progress)

        case .episodeFavorite(let value):
            let episodeID = matchingEpisodeID(value.episodeID, feedID: value.feedID, audioURL: value.audioURL)
            lastEpisodeFavorites = lastEpisodeFavorites ?? EpisodeStateManager.shared.episodeFavorites
            lastEpisodeFavorites?["\(value.feedID)\u{1F}\(episodeID)"] = value.isFavorite
            if versioned {
                PodcastViewModel.shared.applyWatchEpisodeState(episodeID, feedID: value.feedID, isFavorite: value.isFavorite)
            } else {
                PodcastViewModel.shared.updateEpisodeState(episodeID, feedId: value.feedID, isFavorite: value.isFavorite)
            }

        case .stationPlayed(let value):
            let viewModel = RadioStationViewModel.shared
            let identity = SRWatchMutation.stationIdentity(value.streamURL)
            let station: RadioStation
            if let index = viewModel.stations.firstIndex(where: {
                $0.id == value.stationID || SRWatchMutation.stationIdentity($0.url) == identity
            }) {
                guard (viewModel.stations[index].lastPlayed ?? .distantPast) < value.playedAt else { return }
                viewModel.stations[index].lastPlayed = value.playedAt
                station = viewModel.stations[index]
            } else {
                station = RadioStation(id: value.stationID, name: value.name, url: value.streamURL,
                    country: value.country, lastPlayed: value.playedAt)
                viewModel.stations.append(station)
            }
            viewModel.syncStationToCloudKit(station, reason: "Played on Apple Watch")
            NotificationCenter.default.post(
                name: NSNotification.Name("RemoteStationPlayedForRecents"),
                object: nil,
                userInfo: ["stationId": station.id]
            )
        }
    }

    /// The Watch reports progress every 15s while playing; write iCloud at most once a minute per episode.
    @MainActor
    private func scheduleWatchProgressCloudSync(episodeID: String, feedID: String, progress: Double) {
        let key = "\(feedID)\u{1F}\(episodeID)"
        watchProgressCloudSyncTasks[key]?.cancel()
        watchProgressCloudSyncTasks[key] = nil
        let sync = { [weak self] in
            PodcastCloudKitManager.shared.syncPodcastProgressInstantly(episodeId: episodeID, feedId: feedID, progress: progress)
            self?.watchProgressCloudSyncDates[key] = .now
        }
        let lastSync = watchProgressCloudSyncDates[key] ?? .distantPast
        if progress >= 0.99 || progress <= 0 || Date().timeIntervalSince(lastSync) >= 60 {
            sync()
            return
        }
        watchProgressCloudSyncTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            sync()
            self?.watchProgressCloudSyncTasks[key] = nil
        }
    }

    @MainActor
    private func matchingEpisodeID(_ id: String, feedID: String, audioURL: String?) -> String {
        if let match = PodcastViewModel.shared.podcastFeeds.first(where: { $0.id == feedID })?.episodes.first(where: {
            $0.id == id || (audioURL != nil && $0.audioUrl == audioURL)
        }) {
            return match.id
        }
        // `podcastFeeds[].episodes` misses episodes merged after the feed loaded; Core Data has every one.
        var candidates = [NSPredicate(format: "id == %@", id)]
        if let audioURL, !audioURL.isEmpty { candidates.append(NSPredicate(format: "audioUrl == %@", audioURL)) }
        let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "feedId == %@", feedID),
            NSCompoundPredicate(orPredicateWithSubpredicates: candidates)
        ])
        request.fetchLimit = 4
        let context = CoreDataStack.shared.context
        var resolved: String?
        context.performAndWait {
            let ids = ((try? context.fetch(request)) ?? []).compactMap(\.id)
            resolved = ids.first { $0 == id } ?? ids.first
        }
        return resolved ?? id
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            for change in journal.pending { sendChange(change) }
        }
    }

    private func receiveEpisodeState(_ message: [String: Any]) -> Bool {
        guard let data = message[SRLibrarySnapshotTransport.episodeStateUpdateKey] as? Data,
              let state = try? SRLibrarySnapshotTransport.decodeEpisodeState(data) else {
            return false
        }

        DispatchQueue.main.async {
            guard !self.journal.contains(.episodeProgress(SREpisodeProgressMutation(
                episodeID: state.episodeID, feedID: state.feedID, audioURL: state.audioURL,
                progress: state.progress))) else { return }
            let viewModel = PodcastViewModel.shared
            let matchingEpisode = viewModel.podcastFeeds
                .first(where: { $0.id == state.feedID })?
                .episodes.first(where: { episode in
                    episode.id == state.episodeID
                        || (state.audioURL != nil && episode.audioUrl == state.audioURL)
                })
            let episodeID = matchingEpisode?.id ?? state.episodeID
            let currentProgress = EpisodeStateManager.shared.getProgress(
                for: episodeID,
                feedId: state.feedID
            )
            guard state.progress >= currentProgress || state.isPlayed else { return }

            viewModel.updateEpisodeState(
                episodeID,
                feedId: state.feedID,
                progress: state.progress,
                isPlayed: state.isPlayed
            )
            PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                episodeId: episodeID,
                feedId: state.feedID,
                progress: state.progress
            )
        }
        return true
    }
}

func updateWidget() {
    let radioPlayer = RadioPlayer.shared
    guard let currentStation = radioPlayer.currentlyPlayingStation else {
        print("No current station found.")
        return
    }
    
    // CRITICAL FIX: Use currentlyPlayingStation directly to prevent contamination
    let metadata = radioPlayer.metadata ?? "No metadata"
      
    let sharedDefaults = UserDefaults(suiteName: "group.streamradios")
    sharedDefaults?.set(currentStation.name, forKey: "stationName")
    sharedDefaults?.set(currentStation.iconData, forKey: "stationIcon")
    sharedDefaults?.set(metadata, forKey: "stationMetadata")
    
    WidgetCenter.shared.reloadAllTimelines()
    print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
}
