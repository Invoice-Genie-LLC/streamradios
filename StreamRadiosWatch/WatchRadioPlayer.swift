import AVFoundation
import Combine
import MediaPlayer
import Network
import Observation
import StreamRadiosCore
import UIKit

/// Mirrors the iPhone player's connection feedback so a weak or lost connection is visible.
enum WatchConnectionStatus: Equatable {
    case normal
    case weakSignal
    case reconnecting(attempt: Int)
    case offline
}

enum WatchPlaybackItem: Equatable {
    case radio(SRRadioStationRecord)
    case podcast(episode: SRPodcastEpisodeRecord, feed: SRPodcastFeedRecord)

    var title: String {
        switch self {
        case .radio(let station): station.name
        case .podcast(let episode, _): episode.title
        }
    }

    var subtitle: String {
        switch self {
        case .radio(let station): station.country
        case .podcast(_, let feed): feed.title
        }
    }

    var systemImage: String {
        switch self {
        case .radio: "radio.fill"
        case .podcast: "mic.fill"
        }
    }

    var artworkURL: URL? {
        let value: String?
        switch self {
        case .radio(let station): value = station.artworkURL
        case .podcast(_, let feed): value = feed.artworkURL
        }
        guard let value else { return nil }
        return URL(string: value)
    }

    var artworkData: Data? {
        switch self {
        case .radio(let station):
            return station.artworkData
        case .podcast(_, let feed):
            return feed.artworkData
        }
    }

    var supportsSeeking: Bool {
        if case .podcast = self { return true }
        return false
    }
}

@MainActor
@Observable
final class WatchAudioPlayer {
    private enum AudioSessionError: LocalizedError {
        case noEligibleRoute

        var errorDescription: String? {
            "No audio route is available. Connect Bluetooth headphones or remove Apple Watch from its charger."
        }
    }

    private static var isAudioSessionConfigured = false
    static let maxReconnectAttempts = 5

    private(set) var item: WatchPlaybackItem? {
        didSet { scheduleNowPlayingUpdate() }
    }
    private(set) var isPlaying = false {
        didSet { scheduleNowPlayingUpdate() }
    }
    private(set) var isBuffering = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0 {
        didSet { if duration != oldValue { scheduleNowPlayingUpdate() } }
    }
    private(set) var errorMessage: String?
    private(set) var connectionStatus: WatchConnectionStatus = .normal
    private(set) var radioMetadata: String? {
        didSet { if radioMetadata != oldValue { scheduleNowPlayingUpdate() } }
    }
    private(set) var radioArtworkURL: URL? {
        didSet { if radioArtworkURL != oldValue { scheduleNowPlayingUpdate() } }
    }
    var artworkURL: URL? { radioArtworkURL ?? item?.artworkURL }
    var artworkData: Data? { radioArtworkURL == nil ? item?.artworkData : nil }
    private(set) var outputRouteName = "Choose Output"
    /// "Kley's AirPods Pro 3" is too long for the player; the device type is enough.
    var outputDisplayName: String {
        outputRouteName.localizedCaseInsensitiveContains("AirPods") ? "AirPods" : outputRouteName
    }
    private(set) var hasAudioOutput = false
    private(set) var isChoosingAudioOutput = false
    private(set) var isPlaybackRequested = false {
        didSet { WatchEpisodeDownloads.shared.playbackIsActive = isPlaybackRequested }
    }
    @ObservationIgnored var onEpisodeStateChange: ((SREpisodeStateRecord) -> Void)?
    @ObservationIgnored var savedEpisodeState: ((SRPodcastEpisodeRecord) -> SREpisodeStateRecord?)?
    @ObservationIgnored var onStationPlaybackStarted: ((SRRadioStationRecord) -> Void)?
    /// Playback requires StreamRadios Pro; browsing does not.
    @ObservationIgnored var canStartPlayback: () -> Bool = { true }
    @ObservationIgnored var onPlaybackBlocked: (() -> Void)?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var playbackRequestID = UUID()
    @ObservationIgnored private var pendingResumeProgress: Double = 0
    @ObservationIgnored private var pendingResumeSeconds: Double?
    @ObservationIgnored private var audioSessionReady = false
    @ObservationIgnored private var outputRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var startupPrepared = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var seekRequestID = UUID()
    @ObservationIgnored private var seekVerificationTask: Task<Void, Never>?
    @ObservationIgnored private var lastReportedProgress: Double = 0
    @ObservationIgnored private var lastReportDate = Date.distantPast
    @ObservationIgnored private var playbackVerificationTask: Task<Void, Never>?
    @ObservationIgnored private var requestStartedAt = Date()
    @ObservationIgnored private var metadataDelegate: WatchRadioMetadataDelegate?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkCache: [String: URL] = [:]
    @ObservationIgnored private var artworkAttemptDates: [String: Date] = [:]
    @ObservationIgnored private var needsPlayerRebuild = false
    @ObservationIgnored private var recoveryAttempt = 0
    @ObservationIgnored private var preferRemoteEpisodeAudio = false
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var didStartCurrentItem = false
    @ObservationIgnored private var isNetworkAvailable = true
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var nowPlayingUpdatePending = false
    @ObservationIgnored private var nowPlayingArtwork: (key: String, artwork: MPMediaItemArtwork)?
    @ObservationIgnored private var nowPlayingArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtworkRequestKey: String?

    init() {
        refreshAudioRoute()
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        print("[WatchPlayback] background audio enabled=\(backgroundModes.contains("audio"))")
        configureRemoteCommands()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkAvailabilityChanged(available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "StreamRadiosWatch.pathMonitor"))
    }

    func play(_ station: SRRadioStationRecord) {
        guard let url = URL(string: station.streamURL) else {
            errorMessage = "This station has an invalid stream URL."
            return
        }
        start(url: url, item: .radio(station))
    }

    func refreshStationArtwork(from stations: [SRRadioStationRecord]) {
        guard case .radio(var currentStation) = item else { return }
        let currentURL = normalizedStreamURL(currentStation.streamURL)
        guard let updatedStation = stations.first(where: {
            normalizedStreamURL($0.streamURL) == currentURL
        }) else { return }

        let previousData = currentStation.artworkData
        let previousURL = currentStation.artworkURL
        currentStation.artworkData = updatedStation.artworkData ?? currentStation.artworkData
        currentStation.artworkURL = updatedStation.artworkURL ?? currentStation.artworkURL
        if currentStation.artworkData != previousData || currentStation.artworkURL != previousURL {
            item = .radio(currentStation)
        }
    }

    func refreshEpisodeMetadata(from episodes: [SRPodcastEpisodeRecord]) {
        guard case .podcast(let currentEpisode, let feed) = item,
              let updatedEpisode = episodes.first(where: {
                  $0.id == currentEpisode.id || $0.audioURL == currentEpisode.audioURL
              }), updatedEpisode != currentEpisode else { return }
        item = .podcast(episode: updatedEpisode, feed: feed)
    }

    func refreshFeedArtwork(from feeds: [SRPodcastFeedRecord]) {
        guard case .podcast(let episode, let feed) = item,
              let updated = feeds.first(where: { $0.id == feed.id }), updated != feed else { return }
        item = .podcast(episode: episode, feed: updated)
    }

    func play(
        _ episode: SRPodcastEpisodeRecord,
        from feed: SRPodcastFeedRecord,
        state: SREpisodeStateRecord? = nil
    ) {
        guard let url = URL(string: episode.audioURL) else {
            errorMessage = "This episode has an invalid audio URL."
            return
        }
        start(
            url: WatchEpisodeDownloads.shared.localURL(for: episode) ?? url,
            item: .podcast(episode: episode, feed: feed),
            resumeProgress: state?.isFinished == true ? 0 : state?.progress ?? 0,
            resumeSeconds: state?.isFinished == true ? nil : state?.positionSeconds
        )
    }

    private func start(
        url: URL,
        item: WatchPlaybackItem,
        resumeProgress: Double = 0,
        resumeSeconds: Double? = nil,
        recoveryAttempt: Int = 0,
        reconnectAttempt: Int = 0
    ) {
        guard canStartPlayback() else {
            onPlaybackBlocked?()
            return
        }
        reconnectTask?.cancel()
        self.reconnectAttempt = reconnectAttempt
        if reconnectAttempt == 0 {
            didStartCurrentItem = false
            connectionStatus = isNetworkAvailable ? .normal : .offline
        }
        // A paused item already reported its position; re-reporting it here would overwrite newer
        // progress from the iPhone or CarPlay with this stale one.
        if isPlaying || isPlaybackRequested { reportEpisodeProgress(force: true) }
        let requestID = UUID()
        playbackRequestID = requestID
        requestStartedAt = .now
        trace("requested")
        self.item = item
        self.recoveryAttempt = recoveryAttempt
        preferRemoteEpisodeAudio = !url.isFileURL
        needsPlayerRebuild = false
        radioMetadata = nil
        radioArtworkURL = nil
        artworkKey = nil
        artworkTask?.cancel()
        if case .podcast(let episode, _) = item {
            WatchEpisodeDownloads.shared.protectedURL = episode.audioURL
        } else {
            WatchEpisodeDownloads.shared.protectedURL = nil
        }
        isBuffering = true
        errorMessage = nil
        isPlaybackRequested = true
        WatchEpisodeDownloads.shared.cancel()
        installPlayer(for: url, resumeProgress: resumeProgress, shouldPlay: false)
        pendingResumeSeconds = resumeSeconds
        if let resumeSeconds { currentTime = resumeSeconds }
        verifyPlaybackStarted(requestID: requestID)

        Task {
            do {
                try await activateAudioSession()
                guard playbackRequestID == requestID, let player else { return }
                audioSessionReady = true
                trace("audio-session-ready")
                preparePlayback(on: player)
            } catch {
                guard playbackRequestID == requestID else { return }
                isPlaybackRequested = false
                isBuffering = false
                let error = error as NSError
                errorMessage = "\(error.localizedDescription) [\(error.domain):\(error.code)]"
            }
        }
    }

    /// Stops audio when StreamRadios Pro is no longer active.
    func pauseForPaywall() {
        if isPlaybackRequested || isPlaying { togglePlayback() }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaybackRequested || isPlaying {
            isPlaybackRequested = false
            isPlaying = false
            isBuffering = false
            playbackVerificationTask?.cancel()
            reconnectTask?.cancel()
            connectionStatus = .normal
            player.pause()
            reportEpisodeProgress(force: true)
        } else {
            guard canStartPlayback() else {
                onPlaybackBlocked?()
                return
            }
            if case .podcast(let episode, let feed) = item,
               let saved = savedEpisodeState?(episode), !saved.isFinished,
               saved.modifiedAt > lastReportDate {
                let target = saved.positionSeconds ?? (duration > 0 ? saved.progress * duration : nil)
                // The episode moved on elsewhere since it was paused here; resume from there.
                if target.map({ abs($0 - currentTime) > 3 }) ?? true {
                    play(episode, from: feed, state: saved)
                    return
                }
            }
            if needsPlayerRebuild || player.currentItem?.status == .failed {
                restartCurrentItem()
                return
            }
            isPlaybackRequested = true
            isBuffering = true
            WatchEpisodeDownloads.shared.cancel()
            verifyPlaybackStarted(requestID: playbackRequestID)
            Task {
                do {
                    try await activateAudioSession()
                    guard self.player === player, isPlaybackRequested else { return }
                    audioSessionReady = true
                    preparePlayback(on: player)
                    verifyPlaybackStarted(requestID: playbackRequestID)
                } catch {
                    guard self.player === player, isPlaybackRequested else { return }
                    isPlaybackRequested = false
                    isBuffering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// When AirPods disconnect, watchOS deactivates the long-form session (interruption reason
    /// `.routeDisconnected`), so playing again needs a fresh activation to pick the next route (e.g. speaker).
    private func continueAfterOutputLoss() {
        guard isPlaybackRequested, outputRecoveryTask == nil, !isChoosingAudioOutput else { return }
        trace("output lost, recovering hasOutput=\(hasAudioOutput)")
        reportEpisodeProgress(force: true)
        let requestID = playbackRequestID
        outputRecoveryTask = Task { @MainActor [weak self] in
            // Let the system finish tearing down the old route before asking for a new one.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.outputRecoveryTask = nil
            guard self.playbackRequestID == requestID, self.isPlaybackRequested else { return }
            self.chooseAudioOutput()
        }
    }

    func chooseAudioOutput() {
        guard !isChoosingAudioOutput else { return }
        isChoosingAudioOutput = true
        let requestID = playbackRequestID
        playbackVerificationTask?.cancel()
        audioSessionReady = false
        player?.pause()
        isPlaying = false
        isBuffering = isPlaybackRequested
        reportEpisodeProgress(force: true)
        Task {
            defer { isChoosingAudioOutput = false }
            do {
                try await deactivateAudioSession()
                guard playbackRequestID == requestID else { return }
                try await activateAudioSession()
                guard playbackRequestID == requestID else { return }
                audioSessionReady = true
                errorMessage = nil
                if isPlaybackRequested, let player {
                    preparePlayback(on: player)
                    verifyPlaybackStarted(requestID: playbackRequestID)
                }
            } catch {
                guard playbackRequestID == requestID else { return }
                isPlaybackRequested = false
                isPlaying = false
                isBuffering = false
                refreshAudioRoute()
                let failure = error as NSError
                trace("audio-output reconnect failed domain=\(failure.domain) code=\(failure.code)")
                errorMessage = "\(failure.localizedDescription) Select your AirPods in Watch Control Center or Settings > Bluetooth, then tap Play."
            }
        }
    }

    func skip(by interval: TimeInterval) {
        guard item?.supportsSeeking == true, let player else { return }
        let playerTime = player.currentTime().seconds
        let baseTime = !isSeeking && playerTime.isFinite ? playerTime : currentTime
        performSeek(to: baseTime + interval, player: player)
    }

    func seek(to time: TimeInterval) {
        guard item?.supportsSeeking == true, let player else { return }
        performSeek(to: time, player: player)
    }

    private func performSeek(to requestedTime: TimeInterval, player: AVPlayer) {
        guard self.player === player, requestedTime.isFinite else { return }
        guard startupPrepared, player.currentItem?.status == .readyToPlay else {
            errorMessage = "Audio is not ready to seek yet. Try again when playback starts."
            return
        }
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let knownDuration: TimeInterval
        if itemDuration.isFinite, itemDuration > 0 {
            knownDuration = itemDuration
        } else if duration > 0 {
            knownDuration = duration
        } else if case .podcast(let episode, _) = item {
            knownDuration = episode.duration
        } else {
            knownDuration = 0
        }

        let nonnegativeTarget = max(0, requestedTime)
        let target = knownDuration > 0
            ? min(nonnegativeTarget, knownDuration)
            : nonnegativeTarget
        currentTime = target
        isSeeking = true
        isBuffering = isPlaybackRequested
        let seekID = UUID()
        seekRequestID = seekID
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        errorMessage = nil
        trace("seek requested target=\(target)")
        trace("seekable ranges=\(player.currentItem?.seekableTimeRanges ?? [])")
        seekVerificationTask?.cancel()
        seekVerificationTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let player, self.player === player,
                  self.seekRequestID == seekID, self.isSeeking else { return }
            self.seekRequestID = UUID()
            player.currentItem?.cancelPendingSeeks()
            self.isSeeking = false
            self.isPlaybackRequested = false
            self.isPlaying = false
            self.isBuffering = false
            self.playbackVerificationTask?.cancel()
            player.pause()
            let actual = player.currentTime().seconds
            if actual.isFinite { self.currentTime = max(0, actual) }
            self.trace("seek timed out target=\(target) actual=\(actual)")
            self.needsPlayerRebuild = true
            self.errorMessage = "Seeking timed out. Tap Play to resume, or download the episode and try again."
        }
        if isPlaybackRequested { verifyPlaybackStarted(requestID: playbackRequestID) }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
        ) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.player === player, self.seekRequestID == seekID else { return }
                self.seekVerificationTask?.cancel()
                self.isSeeking = false
                self.isBuffering = false
                self.scheduleNowPlayingUpdate()
                self.trace("seek completed=\(finished) actual=\(player.currentTime().seconds) target=\(target)")
                if finished {
                    self.reportEpisodeProgress(force: true)
                } else {
                    let actual = player.currentTime().seconds
                    if actual.isFinite { self.currentTime = max(0, actual) }
                    self.errorMessage = "Unable to seek this episode. Download it and try again."
                }
                if self.isPlaybackRequested { player.play() }
            }
        }
    }

    private func installPlayer(
        for url: URL,
        resumeProgress: Double = 0,
        shouldPlay: Bool = true
    ) {
        player?.pause()
        removeTimeObserver()
        cancellables.removeAll()
        player = nil

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = item?.supportsSeeking == true ? 0 : 8
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        metadataDelegate = nil
        if case .radio = item {
            let output = AVPlayerItemMetadataOutput(identifiers: nil)
            let delegate = WatchRadioMetadataDelegate { [weak self, weak player] metadata in
                guard let self, let player, self.player === player else { return }
                self.receiveRadioMetadata(metadata)
            }
            metadataDelegate = delegate
            output.setDelegate(delegate, queue: .main)
            playerItem.add(output)
        }
        audioSessionReady = false
        startupPrepared = false
        isSeeking = false
        seekVerificationTask?.cancel()
        seekRequestID = UUID()
        isPlaying = false
        pendingResumeProgress = resumeProgress
        pendingResumeSeconds = nil
        if case .podcast(let episode, _) = item, episode.duration > 0 {
            duration = episode.duration
            currentTime = episode.duration * resumeProgress
        } else {
            currentTime = 0
            duration = 0
        }
        lastReportedProgress = resumeProgress
        lastReportDate = .now
        observe(player)
        if shouldPlay { player.play() }
    }

    private func receiveRadioMetadata(_ metadata: String) {
        guard case .radio(let station) = item else { return }
        radioMetadata = metadata
        guard let track = SRRadioArtworkLookup.Track(metadata: metadata, stationName: station.name) else {
            artworkTask?.cancel()
            artworkKey = nil
            radioArtworkURL = nil
            return
        }
        guard track.key != artworkKey else { return }
        artworkTask?.cancel()
        artworkKey = track.key
        radioArtworkURL = artworkCache[track.key]
        if radioArtworkURL != nil { return }
        if let attempted = artworkAttemptDates[track.key], Date().timeIntervalSince(attempted) < 60 {
            artworkKey = nil
            return
        }
        let requestID = playbackRequestID
        artworkTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, self.playbackRequestID == requestID, self.artworkKey == track.key else { return }
                if self.artworkAttemptDates.count >= 100 { self.artworkAttemptDates.removeAll() }
                self.artworkAttemptDates[track.key] = .now
                let url = try await SRRadioArtworkLookup.artworkURL(for: track)
                guard !Task.isCancelled, self.playbackRequestID == requestID, self.artworkKey == track.key else { return }
                self.radioArtworkURL = url
                if let url {
                    if self.artworkCache.count >= 50 { self.artworkCache.removeAll() }
                    self.artworkCache[track.key] = url
                } else {
                    self.artworkKey = nil
                }
                self.trace("radio artwork matched=\(url != nil)")
            } catch {
                guard !Task.isCancelled, let self, self.playbackRequestID == requestID, self.artworkKey == track.key else { return }
                self.artworkKey = nil
                self.trace("radio artwork lookup failed: \(error.localizedDescription)")
            }
        }
    }

    private func observe(_ player: AVPlayer) {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] status in
                guard let self, let player, self.player === player else { return }
                self.isPlaying = status == .playing
                self.isBuffering = self.isPlaybackRequested
                    && (status == .waitingToPlayAtSpecifiedRate || self.isSeeking || !self.startupPrepared)
                print("[WatchPlayback] status=\(status.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "none") route=\(self.outputRouteName)")
                if status == .playing {
                    self.trace("playing")
                    self.playbackVerificationTask?.cancel()
                    self.reconnectTask?.cancel()
                    self.reconnectAttempt = 0
                    self.didStartCurrentItem = true
                    self.connectionStatus = .normal
                    self.installTimeObserver(on: player)
                    if case .radio(let station) = self.item {
                        self.onStationPlaybackStarted?(station)
                    }
                } else if status == .waitingToPlayAtSpecifiedRate, self.isPlaybackRequested {
                    self.verifyPlaybackStarted(requestID: self.playbackRequestID)
                }
            }
            .store(in: &cancellables)

        player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] status in
                guard let self, let player, self.player === player else { return }
                if status == .readyToPlay {
                    self.trace("item-ready")
                    let seconds = player.currentItem?.duration.seconds ?? 0
                    if seconds.isFinite, seconds > 0 {
                        self.duration = seconds
                    }
                    self.preparePlayback(on: player)
                } else if status == .failed {
                    self.handlePlaybackFailure(player.currentItem?.error,
                        message: "Unable to play this audio.", player: player)
                }
            }
            .store(in: &cancellables)

        player.currentItem?.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] time in
                guard let self, let player, self.player === player,
                      time.seconds.isFinite, time.seconds > 0 else { return }
                self.duration = time.seconds
                if !self.startupPrepared { self.preparePlayback(on: player) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .AVPlayerItemPlaybackStalled,
            object: player.currentItem
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak player] _ in
            guard let self, let player, self.player === player,
                  self.isPlaybackRequested else { return }
            self.isPlaying = false
            self.isBuffering = true
            self.verifyPlaybackStarted(requestID: self.playbackRequestID)
            print("[WatchPlayback] stalled time=\(player.currentTime().seconds) rate=\(player.rate)")
            self.handleStall(of: player)
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak player] notification in
            guard let self, let player, self.player === player else { return }
            self.handlePlaybackFailure(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error,
                message: "Playback stopped unexpectedly.", player: player)
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak player] _ in
            guard let self, let player, self.player === player else { return }
            self.reportEpisodeProgress(force: true)
            self.isPlaybackRequested = false
            self.isPlaying = false
            self.isBuffering = false
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak player] notification in
            guard let self, let player, self.player === player else { return }
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            print("[WatchPlayback] interruption=\(rawType) route=\(self.outputRouteName)")
            if type == .began {
                self.playbackVerificationTask?.cancel()
                self.audioSessionReady = false
                player.pause()
                self.isPlaying = false
                self.isBuffering = false
                self.reportEpisodeProgress(force: true)
                let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                if reason == AVAudioSession.InterruptionReason.routeDisconnected.rawValue {
                    self.continueAfterOutputLoss()
                }
            } else if let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
                      self.isPlaybackRequested {
                    self.verifyPlaybackStarted(requestID: self.playbackRequestID)
                Task { @MainActor in
                    do {
                        try await self.activateAudioSession()
                        guard self.player === player, self.isPlaybackRequested else { return }
                        self.audioSessionReady = true
                        self.preparePlayback(on: player)
                    } catch {
                        guard self.player === player else { return }
                        self.isPlaybackRequested = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            } else if self.outputRecoveryTask == nil, !self.isChoosingAudioOutput {
                self.isPlaybackRequested = false
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak player] notification in
            guard let self, let player, self.player === player else { return }
            self.refreshAudioRoute()
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            print("[WatchPlayback] route change=\(reason) output=\(self.outputRouteName)")
            let deviceWentAway = reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if self.isPlaybackRequested, deviceWentAway || !self.hasAudioOutput {
                self.continueAfterOutputLoss()
                return
            }
            if !self.hasAudioOutput, self.audioSessionReady {
                player.pause()
                self.reportEpisodeProgress(force: true)
                self.isPlaybackRequested = false
                self.isPlaying = false
                self.isBuffering = false
                self.audioSessionReady = false
                self.errorMessage = "Audio output disconnected. Reconnect an output, then tap Play."
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Self.isAudioSessionConfigured = false
            guard let self else { return }
            self.refreshAudioRoute()
            if self.isPlaybackRequested {
                self.restartCurrentItem()
            } else {
                self.audioSessionReady = false
            }
        }
        .store(in: &cancellables)

    }

    private func installTimeObserver(on player: AVPlayer) {
        guard timeObserver == nil, self.player === player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player else { return }
                guard self.startupPrepared, !self.isSeeking, time.seconds.isFinite else { return }
                self.currentTime = max(0, time.seconds)
                let seconds = player.currentItem?.duration.seconds ?? 0
                if seconds.isFinite, seconds > 0 { self.duration = seconds }
                self.reportEpisodeProgress(force: false)
            }
        }
    }

    private func preparePlayback(on player: AVPlayer) {
        guard self.player === player, audioSessionReady, isPlaybackRequested,
              player.currentItem?.status == .readyToPlay, !isSeeking else { return }
            errorMessage = nil
        if startupPrepared {
            player.play()
            return
        }
        guard pendingResumeProgress > 0 || (pendingResumeSeconds ?? 0) > 0 else {
            startupPrepared = true
            player.play()
            return
        }
        // The iPhone sends a fraction of ITS player's duration; feed metadata is often rounded or missing.
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        guard pendingResumeSeconds != nil || duration > 0 else {
            isBuffering = false
            errorMessage = "Waiting for episode duration to restore your saved position."
            return
        }
        let requestedTarget = pendingResumeSeconds ?? duration * pendingResumeProgress
        let target = requestedTarget.isFinite
            ? min(max(0, requestedTarget), duration > 0 ? max(0, duration - 1) : requestedTarget)
            : 0
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        let seekID = UUID()
        seekRequestID = seekID
        verifyPlaybackStarted(requestID: playbackRequestID)
        currentTime = target
        print("[WatchPlayback] resume seek target=\(target)")
        player.seek(
            to: targetTime,
            toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
        ) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.player === player, self.seekRequestID == seekID else { return }
                self.isSeeking = false
                print("[WatchPlayback] resume seek completed=\(finished)")
                guard finished else {
                    self.handlePlaybackFailure(player.currentItem?.error,
                        message: "Unable to restore the saved position. Tap Play to retry.", player: player)
                    return
                }
                self.pendingResumeProgress = 0
                self.pendingResumeSeconds = nil
                self.startupPrepared = true
                if self.isPlaybackRequested { player.play() }
            }
        }
    }

    private func reportEpisodeProgress(force: Bool) {
        guard startupPrepared, !isSeeking,
              case .podcast(let episode, let feed) = item else { return }
          if force, player?.currentItem?.status != .failed,
              let seconds = player?.currentTime().seconds, seconds.isFinite {
            currentTime = max(0, seconds)
        }
        let effectiveDuration = duration > 0 ? duration : episode.duration
        guard effectiveDuration > 0 else { return }
        let progress = min(max(currentTime / effectiveDuration, 0), 1)
        guard force || (
            Date().timeIntervalSince(lastReportDate) >= 15
        ) else { return }

        lastReportedProgress = progress
        lastReportDate = .now
        onEpisodeStateChange?(
            SREpisodeStateRecord(
                episodeID: episode.id,
                feedID: feed.id,
                audioURL: episode.audioURL,
                progress: progress,
                isPlayed: progress >= 0.99,
                positionSeconds: currentTime,
                durationSeconds: effectiveDuration
            )
        )
    }

    private func normalizedStreamURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func removeTimeObserver() {
        playbackVerificationTask?.cancel()
        playbackVerificationTask = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func activateAudioSession() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        if !Self.isAudioSessionConfigured {
            try audioSession.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            Self.isAudioSessionConfigured = true
        }
        guard try await audioSession.activate(options: []) else {
            refreshAudioRoute()
            throw AudioSessionError.noEligibleRoute
        }
        refreshAudioRoute()
        guard hasAudioOutput else { throw AudioSessionError.noEligibleRoute }
    }

    private nonisolated func deactivateAudioSession() async throws {
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }.value
    }

    private func refreshAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        hasAudioOutput = !outputs.isEmpty
        outputRouteName = outputs.first?.portName ?? "Choose Output"
    }

    private func verifyPlaybackStarted(requestID: UUID) {
        playbackVerificationTask?.cancel()
        playbackVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.playbackRequestID == requestID,
                  self.isPlaybackRequested else { return }
            if self.player?.timeControlStatus == .playing, self.startupPrepared, !self.isSeeking { return }
            self.trace("timeout seeking=\(self.isSeeking)")
            guard let player = self.player else { return }
            self.handlePlaybackFailure(player.currentItem?.error,
                message: "Playback timed out. Check your connection and audio output, then tap Play to retry.",
                player: player)
        }
    }

    func checkpoint() {
        reportEpisodeProgress(force: true)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func handlePlaybackFailure(_ error: Error?, message: String, player: AVPlayer) {
        guard self.player === player else { return }
        let failure = error as NSError?
        let details = failure.map { "\($0.localizedDescription) [\($0.domain):\($0.code)]" } ?? message
        trace("failure attempt=\(recoveryAttempt) prepared=\(startupPrepared) seeking=\(isSeeking) error=\(details)")
        if let event = player.currentItem?.errorLog()?.events.last {
            trace("error-log domain=\(event.errorDomain) code=\(event.errorStatusCode) comment=\(event.errorComment ?? "none")")
        }
        playbackVerificationTask?.cancel()
        seekVerificationTask?.cancel()
        seekRequestID = UUID()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        needsPlayerRebuild = true
        // Audio that was already playing and dropped out is a connection problem: keep trying,
        // like the iPhone player, instead of stopping with an error.
        if isPlaybackRequested, didStartCurrentItem {
            if !isNetworkAvailable {
                trace("failure while offline; waiting for network")
                reportEpisodeProgress(force: true)
                isPlaying = false
                isBuffering = true
                connectionStatus = .offline
                return
            }
            if reconnectAttempt < Self.maxReconnectAttempts {
                scheduleReconnect()
                return
            }
        }
        if isPlaybackRequested, case .podcast = item, recoveryAttempt < 1 {
            trace("retrying podcast with fresh remote asset")
            restartCurrentItem(recoveryAttempt: recoveryAttempt + 1, preferRemote: true)
            return
        }
        reportEpisodeProgress(force: true)
        isPlaybackRequested = false
        isPlaying = false
        isBuffering = false
        isSeeking = false
        reconnectTask?.cancel()
        let lostConnection = reconnectAttempt >= Self.maxReconnectAttempts
        connectionStatus = .normal
        errorMessage = lostConnection
            ? "Connection lost. Check your connection, then tap Play to try again."
            : details
    }

    private func handleStall(of player: AVPlayer) {
        guard didStartCurrentItem else { return }
        if !isNetworkAvailable {
            connectionStatus = .offline
            return
        }
        if case .reconnecting = connectionStatus { return }
        connectionStatus = .weakSignal
        let requestID = playbackRequestID
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self, weak player] in
            // Give AVPlayer a moment to refill its buffer on its own before rebuilding the stream.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, let player, self.player === player,
                  self.playbackRequestID == requestID, self.isPlaybackRequested,
                  player.timeControlStatus != .playing else { return }
            guard self.isNetworkAvailable else {
                self.connectionStatus = .offline
                return
            }
            self.trace("stall did not recover; reconnecting")
            self.reconnectNow()
        }
    }

    private func scheduleReconnect() {
        let attempt = reconnectAttempt + 1
        connectionStatus = .reconnecting(attempt: attempt)
        isPlaying = false
        isBuffering = true
        reportEpisodeProgress(force: true)
        let requestID = playbackRequestID
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            guard !Task.isCancelled, let self, self.playbackRequestID == requestID,
                  self.isPlaybackRequested else { return }
            self.trace("reconnect attempt=\(attempt)")
            self.restartCurrentItem(reconnectAttempt: attempt)
        }
    }

    private func reconnectNow() {
        guard isPlaybackRequested, reconnectAttempt < Self.maxReconnectAttempts else { return }
        let attempt = reconnectAttempt + 1
        connectionStatus = .reconnecting(attempt: attempt)
        reportEpisodeProgress(force: true)
        restartCurrentItem(reconnectAttempt: attempt)
    }

    private func networkAvailabilityChanged(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        print("[WatchPlayback] network available=\(available)")
        guard isPlaybackRequested, didStartCurrentItem else { return }
        if !available {
            // Keep playing whatever is buffered; reconnect when the network comes back.
            reconnectTask?.cancel()
            connectionStatus = .offline
        } else if connectionStatus != .normal || needsPlayerRebuild || player?.timeControlStatus != .playing {
            reconnectAttempt = 0
            reconnectNow()
        }
    }

    private func restartCurrentItem(
        recoveryAttempt: Int = 0,
        preferRemote: Bool = false,
        reconnectAttempt: Int = 0
    ) {
        guard let item else { return }
        switch item {
        case .radio(let station):
            guard let url = URL(string: station.streamURL) else { return }
            start(url: url, item: item, reconnectAttempt: reconnectAttempt)
        case .podcast(let episode, _):
            guard let remoteURL = URL(string: episode.audioURL) else { return }
            let seconds = startupPrepared ? currentTime : pendingResumeSeconds
            let progress = startupPrepared && duration > 0 ? currentTime / duration : pendingResumeProgress
            let url = preferRemote || preferRemoteEpisodeAudio
                ? remoteURL : WatchEpisodeDownloads.shared.localURL(for: episode) ?? remoteURL
            start(url: url, item: item, resumeProgress: progress, resumeSeconds: seconds,
                recoveryAttempt: recoveryAttempt, reconnectAttempt: reconnectAttempt)
        }
    }

    // MARK: - Now Playing

    /// Publishing Now Playing info and handling remote commands is what makes watchOS show the
    /// app's Now Playing indicator at the top of the watch face while audio plays.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return .noActionableNowPlayingItem }
                if !self.isPlaybackRequested { self.togglePlayback() }
                return .success
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return .noActionableNowPlayingItem }
                if self.isPlaybackRequested || self.isPlaying { self.togglePlayback() }
                return .success
            }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return .noActionableNowPlayingItem }
                self.togglePlayback()
                return .success
            }
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.item?.supportsSeeking == true else { return .commandFailed }
                self.skip(by: 30)
                return .success
            }
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.item?.supportsSeeking == true else { return .commandFailed }
                self.skip(by: -15)
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.item?.supportsSeeking == true,
                      let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self.seek(to: event.positionTime)
                return .success
            }
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func scheduleNowPlayingUpdate() {
        guard !nowPlayingUpdatePending else { return }
        nowPlayingUpdatePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.nowPlayingUpdatePending = false
            self.updateNowPlayingInfo()
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPRemoteCommandCenter.shared()
        guard let item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let seekable = item.supportsSeeking
        center.skipForwardCommand.isEnabled = seekable
        center.skipBackwardCommand.isEnabled = seekable
        center.changePlaybackPositionCommand.isEnabled = seekable

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        switch item {
        case .radio(let station):
            let metadata = radioMetadata?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            info[MPMediaItemPropertyTitle] = metadata.isEmpty ? station.name : metadata
            info[MPMediaItemPropertyArtist] = metadata.isEmpty ? station.country : station.name
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        case .podcast(let episode, let feed):
            info[MPMediaItemPropertyTitle] = episode.title
            info[MPMediaItemPropertyArtist] = feed.title
            info[MPMediaItemPropertyAlbumTitle] = feed.title
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            let effectiveDuration = duration > 0 ? duration : episode.duration
            if effectiveDuration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = effectiveDuration
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        if let artwork = nowPlayingArtworkForCurrentItem() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func nowPlayingArtworkForCurrentItem() -> MPMediaItemArtwork? {
        let data = artworkData
        let url = artworkURL
        let key: String
        if let data {
            key = "data:\(data.count):\(data.hashValue)"
        } else if let url {
            key = url.absoluteString
        } else {
            return nil
        }
        if let cached = nowPlayingArtwork, cached.key == key { return cached.artwork }
        if let data {
            guard let artwork = Self.makeArtwork(from: data) else { return nil }
            nowPlayingArtwork = (key, artwork)
            return artwork
        }
        guard let url, nowPlayingArtworkRequestKey != key else { return nowPlayingArtwork?.artwork }
        nowPlayingArtworkRequestKey = key
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = Task { @MainActor [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled, let self, self.nowPlayingArtworkRequestKey == key,
                  let artwork = Self.makeArtwork(from: data) else { return }
            self.nowPlayingArtwork = (key, artwork)
            self.updateNowPlayingInfo()
        }
        // Keep showing the previous artwork until the new one arrives.
        return nowPlayingArtwork?.artwork
    }

    private static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func trace(_ event: String) {
        print("[WatchPlayback] request=\(playbackRequestID) elapsed=\(Date().timeIntervalSince(requestStartedAt)) event=\(event) route=\(outputRouteName)")
    }
}

private final class WatchRadioMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onMetadata: @MainActor (String) -> Void
    private var metadataTask: Task<Void, Never>?

    init(onMetadata: @escaping @MainActor (String) -> Void) {
        self.onMetadata = onMetadata
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        metadataTask?.cancel()
        metadataTask = Task { @MainActor in
            var title: String?
            var artist: String?
            var fallback: String?
            for metadata in groups.flatMap({ $0.items }) {
                guard let value = try? await metadata.load(.stringValue), !value.isEmpty else { continue }
                switch metadata.commonKey {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                default: if fallback == nil { fallback = value }
                }
            }
            guard !Task.isCancelled else { return }
            if let title, let artist {
                onMetadata("\(artist) - \(title)")
            } else if let value = title ?? fallback ?? artist {
                onMetadata(value)
            }
        }
    }
}