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
    let category: String?
    
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
            source: .podcastIndex,
            category: nil
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
            source: .iTunes,
            category: nil
        )
    }
}



// MARK: - Podcast Search Service
@MainActor
class PodcastSearchService: ObservableObject {
    @Published var searchResults: [PodcastSearchResult] = []
    @Published var popularPodcasts: [PodcastSearchResult] = []
    @Published var categorizedPopularPodcasts: [(category: String, podcasts: [PodcastSearchResult])] = []
    @Published var isSearching = false
    @Published var isLoadingPopular = false
    @Published var searchError: String?
    
    private let podcastIndexAPIKey = "CCWZDUP9ANLKNFNCJTNC"
    let podcastIndexAPISecret = "Fz3pSCAcLdJpGF$JUEdvxLHc#Z^UT96FEgHcB9Wg" // Get from https://api.podcastindex.org/signup

    /// Bumped by every new or cleared search so a slow, superseded request can't publish.
    private var searchGeneration = 0
    
    func searchPodcasts(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.searchResults = []
            return
        }
        
        searchGeneration += 1
        let generation = searchGeneration
        
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
        
        // A cancelled or superseded request must not clobber the results of the newer one.
        guard generation == searchGeneration, !Task.isCancelled else {
            // Cancelled with nothing newer behind it: don't leave the spinner up.
            if generation == searchGeneration { self.isSearching = false }
            return
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
    
    func fetchPopularPodcasts() async {
        self.isLoadingPopular = true
        self.searchError = nil
        
        do {
            // Fetch top podcasts from iTunes API with categories
            let (results, categorized) = try await fetchTopPodcastsFromiTunes()
            self.popularPodcasts = results
            self.categorizedPopularPodcasts = categorized
            print("✅ Fetched \(results.count) popular podcasts from iTunes in \(categorized.count) categories")
        } catch {
            print("⚠️ Failed to fetch popular podcasts: \(error.localizedDescription)")
            self.searchError = "Failed to load popular podcasts"
            self.popularPodcasts = []
            self.categorizedPopularPodcasts = []
        }
        
        self.isLoadingPopular = false
    }
    
    private func fetchTopPodcastsFromiTunes() async throws -> ([PodcastSearchResult], [(category: String, podcasts: [PodcastSearchResult])]) {
        // Expanded categories with more specific terms for better quality results
        let categories = [
            ("News & Politics", ["news", "politics", "current events"]),
            ("Comedy", ["comedy", "humor", "stand-up"]),
            ("True Crime", ["true crime", "mystery", "investigation"]),
            ("Business", ["business", "entrepreneur", "investing"]),
            ("Health & Fitness", ["health", "fitness", "wellness"]),
            ("Technology", ["technology", "tech", "programming", "AI", "software"]),
            ("Education", ["education", "learning", "science"]),
            ("Sports", ["sports", "football", "basketball"]),
            ("Arts & Culture", ["arts", "culture", "design"]),
            ("Society", ["society", "philosophy", "religion"]),
            ("Entertainment", ["entertainment", "celebrity", "movies"]),
            ("Music", ["music", "musicians", "album"]),
            ("History", ["history", "historical", "war"]),
            ("Self Improvement", ["self improvement", "productivity", "motivation"]),
            ("Gaming", ["gaming", "video games", "esports"]),
            ("Food & Cooking", ["food", "cooking", "recipes"]),
            ("Travel", ["travel", "adventure", "destinations"]),
            ("Science", ["science", "research", "discovery"]),
            ("Lifestyle", ["lifestyle", "fashion", "beauty"]),
            ("Parenting", ["parenting", "family", "kids"])
        ]
        
        var categorizedResults: [(category: String, podcasts: [PodcastSearchResult])] = []
        var seenIds: Set<String> = []
        
        // Use TaskGroup for concurrent API calls to improve performance
        await withTaskGroup(of: (String, [PodcastSearchResult]).self) { group in
            // Add tasks for each category concurrently
            for (categoryName, terms) in categories {
                group.addTask {
                    await self.fetchCategoryPodcasts(categoryName: categoryName, terms: terms)
                }
            }
            
            // Collect results as they complete
            for await (categoryName, categoryPodcasts) in group {
                if !categoryPodcasts.isEmpty {
                    // Filter duplicates and enhance artwork
                    var filteredPodcasts: [PodcastSearchResult] = []
                    for podcast in categoryPodcasts {
                        if !seenIds.contains(podcast.id) {
                            seenIds.insert(podcast.id)
                            
                            // Enhance artwork URL for higher quality
                            let enhancedArtworkUrl = podcast.artworkUrl != nil ? enhanceArtworkQuality(podcast.artworkUrl!) : podcast.artworkUrl
                            
                            let enhancedResult = PodcastSearchResult(
                                id: podcast.id,
                                title: podcast.title,
                                feedUrl: podcast.feedUrl,
                                artworkUrl: enhancedArtworkUrl,
                                description: podcast.description,
                                author: podcast.author,
                                source: podcast.source,
                                category: categoryName
                            )
                            
                            filteredPodcasts.append(enhancedResult)
                        }
                    }
                    
                    if !filteredPodcasts.isEmpty {
                        // Limit to 15 podcasts per category to reach ~300 total (20 categories × 15)
                        categorizedResults.append((category: categoryName, podcasts: Array(filteredPodcasts.prefix(15))))
                    }
                }
            }
        }
        
        // Flatten results while maintaining some category order
        var finalResults: [PodcastSearchResult] = []
        let maxPerCategory = 15 // 20 categories × 15 = 300 podcasts
        
        for (_, podcasts) in categorizedResults {
            finalResults.append(contentsOf: Array(podcasts.prefix(maxPerCategory)))
        }
        
        return (Array(finalResults.prefix(300)), categorizedResults) // Return up to 300 results and categories
    }
    
    private func fetchCategoryPodcasts(categoryName: String, terms: [String]) async -> (String, [PodcastSearchResult]) {
        var categoryPodcasts: [PodcastSearchResult] = []
        
        // Search multiple terms per category for diversity - limit to 2 terms for performance
        for term in terms.prefix(2) {
            do {
                let results = try await searchiTunes(query: term)
                // Take more results per term to get 15 per category
                for result in results.prefix(10) {
                    let enhancedResult = PodcastSearchResult(
                        id: result.id,
                        title: result.title,
                        feedUrl: result.feedUrl,
                        artworkUrl: result.artworkUrl,
                        description: result.description,
                        author: result.author,
                        source: result.source,
                        category: categoryName
                    )
                    categoryPodcasts.append(enhancedResult)
                }
            } catch {
                print("⚠️ Failed to fetch podcasts for term '\(term)' in category '\(categoryName)': \(error.localizedDescription)")
                continue
            }
        }
        
        return (categoryName, categoryPodcasts)
    }
    
    private func enhanceArtworkQuality(_ originalUrl: String) -> String {
        var enhancedUrl = originalUrl
        
        // For iTunes/Apple artwork, try to get larger versions
        if enhancedUrl.contains("mzstatic.com") || enhancedUrl.contains("is1-ssl.mzstatic.com") {
            // Replace common small sizes with larger ones
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "60x60", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "100x100", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "170x170", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "300x300", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "400x400", with: "600x600")
            enhancedUrl = enhancedUrl.replacingOccurrences(of: "500x500", with: "600x600")
            
            // Also try the bb parameter for better quality
            if !enhancedUrl.contains("bb=") {
                enhancedUrl += enhancedUrl.contains("?") ? "&bb=" : "?bb="
            }
        }
        
        // For other CDNs, try common size parameters
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "size=60", with: "size=600")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "size=100", with: "size=600")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "width=60", with: "width=600")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "width=100", with: "width=600")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "height=60", with: "height=600")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "height=100", with: "height=600")
        
        // Replace small image suffixes
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_small.jpg", with: "_large.jpg")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_thumb.jpg", with: "_large.jpg")
        enhancedUrl = enhancedUrl.replacingOccurrences(of: "_s.jpg", with: "_l.jpg")
        
        return enhancedUrl
    }
    
    func clearResults() {
        searchGeneration += 1
        searchResults = []
        searchError = nil
        isSearching = false
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
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @StateObject private var radioPlayer = RadioPlayer.shared
    
    // Progress indicator state
    @State private var isAddingPodcast = false
    @State private var addingProgress: Double = 0.0
    @State private var addingStageText = ""
    
    // Add editing support
    let podcastToEdit: PodcastFeed?
    let onAdd: (String?) -> Void
    let onUpdate: ((PodcastFeed) -> Void)?
    

    
    // Color system for adaptive theming - using shared adaptive colors
    
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
                        VStack(spacing: 24) {
                            podcastDetailsCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 80)
                    }
                    
                    // Global Player now handles all playback display
                }
                .background(
                    Color.adaptiveBackground
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Only dismiss keyboard when tapping on the background, not on interactive elements
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(navigationTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if !isAddingPodcast {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                    .disabled(isAddingPodcast)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(actionButtonText) {
                        validateAndSavePodcast()
                    }
                    .disabled(isAddingPodcast)
                }
            }
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
                    // Adding new podcast - dismiss keyboard if it's showing
                    print("🔧 DEBUG: New podcast mode")
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    
                    if title.isEmpty && url.isEmpty {
                        print("🔧 DEBUG: Form fields are empty - ready for new input")
                    } else {
                        print("🔧 DEBUG: Form fields have values - preserving them")
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
    
    // MARK: - UI Components
    
    @ViewBuilder
    private var podcastDetailsCard: some View {
        AddSimpleCard {
            VStack(spacing: 24) {
                AddSimpleTextField(
                    title: "Podcast Title",
                    text: $title,
                    placeholder: "Enter podcast title",
                    icon: "mic.fill",
                    maxLength: 100
                )
                
                AddSimpleTextField(
                    title: "RSS Feed URL",
                    text: $url,
                    placeholder: "https://example.com/podcast.rss",
                    icon: "link",
                    keyboardType: .URL
                )
            }
        }
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
        
        // Notify DataSyncManager that individual feed addition started
        DataSyncManager.shared.startIndividualFeedAddition()
        
        Task {
            do {
                // Stage 1: Validate URL
                await updateProgress(0.1, "Connecting to podcast feed...")
                try await Task.sleep(nanoseconds: 200_000_000) // Brief pause for UI
                
                // Stage 2: Download and parse RSS feed
                await updateProgress(0.3, "Downloading podcast RSS feed...")
                
                // Add the podcast feed using the ViewModel with custom title
                let customTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let customTitleToUse = customTitle.isEmpty ? nil : customTitle
                let success = await podcastViewModel.addPodcastFeed(url: url, customTitle: customTitleToUse)
                
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
                        // Get the newly added podcast ID (should be the last one in the order)
                        let newPodcastId = podcastViewModel.podcastFeedOrder.last
                        
                        // Call onAdd() to notify parent view (like SearchPodcastsView) to dismiss
                        onAdd(newPodcastId)
                        
                                            // Close the sheet and reset state
                    isPresented = false
                    isAddingPodcast = false
                    
                    // CRITICAL FIX: Delay completion until after auto-focus operations have time to complete
                    // This prevents the main banner from appearing during auto-focus operations
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        DataSyncManager.shared.completeIndividualFeedAddition()
                        print("🔄 AddPodcastView: Delayed completion of individual feed addition")
                    }
                    
                    // Clear the input fields for next time
                    title = ""
                    url = ""
                    }
                } else {
                    await MainActor.run {
                        isAddingPodcast = false
                        alertMessage = podcastViewModel.error ?? "Failed to add podcast. Please check the URL and try again."
                        showAlert = true
                        
                        // CRITICAL FIX: Delay completion even for errors to maintain consistency
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            DataSyncManager.shared.completeIndividualFeedAddition()
                            print("🔄 AddPodcastView: Delayed completion of individual feed addition (error case)")
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
                        print("🔄 AddPodcastView: Delayed completion of individual feed addition (exception case)")
                    }
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
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    if let author = result.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: result.source == .podcastIndex ? "radio" : "applelogo")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(result.source == .podcastIndex ? "PodcastIndex" : "iTunes")
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
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Progress View Component

struct PodcastAddingProgressView: View {
    let progress: Double
    let stageText: String
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackgroundColor: Color {
        // Use solid, opaque background instead of adaptive transparent one
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var titleColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.gray : Color.secondary
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("Adding Podcast")
                .font(.title3)
                .foregroundColor(titleColor)
            
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
                
                Image(systemName: "microphone")
                    .font(.largeTitle)
                    
            }
            
            // Progress percentage
            Text("\(Int(progress * 100))%")
                .font(.body)
                .foregroundColor(secondaryTextColor)
                .animation(.easeInOut(duration: 0.3), value: progress)
            
            // Stage text
            Text(stageText)
                .font(.body)
                .foregroundColor(titleColor)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: stageText)
            
            // Linear progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
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
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
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
                onAdd: { podcastId in
                    print("Podcast added with ID: \(podcastId ?? "unknown")")
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
                onAdd: { podcastId in
                    print("Podcast added with ID: \(podcastId ?? "unknown")")
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
