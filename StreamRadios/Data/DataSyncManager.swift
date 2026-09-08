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

    private var highestOverallProgress: Double = 0.0
    
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

    /// Owns the auto-dismiss of the podcast feed banner. The banner view installs its own
    /// `.onChange` observer, but it only exists while the banner is visible, so a short
    /// operation can go straight to `.completed` without any observer ever seeing a change.
    private var podcastFeedsDismissTask: Task<Void, Never>?
    
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
    
    // CORE DATA + IN-MEMORY CACHE: Episode data loaded from Core Data into FeedIsolationManager
    @Published var coreDataEpisodesLoaded = false
    @Published var feedsLoadedFromCoreData = 0
    @Published var totalFeedsInCoreData = 0
    
    // Radio Station Snapshots Readiness
    @Published var stationSnapshotsReady = false
    @Published var countriesWithSnapshots = 0
    @Published var totalCountriesRequiringSnapshots = 0
    
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
    private var expectedFreshInstallPodcastFeedCount = 0
    
    private init() {
        setupProgressCalculation()
        
        // Check if sync has ever completed successfully
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let hasSyncCompleted = UserDefaults.standard.bool(forKey: "DataSyncCompleted")
        
        // 🔧 FRESH INSTALL DETECTION:
        // Only check Core Data to detect app reinstall (UserDefaults persist in App Group)
        // If HasLaunchedBefore=true but Core Data is completely empty, app was reinstalled
        let coreDataIsEmpty = checkIfCoreDataIsEmpty()
        let isAppReinstall = hasLaunchedBefore && coreDataIsEmpty
        
        if isAppReinstall {
            // App was reinstalled - Core Data is empty but UserDefaults say we launched before
            // This is a TRUE fresh install, reset all flags
            print("🔄 App reinstall detected - resetting sync flags")
            UserDefaults.standard.set(false, forKey: "HasLaunchedBefore")
            UserDefaults.standard.set(false, forKey: "DataSyncCompleted")
            UserDefaults.standard.set(false, forKey: "HasRadioStationsSynced")
            UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
            UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
        }
        
        // Re-check after potential reset
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let syncCompleted = UserDefaults.standard.bool(forKey: "DataSyncCompleted")
        
        // Show sync screen ONLY on first-ever launch (never launched before AND sync never completed)
        // Once HasLaunchedBefore is true, NEVER show the sync screen again
        if !isFreshInstall {
            isFreshInstallUIReady = true
        } else {
            isFreshInstallUIReady = false
        }
    }
    
    // MARK: - Private Helper Methods
    
    /// Check if Core Data is empty to detect TRUE fresh install
    /// App Group UserDefaults persist across app deletions, so we check Core Data instead
    /// We check BOTH podcast feeds AND radio stations - if either has data, it's not a fresh install
    private func checkIfCoreDataIsEmpty() -> Bool {
        let context = CoreDataStack.shared.context
        var isEmpty = false
        
        context.performAndWait {
            do {
                // Check for podcast feeds
                let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                feedRequest.fetchLimit = 1
                let feedCount = try context.count(for: feedRequest)
                
                // Check for radio stations
                let stationRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                stationRequest.fetchLimit = 1
                let stationCount = try context.count(for: stationRequest)
                
                // Core Data is empty only if BOTH feeds AND stations are empty
                isEmpty = (feedCount == 0 && stationCount == 0)
                
                if !isEmpty {
                    print("📊 Core Data check: \(feedCount > 0 ? "has feeds" : "no feeds"), \(stationCount > 0 ? "has stations" : "no stations") - NOT a fresh install")
                }
            } catch {
                print("❌ Error checking Core Data for fresh install: \(error)")
                isEmpty = false // Assume not empty on error to be safe
            }
        }
        
        return isEmpty
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
            
            // Start sync operations in proper sequence
            // SEQUENCED CLOUDKIT OPERATIONS to prevent rate limiting:
            print("🔄 Starting sequential CloudKit sync to prevent rate limiting...")
            
            // First: Sync Radio Stations (fastest, no dependencies)
            await syncRadioStations()
            
            // Second: Sync Podcast Feeds (after radio stations complete to prevent CloudKit rate limiting)
            await syncPodcastFeeds()
            
            // Parallel operations that don't use CloudKit heavily
            await withTaskGroup(of: Void.self) { group in
                // User Preferences Sync (lightweight, can run in parallel)
                group.addTask {
                    await self.syncUserPreferences()
                }
                
                // Wait for all parallel operations to complete
                for await _ in group {
                    // Tasks completed
                }
            }
            
            // Then: Sync Episode States (depends on feeds being loaded)
            // Check if episode states were already synced during RSS processing
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            
            if isFreshInstall && hasPodcastFeedsSynced && hasEpisodeStatesSynced {
                print("⚡ FRESH INSTALL: Episode states already synced during RSS processing - marking as completed")
                // CRITICAL FIX: Update episode states status to completed since it was already synced
                await MainActor.run {
                    episodeStatesStatus = .completed
                    episodeStatesProgress = 1.0
                    episodeStatesOperation = "✅ Episode states already synced during fresh install"
                }
            } else {
                await syncEpisodeStates()
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
        // Note: synchronize() is deprecated and unnecessary
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
                radioStationsOperation = "Fetching radio stations from iCloud..."
                await syncRadioStationsFromCloudKitWithProgress()
                // Mark radio stations as synced
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            } else {
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
    
    /// Shows the podcast feed banner for a new operation and cancels any pending dismissal.
    @MainActor
    func beginPodcastFeedsSync(totalCount: Int, operation: String) {
        podcastFeedsDismissTask?.cancel()
        podcastFeedsDismissTask = nil

        podcastFeedsStatus = .inProgress
        podcastFeedsOperation = operation
        podcastFeedsProgress = 0.0
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = totalCount
    }

    /// Marks the podcast feed banner complete and clears it after a brief display.
    /// The reset happens here rather than in the banner view so it runs even when no
    /// view was alive to observe the `.completed` transition.
    @MainActor
    func completePodcastFeedsSync(operation: String, displayDuration: TimeInterval = 2.0) {
        podcastFeedsStatus = .completed
        podcastFeedsOperation = operation
        podcastFeedsProgress = 1.0

        podcastFeedsDismissTask?.cancel()
        podcastFeedsDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.podcastFeedsStatus == .completed else { return }

            self.podcastFeedsStatus = .none
            self.podcastFeedsProgress = 0.0
            self.podcastFeedsOperation = ""
            self.podcastFeedsCurrentCount = 0
            self.podcastFeedsTotalCount = 0
        }
    }

    @MainActor
    private func syncPodcastFeeds() async {
        // Check how many feeds we expect to sync FIRST
        let expectedFeedCount = await getExpectedPodcastFeedCount()
        expectedFreshInstallPodcastFeedCount = expectedFeedCount
        
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
            podcastFeedsProgress = 0.95
            podcastFeedsStatus = .inProgress
            podcastFeedsOperation = "Verifying \(finalCount) podcast feeds and episodes..."
            print("✅ Podcast feed parsing finished - \(finalCount) feeds awaiting readiness verification")
            
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
            // Get the PodcastViewModel instance
            let podcastViewModel = PodcastViewModel.shared
            
            // Wait for podcast feeds to be loaded first
            await waitForPodcastFeedsToLoad(podcastViewModel)
            
                    // PERFORMANCE: Skip entire episode sync if caches are available
        // Caches already contain complete episode data with states
        let hasCaches = await MainActor.run {
            for feed in podcastViewModel.podcastFeeds {
                if podcastViewModel.feedIsolationManager.getEpisodesForFeed(feed.id) != nil {
                    print("⚡ PERFORMANCE: Found episode cache for feed \(feed.title)")
                    return true
                }
            }
            return false
        }
        
        if hasCaches {
            print("⚡ PERFORMANCE: Skipping entire episode state sync - using episode cache with complete state data")
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "Using episode cache (no sync needed)"
            return
        }
        
        // Get actual episode count from loaded feeds
        episodeStatesTotalCount = await getActualEpisodeCount(podcastViewModel)
        
        if episodeStatesTotalCount == 0 {
            print("📊 No episodes found - skipping episode state sync")
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "No episodes to sync"
            return
        }
        
        print("📊 Starting episode state sync for \(episodeStatesTotalCount) episodes across \(podcastViewModel.podcastFeeds.count) feeds")
        
        // Phase 1: CloudKit Episode State Sync (0-60%)
        episodeStatesOperation = "Syncing episode states from iCloud..."
        episodeStatesProgress = 0.1
            
            // Check if episode states were already synced during fresh install
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            let hasEpisodeStatesSynced = UserDefaults.standard.bool(forKey: "HasEpisodeStatesSynced")
            
            let syncSuccess: Bool
            if isFreshInstall && hasPodcastFeedsSynced && hasEpisodeStatesSynced {
                // Episode states were already synced during fresh install RSS processing
                print("⚡ PERFORMANCE: Skipping CloudKit episode sync - already completed during fresh install")
                syncSuccess = true
                episodeStatesProgress = 0.6
                episodeStatesOperation = "Episode states already synced during fresh install..."
            } else {
                // Perform actual CloudKit episode state sync
                syncSuccess = await podcastViewModel.syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
                
                if syncSuccess {
                    episodeStatesProgress = 0.6
                    episodeStatesOperation = "Episode states synced from iCloud..."
                    print("✅ CloudKit episode state sync completed")
                } else {
                    print("⚠️ CloudKit episode state sync failed, continuing with local data")
                    episodeStatesProgress = 0.3
                }
            }
            
            // Phase 2: Load Episode Data from Core Data into Memory (60-90%)
            episodeStatesOperation = "Loading episodes from Core Data into memory..."
            await loadEpisodesFromCoreDataToMemory(podcastViewModel)
            episodeStatesProgress = 0.9
            
            // Update current count to reflect feeds loaded
            episodeStatesCurrentCount = Int(Double(episodeStatesTotalCount) * 0.9)
            
            // Phase 3: Final Verification (90-100%)
            episodeStatesOperation = "Verifying Core Data episode availability..."
            await verifyEpisodeCachesAreReady(podcastViewModel)
            
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesCurrentCount = episodeStatesTotalCount
            episodeStatesOperation = "✅ \(feedsLoadedFromCoreData) feeds loaded from Core Data into memory"
            print("✅ Episode states sync completed with Core Data loaded into memory")
            
        } catch {
            episodeStatesStatus = .failed
            episodeStatesOperation = "❌ Failed to sync episode states: \(error.localizedDescription)"
            print("❌ Episode states sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncUserPreferences() async {
        userPreferencesStatus = .inProgress
        userPreferencesProgress = 0.3
        userPreferencesOperation = "Restoring your settings..."

        if let restored = RadioStationViewModel.shared.restoreSelectedCountryAfterSync() {
            userPreferencesOperation = "✅ Restored \(restored)"
        } else {
            userPreferencesOperation = "✅ Preferences loaded"
        }

        userPreferencesProgress = 1.0
        userPreferencesStatus = .completed
        print("✅ User preferences sync completed")
    }
    
    // MARK: - Helper Methods
    
    private func resetProgress() {
        highestOverallProgress = 0.0
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
        
        // Core Data + In-Memory Cache
        coreDataEpisodesLoaded = false
        feedsLoadedFromCoreData = 0
        totalFeedsInCoreData = 0
        expectedFreshInstallPodcastFeedCount = 0
        
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
    
    /// Update podcast feed counts during RSS parsing
    @MainActor
    func updatePodcastFeedCounts(current: Int, total: Int) {
        podcastFeedsCurrentCount = current
        podcastFeedsTotalCount = max(podcastFeedsTotalCount, total)
        
        // Update progress to reflect RSS parsing (30% to 70% of total sync)
        let rssProgress = Double(current) / Double(total)
        podcastFeedsProgress = 0.3 + (rssProgress * 0.4) // Maps 0-100% RSS to 30-70% overall
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
        
        // Also reset Core Data tracking
        coreDataEpisodesLoaded = false
        feedsLoadedFromCoreData = 0
        totalFeedsInCoreData = 0
        
        print("🔄 DataSyncManager: Reset episode state sync tracking and Core Data status")
    }
    
    /// Update Core Data episode loading tracking
    @MainActor
    func updateCoreDataEpisodeLoadStatus(feedsLoaded: Int, totalFeeds: Int) {
        self.feedsLoadedFromCoreData = feedsLoaded
        self.totalFeedsInCoreData = totalFeeds
        self.coreDataEpisodesLoaded = (feedsLoaded == totalFeeds && totalFeeds > 0)
    }
    
    /// Update radio station snapshot readiness tracking
    @MainActor
    func updateStationSnapshotReadiness(countriesWithSnapshots: Int, totalCountriesRequiringSnapshots: Int) {
        self.countriesWithSnapshots = countriesWithSnapshots
        self.totalCountriesRequiringSnapshots = totalCountriesRequiringSnapshots
        self.stationSnapshotsReady = (countriesWithSnapshots == totalCountriesRequiringSnapshots && totalCountriesRequiringSnapshots > 0)
    }
    
    // MARK: - Individual Feed Addition Tracking
    
    /// Start tracking individual feed addition (UI-initiated)
    @MainActor
    func startIndividualFeedAddition() {
        isAddingIndividualFeed = true
    }
    
    /// Complete individual feed addition tracking
    @MainActor
    func completeIndividualFeedAddition() {
        isAddingIndividualFeed = false
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
        .map { [weak self] first, preference in
            let (radio, podcast, artwork, episode) = first
            let raw = min(1.0, (radio + podcast + artwork + episode + preference) / 5.0)
            guard let self else { return raw }
            // Stages restart at 0 when they re-enter (artwork tracking, feed re-phasing), which
            // would visibly rewind the bar by up to 20%. Only ever move forward.
            self.highestOverallProgress = max(self.highestOverallProgress, raw)
            return self.highestOverallProgress
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
        guard totalArtworkDownloads > 0, artworkDownloadsStatus == .inProgress else { return }

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
        guard totalArtworkDownloads > 0, artworkDownloadsStatus == .inProgress else { return }

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
        
        // CRITICAL: Final verification that episode cache are available
        await verifyEpisodeCachesAreReady(podcastViewModel)
        
        currentOperation = "Verifying synchronized data..."
        
        // CRITICAL: Force Core Data save and reload before any verification
        print("🚀 CRITICAL: Forcing Core Data save and reload before UI refresh")
        await podcastViewModel.forceSaveAndReload()
        
        // CRITICAL: Load episodes from Core Data into FeedIsolationManager (in-memory cache)
        await loadEpisodesFromCoreDataToMemory(podcastViewModel)

        guard await waitForFreshInstallPodcastData(podcastViewModel) else {
            podcastFeedsStatus = .failed
            podcastFeedsOperation = "Failed to load every podcast feed and its episodes"
            currentOperation = "Podcast synchronization incomplete. Keep the app open to retry."
            print("❌ FRESH INSTALL READINESS: Expected \(expectedFreshInstallPodcastFeedCount) feeds, but the complete feed and episode set is not available")
            return
        }

        podcastFeedsStatus = .completed
        podcastFeedsProgress = 1.0
        podcastFeedsCurrentCount = expectedFreshInstallPodcastFeedCount
        podcastFeedsOperation = "✅ \(expectedFreshInstallPodcastFeedCount) podcast feeds and episodes loaded"

        // Final verification that all sync statuses are completed
        await waitForAllSyncStatusesToComplete()
        currentOperation = "Synchronization completed!"
        
        // CRITICAL: Ensure radio station caches are created for all countries before completion
        await ensureStationSnapshotsAreCreated(RadioStationViewModel.shared)

        // Re-run in case the CloudKit merge landed after the preferences step; it no-ops once set.
        await MainActor.run { RadioStationViewModel.shared.restoreSelectedCountryAfterSync() }
        
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
            
            let expectedFeedCount = expectedFreshInstallPodcastFeedCount
            if feedCount >= expectedFeedCount && feedOrderCount >= expectedFeedCount {
                print("✅ UI Update verified: \(feedCount) feeds and \(feedOrderCount) feed order items are now available")
                
                // Additional verification: make sure Core Data also has the feeds
                let coreDataHasFeeds = await verifyCoreDataHasFeeds(expectedCount: expectedFeedCount)
                if coreDataHasFeeds {
                    print("✅ Core Data verification passed - feeds are properly persisted")
                    break
                } else {
                    print("⚠️ Core Data verification failed - feeds not found in Core Data, continuing wait...")
                }
            } else {
                // Only log every 5th attempt to reduce log noise
                if uiUpdateAttempts % 5 == 0 {
                    print("⏳ Waiting for UI to show feeds... attempt \(uiUpdateAttempts + 1) - Feeds: \(feedCount), Order: \(feedOrderCount)")
                }
                
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
        
        // Additional pause to ensure UI is fully updated before hiding progress view
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for visual feedback
        
        // CRITICAL: Force complete UI refresh to ensure SwiftUI properly reflects the data changes
        await forceCompleteUIRefresh(podcastViewModel)
        
        // FINAL: Verify that PodcastListView actually has feeds loaded before showing UI
        let finalFeedCount = podcastViewModel.podcastFeeds.count
        let finalFeedOrderCount = podcastViewModel.podcastFeedOrder.count
        
        print("🎯 FINAL VERIFICATION: podcastFeeds.count=\(finalFeedCount), podcastFeedOrder.count=\(finalFeedOrderCount)")
        print("🎯 FINAL VERIFICATION: Current isFreshInstallUIReady=\(isFreshInstallUIReady)")
        
        let expectedFeedCount = expectedFreshInstallPodcastFeedCount
        var finalDataReady = false
        if finalFeedCount >= expectedFeedCount && finalFeedOrderCount >= expectedFeedCount {
            // CRITICAL: Check that Core Data episodes are loaded into memory and station snapshots are ready
            let dataReady = (coreDataEpisodesLoaded || totalFeedsInCoreData == 0) && 
                            (stationSnapshotsReady || totalCountriesRequiringSnapshots == 0)
            
            if dataReady {
                print("✅ FINAL SUCCESS: UI is ready with \(finalFeedCount) feeds, \(finalFeedOrderCount) feed order items, \(feedsLoadedFromCoreData) episodes loaded from Core Data, and \(countriesWithSnapshots) station snapshots")
                finalDataReady = true
            } else {
                print("⏳ WAITING FOR DATA: Feeds ready but Core Data not fully loaded - Episodes: (\(feedsLoadedFromCoreData)/\(totalFeedsInCoreData)), Stations: (\(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots))")
                // Wait a bit more for data loading to complete
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                let dataReadyAfterWait = (coreDataEpisodesLoaded || totalFeedsInCoreData == 0) && 
                                         (stationSnapshotsReady || totalCountriesRequiringSnapshots == 0)
                
                if dataReadyAfterWait {
                    print("✅ DATA READY: Core Data fully loaded into memory after wait")
                    finalDataReady = true
                } else {
                    print("⏳ STILL WAITING: Data not ready after wait - will retry")
                }
            }
        } else {
            print("❌ FINAL ERROR: UI still not ready - feeds: \(finalFeedCount), order: \(finalFeedOrderCount)")
            print("🔧 Forcing final refresh attempt...")
            
            // One final aggressive attempt
            await podcastViewModel.forceSaveAndReload()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 more second
            
            let retryFeedCount = podcastViewModel.podcastFeeds.count
            let retryFeedOrderCount = podcastViewModel.podcastFeedOrder.count
            
            if retryFeedCount >= expectedFeedCount && retryFeedOrderCount >= expectedFeedCount {
                print("✅ RETRY SUCCESS: UI is ready with \(retryFeedCount) feeds after final attempt")
                finalDataReady = (coreDataEpisodesLoaded || totalFeedsInCoreData == 0) &&
                                 (stationSnapshotsReady || totalCountriesRequiringSnapshots == 0)
            } else {
                print("❌ RETRY FAILED: Expected \(expectedFeedCount) feeds, found \(retryFeedCount) feeds and \(retryFeedOrderCount) order entries")
                podcastFeedsStatus = .failed
                podcastFeedsOperation = "Podcast data is incomplete"
                currentOperation = "Podcast synchronization incomplete. Keep the app open to retry."
            }
        }

        guard finalDataReady else { return }

        podcastFeedsDismissTask?.cancel()
        podcastFeedsDismissTask = nil
        podcastFeedsStatus = .none
        podcastFeedsProgress = 0.0
        podcastFeedsOperation = ""
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = 0
        feedParsingProgress = 0.0
        feedParsingMessage = ""
        isParsingFeeds = false

        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
        UserDefaults.standard.synchronize()
        isFreshInstallUIReady = true
        isSyncing = false
        print("✅ SYNC COMPLETE: Marked HasLaunchedBefore=true after successful sync")
        print("🚀 DataSyncProgressView hidden - all synchronized data is ready")
        print("🎉 Fresh install data synchronization completed successfully!")
        print("📊 Final state: Podcast feeds: \(podcastViewModel.podcastFeeds.count), Radio stations: \(radioStationViewModel.stations.count)")
    }

    @MainActor
    private func waitForFreshInstallPodcastData(_ podcastViewModel: PodcastViewModel) async -> Bool {
        let expectedFeedCount = expectedFreshInstallPodcastFeedCount
        guard expectedFeedCount > 0 else { return true }

        for attempt in 1...10 {
            let feeds = podcastViewModel.podcastFeeds
            let orderedFeedCount = Set(podcastViewModel.podcastFeedOrder).count
            let feedsWithEpisodes = feeds.filter { !$0.episodes.isEmpty }
            let feedsWithCaches = feedsWithEpisodes.filter {
                !podcastViewModel.feedIsolationManager.getEpisodesForFeed($0.id).isEmpty
            }
            let coreDataReady = await verifyCoreDataHasFeeds(expectedCount: expectedFeedCount)

            if feeds.count >= expectedFeedCount,
               orderedFeedCount >= expectedFeedCount,
               feedsWithEpisodes.count >= expectedFeedCount,
               feedsWithCaches.count >= expectedFeedCount,
               coreDataReady {
                print("✅ FRESH INSTALL READINESS: \(expectedFeedCount)/\(expectedFeedCount) feeds, episode sets, and caches are available")
                return true
            }

            print("⏳ FRESH INSTALL READINESS \(attempt)/10: feeds \(feeds.count)/\(expectedFeedCount), order \(orderedFeedCount)/\(expectedFeedCount), parsed \(feedsWithEpisodes.count)/\(expectedFeedCount), cached \(feedsWithCaches.count)/\(expectedFeedCount)")

            guard attempt < 10 else { break }
            await podcastViewModel.forceSaveAndReload()
            await loadEpisodesFromCoreDataToMemory(podcastViewModel)
        }

        return false
    }
    
    /// CORE DATA + IN-MEMORY CACHE: Load episodes from Core Data into FeedIsolationManager
    /// This provides instant access to persistent episode data without snapshots
    @MainActor
    private func loadEpisodesFromCoreDataToMemory(_ podcastViewModel: PodcastViewModel) async {
        print("💾 CORE DATA LOAD: Loading episodes from Core Data into in-memory cache...")
        
        let feedsWithEpisodes = podcastViewModel.podcastFeeds.filter { !$0.episodes.isEmpty }
        var feedsLoaded = 0
        var totalEpisodes = 0
        
        // Update tracking
        totalFeedsInCoreData = max(feedsWithEpisodes.count, expectedFreshInstallPodcastFeedCount)
        feedsLoadedFromCoreData = 0
        
        for feed in podcastViewModel.podcastFeeds {
            if !feed.episodes.isEmpty {
                // 🛡️ CONTAMINATION PREVENTION: Validate episodes belong to this feed
                let validEpisodes = feed.episodes.filter { $0.feedId == feed.id }
                if validEpisodes.count != feed.episodes.count {
                    print("🚨 CORE DATA CONTAMINATION: Feed '\(feed.title)' has \(feed.episodes.count - validEpisodes.count) contaminated episodes")
                }
                
                // Apply current states from EpisodeStateManager (already persisted)
                let episodesWithStates = validEpisodes.map { episode in
                    var updatedEpisode = episode
                    
                    // Get current states from EpisodeStateManager
                    let progress = EpisodeStateManager.shared.getProgress(for: episode.id, feedId: episode.feedId)
                    let isFavorite = EpisodeStateManager.shared.isFavorite(episode.id, feedId: episode.feedId)
                    let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id, feedId: episode.feedId)
                    let playbackState = EpisodeStateManager.shared.getState(for: episode.id)
                    
                    // Update episode state with current values
                    updatedEpisode.state.progress = progress
                    updatedEpisode.state.isFavorite = isFavorite
                    updatedEpisode.state.isDownloaded = isDownloaded
                    updatedEpisode.state.isPlayed = (playbackState == .played)
                    
                    return updatedEpisode
                }
                
                // Load into FeedIsolationManager (in-memory cache)
                podcastViewModel.feedIsolationManager.replaceEpisodesForFeed(episodesWithStates, feedId: feed.id)
                feedsLoadedFromCoreData += 1
                feedsLoaded += 1
                totalEpisodes += validEpisodes.count
                print("💾 Loaded '\(feed.title)' episodes from Core Data into memory (\(validEpisodes.count) episodes)")
            }
        }
        
        // Mark as loaded
        coreDataEpisodesLoaded = (feedsLoadedFromCoreData >= totalFeedsInCoreData)
        
        print("💾 CORE DATA LOAD COMPLETE: \(feedsLoaded) feeds loaded with \(totalEpisodes) total episodes")
        print("💾 CORE DATA STATUS: \(feedsLoadedFromCoreData)/\(totalFeedsInCoreData) feeds loaded into memory - Ready: \(coreDataEpisodesLoaded)")
        
        // Update episode states progress
        if episodeStatesStatus != .completed {
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "✅ \(feedsLoadedFromCoreData) feeds loaded from Core Data into memory"
        }
    }
    
    /// Ensure radio station caches are created for all countries before completing sync
    @MainActor
    private func ensureStationSnapshotsAreCreated(_ radioStationViewModel: RadioStationViewModel) async {
        print("📸 FINAL STATION SNAPSHOT CHECK: Ensuring all countries have station snapshots...")
        
        let countriesWithStations = Dictionary(grouping: radioStationViewModel.stations) { $0.country }
            .filter { !$0.key.isEmpty && $0.key != "Unknown Region" && $0.key != "Select Country" }
        
        var snapshotsCreated = 0
        var totalStations = 0
        
        // Update cache tracking
        totalCountriesRequiringSnapshots = countriesWithStations.count
        countriesWithSnapshots = 0
        
        for (country, stations) in countriesWithStations {
            // Check if snapshot already exists
            if radioStationViewModel.getStationSnapshot(for: country) != nil {
                countriesWithSnapshots += 1
                snapshotsCreated += 1
                print("📸 Station snapshot already exists for '\(country)'")
            } else {
                // Create cache for countries with stations
                radioStationViewModel.updateStationSnapshot(for: country, stations: stations)
                countriesWithSnapshots += 1
                snapshotsCreated += 1
                totalStations += stations.count
                print("📸 Created final station snapshot for '\(country)' with \(stations.count) stations")
            }
        }
        
        // Mark caches as ready
        stationSnapshotsReady = (countriesWithSnapshots == totalCountriesRequiringSnapshots)
        
        print("📸 FINAL STATION CACHE SUMMARY: \(snapshotsCreated) caches available with \(totalStations) total stations")
        print("📸 FINAL STATION CACHE READINESS: \(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots) countries have caches - Ready: \(stationSnapshotsReady)")
        
        // Update radio stations progress to reflect cache creation
        if radioStationsStatus != .completed {
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            radioStationsOperation = "✅ \(countriesWithSnapshots) station snapshots ready for instant access"
        }
    }
    
    /// Force complete UI refresh to ensure SwiftUI properly reflects data changes
    @MainActor
    private func forceCompleteUIRefresh(_ podcastViewModel: PodcastViewModel) async {
        // 1. Force PodcastViewModel to reload its data from Core Data
        await podcastViewModel.forceSaveAndReload()
        
        // 2. Manually trigger objectWillChange on PodcastViewModel to notify all SwiftUI views
        podcastViewModel.objectWillChange.send()
        
        // 3. Force our own DataSyncManager to notify SwiftUI views observing it
        objectWillChange.send()
        
        // 4. Post multiple notifications to trigger all possible UI refresh mechanisms
        NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("PodcastDataUpdated"), object: nil)
        
        // 5. Give SwiftUI time to process the changes
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
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
    private func verifyCoreDataHasFeeds(expectedCount: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            context.perform {
                let request: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                do {
                    let feedCount = try context.count(for: request)
                    let hasFeeds = feedCount >= expectedCount
                    print("🔍 Core Data verification: Found \(feedCount)/\(expectedCount) expected feeds in Core Data")
                    continuation.resume(returning: hasFeeds)
                } catch {
                    print("❌ Core Data verification error: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Sync from CloudKit with retry logic for rate limiting
    private func syncFromCloudKitWithRetry() async throws -> [PodcastFeed] {
        let maxRetries = 3
        var retryCount = 0
        
        while retryCount < maxRetries {
            do {
                print("☁️ FRESH INSTALL: Attempting CloudKit sync (attempt \(retryCount + 1)/\(maxRetries))")
                return try await PodcastCloudKitManager.shared.syncFromCloudKit()
            } catch {
                retryCount += 1
                
                // Check if it's a rate limiting error
                if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    let retryAfter = ckError.retryAfterSeconds ?? 30.0
                    print("⏱️ FRESH INSTALL: Rate limited, waiting \(retryAfter) seconds before retry \(retryCount)/\(maxRetries)")
                    
                    if retryCount < maxRetries {
                        // Update progress to show we're waiting
                        await MainActor.run {
                            podcastFeedsOperation = "Rate limited, waiting \(Int(retryAfter))s before retry..."
                        }
                        
                        // Wait for the specified time
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        
                        // Update progress for next attempt
                        await MainActor.run {
                            podcastFeedsOperation = "Retrying podcast feeds from iCloud..."
                        }
                    } else {
                        print("❌ FRESH INSTALL: Max retries exceeded for CloudKit rate limiting")
                        throw error
                    }
                } else {
                    print("❌ FRESH INSTALL: Non-rate-limiting error: \(error)")
                    throw error
                }
            }
        }
        
        throw CKError(.requestRateLimited)
    }
    
    /// Initialize CloudKit feeds for fresh install (with RSS processing)
    @MainActor
    private func initializeCloudKitFeedsForFreshInstall(_ podcastViewModel: PodcastViewModel) async {
        print("🚀 Initializing CloudKit feeds for fresh install...")
        
        do {
            // Update progress
            podcastFeedsOperation = "Fetching podcast feeds from iCloud..."
            podcastFeedsProgress = 0.4
            
            // Get feeds from CloudKit with retry logic for rate limiting
            let cloudKitFeeds = try await syncFromCloudKitWithRetry()
            
            if !cloudKitFeeds.isEmpty {
                expectedFreshInstallPodcastFeedCount = Set(cloudKitFeeds.map(\.url)).count
                podcastFeedsTotalCount = expectedFreshInstallPodcastFeedCount
                print("🌟 Found \(cloudKitFeeds.count) feeds in CloudKit for fresh install processing")
                
                // STEP 1: Clear any existing episode cache to start fresh
                podcastFeedsOperation = "Clearing existing episode cache..."
                podcastFeedsProgress = 0.3
                print("🗑️ FRESH INSTALL: Clearing any existing episode cache...")
                await podcastViewModel.clearAllEpisodeCaches()
                
                // STEP 2: Process RSS feeds to get complete episode lists
                podcastFeedsOperation = "Parsing \(cloudKitFeeds.count) RSS feeds..."
                podcastFeedsProgress = 0.3
                
                // Start feed parsing progress tracking
                isParsingFeeds = true
                feedParsingProgress = 0.0
                feedParsingMessage = "Processing RSS feeds..."
                print("🔄 📻 Parsing ALL RSS feeds and saving episodes...")
                
                // Load and parse all feeds with progress monitoring
                await podcastViewModel.loadFreshInstallPodcastData(cloudKitFeeds)
                
                // Update progress after RSS parsing
                podcastFeedsProgress = 0.75
                podcastFeedsCurrentCount = podcastViewModel.podcastFeeds.count
                podcastFeedsTotalCount = max(podcastFeedsTotalCount, podcastFeedsCurrentCount)
                podcastFeedsOperation = "Parsed \(podcastFeedsCurrentCount) feeds, finalizing..."
                
                // Apply metadata from CloudKit
                print("🔄 📻 Applying CloudKit metadata to feeds...")
                podcastFeedsOperation = "Applying metadata to \(podcastFeedsCurrentCount) feeds..."
                podcastFeedsProgress = 0.85
                await podcastViewModel.applyCloudKitFeedMetadata(cloudKitFeeds)
                
                // Update progress after metadata
                podcastFeedsProgress = 0.95
                podcastFeedsOperation = "Completing feed sync..."
                
                // STEP 3: Fetch ALL episode states from CloudKit for complete caches
                podcastFeedsOperation = "Fetching ALL episode states from iCloud..."
                podcastFeedsProgress = 0.9
                episodeStatesStatus = .inProgress
                episodeStatesOperation = "Fetching ALL episode states from CloudKit..."
                episodeStatesProgress = 0.1
                
                print("☁️ ========================================")
                print("☁️ FRESH INSTALL: Starting CRITICAL episode state sync from CloudKit")
                print("☁️ This will restore your favorites, play positions, and episode states")
                print("☁️ ========================================")
                
                print("☁️ FRESH INSTALL: Calling syncEpisodeStatesFromCloudKit with isFreshInstall=true")
                let episodeStatesSyncSuccess = await podcastViewModel.syncEpisodeStatesFromCloudKit(isFreshInstall: true)
                print("☁️ FRESH INSTALL: Episode state sync completed with success=\(episodeStatesSyncSuccess)")
                
                if episodeStatesSyncSuccess {
                    podcastFeedsOperation = "All episode states synchronized"
                    podcastFeedsProgress = 0.8
                    episodeStatesOperation = "All episode states synchronized"
                    episodeStatesProgress = 0.8
                    
                    // Mark episode states as synced to prevent duplicate sync
                    UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                    print("✅ FRESH INSTALL: All episode states fetched successfully and marked as synced")
                } else {
                    podcastFeedsOperation = "Episode states sync completed with warnings"
                    podcastFeedsProgress = 0.8
                    episodeStatesOperation = "Episode states sync completed with warnings"
                    episodeStatesProgress = 0.8
                    print("⚠️ FRESH INSTALL: Episode states sync had issues, continuing...")
                }
                
                // STEP 4: Apply CloudKit feed metadata updates before creating caches
                podcastFeedsOperation = "Applying CloudKit feed metadata updates..."
                podcastFeedsProgress = 0.85
                episodeStatesOperation = "Applying CloudKit feed metadata updates..."
                episodeStatesProgress = 0.85
                feedParsingMessage = "Applying latest feed metadata from CloudKit..."
                print("🔄 FRESH INSTALL: Applying CloudKit feed metadata updates...")
                
                // Apply CloudKit metadata to existing feeds
                await podcastViewModel.applyCloudKitFeedMetadata(cloudKitFeeds)
                
                // STEP 5: Load episodes from Core Data into memory with states
                podcastFeedsOperation = "Loading episodes from Core Data into memory..."
                podcastFeedsProgress = 0.9
                episodeStatesOperation = "Loading episodes from Core Data into memory..."
                episodeStatesProgress = 0.9
                feedParsingMessage = "Loading episode data from Core Data..."
                print("💾 FRESH INSTALL: Loading episodes from Core Data into in-memory cache...")
                
                // Load episodes from Core Data into FeedIsolationManager (in-memory cache)
                await loadEpisodesFromCoreDataToMemory(podcastViewModel)
                
                // Complete episode states sync
                episodeStatesStatus = .completed
                episodeStatesOperation = "✅ \(feedsLoadedFromCoreData) feeds loaded from Core Data into memory"
                episodeStatesProgress = 1.0
                
                // Complete feed parsing
                podcastFeedsOperation = "Fresh install completed successfully"
                podcastFeedsProgress = 0.95
                feedParsingProgress = 1.0
                feedParsingMessage = "Fresh install processing completed successfully"
                // PERFORMANCE OPTIMIZATION: Removed 0.5s delay for instant UI readiness
                isParsingFeeds = false
                
                // Mark feeds as synced
                UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
                
                print("✅ Fresh install feed processing completed with \(podcastViewModel.podcastFeeds.count) feeds")
            } else {
                print("📡 No feeds found in CloudKit - fresh install with empty podcast library")
                
                // Mark episode states as completed (no episodes to sync)
                episodeStatesStatus = .completed
                episodeStatesProgress = 1.0
                episodeStatesOperation = "✅ No episodes to sync (empty library)"
                UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                
                // Initialize artwork tracking with 0 feeds
                startArtworkDownloadTracking(totalFeeds: 0)
                UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            }
            
        } catch {
            print("❌ Failed to initialize CloudKit feeds for fresh install: \(error)")
            
            episodeStatesStatus = .failed
            episodeStatesProgress = 0.0
            episodeStatesOperation = "Episode sync failed before CloudKit states were fetched"
            UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
            
            // Initialize artwork tracking with 0 feeds even on error
            startArtworkDownloadTracking(totalFeeds: 0)
            podcastFeedsOperation = "❌ Failed to sync podcast feeds from iCloud"
        }
    }
    
    /// Verify that episode cache are ready for immediate use
    @MainActor
    private func verifyEpisodeCachesAreReady(_ podcastViewModel: PodcastViewModel) async {
        print("🔍 FINAL VERIFICATION: Checking episode cache availability...")
        
        var feedsWithCaches = 0
        var feedsWithEpisodes = 0
        var totalCacheEpisodes = 0
        
        for feed in podcastViewModel.podcastFeeds {
            if !feed.episodes.isEmpty {
                feedsWithEpisodes += 1
                
                let cachedEpisodes = podcastViewModel.feedIsolationManager.getEpisodesForFeed(feed.id)
                if !cachedEpisodes.isEmpty {
                    feedsWithCaches += 1
                    totalCacheEpisodes += cachedEpisodes.count
                    print("✅ Cache verified for '\(feed.title)': \(cachedEpisodes.count) episodes")
                } else {
                    print("⚠️ Missing cache for '\(feed.title)' with \(feed.episodes.count) episodes")
                    
                    // 🛡️ CONTAMINATION PREVENTION: Validate episodes before creating missing cache
                    let validEpisodes = feed.episodes.filter { $0.feedId == feed.id }
                    if validEpisodes.count != feed.episodes.count {
                        print("🚨 MISSING CACHE CONTAMINATION: Feed '\(feed.title)' has \(feed.episodes.count - validEpisodes.count) contaminated episodes")
                    }
                    
                    // Create missing cache with validated episodes
                    podcastViewModel.feedIsolationManager.replaceEpisodesForFeed(validEpisodes, feedId: feed.id)
                    feedsWithCaches += 1
                    totalCacheEpisodes += validEpisodes.count
                    print("🔧 Created missing cache for '\(feed.title)' with \(validEpisodes.count) validated episodes")
                }
            }
        }
        
        let cacheCoverage = feedsWithEpisodes > 0 ? (Double(feedsWithCaches) / Double(feedsWithEpisodes)) * 100 : 100
        print("📊 CACHE COVERAGE: \(feedsWithCaches)/\(feedsWithEpisodes) feeds (\(Int(cacheCoverage))%) with \(totalCacheEpisodes) total episodes")
        
        if feedsWithCaches == feedsWithEpisodes {
            print("✅ All feeds with episodes have caches - ready for instant access")
        } else {
            print("⚠️ Some feeds missing caches - this may affect performance")
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
            
            // Only log every 10th attempt to reduce log noise
            if attempts % 10 == 0 {
                print("⏳ Waiting for sync statuses to complete: Radio:\(radioStationsStatus), Podcast:\(podcastFeedsStatus), Artwork:\(artworkDownloadsStatus), Episodes:\(episodeStatesStatus), Preferences:\(userPreferencesStatus)")
            }
            
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
                        viewModel.mergeStationsFromCloudKit(stations)
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
                    Task { @MainActor in
                        if let stations = stations {
                            viewModel.mergeStationsFromCloudKit(stations)
                            viewModel.saveStationsToCoreData()
                            
                            // Update final counts
                            self?.radioStationsCurrentCount = stations.count
                            self?.radioStationsTotalCount = stations.count
                            self?.radioStationsOperation = "✅ \(stations.count) radio stations synced from iCloud"
                            
                            print("✅ Synced \(stations.count) radio stations with progress tracking")
                            
                            // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                            UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                        } else if let error = error {
                            self?.radioStationsOperation = "❌ Failed to sync radio stations: \(error.localizedDescription)"
                            print("❌ Failed to sync radio stations: \(error)")
                        }
                        continuation.resume()
                    }
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
    
    /// Get actual episode count from loaded podcast feeds
    private func getActualEpisodeCount(_ podcastViewModel: PodcastViewModel) async -> Int {
        return await MainActor.run {
            var totalEpisodes = 0
            for feed in podcastViewModel.podcastFeeds {
                totalEpisodes += feed.episodes.count
            }
            return totalEpisodes
        }
    }
    
    /// Wait for podcast feeds to be loaded before syncing episode states
    private func waitForPodcastFeedsToLoad(_ podcastViewModel: PodcastViewModel) async {
        print("⏳ Waiting for podcast feeds to load before episode state sync...")
        
        var attempts = 0
        let maxAttempts = 30 // 3 seconds max wait
        
        while attempts < maxAttempts {
            let feedCount = await MainActor.run { podcastViewModel.podcastFeeds.count }
            if feedCount > 0 {
                print("✅ Podcast feeds loaded: \(feedCount) feeds available")
                break
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            attempts += 1
        }
        
        if attempts >= maxAttempts {
            print("⚠️ Podcast feeds not loaded within timeout - proceeding with episode sync anyway")
        }
    }
    
    // MARK: - Obsolete Methods (Removed - Now using Core Data + FeedIsolationManager)
    // createEpisodeCachesForAllFeeds() - REMOVED: Now using loadEpisodesFromCoreDataToMemory()
    // verifyEpisodeDataAvailability() - REMOVED: Now using verifyEpisodeCachesAreReady()
    
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
    
    /// Test method to manually trigger episode state sync with caches
    @MainActor
    func testEpisodeStateSyncWithCaches() {
        print("🧪 TEST: Manually triggering episode state sync with cache creation")
        Task {
            await self.syncEpisodeStates()
        }
    }
    
    /// Reset the podcast feeds sync flag to force cross-device check on next launch
    @MainActor
    func resetPodcastFeedsSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
        print("🔄 Reset podcast feeds sync flag - will check CloudKit for cross-device feeds on next initialization")
    }
    
    /// Reset the episode states sync flag to force a complete re-sync on next launch
    @MainActor
    func resetEpisodeStatesSyncFlag() {
        UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
        print("🔄 Reset episode states sync flag - will re-sync from CloudKit on next launch")
    }
}

