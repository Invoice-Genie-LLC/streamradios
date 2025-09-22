//
//  PodcastPlayerSheetView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 1/17/25.
//

import SwiftUI
import AVFoundation
import CoreData
import AVKit

struct PodcastPlayerSheetView: View {
    let episode: PodcastEpisode
    let feed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject private var episodeStateManager = EpisodeStateManager.shared
    @Binding var isPresented: Bool
    
    @State private var showAudioSettings = false
    @State private var currentChapterIndex = 0
    @State private var selectedTab = 0 // 0: Now Playing, 1: Details, 2: Chapters
    @State private var fallbackChapters: [PodcastChapter] = []
    @State private var showDeleteDownloadAlert = false
    @State private var refreshTrigger = false // Force view refresh after download operations
    @Environment(\.colorScheme) var colorScheme
    
    // Computed properties for adaptive colors
    private var backButtonColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var selectedTextColor: Color {
        colorScheme == .dark ? .black : .white
    }
    
    private var unselectedTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var selectedBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var topBarBackgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9)
    }
    
    private var segmentedControlBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.2)
    }
    
    init(episode: PodcastEpisode, feed: PodcastFeed, podcastPlayer: PodcastPlayer, viewModel: PodcastViewModel, isPresented: Binding<Bool>) {
        self.episode = episode
        self.feed = feed
        self.podcastPlayer = podcastPlayer
        self.viewModel = viewModel
        self._isPresented = isPresented
        // Always default to Now Playing on open
        self._selectedTab = State(initialValue: 0)
        // Pre-derive chapters from notes synchronously to avoid any initial delay
        var derived: [PodcastChapter] = []
        if (episode.chapters == nil || episode.chapters?.isEmpty == true), let content = episode.notes?.content, !content.isEmpty {
            derived = parseChaptersFromContent(content)
        }
        self._fallbackChapters = State(initialValue: derived)
    }
    
    // Get chapters for navigation - using same logic as PodcastChaptersNotesView
    private var chapters: [PodcastChapter] {
        let chaptersToShow = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
        return chaptersToShow
    }
    
    private var hasChapters: Bool {
        !chapters.isEmpty
    }
    
    private var hasNotes: Bool {
        episode.notes?.content.isEmpty == false
    }
    
    
    // Current chapter based on playback time
    private var currentChapter: PodcastChapter? {
        guard hasChapters, podcastPlayer.currentEpisode?.id == episode.id else { return nil }
        
        let currentTime = podcastPlayer.currentTime
        for (index, chapter) in chapters.enumerated() {
            let nextChapterTime = index + 1 < chapters.count ? chapters[index + 1].startTime : episode.duration
            if currentTime >= chapter.startTime && currentTime < nextChapterTime {
                DispatchQueue.main.async {
                    if currentChapterIndex != index {
                        currentChapterIndex = index
                    }
                }
                return chapter
            }
        }
        return chapters.first
    }
    
    // Chapter progress for the current chapter
    private var currentChapterProgress: Double {
        guard let chapter = currentChapter, podcastPlayer.currentEpisode?.id == episode.id else { return 0 }
        
        let currentTime = podcastPlayer.currentTime
        let chapterIndex = chapters.firstIndex(where: { $0.id == chapter.id }) ?? 0
        let nextChapterTime = chapterIndex + 1 < chapters.count ? chapters[chapterIndex + 1].startTime : episode.duration
        let chapterDuration = nextChapterTime - chapter.startTime
        
        if chapterDuration <= 0 { return 0 }
        
        let progress = (currentTime - chapter.startTime) / chapterDuration
        return max(0, min(1, progress))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top navigation bar with custom segmented control
                HStack(spacing: 16) {
                    // Back button (downward arrow)
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .foregroundColor(backButtonColor)
                            .frame(width: 44, height: 44)
                    }
                    
                    // Custom segmented control - full width
                    HStack(spacing: 2) {
                        // Now Playing button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = 0
                            }
                        }) {
                            Text("Now Playing")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedTab == 0 ? selectedTextColor : unselectedTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(selectedTab == 0 ? selectedBackgroundColor : Color.clear)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // Details button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = 1
                            }
                        }) {
                            Text("Details")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedTab == 1 ? selectedTextColor : unselectedTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(selectedTab == 1 ? selectedBackgroundColor : Color.clear)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // Chapters button (only show if chapters exist)
                        if hasChapters {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTab = 2
                                }
                            }) {
                                Text("Chapters")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(selectedTab == 2 ? selectedTextColor : unselectedTextColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20)
                                            .fill(selectedTab == 2 ? selectedBackgroundColor : Color.clear)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(segmentedControlBackgroundColor)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(topBarBackgroundColor)
                )
                .conditionalGlassEffect(cornerRadius: 24)
                
                // Swipeable content container
                TabView(selection: $selectedTab) {
                    nowPlayingContentView
                        .tag(0)
                    
                    detailsView
                        .tag(1)
                    
                    chaptersView
                        .tag(2)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
                
                // Bottom menu - always visible
                bottomMenuView
            }
            .background(Color.adaptiveBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsSheet(podcastPlayer: podcastPlayer)
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Delete Download", isPresented: $showDeleteDownloadAlert) {
            Button("Delete Download", role: .destructive) {
                deleteDownload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the downloaded file? The episode will remain in the list but will need to be downloaded again to listen offline.")
        }
        .onAppear {
            // Persist fallback chapters if they were derived during initialization
            if !fallbackChapters.isEmpty {
                persistFallbackChapters(fallbackChapters)
            }
            
            // Attempt to read embedded chapters from the audio asset as a background enhancement
            if (episode.chapters == nil || episode.chapters?.isEmpty == true) && self.fallbackChapters.isEmpty {
                Task { await loadChaptersFromAsset() }
            }
            
            // If no chapters and currently on chapters tab, switch to Now Playing
            if !hasChapters && selectedTab == 2 {
                selectedTab = 0
            }
        }
    }
    
    // MARK: - Tab Views
    
    @ViewBuilder
    private var nowPlayingView: some View {
        VStack(spacing: 0) {
            // Main content area
            VStack(spacing: 24) {
                Spacer()
                
                // Large podcast artwork
                artworkView
                    .frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                
                // Episode title and podcast name
                VStack(spacing: 8) {
                    Text(episode.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    
                    Text(feed.title)
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                
                // Chapter navigation (only show if chapters exist)
                if hasChapters {
                    chapterNavigationView
                }
                
                // Playback controls
                playbackControlsView
                
                Spacer()
            }
            .padding(.horizontal, 20)
            
            // Bottom menu
            bottomMenuView
        }
    }
    
    @ViewBuilder
    private var nowPlayingContentView: some View {
        // Main content area without bottom menu (since it's now always visible)
        VStack(spacing: hasChapters ? 8 : 10) {
            // Conditional top spacing - more space when no chapters
            Spacer(minLength: hasChapters ? 0 : 40)
            
            // Podcast artwork - smaller when chapters present for better fit
            artworkView
                .frame(width: hasChapters ? 200 : 240, height: hasChapters ? 200 : 240)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                .padding(.top, hasChapters ? 10 : 20)
            
            // Episode title and podcast name
            VStack(spacing: hasChapters ? 4 : 6) {
                Text(episode.title)
                    .font(hasChapters ? .body : .title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.adaptivePrimaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(hasChapters ? 2 : 3)
                
                Text(feed.title)
                    .font(.subheadline)
                    .foregroundColor(.adaptiveSecondaryText)
                    .lineLimit(1)
                    .padding(.bottom, 12) // Added bottom padding after podcast name
            }
            .padding(.horizontal, 20)
            
            // Chapter navigation (only show if chapters exist)
            if hasChapters {
                chapterNavigationView
                    .padding(.top, -4) // Tighter spacing above chapters
            }
            
            // Playback controls
            playbackControlsView
                .padding(.top, hasChapters ? -8 : 0) // Tighter spacing when chapters present
            
            // Conditional bottom spacing - more space when no chapters
            Spacer(minLength: hasChapters ? 5 : 60)
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var detailsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Episode header
                episodeHeaderView
                
                // Episode details/notes - using same logic as PodcastChaptersNotesView
                if let notes = episode.notes {
                    // Show notes content with rich formatting
                    if !notes.content.isEmpty {
                        FormattedNotesView(content: notes.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Fallback if no notes - using same logic as PodcastChaptersNotesView
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundColor(.adaptiveSecondaryText)
                        
                        Text("No show notes available")
                            .font(.body)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
    
    @ViewBuilder
    private var chaptersView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                let chaptersToShow = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
                if !chaptersToShow.isEmpty {
                    ForEach(chaptersToShow) { chapter in
                        ChapterRowView(
                            chapter: chapter,
                            isCurrentChapter: isCurrentChapter(chapter),
                            progress: chapterProgress(for: chapter),
                            durationText: formatChapterDuration(for: chapter),
                            hasLink: chapterLinkURL(for: chapter) != nil,
                            onTap: {
                                seekToChapter(chapter)
                            },
                            onLinkTap: {
                                openChapterLink(chapter)
                            }
                        )
                    }
                } else {
                    // Fallback if no chapters - using same logic as PodcastChaptersNotesView
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "list.number")
                            .font(.largeTitle)
                            .foregroundColor(.adaptiveSecondaryText)
                        
                        Text("No chapters available")
                            .font(.body)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
    
    // MARK: - Artwork View
    @ViewBuilder
    private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.2))
            
            // Priority: Direct image data > Base64 icon data > default
            if let imageData = feed.imageData, !imageData.isEmpty {
                if let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    defaultPodcastIcon
                }
            } else if let iconData = feed.iconData, !iconData.isEmpty {
                if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    defaultPodcastIcon
                }
            } else {
                defaultPodcastIcon
            }
        }
    }
    
    private var defaultPodcastIcon: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 80))
            .foregroundColor(.gray)
    }
    
    // MARK: - Chapter Navigation
    private var chapterNavigationView: some View {
        VStack(spacing: 10) {
            // Chapter navigation controls
            HStack(spacing: 35) {
                // Previous chapter button
                Button(action: previousChapter) {
                    ZStack {
                        Circle()
                            .fill(Color.adaptiveSecondaryBackground)
                            .frame(width: 55, height: 55)
                        
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(currentChapterIndex > 0 ? .adaptivePrimaryText : .adaptiveSecondaryText)
                    }
                }
                .disabled(currentChapterIndex <= 0)
                
                // Chapter progress indicator
                ZStack {
                    Circle()
                        .stroke(Color.adaptiveSecondaryText.opacity(0.3), lineWidth: 3)
                        .frame(width: 70, height: 70)
                    
                    Circle()
                        .trim(from: 0, to: currentChapterProgress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: currentChapterProgress)
                    
                    Text("\(currentChapterIndex + 1)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                }
                
                // Next chapter button
                Button(action: nextChapter) {
                    ZStack {
                        Circle()
                            .fill(Color.adaptiveSecondaryBackground)
                            .frame(width: 55, height: 55)
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(currentChapterIndex < chapters.count - 1 ? .adaptivePrimaryText : .adaptiveSecondaryText)
                    }
                }
                .disabled(currentChapterIndex >= chapters.count - 1)
            }
            
            // Current chapter info (moved below navigation controls)
            if let chapter = currentChapter {
                VStack(spacing: 4) {
                    Text("Chapter \(currentChapterIndex + 1) of \(chapters.count)")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                    
                    Text(chapter.title)
                        .font(.headline)
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.bottom, 12) // Added bottom padding after chapter title
                }
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Playback Controls
    private var playbackControlsView: some View {
        VStack(spacing: 16) {
            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: podcastPlayer.duration > 0 ? podcastPlayer.currentTime / podcastPlayer.duration : 0)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .scaleEffect(y: 2)
                
                HStack {
                    Text(formatTime(podcastPlayer.currentTime))
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                        .monospacedDigit()
                    
                    Spacer()
                    
                    Text(formatTime(podcastPlayer.duration))
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                        .monospacedDigit()
                }
            }
            
            // Main playback controls
            HStack(spacing: 40) {
                // Rewind 15s
                Button(action: {
                    podcastPlayer.skipBackward()
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 32))
                        .foregroundColor(.adaptivePrimaryText)
                }
                
                // Play/Pause
                Button(action: {
                    podcastPlayer.togglePlayPause()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 80, height: 80)
                        
                        if podcastPlayer.loadingEpisodeId == episode.id && !podcastPlayer.isPlaying {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else if podcastPlayer.isAttemptingReconnection || podcastPlayer.connectionState == .connecting || podcastPlayer.connectionState == .buffering {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        }
                    }
                }
                
                // Fast forward 30s
                Button(action: {
                    podcastPlayer.skipForward()
                }) {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 32))
                        .foregroundColor(.adaptivePrimaryText)
                }
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Bottom Menu
    private var bottomMenuView: some View {
        HStack(spacing: 0) {
            // AirPlay button
            VStack(spacing: 4) {
                AirPlayButtonView()
                    .frame(width: 24, height: 24)
                Text("AirPlay")
                    .font(.caption)
                    .foregroundColor(.adaptiveSecondaryText)
            }
            .frame(maxWidth: .infinity)
            
            // Audio settings button
            Button(action: {
                showAudioSettings = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24))
                        .foregroundColor(.adaptivePrimaryText)
                    Text("Settings")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Download button
            Button(action: {
                if !isDownloading {
                    toggleDownload()
                }
            }) {
                VStack(spacing: 4) {
                    ZStack {
                        if isDownloaded {
                            // Downloaded state - filled icon
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                        } else if isDownloading {
                            // Downloading state - circular progress with percentage
                            ZStack {
                                // Background circle
                                Circle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                                    .frame(width: 24, height: 24)
                                
                                // Progress circle
                                Circle()
                                    .trim(from: 0, to: CGFloat(downloadProgress))
                                    .stroke(Color.blue, lineWidth: 3)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 24, height: 24)
                                    .animation(.easeInOut(duration: 0.3), value: downloadProgress)
                                
                                // Percentage text or download icon
                                if downloadProgress > 0.05 { // Show percentage after 5% to avoid cramped text
                                    Text("\(Int(downloadProgress * 100))%")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                } else {
                                    Image(systemName: "arrow.down")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                        } else {
                            // Not downloaded state - outline icon
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 24))
                                .foregroundColor(.adaptivePrimaryText)
                        }
                    }
                    Text(isDownloaded ? "Downloaded" : (isDownloading ? "Downloading" : "Download"))
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(isDownloading)
            .id("download-button-\(episode.id)-\(refreshTrigger)") // Force refresh when trigger changes
            
            // Favorite button
            Button(action: {
                print("🔘 Favorite button tapped! Current state: \(isFavorite)")
                toggleFavorite()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 24))
                        .foregroundColor(isFavorite ? .red : .adaptivePrimaryText)
                    Text(isFavorite ? "Favorited" : "Favorite")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.adaptiveSecondaryBackground)
    }
    
    // MARK: - Helper Properties
    private var isDownloaded: Bool {
        EpisodeStateManager.shared.isDownloaded(episode.id)
    }
    
    private var isFavorite: Bool {
        EpisodeStateManager.shared.isFavorite(episode.id)
    }
    
    // Computed property for checking download state
    private var isDownloading: Bool {
        // Don't show downloading if already downloaded
        if isDownloaded {
            return false
        }
        
        // Check if there's valid download progress
        guard let progress = viewModel.downloadProgress[episode.id] else {
            return false
        }
        
        // Only consider it downloading if progress is between 0 and 1 (exclusive)
        return progress > 0 && progress < 1
    }
    
    // Get download progress
    private var downloadProgress: Double {
        viewModel.downloadProgress[episode.id] ?? 0.0
    }
    
    // MARK: - Actions
    private func previousChapter() {
        guard hasChapters, currentChapterIndex > 0 else { return }
        let previousChapter = chapters[currentChapterIndex - 1]
        podcastPlayer.seek(to: previousChapter.startTime)
        currentChapterIndex -= 1
    }
    
    private func nextChapter() {
        guard hasChapters, currentChapterIndex < chapters.count - 1 else { return }
        let nextChapter = chapters[currentChapterIndex + 1]
        podcastPlayer.seek(to: nextChapter.startTime)
        currentChapterIndex += 1
    }
    
    private func toggleDownload() {
        if isDownloaded {
            // If already downloaded, show confirmation alert before removing
            showDeleteDownloadAlert = true
        } else {
            // If not downloaded, start the download process
            print("⬇️ Starting download for episode: \(episode.title)")
            viewModel.downloadEpisode(episode) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(_):
                        print("✅ Episode downloaded successfully: \(self.episode.title)")
                        // Force UI refresh after successful download
                        self.refreshTrigger.toggle()
                    case .failure(let error):
                        print("❌ Failed to download episode: \(error.localizedDescription)")
                        // Clear any partial download state on failure
                        self.viewModel.downloadProgress.removeValue(forKey: self.episode.id)
                        self.refreshTrigger.toggle()
                    }
                }
            }
        }
    }
    
    private func deleteDownload() {
        print("🗑️ Starting download deletion for episode: \(episode.title)")
        
        // Clear any download progress state immediately on main thread
        viewModel.downloadProgress.removeValue(forKey: episode.id)
        print("🔄 Cleared download progress for episode: \(episode.id)")
        
        // Delete the download
        viewModel.toggleDownload(for: episode)
        
        // Force immediate UI refresh
        refreshTrigger.toggle()
        print("🔄 Immediate UI refresh triggered after download deletion")
        
        // Verify state and do additional refresh if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let currentDownloadState = EpisodeStateManager.shared.isDownloaded(self.episode.id)
            let hasProgress = self.viewModel.downloadProgress[self.episode.id] != nil
            
            print("🗑️ Download deletion verification - isDownloaded: \(currentDownloadState), hasProgress: \(hasProgress)")
            
            // If there's still inconsistent state, force another refresh
            if currentDownloadState || hasProgress {
                print("⚠️ Inconsistent state detected, forcing additional refresh")
                self.viewModel.downloadProgress.removeValue(forKey: self.episode.id)
                self.refreshTrigger.toggle()
            }
        }
    }
    
    private func toggleFavorite() {
        let currentState = isFavorite
        let episodeStateManagerState = EpisodeStateManager.shared.isFavorite(episode.id)
        
        print("❤️ BEFORE TOGGLE:")
        print("   Episode: \(episode.title)")
        print("   Episode ID: \(episode.id)")
        print("   Current isFavorite computed: \(currentState)")
        print("   EpisodeStateManager state: \(episodeStateManagerState)")
        print("   Episode.state.isFavorite: \(episode.state.isFavorite)")
        
        // FIX: Use EpisodeStateManager state directly and create updated episode
        let targetState = !episodeStateManagerState
        print("❤️ SETTING TARGET STATE: \(targetState)")
        
        // Create an updated episode with the correct state for viewModel
        var updatedEpisode = episode
        updatedEpisode.state.isFavorite = episodeStateManagerState // Set current state so toggle works correctly
        
        // Set the target state in EpisodeStateManager first
        EpisodeStateManager.shared.setFavorite(episode.id, isFavorite: targetState)
        
        // Call viewModel with the corrected episode state
        viewModel.toggleFavorite(for: updatedEpisode)
        
        // Check state immediately and after delay
        DispatchQueue.main.async {
            let immediateState = EpisodeStateManager.shared.isFavorite(self.episode.id)
            print("❤️ IMMEDIATE AFTER TOGGLE: \(immediateState)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let delayedState = EpisodeStateManager.shared.isFavorite(self.episode.id)
            let computedState = self.isFavorite
            print("❤️ AFTER 0.5s DELAY:")
            print("   EpisodeStateManager state: \(delayedState)")
            print("   Computed isFavorite: \(computedState)")
            print("   Episode.state.isFavorite: \(self.episode.state.isFavorite)")
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) % 3600 / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    // MARK: - Helper Methods for Chapters
    
    private func isCurrentChapter(_ chapter: PodcastChapter) -> Bool {
        guard podcastPlayer.currentEpisode?.id == episode.id else { return false }
        
        let currentTime = podcastPlayer.currentTime
        
        if !chapters.isEmpty {
            for (index, chap) in chapters.enumerated() {
                let nextChapterTime = index + 1 < chapters.count ? chapters[index + 1].startTime : episode.duration
                if currentTime >= chap.startTime && currentTime < nextChapterTime {
                    return chap.id == chapter.id
                }
            }
        }
        
        return false
    }
    
    private func seekToChapter(_ chapter: PodcastChapter) {
        guard podcastPlayer.currentEpisode?.id == episode.id else { return }
        podcastPlayer.seek(to: chapter.startTime)
    }
    
    private func chapterBounds(for chapter: PodcastChapter) -> (start: TimeInterval, end: TimeInterval) {
        if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
            let nextStart = idx + 1 < chapters.count ? chapters[idx + 1].startTime : episode.duration
            let start = max(0, chapter.startTime)
            let end = max(start, nextStart)
            return (start, end)
        }
        return (chapter.startTime, episode.duration)
    }
    
    private func chapterProgress(for chapter: PodcastChapter) -> Double {
        guard podcastPlayer.currentEpisode?.id == episode.id else { return 0 }
        let (start, end) = chapterBounds(for: chapter)
        let total = max(0.001, end - start)
        let t = podcastPlayer.currentTime
        if t <= start { return 0 }
        if t >= end { return 1 }
        return min(1, max(0, (t - start) / total))
    }
    
    private func formatChapterDuration(for chapter: PodcastChapter) -> String {
        let (start, end) = chapterBounds(for: chapter)
        let seconds = Int(max(1, round(end - start)))
        let minutes = Int(round(Double(seconds) / 60.0))
        return "\(max(1, minutes))m"
    }
    
    private func openChapterLink(_ chapter: PodcastChapter) {
        if let direct = chapter.url, let url = URL(string: direct) { 
            UIApplication.shared.open(url)
            return 
        }
        if let derived = chapterLinkURL(for: chapter), let url = URL(string: derived) { 
            UIApplication.shared.open(url)
            return 
        }
    }
    
    private func chapterLinkURL(for chapter: PodcastChapter) -> String? {
        // Check for direct chapter URL
        if let url = chapter.url, hasValidURL(url) { return url }
        
        // Check for URL embedded in the title text
        let title = chapter.title
        if let range = title.range(of: #"https?://\S+"#, options: .regularExpression) {
            var raw = String(title[range])
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.;)\"]"))
            if hasValidURL(raw) { return raw }
        }
        return nil
    }
    
    private func hasValidURL(_ urlString: String?) -> Bool {
        guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https") { return true }
        return false
    }
    
    // MARK: - Episode Header View
    
    @ViewBuilder
    private var episodeHeaderView: some View {
        HStack(spacing: 12) {
            // Episode artwork
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 80)
                
                // Priority: Direct image data > Base64 icon data > default
                if let imageData = feed.imageData, !imageData.isEmpty {
                    if let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        defaultPodcastIcon
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else if let iconData = feed.iconData, !iconData.isEmpty {
                    if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        defaultPodcastIcon
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    defaultPodcastIcon
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            // Episode info
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(feed.title)
                    .font(.subheadline)
                    .foregroundColor(.adaptiveSecondaryText)
                    .lineLimit(1)
                
                // Current playback time
                if podcastPlayer.currentEpisode?.id == episode.id {
                    Text("Current: \(formatTime(podcastPlayer.currentTime))")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.adaptiveSecondaryBackground)
    }
    
    // MARK: - Notes View
    
    @ViewBuilder
    private var notesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notes = episode.notes {
                if !notes.content.isEmpty {
                    Text(stripHTML(notes.content))
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    private func stripHTML(_ html: String) -> String {
        return html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
    
    // MARK: - Chapter Parsing from PodcastChaptersNotesView
    
    private func parseChaptersFromContent(_ content: String) -> [PodcastChapter] {
        // Normalize HTML into plain text lines
        var normalized = content
        let lineBreakTags = ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"]
        for tag in lineBreakTags {
            normalized = normalized.replacingOccurrences(of: tag, with: "\n", options: [.caseInsensitive])
        }
        normalized = normalized.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        normalized = normalized
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        
        let patterns = [
            #"(.+?)\s+(\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
            #"(.+?)\s+(-?\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
            #"\[(\d{1,2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
            #"\((\d{1,2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
            #"\[(\d{1,2}):(\d{2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
            #"\((\d{1,2}):(\d{2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
            #"^(\d{1,2}):(\d{2})\s+(.+?)(?=\n|$)"#,
            #"^(\d{1,2}):(\d{2}):(\d{2})\s+(.+?)(?=\n|$)"#
        ]
        var chapters: [PodcastChapter] = []
        for (idx, pattern) in patterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) {
                let ns = normalized as NSString
                let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    var start: TimeInterval = 0
                    var title = ""
                    if idx == 0 || idx == 1 {
                        if m.numberOfRanges == 4 {
                            let tR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3)
                            title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
                            let minutes = Double(ns.substring(with: minR)) ?? 0
                            let seconds = Double(ns.substring(with: secR)) ?? 0
                            start = abs(minutes * 60 + seconds)
                        }
                    } else if idx >= 2 && idx <= 5 {
                        if m.numberOfRanges == 4 {
                            let minR = m.range(at: 1), secR = m.range(at: 2), tR = m.range(at: 3)
                            let minutes = Double(ns.substring(with: minR)) ?? 0
                            let seconds = Double(ns.substring(with: secR)) ?? 0
                            title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
                            start = minutes * 60 + seconds
                        } else if m.numberOfRanges == 5 {
                            let hR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3), tR = m.range(at: 4)
                            let hours = Double(ns.substring(with: hR)) ?? 0
                            let minutes = Double(ns.substring(with: minR)) ?? 0
                            let seconds = Double(ns.substring(with: secR)) ?? 0
                            title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
                            start = hours * 3600 + minutes * 60 + seconds
                        }
                    } else {
                        if m.numberOfRanges == 4 {
                            let minR = m.range(at: 1), secR = m.range(at: 2), tR = m.range(at: 3)
                            let minutes = Double(ns.substring(with: minR)) ?? 0
                            let seconds = Double(ns.substring(with: secR)) ?? 0
                            title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
                            start = minutes * 60 + seconds
                        } else if m.numberOfRanges == 5 {
                            let hR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3), tR = m.range(at: 4)
                            let hours = Double(ns.substring(with: hR)) ?? 0
                            let minutes = Double(ns.substring(with: minR)) ?? 0
                            let seconds = Double(ns.substring(with: secR)) ?? 0
                            title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
                            start = hours * 3600 + minutes * 60 + seconds
                        }
                    }
                    if !title.isEmpty && title.count > 2 {
                        let cleaned = title.replacingOccurrences(of: "^\\d+\\.", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                        chapters.append(PodcastChapter(title: cleaned, startTime: start))
                    }
                }
                if !chapters.isEmpty { break }
            }
        }
        chapters.sort { $0.startTime < $1.startTime }
        return chapters
    }
}

// MARK: - View Extensions
extension View {
    @ViewBuilder
    func conditionalGlassEffect(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}

// MARK: - Private Methods
extension PodcastPlayerSheetView {
    private func persistFallbackChapters(_ chapters: [PodcastChapter]) {
        guard !chapters.isEmpty else { return }
        let context = CoreDataStack.shared.context
        context.perform {
            let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", episode.id)
            request.fetchLimit = 1
            if let model = try? context.fetch(request).first {
                if let data = try? JSONEncoder().encode(chapters) {
                    model.chaptersData = data
                    try? context.save()
                }
            }
        }
    }

    @MainActor
    private func loadChaptersFromAsset() async {
        guard let url = URL(string: episode.audioUrl) else { return }
        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            guard let locale = locales.first else { return }
            let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
            var parsed: [PodcastChapter] = []
            for group in groups {
                var title: String?
                for item in group.items {
                    if item.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue {
                        if let value = try? await item.load(.value) as? String { title = value }
                    }
                }
                let timeRange = group.timeRange
                let startSeconds = CMTimeGetSeconds(timeRange.start)
                let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    parsed.append(PodcastChapter(title: name, startTime: max(0, startSeconds)))
                }
            }
            parsed.sort { $0.startTime < $1.startTime }
            if !parsed.isEmpty {
                self.fallbackChapters = parsed
                persistFallbackChapters(parsed)
            }
        } catch {
            // Ignore if chapters not available from asset
        }
    }
}
