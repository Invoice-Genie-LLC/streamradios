import Foundation

/// Which engine produced the currently playing item.
public enum SRPlaybackSource: String, Sendable, Equatable {
    case radio
    case podcast
}

/// What the current item supports, so one player UI can render both sources without
/// branching on `source`. Radio simply doesn't advertise `.seek`; podcast doesn't advertise
/// `.live`.
public struct SRPlaybackCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let seek = SRPlaybackCapabilities(rawValue: 1 << 0)
    public static let skipInterval = SRPlaybackCapabilities(rawValue: 1 << 1)
    public static let variableSpeed = SRPlaybackCapabilities(rawValue: 1 << 2)
    public static let sleepTimer = SRPlaybackCapabilities(rawValue: 1 << 3)
    public static let previousNext = SRPlaybackCapabilities(rawValue: 1 << 4)
    /// Live stream: no duration, no scrubbing, shows a live indicator.
    public static let live = SRPlaybackCapabilities(rawValue: 1 << 5)

    public static let radio: SRPlaybackCapabilities = [.live, .previousNext]
    public static let podcast: SRPlaybackCapabilities = [.seek, .skipInterval, .variableSpeed, .sleepTimer, .previousNext]
}

/// Transport state, unified across the two engines. Radio's connection states and podcast's
/// buffering states collapse into one vocabulary the UI can render generically.
public enum SRPlaybackActivity: Sendable, Equatable {
    case idle
    case connecting
    case buffering
    case playing
    case paused
    case failed(String)

    public var isPlaying: Bool { self == .playing }

    /// True while the user is waiting — drives spinners in rows and the mini-player.
    public var isBusy: Bool {
        self == .connecting || self == .buffering
    }
}

/// The single projection every playback surface binds to: mini-player, full player, list rows,
/// CarPlay, widget and lock screen.
///
/// This is deliberately a value type describing *what to display*. It holds no engine state and
/// owns no AVPlayer, so RadioPlayer and PodcastPlayer stay independent and untouched.
public struct SRNowPlaying: Sendable, Equatable, Identifiable {
    /// Station id or episode id — lets a list row ask "is this me?" cheaply.
    public var id: String
    public var source: SRPlaybackSource
    public var title: String
    /// Live stream metadata ("Artist — Song") or episode/feed name.
    public var subtitle: String?
    public var artwork: SRArtworkSource
    public var activity: SRPlaybackActivity
    public var capabilities: SRPlaybackCapabilities

    public init(
        id: String,
        source: SRPlaybackSource,
        title: String,
        subtitle: String? = nil,
        artwork: SRArtworkSource = .none,
        activity: SRPlaybackActivity = .idle,
        capabilities: SRPlaybackCapabilities = []
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.activity = activity
        self.capabilities = capabilities
    }
}

/// Elapsed/duration are kept out of `SRNowPlaying` deliberately: they change several times a
/// second, and folding them into the same value would invalidate every row observing now-playing.
public struct SRPlaybackProgress: Sendable, Equatable {
    public var elapsed: TimeInterval
    public var duration: TimeInterval

    public static let none = SRPlaybackProgress(elapsed: 0, duration: 0)

    public init(elapsed: TimeInterval, duration: TimeInterval) {
        self.elapsed = elapsed
        self.duration = duration
    }

    public var fraction: Double? {
        guard duration > 0 else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    public var remaining: TimeInterval? {
        guard duration > 0 else { return nil }
        return max(duration - elapsed, 0)
    }
}

/// Commands the UI can issue without knowing which engine is active.
///
/// Everything except `togglePlayPause` has a default no-op, so an adapter only implements what
/// its engine actually supports — the `capabilities` set tells the UI what to show.
@MainActor
public protocol SRPlaybackCommanding: AnyObject {
    func togglePlayPause()
    func stop()
    func skipForward(_ interval: TimeInterval)
    func skipBackward(_ interval: TimeInterval)
    func seek(toProgress progress: Double)
    func setPlaybackRate(_ rate: Double)
    func playNext()
    func playPrevious()
}

public extension SRPlaybackCommanding {
    func stop() {}
    func skipForward(_ interval: TimeInterval) {}
    func skipBackward(_ interval: TimeInterval) {}
    func seek(toProgress progress: Double) {}
    func setPlaybackRate(_ rate: Double) {}
    func playNext() {}
    func playPrevious() {}
}
