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
    var onListButtonTap: (() -> Void)?
    var onCloseButtonTap: (() -> Void)?  // New closure for close button action

    private let height: CGFloat = 70
    private let cornerRadius: CGFloat = 20
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        if let episode = podcastPlayer.currentEpisode,
           let feed = podcastPlayer.currentFeed {
            HStack(spacing: 12) {
                // Feed image
                FeedImageView(feed: feed)
                    .frame(width: height - 20, height: height - 20)
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 4) {
                    // Episode title
                    Text(episode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .foregroundColor(.primary)

                    // Progress bar and time remaining
                    HStack(spacing: 8) {
                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(height: 3)

                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: max(0, min(geometry.size.width * CGFloat(podcastPlayer.currentProgress), geometry.size.width)), height: 3)
                            }
                        }
                        .frame(height: 3)

                        // Time remaining
                        Text(formatTimeRemaining(currentTime: podcastPlayer.currentTime, duration: podcastPlayer.duration))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Playback controls
                HStack(spacing: 10) {
                    Button(action: {
                        onListButtonTap?()
                    }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 18))
                    }

                    Button(action: podcastPlayer.skipBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 18))
                    }

                    Button(action: podcastPlayer.togglePlayPause) {
                        Image(systemName: podcastPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
                    }

                    Button(action: podcastPlayer.skipForward) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 18))
                    }

                    // New close button
                    Button(action: {
                        onCloseButtonTap?()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                    }
                }
                .foregroundColor(.primary)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                ZStack {
                    BlurView(style: .systemThinMaterial)
                        .opacity(colorScheme == .dark ? 0.8 : 1.0)

                    Color.black.opacity(colorScheme == .dark ? 0.4 : 0.2)
                }
            )
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .frame(maxWidth: UIScreen.main.bounds.width - 32)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
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


struct FeedImageView: View {
    let feed: PodcastFeed

    var body: some View {
        Group {
            if let imageData = feed.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
            }
        }
    }
}

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
