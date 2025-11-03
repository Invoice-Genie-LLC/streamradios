//
//  SearchPodcastsView.swift
//  StreamRadios
//
//  Created by Assistant on 12/27/24.
//

import SwiftUI
import CryptoKit
import CommonCrypto

extension Notification.Name {
    static let podcastAddedForFocus = Notification.Name("podcastAddedForFocus")
}

struct SearchPodcastsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    @StateObject private var searchService = PodcastSearchService()
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showingAddPodcast = false
    @State private var selectedPodcast: PodcastFeed?
    @State private var presentedPodcast: PodcastFeed?
    
    private var showingPreview: Binding<Bool> {
        Binding(
            get: { presentedPodcast != nil },
            set: { newValue in
                if !newValue {
                    presentedPodcast = nil
                    selectedPodcast = nil
                }
            }
        )
    }
    @State private var newPodcastTitle = ""
    @State private var newPodcastURL = ""
    
    // Progress indicator state
    @State private var isAddingPodcast = false
    @State private var addingProgress: Double = 0.0
    @State private var addingStageText = ""
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Search Header - only show when search is presented
                    if isSearchPresented {
                        searchHeader
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            // Search Results
                            if searchService.isSearching {
                                loadingView
                            } else if !searchService.searchResults.isEmpty {
                                searchResultsList
                            } else if !searchText.isEmpty && !searchService.isSearching {
                                noResultsView
                            } else {
                                // Show popular podcasts section when no search
                                popularPodcastsSection
                            }
                            
                            // Error Message
                            if let error = searchService.searchError {
                                errorView(error)
                            }
                            
                            // Credit Section (required by PodcastIndex.org)
                            creditSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, isSearchPresented ? 0 : 20)
                        .padding(.bottom, 80)
                    }
                }
                .background(
                    Color.adaptiveBackground
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Search Podcasts")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        searchText = ""
                        isSearchPresented = false
                        searchService.clearResults()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        isPresented = false
                    }
                    .foregroundColor(.blue)
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Group {
                        if isSearchPresented {
                            // Cancel button when search is active
                            Button("Cancel") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isSearchPresented = false
                                    searchText = ""
                                    searchService.clearResults()
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.clear)
                            )
                        } else {
                            HStack(spacing: 8) {
                                // Search button
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isSearchPresented = true
                                    }
                                }) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.adaptivePrimaryText)
                                        .font(.system(size: 16, weight: .medium))
                                        .frame(width: 32, height: 32)
                                }
                                
                                // Separator
                                Text("|")
                                    .foregroundColor(.gray.opacity(0.5))
                                    .font(.system(size: 18))
                                
                                // Add URL button
                                Button("Add URL") {
                                    newPodcastTitle = ""
                                    newPodcastURL = ""
                                    showingAddPodcast = true
                                }
                                .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .onAppear {
                searchText = ""
                isSearchPresented = false
                searchService.clearResults()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                
                // Fetch popular podcasts when view appears
                Task {
                    await searchService.fetchPopularPodcasts()
                }
            }
            .onChange(of: isSearchPresented) { _, newValue in
                // Auto-focus search field when search is presented
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isSearchFieldFocused = true
                    }
                } else {
                    isSearchFieldFocused = false
                }
            }
        }
        .background(Color.adaptiveBackground)
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                        self.showAlert = false
                    }
                    .transition(.opacity)
                }
                
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
        .sheet(isPresented: $showingAddPodcast) {
            AddPodcastView(
                isPresented: $showingAddPodcast,
                title: $newPodcastTitle,
                url: $newPodcastURL,
                podcastToEdit: nil,
                onAdd: addPodcast,
                onUpdate: nil
            )
        }
        .sheet(isPresented: UIDevice.current.userInterfaceIdiom == .phone ? showingPreview : .constant(false)) {
            if let presentedPodcast = presentedPodcast {
                PodcastPreviewView(
                    isPresented: showingPreview,
                    podcast: presentedPodcast,
                    parentDismissal: $isPresented
                )
            }
        }
        .fullScreenCover(isPresented: UIDevice.current.userInterfaceIdiom == .pad ? showingPreview : .constant(false)) {
            if let presentedPodcast = presentedPodcast {
                PodcastPreviewView(
                    isPresented: showingPreview,
                    podcast: presentedPodcast,
                    parentDismissal: $isPresented
                )
            }
        }
    }
    
    // MARK: - UI Components
    
    @ViewBuilder
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search for podcasts...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.adaptivePrimaryText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($isSearchFieldFocused)
                    .onChange(of: searchText) { _, newValue in
                        performSearch(query: newValue)
                    }
                    .padding(.leading, 40) // Make space for search icon
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchService.clearResults()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.adaptiveFieldBackground)
            .cornerRadius(8)
            .overlay(
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .foregroundColor(.adaptiveSecondaryText)
                        .padding(.leading, 16)
                    Spacer()
                },
                alignment: .leading
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
    
    @ViewBuilder
    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Searching podcasts...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.adaptiveCardBackground)
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var searchResultsList: some View {
        LazyVStack(spacing: 12) {
            ForEach(searchService.searchResults, id: \.id) { result in
                PodcastSearchResultRow(result: result) {
                    // Dismiss keyboard when a podcast is selected
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    
                    // Show preview for the selected podcast
                    showPreview(for: result)
                }
            }
        }
    }
    
    @ViewBuilder
    private var popularPodcastsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("POPULAR PODCASTS")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.adaptiveSecondaryText)
                Spacer()
                
                if searchService.isLoadingPopular {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if searchService.isLoadingPopular && searchService.popularPodcasts.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading popular podcasts...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if searchService.popularPodcasts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.adaptiveSecondaryText)
                    
                    Text("Unable to load popular podcasts")
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    Text("Check your internet connection")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.adaptiveCardBackground)
                .cornerRadius(8)
            } else {
                // Loading state for popular podcasts
                if searchService.isLoadingPopular {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.adaptiveSecondaryText)
                        
                        Text("Loading Popular Podcasts...")
                            .font(.headline)
                            .foregroundColor(.adaptiveSecondaryText)
                        
                        Text("Fetching 300+ podcasts across 20 categories")
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .padding()
                } else if searchService.categorizedPopularPodcasts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        
                        Text("Failed to Load Popular Podcasts")
                            .font(.headline)
                            .foregroundColor(.adaptivePrimaryText)
                        
                        Text("Please check your internet connection and try again")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
                            .multilineTextAlignment(.center)
                        
                        Button("Retry") {
                            Task {
                                await searchService.fetchPopularPodcasts()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .padding()
                } else {
                    // Categorized popular podcasts sections
                    LazyVStack(spacing: 24) {
                        ForEach(searchService.categorizedPopularPodcasts, id: \.category) { categoryData in
                            VStack(alignment: .leading, spacing: 12) {
                                // Category header
                                HStack {
                                    Text(categoryData.category)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.adaptivePrimaryText)
                                    Spacer()
                                    Text("\(categoryData.podcasts.count)")
                                        .font(.caption)
                                        .foregroundColor(.adaptiveSecondaryText)
                                }
                                .padding(.horizontal, 4)
                                
                                // Album-style grid for category
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), 
                                    spacing: 16
                                ) {
                                    ForEach(categoryData.podcasts, id: \.id) { podcast in
                                        PopularPodcastItem(podcast: podcast) {
                                            // Dismiss keyboard when a podcast is selected
                                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                            
                                            // Show preview for the selected podcast
                                            showPreview(for: podcast)
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(.adaptiveSecondaryText)
            
            Text("No podcasts found")
                .font(.body)
                .foregroundColor(.primary)
            
            Text("Try adjusting your search terms")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.adaptiveCardBackground)
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var creditSection: some View {
        HStack(spacing: 4) {
            Text("Powered by")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Apple iTunes")
                .font(.caption)
                .foregroundColor(.adaptiveSecondaryText)
            
            Text("&")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("PodcastIndex.org")
                .font(.caption)
                .foregroundColor(.adaptiveSecondaryText)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Helper Methods
    
    private func performSearch(query: String) {
        searchTask?.cancel()
        
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedQuery.isEmpty else {
            searchService.clearResults()
            return
        }
        
        // Don't search for very short queries to avoid too many API calls
        guard trimmedQuery.count >= 2 else {
            return
        }
        
        searchTask = Task {
            // Debounce search by 800ms to reduce cancellations
            try? await Task.sleep(nanoseconds: 800_000_000)
            
            if !Task.isCancelled {
                await searchService.searchPodcasts(query: trimmedQuery)
            }
        }
    }
    
    private func addPodcastFromSearchResult(_ result: PodcastSearchResult) {
        isAddingPodcast = true
        addingProgress = 0.0
        addingStageText = "Preparing to add podcast..."
        
        // Notify DataSyncManager that individual feed addition started
        DataSyncManager.shared.startIndividualFeedAddition()
        
        Task {
            do {
                await updateProgress(0.1, "Connecting to podcast feed...")
                try await Task.sleep(nanoseconds: 200_000_000)
                
                await updateProgress(0.3, "Downloading podcast RSS feed...")
                
                let success = await podcastViewModel.addPodcastFeed(url: result.feedUrl, customTitle: result.title)
                
                if success {
                    await updateProgress(0.6, "Processing episodes and downloading artwork...")
                    try await Task.sleep(nanoseconds: 800_000_000)
                    
                    await updateProgress(0.8, "Saving to your podcast library...")
                    try await Task.sleep(nanoseconds: 400_000_000)
                    
                    await updateProgress(0.95, "Finalizing podcast import...")
                    try await Task.sleep(nanoseconds: 300_000_000)
                    
                    await updateProgress(1.0, "Podcast added successfully!")
                    
                    await MainActor.run {
                        isAddingPodcast = false
                        searchText = ""
                        searchService.clearResults()
                        
                        // Dismiss the search sheet immediately after successful addition
                        isPresented = false
                        
                        // CRITICAL FIX: Delay completion until after auto-focus operations have time to complete
                        // This prevents the main banner from appearing during auto-focus operations
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            DataSyncManager.shared.completeIndividualFeedAddition()
                            print("🔄 SearchPodcastsView: Delayed completion of individual feed addition")
                        }
                    }
                } else {
                    await MainActor.run {
                        isAddingPodcast = false
                        alertMessage = podcastViewModel.error ?? "Failed to add podcast. Please check the URL and try again."
                        showAlert = true
                        
                        // CRITICAL FIX: Delay completion even for errors to maintain consistency
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            DataSyncManager.shared.completeIndividualFeedAddition()
                            print("🔄 SearchPodcastsView: Delayed completion of individual feed addition (error case)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isAddingPodcast = false
                    alertMessage = "Failed to add podcast: \(error.localizedDescription)"
                    showAlert = true
                    
                    // CRITICAL FIX: Delay completion even for errors to maintain consistency
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        DataSyncManager.shared.completeIndividualFeedAddition()
                        print("🔄 SearchPodcastsView: Delayed completion of individual feed addition (exception case)")
                    }
                }
            }
        }
    }
    
    private func addPodcast(_ podcastId: String?) {
        // This is called when AddPodcastView successfully adds a podcast
        // Clear form fields and dismiss the search sheet
        newPodcastTitle = ""
        newPodcastURL = ""
        
        // If we have a podcast ID, trigger auto-focus in PodcastListView
        if let podcastId = podcastId {
            print("🎯 SearchPodcastsView: Posting focus notification for podcast ID: \(podcastId)")
            // Store the podcast ID to trigger auto-focus when we return to PodcastListView
            NotificationCenter.default.post(name: .podcastAddedForFocus, object: podcastId)
        } else {
            print("🎯 SearchPodcastsView: No podcast ID to focus on")
        }
        
        // Dismiss the search sheet after successful addition
        isPresented = false
    }
    
    private func showPreview(for result: PodcastSearchResult) {
        // Convert PodcastSearchResult to PodcastFeed for preview
        // Combine author and description for display
        var description = ""
        if let author = result.author {
            description += "By \(author)"
        }
        if let resultDescription = result.description {
            if !description.isEmpty {
                description += "\n\n"
            }
            description += resultDescription
        }
        
        let podcastFeed = PodcastFeed(
            title: result.title,
            url: result.feedUrl,
            artworkUrl: result.artworkUrl,
            description: description.isEmpty ? nil : description,
            episodes: [] // Episodes will be loaded in the preview
        )
        
        presentedPodcast = podcastFeed
        selectedPodcast = podcastFeed
    }
    
    @MainActor
    private func updateProgress(_ progress: Double, _ text: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            addingProgress = progress
            addingStageText = text
        }
    }
}

// MARK: - Popular Podcast Item

struct PopularPodcastItem: View {
    let podcast: PodcastSearchResult
    let onTap: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                // Podcast Artwork - Album style with enhanced quality
                AsyncImage(url: URL(string: podcast.artworkUrl ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high) // High quality scaling
                            .aspectRatio(1.0, contentMode: .fill) // Perfect square aspect ratio
                            .clipped()
                    case .failure:
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.adaptiveCardBackground, Color.adaptiveCardBackground.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .aspectRatio(1.0, contentMode: .fill)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "music.note.list")
                                        .font(.title3)
                                        .foregroundColor(.adaptiveSecondaryText.opacity(0.6))
                                    Text("No Image")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundColor(.adaptiveSecondaryText.opacity(0.8))
                                }
                            )
                    case .empty:
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.adaptiveCardBackground.opacity(0.3), Color.adaptiveCardBackground.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .aspectRatio(1.0, contentMode: .fill)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.9)
                                    .tint(.adaptiveSecondaryText)
                            )
                    @unknown default:
                        Rectangle()
                            .fill(Color.adaptiveCardBackground)
                            .aspectRatio(1.0, contentMode: .fill)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                
                // Podcast Title
                Text(podcast.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32) // Fixed height for consistent layout
            }
        }
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .opacity(isPressed ? 0.8 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onTapGesture {
            // Add haptic feedback
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { isPressing in
            // Simple press feedback without interfering with scroll
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = isPressing
            }
        } perform: {
            // Long press action - currently unused
        }
        .background(Color.clear)
    }
}

struct SearchPodcastsView_Previews: PreviewProvider {
    static var previews: some View {
        SearchPodcastsView(isPresented: .constant(true))
            .environmentObject(PodcastViewModel())
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
    }
}
