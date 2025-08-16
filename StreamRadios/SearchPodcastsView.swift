//
//  SearchPodcastsView.swift
//  StreamRadios
//
//  Created by Assistant on 12/27/24.
//

import SwiftUI
import CryptoKit
import CommonCrypto

struct SearchPodcastsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    @StateObject private var searchService = PodcastSearchService()
    @State private var searchText = ""
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
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Search Header
                    searchHeader
                        .padding(.top, 80) // Add padding for custom navigation bar
                    
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
                                // Show "My Podcasts" section when no search
                                myPodcastsSection
                            }
                            
                            // Error Message
                            if let error = searchService.searchError {
                                errorView(error)
                            }
                            
                            // Credit Section (required by PodcastIndex.org)
                            creditSection
                        }
                        .padding(.horizontal, 16)
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
            .navigationBarHidden(true)
            .onAppear {
                searchText = ""
                searchService.clearResults()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .background(Color.adaptiveBackground)
        .overlay(navigationBar, alignment: .top)
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
        .sheet(isPresented: showingPreview) {
            if let presentedPodcast = presentedPodcast {
                PodcastPreviewView(
                    isPresented: showingPreview,
                    podcast: presentedPodcast
                )
            }
        }
    }
    
    // MARK: - UI Components
    
    @ViewBuilder
    private var navigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close") {
                    searchText = ""
                    searchService.clearResults()
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    isPresented = false
                }
                .font(.body)
                .foregroundColor(.blue)
                
                Spacer()
                
                Text("Search Podcasts")
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
                
                Button("Add URL") {
                    newPodcastTitle = ""
                    newPodcastURL = ""
                    showingAddPodcast = true
                }
                .font(.body)
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 15)
            .background(Color.adaptiveSecondaryBackground)
            
            Divider()
                .background(Color.adaptiveSeparator)
        }
    }
    
    @ViewBuilder
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search for podcasts...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.adaptivePrimaryText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
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
    private var myPodcastsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MY PODCASTS")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.adaptiveSecondaryText)
                Spacer()
            }
            
            LazyVStack(spacing: 12) {
                ForEach(podcastViewModel.podcastFeeds) { podcast in
                    MyPodcastRow(podcast: podcast)
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
                    try await Task.sleep(nanoseconds: 500_000_000)
                    
                    await MainActor.run {
                        isAddingPodcast = false
                        searchText = ""
                        searchService.clearResults()
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
    
    private func addPodcast() {
        // This is called when AddPodcastView successfully adds a podcast
        // Refresh the view to show the new podcast
        newPodcastTitle = ""
        newPodcastURL = ""
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

// MARK: - My Podcast Row

struct MyPodcastRow: View {
    let podcast: PodcastFeed
    
    var body: some View {
        HStack(spacing: 12) {
            // Podcast Artwork
            AsyncImage(url: URL(string: podcast.artworkUrl ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.adaptiveBorder)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(.adaptiveSecondaryText)
                    )
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Podcast Info
            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                if let description = podcast.descriptionText {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    
                    Text("Subscribed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color.adaptiveCardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.adaptiveBorder, lineWidth: 0.5)
        )
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
