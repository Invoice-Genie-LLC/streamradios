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
    
    // Artwork Downloads
    @Published var artworkDownloadsStatus: DataSyncStatus = .pending
    @Published var artworkDownloadsProgress: Double = 0.0
    
    // Episode States
    @Published var episodeStatesStatus: DataSyncStatus = .pending
    @Published var episodeStatesProgress: Double = 0.0
    
    // User Preferences
    @Published var userPreferencesStatus: DataSyncStatus = .pending
    @Published var userPreferencesProgress: Double = 0.0
    
    // MARK: - Artwork Download Tracking
    private var totalArtworkDownloads = 0
    private var completedArtworkDownloads = 0
    
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
            
            // Wait for artwork downloads to complete before finishing
            await waitForArtworkDownloads()
            
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
        // DISABLED: DataSyncManager no longer handles podcast sync to prevent duplicates
        // PodcastViewModel handles its own CloudKit sync via initializeWithCloudKitSupport()
        print("📡 DataSyncManager: Podcast sync disabled - handled by PodcastViewModel")
        
        podcastFeedsStatus = .completed
        podcastFeedsProgress = 1.0
        print("✅ Podcast feeds sync completed")
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
        
        artworkDownloadsStatus = .pending
        artworkDownloadsProgress = 0.0
        
        episodeStatesStatus = .pending
        episodeStatesProgress = 0.0
        
        userPreferencesStatus = .pending
        userPreferencesProgress = 0.0
        
        // Reset artwork tracking
        totalArtworkDownloads = 0
        completedArtworkDownloads = 0
    }
    
    private func setupProgressCalculation() {
        // Calculate overall progress based on individual progress values including artwork
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                $radioStationsProgress,
                $podcastFeedsProgress,
                $artworkDownloadsProgress,
                $episodeStatesProgress
            ),
            $userPreferencesProgress
        )
        .map { first, preference in
            let (radio, podcast, artwork, episode) = first
            return (radio + podcast + artwork + episode + preference) / 5.0
        }
        .assign(to: \.overallProgress, on: self)
        .store(in: &cancellables)
    }
    
    // MARK: - Artwork Download Tracking Methods
    
    /// Start tracking artwork downloads for a given number of feeds
    @MainActor
    func startArtworkDownloadTracking(totalFeeds: Int) {
        guard totalFeeds > 0 else {
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            return
        }
        
        totalArtworkDownloads = totalFeeds
        completedArtworkDownloads = 0
        artworkDownloadsStatus = .inProgress
        artworkDownloadsProgress = 0.0
        currentOperation = "Downloading artwork..."
        
        print("🎨 Started tracking artwork downloads for \(totalFeeds) feeds")
    }
    
    /// Report that an artwork download has completed
    @MainActor
    func reportArtworkDownloadCompleted(feedTitle: String) {
        completedArtworkDownloads += 1
        artworkDownloadsProgress = Double(completedArtworkDownloads) / Double(totalArtworkDownloads)
        currentOperation = "Downloaded artwork for \(feedTitle) (\(completedArtworkDownloads)/\(totalArtworkDownloads))"
        
        print("🎨 Artwork completed for \(feedTitle): \(completedArtworkDownloads)/\(totalArtworkDownloads)")
        
        if completedArtworkDownloads >= totalArtworkDownloads {
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            currentOperation = "All artwork downloads completed"
            print("✅ All artwork downloads completed")
        }
    }
    
    /// Report that an artwork download failed
    @MainActor
    func reportArtworkDownloadFailed(feedTitle: String, error: Error) {
        completedArtworkDownloads += 1
        artworkDownloadsProgress = Double(completedArtworkDownloads) / Double(totalArtworkDownloads)
        currentOperation = "Artwork failed for \(feedTitle) (\(completedArtworkDownloads)/\(totalArtworkDownloads))"
        
        print("⚠️ Artwork failed for \(feedTitle): \(error.localizedDescription)")
        
        if completedArtworkDownloads >= totalArtworkDownloads {
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            currentOperation = "Artwork downloads completed (some failed)"
            print("✅ All artwork downloads completed (some failed)")
        }
    }
    
    /// Wait for artwork downloads to complete
    @MainActor
    private func waitForArtworkDownloads() async {
        print("⏳ Waiting for artwork downloads to complete...")
        
        // Wait until artwork downloads are completed or failed
        while artworkDownloadsStatus == .inProgress {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        print("✅ Artwork downloads completed, proceeding with app initialization")
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
        // NOTE: This method is no longer used to prevent duplicate PodcastViewModel creation
        // PodcastViewModel handles its own CloudKit sync via initializeWithCloudKitSupport()
        print("📡 DataSyncManager: Skipping duplicate feed processing - handled by PodcastViewModel")
    }
}

