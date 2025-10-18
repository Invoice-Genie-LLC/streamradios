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
    
    // Episode Snapshots Readiness
    @Published var episodeSnapshotsReady = false
    @Published var feedsWithSnapshots = 0
    @Published var totalFeedsRequiringSnapshots = 0
    
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
    
    // CRITICAL: Flag to defer CloudKit notifications during fresh install sync
    @Published var isFreshInstallSyncInProgress = false
    
    private init() {
        setupProgressCalculation()
        
        // 🔧 APP GROUP FIX: Check if Core Data is empty to detect TRUE fresh install
        // App Group UserDefaults persist across app deletions, so we need to check Core Data instead
        let coreDataIsEmpty = checkIfCoreDataIsEmpty()
        if coreDataIsEmpty {
            // TRUE fresh install - Core Data is empty, reset all flags
            UserDefaults.standard.set(false, forKey: "HasLaunchedBefore")
            UserDefaults.standard.set(false, forKey: "DataSyncCompleted")
            UserDefaults.standard.set(false, forKey: "HasRadioStationsSynced")
            UserDefaults.standard.set(false, forKey: "HasPodcastFeedsSynced")
            UserDefaults.standard.set(false, forKey: "HasEpisodeStatesSynced")
            // Note: synchronize() is deprecated and unnecessary
        }
        
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
    
    // MARK: - Private Helper Methods
    
    /// Check if Core Data is empty to detect TRUE fresh install
    /// App Group UserDefaults persist across app deletions, so we check Core Data instead
    /// NOTE: We only check podcast feeds, not radio stations, because radio stations
    /// are initialized early in app lifecycle BEFORE DataSyncManager.initeaa   () runs
    private func checkIfCoreDataIsEmpty() -> Bool {
        let context = CoreDataStack.shared.context
        var isEmpty = false
        
        context.performAndWait {
            do {
                // Only check podcast feeds for fresh install detection
                // Radio stations are initialized before DataSyncManager, so they're not reliable
                let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                feedRequest.fetchLimit = 1
                let feedCount = try context.count(for: feedRequest)
                
                // Core Data is empty if there are no podcast feeds
                isEmpty = (feedCount == 0)
            } catch {
                print("❌ Error checking Core Data for fresh install: \(error)")
                isEmpty = false // Assume not empty on error to be safe
            }
        }
        
        return isEmpty
    }
    
    // MARK: - Public Methods
    
    /// Start the complete data synchronization process for fresh installs
    /// ⚡ REDESIGNED: Ensures ALL data is fetched, parsed, and saved during initial sync
    /// Everything completes in DataSyncProgressView - no lazy loading afterwards
    func startFreshInstallSync() {
        guard !isSyncing else { return }
        
        // CRITICAL: Set flag to defer CloudKit notifications during sync
        isFreshInstallSyncInProgress = true
        print("🚨 FRESH INSTALL SYNC: Deferring CloudKit notifications until sync completes")
        
        Task { @MainActor in
            isSyncing = true
            isFreshInstallUIReady = false
            resetProgress()
            
            print("🔄 ========================================")
            print("🔄 FRESH INSTALL SYNC: Starting COMPREHENSIVE sync...")
            print("🔄 ALL data will be fetched and processed during initial sync")
            print("🔄 Core Data should be EMPTY at this point")
            print("🔄 ========================================")
            
            // ⚡ CRITICAL: Enable fresh install mode to prevent premature episode state saves
            EpisodeStateManager.shared.enableFreshInstallMode()
            
            // ⚡ COMPREHENSIVE SYNC ORDER (CRITICAL for fresh install):
            // 1. Radio Stations: CloudKit -> Core Data -> Create ALL Snapshots
            // 2. Podcast Feeds: CloudKit -> Parse ALL RSS -> Core Data (with ALL episodes)
            // 3. Episode States: CloudKit -> Apply to ALL episodes in Core Data
            // 4. Create ALL Episode Snapshots for instant loading
            // 5. Wait for ALL artwork downloads to complete
            // 6. Final verification and completion
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 1: Syncing ALL Radio Stations")
            print("🔄 ═══════════════════════════════════════")
            await syncRadioStationsComprehensive()
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 2: Syncing ALL Podcast Feeds & Episodes")
            print("🔄 ═══════════════════════════════════════")
            await syncPodcastFeedsComprehensive()
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 3: Syncing ALL Episode States")
            print("🔄 ═══════════════════════════════════════")
            await syncEpisodeStatesComprehensive()
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 4: Creating ALL Snapshots")
            print("🔄 ═══════════════════════════════════════")
            await createAllSnapshotsComprehensive()
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 5: Waiting for ALL Artwork Downloads")
            print("🔄 ═══════════════════════════════════════")
            await waitForAllArtworkDownloadsComplete()
            
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 6: User Preferences Sync")
            print("🔄 ═══════════════════════════════════════")
            await syncUserPreferences()
            
            // ⚡ STEP 7: Disable fresh install mode
            print("🔄 STEP 7: Disabling fresh install mode...")
            EpisodeStateManager.shared.disableFreshInstallMode()
            
            // ⚡ STEP 8: Final verification and completion
            print("🔄 ═══════════════════════════════════════")
            print("🔄 STEP 8: Final Verification & Completion")
            print("🔄 ═══════════════════════════════════════")
            await completeSynchronizationComprehensive()
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
                print("🔄 Radio station sync needed - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                
                // ⚡ ALWAYS CHECK CLOUDKIT: User may have manual stations from another device
                // Aggressive timeouts (5s) ensure fast fallback to ManualStationsData if no CloudKit data
                print("🔄 Checking CloudKit for radio stations (may have data from other device)...")
                radioStationsOperation = "Checking iCloud for stations..."
                await syncRadioStationsFromCloudKitWithProgress()
                
                // Mark radio stations as synced
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            } else {
                print("⚡ Skipping CloudKit radio station sync - loading from local storage only for better performance")
                radioStationsOperation = "Loading radio stations from local storage..."
                radioStationsTotalCount = await getLocalStationCount()
                
                // ⚡ OPTIMIZATION: Load immediately without artificial delays
                radioStationsProgress = 0.5
                radioStationsOperation = "Loading \(radioStationsTotalCount) stations..."
                
                // Load from Core Data instead of CloudKit
                await MainActor.run {
                    viewModel.loadStationsFromCoreData()
                    radioStationsCurrentCount = radioStationsTotalCount
                    radioStationsProgress = 1.0
                }
            }
            
            // CRITICAL: Create station snapshots for all countries after loading
            print("📸 Creating station snapshots for all countries...")
            await createStationSnapshotsForAllCountries()
            
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            radioStationsOperation = "✅ \(radioStationsCurrentCount) radio stations loaded with snapshots"
            print("✅ Radio stations sync completed with snapshots")
            
        } catch {
            radioStationsStatus = .failed
            radioStationsOperation = "❌ Failed to load radio stations"
            print("❌ Radio stations sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncPodcastFeeds() async {
        print("🔄 syncPodcastFeeds: Started")
        
        // Check how many feeds we expect to sync FIRST
        print("🔄 syncPodcastFeeds: Calling getExpectedPodcastFeedCount()")
        let expectedFeedCount = await getExpectedPodcastFeedCount()
        print("🔄 syncPodcastFeeds: Expected feed count = \(expectedFeedCount)")
        
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
        
        // ⚠️ TIMEOUT FIX: Add timeout detection for stuck podcast sync
        let syncStartTime = Date()
        let maxSyncTime: TimeInterval = 60.0 // 60 seconds max for podcast sync
        var lastProgressTime = Date()
        
        do {
            // Get or create PodcastViewModel instance
            let podcastViewModel = PodcastViewModel.shared
            
            // ⚡ OPTIMIZATION: Skip artificial delays, start immediately
            podcastFeedsProgress = 0.1
            podcastFeedsOperation = "Loading podcast feeds from iCloud..."
            
            // Wait for podcast feeds to actually load
            podcastFeedsOperation = "Syncing podcast feeds from iCloud..."
            
            // Check if we need to process fresh install feeds
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasPodcastFeedsSynced = UserDefaults.standard.bool(forKey: "HasPodcastFeedsSynced")
            
            if isFreshInstall || !hasPodcastFeedsSynced {
                // ⚡ OPTIMIZED: Direct CloudKit initialization without complex monitoring
                print("🚀 Starting CloudKit feed initialization...")
                podcastFeedsOperation = "Syncing feeds from iCloud..."
                
                // Simply await the initialization - let it complete naturally
                await initializeCloudKitFeedsForFreshInstall(podcastViewModel)
                
                // Update progress based on actual feed count
                let currentFeedCount = podcastViewModel.podcastFeeds.count
                if currentFeedCount > 0 {
                    podcastFeedsCurrentCount = currentFeedCount
                    podcastFeedsTotalCount = max(podcastFeedsTotalCount, currentFeedCount)
                    print("✅ Loaded \(currentFeedCount) podcast feeds from CloudKit")
                }
            }
            
            // ⚡ OPTIMIZED: Quick finalization without artificial delays
            podcastFeedsProgress = 0.9
            let finalCount = podcastViewModel.podcastFeeds.count
            podcastFeedsCurrentCount = finalCount
            podcastFeedsTotalCount = max(podcastFeedsTotalCount, finalCount)
            podcastFeedsProgress = 1.0
            podcastFeedsStatus = .completed
            
            let totalTime = Int(Date().timeIntervalSince(syncStartTime))
            podcastFeedsOperation = "✅ \(finalCount) podcast feeds loaded (\(totalTime)s)"
            print("✅ Podcast feeds sync completed - \(finalCount) feeds in \(totalTime)s")
            
            // Mark as synced
            UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            
            // ⚡ NON-BLOCKING: Start artwork downloads in background (don't wait)
            startArtworkDownloadTracking(totalFeeds: finalCount)
            
            // Auto-reset banner (skip on fresh install to allow verification to complete)
            let isFreshInstallCheck = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            if !isFreshInstallCheck {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.podcastFeedsStatus = .none
                    self.podcastFeedsProgress = 0.0
                    self.podcastFeedsOperation = ""
                    self.podcastFeedsCurrentCount = 0
                }
            } else {
                print("⚡ FRESH INSTALL: Skipping auto-reset to allow verification to complete")
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
            // Get the PodcastViewModel instance
            let podcastViewModel = PodcastViewModel.shared
            
            // Wait for podcast feeds to be loaded first
            await waitForPodcastFeedsToLoad(podcastViewModel)
            
                    // PERFORMANCE: Skip entire episode sync if snapshots are available
        // Snapshots already contain complete episode data with states
        let hasSnapshots = await MainActor.run {
            for feed in podcastViewModel.podcastFeeds {
                if podcastViewModel.getEpisodeSnapshot(for: feed.id) != nil {
                    print("⚡ PERFORMANCE: Found episode snapshot for feed \(feed.title)")
                    return true
                }
            }
            return false
        }
        
        if hasSnapshots {
            print("⚡ PERFORMANCE: Skipping entire episode state sync - using episode snapshots with complete state data")
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "Using episode snapshots (no sync needed)"
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
            
            // Phase 2: Create Episode Snapshots (60-90%)
            episodeStatesOperation = "Creating episode snapshots for instant access..."
            await createEpisodeSnapshotsForAllFeeds(podcastViewModel)
            episodeStatesProgress = 0.9
            
            // Update current count to reflect snapshots created
            episodeStatesCurrentCount = Int(Double(episodeStatesTotalCount) * 0.9)
            
            // Phase 3: Final Verification (90-100%)
            episodeStatesOperation = "Verifying episode data availability..."
            await verifyEpisodeDataAvailability(podcastViewModel)
            
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesCurrentCount = episodeStatesTotalCount
            episodeStatesOperation = "✅ \(episodeStatesTotalCount) episodes ready with instant snapshots"
            print("✅ Episode states sync completed with snapshots created")
            
        } catch {
            episodeStatesStatus = .failed
            episodeStatesOperation = "❌ Failed to sync episode states: \(error.localizedDescription)"
            print("❌ Episode states sync failed: \(error)")
        }
    }
    
    @MainActor
    private func syncUserPreferences() async {
        userPreferencesStatus = .inProgress
        userPreferencesOperation = "Loading user preferences..."
        
        do {
            // ⚡ OPTIMIZATION: Load preferences instantly without delays
            userPreferencesOperation = "Loading preferences..."
            userPreferencesProgress = 0.5
            
            // Preferences are already loaded, just mark as complete
            userPreferencesProgress = 1.0
            
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
        
        // Episode Snapshots
        episodeSnapshotsReady = false
        feedsWithSnapshots = 0
        totalFeedsRequiringSnapshots = 0
        
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
        
        // Also reset snapshot tracking
        episodeSnapshotsReady = false
        feedsWithSnapshots = 0
        totalFeedsRequiringSnapshots = 0
        
        print("🔄 DataSyncManager: Reset episode state sync tracking and snapshots")
    }
    
    /// Update episode snapshot readiness tracking (called by PodcastViewModel when snapshots are created)
    @MainActor
    func updateEpisodeSnapshotReadiness(feedsWithSnapshots: Int, totalFeedsRequiringSnapshots: Int) {
        self.feedsWithSnapshots = feedsWithSnapshots
        self.totalFeedsRequiringSnapshots = totalFeedsRequiringSnapshots
        self.episodeSnapshotsReady = (feedsWithSnapshots == totalFeedsRequiringSnapshots && totalFeedsRequiringSnapshots > 0)
        
        print("📸 DataSyncManager: Updated episode snapshot readiness - \(feedsWithSnapshots)/\(totalFeedsRequiringSnapshots) ready: \(episodeSnapshotsReady)")
    }
    
    /// Update radio station snapshot readiness tracking (called by RadioStationViewModel when snapshots are created)
    @MainActor
    func updateStationSnapshotReadiness(countriesWithSnapshots: Int, totalCountriesRequiringSnapshots: Int) {
        self.countriesWithSnapshots = countriesWithSnapshots
        self.totalCountriesRequiringSnapshots = totalCountriesRequiringSnapshots
        self.stationSnapshotsReady = (countriesWithSnapshots == totalCountriesRequiringSnapshots && totalCountriesRequiringSnapshots > 0)
        
        print("📸 DataSyncManager: Updated station snapshot readiness - \(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots) ready: \(stationSnapshotsReady)")
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
        print("⏳ Checking artwork downloads...")
        
        // ⚡ OPTIMIZED: Reduced to 3 seconds and non-blocking
        let maxWaitTime: TimeInterval = 3.0
        let checkInterval: TimeInterval = 0.5
        let maxChecks = Int(maxWaitTime / checkInterval)
        var checks = 0
        
        while artworkDownloadsStatus == .inProgress && checks < maxChecks {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            checks += 1
        }
        
        if checks >= maxChecks {
            print("⚠️ Artwork continuing in background")
            // Mark as completed but allow background downloads to continue
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
        } else {
            print("✅ Artwork completed (\(completedArtworkDownloads)/\(totalArtworkDownloads))")
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
        
        // CRITICAL: Final verification that episode snapshots are available
        await verifyEpisodeSnapshotsAreReady(podcastViewModel)
        
        // CRITICAL: Final verification that station snapshots are available
        await verifyStationSnapshotsAreReady(radioStationViewModel)
        
        currentOperation = "Synchronization completed!"
        
        // CRITICAL: Force Core Data save and reload before any verification
        print("🚀 CRITICAL: Forcing Core Data save and reload before UI refresh")
        await podcastViewModel.forceSaveAndReload()
        
        // CRITICAL: Ensure episode snapshots are created for all feeds before completion
        await ensureEpisodeSnapshotsAreCreated(podcastViewModel)
        
        // CRITICAL: Ensure radio station snapshots are created for all countries before completion
        await ensureStationSnapshotsAreCreated(RadioStationViewModel.shared)
        
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
            print("⚠️ WARNING: No podcast feeds found - this is expected on truly fresh install")
            print("✅ FRESH INSTALL: User starts with empty podcast library - can add feeds manually")
            
            // CRITICAL: Set UI as ready even with 0 feeds (fresh install scenario)
            isFreshInstallUIReady = true
            isSyncing = false
            print("✅ FRESH INSTALL UI READY: Marked as ready with 0 podcast feeds")
        }
        
        // Mark sync as completed only after everything is truly ready
        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        
        // CRITICAL FIX: Set HasLaunchedBefore ONLY after sync completes
        // This ensures fresh install detection works correctly during the sync process
        UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
        print("✅ SYNC COMPLETE: Marked HasLaunchedBefore=true after successful sync")
        
        // Note: synchronize() is deprecated and unnecessary
        
        // CRITICAL: Clear flag to allow CloudKit notifications now that sync is complete
        isFreshInstallSyncInProgress = false
        print("✅ FRESH INSTALL SYNC: Re-enabled CloudKit notification processing")
        
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
            // CRITICAL: Also check that both episode and station snapshots are ready before allowing UI access
            let snapshotsReady = (episodeSnapshotsReady || totalFeedsRequiringSnapshots == 0) && 
                                (stationSnapshotsReady || totalCountriesRequiringSnapshots == 0)
            
            if snapshotsReady {
                print("✅ FINAL SUCCESS: UI is ready with \(finalFeedCount) feeds, \(finalFeedOrderCount) feed order items, \(feedsWithSnapshots) episode snapshots, and \(countriesWithSnapshots) station snapshots")
                isFreshInstallUIReady = true
                isSyncing = false
                print("🚀 DataSyncProgressView hidden - UI is confirmed ready with feeds AND all snapshots")
            } else {
                print("⏳ WAITING FOR SNAPSHOTS: Feeds ready but snapshots not complete - Episodes: (\(feedsWithSnapshots)/\(totalFeedsRequiringSnapshots)), Stations: (\(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots))")
                // Wait a bit more for snapshots to complete
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                let snapshotsReadyAfterWait = (episodeSnapshotsReady || totalFeedsRequiringSnapshots == 0) && 
                                             (stationSnapshotsReady || totalCountriesRequiringSnapshots == 0)
                
                if snapshotsReadyAfterWait {
                    print("✅ SNAPSHOTS READY: All snapshots completed after wait")
                    isFreshInstallUIReady = true
                    isSyncing = false
                    print("🚀 DataSyncProgressView hidden - UI is confirmed ready with feeds AND all snapshots")
                } else {
                    print("⏳ STILL WAITING: Snapshots not ready after wait - will retry")
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
    
    /// Ensure episode snapshots are created for all feeds before completing sync
    @MainActor
    private func ensureEpisodeSnapshotsAreCreated(_ podcastViewModel: PodcastViewModel) async {
        print("📸 FINAL SNAPSHOT CHECK: Ensuring all feeds have episode snapshots...")
        
        // CRITICAL: Don't clear snapshots if they already exist and are valid
        // Check if snapshots already exist for all feeds
        var allSnapshotsExist = true
        for feed in podcastViewModel.podcastFeeds {
            if podcastViewModel.getEpisodeSnapshot(for: feed.id) == nil {
                allSnapshotsExist = false
                break
            }
        }
        
        if allSnapshotsExist && !podcastViewModel.podcastFeeds.isEmpty {
            print("✅ FINAL SNAPSHOT CHECK: All snapshots already exist - skipping recreation")
            episodeSnapshotsReady = true
            return
        }
        
        // Load episodes from Core Data for all feeds
        print("📡 FINAL SNAPSHOT: Loading episodes from Core Data for all feeds...")
        var feedsWithLoadedEpisodes: [(PodcastFeed, [PodcastEpisode])] = []
        
        await withTaskGroup(of: (PodcastFeed, [PodcastEpisode]).self) { group in
            for feed in podcastViewModel.podcastFeeds {
                group.addTask {
                    let episodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feed.id)
                    return (feed, episodes)
                }
            }
            
            // Collect all results
            for await (feed, episodes) in group {
                if !episodes.isEmpty {
                    feedsWithLoadedEpisodes.append((feed, episodes))
                }
            }
        }
        
        print("📡 FINAL SNAPSHOT: Loaded episodes for \(feedsWithLoadedEpisodes.count) feeds from Core Data")
        
        var snapshotsCreated = 0
        var totalEpisodes = 0
        
        // Update snapshot tracking
        totalFeedsRequiringSnapshots = feedsWithLoadedEpisodes.count
        feedsWithSnapshots = 0
        
        for (feed, episodes) in feedsWithLoadedEpisodes {
            // 🛡️ CONTAMINATION PREVENTION: Validate episodes before creating snapshot
            let validEpisodes = episodes.filter { $0.feedId == feed.id }
            if validEpisodes.count != episodes.count {
                print("🚨 FINAL CONTAMINATION: Feed '\(feed.title)' has \(episodes.count - validEpisodes.count) contaminated episodes")
            }
            
            // Apply current states from EpisodeStateManager before creating snapshot
            let episodesWithCurrentStates = validEpisodes.map { episode in
                var updatedEpisode = episode
                
                // Get current states from EpisodeStateManager
                let progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                let isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                let playbackState = EpisodeStateManager.shared.getState(for: episode.id)
                
                // Update episode state with current values
                updatedEpisode.state.progress = progress
                updatedEpisode.state.isFavorite = isFavorite
                updatedEpisode.state.isDownloaded = isDownloaded
                updatedEpisode.state.isPlayed = (playbackState == .played)
                
                return updatedEpisode
            }
            
            // Create snapshot for feeds with validated episodes that have current states
            podcastViewModel.updateEpisodeSnapshot(for: feed.id, episodes: episodesWithCurrentStates)
            feedsWithSnapshots += 1
            snapshotsCreated += 1
            totalEpisodes += validEpisodes.count
            print("📸 Created final snapshot for '\(feed.title)' with \(validEpisodes.count) episodes with current states")
        }
        
        // Mark snapshots as ready
        episodeSnapshotsReady = (feedsWithSnapshots == totalFeedsRequiringSnapshots)
        
        print("📸 FINAL SNAPSHOT SUMMARY: \(snapshotsCreated) snapshots available with \(totalEpisodes) total episodes")
        print("📸 FINAL SNAPSHOT READINESS: \(feedsWithSnapshots)/\(totalFeedsRequiringSnapshots) feeds with episodes have snapshots - Ready: \(episodeSnapshotsReady)")
        
        // Update episode states progress to reflect snapshot creation
        if episodeStatesStatus != .completed {
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "✅ \(feedsWithSnapshots) episode snapshots ready for instant access"
        }
    }
    
    /// Ensure radio station snapshots are created for all countries before completing sync
    @MainActor
    private func ensureStationSnapshotsAreCreated(_ radioStationViewModel: RadioStationViewModel) async {
        print("📸 FINAL STATION SNAPSHOT CHECK: Ensuring all countries have station snapshots...")
        
        let countriesWithStations = Dictionary(grouping: radioStationViewModel.stations) { $0.country }
            .filter { !$0.key.isEmpty && $0.key != "Unknown Region" && $0.key != "Select Country" }
        
        var snapshotsCreated = 0
        var totalStations = 0
        
        // Update snapshot tracking
        totalCountriesRequiringSnapshots = countriesWithStations.count
        countriesWithSnapshots = 0
        
        for (country, stations) in countriesWithStations {
            // Check if snapshot already exists
            if radioStationViewModel.getStationSnapshot(for: country) != nil {
                countriesWithSnapshots += 1
                snapshotsCreated += 1
                print("📸 Station snapshot already exists for '\(country)'")
            } else {
                // Create snapshot for countries with stations
                radioStationViewModel.updateStationSnapshot(for: country, stations: stations)
                countriesWithSnapshots += 1
                snapshotsCreated += 1
                totalStations += stations.count
                print("📸 Created final station snapshot for '\(country)' with \(stations.count) stations")
            }
        }
        
        // Mark snapshots as ready
        stationSnapshotsReady = (countriesWithSnapshots == totalCountriesRequiringSnapshots)
        
        print("📸 FINAL STATION SNAPSHOT SUMMARY: \(snapshotsCreated) snapshots available with \(totalStations) total stations")
        print("📸 FINAL STATION SNAPSHOT READINESS: \(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots) countries have snapshots - Ready: \(stationSnapshotsReady)")
        
        // Update radio stations progress to reflect snapshot creation
        if radioStationsStatus != .completed {
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            radioStationsOperation = "✅ \(countriesWithSnapshots) station snapshots ready for instant access"
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
    
    /// Sync from CloudKit with retry logic and timeout
    private func syncFromCloudKitWithRetry() async throws -> [PodcastFeed] {
        // ⚡ OPTIMIZATION: For fresh installs, only try once with reduced timeout
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let maxRetries = isFreshInstall ? 1 : 3  // Only 1 attempt for fresh install
        var retryCount = 0
        
        while retryCount < maxRetries {
            do {
                print("☁️ FRESH INSTALL: Attempting CloudKit sync (attempt \(retryCount + 1)/\(maxRetries))")
                
                // ⚡ OPTIMIZED: Generous timeout for fresh install (CloudKit can be slow, especially with many feeds)
                let timeoutSeconds: TimeInterval = isFreshInstall ? 60.0 : 45.0
                print("⏱️ TIMEOUT: Starting \(Int(timeoutSeconds))s timeout wrapper (fresh install: \(isFreshInstall))")
                
                let result = try await withTimeout(seconds: timeoutSeconds) {
                    return try await PodcastCloudKitManager.shared.syncFromCloudKit()
                }
                
                print("⏱️ TIMEOUT: withTimeout returned, checking result...")
                
                if let feeds = result {
                    print("✅ FRESH INSTALL: CloudKit sync succeeded with \(feeds.count) feeds")
                    return feeds
                } else {
                    // Timeout occurred
                    print("⚠️ ⚠️ ⚠️ FRESH INSTALL: CloudKit sync TIMED OUT after \(Int(timeoutSeconds))s")
                    
                    // For fresh install, fail fast - don't retry
                    if isFreshInstall {
                        print("⚡ FRESH INSTALL: Skipping retries, using fallback immediately")
                        throw NSError(domain: "DataSyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "CloudKit sync timeout - using fallback"])
                    }
                    
                    print("⚠️ THROWING TIMEOUT ERROR to trigger retry...")
                    throw NSError(domain: "DataSyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "CloudKit sync timeout"])
                }
            } catch {
                retryCount += 1
                print("⚠️ FRESH INSTALL: CloudKit sync error caught (attempt \(retryCount)/\(maxRetries)): \(error.localizedDescription)")
                print("⚠️ ERROR TYPE: \(type(of: error))")
                
                // Check if it's a rate limiting error
                if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    let retryAfter = ckError.retryAfterSeconds ?? 10.0
                    print("⏱️ FRESH INSTALL: Rate limited, waiting \(Int(retryAfter))s before retry")
                    
                    if retryCount < maxRetries {
                        Task { @MainActor in
                            podcastFeedsOperation = "Rate limited, waiting \(Int(retryAfter))s..."
                        }
                        
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        
                        Task { @MainActor in
                            podcastFeedsOperation = "Retrying podcast feeds from iCloud..."
                        }
                    }
                } else if retryCount >= maxRetries {
                    // Max retries exceeded
                    print("❌ FRESH INSTALL: Max retries exceeded - giving up on attempt \(retryCount)")
                    throw error
                } else {
                    // Other error - wait briefly before retry
                    print("⏱️ FRESH INSTALL: Error on attempt \(retryCount), waiting 3s before retry \(retryCount + 1)...")
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    print("⏱️ FRESH INSTALL: Retrying now...")
                }
            }
        }
        
        throw NSError(domain: "DataSyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "CloudKit sync failed after all retries"])
    }
    
    /// Helper for timeout operations with return value
    /// CRITICAL: Returns nil immediately after timeout to avoid hanging
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T? {
        print("⏱️ TIMEOUT WRAPPER: Starting with \(Int(seconds))s timeout")
        
        // Use a detached task to avoid blocking on task group completion
        let resultRef = UnsafeMutablePointer<T?>.allocate(capacity: 1)
        resultRef.initialize(to: nil)
        defer { 
            resultRef.deinitialize(count: 1)
            resultRef.deallocate() 
        }
        
        let completed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        completed.initialize(to: false)
        defer {
            completed.deinitialize(count: 1)
            completed.deallocate()
        }
        
        // Start operation in background
        Task {
            do {
                let result = try await operation()
                if !completed.pointee {
                    resultRef.pointee = result
                    print("⏱️ TIMEOUT WRAPPER: Operation completed successfully")
                }
            } catch {
                print("⏱️ TIMEOUT WRAPPER: Operation threw error: \(error.localizedDescription)")
            }
        }
        
        // Wait for timeout or operation completion
        print("⏱️ TIMEOUT WRAPPER: Waiting for timeout or completion...")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        
        completed.pointee = true
        
        if let result = resultRef.pointee {
            print("⏱️ TIMEOUT WRAPPER: Operation completed before timeout - returning result")
            return result
        } else {
            print("⏱️ TIMEOUT WRAPPER: Timeout reached - returning nil")
            return nil
        }
    }
    
    /// Initialize CloudKit feeds for fresh install (with RSS processing)
    @MainActor
    private func initializeCloudKitFeedsForFreshInstall(_ podcastViewModel: PodcastViewModel) async {
        print("🚀 Initializing CloudKit feeds for fresh install...")
        
        // ⚡ ALWAYS CHECK CLOUDKIT: User may have data from another device/reinstall
        // Use 20s timeout - fast fail if CloudKit is hung or rate limited
        print("🔄 Checking CloudKit for existing podcast feeds...")
        print("⚡ FRESH INSTALL: Using 20s timeout for CloudKit sync (inner batch: 10s)")
        podcastFeedsOperation = "Checking iCloud..."
        podcastFeedsProgress = 0.2
        
        // ⚡ CLOUDKIT HUNG FIX: Use 20s outer timeout (inner batch timeout is 10s)
        // If CloudKit doesn't respond in 10s, it's likely rate-limited or network issue
        // Quick fallback to local storage prevents app from hanging
        let quickTimeoutSeconds: TimeInterval = 20.0
        print("⏱️ Using 20s timeout for CloudKit fetch (inner batch: 10s)")
        print("⏱️ If timeout occurs, falling back to local storage immediately")
        
        let cloudKitFeeds: [PodcastFeed]
        do {
            print("🔍 [PODCAST-SYNC-1] About to call syncFromCloudKitWithRetry()...")
            
            // Try with timeout
            print("🔍 [PODCAST-SYNC-1.5] Calling withTimeout now...")
            let result = try await withTimeout(seconds: quickTimeoutSeconds) {
                return try await PodcastCloudKitManager.shared.syncFromCloudKit()
            }
            
            print("🔍 [PODCAST-SYNC-1.75] withTimeout returned! Result is nil: \(result == nil)")
            
            if let feeds = result {
                print("🔍 [PODCAST-SYNC-2] syncFromCloudKit() returned successfully!")
                print("✅ Successfully fetched \(feeds.count) feeds from CloudKit")
                cloudKitFeeds = feeds
            } else {
                // Timeout - use local data immediately
                print("⏱️ CloudKit fetch timed out after \(Int(quickTimeoutSeconds))s - using local data")
                print("⚠️ FRESH INSTALL TIMEOUT: CloudKit hung or rate-limited - falling back to local defaults")
                print("⚠️ This is usually caused by rate limiting or network issues")
                print("⚠️ User's data is safe and will sync automatically when CloudKit is available")
                
                // Do NOT start background sync on fresh install timeout
                // It will also hang and waste resources
                
                cloudKitFeeds = []
                print("🔍 [PODCAST-SYNC-2.5] Set cloudKitFeeds to empty array")
            }
        } catch {
            print("⚠️ CloudKit sync failed: \(error.localizedDescription)")
            print("🔄 [FALLBACK-START] Loading from local Core Data instead...")
            cloudKitFeeds = []
        }
        
        print("🔍 [PODCAST-SYNC-3] After try-catch block, cloudKitFeeds.count = \(cloudKitFeeds.count)")
        
        // Handle empty CloudKit result
        if cloudKitFeeds.isEmpty {
            
            podcastFeedsOperation = "Loading from local storage..."
            podcastFeedsProgress = 0.5
            
            podcastViewModel.loadFeedsFromCoreData()
            let localCount = podcastViewModel.podcastFeeds.count
            
            if localCount > 0 {
                print("✅ Loaded \(localCount) feeds from local storage")
                podcastFeedsOperation = "✅ Loaded \(localCount) feeds"
            } else {
                // Fresh install with CloudKit timeout - user will have empty library
                print("📱 FRESH INSTALL TIMEOUT FALLBACK: No feeds available - user starts with empty library")
                print("📱 User can add podcast feeds manually")
                podcastFeedsOperation = "Ready to add podcasts"
            }
            
            // CRITICAL: Mark podcast feeds as completed to prevent verification timeout
            podcastFeedsStatus = .completed
            podcastFeedsProgress = 1.0
            print("✅ Podcast feeds sync completed - \(localCount) feeds")
            
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "✅ Ready"
            UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
            UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            startArtworkDownloadTracking(totalFeeds: podcastViewModel.podcastFeeds.count)
            
            return
        }
        
        // Process feeds if we got them from CloudKit
        if !cloudKitFeeds.isEmpty {
            print("🌟 Processing \(cloudKitFeeds.count) feeds from CloudKit")
            
            // Clear episode snapshots
            podcastFeedsOperation = "Processing feeds..."
            podcastFeedsProgress = 0.3
            await podcastViewModel.clearAllEpisodeSnapshots()
            
            // Start feed parsing
            isParsingFeeds = true
            feedParsingProgress = 0.0
            feedParsingMessage = "Processing RSS feeds..."
            print("📡 Processing RSS feeds...")
            
            // ⚡ OPTIMIZED: Process feeds with RSS parsing
            await podcastViewModel.loadFreshInstallPodcastData(cloudKitFeeds)
            
            podcastFeedsOperation = "Syncing episode states..."
            podcastFeedsProgress = 0.6
            episodeStatesStatus = .inProgress
            episodeStatesOperation = "Fetching episode states..."
            episodeStatesProgress = 0.3
            
            print("☁️ Syncing episode states from CloudKit...")
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let episodeStatesSyncSuccess = await podcastViewModel.syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
            
            if episodeStatesSyncSuccess {
                episodeStatesOperation = "Episode states synced"
                episodeStatesProgress = 0.7
                UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
                print("✅ Episode states synced")
            }
            
            // ⚡ PARALLEL: Apply metadata while creating snapshots
            podcastFeedsOperation = "Finalizing..."
            podcastFeedsProgress = 0.8
            episodeStatesOperation = "Creating snapshots..."
            episodeStatesProgress = 0.8
            
            await podcastViewModel.applyCloudKitFeedMetadata(cloudKitFeeds)
            await createEpisodeSnapshotsForAllFeeds(podcastViewModel)
            
            // Complete
            episodeStatesStatus = .completed
            episodeStatesOperation = "✅ Episode snapshots ready"
            episodeStatesProgress = 1.0
            
            podcastFeedsOperation = "Completed"
            podcastFeedsProgress = 1.0
            feedParsingProgress = 1.0
            isParsingFeeds = false
            
            UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            print("✅ Fresh install completed with \(podcastViewModel.podcastFeeds.count) feeds")
        } else {
            print("📡 No feeds in CloudKit - empty library")
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesOperation = "✅ No episodes to sync"
            UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
            startArtworkDownloadTracking(totalFeeds: 0)
            UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            podcastFeedsProgress = 1.0
        }
    }
    
    /// Verify that station snapshots are ready for immediate use
    @MainActor
    private func verifyStationSnapshotsAreReady(_ radioStationViewModel: RadioStationViewModel) async {
        print("🔍 FINAL VERIFICATION: Checking station snapshot availability...")
        
        let countriesWithStations = Dictionary(grouping: radioStationViewModel.stations) { $0.country }
            .filter { !$0.key.isEmpty && $0.key != "Unknown Region" && $0.key != "Select Country" }
        
        var countriesWithSnapshots = 0
        var totalSnapshotStations = 0
        
        for (country, stations) in countriesWithStations {
            if let snapshot = radioStationViewModel.getStationSnapshot(for: country) {
                countriesWithSnapshots += 1
                totalSnapshotStations += snapshot.count
                print("✅ Snapshot verified for country '\(country)': \(snapshot.count) stations")
            } else {
                print("⚠️ Missing snapshot for country '\(country)' with \(stations.count) stations")
                
                // Create missing snapshot
                radioStationViewModel.updateStationSnapshot(for: country, stations: stations)
                countriesWithSnapshots += 1
                totalSnapshotStations += stations.count
                print("🔧 Created missing snapshot for country '\(country)' with \(stations.count) stations")
            }
        }
        
        let snapshotCoverage = countriesWithStations.count > 0 ? (Double(countriesWithSnapshots) / Double(countriesWithStations.count)) * 100 : 100
        print("📊 STATION SNAPSHOT COVERAGE: \(countriesWithSnapshots)/\(countriesWithStations.count) countries (\(Int(snapshotCoverage))%) with \(totalSnapshotStations) total stations")
        
        if countriesWithSnapshots == countriesWithStations.count {
            print("✅ All countries have station snapshots - ready for instant access")
            stationSnapshotsReady = true
        } else {
            print("⚠️ Some countries missing snapshots - this may affect performance")
        }
    }
    
    /// Verify that episode snapshots are ready for immediate use
    @MainActor
    private func verifyEpisodeSnapshotsAreReady(_ podcastViewModel: PodcastViewModel) async {
        print("🔍 FINAL VERIFICATION: Checking episode snapshot availability...")
        
        var feedsWithSnapshots = 0
        var feedsWithEpisodes = 0
        var totalSnapshotEpisodes = 0
        
        for feed in podcastViewModel.podcastFeeds {
            if !feed.episodes.isEmpty {
                feedsWithEpisodes += 1
                
                if let snapshot = podcastViewModel.getEpisodeSnapshot(for: feed.id) {
                    feedsWithSnapshots += 1
                    totalSnapshotEpisodes += snapshot.count
                    print("✅ Snapshot verified for '\(feed.title)': \(snapshot.count) episodes")
                } else {
                    print("⚠️ Missing snapshot for '\(feed.title)' with \(feed.episodes.count) episodes")
                    
                    // 🛡️ CONTAMINATION PREVENTION: Validate episodes before creating missing snapshot
                    let validEpisodes = feed.episodes.filter { $0.feedId == feed.id }
                    if validEpisodes.count != feed.episodes.count {
                        print("🚨 MISSING SNAPSHOT CONTAMINATION: Feed '\(feed.title)' has \(feed.episodes.count - validEpisodes.count) contaminated episodes")
                    }
                    
                    // Create missing snapshot with validated episodes
                    podcastViewModel.updateEpisodeSnapshot(for: feed.id, episodes: validEpisodes)
                    feedsWithSnapshots += 1
                    totalSnapshotEpisodes += validEpisodes.count
                    print("🔧 Created missing snapshot for '\(feed.title)' with \(validEpisodes.count) validated episodes")
                }
            }
        }
        
        let snapshotCoverage = feedsWithEpisodes > 0 ? (Double(feedsWithSnapshots) / Double(feedsWithEpisodes)) * 100 : 100
        print("📊 SNAPSHOT COVERAGE: \(feedsWithSnapshots)/\(feedsWithEpisodes) feeds (\(Int(snapshotCoverage))%) with \(totalSnapshotEpisodes) total episodes")
        
        if feedsWithSnapshots == feedsWithEpisodes {
            print("✅ All feeds with episodes have snapshots - ready for instant access")
        } else {
            print("⚠️ Some feeds missing snapshots - this may affect performance")
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
        
        print("⚡ Starting modernized CloudKit radio station sync with async/await...")
        radioStationsOperation = "Connecting to iCloud..."
        radioStationsProgress = 0.0
        
        // ⚡ MODERNIZED: Use async/await with proper timeout
        let timeoutSeconds: TimeInterval = 45.0 // More generous timeout
        
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) {
                return try await self.fetchRadioStationsModern(progressCallback: { progress, count, message in
                    Task { @MainActor in
                        self.radioStationsProgress = progress
                        self.radioStationsCurrentCount = count
                        self.radioStationsOperation = message
                        print("📊 Radio stations progress: \(Int(progress * 100))% - \(count) stations - \(message)")
                    }
                })
            }
            
            if let stations = result {
                // Success!
                viewModel.stations = stations
                viewModel.saveStationsToCoreData()
                
                radioStationsCurrentCount = stations.count
                radioStationsTotalCount = stations.count
                radioStationsProgress = 1.0
                radioStationsOperation = "✅ \(stations.count) radio stations synced from iCloud"
                
                print("✅ Synced \(stations.count) radio stations successfully")
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            } else {
                // Timeout - fall back to local
                print("⏱️ CloudKit fetch timed out - falling back to local data")
                await fallbackToLocalRadioStations(viewModel)
            }
        } catch {
            // Error - fall back to local
            print("⚠️ CloudKit error: \(error.localizedDescription) - falling back to local data")
            await fallbackToLocalRadioStations(viewModel)
        }
    }
    
    /// Modernized radio station fetch using async/await API
    private func fetchRadioStationsModern(progressCallback: @escaping (Double, Int, String) -> Void) async throws -> [RadioStation] {
        print("📡 MODERN API: Starting radio station fetch with async/await...")
        print("📡 MODERN API: Fetching ONLY manual stations (not API stations)")
        
        let privateDatabase = CKContainer.default().privateCloudDatabase
        
        var allStations: [RadioStation] = []
        var cursor: CKQueryOperation.Cursor? = nil
        var batchCount = 0
        let maxBatches = 5 // Safety limit
        
        // ⚡ CRITICAL: Only fetch manual stations from CloudKit
        let manualStationPredicate = NSPredicate(format: "id BEGINSWITH %@", "manual_")
        let query = CKQuery(recordType: "streamingRadios", predicate: manualStationPredicate)
        
        repeat {
            batchCount += 1
            print("📡 MODERN API: Fetching batch \(batchCount)/\(maxBatches)...")
            
            // Add per-batch timeout
            // ⚡ PERFORMANCE: Use aggressive 5s timeout for fast fallback
            let batchTimeoutSeconds: TimeInterval = 5.0
            let batchResult = try await withTimeout(seconds: batchTimeoutSeconds) {
                return try await (cursor == nil
                    ? privateDatabase.records(matching: query, resultsLimit: 400) // Reduced batch size
                    : privateDatabase.records(continuingMatchFrom: cursor!))
            }
            
            guard let (matchResults, nextCursor) = batchResult else {
                print("⚠️ MODERN API: Batch \(batchCount) timed out after \(Int(batchTimeoutSeconds))s")
                if allStations.isEmpty {
                    throw NSError(domain: "DataSyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "CloudKit batch timeout with no data"])
                }
                // If we have some stations, return what we got
                print("⚡ MODERN API: Returning \(allStations.count) stations from \(batchCount - 1) completed batches")
                break
            }
            
            print("✅ MODERN API: Batch \(batchCount) got \(matchResults.count) results")
            
            // Parse stations from this batch
            for (recordID, result) in matchResults {
                switch result {
                case .success(let record):
                    if let station = parseRadioStation(from: record) {
                        allStations.append(station)
                    }
                case .failure(let error):
                    print("⚠️ Skipping record \(recordID.recordName): \(error.localizedDescription)")
                }
            }
            
            // Report progress
            let progress = min(0.95, Double(allStations.count) / 50.0) // Estimate ~50 manual stations
            await MainActor.run {
                progressCallback(progress, allStations.count, "Loading \(allStations.count) manual stations from iCloud...")
            }
            
            cursor = nextCursor
            
            // Longer delay between batches to avoid rate limiting
            if cursor != nil {
                print("📡 MODERN API: Waiting 1s before next batch to avoid rate limiting...")
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay
            }
            
            // Safety check
            if batchCount >= maxBatches {
                print("⚠️ MODERN API: Reached max batches (\(maxBatches)), stopping with \(allStations.count) stations")
                break
            }
            
        } while cursor != nil
        
        print("🌟 MODERN API: Completed fetching \(allStations.count) stations in \(batchCount) batches")
        
        // Final progress report
        await MainActor.run {
            progressCallback(1.0, allStations.count, "Processing \(allStations.count) stations...")
        }
        
        return allStations
    }
    
    /// Parse a CloudKit record into a RadioStation
    private func parseRadioStation(from record: CKRecord) -> RadioStation? {
        guard let name = record["name"] as? String,
              let url = record["url"] as? String else {
            return nil
        }
        
        return RadioStation(
            id: record.recordID.recordName,
            name: name,
            url: url,
            iconData: record["iconData"] as? String,
            iTunesArtworkData: record["iTunesArtworkData"] as? String,
            country: record["country"] as? String ?? "Unknown Region",
            isFavorite: record["isFavorite"] as? Bool ?? false,
            favoritedAt: record["favoritedAt"] as? Date,
            favoriteOrder: record["favoriteOrder"] as? Int,
            order: record["order"] as? Int ?? 0,
            lastPlayed: record["lastPlayed"] as? Date,
            isRecent: record["isRecent"] as? Bool ?? false
        )
    }
    
    /// Fallback to local radio stations when CloudKit fails
    @MainActor
    private func fallbackToLocalRadioStations(_ viewModel: RadioStationViewModel) async {
        radioStationsOperation = "Loading from local storage..."
        radioStationsProgress = 0.5
        
        viewModel.loadStationsFromCoreData()
        
        let localCount = viewModel.stations.count
        radioStationsCurrentCount = localCount
        radioStationsTotalCount = localCount
        radioStationsProgress = 1.0
        
        if localCount > 0 {
            radioStationsOperation = "✅ \(localCount) stations loaded from local storage"
            print("✅ Loaded \(localCount) radio stations from local storage")
        } else {
            radioStationsOperation = "⚠️ No stations available"
            print("⚠️ No radio stations available")
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
        print("🔄 getExpectedPodcastFeedCount: Starting")
        
        // First check local Core Data
        print("🔄 getExpectedPodcastFeedCount: Checking Core Data")
        let localCount = await countExistingPodcastFeeds()
        print("🔄 getExpectedPodcastFeedCount: Local count = \(localCount)")
        
        if localCount > 0 {
            return localCount
        }
        
        // ⚡ OPTIMIZATION: For fresh install, don't wait for CloudKit count - just assume we'll sync
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        if isFreshInstall {
            print("⚡ Fresh install: Skipping CloudKit feed count check, will sync feeds")
            return 10  // Estimate some feeds exist for progress tracking
        }
        
        // If no local feeds, check CloudKit to see if there are feeds to sync (with timeout)
        print("🔄 getExpectedPodcastFeedCount: Checking CloudKit (non-fresh install)")
        let cloudKitCount = await getCloudKitPodcastFeedCount()
        print("🔄 getExpectedPodcastFeedCount: CloudKit count = \(cloudKitCount)")
        
        if cloudKitCount > 0 {
            return cloudKitCount
        }
        
        // If no feeds in local storage or CloudKit, return 0 to prevent banner from showing
        print("🔄 getExpectedPodcastFeedCount: No feeds found, returning 0")
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
    
    /// Create episode snapshots for all loaded feeds for instant access
    private func createEpisodeSnapshotsForAllFeeds(_ podcastViewModel: PodcastViewModel) async {
        // CRITICAL: Always clear old snapshots first to ensure fresh data
        await MainActor.run {
            podcastViewModel.clearAllEpisodeSnapshots()
            print("🗑️ CLEARED: All old episode snapshots to ensure fresh state data")
        }
        
        // CRITICAL: Ensure EpisodeStateManager is ready and has loaded all states
        print("⏳ SNAPSHOT: Ensuring EpisodeStateManager is fully ready...")
        if !EpisodeStateManager.shared.isReady {
            print("⚠️ SNAPSHOT: EpisodeStateManager not ready, waiting...")
            // Wait for it to be ready with longer timeout
            for i in 0..<30 {
                if EpisodeStateManager.shared.isReady {
                    print("✅ SNAPSHOT: EpisodeStateManager became ready after \(i * 100)ms")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
        
        // CRITICAL: Force reload episode states from Core Data to ensure we have latest
        print("🔄 SNAPSHOT: Force reloading episode states from Core Data...")
        await EpisodeStateManager.shared.loadAllStatesFromCoreData()
        
        // Wait a moment for states to be fully loaded
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // CRITICAL FIX: Load episodes from Core Data into memory BEFORE creating snapshots
        print("📡 CRITICAL FIX: Loading episodes from Core Data for all feeds before snapshot creation...")
        var feedsWithLoadedEpisodes: [(PodcastFeed, [PodcastEpisode])] = []
        
        let feeds = await MainActor.run { podcastViewModel.podcastFeeds }
        
        // Load episodes for all feeds using TaskGroup for proper awaiting
        await withTaskGroup(of: (PodcastFeed, [PodcastEpisode]).self) { group in
            for feed in feeds {
                group.addTask {
                    let episodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feed.id)
                    if !episodes.isEmpty {
                        print("📡 Loaded \(episodes.count) episodes from Core Data for feed: \(feed.title)")
                    }
                    return (feed, episodes)
                }
            }
            
            // Collect all results
            for await (feed, episodes) in group {
                if !episodes.isEmpty {
                    feedsWithLoadedEpisodes.append((feed, episodes))
                }
            }
        }
        
        print("📡 Loaded episodes for \(feedsWithLoadedEpisodes.count) feeds from Core Data")
        
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            
            let feedCount = podcastViewModel.podcastFeeds.count
            
            print("📸 Creating episode snapshots for \(feedCount) feeds (\(feedsWithLoadedEpisodes.count) have episodes)...")
            
            // Update snapshot tracking
            self.totalFeedsRequiringSnapshots = feedsWithLoadedEpisodes.count
            self.feedsWithSnapshots = 0
            self.episodeSnapshotsReady = false
            
            var processedFeeds = 0
            
            for (feed, episodes) in feedsWithLoadedEpisodes {
                if !episodes.isEmpty {
                    // 🛡️ CONTAMINATION PREVENTION: Validate all episodes belong to this feed before processing
                    let validEpisodes = episodes.filter { $0.feedId == feed.id }
                    if validEpisodes.count != episodes.count {
                        let contaminatedCount = episodes.count - validEpisodes.count
                        print("🚨 SNAPSHOT CONTAMINATION: Feed '\(feed.title)' has \(contaminatedCount) contaminated episodes - filtering them out")
                        
                        // Log contaminated episodes for debugging
                        let contaminatedEpisodes = episodes.filter { $0.feedId != feed.id }
                        for episode in contaminatedEpisodes.prefix(3) {
                            print("🚨 CONTAMINATED: Episode '\(episode.title)' has feedId '\(episode.feedId)' but is in feed '\(feed.id)'")
                        }
                    }
                    
                    // CRITICAL: Refresh episode states before creating snapshot to ensure they're current
                    
                    // DEBUG: Check EpisodeStateManager state
                    let progressCount = EpisodeStateManager.shared.episodeProgress.count
                    let favoritesCount = EpisodeStateManager.shared.episodeFavorites.count
                    let downloadsCount = EpisodeStateManager.shared.episodeDownloads.count
                    print("📸 SNAPSHOT: EpisodeStateManager Ready=\(EpisodeStateManager.shared.isReady), Progress=\(progressCount), Favorites=\(favoritesCount), Downloads=\(downloadsCount)")
                    
                    let episodesWithCurrentStates = validEpisodes.map { episode in
                        var updatedEpisode = episode
                        
                        // Get current states from EpisodeStateManager
                        let progress = EpisodeStateManager.shared.getProgress(for: episode.id)
                        let isFavorite = EpisodeStateManager.shared.isFavorite(episode.id)
                        let isDownloaded = EpisodeStateManager.shared.isDownloaded(episode.id)
                        let playbackState = EpisodeStateManager.shared.getState(for: episode.id)
                        
                        // Update episode state with current values
                        updatedEpisode.state.progress = progress
                        updatedEpisode.state.isFavorite = isFavorite
                        updatedEpisode.state.isDownloaded = isDownloaded
                        // Note: playbackState is managed separately in EpisodeStateManager, not in EpisodeState struct
                        updatedEpisode.state.isPlayed = (playbackState == .played)
                        
                        return updatedEpisode
                    }
                    
                    // Create snapshot with validated episodes that have current states
                    podcastViewModel.updateEpisodeSnapshot(for: feed.id, episodes: episodesWithCurrentStates)
                    self.feedsWithSnapshots += 1
                    print("📸 Created snapshot for '\(feed.title)' with \(validEpisodes.count) validated episodes with current states (\(self.feedsWithSnapshots)/\(self.totalFeedsRequiringSnapshots))")
                }
                
                processedFeeds += 1
                let progress = 0.6 + (Double(processedFeeds) / Double(feedsWithLoadedEpisodes.count)) * 0.3 // 60% to 90%
                self.episodeStatesProgress = progress
                self.episodeStatesOperation = "Created snapshots for \(self.feedsWithSnapshots)/\(self.totalFeedsRequiringSnapshots) feeds with episodes..."
            }
            
            // Mark snapshots as ready when all feeds with episodes have snapshots
            self.episodeSnapshotsReady = (self.feedsWithSnapshots == self.totalFeedsRequiringSnapshots)
            print("📸 SNAPSHOT READINESS: \(self.feedsWithSnapshots)/\(self.totalFeedsRequiringSnapshots) snapshots created - Ready: \(self.episodeSnapshotsReady)")
        }
    }
    
    /// Create station snapshots for all countries for instant access
    @MainActor
    private func createStationSnapshotsForAllCountries() async {
        let radioViewModel = RadioStationViewModel.shared
        
        print("📸 Creating station snapshots for all countries...")
        
        // Group stations by country
        let countriesWithStations = Dictionary(grouping: radioViewModel.stations) { $0.country }
            .filter { !$0.key.isEmpty && $0.key != "Unknown Region" && $0.key != "Select Country" }
        
        print("📸 Found \(countriesWithStations.count) countries with stations")
        
        // Update snapshot tracking
        totalCountriesRequiringSnapshots = countriesWithStations.count
        countriesWithSnapshots = 0
        stationSnapshotsReady = false
        
        var snapshotsCreated = 0
        var totalStations = 0
        
        for (country, stations) in countriesWithStations {
            // Create snapshot for this country
            radioViewModel.updateStationSnapshot(for: country, stations: stations)
            countriesWithSnapshots += 1
            snapshotsCreated += 1
            totalStations += stations.count
            print("📸 Created station snapshot for '\(country)' with \(stations.count) stations (\(snapshotsCreated)/\(countriesWithStations.count))")
        }
        
        // Mark snapshots as ready
        stationSnapshotsReady = (countriesWithSnapshots == totalCountriesRequiringSnapshots)
        
        print("📸 STATION SNAPSHOT SUMMARY: \(snapshotsCreated) snapshots created with \(totalStations) total stations")
        print("📸 STATION SNAPSHOT READINESS: \(countriesWithSnapshots)/\(totalCountriesRequiringSnapshots) countries have snapshots - Ready: \(stationSnapshotsReady)")
    }
    
    /// Verify that episode data is available and snapshots are created
    private func verifyEpisodeDataAvailability(_ podcastViewModel: PodcastViewModel) async {
        await MainActor.run {
            var totalSnapshots = 0
            var totalEpisodes = 0
            
            for feed in podcastViewModel.podcastFeeds {
                if let snapshot = podcastViewModel.getEpisodeSnapshot(for: feed.id) {
                    totalSnapshots += 1
                    totalEpisodes += snapshot.count
                }
            }
            
            print("🔍 Episode data verification: \(totalSnapshots) snapshots created with \(totalEpisodes) total episodes")
            
            if totalSnapshots > 0 {
                self.episodeStatesOperation = "✅ \(totalSnapshots) feed snapshots ready for instant access"
            } else {
                self.episodeStatesOperation = "⚠️ Episode data verified (no snapshots - feeds may be empty)"
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
    
    /// Force Core Data save to ensure all episode states are persisted
    private func forceEpisodeStateCoreDataSave() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let context = CoreDataStack.shared.context
            context.perform {
                if context.hasChanges {
                    do {
                        try context.save()
                        print("✅ FORCED SAVE: Episode states persisted to Core Data")
                    } catch {
                        print("❌ FORCED SAVE: Failed to save episode states: \(error)")
                    }
                } else {
                    print("ℹ️ FORCED SAVE: No pending episode state changes")
                }
                continuation.resume()
            }
        }
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
    
    /// Test method to manually trigger episode state sync with snapshots
    @MainActor
    func testEpisodeStateSyncWithSnapshots() {
        print("🧪 TEST: Manually triggering episode state sync with snapshot creation")
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
    
    // MARK: - Comprehensive Fresh Install Sync Methods
    
    /// Comprehensive radio stations sync - fetches ALL stations from CloudKit and saves to Core Data
    @MainActor
    private func syncRadioStationsComprehensive() async {
        radioStationsStatus = .inProgress
        radioStationsOperation = "Fetching radio stations from iCloud..."
        radioStationsProgress = 0.0
        radioStationsCurrentCount = 0
        radioStationsTotalCount = 0
        
        print("🔄 🔁 COMPREHENSIVE RADIO SYNC: Starting...")
        
        do {
            let viewModel = RadioStationViewModel.shared
            
            // Always fetch from CloudKit on fresh install
            print("🔄 🔁 Fetching ALL radio stations from CloudKit...")
            radioStationsOperation = "Fetching stations from iCloud..."
            radioStationsProgress = 0.1
            
            // Fetch stations from CloudKit with progress tracking
            await syncRadioStationsFromCloudKitWithProgress()
            
            // Ensure all stations are saved to Core Data
            radioStationsProgress = 0.8
            radioStationsOperation = "Saving stations to local storage..."
            print("🔄 🔁 Ensuring all stations are saved to Core Data...")
            
            // Verify save completion
            radioStationsProgress = 0.9
            radioStationsCurrentCount = await getLocalStationCount()
            radioStationsTotalCount = radioStationsCurrentCount
            
            // Create station snapshots for all countries
            print("🔄 🔁 Creating station snapshots for ALL countries...")
            radioStationsOperation = "Creating station snapshots..."
            await createStationSnapshotsForAllCountries()
            
            // Mark as synced
            UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
            
            radioStationsStatus = .completed
            radioStationsProgress = 1.0
            radioStationsOperation = "✅ \(radioStationsCurrentCount) radio stations synced with snapshots"
            print("✅ 🔁 COMPREHENSIVE RADIO SYNC: Completed - \(radioStationsCurrentCount) stations")
            
        } catch {
            radioStationsStatus = .failed
            radioStationsOperation = "❌ Failed to sync radio stations"
            print("❌ 🔁 COMPREHENSIVE RADIO SYNC: Failed - \(error)")
        }
    }
    
    /// Comprehensive podcast feeds sync - fetches ALL feeds, parses ALL RSS, saves ALL episodes
    @MainActor
    private func syncPodcastFeedsComprehensive() async {
        podcastFeedsStatus = .inProgress
        podcastFeedsOperation = "Fetching podcast feeds from iCloud..."
        podcastFeedsProgress = 0.0
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = 0
        
        print("🔄 📻 COMPREHENSIVE PODCAST SYNC: Starting...")
        
        do {
            let podcastViewModel = PodcastViewModel.shared
            
            // Fetch feeds from CloudKit
            print("🔄 📻 Fetching ALL podcast feeds from CloudKit...")
            podcastFeedsOperation = "Fetching feeds from iCloud..."
            podcastFeedsProgress = 0.1
            
            let cloudKitFeeds = try await syncFromCloudKitWithRetry()
            
            if cloudKitFeeds.isEmpty {
                print("⚠️ 📻 No podcast feeds found in CloudKit - starting with empty library")
                podcastFeedsStatus = .completed
                podcastFeedsProgress = 1.0
                podcastFeedsOperation = "No podcast feeds to sync"
                UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
                return
            }
            
            podcastFeedsTotalCount = cloudKitFeeds.count
            print("🔄 📻 Found \(cloudKitFeeds.count) feeds in CloudKit")
            
            // Clear episode snapshots
            podcastFeedsProgress = 0.2
            podcastFeedsOperation = "Preparing to process feeds..."
            await podcastViewModel.clearAllEpisodeSnapshots()
            
            // Parse ALL RSS feeds and save ALL episodes
            print("🔄 📻 Parsing ALL RSS feeds and saving episodes...")
            podcastFeedsOperation = "Parsing RSS feeds..."
            podcastFeedsProgress = 0.3
            isParsingFeeds = true
            feedParsingProgress = 0.0
            feedParsingMessage = "Processing RSS feeds..."
            
            // Load and parse all feeds
            await podcastViewModel.loadFreshInstallPodcastData(cloudKitFeeds)
            
            // Update progress
            podcastFeedsProgress = 0.7
            podcastFeedsCurrentCount = podcastViewModel.podcastFeeds.count
            podcastFeedsTotalCount = max(podcastFeedsTotalCount, podcastFeedsCurrentCount)
            
            // Apply metadata from CloudKit
            print("🔄 📻 Applying CloudKit metadata to feeds...")
            podcastFeedsOperation = "Applying feed metadata..."
            podcastFeedsProgress = 0.8
            await podcastViewModel.applyCloudKitFeedMetadata(cloudKitFeeds)
            
            // Start artwork downloads in background (don't wait here)
            let finalCount = podcastViewModel.podcastFeeds.count
            startArtworkDownloadTracking(totalFeeds: finalCount)
            
            // Mark as synced
            UserDefaults.standard.set(true, forKey: "HasPodcastFeedsSynced")
            
            podcastFeedsStatus = .completed
            podcastFeedsProgress = 1.0
            podcastFeedsCurrentCount = finalCount
            podcastFeedsOperation = "✅ \(finalCount) podcast feeds synced"
            isParsingFeeds = false
            
            print("✅ 📻 COMPREHENSIVE PODCAST SYNC: Completed - \(finalCount) feeds with all episodes")
            
        } catch {
            podcastFeedsStatus = .failed
            podcastFeedsOperation = "❌ Failed to sync podcast feeds"
            isParsingFeeds = false
            print("❌ 📻 COMPREHENSIVE PODCAST SYNC: Failed - \(error)")
        }
    }
    
    /// Comprehensive episode states sync - fetches ALL episode states from CloudKit
    @MainActor
    private func syncEpisodeStatesComprehensive() async {
        episodeStatesStatus = .inProgress
        episodeStatesOperation = "Syncing episode states from iCloud..."
        episodeStatesProgress = 0.0
        episodeStatesCurrentCount = 0
        episodeStatesTotalCount = 0
        
        print("🔄 📚 COMPREHENSIVE EPISODE STATE SYNC: Starting...")
        
        do {
            let podcastViewModel = PodcastViewModel.shared
            
            // Get all episode IDs from Core Data
            print("🔄 📚 Getting all episode IDs from Core Data...")
            let allEpisodeIds = await podcastViewModel.getAllEpisodeIdsFromCoreData()
            
            if allEpisodeIds.isEmpty {
                print("⚠️ 📚 No episodes found in Core Data - skipping episode state sync")
                episodeStatesStatus = .completed
                episodeStatesProgress = 1.0
                episodeStatesOperation = "No episodes to sync"
                return
            }
            
            episodeStatesTotalCount = allEpisodeIds.count
            print("🔄 📚 Syncing states for \(allEpisodeIds.count) episodes...")
            
            // Start tracking
            await startEpisodeStateSync(totalCount: allEpisodeIds.count)
            
            // Sync from CloudKit
            episodeStatesProgress = 0.2
            episodeStatesOperation = "Fetching episode states from iCloud..."
            print("🔄 📚 Fetching episode states from CloudKit...")
            
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let syncSuccess = await podcastViewModel.syncEpisodeStatesFromCloudKit(isFreshInstall: isFreshInstall)
            
            if syncSuccess {
                episodeStatesProgress = 0.5
                episodeStatesOperation = "Episode states synced from iCloud"
                print("✅ 📚 Episode states synced successfully")
            } else {
                episodeStatesProgress = 0.3
                print("⚠️ 📚 Episode state sync had issues, continuing...")
            }
            
            // CRITICAL: Wait for all Core Data saves to complete
            episodeStatesProgress = 0.6
            episodeStatesOperation = "Ensuring all episode states are saved..."
            print("⏳ 📚 Waiting for all Core Data episode state saves to complete...")
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // CRITICAL: Force Core Data save to ensure all states are persisted
            episodeStatesProgress = 0.7
            episodeStatesOperation = "Persisting episode states to storage..."
            await forceEpisodeStateCoreDataSave()
            
            // Mark as synced
            UserDefaults.standard.set(true, forKey: "HasEpisodeStatesSynced")
            
            episodeStatesStatus = .completed
            episodeStatesProgress = 1.0
            episodeStatesCurrentCount = episodeStatesTotalCount
            episodeStatesOperation = "✅ \(episodeStatesTotalCount) episode states synced"
            
            print("✅ 📚 COMPREHENSIVE EPISODE STATE SYNC: Completed - \(episodeStatesTotalCount) states")
            
        } catch {
            episodeStatesStatus = .failed
            episodeStatesOperation = "❌ Failed to sync episode states"
            print("❌ 📚 COMPREHENSIVE EPISODE STATE SYNC: Failed - \(error)")
        }
    }
    
    /// Create ALL snapshots (both stations and episodes) for instant loading
    @MainActor
    private func createAllSnapshotsComprehensive() async {
        print("🔄 📸 COMPREHENSIVE SNAPSHOT CREATION: Starting...")
        
        currentOperation = "Creating snapshots for instant loading..."
        
        // Create episode snapshots for all feeds
        print("🔄 📸 Creating episode snapshots for all feeds...")
        let podcastViewModel = PodcastViewModel.shared
        await createEpisodeSnapshotsForAllFeeds(podcastViewModel)
        
        // Verify episode snapshots
        await verifyEpisodeSnapshotsAreReady(podcastViewModel)
        
        // Station snapshots already created in syncRadioStationsComprehensive
        // But verify they're ready
        let radioViewModel = RadioStationViewModel.shared
        await verifyStationSnapshotsAreReady(radioViewModel)
        
        print("✅ 📸 COMPREHENSIVE SNAPSHOT CREATION: Completed")
    }
    
    /// Wait for ALL artwork downloads to complete (with generous timeout)
    @MainActor
    private func waitForAllArtworkDownloadsComplete() async {
        print("🔄 🎨 COMPREHENSIVE ARTWORK WAIT: Starting...")
        print("⏳ 🎨 Waiting for all artwork downloads to complete...")
        
        artworkDownloadsOperation = "Waiting for artwork downloads..."
        
        // Much more generous timeout for artwork downloads (60 seconds)
        let maxWaitTime: TimeInterval = 60.0
        let checkInterval: TimeInterval = 1.0
        let maxChecks = Int(maxWaitTime / checkInterval)
        var checks = 0
        
        while artworkDownloadsStatus == .inProgress && checks < maxChecks {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            checks += 1
            
            // Update operation with progress
            if totalArtworkDownloads > 0 {
                artworkDownloadsOperation = "Downloading artwork \(completedArtworkDownloads)/\(totalArtworkDownloads)..."
                print("🎨 Artwork progress: \(completedArtworkDownloads)/\(totalArtworkDownloads) (\(checks * 100 / maxChecks)% of wait time)")
            }
        }
        
        if checks >= maxChecks && artworkDownloadsStatus == .inProgress {
            print("⚠️ 🎨 Artwork download timeout reached - some may still be downloading in background")
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            artworkDownloadsOperation = "Artwork downloads continuing in background"
        } else {
            print("✅ 🎨 All artwork downloads completed: \(completedArtworkDownloads)/\(totalArtworkDownloads)")
            artworkDownloadsStatus = .completed
            artworkDownloadsProgress = 1.0
            artworkDownloadsOperation = "✅ Artwork downloads completed"
        }
        
        print("✅ 🎨 COMPREHENSIVE ARTWORK WAIT: Completed")
    }
    
    /// Comprehensive completion - final verification and UI readiness
    @MainActor
    private func completeSynchronizationComprehensive() async {
        currentOperation = "Finalizing synchronization..."
        
        print("🔄 ✅ COMPREHENSIVE COMPLETION: Starting final verification...")
        
        // Ensure all components are ready
        let podcastViewModel = PodcastViewModel.shared
        let radioViewModel = RadioStationViewModel.shared
        
        // Force final save and reload
        print("🔄 ✅ Forcing final Core Data save and reload...")
        await podcastViewModel.forceSaveAndReload()
        
        // Verify feeds are loaded
        print("🔄 ✅ Verifying podcast feeds are loaded...")
        await podcastViewModel.ensureFeedsAreLoaded()
        await waitForPodcastLoadingToComplete(podcastViewModel)
        await waitForCloudKitInitializationToComplete(podcastViewModel)
        
        // Verify radio stations are loaded
        print("🔄 ✅ Verifying radio stations are loaded...")
        await waitForRadioStationsToLoad(radioViewModel)
        
        // Verify all sync statuses are completed
        print("🔄 ✅ Verifying all sync statuses are completed...")
        await waitForAllSyncStatusesToComplete()
        
        // Verify episode snapshots are ready
        print("🔄 ✅ Verifying episode snapshots are ready...")
        await verifyEpisodeSnapshotsAreReady(podcastViewModel)
        await ensureEpisodeSnapshotsAreCreated(podcastViewModel)
        
        // Verify station snapshots are ready
        print("🔄 ✅ Verifying station snapshots are ready...")
        await verifyStationSnapshotsAreReady(radioViewModel)
        await ensureStationSnapshotsAreCreated(radioViewModel)
        
        // Trigger UI refresh
        print("🔄 ✅ Triggering final UI refresh...")
        await podcastViewModel.ensureFeedsAreLoaded()
        
        // Post notification
        NotificationCenter.default.post(name: NSNotification.Name("FreshInstallDataAvailable"), object: nil)
        print("📢 ✅ Posted fresh install completion notification")
        
        // Wait for UI to process
        print("⏳ ✅ Waiting for UI to process and refresh...")
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds for UI
        
        // Verify UI has been updated
        var verificationAttempts = 0
        let maxVerificationAttempts = 10
        
        while verificationAttempts < maxVerificationAttempts {
            // Check if data is visible
            if podcastViewModel.podcastFeeds.count > 0 && radioViewModel.stations.count > 0 {
                print("✅ ✅ UI data verified - feeds: \(podcastViewModel.podcastFeeds.count), stations: \(radioViewModel.stations.count)")
                break
            }
            
            verificationAttempts += 1
            print("⏳ ✅ UI verification attempt \(verificationAttempts)/\(maxVerificationAttempts)...")
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Mark as completed
        UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
        UserDefaults.standard.set(true, forKey: "DataSyncCompleted")
        
        // Clear fresh install flags
        isFreshInstallSyncInProgress = false
        
        currentOperation = "✅ Synchronization completed!"
        overallProgress = 1.0
        
        // Mark UI as ready
        isFreshInstallUIReady = true
        
        print("🎉 ✅ COMPREHENSIVE COMPLETION: All sync completed successfully!")
        print("🎉 ✅ Fresh install sync is COMPLETE - UI is ready to show")
        
        // CRITICAL: Reset all sync statuses to .none to hide banners after completion
        print("🧹 ✅ Resetting all sync statuses to hide banners...")
        podcastFeedsStatus = .none
        podcastFeedsProgress = 0.0
        podcastFeedsOperation = ""
        podcastFeedsCurrentCount = 0
        podcastFeedsTotalCount = 0
        
        radioStationsStatus = .none
        radioStationsProgress = 0.0
        radioStationsOperation = ""
        radioStationsCurrentCount = 0
        radioStationsTotalCount = 0
        
        episodeStatesStatus = .none
        episodeStatesProgress = 0.0
        episodeStatesOperation = ""
        episodeStatesCurrentCount = 0
        episodeStatesTotalCount = 0
        
        artworkDownloadsStatus = .none
        artworkDownloadsProgress = 0.0
        artworkDownloadsOperation = ""
        artworkDownloadsCurrentCount = 0
        artworkDownloadsTotalCount = 0
        
        userPreferencesStatus = .none
        userPreferencesProgress = 0.0
        userPreferencesOperation = ""
        
        print("✅ ✅ All sync statuses reset - banners will not show")
        
        // Stop syncing
        isSyncing = false
    }
}


