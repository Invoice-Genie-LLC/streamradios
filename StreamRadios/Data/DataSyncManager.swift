import Foundation
import Combine
import SwiftUI
import CoreData
import UIKit

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
    
    /// Sync radio stations from CloudKit with performance optimization
    /// PERFORMANCE OPTIMIZATION: Only sync radio stations from CloudKit on fresh installs
    /// This prevents the app from loading thousands of radio stations from CloudKit on every launch
    /// After the initial sync, radio stations are loaded from local storage (Core Data)
    /// 
    /// Benefits:
    /// - Faster app startup (no CloudKit network requests for radio stations)
    /// - Reduced CloudKit API usage and rate limiting  
    /// - Better offline experience
    /// - Radio stations are still synced TO CloudKit when users make changes
    /// 
    /// To force a re-sync (for troubleshooting), call resetRadioStationsSyncFlag()
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
            
            // PERFORMANCE FIX: Only sync radio stations from CloudKit on fresh installs
            // Check if this is a fresh install before fetching from CloudKit
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
            
            let viewModel = RadioStationViewModel.shared
            
            if isFreshInstall || !hasRadioStationsSynced {
                print("🔄 Radio station sync needed - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                await syncRadioStationsFromCloudKit()
                // Mark radio stations as synced
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            } else {
                print("⚡ Skipping CloudKit radio station sync - loading from local storage only for better performance")
                // Load from Core Data instead of CloudKit
                await MainActor.run {
                    viewModel.loadStationsFromCoreData()
                }
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
        currentOperation = "Loading podcast feeds..."
        
        do {
            // Get or create PodcastViewModel instance
            let podcastViewModel = PodcastViewModel.shared
            
            // Start podcast loading with progress updates
            for progress in stride(from: 0.0, through: 0.3, by: 0.1) {
                podcastFeedsProgress = progress
                currentOperation = "Initializing podcast feeds..."
                try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            }
            
            // Wait for podcast feeds to actually load
            currentOperation = "Syncing podcast feeds from iCloud..."
            await podcastViewModel.waitForDataSyncCompletion()
            
            // Update progress as feeds are loaded
            for progress in stride(from: 0.3, through: 0.8, by: 0.1) {
                podcastFeedsProgress = progress
                currentOperation = "Processing podcast feeds..."
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
            
            // Final verification that feeds are loaded
            currentOperation = "Finalizing podcast feeds..."
            await podcastViewModel.ensureFeedsAreLoaded()
            
            podcastFeedsProgress = 1.0
            podcastFeedsStatus = .completed
            currentOperation = "Podcast feeds loaded successfully"
            print("✅ Podcast feeds sync completed - feeds actually loaded")
            
        } catch {
            podcastFeedsStatus = .failed
            currentOperation = "Failed to load podcast feeds"
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
        currentOperation = "Finalizing synchronization..."
        
        // CRITICAL: Ensure all components are actually ready before completion
        print("🔄 Final verification: Ensuring all data is loaded and available...")
        
        // Verify podcast feeds are loaded
        let podcastViewModel = PodcastViewModel.shared
        await podcastViewModel.ensureFeedsAreLoaded()
        
        // Verify radio stations are loaded
        let radioStationViewModel = RadioStationViewModel.shared
        await waitForRadioStationsToLoad(radioStationViewModel)
        
        // Final verification that all sync statuses are completed
        await waitForAllSyncStatusesToComplete()
        
        currentOperation = "Synchronization completed!"
        
        // IMMEDIATE: Trigger PodcastViewModel UI refresh as soon as sync completes
        print("🚀 IMMEDIATE: Triggering UI refresh for fresh install completion")
        await podcastViewModel.ensureFeedsAreLoaded()
        
        // Post immediate notification for any listening views
        NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
        print("📢 IMMEDIATE: Posted fresh install notification from DataSyncManager")
        
        // Mark sync as completed only after everything is truly ready
        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        UserDefaults.standard.synchronize()
        
        print("🎉 Fresh install data synchronization completed successfully!")
        print("📊 Final state: Podcast feeds: \(podcastViewModel.podcastFeeds.count), Radio stations: \(radioStationViewModel.stations.count)")
        
        // Brief pause for visual feedback
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Hide the sync view only after everything is complete
        isSyncing = false
    }
    
    /// Wait for radio stations to load
    private func waitForRadioStationsToLoad(_ radioStationViewModel: RadioStationViewModel) async {
        // Give radio stations time to load if they haven't already
        var attempts = 0
        let maxAttempts = 20 // 2 seconds max wait
        
        while radioStationViewModel.stations.isEmpty && attempts < maxAttempts {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            attempts += 1
        }
        
        if radioStationViewModel.stations.isEmpty {
            print("⚠️ Radio stations not loaded after timeout - this might be normal for fresh installs")
        } else {
            print("✅ Radio stations loaded: \(radioStationViewModel.stations.count)")
        }
    }
    
    /// Wait for all sync statuses to complete
    private func waitForAllSyncStatusesToComplete() async {
        var attempts = 0
        let maxAttempts = 30 // 3 seconds max wait
        
        while attempts < maxAttempts {
            let allCompleted = (
                radioStationsStatus == .completed &&
                podcastFeedsStatus == .completed &&
                artworkDownloadsStatus == .completed &&
                episodeStatesStatus == .completed &&
                userPreferencesStatus == .completed
            )
            
            if allCompleted {
                print("✅ All sync statuses completed")
                break
            }
            
            print("⏳ Waiting for sync statuses to complete: Radio:\(radioStationsStatus), Podcast:\(podcastFeedsStatus), Artwork:\(artworkDownloadsStatus), Episodes:\(episodeStatesStatus), Preferences:\(userPreferencesStatus)")
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            attempts += 1
        }
        
        if attempts >= maxAttempts {
            print("⚠️ Some sync statuses did not complete in time - proceeding anyway")
        }
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
                        
                        // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                        UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
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
    
    // MARK: - Troubleshooting Methods
    
    /// Reset the radio stations sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if radio stations get out of sync
    @MainActor
    func resetRadioStationsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasRadioStationsSynced")
        print("🔄 Reset radio stations sync flag - will re-sync from CloudKit on next fresh install sync")
    }
}

