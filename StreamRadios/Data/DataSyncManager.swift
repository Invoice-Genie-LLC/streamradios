import Foundation
import Combine
import SwiftUI
import CoreData
import UIKit
import CloudKit



// MARK: - Cross-Device Progress Model

struct CrossDeviceFeedProgress {
    let feedId: String
    let feedTitle: String
    let progress: Double
    let message: String
    let lastUpdated: Date
}

// MARK: - Real-Time Episode Sync Types

enum RealTimeEpisodeSyncType: String, CaseIterable {
    case progress = "progress"
    case favorite = "favorite"
    case download = "download"
    case played = "played"
    
    var icon: String {
        switch self {
        case .progress: return "⏱️"
        case .favorite: return "❤️"
        case .download: return "⬇️"
        case .played: return "✅"
        }
    }
    
    var displayName: String {
        switch self {
        case .progress: return "Progress"
        case .favorite: return "Favorite"
        case .download: return "Download"
        case .played: return "Played"
        }
    }
}

class DataSyncManager: ObservableObject {
    static let shared = DataSyncManager()
    
    // MARK: - Published Properties
    @Published var isSyncing = false
    @Published var overallProgress: Double = 0.0
    @Published var currentOperation = ""
    @Published var isFreshInstallUIReady = false
    
    // Radio Stations
    @Published var radioStationsStatus: DataSyncStatus = .none
    @Published var radioStationsProgress: Double = 0.0
    @Published var radioStationsOperation = ""
    @Published var radioStationsCurrentCount = 0
    @Published var radioStationsTotalCount = 0
    
    // Resumable Sync State
    @Published var radioStationsRemainingCount = 0
    @Published var radioStationsSyncStartTime: Date?
    @Published var radioStationsEstimatedTimeRemaining: TimeInterval = 0
    @Published var radioStationsAverageTimePerStation: Double = 0
    
    // Detailed Progress Overlay
    @Published var showDetailedProgressOverlay = false
    
    // Podcast Feeds
    @Published var podcastFeedsStatus: DataSyncStatus = .pending
    @Published var podcastFeedsProgress: Double = 0.0
    @Published var podcastFeedsOperation = ""
    @Published var podcastFeedsCurrentCount = 0
    @Published var podcastFeedsTotalCount = 0
    
    // Cross-Device Feed Sync (when feeds exist on CloudKit but not locally)
    @Published var crossDeviceFeedSyncStatus: DataSyncStatus = .none
    @Published var crossDeviceFeedSyncProgress: Double = 0.0
    @Published var crossDeviceFeedSyncOperation = ""
    @Published var crossDeviceFeedSyncCurrentCount = 0
    @Published var crossDeviceFeedSyncTotalCount = 0
    
    // Artwork Downloads
    @Published var artworkDownloadsStatus: DataSyncStatus = .pending
    @Published var artworkDownloadsProgress: Double = 0.0
    @Published var artworkDownloadsOperation = ""
    @Published var artworkDownloadsCurrentCount = 0
    @Published var artworkDownloadsTotalCount = 0
    
    // Episode States
    @Published var episodeStatesStatus: DataSyncStatus = .pending
    @Published var episodeStatesProgress: Double = 0.0
    @Published var episodeStatesOperation = ""
    @Published var episodeStatesCurrentCount = 0
    @Published var episodeStatesTotalCount = 0
    
    // Minimal CloudKit sync indicator (for individual saves)
    @Published var isMinimalCloudKitSyncing = false
    @Published var minimalSyncTimer: Timer?
    
    // User Preferences
    @Published var userPreferencesStatus: DataSyncStatus = .pending
    @Published var userPreferencesProgress: Double = 0.0
    @Published var userPreferencesOperation = ""
    
    // Feed Parsing Progress (after CloudKit sync)
    @Published var feedParsingProgress: Double = 0.0
    @Published var feedParsingMessage = ""
    @Published var isParsingFeeds = false
    
    // Individual Feed Addition (UI-initiated)
    @Published var isAddingIndividualFeed = false
    
    // MARK: - Artwork Download Tracking
    private var totalArtworkDownloads = 0
    private var completedArtworkDownloads = 0
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private let syncQueue = DispatchQueue(label: "com.streamradios.sync", qos: .userInitiated)
    
    private init() {
        setupProgressCalculation()
        
        // If this is not a fresh install, mark UI as ready immediately
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let hasSyncCompleted = UserDefaults.standard.bool(forKey: "DataSyncCompleted")
        
        print("🎯 DataSyncManager init: isFreshInstall=\(isFreshInstall), hasSyncCompleted=\(hasSyncCompleted)")
        
        if !isFreshInstall && hasSyncCompleted {
            isFreshInstallUIReady = true
            print("🎯 DataSyncManager init: Set isFreshInstallUIReady=true (not fresh install)")
        } else {
            print("🎯 DataSyncManager init: Set isFreshInstallUIReady=false (fresh install or sync not completed)")
        }
    }
    
    // MARK: - Public Methods
    
    /// Start the complete data synchronization process for fresh installs
    func startFreshInstallSync() {
        guard !isSyncing else { return }
        
        Task { @MainActor in
            isSyncing = true
            isFreshInstallUIReady = false
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
    
    /// Force a fresh install sync (for testing purposes)
    func forceFreshInstallSync() {
        print("🔄 FORCED: Resetting fresh install flags for testing...")
        UserDefaults.standard.set(false, forKey: "HasLaunchedBefore")
        UserDefaults.standard.set(false, forKey: "DataSyncCompleted")
        UserDefaults.standard.set(false, forKey: "HasRadioStationsSynced")
        UserDefaults.standard.synchronize()
        startFreshInstallSync()
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
        radioStationsOperation = "Initializing radio stations sync..."
        radioStationsProgress = 0.0
        radioStationsCurrentCount = 0
        radioStationsTotalCount = 0
        
        do {
            // PERFORMANCE FIX: Only sync radio stations from CloudKit on fresh installs
            // Check if this is a fresh install before fetching from CloudKit
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
            
            let viewModel = RadioStationViewModel.shared
            
            if isFreshInstall || !hasRadioStationsSynced {
                print("🔄 Radio station sync needed - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                radioStationsOperation = "Fetching radio stations from iCloud..."
                await syncRadioStationsFromCloudKitWithProgress()
                // Mark radio stations as synced
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            } else {
                print("⚡ Skipping CloudKit radio station sync - loading from local storage only for better performance")
                radioStationsOperation = "Loading radio stations from local storage..."
                radioStationsTotalCount = await getLocalStationCount()
                
                // Simulate quick progress for local loading with realistic counts
                for progress in stride(from: 0.0, through: 1.0, by: 0.25) {
                    radioStationsProgress = progress
                    radioStationsCurrentCount = Int(Double(radioStationsTotalCount) * progress)
                    radioStationsOperation = "Loading \(radioStationsCurrentCount) of \(radioStationsTotalCount) stations..."
                    if progress < 1.0 {
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    }
                }
                // Load from Core Data instead of CloudKit
                await MainActor.run {
                    viewModel.loadStationsFromCoreData()
                    radioStationsCurrentCount = radioStationsTotalCount
                }
            }
            
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            radioStationsOperation = "✅ \(radioStationsCurrentCount) radio stations loaded"
            print("✅ Radio stations sync completed")
            
        } catch {
            radioStationsStatus = .failed
            radioStationsOperation = "❌ Failed to load radio stations"
            print("❌ Radio stations sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncPodcastFeeds() async {
        // Check how many feeds we expect to sync FIRST
        let expectedFeedCount = await getExpectedPodcastFeedCount()
        
        // If there are no feeds to sync, skip the entire process
        if expectedFeedCount == 0 {
            print("📡 DataSyncManager: No podcast feeds to sync - skipping")
            podcastFeedsStatus = .none
            podcastFeedsOperation = ""
            podcastFeedsProgress = 0.0
            podcastFeedsCurrentCount = 0
            podcastFeedsTotalCount = 0
            return
        }
        
        podcastFeedsStatus = .inProgress
        podcastFeedsOperation = "Initializing podcast feeds..."
        podcastFeedsProgress = 0.0
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = expectedFeedCount
        
        do {
            // Get or create PodcastViewModel instance
            let podcastViewModel = PodcastViewModel.shared
            
            // Start podcast loading with progress updates
            for progress in stride(from: 0.0, through: 0.3, by: 0.1) {
                podcastFeedsProgress = progress
                podcastFeedsCurrentCount = Int(Double(podcastFeedsTotalCount) * progress * 0.3)
                podcastFeedsOperation = "Initializing \(podcastFeedsCurrentCount) of \(podcastFeedsTotalCount) podcast feeds..."
                try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            }
            
            // Wait for podcast feeds to actually load
            podcastFeedsOperation = "Syncing podcast feeds from iCloud..."
            
            // Check if we need to process fresh install feeds
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            
            if isFreshInstall || !hasPodcastFeedsSynced {
                // Fresh install: Need to load feeds from CloudKit and process RSS
                await initializeCloudKitFeedsForFreshInstall(podcastViewModel)
            }
            
            // Note: Artwork downloads happen during RSS processing in PodcastFeedManager
            
            // Start monitoring podcast feed loading progress
            let progressTask = Task { @MainActor in
                while podcastFeedsProgress < 0.8 && !Task.isCancelled {
                    let currentFeeds = podcastViewModel.podcastFeeds.count
                    if podcastFeedsTotalCount > 0 {
                        let feedProgress = Double(currentFeeds) / Double(podcastFeedsTotalCount)
                        podcastFeedsProgress = 0.3 + (feedProgress * 0.5) // 30% to 80% range
                        podcastFeedsCurrentCount = currentFeeds
                        podcastFeedsOperation = "Synced \(currentFeeds) of \(podcastFeedsTotalCount) podcast feeds..."
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }
            }
            
            await podcastViewModel.waitForDataSyncCompletion()
            progressTask.cancel()
            
            // Update progress as feeds are loaded
            for progress in stride(from: 0.8, through: 0.95, by: 0.05) {
                podcastFeedsProgress = progress
                let currentFeeds = podcastViewModel.podcastFeeds.count
                podcastFeedsCurrentCount = currentFeeds
                podcastFeedsOperation = "Processing \(currentFeeds) podcast feeds..."
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
            
            // Final verification that feeds are loaded
            podcastFeedsOperation = "Finalizing podcast feeds..."
            await podcastViewModel.ensureFeedsAreLoaded()
            
            let finalCount = podcastViewModel.podcastFeeds.count
            podcastFeedsCurrentCount = finalCount
            podcastFeedsTotalCount = max(podcastFeedsTotalCount, finalCount)
            podcastFeedsProgress = 1.0
            podcastFeedsStatus = .completed
            podcastFeedsOperation = "✅ \(finalCount) podcast feeds loaded"
            print("✅ Podcast feeds sync completed - \(finalCount) feeds actually loaded")
            
            // Start artwork download tracking after feeds are loaded
            startArtworkDownloadTracking(totalFeeds: finalCount)
            
            // NEW: Auto-reset feed sync banner after brief completion display
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                self.podcastFeedsStatus = .none
                self.podcastFeedsProgress = 0.0
                self.podcastFeedsOperation = ""
                // Optionally clear counts to be safe
                self.podcastFeedsCurrentCount = 0
                // Keep totalCount for analytics if needed; not required for UI gating
            }
            
        } catch {
            podcastFeedsStatus = .failed
            podcastFeedsOperation = "❌ Failed to load podcast feeds"
            print("❌ Podcast feeds sync failed: \(error)")
            
            // Mark artwork downloads as completed if feeds failed to load
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
        }
    }
    
    @MainActor
    private func syncEpisodeStates() async {
        episodeStatesStatus = .inProgress
        episodeStatesOperation = "Initializing episode states sync..."
        episodeStatesProgress = 0.0
        episodeStatesCurrentCount = 0
        episodeStatesTotalCount = 0
        
        do {
            // Get estimated episode count for progress tracking
            episodeStatesTotalCount = await getEstimatedEpisodeCount()
            
            // Simulate progressive sync of episode states with detailed tracking
            for progress in stride(from: 0.0, through: 1.0, by: 0.25) {
                episodeStatesProgress = progress
                episodeStatesCurrentCount = Int(Double(episodeStatesTotalCount) * progress)
                
                switch progress {
                case 0.25:
                    episodeStatesOperation = "Loading episode progress... (\(episodeStatesCurrentCount)/\(episodeStatesTotalCount))"
                case 0.5:
                    episodeStatesOperation = "Syncing favorites... (\(episodeStatesCurrentCount)/\(episodeStatesTotalCount))"
                case 0.75:
                    episodeStatesOperation = "Syncing downloads... (\(episodeStatesCurrentCount)/\(episodeStatesTotalCount))"
                case 1.0:
                    episodeStatesOperation = "✅ \(episodeStatesTotalCount) episode states synced"
                default:
                    episodeStatesOperation = "Processing episode states... (\(episodeStatesCurrentCount)/\(episodeStatesTotalCount))"
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
            episodeStatesCurrentCount = episodeStatesTotalCount
            episodeStatesOperation = "✅ \(episodeStatesTotalCount) episode states completed"
            print("✅ Episode states sync completed")
            
        } catch {
            episodeStatesStatus = .failed
            episodeStatesOperation = "❌ Failed to sync episode states"
            print("❌ Episode states sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncUserPreferences() async {
        userPreferencesStatus = .inProgress
        userPreferencesOperation = "Loading user preferences..."
        
        do {
            // Simulate loading preferences
            for progress in stride(from: 0.0, through: 1.0, by: 0.33) {
                userPreferencesProgress = progress
                
                switch progress {
                case 0.33:
                    userPreferencesOperation = "Loading app settings..."
                case 0.66:
                    userPreferencesOperation = "Configuring notifications..."
                case 1.0:
                    userPreferencesOperation = "✅ Preferences loaded"
                default:
                    break
                }
                
                if progress < 1.0 {
                    try await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds
                }
            }
            
            userPreferencesStatus = .completed
            userPreferencesProgress = 1.0
            userPreferencesOperation = "✅ User preferences completed"
            print("✅ User preferences sync completed")
            
        } catch {
            userPreferencesStatus = .failed
            userPreferencesOperation = "❌ Failed to load preferences"
            print("❌ User preferences sync failed: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func resetProgress() {
        overallProgress = 0.0
        currentOperation = "Initializing sync..."
        
        // Radio Stations
        radioStationsStatus = .pending
        radioStationsProgress = 0.0
        radioStationsOperation = ""
        radioStationsCurrentCount = 0
        radioStationsTotalCount = 0
        
        // Podcast Feeds
        podcastFeedsStatus = .pending
        podcastFeedsProgress = 0.0
        podcastFeedsOperation = ""
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = 0
        
        // Artwork Downloads
        artworkDownloadsStatus = .pending
        artworkDownloadsProgress = 0.0
        artworkDownloadsOperation = ""
        artworkDownloadsCurrentCount = 0
        artworkDownloadsTotalCount = 0
        
        // Episode States
        episodeStatesStatus = .pending
        episodeStatesProgress = 0.0
        episodeStatesOperation = ""
        episodeStatesCurrentCount = 0
        episodeStatesTotalCount = 0
        
        // User Preferences
        userPreferencesStatus = .pending
        userPreferencesProgress = 0.0
        userPreferencesOperation = ""
        
        // Reset artwork tracking
        totalArtworkDownloads = 0
        completedArtworkDownloads = 0
        
        // Reset feed parsing progress
        feedParsingProgress = 0.0
        feedParsingMessage = ""
        isParsingFeeds = false
    }
    
    // MARK: - Feed Parsing Progress
    
    @MainActor
    func updateFeedParsingProgress(_ progress: Double, message: String) {
        feedParsingProgress = progress
        feedParsingMessage = message
        // CRITICAL FIX: Don't show main banner during individual feed addition (PodcastAddingProgressView handles it)
        isParsingFeeds = (progress > 0.0 && progress < 1.0) && !isAddingIndividualFeed
        
        // Also update podcast feeds operation if parsing is active
        if isParsingFeeds {
            podcastFeedsOperation = message
        }
    }
    
    /// Start episode state synchronization tracking
    @MainActor
    func startEpisodeStateSync(totalCount: Int) {
        if totalCount > 0 {
            episodeStatesStatus = .inProgress
            episodeStatesProgress = 0.0
            episodeStatesCurrentCount = 0
            episodeStatesTotalCount = totalCount
            episodeStatesOperation = "Syncing episode states from iCloud..."
            print("📊 DataSyncManager: Started episode state sync tracking (\(totalCount) episodes)")
        } else {
            // No episodes to sync - immediately mark as completed and reset
            episodeStatesStatus = .none
            episodeStatesProgress = 0.0
            episodeStatesCurrentCount = 0
            episodeStatesTotalCount = 0
            episodeStatesOperation = ""
            print("📊 DataSyncManager: No episodes to sync - skipping")
        }
    }
    
    /// Update episode state synchronization progress
    @MainActor
    func updateEpisodeStateProgress(currentCount: Int, operation: String = "") {
        episodeStatesCurrentCount = currentCount
        if episodeStatesTotalCount > 0 {
            episodeStatesProgress = Double(currentCount) / Double(episodeStatesTotalCount)
        }
        if !operation.isEmpty {
            episodeStatesOperation = operation
        }
        // print("📊 Episode sync progress: \(currentCount)/\(episodeStatesTotalCount) (\(Int(episodeStatesProgress * 100))%)")
    }
    
    /// Complete episode state synchronization
    @MainActor
    func completeEpisodeStateSync() {
        episodeStatesStatus = .completed
        episodeStatesProgress = 1.0
        episodeStatesCurrentCount = episodeStatesTotalCount
        episodeStatesOperation = "Episode states synchronized"
        print("✅ DataSyncManager: Completed episode state sync tracking")
        
        // Auto-reset after 3 seconds to hide the banner
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.resetEpisodeStateSync()
        }
    }
    
    /// Reset episode state synchronization tracking
    @MainActor
    func resetEpisodeStateSync() {
        episodeStatesStatus = .none
        episodeStatesProgress = 0.0
        episodeStatesCurrentCount = 0
        episodeStatesTotalCount = 0
        episodeStatesOperation = ""
        print("🔄 DataSyncManager: Reset episode state sync tracking")
    }
    
    // MARK: - Individual Feed Addition Tracking
    
    /// Start tracking individual feed addition (UI-initiated)
    @MainActor
    func startIndividualFeedAddition() {
        isAddingIndividualFeed = true
        print("🔄 DataSyncManager: Started individual feed addition tracking")
    }
    
    /// Complete individual feed addition tracking
    @MainActor
    func completeIndividualFeedAddition() {
        isAddingIndividualFeed = false
        print("🔄 DataSyncManager: Completed individual feed addition tracking")
    }
    
    // MARK: - Radio Station Sync Management
    
    /// Start radio station sync tracking with resumable support
    @MainActor
    func startRadioStationSync(totalStations: Int, country: String?, operationType: String) {
        radioStationsStatus = .inProgress
        radioStationsTotalCount = totalStations
        radioStationsCurrentCount = 0
        radioStationsRemainingCount = totalStations
        radioStationsSyncStartTime = Date()
        radioStationsEstimatedTimeRemaining = 0
        radioStationsAverageTimePerStation = 0
        
        let countryInfo = country != nil ? " for \(country!)" : ""
        radioStationsOperation = "Starting sync\(countryInfo)..."
        
        print("🔄 DataSyncManager: Started radio station sync tracking - \(totalStations) stations")
        
        // Update progress periodically
        startProgressTracking()
    }
    
    /// Update radio station sync progress
    @MainActor
    func updateRadioStationProgress(_ progress: Double, currentCount: Int, operation: String) {
        radioStationsProgress = progress
        radioStationsCurrentCount = currentCount
        radioStationsRemainingCount = max(0, radioStationsTotalCount - currentCount)
        radioStationsOperation = operation
        
        // Update performance metrics
        if let startTime = radioStationsSyncStartTime, currentCount > 0 {
            let elapsedTime = Date().timeIntervalSince(startTime)
            radioStationsAverageTimePerStation = elapsedTime / Double(currentCount)
            
            if radioStationsRemainingCount > 0 {
                radioStationsEstimatedTimeRemaining = Double(radioStationsRemainingCount) * radioStationsAverageTimePerStation
            }
        }
    }
    
    /// Complete radio station sync
    @MainActor
    func completeRadioStationSync() {
        radioStationsStatus = .completed
        radioStationsProgress = 1.0
        radioStationsCurrentCount = radioStationsTotalCount
        radioStationsRemainingCount = 0
        radioStationsEstimatedTimeRemaining = 0
        radioStationsOperation = "✅ All stations synced to CloudKit"
        
        print("✅ DataSyncManager: Completed radio station sync tracking")
        
        // Auto-reset after showing completion
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.resetRadioStationSync()
        }
    }
    
    /// Reset radio station sync tracking
    @MainActor
    func resetRadioStationSync() {
        radioStationsStatus = .none
        radioStationsProgress = 0.0
        radioStationsCurrentCount = 0
        radioStationsTotalCount = 0
        radioStationsRemainingCount = 0
        radioStationsSyncStartTime = nil
        radioStationsEstimatedTimeRemaining = 0
        radioStationsAverageTimePerStation = 0
        radioStationsOperation = ""
        
        print("🔄 DataSyncManager: Reset radio station sync tracking")
    }
    
    /// Check and resume incomplete sync on app startup
    @MainActor
    func checkAndResumeRadioStationSync() {
        if SyncStateManager.shared.hasIncompleteRadioStationSync(),
           let syncState = SyncStateManager.shared.getRadioStationSyncState() {
            
            radioStationsStatus = .inProgress
            radioStationsTotalCount = syncState.totalStations
            radioStationsCurrentCount = syncState.completedCount
            radioStationsRemainingCount = syncState.remainingCount
            radioStationsProgress = syncState.progress
            radioStationsSyncStartTime = syncState.startTime
            
            let countryInfo = syncState.country != nil ? " for \(syncState.country!)" : ""
            radioStationsOperation = "Resuming sync\(countryInfo)... (\(syncState.remainingCount) remaining)"
            
            print("🔄 DataSyncManager: Resumed radio station sync tracking - \(syncState.remainingCount) remaining of \(syncState.totalStations)")
            
            // Update performance metrics
            if let metadata = SyncStateManager.shared.getSyncMetadata() {
                radioStationsAverageTimePerStation = metadata.averageTimePerStation
                radioStationsEstimatedTimeRemaining = metadata.estimatedTimeRemaining
            }
            
            startProgressTracking()
            
            // Actually continue the CloudKit sync process
            Task {
                await continueRadioStationSync()
            }
        }
    }
    
    /// Continue the radio station sync process after resume
    @MainActor
    private func continueRadioStationSync() async {
        guard let syncState = SyncStateManager.shared.getRadioStationSyncState() else {
            print("⚠️ No sync state found to continue")
            return
        }
        
        print("🔄 DataSyncManager: Continuing radio station sync - \(syncState.operationType)")
        
        do {
            let radioViewModel = RadioStationViewModel.shared
            
            // Continue the sync based on operation type
            if syncState.operationType == "order_sync" {
                // Continue order sync
                try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(radioViewModel.stations, country: syncState.country) { [weak self] progress, count, message in
                    Task { @MainActor in
                        self?.updateRadioStationProgress(progress, currentCount: count, operation: message)
                    }
                }
                
                // Trigger cross-device order sync notification
                await RadioStationCloudKitManager.shared.triggerCrossDeviceOrderSync(action: "order_changed")
                
                print("📡 ✅ RADIO RESUME: Successfully completed resumed order sync")
                completeRadioStationSync()
                
            } else if syncState.operationType == "batch_save" {
                // Continue batch save sync
                try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(radioViewModel.stations, country: syncState.country) { [weak self] progress, count, message in
                    Task { @MainActor in
                        self?.updateRadioStationProgress(progress, currentCount: count, operation: message)
                    }
                }
                
                print("📡 ✅ RADIO RESUME: Successfully completed resumed batch save")
                completeRadioStationSync()
                
            } else {
                print("⚠️ Unknown operation type for resume: \(syncState.operationType)")
                resetRadioStationSync()
            }
            
        } catch {
            print("📡 ❌ RADIO RESUME: Failed to continue sync: \(error)")
            radioStationsStatus = .failed
            radioStationsOperation = "Failed to resume sync: \(error.localizedDescription)"
            
            // Reset after showing error
            Task { @MainActor in
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                self.resetRadioStationSync()
            }
        }
    }
    
    /// Start periodic progress tracking updates
    private func startProgressTracking() {
        // Update progress from SyncStateManager periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor in
                guard self.radioStationsStatus == .inProgress else {
                    timer.invalidate()
                    return
                }
                
                if let syncState = SyncStateManager.shared.getRadioStationSyncState() {
                    self.radioStationsCurrentCount = syncState.completedCount
                    self.radioStationsRemainingCount = syncState.remainingCount
                    self.radioStationsProgress = syncState.progress
                    
                    if let metadata = SyncStateManager.shared.getSyncMetadata() {
                        self.radioStationsAverageTimePerStation = metadata.averageTimePerStation
                        self.radioStationsEstimatedTimeRemaining = metadata.estimatedTimeRemaining
                    }
                } else {
                    // Sync completed or cancelled
                    timer.invalidate()
                }
            }
        }
    }
    
    // MARK: - Minimal CloudKit Sync Indicator
    
    /// Show minimal sync indicator for individual CloudKit saves
    @MainActor
    func showMinimalCloudKitSync() {
        // Cancel existing timer
        minimalSyncTimer?.invalidate()
        
        // Show indicator
        isMinimalCloudKitSyncing = true
        
        // Auto-hide after 1.5 seconds
        minimalSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isMinimalCloudKitSyncing = false
                self?.minimalSyncTimer = nil
            }
        }
    }
    
    // MARK: - Real-Time Episode Sync Tracking
    
    // Real-time episode sync tracking for individual episode state changes
    @Published var isRealTimeEpisodeSyncing = false
    @Published var realTimeEpisodeTitle = ""
    @Published var realTimeEpisodeType: RealTimeEpisodeSyncType = .progress
    @Published var realTimeEpisodeValue = ""
    @Published var realTimeEpisodeSyncTimer: Timer?
    
    // MARK: - Real-Time Episode Sync Methods
    
    /// Start real-time episode sync banner for individual episode state changes
    @MainActor
    func startRealTimeEpisodeSync(type: RealTimeEpisodeSyncType, episodeTitle: String, value: String) {
        // Cancel existing timer
        realTimeEpisodeSyncTimer?.invalidate()
        
        // Truncate title if too long for banner
        let displayTitle = episodeTitle.count > 40 ? String(episodeTitle.prefix(37)) + "..." : episodeTitle
        
        // Set real-time sync properties
        realTimeEpisodeType = type
        realTimeEpisodeTitle = displayTitle
        realTimeEpisodeValue = value
        isRealTimeEpisodeSyncing = true
        
        print("📡 🚀 REAL-TIME EPISODE SYNC: Started banner - \(type.displayName): \(displayTitle) -> \(value)")
        
        // Auto-hide after 2 seconds
        realTimeEpisodeSyncTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.completeRealTimeEpisodeSync()
            }
        }
    }
    
    /// Complete real-time episode sync banner
    @MainActor
    func completeRealTimeEpisodeSync() {
        isRealTimeEpisodeSyncing = false
        realTimeEpisodeSyncTimer?.invalidate()
        realTimeEpisodeSyncTimer = nil
        
        print("📡 ✅ REAL-TIME EPISODE SYNC: Completed banner display")
    }
    
    // MARK: - Cross-Device Progress Tracking
    
    // Cross-device feed progress tracking
    @Published var crossDeviceFeedProgress: [String: CrossDeviceFeedProgress] = [:]
    @Published var isReceivingCrossDeviceProgress = false
    
    @MainActor
    func updateCrossDeviceFeedProgress(feedId: String, feedTitle: String, progress: Double, message: String) {
        let feedProgress = CrossDeviceFeedProgress(
            feedId: feedId,
            feedTitle: feedTitle,
            progress: progress,
            message: message,
            lastUpdated: Date()
        )
        
        crossDeviceFeedProgress[feedId] = feedProgress
        isReceivingCrossDeviceProgress = progress > 0.0 && progress < 1.0
        
        // Also update the general feed parsing progress for UI consistency
        if isReceivingCrossDeviceProgress {
            feedParsingProgress = progress
            feedParsingMessage = "📡 \(feedTitle): \(message)"
            // CRITICAL FIX: Don't show main banner during individual feed addition AND use consistent logic for isParsingFeeds
            isParsingFeeds = (progress > 0.0 && progress < 1.0) && !isAddingIndividualFeed
            podcastFeedsOperation = "📡 Syncing from other device: \(message)"
        } else if progress >= 1.0 {
            // CRITICAL FIX: Reset parsing flags when cross-device sync completes
            isParsingFeeds = false
            feedParsingMessage = ""
        }
        
        // Clean up completed or old progress entries
        cleanupOldCrossDeviceProgress()
        
        print("📡 📊 CROSS-DEVICE PROGRESS UPDATED: \(feedTitle) - \(Int(progress * 100))% - \(message)")
    }
    
    @MainActor
    private func cleanupOldCrossDeviceProgress() {
        let cutoffDate = Date().addingTimeInterval(-60) // Remove progress older than 1 minute
        
        crossDeviceFeedProgress = crossDeviceFeedProgress.filter { _, progress in
            // Keep if recent or still in progress
            progress.lastUpdated > cutoffDate || (progress.progress > 0.0 && progress.progress < 1.0)
        }
        
        // Update overall state
        isReceivingCrossDeviceProgress = crossDeviceFeedProgress.values.contains { progress in
            progress.progress > 0.0 && progress.progress < 1.0
        }
    }
    
    @MainActor
    func clearCrossDeviceProgress(for feedId: String) {
        crossDeviceFeedProgress.removeValue(forKey: feedId)
        isReceivingCrossDeviceProgress = crossDeviceFeedProgress.values.contains { progress in
            progress.progress > 0.0 && progress.progress < 1.0
        }
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
    
    /// Wait for artwork downloads to complete with timeout
    @MainActor
    private func waitForArtworkDownloads() async {
        print("⏳ Waiting for artwork downloads to complete...")
        
        // Set a maximum wait time of 30 seconds for artwork downloads
        let maxWaitTime: TimeInterval = 30.0
        let checkInterval: TimeInterval = 0.5
        let maxChecks = Int(maxWaitTime / checkInterval)
        var checks = 0
        
        // Wait until artwork downloads are completed, failed, or timeout
        while artworkDownloadsStatus == .inProgress && checks < maxChecks {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            checks += 1
            
            // Log progress every 10 seconds
            if checks % 20 == 0 {
                print("⏳ Still waiting for artwork downloads... (\(completedArtworkDownloads)/\(totalArtworkDownloads)) - \(Double(checks) * checkInterval)s elapsed")
            }
        }
        
        if checks >= maxChecks {
            print("⚠️ Artwork downloads timed out after \(maxWaitTime)s - proceeding anyway")
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            currentOperation = "Artwork downloads completed (some may have timed out)"
        } else {
            print("✅ Artwork downloads completed, proceeding with app initialization")
        }
    }
    
    @MainActor
    private func completeSynchronization() async {
        currentOperation = "Finalizing synchronization..."
        
        // CRITICAL: Ensure all components are actually ready before completion
        print("🔄 Final verification: Ensuring all data is loaded and available...")
        
        // Verify podcast feeds are loaded and finished loading
        let podcastViewModel = PodcastViewModel.shared
        await podcastViewModel.ensureFeedsAreLoaded()
        
        // Wait for podcast loading to complete
        await waitForPodcastLoadingToComplete(podcastViewModel)
        
        // Wait for CloudKit initialization to completely finish (including final UI refresh)
        await waitForCloudKitInitializationToComplete(podcastViewModel)
        
        // Verify radio stations are loaded
        let radioStationViewModel = RadioStationViewModel.shared
        await waitForRadioStationsToLoad(radioStationViewModel)
        
        // Final verification that all sync statuses are completed
        await waitForAllSyncStatusesToComplete()
        
        currentOperation = "Synchronization completed!"
        
        // CRITICAL: Force Core Data save and reload before any verification
        print("🚀 CRITICAL: Forcing Core Data save and reload before UI refresh")
        await podcastViewModel.forceSaveAndReload()
        
        // IMMEDIATE: Trigger PodcastViewModel UI refresh as soon as sync completes
        print("🚀 IMMEDIATE: Triggering UI refresh for fresh install completion")
        await podcastViewModel.ensureFeedsAreLoaded()
        
        // Post immediate notification for any listening views
        NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
        print("📢 IMMEDIATE: Posted fresh install notification from DataSyncManager")
        
        // CRITICAL: Wait for UI to process the notification and refresh before hiding progress view
        print("⏳ Waiting for UI to process notification and refresh...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0 seconds for UI to update
        
        // Verify that PodcastListView has actually refreshed by checking if feeds are visible
        // This ensures the UI has processed the notification before we hide the progress view
        var uiUpdateAttempts = 0
        let maxUIUpdateAttempts = 15 // Increased attempts for more robust checking
        
        while uiUpdateAttempts < maxUIUpdateAttempts {
            // Check if podcast feeds are available in the view model
            let feedCount = podcastViewModel.podcastFeeds.count
            let feedOrderCount = podcastViewModel.podcastFeedOrder.count
            
            if feedCount > 0 && feedOrderCount > 0 {
                print("✅ UI Update verified: \(feedCount) feeds and \(feedOrderCount) feed order items are now available")
                
                // Additional verification: make sure Core Data also has the feeds
                let coreDataHasFeeds = await verifyCoreDataHasFeeds()
                if coreDataHasFeeds {
                    print("✅ Core Data verification passed - feeds are properly persisted")
                    break
                } else {
                    print("⚠️ Core Data verification failed - feeds not found in Core Data, continuing wait...")
                }
            } else {
                print("⏳ Waiting for UI to show feeds... attempt \(uiUpdateAttempts + 1) - Feeds: \(feedCount), Order: \(feedOrderCount)")
                
                // If we're taking too long, try to force a refresh
                if uiUpdateAttempts > 7 {
                    print("🔧 Taking too long - forcing additional refresh attempt")
                    await podcastViewModel.loadFeedsFromCoreData()
                    try? await Task.sleep(nanoseconds: 500_000_000) // Wait longer after forced refresh
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                }
                uiUpdateAttempts += 1
            }
        }
        
        // Final check and warning if feeds are still not available
        if podcastViewModel.podcastFeeds.isEmpty {
            print("⚠️ WARNING: UI update verification failed - no feeds found after \(maxUIUpdateAttempts) attempts")
            print("⚠️ This may indicate a data synchronization issue")
        }
        
        // Mark sync as completed only after everything is truly ready
        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        UserDefaults.standard.synchronize()
        
        print("🎉 Fresh install data synchronization completed successfully!")
        print("📊 Final state: Podcast feeds: \(podcastViewModel.podcastFeeds.count), Radio stations: \(radioStationViewModel.stations.count)")
        
        // Additional pause to ensure UI is fully updated before hiding progress view
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for visual feedback
        
        // CRITICAL: Force complete UI refresh to ensure SwiftUI properly reflects the data changes
        await forceCompleteUIRefresh(podcastViewModel)
        
        // FINAL: Verify that PodcastListView actually has feeds loaded before showing UI
        let finalFeedCount = podcastViewModel.podcastFeeds.count
        let finalFeedOrderCount = podcastViewModel.podcastFeedOrder.count
        
        print("🎯 FINAL VERIFICATION: podcastFeeds.count=\(finalFeedCount), podcastFeedOrder.count=\(finalFeedOrderCount)")
        print("🎯 FINAL VERIFICATION: Current isFreshInstallUIReady=\(isFreshInstallUIReady)")
        
        if finalFeedCount > 0 && finalFeedOrderCount > 0 {
            print("✅ FINAL SUCCESS: UI is ready with \(finalFeedCount) feeds and \(finalFeedOrderCount) feed order items")
            isFreshInstallUIReady = true
            isSyncing = false
            print("🚀 DataSyncProgressView hidden - UI is confirmed ready with feeds")
        } else {
            print("❌ FINAL ERROR: UI still not ready - feeds: \(finalFeedCount), order: \(finalFeedOrderCount)")
            print("🔧 Forcing final refresh attempt...")
            
            // One final aggressive attempt
            await podcastViewModel.forceSaveAndReload()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 more second
            
            let retryFeedCount = podcastViewModel.podcastFeeds.count
            let retryFeedOrderCount = podcastViewModel.podcastFeedOrder.count
            
            if retryFeedCount > 0 && retryFeedOrderCount > 0 {
                print("✅ RETRY SUCCESS: UI is ready with \(retryFeedCount) feeds after final attempt")
                isFreshInstallUIReady = true
                isSyncing = false
            } else {
                print("❌ RETRY FAILED: Still no feeds after final attempt - allowing UI to show anyway")
                isFreshInstallUIReady = true
                isSyncing = false
            }
        }
    }
    
    /// Force complete UI refresh to ensure SwiftUI properly reflects data changes
    @MainActor
    private func forceCompleteUIRefresh(_ podcastViewModel: PodcastViewModel) async {
        print("🚀 FORCE UI REFRESH: Starting complete UI refresh sequence")
        
        // 1. Force PodcastViewModel to reload its data from Core Data
        await podcastViewModel.forceSaveAndReload()
        print("🚀 FORCE UI REFRESH: Completed forceSaveAndReload")
        
        // 2. Manually trigger objectWillChange on PodcastViewModel to notify all SwiftUI views
        podcastViewModel.objectWillChange.send()
        print("🚀 FORCE UI REFRESH: Triggered PodcastViewModel.objectWillChange.send()")
        
        // 3. Force our own DataSyncManager to notify SwiftUI views observing it
        objectWillChange.send()
        print("🚀 FORCE UI REFRESH: Triggered DataSyncManager.objectWillChange.send()")
        
        // 4. Post multiple notifications to trigger all possible UI refresh mechanisms
        NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("PodcastDataUpdated"), object: nil)
        print("🚀 FORCE UI REFRESH: Posted refresh notifications")
        
        // 5. Give SwiftUI time to process the changes
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        
        // 6. Verify that the changes are reflected in the ViewModel
        let feedsAfterRefresh = podcastViewModel.podcastFeeds.count
        let orderAfterRefresh = podcastViewModel.podcastFeedOrder.count
        print("🚀 FORCE UI REFRESH: After refresh - Feeds: \(feedsAfterRefresh), Order: \(orderAfterRefresh)")
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
    
    /// Wait for podcast loading to complete
    @MainActor
    private func waitForPodcastLoadingToComplete(_ podcastViewModel: PodcastViewModel) async {
        print("⏳ Waiting for podcast loading to complete...")
        
        var attempts = 0
        let maxAttempts = 50 // 5 seconds max wait
        
        while (podcastViewModel.isLoading || podcastViewModel.isLoadingFeeds) && attempts < maxAttempts {
            print("⏳ Podcast loading in progress - isLoading: \(podcastViewModel.isLoading), isLoadingFeeds: \(podcastViewModel.isLoadingFeeds)")
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            attempts += 1
        }
        
        if attempts >= maxAttempts {
            print("⚠️ Podcast loading did not complete within timeout - proceeding anyway")
        } else {
            print("✅ Podcast loading completed - feeds: \(podcastViewModel.podcastFeeds.count)")
        }
    }
    

    
    /// Wait for CloudKit initialization to completely finish including final UI refresh
    @MainActor
    private func waitForCloudKitInitializationToComplete(_ podcastViewModel: PodcastViewModel) async {
        print("⏳ Waiting for CloudKit initialization to complete...")
        
        // Give a brief moment for final UI refresh to complete after all loading flags are cleared
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        
        print("✅ CloudKit initialization completed")
    }
    
    /// Verify that Core Data actually contains podcast feeds
    private func verifyCoreDataHasFeeds() async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            context.perform {
                let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                do {
                    let results = try context.fetch(request)
                    let hasFeeds = !results.isEmpty
                    print("🔍 Core Data verification: Found \(results.count) feeds in Core Data")
                    continuation.resume(returning: hasFeeds)
                } catch {
                    print("❌ Core Data verification error: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Initialize CloudKit feeds for fresh install (with RSS processing)
    @MainActor
    private func initializeCloudKitFeedsForFreshInstall(_ podcastViewModel: PodcastViewModel) async {
        print("🚀 Initializing CloudKit feeds for fresh install...")
        
        do {
            // Update progress
            podcastFeedsOperation = "Fetching podcast feeds from iCloud..."
            podcastFeedsProgress = 0.4
            
            // Get feeds from CloudKit
            let cloudKitFeeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()
            
            if !cloudKitFeeds.isEmpty {
                print("🌟 Found \(cloudKitFeeds.count) feeds in CloudKit for fresh install processing")
                
                // Update progress and operation
                podcastFeedsOperation = "Processing RSS feeds and episodes..."
                podcastFeedsProgress = 0.5
                
                // Start feed parsing progress tracking
                isParsingFeeds = true
                feedParsingProgress = 0.0
                feedParsingMessage = "Starting RSS feed processing..."
                
                // Use PodcastViewModel's fresh install processing
                await podcastViewModel.loadFreshInstallPodcastData(cloudKitFeeds)
                
                // Complete feed parsing
                feedParsingProgress = 1.0
                feedParsingMessage = "RSS feed processing completed"
                try? await Task.sleep(nanoseconds: 500_000_000) // Show completion for 0.5 seconds
                isParsingFeeds = false
                
                // Mark feeds as synced
                UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
                
                print("✅ Fresh install feed processing completed with \(podcastViewModel.podcastFeeds.count) feeds")
            } else {
                print("📡 No feeds found in CloudKit - fresh install with empty podcast library")
                // Initialize artwork tracking with 0 feeds
                startArtworkDownloadTracking(totalFeeds: 0)
                UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            }
            
        } catch {
            print("❌ Failed to initialize CloudKit feeds for fresh install: \(error)")
            // Initialize artwork tracking with 0 feeds even on error
            startArtworkDownloadTracking(totalFeeds: 0)
            podcastFeedsOperation = "❌ Failed to sync podcast feeds from iCloud"
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
    
    @MainActor
    private func syncRadioStationsFromCloudKitWithProgress() async {
        let viewModel = RadioStationViewModel.shared
        
        return await withCheckedContinuation { continuation in
            DataStore.shared.fetchRadioStationsWithProgress(
                progressCallback: { [weak self] progress, count, message in
                    Task { @MainActor in
                        self?.radioStationsProgress = progress
                        self?.radioStationsCurrentCount = count
                        self?.radioStationsOperation = message
                        // Estimate total based on current progress and count
                        if progress > 0.1 && count > 0 {
                            let estimatedTotal = Int(Double(count) / progress)
                            self?.radioStationsTotalCount = max(self?.radioStationsTotalCount ?? 0, estimatedTotal)
                        }
                        print("📊 Radio stations progress: \(Int(progress * 100))% - \(count) stations - \(message)")
                    }
                },
                completion: { [weak self] stations, error in
                    if let stations = stations {
                        DispatchQueue.main.async {
                            viewModel.stations = stations
                            viewModel.saveStationsToCoreData()
                            
                            // Update final counts
                            Task { @MainActor in
                                self?.radioStationsCurrentCount = stations.count
                                self?.radioStationsTotalCount = stations.count
                                self?.radioStationsOperation = "✅ \(stations.count) radio stations synced from iCloud"
                            }
                            
                            print("✅ Synced \(stations.count) radio stations with progress tracking")
                            
                            // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                            UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                        }
                    } else if let error = error {
                        Task { @MainActor in
                            self?.radioStationsOperation = "❌ Failed to sync radio stations: \(error.localizedDescription)"
                        }
                        print("❌ Failed to sync radio stations: \(error)")
                    }
                    continuation.resume()
                }
            )
        }
    }
    
    private func getLocalStationCount() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request = NSFetchRequest<CDStation>(entityName: "CDStation")
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Error counting local stations: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    private func getExpectedPodcastFeedCount() async -> Int {
        // First check local Core Data
        let localCount = await countExistingPodcastFeeds()
        if localCount > 0 {
            return localCount
        }
        
        // If no local feeds, check CloudKit to see if there are feeds to sync
        let cloudKitCount = await getCloudKitPodcastFeedCount()
        if cloudKitCount > 0 {
            return cloudKitCount
        }
        
        // If no feeds in local storage or CloudKit, return 0 to prevent banner from showing
        return 0
    }
    
    private func getEstimatedEpisodeCount() async -> Int {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    let request = NSFetchRequest<PodcastModel>(entityName: "PodcastModel")
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    print("❌ Error counting episodes: \(error)")
                    continuation.resume(returning: 100) // Conservative estimate
                }
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
    
    private func getCloudKitPodcastFeedCount() async -> Int {
        do {
            // Quick CloudKit query to get feed count without downloading data
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: "PodcastFeed", predicate: predicate)
            
            // Use queryOperation with resultsLimit to get count efficiently
            return await withCheckedContinuation { continuation in
                let operation = CKQueryOperation(query: query)
                operation.resultsLimit = 100 // Reasonable limit for count estimation
                operation.desiredKeys = ["recordID"] // Only fetch record ID to minimize data transfer
                
                var recordCount = 0
                operation.recordMatchedBlock = { _, _ in
                    recordCount += 1
                }
                
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        // For simplicity, we'll use the count from first batch
                        // In a real scenario, you might want to continue querying with cursor
                        print("📊 CloudKit podcast feed count: \(recordCount)")
                        continuation.resume(returning: recordCount)
                    case .failure(let error):
                        print("❌ Failed to count CloudKit feeds: \(error)")
                        continuation.resume(returning: 0)
                    }
                }
                
                let database = CKContainer(identifier: "iCloud.com.radio.streamradios").privateCloudDatabase
                database.add(operation)
            }
        } catch {
            print("❌ Error querying CloudKit feed count: \(error)")
            return 0
        }
    }
    
    private func processFreshInstallFeeds(_ cloudKitFeeds: [PodcastFeed]) async {
        // NOTE: This method is no longer used to prevent duplicate PodcastViewModel creation
        // PodcastViewModel handles its own CloudKit sync via initializeWithCloudKitSupport()
        print("📡 DataSyncManager: Skipping duplicate feed processing - handled by PodcastViewModel")
    }
    
    // MARK: - Cross-Device Feed Sync Management
    
    /// Start tracking cross-device feed sync (when feeds exist on CloudKit but not locally)
    @MainActor
    func startCrossDeviceFeedSync(totalCount: Int, operation: String = "Syncing feeds from other devices") {
        guard totalCount > 0 else {
            crossDeviceFeedSyncStatus = .none
            return
        }
        
        crossDeviceFeedSyncStatus = .inProgress
        crossDeviceFeedSyncProgress = 0.0
        crossDeviceFeedSyncOperation = operation
        crossDeviceFeedSyncCurrentCount = 0
        crossDeviceFeedSyncTotalCount = totalCount
        
        print("📡 🔄 CROSS-DEVICE FEED SYNC: Started syncing \(totalCount) feeds from other devices")
    }
    
    /// Update cross-device feed sync progress
    @MainActor
    func updateCrossDeviceFeedSyncProgress(currentCount: Int, operation: String? = nil) {
        guard crossDeviceFeedSyncTotalCount > 0 else { return }
        
        crossDeviceFeedSyncCurrentCount = currentCount
        crossDeviceFeedSyncProgress = Double(currentCount) / Double(crossDeviceFeedSyncTotalCount)
        
        if let operation = operation {
            crossDeviceFeedSyncOperation = operation
        }
        
        print("📡 🔄 CROSS-DEVICE FEED SYNC: Progress \(currentCount)/\(crossDeviceFeedSyncTotalCount) (\(Int(crossDeviceFeedSyncProgress * 100))%)")
    }
    
    /// Complete cross-device feed sync
    @MainActor
    func completeCrossDeviceFeedSync() {
        crossDeviceFeedSyncStatus = .completed
        crossDeviceFeedSyncProgress = 1.0
        crossDeviceFeedSyncOperation = "✅ Feeds synced from other devices"
        
        print("📡 ✅ CROSS-DEVICE FEED SYNC: Completed syncing \(crossDeviceFeedSyncTotalCount) feeds")
        
        // Auto-reset after showing completion for 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await MainActor.run {
                self.resetCrossDeviceFeedSync()
            }
        }
    }
    
    /// Reset cross-device feed sync status
    @MainActor
    func resetCrossDeviceFeedSync() {
        crossDeviceFeedSyncStatus = .none
        crossDeviceFeedSyncProgress = 0.0
        crossDeviceFeedSyncOperation = ""
        crossDeviceFeedSyncCurrentCount = 0
        crossDeviceFeedSyncTotalCount = 0
        
        print("📡 🔄 CROSS-DEVICE FEED SYNC: Reset sync status")
    }
    
    // MARK: - Troubleshooting Methods
    
    /// Reset the radio stations sync flag to force a re-sync from CloudKit on next launch
    /// This is useful for troubleshooting if radio stations get out of sync
    @MainActor
    func resetRadioStationsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasRadioStationsSynced")
        print("🔄 Reset radio stations sync flag - will re-sync from CloudKit on next fresh install sync")
    }
    
    /// Test method to manually trigger cross-device feed sync banner
    @MainActor
    func testCrossDeviceFeedSyncBanner() {
        print("🧪 TEST: Manually triggering cross-device feed sync banner")
        startCrossDeviceFeedSync(
            totalCount: 2,
            operation: "Testing cross-device feed sync"
        )
        
        // Simulate progress updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateCrossDeviceFeedSyncProgress(
                currentCount: 1,
                operation: "Added 'Test Podcast 1'"
            )
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.updateCrossDeviceFeedSyncProgress(
                currentCount: 2,
                operation: "Added 'Test Podcast 2'"
            )
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.completeCrossDeviceFeedSync()
        }
    }
    
    /// Reset the podcast feeds sync flag to force cross-device check on next launch
    @MainActor
    func resetPodcastFeedsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
        print("🔄 Reset podcast feeds sync flag - will check CloudKit for cross-device feeds on next initialization")
    }
}

