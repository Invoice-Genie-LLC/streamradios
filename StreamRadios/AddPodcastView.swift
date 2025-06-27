//
//  AddPodcastView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import SwiftUI
import CryptoKit
import CommonCrypto

// MARK: - PodcastIndex Authentication Extension
extension String {
    func sha1() -> String {
        let data = Data(self.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        let hexBytes = digest.map { String(format: "%02hhx", $0) }
        return hexBytes.joined()
    }
}

// MARK: - Podcast Search Models
struct PodcastSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let feedUrl: String
    let artworkUrl: String?
    let description: String?
    let author: String?
    let source: SearchSource
    
    enum SearchSource {
        case podcastIndex
        case iTunes
    }
}

struct PodcastIndexResponse: Codable {
    let feeds: [PodcastIndexFeed]
}

struct PodcastIndexFeed: Codable {
    let id: Int
    let title: String
    let url: String
    let description: String?
    let author: String?
    let image: String?
    let artwork: String?
    
    var searchResult: PodcastSearchResult {
        PodcastSearchResult(
            id: "pi_\(id)",
            title: title,
            feedUrl: url,
            artworkUrl: image ?? artwork,
            description: description,
            author: author,
            source: .podcastIndex
        )
    }
}

struct iTunesSearchResponse: Codable {
    let results: [iTunesResult]
}

struct iTunesResult: Codable {
    let collectionId: Int
    let collectionName: String
    let feedUrl: String?
    let artworkUrl100: String?
    let artistName: String?
    let collectionCensoredName: String?
    
    var searchResult: PodcastSearchResult? {
        guard let feedUrl = feedUrl else { return nil }
        return PodcastSearchResult(
            id: "itunes_\(collectionId)",
            title: collectionCensoredName ?? collectionName,
            feedUrl: feedUrl,
            artworkUrl: artworkUrl100,
            description: nil,
            author: artistName,
            source: .iTunes
        )
    }
}

// MARK: - Podcast Search Service
@MainActor
class PodcastSearchService: ObservableObject {
    @Published var searchResults: [PodcastSearchResult] = []
    @Published var isSearching = false
    @Published var searchError: String?
    
    private let podcastIndexAPIKey = "CCWZDUP9ANLKNFNCJTNC"
    let podcastIndexAPISecret = "Fz3pSCAcLdJpGF$JUEdvxLHc#Z^UT96FEgHcB9Wg" // Get from https://api.podcastindex.org/signup
    
    func searchPodcasts(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.searchResults = []
            return
        }
        
        self.isSearching = true
        self.searchError = nil
        
        // Search with iTunes priority - iTunes first, PodcastIndex as fallback
        var piResults: [PodcastSearchResult] = []
        var itunesResults: [PodcastSearchResult] = []
        
        // Try iTunes first (priority source)
        do {
            itunesResults = try await searchiTunes(query: query)
            print("✅ iTunes returned \(itunesResults.count) results")
        } catch {
            print("⚠️ iTunes search failed: \(error.localizedDescription)")
        }
        
        // Use PodcastIndex as fallback only if iTunes has insufficient results
        if itunesResults.count < 10 {
            do {
                piResults = try await searchPodcastIndex(query: query)
                print("✅ PodcastIndex returned \(piResults.count) results (fallback)")
            } catch {
                print("⚠️ PodcastIndex search failed: \(error.localizedDescription)")
            }
        } else {
            print("📱 iTunes provided sufficient results (\(itunesResults.count)), skipping PodcastIndex")
        }
        
        // Combine results with iTunes priority
        var combinedResults: [PodcastSearchResult] = []
        var seenUrls: Set<String> = []
        
        // Add iTunes results first (priority)
        for result in itunesResults {
            if !seenUrls.contains(result.feedUrl) {
                combinedResults.append(result)
                seenUrls.insert(result.feedUrl)
            }
        }
        
        // Add PodcastIndex results only if not already present from iTunes
        for result in piResults {
            if !seenUrls.contains(result.feedUrl) {
                combinedResults.append(result)
                seenUrls.insert(result.feedUrl)
            }
        }
        
        self.searchResults = combinedResults
        
        // Only show error if both APIs failed and we have no results
        if combinedResults.isEmpty && piResults.isEmpty && itunesResults.isEmpty {
            if podcastIndexAPISecret == "YOUR_SECRET_HERE" {
                self.searchError = "Please add your PodcastIndex.org API secret to enable full search functionality. Currently using iTunes only."
            } else {
                self.searchError = "Search temporarily unavailable. Please try again."
            }
        }
        
        self.isSearching = false
    }
    
    private func searchPodcastIndex(query: String) async throws -> [PodcastSearchResult] {
        // Skip PodcastIndex if secret is not configured
        guard podcastIndexAPISecret != "YOUR_SECRET_HERE" else {
            print("🔑 PodcastIndex API secret not configured, skipping...")
            return []
        }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.podcastindex.org/api/1.0/search/byterm?q=\(encodedQuery)&max=50") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("StreamRadios/1.0", forHTTPHeaderField: "User-Agent")
        
        // Generate authorization headers for PodcastIndex
        // Create authorization header (using PodcastIndex.org official method)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let authString = podcastIndexAPIKey + podcastIndexAPISecret + timestamp
        let hashString = authString.sha1()
        
        request.setValue(podcastIndexAPIKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(timestamp, forHTTPHeaderField: "X-Auth-Date")
        request.setValue(hashString, forHTTPHeaderField: "Authorization")
        
        print("🔑 PodcastIndex Auth Debug:")
        print("   API Key: \(String(podcastIndexAPIKey.prefix(8)))...")
        print("   Secret: \(String(podcastIndexAPISecret.prefix(8)))...")
        print("   Timestamp: \(timestamp)")
        print("   Auth String: \(String(authString.prefix(20)))...")
        print("   Hash: \(hashString)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check if we got HTML instead of JSON (common with auth errors)
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("text/html") {
            print("🚫 PodcastIndex returned HTML (likely auth error), status: \(httpResponse.statusCode)")
            throw NSError(domain: "PodcastIndexError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"])
        }
        
        // Try to decode as JSON
        do {
            let response = try JSONDecoder().decode(PodcastIndexResponse.self, from: data)
            return response.feeds.map { $0.searchResult }
        } catch {
            // Log the actual response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("🚫 PodcastIndex JSON decode failed. Response: \(responseString.prefix(200))")
            }
            throw error
        }
    }
    
    private func searchiTunes(query: String) async throws -> [PodcastSearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&media=podcast&limit=50") else {
            throw URLError(.badURL)
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        // Check HTTP response
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            print("🚫 iTunes API error, status: \(httpResponse.statusCode)")
            throw NSError(domain: "iTunesError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "iTunes API error"])
        }
        
        do {
            let response = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
            return response.results.compactMap { $0.searchResult }
        } catch {
            // Log the actual response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("🚫 iTunes JSON decode failed. Response: \(responseString.prefix(200))")
            }
            throw error
        }
    }
    
    func clearResults() {
        searchResults = []
        searchError = nil
    }
}

struct AddPodcastView: View {
    @Binding var isPresented: Bool
    @Binding var title: String
    @Binding var url: String
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var permissionManager: PermissionManager
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var searchService = PodcastSearchService()
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    
    // Progress indicator state
    @State private var isAddingPodcast = false
    @State private var addingProgress: Double = 0.0
    @State private var addingStageText = ""
    
    // Add editing support
    let podcastToEdit: PodcastFeed?
    let onAdd: () -> Void
    let onUpdate: ((PodcastFeed) -> Void)?
    
    private let miniPlayerHeight: CGFloat = 60
    
    // Modern color system for adaptive theming - using shared adaptive colors
    
    // Computed properties for UI
    private var navigationTitle: String {
        podcastToEdit != nil ? "Edit Podcast" : "Add Podcast"
    }
    
    private var actionButtonText: String {
        podcastToEdit != nil ? "Update" : "Add"
    }
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            podcastSearchCard
                            modernPodcastDetailsCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 80) // Add padding for custom navigation bar
                        .padding(.bottom, podcastPlayer.isPlaying && !radioPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 120 : 80)
                    }
                    
                    // Fixed Mini Player
                    if podcastPlayer.isPlaying && !radioPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                        MiniPodcastPlayerView(
                            currentEpisode: currentEpisode,
                            currentFeed: currentFeed,
                            podcastPlayer: podcastPlayer,
                            viewModel: podcastViewModel,
                            selectedPodcast: $selectedPodcast,
                            onListButtonTap: {
                                selectedPodcast = currentFeed
                                podcastViewModel.fetchAllEpisodes(for: currentFeed)
                                scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                                showPodcastPlayerSheet = true
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
                .background(Color.adaptiveBackground)
            }
            .navigationBarHidden(true)
            .onAppear {
                print("🔧 DEBUG: AddPodcastView onAppear - podcastToEdit: \(podcastToEdit?.title ?? "nil")")
                print("🔧 DEBUG: AddPodcastView onAppear - current title binding: '\(title)', url binding: '\(url)'")
                
                if let podcastToEdit = podcastToEdit {
                    // Populate fields when editing - force binding updates
                    print("🔧 DEBUG: Populating edit fields - Title: '\(podcastToEdit.title)', URL: '\(podcastToEdit.url)'")
                    
                    // Ensure we have valid data before setting
                    if !podcastToEdit.title.isEmpty && !podcastToEdit.url.isEmpty {
                        title = podcastToEdit.title
                        url = podcastToEdit.url
                        print("🔧 SUCCESS: Edit fields populated successfully")
                    } else {
                        print("🔧 WARNING: podcastToEdit has empty title or URL")
                        print("🔧 DEBUG: Trying to use current binding values as fallback")
                        
                        // If bindings already have values from parent, use them
                        if !title.isEmpty && !url.isEmpty {
                            print("🔧 SUCCESS: Using existing binding values")
                        } else {
                            print("🔧 ERROR: Both podcastToEdit and bindings are empty - edit will fail")
                        }
                    }
                } else {
                    // Adding new podcast - only clear fields if they're not already set from bindings
                    if title.isEmpty && url.isEmpty {
                        print("🔧 DEBUG: Clearing fields for new podcast")
                        title = ""
                        url = ""
                        searchText = ""
                        searchService.clearResults()
                        
                        // Dismiss keyboard if it's showing
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } else {
                        print("🔧 DEBUG: New podcast mode but fields already have values - preserving them")
                    }
                }
                
                print("🔧 DEBUG: AddPodcastView onAppear completed - title: '\(title)', url: '\(url)'")
                
                // Final validation - if we're editing and still have empty fields, log an error
                if podcastToEdit != nil && (title.isEmpty || url.isEmpty) {
                    print("🔧 ERROR: Edit mode but fields are still empty after onAppear - this indicates a data preparation issue")
                    print("🔧 ERROR: podcastToEdit - Title: '\(podcastToEdit?.title ?? "nil")', URL: '\(podcastToEdit?.url ?? "nil")'")
                }
            }
        }
        .background(Color.adaptiveBackground)
        .overlay(simpleNavigationBar, alignment: .top)
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
                    Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
                    PodcastAddingProgressView(
                        progress: addingProgress,
                        stageText: addingStageText
                    )
                    .transition(.opacity)
                }
            }
        )
        .sheet(isPresented: $showPodcastPlayerSheet) {
            if let podcast = selectedPodcast {
                PodcastPlayerView(
                    viewModel: podcastViewModel,
                    feed: podcast,
                    initialScrollToEpisodeID: scrollToEpisodeID,
                    podcastPlayer: podcastPlayer,
                    selectedPodcast: $selectedPodcast,
                    episodeToScrollTo: Binding(
                        get: { podcastPlayer.currentEpisode },
                        set: { _ in }
                    )
                )
            }
        }
    }
    
    // MARK: - Modern UI Components
    
    @ViewBuilder
    private var podcastSearchCard: some View {
        VStack(spacing: 16) {
            // Search Header
            searchHeader
            
            // Search Results
            if searchService.isSearching {
                loadingView
            } else if !searchService.searchResults.isEmpty {
                searchResultsList
            } else if !searchText.isEmpty && !searchService.isSearching {
                noResultsView
            }
            
            // Error Message
            if let error = searchService.searchError {
                errorView(error)
            }
            
            // Credit Section (required by PodcastIndex.org)
            creditSection
        }
    }
    
    @ViewBuilder
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                
                Text("Search Podcasts")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
            }
            
            HStack {
                TextField("Search for podcasts...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.adaptivePrimaryText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: searchText) { newValue in
                        performSearch(query: newValue)
                    }
                    .padding(.leading, 4)
                
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
        }
        .padding(20)
        .background(Color.adaptiveCardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.adaptiveBorder, lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Searching podcasts...")
                .font(.system(size: 14))
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
                    
                    // Populate the form fields when a podcast is selected
                    title = result.title
                    url = result.feedUrl
                    
                    // Clear search results and text to dismiss the selection list
                    searchText = ""
                    searchService.clearResults()
                }
            }
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.adaptiveSecondaryText)
            
            Text("No podcasts found")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
            
            Text("Try adjusting your search terms")
                .font(.system(size: 14))
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
                .font(.system(size: 14))
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
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            Text("Apple iTunes")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.adaptiveSecondaryText)
            
            Text("&")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            Text("PodcastIndex.org")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.adaptiveSecondaryText)
        }
        .padding(.horizontal)
    }
    
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
    
    @ViewBuilder
    private var modernPodcastDetailsCard: some View {
        ModernFormCard(title: "Podcast Details") {
            VStack(spacing: 16) {
                ModernTextField(
                    title: "Podcast Title",
                    text: $title,
                    placeholder: "Enter podcast title",
                    icon: "mic.fill",
                    maxLength: 40
                )
                
                ModernTextField(
                    title: "RSS Feed URL",
                    text: $url,
                    placeholder: "https://example.com/podcast.rss",
                    icon: "link",
                    keyboardType: .URL
                )
            }
        }
    }
    
    @ViewBuilder
    private var modernCancelButton: some View {
        Button("Cancel") {
            if !isAddingPodcast {
                isPresented = false
            }
        }
        .foregroundColor(isAddingPodcast ? .gray : .blue)
        .disabled(isAddingPodcast)
    }
    
    @ViewBuilder
    private var modernSaveButton: some View {
        Button(actionButtonText) {
            validateAndSavePodcast()
        }
        .foregroundColor(isAddingPodcast ? .gray : .blue)
        .fontWeight(.semibold)
        .disabled(isAddingPodcast)
    }
    
    // MARK: - Helper Methods (Preserved from original)
    
    private func validateAndSavePodcast() {
        // Validate title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Please enter a podcast title."
            showAlert = true
            return
        }
        
        // Validate URL
        guard let url = URL(string: self.url),
              UIApplication.shared.canOpenURL(url),
              url.scheme == "http" || url.scheme == "https" else {
            alertMessage = "Please enter a valid RSS Feed URL (must start with http:// or https://)."
            showAlert = true
            return
        }

        // Handle edit vs add
        if let podcastToEdit = podcastToEdit {
            // Update existing podcast - no progress needed for updates
            print("DEBUG: AddPodcastView - Original podcast - ID: \(podcastToEdit.id), Title: '\(podcastToEdit.title)', URL: '\(podcastToEdit.url)'")
            print("DEBUG: AddPodcastView - New values - Title: '\(title.trimmingCharacters(in: .whitespacesAndNewlines))', URL: '\(self.url.trimmingCharacters(in: .whitespacesAndNewlines))'")
            
            var updatedPodcast = podcastToEdit
            updatedPodcast.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            updatedPodcast.url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("DEBUG: AddPodcastView - Updated podcast - ID: \(updatedPodcast.id), Title: '\(updatedPodcast.title)', URL: '\(updatedPodcast.url)'")
            onUpdate?(updatedPodcast)
            isPresented = false
        } else {
            // Add new podcast with progress indication
            addPodcastWithProgress()
        }
    }
    
    private func addPodcastWithProgress() {
        isAddingPodcast = true
        addingProgress = 0.0
        addingStageText = "Preparing to add podcast..."
        
        Task {
            do {
                // Stage 1: Validate URL
                await updateProgress(0.1, "Connecting to podcast...")
                try await Task.sleep(nanoseconds: 200_000_000) // Brief pause for UI
                
                // Stage 2: Download feed
                await updateProgress(0.3, "Fetching podcast information...")
                
                // Add the podcast feed using the ViewModel
                let success = await podcastViewModel.addPodcastFeed(url: url)
                
                if success {
                    // Stage 3: Processing episodes
                    await updateProgress(0.7, "Processing episodes and content...")
                    try await Task.sleep(nanoseconds: 500_000_000) // Pause for parsing
                    
                    // Stage 4: Saving to device
                    await updateProgress(0.9, "Adding to your podcast library...")
                    try await Task.sleep(nanoseconds: 300_000_000) // Pause for saving
                    
                    // Stage 5: Complete
                    await updateProgress(1.0, "Podcast added successfully!")
                    try await Task.sleep(nanoseconds: 500_000_000) // Show completion briefly
                    
                    await MainActor.run {
                        onAdd()
                        isPresented = false
                        isAddingPodcast = false
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
    
    // MARK: - Navigation Bar
    
    @ViewBuilder
    private var simpleNavigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    if !isAddingPodcast {
                        isPresented = false
                    }
                }
                .font(.system(size: 17))
                .foregroundColor(isAddingPodcast ? .gray : .blue)
                .disabled(isAddingPodcast)
                
                Spacer()
                
                Text(navigationTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
                
                Button(actionButtonText) {
                    validateAndSavePodcast()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isAddingPodcast ? .gray : .blue)
                .disabled(isAddingPodcast)
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 15)
            .background(Color.adaptiveSecondaryBackground)
            
            Divider()
                .background(Color.adaptiveSeparator)
        }
    }
}

// MARK: - Modern UI Components for Forms

struct ModernFormCard<Content: View>: View {
    let title: String
    let content: () -> Content
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackgroundColor: Color {
        Color.adaptiveCardBackground
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
            }
            
            // Content
            content()
        }
        .padding(20)
        .background(cardBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.adaptiveBorder, lineWidth: 0.5)
        )
    }
}

struct ModernTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let icon: String
    let maxLength: Int?
    let keyboardType: UIKeyboardType
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, text: Binding<String>, placeholder: String, icon: String, maxLength: Int? = nil, keyboardType: UIKeyboardType = .default) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.icon = icon
        self.maxLength = maxLength
        self.keyboardType = keyboardType
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.adaptivePrimaryText)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .disableAutocorrection(keyboardType == .URL)
                    .onChange(of: text) { newValue in
                        if let maxLength = maxLength, newValue.count > maxLength {
                            text = String(newValue.prefix(maxLength))
                        }
                    }
                    .padding(.leading, 4)
                
                if !text.isEmpty {
                    Button(action: {
                        text = ""
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
        }
    }
}

struct PodcastSearchResultRow: View {
    let result: PodcastSearchResult
    let onTap: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    // Now using adaptive color system
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Podcast Artwork
                AsyncImage(url: URL(string: result.artworkUrl ?? "")) { image in
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
                    Text(result.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    if let author = result.author {
                        Text(author)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: result.source == .podcastIndex ? "radio" : "applelogo")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text(result.source == .podcastIndex ? "PodcastIndex" : "iTunes")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
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
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Progress View Component

struct PodcastAddingProgressView: View {
    let progress: Double
    let stageText: String
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackgroundColor: Color {
        Color.adaptiveCardBackground
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("Adding Podcast")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.adaptivePrimaryText)
            
            // Animated podcast icon
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 3)
                    .frame(width: 80, height: 80)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: progress)
                
                Image(systemName: "podcast")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.blue)
            }
            
            // Progress percentage
            Text("\(Int(progress * 100))%")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.adaptiveSecondaryText)
                .animation(.easeInOut(duration: 0.3), value: progress)
            
            // Stage text
            Text(stageText)
                .font(.system(size: 16))
                .foregroundColor(.adaptivePrimaryText)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: stageText)
            
            // Linear progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.adaptiveBorder)
                            .frame(height: 6)
                            .cornerRadius(3)
                        
                        Rectangle()
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [Color.blue, Color.purple]),
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geometry.size.width * progress, height: 6)
                            .cornerRadius(3)
                            .animation(.easeInOut(duration: 0.5), value: progress)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(32)
        .background(cardBackgroundColor)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 8)
        .scaleEffect(0.9)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
    }
}

struct AddPodcastView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AddPodcastView(
                isPresented: .constant(true), 
                title: .constant(""), 
                url: .constant(""), 
                podcastToEdit: nil,
                onAdd: {
                    print("Podcast added")
                },
                onUpdate: { podcast in
                    print("Podcast updated: \(podcast.title)")
                }
            )
            .environmentObject(PermissionManager())
            .environmentObject(PodcastViewModel())
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
            
            AddPodcastView(
                isPresented: .constant(true), 
                title: .constant("Sample Podcast"), 
                url: .constant("https://example.com/feed.rss"), 
                podcastToEdit: nil,
                onAdd: {
                    print("Podcast added")
                },
                onUpdate: { podcast in
                    print("Podcast updated: \(podcast.title)")
                }
            )
            .environmentObject(PermissionManager())
            .environmentObject(PodcastViewModel())
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
            
            // Progress view preview
            PodcastAddingProgressView(
                progress: 0.6,
                stageText: "Downloading podcast feed..."
            )
            .preferredColorScheme(.dark)
            .previewDisplayName("Progress View")
        }
    }
}
