//  NowPlayingCenter.swift
//  StreamRadios
//
//  The single read model + command surface the redesigned UI talks to.

import Combine
import Foundation
import StreamRadiosKit
import UIKit

/// Projects whichever engine currently owns the audio session into one `SRNowPlaying` value.
///
/// The radio and podcast engines stay completely independent; this only observes them. That keeps
/// ~10.5k lines of battle-tested playback code untouched while giving every new screen — rows,
/// mini-player, full player — a single source of truth with no `if isRadio` branching.
@MainActor
@Observable
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private(set) var current: SRNowPlaying?
    private(set) var progress: SRPlaybackProgress = .none

    @ObservationIgnored private let radio = RadioPlayerAdapter(player: RadioPlayer.shared)
    @ObservationIgnored private let podcast = PodcastPlayerAdapter(player: PodcastPlayer.shared)
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private init() {
        // Between them these three publish on every progress tick, buffer update and metadata
        // change — tens of times a second. The projection only has to be fresh enough for a human
        // to see it, and rebuilding it unthrottled steals main-thread time from whatever is
        // scrolling. Throttling also settles the values, since objectWillChange fires *before*
        // the mutation.
        let pulses = Publishers.MergeMany(
            RadioPlayer.shared.objectWillChange.map { _ in () },
            PodcastPlayer.shared.objectWillChange.map { _ in () },
            PlaybackManager.shared.objectWillChange.map { _ in () }
        )
        .share()

        // `throttle` drops the trailing event, so anything that lands alone in a quiet moment —
        // Shazam artwork arriving a second after the metadata burst — never reached `refresh()`.
        // The debounce guarantees one final pass once the burst settles.
        let throttled = pulses
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
        let settled = pulses
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()

        throttled
            .merge(with: settled)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    var activeCommands: (any SRPlaybackCommanding)? {
        switch PlaybackManager.shared.activePlayer {
        case .radio: return radio
        case .podcast: return podcast
        default: return nil
        }
    }

    /// True when `id` is the item currently loaded in the active engine.
    func isCurrent(_ id: String) -> Bool { current?.id == id }

    private func refresh() {
        let snapshot: (SRNowPlaying, SRPlaybackProgress)?
        switch PlaybackManager.shared.activePlayer {
        case .radio: snapshot = radio.snapshot()
        case .podcast: snapshot = podcast.snapshot()
        default: snapshot = radio.snapshot() ?? podcast.snapshot()
        }

        let newValue = snapshot?.0
        if current != newValue { current = newValue }

        let newProgress = snapshot?.1 ?? .none
        if progress != newProgress { progress = newProgress }
    }
}

// MARK: - Radio

@MainActor
final class RadioPlayerAdapter: SRPlaybackCommanding {
    private let player: RadioPlayer

    init(player: RadioPlayer) { self.player = player }

    func snapshot() -> (SRNowPlaying, SRPlaybackProgress)? {
        guard let station = player.currentlyPlayingStation else { return nil }

        let item = SRNowPlaying(
            id: station.id,
            source: .radio,
            title: station.name,
            subtitle: liveMetadata,
            artwork: artwork(for: station),
            activity: activity,
            capabilities: .radio
        )
        // Live streams have no meaningful timeline.
        return (item, .none)
    }

    /// Shazam/ICY metadata, falling back through the same chain the existing row uses.
    private var liveMetadata: String? {
        let title = player.displayTitle ?? player.songTitle
        let artist = player.displayArtist ?? player.artistName
        let parts = [artist, title].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " — ") }

        if let metadata = player.metadata?.trimmingCharacters(in: .whitespaces), !metadata.isEmpty {
            return metadata
        }
        return nil
    }

    private var activity: SRPlaybackActivity {
        if player.isBuffering { return .buffering }
        switch player.connectionState {
        case .connecting: return .connecting
        case .buffering: return .buffering
        case .error: return .failed("Connection failed")
        case .disconnected: return player.userWantsToPlay ? .connecting : .paused
        case .connected, .paused: return player.isPlaying ? .playing : .paused
        }
    }

    /// Song art from Shazam/iTunes wins while the stream is actually playing; stopping falls back to
    /// the station's own icon, matching the player sheet.
    private func artwork(for station: RadioStation) -> SRArtworkSource {
        if player.isPlaying, let art = player.iTunesAlbumArt ?? player.albumArt {
            // Keyed on the image instance, not the track name: an artwork source compares equal by
            // cache key alone, and the cover can be replaced while the title stays the same.
            let key = "radio.live.\(station.id).\(ObjectIdentifier(art).hashValue)"
            return .image(art, cacheKey: key)
        }
        if let encoded = station.iTunesArtworkData, !encoded.isEmpty {
            return .encoded(base64: encoded, cacheKey: "station.itunes.\(station.id)")
        }
        if let encoded = station.iconData, !encoded.isEmpty {
            return .encoded(base64: encoded, cacheKey: "station.icon.\(station.id)")
        }
        return .none
    }

    // MARK: Commands

    func togglePlayPause() { player.togglePlayPause() }

    func stop() { player.stop() }

    func playNext() {
        guard let stations = player.viewModel?.stations, !stations.isEmpty else { return }
        player.nextStation(from: stations)
    }

    func playPrevious() {
        guard let stations = player.viewModel?.stations, !stations.isEmpty else { return }
        player.previousStation(from: stations)
    }
}

// MARK: - Podcast

@MainActor
final class PodcastPlayerAdapter: SRPlaybackCommanding {
    private let player: PodcastPlayer

    init(player: PodcastPlayer) { self.player = player }

    func snapshot() -> (SRNowPlaying, SRPlaybackProgress)? {
        guard let episode = player.currentEpisode else { return nil }

        let item = SRNowPlaying(
            id: episode.id,
            source: .podcast,
            title: episode.title,
            subtitle: player.currentFeed?.title,
            artwork: artwork(for: player.currentFeed),
            activity: activity(for: episode),
            capabilities: .podcast
        )
        // `duration` is seeded to 0.01 before the asset loads; treat that as "unknown".
        let duration = player.duration > 1 ? player.duration : episode.duration
        return (item, SRPlaybackProgress(elapsed: player.currentTime, duration: duration))
    }

    private func activity(for episode: PodcastEpisode) -> SRPlaybackActivity {
        if player.loadingEpisodeId == episode.id { return .connecting }
        switch player.connectionState {
        case .connecting, .loading: return .connecting
        case .buffering: return .buffering
        case .error: return .failed("Playback failed")
        case .connected, .disconnected: return player.isPlaying ? .playing : .paused
        }
    }

    private func artwork(for feed: PodcastFeed?) -> SRArtworkSource {
        guard let feed else { return .none }
        if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
            return .remote(url)
        }
        if let encoded = feed.iconData, !encoded.isEmpty {
            return .encoded(base64: encoded, cacheKey: "feed.icon.\(feed.id)")
        }
        return .none
    }

    // MARK: Commands

    func togglePlayPause() { player.togglePlayPause() }

    func stop() { player.stop() }

    // The engine owns the skip interval (it's a user setting), so the requested one is advisory.
    func skipForward(_ interval: TimeInterval) { player.skipForward() }

    func skipBackward(_ interval: TimeInterval) { player.skipBackward() }

    func seek(toProgress progress: Double) {
        guard player.duration > 1 else { return }
        player.seek(to: min(max(progress, 0), 1) * player.duration)
    }

    func setPlaybackRate(_ rate: Double) { player.setPlaybackSpeed(rate) }

    func playNext() { player.skipToNextEpisode() }

    func playPrevious() { player.skipToPreviousEpisode() }
}
