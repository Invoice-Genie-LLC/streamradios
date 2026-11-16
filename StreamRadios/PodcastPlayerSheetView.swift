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

enum SleepTimerMode {
    case none
    case timer(minutes: Int)
    case endOfEpisode
}

struct PodcastPlayerSheetView: View {
    let episode: PodcastEpisode
    let feed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject private var episodeStateManager = EpisodeStateManager.shared
    /// True when the system bars run down the side (iPhone Duo's short outer display).
    @ObservedObject private var tabBarClearance = TabBarClearance.shared
    /// True on iPhone Duo while the player is wider than tall (open inner display in landscape).
    @State private var isDuoLandscape = false
    /// True as the Now Playing half of the iPhone Duo split, where there is nothing to dismiss.
    @Environment(\.isDuoSplitPane) private var isDuoSplitPane
    @Binding var isPresented: Bool
    
    @State private var showAudioSettings = false
    @State private var currentChapterIndex = 0
    @State private var selectedTab = 0 // 0: Now Playing, 1: Details, 2: Chapters
    @State private var fallbackChapters: [PodcastChapter] = []
    /// Chapter URLs recovered from the audio file's ID3 tag, keyed by start time and by title.
    @State private var chapterLinkIndex: [String: String] = [:]
    @State private var showDeleteDownloadAlert = false
    @State private var refreshTrigger = false // Force view refresh after download operations
    @State private var hasScrolledToCurrentChapter = false
    @State private var scrollTrigger = false
    @State private var showSleepTimer = false
    @State private var sleepTimerMinutes: Int? = nil
    @State private var sleepTimerEndTime: Date? = nil
    @State private var sleepTimerActive = false
    @State private var sleepTimerMode: SleepTimerMode = .none
    @State private var isDraggingProgress = false
    @State private var draggedProgress: Double = 0
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var playerTabNamespace
    
    // UserDefaults keys for timer persistence
    private let timerActiveKey = "PodcastSleepTimerActive"
    private let timerEndTimeKey = "PodcastSleepTimerEndTime"
    private let timerMinutesKey = "PodcastSleepTimerMinutes"
    private let timerModeKey = "PodcastSleepTimerMode"
    
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
    
    private var playbackControlIconColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var buttonGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05),
                Color.white.opacity(0.15)
            ]
        } else {
            return [
                Color.black.opacity(0.15),
                Color.black.opacity(0.05),
                Color.black.opacity(0.10)
            ]
        }
    }
    
    private var buttonBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1),
                Color.white.opacity(0.3)
            ]
        } else {
            return [
                Color.black.opacity(0.3),
                Color.black.opacity(0.15),
                Color.black.opacity(0.25)
            ]
        }
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
        var chaptersToShow = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
        guard !chapterLinkIndex.isEmpty else { return chaptersToShow }
        
        for index in chaptersToShow.indices where chaptersToShow[index].url == nil {
            chaptersToShow[index].url = chapterLink(for: chaptersToShow[index])
        }
        return chaptersToShow
    }
    
    private func chapterLink(for chapter: PodcastChapter) -> String? {
        chapterLinkIndex["t:\(Int(chapter.startTime.rounded()))"]
            ?? chapterLinkIndex["n:\(chapter.title.lowercased())"]
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
                playerHeader
                
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
                // Network status floats over the top of the content, below the header.
                .overlay(alignment: .top) {
                    PlaybackStatusPill()
                        .padding(.top, 6)
                }
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
                .allowsHitTesting(!isDraggingProgress) // Disable swipe gestures when dragging progress bar
                .onChange(of: selectedTab) { oldValue, newValue in
                    // Trigger scroll to current chapter when switching to Chapters tab
                    if newValue == 2 && hasChapters {
                        scrollTrigger.toggle()
                    }
                }
                
                // Bottom menu - always visible
                bottomMenuView
            }
            .background(Color.adaptiveBackground)
            .trackDuoLandscape($isDuoLandscape)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsSheet(podcastPlayer: podcastPlayer)
                .adaptiveSheetDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheet(
                sleepTimerMode: $sleepTimerMode,
                sleepTimerActive: $sleepTimerActive,
                sleepTimerMinutes: $sleepTimerMinutes,
                sleepTimerEndTime: $sleepTimerEndTime,
                podcastPlayer: podcastPlayer,
                episode: episode,
                saveTimerState: saveTimerState,
                clearTimerState: clearTimerState
            )
            .adaptiveSheetDetents([.fraction(0.5), .large])
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
            // Restore timer state
            restoreTimerState()
            
            // Persist fallback chapters if they were derived during initialization
            if !fallbackChapters.isEmpty {
                persistFallbackChapters(fallbackChapters)
            }
            
            // Attempt to read embedded chapters from the audio asset as a background enhancement
            if (episode.chapters == nil || episode.chapters?.isEmpty == true) && self.fallbackChapters.isEmpty {
                Task { await loadChaptersFromAsset() }
            }
            
            Task { await loadChapterLinks() }
            
            // If no chapters and currently on chapters tab, switch to Now Playing
            if !hasChapters && selectedTab == 2 {
                selectedTab = 0
            }
        }
    }
    
    // MARK: - Header
    
    /// Mirrors the radio player header: a leading capsule button plus a capsule segmented control.
    private var playerHeader: some View {
        HStack(spacing: 10) {
            if !isDuoSplitPane {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.adaptivePrimaryText)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .background(Capsule().fill(Color.adaptiveSecondaryBackground))
                .conditionalGlassEffect(cornerRadius: 20)
            }
            
            playerTabBar
        }
        .padding(.horizontal, 16)
        .padding(.top, isDuoSplitPane ? DuoSplit.headerTopPadding(isBarOnSide: tabBarClearance.isBarOnSide) : (tabBarClearance.isBarOnSide ? 14 : 8))
        .padding(.bottom, tabBarClearance.isBarOnSide ? 4 : 10)
        .background(Color.adaptiveBackground)
    }
    
    private var playerTabBar: some View {
        HStack(spacing: 4) {
            playerTabButton("Now Playing", tag: 0)
            playerTabButton("Notes", tag: 1)
            if hasChapters {
                playerTabButton("Chapters", tag: 2)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.adaptiveSectionBackground))
    }
    
    private func playerTabButton(_ title: String, tag: Int) -> some View {
        let isSelected = selectedTab == tag
        
        return Button {
            UIDevice.playHapticFeedback()
            withAnimation(.snappy(duration: 0.28)) { selectedTab = tag }
        } label: {
            Text(title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? selectedTabForeground : Color.adaptiveSecondaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(selectedTabFill)
                            .shadow(color: colorScheme == .dark ? .clear : Color.accentColor.opacity(0.35),
                                    radius: 4, y: 2)
                            .matchedGeometryEffect(id: "selectedPodcastPlayerTab", in: playerTabNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var selectedTabFill: Color {
        colorScheme == .dark ? Color.blue.opacity(0.15) : Color.accentColor
    }
    
    private var selectedTabForeground: Color {
        colorScheme == .dark ? .blue : .white
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
        if tabBarClearance.isBarOnSide || isDuoLandscape {
            // iPhone Duo is too short for this page at full size in landscape, on the outer
            // display and on the open inner one: the playback controls ended up behind the bottom
            // menu with no way to reach them. Use a smaller artwork and let the page scroll;
            // `minHeight` keeps it centred when it does fit.
            GeometryReader { geometry in
                ScrollView {
                    nowPlayingStack(compact: true)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(isDraggingProgress)
            }
        } else {
            nowPlayingStack(compact: false)
        }
    }
    
    @ViewBuilder
    private func nowPlayingStack(compact: Bool) -> some View {
        let baseArtworkSide: CGFloat = compact ? (hasChapters ? 120 : 170) : (hasChapters ? 200 : 240)
        let artworkSide = isDuoSplitPane ? (baseArtworkSide * DuoSplit.artworkScale).rounded() : baseArtworkSide
        // Main content area without bottom menu (since it's now always visible)
        VStack(spacing: hasChapters ? 8 : 10) {
            // Conditional top spacing - more space when no chapters
            Spacer(minLength: compact ? 0 : (hasChapters ? 0 : 40))
            
            // Podcast artwork - smaller when chapters present for better fit
            artworkView
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                .padding(.top, compact ? 4 : (hasChapters ? 10 : 20))
            
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
            Spacer(minLength: compact ? 8 : (hasChapters ? 5 : 60))
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var detailsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Episode header
                episodeHeaderView
                
                if let notes = episode.notes, !notes.content.isEmpty {
                    NotesCardView(content: notes.content)
                } else {
                    NotesEmptyStateView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder
    private var chaptersView: some View {
        let chaptersToShow = chapters
        
        if chaptersToShow.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.adaptiveSecondaryText)
                
                Text("No chapters available")
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                
                Text("This episode doesn't include chapter markers.")
                    .font(.footnote)
                    .foregroundColor(.adaptiveSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    chaptersSummaryBar(chaptersToShow, proxy: proxy)
                    
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(chaptersToShow) { chapter in
                                ChapterRowView(
                                    chapter: chapter,
                                    allChapters: chaptersToShow,
                                    episode: episode,
                                    feed: feed,
                                    podcastPlayer: podcastPlayer,
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
                                .id(chapter.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                        .animation(.easeInOut(duration: 0.25), value: currentChapterIndex)
                    }
                }
                .onAppear {
                    // Scroll to current chapter when chapters view appears
                    if !hasScrolledToCurrentChapter {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            scrollToCurrentChapter(proxy: proxy)
                            hasScrolledToCurrentChapter = true
                        }
                    }
                }
                .onChange(of: scrollTrigger) { _, _ in
                    // Scroll to current chapter when tab is switched to Chapters
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToCurrentChapter(proxy: proxy)
                    }
                }
            }
        }
    }
    
    private func chaptersSummaryBar(_ chaptersToShow: [PodcastChapter], proxy: ScrollViewProxy) -> some View {
        let isThisEpisode = podcastPlayer.currentEpisode?.id == episode.id
        
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(chaptersToShow.count) chapters")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                if isThisEpisode, let current = currentChapter,
                   let index = chaptersToShow.firstIndex(where: { $0.id == current.id }) {
                    Text("Playing \(index + 1) of \(chaptersToShow.count)")
                        .font(.caption2)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            
            Spacer(minLength: 0)
            
            if isThisEpisode && currentChapter != nil {
                Button {
                    UIDevice.playHapticFeedback()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollToCurrentChapter(proxy: proxy)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Current")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundColor(Color.accentColor)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
            // Draggable Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)
                        
                        // Progress fill
                        Capsule()
                            .fill(Color.blue)
                            .frame(
                                width: geometry.size.width * (isDraggingProgress ? draggedProgress : (podcastPlayer.duration > 0 ? podcastPlayer.currentTime / podcastPlayer.duration : 0)),
                                height: 4
                            )
                        
                        // Draggable thumb
                        Circle()
                            .fill(Color.blue)
                            .frame(width: isDraggingProgress ? 16 : 12, height: isDraggingProgress ? 16 : 12)
                            .offset(
                                x: geometry.size.width * (isDraggingProgress ? draggedProgress : (podcastPlayer.duration > 0 ? podcastPlayer.currentTime / podcastPlayer.duration : 0)) - (isDraggingProgress ? 8 : 6)
                            )
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    }
                    .frame(height: 4)
                    .contentShape(Rectangle()) // Make entire area tappable/draggable
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingProgress = true
                                let progress = min(max(0, value.location.x / geometry.size.width), 1)
                                draggedProgress = progress
                            }
                            .onEnded { value in
                                let progress = min(max(0, value.location.x / geometry.size.width), 1)
                                let seekTime = progress * podcastPlayer.duration
                                podcastPlayer.seek(to: seekTime)
                                isDraggingProgress = false
                            }
                    )
                }
                .frame(height: 20) // Give it enough height for easy dragging
                
                HStack {
                    Text(formatTime(isDraggingProgress ? draggedProgress * podcastPlayer.duration : podcastPlayer.currentTime))
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
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                            .foregroundColor(playbackControlIconColor)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Play/Pause
                Button(action: {
                    podcastPlayer.togglePlayPause()
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 64, height: 64)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .frame(width: 64, height: 64)
                        
                        if podcastPlayer.loadingEpisodeId == episode.id && !podcastPlayer.isPlaying {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: playbackControlIconColor))
                                .scaleEffect(1.2)
                        } else if let statusSymbol = podcastPlayer.networkStatus.transportSymbol {
                            // Offline / failed: a quiet glyph instead of an endless spinner
                            Image(systemName: statusSymbol)
                                .font(.title)
                                .foregroundColor(playbackControlIconColor)
                        } else if podcastPlayer.isAttemptingReconnection || podcastPlayer.connectionState == .connecting || podcastPlayer.connectionState == .buffering {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: playbackControlIconColor))
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                                .foregroundColor(playbackControlIconColor)
                                .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Fast forward 30s
                Button(action: {
                    podcastPlayer.skipForward()
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "goforward.30")
                            .font(.title2)
                            .foregroundColor(playbackControlIconColor)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Bottom Menu
    private var bottomMenuView: some View {
        HStack(spacing: 4) {
            // AirPlay button
            VStack(spacing: 6) {
                menuIcon(isActive: false) {
                    AirPlayButtonView()
                        .frame(width: 28, height: 24)
                        .tint(.adaptivePrimaryText)
                }
                menuLabel("AirPlay", isActive: false)
            }
            .frame(maxWidth: .infinity)
            
            // Sleep Timer button
            Button(action: {
                showSleepTimer = true
            }) {
                VStack(spacing: 6) {
                    menuIcon(isActive: sleepTimerActive) {
                        Image(systemName: sleepTimerActive ? "moon.fill" : "moon")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(sleepTimerActive ? .blue : .adaptivePrimaryText)
                    }
                    menuLabel(sleepTimerActive ? "Timer On" : "Timer", isActive: sleepTimerActive)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Audio settings button
            Button(action: {
                showAudioSettings = true
            }) {
                VStack(spacing: 6) {
                    menuIcon(isActive: false) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.adaptivePrimaryText)
                    }
                    menuLabel("Settings", isActive: false)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Download button
            Button(action: {
                if !isDownloading {
                    toggleDownload()
                }
            }) {
                VStack(spacing: 6) {
                    menuIcon(isActive: isDownloaded || isDownloading) {
                        if isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.blue)
                        } else if isDownloading {
                            ZStack {
                                Circle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                                    .frame(width: 24, height: 24)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(downloadProgress))
                                    .stroke(Color.blue, lineWidth: 3)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 24, height: 24)
                                    .animation(.easeInOut(duration: 0.3), value: downloadProgress)
                                
                                // Show percentage after 5% to avoid cramped text
                                if downloadProgress > 0.05 {
                                    Text("\(Int(downloadProgress * 100))")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.adaptivePrimaryText)
                                } else {
                                    Image(systemName: "arrow.down")
                                        .font(.caption2)
                                        .foregroundColor(.adaptivePrimaryText)
                                }
                            }
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.adaptivePrimaryText)
                        }
                    }
                    menuLabel(isDownloaded ? "Downloaded" : (isDownloading ? "Downloading" : "Download"),
                              isActive: isDownloaded)
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
                VStack(spacing: 6) {
                    menuIcon(isActive: isFavorite, tint: .red) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isFavorite ? .red : .adaptivePrimaryText)
                    }
                    menuLabel(isFavorite ? "Favorited" : "Favorite", isActive: isFavorite, tint: .red)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        // Runs under a side status column (iPhone Duo); the horizontal safe-area insets are
        // zero on portrait iPhone and iPad, so nothing changes there.
        // No band in the iPhone Duo split: it would mark the player off as a screen of its own.
        .background((isDuoSplitPane ? Color.clear : Color.adaptiveSecondaryBackground).ignoresSafeArea(.container, edges: [.horizontal, .bottom]))
    }
    
    private func menuIcon<Content: View>(
        isActive: Bool,
        tint: Color = .blue,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? tint.opacity(0.16) : Color.adaptiveFieldBackground)
            )
    }
    
    /// The labels sit in fifths of the screen, so they have to shrink rather than wrap.
    private func menuLabel(_ title: String, isActive: Bool, tint: Color = .blue) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(isActive ? tint : .adaptiveSecondaryText)
    }
    
    // MARK: - Helper Properties
    private var isDownloaded: Bool {
        EpisodeStateManager.shared.isDownloaded(episode.id, feedId: episode.feedId)
    }
    
    private var isFavorite: Bool {
        EpisodeStateManager.shared.isFavorite(episode.id, feedId: episode.feedId)
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
        print("🗑️ Episode ID: \(episode.id)")
        print("🗑️ Current download state: \(EpisodeStateManager.shared.isDownloaded(episode.id, feedId: episode.feedId))")
        
        // Clear any download progress state immediately on main thread
        viewModel.downloadProgress.removeValue(forKey: episode.id)
        print("🔄 Cleared download progress for episode: \(episode.id)")
        
        // Delete the download
        viewModel.toggleDownload(for: episode)
        print("🗑️ Called toggleDownload on viewModel")
        
        // Force immediate UI refresh
        refreshTrigger.toggle()
        print("🔄 Immediate UI refresh triggered after download deletion")
        
        // Force view update
        DispatchQueue.main.async {
            self.refreshTrigger.toggle()
            print("🔄 Second UI refresh on main thread")
        }
        
        // Verify state and do additional refresh if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let currentDownloadState = EpisodeStateManager.shared.isDownloaded(self.episode.id, feedId: self.episode.feedId)
            let hasProgress = self.viewModel.downloadProgress[self.episode.id] != nil
            
            print("🗑️ Download deletion verification - isDownloaded: \(currentDownloadState), hasProgress: \(hasProgress)")
            
            // If there's still inconsistent state, force another refresh
            if currentDownloadState || hasProgress {
                print("⚠️ Inconsistent state detected after 0.3s, forcing additional refresh")
                self.viewModel.downloadProgress.removeValue(forKey: self.episode.id)
                self.refreshTrigger.toggle()
                
                // Force update the episode state directly
                EpisodeStateManager.shared.setDownloaded(self.episode.id, isDownloaded: false)
                print("🗑️ Forced download state to false in EpisodeStateManager")
                
                // One more refresh to ensure UI updates
                DispatchQueue.main.async {
                    self.refreshTrigger.toggle()
                    print("🔄 Final UI refresh after forced state update")
                }
            } else {
                print("✅ Download successfully deleted and state is consistent")
            }
        }
    }
    
    private func toggleFavorite() {
        let currentState = isFavorite
        let episodeStateManagerState = EpisodeStateManager.shared.isFavorite(episode.id, feedId: episode.feedId)
        
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
        // Pass feedId for immediate CloudKit sync
        EpisodeStateManager.shared.setFavorite(episode.id, isFavorite: targetState, feedId: episode.feedId)
        
        // Call viewModel with the corrected episode state
        viewModel.toggleFavorite(for: updatedEpisode)
        
        // Check state immediately and after delay
        DispatchQueue.main.async {
            let immediateState = EpisodeStateManager.shared.isFavorite(self.episode.id, feedId: self.episode.feedId)
            print("❤️ IMMEDIATE AFTER TOGGLE: \(immediateState)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let delayedState = EpisodeStateManager.shared.isFavorite(self.episode.id, feedId: self.episode.feedId)
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
    
    // Scroll to the currently playing chapter
    private func scrollToCurrentChapter(proxy: ScrollViewProxy) {
        guard podcastPlayer.currentEpisode?.id == episode.id else { return }
        
        let chaptersToShow = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
        guard !chaptersToShow.isEmpty else { return }
        
        let currentTime = podcastPlayer.currentTime
        
        // Find the current chapter based on current time
        for (index, chapter) in chaptersToShow.enumerated() {
            let nextChapterTime = index + 1 < chaptersToShow.count ? chaptersToShow[index + 1].startTime : episode.duration
            if currentTime >= chapter.startTime && currentTime < nextChapterTime {
                // Scroll to this chapter with animation
                withAnimation {
                    proxy.scrollTo(chapter.id, anchor: .top)
                }
                return
            }
        }
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
        
        // Chapters derived from the notes carry no URL of their own, so fall back to any note link
        // timestamped inside this chapter's window.
        let (start, end) = chapterBounds(for: chapter)
        if let links = episode.notes?.links, !links.isEmpty {
            if let match = links.first(where: { link in
                guard hasValidURL(link.url) else { return false }
                guard let ts = link.timeStamp else { return false }
                return ts >= start && ts < end
            }) {
                return match.url
            }
        }
        
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
        attachInlineLinks(to: &chapters, from: content)
        return chapters
    }
    
    /// The chapter regexes run on tag-stripped text, so any `<a href>` wrapping a chapter line is
    /// lost by then — recover it by matching each chapter back to its original HTML line.
    private func attachInlineLinks(to chapters: inout [PodcastChapter], from content: String) {
        guard !chapters.isEmpty else { return }
        
        var normalized = content
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"] {
            normalized = normalized.replacingOccurrences(of: tag, with: "\n", options: [.caseInsensitive])
        }
        
        var linksByLine: [(text: String, url: String)] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            guard rawLine.range(of: "<a", options: .caseInsensitive) != nil else { continue }
            guard let hrefRange = rawLine.range(of: #"href\s*=\s*["']([^"']+)["']"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            
            let href = String(rawLine[hrefRange])
                .replacingOccurrences(of: #"^href\s*=\s*["']"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"["']$"#, with: "", options: .regularExpression)
            guard hasValidURL(href) else { continue }
            
            let text = stripHTML(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            linksByLine.append((text.lowercased(), href))
        }
        
        guard !linksByLine.isEmpty else { return }
        
        for index in chapters.indices where chapters[index].url == nil {
            let title = chapters[index].title.lowercased()
            guard title.count > 2 else { continue }
            if let match = linksByLine.first(where: { $0.text.contains(title) }) {
                chapters[index].url = match.url
            }
        }
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
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "id == %@", episode.id),
                NSPredicate(format: "feedId == %@", episode.feedId)
            ])
            request.fetchLimit = 1
            if let model = try? context.fetch(request).first {
                if let data = try? JSONEncoder().encode(chapters) {
                    model.chaptersData = data
                    try? context.save()
                }
            }
        }
    }

    /// Chapter links live in the audio file's ID3 tag, which AVFoundation doesn't expose.
    @MainActor
    private func loadChapterLinks() async {
        guard chapterLinkIndex.isEmpty else { return }
        
        let embedded = await ID3ChapterReader.loadChapters(
            remoteURL: URL(string: episode.audioUrl),
            localPath: episode.localFilePath
        )
        
        var index: [String: String] = [:]
        for chapter in embedded {
            guard let url = chapter.url else { continue }
            index["t:\(Int(chapter.startTime.rounded()))"] = url
            index["n:\(chapter.title.lowercased())"] = url
        }
        
        guard !index.isEmpty else { return }
        chapterLinkIndex = index
        persistFallbackChapters(chapters)
    }

    @MainActor
    private func loadChaptersFromAsset() async {        guard let url = URL(string: episode.audioUrl) else { return }
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
    
    // MARK: - Timer State Persistence
    private func restoreTimerState() {
        let userDefaults = UserDefaults.standard
        
        // Check if timer was active
        guard userDefaults.bool(forKey: timerActiveKey) else {
            sleepTimerActive = false
            sleepTimerMode = .none
            return
        }
        
        // Restore timer mode
        if let modeString = userDefaults.string(forKey: timerModeKey) {
            if modeString == "endOfEpisode" {
                sleepTimerMode = .endOfEpisode
                sleepTimerActive = true
                print("✅ Restored end-of-episode timer")
            } else if let minutes = userDefaults.object(forKey: timerMinutesKey) as? Int {
                // Check if timer end time has passed
                if let endTime = userDefaults.object(forKey: timerEndTimeKey) as? Date {
                    if endTime > Date() {
                        // Timer is still valid
                        sleepTimerEndTime = endTime
                        sleepTimerMinutes = minutes
                        sleepTimerMode = .timer(minutes: minutes)
                        sleepTimerActive = true
                        
                        // Reschedule timer for remaining time
                        let remainingTime = endTime.timeIntervalSinceNow
                        DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) {
                            if self.sleepTimerActive, case .timer(let mins) = self.sleepTimerMode, mins == minutes {
                                self.podcastPlayer.pause()
                                self.clearTimerState()
                            }
                        }
                        print("✅ Restored timer with \(Int(remainingTime/60)) minutes remaining")
                    } else {
                        // Timer expired, clear it
                        clearTimerState()
                        print("⏰ Timer expired, clearing state")
                    }
                }
            }
        }
    }
    
    func saveTimerState() {
        let userDefaults = UserDefaults.standard
        userDefaults.set(sleepTimerActive, forKey: timerActiveKey)
        
        if let endTime = sleepTimerEndTime {
            userDefaults.set(endTime, forKey: timerEndTimeKey)
        }
        
        if let minutes = sleepTimerMinutes {
            userDefaults.set(minutes, forKey: timerMinutesKey)
        }
        
        switch sleepTimerMode {
        case .endOfEpisode:
            userDefaults.set("endOfEpisode", forKey: timerModeKey)
        case .timer(let minutes):
            userDefaults.set("timer", forKey: timerModeKey)
            userDefaults.set(minutes, forKey: timerMinutesKey)
        case .none:
            userDefaults.removeObject(forKey: timerModeKey)
        }
        
        userDefaults.synchronize()
    }
    
    func clearTimerState() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: timerActiveKey)
        userDefaults.removeObject(forKey: timerEndTimeKey)
        userDefaults.removeObject(forKey: timerMinutesKey)
        userDefaults.removeObject(forKey: timerModeKey)
        userDefaults.synchronize()
        
        sleepTimerActive = false
        sleepTimerMode = .none
        sleepTimerMinutes = nil
        sleepTimerEndTime = nil
    }
}

// MARK: - Sleep Timer Sheet
struct SleepTimerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Binding var sleepTimerMode: SleepTimerMode
    @Binding var sleepTimerActive: Bool
    @Binding var sleepTimerMinutes: Int?
    @Binding var sleepTimerEndTime: Date?
    @ObservedObject var podcastPlayer: PodcastPlayer
    let episode: PodcastEpisode
    let saveTimerState: () -> Void
    let clearTimerState: () -> Void
    
    @State private var showCustomPicker = false
    @State private var customMinutes = 30
    
    private let quickTimerOptions = [60, 120, 180, 240, 300]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    // Drag indicator
                    SheetGrabber()
                    
                    Text("Sleep Timer")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Quick timer buttons section
                        VStack(spacing: 16) {
                            HStack(spacing: 12) {
                                ForEach(quickTimerOptions, id: \.self) { minutes in
                                    Button(action: {
                                        setTimer(minutes: minutes)
                                    }) {
                                        VStack(spacing: 4) {
                                            Text("\(minutes)")
                                                .font(.system(size: 28, weight: .semibold))
                                            Text("MIN")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                        }
                                        .foregroundColor(.white)
                                        .frame(width: 60, height: 60)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.blue)
                                        )
                                    }
                                }
                            }
                            
                            // Custom button
                            Button(action: {
                                showCustomPicker = true
                            }) {
                                HStack {
                                    Text("Custom...")
                                        .font(.body)
                                        
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.gray.opacity(0.08))
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(12)
                        // Line the first card up with the one below it on iPhone Duo's narrow display.
                        .padding(.horizontal, TabBarClearance.shared.isBarOnSide ? 16 : 0)
                        
                        // Timer options section
                        VStack(spacing: 16) {
                            // Active timer display
                            if sleepTimerActive, let endTime = sleepTimerEndTime {
                                Button(action: {
                                    cancelTimer()
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Stop After \(timeRemaining(until: endTime))")
                                                .font(.body)
                                                .foregroundColor(.primary)
                                            Text("Tap to cancel")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.title3)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(12)
                            }
                            
                            // Stop after episode option
                            Button(action: {
                                setTimerEndOfEpisode()
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Stop After This Episode")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if case .endOfEpisode = sleepTimerMode {
                                            Text("Active")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if case .endOfEpisode = sleepTimerMode {
                                        Image(systemName: "checkmark.circle.fill")
                                            
                                            .font(.title3)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 150)
                }
            }
            .duoSheetBalance()
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomTimerPicker(customMinutes: $customMinutes) {
                setTimer(minutes: customMinutes)
                showCustomPicker = false
            }
            .presentationDetents([.height(250)])
            .presentationDragIndicator(.visible)
        }
    }
    
    private func setTimer(minutes: Int) {
        sleepTimerMinutes = minutes
        sleepTimerEndTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerMode = .timer(minutes: minutes)
        sleepTimerActive = true
        
        // Save timer state to UserDefaults
        saveTimerState()
        
        // Schedule timer to pause playback
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60)) {
            if sleepTimerActive, case .timer(let mins) = sleepTimerMode, mins == minutes {
                podcastPlayer.pause()
                sleepTimerActive = false
                sleepTimerMode = .none
                sleepTimerEndTime = nil
                clearTimerState()
            }
        }
        
        dismiss()
    }
    
    private func setTimerEndOfEpisode() {
        sleepTimerMode = .endOfEpisode
        sleepTimerActive = true
        sleepTimerMinutes = nil
        sleepTimerEndTime = nil
        
        // Save timer state to UserDefaults
        saveTimerState()
        
        // Monitor for end of episode
        // This will be handled by the player's completion handler
        
        dismiss()
    }
    
    private func cancelTimer() {
        sleepTimerActive = false
        sleepTimerMode = .none
        sleepTimerMinutes = nil
        sleepTimerEndTime = nil
        
        // Clear timer state from UserDefaults
        clearTimerState()
    }
    
    private func timeRemaining(until endTime: Date) -> String {
        let remaining = Int(endTime.timeIntervalSinceNow)
        if remaining <= 0 {
            return "0:00"
        }
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Custom Timer Picker
struct CustomTimerPicker: View {
    @Environment(\.dismiss) var dismiss
    @Binding var customMinutes: Int
    let onSet: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Custom Timer")
                .font(.headline)
                .padding(.top)
            
            Picker("Minutes", selection: $customMinutes) {
                ForEach(1..<301) { minute in
                    Text("\(minute) min").tag(minute)
                }
            }
            .pickerStyle(WheelPickerStyle())
            .frame(height: 120)
            
            Button(action: onSet) {
                Text("Set Timer")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
