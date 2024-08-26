//
//  MiniPlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/26/24.
//

import SwiftUI
import Combine

struct MiniPlayerView: View {
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @Environment(\.colorScheme) var colorScheme
    @Binding var selectedPodcast: PodcastFeed?

    private let height: CGFloat = 64

    var body: some View {
        if let episode = podcastPlayer.currentEpisode,
           let feed = podcastPlayer.currentFeed {
            HStack(spacing: 12) {
                // Feed image
                FeedImageView(feed: feed)
                    .frame(width: height - 16, height: height - 16)
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 4) {
                    // Episode title
                    Text(episode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    // Progress and time remaining
                    HStack(spacing: 8) {
                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: geometry.size.width, height: 3)

                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geometry.size.width * CGFloat(viewModel.getProgress(for: episode)), height: 3)
                            }
                        }
                        .frame(height: 3)

                        // Time remaining
                        Text(formatTimeRemaining(currentTime: podcastPlayer.currentTime, duration: episode.duration))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Playback controls
                HStack(spacing: 20) {
                    Button(action: podcastPlayer.skipBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 22))
                            .foregroundColor(.primary)
                    }

                    Button(action: podcastPlayer.togglePlayPause) {
                        Image(systemName: podcastPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.accentColor)
                    }

                    Button(action: podcastPlayer.skipForward) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 22))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(
                ZStack {
                    BlurView(style: .systemThinMaterialDark)
                        .opacity(colorScheme == .dark ? 0.8 : 1.0)

                    Color.black.opacity(colorScheme == .dark ? 0.4 : 0.2)
                }
            )
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.primary.opacity(0.2))
                    .offset(y: -height / 2)
            )
            .onTapGesture {
                selectedPodcast = feed
            }
        }
    }

    private func formatTimeRemaining(currentTime: TimeInterval, duration: TimeInterval) -> String {
        let remainingTime = max(0, duration - currentTime)

        guard remainingTime > 0 else {
            return "0:00"
        }

        let hours = Int(remainingTime) / 3600
        let minutes = (Int(remainingTime) % 3600) / 60
        let seconds = Int(remainingTime) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
