//
//  PodcastPreviewView.swift
//  StreamRadios
//
//  Created by Assistant on 12/27/24.
//

import SwiftUI

struct PodcastPreviewView: View {
    @Binding var isPresented: Bool
    let podcast: PodcastFeed
    var parentDismissal: Binding<Bool>?
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    @State private var episodes: [PodcastEpisode] = []
    @State private var isLoadingEpisodes = false
    @State private var showingAddPodcast = false
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    // Progress indicator state
    @State private var isAddingPodcast = false
    @State private var addingProgress: Double = 0.0
    @State private var addingStageText = ""
    

    
    @State private var presentedEpisode: PodcastEpisode?
    @State private var selectedEpisode: PodcastEpisode?
    @State private var enhancedFeed: PodcastFeed?
    
    private var showingEpisodeNotes: Binding<Bool> {
        Binding(
            get: { presentedEpisode != nil },
            set: { newValue in
                if !newValue {
                    presentedEpisode = nil
                    selectedEpisode = nil
                }
            }
        )
    }
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.adaptiveBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Podcast Header
                        podcastHeaderView
                        
                        // Add Podcast Button
                        addPodcastButton
                        
                        // Description
                        if let description = podcast.descriptionText, !description.isEmpty {
                            descriptionView(description)
                        }
                        
                        // Episodes List
                        episodesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 100) // Extra padding for bottom
                }
            }
            .navigationTitle("Podcast Preview")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(leading: 
                Button("Cancel") {
                    isPresented = false
                }
                .foregroundColor(.accentColor)
            )
        }
        .onAppear {
            print("PodcastPreviewView appeared for: \(podcast.title)")
            print("Podcast URL: \(podcast.url)")
            setupForPreview()
            loadEpisodes()
            enhancePreviewFeed()
        }
        .sheet(isPresented: $showingAddPodcast) {
            AddPodcastView(
                isPresented: $showingAddPodcast,
                title: $newPodcastTitle,
                url: $newPodcastURL,
                podcastToEdit: nil,
                onAdd: addPodcastAction,
                onUpdate: nil
            )
        }
        .sheet(isPresented: showingEpisodeNotes) {
            if let presentedEpisode = presentedEpisode {
                // Use enhancedFeed if available, otherwise fallback to original podcast
                let feedToUse = enhancedFeed ?? podcast
                PodcastChaptersNotesView(
                    episode: presentedEpisode,
                    feed: feedToUse,
                    podcastPlayer: PodcastPlayer.shared,
                    isPresented: showingEpisodeNotes
                )
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("Episode Not Found")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("The selected episode could not be loaded. Please try again.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Close") {
                        presentedEpisode = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .overlay(
            Group {
                if isAddingPodcast {
                    Color.black.opacity(0.75).edgesIgnoringSafeArea(.all)
                    PodcastAddingProgressView(
                        progress: addingProgress,
                        stageText: addingStageText
                    )
                    .transition(.opacity)
                }
            }
        )
    }
    
    @ViewBuilder
    private var podcastHeaderView: some View {
        VStack(spacing: 16) {
            // Podcast Artwork
            AsyncImage(url: URL(string: enhanceArtworkUrl(podcast.artworkUrl ?? ""))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .clipped()
                case .failure(_):
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        )
                        .frame(width: 200, height: 200)
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                                .scaleEffect(1.2)
                        )
                        .frame(width: 200, height: 200)
                @unknown default:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 200, height: 200)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            
            // Podcast Title
            VStack(spacing: 8) {
                Text(podcast.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }
        }
    }
    
    @ViewBuilder
    private var addPodcastButton: some View {
        Button(action: {
            addPodcastAction(nil)
        }) {
            HStack {
                Image(systemName: "plus")
                    .font(.headline)
                Text("Add Podcast")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 25)
                    .fill(Color.accentColor)
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func descriptionView(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Episodes")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isLoadingEpisodes {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if isLoadingEpisodes {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading episodes...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(episodes, id: \.id) { episode in
                        VStack {
                            PreviewEpisodeRowView(episode: episode, onTap: {
                                // Show notes when tapped
                                presentedEpisode = episode
                                selectedEpisode = episode
                            })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func setupForPreview() {
        newPodcastTitle = podcast.title
        newPodcastURL = podcast.url
    }
    
    private func enhanceArtworkUrl(_ originalUrl: String) -> String {
        // Try to enhance artwork URL for higher resolution
        // Many podcast feeds provide low-res artwork by default
        var enhancedUrl = originalUrl
        
        // For iTunes/Apple Podcasts artwork, try to get larger versions
        if enhancedUrl.contains("mzstatic.com") {
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "60x60", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "100x100", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "170x170", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "300x300", with: "600x600")
        }
        
        // For other common CDNs, try common size replacements
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_60.jpg", with: "_600.jpg")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_100.jpg", with: "_600.jpg")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_small.jpg", with: "_large.jpg")
        
        return enhancedUrl
    }
    

    private func enhancePreviewFeed() {
        // Create enhanced feed with artwork data for proper display in notes view
        Task {
            var enhanced = podcast
            
            // Download artwork if available
            if let artworkUrlString = podcast.artworkUrl, 
               let artworkUrl = URL(string: enhanceArtworkUrl(artworkUrlString)) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: artworkUrl)
                    enhanced.imageData = data
                    print("🎨 Downloaded artwork for podcast: \(podcast.title)")
                } catch {
                    print("⚠️ Failed to download artwork: \(error)")
                }
            }
            
            await MainActor.run {
                self.enhancedFeed = enhanced
            }
        }
    }
    
    private func loadEpisodes() {
        guard let feedURL = URL(string: podcast.url) else { 
            print("Invalid podcast URL: \(podcast.url)")
            return 
        }
        
        // Reset episodes and start loading
        episodes = []
        isLoadingEpisodes = true
        
        Task {
            do {
                print("Loading episodes from: \(feedURL)")
                let (feedData, _) = try await URLSession.shared.data(from: feedURL)
                let parser = RSSFeedParser(data: feedData, feedUrl: podcast.url)
                let (_, parsedEpisodes) = try parser.parseComplete()
                
                await MainActor.run {
                    print("Successfully loaded \(parsedEpisodes.count) episodes")
                    self.episodes = parsedEpisodes
                    self.isLoadingEpisodes = false
                }
            } catch {
                await MainActor.run {
                    print("Error loading episodes: \(error)")
                    self.isLoadingEpisodes = false
                    // Keep episodes empty on error
                }
            }
        }
    }
    
    private func addPodcastAction(_ podcastId: String?) {
        // Validate inputs
        guard !newPodcastTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Please enter a podcast title."
            showAlert = true
            return
        }
        
        guard !newPodcastURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              URL(string: newPodcastURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            alertMessage = "Please enter a valid RSS feed URL."
            showAlert = true
            return
        }
        
        // Add podcast with progress indication
        addPodcastWithProgress()
    }
    
    private func addPodcastWithProgress() {
        isAddingPodcast = true
        addingProgress = 0.0
        addingStageText = "Preparing to add podcast..."
        
        Task {
            do {
                // Stage 1: Validate URL
                await updateProgress(0.1, "Connecting to podcast feed...")
                try await Task.sleep(nanoseconds: 200_000_000) // Brief pause for UI
                
                // Stage 2: Download and parse RSS feed
                await updateProgress(0.3, "Downloading podcast RSS feed...")
                
                // Add the podcast feed using the ViewModel with custom title
                let customTitle = newPodcastTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let customTitleToUse = customTitle.isEmpty ? nil : customTitle
                let success = await podcastViewModel.addPodcastFeed(
                    url: newPodcastURL.trimmingCharacters(in: .whitespacesAndNewlines), 
                    customTitle: customTitleToUse
                )
                
                if success {
                    // Stage 3: Processing episodes and artwork
                    await updateProgress(0.6, "Processing episodes and downloading artwork...")
                    try await Task.sleep(nanoseconds: 800_000_000) // Allow time for RSS parsing and artwork download
                    
                    // Stage 4: Saving to Core Data and CloudKit
                    await updateProgress(0.8, "Saving to your podcast library...")
                    try await Task.sleep(nanoseconds: 400_000_000) // Allow time for Core Data and CloudKit sync
                    
                    // Stage 5: Finalizing and updating UI
                    await updateProgress(0.95, "Finalizing podcast import...")
                    try await Task.sleep(nanoseconds: 300_000_000) // Allow background operations to complete
                    
                    // Stage 6: Complete - Feed should now be visible
                    await updateProgress(1.0, "Podcast added successfully!")
                    
                    await MainActor.run {
                        isAddingPodcast = false
                        
                        // Get the newly added podcast ID for auto-focus
                        let newPodcastId = podcastViewModel.podcastFeedOrder.last
                        print("🎯 PodcastPreviewView: Successfully added podcast, last ID in order: \(newPodcastId ?? "nil")")
                        if let podcastId = newPodcastId {
                            print("🎯 PodcastPreviewView: Posting focus notification for podcast ID: \(podcastId)")
                            // Notify PodcastListView to auto-focus on the new podcast
                            NotificationCenter.default.post(name: .podcastAddedForFocus, object: podcastId)
                        } else {
                            print("🎯 PodcastPreviewView: No podcast ID to focus on")
                        }
                        
                        // Clear the input fields for next time
                        newPodcastTitle = ""
                        newPodcastURL = ""
                        
                        // Dismiss both the preview and the parent search sheet immediately
                        isPresented = false
                        parentDismissal?.wrappedValue = false
                    }
                } else {
                    await MainActor.run {
                        isAddingPodcast = false
                        alertMessage = podcastViewModel.error ?? "Failed to add podcast. Please check the URL and try again."
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    isAddingPodcast = false
                    alertMessage = "Failed to add podcast: \(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
    
    @MainActor
    private func updateProgress(_ progress: Double, _ text: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            addingProgress = progress
            addingStageText = text
        }
    }
}

// MARK: - Episode Notes View
struct EpisodeNotesView: View {
    let episode: PodcastEpisode
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Episode Header
                    VStack(alignment: .leading, spacing: 12) {
                        Text(episode.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        
                        HStack {
                            Text(formatDate(episode.publicationDate))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            if episode.duration > 0 {
                                Text("•")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(formatDuration(episode.duration))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                    
                    Divider()
                    
                    // Episode Notes/Description
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Episode Notes")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if !episode.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(episode.descriptionText.htmlStripped)
                                .font(.body)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        } else {
                            Text("No episode notes available.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color.adaptiveBackground)
            .navigationTitle("Episode Details")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(leading: 
                Button("Done") {
                    isPresented = false
                }
                .foregroundColor(.accentColor)
            )
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) % 3600 / 60
        
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else {
            return String(format: "%dm", minutes)
        }
    }
}

// MARK: - Preview Episode Row View

struct PreviewEpisodeRowView: View {
    let episode: PodcastEpisode
    let onTap: () -> Void
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    private var formattedDuration: String {
        if episode.duration > 0 {
            return Self.durationFormatter.string(from: episode.duration) ?? ""
        }
        return ""
    }
    
    private var formattedDate: String {
        Self.dateFormatter.string(from: episode.publicationDate)
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    
                    if !episode.descriptionText.isEmpty {
                        Text(episode.descriptionText.htmlStripped)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    
                    HStack(spacing: 8) {
                        Text(formattedDate)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if !formattedDuration.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Text(formattedDuration)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Arrow indicator
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(0.6)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color.adaptiveCardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.adaptiveBorder, lineWidth: 0.5)
        )
    }
}

// Extension to strip HTML tags
extension String {
    var htmlStripped: String {
        return self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
    }
}
