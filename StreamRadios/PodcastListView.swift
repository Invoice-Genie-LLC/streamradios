//
//  PodcastListView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/8/24.
//

import SwiftUI
import Combine
import os
import AVKit

struct PodcastListView: View {
    @StateObject private var viewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var selectedPodcast: PodcastFeed?
    @State private var searchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var expandedFeedId: String?
    @State private var isEditing = false
    
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "PodcastListView")
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    instructionText
                    searchBar
                    podcastList
                }
                .navigationTitle("Podcasts")
                .toolbar {
                    ToolbarItems(isEditing: $isEditing, onAddTapped: { showingAddPodcast = true }, onSortTapped: viewModel.sortFeedsAlphabetically)
                }
                .onAppear(perform: onAppear)
                .sheet(isPresented: $showingAddPodcast) {
                    AddPodcastView(isPresented: $showingAddPodcast, title: $newPodcastTitle, url: $newPodcastURL, onAdd: addPodcast)
                }
                .sheet(item: $selectedPodcast) { podcast in
                    PodcastPlayerView(
                        viewModel: viewModel,
                        feed: podcast,
                        initialScrollToEpisodeID: podcastPlayer.currentEpisode?.id,
                        podcastPlayer: podcastPlayer,
                        episodeToScrollTo: Binding(
                            get: {
                                podcastPlayer.currentEpisode
                            },
                            set: { _ in }
                        )
                        
                    )
                }
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                
                miniPlayer
            }
        }
        .alert(isPresented: $viewModel.showNoEpisodesAlert) {
            Alert(
                title: Text("No Episodes in Progress"),
                message: Text(viewModel.noEpisodesAlertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    private var instructionText: some View {
        Text("Tap on a podcast image to explore its episodes and discover more content.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
    }
    
    private var searchBar: some View {
        TextField("Search podcasts", text: $searchText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(.horizontal)
            .autocapitalization(.none)
            .disableAutocorrection(true)
    }
    
    private var podcastList: some View {
        List {
            ForEach(viewModel.podcastFeedOrder, id: \.self) { feedId in
                if let feed = viewModel.podcastFeeds.first(where: { $0.id == feedId }),
                   filteredPodcasts.contains(where: { $0.id == feedId }) {
                    PodcastRowView(
                        feed: feed,
                        isPlaying: podcastPlayer.currentEpisode?.feedId == feed.id && podcastPlayer.isPlaying,
                        onPlay: { podcastPlayer.playLastEpisodeForFeed(feed) },
                        onStop: { podcastPlayer.togglePlayPause() },
                        onTap: { selectedPodcast = feed },
                        isExpanded: Binding(
                            get: { expandedFeedId == feed.id },
                            set: { isExpanded in
                                expandedFeedId = isExpanded ? feed.id : nil
                            }
                        ),
                        viewModel: viewModel,
                        podcastPlayer: podcastPlayer
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            podcastToDelete = feed
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove(perform: viewModel.moveFeed)
            Spacer()
                .frame(height: 100)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(PlainListStyle())
        .alert("Delete Podcast", isPresented: $showingDeleteConfirmation, presenting: podcastToDelete) { podcast in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deletePodcastFeed(podcast)
            }
        } message: { podcast in
            Text("Are you sure you want to delete '\(podcast.title)'? This action cannot be undone.")
        }
    }
    
    private var miniPlayer: some View {
        Group {
            if podcastPlayer.currentEpisode != nil {
                MiniPlayerView(
                    podcastPlayer: podcastPlayer,
                    viewModel: viewModel,
                    selectedPodcast: $selectedPodcast,
                    onListButtonTap: {
                        selectedPodcast = podcastPlayer.currentFeed
                    },
                    onCloseButtonTap: {
                        podcastPlayer.pause()
                        podcastPlayer.currentEpisode = nil
                        podcastPlayer.currentFeed = nil
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
    }
    
    private func onAppear() {
        os_log("PodcastListView appeared", log: log, type: .info)
        viewModel.loadFeedOrder()
        viewModel.fetchPodcastFeeds()
    }
    
    private func addPodcast() {
        let newFeed = PodcastFeed(id: UUID().uuidString, title: newPodcastTitle, url: newPodcastURL)
        viewModel.addPodcastFeed(newFeed)
        newPodcastTitle = ""
        newPodcastURL = ""
        showingAddPodcast = false
    }
    
    private func playLatestEpisode(for feed: PodcastFeed) {
        viewModel.fetchEpisodes(for: feed) { result in
            switch result {
            case .success(let episodes):
                if let latestEpisode = episodes.first {
                    podcastPlayer.playEpisode(latestEpisode, feed: feed)
                }
            case .failure(let error):
                os_log("Failed to fetch episodes: %@", log: log, type: .error, error.localizedDescription)
            }
        }
    }
    
    var filteredPodcasts: [PodcastFeed] {
        if searchText.isEmpty {
            return viewModel.podcastFeeds
        } else {
            return viewModel.podcastFeeds.filter { feed in
                feed.title.lowercased().contains(searchText.lowercased()) ||
                (feed.descriptionText?.lowercased().contains(searchText.lowercased()) ?? false)
            }
        }
    }
}

struct ToolbarItems: ToolbarContent {
    @Binding var isEditing: Bool
    let onAddTapped: () -> Void
    let onSortTapped: () -> Void
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                isEditing.toggle()
            }) {
                Text(isEditing ? "Done" : "Edit")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !isEditing {
                Button(action: onSortTapped) {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Button(action: onAddTapped) {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

struct PodcastRowView: View {
    let feed: PodcastFeed
    let isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onTap: () -> Void
    @Binding var isExpanded: Bool
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PodcastIconView(iconData: feed.iconData, artworkUrl: feed.artworkUrl)
                .frame(width: 70, height: 70)
                .cornerRadius(10)
                .padding(.top, 10)
                .padding(.trailing, 8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(2)
                    .alignmentGuide(.top) { d in d[.top] }
                
                if isExpanded {
                    Text(feed.descriptionText ?? "No description available")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(feed.descriptionText ?? "No description available")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                HStack {
                    if !isExpanded && (feed.descriptionText?.count ?? 0) > 100 {
                        Button(action: {
                            isExpanded.toggle()
                        }) {
                            Text("Read More")
                                .font(.footnote)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Spacer()
                    
                    if isPlaying {
                        Button(action: {
                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                            impactFeedback.impactOccurred()
                            onStop()
                        }) {
                            HStack {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundColor(.blue)
                                Text("Pause")
                                    .font(.footnote)
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onStop()
                        }
                    } else {
                        Button(action: {
                            checkAndPlayEpisode()
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                    .foregroundColor(.green)
                                Text("Continue Listening")
                                    .font(.footnote)
                                    .foregroundColor(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onPlay)
                    }
                }
            }
            .padding(.vertical, 6)
            .alignmentGuide(.top) { d in d[.top] }
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
    
    private func checkAndPlayEpisode() {
        let feedEpisodes = viewModel.allEpisodes.filter { $0.feedId == feed.id }
        let episodesInProgress = feedEpisodes.filter { $0.state.progress > 0 && $0.state.progress < 1 }
        
        if episodesInProgress.isEmpty {
            viewModel.showNoEpisodesInProgressAlert(for: feed)
            if let latestEpisode = feedEpisodes.sorted(by: { $0.publicationDate > $1.publicationDate }).first {
                podcastPlayer.playEpisode(latestEpisode, feed: feed)
            }
        } else {
            onPlay()
        }
    }
}

struct PodcastIconView: View {
    let iconData: String?
    let artworkUrl: String?
    
    var body: some View {
        Group {
            if let iconData = iconData, let uiImage = UIImage(data: Data(base64Encoded: iconData) ?? Data()) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 70, height: 70)
                    .cornerRadius(10)
            } else if let artworkUrl = artworkUrl, let url = URL(string: artworkUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 70, height: 70)
                            .cornerRadius(10)
                    case .failure:
                        Image(systemName: "photo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 70, height: 70)
                            .cornerRadius(10)
                            .foregroundColor(.gray)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "mic.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 70, height: 70)
                    .padding(16)
                    .background(Color.blue.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}

struct EpisodeRowView: View {
    let episode: PodcastEpisode
    var isPlaying: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var progress: Double
    @State private var isDownloading: Bool = false
    @State private var showingDeleteConfirmation = false
    @State private var showingBannerAlert = false
    @State private var bannerAlertMessage = ""
    private let buttonSize: CGFloat = 22
    private let rowHeight: CGFloat = 70
    private var remainingTime: Double {
        if isPlaying {
            return podcastPlayer.remainingTime
        } else {
            return episode.duration * (1 - progress)
        }
    }
    
    init(episode: PodcastEpisode, isPlaying: Bool, onPlay: @escaping () -> Void, onStop: @escaping () -> Void, viewModel: PodcastViewModel, podcastPlayer: PodcastPlayer) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onStop = onStop
        self.viewModel = viewModel
        self.podcastPlayer = podcastPlayer
        _progress = State(initialValue: viewModel.getProgress(for: episode))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            if showingBannerAlert {
                Text(bannerAlertMessage)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
            }
            
            HStack(alignment: .center, spacing: 10) {
                // Play/Pause button
                Button(action: {
                    let progress = podcastPlayer.getCurrentProgress(for: episode)
                    if episode.state.isPlayed || progress >= 0.99 {
                        podcastPlayer.rewindAndPlay(episode: episode)
                    } else if isPlaying {
                        onStop()
                    } else {
                        onPlay()
                    }
                }) {
                    Image(systemName: episode.state.isPlayed || progress >= 0.99 ? "arrow.counterclockwise.circle.fill" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(episode.state.isPlayed || progress >= 0.99 ? .blue : (isPlaying ? .blue : .green))
                }
                .frame(width: buttonSize, height: buttonSize)
                
                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    // Episode title (2 lines)
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    // Episode info and status
                    HStack(spacing: 2) {
                        episodeStatusIndicator
                            .fixedSize()
                        Text("•")
                            .fixedSize()
                        Text(formatDate(episode.publicationDate))
                            .lineLimit(1)
                        Text("•")
                            .fixedSize()
                        Text(formatRemainingTime())
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Right column: File size, Bookmark button, Download button
                VStack(alignment: .trailing, spacing: 4) {
                    // File size
                    if let fileSize = episode.fileSize, fileSize > 0 {
                        Text(formatFileSize(fileSize))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Bookmark button
                    Button(action: {
                        if isPlaying {
                            showBannerAlert(message: "You can't add or remove favorites while the episode is playing.")
                        } else {
                            viewModel.toggleFavorite(for: episode)
                        }
                    }) {
                        Image(systemName: episode.state.isFavorite ? "bookmark.fill" : "bookmark")
                            .foregroundColor(episode.state.isFavorite ? .blue : .gray)
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    
                    // Download button or trash can
                    Group {
                        if viewModel.currentTab == 2 && episode.state.isDownloaded {
                            Button(action: {
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .frame(width: buttonSize, height: buttonSize)
                            }
                        } else {
                            downloadButton
                        }
                    }
                    .frame(width: buttonSize, height: buttonSize)
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, 10)
            
            // Progress bar (only for playing episode)
            if isPlaying {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 3)
                        
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * CGFloat(progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Downloaded Episode"),
                message: Text("Are you sure you want to delete this downloaded episode?"),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.deleteDownloadedEpisode(episode)
                },
                secondaryButton: .cancel()
            )
        }
        .onReceive(podcastPlayer.$currentProgress) { _ in
            if podcastPlayer.currentEpisode?.id == episode.id {
                progress = podcastPlayer.currentProgress
            }
        }
        .onReceive(viewModel.$episodeProgress) { _ in
            progress = viewModel.getProgress(for: episode)
        }
    }
    
    
    
    private var episodeStatusIndicator: some View {
        Group {
            if episode.state.isPlayed || progress >= 0.99 {
                Text("Played")
                    .foregroundColor(.gray)
            } else if isPlaying {
                Text("Playing")
                    .foregroundColor(.blue)
            } else if progress > 0 {
                Text("In Progress")
                    .foregroundColor(.orange)
            } else {
                Text("New")
                    .foregroundColor(.green)
            }
        }
        .font(.caption2)
        .fontWeight(.semibold)
    }
    
    private var downloadButton: some View {
        Button(action: {
            if isPlaying {
                showBannerAlert(message: "You can't download episodes while playing.")
            } else if !episode.state.isDownloaded && !isDownloading {
                isDownloading = true
                viewModel.downloadEpisode(episode) { result in
                    DispatchQueue.main.async {
                        isDownloading = false
                    }
                }
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: buttonSize, height: buttonSize)
                
                if episode.state.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.green)
                } else if isDownloading {
                    Circle()
                        .trim(from: 0, to: CGFloat(viewModel.downloadProgress[episode.id] ?? 0))
                        .stroke(Color.blue, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: buttonSize, height: buttonSize)
                    
                    Image(systemName: "arrow.down")
                        .font(.system(size: buttonSize * 0.5))
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private func showBannerAlert(message: String) {
        bannerAlertMessage = message
        showingBannerAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingBannerAlert = false
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    private func formatRemainingTime() -> String {
        return formatTime(remainingTime)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d remaining", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d remaining", minutes, seconds)
        }
    }
    
    
}

struct PodcastPlayerView: View {
    @ObservedObject var viewModel: PodcastViewModel
    @Environment(\.presentationMode) var presentationMode
    let feed: PodcastFeed
    let initialScrollToEpisodeID: String?
    @ObservedObject var podcastPlayer: PodcastPlayer
    @State private var selectedTab = 0
    @State private var seekPosition: Double = 0
    @State private var isSeekingManually = false
    @State private var debounceTimer: Timer?
    @State private var scrollToEpisodeID: String?
    @Binding var episodeToScrollTo: PodcastEpisode?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var hasScrolledToInitialEpisode = false
    
    private var sliderRange: ClosedRange<Double> {
        0...max(podcastPlayer.duration, 0.01)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation bar
            HStack {
                Button(action: updateViewModelAndDismiss) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.primary)
                }
                Spacer()
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                AirPlayButton()
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal)
            .frame(height: 44)
            .background(Color(UIColor.systemBackground))
            
            // Pinned player area
            VStack(spacing: 12) {
                // Centered, smaller feed image
                FeedImageView(feed: feed)
                    .frame(width: 120, height: 120)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
                
                VStack(alignment: .center, spacing: 4) {
                    Text(podcastPlayer.currentEpisode?.title ?? "No episode playing")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    
                    if let currentEpisode = podcastPlayer.currentEpisode {
                        Text(formatDate(currentEpisode.publicationDate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                // Progress slider
                ProgressSlider(
                    value: $seekPosition,
                    inRange: sliderRange,
                    onEditingChanged: { editing in
                        isSeekingManually = editing
                        if !editing {
                            podcastPlayer.seek(to: seekPosition)
                        }
                    }
                )
                .frame(height: 4)
                .padding(.horizontal)
                
                // Time labels
                HStack {
                    Text(formatTime(podcastPlayer.currentTime))
                    Spacer()
                    Text("-" + formatTime(podcastPlayer.remainingTime))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                
                // Playback controls
                HStack(spacing: 20) {
                    Button(action: podcastPlayer.skipBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 20))
                    }
                    
                    Button(action: podcastPlayer.togglePlayPause) {
                        Image(systemName: podcastPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: podcastPlayer.skipForward) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 20))
                    }
                }
                .foregroundColor(.primary)
                .padding(.bottom, 8)
            }
            .padding(.vertical, 6)
            .background(Color(UIColor.secondarySystemBackground))
            
            // Episode filter tabs
            episodeFilterTabs
            
            Group {
                if viewModel.isLoadingEpisodes {
                    ProgressView("Loading episodes...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        ScrollViewReader { proxy in
                            episodeList
                                .onAppear {
                                    scrollProxy = proxy
                                    scrollToEpisodeIfNeeded()
                                }
                        }
                    }
                }
            }
        }
        .onDisappear {
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: viewModel.currentTab)
        }
        .onAppear {
            loadEpisodes()
        }
        
        
        .onAppear {
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: selectedTab)
            seekPosition = podcastPlayer.currentTime
        }
        .onReceive(podcastPlayer.$currentTime) { _ in
            if !isSeekingManually {
                seekPosition = podcastPlayer.currentTime
            }
        }
        .onChange(of: episodeToScrollTo) { _ in
            scrollToEpisodeIfNeeded()
        }
        // ReconnectingIndicatorView(isAttemptingReconnection: $podcastPlayer.isAttemptingReconnection)
        .navigationBarHidden(true)
    }
    
    private func loadEpisodes() {
        viewModel.fetchEpisodes(for: feed) { result in
            switch result {
            case .success(let episodes):
                // Episodes are now automatically updated in the viewModel with correct statuses
                print("Loaded \(episodes.count) episodes with bookmark and download statuses")
            case .failure(let error):
                print("Failed to load episodes: \(error.localizedDescription)")
            }
        }
    }
    
    private var episodeFilterTabs: some View {
        Picker("", selection: $selectedTab) {
            Text("All").tag(0)
            Text("Favorites").tag(1)
            Text("Downloads").tag(2)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
        .onChange(of: selectedTab) { newValue in
            viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: newValue)
        }
    }
    
    private var episodeList: some View {
        LazyVStack(spacing: 8) {
            ForEach(viewModel.currentEpisodes) { episode in
                EpisodeRowView(
                    episode: episode,
                    isPlaying: podcastPlayer.currentEpisode?.id == episode.id && podcastPlayer.isPlaying,
                    onPlay: { playEpisode(episode) },
                    onStop: { podcastPlayer.togglePlayPause() },
                    viewModel: viewModel,
                    podcastPlayer: podcastPlayer
                )
                .id(episode.id)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private func scrollToInitialEpisode() {
        if let initialID = initialScrollToEpisodeID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation {
                    scrollProxy?.scrollTo(initialID, anchor: .top)
                }
            }
        }
    }
    
    private func updateViewModelAndDismiss() {
        if let currentEpisode = podcastPlayer.currentEpisode {
            // Update progress
            viewModel.updateProgress(for: currentEpisode, progress: podcastPlayer.currentProgress)
            
            // Update favorite (bookmark) state
            if currentEpisode.state.isFavorite != viewModel.favoriteEpisodes.contains(where: { $0.id == currentEpisode.id }) {
                viewModel.toggleFavorite(for: currentEpisode)
            }
            
            // Update download state
            let isDownloaded = viewModel.downloadedEpisodes.contains(where: { $0.id == currentEpisode.id })
            if currentEpisode.state.isDownloaded != isDownloaded {
                if isDownloaded {
                    // If it's downloaded in the viewModel but not in the current episode state, update the current episode
                    var updatedEpisode = currentEpisode
                    updatedEpisode.state.isDownloaded = true
                    viewModel.updateEpisode(updatedEpisode)
                } else {
                    // If it's not downloaded in the viewModel but is in the current episode state, remove it from downloads
                    viewModel.deleteDownloadedEpisode(currentEpisode)
                }
            }
        }
        
        // Update filtered episodes
        viewModel.updateFilteredEpisodes(for: feed.id, selectedTab: viewModel.currentTab)
        
        // Dismiss the view
        presentationMode.wrappedValue.dismiss()
    }
    
    private func playEpisode(_ episode: PodcastEpisode) {
        if podcastPlayer.currentEpisode?.id == episode.id {
            if episode.state.isPlayed || podcastPlayer.currentProgress >= 0.99 {
                podcastPlayer.rewindAndPlay(episode: episode)
            } else {
                podcastPlayer.togglePlayPause()
            }
        } else {
            podcastPlayer.playEpisode(episode, feed: feed)
        }
    }
    
    private func scrollToEpisodeIfNeeded() {
        Task {
            // Add a short delay to ensure the view is fully loaded
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            await MainActor.run {
                if let episodeToScrollTo = episodeToScrollTo {
                    withAnimation {
                        scrollProxy?.scrollTo(episodeToScrollTo.id, anchor: .top)
                    }
                } else if let initialID = initialScrollToEpisodeID, !hasScrolledToInitialEpisode {
                    withAnimation {
                        scrollProxy?.scrollTo(initialID, anchor: .top)
                    }
                    hasScrolledToInitialEpisode = true
                }
            }
        }
    }
}

private func formatTime(_ time: Double) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%02d:%02d", minutes, seconds)
}




private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}


struct ProgressSlider: View {
    @Binding var value: Double
    let inRange: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 4)
                
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geometry.size.width * CGFloat((value - inRange.lowerBound) / (inRange.upperBound - inRange.lowerBound)), height: 4)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                    .offset(x: geometry.size.width * CGFloat((value - inRange.lowerBound) / (inRange.upperBound - inRange.lowerBound)) - 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let newValue = Double(gesture.location.x / geometry.size.width) * (inRange.upperBound - inRange.lowerBound) + inRange.lowerBound
                                value = min(max(newValue, inRange.lowerBound), inRange.upperBound)
                                onEditingChanged(true)
                            }
                            .onEnded { _ in
                                onEditingChanged(false)
                            }
                    )
            }
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let routePickerView = AVRoutePickerView()
        routePickerView.activeTintColor = .blue
        routePickerView.tintColor = .gray
        
        // Customize the button appearance
        if let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton {
            button.setImage(UIImage(systemName: "airplayaudio"), for: .normal)
            button.contentVerticalAlignment = .fill
            button.contentHorizontalAlignment = .fill
            button.imageEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        }
        
        return routePickerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PodcastList: View {
    let feeds: [PodcastFeed]
    @ObservedObject var viewModel: PodcastViewModel
    @ObservedObject var podcastPlayer: PodcastPlayer
    let onPlay: (PodcastFeed) -> Void
    let onDelete: (PodcastFeed) -> Void
    @Binding var selectedPodcast: PodcastFeed?
    @State private var expandedFeedId: String?
    
    var body: some View {
        List {
            ForEach(orderedFeeds, id: \.id) { feed in
                PodcastRowView(
                    feed: feed,
                    isPlaying: podcastPlayer.currentEpisode?.feedId == feed.id && podcastPlayer.isPlaying,
                    onPlay: {
                        if let episode = viewModel.getLastPlayedOrLatestEpisode(for: feed) {
                            podcastPlayer.playEpisode(episode, feed: feed)
                        }
                    },
                    onStop: { podcastPlayer.togglePlayPause() },
                    onTap: { selectedPodcast = feed },
                    isExpanded: Binding(
                        get: { expandedFeedId == feed.id },
                        set: { isExpanded in
                            expandedFeedId = isExpanded ? feed.id : nil
                        }
                    ),
                    viewModel: viewModel,  // Pass the viewModel here
                    podcastPlayer: podcastPlayer
                    
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onDelete(feed)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var orderedFeeds: [PodcastFeed] {
        let orderedIds = Set(viewModel.podcastFeedOrder)
        let orderedFeeds = feeds.filter { orderedIds.contains($0.id) }
            .sorted { viewModel.podcastFeedOrder.firstIndex(of: $0.id)! < viewModel.podcastFeedOrder.firstIndex(of: $1.id)! }
        let remainingFeeds = feeds.filter { !orderedIds.contains($0.id) }
        return orderedFeeds + remainingFeeds
    }
}
