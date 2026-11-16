//
//  ReconnectingIndicatorView.swift
//  StreamRadios
//
//  The one network-status indicator for radio and podcast playback.
//

import SwiftUI

/// What the network is doing to the current playback, as the user should see it.
/// Both engines project their own state into this; nothing else decides what "offline" looks like.
enum PlaybackNetworkStatus: Equatable {
    /// Nothing to report (playing, paused by the user, or simply starting up).
    case normal
    /// No network and no audio; playback resumes by itself when the network returns.
    case offline
    /// No network, but buffered audio is still playing (podcasts).
    case offlinePlayingBuffer
    /// The network is back (or flaky) and the stream is being re-established.
    case reconnecting
    /// Mid-playback stall on a working network.
    case buffering
    /// Automatic retries are exhausted, or the item cannot be played.
    case failed

    /// Replaces the play/pause glyph while it applies. Offline shows a quiet wifi-slash instead
    /// of an endless spinner; failure invites a retry.
    var transportSymbol: String? {
        switch self {
        case .offline: return "wifi.slash"
        case .failed: return "arrow.clockwise"
        case .normal, .offlinePlayingBuffer, .reconnecting, .buffering: return nil
        }
    }

    fileprivate var message: String {
        switch self {
        case .normal: return ""
        case .offline: return "Offline · resumes automatically"
        case .offlinePlayingBuffer: return "Offline · playing buffered audio"
        case .reconnecting: return "Reconnecting…"
        case .buffering: return "Buffering…"
        case .failed: return "Couldn't connect · tap play to retry"
        }
    }

    fileprivate var symbol: String? {
        switch self {
        case .offline, .offlinePlayingBuffer: return "wifi.slash"
        case .failed: return "exclamationmark.triangle.fill"
        case .normal, .reconnecting, .buffering: return nil
        }
    }

    /// Calm by design: an outage that heals itself is neutral, work in progress is amber,
    /// and red is reserved for the one state that needs the user.
    fileprivate var tint: Color {
        switch self {
        case .normal, .offline, .offlinePlayingBuffer: return .secondary
        case .reconnecting, .buffering: return .orange
        case .failed: return .red
        }
    }
}

/// Floating Liquid Glass capsule shown above the mini-player and at the top of the player
/// sheets while the network is affecting playback. It never takes layout space or touches.
struct PlaybackStatusPill: View {
    @ObservedObject private var radioPlayer = RadioPlayer.shared
    @ObservedObject private var podcastPlayer = PodcastPlayer.shared
    @ObservedObject private var playbackManager = PlaybackManager.shared

    /// What is on screen, which lags `status` on purpose (see `present`).
    @State private var shown: PlaybackNetworkStatus = .normal
    @State private var pendingChange: Task<Void, Never>?

    private var status: PlaybackNetworkStatus {
        #if DEBUG
        if let forced = Self.debugForcedStatus { return forced }
        #endif
        switch playbackManager.activePlayer {
        case .radio: return radioPlayer.networkStatus
        case .podcast: return podcastPlayer.networkStatus
        case .none: return .normal
        }
    }

    var body: some View {
        ZStack {
            // Keeps the view in the hierarchy while nothing is shown, so the status observers
            // below stay attached.
            Color.clear.frame(width: 1, height: 1)
            if shown != .normal {
                pill(for: shown)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shown)
        .allowsHitTesting(false)
        .onChange(of: status, initial: true) { _, newStatus in
            present(newStatus)
        }
        .onAppear { present(status) }
        .onDisappear { pendingChange?.cancel() }
    }

    private func pill(for status: PlaybackNetworkStatus) -> some View {
        HStack(spacing: 8) {
            if let symbol = status.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(status.tint)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(status.tint)
            }
            Text(status.message)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.message)
    }

    private func present(_ newStatus: PlaybackNetworkStatus) {
        pendingChange?.cancel()
        pendingChange = nil

        switch newStatus {
        case .buffering:
            // Every seek and every station start buffers for a moment. Only a stall worth
            // mentioning gets the pill.
            pendingChange = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                shown = .buffering
            }
        case .offlinePlayingBuffer:
            // Audio is fine, so this is a heads-up rather than a state to stare at.
            shown = newStatus
            pendingChange = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                shown = .normal
            }
        case .normal, .offline, .reconnecting, .failed:
            shown = newStatus
        }
    }

    #if DEBUG
    /// `-SRDebugNetworkStatus offline|buffered|reconnecting|buffering|failed` pins the pill for
    /// screenshots, since the Simulator cannot drop its network.
    private static let debugForcedStatus: PlaybackNetworkStatus? = {
        switch UserDefaults.standard.string(forKey: "SRDebugNetworkStatus") {
        case "offline": return .offline
        case "buffered": return .offlinePlayingBuffer
        case "reconnecting": return .reconnecting
        case "buffering": return .buffering
        case "failed": return .failed
        default: return nil
        }
    }()
    #endif
}
