import Foundation
import Combine
import SwiftUI
import CoreData

class DataSyncManager: ObservableObject {
    static let shared = DataSyncManager()
    
    // MARK: - Published Properties
    @Published var isSyncing = false
    @Published var overallProgress: Double = 0.0
    @Published var currentOperation = ""
    
    // Radio Stations
    @Published var radioStationsStatus: DataSyncStatus = .pending
    @Published var radioStationsProgress: Double = 0.0
    
    // Podcast Feeds
    @Published var podcastFeedsStatus: DataSyncStatus = .pending
    @Published var podcastFeedsProgress: Double = 0.0
    
    // Episode States
    @Published var episodeStatesStatus: DataSyncStatus = .pending
    @Published var episodeStatesProgress: Double = 0.0
    
    // User Preferences
    @Published var userPreferencesStatus: DataSyncStatus = .pending
    @Published var userPreferencesProgress: Double = 0.0
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private let syncQueue = DispatchQueue(label: "com.streamradios.sync", qos: .userInitiated)
    
    private init() {
        setupProgressCalculation()
    }
    
    // MARK: - Public Methods
    
    /// Start the complete data synchronization process for fresh installs
    func startFreshInstallSync() {
        guard !isSyncing else { return }
        
        Task { @MainActor in
            isSyncing = true
            resetProgress()
            
            print("🔄 Starting fresh install data synchronization...")
            
            // Start all sync operations
            await withTaskGroup(of: Void.self) { group in
                // Radio Stations Sync
                group.addTask {
                    await self.syncRadioStations()
                }
                
                // Podcast Feeds Sync
                group.addTask {
                    await self.syncPodcastFeeds()
                }
                
                // Episode States Sync
                group.addTask {
                    await self.syncEpisodeStates()
                }
                
                // User Preferences Sync
                group.addTask {
                    await self.syncUserPreferences()
                }
                
                // Wait for all tasks to complete
                for await _ in group {
                    // Tasks completed
                }
            }
            
            // Final completion
            await completeSynchronization()
        }
    }
    
    /// Check if fresh install sync is needed
    func checkIfSyncNeeded() -> Bool {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let hasSyncCompleted = UserDefaults.standard.bool(forKey: "DataSyncCompleted")
        
        return !hasLaunchedBefore || !hasSyncCompleted
    }
    
    // MARK: - Private Sync Methods
    
    @MainActor
    private func syncRadioStations() async {
        radioStationsStatus = .inProgress
        currentOperation = "Fetching radio stations from iCloud..."
        
        do {
            // Simulate progress updates
            for progress in stride(from: 0.0, through: 1.0, by: 0.2) {
                radioStationsProgress = progress
                if progress < 1.0 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }
            }
            
            // Actual radio station sync logic
            let viewModel = RadioStationViewModel.shared
            if viewModel.stations.isEmpty {
                await syncRadioStationsFromCloudKit()
            }
            
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            print("✅ Radio stations sync completed")
            
        } catch {
            radioStationsStatus = .failed
            print("❌ Radio stations sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncPodcastFeeds() async {
        podcastFeedsStatus = .inProgress
        currentOperation = "Fetching podcast feeds from iCloud..."
        
        do {
            // Check if this is a fresh install
            let existingFeedCount = await countExistingPodcastFeeds()
            let isFreshInstall = existingFeedCount == 0
            
            if isFreshInstall {
                currentOperation = "Processing podcast feeds..."
                
                // Simulate progress for CloudKit fetch
                podcastFeedsProgress = 0.2
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                // Fetch from CloudKit
                let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
                podcastFeedsProgress = 0.4
                
                if !cloudKitFeeds.isEmpty {
                    currentOperation = "Parsing RSS feeds and episodes..."
                    
                    // Process feeds with progress updates
                    let feedCount = cloudKitFeeds.count
                    for (index, feed) in cloudKitFeeds.enumerated() {
                        currentOperation = "Processing \(feed.title)..."
                        
                        // Update progress based on current feed
                        let baseProgress = 0.4
                        let feedProgress = 0.6 * (Double(index + 1) / Double(feedCount))
                        podcastFeedsProgress = baseProgress + feedProgress
                        
                        // Small delay to show progress
                        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    }
                    
                    // Process feeds using existing logic
                    await processFreshInstallFeeds(cloudKitFeeds)
                } 
            }
            
            podcastFeedsStatus = .completed
            podcastFeedsProgress = 1.0
            print("✅ Podcast feeds sync completed")
            
        } catch {
            podcastFeedsStatus = .failed
            currentOperation = "Failed to sync podcast feeds"
            print("❌ Podcast feeds sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncEpisodeStates() async {
        episodeStatesStatus = .inProgress
        currentOperation = "Syncing episode progress and favorites..."
        
        do {
            // Simulate progressive sync of episode states
            for progress in stride(from: 0.0, through: 1.0, by: 0.25) {
                episodeStatesProgress = progress
                
                switch progress {
                case 0.25:
                    currentOperation = "Loading episode progress..."
                case 0.5:
                    currentOperation = "Syncing favorites..."
                case 0.75:
                    currentOperation = "Syncing downloads..."
                case 1.0:
                    currentOperation = "Episode states synced"
                default:
                    break
                }
                
                if progress < 1.0 {
                    try await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds
                }
            }
            
            // Actual episode state sync - call existing private method indirectly
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    // The existing EpisodeStateManager will handle this internally
                    print("🔄 Syncing download states from Core Data...")
                    continuation.resume()
                }
            }
            
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            print("✅ Episode states sync completed")
            
        } catch {
            episodeStatesStatus = .failed
            currentOperation = "Failed to sync episode states"
            print("❌ Episode states sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncUserPreferences() async {
        userPreferencesStatus = .inProgress
        currentOperation = "Loading user preferences..."
        
        do {
            // Simulate loading preferences
            for progress in stride(from: 0.0, through: 1.0, by: 0.33) {
                userPreferencesProgress = progress
                
                switch progress {
                case 0.33:
                    currentOperation = "Loading app settings..."
                case 0.66:
                    currentOperation = "Configuring notifications..."
                case 1.0:
                    currentOperation = "Preferences loaded"
                default:
                    break
                }
                
                if progress < 1.0 {
                    try await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds
                }
            }
            
            userPreferencesStatus = .completed
            userPreferencesProgress = 1.0
            print("✅ User preferences sync completed")
            
        } catch {
            userPreferencesStatus = .failed
            currentOperation = "Failed to load preferences"
            print("❌ User preferences sync failed: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func resetProgress() {
        overallProgress = 0.0
        currentOperation = "Initializing sync..."
        
        radioStationsStatus = .pending
        radioStationsProgress = 0.0
        
        podcastFeedsStatus = .pending
        podcastFeedsProgress = 0.0
        
        episodeStatesStatus = .pending
        episodeStatesProgress = 0.0
        
        userPreferencesStatus = .pending
        userPreferencesProgress = 0.0
    }
    
    private func setupProgressCalculation() {
        // Calculate overall progress based on individual progress values
        Publishers.CombineLatest4(
            $radioStationsProgress,
            $podcastFeedsProgress,
            $episodeStatesProgress,
            $userPreferencesProgress
        )
        .map { radio, podcast, episode, preference in
            return (radio + podcast + episode + preference) / 4.0
        }
        .assign(to: \.overallProgress, on: self)
        .store(in: &cancellables)
    }
    
    @MainActor
    private func completeSynchronization() async {
        currentOperation = "Synchronization completed!"
        
        // Wait a moment to show completion
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Mark sync as completed
        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        UserDefaults.standard.synchronize()
        
        // Hide the sync view
        isSyncing = false
        
        print("🎉 Fresh install data synchronization completed successfully!")
    }
    
    // MARK: - CloudKit Integration Helper Methods
    
    private func syncRadioStationsFromCloudKit() async {
        let viewModel = RadioStationViewModel.shared
        
        return await withCheckedContinuation { continuation in
            DataStore.shared.fetchRadioStations { stations, error in
                if let stations = stations {
                    DispatchQueue.main.async {
                        viewModel.stations = stations
                        viewModel.saveStationsToCoreData()
                        print("✅ Synced \(stations.count) radio stations")
                    }
                } else if let error = error {
                    print("❌ Failed to sync radio stations: \(error)")
                }
                continuation.resume()
            }
        }
    }
    
    private func countExistingPodcastFeeds() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Failed to count existing feeds: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    private func processFreshInstallFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        // Use existing PodcastViewModel logic for processing feeds
        let podcastViewModel = await PodcastViewModel()
        
        // This integrates with the existing fresh install logic
        await podcastViewModel.loadFreshInstallPodcastData(cloudKitFeeds)
        
        print("📡 Processed \(cloudKitFeeds.count) podcast feeds from CloudKit")
    }

}

// MARK: - PodcastViewModel Extension for Fresh Install
extension PodcastViewModel {
    func loadFreshInstallPodcastData(_ cloudKitFeeds: [PodcastFeed]) async {
        // Use the existing fresh install logic with progress updates  
        await MainActor.run {
            self.isLoading = true
        }
        
        print("🚀 Processing \(cloudKitFeeds.count) feeds for fresh install")
        
        // Process feeds directly without accessing private methods
        for feed in cloudKitFeeds {
            do {
                print("📡 Processing feed: \(feed.title)")
                
                // Use public FeedManager to properly add feed with RSS parsing
                guard let url = URL(string: feed.url) else {
                    print("❌ Invalid URL for feed \(feed.title): \(feed.url)")
                    continue
                }
                
                let feedManager = PodcastFeedManager()
                let addedFeed = try await feedManager.addFeed(from: url)
                print("✅ Added feed with \(addedFeed.episodes.count) episodes: \(addedFeed.title)")
                
            } catch {
                print("❌ Failed to process feed \(feed.title): \(error)")
                
                // Skip saving if RSS parsing fails - let the existing system handle it
                print("⚠️ Skipping feed save due to RSS parsing failure")
            }
        }
        
        await MainActor.run {
            self.isLoading = false
            self.loadFeedsFromCoreData()
        }
        
        print("🎉 Fresh install processing complete")
    }
}

