//
//  EpisodeStateManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 11/11/24.
//

// EpisodeStateManager.swift

import Foundation
import Combine
import SwiftUI
import CoreData

/// Structure to track CloudKit sync progress for resumption capability
struct CloudKitSyncProgress: Codable {
    let totalEpisodeIds: [String]
    var processedEpisodeIds: Set<String>
    let startTime: Date
    var lastProgressTime: Date
    let isFreshInstall: Bool
    
    init(totalEpisodeIds: [String], isFreshInstall: Bool) {
        self.totalEpisodeIds = totalEpisodeIds
        self.processedEpisodeIds = Set<String>()
        self.startTime = Date()
        self.lastProgressTime = Date()
        self.isFreshInstall = isFreshInstall
    }
    
    var remainingEpisodeIds: [String] {
        return totalEpisodeIds.filter { !processedEpisodeIds.contains($0) }
    }
    
    var progress: Double {
        guard !totalEpisodeIds.isEmpty else { return 1.0 }
        return Double(processedEpisodeIds.count) / Double(totalEpisodeIds.count)
    }
    
    var isComplete: Bool {
        return processedEpisodeIds.count >= totalEpisodeIds.count
    }
    
    mutating func markEpisodeProcessed(_ episodeId: String) {
        processedEpisodeIds.insert(episodeId)
        lastProgressTime = Date()
    }
}

/// High-performance batch episode data structure for optimized loading
struct EpisodeStateData {
    let progress: Double
    let state: EpisodePlaybackState
    let isFavorite: Bool
    let isDownloaded: Bool
}

enum EpisodePlaybackState: String, Codable, Equatable {
    case new
    case playing
    case inProgress
    case played
    
    var statusText: String {
        switch self {
        case .new: return "New"
        case .playing: return "Playing"
        case .inProgress: return "IN PROGRESS"
        case .played: return "Played"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .new: return .blue // New episodes in blue
        case .playing: return .blue
        case .inProgress: return .orange // In Progress episodes in orange
        case .played: return .gray
        }
    }
    
    var buttonImage: String {
        switch self {
        case .new:
            return "play.circle.fill"
        case .playing:
            return "pause.fill"
        case .inProgress:
            return "play.circle.fill"
        case .played:
            return "arrow.counterclockwise.circle.fill" // Rewind icon for played episodes
        }
    }
    
    var buttonColor: Color {
        switch self {
        case .new:
            return .blue
        case .playing:
            return .blue
        case .inProgress:
            return .orange // Orange color for in progress
        case .played:
            return .gray // Gray color for played episodes
        }
    }
}

struct EpisodeProgress: Codable {
    var state: EpisodePlaybackState
    var progress: Double
    var currentTime: Double?
    var duration: Double?
    
    // Initialize with legacy support
    init(state: EpisodePlaybackState, progress: Double, currentTime: Double? = nil, duration: Double? = nil) {
        self.state = state
        self.progress = progress
        self.currentTime = currentTime
        self.duration = duration
    }
}

class EpisodeStateManager: ObservableObject {
    static let shared = EpisodeStateManager()
    
    // MARK: - Published Properties
    @Published var episodeStates: [String: EpisodePlaybackState] = [:]
    @Published var episodeProgress: [String: Double] = [:]
    @Published var episodeFavorites: [String: Bool] = [:] // New: Track favorite states
    @Published var episodeDownloads: [String: Bool] = [:] // New: Track download states
    
    // MARK: - Private Properties
    private let userDefaults: UserDefaults
    private let isUsingAppGroup: Bool // Track if we're using app group UserDefaults
    private let statesKey = "EpisodeStates"
    private let progressKey = "EpisodeProgress"
    private let favoritesKey = "EpisodeFavorites" // New: Favorites storage key
    private let downloadsKey = "EpisodeDownloads" // New: Downloads storage key
    private let currentlyPlayingKey = "CurrentlyPlayingEpisode"
    
    // UPGRADE PROTECTION: Keys for tracking app version and preventing data loss
    private let appVersionKey = "EpisodeStateManagerAppVersion"
    private let downloadStateBackupKey = "DownloadStateBackup"
    private let lastSuccessfulInitKey = "LastSuccessfulEpisodeStateInit"
    
    private var currentlyPlayingEpisodeId: String?
    private var episodeCurrentTime: [String: Double] = [:]
    
    // Throttled update properties
    private var updateTimer: Timer?
    private let updateDelay: TimeInterval = 0.1
    
    // Periodic backup counter
    private var periodicBackupCounter = 0
    
    // SELECTIVE SYNC: Control when CloudKit syncs happen
    private var deferCloudKitSync = false
    private var pendingCloudKitSyncs: Set<String> = []
    
    // SYNC DEDUPLICATION: Track recent syncs to prevent duplicates
    private var recentSyncs: [String: Double] = [:]
    private let syncDeduplicationWindow: TimeInterval = 0.5 // 0.5 seconds - much shorter to allow real-time syncs
    
    // PERFORMANCE: Control verbose logging during batch operations to reduce CPU usage
    private var isVerboseLoggingEnabled: Bool = false
    
    // EPISODE-SPECIFIC SYNC TIMING: Track real-time sync timing per episode to prevent refresh conflicts
    private var episodeLastRealTimeSyncTime: [String: Double] = [:]
    
    // CLOUDKIT PRIORITY MODE: When enabled, Core Data takes precedence over EpisodeStateManager
    // Used during pull-to-refresh and episode list loading to ensure CloudKit data is immediately visible
    private var cloudKitPriorityMode: Bool = false
    private let cloudKitPriorityQueue = DispatchQueue(label: "com.streamradios.cloudkitPriority", attributes: .concurrent)
    
    // SYNC RESUMPTION: Track CloudKit sync progress
    private var cloudKitSyncProgress: CloudKitSyncProgress?
    private let syncProgressKey = "CloudKitSyncProgress"
    
    // Readiness indicator to help avoid cold-start races
    private(set) var isReady: Bool = false
    
    // Track if we just restored from backup to prevent overwriting
    private var didRestoreFromBackup: Bool = false
    
    // DATA INTEGRITY: Track integrity check timing and results
    private var lastIntegrityCheckTime: Date?
    private var integrityCheckTimer: Timer?
    private let integrityCheckInterval: TimeInterval = 300 // Check every 5 minutes
    private var integrityIssuesFound: Int = 0
    private var integrityChecksPerformed: Int = 0
    
    private init() {
        // Try to use app group UserDefaults, fallback to standard if not available
        if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
            self.userDefaults = appGroupDefaults
            self.isUsingAppGroup = true
            print("✅ EpisodeStateManager: Using app group UserDefaults")
        } else {
            self.userDefaults = UserDefaults.standard
            self.isUsingAppGroup = false
            print("⚠️ EpisodeStateManager: App group not available, using standard UserDefaults")
        }
        
        // UPGRADE PROTECTION: Check for app version changes and migrate data if needed
        // This may set didRestoreFromBackup = true if backup restoration occurs
        handleAppVersionUpgrade()
        
        // CRITICAL CLEANUP: Remove old data from standard UserDefaults to prevent CFPreferences overflow
        cleanupStandardUserDefaults()
        
        // Load currently playing episode synchronously (small, fast operation)
        currentlyPlayingEpisodeId = userDefaults.string(forKey: currentlyPlayingKey)
        
        // PERFORMANCE: Load states asynchronously to avoid blocking app startup
        // Start with empty dictionaries and load in background
        Task.detached(priority: .userInitiated) {
            await self.loadSavedStatesAsync()
        }
        
        setupDebugLogging()
        
        // Mark successful initialization
        userDefaults.set(Date().timeIntervalSince1970, forKey: lastSuccessfulInitKey)
        
        // CRITICAL FIX: Check current UserDefaults size and clean if needed
        checkAndCleanUserDefaultsSize()
        
        // CRITICAL: Setup notification listeners for Core Data recreation events
        setupCoreDataNotificationListeners()
        
        // SYNC RESUMPTION: Load any incomplete sync progress on startup
        loadSyncProgress()
        
        // MIGRATION: Ensure all feeds have unique IDs and episodes are properly connected
        Task.detached(priority: .utility) {
            await self.ensureAllFeedsHaveUniqueIds()
        }
        
        // Mark manager as ready and notify listeners
        self.isReady = true
        NotificationCenter.default.post(name: NSNotification.Name("EpisodeStateManagerReady"), object: nil)
        
        // DATA INTEGRITY: Start periodic integrity checks
        startPeriodicIntegrityChecks()
        
        // Perform initial integrity check after a delay to allow Core Data to fully load
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.performDataIntegrityCheck(reason: "initial_startup")
        }
    }
    
    // MARK: - Core Data Recreation Protection
    
    /// Setup notification listeners for Core Data recreation events
    private func setupCoreDataNotificationListeners() {
        // Listen for Core Data deletion warning
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CoreDataWillBeDeleted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleCoreDataDeletionWarning()
        }
        
        // Listen for Core Data recreation completion
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CoreDataWasRecreated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleCoreDataRecreation()
        }
        
        print("✅ EpisodeStateManager: Core Data recreation notification listeners setup")
    }
    
    /// Handle warning that Core Data is about to be deleted due to migration errors
    private func handleCoreDataDeletionWarning() {
        print("🚨 EpisodeStateManager: Core Data deletion warning received - creating emergency backup")
        
        // Create comprehensive backup before Core Data is wiped
        createEmergencyBackup()
        
        // Force save any pending changes
        saveCurrentStates()
        
        print("💾 EpisodeStateManager: Emergency backup completed before Core Data deletion")
    }
    
    /// Handle notification that Core Data has been recreated
    private func handleCoreDataRecreation() {
        print("🔄 EpisodeStateManager: Core Data recreation detected - attempting data recovery")
        
        // Restore data from emergency backup
        restoreFromEmergencyBackup()
        
        // Re-sync with the new empty Core Data
        saveToCoreData()
        
        print("✅ EpisodeStateManager: Data recovery from Core Data recreation completed")
        
        // Perform integrity check after recreation
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.performDataIntegrityCheck(reason: "after_core_data_recreation")
        }
    }
    
    // MARK: - Data Integrity Verification System
    
    /// Start periodic integrity checks to ensure Core Data, CloudKit, and local memory stay synchronized
    private func startPeriodicIntegrityChecks() {
        // Stop any existing timer
        integrityCheckTimer?.invalidate()
        
        // Create new timer for periodic checks
        integrityCheckTimer = Timer.scheduledTimer(withTimeInterval: integrityCheckInterval, repeats: true) { [weak self] _ in
            self?.performDataIntegrityCheck(reason: "periodic_check")
        }
        
        print("✅ DATA INTEGRITY: Started periodic integrity checks (every \(Int(integrityCheckInterval))s)")
    }
    
    /// Perform comprehensive data integrity check across all storage layers
    /// Compares Core Data, local memory, and validates CloudKit sync status
    func performDataIntegrityCheck(reason: String) {
        // FRESH INSTALL GUARD: Skip integrity checks if there are no episodes
        // This prevents noise on fresh installs where CloudKit may have orphaned data
        let checkContext = CoreDataStack.shared.newBackgroundContext()
        let countRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        countRequest.fetchLimit = 1
        
        do {
            let episodeCount = try checkContext.count(for: countRequest)
            if episodeCount == 0 {
                return // Silently skip - no episodes to check
            }
        } catch {
            // Continue if we can't determine episode count
        }
        
        print("🔍 DATA INTEGRITY CHECK: Starting verification (reason: \(reason))")
        
        integrityChecksPerformed += 1
        lastIntegrityCheckTime = Date()
        
        // DIAGNOSTIC: Log current memory state
        print("📊 MEMORY STATE: Progress=\(episodeProgress.count), Favorites=\(episodeFavorites.count), Downloads=\(episodeDownloads.count), States=\(episodeStates.count)")
        if episodeProgress.count > 0 {
            print("📊 PROGRESS EPISODES: \(Array(episodeProgress.keys.prefix(3)).map { $0.prefix(8) })")
        }
        
        let context = CoreDataStack.shared.newBackgroundContext()
        
        context.perform { [weak self] in
            guard let self = self else { return }
            
            var issuesFound = 0
            var totalEpisodesChecked = 0
            var discrepancies: [String: IntegrityDiscrepancy] = [:]
            
            do {
                // Load all episodes from Core Data
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                let coreDataEpisodes = try context.fetch(fetchRequest)
                
                print("🔍 DATA INTEGRITY: Checking \(coreDataEpisodes.count) Core Data episodes against local memory")
                
                // DIAGNOSTIC: Check for episodes with states in Core Data
                let coreDataEpisodesWithProgress = coreDataEpisodes.filter { $0.progress > 0 }
                if !coreDataEpisodesWithProgress.isEmpty {
                    print("📊 CORE DATA PROGRESS: Found \(coreDataEpisodesWithProgress.count) episodes with progress")
                    for episode in coreDataEpisodesWithProgress.prefix(3) {
                        if let id = episode.id {
                            print("   - \(id.prefix(8)): progress=\(episode.progress)")
                        }
                    }
                }
                
                for episode in coreDataEpisodes {
                    guard let episodeId = episode.id, !episodeId.isEmpty else { continue }
                    
                    totalEpisodesChecked += 1
                    
                    // Compare progress
                    let coreDataProgress = Double(episode.progress)
                    let memoryProgress = self.episodeProgress[episodeId] ?? 0.0
                    
                    if abs(coreDataProgress - memoryProgress) > 0.01 { // Allow 1% tolerance
                        issuesFound += 1
                        discrepancies[episodeId] = IntegrityDiscrepancy(
                            episodeId: episodeId,
                            type: .progressMismatch,
                            coreDataValue: coreDataProgress,
                            memoryValue: memoryProgress,
                            fieldName: "progress"
                        )
                        print("⚠️ INTEGRITY ISSUE: Progress mismatch for \(episodeId.prefix(8)) - CoreData: \(coreDataProgress), Memory: \(memoryProgress)")
                    }
                    
                    // Compare played state
                    let coreDataPlayed = episode.isPlayed
                    let memoryState = self.episodeStates[episodeId]
                    let memoryPlayed = (memoryState == .played)
                    
                    if coreDataPlayed != memoryPlayed {
                        issuesFound += 1
                        discrepancies[episodeId] = IntegrityDiscrepancy(
                            episodeId: episodeId,
                            type: .playedStateMismatch,
                            coreDataValue: coreDataPlayed,
                            memoryValue: memoryPlayed,
                            fieldName: "isPlayed"
                        )
                        print("⚠️ INTEGRITY ISSUE: Played state mismatch for \(episodeId.prefix(8)) - CoreData: \(coreDataPlayed), Memory: \(memoryPlayed)")
                    }
                    
                    // Compare favorite status
                    let coreDataFavorite = episode.isFavorite
                    let memoryFavorite = self.episodeFavorites[episodeId] ?? false
                    
                    if coreDataFavorite != memoryFavorite {
                        issuesFound += 1
                        discrepancies[episodeId] = IntegrityDiscrepancy(
                            episodeId: episodeId,
                            type: .favoriteMismatch,
                            coreDataValue: coreDataFavorite,
                            memoryValue: memoryFavorite,
                            fieldName: "isFavorite"
                        )
                        print("⚠️ INTEGRITY ISSUE: Favorite mismatch for \(episodeId.prefix(8)) - CoreData: \(coreDataFavorite), Memory: \(memoryFavorite)")
                    }
                    
                    // Compare download status
                    let coreDataDownloaded = episode.isDownloaded
                    let memoryDownloaded = self.episodeDownloads[episodeId] ?? false
                    
                    if coreDataDownloaded != memoryDownloaded {
                        issuesFound += 1
                        discrepancies[episodeId] = IntegrityDiscrepancy(
                            episodeId: episodeId,
                            type: .downloadMismatch,
                            coreDataValue: coreDataDownloaded,
                            memoryValue: memoryDownloaded,
                            fieldName: "isDownloaded"
                        )
                        print("⚠️ INTEGRITY ISSUE: Download mismatch for \(episodeId.prefix(8)) - CoreData: \(coreDataDownloaded), Memory: \(memoryDownloaded)")
                    }
                }
                
                // Check for episodes in memory that don't exist in Core Data
                let coreDataEpisodeIds = Set(coreDataEpisodes.compactMap { $0.id })
                let memoryEpisodeIds = Set(self.episodeStates.keys)
                    .union(Set(self.episodeProgress.keys))
                    .union(Set(self.episodeFavorites.keys))
                    .union(Set(self.episodeDownloads.keys))
                
                let orphanedMemoryEpisodes = memoryEpisodeIds.subtracting(coreDataEpisodeIds)
                if !orphanedMemoryEpisodes.isEmpty {
                    issuesFound += orphanedMemoryEpisodes.count
                    print("⚠️ INTEGRITY ISSUE: Found \(orphanedMemoryEpisodes.count) episodes in memory but not in Core Data")
                    for orphanId in orphanedMemoryEpisodes.prefix(5) {
                        print("   - Orphaned episode: \(orphanId.prefix(8))")
                    }
                }
                
                // Report results
                print("📊 DATA INTEGRITY REPORT:")
                print("   - Episodes checked: \(totalEpisodesChecked)")
                print("   - Issues found: \(issuesFound)")
                print("   - Total integrity checks: \(self.integrityChecksPerformed)")
                print("   - Total issues found historically: \(self.integrityIssuesFound + issuesFound)")
                
                self.integrityIssuesFound += issuesFound
                
                // If issues found, reconcile them
                if issuesFound > 0 {
                    print("🔧 DATA INTEGRITY: Attempting to reconcile \(issuesFound) discrepancies")
                    Task { @MainActor in
                        self.reconcileDataInconsistencies(discrepancies: discrepancies)
                    }
                } else {
                    print("✅ DATA INTEGRITY: All data is synchronized correctly")
                }
                
            } catch {
                print("❌ DATA INTEGRITY CHECK FAILED: \(error)")
            }
        }
    }
    
    /// Reconcile data inconsistencies by applying the "source of truth" rule
    /// Memory is considered the source of truth, Core Data is updated to match
    @MainActor
    private func reconcileDataInconsistencies(discrepancies: [String: IntegrityDiscrepancy]) {
        print("🔧 RECONCILIATION: Fixing \(discrepancies.count) data inconsistencies")
        
        var fixedCount = 0
        let context = CoreDataStack.shared.newBackgroundContext()
        
        context.perform {
            for (episodeId, discrepancy) in discrepancies {
                do {
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                    fetchRequest.fetchLimit = 1
                    
                    guard let episode = try context.fetch(fetchRequest).first else {
                        print("⚠️ RECONCILIATION: Episode \(episodeId.prefix(8)) not found in Core Data, skipping")
                        continue
                    }
                    
                    // Apply memory values to Core Data (memory is source of truth)
                    switch discrepancy.type {
                    case .progressMismatch:
                        if let memoryValue = discrepancy.memoryValue as? Double {
                            episode.progress = memoryValue
                            print("✅ RECONCILIATION: Fixed progress for \(episodeId.prefix(8)) - set to \(memoryValue)")
                            fixedCount += 1
                        }
                        
                    case .playedStateMismatch:
                        if let memoryValue = discrepancy.memoryValue as? Bool {
                            episode.isPlayed = memoryValue
                            print("✅ RECONCILIATION: Fixed played state for \(episodeId.prefix(8)) - set to \(memoryValue)")
                            fixedCount += 1
                        }
                        
                    case .favoriteMismatch:
                        if let memoryValue = discrepancy.memoryValue as? Bool {
                            episode.isFavorite = memoryValue
                            print("✅ RECONCILIATION: Fixed favorite for \(episodeId.prefix(8)) - set to \(memoryValue)")
                            fixedCount += 1
                        }
                        
                    case .downloadMismatch:
                        if let memoryValue = discrepancy.memoryValue as? Bool {
                            episode.isDownloaded = memoryValue
                            print("✅ RECONCILIATION: Fixed download status for \(episodeId.prefix(8)) - set to \(memoryValue)")
                            fixedCount += 1
                        }
                    }
                    
                } catch {
                    print("❌ RECONCILIATION ERROR for \(episodeId.prefix(8)): \(error)")
                }
            }
            
            // Save all changes
            if fixedCount > 0 {
                do {
                    try context.save()
                    print("✅ RECONCILIATION COMPLETE: Fixed \(fixedCount) inconsistencies and saved to Core Data")
                    
                    // Sync fixed data to CloudKit
                    Task { @MainActor in
                        for (episodeId, _) in discrepancies.prefix(10) {
                            // Sync the fixed episode to CloudKit
                            self.syncEpisodeStateToCloudKit(episodeId: episodeId)
                        }
                    }
                } catch {
                    print("❌ RECONCILIATION: Failed to save to Core Data: \(error)")
                }
            }
        }
    }
    
    /// Sync a single episode's state to CloudKit after reconciliation
    private func syncEpisodeStateToCloudKit(episodeId: String) {
        guard let feedId = getFeedId(for: episodeId) else {
            print("⚠️ CLOUDKIT SYNC: Cannot sync \(episodeId.prefix(8)) - feedId not found")
            return
        }
        
        let progress = episodeProgress[episodeId] ?? 0.0
        let state = episodeStates[episodeId]
        let isFavorite = episodeFavorites[episodeId] ?? false
        let isDownloaded = episodeDownloads[episodeId] ?? false
        let isPlayed = (state == .played)
        
        // Sync complete episode state to CloudKit
        Task {
            await PodcastCloudKitManager.shared.saveEpisodeState(
                episodeId: episodeId,
                feedId: feedId,
                progress: progress,
                isFavorite: isFavorite,
                isDownloaded: isDownloaded,
                isPlayed: isPlayed
            )
        }
        
        print("☁️ CLOUDKIT SYNC: Synced reconciled state for \(episodeId.prefix(8))")
    }
    
    /// Helper struct to track integrity discrepancies
    private struct IntegrityDiscrepancy {
        let episodeId: String
        let type: DiscrepancyType
        let coreDataValue: Any
        let memoryValue: Any
        let fieldName: String
        
        enum DiscrepancyType {
            case progressMismatch
            case playedStateMismatch
            case favoriteMismatch
            case downloadMismatch
        }
    }
    
    /// Public method to manually trigger integrity check
    func forceIntegrityCheck() {
        print("🔍 MANUAL INTEGRITY CHECK: Forcing immediate verification")
        performDataIntegrityCheck(reason: "manual_trigger")
    }
    
    /// Diagnostic method to investigate missing episode states
    func diagnoseEpisodeStates(for episodeIds: [String]) {
        print("🔬 DIAGNOSTIC: Investigating states for \(episodeIds.count) episodes")
        
        for episodeId in episodeIds.prefix(5) {
            let progress = episodeProgress[episodeId] ?? 0.0
            let isFavorite = episodeFavorites[episodeId] ?? false
            let isDownloaded = episodeDownloads[episodeId] ?? false
            let state = episodeStates[episodeId]
            
            print("🔬 Episode \(episodeId.prefix(8)):")
            print("   - Progress: \(progress)")
            print("   - Favorite: \(isFavorite)")
            print("   - Downloaded: \(isDownloaded)")
            print("   - State: \(state?.rawValue ?? "none")")
            
            // Check Core Data
            let context = CoreDataStack.shared.context
            context.performAndWait {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                if let episode = try? context.fetch(fetchRequest).first {
                    print("   - Core Data Progress: \(episode.progress)")
                    print("   - Core Data Played: \(episode.isPlayed)")
                    print("   - Core Data Favorite: \(episode.isFavorite)")
                    print("   - Core Data Downloaded: \(episode.isDownloaded)")
                } else {
                    print("   ⚠️ NOT FOUND in Core Data")
                }
            }
        }
        
        // Summary
        print("📊 DIAGNOSTIC SUMMARY:")
        print("   - Total episodes in progress dict: \(episodeProgress.count)")
        print("   - Total episodes in favorites dict: \(episodeFavorites.count)")
        print("   - Total episodes in downloads dict: \(episodeDownloads.count)")
        print("   - Total episodes in states dict: \(episodeStates.count)")
    }
    
    /// Create emergency backup of CRITICAL data only to prevent CFPreferences overflow
    private func createEmergencyBackup() {
        // EMERGENCY PERFORMANCE: Move backup creation to background queue to prevent main thread hangs
        Task.detached(priority: .background) {
            let timestamp = Date().timeIntervalSince1970
            
            var emergencyData: [String: Any] = [:]
            
            // CRITICAL FIX: Only backup ESSENTIAL data to prevent CFPreferences 4MB limit
            // Do NOT backup episodeStates or episodeProgress (can be 3829+ episodes = 4MB+)
            // These are already in Core Data and will be restored from there
            let favoritesSnapshot = self.episodeFavorites
            let downloadsSnapshot = self.episodeDownloads
            let playingSnapshot = self.currentlyPlayingEpisodeId
            
            // Only backup critical data that's hard to recover
            emergencyData["episodeFavorites"] = favoritesSnapshot
            emergencyData["episodeDownloads"] = downloadsSnapshot
            emergencyData["currentlyPlaying"] = playingSnapshot
            emergencyData["timestamp"] = timestamp
            emergencyData["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            
            // Store emergency backup
            if let emergencyBackupData = try? JSONSerialization.data(withJSONObject: emergencyData) {
                let backupSize = emergencyBackupData.count
                
                // SAFETY CHECK: Only store if under 1MB to avoid CFPreferences overflow
                guard backupSize < 1_000_000 else {
                    print("⚠️ EpisodeStateManager: Emergency backup too large (\(backupSize) bytes), skipping to prevent CFPreferences overflow")
                    return
                }
                
                // FIXED KEY ONLY: Use single fixed key (overwrites previous backup)
                // This prevents accumulation of timestamped keys that can cause overflow
                self.userDefaults.set(emergencyBackupData, forKey: "CoreDataEmergencyBackup")
                
                // Tertiary backup in iCloud key-value storage if available
                if let iCloudStore = NSUbiquitousKeyValueStore.default as NSUbiquitousKeyValueStore? {
                    iCloudStore.set(emergencyBackupData, forKey: "StreamRadios_EpisodeStates_Emergency")
                    iCloudStore.synchronize()
                }
                
                print("💾 EpisodeStateManager: Created emergency backup (\(backupSize) bytes) with \(favoritesSnapshot.count) favorites, \(downloadsSnapshot.count) downloads")
                
                // CLEANUP: Remove old timestamped emergency backups to prevent accumulation
                // Keep only the fixed "CoreDataEmergencyBackup" key and remove all timestamped ones
                self.cleanupOldEmergencyBackups()
            }
        }
    }
    
    /// Clean up old timestamped emergency backup keys to prevent UserDefaults bloat
    private func cleanupOldEmergencyBackups() {
        var removedCount = 0
        var totalBytesRemoved = 0
        
        // Get all keys from UserDefaults
        if let allKeys = userDefaults.dictionaryRepresentation().keys as? [String] {
            // Remove all timestamped emergency backup keys (EmergencyBackup_<timestamp>)
            // Keep only the fixed "CoreDataEmergencyBackup" key
            for key in allKeys {
                if key.hasPrefix("EmergencyBackup_") {
                    if let data = userDefaults.data(forKey: key) {
                        totalBytesRemoved += data.count
                        userDefaults.removeObject(forKey: key)
                        removedCount += 1
                    }
                }
            }
        }
        
    }
    
    /// Restore CRITICAL data from emergency backup after Core Data recreation
    private func restoreFromEmergencyBackup() {
        // Try restoring from the most recent emergency backup
        guard let emergencyData = userDefaults.data(forKey: "CoreDataEmergencyBackup"),
              let backup = try? JSONSerialization.jsonObject(with: emergencyData) as? [String: Any] else {
            print("⚠️ EpisodeStateManager: No emergency backup found")
            return
        }
        
        print("🔄 EpisodeStateManager: Restoring from emergency backup")
        
        // NOTE: episodeStates and episodeProgress are NOT in emergency backup (too large)
        // These will be restored from Core Data instead
        
        // Restore episode states from old backups (if present for backward compatibility)
        if let statesDict = backup["episodeStates"] as? [String: String] {
            self.episodeStates = statesDict.compactMapValues { EpisodePlaybackState(rawValue: $0) }
            print("🔄 Restored \(self.episodeStates.count) episode states from old backup format")
        }
        
        // Restore episode progress from old backups (if present for backward compatibility)
        if let progressDict = backup["episodeProgress"] as? [String: Double] {
            self.episodeProgress = progressDict
            print("🔄 Restored \(self.episodeProgress.count) progress entries from old backup format")
        }
        
        // Restore CRITICAL data that's in new backup format
        if let favoritesDict = backup["episodeFavorites"] as? [String: Bool] {
            self.episodeFavorites = favoritesDict
            print("🔄 Restored \(self.episodeFavorites.count) favorites from backup")
        }
        
        if let downloadsDict = backup["episodeDownloads"] as? [String: Bool] {
            self.episodeDownloads = downloadsDict
            print("🔄 Restored \(self.episodeDownloads.count) downloads from backup")
        }
        
        if let currentlyPlaying = backup["currentlyPlaying"] as? String {
            self.currentlyPlayingEpisodeId = currentlyPlaying
            print("🔄 Restored currently playing: \(currentlyPlaying)")
        }
        
        print("✅ EpisodeStateManager: Restored \(episodeStates.count) states, \(episodeProgress.count) progress entries from emergency backup")
        
        // Save restored data immediately
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    /// Restore from emergency backup only if current data appears incomplete after upgrade
    private func restoreFromEmergencyBackupIfNeeded() {
        // Check if we have emergency backup
        guard let emergencyData = userDefaults.data(forKey: "CoreDataEmergencyBackup"),
              let backup = try? JSONSerialization.jsonObject(with: emergencyData) as? [String: Any] else {
            print("⚠️ EpisodeStateManager: No emergency backup available for upgrade restoration")
            didRestoreFromBackup = false
            return
        }
        
        // Get backup data counts
        let backupStatesCount = (backup["episodeStates"] as? [String: String])?.count ?? 0
        let backupProgressCount = (backup["episodeProgress"] as? [String: Double])?.count ?? 0
        let backupFavoritesCount = (backup["episodeFavorites"] as? [String: Bool])?.count ?? 0
        let backupDownloadsCount = (backup["episodeDownloads"] as? [String: Bool])?.count ?? 0
        
        let backupTotalCount = backupStatesCount + backupProgressCount + backupFavoritesCount + backupDownloadsCount
        let currentTotalCount = episodeStates.count + episodeProgress.count + episodeFavorites.count + episodeDownloads.count
        
        print("📊 UPGRADE RESTORE CHECK: Current data count: \(currentTotalCount), Backup count: \(backupTotalCount)")
        
        // Restore if backup has data (we're in upgrade scenario)
        // Set flag to prevent Core Data from overwriting restored data
        if backupTotalCount > 0 {
            if currentTotalCount == 0 || (backupTotalCount > currentTotalCount * 2) {
                print("🔄 UPGRADE RESTORE: Restoring from backup - current data appears incomplete")
                restoreFromEmergencyBackup()
                didRestoreFromBackup = true
            } else if backupTotalCount > currentTotalCount {
                // Merge backup data with current data (take the maximum of both)
                print("🔄 UPGRADE MERGE: Merging backup data with current data")
                mergeEmergencyBackup(backup)
                didRestoreFromBackup = true
            } else {
                print("✅ UPGRADE RESTORE: Current data looks complete, no restore needed")
                didRestoreFromBackup = false
            }
        } else {
            didRestoreFromBackup = false
        }
    }
    
    /// Merge emergency backup with current data (keep the maximum of both)
    private func mergeEmergencyBackup(_ backup: [String: Any]) {
        var mergedCount = 0
        
        // Merge episode states
        if let backupStates = backup["episodeStates"] as? [String: String] {
            for (episodeId, stateRaw) in backupStates {
                if episodeStates[episodeId] == nil, let state = EpisodePlaybackState(rawValue: stateRaw) {
                    episodeStates[episodeId] = state
                    mergedCount += 1
                }
            }
        }
        
        // Merge episode progress
        if let backupProgress = backup["episodeProgress"] as? [String: Double] {
            for (episodeId, progress) in backupProgress {
                let currentProgress = episodeProgress[episodeId] ?? 0.0
                if progress > currentProgress {
                    episodeProgress[episodeId] = progress
                    mergedCount += 1
                }
            }
        }
        
        // Merge episode favorites
        if let backupFavorites = backup["episodeFavorites"] as? [String: Bool] {
            for (episodeId, isFavorite) in backupFavorites {
                if episodeFavorites[episodeId] == nil && isFavorite {
                    episodeFavorites[episodeId] = isFavorite
                    mergedCount += 1
                }
            }
        }
        
        // Merge episode downloads
        if let backupDownloads = backup["episodeDownloads"] as? [String: Bool] {
            for (episodeId, isDownloaded) in backupDownloads {
                if episodeDownloads[episodeId] == nil && isDownloaded {
                    episodeDownloads[episodeId] = isDownloaded
                    mergedCount += 1
                }
            }
        }
        
        if mergedCount > 0 {
            print("✅ UPGRADE MERGE: Merged \(mergedCount) items from backup")
            saveCurrentStates()
            sendThrottledUpdate()
        }
    }
    
    // MARK: - Upgrade Protection Methods
    
    /// Handle app version upgrades and migrate data to prevent loss
    private func handleAppVersionUpgrade() {
        guard let infoDictionary = Bundle.main.infoDictionary,
              let currentVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            print("⚠️ EpisodeStateManager: Could not get app version")
            return
        }
        
        let storedVersion = userDefaults.string(forKey: appVersionKey)
        
        if storedVersion == nil {
            // First time running this version or fresh install
            print("🆕 EpisodeStateManager: First run - version \(currentVersion)")
            
            // Check if this is actually an upgrade (has existing episode data)
            if hasExistingEpisodeData() {
                print("🔄 EpisodeStateManager: Detected upgrade scenario - preserving existing data")
                performUpgradeMigration(from: storedVersion, to: currentVersion)
                
                // CRITICAL: Restore from emergency backup if available
                restoreFromEmergencyBackupIfNeeded()
            } else {
                print("🆕 EpisodeStateManager: Fresh install detected")
            }
        } else if storedVersion != currentVersion {
            // App version changed - this is an upgrade
            print("🔄 EpisodeStateManager: App upgraded from \(storedVersion ?? "unknown") to \(currentVersion)")
            performUpgradeMigration(from: storedVersion, to: currentVersion)
            
            // CRITICAL: Restore from emergency backup after upgrade
            restoreFromEmergencyBackupIfNeeded()
            
            // DATA INTEGRITY: Perform immediate check after upgrade to ensure states are preserved
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.performDataIntegrityCheck(reason: "post_upgrade_verification")
            }
        } else {
            print("✅ EpisodeStateManager: Same version (\(currentVersion)) - no migration needed")
        }
        
        // Always update the stored version
        userDefaults.set(currentVersion, forKey: appVersionKey)
    }
    
    /// Check if there's existing episode data to help determine if this is an upgrade
    private func hasExistingEpisodeData() -> Bool {
        // Check multiple sources for existing data
        let hasProgressData = userDefaults.data(forKey: progressKey) != nil
        let hasFavoritesData = userDefaults.data(forKey: favoritesKey) != nil
        let hasDownloadsData = userDefaults.data(forKey: downloadsKey) != nil
        let hasStatesData = userDefaults.data(forKey: statesKey) != nil
        
        // Also check for any legacy keys that might indicate existing data
        let hasLegacyData = userDefaults.dictionaryRepresentation().keys.contains { key in
            key.lowercased().contains("episode") || key.lowercased().contains("podcast")
        }
        
        let hasAnyData = hasProgressData || hasFavoritesData || hasDownloadsData || hasStatesData || hasLegacyData
        
        
        return hasAnyData
    }
    
    /// Perform upgrade migration to preserve download states
    private func performUpgradeMigration(from oldVersion: String?, to newVersion: String) {
        print("🔄 EpisodeStateManager: Performing upgrade migration")
        
        // CRITICAL: Create backup of current download states before any migration
        backupDownloadStates()
        
        // Migrate from different UserDefaults if needed
        migrateFromStandardUserDefaults()
        
        // Restore download states from backup if main data is missing
        restoreDownloadStatesFromBackup()
        
        print("✅ EpisodeStateManager: Upgrade migration completed")
    }
    
    /// Backup current download states to prevent loss
    private func backupDownloadStates() {
        var backupData: [String: Any] = [:]
        
        // Backup all episode-related data (convert Data to base64 strings for JSON serialization)
        if let progressData = userDefaults.data(forKey: progressKey) {
            backupData["progress"] = progressData.base64EncodedString()
        }
        
        if let favoritesData = userDefaults.data(forKey: favoritesKey) {
            backupData["favorites"] = favoritesData.base64EncodedString()
        }
        
        if let downloadsData = userDefaults.data(forKey: downloadsKey) {
            backupData["downloads"] = downloadsData.base64EncodedString()
        }
        
        if let statesData = userDefaults.data(forKey: statesKey) {
            backupData["states"] = statesData.base64EncodedString()
        }
        
        // Store backup with timestamp
        backupData["timestamp"] = Date().timeIntervalSince1970  // Convert Date to TimeInterval for JSON serialization
        backupData["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        if let backupDataEncoded = try? JSONSerialization.data(withJSONObject: backupData) {
            let backupSize = backupDataEncoded.count
            
            // SAFETY CHECK: Only store if under 1MB to avoid CFPreferences overflow
            guard backupSize < 1_000_000 else {
                print("⚠️ EpisodeStateManager: Download state backup too large (\(backupSize) bytes), skipping to prevent CFPreferences overflow")
                print("💾 Download states are safely stored in Core Data - backup not needed")
                return
            }
            
            userDefaults.set(backupDataEncoded, forKey: downloadStateBackupKey)
            print("💾 EpisodeStateManager: Created backup of episode states (\(backupSize) bytes)")
        }
    }
    
    /// Migrate data from standard UserDefaults to app group UserDefaults if needed
    private func migrateFromStandardUserDefaults() {
        // Only migrate if we're using app group UserDefaults but data might be in standard
        guard isUsingAppGroup else { return }
        
        let standardDefaults = UserDefaults.standard
        var migratedCount = 0
        
        // Check each key and migrate if data exists in standard but not in app group
        let keysToMigrate = [progressKey, favoritesKey, downloadsKey, statesKey, currentlyPlayingKey]
        
        for key in keysToMigrate {
            if userDefaults.data(forKey: key) == nil, let data = standardDefaults.data(forKey: key) {
                // SAFETY CHECK: Don't migrate if data is too large (> 1MB)
                guard data.count < 1_000_000 else {
                    print("⚠️ EpisodeStateManager: Skipping migration of \(key) - too large (\(data.count) bytes)")
                    print("💾 Data will be loaded from Core Data instead")
                    // Remove the large data from standard UserDefaults to prevent overflow
                    standardDefaults.removeObject(forKey: key)
                    continue
                }
                
                userDefaults.set(data, forKey: key)
                migratedCount += 1
                print("🔄 EpisodeStateManager: Migrated \(key) from standard to app group UserDefaults (\(data.count) bytes)")
            }
        }
        
        if migratedCount > 0 {
            print("✅ EpisodeStateManager: Migrated \(migratedCount) keys from standard UserDefaults")
        }
    }
    
    /// Clean up old data from standard UserDefaults to prevent CFPreferences 4MB overflow
    private func cleanupStandardUserDefaults() {
        // Only clean up if we're using app group UserDefaults
        guard isUsingAppGroup else {
            print("⚠️ EpisodeStateManager: Not using app group, skipping standard UserDefaults cleanup")
            return
        }
        
        let standardDefaults = UserDefaults.standard
        var removedCount = 0
        var totalBytesRemoved = 0
        
        // CRITICAL: Remove all episode state keys from standard UserDefaults
        let keysToRemove = [progressKey, favoritesKey, downloadsKey, statesKey, downloadStateBackupKey]
        
        for key in keysToRemove {
            if let data = standardDefaults.data(forKey: key) {
                totalBytesRemoved += data.count
                standardDefaults.removeObject(forKey: key)
                removedCount += 1
                print("🗑️ Removed \(key) (\(data.count) bytes) from standard UserDefaults")
            }
        }
        
        // COMPREHENSIVE CLEANUP: Remove ALL app-related keys from standard UserDefaults
        // This prevents CFPreferences overflow even when new data is written
        if let allKeys = standardDefaults.dictionaryRepresentation().keys as? [String] {
            for key in allKeys {
                // Remove emergency backups
                if key.hasPrefix("EmergencyBackup_") || key == "CoreDataEmergencyBackup" {
                    if let data = standardDefaults.data(forKey: key) {
                        totalBytesRemoved += data.count
                        standardDefaults.removeObject(forKey: key)
                        removedCount += 1
                        print("🗑️ Removed emergency backup: \(key) (\(data.count) bytes)")
                    }
                }
                // Remove RSS refresh timestamps (should be in app group)
                else if key.hasPrefix("LastRSSRefresh_") {
                    standardDefaults.removeObject(forKey: key)
                    removedCount += 1
                    print("🗑️ Removed RSS timestamp: \(key)")
                }
                // Remove download backups
                else if key.hasPrefix("DownloadBackup_") {
                    if let data = standardDefaults.data(forKey: key) {
                        totalBytesRemoved += data.count
                        standardDefaults.removeObject(forKey: key)
                        removedCount += 1
                        print("🗑️ Removed download backup: \(key) (\(data.count) bytes)")
                    }
                }
                // Remove any large data objects (> 1KB) that shouldn't be in standard UserDefaults
                else if let data = standardDefaults.data(forKey: key), data.count > 1024 {
                    totalBytesRemoved += data.count
                    standardDefaults.removeObject(forKey: key)
                    removedCount += 1
                    print("🗑️ Removed large data: \(key) (\(data.count) bytes)")
                }
            }
        }
        
        if removedCount > 0 {
            print("✅ CLEANUP: Removed \(removedCount) keys (\(totalBytesRemoved) bytes total) from standard UserDefaults to prevent overflow")
            print("💾 All app data is now safely stored in app group UserDefaults and Core Data")
        } else {
            print("✅ CLEANUP: Standard UserDefaults is already clean - no episode data found")
        }
    }
    
    /// Restore download states from backup if main data is missing
    private func restoreDownloadStatesFromBackup() {
        // Check if current download data is missing but backup exists
        guard userDefaults.data(forKey: downloadsKey) == nil,
              let backupData = userDefaults.data(forKey: downloadStateBackupKey),
              let backup = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any] else {
            return
        }
        
        print("🔄 EpisodeStateManager: Restoring download states from backup")
        
        // Restore each data type from backup (convert from base64 strings back to Data)
        // SAFETY CHECK: Only restore if data is reasonable size (< 500KB per key)
        if let progressString = backup["progress"] as? String,
           let progressData = Data(base64Encoded: progressString) {
            if progressData.count < 500_000 {
                userDefaults.set(progressData, forKey: progressKey)
            } else {
                print("⚠️ Skipping progress restore - too large (\(progressData.count) bytes)")
            }
        }
        
        if let favoritesString = backup["favorites"] as? String,
           let favoritesData = Data(base64Encoded: favoritesString) {
            if favoritesData.count < 500_000 {
                userDefaults.set(favoritesData, forKey: favoritesKey)
            } else {
                print("⚠️ Skipping favorites restore - too large (\(favoritesData.count) bytes)")
            }
        }
        
        if let downloadsString = backup["downloads"] as? String,
           let downloadsData = Data(base64Encoded: downloadsString) {
            if downloadsData.count < 500_000 {
                userDefaults.set(downloadsData, forKey: downloadsKey)
                print("✅ EpisodeStateManager: Restored download states from backup (\(downloadsData.count) bytes)")
            } else {
                print("⚠️ Skipping downloads restore - too large (\(downloadsData.count) bytes)")
            }
        }
        
        if let statesString = backup["states"] as? String,
           let statesData = Data(base64Encoded: statesString) {
            if statesData.count < 500_000 {
                userDefaults.set(statesData, forKey: statesKey)
            } else {
                print("⚠️ Skipping states restore - too large (\(statesData.count) bytes)")
            }
        }
        
        print("💾 All episode data will be loaded from Core Data if backup was too large")
    }
    
    /// Check if this is a definite upgrade scenario (not fresh install)
    func isUpgradeScenario() -> Bool {
        // Multiple indicators that this is an upgrade:
        // 1. Has existing episode data
        // 2. Has app version stored (ran before)
        // 3. Has successful initialization timestamp
        // 4. Has Core Data with episodes
        
        let hasStoredVersion = userDefaults.string(forKey: appVersionKey) != nil
        let hasInitTimestamp = userDefaults.object(forKey: lastSuccessfulInitKey) != nil
        let hasEpisodeData = hasExistingEpisodeData()
        
        let isUpgrade = hasStoredVersion || hasInitTimestamp || hasEpisodeData
        
        return isUpgrade
    }
    
    // MARK: - CloudKit Priority Mode Methods
    
    /// Enable CloudKit priority mode - Core Data takes precedence over EpisodeStateManager
    /// Used during pull-to-refresh and episode list loading
    func enableCloudKitPriorityMode() {
        cloudKitPriorityQueue.async(flags: .barrier) {
            self.cloudKitPriorityMode = true
            print("☁️ 🔄 CLOUDKIT PRIORITY: Enabled - Core Data will take precedence during episode loading")
        }
    }
    
    /// Disable CloudKit priority mode - return to normal EpisodeStateManager priority
    func disableCloudKitPriorityMode() {
        cloudKitPriorityQueue.async(flags: .barrier) {
            self.cloudKitPriorityMode = false
        }
    }
    
    /// Check if CloudKit priority mode is enabled (thread-safe)
    func isCloudKitPriorityMode() -> Bool {
        return cloudKitPriorityQueue.sync {
            return cloudKitPriorityMode
        }
    }
    
    // MARK: - Public Methods
    
    /// Async version of loadSavedStates for background loading during app startup
    private func loadSavedStatesAsync() async {
        // CRITICAL FIX: If we just restored from backup, merge Core Data instead of replacing
        if didRestoreFromBackup {
            print("🔄 UPGRADE LOAD: Backup was restored, merging Core Data (not replacing)")
            await loadFromCoreDataAndMergeAsync()
        } else {
            // Normal startup: Load from Core Data asynchronously
            print("💾 NORMAL LOAD: Loading states from Core Data asynchronously")
            await loadFromCoreDataAsync()
            
            // Check if Core Data loading failed and we need to restore from emergency backup
            if episodeStates.isEmpty && episodeProgress.isEmpty && hasEmergencyBackup() {
                print("🚨 EpisodeStateManager: Core Data appears empty but emergency backup exists - attempting recovery")
                restoreFromEmergencyBackup()
            }
        }
        
        // Sync download states from Core Data after loading
        syncDownloadStatesFromCoreData()
        
        print("✅ EpisodeStateManager: Async state loading completed")
    }
    
    /// Check if emergency backup exists
    private func hasEmergencyBackup() -> Bool {
        return userDefaults.data(forKey: "CoreDataEmergencyBackup") != nil
    }
    
    /// Load episode states from Core Data asynchronously (performance optimized)
    /// PERFORMANCE: Async loading prevents blocking app startup with large episode counts
    private func loadFromCoreDataAsync() async {
        let context = CoreDataStack.shared.context
        
        var loadedProgress: [String: Double] = [:]
        var loadedFavorites: [String: Bool] = [:]
        var loadedDownloads: [String: Bool] = [:]
        var loadedStates: [String: EpisodePlaybackState] = [:]
        
        // PERFORMANCE: Use async perform to avoid blocking app startup
        // States will load in background and be available when needed
        await context.perform {
            do {
                // CRITICAL FIX: Fetch ALL episodes, not just those with state data
                // The contamination fixes may have reset some state flags
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                // Remove the restrictive predicate to load all episodes
                
                let episodes = try context.fetch(fetchRequest)
                
                var progressCount = 0
                var favoritesCount = 0
                var downloadsCount = 0
                var playedCount = 0
                
                for episode in episodes {
                    guard let episodeId = episode.id, !episodeId.isEmpty else { 
                        continue 
                    }
                    
                    // Load progress (check for any progress > 0)
                    if episode.progress > 0 {
                        loadedProgress[episodeId] = Double(episode.progress)
                        progressCount += 1
                    }
                    
                    // Load favorites
                    if episode.isFavorite {
                        loadedFavorites[episodeId] = true
                        favoritesCount += 1
                    }
                    
                    // Load downloads
                    if episode.isDownloaded {
                        loadedDownloads[episodeId] = true
                        downloadsCount += 1
                    }
                    
                    // Load played state - prioritize explicit isPlayed over progress calculation
                    if episode.isPlayed {
                        loadedStates[episodeId] = .played
                        playedCount += 1
                    } else if episode.progress >= 1.0 {
                        // Episode completed but not explicitly marked as played - mark it
                        loadedStates[episodeId] = .played
                        playedCount += 1
                    } else if episode.progress > 0 {
                        loadedStates[episodeId] = .inProgress
                    }
                }
                
            } catch {
                print("❌ EpisodeStateManager: Failed to load from Core Data: \(error)")
                // Continue with empty dictionaries for fallback loading
            }
        }
        
        // Update in-memory dictionaries on main actor for thread safety
        await MainActor.run {
            self.episodeProgress = loadedProgress
            self.episodeFavorites = loadedFavorites
            self.episodeDownloads = loadedDownloads
            self.episodeStates = loadedStates
        }
        
        print("✅ EpisodeStateManager: Loaded from Core Data asynchronously - Progress: \(loadedProgress.count), Favorites: \(loadedFavorites.count), Downloads: \(loadedDownloads.count), States: \(loadedStates.count)")
        
        // CRITICAL FIX: Clean up orphaned states (states for episodes that no longer exist in Core Data)
        // This prevents displaying "ghost" states after app upgrades when episodes are removed
        Task.detached(priority: .utility) {
            await self.cleanupOrphanedStates()
        }
        
        // Fallback: If no Core Data found, try loading from UserDefaults (for migration)
        if loadedProgress.isEmpty && loadedFavorites.isEmpty && loadedDownloads.isEmpty {
            print("🔄 EpisodeStateManager: No Core Data found, trying UserDefaults fallback")
            self.loadFromUserDefaultsAsFallback()
        }
    }
    
    /// Clean up orphaned episode states - states for episodes that no longer exist in Core Data
    /// This prevents "ghost" favorites/progress from old episodes showing up after upgrades
    private func cleanupOrphanedStates() async {
        let context = CoreDataStack.shared.newBackgroundContext()
        
        var validEpisodeIds = Set<String>()
        await context.perform {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.propertiesToFetch = ["id"]
            
            do {
                let episodes = try context.fetch(fetchRequest)
                validEpisodeIds = Set(episodes.compactMap { $0.id })
            } catch {
                print("❌ ORPHAN CLEANUP: Failed to fetch episode IDs: \(error)")
            }
        }
        
        // An empty store means Core Data was reset, not that every episode is an orphan.
        guard !validEpisodeIds.isEmpty else {
            print("⚠️ ORPHAN CLEANUP: No episodes in Core Data - skipping to avoid wiping recoverable state")
            return
        }
        
        print("🧹 ORPHAN CLEANUP: Found \(validEpisodeIds.count) valid episodes in Core Data")
        
        await MainActor.run {
            // Keep anything the user actually did - the episode may come back on a later refresh.
            let isOrphan: (String) -> Bool = { episodeId in
                guard !validEpisodeIds.contains(episodeId) else { return false }
                let hasProgress = (self.episodeProgress[episodeId] ?? 0) > 0
                let isFavorite = self.episodeFavorites[episodeId] ?? false
                let isDownloaded = self.episodeDownloads[episodeId] ?? false
                let wasPlayed = self.episodeStates[episodeId] == .played
                return !hasProgress && !isFavorite && !isDownloaded && !wasPlayed
            }
            
            let before = self.episodeProgress.count + self.episodeFavorites.count
                + self.episodeDownloads.count + self.episodeStates.count
            
            self.episodeProgress = self.episodeProgress.filter { !isOrphan($0.key) }
            self.episodeFavorites = self.episodeFavorites.filter { !isOrphan($0.key) }
            self.episodeDownloads = self.episodeDownloads.filter { !isOrphan($0.key) }
            self.episodeStates = self.episodeStates.filter { !isOrphan($0.key) }
            
            let removed = before - (self.episodeProgress.count + self.episodeFavorites.count
                + self.episodeDownloads.count + self.episodeStates.count)
            
            if removed > 0 {
                print("🧹 ORPHAN CLEANUP: Removed \(removed) orphaned entries with no user data")
            } else {
                print("✅ ORPHAN CLEANUP: No orphaned states found - all episode states are valid")
            }
        }
    }
    
    /// Load episode states from Core Data and MERGE with existing restored backup data
    /// Used after backup restoration to avoid overwriting restored data
    private func loadFromCoreDataAndMerge() {
        let context = CoreDataStack.shared.context
        
        var coreDataProgress: [String: Double] = [:]
        var coreDataFavorites: [String: Bool] = [:]
        var coreDataDownloads: [String: Bool] = [:]
        var coreDataStates: [String: EpisodePlaybackState] = [:]
        
        context.performAndWait {
            do {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                let episodes = try context.fetch(fetchRequest)
                print("💾 MERGE LOAD: Found \(episodes.count) episodes in Core Data to merge")
                
                for episode in episodes {
                    guard let episodeId = episode.id, !episodeId.isEmpty else { continue }
                    
                    // Collect Core Data values
                    if episode.progress > 0 {
                        coreDataProgress[episodeId] = Double(episode.progress)
                    }
                    if episode.isFavorite {
                        coreDataFavorites[episodeId] = true
                    }
                    if episode.isDownloaded {
                        coreDataDownloads[episodeId] = true
                    }
                    if episode.isPlayed {
                        coreDataStates[episodeId] = .played
                    } else if episode.progress >= 1.0 {
                        coreDataStates[episodeId] = .played
                    } else if episode.progress > 0 {
                        coreDataStates[episodeId] = .inProgress
                    }
                }
            } catch {
                print("❌ MERGE LOAD: Failed to load from Core Data: \(error)")
            }
        }
        
        // MERGE: Take maximum of both sources (never lose data)
        var mergedCount = 0
        
        // Merge progress - take maximum
        for (episodeId, coreProgress) in coreDataProgress {
            let existingProgress = self.episodeProgress[episodeId] ?? 0.0
            if coreProgress > existingProgress {
                self.episodeProgress[episodeId] = coreProgress
                mergedCount += 1
            }
        }
        
        // Merge favorites - keep any true values
        for (episodeId, isFavorite) in coreDataFavorites {
            if isFavorite && (self.episodeFavorites[episodeId] == nil || !self.episodeFavorites[episodeId]!) {
                self.episodeFavorites[episodeId] = true
                mergedCount += 1
            }
        }
        
        // Merge downloads - keep any true values
        for (episodeId, isDownloaded) in coreDataDownloads {
            if isDownloaded && (self.episodeDownloads[episodeId] == nil || !self.episodeDownloads[episodeId]!) {
                self.episodeDownloads[episodeId] = true
                mergedCount += 1
            }
        }
        
        // Merge states - prioritize played over in-progress
        for (episodeId, coreState) in coreDataStates {
            let existingState = self.episodeStates[episodeId]
            if existingState == nil || (coreState == .played && existingState != .played) {
                self.episodeStates[episodeId] = coreState
                mergedCount += 1
            }
        }
        
        print("✅ MERGE COMPLETE: Merged \(mergedCount) items from Core Data with restored backup")
        print("📊 FINAL COUNTS: Progress=\(self.episodeProgress.count), Favorites=\(self.episodeFavorites.count), Downloads=\(self.episodeDownloads.count), States=\(self.episodeStates.count)")
    }
    
    /// Async version: Load episode states from Core Data and MERGE with existing restored backup data
    /// Used after backup restoration to avoid overwriting restored data
    private func loadFromCoreDataAndMergeAsync() async {
        let context = CoreDataStack.shared.context
        
        var coreDataProgress: [String: Double] = [:]
        var coreDataFavorites: [String: Bool] = [:]
        var coreDataDownloads: [String: Bool] = [:]
        var coreDataStates: [String: EpisodePlaybackState] = [:]
        
        await context.perform {
            do {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                let episodes = try context.fetch(fetchRequest)
                print("💾 MERGE LOAD: Found \(episodes.count) episodes in Core Data to merge")
                
                for episode in episodes {
                    guard let episodeId = episode.id, !episodeId.isEmpty else { continue }
                    
                    // Collect Core Data values
                    if episode.progress > 0 {
                        coreDataProgress[episodeId] = Double(episode.progress)
                    }
                    if episode.isFavorite {
                        coreDataFavorites[episodeId] = true
                    }
                    if episode.isDownloaded {
                        coreDataDownloads[episodeId] = true
                    }
                    if episode.isPlayed {
                        coreDataStates[episodeId] = .played
                    } else if episode.progress >= 1.0 {
                        coreDataStates[episodeId] = .played
                    } else if episode.progress > 0 {
                        coreDataStates[episodeId] = .inProgress
                    }
                }
            } catch {
                print("❌ MERGE LOAD: Failed to load from Core Data: \(error)")
            }
        }
        
        // MERGE: Take maximum of both sources (never lose data) - on main actor
        await MainActor.run {
            var mergedCount = 0
            
            // Merge progress - take maximum
            for (episodeId, coreProgress) in coreDataProgress {
                let existingProgress = self.episodeProgress[episodeId] ?? 0.0
                if coreProgress > existingProgress {
                    self.episodeProgress[episodeId] = coreProgress
                    mergedCount += 1
                }
            }
            
            // Merge favorites - keep any true values
            for (episodeId, isFavorite) in coreDataFavorites {
                if isFavorite && (self.episodeFavorites[episodeId] == nil || !self.episodeFavorites[episodeId]!) {
                    self.episodeFavorites[episodeId] = true
                    mergedCount += 1
                }
            }
            
            // Merge downloads - keep any true values
            for (episodeId, isDownloaded) in coreDataDownloads {
                if isDownloaded && (self.episodeDownloads[episodeId] == nil || !self.episodeDownloads[episodeId]!) {
                    self.episodeDownloads[episodeId] = true
                    mergedCount += 1
                }
            }
            
            // Merge states - prioritize played over in-progress
            for (episodeId, coreState) in coreDataStates {
                let existingState = self.episodeStates[episodeId]
                if existingState == nil || (coreState == .played && existingState != .played) {
                    self.episodeStates[episodeId] = coreState
                    mergedCount += 1
                }
            }
            
            print("✅ MERGE COMPLETE: Merged \(mergedCount) items from Core Data with restored backup")
            print("📊 FINAL COUNTS: Progress=\(self.episodeProgress.count), Favorites=\(self.episodeFavorites.count), Downloads=\(self.episodeDownloads.count), States=\(self.episodeStates.count)")
        }
    }
    
    /// Fallback method to load from UserDefaults (for migration from old data)
    private func loadFromUserDefaultsAsFallback() {
        print("🔄 EpisodeStateManager: Loading from UserDefaults as fallback")
        
        // Load episode states
        if let statesData = userDefaults.data(forKey: statesKey),
           let decodedStates = try? JSONDecoder().decode([String: String].self, from: statesData) {
            self.episodeStates = decodedStates.compactMapValues { EpisodePlaybackState(rawValue: $0) }
            print("✅ EpisodeStateManager: Loaded \(episodeStates.count) episode states from UserDefaults")
        }
        
        // Load episode progress
        if let progressData = userDefaults.data(forKey: progressKey),
           let decodedProgress = try? JSONDecoder().decode([String: Double].self, from: progressData) {
            self.episodeProgress = decodedProgress
            print("✅ EpisodeStateManager: Loaded \(episodeProgress.count) episode progress entries from UserDefaults")
        }
        
        // Load episode favorites
        if let favoritesData = userDefaults.data(forKey: favoritesKey),
           let decodedFavorites = try? JSONDecoder().decode([String: Bool].self, from: favoritesData) {
            self.episodeFavorites = decodedFavorites
            print("✅ EpisodeStateManager: Loaded \(episodeFavorites.count) episode favorites from UserDefaults")
        }
        
        // Load episode downloads
        if let downloadsData = userDefaults.data(forKey: downloadsKey),
           let decodedDownloads = try? JSONDecoder().decode([String: Bool].self, from: downloadsData) {
            self.episodeDownloads = decodedDownloads
            print("✅ EpisodeStateManager: Loaded \(episodeDownloads.count) episode downloads from UserDefaults")
        }
        
        // UPGRADE PROTECTION: Recover any missing download states from backups
        if episodeDownloads.isEmpty || isUpgradeScenario() {
            print("🔄 EpisodeStateManager: Attempting to recover download states from backups")
            restoreDownloadStatesFromBackup()
            recoverDownloadStatesFromIndividualBackups()
        }
        
        // If we loaded from UserDefaults, immediately migrate to Core Data
        if !episodeProgress.isEmpty || !episodeFavorites.isEmpty || !episodeDownloads.isEmpty {
            print("🔄 EpisodeStateManager: Migrating UserDefaults data to Core Data")
            saveToCoreData()
        }
    }
    
    private func saveCurrentStates() {
        // CRITICAL FIX: Save to Core Data instead of UserDefaults to prevent CFPreferences overflow
        saveToCoreData()
        
        // Save currently playing episode to UserDefaults (small data, safe)
        if let playingId = currentlyPlayingEpisodeId {
            userDefaults.set(playingId, forKey: currentlyPlayingKey)
        } else {
            userDefaults.removeObject(forKey: currentlyPlayingKey)
        }
        
        // CRITICAL: Create emergency backup periodically to survive Core Data recreation
        createPeriodicEmergencyBackup()
        
        // DATA INTEGRITY: Perform integrity check every 100 saves
        if periodicBackupCounter % 100 == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.performDataIntegrityCheck(reason: "after_100_saves")
            }
        }
        
        // Send throttled notification about state changes
        sendThrottledUpdate()
    }
    
    /// Create emergency backup periodically to prevent data loss during app updates
    private func createPeriodicEmergencyBackup() {
        // Use instance property instead of static to avoid Swift compilation error
        periodicBackupCounter += 1
        
        // UPGRADE PROTECTION: Create backup more frequently to prevent data loss during app updates
        // Backup every 50 saves (was 500) to ensure recent changes are captured before updates
        if periodicBackupCounter % 50 == 0 {
            createEmergencyBackup()
            print("💾 PERIODIC BACKUP: Created emergency backup (backup #\(periodicBackupCounter / 50))")
        }
    }
    
    /// Force create emergency backup (for app lifecycle events)
    func forceCreateEmergencyBackup() {
        print("🚨 FORCED BACKUP: Creating emergency backup for app lifecycle event")
        createEmergencyBackup()
    }
    
    /// Helper method to get feedId for an episode (needed for CloudKit sync)
    /// Get feedId for episode from Core Data with enhanced lookup and repair functionality
    /// Thread-safe: Uses background context to prevent concurrent access issues
    private func getFeedId(for episodeId: String) -> String? {
        var result: String?
        let context = CoreDataStack.shared.newBackgroundContext()
        
        context.performAndWait {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
            fetchRequest.propertiesToFetch = ["feedId", "feed"] // Fetch feedId and relationship
            fetchRequest.fetchLimit = 1
            
            do {
                if let episode = try context.fetch(fetchRequest).first {
                    // First try to get feedId from the stored property
                    if let directFeedId = episode.feedId, !directFeedId.isEmpty {
                        result = directFeedId
                        print("📡 ✅ CORE DATA LOOKUP: Found feedId \(directFeedId) for episode \(episodeId)")
                    } 
                    // If no direct feedId, try to get from feed relationship
                    else if let feedRelation = episode.feed, let relationFeedId = feedRelation.id, !relationFeedId.isEmpty {
                        result = relationFeedId
                        print("📡 🔧 RELATIONSHIP LOOKUP: Found feedId \(relationFeedId) via relationship for episode \(episodeId)")
                        
                        // Repair the feedId property
                        episode.feedId = relationFeedId
                        try context.save()
                        print("📡 ✅ REPAIR: Fixed missing feedId property for episode \(episodeId)")
                    }
                    // If still no feedId, try to find by URL pattern matching
                    else if let audioUrl = episode.audioUrl {
                        result = attemptFeedIdRecovery(for: episodeId, audioUrl: audioUrl, context: context)
                        if let recoveredFeedId = result {
                            episode.feedId = recoveredFeedId
                            try context.save()
                            print("📡 ✅ RECOVERY: Recovered and assigned feedId \(recoveredFeedId) for episode \(episodeId)")
                        }
                    }
                }
            } catch {
                print("❌ EpisodeStateManager: Failed to fetch feedId for episode \(episodeId): \(error)")
            }
        }
        
        if result == nil {
            print("📡 ❌ FEEDID LOOKUP FAILED: Could not find feedId for episode \(episodeId) in Core Data")
            
            // Trigger a migration check to ensure all feeds have proper GUIDs
            Task.detached(priority: .utility) {
                await self.ensureAllFeedsHaveUniqueIds()
            }
        }
        
        return result
    }
    
    /// Attempt to recover feedId by matching episode audio URL pattern with known feeds
    private func attemptFeedIdRecovery(for episodeId: String, audioUrl: String, context: NSManagedObjectContext) -> String? {
        // Extract domain or podcast identifier from audio URL
        guard let url = URL(string: audioUrl) else { return nil }
        let host = url.host ?? ""
        
        let feedFetchRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
        
        do {
            let allFeeds = try context.fetch(feedFetchRequest)
            
            // Try to match by URL domain/pattern
            for feed in allFeeds {
                if let feedUrl = feed.url {
                    let feedUrlComponents = URL(string: feedUrl)
                    let feedHost = feedUrlComponents?.host ?? ""
                    
                    // If hosts match, this is likely the correct feed
                    if !host.isEmpty && host == feedHost {
                        print("📡 🔧 URL RECOVERY: Matched episode \(episodeId) to feed \(feed.id ?? "unknown") via URL host: \(host)")
                        return feed.id
                    }
                    
                    // Also check if audio URL contains feed URL as substring
                    if audioUrl.contains(feedUrl) || feedUrl.contains(audioUrl.components(separatedBy: "/").dropLast().joined(separator: "/")) {
                        print("📡 🔧 URL RECOVERY: Matched episode \(episodeId) to feed \(feed.id ?? "unknown") via URL pattern")
                        return feed.id
                    }
                }
            }
            
            // If no URL match, assign to the first available feed (last resort)
            if let firstFeed = allFeeds.first, let firstFeedId = firstFeed.id {
                print("📡 ⚠️ FALLBACK RECOVERY: Assigned episode \(episodeId) to feed \(firstFeedId) as fallback")
                return firstFeedId
            }
            
        } catch {
            print("❌ Failed to recover feedId for episode \(episodeId): \(error)")
        }
        
        return nil
    }
    
    /// Ensure all feeds have unique GUID IDs and all episodes are properly connected to feeds
    private func ensureAllFeedsHaveUniqueIds() async {
        await withCheckedContinuation { continuation in
            let context = CoreDataStack.shared.newBackgroundContext()
            
            context.perform {
                do {
                    // 1. Fix all feeds without proper IDs
                    let feedRequest: NSFetchRequest<FeedModel> = FeedModel.fetchRequest()
                    let allFeeds = try context.fetch(feedRequest)
                    
                    var feedsFixed = 0
                    for feed in allFeeds {
                        if feed.id == nil || feed.id!.isEmpty {
                            let newId = UUID().uuidString
                            feed.id = newId
                            feedsFixed += 1
                        }
                    }
                    
                    // 2. Fix all episodes without proper feedId connections
                    let episodeRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    let allEpisodes = try context.fetch(episodeRequest)
                    
                    var episodesFixed = 0
                    for episode in allEpisodes {
                        var needsRepair = false
                        
                        // Check if episode has no feedId or empty feedId
                        if episode.feedId == nil || episode.feedId!.isEmpty {
                            needsRepair = true
                        }
                        
                        if needsRepair {
                            // Try to get feedId from relationship
                            if let feedRelation = episode.feed, let relationFeedId = feedRelation.id {
                                episode.feedId = relationFeedId
                                episodesFixed += 1
                            }
                            // If no relationship, try URL pattern matching
                            else if let audioUrl = episode.audioUrl {
                                if let recoveredFeedId = self.attemptFeedIdRecovery(for: episode.id ?? "", audioUrl: audioUrl, context: context) {
                                    episode.feedId = recoveredFeedId
                                    
                                    // Also set the relationship if possible
                                    let feedToConnect = allFeeds.first { $0.id == recoveredFeedId }
                                    episode.feed = feedToConnect
                                    
                                    episodesFixed += 1
                                }
                            }
                            // Last resort: assign to first available feed
                            else if let firstFeed = allFeeds.first, let firstFeedId = firstFeed.id {
                                episode.feedId = firstFeedId
                                episode.feed = firstFeed
                                episodesFixed += 1
                            }
                        }
                    }
                    
                    // 3. Save all changes
                    if feedsFixed > 0 || episodesFixed > 0 {
                        try context.save()
                    }
                    
                } catch {
                    print("❌ MIGRATION FAILED: Error during feed ID migration: \(error)")
                }
                
                continuation.resume()
            }
        }
    }
    
    /// Set progress with real-time sync and known feedId (more efficient)
    func setProgressWithRealTimeSync(for episodeId: String, progress: Double, reason: String, feedId: String?) {
        // Update local progress first
        setProgress(for: episodeId, progress: progress)
        
        // REAL-TIME SYNC: Instantly sync progress changes for allowed conditions
        let allowedReasons = ["episode_paused", "app_background", "app_closed", "app_resign_active_force_close_protection", "app_did_enter_background_potential_force_close"]
        if allowedReasons.contains(reason) {
            if let feedId = feedId {
                // Use provided feedId for efficient sync
                performRealTimeSyncForEpisode(episodeId, reason: reason, feedId: feedId)
            } else {
                // Fallback to lookup method
                performRealTimeSyncForEpisode(episodeId, reason: reason)
            }
            
            // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
            
            print("📡 ⚡ REAL-TIME PROGRESS SYNC: Triggered for \(episodeId) (reason: \(reason))")
        } else {
            print("📡 🔄 DEFERRED PROGRESS SYNC: Reason '\(reason)' not in allowed list for real-time sync")
        }
    }
    
    /// Save episode states to Core Data instead of UserDefaults
    /// Thread-safe: Uses background context to prevent concurrent access issues
    /// silentMode: When true, saves asynchronously (for CloudKit syncs). When false, saves synchronously (for user actions)
    private func saveToCoreData(silentMode: Bool = false) {
        let context = CoreDataStack.shared.newBackgroundContext()
        
        // CRITICAL FIX: Use synchronous save for user actions to ensure immediate persistence
        // Use async save only for silent modes (bulk CloudKit sync) to avoid blocking UI
        let performBlock = {
            self.saveToCoreDataImpl(context: context)
        }
        
        if silentMode {
            // Async save for bulk operations (CloudKit sync)
            context.perform(performBlock)
        } else {
            // Sync save for user actions (favorite, download) - ensures data is saved before app can close
            context.performAndWait(performBlock)
        }
    }
    
    /// Internal implementation of Core Data save
    private func saveToCoreDataImpl(context: NSManagedObjectContext) {
            var savedCount = 0
            var errorCount = 0
            
            // Get all episodes that have state changes
            let episodesToUpdate = Set(self.episodeStates.keys)
                .union(Set(self.episodeProgress.keys))
                .union(Set(self.episodeFavorites.keys))
                .union(Set(self.episodeDownloads.keys))
            
            // FRESH INSTALL FIX: Check if there are ANY episodes in Core Data first
            // This prevents hundreds of "Episode not found" warnings on fresh installs
            let countRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            countRequest.fetchLimit = 1
            
            do {
                let episodeCount = try context.count(for: countRequest)
                if episodeCount == 0 {
                    print("⚡ FRESH INSTALL: No episodes in Core Data - skipping episode state save")
                    print("⚡ Episode states will be saved automatically when you add your first podcast feed")
                    return
                }
            } catch {
                print("❌ EpisodeStateManager: Failed to check episode count: \(error)")
                // Continue anyway in case of error
            }
            
            print("💾 CORE DATA SAVE: Attempting to update \(episodesToUpdate.count) episodes")
            
            for episodeId in episodesToUpdate {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
                fetchRequest.fetchLimit = 1
                
                do {
                    if let episode = try context.fetch(fetchRequest).first {
                        var hasChanges = false
                        
                        // Update progress
                        if let progress = self.episodeProgress[episodeId] {
                            let newProgress = Float(progress)
                            if abs(Double(episode.progress) - progress) > 0.001 { // Use epsilon comparison for floating point
                                episode.progress = Double(newProgress)
                                hasChanges = true
                            }
                        }
                        
                        // Update played status from episodeStates (preserves explicit played state)
                        if let episodeState = self.episodeStates[episodeId] {
                            let shouldBePlayed = (episodeState == .played)
                            if episode.isPlayed != shouldBePlayed {
                                episode.isPlayed = shouldBePlayed
                                hasChanges = true
                                // PERFORMANCE: Reduce excessive logging during batch operations
                                if self.isVerboseLoggingEnabled {
                                    print("💾 PLAYED STATE: Saved isPlayed=\(shouldBePlayed) for episode \(episodeId) from episodeStates")
                                }
                            }
                        } else {
                            // Fallback: If no explicit state, derive from progress
                            let progress = self.episodeProgress[episodeId] ?? 0.0
                            let derivedPlayed = progress >= 1.0
                            if episode.isPlayed != derivedPlayed {
                                episode.isPlayed = derivedPlayed
                                hasChanges = true
                                // PERFORMANCE: Reduce excessive logging during batch operations
                                if self.isVerboseLoggingEnabled {
                                    print("💾 PLAYED STATE: Fallback isPlayed=\(derivedPlayed) for episode \(episodeId) from progress (\(progress))")
                                }
                            }
                        }
                        
                        // Update favorite status
                        if let isFavorite = self.episodeFavorites[episodeId] {
                            if episode.isFavorite != isFavorite {
                                episode.isFavorite = isFavorite
                                hasChanges = true
                            }
                        }
                        
                        // Update download status
                        if let isDownloaded = self.episodeDownloads[episodeId] {
                            if episode.isDownloaded != isDownloaded {
                                episode.isDownloaded = isDownloaded
                                hasChanges = true
                            }
                        }
                        
                        if hasChanges {
                            savedCount += 1
                            
                        }
                    } else {
                        print("⚠️ CORE DATA SAVE: Episode not found in Core Data: \(episodeId.prefix(8))")
                        errorCount += 1
                    }
                } catch {
                    print("❌ EpisodeStateManager: Failed to fetch episode \(episodeId): \(error)")
                    errorCount += 1
                }
            }
            
            // Save context if we made changes
            if savedCount > 0 {
                do {
                    try context.save()
                    print("✅ CORE DATA SAVE: Successfully saved \(savedCount) episode states")
                    print("   📊 States saved - Progress: \(self.episodeProgress.count), Favorites: \(self.episodeFavorites.count), Downloads: \(self.episodeDownloads.count)")
                } catch {
                    print("❌ EpisodeStateManager: Failed to save to Core Data: \(error)")
                    errorCount += 1
                }
            } else {
                print("💾 CORE DATA SAVE: No changes to save")
            }
            
            if errorCount > 0 {
                print("⚠️ EpisodeStateManager: Encountered \(errorCount) errors while saving to Core Data")
            }
    }
    
    // MARK: - Data Cleanup Methods
    
    /// Emergency cleanup before any save operations
    private func emergencyCleanupIfNeeded() {
        let emergencyLimit = 3_000 // Much stricter limit for emergency situations
        
        if episodeStates.count > emergencyLimit {
            print("🚨 EpisodeStateManager: Emergency cleanup - episode states (\(episodeStates.count) > \(emergencyLimit))")
            emergencyCleanupStates()
        }
        
        if episodeProgress.count > emergencyLimit {
            print("🚨 EpisodeStateManager: Emergency cleanup - episode progress (\(episodeProgress.count) > \(emergencyLimit))")
            emergencyCleanupProgress()
        }
        
        if episodeFavorites.count > emergencyLimit {
            print("🚨 EpisodeStateManager: Emergency cleanup - episode favorites (\(episodeFavorites.count) > \(emergencyLimit))")
            emergencyCleanupFavorites()
        }
        
        if episodeDownloads.count > emergencyLimit {
            print("🚨 EpisodeStateManager: Emergency cleanup - episode downloads (\(episodeDownloads.count) > \(emergencyLimit))")
            emergencyCleanupDownloads()
        }
    }
    
    /// Emergency cleanup for episode states - keep only the most essential data
    private func emergencyCleanupStates() {
        let keepCount = 1000 // Only keep 1000 most recent states
        let sortedStates = episodeStates.sorted { $0.key > $1.key } // Sort by ID descending (newer first)
        let keepStates = Array(sortedStates.prefix(keepCount))
        episodeStates = Dictionary(uniqueKeysWithValues: keepStates)
        print("🧹 EpisodeStateManager: Emergency cleaned episode states to \(episodeStates.count) entries")
    }
    
    /// Emergency cleanup for episode progress - keep only the most essential data
    private func emergencyCleanupProgress() {
        let keepCount = 1000 // Only keep 1000 most recent progress entries
        let sortedProgress = episodeProgress.sorted { $0.key > $1.key } // Sort by ID descending (newer first)
        let keepProgress = Array(sortedProgress.prefix(keepCount))
        episodeProgress = Dictionary(uniqueKeysWithValues: keepProgress)
        print("🧹 EpisodeStateManager: Emergency cleaned episode progress to \(episodeProgress.count) entries")
    }
    
    /// Emergency cleanup for episode favorites - keep only the most essential data
    private func emergencyCleanupFavorites() {
        let keepCount = 1000 // Only keep 1000 most recent favorites
        let sortedFavorites = episodeFavorites.sorted { $0.key > $1.key } // Sort by ID descending (newer first)
        let keepFavorites = Array(sortedFavorites.prefix(keepCount))
        episodeFavorites = Dictionary(uniqueKeysWithValues: keepFavorites)
        print("🧹 EpisodeStateManager: Emergency cleaned episode favorites to \(episodeFavorites.count) entries")
    }
    
    /// Emergency cleanup for episode downloads - keep only the most essential data
    private func emergencyCleanupDownloads() {
        let keepCount = 1000 // Only keep 1000 most recent downloads
        let sortedDownloads = episodeDownloads.sorted { $0.key > $1.key } // Sort by ID descending (newer first)
        let keepDownloads = Array(sortedDownloads.prefix(keepCount))
        episodeDownloads = Dictionary(uniqueKeysWithValues: keepDownloads)
        print("🧹 EpisodeStateManager: Emergency cleaned episode downloads to \(episodeDownloads.count) entries")
    }
    
    /// Clean up old data if we have too many entries to prevent UserDefaults overflow
    private func cleanupOldDataIfNeeded() {
        let maxEntries = 10_000 // Maximum number of episodes to keep in UserDefaults
        
        // Clean up episode states if too many
        if episodeStates.count > maxEntries {
            print("🧹 EpisodeStateManager: Cleaning up episode states (\(episodeStates.count) > \(maxEntries))")
            let sortedStates = episodeStates.sorted { $0.key < $1.key }
            let keepStates = Dictionary(uniqueKeysWithValues: sortedStates.suffix(maxEntries * 3 / 4)) // Keep 75% of max
            episodeStates = keepStates
        }
        
        // Clean up episode progress if too many
        if episodeProgress.count > maxEntries {
            print("🧹 EpisodeStateManager: Cleaning up episode progress (\(episodeProgress.count) > \(maxEntries))")
            let sortedProgress = episodeProgress.sorted { $0.key < $1.key }
            let keepProgress = Dictionary(uniqueKeysWithValues: sortedProgress.suffix(maxEntries * 3 / 4))
            episodeProgress = keepProgress
        }
        
        // Clean up favorites and downloads similarly
        if episodeFavorites.count > maxEntries {
            let sortedFavorites = episodeFavorites.sorted { $0.key < $1.key }
            let keepFavorites = Dictionary(uniqueKeysWithValues: sortedFavorites.suffix(maxEntries * 3 / 4))
            episodeFavorites = keepFavorites
        }
        
        if episodeDownloads.count > maxEntries {
            let sortedDownloads = episodeDownloads.sorted { $0.key < $1.key }
            let keepDownloads = Dictionary(uniqueKeysWithValues: sortedDownloads.suffix(maxEntries * 3 / 4))
            episodeDownloads = keepDownloads
        }
    }
    
    /// Clean up datasets when they become too large
    private func cleanupLargeDatasets() {
        let targetSize = 5_000 // Target maximum entries
        
        // Only keep the most recent entries for each dataset
        if episodeStates.count > targetSize {
            let sortedStates = episodeStates.sorted { $0.key < $1.key }
            episodeStates = Dictionary(uniqueKeysWithValues: sortedStates.suffix(targetSize))
            print("🧹 EpisodeStateManager: Cleaned episode states to \(episodeStates.count) entries")
        }
        
        if episodeProgress.count > targetSize {
            let sortedProgress = episodeProgress.sorted { $0.key < $1.key }
            episodeProgress = Dictionary(uniqueKeysWithValues: sortedProgress.suffix(targetSize))
            print("🧹 EpisodeStateManager: Cleaned episode progress to \(episodeProgress.count) entries")
        }
        
        if episodeFavorites.count > targetSize {
            let sortedFavorites = episodeFavorites.sorted { $0.key < $1.key }
            episodeFavorites = Dictionary(uniqueKeysWithValues: sortedFavorites.suffix(targetSize))
            print("🧹 EpisodeStateManager: Cleaned episode favorites to \(episodeFavorites.count) entries")
        }
        
        if episodeDownloads.count > targetSize {
            let sortedDownloads = episodeDownloads.sorted { $0.key < $1.key }
            episodeDownloads = Dictionary(uniqueKeysWithValues: sortedDownloads.suffix(targetSize))
            print("🧹 EpisodeStateManager: Cleaned episode downloads to \(episodeDownloads.count) entries")
        }
    }
    
    /// Check and clean UserDefaults size if it's getting too large
    private func checkAndCleanUserDefaultsSize() {
        let maxDataSize = 300_000 // CRITICAL FIX: 300KB per dataset to prevent CFPreferences overflow
        
        // Check each data set size
        var totalSize = 0
        var oversizedKeys: [String] = []
        
        if let statesData = userDefaults.data(forKey: statesKey) {
            totalSize += statesData.count
            if statesData.count > maxDataSize {
                oversizedKeys.append(statesKey)
            }
        }
        
        if let progressData = userDefaults.data(forKey: progressKey) {
            totalSize += progressData.count
            if progressData.count > maxDataSize {
                oversizedKeys.append(progressKey)
            }
        }
        
        if let favoritesData = userDefaults.data(forKey: favoritesKey) {
            totalSize += favoritesData.count
            if favoritesData.count > maxDataSize {
                oversizedKeys.append(favoritesKey)
            }
        }
        
        if let downloadsData = userDefaults.data(forKey: downloadsKey) {
            totalSize += downloadsData.count
            if downloadsData.count > maxDataSize {
                oversizedKeys.append(downloadsKey)
            }
        }
        
        if totalSize > 1_000_000 || !oversizedKeys.isEmpty { // CRITICAL FIX: 1MB total limit to prevent CFPreferences overflow
            print("⚠️ EpisodeStateManager: UserDefaults too large (\(totalSize) bytes), cleaning up keys: \(oversizedKeys)")
            
            // Emergency cleanup - remove oversized data and reload from Core Data
            for key in oversizedKeys {
                userDefaults.removeObject(forKey: key)
            }
            
            // Clear in-memory dictionaries to force reload from smaller dataset
            if oversizedKeys.contains(statesKey) {
                episodeStates.removeAll()
            }
            if oversizedKeys.contains(progressKey) {
                episodeProgress.removeAll()
            }
            if oversizedKeys.contains(favoritesKey) {
                episodeFavorites.removeAll()
            }
            if oversizedKeys.contains(downloadsKey) {
                episodeDownloads.removeAll()
            }
            
            print("✅ EpisodeStateManager: Cleaned up UserDefaults, will sync from Core Data")
        } else if totalSize > 0 {
            print("✅ EpisodeStateManager: UserDefaults size OK (\(totalSize) bytes)")
        }
    }
    
    // Throttled update method to prevent excessive UI updates
    private var lastUpdateTime = Date()
    private let updateThrottleInterval: TimeInterval = 3.0 // 3 seconds between updates
    
    func getState(for episodeId: String) -> EpisodePlaybackState {
        return episodeStates[episodeId] ?? .new
    }
    
    func getProgress(for episodeId: String) -> Double {
        let progress = episodeProgress[episodeId] ?? 0.0
        return progress
    }
    
    /// PERFORMANCE OPTIMIZATION: Get batch states for multiple episodes at once
    /// This is much more efficient than individual calls for each episode
    func getBatchStates(for episodeIds: [String]) -> [String: (progress: Double, isFavorite: Bool, isDownloaded: Bool)] {
        var batchStates: [String: (progress: Double, isFavorite: Bool, isDownloaded: Bool)] = [:]
        batchStates.reserveCapacity(episodeIds.count)
        
        for episodeId in episodeIds {
            let progress = episodeProgress[episodeId] ?? 0.0
            let isFavorite = self.isFavorite(episodeId)
            let isDownloaded = self.isDownloaded(episodeId)
            batchStates[episodeId] = (progress: progress, isFavorite: isFavorite, isDownloaded: isDownloaded)
        }
        
        return batchStates
    }
    
    /// HIGH-PERFORMANCE: Batch episode data lookup for optimized episode list loading
    /// This method eliminates individual lookups and provides all episode state data at once
    func getBatchEpisodeData(for episodeIds: [String]) -> [String: EpisodeStateData] {
        var batchData: [String: EpisodeStateData] = [:]
        
        // FAST BATCH PROCESSING: Build result dictionary in single pass
        for episodeId in episodeIds {
            let progress = episodeProgress[episodeId] ?? 0.0
            let isFavorite = episodeFavorites[episodeId] ?? false
            let isDownloaded = episodeDownloads[episodeId] ?? false
            
            // Determine state from progress
            let state: EpisodePlaybackState
            if progress >= 0.99 {
                state = .played
            } else if progress > 0 {
                state = .inProgress
            } else {
                state = .new
            }
            
            batchData[episodeId] = EpisodeStateData(
                progress: progress,
                state: state,
                isFavorite: isFavorite,
                isDownloaded: isDownloaded
            )
        }
        
        return batchData
    }
    
    func getCurrentTime(for episodeId: String) -> Double {
        let currentTime = episodeCurrentTime[episodeId] ?? 0.0
        print("🔍 EpisodeStateManager: Getting currentTime \(currentTime)s for episode \(episodeId)")
        return currentTime
    }
    
    func startPlaying(episodeId: String) {
        // If there's a currently playing episode, mark it as "In Progress" before switching
        if let currentPlayingId = currentlyPlayingEpisodeId, currentPlayingId != episodeId {
            let currentProgress = episodeProgress[currentPlayingId] ?? 0.0
            if currentProgress > 0 {
                let currentState = episodeStates[currentPlayingId] ?? .new
                if currentState != .played {
                    // Only update to inProgress if it wasn't already marked as played
                    // FIXED: Use 1.0 (100%) instead of 0.99 (99%) to ensure complete playback
                    if currentProgress >= 1.0 {
                        episodeStates[currentPlayingId] = .played
                    } else {
                        episodeStates[currentPlayingId] = .inProgress
                    }
                }
            }
        }
        
        episodeStates[episodeId] = .playing
        currentlyPlayingEpisodeId = episodeId
        saveCurrentStates()
        
        // CRITICAL: Send immediate update for playing state changes to prevent UI lag
        sendImmediateUpdate()
        sendThrottledUpdate()
    }
    
    func pausePlayback(episodeId: String, progress: Double) {
        episodeProgress[episodeId] = progress
        
        // CRITICAL FIX: Set state based on progress, ensuring .inProgress is set for paused episodes
        let wasCompleted = progress >= 1.0
        if wasCompleted {
            episodeStates[episodeId] = .played
        } else if progress > 0 {
            episodeStates[episodeId] = .inProgress
        } else {
            // Even if progress is 0, if we're pausing, it should be .new (not .inProgress)
            episodeStates[episodeId] = .new
        }
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        saveCurrentStates()
        
        // CRITICAL: Send immediate update for pause state changes to prevent UI lag
        sendImmediateUpdate()
        
        // CRITICAL FIX: Trigger CloudKit sync for completed episodes
        if wasCompleted {
            Task.detached(priority: .userInitiated) {
                await PodcastCloudKitManager.shared.syncPodcastPlayedInstantly(
                    episodeId: episodeId,
                    isPlayed: true
                )
                print("☁️ PAUSE COMPLETION: Synced played state to CloudKit for completed episode: \(episodeId)")
            }
        }
        
        // REAL-TIME NOTIFICATION: Send immediate notification for progress changes on main thread
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeProgressChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "progress": progress]
            )
            
            // Also send state change notification for real-time status updates
            let newState: EpisodePlaybackState = progress >= 1.0 ? .played : (progress > 0 ? .inProgress : .new)
            NotificationCenter.default.post(
                name: .init("EpisodeStateChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "state": newState.rawValue]
            )
        }
    }
    
    func switchToEpisode(newEpisodeId: String, previousEpisodeId: String, previousProgress: Double) {
        // CRITICAL: Immediately stop the previous episode from showing as playing
        if currentlyPlayingEpisodeId == previousEpisodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        // Mark previous episode as "In Progress" only if it wasn't already marked as "Played"
        if previousProgress > 0 {
            let currentState = episodeStates[previousEpisodeId] ?? .new
            if currentState != .played {
                // Only update to inProgress if it wasn't already marked as played
                // FIXED: Use 1.0 (100%) instead of 0.99 (99%) to ensure complete playback
                if previousProgress >= 1.0 {
                    episodeStates[previousEpisodeId] = .played
                } else {
                    episodeStates[previousEpisodeId] = .inProgress
                }
            }
            episodeProgress[previousEpisodeId] = previousProgress
        }
        
        // Start playing new episode
        episodeStates[newEpisodeId] = .playing
        currentlyPlayingEpisodeId = newEpisodeId
        
        saveCurrentStates()
        
        // CRITICAL: Send immediate update to refresh UI immediately, then follow with throttled update
        sendImmediateUpdate()
        sendThrottledUpdate()
    }
    
    func completeEpisode(episodeId: String) {
        print("✅ Episode \(episodeId.prefix(8)) completed")
        episodeStates[episodeId] = .played
        episodeProgress[episodeId] = 1.0
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        saveCurrentStates()
        sendImmediateUpdate() // Use immediate update for completion
        
        // CRITICAL FIX: Trigger CloudKit sync for played state when episode completes
        setPlayed(episodeId, isPlayed: true)
        
        // Send immediate notification for UI updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeStateChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "state": EpisodePlaybackState.played.rawValue]
            )
            
            NotificationCenter.default.post(
                name: .init("EpisodePlayedChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isPlayed": true]
            )
        }
    }
    
    func rewindAndPlay(episodeId: String) {
        // Stop any currently playing episode first
        if let currentPlayingId = currentlyPlayingEpisodeId, currentPlayingId != episodeId {
            let currentProgress = episodeProgress[currentPlayingId] ?? 0.0
            if currentProgress > 0 {
                let currentState = episodeStates[currentPlayingId] ?? .new
                if currentState != .played {
                    // Only update to inProgress if it wasn't already marked as played
                    // FIXED: Use 1.0 (100%) instead of 0.99 (99%) to ensure complete playback
                    if currentProgress >= 1.0 {
                        episodeStates[currentPlayingId] = .played
                    } else {
                        episodeStates[currentPlayingId] = .inProgress
                    }
                }
            }
        }
        
        // CRITICAL FIX: Reset the episode to beginning and clear any previous played state
        // This ensures the episode can play from beginning without immediately completing
        episodeStates[episodeId] = .playing
        episodeProgress[episodeId] = 0.0
        currentlyPlayingEpisodeId = episodeId
        
        // REWIND FIX: Clear any existing completion flags that might cause immediate completion
        // Remove any stale progress data that could interfere with playback
        episodeCurrentTime[episodeId] = 0.0
        
        print("🔄 REWIND AND PLAY: Reset episode \(episodeId) to playing state with 0.0 progress")
        
        saveCurrentStates()
        sendThrottledUpdate()
    }
    
    func updateProgress(for episodeId: String, progress: Double, isPlaying: Bool, currentTime: Double? = nil) {
        let newState: EpisodePlaybackState
        
        // Prevent overwriting existing progress with 0.0 unless it's a genuine reset
        let existingProgress = episodeProgress[episodeId] ?? 0.0
        let existingState = episodeStates[episodeId] ?? .new
        let shouldUpdateProgress: Bool
        
        
        if progress > 0 {
            // CHAPTER SEEK PROTECTION: Check if we're in chapter protection period
            let isChapterProtected = PodcastPlayer.shared.isInChapterProtectionPeriod()
            let isRewindProtected = PodcastPlayer.shared.isInRewindProtectionPeriod()
            
            // PROGRESS PROTECTION: Only update if progress moves forward, unless in chapter or rewind protection
            if progress >= existingProgress || isChapterProtected || isRewindProtected {
                if isChapterProtected && progress < existingProgress {
                    print("🎯 UPDATE CHAPTER PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - chapter seek override")
                } else if isRewindProtected && progress < existingProgress {
                    print("🔄 UPDATE REWIND PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - rewind override")
                }
                shouldUpdateProgress = true
                // Ensure UI updates happen on main thread
                DispatchQueue.main.async {
                    self.episodeProgress[episodeId] = progress
                }
            } else {
                print("🛡️ UPDATE PROGRESS PROTECTION: Blocked backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress))")
                shouldUpdateProgress = false
            }
        } else if existingProgress == 0.0 {
            // Update to 0.0 only if there's no existing progress
            shouldUpdateProgress = true
            // Ensure UI updates happen on main thread
            DispatchQueue.main.async {
                self.episodeProgress[episodeId] = progress
            }
        } else if currentTime != nil {
            // Update if we have explicit currentTime (from episode switch) - but still protect against backwards progress
            if progress >= existingProgress || progress == 0.0 {
                shouldUpdateProgress = true
                // Ensure UI updates happen on main thread
                DispatchQueue.main.async {
                    self.episodeProgress[episodeId] = progress
                }
            } else {
                print("🛡️ SWITCH PROGRESS PROTECTION: Blocked backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress))")
                shouldUpdateProgress = false
            }
        } else if !isPlaying && existingState == .inProgress && progress == 0.0 {
            // CRITICAL: Don't overwrite in-progress episodes with 0.0 during loading
            shouldUpdateProgress = false
        } else {
            // Don't overwrite existing progress with 0.0
            shouldUpdateProgress = false
        }
        
        // Store current time if provided
        if let currentTime = currentTime {
            episodeCurrentTime[episodeId] = currentTime
        }
        
        // Use the actual progress value for state determination
        let effectiveProgress = shouldUpdateProgress ? progress : existingProgress
        
        if isPlaying {
            newState = .playing
            currentlyPlayingEpisodeId = episodeId
        } else if existingState == .played && effectiveProgress < 1.0 {
            // REWIND FIX: If episode was played but progress is now < 1.0, allow state change
            // This happens when an episode is rewound from a completed state
            if effectiveProgress > 0 {
                newState = .inProgress
                print("🔄 REWIND PROGRESS: Episode \(episodeId) was played but progress < 1.0, changing to inProgress")
            } else {
                newState = .new
                print("🔄 REWIND PROGRESS: Episode \(episodeId) was played but progress = 0.0, changing to new")
            }
            currentlyPlayingEpisodeId = nil
        } else if existingState == .played {
            // REWIND PROTECTION: Don't preserve played state during rewind operations
            let isRewindProtected = PodcastPlayer.shared.isEpisodeInRewindProtectionPeriod(episodeId)
            
            if isRewindProtected {
                // During rewind protection, allow state changes even for played episodes
                print("🔄 REWIND PROTECTION: Active protection detected for episode \(episodeId) - progress: \(String(format: "%.4f", effectiveProgress))")
                if isPlaying {
                    newState = .playing
                    currentlyPlayingEpisodeId = episodeId
                    print("🔄 REWIND PROTECTION: Episode now playing during rewind period")
                } else if effectiveProgress >= 1.0 {
                    newState = .played
                    currentlyPlayingEpisodeId = nil
                    print("🔄 REWIND PROTECTION: Episode completed during rewind period")
                } else if effectiveProgress > 0 {
                    newState = .inProgress
                    currentlyPlayingEpisodeId = nil
                    print("🔄 REWIND PROTECTION: Episode in progress during rewind period (progress: \(String(format: "%.2f", effectiveProgress * 100))%)")
                } else {
                    newState = .new
                    currentlyPlayingEpisodeId = nil
                    print("🔄 REWIND PROTECTION: Episode reset to new during rewind period")
                }
            } else {
                // CRITICAL: Preserve explicitly set played state regardless of progress
                newState = .played
                currentlyPlayingEpisodeId = nil
                print("💾 PLAYED STATE: Preserving existing played state for episode \(episodeId) (not in rewind protection)")
            }
        } else if effectiveProgress >= 1.0 {
            newState = .played
            currentlyPlayingEpisodeId = nil
        } else if effectiveProgress > 0 {
            newState = .inProgress
            currentlyPlayingEpisodeId = nil
        } else if existingState == .inProgress && !shouldUpdateProgress {
            // CRITICAL: Preserve in-progress state when protecting from 0.0 updates
            newState = .inProgress
        } else {
            newState = .new
        }
        
        if episodeStates[episodeId] != newState || shouldUpdateProgress || currentTime != nil {
            // Ensure UI updates happen on main thread
            DispatchQueue.main.async {
                self.episodeStates[episodeId] = newState
            }
            saveCurrentStates()
            
            // CRITICAL: Use immediate update for pause operations (when isPlaying is false)
            // This ensures progress labels update instantly when episodes are paused
            if !isPlaying {
                sendImmediateUpdate()
            } else {
                sendThrottledUpdate()
            }
            
            // Send immediate notification for state changes
            if episodeStates[episodeId] != existingState {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("EpisodeStateChangedInstantly"),
                        object: nil,
                        userInfo: ["episodeId": episodeId, "state": newState.rawValue]
                    )
                    
                    if newState == .played {
                        NotificationCenter.default.post(
                            name: .init("EpisodePlayedChangedInstantly"),
                            object: nil,
                            userInfo: ["episodeId": episodeId, "isPlayed": true]
                        )
                    }
                }
                
                // CRITICAL FIX: Trigger CloudKit sync when episode becomes played via updateProgress
                if newState == .played && existingState != .played {
                    Task.detached(priority: .userInitiated) {
                        await PodcastCloudKitManager.shared.syncPodcastPlayedInstantly(
                            episodeId: episodeId,
                            isPlayed: true
                        )
                        print("☁️ UPDATE PROGRESS COMPLETION: Synced played state to CloudKit for completed episode: \(episodeId)")
                    }
                }
            }
            
            // CRITICAL: Send immediate progress notification for pause operations
            if !isPlaying && shouldUpdateProgress {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("EpisodeProgressChangedInstantly"),
                        object: nil,
                        userInfo: ["episodeId": episodeId, "progress": self.episodeProgress[episodeId] ?? 0.0]
                    )
                }
            }
            
            // REAL-TIME SYNC ONLY: No automatic CloudKit sync - only sync under specific conditions
            // Real-time sync is handled by setProgressWithRealTimeSync() for allowed conditions:
            // - Episode paused, app background, app closed, episode favorited, episode downloaded
            print("📡 🔄 LOCAL UPDATE: Episode state updated locally for \(episodeId) - CloudKit sync only on specific conditions")
        }
    }
    
    func setProgress(for episodeId: String, progress: Double) {
        // CHAPTER SEEK PROTECTION: Check if we're in chapter protection period
        let isChapterProtected = PodcastPlayer.shared.isInChapterProtectionPeriod()
        
        // REWIND PROTECTION: Check if we're in rewind protection period
        let isRewindProtected = PodcastPlayer.shared.isInRewindProtectionPeriod()
        
        // PROGRESS PROTECTION: Never allow progress to go backwards, unless in chapter or rewind protection
        let existingProgress = episodeProgress[episodeId] ?? 0.0
        let finalProgress: Double
        
        // ENHANCED PROTECTION: Critical check for accidental reset to 0
        if progress == 0.0 && existingProgress > 0.0 && !isRewindProtected {
            print("🛡️ CRITICAL PROTECTION: Blocked progress reset from \(String(format: "%.4f", existingProgress)) to 0.0 for episode \(episodeId) - preserving existing progress")
            finalProgress = existingProgress // Block accidental reset to 0
        } else if progress < existingProgress && !isChapterProtected && !isRewindProtected {
            print("🛡️ PROGRESS PROTECTION: Blocked backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - keeping higher value")
            finalProgress = existingProgress // Keep the higher progress
        } else {
            if isChapterProtected && progress < existingProgress {
                print("🎯 CHAPTER PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - chapter seek override")
            } else if isRewindProtected && progress < existingProgress {
                print("🔄 REWIND PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - rewind override")
            }
            finalProgress = progress // Allow forward progress, same value, chapter backward progress, or intentional rewind
        }
        
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async {
            self.episodeProgress[episodeId] = finalProgress
        }
        
        // Update state based on final progress
        let newState: EpisodePlaybackState
        if finalProgress >= 1.0 {
            newState = .played
        } else if finalProgress > 0 {
            newState = .inProgress
        } else {
            newState = .new
        }
        
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async {
            self.episodeStates[episodeId] = newState
        }
        saveCurrentStates()
        
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        
        // REAL-TIME UI: Send immediate update for progress changes to ensure instant UI refresh
        sendImmediateUpdate()
        
        // REAL-TIME NOTIFICATION: Send immediate notification for episode progress changes on main thread
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeProgressChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "progress": finalProgress]
            )
        }
        
        // CONDITIONAL SYNC: Progress updates are stored locally only
        // CloudKit sync will happen only during specific conditions:
        // - Episode paused, app backgrounded, app closed (handled by PodcastPlayer)
        // - User explicitly favorites/downloads (handled by respective methods)
        print("📡 🔄 CONDITIONAL SYNC: Progress stored locally for \(episodeId) - CloudKit sync deferred until allowed condition")
    }
    
    /// Set progress with real-time sync for specific trigger conditions
    func setProgressWithRealTimeSync(for episodeId: String, progress: Double, reason: String) {
        // Get episode title for banner display
        let episodeTitle = getEpisodeTitle(for: episodeId)
        let progressValue = "\(Int(progress * 100))%"
        
        // Start real-time sync banner
        DispatchQueue.main.async {
            DataSyncManager.shared.startRealTimeEpisodeSync(
                type: .progress, 
                episodeTitle: episodeTitle, 
                value: progressValue
            )
        }
        
        // Update local progress first
        setProgress(for: episodeId, progress: progress)
        
        // REAL-TIME SYNC: Instantly sync progress changes for allowed conditions
        let allowedReasons = ["episode_paused", "app_background", "app_closed", "app_resign_active_force_close_protection", "app_did_enter_background_potential_force_close"]
        if allowedReasons.contains(reason) {
            performRealTimeSyncForEpisode(episodeId, reason: reason)
            
            // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
            
            print("📡 ⚡ REAL-TIME PROGRESS SYNC: Triggered for \(episodeId) (reason: \(reason))")
        } else {
            print("📡 🔄 DEFERRED PROGRESS SYNC: Reason '\(reason)' not in allowed list for real-time sync")
        }
    }
    

    
    /// Carry in-memory state across an episode ID rewrite (see migrateUnstableEpisodeIDs).
    @MainActor
    func remapEpisodeIds(_ pairs: [(old: String, new: String)]) {
        for (old, new) in pairs {
            if let value = episodeProgress.removeValue(forKey: old) { episodeProgress[new] = value }
            if let value = episodeFavorites.removeValue(forKey: old) { episodeFavorites[new] = value }
            if let value = episodeDownloads.removeValue(forKey: old) { episodeDownloads[new] = value }
            if let value = episodeStates.removeValue(forKey: old) { episodeStates[new] = value }
        }
        saveCurrentStates()
        sendImmediateUpdate()
    }
    
    /// Get favorite state for an episode
    func isFavorite(_ episodeId: String) -> Bool {
        return episodeFavorites[episodeId] ?? false
    }
    
    /// Set favorite state for an episode with real-time CloudKit sync
    func setFavorite(_ episodeId: String, isFavorite: Bool) {
        setFavorite(episodeId, isFavorite: isFavorite, feedId: nil)
    }
    
    /// Set favorite state for an episode with real-time CloudKit sync and known feedId
    func setFavorite(_ episodeId: String, isFavorite: Bool, feedId: String?) {
        // Get episode title for banner display
        let episodeTitle = getEpisodeTitle(for: episodeId)
        let favoriteValue = isFavorite ? "❤️" : "♡"
        
        // Start real-time sync banner
        DispatchQueue.main.async {
            DataSyncManager.shared.startRealTimeEpisodeSync(
                type: .favorite, 
                episodeTitle: episodeTitle, 
                value: favoriteValue
            )
        }
        
        // CRITICAL FIX: Set favorite state SYNCHRONOUSLY before CloudKit sync
        // This prevents race condition where CloudKit sync reads old state
        episodeFavorites[episodeId] = isFavorite
        saveCurrentStates()
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendImmediateUpdate() // Use immediate update for real-time UI
        print("🔍 EpisodeStateManager: Set favorite for \(episodeId): \(isFavorite)")
        
        // REAL-TIME SYNC: Instantly sync favorite changes across devices
        print("📡 🚀 REAL-TIME FAVORITE SYNC: About to call performRealTimeSyncForEpisode for \(episodeId)")
        if let feedId = feedId {
            performRealTimeSyncForEpisode(episodeId, reason: "favorite_action", feedId: feedId)
        } else {
            performRealTimeSyncForEpisode(episodeId, reason: "favorite_action")
        }
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for favorite changes
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeFavoriteChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isFavorite": isFavorite]
            )
        }
        
        print("📡 ✅ REAL-TIME FAVORITE SYNC: Completed all sync operations for \(episodeId)")
    }
    
    /// Get download state for an episode
    func isDownloaded(_ episodeId: String) -> Bool {
        return episodeDownloads[episodeId] ?? false
    }
    
    /// Get played state for an episode from Core Data
    /// Thread-safe: Uses background context to prevent concurrent access issues
    func getIsPlayed(_ episodeId: String) -> Bool {
        // CRITICAL: Check in-memory episodeStates first (most accurate and up-to-date)
        if let episodeState = episodeStates[episodeId] {
            let isPlayedFromState = (episodeState == .played)
            if isPlayedFromState {
                print("💾 PLAYED CHECK: Episode \(episodeId) is played (from episodeStates)")
                return true
            }
        }
        
        // Fallback to Core Data
        var result: Bool = false
        let context = CoreDataStack.shared.newBackgroundContext()
        
        context.performAndWait {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
            fetchRequest.fetchLimit = 1
            
            do {
                if let episode = try context.fetch(fetchRequest).first {
                    result = episode.isPlayed
                    if result {
                        print("💾 PLAYED CHECK: Episode \(episodeId) is played (from Core Data)")
                    }
                }
            } catch {
                print("❌ EpisodeStateManager: Failed to fetch isPlayed for episode \(episodeId): \(error)")
            }
        }
        
        // Final fallback to progress calculation if Core Data doesn't have the episode
        if !result {
            let progress = getProgress(for: episodeId)
            result = progress >= 1.0
            if result {
                print("💾 PLAYED CHECK: Episode \(episodeId) is played (from progress 100%: \(progress))")
            }
        }
        
        return result
    }
    
    /// Set played state for an episode with real-time CloudKit sync
    func setPlayed(_ episodeId: String, isPlayed: Bool) {
        // Get episode title for banner display
        let episodeTitle = getEpisodeTitle(for: episodeId)
        let playedValue = isPlayed ? "✅ Completed" : "🔄 Reset"
        
        // Start real-time sync banner
        DispatchQueue.main.async {
            DataSyncManager.shared.startRealTimeEpisodeSync(
                type: .played, 
                episodeTitle: episodeTitle, 
                value: playedValue
            )
        }
        
        // Update local state tracking
        if isPlayed {
            episodeStates[episodeId] = .played
        } else if episodeStates[episodeId] == .played {
            // Only change from played to not played, preserve other states
            let currentProgress = getProgress(for: episodeId)
            if currentProgress > 0 {
                episodeStates[episodeId] = .inProgress
            } else {
                episodeStates[episodeId] = .new
            }
        }
        
        saveCurrentStates()
        sendImmediateUpdate() // Use immediate update for real-time UI
        
        // REAL-TIME SYNC: Instantly sync played state changes across devices
        let currentProgress = getProgress(for: episodeId)
        let currentFavorite = isFavorite(episodeId)
        let currentDownloaded = isDownloaded(episodeId)
        
        Task.detached(priority: .userInitiated) {
            // Instant sync for real-time updates - use dedicated played sync method
            await PodcastCloudKitManager.shared.syncPodcastPlayedInstantly(
                episodeId: episodeId,
                isPlayed: isPlayed
            )
            
            // Also sync progress for completeness
            await PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                episodeId: episodeId,
                progress: currentProgress
            )
            
            // Persistent sync to CloudKit records
            await PodcastCloudKitManager.shared.saveEpisodeState(
                episodeId: episodeId,
                feedId: self.getFeedId(for: episodeId) ?? "",
                progress: currentProgress,
                isFavorite: currentFavorite,
                isDownloaded: currentDownloaded,
                isPlayed: isPlayed
            )
            print("☁️ EpisodeStateManager: Real-time synced played state to CloudKit: \(episodeId)")
        }
        
        // REAL-TIME NOTIFICATION: Send immediate notification for played state changes
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodePlayedChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isPlayed": isPlayed]
            )
        }
    }
    
    /// Set download state for an episode with real-time CloudKit sync
    func setDownloaded(_ episodeId: String, isDownloaded: Bool) {
        setDownloaded(episodeId, isDownloaded: isDownloaded, feedId: nil)
    }
    
    /// Set download state for an episode with real-time CloudKit sync and known feedId
    func setDownloaded(_ episodeId: String, isDownloaded: Bool, feedId: String?) {
        // Get episode title for banner display
        let episodeTitle = getEpisodeTitle(for: episodeId)
        let downloadValue = isDownloaded ? "⬇️ Downloaded" : "❌ Removed"
        
        // Start real-time sync banner
        DispatchQueue.main.async {
            DataSyncManager.shared.startRealTimeEpisodeSync(
                type: .download, 
                episodeTitle: episodeTitle, 
                value: downloadValue
            )
        }
        
        // CRITICAL FIX: Set download state SYNCHRONOUSLY before CloudKit sync
        // This prevents race condition where CloudKit sync reads old state
        episodeDownloads[episodeId] = isDownloaded
        saveCurrentStates()
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendImmediateUpdate() // Use immediate update for real-time UI
        print("🔍 EpisodeStateManager: Set downloaded for \(episodeId): \(isDownloaded)")
        
        // REAL-TIME SYNC: Instantly sync download changes across devices
        print("📡 🚀 REAL-TIME DOWNLOAD SYNC: About to call performRealTimeSyncForEpisode for \(episodeId)")
        if let feedId = feedId {
            performRealTimeSyncForEpisode(episodeId, reason: "download_action", feedId: feedId)
        } else {
            performRealTimeSyncForEpisode(episodeId, reason: "download_action")
        }
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for download changes
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeDownloadChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isDownloaded": isDownloaded]
            )
        }
        
        print("📡 ✅ REAL-TIME DOWNLOAD SYNC: Completed all sync operations for \(episodeId)")
    }
    
    /// UPGRADE PROTECTION: Enhanced download state setting with backup
    func setDownloadedWithProtection(_ episodeId: String, isDownloaded: Bool, reason: String = "normal") {
        let previousState = episodeDownloads[episodeId] ?? false
        
        // If we're setting to false but it was true, check if this is during an upgrade
        if previousState && !isDownloaded && isUpgradeScenario() {
            print("⚠️ EpisodeStateManager: Preventing download state reset during upgrade for \(episodeId) (reason: \(reason))")
            // Don't change the state during upgrades unless explicitly forced
            return
        }
        
        episodeDownloads[episodeId] = isDownloaded
        saveCurrentStates()
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendThrottledUpdate()
        print("🔍 EpisodeStateManager: Set downloaded for \(episodeId): \(isDownloaded) (reason: \(reason))")
        
        // Create additional backup if setting to true
        if isDownloaded {
            backupSingleDownloadState(episodeId: episodeId)
        }
    }
    
    /// Backup a single download state for recovery
    private func backupSingleDownloadState(episodeId: String) {
        let backupKey = "DownloadBackup_\(episodeId)"
        let backupData: [String: Any] = [
            "isDownloaded": true,
            "timestamp": Date().timeIntervalSince1970,  // Convert Date to TimeInterval for JSON serialization
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]
        
        if let encoded = try? JSONSerialization.data(withJSONObject: backupData) {
            userDefaults.set(encoded, forKey: backupKey)
        }
    }
    
    /// Recover download states from individual backups
    private func recoverDownloadStatesFromIndividualBackups() {
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let backupKeys = allKeys.filter { $0.hasPrefix("DownloadBackup_") }
        
        var recoveredCount = 0
        
        for backupKey in backupKeys {
            let episodeId = String(backupKey.dropFirst("DownloadBackup_".count))
            
            // Only recover if current state is false but backup exists
            if !(episodeDownloads[episodeId] ?? false),
               let backupData = userDefaults.data(forKey: backupKey),
               let backup = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any],
               let wasDownloaded = backup["isDownloaded"] as? Bool,
               wasDownloaded {
                
                episodeDownloads[episodeId] = true
                recoveredCount += 1
                print("🔄 EpisodeStateManager: Recovered download state for \(episodeId)")
            }
        }
        
        if recoveredCount > 0 {
            print("✅ EpisodeStateManager: Recovered \(recoveredCount) download states from individual backups")
            saveCurrentStates()
        }
    }
    
    /// Clear individual backup file for a specific episode (used when deleting downloads)
    func clearEpisodeBackup(_ episodeId: String) {
        let backupKey = "DownloadBackup_\(episodeId)"
        userDefaults.removeObject(forKey: backupKey)
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        print("🗑️ EpisodeStateManager: Cleared backup for episode \(episodeId)")
    }
    
    /// Clear all data for a specific episode (used when deleting podcasts)
    func clearEpisodeData(_ episodeId: String) {
        episodeStates.removeValue(forKey: episodeId)
        episodeProgress.removeValue(forKey: episodeId)
        episodeFavorites.removeValue(forKey: episodeId)
        episodeDownloads.removeValue(forKey: episodeId)
        episodeCurrentTime.removeValue(forKey: episodeId)
        
        // Clear currently playing if this is the episode
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
        }
        
        // Clear individual backup file
        clearEpisodeBackup(episodeId)
        
        saveCurrentStates()
        sendThrottledUpdate()
        print("🗑️ EpisodeStateManager: Cleared all data for episode \(episodeId)")
    }
    
    /// Clear all data for multiple episodes in batch (optimized for feed deletion)
    func clearEpisodeDataBatch(_ episodeIds: [String]) {
        guard !episodeIds.isEmpty else { return }
        
        print("🗑️ EpisodeStateManager: Starting batch clear for \(episodeIds.count) episodes")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var clearedCount = 0
        var backupsCleared = 0
        
        // Clear all data in batches without saving after each operation
        for episodeId in episodeIds {
            // Remove from all dictionaries
            episodeStates.removeValue(forKey: episodeId)
            episodeProgress.removeValue(forKey: episodeId)
            episodeFavorites.removeValue(forKey: episodeId)
            episodeDownloads.removeValue(forKey: episodeId)
            episodeCurrentTime.removeValue(forKey: episodeId)
            
            // Clear currently playing if this is the episode
            if currentlyPlayingEpisodeId == episodeId {
                currentlyPlayingEpisodeId = nil
            }
            
            clearedCount += 1
        }
        
        // Clear backup files in batch
        for episodeId in episodeIds {
            clearEpisodeBackup(episodeId)
            backupsCleared += 1
        }
        
        // Save only once at the end
        saveCurrentStates()
        sendThrottledUpdate()
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        print("🗑️ EpisodeStateManager: Batch clear completed:")
        print("🗑️   ✅ Cleared \(clearedCount) episode states")
        print("🗑️   ✅ Cleared \(backupsCleared) backup files")
        print("🗑️   ⏱️ Duration: \(String(format: "%.3f", duration)) seconds")
        print("🗑️   🚀 Performance: \(String(format: "%.1f", Double(clearedCount) / duration)) episodes/second")
    }
    
    /// Clear state for a specific episode
    /// Used when deleting individual episodes or feeds
    func clearState(for episodeId: String) {
        episodeStates.removeValue(forKey: episodeId)
        episodeProgress.removeValue(forKey: episodeId)
        episodeFavorites.removeValue(forKey: episodeId)
        episodeDownloads.removeValue(forKey: episodeId)
        
        if currentlyPlayingEpisodeId == episodeId {
            currentlyPlayingEpisodeId = nil
            userDefaults.removeObject(forKey: currentlyPlayingKey)
        }
        
        // NOTE: We don't call saveToCoreData() here because the episode is being deleted
        // from Core Data anyway. Calling it would try to update a non-existent episode.
        // The episode will be removed from Core Data by the deletion operation.
        
        sendThrottledUpdate()
    }
    
    func clearAllStates() {
        episodeStates.removeAll()
        episodeProgress.removeAll()
        episodeFavorites.removeAll()
        episodeDownloads.removeAll()
        currentlyPlayingEpisodeId = nil
        
        userDefaults.removeObject(forKey: statesKey)
        userDefaults.removeObject(forKey: progressKey)
        userDefaults.removeObject(forKey: favoritesKey)
        userDefaults.removeObject(forKey: downloadsKey)
        userDefaults.removeObject(forKey: currentlyPlayingKey)
        
        sendThrottledUpdate()
    }
    
    /// Synchronize download states from Core Data on startup to recover from force close scenarios
    /// UPGRADE PROTECTION: Enhanced to prevent download state loss during upgrades
    private func syncDownloadStatesFromCoreData() {
        DispatchQueue.global(qos: .utility).async {
            let context = CoreDataStack.shared.context
            context.perform {
                do {
                    // Get all downloaded episodes from Core Data
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
                    
                    let downloadedEpisodes = try context.fetch(fetchRequest)
                    
                    var syncedCount = 0
                    var cleanedCount = 0
                    let isUpgrade = EpisodeStateManager.shared.isUpgradeScenario()
                    
                    print("🔄 EpisodeStateManager: Syncing \(downloadedEpisodes.count) downloaded episodes from Core Data (upgrade: \(isUpgrade))")
                    
                    for managedEpisode in downloadedEpisodes {
                        guard let episodeId = managedEpisode.id else { continue }
                        
                        // Verify file still exists
                        var fileExists = false
                        if let localPath = managedEpisode.localFilePath, !localPath.isEmpty {
                            fileExists = FileManager.default.fileExists(atPath: localPath)
                        }
                        
                        if fileExists {
                            // File exists, ensure EpisodeStateManager knows about it
                            DispatchQueue.main.async {
                                EpisodeStateManager.shared.setDownloadedWithProtection(episodeId, isDownloaded: true, reason: "core_data_sync")
                            }
                            syncedCount += 1
                        } else {
                            // UPGRADE PROTECTION: During upgrades, be more conservative about cleaning up missing files
                            if isUpgrade {
                                print("⚠️ EpisodeStateManager: File missing during upgrade - preserving download state for \(episodeId)")
                                // Keep the download state in EpisodeStateManager but clean up Core Data
                                managedEpisode.localFilePath = nil
                                // Don't change the isDownloaded flag in Core Data during upgrades
                            } else {
                                // Not an upgrade, safe to clean up normally
                                managedEpisode.isDownloaded = false
                                managedEpisode.localFilePath = nil
                                DispatchQueue.main.async {
                                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                    EpisodeStateManager.shared.clearEpisodeBackup(episodeId)  // Clear backup to prevent recovery
                                    
                                    // CRITICAL: Sync the download state change to CloudKit
                                    if let feedId = managedEpisode.feedId, !feedId.isEmpty {
                                        Task.detached(priority: .utility) {
                                            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                                            let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                                            let currentPlayed = EpisodeStateManager.shared.getIsPlayed(episodeId)
                                            await PodcastCloudKitManager.shared.saveEpisodeState(
                                                episodeId: episodeId,
                                                feedId: feedId,
                                                progress: currentProgress,
                                                isFavorite: currentFavorite,
                                                isDownloaded: false,
                                                isPlayed: currentPlayed
                                            )
                                            print("☁️ Synced download state cleanup to CloudKit from EpisodeStateManager: \(episodeId)")
                                        }
                                    }
                                }
                                cleanedCount += 1
                            }
                        }
                    }
                    
                    // Save Core Data changes if needed
                    if cleanedCount > 0 {
                        try context.save()
                    }
                    
                    print("🔄 EpisodeStateManager startup sync: \(syncedCount) downloads synced, \(cleanedCount) cleaned up")
                    
                } catch {
                    print("❌ EpisodeStateManager startup sync error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDebugLogging() {
        // Set up app termination observer to save state
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("🛑 APP TERMINATING: Force saving all episode states to Core Data")
            self.saveCurrentStates() // Synchronous save to ensure data persists before app closes
            print("✅ APP TERMINATING: All episode states saved successfully")
        }
        
        // Also save on background and resign active (for force close protection)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("📱 APP BACKGROUNDED: Force saving all episode states to Core Data")
            self.saveCurrentStates() // Synchronous save for force close protection
            print("✅ APP BACKGROUNDED: All episode states saved successfully")
        }
    }
    
    private func sendThrottledUpdate() {
        // Cancel any existing timer
        updateTimer?.invalidate()
        
        // Create a new timer that will fire after the delay
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateDelay, repeats: false) { _ in
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    private func sendImmediateUpdate() {
        // Send immediate update to refresh UI without throttling
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}

// MARK: - Selective CloudKit Sync Management

extension EpisodeStateManager {
    /// Enable deferred CloudKit sync mode (sync only on pause/background/close)
    func enableDeferredCloudKitSync() {
        deferCloudKitSync = true
        print("📡 🔄 SELECTIVE SYNC: Enabled deferred CloudKit sync mode")
    }
    
    /// Disable deferred CloudKit sync mode (immediate syncs)
    func disableDeferredCloudKitSync() {
        deferCloudKitSync = false
        print("📡 🔄 SELECTIVE SYNC: Disabled deferred CloudKit sync mode")
    }
    
    /// Flush all pending CloudKit syncs (called on pause/background/close)
    func flushPendingCloudKitSyncs() {
        guard !pendingCloudKitSyncs.isEmpty else { return }
        
        print("📡 🔄 SELECTIVE SYNC: Flushing \(pendingCloudKitSyncs.count) pending CloudKit syncs")
        
        for episodeId in pendingCloudKitSyncs {
            syncEpisodeToCloudKit(episodeId: episodeId)
        }
        
        pendingCloudKitSyncs.removeAll()
        print("📡 ✅ SELECTIVE SYNC: All pending syncs flushed")
    }
    
    /// Internal method to sync a specific episode to CloudKit
    private func syncEpisodeToCloudKit(episodeId: String) {
        guard let feedId = getFeedId(for: episodeId), !feedId.isEmpty else { return }
        
        let currentProgress = getProgress(for: episodeId)
        let currentFavorite = isFavorite(episodeId)
        let currentDownloaded = isDownloaded(episodeId)
        let currentPlayed = getIsPlayed(episodeId)
        
        Task.detached(priority: .userInitiated) {
            await PodcastCloudKitManager.shared.saveEpisodeState(
                episodeId: episodeId,
                feedId: feedId,
                progress: currentProgress,
                isFavorite: currentFavorite,
                isDownloaded: currentDownloaded,
                isPlayed: currentPlayed
            )
            print("☁️ EpisodeStateManager: Synced pending state to CloudKit: \(episodeId)")
        }
    }
    
    /// Save current states silently without triggering CloudKit sync (for incoming CloudKit updates)
    private func saveCurrentStatesSilently() {
        // CRITICAL FIX: Save to Core Data instead of UserDefaults to prevent CFPreferences overflow
        saveToCoreData(silentMode: true) // Silent mode prevents CloudKit sync loop
        
        // Save currently playing episode to UserDefaults (small data, safe)
        if let playingId = currentlyPlayingEpisodeId {
            userDefaults.set(playingId, forKey: "currentlyPlayingEpisodeId")
        }
        
        // CRITICAL: Do NOT call synchronize() during silent saves (CloudKit sync operations)
        // Synchronize is deprecated and calling it thousands of times during pull-to-refresh
        // causes CFPreferences overflow by forcing excessive disk writes
        
        // CRITICAL: Do NOT create emergency backups during silent saves (CloudKit sync operations)
        // During pull-to-refresh, saveCurrentStatesSilently() is called 3000+ times
        // Creating backups every 50 calls would create 60+ backups, overwhelming UserDefaults
        // Emergency backups are only needed for user-initiated saves, not CloudKit syncs
    }
    
    // MARK: - Silent Update Methods (No CloudKit Sync)
    
    /// Set progress silently without triggering CloudKit sync (for incoming CloudKit updates)
    func setProgressSilently(for episodeId: String, progress: Double) {
        // CHAPTER SEEK PROTECTION: Check if we're in chapter protection period
        let isChapterProtected = PodcastPlayer.shared.isInChapterProtectionPeriod()
        
        // REWIND PROTECTION: Check if we're in rewind protection period
        let isRewindProtected = PodcastPlayer.shared.isInRewindProtectionPeriod()
        
        // PROGRESS PROTECTION: Never allow progress to go backwards, even from CloudKit, unless in chapter or rewind protection
        let existingProgress = episodeProgress[episodeId] ?? 0.0
        let finalProgress: Double
        
        // ENHANCED CLOUDKIT PROTECTION: Critical check for accidental reset to 0 from CloudKit
        if progress == 0.0 && existingProgress > 0.0 && !isRewindProtected {
            print("🛡️ CRITICAL CLOUDKIT PROTECTION: Blocked CloudKit progress reset from \(String(format: "%.4f", existingProgress)) to 0.0 for episode \(episodeId) - preserving existing progress")
            finalProgress = existingProgress // Block accidental reset to 0 from CloudKit
        } else if progress < existingProgress && !isChapterProtected && !isRewindProtected {
            print("🛡️ CLOUDKIT PROGRESS PROTECTION: Blocked backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - keeping higher value")
            finalProgress = existingProgress // Keep the higher progress
        } else {
            if isChapterProtected && progress < existingProgress {
                print("🎯 CLOUDKIT CHAPTER PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - chapter seek override")
            } else if isRewindProtected && progress < existingProgress {
                print("🔄 CLOUDKIT REWIND PROTECTION: Allowing backward progress for \(episodeId): \(String(format: "%.4f", progress)) < \(String(format: "%.4f", existingProgress)) - rewind override")
            }
            finalProgress = progress // Allow forward progress, same value, chapter backward progress, or intentional rewind
        }
        
        episodeProgress[episodeId] = finalProgress
        
        // CRITICAL FIX: Update episode state based on final progress (just like setProgress does)
        // This ensures "NEW" changes to "IN PROGRESS" immediately when synced from other devices
        let newState: EpisodePlaybackState
        if finalProgress >= 1.0 {
            newState = .played
        } else if finalProgress > 0 {
            newState = .inProgress
        } else {
            newState = .new
        }
        
        episodeStates[episodeId] = newState
        saveCurrentStatesSilently() // Use silent save to prevent CloudKit sync loop
        sendImmediateUpdate() // Use immediate update for real-time cross-device UI updates
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for cross-device UI updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeProgressChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "progress": finalProgress]
            )
            
            // Also send state change notification for real-time status updates
            NotificationCenter.default.post(
                name: .init("EpisodeStateChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "state": newState.rawValue]
            )
        }
        
        print("🔄 EpisodeStateManager: Set progress silently for \(episodeId): \(Int(finalProgress * 100))% -> State: \(newState)")
    }
    
    /// Set favorite state silently without triggering CloudKit sync
    func setFavoriteSilently(_ episodeId: String, isFavorite: Bool) {
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async {
            self.episodeFavorites[episodeId] = isFavorite
        }
        saveCurrentStatesSilently() // Use silent save to prevent CloudKit sync loop
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendImmediateUpdate() // Use immediate update for real-time cross-device UI updates
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for cross-device favorite updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeFavoriteChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isFavorite": isFavorite]
            )
        }
        
    }
    
    /// Set download state silently without triggering CloudKit sync
    func setDownloadedSilently(_ episodeId: String, isDownloaded: Bool) {
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async {
            self.episodeDownloads[episodeId] = isDownloaded
        }
        saveCurrentStatesSilently() // Use silent save to prevent CloudKit sync loop
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendImmediateUpdate() // Use immediate update for real-time cross-device UI updates
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for cross-device download updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodeDownloadChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isDownloaded": isDownloaded]
            )
        }
        
        print("🔄 EpisodeStateManager: Set downloaded silently for \(episodeId): \(isDownloaded)")
    }
    
    /// Set played state silently without triggering CloudKit sync
    func setPlayedSilently(_ episodeId: String, isPlayed: Bool) {
        // Update local state tracking
        if isPlayed {
            episodeStates[episodeId] = .played
            print("💾 PLAYED STATE: Set episode \(episodeId) as played silently")
        } else if episodeStates[episodeId] == .played {
            // Only change from played to not played, preserve other states
            let currentProgress = getProgress(for: episodeId)
            if currentProgress > 0 {
                episodeStates[episodeId] = .inProgress
                print("💾 PLAYED STATE: Reverted episode \(episodeId) from played to inProgress")
            } else {
                episodeStates[episodeId] = .new
                print("💾 PLAYED STATE: Reverted episode \(episodeId) from played to new")
            }
        }
        
        saveCurrentStatesSilently() // Use silent save to prevent CloudKit sync loop
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        sendImmediateUpdate() // Use immediate update for real-time cross-device UI updates
        
        // Episode-specific timing is already tracked in performRealTimeSyncForEpisode
        
        // REAL-TIME NOTIFICATION: Send immediate notification for cross-device played state updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("EpisodePlayedChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "isPlayed": isPlayed]
            )
            
            // Also send state change notification for real-time status updates
            let newState: EpisodePlaybackState = isPlayed ? .played : (self.getProgress(for: episodeId) > 0 ? .inProgress : .new)
            NotificationCenter.default.post(
                name: .init("EpisodeStateChangedInstantly"),
                object: nil,
                userInfo: ["episodeId": episodeId, "state": newState.rawValue]
            )
        }
        
    }
    
    // MARK: - Helper Methods
    
    /// Get episode title for banner display
    private func getEpisodeTitle(for episodeId: String) -> String {
        let context = CoreDataStack.shared.newBackgroundContext()
        var title = "Episode"
        
        context.performAndWait {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episodeId)
            fetchRequest.fetchLimit = 1
            
            do {
                if let episode = try context.fetch(fetchRequest).first,
                   let episodeTitle = episode.title {
                    title = episodeTitle
                }
            } catch {
                print("❌ EpisodeStateManager: Failed to fetch episode title for \(episodeId): \(error)")
            }
        }
        
        // Truncate title if too long for banner
        if title.count > 40 {
            return String(title.prefix(37)) + "..."
        }
        return title
    }
}

// MARK: - CloudKit Sync Progress Management
extension EpisodeStateManager {
    /// Start tracking CloudKit sync progress for resumption capability
    func startCloudKitSyncProgress(totalEpisodeIds: [String], isFreshInstall: Bool) {
        let syncProgress = CloudKitSyncProgress(totalEpisodeIds: totalEpisodeIds, isFreshInstall: isFreshInstall)
        self.cloudKitSyncProgress = syncProgress
        saveSyncProgress()
        print("📡 🔄 SYNC RESUMPTION: Started tracking sync for \(totalEpisodeIds.count) episodes (fresh install: \(isFreshInstall))")
    }
    
    /// Mark an episode as processed in the sync progress
    func markEpisodeProcessed(_ episodeId: String) {
        guard var syncProgress = self.cloudKitSyncProgress else { return }
        syncProgress.markEpisodeProcessed(episodeId)
        self.cloudKitSyncProgress = syncProgress
        saveSyncProgress()
        
        let progressPercent = Int(syncProgress.progress * 100)
    }
    
    /// Get the current sync progress if any
    func getCurrentSyncProgress() -> CloudKitSyncProgress? {
        return cloudKitSyncProgress
    }
    
    /// Check if there's an incomplete sync that can be resumed
    func hasIncompleteSyncToResume() -> Bool {
        guard let syncProgress = cloudKitSyncProgress else { return false }
        return !syncProgress.isComplete
    }
    
    /// Get remaining episode IDs to sync
    func getRemainingEpisodesToSync() -> [String] {
        return cloudKitSyncProgress?.remainingEpisodeIds ?? []
    }
    
    /// Complete the current sync progress
    func completeSyncProgress() {
        cloudKitSyncProgress = nil
        userDefaults.removeObject(forKey: syncProgressKey)
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        print("📡 ✅ SYNC RESUMPTION: Sync progress completed and cleared")
    }
    
    /// Save sync progress to persistent storage
    private func saveSyncProgress() {
        guard let syncProgress = cloudKitSyncProgress else {
            userDefaults.removeObject(forKey: syncProgressKey)
            return
        }
        
        do {
            let data = try JSONEncoder().encode(syncProgress)
            userDefaults.set(data, forKey: syncProgressKey)
            // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        } catch {
            print("⚠️ SYNC RESUMPTION: Failed to save sync progress: \(error)")
        }
    }
    
    /// Load sync progress from persistent storage
    private func loadSyncProgress() {
        guard let data = userDefaults.data(forKey: syncProgressKey) else { return }
        
        do {
            let syncProgress = try JSONDecoder().decode(CloudKitSyncProgress.self, from: data)
            self.cloudKitSyncProgress = syncProgress
            print("📡 🔄 SYNC RESUMPTION: Loaded incomplete sync with \(syncProgress.remainingEpisodeIds.count) remaining episodes")
        } catch {
            print("⚠️ SYNC RESUMPTION: Failed to load sync progress: \(error)")
            // Clear corrupted data
            userDefaults.removeObject(forKey: syncProgressKey)
        }
    }
}

// MARK: - Real-Time CloudKit Sync Management
extension EpisodeStateManager {
    
    /// Check if an episode was recently synced to prevent duplicates
    private func wasRecentlySynced(_ episodeId: String) -> Bool {
        let currentTime = Date().timeIntervalSince1970
        if let lastSyncTime = recentSyncs[episodeId] {
            let timeSinceLastSync = currentTime - lastSyncTime
            if timeSinceLastSync < syncDeduplicationWindow {
                print("📡 🔄 SYNC DEDUPLICATION: Skipping duplicate sync for \(episodeId) (last sync: \(String(format: "%.1f", timeSinceLastSync))s ago)")
                return true
            }
        }
        return false
    }
    
    /// Mark an episode as recently synced
    private func markAsRecentlySynced(_ episodeId: String) {
        let currentTime = Date().timeIntervalSince1970
        recentSyncs[episodeId] = currentTime
        
        // Clean up old entries to prevent memory bloat
        recentSyncs = recentSyncs.filter { currentTime - $0.value < syncDeduplicationWindow * 2 }
    }
    
    /// Mark episode real-time sync timing for UI refresh protection
    private func markEpisodeRealTimeSyncTime(_ episodeId: String) {
        let currentTime = Date().timeIntervalSince1970
        episodeLastRealTimeSyncTime[episodeId] = currentTime
        
        // Clean up old entries to prevent memory bloat
        episodeLastRealTimeSyncTime = episodeLastRealTimeSyncTime.filter { currentTime - $0.value < 10.0 }
    }
    
    /// Check if an episode was recently synced for UI refresh protection
    func wasEpisodeRecentlySynced(_ episodeId: String, within timeWindow: TimeInterval = 2.0) -> Bool {
        let currentTime = Date().timeIntervalSince1970
        if let lastSyncTime = episodeLastRealTimeSyncTime[episodeId] {
            let timeSinceLastSync = currentTime - lastSyncTime
            return timeSinceLastSync < timeWindow
        }
        return false
    }
    
    /// Perform real-time CloudKit sync for immediate cross-device updates
    func performRealTimeSyncForEpisode(_ episodeId: String, reason: String) {
        print("📡 🔄 REAL-TIME SYNC ENTRY: Called for \(episodeId) with reason: \(reason)")
        
        // SYNC DEDUPLICATION: Prevent duplicate syncs within short time window
        if wasRecentlySynced(episodeId) {
            print("📡 ⏭️ REAL-TIME SYNC SKIPPED: Episode \(episodeId) was recently synced (deduplication)")
            return
        }
        
        print("📡 ✅ REAL-TIME SYNC DEDUP: Episode \(episodeId) passed deduplication check")
        
        guard let feedId = getFeedId(for: episodeId), !feedId.isEmpty else {
            print("⚠️ REAL-TIME SYNC FAILED: Could not find feedId for episode \(episodeId), skipping CloudKit sync")
            return
        }
        
        print("📡 ✅ REAL-TIME SYNC FEEDID: Found feedId \(feedId) for episode \(episodeId)")
        
        // Call the efficient version with known feedId
        performRealTimeSyncForEpisode(episodeId, reason: reason, feedId: feedId)
    }
    
    /// Perform real-time CloudKit sync with known feedId (more efficient)
    func performRealTimeSyncForEpisode(_ episodeId: String, reason: String, feedId: String) {
        print("📡 🔄 REAL-TIME SYNC ENTRY: Called for \(episodeId) with reason: \(reason) and feedId: \(feedId)")
        
        // SYNC DEDUPLICATION: Prevent duplicate syncs within short time window
        if wasRecentlySynced(episodeId) {
            print("📡 ⏭️ REAL-TIME SYNC SKIPPED: Episode \(episodeId) was recently synced (deduplication)")
            return
        }
        
        print("📡 ✅ REAL-TIME SYNC DEDUP: Episode \(episodeId) passed deduplication check")
        
        // Mark as recently synced before starting sync
        markAsRecentlySynced(episodeId)
        
        // Mark episode-specific real-time sync timing
        markEpisodeRealTimeSyncTime(episodeId)
        
        let currentProgress = getProgress(for: episodeId)
        let currentFavorite = isFavorite(episodeId)
        let currentDownloaded = isDownloaded(episodeId)
        let currentPlayed = getIsPlayed(episodeId)
        
        print("📡 ⚡ REAL-TIME SYNC: Instantly syncing \(episodeId) to CloudKit (reason: \(reason))")
        print("📡 📊 REAL-TIME SYNC STATE: progress=\(currentProgress), favorite=\(currentFavorite), downloaded=\(currentDownloaded), played=\(currentPlayed)")
        
        // Perform both instant sync and persistent sync for real-time updates
        Task.detached(priority: .userInitiated) {
            // Step 1: Instant sync for real-time cross-device updates
            await PodcastCloudKitManager.shared.syncPodcastProgressInstantly(
                episodeId: episodeId,
                progress: currentProgress
            )
            
            await PodcastCloudKitManager.shared.syncPodcastFavoriteInstantly(
                episodeId: episodeId,
                isFavorite: currentFavorite
            )
            
            await PodcastCloudKitManager.shared.syncPodcastDownloadInstantly(
                episodeId: episodeId,
                isDownloaded: currentDownloaded
            )
            
            await PodcastCloudKitManager.shared.syncPodcastPlayedInstantly(
                episodeId: episodeId,
                isPlayed: currentPlayed
            )
            
            // Step 2: Persistent sync to CloudKit records
            await PodcastCloudKitManager.shared.saveEpisodeState(
                episodeId: episodeId,
                feedId: feedId,
                progress: currentProgress,
                isFavorite: currentFavorite,
                isDownloaded: currentDownloaded,
                isPlayed: currentPlayed
            )
            
            print("☁️ REAL-TIME SYNC: Completed instant sync for \(episodeId) (reason: \(reason))")
        }
    }
    
    /// Perform instant CloudKit sync only for allowed conditions (preserved for compatibility)
    func performInstantSyncForEpisode(_ episodeId: String, reason: String) {
        // Validate that this is an allowed sync condition
        let allowedReasons = ["favorite_action", "download_action", "episode_paused", "app_background", "app_closed"]
        guard allowedReasons.contains(reason) else {
            print("📡 ❌ CONDITIONAL SYNC: Rejected sync for \(episodeId) - reason '\(reason)' not allowed")
            return
        }
        
        // Use the real-time sync for allowed conditions
        performRealTimeSyncForEpisode(episodeId, reason: reason)
    }
    
    /// Perform conditional sync for multiple episodes (used by PodcastPlayer for pause/background/close)
    func performConditionalSyncForEpisodes(_ episodeIds: [String], reason: String) {
        for episodeId in episodeIds {
            performInstantSyncForEpisode(episodeId, reason: reason)
        }
    }
}
