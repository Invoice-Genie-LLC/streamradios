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
    var onCloseButtonTap: (() -> Void)?
    var isPlaylistButtonDisabled: Bool

    @State private var isDragging = false
    @State private var sliderProgress: Double = 0

    private let height: CGFloat = 70
    private let cornerRadius: CGFloat = 0
    private let horizontalPadding: CGFloat = 16
    private let sliderWidth: CGFloat = 110 // Further reduced width for the slider
    private let imageSize: CGFloat = 50 // Slightly reduced size for the feed image

    var body: some View {
        if let episode = podcastPlayer.currentEpisode,
           let feed = podcastPlayer.currentFeed {
            HStack(spacing: 12) {
                // Feed image
                FeedImageView(feed: feed)
                    .frame(width: imageSize, height: imageSize)
                    .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    // Episode title
                    Text(episode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    // Progress bar and time remaining
                    HStack(spacing: 4) {
                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.15))
                                    .frame(height: 3)

                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: max(0, min(geometry.size.width * CGFloat(sliderProgress), geometry.size.width)), height: 3)

                                // Draggable circle
                                Circle()
                                    .fill(Color.white)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.accentColor, lineWidth: 1)
                                    )
                                    .frame(width: 12, height: 12)
                                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                                    .offset(x: max(0, min(geometry.size.width * CGFloat(sliderProgress) - 6, geometry.size.width - 12)))
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                isDragging = true
                                                sliderProgress = min(max(Double(value.location.x / geometry.size.width), 0), 1)
                                            }
                                            .onEnded { _ in
                                                isDragging = false
                                                podcastPlayer.seek(to: sliderProgress * podcastPlayer.duration)
                                            }
                                    )
                            }
                        }
                        .frame(width: sliderWidth, height: 12)

                        // Time remaining
                        Text(formatTimeRemaining(currentTime: isDragging ? sliderProgress * podcastPlayer.duration : podcastPlayer.currentTime, duration: podcastPlayer.duration))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Playback controls
                HStack(spacing: 8) {
                    Button(action: podcastPlayer.skipBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 14, weight: .medium))
                    }

                    Button(action: podcastPlayer.togglePlayPause) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    Button(action: podcastPlayer.skipForward) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 14, weight: .medium))
                    }

                    // List button
                    Button(action: {
                                       if !isPlaylistButtonDisabled {
                                           onListButtonTap?()
                                       }
                                   }) {
                                       Image(systemName: "list.bullet")
                                           .font(.system(size: 14, weight: .medium))
                                   }
                                   .disabled(isPlaylistButtonDisabled)
                                   .opacity(isPlaylistButtonDisabled ? 0.5 : 1)

                                   // Close button
                                   Button(action: {
                                       onCloseButtonTap?()
                                   }) {
                                       Image(systemName: "xmark.circle.fill")
                                           .font(.system(size: 14, weight: .medium))
                                           .foregroundColor(.secondary)
                                   }
                               }
                               .foregroundColor(.primary)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                ZStack {
                    Color(UIColor.secondarySystemBackground)
                    
                    // Top border
                    VStack {
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 1)
                        Spacer()
                    }
                    
                    // Subtle overlay for depth
                    Color.black.opacity(colorScheme == .dark ? 0.2 : 0.05)
                }
            )
            .overlay(
                // Side borders
                HStack {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 0.5)
                    Spacer()
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 0.5)
                }
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .onReceive(podcastPlayer.$currentProgress) { progress in
                if !isDragging {
                    sliderProgress = progress
                }
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


struct FeedImageView: View {
    let feed: PodcastFeed

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.1), Color.black.opacity(0.05)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
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
                            .tint(.accentColor)
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.primary.opacity(0.7))
                }
            }
            
            // Subtle border overlay
            Rectangle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
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
