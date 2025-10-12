// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import UIKit
import Foundation
import Combine
import CoreData
import UniformTypeIdentifiers
import CloudKit

// MARK: - Import Error Types
enum ImportError: Error {
    case invalidJSON(String)
    case invalidJSONStructure(String)
    case missingRequiredFields([String])
    case fileReadError(String)
    
    var userFriendlyMessage: String {
        switch self {
        case .invalidJSON(let details):
            return "The selected file contains invalid JSON format. Please check the file structure. Details: \(details)"
        case .invalidJSONStructure(let details):
            return "The JSON structure is not compatible. Expected an array of station objects. Details: \(details)"
        case .missingRequiredFields(let fields):
            return "Required fields are missing from the station data: \(fields.joined(separator: ", ")). Each station must have 'id', 'name', and 'url' fields."
        case .fileReadError(let details):
            return "Could not read the selected file. Details: \(details)"
        }
    }
}

// Sub-tab enum for radio filtering
enum RadioSubTab: Int, CaseIterable {
    case recent = 0
    case favorites = 1
    case all = 2
    
    var title: String {
        switch self {
        case .recent: return "Recent"
        case .favorites: return "Favorites"
        case .all: return "All"
        }
    }
    
    var iconName: String {
        switch self {
        case .recent: return "clock.fill"
        case .favorites: return "heart.fill"
        case .all: return "list.bullet"
        }
    }
}


class RadioStationViewModel: NSObject, ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var countries: [Country] = Country.getAllCountriesWithAPICodes()
    @Published var selectedTab: Tab = .radio
    @Published var selectedSubTab: RadioSubTab = .recent
    @Published var activeSheet: ActiveSheet? = nil
    @Published var isLoading = false
    @Published var isLoadingFromAPI = false
    @Published var isDeletingData: Bool = false
    @Published var deletionComplete: Bool = false
    @Published var isCloudKitOperationRunning = false
    @Published var isDeletionInProgress = false
    @Published var isUploadingToCloudKit = false
    @Published var isImportInProgress = false
    @Published var isAscendingSort = true
    
    // Flag to prevent API fetches until migration is complete
    private var isMigrationComplete = false
    
    // Progress tracking for station loading
    @Published var loadingProgress: Double = 0.0
    @Published var loadingStationsCount: Int = 0
    @Published var totalStationsToLoad: Int = 0
    
    // Track stations currently being processed for favicon updates to prevent duplicates
    private var stationsBeingProcessed: Set<String> = []
    private let processingQueue = DispatchQueue(label: "com.streamradios.favicon", qos: .utility)
    
    // Track current API fetch task to prevent multiple concurrent fetches
    private var currentFetchTask: Task<Void, Never>?
    @Published var loadingPhase: String = ""
    
    // Flag to prevent infinite loop in favorite timestamp migration
    private var isMigrationInProgress = false
    
    // MARK: - Radio Station Snapshots (Performance Optimization)
    
    /// Cache for radio station snapshots by country for instant access
    private var stationSnapshotCache: [String: [RadioStation]] = [:]
    
    /// Timestamps for snapshot creation to manage cleanup
    private var snapshotTimestamps: [String: Date] = [:]
    
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country" {
        didSet {
            print("🌍 Country selection changed from '\(oldValue)' to '\(selectedCountry)'")
            
            // Only proceed if the country actually changed and it's not "Select Country"
            if oldValue != selectedCountry && selectedCountry != "Select Country" {
                // Switch to All tab when country changes (except during initialization)
                selectedSubTab = .all
                print("🌍 Country changed from '\(oldValue)' to '\(selectedCountry)' - switching to All tab")
                
                // STABILITY FIX: Preserve currently playing station display during country changes
                // The currently playing station should remain stable regardless of country picker changes
                if let currentStation = RadioPlayer.shared.currentlyPlayingStation {
                    print("📍 STABILITY: Preserving currently playing station '\(currentStation.name)' from '\(currentStation.country)' during country change")
                    print("📍 STABILITY: Station display will remain consistent regardless of country picker selection")
                }
                
                // CRITICAL FIX: Force migration for all countries except US and UK to handle API name variations
                if selectedCountry != "United States" && selectedCountry != "United Kingdom" && selectedCountry != "Select Country" && selectedCountry != "Unknown Region" {
                    print("🔧 Forcing migration for country name normalization: \(selectedCountry)")
                    Task { @MainActor in
                        forceMigrateStationCountryNames()
                    }
                }
                
                // Station fetching is now handled manually by the UI when user taps on country
                print("🌍 Country changed to: \(selectedCountry) - stations will be fetched when user selects country")
            } else if oldValue == selectedCountry {
                print("🌍 Country selection unchanged, skipping API fetch")
            } else if selectedCountry == "Select Country" {
                print("🌍 Reset to 'Select Country', skipping API fetch")
            } else {
                print("🌍 Skipping API fetch - oldValue: '\(oldValue)', selectedCountry: '\(selectedCountry)'")
            }
            
            saveSelectedCountry()
            NotificationCenter.default.post(name: .countrySelected, object: nil)
            NotificationCenter.default.post(name: .countryChanged, object: nil)
        }
    }
    private var notificationManager = NotificationManager.shared
    private var backgroundObserver: NSObjectProtocol?
    static let shared = RadioStationViewModel()
    
    // Track manually deleted station IDs to prevent re-fetching
    private let deletedStationIdsKey = "DeletedStationIds"
    private var deletedStationIds: Set<String> {
        get {
            let array = UserDefaults.standard.array(forKey: deletedStationIdsKey) as? [String] ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: deletedStationIdsKey)
        }
    }
    
    var currentlyPlayingStation: RadioStation? {
            guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
                  stations.indices.contains(currentStationIndex) else {
                return nil
            }
            return stations[currentStationIndex]
        }
    
    enum ActiveSheet: Identifiable {
        case editStation
        var id: Int {
            self.hashValue
        }
    }
    
    private func saveSelectedCountry() {
        UserDefaults.standard.set(selectedCountry, forKey: "selectedCountry")
    }
    

    

    
    override init() {
        super.init()
        
            selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country"
            
            // Always start with Recent tab (no persistence)
            selectedSubTab = .recent
            
            // Listen for hidden countries changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHiddenCountriesChanged(_:)),
                name: .hiddenCountriesChanged,
                object: nil
            )
            
            // Listen for selected country cleared
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectedCountryCleared),
                name: .selectedCountryCleared,
                object: nil
            )
            
            // Load sorting preferences
            loadSortingPreferences()
        
            // PERFORMANCE FIX: Only sync radio stations from CloudKit on fresh installs
            // Check if radio stations have been synced to prevent unnecessary CloudKit fetching
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
            
            if isFreshInstall || !hasRadioStationsSynced {
                print("🔄 Radio station sync needed in ViewModel - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                print("⏭️ SEQUENCING: Radio station sync will be handled by DataSyncManager to prevent CloudKit rate limiting")
                // NOTE: Radio station sync is now handled by DataSyncManager in sequence to prevent CloudKit rate limiting
                // syncStationsWithCloudKit() - REMOVED to prevent parallel CloudKit operations
            } else {
                print("⚡ Skipping CloudKit radio station sync in ViewModel - loading from local storage only for better performance")
                
                // Only check for CloudKit changes if we haven't done a complete check recently or if changes are expected
                Task {
                    await checkForCloudKitChangesIfNeeded()
                }
            }
    
            loadStationsFromCoreData()
            
            // Migrate existing stations to use normalized country names (one-time migration)
            // CRITICAL: Run synchronously to prevent race conditions with API fetches
            Task { @MainActor in
                await migrateStationCountryNames()
                self.isMigrationComplete = true
                
                // CROSS-COUNTRY CONTAMINATION PREVENTION: Run cleanup after migration
                await checkAndPerformContaminationCleanupIfNeeded()
            }
            
            let userDefaults = UserDefaults.standard
            let hasLaunchedBeforeKey = "HasLaunchedBefore"
            
            if !userDefaults.bool(forKey: hasLaunchedBeforeKey) {
                print("First time setup or new default stations detected, initializing default stations and saving to local and CloudKit.")
                initializeStationsForFirstTime()
            } else {
                print("App relaunch detected.")
                // Removed the second syncStationsWithCloudKit() call for performance optimization
            }
            
            // INSTANT STARTUP: Skip automatic API refresh on startup to show cached stations immediately
            // Users can manually refresh if they want fresh stations from the API
            // This ensures cached stations appear instantly without any loading states
            if selectedCountry != "Select Country" {
                print("⚡ Instant startup: Showing cached stations for \(selectedCountry). API refresh available via manual refresh.")
            }
            
            // Setup instant sync listener for real-time cross-device updates
            setupInstantSyncListener()
        }
    
    // MARK: - Instant Sync Listener
    
    private func setupInstantSyncListener() {
        // Legacy instant sync notifications (keeping for backward compatibility)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantRadioFavoriteSync),
            name: .init("InstantSyncDidUpdateRadioFavorite"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantRadioStationAddedSync),
            name: .init("InstantSyncDidAddRadioStation"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantRadioStationRemovedSync),
            name: .init("InstantSyncDidRemoveRadioStation"),
            object: nil
        )
        
        // New enhanced CloudKit sync notifications from RadioStationCloudKitManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitStationUpdatedSync(_:)),
            name: .init("CloudKitDidUpdateRadioStation"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitStationAddedSync(_:)),
            name: .init("CloudKitDidAddRadioStation"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitStationDeletedSync(_:)),
            name: .init("CloudKitDidDeleteRadioStation"),
            object: nil
        )
        
        // Enhanced instant sync notifications from RadioStationCloudKitManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantStationUpdatedSync(_:)),
            name: .init("InstantSyncDidUpdateRadioStation"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantStationDeletedSync(_:)),
            name: .init("InstantSyncDidDeleteRadioStation"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantFavoriteChangedSync(_:)),
            name: .init("InstantSyncDidChangeFavorite"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstantOrderChangedSync(_:)),
            name: .init("InstantSyncDidChangeOrder"),
            object: nil
        )
    }
    
    @objc private func handleInstantRadioFavoriteSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool,
              let index = stations.firstIndex(where: { $0.id == stationId }) else {
            return
        }
        
        // Update station favorite status from remote sync
        var updatedStation = stations[index]
        let wasAlreadyFavorite = updatedStation.isFavorite
        
        // Only update if the value actually changed to avoid infinite loops
        if wasAlreadyFavorite != isFavorite {
            updatedStation.isFavorite = isFavorite
            
            if isFavorite {
                updatedStation.favoritedAt = Date()
                updatedStation.favoriteOrder = 0
            } else {
                updatedStation.favoritedAt = nil
                updatedStation.favoriteOrder = nil
            }
            
            stations[index] = updatedStation
            saveStationsToCoreData()
            
            print("📡 Applied instant radio favorite sync: \(stationId) (favorite: \(isFavorite))")
        }
    }
    
    @objc private func handleInstantRadioStationAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationData = userInfo["station"] as? [String: Any] else {
            return
        }
        
        // Convert dictionary back to RadioStation
        if let station = radioStationFromDictionary(stationData) {
            // Check if station already exists to avoid duplicates
            if !stations.contains(where: { $0.id == station.id }) {
                stations.append(station)
                saveStationsToCoreData()
                
                print("📡 Applied instant radio station addition sync: \(station.name)")
            }
        }
    }
    
    @objc private func handleInstantRadioStationRemovedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            return
        }
        
        // Remove station if it exists
        if let index = stations.firstIndex(where: { $0.id == stationId }) {
            let stationName = stations[index].name
            stations.remove(at: index)
            saveStationsToCoreData()
            
            print("📡 Applied instant radio station removal sync: \(stationName)")
        }
    }
    
    // MARK: - Enhanced CloudKit Sync Handlers
    
    @objc private func handleCloudKitStationUpdatedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            print("📡 ☁️ CLOUDKIT STATION UPDATE FAILED: Invalid station ID in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT STATION UPDATE: Received station update from CloudKit: \(stationId)")
        
        // Trigger a refresh of the specific station from CloudKit
        Task {
            await refreshStationFromCloudKit(stationId: stationId)
        }
    }
    
    @objc private func handleCloudKitStationAddedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            print("📡 ☁️ CLOUDKIT STATION ADD FAILED: Invalid station ID in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT STATION ADD: Received station addition from CloudKit: \(stationId)")
        
        // Trigger a refresh to get the new station
        Task {
            await refreshStationFromCloudKit(stationId: stationId)
        }
    }
    
    @objc private func handleCloudKitStationDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            print("📡 ☁️ CLOUDKIT STATION DELETE FAILED: Invalid station ID in notification")
            return
        }
        
        print("📡 ☁️ CLOUDKIT STATION DELETE: Received station deletion from CloudKit: \(stationId)")
        
        // Remove station if it exists
        if let index = stations.firstIndex(where: { $0.id == stationId }) {
            let stationName = stations[index].name
            
            DispatchQueue.main.async {
                self.stations.remove(at: index)
                self.saveStationsToCoreData()
                
                print("📡 ☁️ CLOUDKIT STATION DELETE: ✅ Removed station from CloudKit deletion: \(stationName)")
            }
        } else {
            print("📡 ☁️ CLOUDKIT STATION DELETE: Station not found locally: \(stationId)")
        }
    }
    
    @objc private func handleInstantStationUpdatedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            print("📡 🔔 INSTANT STATION UPDATE FAILED: Invalid station ID in notification")
            return
        }
        
        print("📡 🔔 INSTANT STATION UPDATE: Received real-time station update: \(stationId)")
        
        // Trigger a refresh of the specific station from CloudKit
        Task {
            await refreshStationFromCloudKit(stationId: stationId)
        }
    }
    
    @objc private func handleInstantStationDeletedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String else {
            print("📡 🔔 INSTANT STATION DELETE FAILED: Invalid station ID in notification")
            return
        }
        
        print("📡 🔔 INSTANT STATION DELETE: Received real-time station deletion: \(stationId)")
        
        // Remove station if it exists
        if let index = stations.firstIndex(where: { $0.id == stationId }) {
            let stationName = stations[index].name
            
            DispatchQueue.main.async {
                self.stations.remove(at: index)
                self.saveStationsToCoreData()
                
                print("📡 🔔 INSTANT STATION DELETE: ✅ Applied real-time deletion: \(stationName)")
            }
        } else {
            print("📡 🔔 INSTANT STATION DELETE: Station not found locally: \(stationId)")
        }
    }
    
    @objc private func handleInstantFavoriteChangedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("📡 🔔 INSTANT FAVORITE CHANGE FAILED: Invalid data in notification")
            return
        }
        
        print("📡 🔔 INSTANT FAVORITE CHANGE: Received real-time favorite change: \(stationId) (favorite: \(isFavorite))")
        
        // Find and update the station
        if let index = stations.firstIndex(where: { $0.id == stationId }) {
            var updatedStation = stations[index]
            let wasAlreadyFavorite = updatedStation.isFavorite
            
            // Only update if the value actually changed to avoid infinite loops
            if wasAlreadyFavorite != isFavorite {
                updatedStation.isFavorite = isFavorite
                
                if isFavorite {
                    // Use provided timestamp or current time
                    updatedStation.favoritedAt = userInfo["favoritedAt"] as? Date ?? Date()
                    updatedStation.favoriteOrder = userInfo["favoriteOrder"] as? Int ?? 0
                } else {
                    updatedStation.favoritedAt = nil
                    updatedStation.favoriteOrder = nil
                }
                
                DispatchQueue.main.async {
                    self.stations[index] = updatedStation
                    self.saveStationsToCoreData()
                    
                    print("📡 🔔 INSTANT FAVORITE CHANGE: ✅ Applied real-time favorite change: \(stationId) (favorite: \(isFavorite))")
                }
            }
        } else {
            print("📡 🔔 INSTANT FAVORITE CHANGE: Station not found locally: \(stationId)")
        }
    }
    
    @objc private func handleInstantOrderChangedSync(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            print("📡 🔔 INSTANT ORDER CHANGE FAILED: No data in notification")
            return
        }
        
        print("📡 🔔 INSTANT ORDER CHANGE: Received real-time order change from CloudKit")
        
        // Extract action type from notification
        if let action = userInfo["action"] as? String {
            print("📡 🔔 INSTANT ORDER CHANGE: Action type: \(action)")
            
            Task {
                await handleOrderChangeSync(action: action)
            }
        } else {
            print("📡 🔔 INSTANT ORDER CHANGE: No action specified, doing full refresh")
            Task {
                await refreshStationsFromCloudKit()
            }
        }
    }
    
    /// Handle specific order change sync actions
    private func handleOrderChangeSync(action: String) async {
        switch action {
        case "order_changed":
            print("📡 🔔 INSTANT ORDER CHANGE: Handling station list order change")
            await refreshStationsFromCloudKit()
        case "favorite_order_changed":
            print("📡 🔔 INSTANT ORDER CHANGE: Handling favorites order change")
            await refreshStationsFromCloudKit()
        default:
            print("📡 🔔 INSTANT ORDER CHANGE: Unknown action '\(action)', doing full refresh")
            await refreshStationsFromCloudKit()
        }
    }
    
    // MARK: - Automatic CloudKit Change Detection
    
    /// Smart CloudKit change detection that only runs when needed
    private func checkForCloudKitChangesIfNeeded() async {
        print("🔍 Checking if CloudKit change detection is needed...")
        
        // Check if we've already done a complete sync check recently
        let lastSyncCheckTime = UserDefaults.standard.object(forKey: "LastSyncCheckTime") as? Date ?? Date.distantPast
        let timeSinceLastCheck = Date().timeIntervalSince(lastSyncCheckTime)
        let minimumCheckInterval: TimeInterval = 3600 // 1 hour between automatic checks
        
        // Only run sync check if:
        // 1. It's been more than 1 hour since last check, OR
        // 2. There's a flag indicating changes are expected, OR  
        // 3. We've never done a sync check before
        let shouldPerformCheck = timeSinceLastCheck > minimumCheckInterval || 
                                UserDefaults.standard.bool(forKey: "ExpectingCloudKitChanges") ||
                                lastSyncCheckTime == Date.distantPast
        
        if shouldPerformCheck {
            print("✅ Performing CloudKit change detection - last check: \(Int(timeSinceLastCheck))s ago")
            await checkForCloudKitChangesOnLaunch()
        } else {
            print("⏭️ Skipping CloudKit change detection - checked recently (\(Int(timeSinceLastCheck))s ago)")
        }
    }
    
    /// Check for CloudKit changes on app launch and trigger sync banner if needed
    private func checkForCloudKitChangesOnLaunch() async {
        print("🔍 Checking for CloudKit changes on app launch...")
        
        do {
            // Get the count of stations in CloudKit
            let cloudKitStationCount = try await RadioStationCloudKitManager.shared.getCloudKitStationCount()
            let localStationCount = stations.count
            
            print("📊 Station count comparison - CloudKit: \(cloudKitStationCount), Local: \(localStationCount)")
            
            // Check if there are more stations in CloudKit than locally (new stations added on other devices)
            if cloudKitStationCount > localStationCount {
                let newStationsCount = cloudKitStationCount - localStationCount
                print("🆕 Detected \(newStationsCount) new stations in CloudKit")
                
                // CRITICAL PERFORMANCE: Defer radio station sync to prevent CPU spikes during episode loading
                // Schedule sync for later to avoid interfering with podcast operations
                print("⚡ PERFORMANCE: Deferring radio station sync to prevent interference with podcast loading")
                
                await MainActor.run {
                    // Update DataSyncManager to show that sync is needed but deferred
                    DataSyncManager.shared.radioStationsOperation = "\(newStationsCount) new stations available - will sync when convenient"
                }
                
                // Schedule deferred sync (10 seconds delay to allow podcast operations to complete)
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 second delay
                    
                    print("⏰ DEFERRED SYNC: Starting radio station sync after delay")
                    
                    await MainActor.run {
                        DataSyncManager.shared.radioStationsStatus = .inProgress
                        DataSyncManager.shared.radioStationsOperation = "Loading \(newStationsCount) new stations from other devices"
                        DataSyncManager.shared.radioStationsProgress = 0.0
                        DataSyncManager.shared.radioStationsTotalCount = cloudKitStationCount
                        DataSyncManager.shared.radioStationsCurrentCount = localStationCount
                    }
                    
                    // Trigger the sync with progress tracking
                    await self.syncStationsFromCloudKitWithProgress()
                }
                
            } else if cloudKitStationCount < localStationCount {
                // More stations locally than in CloudKit (stations deleted on other devices)
                let deletedStationsCount = localStationCount - cloudKitStationCount
                print("🗑️ Detected \(deletedStationsCount) stations deleted on other devices")
                
                // SAFETY CHECK: Don't trigger mass deletion if the discrepancy is too large
                // This could indicate CloudKit issues, migration, or other problems
                let discrepancyPercentage = Double(deletedStationsCount) / Double(localStationCount)
                if discrepancyPercentage > 0.5 { // More than 50% discrepancy
                    print("⚠️ SAFETY: Large station count discrepancy detected (\(Int(discrepancyPercentage * 100))%)")
                    print("⚠️ SAFETY: CloudKit: \(cloudKitStationCount), Local: \(localStationCount)")
                    print("⚠️ SAFETY: Skipping automatic deletion sync to prevent data loss")
                    print("⚠️ SAFETY: This may be due to migration, CloudKit issues, or data corruption")
                    
                    // Check if we've recently attempted recovery to avoid infinite loops
                    let lastRecoveryTime = UserDefaults.standard.object(forKey: "LastDiscrepancyRecoveryTime") as? Date ?? Date.distantPast
                    let timeSinceLastRecovery = Date().timeIntervalSince(lastRecoveryTime)
                    
                    if timeSinceLastRecovery > 3600 { // Only attempt recovery once per hour
                        // Offer recovery options
                        await handleLargeDiscrepancy(cloudKitCount: cloudKitStationCount, localCount: localStationCount)
                    } else {
                        print("⚠️ SAFETY: Recovery attempted recently, skipping to prevent loops")
                        print("⚠️ SAFETY: Next recovery attempt available in \(Int(3600 - timeSinceLastRecovery)) seconds")
                    }
                    return
                }
                
                print("🗑️ Proceeding with deletion sync for \(deletedStationsCount) stations...")
                
                await MainActor.run {
                    // Update DataSyncManager to show sync banner  
                    DataSyncManager.shared.radioStationsStatus = .inProgress
                    DataSyncManager.shared.radioStationsOperation = "Loading station deletions from other devices..."
                    DataSyncManager.shared.radioStationsProgress = 0.0
                    DataSyncManager.shared.radioStationsTotalCount = cloudKitStationCount
                    DataSyncManager.shared.radioStationsCurrentCount = localStationCount
                }
                
                // Trigger the sync with progress tracking
                await syncStationsFromCloudKitWithProgress()
                
            } else {
                // Station counts match - only sync if there are significant changes worth showing to user
                print("📊 Station counts match (\(localStationCount)), checking for significant modifications...")
                
                // Be more conservative: only check for modifications if the user hasn't synced recently
                let lastSyncTime = UserDefaults.standard.object(forKey: "LastCloudKitSyncTime") as? Date ?? Date.distantPast
                let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
                let minimumSyncInterval: TimeInterval = 300 // 5 minutes
                
                if timeSinceLastSync > minimumSyncInterval {
                    let hasModifications = try await RadioStationCloudKitManager.shared.checkForStationModifications(localStations: stations)
                    
                    if hasModifications {
                        print("📝 Detected station modifications on other devices, triggering sync")
                        
                        await MainActor.run {
                            // Update DataSyncManager to show sync banner
                            DataSyncManager.shared.radioStationsStatus = .inProgress
                            DataSyncManager.shared.radioStationsOperation = "Loading station updates from other devices"
                            DataSyncManager.shared.radioStationsProgress = 0.0
                            DataSyncManager.shared.radioStationsTotalCount = cloudKitStationCount
                            DataSyncManager.shared.radioStationsCurrentCount = 0
                        }
                        
                        // Trigger the sync with progress tracking
                        await syncStationsFromCloudKitWithProgress()
                    } else {
                        print("✅ No significant CloudKit changes detected - station counts and modification times match")
                        print("ℹ️ Skipping sync banner - no changes needed")
                    }
                } else {
                    print("⏭️ Skipping modification check - synced recently (\(Int(timeSinceLastSync))s ago)")
                    print("ℹ️ Skipping sync banner - no changes needed")
                }
            }
            
        } catch {
            print("❌ Failed to check CloudKit changes: \(error)")
            // Don't trigger sync on error to avoid unnecessary network requests
        }
        
        // Mark that we've completed a sync check and clear any expectation flags
        UserDefaults.standard.set(Date(), forKey: "LastSyncCheckTime")
        UserDefaults.standard.set(false, forKey: "ExpectingCloudKitChanges")
        print("📝 Sync check completed and timestamp saved")
    }
    
    /// Mark that CloudKit changes are expected and should be checked on next launch
    @MainActor
    func markCloudKitChangesExpected() {
        UserDefaults.standard.set(true, forKey: "ExpectingCloudKitChanges")
        print("🔔 Marked CloudKit changes as expected - will check on next sync opportunity")
    }
    
    /// Force a CloudKit change check on the next app launch (useful after manual changes)
    @MainActor  
    func forceCloudKitCheckOnNextLaunch() {
        UserDefaults.standard.set(Date.distantPast, forKey: "LastSyncCheckTime")
        UserDefaults.standard.set(true, forKey: "ExpectingCloudKitChanges")
    }
    
    // MARK: - Cross-Country Contamination Prevention
    
    /// Validate and clean stations to prevent cross-country contamination
    private func validateAndCleanStationsCountry(_ stations: [RadioStation]) -> [RadioStation] {
        var validatedStations: [RadioStation] = []
        var contaminationCount = 0
        
        for station in stations {
            if isStationCountryValid(station) {
                validatedStations.append(station)
            } else {
                contaminationCount += 1
                print("🚨 CONTAMINATION BLOCKED: Station '\(station.name)' (Country: '\(station.country)') failed validation")
                
                // Try to fix the country if possible
                if let correctedStation = attemptStationCountryCorrection(station) {
                    validatedStations.append(correctedStation)
                    print("🛡️ CONTAMINATION FIXED: Corrected station '\(station.name)' country to '\(correctedStation.country)'")
                } else {
                    print("🗑️ CONTAMINATION REMOVED: Discarded station '\(station.name)' - could not determine correct country")
                }
            }
        }
        
        if contaminationCount > 0 {
            print("🛡️ CONTAMINATION PREVENTION: Blocked/fixed \(contaminationCount) contaminated stations out of \(stations.count) total")
        }
        
        return validatedStations
    }
    
    /// Check if a station's country assignment is valid
    private func isStationCountryValid(_ station: RadioStation) -> Bool {
        let stationName = station.name.lowercased()
        let stationCountry = station.country
        
        // Check for obvious country mismatches based on station names
        
        // Italian stations should only be in Italy
        if stationCountry != "Italy" && isItalianStation(stationName) {
            return false
        }
        
        // UK stations should only be in United Kingdom
        if stationCountry != "United Kingdom" && isUKStation(stationName) {
            return false
        }
        
        // German stations should only be in Germany
        if stationCountry != "Germany" && isGermanStation(stationName) {
            return false
        }
        
        // French stations should only be in France
        if stationCountry != "France" && isFrenchStation(stationName) {
            return false
        }
        
        // Spanish stations should only be in Spain
        if stationCountry != "Spain" && isSpanishStation(stationName) {
            return false
        }
        
        // US stations should only be in United States
        if stationCountry != "United States" && isUSStation(stationName) {
            return false
        }
        
        // Add more country validations as needed
        
        return true
    }
    
    /// Attempt to correct a station's country assignment
    private func attemptStationCountryCorrection(_ station: RadioStation) -> RadioStation? {
        let stationName = station.name.lowercased()
        var correctedStation = station
        
        // Attempt to determine correct country based on station name
        if isItalianStation(stationName) {
            correctedStation.country = "Italy"
            return correctedStation
        } else if isUKStation(stationName) {
            correctedStation.country = "United Kingdom"
            return correctedStation
        } else if isGermanStation(stationName) {
            correctedStation.country = "Germany"
            return correctedStation
        } else if isFrenchStation(stationName) {
            correctedStation.country = "France"
            return correctedStation
        } else if isSpanishStation(stationName) {
            correctedStation.country = "Spain"
            return correctedStation
        } else if isUSStation(stationName) {
            correctedStation.country = "United States"
            return correctedStation
        }
        
        // Could not determine correct country
        return nil
    }
    
    // MARK: - Country Detection Helpers
    
    private func isItalianStation(_ name: String) -> Bool {
        return name.contains("radio rai") || 
               name.contains("rai radio") ||
               name.contains("radio italia") ||
               name.contains("virgin radio italia") ||
               name.contains("radio kiss kiss") ||
               name.contains("radio norba") ||
               name.contains("radio monte carlo") ||
               name.hasPrefix("rai ") ||
               name.contains("radio maria") ||
               name.contains("radio popolare") ||
               name.contains("radio deejay") ||
               name.contains("radio 105") ||
               name.contains("rtl 102.5") ||
               name.contains("radio capitale") ||
               name.contains("radio 24") ||
               name.contains("radio lombardia")
    }
    
    private func isUKStation(_ name: String) -> Bool {
        return name.contains("bbc") ||
               name.contains("talksport") ||
               name.contains("talkradio") ||
               name.contains("virgin radio uk") ||
               name.contains("smooth radio") ||
               name.contains("resonance fm") ||
               name.contains("sky news uk") ||
               name.contains("gb news") ||
               name.contains("capital fm") ||
               name.contains("heart radio") ||
               name.contains("magic radio") ||
               name.contains("classic fm") ||
               name.contains("lbc") ||
               name.contains("radio x")
    }
    
    private func isGermanStation(_ name: String) -> Bool {
        return name.contains("deutschlandfunk") ||
               name.contains("wdr") ||
               name.contains("swr") ||
               name.contains("ndr") ||
               name.contains("br klassik") ||
               name.contains("hr") ||
               name.contains("mdr") ||
               name.contains("rbb") ||
               name.contains("antenne bayern") ||
               name.contains("radio ffh") ||
               name.contains("1live")
    }
    
    private func isFrenchStation(_ name: String) -> Bool {
        return name.contains("france inter") ||
               name.contains("france info") ||
               name.contains("france culture") ||
               name.contains("france musique") ||
               name.contains("rtl france") ||
               name.contains("europe 1") ||
               name.contains("rmc") ||
               name.contains("nostalgie france") ||
               name.contains("nrj france") ||
               name.contains("skyrock")
    }
    
    private func isSpanishStation(_ name: String) -> Bool {
        return name.contains("radio nacional") ||
               name.contains("cadena ser") ||
               name.contains("cope") ||
               name.contains("onda cero") ||
               name.contains("radio marca") ||
               name.contains("esradio") ||
               name.contains("radio intereconomía") ||
               name.contains("catalunya radio") ||
               name.contains("rac1")
    }
    
    private func isUSStation(_ name: String) -> Bool {
        return name.contains("npr") ||
               name.contains("cnn") ||
               name.contains("fox news") ||
               name.contains("msnbc") ||
               name.contains("bloomberg") ||
               name.contains("espn radio") ||
               name.contains("siriusxm") ||
               name.contains("iheartradio") ||
               name.contains("kqed") ||
               name.contains("wnyc") ||
               name.contains("wxrt") ||
               name.contains("kroq")
    }
    
    // MARK: - Data Integrity & Cleanup
    
    /// Perform comprehensive cleanup of cross-country contamination
    @MainActor
    func performCrossCountryContaminationCleanup() async {
        print("🛡️ STARTING COMPREHENSIVE CROSS-COUNTRY CONTAMINATION CLEANUP")
        
        let originalCount = stations.count
        
        // Apply validation and cleanup to all stations
        let cleanedStations = validateAndCleanStationsCountry(stations)
        let removedCount = originalCount - cleanedStations.count
        
        if removedCount > 0 {
            stations = cleanedStations
            
            // Save cleaned data to Core Data
            saveStationsToCoreData()
            
            // Also clean up CloudKit by uploading the cleaned data
            syncStationsWithCloudKit()
            
            print("🛡️ CONTAMINATION CLEANUP COMPLETE: Removed/corrected \(removedCount) contaminated stations out of \(originalCount) total")
            print("🛡️ CLEAN STATIONS REMAINING: \(stations.count)")
            
            // Force UI refresh
            objectWillChange.send()
        } else {
            print("🛡️ CONTAMINATION CLEANUP: No contaminated stations found - data is clean")
        }
    }
    
    /// Check if the data needs contamination cleanup (run on app launch)
    @MainActor
    func checkAndPerformContaminationCleanupIfNeeded() async {
        let lastCleanupVersion = UserDefaults.standard.string(forKey: "LastContaminationCleanupVersion") ?? "0.0.0"
        let currentVersion = "2.0.6" // Update this when making cleanup improvements
        
        if lastCleanupVersion != currentVersion {
            print("🛡️ CONTAMINATION CHECK: Running cleanup for version \(currentVersion) (last cleanup: \(lastCleanupVersion))")
            await performCrossCountryContaminationCleanup()
            
            // Mark cleanup as completed for this version
            UserDefaults.standard.set(currentVersion, forKey: "LastContaminationCleanupVersion")
        } else {
            print("🛡️ CONTAMINATION CHECK: Data already cleaned for version \(currentVersion)")
        }
    }
    
    /// Merge CloudKit stations with local state to preserve Recent, Favorites, and other local data
    private func mergeCloudKitStationsWithLocalState(_ cloudKitStations: [RadioStation]) {
        
        // CROSS-COUNTRY CONTAMINATION PREVENTION: Validate and filter CloudKit stations
        let validatedCloudKitStations = validateAndCleanStationsCountry(cloudKitStations)
        print("🛡️ COUNTRY VALIDATION: Filtered \(cloudKitStations.count - validatedCloudKitStations.count) contaminated stations from CloudKit")
        
        // Create a dictionary of current local stations by ID for fast lookup
        var localStationsById: [String: RadioStation] = [:]
        for station in stations {
            localStationsById[station.id] = station
        }
        
        // Merge CloudKit stations with preserved local state
        var mergedStations: [RadioStation] = []
        
        for cloudKitStation in validatedCloudKitStations {
            if let localStation = localStationsById[cloudKitStation.id] {
                // Station exists locally - merge CloudKit data with local state
                var mergedStation = cloudKitStation
                
                // CRITICAL IMPORT PROTECTION: Preserve user-imported custom data
                if localStation.iconData != nil || localStation.iTunesArtworkData != nil {
                    print("🛡️ IMPORT PROTECTION: Preserving custom icon data for user-imported station '\(localStation.name)'")
                    mergedStation.iconData = localStation.iconData
                    mergedStation.iTunesArtworkData = localStation.iTunesArtworkData
                }
                
                // CROSS-COUNTRY CONTAMINATION PREVENTION: Validate country consistency
                if localStation.country != cloudKitStation.country {
                    print("🚨 COUNTRY CONTAMINATION DETECTED: Station '\(cloudKitStation.name)' has mismatched countries - Local: '\(localStation.country)' vs CloudKit: '\(cloudKitStation.country)'")
                    // Keep local country as it's more trusted (user has been using it)
                    mergedStation.country = localStation.country
                    print("🛡️ COUNTRY PROTECTION: Preserved local country '\(localStation.country)' for station '\(cloudKitStation.name)'")
                }
                
                // PRESERVE LOCAL STATE: These fields should never be overwritten by CloudKit
                mergedStation.lastPlayed = localStation.lastPlayed  // Preserve Recent stations
                
                // Favorites priority policy:
                // - If CloudKit has favorite metadata, always prefer CloudKit's favoriteOrder to avoid
                //   local UserDefaults/UI sorting from overriding the server source of truth.
                // - If CloudKit lacks favorite metadata but local has it (offline/new device), preserve local state.
                if cloudKitStation.favoritedAt != nil || cloudKitStation.favoriteOrder != nil {
                    mergedStation.isFavorite = cloudKitStation.isFavorite
                    mergedStation.favoritedAt = cloudKitStation.favoritedAt
                    mergedStation.favoriteOrder = cloudKitStation.favoriteOrder
                } else if localStation.favoritedAt != nil || localStation.favoriteOrder != nil {
                    mergedStation.isFavorite = localStation.isFavorite
                    mergedStation.favoritedAt = localStation.favoritedAt
                    mergedStation.favoriteOrder = localStation.favoriteOrder
                }
                
                mergedStations.append(mergedStation)
            } else {
                // New station from CloudKit - add as-is (already validated)
                mergedStations.append(cloudKitStation)
            }
        }
        
        // Update the stations array with merged data, but never drop local stations
        // that aren't present in CloudKit yet (e.g., just-added API stations waiting for upload).
        // Merge-in any local-only stations by URL to avoid duplicates.
        // Handle potential duplicate URLs in mergedStations
        var mergedByURL: [String: RadioStation] = [:]
        for station in mergedStations {
            let key = station.url.lowercased()
            if mergedByURL[key] != nil {
                print("🔄 Duplicate station URL '\(key)' found in CloudKit merge - keeping first occurrence")
            } else {
                mergedByURL[key] = station
            }
        }
        for local in stations {
            let key = local.url.lowercased()
            if mergedByURL[key] == nil {
                mergedByURL[key] = local
            } else {
                // CRITICAL IMPORT PROTECTION: If local station has custom data, preserve it over CloudKit version
                let existingStation = mergedByURL[key]!
                if (local.iconData != nil || local.iTunesArtworkData != nil) && 
                   (existingStation.iconData == nil && existingStation.iTunesArtworkData == nil) {
                    print("🛡️ IMPORT PROTECTION: Replacing CloudKit station with user-imported version for '\(local.name)'")
                    mergedByURL[key] = local
                }
            }
        }
        stations = Array(mergedByURL.values)
        
        // Log recent stations count for verification
        let recentCount = stations.filter { $0.lastPlayed != nil }.count
        let favoriteCount = stations.filter { $0.isFavorite }.count
    }
    
    /// Sync stations from CloudKit with progress tracking for automatic sync
    private func syncStationsFromCloudKitWithProgress() async {
        print("🔄 Starting automatic CloudKit sync with progress tracking")
        
        do {
            // Use DataStore's fetchRadioStationsWithProgress for banner integration
            await withCheckedContinuation { continuation in
                DataStore.shared.fetchRadioStationsWithProgress(
                    progressCallback: { [weak self] progress, count, message in
                        Task { @MainActor in
                            DataSyncManager.shared.radioStationsProgress = progress
                            DataSyncManager.shared.radioStationsCurrentCount = count
                            DataSyncManager.shared.radioStationsOperation = message
                            // Estimate total based on current progress and count
                            if progress > 0.1 && count > 0 {
                                let estimatedTotal = Int(Double(count) / progress)
                                DataSyncManager.shared.radioStationsTotalCount = max(DataSyncManager.shared.radioStationsTotalCount, estimatedTotal)
                            }
                        }
                    },
                    completion: { [weak self] stations, error in
                        if let cloudKitStations = stations {
                            DispatchQueue.main.async {
                                // CRITICAL: Merge CloudKit data with local state instead of replacing
                                // This preserves Recent stations (lastPlayed), local favorites, and other local state
                                self?.mergeCloudKitStationsWithLocalState(cloudKitStations)
                                self?.saveStationsToCoreData()
                                
                                // Update final progress
                                Task { @MainActor in
                                    DataSyncManager.shared.radioStationsCurrentCount = self?.stations.count ?? cloudKitStations.count
                                    DataSyncManager.shared.radioStationsTotalCount = self?.stations.count ?? cloudKitStations.count
                                    DataSyncManager.shared.radioStationsOperation = "✅ \(self?.stations.count ?? cloudKitStations.count) stations synced from other devices"
                                    DataSyncManager.shared.radioStationsStatus = .completed
                                    DataSyncManager.shared.radioStationsProgress = 1.0
                                    
                                    // Update the last sync time to prevent false positives on next check
                                    UserDefaults.standard.set(Date(), forKey: "LastCloudKitSyncTime")
                                }
                                
                                print("✅ Auto-synced \(self?.stations.count ?? cloudKitStations.count) stations from CloudKit with local state preserved")
                            }
                        } else if let error = error {
                            Task { @MainActor in
                                DataSyncManager.shared.radioStationsOperation = "❌ Failed to sync stations from other devices"
                                DataSyncManager.shared.radioStationsStatus = .failed
                            }
                            print("❌ Auto-sync failed: \(error)")
                        }
                        continuation.resume()
                    }
                )
            }
        }
    }
    
    // MARK: - CloudKit Refresh Helpers
    
    private func refreshStationFromCloudKit(stationId: String) async {
        do {
            if let updatedStation = try await RadioStationCloudKitManager.shared.fetchRadioStationFromCloudKit(stationId: stationId) {
                await MainActor.run {
                    // Find and update the station in the stations array
                    if let index = self.stations.firstIndex(where: { $0.id == stationId }) {
                        self.stations[index] = updatedStation
                        print("📡 🔄 CLOUDKIT STATION REFRESH: ✅ Updated station \\(updatedStation.name)")
                        
                        // Save the updated station to Core Data
                        self.saveStationsToCoreData()
                        
                        // Update UI
                        self.objectWillChange.send()
                    } else {
                        // Station not found locally, add it
                        self.stations.append(updatedStation)
                        print("📡 🔄 CLOUDKIT STATION REFRESH: ✅ Added new station \\(updatedStation.name)")
                        
                        // Save to Core Data
                        self.saveStationsToCoreData()
                        
                        // Update UI
                        self.objectWillChange.send()
                    }
                }
            } else {
                print("📡 🔄 CLOUDKIT STATION REFRESH: ❌ Station \\(stationId) not found in CloudKit")
            }
        } catch {
            print("📡 🔄 CLOUDKIT STATION REFRESH: ❌ Error refreshing station \\(stationId): \\(error)")
        }
    }
    
    private func refreshStationsFromCloudKit() async {
        print("📡 🔄 Refreshing stations from CloudKit...")
        
        await MainActor.run {
            // Trigger a CloudKit sync to get the latest data
            syncStationsWithCloudKit()
        }
    }
    
    // Helper method to convert dictionary to RadioStation
    private func radioStationFromDictionary(_ data: [String: Any]) -> RadioStation? {
        guard let id = data["id"] as? String,
              let name = data["name"] as? String,
              let url = data["url"] as? String else {
            return nil
        }
        
        let iconData = data["iconData"] as? String
        let iTunesArtworkData = data["iTunesArtworkData"] as? String
        let country = data["country"] as? String ?? "Unknown Region"
        let isFavorite = data["isFavorite"] as? Bool ?? false
        let order = data["order"] as? Int ?? 0
        let favoriteOrder = data["favoriteOrder"] as? Int
        let isRecent = data["isRecent"] as? Bool ?? false
        
        // Handle dates
        var lastPlayed: Date?
        if let lastPlayedTimestamp = data["lastPlayed"] as? TimeInterval {
            lastPlayed = Date(timeIntervalSince1970: lastPlayedTimestamp)
        }
        
        var favoritedAt: Date?
        if let favoritedAtTimestamp = data["favoritedAt"] as? TimeInterval {
            favoritedAt = Date(timeIntervalSince1970: favoritedAtTimestamp)
        }
        
        return RadioStation(
            id: id,
            name: name,
            url: url,
            iconData: iconData,
            iTunesArtworkData: iTunesArtworkData,
            country: country,
            isFavorite: isFavorite,
            favoritedAt: favoritedAt,
            favoriteOrder: favoriteOrder,
            order: order,
            lastPlayed: lastPlayed,
            isRecent: isRecent
        )
    }
    
    // Helper method to convert RadioStation to dictionary for syncing
    private func radioStationToDictionary(_ station: RadioStation) -> [String: Any] {
        var data: [String: Any] = [
            "id": station.id,
            "name": station.name,
            "url": station.url,
            "country": station.country,
            "isFavorite": station.isFavorite,
            "order": station.order
        ]
        
        if let iconData = station.iconData {
            data["iconData"] = iconData
        }
        
        if let iTunesArtworkData = station.iTunesArtworkData {
            data["iTunesArtworkData"] = iTunesArtworkData
        }
        
        if let lastPlayed = station.lastPlayed {
            data["lastPlayed"] = lastPlayed.timeIntervalSince1970
        }
        
        if let favoriteOrder = station.favoriteOrder {
            data["favoriteOrder"] = favoriteOrder
        }
        
        if let favoritedAt = station.favoritedAt {
            data["favoritedAt"] = favoritedAt.timeIntervalSince1970
        }
        
        if let isRecent = station.isRecent {
            data["isRecent"] = isRecent
        }
        
        return data
    }
    
    func importStationsFromFile(url: URL, progressHandler: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing station playlist from file")
        
        do {
            let data = try Data(contentsOf: url)
            print("📄 Import: Read \(data.count) bytes from file")
            
            let jsonDecoder = JSONDecoder()
            
            // First try to decode as ExportStation (the format we actually export)
            do {
                let exportStationsFromJson = try jsonDecoder.decode([ExportStation].self, from: data)
                print("✅ Import: Successfully decoded \(exportStationsFromJson.count) ExportStation objects")
                
                // Convert ExportStation to RadioStation with proper defaults
                let stationsFromJson = exportStationsFromJson.map { exportStation in
                    RadioStation(
                        id: exportStation.id,
                        name: exportStation.name,
                        url: exportStation.url,
                        iconData: nil,                    // Will be downloaded if needed
                        iTunesArtworkData: nil,           // Will be downloaded if needed
                        country: exportStation.country,
                        isFavorite: exportStation.isFavorite,
                        favoritedAt: exportStation.isFavorite ? Date() : nil,  // Set current time for favorites
                        favoriteOrder: nil,               // Will be set when organizing favorites
                        order: 0,                         // Will be set based on position
                        lastPlayed: nil,                  // New stations haven't been played
                        isRecent: false                   // New stations aren't recent
                    )
                }

                // IMPORT OVERRIDE LOGIC: Import ALL stations from file, replacing existing ones and adding new ones
                var stationsToImport: [RadioStation] = []
                var stationsToReplace: [(index: Int, station: RadioStation)] = []
                
                print("📥 IMPORT ANALYSIS: Processing \(stationsFromJson.count) stations from import file")
                print("📊 CURRENT STATE: \(stations.count) stations currently in memory")
                
                // ENHANCED: Also check Core Data for existing stations (including default stations)
                let context = CoreDataStack.shared.persistentContainer.viewContext
                
                for importedStation in stationsFromJson {
                    // First check in-memory stations
                    if let existingIndex = stations.firstIndex(where: { $0.url == importedStation.url }) {
                        let existingStation = stations[existingIndex]
                        
                        // CRITICAL: Custom imported stations ALWAYS win over any existing station
                        // This includes API stations, default stations, or any other type
                        print("🔄 IMPORT OVERRIDE: Replacing existing station '\(existingStation.name)' (URL: \(existingStation.url)) with imported version")
                        
                        // Preserve some local state from existing station
                        var updatedStation = importedStation
                        // Mark as user-imported station for future protection
                        if !updatedStation.id.hasPrefix("import_") && !updatedStation.id.hasPrefix("manual_") {
                            updatedStation.id = "import_" + updatedStation.id
                        }
                        updatedStation.lastPlayed = existingStation.lastPlayed
                        updatedStation.order = existingStation.order
                        // Only preserve favorite status if imported station isn't already marked as favorite
                        if !importedStation.isFavorite && existingStation.isFavorite {
                            updatedStation.isFavorite = existingStation.isFavorite
                            updatedStation.favoritedAt = existingStation.favoritedAt
                            updatedStation.favoriteOrder = existingStation.favoriteOrder
                        }
                        stationsToReplace.append((index: existingIndex, station: updatedStation))
                    } else {
                        // Check if station exists in Core Data (might be a default station not loaded in memory)
                        let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "url == %@", importedStation.url)
                        
                        do {
                            let existingCoreDataStations = try context.fetch(fetchRequest)
                            if let existingCDStation = existingCoreDataStations.first {
                                print("🔄 IMPORT OVERRIDE (CORE DATA): Found existing station in Core Data '\(existingCDStation.name ?? "Unknown")' - will be replaced by import")
                                // Delete the existing Core Data station - it will be replaced by the imported one
                                context.delete(existingCDStation)
                            }
                        } catch {
                            print("⚠️ Error checking Core Data for existing station: \(error)")
                        }
                        
                        // Add as new station (will replace any Core Data version we just deleted)
                        print("➕ IMPORT NEW: Adding new station '\(importedStation.name)' (URL: \(importedStation.url)) - Logo: \(importedStation.iconData != nil ? "Yes" : "No")")
                        var newImportedStation = importedStation
                        // Mark as user-imported station for future protection
                        if !newImportedStation.id.hasPrefix("import_") && !newImportedStation.id.hasPrefix("manual_") {
                            newImportedStation.id = "import_" + newImportedStation.id
                        }
                        stationsToImport.append(newImportedStation)
                    }
                }
                
                print("📊 IMPORT SUMMARY: Will replace \(stationsToReplace.count) existing stations and add \(stationsToImport.count) new stations")
                
                // Save Core Data context to commit any deletions of existing default stations
                do {
                    try context.save()
                    print("✅ CORE DATA: Saved deletions of existing stations that will be replaced by imports")
                } catch {
                    print("⚠️ Error saving Core Data deletions: \(error)")
                }
                
                let newStations = stationsToImport
                
                let totalNewStations = Double(newStations.count)
                var importedStations = 0.0

                DispatchQueue.main.async {
                    // First, replace existing stations with imported versions
                    for replacement in stationsToReplace {
                        self.stations[replacement.index] = replacement.station
                        print("🔄 Replaced station at index \(replacement.index) with imported version: \(replacement.station.name)")
                    }
                    
                    // Then append new stations
                    for station in newStations {
                        self.stations.append(station)
                        importedStations += 1
                        progressHandler(importedStations / max(totalNewStations, 1))
                    }

                    let totalProcessed = newStations.count + stationsToReplace.count
                    let skipped = stationsFromJson.count - totalProcessed
                    print("Imported \(newStations.count) new stations, replaced \(stationsToReplace.count) existing stations. Skipped \(skipped) duplicates.")

                    // Save these to CoreData first
                    self.saveStationsToCoreData()

                    // Wait a bit to ensure Core Data save is complete, then save ALL imported stations to CloudKit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Collect ALL imported stations (both new and replaced) that have iconData for CloudKit sync
                        let allImportedStations = newStations + stationsToReplace.map { $0.station }
                        let stationsWithIconData = allImportedStations.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
                        
                        print("☁️ CLOUDKIT SYNC: Syncing \(allImportedStations.count) total imported stations (\(stationsWithIconData.count) with custom icons)")
                        
                        // Save ALL imported stations to CloudKit with duplicate prevention
                        DataStore.shared.saveImportedStationsToCloudKit(stations: allImportedStations) { success, recordIDs in
                            DispatchQueue.main.async {
                                if success {
                                    print("Successfully saved \(allImportedStations.count) imported stations to CloudKit (\(stationsWithIconData.count) with custom icons).")
                                    NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported \(totalProcessed) stations (\(stationsWithIconData.count) with custom icons). Skipped \(skipped) duplicates.")
                                } else {
                                    print("Failed to save some or all imported stations to CloudKit.")
                                    NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(totalProcessed) stations locally. Some stations may not have synced to iCloud.")
                                }
                                
                                // Clear import flag and notify completion
                                self.isImportInProgress = false
                                NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                                completion()
                            }
                        }
                    }
                }
            } catch {
                print("❌ Import: Failed to decode as ExportStation: \(error)")
                // Try to decode as String to see what the content actually is
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("📄 Import: File content preview: \(String(jsonString.prefix(200)))...")
                }
                throw error
            }
        } catch let importError as ImportError {
            DispatchQueue.main.async {
                self.isImportInProgress = false
            }
            let errorMessage = importError.userFriendlyMessage
            NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: errorMessage)
            print("Import failed with specific error: \(errorMessage)")
            completion()
        } catch {
            DispatchQueue.main.async {
                self.isImportInProgress = false
            }
            
            var errorMessage = "Unknown error occurred"
            
            if let decodingError = error as? DecodingError {
                errorMessage = self.parseDecodingError(decodingError)
            } else {
                errorMessage = error.localizedDescription
            }
            
            NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: errorMessage)
            print("Failed to import stations: \(error)")
            completion()
        }
    }
    
    // MARK: - Sample JSON Generation
    
    func generateSampleImportJSON() -> String {
        let sampleStations = [
            [
                "id": "sample-1",
                "name": "Sample Radio Station 1",
                "url": "https://example.com/stream1.mp3",
                "country": "United States",
                "isFavorite": false
            ],
            [
                "id": "sample-2", 
                "name": "Sample Radio Station 2",
                "url": "https://example.com/stream2.mp3",
                "country": "Canada",
                "isFavorite": true
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sampleStations, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? "Error generating sample JSON"
        } catch {
            return "Error generating sample JSON: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Import Error Handling
    
    private func parseDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Expected \(type) but found different type at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
        case .valueNotFound(let type, let context):
            return "Required field '\(context.codingPath.last?.stringValue ?? "unknown")' of type \(type) is missing"
        case .keyNotFound(let key, let context):
            return "Required field '\(key.stringValue)' is missing from the JSON"
        case .dataCorrupted(let context):
            return "Data is corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> ")): \(context.debugDescription)"
        @unknown default:
            return "Unknown decoding error: \(error.localizedDescription)"
        }
    }
    
    func exportStationsToFile(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportStationsToFile called")
        print("📊 DEBUG: Total stations: \(self.stations.count)")
        print("🌍 DEBUG: Selected country: \(self.selectedCountry)")
        
        let filteredStations = self.stations.filter { $0.country == self.selectedCountry || self.selectedCountry == "Select Country" }
                                            .map { ExportStation(from: $0, includeImages: false) }

        print("📋 DEBUG: Filtered stations for export: \(filteredStations.count)")
        
        let fileName = "stations_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export file path: \(fileURL.path)")

        do {
            // Use standard JSONEncoder instead of manual string construction
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted // Make it readable
            let jsonData = try jsonEncoder.encode(filteredStations)
            
            try jsonData.write(to: fileURL)
            print("✅ DEBUG: JSON file written successfully using JSONEncoder")
            print("📏 DEBUG: JSON data length: \(jsonData.count) bytes")
            DispatchQueue.main.async {
                print("🎯 DEBUG: Calling completion with fileURL")
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export stations: \(error)")
            DispatchQueue.main.async {
                print("💥 DEBUG: Calling completion with nil due to error")
                completion(nil)
            }
        }
    }
    
    // MARK: - Enhanced Import/Export Methods
    
    /// Export stations as list (metadata only)
    func exportStationsAsList(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportStationsAsList called")
        print("📊 DEBUG: Total stations: \(self.stations.count)")
        print("🌍 DEBUG: Selected country: \(self.selectedCountry)")
        
        let filteredStations = self.stations.filter { $0.country == self.selectedCountry || self.selectedCountry == "Select Country" }
                                            .map { ExportStation(from: $0, includeImages: false) }

        print("📋 DEBUG: Filtered stations for list export: \(filteredStations.count)")
        
        let fileName = "stations_list_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export file path: \(fileURL.path)")

        do {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let jsonData = try jsonEncoder.encode(filteredStations)
            
            try jsonData.write(to: fileURL)
            print("✅ DEBUG: JSON file written successfully (list only)")
            print("📏 DEBUG: JSON data length: \(jsonData.count) bytes")
            DispatchQueue.main.async {
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export stations list: \(error)")
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    /// Export stations with images (metadata + custom images)
    func exportStationsWithImages(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportStationsWithImages called")
        print("📊 DEBUG: Total stations: \(self.stations.count)")
        print("🌍 DEBUG: Selected country: \(self.selectedCountry)")
        
        let filteredStations = self.stations.filter { $0.country == self.selectedCountry || self.selectedCountry == "Select Country" }
                                            .map { ExportStation(from: $0, includeImages: true) }

        print("📋 DEBUG: Filtered stations for image export: \(filteredStations.count)")
        
        // Count stations with custom images
        let stationsWithImages = filteredStations.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
        print("🖼️ DEBUG: Stations with custom images: \(stationsWithImages.count)")
        
        let fileName = "stations_with_images_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export file path: \(fileURL.path)")

        do {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let jsonData = try jsonEncoder.encode(filteredStations)
            
            try jsonData.write(to: fileURL)
            print("✅ DEBUG: JSON file written successfully (with images)")
            print("📏 DEBUG: JSON data length: \(jsonData.count) bytes")
            DispatchQueue.main.async {
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export stations with images: \(error)")
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    /// Import stations as list (metadata only)
    func importStationsAsList(url: URL, progressHandler: @escaping (Double) -> Void, messageHandler: ((String) -> Void)? = nil, completion: @escaping () -> Void) {
        print("🚀 DEBUG: importStationsAsList called")
        
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        messageHandler?("Reading file…")
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing station list from file (metadata only)")
        
        do {
            let data = try Data(contentsOf: url)
            print("📄 Import: Read \(data.count) bytes from file")
            messageHandler?("Decoding JSON… \(data.count) bytes")
            
            let jsonDecoder = JSONDecoder()
            let exportStationsFromJson = try jsonDecoder.decode([ExportStation].self, from: data)
            print("✅ Import: Successfully decoded \(exportStationsFromJson.count) ExportStation objects")
            messageHandler?("Decoded \(exportStationsFromJson.count) stations")
            
            // Convert ExportStation to RadioStation with proper defaults (no images)
            let stationsFromJson = exportStationsFromJson.map { exportStation in
                RadioStation(
                    id: exportStation.id,
                    name: exportStation.name,
                    url: exportStation.url,
                    iconData: nil,                    // Explicitly ignore any image data
                    iTunesArtworkData: nil,           // Explicitly ignore any image data
                    country: exportStation.country,
                    isFavorite: exportStation.isFavorite,
                    favoritedAt: exportStation.isFavorite ? Date() : nil,
                    favoriteOrder: nil,
                    order: 0,
                    lastPlayed: nil,
                    isRecent: false
                )
            }

            // Get existing URLs to check for duplicates
            let existingURLs = Set(stations.map { $0.url })
            
            // Filter out stations that already exist by URL
            let newStations = stationsFromJson.filter { !existingURLs.contains($0.url) }
            
            let totalNewStations = Double(newStations.count)
            var importedStations = 0.0

            DispatchQueue.main.async {
                messageHandler?("Appending to library…")
                // Append new stations instead of removing existing ones
                for station in newStations {
                    self.stations.append(station)
                    importedStations += 1
                    progressHandler(importedStations / max(totalNewStations, 1))
                }

                print("Imported \(newStations.count) new stations (list only). Skipped \(stationsFromJson.count - newStations.count) duplicates.")

                // Save these to CoreData first
                self.saveStationsToCoreData()

                // Wait a bit to ensure Core Data save is complete, then save only new stations to CloudKit
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    messageHandler?("Uploading new stations to iCloud…")
                    // Only save the newly imported stations to CloudKit (with URL duplicate checking)
                    DataStore.shared.saveImportedStationsToCloudKit(stations: newStations) { success, recordIDs in
                        DispatchQueue.main.async {
                            if success {
                                print("Successfully saved \(newStations.count) new stations to CloudKit.")
                                messageHandler?("iCloud sync complete: \(newStations.count) items")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed", message: "Successfully imported \(newStations.count) new stations (list only).")
                            } else {
                                print("Failed to save some or all new stations to CloudKit.")
                                messageHandler?("iCloud sync completed with warnings")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(newStations.count) new stations locally. Some stations may not have synced to iCloud.")
                            }
                            
                            // Clear import flag and notify completion
                            self.isImportInProgress = false
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                            completion()
                        }
                    }
                }
            }
        } catch {
            print("❌ Import: Failed to import stations list: \(error)")
            DispatchQueue.main.async {
                self.isImportInProgress = false
                messageHandler?("Failed: \(error.localizedDescription)")
                NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: "Failed to import stations list: \(error.localizedDescription)")
                completion()
            }
        }
    }
    
    /// Import stations with images (metadata + custom images)
    func importStationsWithImages(url: URL, progressHandler: @escaping (Double) -> Void, messageHandler: ((String) -> Void)? = nil, completion: @escaping () -> Void) {
        print("🚀 DEBUG: importStationsWithImages called")
        
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        messageHandler?("Reading file…")
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing stations with images from file")
        
        do {
            let data = try Data(contentsOf: url)
            print("📄 Import: Read \(data.count) bytes from file")
            
            let jsonDecoder = JSONDecoder()
            let exportStationsFromJson = try jsonDecoder.decode([ExportStation].self, from: data)
            print("✅ Import: Successfully decoded \(exportStationsFromJson.count) ExportStation objects")
            
            // Count stations with images
            let stationsWithImages = exportStationsFromJson.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
            print("🖼️ Import: Stations with custom images: \(stationsWithImages.count)")
            messageHandler?("Found \(stationsWithImages.count) items with logos")
            
            // Convert ExportStation to RadioStation preserving image data
            let stationsFromJson = exportStationsFromJson.map { exportStation in
                RadioStation(
                    id: exportStation.id,
                    name: exportStation.name,
                    url: exportStation.url,
                    iconData: exportStation.iconData,           // Preserve custom image data
                    iTunesArtworkData: exportStation.iTunesArtworkData, // Preserve custom image data
                    country: exportStation.country,
                    isFavorite: exportStation.isFavorite,
                    favoritedAt: exportStation.isFavorite ? Date() : nil,
                    favoriteOrder: nil,
                    order: 0,
                    lastPlayed: nil,
                    isRecent: false
                )
            }

            // IMPORT OVERRIDE LOGIC: Import ALL stations from file, replacing existing ones and adding new ones
            var stationsToImport: [RadioStation] = []
            var stationsToReplace: [(index: Int, station: RadioStation)] = []
            
            print("📥 IMPORT ANALYSIS (WITH IMAGES): Processing \(stationsFromJson.count) stations from import file")
            print("📊 CURRENT STATE: \(stations.count) stations currently in memory")
            
            // ENHANCED: Also check Core Data for existing stations (including default stations)
            let context = CoreDataStack.shared.persistentContainer.viewContext
            
            for importedStation in stationsFromJson {
                // First check in-memory stations
                if let existingIndex = stations.firstIndex(where: { $0.url == importedStation.url }) {
                    let existingStation = stations[existingIndex]
                    
                    // CRITICAL: Custom imported stations ALWAYS win over any existing station
                    // This includes API stations, default stations, or any other type
                    print("🔄 IMPORT OVERRIDE: Replacing existing station '\(existingStation.name)' (URL: \(existingStation.url)) with imported version (with images)")
                    
                    // Preserve some local state from existing station
                    var updatedStation = importedStation
                    // Mark as user-imported station for future protection
                    if !updatedStation.id.hasPrefix("import_") && !updatedStation.id.hasPrefix("manual_") {
                        updatedStation.id = "import_" + updatedStation.id
                    }
                    updatedStation.lastPlayed = existingStation.lastPlayed
                    updatedStation.order = existingStation.order
                    // Only preserve favorite status if imported station isn't already marked as favorite
                    if !importedStation.isFavorite && existingStation.isFavorite {
                        updatedStation.isFavorite = existingStation.isFavorite
                        updatedStation.favoritedAt = existingStation.favoritedAt
                        updatedStation.favoriteOrder = existingStation.favoriteOrder
                    }
                    stationsToReplace.append((index: existingIndex, station: updatedStation))
                } else {
                    // Check if station exists in Core Data (might be a default station not loaded in memory)
                    let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "url == %@", importedStation.url)
                    
                    do {
                        let existingCoreDataStations = try context.fetch(fetchRequest)
                        if let existingCDStation = existingCoreDataStations.first {
                            print("🔄 IMPORT OVERRIDE (CORE DATA WITH IMAGES): Found existing station in Core Data '\(existingCDStation.name ?? "Unknown")' - will be replaced by import")
                            // Delete the existing Core Data station - it will be replaced by the imported one
                            context.delete(existingCDStation)
                        }
                    } catch {
                        print("⚠️ Error checking Core Data for existing station: \(error)")
                    }
                    
                    // Add as new station (will replace any Core Data version we just deleted)
                    print("➕ IMPORT NEW (WITH IMAGES): Adding new station '\(importedStation.name)' (URL: \(importedStation.url)) - Logo: \(importedStation.iconData != nil ? "Yes" : "No")")
                    var newImportedStation = importedStation
                    // Mark as user-imported station for future protection
                    if !newImportedStation.id.hasPrefix("import_") && !newImportedStation.id.hasPrefix("manual_") {
                        newImportedStation.id = "import_" + newImportedStation.id
                    }
                    stationsToImport.append(newImportedStation)
                }
            }
            
            print("📊 IMPORT SUMMARY (WITH IMAGES): Will replace \(stationsToReplace.count) existing stations and add \(stationsToImport.count) new stations")
            
            // Save Core Data context to commit any deletions of existing default stations
            do {
                try context.save()
                print("✅ CORE DATA (WITH IMAGES): Saved deletions of existing stations that will be replaced by imports")
            } catch {
                print("⚠️ Error saving Core Data deletions: \(error)")
            }
            
            let newStations = stationsToImport
            
            let totalNewStations = Double(newStations.count)
            var importedStations = 0.0

            DispatchQueue.main.async {
                // First, replace existing stations with imported versions
                for replacement in stationsToReplace {
                    self.stations[replacement.index] = replacement.station
                    print("🔄 Replaced station at index \(replacement.index) with imported version: \(replacement.station.name)")
                }
                
                // Then append new stations
                for station in newStations {
                    self.stations.append(station)
                    importedStations += 1
                    progressHandler(importedStations / max(totalNewStations, 1))
                }

                let newStationsWithImages = newStations.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
                let totalProcessed = newStations.count + stationsToReplace.count
                let skipped = stationsFromJson.count - totalProcessed
                print("Imported \(newStations.count) new stations with \(newStationsWithImages.count) custom images, replaced \(stationsToReplace.count) existing stations. Skipped \(skipped) duplicates.")

                // Save these to CoreData first
                self.saveStationsToCoreData()

                // Wait a bit to ensure Core Data save is complete, then save ALL imported stations to CloudKit
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Collect ALL imported stations (both new and replaced) that have iconData for CloudKit sync
                    let allImportedStations = newStations + stationsToReplace.map { $0.station }
                    let stationsWithIconData = allImportedStations.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
                    
                    messageHandler?("Uploading \(allImportedStations.count) stations to iCloud (\(stationsWithIconData.count) with images)…")
                    print("☁️ CLOUDKIT SYNC (WITH IMAGES): Syncing \(allImportedStations.count) total imported stations (\(stationsWithIconData.count) with custom icons)")
                    
                    // Save ALL imported stations to CloudKit with duplicate prevention
                    DataStore.shared.saveImportedStationsToCloudKit(stations: allImportedStations) { success, recordIDs in
                        DispatchQueue.main.async {
                            if success {
                                print("Successfully saved \(allImportedStations.count) imported stations with images to CloudKit (\(stationsWithIconData.count) with custom icons).")
                                messageHandler?("iCloud sync complete: \(allImportedStations.count) items (\(stationsWithIconData.count) with images)")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed", message: "Successfully imported \(totalProcessed) stations (\(stationsWithIconData.count) with custom images).")
                            } else {
                                print("Failed to save some or all imported stations to CloudKit.")
                                messageHandler?("iCloud sync completed with warnings")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(totalProcessed) stations locally. Some stations may not have synced to iCloud.")
                            }
                            
                            // Clear import flag and notify completion
                            self.isImportInProgress = false
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                            completion()
                        }
                    }
                }
            }
        } catch {
            print("❌ Import: Failed to import stations with images: \(error)")
            DispatchQueue.main.async {
                self.isImportInProgress = false
                messageHandler?("Failed: \(error.localizedDescription)")
                NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: "Failed to import stations with images: \(error.localizedDescription)")
                completion()
            }
        }
    }
    
    // MARK: - Favorites Import/Export Methods
    
    /// Export favorite stations as list (metadata only)
    func exportFavoritesAsList(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportFavoritesAsList called")
        
        let favoriteStations = self.stations.filter { $0.isFavorite }
                                           .map { ExportStation(from: $0, includeImages: false) }

        print("📋 DEBUG: Filtered favorite stations for list export: \(favoriteStations.count)")
        
        if favoriteStations.isEmpty {
            print("⚠️ DEBUG: No favorite stations to export")
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        
        let fileName = "favorites_list_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export favorites file path: \(fileURL.path)")

        do {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let jsonData = try jsonEncoder.encode(favoriteStations)
            
            try jsonData.write(to: fileURL)
            print("✅ DEBUG: Favorites JSON file written successfully (list only)")
            print("📏 DEBUG: JSON data length: \(jsonData.count) bytes")
            DispatchQueue.main.async {
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export favorites list: \(error)")
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    /// Export favorite stations with images (metadata + custom images)
    func exportFavoritesWithImages(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportFavoritesWithImages called")
        
        let favoriteStations = self.stations.filter { $0.isFavorite }
                                           .map { ExportStation(from: $0, includeImages: true) }

        print("📋 DEBUG: Filtered favorite stations for image export: \(favoriteStations.count)")
        
        if favoriteStations.isEmpty {
            print("⚠️ DEBUG: No favorite stations to export")
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        
        // Count favorites with custom images
        let favoritesWithImages = favoriteStations.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
        print("🖼️ DEBUG: Favorite stations with custom images: \(favoritesWithImages.count)")
        
        let fileName = "favorites_with_images_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export favorites file path: \(fileURL.path)")

        do {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let jsonData = try jsonEncoder.encode(favoriteStations)
            
            try jsonData.write(to: fileURL)
            print("✅ DEBUG: Favorites JSON file written successfully (with images)")
            print("📏 DEBUG: JSON data length: \(jsonData.count) bytes")
            DispatchQueue.main.async {
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export favorites with images: \(error)")
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    /// Import favorite stations as list (metadata only) with smart country assignment
    func importFavoritesAsList(url: URL, progressHandler: @escaping (Double) -> Void, messageHandler: ((String) -> Void)? = nil, completion: @escaping () -> Void) {
        print("🚀 DEBUG: importFavoritesAsList called")
        
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        messageHandler?("Reading file…")
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing favorite stations list from file (metadata only)")
        
        do {
            let data = try Data(contentsOf: url)
            print("📄 Import: Read \(data.count) bytes from file")
            
            let jsonDecoder = JSONDecoder()
            let exportStationsFromJson = try jsonDecoder.decode([ExportStation].self, from: data)
            print("✅ Import: Successfully decoded \(exportStationsFromJson.count) ExportStation objects")
            
            // Convert ExportStation to RadioStation with proper defaults (no images, all as favorites)
            let favoritesFromJson = exportStationsFromJson.map { exportStation in
                RadioStation(
                    id: exportStation.id,
                    name: exportStation.name,
                    url: exportStation.url,
                    iconData: nil,                    // Explicitly ignore any image data
                    iTunesArtworkData: nil,           // Explicitly ignore any image data
                    country: exportStation.country,
                    isFavorite: true,                 // Force all imported stations to be favorites
                    favoritedAt: Date(),              // Set current time for all favorites
                    favoriteOrder: nil,               // Will be set when organizing favorites
                    order: 0,                         // Will be set based on position
                    lastPlayed: nil,                  // New stations haven't been played
                    isRecent: false                   // New stations aren't recent
                )
            }

            // Get existing URLs to check for duplicates
            let existingURLs = Set(stations.map { $0.url })
            
            // Filter out stations that already exist by URL
            let newFavorites = favoritesFromJson.filter { !existingURLs.contains($0.url) }
            messageHandler?("Filtering duplicates… kept \(newFavorites.count) new / skipped \(favoritesFromJson.count - newFavorites.count)")
            
            let totalNewFavorites = Double(newFavorites.count)
            var importedFavorites = 0.0

            DispatchQueue.main.async {
                messageHandler?("Distributing favorites by country…")
                // Group favorites by country for smart assignment
                let favoritesByCountry = Dictionary(grouping: newFavorites) { $0.country }
                
                // Add favorites to their respective countries
                for (country, countryFavorites) in favoritesByCountry {
                    for favorite in countryFavorites {
                        self.stations.append(favorite)
                        importedFavorites += 1
                        progressHandler(importedFavorites / max(totalNewFavorites, 1))
                    }
                    print("📍 Added \(countryFavorites.count) favorite stations to \(country)")
                }

                print("Imported \(newFavorites.count) new favorite stations (list only) across \(favoritesByCountry.keys.count) countries. Skipped \(favoritesFromJson.count - newFavorites.count) duplicates.")

                // Save these to CoreData first
                self.saveStationsToCoreData()

                // Wait a bit to ensure Core Data save is complete, then save only new favorites to CloudKit
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Only save the newly imported favorites to CloudKit (with URL duplicate checking)
                    DataStore.shared.saveImportedStationsToCloudKit(stations: newFavorites) { success, recordIDs in
                        DispatchQueue.main.async {
                            if success {
                                print("Successfully saved \(newFavorites.count) new favorite stations to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed", message: "Successfully imported \(newFavorites.count) favorite stations (list only) across \(favoritesByCountry.keys.count) countries.")
                            } else {
                                print("Failed to save some or all new favorite stations to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(newFavorites.count) favorite stations locally. Some stations may not have synced to iCloud.")
                            }
                            
                            // Clear import flag and notify completion
                            self.isImportInProgress = false
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                            completion()
                        }
                    }
                }
            }
        } catch {
            print("❌ Import: Failed to import favorites list: \(error)")
            DispatchQueue.main.async {
                self.isImportInProgress = false
                messageHandler?("Failed: \(error.localizedDescription)")
                NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: "Failed to import favorites list: \(error.localizedDescription)")
                completion()
            }
        }
    }
    
    /// Import favorite stations with images (metadata + custom images) with smart country assignment
    func importFavoritesWithImages(url: URL, progressHandler: @escaping (Double) -> Void, messageHandler: ((String) -> Void)? = nil, completion: @escaping () -> Void) {
        print("🚀 DEBUG: importFavoritesWithImages called")
        
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        messageHandler?("Reading file…")
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing favorite stations with images from file")
        
        do {
            let data = try Data(contentsOf: url)
            print("📄 Import: Read \(data.count) bytes from file")
            
            let jsonDecoder = JSONDecoder()
            let exportStationsFromJson = try jsonDecoder.decode([ExportStation].self, from: data)
            print("✅ Import: Successfully decoded \(exportStationsFromJson.count) ExportStation objects")
            
            // Count favorites with images
            let favoritesWithImages = exportStationsFromJson.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
            print("🖼️ Import: Favorite stations with custom images: \(favoritesWithImages.count)")
            messageHandler?("Found \(favoritesWithImages.count) items with logos")
            
            // Convert ExportStation to RadioStation preserving image data (all as favorites)
            let favoritesFromJson = exportStationsFromJson.map { exportStation in
                RadioStation(
                    id: exportStation.id,
                    name: exportStation.name,
                    url: exportStation.url,
                    iconData: exportStation.iconData,           // Preserve custom image data
                    iTunesArtworkData: exportStation.iTunesArtworkData, // Preserve custom image data
                    country: exportStation.country,
                    isFavorite: true,                           // Force all imported stations to be favorites
                    favoritedAt: Date(),                        // Set current time for all favorites
                    favoriteOrder: nil,                         // Will be set when organizing favorites
                    order: 0,                                   // Will be set based on position
                    lastPlayed: nil,                            // New stations haven't been played
                    isRecent: false                             // New stations aren't recent
                )
            }

            // Get existing URLs to check for duplicates
            let existingURLs = Set(stations.map { $0.url })
            
            // Filter out stations that already exist by URL
            let newFavorites = favoritesFromJson.filter { !existingURLs.contains($0.url) }
            
            let totalNewFavorites = Double(newFavorites.count)
            var importedFavorites = 0.0

            DispatchQueue.main.async {
                // Group favorites by country for smart assignment
                let favoritesByCountry = Dictionary(grouping: newFavorites) { $0.country }
                
                // Add favorites to their respective countries
                for (country, countryFavorites) in favoritesByCountry {
                    for favorite in countryFavorites {
                        self.stations.append(favorite)
                        importedFavorites += 1
                        progressHandler(importedFavorites / max(totalNewFavorites, 1))
                    }
                    print("📍 Added \(countryFavorites.count) favorite stations to \(country)")
                }

                let newFavoritesWithImages = newFavorites.filter { $0.iconData != nil || $0.iTunesArtworkData != nil }
                print("Imported \(newFavorites.count) new favorite stations with \(newFavoritesWithImages.count) custom images across \(favoritesByCountry.keys.count) countries. Skipped \(favoritesFromJson.count - newFavorites.count) duplicates.")

                // Save these to CoreData first
                self.saveStationsToCoreData()

                // Wait a bit to ensure Core Data save is complete, then save only new favorites to CloudKit
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Only save the newly imported favorites to CloudKit (with URL duplicate checking)
                    DataStore.shared.saveImportedStationsToCloudKit(stations: newFavorites) { success, recordIDs in
                        DispatchQueue.main.async {
                            if success {
                                print("Successfully saved \(newFavorites.count) new favorite stations with images to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed", message: "Successfully imported \(newFavorites.count) favorite stations with \(newFavoritesWithImages.count) custom images across \(favoritesByCountry.keys.count) countries.")
                            } else {
                                print("Failed to save some or all new favorite stations to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(newFavorites.count) favorite stations locally. Some stations may not have synced to iCloud.")
                            }
                            
                            // Clear import flag and notify completion
                            self.isImportInProgress = false
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                            completion()
                        }
                    }
                }
            }
        } catch {
            print("❌ Import: Failed to import favorites with images: \(error)")
            DispatchQueue.main.async {
                self.isImportInProgress = false
                messageHandler?("Failed: \(error.localizedDescription)")
                NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: "Failed to import favorites with images: \(error.localizedDescription)")
                completion()
            }
        }
    }
    
    /// Clear stations from UI immediately for instant user feedback
    func clearStationsFromUI() {
        DispatchQueue.main.async {
            self.stations.removeAll()
            print("🎧 ✅ Immediately cleared radio stations from UI")
        }
    }
    
    func deleteAllData(completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async {
            self.isDeletingData = true
            self.deletionComplete = false
            self.isCloudKitOperationRunning = true
            self.isDeletionInProgress = true
        }
        
        // Set up background task with proper timeout handling
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var isTaskCompleted = false
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            // Task expired - clean up properly
            print("⚠️ Background task expired during data deletion")
            if !isTaskCompleted {
                isTaskCompleted = true
                DispatchQueue.main.async {
                    self.cleanupAfterDeletion(success: false, error: NSError(domain: "BackgroundTaskExpired", code: -1, userInfo: [NSLocalizedDescriptionKey: "Background task expired before completion"]), backgroundTaskID: backgroundTaskID, completion: completion)
                }
            }
        }
        
        // Set up observer for app entering background
        setupBackgroundObserver()
        
        // First clear Core Data efficiently using batch deletion
        DispatchQueue.main.async {
            self.clearCoreData { coreDataSuccess, coreDataError in
                if !isTaskCompleted {
                    if coreDataSuccess {
                        // Clear in-memory data immediately after successful Core Data deletion
                        self.stations.removeAll()
                        self.clearDeletedStationsList()
                        
                        // Now handle CloudKit deletion in background
                        Task {
                            await self.performCloudKitBatchDeletion(
                                backgroundTaskID: backgroundTaskID,
                                completion: completion
                            ) { completed in
                                isTaskCompleted = completed
                            }
                        }
                    } else {
                        isTaskCompleted = true
                        self.cleanupAfterDeletion(success: false, error: coreDataError, backgroundTaskID: backgroundTaskID, completion: completion)
                    }
                }
            }
        }
    }
    
    /// Perform optimized CloudKit batch deletion with minimal sync notifications
    private func performCloudKitBatchDeletion(
        backgroundTaskID: UIBackgroundTaskIdentifier,
        completion: @escaping (Bool, Error?) -> Void,
        taskCompletionHandler: @escaping (Bool) -> Void
    ) async {
        do {
            // Fetch all record IDs for 'streamingRadios' from CloudKit
            let recordIDs = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
                DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let recordIDs = recordIDs {
                        continuation.resume(returning: recordIDs)
                    } else {
                        continuation.resume(throwing: NSError(domain: "RadioStationDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "No record IDs found"]))
                    }
                }
            }
            
            guard !recordIDs.isEmpty else {
                print("✅ No radio stations found in CloudKit to delete")
                DispatchQueue.main.async {
                    taskCompletionHandler(true)
                    self.cleanupAfterDeletion(success: true, error: nil, backgroundTaskID: backgroundTaskID, completion: completion)
                }
                return
            }
            
            // Extract station IDs from record IDs
            let stationIds = recordIDs.map { $0.recordName }
            print("🗑️ Starting optimized batch deletion of \(stationIds.count) stations from CloudKit")
            
            // **OPTIMIZED**: Use the new batch deletion method that sends only one sync notification
            try await RadioStationCloudKitManager.shared.deleteRadioStationsBatchFromCloudKit(stationIds)
            
            print("✅ Successfully completed batch deletion of \(stationIds.count) stations")
            DispatchQueue.main.async {
                taskCompletionHandler(true)
                self.cleanupAfterDeletion(success: true, error: nil, backgroundTaskID: backgroundTaskID, completion: completion)
            }
            
        } catch {
            print("❌ CloudKit batch deletion failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                taskCompletionHandler(true)
                self.cleanupAfterDeletion(success: false, error: error, backgroundTaskID: backgroundTaskID, completion: completion)
            }
        }
    }

    private func cleanupAfterDeletion(success: Bool, error: Error?, backgroundTaskID: UIBackgroundTaskIdentifier, completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async {
            self.isDeletingData = false
            self.isCloudKitOperationRunning = false
            self.isDeletionInProgress = false
            self.deletionComplete = success
            
            // Remove the background observer
            self.removeBackgroundObserver()
            
            // End background task if it's still valid
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            
            completion(success, error)
            
            if success {
                print("✅ Data deletion completed successfully")
            } else if let error = error {
                print("❌ Data deletion failed: \(error.localizedDescription)")
                NotificationManager.shared.notifyUser(title: "Deletion Failed", message: "An error occurred: \(error.localizedDescription)")
            }
        }
    }
    
    func clearCoreData(completion: @escaping (Bool, Error?) -> Void) {
        // Use batch deletion for much faster performance
        let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        privateMOC.parent = CoreDataStack.shared.persistentContainer.viewContext
        privateMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        // Debug: Check what data exists before deletion
        do {
            let stationCount = try CoreDataStack.shared.persistentContainer.viewContext.count(for: CDStation.fetchRequest())
            print("🔍 STATION DEBUG: Before deletion - Stations: \(stationCount)")
        } catch {
            print("❌ STATION DEBUG: Error counting stations before deletion: \(error)")
        }
        
        privateMOC.perform {
            print("🔍 STATION DEBUG: Private context is performing station deletion...")
            do {
                // Use NSBatchDeleteRequest for efficient bulk deletion
                let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CDStation.fetchRequest()
                let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                batchDeleteRequest.resultType = .resultTypeObjectIDs
                
                // Execute batch delete
                let result = try privateMOC.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let objectIDArray = result?.result as? [NSManagedObjectID]
                
                // Merge changes into view context to ensure UI updates
                if let objectIDs = objectIDArray {
                    let changes = [NSDeletedObjectsKey: objectIDs]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [CoreDataStack.shared.persistentContainer.viewContext])
                    print("✅ Batch deleted \(objectIDs.count) stations from Core Data")
                }
                
                // Save the context after batch deletion
                try privateMOC.save()
                print("🔍 STATION DEBUG: Private context saved successfully")
                
                // Update main context and UI on main thread
                DispatchQueue.main.async {
                    do {
                        print("🔍 STATION DEBUG: Saving main context...")
                        try CoreDataStack.shared.persistentContainer.viewContext.save()
                        print("🔍 STATION DEBUG: Main context saved successfully")
                        
                        // **CRITICAL**: Force refresh all contexts to clear cached objects
                        print("🔄 STATION CONTEXT REFRESH: Starting comprehensive context refresh...")
                        let mainContext = CoreDataStack.shared.persistentContainer.viewContext
                        
                        // Reset the main context to clear all cached objects
                        mainContext.reset()
                        print("🔄 STATION CONTEXT REFRESH: Main context reset completed")
                        
                        // Refresh all objects in the context (in case any are still cached)
                        mainContext.refreshAllObjects()
                        print("🔄 STATION CONTEXT REFRESH: All objects refreshed")
                        
                        // Also refresh any background contexts
                        CoreDataStack.shared.persistentContainer.performBackgroundTask { backgroundContext in
                            backgroundContext.reset()
                            print("🔄 STATION CONTEXT REFRESH: Background context reset completed")
                        }
                        
                        // Debug: Check what data exists after deletion and context refresh
                        do {
                            let stationCountAfter = try CoreDataStack.shared.persistentContainer.viewContext.count(for: CDStation.fetchRequest())
                            print("🔍 STATION DEBUG: After deletion and context refresh - Stations: \(stationCountAfter)")
                            
                            if stationCountAfter > 0 {
                                print("❌ STATION ERROR: \(stationCountAfter) stations still exist after deletion!")
                            } else {
                                print("✅ STATION SUCCESS: All stations successfully deleted from Core Data and contexts refreshed")
                            }
                        } catch {
                            print("❌ STATION DEBUG: Error counting stations after deletion: \(error)")
                        }
                        
                        // Clear in-memory data after successful save
                        self.stations.removeAll()
                        // Clear deleted stations list since all data is being removed
                        self.clearDeletedStationsList()
                        
                        // RESET COUNTRY: When no stations exist, reset to "Select Country"
                        if self.stations.isEmpty {
                            print("🌍 RESET: No stations remaining, resetting country to 'Select Country'")
                            self.selectedCountry = "Select Country"
                        }
                        
                        self.isDeletingData = false
                        self.deletionComplete = true
                        print("✅ Radio station Core Data cleared successfully using batch deletion")
                        completion(true, nil)
                    } catch {
                        print("❌ Error saving main context after station batch deletion: \(error.localizedDescription)")
                        self.isDeletingData = false
                        completion(false, error)
                    }
                }
            } catch {
                print("❌ Error performing batch deletion of stations from CoreData: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isDeletingData = false
                    completion(false, error)
                }
            }
        }
    }
    
    func syncStationsWithCloudKit() {
        // Don't sync during import or deletion operations
        guard !isImportInProgress && !isDeletionInProgress else {
            print("Skipping CloudKit sync - import or deletion in progress")
            return
        }
        
        // Use the same approach as the banner sync to preserve local state
        DataStore.shared.fetchRadioStationsWithProgress(
            progressCallback: { progress, count, message in
                // No progress tracking needed for this method
            },
            completion: { [weak self] stations, error in
                if let cloudKitStations = stations {
                    DispatchQueue.main.async {
                        // CRITICAL: Merge CloudKit data with local state instead of replacing
                        self?.mergeCloudKitStationsWithLocalState(cloudKitStations)
                        self?.saveStationsToCoreData()
                        
                        // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                        UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                        
                        NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                        print("✅ Regular CloudKit sync completed with local state preserved")
                    }
                } else if let error = error {
                    print("❌ Error syncing with CloudKit: \(error.localizedDescription)")
                }
            }
        )
    }
    
    private func initializeStationsForFirstTime() {
        let userDefaults = UserDefaults.standard
        let hasLaunchedBeforeKey = "HasLaunchedBefore"
        
        if userDefaults.bool(forKey: hasLaunchedBeforeKey) == false {
            print("Initializing default stations for first time setup or new default stations detected.")
            
            // CRITICAL: Load all manual stations on fresh install
            // This ensures manual stations are available immediately, even before country selection
            let allManualStations = ManualStationManager.shared.getAllManualStations()
            if !allManualStations.isEmpty {
                print("📻 Loading \(allManualStations.count) manual stations across all countries on fresh install")
                stations = allManualStations
            }
            
            // Save locally first, then sync to CloudKit
            saveStationsToCoreData()
            saveStationsToCloudKit()
            
            // CRITICAL FIX: Mark all manual stations as already synced to prevent re-syncing during country selection
            let currentTime = Date().timeIntervalSince1970
            let allCountries = Set(allManualStations.map { $0.country })
            for country in allCountries {
                let syncKey = "ManualStationsSynced_\(country)_Time"
                userDefaults.set(currentTime, forKey: syncKey)
                print("📻 ☁️ FRESH INSTALL: Marked manual stations for \(country) as synced to prevent duplicate CloudKit saves")
            }
            
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.synchronize() // Ensure the flag is saved immediately
        }
    }
    
    func isStationPlaying(_ station: RadioStation) -> Bool {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              currentStationIndex < stations.count,
              stations[currentStationIndex].id == station.id else {
            return false
        }
        return true
    }
    
    func isStationCurrentlyPlaying(_ station: RadioStation) -> Bool {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              currentStationIndex < stations.count,
              stations[currentStationIndex].id == station.id else {
            return false
        }
        return RadioPlayer.shared.isPlaying
    }
    
    func toggleFavorite(for station: RadioStation) {
        if let index = stations.firstIndex(of: station) {
            var updatedStation = stations[index]
            updatedStation.isFavorite.toggle()
            
            // Set favoritedAt timestamp and favoriteOrder when marking as favorite, clear when unfavoriting
            if updatedStation.isFavorite {
                updatedStation.favoritedAt = Date()
                
                // Add new favorite at the top (favoriteOrder = 0)
                // First, increment all existing favorites' favoriteOrder by 1 to make room at the top
                for i in 0..<stations.count {
                    if stations[i].isFavorite && stations[i].id != station.id {
                        if let currentOrder = stations[i].favoriteOrder {
                            stations[i].favoriteOrder = currentOrder + 1
                        }
                    }
                }
                
                // Set the new favorite to favoriteOrder = 0 (top of the list)
                updatedStation.favoriteOrder = 0
            } else {
                updatedStation.favoritedAt = nil
                updatedStation.favoriteOrder = nil
            }
            
            stations[index] = updatedStation
            
            // Sync favorite changes to CloudKit using the comprehensive sync system
            syncStationToCloudKit(updatedStation, reason: "Favorite status changed")
            
            // Notify CarPlay immediately about favorite station changes
            NotificationCenter.default.post(
                name: NSNotification.Name("FavoriteStationChanged"),
                object: nil,
                userInfo: [
                    "stationId": updatedStation.id,
                    "isFavorite": updatedStation.isFavorite,
                    "favoriteOrder": updatedStation.favoriteOrder as Any
                ]
            )
        }
    }
    
    // MARK: - Comprehensive CloudKit Sync for User Modifications
    
    /// Sync any user-modified station to CloudKit
    /// Call this method whenever a user modifies any station field
    func syncStationToCloudKit(_ station: RadioStation, reason: String = "User modification") {
        print("📡 🔄 CLOUDKIT SYNC: Syncing station '\(station.name)' to CloudKit - Reason: \(reason)")
        
        // Save locally first
        saveStationsToCoreData()
        
        // Sync to CloudKit
        Task {
            DataStore.shared.saveImportedStationsToCloudKit(stations: [station]) { success, recordIDs in
                DispatchQueue.main.async {
                    if success {
                        print("✅ CLOUDKIT SYNC: Successfully synced '\(station.name)' to CloudKit")
                    } else {
                        print("❌ CLOUDKIT SYNC: Failed to sync '\(station.name)' to CloudKit")
                    }
                }
            }
        }
    }
    
    /// Update station name and sync to CloudKit
    func updateStationName(_ station: RadioStation, newName: String) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].name = newName
            syncStationToCloudKit(stations[index], reason: "Name changed")
        }
    }
    
    /// Update station country and sync to CloudKit
    func updateStationCountry(_ station: RadioStation, newCountry: String) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].country = newCountry
            syncStationToCloudKit(stations[index], reason: "Country changed")
        }
    }
    
    /// Update station order and sync to CloudKit
    func updateStationOrder(_ station: RadioStation, newOrder: Int) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].order = newOrder
            syncStationToCloudKit(stations[index], reason: "Order changed")
        }
    }
    
    /// Update favorite station order and notify CarPlay immediately
    func updateFavoriteStationOrder(_ stationId: String, newFavoriteOrder: Int) {
        if let index = stations.firstIndex(where: { $0.id == stationId }) {
            stations[index].favoriteOrder = newFavoriteOrder
            syncStationToCloudKit(stations[index], reason: "Favorite order changed")
            
            // Notify CarPlay immediately about favorite order change
            NotificationCenter.default.post(
                name: NSNotification.Name("FavoriteStationOrderChanged"),
                object: nil,
                userInfo: [
                    "stationId": stationId,
                    "newFavoriteOrder": newFavoriteOrder
                ]
            )
        }
    }
    
    /// Update last played and sync to CloudKit
    func updateLastPlayed(_ station: RadioStation) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].lastPlayed = Date()
            syncStationToCloudKit(stations[index], reason: "Last played updated")
        }
    }
    
    func recentStations() -> [RadioStation] {
        let recentStations = stations.filter { $0.lastPlayed != nil }
        
        // Sort based on current sort direction
        // When isAscendingSort is true (A-Z), show oldest played first (most recent at bottom)
        // When isAscendingSort is false (Z-A), show most recent played first (most recent at top)
        if isAscendingSort {
            // Ascending: oldest first, most recent last
            return recentStations.sorted { $0.lastPlayed ?? Date.distantPast < $1.lastPlayed ?? Date.distantPast }
        } else {
            // Descending: most recent first, oldest last
            return recentStations.sorted { $0.lastPlayed ?? Date.distantPast > $1.lastPlayed ?? Date.distantPast }
        }
    }
    
    func favoriteStations() -> [RadioStation] {
        // Get hidden countries
        let hiddenCountriesData = UserDefaults.standard.data(forKey: "hiddenCountries") ?? Data()
        let hiddenCountries = (try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData)) ?? Set<String>()
        
        // Filter out favorites from hidden countries
        return stations.filter { $0.isFavorite && !hiddenCountries.contains($0.country) }
            .sorted { (station1, station2) in
                // First, check if both stations have favoriteOrder values
                if let order1 = station1.favoriteOrder, let order2 = station2.favoriteOrder {
                    return order1 < order2
                }
                
                // If only one has favoriteOrder, prioritize it
                if station1.favoriteOrder != nil && station2.favoriteOrder == nil {
                    return true
                }
                if station1.favoriteOrder == nil && station2.favoriteOrder != nil {
                    return false
                }
                
                // If neither has favoriteOrder, fall back to favoritedAt timestamp
                if let date1 = station1.favoritedAt, let date2 = station2.favoritedAt {
                    return date1 < date2
                }
                
                // Final fallback: alphabetical by name
                return station1.name.localizedCaseInsensitiveCompare(station2.name) == .orderedAscending
            }
    }

    private func migrateFavoriteTimestamps() {
        // Prevent infinite loop by checking if migration is already in progress
        guard !isMigrationInProgress else { return }
        
        Task { @MainActor in
            self.isMigrationInProgress = true
            defer { self.isMigrationInProgress = false }
            
            var needsUpdate = false
            let now = Date()
            
            for i in 0..<stations.count {
                if stations[i].isFavorite && stations[i].favoritedAt == nil {
                    stations[i].favoritedAt = now
                    needsUpdate = true
                }
            }
            
            if needsUpdate {
                print("Migrating favorite timestamps for \(stations.filter { $0.isFavorite && $0.favoritedAt == now }.count) stations")
                saveStationsToCoreData()
            }
        }
    }
    
    func playStation(_ station: RadioStation) {
            if let index = stations.firstIndex(of: station) {
                RadioPlayer.shared.playStation(at: index, from: stations)
                updateLastPlayed(for: station)
            }
        }
    
    func updateLastPlayed(for station: RadioStation) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].lastPlayed = Date()
            
            // Save to CoreData on main thread but asynchronously to avoid blocking current operation
            DispatchQueue.main.async {
                self.saveStationsToCoreData()
            }
            
            // Post notification for real-time CarPlay recents update
            NotificationCenter.default.post(
                name: NSNotification.Name("StationPlayedForRecents"),
                object: nil,
                userInfo: ["stationId": station.id, "station": stations[index]]
            )
            print("🚗 Posted recents update notification for station: \(station.name)")
        }
    }
    
    
    func loadImageData(named name: String) -> String? {
        let assetName = name.replacingOccurrences(of: " ", with: "_")
        
        guard let image = UIImage(named: assetName) else {
            print("Failed to load image named: \(assetName)")
            return nil
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to compress image named: \(assetName)")
            return nil
        }
        print("Image loaded and encoded for: \(assetName)")
        return imageData.base64EncodedString()
    }
    
    @MainActor 
    func addStation(name: String, url: String, iconData: String?, country: String) -> Bool {
        // Check if a station with the same URL already exists
        if stations.contains(where: { $0.url == url }) {
            print("Station with URL \(url) already exists. Skipping addition.")
            return false
        }
        
        // First, increment the order of all existing stations in the same country
        for i in 0..<stations.count {
            if stations[i].country == country {
                stations[i].order += 1
            }
        }
        
        // Create new station with order = 0 to place it at the top
        let newStation = RadioStation(id: UUID().uuidString, name: name, url: url, iconData: iconData, country: country, isFavorite: false, favoriteOrder: nil, order: 0)
        
        // Remove from deleted stations list if user is manually re-adding it
        // Note: This won't match by ID since manual additions get new UUIDs,
        // but it's here for consistency and future improvements
        removeFromDeletedStations(newStation.id)
        
        stations.append(newStation)
        print("Added new station: \(newStation) at the top of \(country) list")
        saveStationsToCoreData()
        
        // PERFORMANCE: Update station snapshot for the country when new station is added
        let countryStations = stations.filter { $0.country == country }
        updateStationSnapshot(for: country, stations: countryStations)
        
        // Force UI refresh and notify listeners that stations changed
        DispatchQueue.main.async {
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
        }
        
        // Mark that changes are expected on other devices after manual addition
        forceCloudKitCheckOnNextLaunch()
        
        // ENHANCED CLOUDKIT SYNC: Save new station to CloudKit and sync across all devices (after local save)
        Task {
            do {
                try await RadioStationCloudKitManager.shared.saveRadioStationToCloudKit(newStation)
                print("📡 ✅ RADIO CLOUDKIT SYNC: Successfully added station to CloudKit: \(newStation.name)")
            } catch {
                print("📡 ❌ RADIO CLOUDKIT SYNC: Failed to add station to CloudKit: \(error)")
            }
        }
        
        return true
    }

    
    func saveStationsToCloudKit() {
        isUploadingToCloudKit = true
        NotificationManager.shared.notifyUser(title: "Upload Started", message: "Saving stations to iCloud has begun.")
        
        setupBackgroundObserver()
        
        DataStore.shared.saveStationsToCloudKit(stations: stations) { [weak self] success, recordIDs in
            DispatchQueue.main.async {
                self?.isUploadingToCloudKit = false
                self?.removeBackgroundObserver()
                
                if success {
                    NotificationManager.shared.notifyUser(title: "Upload Complete", message: "All stations have been successfully saved to iCloud.")
                    print("Successfully saved all stations to CloudKit.")
                } else {
                    NotificationManager.shared.notifyUser(title: "Upload Incomplete", message: "Some stations failed to save to iCloud.")
                    print("Failed to save some or all stations to CloudKit.")
                    if let recordIDs = recordIDs {
                        let failedStations = self?.stations.filter { !recordIDs.contains($0.id) } ?? []
                        for station in failedStations {
                            print("Failed to save station: \(station.name)")
                        }
                    } else {
                        print("No stations were saved successfully.")
                    }
                }
            }
        }
    }
    
    private func setupBackgroundObserver() {
        // Remove any existing observer before adding a new one
        removeBackgroundObserver()
        
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.isDeletionInProgress == true {
                NotificationManager.shared.notifyUser(title: "Deletion in Progress", message: "Please keep the app open in the background until the deletion process is complete.")
            } else if self?.isUploadingToCloudKit == true {
                NotificationManager.shared.notifyUser(title: "Initial iCloud Sync in Progress", message: "iCloud sync in progress. May take 5 mins. Keep app in background. We'll notify when done.")
            }
        }
    }
    
    private func removeBackgroundObserver() {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
    }
    
    
    func saveStationToCloudKit(station: RadioStation) {
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        DataStore.shared.saveNewStationToCloudKit(station: station, iconImage: iconImage) { success, recordName in
            DispatchQueue.main.async {
                if success {
                    print("Station saved to CloudKit with record ID:", recordName ?? "Unknown")
                } else {
                    print("Failed to save station to CloudKit.")
                }
            }
        }
    }
    
    func deleteStationFromCoreData(_ station: RadioStation) {
        NotificationManager.shared.notifyUserImmediate(title: "Deletion Started", message: "Deleting station '\(station.name)'...")
        
        // Track the station ID as manually deleted to prevent re-fetching
        addToDeletedStations(station.id)
        
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", station.id)
        
        do {
            let results = try context.fetch(request)
            for object in results {
                context.delete(object)
            }
            try context.save()
            
            // Check if there are no more stations left
            let remainingStations = try context.fetch(CDStation.fetchRequest())
            if remainingStations.isEmpty {
                deleteLocalFile()
                
                // RESET COUNTRY: When no stations exist, reset to "Select Country"
                print("🌍 RESET: No stations remaining after individual deletion, resetting country to 'Select Country'")
                self.selectedCountry = "Select Country"
                
                // Clear all station snapshots when no stations remain
                clearAllStationSnapshots()
            } else {
                // PERFORMANCE: Update station snapshot for the country when station is deleted
                let countryStations = stations.filter { $0.country == station.country }
                updateStationSnapshot(for: station.country, stations: countryStations)
            }
            
            // ENHANCED CLOUDKIT SYNC: Delete from CloudKit and sync across all devices
            Task {
                do {
                    try await RadioStationCloudKitManager.shared.deleteRadioStationFromCloudKit(station.id)
                    print("📡 ✅ RADIO CLOUDKIT SYNC: Successfully deleted station from CloudKit: \(station.name)")
                } catch {
                    print("📡 ❌ RADIO CLOUDKIT SYNC: Failed to delete station from CloudKit: \(error)")
                }
            }
            
            print("Station deleted from CoreData successfully.")
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Successfully deleted station '\(station.name)'.")
        } catch {
            print("Failed to delete station from CoreData: \(error)")
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to delete station '\(station.name)': \(error.localizedDescription)")
        }
    }
    
    func deleteLocalFile() {
        let fileManager = FileManager.default
        guard let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreDescriptions.first?.url else {
            print("Failed to get CoreData file URL.")
            return
        }
        
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        
        do {
            // Ensure any changes are saved
            if context.hasChanges {
                try context.save()
            }
            
            // Remove the persistent store
            if let store = coordinator.persistentStore(for: storeURL) {
                try coordinator.remove(store)
            }
            
            // Delete the file
            try fileManager.removeItem(at: storeURL)
            print("Local CoreData file deleted successfully.")
            
            // Reset the context to clear any cached data
            context.reset()
        } catch {
            print("Failed to delete local CoreData file: \(error)")
        }
    }
    
    
    func updateStation(_ existingStation: RadioStation, name: String, url: String, iconData: String?, country: String) {
        if let index = stations.firstIndex(where: { $0.id == existingStation.id }) {
            stations[index].name = name
            stations[index].url = url
            stations[index].iconData = iconData
            stations[index].country = country
            updateStationInCloudKit(station: stations[index])
            saveStationsToCoreData()
        } else {
            print("Error: Station not found in local data.")
        }
    }
    
    func updateStationInCloudKit(station: RadioStation) {
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        DataStore.shared.updateStationInCloudKit(station: station, iconImage: iconImage) { success, recordName in
            DispatchQueue.main.async {
                if success {
                    print("Station updated in CloudKit with record ID:", recordName ?? "Unknown")
                } else {
                    print("Failed to update station in CloudKit.")
                }
            }
        }
    }
    
    @MainActor
    func moveStation(from source: IndexSet, to destination: Int) {
        // Move the station in the array
        stations.move(fromOffsets: source, toOffset: destination)
        
        // Update order values for all stations to reflect new positions
        updateStationOrderValues()
        
        // Save to CoreData
        saveStationsToCoreData()
        
        // Mark that changes are expected on other devices after reordering
        forceCloudKitCheckOnNextLaunch()
        
        // ENHANCED CLOUDKIT SYNC: Sync order changes to CloudKit
        Task {
            await syncOrderChangesToCloudKit()
        }
    }
    
    /// Update order values for all stations to reflect their current positions
    private func updateStationOrderValues() {
        // Group stations by country and update order values
        let groupedStations = Dictionary(grouping: stations.enumerated()) { $0.element.country }
        
        for (country, indexedStations) in groupedStations {
            // Sort by current array index to maintain the new order
            let sortedStations = indexedStations.sorted { $0.offset < $1.offset }
            
            // Update order values
            for (newOrder, indexedStation) in sortedStations.enumerated() {
                let originalIndex = indexedStation.offset
                stations[originalIndex].order = newOrder
            }
        }
        
        print("📡 🔄 Updated order values for all stations")
    }
    
    /// Move station within favorites list and update favoriteOrder values
    func moveFavoriteStation(from source: IndexSet, to destination: Int) {
        print("📡 🔄 DRAG AND DROP: Starting moveFavoriteStation - source: \(source), destination: \(destination)")
        
        var favoritesList = favoriteStations()
        print("📡 📊 DRAG AND DROP: Current favorites count: \(favoritesList.count)")
        
        favoritesList.move(fromOffsets: source, toOffset: destination)
        
        // Update favoriteOrder values
        for (index, favorite) in favoritesList.enumerated() {
            if let stationIndex = stations.firstIndex(where: { $0.id == favorite.id }) {
                let oldOrder = stations[stationIndex].favoriteOrder
                stations[stationIndex].favoriteOrder = index
                print("📡 🔢 DRAG AND DROP: Updated \(favorite.name) - old order: \(oldOrder ?? -1), new order: \(index)")
            }
        }
        
        // Save to CoreData
        print("📡 💾 DRAG AND DROP: Saving to CoreData...")
        saveStationsToCoreData()
        
        // Save favorite order to UserDefaults for immediate persistence
        let favoriteOrderDict = Dictionary(uniqueKeysWithValues: favoritesList.enumerated().map { ($0.element.id, $0.offset) })
        UserDefaults.standard.set(favoriteOrderDict, forKey: "FavoriteStationsOrder")
        UserDefaults.standard.synchronize()
        print("📡 💾 DRAG AND DROP: Saved favorite order to UserDefaults for \(favoritesList.count) stations")
        
        // ENHANCED CLOUDKIT SYNC: Sync favorite order changes to CloudKit
        print("📡 ☁️ DRAG AND DROP: Starting CloudKit sync...")
        Task {
            await syncFavoriteOrderChangesToCloudKit()
        }
        
        // Notify CarPlay immediately about favorite order change
        NotificationCenter.default.post(
            name: NSNotification.Name("FavoriteStationOrderChanged"),
            object: nil,
            userInfo: [
                "reason": "manual_reorder",
                "stationCount": favoritesList.count
            ]
        )
        
        print("📡 ✅ DRAG AND DROP: Completed - Updated favorite order values for \(favoritesList.count) stations and notified CarPlay")
    }
    
    /// Sort stations alphabetically and toggle sort direction
    func sortStationsAlphabetically() {
        // Toggle sort direction
        isAscendingSort.toggle()
        
        // Save the sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "RadioStationSortAscending")
        
        print("📡 📝 Toggled radio station sort direction to: \(isAscendingSort ? "A-Z" : "Z-A")")
    }
    
    /// Sort favorite stations alphabetically and update their favoriteOrder
    func sortFavoritesAlphabetically() {
        // Toggle sort direction
        isAscendingSort.toggle()
        
        // Get all favorite stations
        var favorites = favoriteStations()
        
        // Sort alphabetically based on the toggle
        if isAscendingSort {
            favorites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else {
            favorites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
        
        // Update favoriteOrder values based on new alphabetical order
        for (index, favorite) in favorites.enumerated() {
            if let stationIndex = stations.firstIndex(where: { $0.id == favorite.id }) {
                stations[stationIndex].favoriteOrder = index
            }
        }
        
        // Save to CoreData
        saveStationsToCoreData()
        
        // Save favorite order to UserDefaults
        let favoriteOrderDict = Dictionary(uniqueKeysWithValues: favorites.enumerated().map { ($0.element.id, $0.offset) })
        UserDefaults.standard.set(favoriteOrderDict, forKey: "FavoriteStationsOrder")
        UserDefaults.standard.synchronize()
        
        // Save the sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "RadioStationSortAscending")
        
        // Sync to CloudKit
        Task {
            await syncFavoriteOrderChangesToCloudKit()
        }
        
        print("📡 📝 Sorted \(favorites.count) favorites alphabetically: \(isAscendingSort ? "A-Z" : "Z-A")")
    }
    
    /// Sort recent stations by recency (toggles between oldest first and most recent first)
    func sortRecentStationsAlphabetically() {
        // Toggle sort direction
        isAscendingSort.toggle()
        
        // Save the sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "RadioStationSortAscending")
        
        print("📡 📝 Toggled recent stations sort direction to: \(isAscendingSort ? "Oldest First (Most Recent at Bottom)" : "Most Recent First (Most Recent at Top)")")
    }
    
    /// Load sorting preferences from UserDefaults
    private func loadSortingPreferences() {
        if UserDefaults.standard.object(forKey: "RadioStationSortAscending") != nil {
            isAscendingSort = UserDefaults.standard.bool(forKey: "RadioStationSortAscending")
        } else {
            isAscendingSort = true // Default to ascending (A-Z)
            UserDefaults.standard.set(isAscendingSort, forKey: "RadioStationSortAscending")
        }
    }
    
    /// Handle large discrepancy between CloudKit and local station counts
    private func handleLargeDiscrepancy(cloudKitCount: Int, localCount: Int) async {
        print("🔧 RECOVERY: Starting discrepancy recovery process...")
        
        // Option 1: Force upload local stations to CloudKit (most likely scenario)
        if localCount > cloudKitCount {
            print("🔧 RECOVERY: Local has more stations (\(localCount)) than CloudKit (\(cloudKitCount))")
            print("🔧 RECOVERY: This suggests CloudKit data may be incomplete or corrupted")
            print("🔧 RECOVERY: Attempting to upload local stations to CloudKit...")
            
        await MainActor.run {
            DataSyncManager.shared.radioStationsStatus = .inProgress
                DataSyncManager.shared.radioStationsOperation = "🔧 Recovering CloudKit data - uploading \(localCount) stations..."
            DataSyncManager.shared.radioStationsProgress = 0.0
                DataSyncManager.shared.radioStationsTotalCount = localCount
            DataSyncManager.shared.radioStationsCurrentCount = 0
        }
        
        do {
                // Force upload all local stations to CloudKit
                try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(stations, country: nil) { [weak self] progress, count, message in
                Task { @MainActor in
                        DataSyncManager.shared.updateRadioStationProgress(progress, currentCount: count, operation: "🔧 Recovery: \(message)")
                    }
                }
                
                await MainActor.run {
                    DataSyncManager.shared.radioStationsStatus = .completed
                    DataSyncManager.shared.radioStationsOperation = "✅ Recovery complete - uploaded \(localCount) stations to CloudKit"
                    DataSyncManager.shared.radioStationsProgress = 1.0
                }
                
                print("✅ RECOVERY: Successfully uploaded \(localCount) stations to CloudKit")
                
                // Set a flag to prevent this recovery from running again immediately
                UserDefaults.standard.set(Date(), forKey: "LastDiscrepancyRecoveryTime")
                
            } catch {
                await MainActor.run {
                    DataSyncManager.shared.radioStationsStatus = .failed
                    DataSyncManager.shared.radioStationsOperation = "❌ Recovery failed: \(error.localizedDescription)"
                }
                print("❌ RECOVERY: Failed to upload stations to CloudKit: \(error)")
            }
        }
    }
    
    /// Sync station order changes to CloudKit with resumable support
    func syncOrderChangesToCloudKit() async {
        print("📡 🚨 RADIO ORDER SYNC: Starting batch order sync to CloudKit...")
        
        // Use DataSyncManager's new resumable sync system
        await MainActor.run {
            DataSyncManager.shared.startRadioStationSync(totalStations: stations.count, country: nil, operationType: "order_sync")
        }
        
        do {
            // **OPTIMIZED**: Sync all stations to CloudKit in batches with resumable support
            try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(stations, country: nil) { [weak self] progress, count, message in
                Task { @MainActor in
                    DataSyncManager.shared.updateRadioStationProgress(progress, currentCount: count, operation: message)
                }
            }
            print("📡 ✅ RADIO ORDER SYNC: Successfully saved \(stations.count) stations in batches")
            
            // Trigger cross-device order sync notification
            await RadioStationCloudKitManager.shared.triggerCrossDeviceOrderSync(action: "order_changed")
            
            // Mark operation as completed
            await MainActor.run {
                DataSyncManager.shared.completeRadioStationSync()
            }
            
            print("📡 ✅ RADIO ORDER SYNC: Successfully synced station order to CloudKit")
        } catch {
            // Mark operation as failed
            await MainActor.run {
                DataSyncManager.shared.radioStationsStatus = .failed
                DataSyncManager.shared.radioStationsOperation = "Failed to save stations: \(error.localizedDescription)"
                DataSyncManager.shared.radioStationsProgress = 0.0
            }
            
            print("📡 ❌ RADIO ORDER SYNC: Failed to sync order to CloudKit: \(error)")
        }
    }
    
    /// Sync favorite order changes to CloudKit
    func syncFavoriteOrderChangesToCloudKit() async {
        print("📡 🚨 RADIO FAVORITE ORDER SYNC: Starting batch favorite order sync to CloudKit...")
        
        // **OPTIMIZED**: Sync all favorite stations to CloudKit in batches instead of individually
        let favorites = favoriteStations()
        guard !favorites.isEmpty else {
            print("📡 ⚠️ RADIO FAVORITE ORDER SYNC: No favorite stations to sync")
            return
        }
        
        // Update DataSyncManager to show we're starting a save operation
        await MainActor.run {
            DataSyncManager.shared.radioStationsStatus = .inProgress
            DataSyncManager.shared.radioStationsOperation = "Saving favorite stations to iCloud"
            DataSyncManager.shared.radioStationsProgress = 0.0
            DataSyncManager.shared.radioStationsTotalCount = favorites.count
            DataSyncManager.shared.radioStationsCurrentCount = 0
        }
        
        do {
            try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(favorites) { [weak self] progress, count, message in
                Task { @MainActor in
                    DataSyncManager.shared.radioStationsProgress = progress
                    DataSyncManager.shared.radioStationsCurrentCount = count
                    DataSyncManager.shared.radioStationsOperation = message
                }
            }
            print("📡 ✅ RADIO FAVORITE ORDER SYNC: Successfully saved \(favorites.count) favorite stations in batches")
            
            // Trigger cross-device favorite order sync notification
            await RadioStationCloudKitManager.shared.triggerCrossDeviceOrderSync(action: "favorite_order_changed")
            
            // Mark operation as completed
            await MainActor.run {
                DataSyncManager.shared.radioStationsStatus = .completed
                DataSyncManager.shared.radioStationsOperation = "Saved \(favorites.count) favorite stations to CloudKit"
                DataSyncManager.shared.radioStationsProgress = 1.0
            }
            
            print("📡 ✅ RADIO FAVORITE ORDER SYNC: Successfully synced favorite order to CloudKit")
        } catch {
            // Mark operation as failed
            await MainActor.run {
                DataSyncManager.shared.radioStationsStatus = .failed
                DataSyncManager.shared.radioStationsOperation = "Failed to save favorites: \(error.localizedDescription)"
                DataSyncManager.shared.radioStationsProgress = 0.0
            }
            
            print("📡 ❌ RADIO FAVORITE ORDER SYNC: Failed to sync favorite order to CloudKit: \(error)")
        }
    }

    // MARK: - Favorites Sorting

    /// Apply alphabetical sorting to favorites by updating favoriteOrder values, then persist to Core Data and CloudKit
    @MainActor
    func applyAlphabeticalSortToFavoritesAndPersist(ascending: Bool) async {
        var favorites = favoriteStations()
        favorites.sort { a, b in
            let comparison = a.name.localizedCaseInsensitiveCompare(b.name)
            return ascending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
        // Update favoriteOrder based on sorted positions
        for (index, fav) in favorites.enumerated() {
            if let i = stations.firstIndex(where: { $0.id == fav.id }) {
                stations[i].favoriteOrder = index
            }
        }
        // Persist locally
        saveStationsToCoreData()
        // Push to CloudKit
        await syncFavoriteOrderChangesToCloudKit()
    }
    
    // MARK: - Radio Browser API Integration
    
    @MainActor
    func fetchStationsFromAPI(for country: Country) async {
        // Wait for migration to complete to prevent race conditions
        while !isMigrationComplete {
            try? await Task.sleep(nanoseconds: 100_000_000) // Wait 0.1 seconds
        }
        
        isLoadingFromAPI = true
        isLoading = true
        loadingProgress = 0.0
        totalStationsToLoad = 0
        loadingStationsCount = 0
        loadingPhase = "Fetching stations"
        
        do {
            print("🌐 Radio Browser API: Fetching stations for \(country.name) with API code: \(country.apiCountryCode)")
            logDeletedStationsCount()
            
            await MainActor.run {
                loadingPhase = "Connecting to radio database"
                loadingProgress = 0.05
            }
            
            // Start progress simulation during API call with weak self capture
            let progressTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                var currentProgress = 0.05
                while currentProgress < 0.25 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                    currentProgress += 0.02
                    
                    // Check if self is still valid before updating
                    guard !Task.isCancelled else { break }
                    self.loadingProgress = currentProgress
                    
                    // Update phase messages during download
                    if currentProgress < 0.1 {
                        self.loadingPhase = "Connecting to radio database."
                    } else if currentProgress < 0.15 {
                        self.loadingPhase = "Downloading station data"
                    } else if currentProgress < 0.2 {
                        self.loadingPhase = "Receiving stations"
                    } else {
                        self.loadingPhase = "Finishing download"
                    }
                }
            }
            
            // Fetch stations using multiple strategies to ensure we get exactly 500 unique stations
            let targetUniqueStations = 500
            var allApiStations: [RadioBrowserStation] = []
            var uniqueURLs = Set<String>()
            
            print("🎯 TARGET: Fetching stations using multiple strategies until we have \(targetUniqueStations) unique stations")
            
            // Strategy 1: Fetch by clickcount (most popular first)
            print("📡 Strategy 1: Fetching by clickcount...")
            let clickcountStations = try await RadioBrowserAPI.shared.fetchTopStationsByCountry(
                countryCode: country.apiCountryCode, 
                limit: 1000,
                offset: 0,
                order: "clickcount"
            )
            
            // Add unique stations from clickcount strategy
            for station in clickcountStations {
                let normalizedURL = station.url.lowercased()
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                
                if !uniqueURLs.contains(normalizedURL) {
                    uniqueURLs.insert(normalizedURL)
                    allApiStations.append(station)
                }
                
                if uniqueURLs.count >= targetUniqueStations {
                    break
                }
            }
            
            print("📡 Strategy 1: Added \(uniqueURLs.count) unique stations from clickcount")
            
            // Strategy 2: If we still need more, fetch by votes (highest rated)
            if uniqueURLs.count < targetUniqueStations {
                print("📡 Strategy 2: Fetching by votes...")
                let votesStations = try await RadioBrowserAPI.shared.fetchTopStationsByCountry(
                    countryCode: country.apiCountryCode, 
                    limit: 1000,
                    offset: 0,
                    order: "votes"
                )
                
                for station in votesStations {
                    let normalizedURL = station.url.lowercased()
                        .replacingOccurrences(of: "https://", with: "")
                        .replacingOccurrences(of: "http://", with: "")
                    
                    if !uniqueURLs.contains(normalizedURL) {
                        uniqueURLs.insert(normalizedURL)
                        allApiStations.append(station)
                    }
                    
                    if uniqueURLs.count >= targetUniqueStations {
                        break
                    }
                }
                
                print("📡 Strategy 2: Total unique stations after votes: \(uniqueURLs.count)")
            }
            
            // Strategy 3: If we still need more, fetch by lastchangetime (recently updated)
            if uniqueURLs.count < targetUniqueStations {
                print("📡 Strategy 3: Fetching by lastchangetime...")
                let recentStations = try await RadioBrowserAPI.shared.fetchTopStationsByCountry(
                    countryCode: country.apiCountryCode, 
                    limit: 1000,
                    offset: 0,
                    order: "lastchangetime"
                )
                
                for station in recentStations {
                    let normalizedURL = station.url.lowercased()
                        .replacingOccurrences(of: "https://", with: "")
                        .replacingOccurrences(of: "http://", with: "")
                    
                    if !uniqueURLs.contains(normalizedURL) {
                        uniqueURLs.insert(normalizedURL)
                        allApiStations.append(station)
                    }
                    
                    if uniqueURLs.count >= targetUniqueStations {
                        break
                    }
                }
                
                print("📡 Strategy 3: Total unique stations after recent: \(uniqueURLs.count)")
            }
            
            // Trim to exact target if we have more than needed
            if allApiStations.count > targetUniqueStations {
                allApiStations = Array(allApiStations.prefix(targetUniqueStations))
            }
            
            let apiStations = allApiStations
            print("🎯 FINAL: Collected \(apiStations.count) unique stations for processing")
            
            // Cancel progress simulation as API call completed
            progressTask.cancel()
            
            print("📡 RadioBrowserAPI: Received \(apiStations.count) stations for \(country.name)")
            
            // Debug logging for specific countries that have issues
            if country.name == "Saint Vincent & Grenadines" || country.name == "Saint Pierre & Miquelon" {
                print("🔍 Debug: API returned \(apiStations.count) stations for \(country.name) (code: \(country.apiCountryCode))")
                if !apiStations.isEmpty {
                    print("🔍 Debug: First few stations: \(apiStations.prefix(3).map { $0.name })")
                    print("🔍 Debug: Station countries from API: \(apiStations.prefix(3).map { $0.country ?? "nil" })")
                } else {
                    print("🔍 Debug: API returned empty result - checking if country code '\(country.apiCountryCode)' is valid")
                }
            }
            
            await MainActor.run {
                loadingProgress = 0.3
                loadingPhase = "Download completed, received \(apiStations.count) stations"
            }
            
            guard !apiStations.isEmpty else {
                print("📡 RadioBrowserAPI: No stations found for \(country.name)")
                isLoadingFromAPI = false
                isLoading = false
                loadingProgress = 0.0
                loadingPhase = ""
                return
            }
            
            await MainActor.run {
                totalStationsToLoad = apiStations.count
                loadingPhase = "Preparing to process \(totalStationsToLoad) stations"
                loadingProgress = 0.32
            }
            
            // DEDUPLICATION: Filter out stations with identical URLs from the API response
            // Prioritize HTTPS URLs over HTTP when same URL exists with both protocols
            await MainActor.run {
                loadingPhase = "Checking for duplicates"
                loadingProgress = 0.35
            }
            
            var urlToStationMap = [String: RadioBrowserStation]()
            var processedCount = 0
            
            // First pass: collect all stations and handle HTTP/HTTPS duplicates
            for apiStation in apiStations {
                processedCount += 1
                
                // Update progress during deduplication
                if processedCount % 50 == 0 || processedCount == apiStations.count {
                    let dedupeProgress = Double(processedCount) / Double(apiStations.count) * 0.15 // 15% range for deduplication
                    Task { @MainActor in
                        loadingProgress = 0.35 + dedupeProgress
                        loadingPhase = "Checking duplicates \(processedCount)/\(apiStations.count)"
                    }
                }
                
                guard !apiStation.url.isEmpty else { continue }
                
                let url = apiStation.url.lowercased()
                
                // Create normalized URL by removing protocol to check for HTTP/HTTPS duplicates
                let normalizedURL: String
                if url.hasPrefix("https://") {
                    normalizedURL = String(url.dropFirst(8)) // Remove "https://"
                } else if url.hasPrefix("http://") {
                    normalizedURL = String(url.dropFirst(7)) // Remove "http://"
                } else {
                    normalizedURL = url
                }
                
                // Check if we already have this URL with a different protocol
                let httpsURL = "https://" + normalizedURL
                let httpURL = "http://" + normalizedURL
                
                let currentURL = apiStation.url
                
                if let existingStation = urlToStationMap[normalizedURL] {
                    // We have a duplicate - prioritize HTTPS
                    let existingIsHTTPS = existingStation.url.lowercased().hasPrefix("https://")
                    let currentIsHTTPS = currentURL.lowercased().hasPrefix("https://")
                    
                    if currentIsHTTPS && !existingIsHTTPS {
                        // Current is HTTPS, existing is HTTP - replace with HTTPS
                        print("🔄 Replacing HTTP with HTTPS: \(existingStation.url) -> \(currentURL) (Station: \(apiStation.name))")
                        urlToStationMap[normalizedURL] = apiStation
                    } else if !currentIsHTTPS && existingIsHTTPS {
                        // Current is HTTP, existing is HTTPS - keep existing
                        print("🔄 Skipping HTTP (keeping HTTPS): \(currentURL) (Station: \(apiStation.name))")
                    } else {
                        // Both same protocol or both non-standard - keep first (usually higher click count)
                        print("🔄 Skipping duplicate URL: \(currentURL) (Station: \(apiStation.name))")
                    }
                } else {
                    // New URL - add it
                    urlToStationMap[normalizedURL] = apiStation
                }
            }
            
            let deduplicatedStations = Array(urlToStationMap.values)
            
            let duplicatesSkippedFromAPI = apiStations.count - deduplicatedStations.count
            if duplicatesSkippedFromAPI > 0 {
                print("⚡ URL Deduplication: Filtered out \(duplicatesSkippedFromAPI) stations with duplicate URLs from API response")
            }
            
            print("📡 RadioBrowserAPI: Processing \(deduplicatedStations.count) unique stations (removed \(duplicatesSkippedFromAPI) URL duplicates)")
            
            // Use deduplicated stations for processing
            let processedAPIStations = deduplicatedStations
            await MainActor.run {
                totalStationsToLoad = processedAPIStations.count
                loadingPhase = "Converting \(totalStationsToLoad) stations"
                loadingProgress = 0.5
            }
            
            // Convert API stations to app stations, preserving existing favicon data if available
            // Handle duplicates in stations array before creating dictionary
            var stationsByID: [String: RadioStation] = [:]
            for station in stations {
                if let existingStation = stationsByID[station.id] {
                    // Keep the station with more recent lastPlayed date, or existing if dates are equal
                    if let stationLastPlayed = station.lastPlayed,
                       let existingLastPlayed = existingStation.lastPlayed,
                       stationLastPlayed > existingLastPlayed {
                        stationsByID[station.id] = station
                        print("🔄 Duplicate station ID '\(station.id)' found - keeping newer (API conversion)")
                    }
                    // Otherwise keep existing
                } else {
                    stationsByID[station.id] = station
                }
            }
            let existingStationsMap = stationsByID
            var cachedFaviconCount = 0
            var conversionProcessedCount = 0
            
            let newStations: [RadioStation] = processedAPIStations.compactMap { apiStation in
                conversionProcessedCount += 1
                
                // Update progress every 10 stations or on completion for smoother progress
                if conversionProcessedCount % 10 == 0 || conversionProcessedCount == totalStationsToLoad {
                    // Map conversion progress from 50% to 75% (25% range)
                    let conversionProgress = Double(conversionProcessedCount) / Double(totalStationsToLoad) * 0.25
                    Task { @MainActor in
                        loadingStationsCount = conversionProcessedCount
                        loadingProgress = 0.5 + conversionProgress
                        loadingPhase = "Converting stations \(conversionProcessedCount)/\(totalStationsToLoad)"
                    }
                }
                
                guard !apiStation.url.isEmpty else { 
                    return nil 
                }
                
                // Skip stations that were manually deleted by the user
                if isStationDeleted(apiStation.stationuuid) {
                    print("🚫 Skipping deleted station: \(apiStation.name) (ID: \(apiStation.stationuuid))")
                    return nil
                }
                
                // CRITICAL: Skip API stations that duplicate manual stations
                if ManualStationManager.shared.isManualStation(name: apiStation.name, country: country.name) {
                    print("📻 Skipping API station '\(apiStation.name)' - duplicate of manual station")
                    return nil
                }
                
                // CROSS-COUNTRY CONTAMINATION PREVENTION: Validate station country
                let stationCountryFromAPI = apiStation.country ?? country.name
                let tempStation = RadioStation(
                    id: apiStation.stationuuid,
                    name: apiStation.name,
                    url: apiStation.url,
                    iconData: nil,
                    country: stationCountryFromAPI,
                    isFavorite: false,
                    favoritedAt: nil,
                    favoriteOrder: nil,
                    order: 0,
                    lastPlayed: nil
                )
                
                if !isStationCountryValid(tempStation) {
                    print("🚨 API CONTAMINATION BLOCKED: Station '\(apiStation.name)' (API Country: '\(stationCountryFromAPI)') failed validation for '\(country.name)'")
                    
                    // Try to correct the country
                    if let correctedStation = attemptStationCountryCorrection(tempStation) {
                        print("🛡️ API CONTAMINATION FIXED: Corrected station '\(apiStation.name)' country to '\(correctedStation.country)'")
                        // Continue with corrected country
                    } else {
                        print("🗑️ API CONTAMINATION REMOVED: Discarded station '\(apiStation.name)' - could not determine correct country")
                        return nil
                    }
                }
                
                // Check if we already have this station and preserve its favorite status and icon data
                // Check both Core Data (existingStationsMap) and in-memory stations
                let existingStationFromCoreData = existingStationsMap[apiStation.stationuuid]
                let existingStationFromMemory = stations.first { $0.id == apiStation.stationuuid || $0.url == apiStation.url }
                
                // Prioritize in-memory station (more up-to-date) over Core Data
                let existingStation = existingStationFromMemory ?? existingStationFromCoreData
                let existingIconData = existingStation?.iconData
                
                if existingIconData != nil {
                    cachedFaviconCount += 1
                }
                
                // Log when preserving favorite status
                if existingStation?.isFavorite == true {
                    print("⭐ FAVORITE PRESERVED: Keeping favorite status for API station '\(apiStation.name)'")
                }
                
                // Clean station name by trimming whitespace and ALL leading special characters
                var cleanedName = apiStation.name.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove all leading special characters (non-alphanumeric)
                while !cleanedName.isEmpty && !cleanedName.first!.isLetter && !cleanedName.first!.isNumber {
                    cleanedName.removeFirst()
                    cleanedName = cleanedName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // Final trim to ensure no trailing whitespace
                cleanedName = cleanedName.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Use actual country from API if available, otherwise use selected country as fallback
                // Never assign "Select Country" or other invalid country names to stations
                let stationCountry: String
                if let apiCountry = apiStation.country, !apiCountry.isEmpty && apiCountry.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
                    let trimmedApiCountry = apiCountry.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Debug logging for Vatican City and other small countries
                    if country.name == "Vatican City" || trimmedApiCountry.lowercased().contains("vatican") || trimmedApiCountry.lowercased().contains("holy") {
                        print("🏛️ Vatican Debug: API returned '\(trimmedApiCountry)' for selected country '\(country.name)'")
                    }
                    
                    // Debug logging for Saint Vincent & Grenadines
                    if country.name == "Saint Vincent & Grenadines" || trimmedApiCountry.lowercased().contains("saint vincent") || trimmedApiCountry.lowercased().contains("st. vincent") || trimmedApiCountry.lowercased().contains("grenadines") {
                        print("🏝️ Saint Vincent Debug: API returned '\(trimmedApiCountry)' for selected country '\(country.name)'")
                    }
                    
                    // Debug logging for Saint Pierre & Miquelon
                    if country.name == "Saint Pierre & Miquelon" || trimmedApiCountry.lowercased().contains("saint pierre") || trimmedApiCountry.lowercased().contains("st. pierre") || trimmedApiCountry.lowercased().contains("miquelon") {
                        print("🇫🇷 Saint Pierre Debug: API returned '\(trimmedApiCountry)' for selected country '\(country.name)'")
                    }
                    
                    // Normalize API country names to match our Country model
                    let normalizedCountry = normalizeAPICountryName(trimmedApiCountry)
                    stationCountry = normalizedCountry ?? country.name
                    
                    // Debug logging for normalization results
                    if country.name == "Vatican City" || trimmedApiCountry.lowercased().contains("vatican") || trimmedApiCountry.lowercased().contains("holy") {
                        print("🏛️ Vatican Debug: Normalized to '\(stationCountry)'")
                    }
                    
                    if country.name == "Saint Vincent & Grenadines" || trimmedApiCountry.lowercased().contains("saint vincent") || trimmedApiCountry.lowercased().contains("st. vincent") || trimmedApiCountry.lowercased().contains("grenadines") {
                        print("🏝️ Saint Vincent Debug: Normalized to '\(stationCountry)'")
                    }
                    
                    if country.name == "Saint Pierre & Miquelon" || trimmedApiCountry.lowercased().contains("saint pierre") || trimmedApiCountry.lowercased().contains("st. pierre") || trimmedApiCountry.lowercased().contains("miquelon") {
                        print("🇫🇷 Saint Pierre Debug: Normalized to '\(stationCountry)'")
                    }
                } else if country.name != "Select Country" && !country.name.isEmpty {
                    stationCountry = country.name
                    if country.name == "Vatican City" {
                        print("🏛️ Vatican Debug: Using fallback country name '\(stationCountry)'")
                    }
                    if country.name == "Saint Vincent & Grenadines" {
                        print("🏝️ Saint Vincent Debug: Using fallback country name '\(stationCountry)'")
                    }
                    if country.name == "Saint Pierre & Miquelon" {
                        print("🇫🇷 Saint Pierre Debug: Using fallback country name '\(stationCountry)'")
                    }
                } else {
                    // Skip stations that don't have valid country information
                    return nil
                }
                
                return RadioStation(
                    id: apiStation.stationuuid,
                    name: cleanedName,
                    url: apiStation.url,
                    iconData: existingIconData, // Use cached favicon if available
                    country: stationCountry,
                    isFavorite: existingStation?.isFavorite ?? false, // Preserve existing favorite status
                    favoritedAt: existingStation?.favoritedAt, // Preserve existing favorite date
                    favoriteOrder: existingStation?.favoriteOrder, // Preserve existing favorite order
                    order: existingStation?.order ?? 0, // Preserve existing order
                    lastPlayed: existingStation?.lastPlayed // Preserve existing last played date
                )
            }
            
            // Download favicons in background only for stations that don't have them (non-blocking)
            let stationsNeedingFavicons = newStations.filter { $0.iconData == nil }
            if !stationsNeedingFavicons.isEmpty {
                // Handle potential duplicate stationuuid in API data
                var apiStationsMap: [String: RadioBrowserStation] = [:]
                for apiStation in processedAPIStations {
                    if apiStationsMap[apiStation.stationuuid] != nil {
                        print("🔄 Duplicate API station UUID '\(apiStation.stationuuid)' found - keeping first occurrence")
                    } else {
                        apiStationsMap[apiStation.stationuuid] = apiStation
                    }
                }
                let correspondingAPIStations = stationsNeedingFavicons.compactMap { station in
                    apiStationsMap[station.id]
                }
                
                Task.detached { [weak self] in
                    await self?.downloadFaviconsInBackground(for: stationsNeedingFavicons, apiStations: correspondingAPIStations)
                }
            }
            
            // Filter out stations that already exist (check by URL to avoid duplicates)
            // Use Core Data as the source of truth to avoid race conditions with in-memory array
            await MainActor.run {
                loadingPhase = "Filtering existing stations"
                loadingProgress = 0.75
            }
            
            // Get existing URLs from Core Data to avoid race conditions with in-memory array
            let existingURLs: Set<String> = await withCheckedContinuation { continuation in
                let backgroundContext = CoreDataStack.shared.newBackgroundContext()
                backgroundContext.perform {
                    let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                    fetchRequest.propertiesToFetch = ["url"] // Only fetch URLs for performance
                    
                    do {
                        let existingStations = try backgroundContext.fetch(fetchRequest)
                        let urls = Set(existingStations.compactMap { $0.url })
                        continuation.resume(returning: urls)
                    } catch {
                        print("⚠️ Error fetching existing URLs from Core Data: \(error)")
                        // Fallback to in-memory array
                        continuation.resume(returning: Set(self.stations.map { $0.url }))
                    }
                }
            }
            
            // Filter out stations that already exist by URL AND exclude any manual stations that might have been mixed in
            let uniqueNewStations = newStations.filter { station in
                // ENHANCED PROTECTION: Check both Core Data and in-memory stations for existing URLs
                let urlExistsInCoreData = existingURLs.contains(station.url)
                let existingInMemoryStation = stations.first { $0.url == station.url }
                
                // If URL exists in Core Data, skip
                if urlExistsInCoreData {
                    print("🚫 IMPORT PROTECTION: Skipping API station '\(station.name)' - URL exists in Core Data")
                    return false
                }
                
                // If URL exists in memory, check if we should protect the existing station
                if let existingStation = existingInMemoryStation {
                    // ENHANCED PROTECTION: Protect stations that are user-imported or have custom data
                    let isUserImported = existingStation.iconData != nil || 
                                       existingStation.iTunesArtworkData != nil || 
                                       existingStation.id.hasPrefix("manual_") ||
                                       existingStation.id.hasPrefix("import_") // Mark imported stations
                    
                    if isUserImported {
                        print("🛡️ IMPORT PROTECTION: Skipping API station '\(station.name)' - protecting user-imported station '\(existingStation.name)'")
                        return false
                    } else {
                        print("🔄 API REPLACEMENT: Allowing API station '\(station.name)' to replace existing API station '\(existingStation.name)'")
                    }
                }
                
                // CRITICAL: Exclude manual stations entirely from API processing
                guard !station.id.hasPrefix("manual_") else {
                    print("📻 🚫 MANUAL STATION EXCLUDED: Manual station \(station.name) (ID: \(station.id)) excluded from API CloudKit save")
                    return false
                }
                
                return true
            }
            
            // Debug logging for Canada to track duplicate issue
            if country.name == "Canada" {
                print("🍁 Canada Debug: API returned \(apiStations.count) stations")
                print("🍁 Canada Debug: After URL deduplication: \(processedAPIStations.count) stations")
                print("🍁 Canada Debug: After conversion: \(newStations.count) stations")
                print("🍁 Canada Debug: Existing URLs in Core Data: \(existingURLs.count)")
                print("🍁 Canada Debug: Unique new stations to add: \(uniqueNewStations.count)")
                if !uniqueNewStations.isEmpty {
                    print("🍁 Canada Debug: New station URLs: \(uniqueNewStations.map { $0.url })")
                    print("🍁 Canada Debug: New station names: \(uniqueNewStations.map { $0.name })")
                }
            }
            
            await MainActor.run {
                loadingPhase = "Analyzing results"
                loadingProgress = 0.8
            }
            
            // Calculate counts for notification
            let totalFetched = apiStations.count
            let totalAfterURLDeduplication = processedAPIStations.count
            let deletedStationsFiltered = totalAfterURLDeduplication - newStations.count
            let newStationsAdded = uniqueNewStations.count
            let duplicatesSkipped = newStations.count - newStationsAdded
            
            if uniqueNewStations.isEmpty {
                print("📡 RadioBrowserAPI: All fetched stations already exist for \(country.name) - stations are up to date")
            } else {
                print("📡 RadioBrowserAPI: Found \(newStationsAdded) new stations for \(country.name)")
            }
            
            await MainActor.run {
                if uniqueNewStations.isEmpty {
                    loadingPhase = "Stations are up to date"
                } else {
                    loadingPhase = "Adding \(uniqueNewStations.count) new stations"
                }
                loadingProgress = 0.82
            }
            
            // Add to local stations array (new stations at the top) - only if there are new stations
            if !uniqueNewStations.isEmpty {
                print("📡 RadioBrowserAPI: Adding \(uniqueNewStations.count) new stations for \(country.name)")
                
                for newStation in uniqueNewStations.reversed() {
                    // CRITICAL PROTECTION: Double-check that we're not overwriting an imported station with custom data
                    let existingStationIndex = stations.firstIndex { $0.url == newStation.url }
                    if let existingIndex = existingStationIndex {
                        let existingStation = stations[existingIndex]
                        // If existing station has custom icon data or is manually imported, preserve it
                        if existingStation.iconData != nil || existingStation.iTunesArtworkData != nil || existingStation.id.hasPrefix("manual_") {
                            print("🛡️ IMPORT PROTECTION: Preserving user-imported station '\(existingStation.name)' with custom data over API station")
                            continue // Skip adding this API station
                        }
                    }
                    
                    // Increment order of existing stations in the same country to make room at top
                    for i in 0..<stations.count {
                        if stations[i].country == country.name {
                            stations[i].order += 1
                        }
                    }
                    // Insert new station at the beginning of the array
                    stations.insert(newStation, at: 0)
                }
            }
            
            if uniqueNewStations.isEmpty {
                print("✅ Stations for \(country.name) are up to date - no new stations found")
            } else {
                print("✅ Added \(uniqueNewStations.count) new stations for \(country.name)")
            }
            if country.name == "Vatican City" {
                print("🏛️ Vatican Debug: Added stations with countries: \(uniqueNewStations.map { $0.country })")
                print("🏛️ Vatican Debug: Station names: \(uniqueNewStations.map { $0.name })")
            }
            if country.name == "Saint Vincent & Grenadines" {
                print("🏝️ Saint Vincent Debug: Added stations with countries: \(uniqueNewStations.map { $0.country })")
                print("🏝️ Saint Vincent Debug: Station names: \(uniqueNewStations.map { $0.name })")
            }
            if country.name == "Saint Pierre & Miquelon" {
                print("🇫🇷 Saint Pierre Debug: Added stations with countries: \(uniqueNewStations.map { $0.country })")
                print("🇫🇷 Saint Pierre Debug: Station names: \(uniqueNewStations.map { $0.name })")
            }
            if cachedFaviconCount > 0 {
                print("🖼️ Using \(cachedFaviconCount) cached favicons, downloading \(uniqueNewStations.count - cachedFaviconCount) new ones")
            }
            
            // Only save and sync if there are new stations to process
            if !uniqueNewStations.isEmpty {
                // Trigger immediate UI refresh after adding stations to in-memory array
                await MainActor.run {
                    self.objectWillChange.send()
                    loadingPhase = "Preparing local storage"
                    loadingProgress = 0.85
                }
            } else {
                // No new stations, but still update progress
                await MainActor.run {
                    loadingPhase = "Check complete - stations up to date"
                    loadingProgress = 0.85
                }
            }
            
            // Only save to Core Data if there are new stations
            if !uniqueNewStations.isEmpty {
                saveStationsToCoreData()
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                }
            }
            
            // Only do CloudKit sync if there are new stations
            if !uniqueNewStations.isEmpty {
                await MainActor.run {
                    loadingPhase = "Saving to local storage"
                    loadingProgress = 0.9
                }
                
                // Save to CloudKit (using the same method as import for new stations)
                await MainActor.run {
                    loadingPhase = "Initiating cloud sync"
                    loadingProgress = 0.93
                    
                    // Update DataSyncManager to show CloudKit save progress
                    DataSyncManager.shared.radioStationsStatus = .inProgress
                    DataSyncManager.shared.radioStationsOperation = "Saving \(uniqueNewStations.count) new stations to iCloud.\nWait for iCloud sync to complete before importing other stations."
                    DataSyncManager.shared.radioStationsProgress = 0.95
                    DataSyncManager.shared.radioStationsTotalCount = uniqueNewStations.count
                    DataSyncManager.shared.radioStationsCurrentCount = 0
                }
            } else {
                // Skip CloudKit sync when no new stations
                await MainActor.run {
                    loadingPhase = "No new stations to sync"
                    loadingProgress = 0.93
                }
            }
            
            // Only call CloudKit save if there are new stations
            if !uniqueNewStations.isEmpty {
                // Check if this is the first time loading API stations for this country
                let userDefaults = UserDefaults.standard
                let firstLoadKey = "APIStationsFirstLoad_\(country.name)"
                let isFirstLoad = !userDefaults.bool(forKey: firstLoadKey)
                
                print("📡 🔍 FIRST LOAD CHECK: Country \(country.name) - First load: \(isFirstLoad)")
                
                // ENHANCED FILTERING: Double-check to ensure we only save NEW API stations (not manual stations)
                let manualStationsFound = uniqueNewStations.filter { $0.id.hasPrefix("manual_") }
                let apiOnlyNewStations = uniqueNewStations.filter { station in
                    // Exclude manual stations (they have their own sync process)
                    let isManual = station.id.hasPrefix("manual_")
                    if isManual {
                        print("📻 🚫 DOUBLE-CHECK EXCLUSION: Manual station \(station.name) (ID: \(station.id)) excluded from CloudKit save")
                    }
                    return !isManual
                }
                
                if !manualStationsFound.isEmpty {
                    print("📻 ⚠️ WARNING: Found \(manualStationsFound.count) manual stations in uniqueNewStations that should not be there!")
                    for manualStation in manualStationsFound {
                        print("📻 ⚠️ Manual station found: \(manualStation.name) (ID: \(manualStation.id))")
                    }
                }
                
                if apiOnlyNewStations.isEmpty {
                    print("📡 ℹ️ No new API stations to save to CloudKit - all new stations were manual stations (\(manualStationsFound.count) manual stations excluded)")
                    
                    // Show notification for no new stations case
                    await MainActor.run {
                        self.showStationFetchNotification(
                            country: country,
                            actualNewStations: 0,
                            duplicatesSkippedFromAPI: duplicatesSkippedFromAPI,
                            duplicatesSkipped: duplicatesSkipped,
                            deletedStationsFiltered: deletedStationsFiltered
                        )
                    }
                } else {
                    // Determine which stations to save based on first load vs subsequent loads
                    let stationsToSave: [RadioStation]
                    if isFirstLoad {
                        // First load: Save all API stations to CloudKit
                        stationsToSave = apiOnlyNewStations
                        print("📡 🔄 FIRST LOAD: Saving ALL \(apiOnlyNewStations.count) API stations to CloudKit for \(country.name)")
                    } else {
                        // Subsequent loads: Only save stations that are actually new (not in CloudKit)
                        print("📡 🔄 SUBSEQUENT LOAD: Only saving truly new stations to CloudKit for \(country.name)")
                        stationsToSave = apiOnlyNewStations
                    }
                    
                    print("📡 🔄 Saving \(stationsToSave.count) API stations to CloudKit (excluding \(uniqueNewStations.count - apiOnlyNewStations.count) manual stations)")
                    
                    // Use different save methods based on first load vs subsequent loads
                    if isFirstLoad {
                        // First load: Use batch save method to save all stations efficiently
                        Task {
                            do {
                                try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(
                                    stationsToSave,
                                    country: country.name,
                                    progressCallback: { progress, count, message in
                                        Task { @MainActor in
                                            DataSyncManager.shared.updateRadioStationProgress(progress, currentCount: count, operation: message)
                                        }
                                    }
                                )
                                
                                // Mark first load as complete
                                userDefaults.set(true, forKey: firstLoadKey)
                                userDefaults.synchronize()
                                print("📡 ✅ FIRST LOAD COMPLETE: Marked API stations as loaded for \(country.name)")
                                
                                await MainActor.run {
                                    DataSyncManager.shared.radioStationsStatus = .completed
                                    DataSyncManager.shared.radioStationsOperation = "Saved \(stationsToSave.count) stations to iCloud (first load)"
                                    DataSyncManager.shared.radioStationsProgress = 1.0
                                    DataSyncManager.shared.radioStationsCurrentCount = stationsToSave.count
                                    
                                    // Show notification
                                    self.showStationFetchNotification(
                                        country: country,
                                        actualNewStations: stationsToSave.count,
                                        duplicatesSkippedFromAPI: duplicatesSkippedFromAPI,
                                        duplicatesSkipped: duplicatesSkipped,
                                        deletedStationsFiltered: deletedStationsFiltered
                                    )
                                }
                            } catch {
                                print("📡 ❌ First load CloudKit save failed: \(error)")
                                await MainActor.run {
                                    DataSyncManager.shared.radioStationsStatus = .failed
                                    DataSyncManager.shared.radioStationsOperation = "Failed to save stations: \(error.localizedDescription)"
                                }
                            }
                        }
                    } else {
                        // Subsequent loads: Use selective save method (existing logic)
                        DataStore.shared.saveNewStationsToCloudKit(stations: stationsToSave) { success, recordIDs in
                DispatchQueue.main.async {
                    let actualSavedCount = recordIDs?.count ?? 0
                    
                    if success {
                        print("📡 ✅ Successfully saved \(actualSavedCount) API-fetched stations to CloudKit for \(country.name)")
                        
                        // Update DataSyncManager on success
                        DataSyncManager.shared.radioStationsStatus = .completed
                        DataSyncManager.shared.radioStationsOperation = "Saved \(actualSavedCount) new stations to iCloud"
                        DataSyncManager.shared.radioStationsProgress = 1.0
                        DataSyncManager.shared.radioStationsCurrentCount = actualSavedCount
                        // Re-save merged set to Core Data to ensure we don't lose just-added items
                        self.saveStationsToCoreData()
                        NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                        
                        // FIXED: Show notification with actual count of saved stations
                        Task { @MainActor in
                            self.showStationFetchNotification(
                                country: country,
                                actualNewStations: actualSavedCount,
                                duplicatesSkippedFromAPI: duplicatesSkippedFromAPI,
                                duplicatesSkipped: duplicatesSkipped,
                                deletedStationsFiltered: deletedStationsFiltered
                            )
                        }
                    } else {
                        print("📡 ⚠️ Failed to save some API-fetched stations to CloudKit for \(country.name)")
                        
                        // Update DataSyncManager on failure
                        DataSyncManager.shared.radioStationsStatus = .failed
                        DataSyncManager.shared.radioStationsOperation = "Failed to save new stations to iCloud"
                        DataSyncManager.shared.radioStationsProgress = 0.0
                        
                        // Show notification for failure case
                        Task { @MainActor in
                            self.showStationFetchNotification(
                                country: country,
                                actualNewStations: 0,
                                duplicatesSkippedFromAPI: duplicatesSkippedFromAPI,
                                duplicatesSkipped: duplicatesSkipped,
                                deletedStationsFiltered: deletedStationsFiltered
                            )
                        }
                    }
                        }
                    }
                }
            }
            } // End of uniqueNewStations.isEmpty condition
            
            await MainActor.run {
                loadingPhase = "Completing sync"
                loadingProgress = 0.96
            }
            
            // Notification is now handled in CloudKit save callback or no-new-stations case
            
            // Notify that stations have been updated
            await MainActor.run {
                loadingPhase = "Finalizing"
                loadingProgress = 0.98
            }
            
            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
            
            // Complete loading
            await MainActor.run {
                loadingPhase = "Completed!"
                loadingProgress = 1.0
            }
            
        } catch {
            print("❌ RadioBrowserAPI: Failed to fetch stations for \(country.name): \(error)")
            await MainActor.run {
                loadingPhase = "Failed to load stations"
                loadingProgress = 0.0
            }
        }
        
        await MainActor.run {
            isLoadingFromAPI = false
            isLoading = false
            
            // Mark that changes might be expected on other devices after API fetch
            forceCloudKitCheckOnNextLaunch()
        }
        
        // Reset progress values after a short delay with weak self capture
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                guard let self = self else { return }
                self.loadingProgress = 0.0
                self.loadingStationsCount = 0
                self.totalStationsToLoad = 0
                self.loadingPhase = ""
            }
        }
    }
    
    @MainActor
    func fetchStationsForAllCountries() async {
        print("🌐 Radio Browser API: Starting to fetch stations for all countries")
        
        let supportedCountries = countries.filter { $0.supportsRadioLookup }
        print("🌐 Radio Browser API: Found \(supportedCountries.count) supported countries")
        
        let initialStationCount = stations.count
        
        for country in supportedCountries {
            await fetchStationsFromAPI(for: country)
            
            // Add a small delay to be respectful to the API
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        let finalStationCount = stations.count
        let totalStationsAdded = finalStationCount - initialStationCount
        
        print("🌐 Radio Browser API: Finished fetching stations for all countries")
        
        // Notify user about the overall results (only when new stations were added)
        if totalStationsAdded > 0 {
            DispatchQueue.main.async {
                NotificationManager.shared.notifyUserImmediate(
                    title: "Global Radio Fetch Complete",
                    message: "Completed fetching stations from \(supportedCountries.count) countries. Added \(totalStationsAdded) new stations to your collection."
                )
            }
        }
    }
    
    @MainActor
    func fetchStationsForCurrentCountry() async {
        guard let currentCountry = countries.first(where: { $0.name == selectedCountry }) else {
            print("🌐 Radio Browser API: No country selected or country not found")
            return
        }
        
        await fetchStationsFromAPI(for: currentCountry)
    }
    
    @MainActor
    func fetchStationsForSelectedCountry(forceRefresh: Bool = false) async {
        print("🌐 Manual + API Station Loading: fetchStationsForSelectedCountry called for country: \(selectedCountry), forceRefresh: \(forceRefresh)")
        
        // Cancel any ongoing fetch to prevent memory issues and conflicts
        currentFetchTask?.cancel()
        
        // Create new fetch task
        currentFetchTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Capture values synchronously to avoid await issues
            let selectedCountryName = self.selectedCountry
            let countriesArray = self.countries
            
            // STEP 1: Load manual stations first (they take priority)
            print("📻 🔍 DEBUG: About to load manual stations for \(selectedCountryName)")
            await self.loadManualStationsForCountry(selectedCountryName)
            print("📻 🔍 DEBUG: Finished loading manual stations for \(selectedCountryName)")
            
            // STEP 2: Always check API for new stations, but handle existing ones efficiently
            let existingAPIStationsCount = await self.getExistingAPIStationsCount(for: selectedCountryName)
            
            if !forceRefresh && existingAPIStationsCount > 0 {
                print("🌐 🔄 INCREMENTAL UPDATE: Found \(existingAPIStationsCount) existing API stations for \(selectedCountryName), checking for new stations from API")
                
                // Load existing stations from Core Data to display them immediately
                await self.loadExistingStationsForCountry(selectedCountryName)
            } else if forceRefresh {
                print("🌐 🔄 FORCE REFRESH: Fetching fresh stations from API for \(selectedCountryName)")
            } else {
                print("🌐 📡 FIRST TIME FETCH: No existing API stations found for \(selectedCountryName), proceeding with full API fetch")
            }
            
            // STEP 3: Always fetch from API to check for new stations (existing ones will be filtered out)
            // First try to find the country in the existing countries array
            var currentCountry = countriesArray.first(where: { $0.name == selectedCountryName })
            
            // If not found (common on fresh install), create a country object as fallback
            if currentCountry == nil && selectedCountryName != "Select Country" {
                print("🌐 Radio Browser API: Country not found in array, creating fallback country object for: \(selectedCountryName)")
                currentCountry = Country(name: selectedCountryName, flag: "")
                print("🌐 Radio Browser API: Created fallback country with API code: \(currentCountry?.apiCountryCode ?? "nil")")
            }
            
            guard let country = currentCountry else {
                print("🌐 Radio Browser API: No country selected or could not create country object for: \(selectedCountryName)")
                return
            }
            
            print("🌐 Radio Browser API: Found/created country: \(country.name) with API code: \(country.apiCountryCode)")
            
            // Check if task was cancelled before proceeding
            guard !Task.isCancelled else {
                print("🌐 Radio Browser API: Fetch task was cancelled before execution")
                return
            }
            
            await self.fetchStationsFromAPI(for: country)
        }
        
        await currentFetchTask?.value
    }
    
    /// Check how many API stations already exist for a country in Core Data
    @MainActor
    private func getExistingAPIStationsCount(for country: String) async -> Int {
        return await withCheckedContinuation { continuation in
            let backgroundContext = CoreDataStack.shared.newBackgroundContext()
            backgroundContext.perform {
                let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "country == %@", country)
                
                do {
                    let count = try backgroundContext.count(for: fetchRequest)
                    continuation.resume(returning: count)
                } catch {
                    print("⚠️ Error counting existing stations for \(country): \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }
    
    /// Load existing stations for a country from Core Data and display them
    @MainActor
    private func loadExistingStationsForCountry(_ country: String) async {
        // Filter and display stations for the selected country from the current in-memory stations
        let countryStations = stations.filter { $0.country == country }
        
        if countryStations.isEmpty {
            // If no stations in memory, load from Core Data
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            request.predicate = NSPredicate(format: "country == %@", country)
            request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
            
            do {
                let results = try context.fetch(request)
                let loadedStations = results.map { cdStation in
                    RadioStation(
                        id: cdStation.id ?? UUID().uuidString,
                        name: cdStation.name ?? "Unknown",
                        url: cdStation.url ?? "http://default.url",
                        iconData: cdStation.iconData,
                        country: cdStation.country ?? "Unknown",
                        isFavorite: cdStation.isFavorite,
                        favoritedAt: cdStation.favoritedAt,
                        favoriteOrder: cdStation.favoriteOrder >= 0 ? Int(cdStation.favoriteOrder) : nil,
                        order: Int(cdStation.order),
                        lastPlayed: cdStation.lastPlayed
                    )
                }
                
                // CRITICAL FIX: Merge loaded stations with existing ones, preserving user-imported stations with custom data
                let existingCountryStations = stations.filter { $0.country == country }
                let existingURLs = Set(existingCountryStations.map { $0.url })
                
                // Enhanced filtering: Only add loaded stations that don't conflict with user-imported stations
                let newLoadedStations = loadedStations.filter { loadedStation in
                    // Skip if URL already exists in memory
                    guard !existingURLs.contains(loadedStation.url) else {
                        return false
                    }
                    
                    // Double-check: if there's an existing station with custom data, don't override it
                    if let existingStation = existingCountryStations.first(where: { $0.url == loadedStation.url }) {
                        if existingStation.iconData != nil || existingStation.iTunesArtworkData != nil {
                            print("🛡️ CORE DATA PROTECTION: Preserving user-imported station '\(existingStation.name)' over Core Data version")
                            return false
                        }
                    }
                    
                    return true
                }
                
                // Keep all non-country stations + existing country stations + new loaded stations
                stations = stations.filter { $0.country != country } + existingCountryStations + newLoadedStations
                print("🌐 ✅ Loaded \(loadedStations.count) cached stations for \(country) from Core Data (added \(newLoadedStations.count) new, preserved \(existingCountryStations.count) existing)")
            } catch {
                print("⚠️ Error loading cached stations for \(country): \(error)")
            }
        } else {
            print("🌐 ✅ Displaying \(countryStations.count) cached stations for \(country) from memory")
        }
    }

    /// Load manual stations for a specific country
    @MainActor
    private func loadManualStationsForCountry(_ country: String) async {
        guard country != "Select Country" else { return }
        
        let allManualStations = ManualStationManager.shared.getManualStations(for: country)
        print("📻 🔍 DEBUG: Found \(allManualStations.count) total manual stations for \(country)")
        
        // Debug: Log all manual station IDs and their deleted status
        for station in allManualStations {
            let isDeleted = isStationDeleted(station.id)
            print("📻 🔍 Manual station: \(station.name) (ID: \(station.id)) - Deleted: \(isDeleted)")
        }
        
        // CRITICAL: Filter out manually deleted stations
        // Apply the same protection rule as API stations
        let manualStations = allManualStations.filter { station in
            if isStationDeleted(station.id) {
                print("🚫 Skipping deleted manual station: \(station.name) (ID: \(station.id))")
                return false
            }
            return true
        }
        
        if !manualStations.isEmpty {
            print("📻 Loading \(manualStations.count) manual stations for \(country) (filtered \(allManualStations.count - manualStations.count) deleted)")
            
            // Add manual stations to the beginning of the stations array
            // This ensures they appear first and have priority
            let existingStations = stations.filter { $0.country != country }
            stations = manualStations + existingStations
            
            // Save to Core Data
            saveStationsToCoreData()
            
            // Check if manual stations need to be synced to CloudKit (prevent duplicate syncing)
            let syncKey = "ManualStationsSynced_\(country)_Time"
            let lastSyncTime = UserDefaults.standard.double(forKey: syncKey)
            let currentTime = Date().timeIntervalSince1970
            let syncInterval: TimeInterval = 24 * 60 * 60 // 24 hours
            
            // Only sync if never synced before OR it's been more than 24 hours since last sync
            if lastSyncTime == 0 || (currentTime - lastSyncTime) > syncInterval {
                print("📻 ☁️ SYNC CHECK: Manual stations for \(country) need syncing - lastSync: \(lastSyncTime == 0 ? "never" : "\(Date(timeIntervalSince1970: lastSyncTime))"), interval: \(currentTime - lastSyncTime) seconds")
                print("📻 ☁️ Syncing \(manualStations.count) manual stations to CloudKit for \(country) (last sync: \(lastSyncTime == 0 ? "never" : "\(Int((currentTime - lastSyncTime) / 3600)) hours ago"))...")
                Task {
                    do {
                        // Use batch syncing for better performance
                        try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(
                            manualStations,
                            country: country,
                            progressCallback: { progress, count, message in
                                print("📻 ☁️ Manual stations batch sync progress: \(Int(progress * 100))% - \(message)")
                            }
                        )
                        print("📻 ☁️ ✅ Successfully completed batch syncing \(manualStations.count) manual stations to CloudKit for \(country)")
                        
                        // Mark as synced with current timestamp
                        UserDefaults.standard.set(currentTime, forKey: "\(syncKey)_Time")
                    } catch {
                        print("📻 ☁️ ❌ Failed to batch sync manual stations to CloudKit for \(country): \(error)")
                        print("📻 ☁️ Error details: \(error.localizedDescription)")
                        if let ckError = error as? CKError {
                            print("📻 ☁️ CloudKit error code: \(ckError.code.rawValue)")
                            print("📻 ☁️ CloudKit error description: \(ckError.localizedDescription)")
                        }
                        // Don't mark as synced if it failed, so it will retry next time
                    }
                }
            } else {
                print("📻 ☁️ SYNC SKIPPED: Manual stations for \(country) already synced recently - last sync: \(Date(timeIntervalSince1970: lastSyncTime)), \(Int((currentTime - lastSyncTime) / 3600)) hours ago")
                print("📻 ☁️ Manual stations for \(country) recently synced (\(Int((currentTime - lastSyncTime) / 3600)) hours ago), skipping sync")
            }
            
            print("📻 ✅ Successfully loaded \(manualStations.count) manual stations for \(country)")
        } else {
            print("📻 No manual stations defined for \(country)")
        }
    }
    
    func reportStationClick(for station: RadioStation) {
        Task {
            await RadioBrowserAPI.shared.reportStationClick(stationUuid: station.id)
        }
    }
    
    // MARK: - Country Name Normalization
    
    /// Normalize API country names to match our Country model names
    private func normalizeAPICountryName(_ apiCountryName: String) -> String? {
        let trimmed = apiCountryName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch trimmed {
        // United Kingdom variations (excluded from migration)
        case "The United Kingdom Of Great Britain And Northern Ireland":
            return "United Kingdom"
        
        // United States variations (excluded from migration)
        case "The United States Of America", "United States Of America", "USA", "United States of America", "US", "America":
            return "United States"
        
        // Countries with "The" prefix
        case "The Faroe Islands":
            return "Faroe Islands"
        case "The Netherlands":
            return "Netherlands"
        case "The Bahamas":
            return "Bahamas"
        case "The Gambia":
            return "Gambia"
        
        // Countries with alternative names
        case "Czech Republic", "Czechia":
            return "Czech Republic"
        case "Russian Federation", "Russia (Russian Federation)":
            return "Russia"
        case "Republic of Korea", "Korea (Republic of)":
            return "South Korea"
        case "Democratic People's Republic of Korea", "Korea (Democratic People's Republic of)":
            return "North Korea"
        case "Iran (Islamic Republic of)", "Islamic Republic of Iran":
            return "Iran"
        case "Syria (Syrian Arab Republic)", "Syrian Arab Republic":
            return "Syria"
        case "Venezuela (Bolivarian Republic of)", "Bolivarian Republic of Venezuela":
            return "Venezuela"
        case "Bolivia (Plurinational State of)", "Plurinational State of Bolivia":
            return "Bolivia"
        case "Tanzania (United Republic of)", "United Republic of Tanzania":
            return "Tanzania"
        case "Moldova (Republic of)", "Republic of Moldova":
            return "Moldova"
        case "Macedonia (the former Yugoslav Republic of)", "The Former Yugoslav Republic of Macedonia", "North Macedonia":
            return "Macedonia"
        case "Congo (Democratic Republic of the)", "Democratic Republic of the Congo", "Congo-Kinshasa", "DR Congo":
            return "Congo - Kinshasa"
        case "Congo (Republic of the)", "Republic of the Congo", "Congo-Brazzaville":
            return "Congo - Brazzaville"
        case "Lao People's Democratic Republic", "Laos PDR":
            return "Laos"
        case "Viet Nam":
            return "Vietnam"
        case "Brunei Darussalam":
            return "Brunei"
        case "Myanmar (Burma)", "Burma":
            return "Myanmar"
        
        // Countries with & symbols
        case "Bosnia and Herzegovina", "Bosnia And Herzegovina":
            return "Bosnia & Herzegovina"
        case "Trinidad and Tobago", "Trinidad And Tobago":
            return "Trinidad & Tobago"
        case "São Tomé and Príncipe", "Sao Tome and Principe", "Sao Tome & Principe":
            return "São Tomé & Príncipe"
        case "Antigua and Barbuda", "Antigua And Barbuda":
            return "Antigua & Barbuda"
        case "Saint Kitts and Nevis", "St. Kitts and Nevis", "St Kitts and Nevis", "Saint Kitts & Nevis", "St. Kitts & Nevis", "St Kitts & Nevis":
            return "Saint Kitts & Nevis"
        case "Turks and Caicos Islands", "Turks And Caicos Islands":
            return "Turks & Caicos Islands"
        case "Wallis and Futuna", "Wallis And Futuna":
            return "Wallis & Futuna"
        
        // Saint/St variations
        case "Saint Vincent and the Grenadines", "St. Vincent and the Grenadines", "St Vincent and the Grenadines", "Saint Vincent and Grenadines", "St. Vincent & Grenadines", "St Vincent & Grenadines":
            return "Saint Vincent & Grenadines"
        case "Saint Pierre and Miquelon", "St. Pierre and Miquelon", "St Pierre and Miquelon", "Saint Pierre et Miquelon", "St. Pierre et Miquelon", "St Pierre et Miquelon":
            return "Saint Pierre & Miquelon"
        case "Saint Lucia", "St. Lucia", "St Lucia":
            return "Saint Lucia"
        case "Saint Martin", "St. Martin", "St Martin":
            return "Saint Martin"
        case "Saint Helena", "St. Helena", "St Helena":
            return "Saint Helena"
        case "Saint Barthélemy", "St. Barthélemy", "St Barthélemy", "Saint Barthelemy", "St. Barthelemy", "St Barthelemy":
            return "Saint Barthélemy"
        
        // Vatican variations
        case "Vatican", "Holy See", "Vatican City State", "The Vatican":
            return "Vatican City"
        
        // Virgin Islands variations
        case "U.S. Virgin Islands", "US Virgin Islands", "Virgin Islands (U.S.)", "Virgin Islands, U.S.":
            return "United States Virgin Islands"
        case "British Virgin Islands", "Virgin Islands (British)":
            return "British Virgin Islands"
        
        // Island variations
        case "Falkland Islands (Malvinas)", "Falkland Islands (Islas Malvinas)":
            return "Falkland Islands"
        case "Cocos (Keeling) Islands", "Cocos Islands":
            return "Cocos (Keeling) Islands"
        case "Northern Mariana Islands", "Northern Marianas":
            return "Northern Mariana Islands"
        case "Marshall Islands", "Marshall Is.":
            return "Marshall Islands"
        case "Solomon Islands", "Solomon Is.":
            return "Solomon Islands"
        case "Cayman Islands", "Cayman Is.":
            return "Cayman Islands"
        case "Cook Islands", "Cook Is.":
            return "Cook Islands"
        case "Pitcairn Islands", "Pitcairn":
            return "Pitcairn Islands"
        case "Norfolk Island", "Norfolk Is.":
            return "Norfolk Island"
        case "Christmas Island", "Christmas Is.":
            return "Christmas Island"
        case "Åland Islands", "Aland Islands":
            return "Åland Islands"
        
        // Other territories and dependencies
        case "Palestinian Territory", "Palestine", "Palestinian Territories", "State of Palestine":
            return "Palestinian Territories"
        case "Timor-Leste", "East Timor":
            return "Timor-Leste"
        case "Côte d'Ivoire", "Cote d'Ivoire", "Ivory Coast":
            return "Côte d'Ivoire"
        case "Swaziland", "eSwatini":
            return "Swaziland"
        case "Cape Verde", "Cabo Verde":
            return "Cape Verde"
        case "Guinea-Bissau", "Guinea Bissau":
            return "Guinea-Bissau"
        case "Papua New Guinea", "Papua N. Guinea":
            return "Papua New Guinea"
        case "Equatorial Guinea", "Eq. Guinea":
            return "Equatorial Guinea"
        case "Central African Republic", "CAR", "C.A.R.":
            return "Central African Republic"
        case "Dominican Republic", "Dom. Rep.":
            return "Dominican Republic"
        case "United Arab Emirates", "UAE", "U.A.E.":
            return "United Arab Emirates"
        case "South Africa", "S. Africa":
            return "South Africa"
        case "South Sudan", "S. Sudan":
            return "South Sudan"
        case "New Zealand", "N. Zealand":
            return "New Zealand"
        case "New Caledonia", "N. Caledonia":
            return "New Caledonia"
        case "El Salvador", "Salvador":
            return "El Salvador"
        case "Costa Rica", "C. Rica":
            return "Costa Rica"
        case "Puerto Rico", "P. Rico":
            return "Puerto Rico"
        case "Sierra Leone", "S. Leone":
            return "Sierra Leone"
        case "Saudi Arabia", "S. Arabia":
            return "Saudi Arabia"
        case "French Polynesia", "Fr. Polynesia":
            return "French Polynesia"
        case "French Guiana", "Fr. Guiana":
            return "French Guiana"
        case "American Samoa", "Am. Samoa":
            return "American Samoa"
        case "Western Sahara", "W. Sahara":
            return "Western Sahara"
        
        default:
            // Handle general cases where API adds "The" prefix
            if trimmed.hasPrefix("The ") {
                let withoutThe = String(trimmed.dropFirst(4))
                return withoutThe
            }
            return trimmed
        }
    }
    
    /// Force migration to run immediately (bypasses cooldown) - used for critical fixes
    @MainActor
    func forceMigrateStationCountryNames() {
        // Reset the cleanup timer to force migration
        UserDefaults.standard.set(0, forKey: "LastStationCleanupTime")
        
        // Run migration immediately
        Task {
            await migrateStationCountryNames()
        }
    }
    
    /// Migrate existing stations to use normalized country names and fix massive database corruption
    @MainActor
    func migrateStationCountryNames() {
        print("🔄 Starting country name migration for existing stations...")
        
        let context = CoreDataStack.shared.context
        var migrationCount = 0
        var corruptedStationsRemoved = 0
        var countryReassignments = 0
        
        // Debug: Check all unique country names currently in stations
        let uniqueCountries = Set(stations.map { $0.country })
        print("🔍 Current unique country names: \(uniqueCountries.sorted())")
        
        // CRITICAL FIX: Detect massive database corruption where all stations are assigned to "Italy"
        let italyStationCount = stations.filter { $0.country == "Italy" }.count
        let totalStationCount = stations.count
        let corruptionPercentage = totalStationCount > 0 ? Double(italyStationCount) / Double(totalStationCount) * 100 : 0
        
        print("🚨 CORRUPTION ANALYSIS: \(italyStationCount) of \(totalStationCount) stations (\(String(format: "%.1f", corruptionPercentage))%) assigned to Italy")
        
        // Check if we've done cleanup recently to prevent endless loops
        let lastCleanupTime = UserDefaults.standard.double(forKey: "LastStationCleanupTime")
        let currentTime = Date().timeIntervalSince1970
        let timeSinceLastCleanup = currentTime - lastCleanupTime
        
        // Only run cleanup if it's been more than 1 hour since last cleanup
        if timeSinceLastCleanup < 3600 && lastCleanupTime > 0 { // 3600 = 1 hour
            print("⏭️ Skipping station cleanup (last cleanup: \(Int(timeSinceLastCleanup/60)) minutes ago)")
            return
        }
        
        // If more than 80% of stations are assigned to Italy, this indicates database corruption
        if corruptionPercentage > 80.0 {
            print("🚨 MASSIVE DATABASE CORRUPTION DETECTED!")
            print("🔧 Attempting to fix country assignments using API country codes...")
            
            // Fix corrupted country assignments by inferring correct countries from station names
            for station in stations {
                if station.country == "Italy" {
                    // Try to determine correct country from station name patterns
                    if let correctCountry = inferCountryFromStationName(station.name), correctCountry != "Italy" {
                        print("🔧 Reassigning '\(station.name)' from Italy to '\(correctCountry)'")
                        
                        // Update in memory
                        if let index = stations.firstIndex(where: { $0.id == station.id }) {
                            var updatedStation = stations[index]
                            updatedStation.country = correctCountry
                            stations[index] = updatedStation
                        }
                        
                        // Update in Core Data
                        let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", station.id)
                        
                        do {
                            let managedStations = try context.fetch(fetchRequest)
                            if let managedStation = managedStations.first {
                                managedStation.country = correctCountry
                                countryReassignments += 1
                            }
                        } catch {
                            print("❌ Failed to fetch station for country reassignment: \(error)")
                        }
                    }
                }
            }
        }
        
        // ENHANCED CROSS-COUNTRY CONTAMINATION CLEANUP
        print("🛡️ Starting comprehensive cross-country contamination cleanup...")
        
        var stationsToRemove: [RadioStation] = []
        var stationsToCorrect: [(original: RadioStation, corrected: RadioStation)] = []
        
        for station in stations {
            if !isStationCountryValid(station) {
                // Try to correct the station first
                if let correctedStation = attemptStationCountryCorrection(station) {
                    stationsToCorrect.append((original: station, corrected: correctedStation))
                    print("🛡️ CLEANUP: Will correct station '\(station.name)' from '\(station.country)' to '\(correctedStation.country)'")
                } else {
                    stationsToRemove.append(station)
                    print("🗑️ CLEANUP: Will remove contaminated station '\(station.name)' (Country: '\(station.country)') - could not determine correct country")
                }
            }
        }
        
        // Apply corrections
        for correction in stationsToCorrect {
            if let index = stations.firstIndex(where: { $0.id == correction.original.id }) {
                stations[index] = correction.corrected
            }
        }
        
        print("🛡️ CLEANUP SUMMARY: Corrected \(stationsToCorrect.count) stations, will remove \(stationsToRemove.count) stations")
        
        // Remove corrupted stations from memory and Core Data
        for station in stationsToRemove {
            // Remove from memory
            if let index = stations.firstIndex(where: { $0.id == station.id }) {
                stations.remove(at: index)
            }
            
            // Remove from Core Data
            let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", station.id)
            
            do {
                let managedStations = try context.fetch(fetchRequest)
                if let managedStation = managedStations.first {
                    context.delete(managedStation)
                    corruptedStationsRemoved += 1
                }
            } catch {
                print("❌ Failed to delete corrupted station: \(error)")
            }
        }
        
        // Second pass: Update stations with old country names
        for station in stations {
            if let normalizedName = normalizeAPICountryName(station.country),
               normalizedName != station.country {
                print("🔄 Migrating station '\(station.name)' from '\(station.country)' to '\(normalizedName)'")
                
                // Update in memory
                if let index = stations.firstIndex(where: { $0.id == station.id }) {
                    var updatedStation = stations[index]
                    updatedStation.country = normalizedName
                    stations[index] = updatedStation
                }
                
                // Update in Core Data
                let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", station.id)
                
                do {
                    let managedStations = try context.fetch(fetchRequest)
                    if let managedStation = managedStations.first {
                        managedStation.country = normalizedName
                        migrationCount += 1
                    }
                } catch {
                    print("❌ Failed to fetch station for migration: \(error)")
                }
            }
        }
        
        // Save changes
        if migrationCount > 0 || corruptedStationsRemoved > 0 || countryReassignments > 0 {
            do {
                try context.save()
                print("✅ Database cleanup completed:")
                print("   - Reassigned \(countryReassignments) stations from corrupted Italy assignments")
                print("   - Migrated \(migrationCount) stations to correct country names")
                print("   - Removed \(corruptedStationsRemoved) corrupted stations")
                
                // Update cleanup timestamp to prevent repeated cleanup
                UserDefaults.standard.set(currentTime, forKey: "LastStationCleanupTime")
                
                // Reload stations from Core Data to reflect changes
                loadStationsFromCoreData()
            } catch {
                print("❌ Failed to save database cleanup: \(error)")
            }
        } else {
            print("✅ No stations needed migration or cleanup")
        }
    }
    
    /// Helper function to get country name from ISO country code
    private func getCountryNameFromCode(_ code: String) -> String? {
        let countryMappings: [String: String] = [
            // Skip US and UK as requested
            // "US": "United States",
            // "GB": "United Kingdom", 
            // "UK": "United Kingdom",
            
            // A
            "AD": "Andorra",
            "AE": "United Arab Emirates",
            "AF": "Afghanistan",
            "AG": "Antigua & Barbuda",
            "AI": "Anguilla",
            "AL": "Albania",
            "AM": "Armenia",
            "AO": "Angola",
            "AR": "Argentina",
            "AS": "American Samoa",
            "AT": "Austria",
            "AU": "Australia",
            "AW": "Aruba",
            "AX": "Åland Islands",
            "AZ": "Azerbaijan",
            
            // B
            "BA": "Bosnia & Herzegovina",
            "BB": "Barbados",
            "BD": "Bangladesh",
            "BE": "Belgium",
            "BF": "Burkina Faso",
            "BG": "Bulgaria",
            "BH": "Bahrain",
            "BI": "Burundi",
            "BJ": "Benin",
            "BL": "Saint Barthélemy",
            "BM": "Bermuda",
            "BN": "Brunei",
            "BO": "Bolivia",
            "BR": "Brazil",
            "BS": "Bahamas",
            "BT": "Bhutan",
            "BW": "Botswana",
            "BY": "Belarus",
            "BZ": "Belize",
            
            // C
            "CA": "Canada",
            "CC": "Cocos (Keeling) Islands",
            "CD": "Congo - Kinshasa",
            "CF": "Central African Republic",
            "CG": "Congo - Brazzaville",
            "CH": "Switzerland",
            "CI": "Côte d'Ivoire",
            "CK": "Cook Islands",
            "CL": "Chile",
            "CM": "Cameroon",
            "CN": "China",
            "CO": "Colombia",
            "CR": "Costa Rica",
            "CU": "Cuba",
            "CV": "Cape Verde",
            "CW": "Curaçao",
            "CX": "Christmas Island",
            "CY": "Cyprus",
            "CZ": "Czech Republic",
            
            // D
            "DE": "Germany",
            "DJ": "Djibouti",
            "DK": "Denmark",
            "DM": "Dominica",
            "DO": "Dominican Republic",
            "DZ": "Algeria",
            
            // E
            "EC": "Ecuador",
            "EE": "Estonia",
            "EG": "Egypt",
            "ER": "Eritrea",
            "ES": "Spain",
            "ET": "Ethiopia",
            
            // F
            "FI": "Finland",
            "FJ": "Fiji",
            "FK": "Falkland Islands",
            "FM": "Micronesia",
            "FO": "Faroe Islands",
            "FR": "France",
            
            // G
            "GA": "Gabon",
            "GD": "Grenada",
            "GE": "Georgia",
            "GF": "French Guiana",
            "GG": "Guernsey",
            "GH": "Ghana",
            "GI": "Gibraltar",
            "GL": "Greenland",
            "GM": "Gambia",
            "GN": "Guinea",
            "GP": "Guadeloupe",
            "GQ": "Equatorial Guinea",
            "GR": "Greece",
            "GT": "Guatemala",
            "GU": "Guam",
            "GW": "Guinea-Bissau",
            "GY": "Guyana",
            
            // H
            "HK": "Hong Kong",
            "HN": "Honduras",
            "HR": "Croatia",
            "HT": "Haiti",
            "HU": "Hungary",
            
            // I
            "ID": "Indonesia",
            "IE": "Ireland",
            "IL": "Israel",
            "IM": "Isle of Man",
            "IN": "India",
            "IQ": "Iraq",
            "IR": "Iran",
            "IS": "Iceland",
            "IT": "Italy",
            
            // J
            "JE": "Jersey",
            "JM": "Jamaica",
            "JO": "Jordan",
            "JP": "Japan",
            
            // K
            "KE": "Kenya",
            "KG": "Kyrgyzstan",
            "KH": "Cambodia",
            "KI": "Kiribati",
            "KM": "Comoros",
            "KN": "Saint Kitts & Nevis",
            "KP": "North Korea",
            "KR": "South Korea",
            "KW": "Kuwait",
            "KY": "Cayman Islands",
            "KZ": "Kazakhstan",
            
            // L
            "LA": "Laos",
            "LB": "Lebanon",
            "LC": "Saint Lucia",
            "LI": "Liechtenstein",
            "LK": "Sri Lanka",
            "LR": "Liberia",
            "LS": "Lesotho",
            "LT": "Lithuania",
            "LU": "Luxembourg",
            "LV": "Latvia",
            "LY": "Libya",
            
            // M
            "MA": "Morocco",
            "MC": "Monaco",
            "MD": "Moldova",
            "ME": "Montenegro",
            "MF": "Saint Martin",
            "MG": "Madagascar",
            "MH": "Marshall Islands",
            "MK": "Macedonia",
            "ML": "Mali",
            "MM": "Myanmar",
            "MN": "Mongolia",
            "MO": "Macau",
            "MP": "Northern Mariana Islands",
            "MQ": "Martinique",
            "MR": "Mauritania",
            "MS": "Montserrat",
            "MT": "Malta",
            "MU": "Mauritius",
            "MV": "Maldives",
            "MW": "Malawi",
            "MX": "Mexico",
            "MY": "Malaysia",
            "MZ": "Mozambique",
            
            // N
            "NA": "Namibia",
            "NC": "New Caledonia",
            "NE": "Niger",
            "NF": "Norfolk Island",
            "NG": "Nigeria",
            "NI": "Nicaragua",
            "NL": "Netherlands",
            "NO": "Norway",
            "NP": "Nepal",
            "NR": "Nauru",
            "NU": "Niue",
            "NZ": "New Zealand",
            
            // O
            "OM": "Oman",
            
            // P
            "PA": "Panama",
            "PE": "Peru",
            "PF": "French Polynesia",
            "PG": "Papua New Guinea",
            "PH": "Philippines",
            "PK": "Pakistan",
            "PL": "Poland",
            "PM": "Saint Pierre & Miquelon",
            "PN": "Pitcairn Islands",
            "PR": "Puerto Rico",
            "PS": "Palestinian Territories",
            "PT": "Portugal",
            "PW": "Palau",
            "PY": "Paraguay",
            
            // Q
            "QA": "Qatar",
            
            // R
            "RE": "Réunion",
            "RO": "Romania",
            "RS": "Serbia",
            "RU": "Russia",
            "RW": "Rwanda",
            
            // S
            "SA": "Saudi Arabia",
            "SB": "Solomon Islands",
            "SC": "Seychelles",
            "SD": "Sudan",
            "SE": "Sweden",
            "SG": "Singapore",
            "SH": "Saint Helena",
            "SI": "Slovenia",
            "SK": "Slovakia",
            "SL": "Sierra Leone",
            "SM": "San Marino",
            "SN": "Senegal",
            "SO": "Somalia",
            "SR": "Suriname",
            "SS": "South Sudan",
            "ST": "São Tomé & Príncipe",
            "SV": "El Salvador",
            "SX": "Sint Maarten",
            "SY": "Syria",
            "SZ": "Swaziland",
            
            // T
            "TC": "Turks & Caicos Islands",
            "TD": "Chad",
            "TG": "Togo",
            "TH": "Thailand",
            "TJ": "Tajikistan",
            "TK": "Tokelau",
            "TL": "Timor-Leste",
            "TM": "Turkmenistan",
            "TN": "Tunisia",
            "TO": "Tonga",
            "TR": "Turkey",
            "TT": "Trinidad & Tobago",
            "TV": "Tuvalu",
            "TW": "Taiwan",
            "TZ": "Tanzania",
            
            // U
            "UA": "Ukraine",
            "UG": "Uganda",
            "UY": "Uruguay",
            "UZ": "Uzbekistan",
            
            // V
            "VA": "Vatican City",
            "VC": "Saint Vincent & Grenadines",
            "VE": "Venezuela",
            "VG": "British Virgin Islands",
            "VI": "United States Virgin Islands",
            "VN": "Vietnam",
            "VU": "Vanuatu",
            
            // W
            "WF": "Wallis & Futuna",
            "WS": "Samoa",
            
            // X
            "XK": "Kosovo",
            
            // Y
            "YE": "Yemen",
            "YT": "Mayotte",
            
            // Z
            "ZA": "South Africa",
            "ZM": "Zambia",
            "ZW": "Zimbabwe"
        ]
        
        return countryMappings[code.uppercased()]
    }
    
    /// Helper function to infer country from station name patterns
    private func inferCountryFromStationName(_ name: String) -> String? {
        let nameLower = name.lowercased()
        
        // US patterns - very comprehensive
        if nameLower.contains("usa") || nameLower.contains("america") || nameLower.contains("american") ||
           nameLower.contains("chicago") || nameLower.contains("new york") || nameLower.contains("los angeles") ||
           nameLower.contains("seattle") || nameLower.contains("boston") || nameLower.contains("miami") ||
           nameLower.contains("texas") || nameLower.contains("california") || nameLower.contains("florida") ||
           nameLower.contains("atlanta") || nameLower.contains("denver") || nameLower.contains("phoenix") ||
           nameLower.contains("philadelphia") || nameLower.contains("detroit") || nameLower.contains("houston") ||
           nameLower.contains("dallas") || nameLower.contains("nashville") || nameLower.contains("memphis") ||
           nameLower.contains("washington") || nameLower.contains("oregon") || nameLower.contains("nevada") ||
           nameLower.contains("arizona") || nameLower.contains("utah") || nameLower.contains("colorado") ||
           nameLower.contains("minnesota") || nameLower.contains("wisconsin") || nameLower.contains("ohio") ||
           nameLower.contains("michigan") || nameLower.contains("indiana") || nameLower.contains("illinois") ||
           nameLower.contains("missouri") || nameLower.contains("kansas") || nameLower.contains("oklahoma") ||
           nameLower.contains("arkansas") || nameLower.contains("louisiana") || nameLower.contains("mississippi") ||
           nameLower.contains("alabama") || nameLower.contains("georgia") || nameLower.contains("south carolina") ||
           nameLower.contains("north carolina") || nameLower.contains("virginia") || nameLower.contains("maryland") ||
           nameLower.contains("delaware") || nameLower.contains("new jersey") || nameLower.contains("pennsylvania") ||
           nameLower.contains("connecticut") || nameLower.contains("massachusetts") || nameLower.contains("rhode island") ||
           nameLower.contains("vermont") || nameLower.contains("new hampshire") || nameLower.contains("maine") ||
           nameLower.contains("alaska") || nameLower.contains("hawaii") || nameLower.contains("montana") ||
           nameLower.contains("wyoming") || nameLower.contains("north dakota") || nameLower.contains("south dakota") ||
           nameLower.contains("nebraska") || nameLower.contains("iowa") || nameLower.contains("kentucky") ||
           nameLower.contains("tennessee") || nameLower.contains("west virginia") || nameLower.contains("idaho") ||
           nameLower.contains("new mexico") || nameLower.contains("portland") || nameLower.contains("sacramento") ||
           nameLower.contains("san francisco") || nameLower.contains("san diego") || nameLower.contains("las vegas") ||
           nameLower.contains("milwaukee") || nameLower.contains("cleveland") || nameLower.contains("cincinnati") ||
           nameLower.contains("columbus") || nameLower.contains("pittsburgh") || nameLower.contains("baltimore") ||
           nameLower.contains("buffalo") || nameLower.contains("rochester") || nameLower.contains("syracuse") ||
           nameLower.contains("albany") || nameLower.contains("richmond") || nameLower.contains("norfolk") ||
           nameLower.contains("charlotte") || nameLower.contains("raleigh") || nameLower.contains("charleston") ||
           nameLower.contains("columbia") || nameLower.contains("savannah") || nameLower.contains("jacksonville") ||
           nameLower.contains("tampa") || nameLower.contains("orlando") || nameLower.contains("fort lauderdale") ||
           nameLower.contains("west palm beach") || nameLower.contains("pensacola") || nameLower.contains("tallahassee") ||
           nameLower.contains("gainesville") || nameLower.contains("birmingham") || nameLower.contains("montgomery") ||
           nameLower.contains("mobile") || nameLower.contains("huntsville") || nameLower.contains("jackson") ||
           nameLower.contains("new orleans") || nameLower.contains("baton rouge") || nameLower.contains("shreveport") ||
           nameLower.contains("lafayette") || nameLower.contains("little rock") || nameLower.contains("fayetteville") ||
           nameLower.contains("fort smith") || nameLower.contains("tulsa") || nameLower.contains("oklahoma city") ||
           nameLower.contains("wichita") || nameLower.contains("topeka") || nameLower.contains("kansas city") ||
           nameLower.contains("st. louis") || nameLower.contains("springfield") || nameLower.contains("jefferson city") ||
           nameLower.contains("des moines") || nameLower.contains("cedar rapids") || nameLower.contains("davenport") ||
           nameLower.contains("sioux city") || nameLower.contains("omaha") || nameLower.contains("lincoln") ||
           nameLower.contains("grand island") || nameLower.contains("sioux falls") || nameLower.contains("rapid city") ||
           nameLower.contains("fargo") || nameLower.contains("bismarck") || nameLower.contains("grand forks") ||
           nameLower.contains("minneapolis") || nameLower.contains("st. paul") || nameLower.contains("duluth") ||
           nameLower.contains("rochester") || nameLower.contains("madison") || nameLower.contains("green bay") ||
           nameLower.contains("appleton") || nameLower.contains("eau claire") || nameLower.contains("la crosse") ||
           (nameLower.contains("fm") && (nameLower.contains(" us ") || nameLower.contains("united states"))) {
            return "United States"
        }
        
        // UK patterns - comprehensive
        if nameLower.contains("bbc") || nameLower.contains("london") || nameLower.contains("uk") ||
           nameLower.contains("britain") || nameLower.contains("british") || nameLower.contains("england") || 
           nameLower.contains("scotland") || nameLower.contains("wales") || nameLower.contains("northern ireland") ||
           nameLower.contains("manchester") || nameLower.contains("birmingham") || nameLower.contains("liverpool") ||
           nameLower.contains("leeds") || nameLower.contains("sheffield") || nameLower.contains("bristol") ||
           nameLower.contains("glasgow") || nameLower.contains("edinburgh") || nameLower.contains("cardiff") ||
           nameLower.contains("belfast") || nameLower.contains("newcastle") || nameLower.contains("nottingham") ||
           nameLower.contains("leicester") || nameLower.contains("coventry") || nameLower.contains("hull") ||
           nameLower.contains("bradford") || nameLower.contains("stoke") || nameLower.contains("wolverhampton") ||
           nameLower.contains("plymouth") || nameLower.contains("derby") || nameLower.contains("swansea") ||
           nameLower.contains("southampton") || nameLower.contains("salford") || nameLower.contains("aberdeen") ||
           nameLower.contains("westminster") || nameLower.contains("croydon") || nameLower.contains("harrow") ||
           nameLower.contains("brent") || nameLower.contains("ealing") || nameLower.contains("wandsworth") ||
           nameLower.contains("lambeth") || nameLower.contains("southwark") || nameLower.contains("lewisham") ||
           nameLower.contains("greenwich") || nameLower.contains("hackney") || nameLower.contains("tower hamlets") ||
           nameLower.contains("newham") || nameLower.contains("waltham forest") || nameLower.contains("redbridge") ||
           nameLower.contains("havering") || nameLower.contains("barking") || nameLower.contains("enfield") ||
           nameLower.contains("barnet") || nameLower.contains("haringey") || nameLower.contains("camden") ||
           nameLower.contains("islington") || nameLower.contains("kensington") || nameLower.contains("chelsea") ||
           nameLower.contains("hammersmith") || nameLower.contains("fulham") || nameLower.contains("richmond") ||
           nameLower.contains("kingston") || nameLower.contains("merton") || nameLower.contains("sutton") ||
           nameLower.contains("croydon") || nameLower.contains("bromley") || nameLower.contains("bexley") ||
           nameLower.contains("hillingdon") || nameLower.contains("hounslow") {
            return "United Kingdom"
        }
        
        // German patterns
        if nameLower.contains("deutschland") || nameLower.contains("german") || nameLower.contains("berlin") ||
           nameLower.contains("münchen") || nameLower.contains("munich") || nameLower.contains("hamburg") ||
           nameLower.contains("cologne") || nameLower.contains("köln") || nameLower.contains("frankfurt") ||
           nameLower.contains("stuttgart") || nameLower.contains("düsseldorf") || nameLower.contains("dortmund") ||
           nameLower.contains("essen") || nameLower.contains("leipzig") || nameLower.contains("bremen") ||
           nameLower.contains("dresden") || nameLower.contains("hannover") || nameLower.contains("nürnberg") ||
           nameLower.contains("nuremberg") || nameLower.contains("duisburg") || nameLower.contains("bochum") ||
           nameLower.contains("wuppertal") || nameLower.contains("bielefeld") || nameLower.contains("bonn") ||
           nameLower.contains("münster") || nameLower.contains("karlsruhe") || nameLower.contains("mannheim") ||
           nameLower.contains("augsburg") || nameLower.contains("wiesbaden") || nameLower.contains("gelsenkirchen") ||
           nameLower.contains("mönchengladbach") || nameLower.contains("braunschweig") || nameLower.contains("chemnitz") ||
           nameLower.contains("kiel") || nameLower.contains("aachen") || nameLower.contains("halle") ||
           nameLower.contains("magdeburg") || nameLower.contains("freiburg") || nameLower.contains("krefeld") ||
           nameLower.contains("lübeck") || nameLower.contains("oberhausen") || nameLower.contains("erfurt") ||
           nameLower.contains("mainz") || nameLower.contains("rostock") || nameLower.contains("kassel") ||
           nameLower.contains("hagen") || nameLower.contains("potsdam") || nameLower.contains("saarbrücken") ||
           nameLower.contains("hamm") || nameLower.contains("mülheim") || nameLower.contains("ludwigshafen") ||
           nameLower.contains("leverkusen") || nameLower.contains("oldenburg") || nameLower.contains("osnabrück") ||
           nameLower.contains("solingen") || nameLower.contains("heidelberg") || nameLower.contains("herne") ||
           nameLower.contains("neuss") || nameLower.contains("darmstadt") || nameLower.contains("paderborn") ||
           nameLower.contains("regensburg") || nameLower.contains("ingolstadt") || nameLower.contains("würzburg") ||
           nameLower.contains("fürth") || nameLower.contains("wolfsburg") || nameLower.contains("offenbach") ||
           nameLower.contains("ulm") || nameLower.contains("heilbronn") || nameLower.contains("pforzheim") ||
           nameLower.contains("göttingen") || nameLower.contains("bottrop") || nameLower.contains("trier") ||
           nameLower.contains("recklinghausen") || nameLower.contains("reutlingen") || nameLower.contains("bremerhaven") ||
           nameLower.contains("koblenz") || nameLower.contains("bergisch gladbach") || nameLower.contains("jena") ||
           nameLower.contains("remscheid") || nameLower.contains("erlangen") || nameLower.contains("moers") ||
           nameLower.contains("siegen") || nameLower.contains("hildesheim") || nameLower.contains("salzgitter") {
            return "Germany"
        }
        
        // French patterns
        if nameLower.contains("france") || nameLower.contains("french") || nameLower.contains("français") ||
           nameLower.contains("paris") || nameLower.contains("radio france") || nameLower.contains("marseille") ||
           nameLower.contains("lyon") || nameLower.contains("toulouse") || nameLower.contains("nice") ||
           nameLower.contains("nantes") || nameLower.contains("strasbourg") || nameLower.contains("montpellier") ||
           nameLower.contains("bordeaux") || nameLower.contains("lille") || nameLower.contains("rennes") ||
           nameLower.contains("reims") || nameLower.contains("le havre") || nameLower.contains("saint-étienne") ||
           nameLower.contains("toulon") || nameLower.contains("angers") || nameLower.contains("grenoble") ||
           nameLower.contains("dijon") || nameLower.contains("nîmes") || nameLower.contains("aix-en-provence") ||
           nameLower.contains("brest") || nameLower.contains("le mans") || nameLower.contains("amiens") ||
           nameLower.contains("tours") || nameLower.contains("limoges") || nameLower.contains("clermont-ferrand") ||
           nameLower.contains("villeurbanne") || nameLower.contains("besançon") || nameLower.contains("orléans") ||
           nameLower.contains("metz") || nameLower.contains("rouen") || nameLower.contains("mulhouse") ||
           nameLower.contains("perpignan") || nameLower.contains("caen") || nameLower.contains("boulogne-billancourt") ||
           nameLower.contains("nancy") || nameLower.contains("argenteuil") || nameLower.contains("roubaix") ||
           nameLower.contains("tourcoing") || nameLower.contains("nanterre") || nameLower.contains("avignon") ||
           nameLower.contains("créteil") || nameLower.contains("dunkerque") || nameLower.contains("poitiers") ||
           nameLower.contains("asnières-sur-seine") || nameLower.contains("courbevoie") || nameLower.contains("versailles") ||
           nameLower.contains("colombes") || nameLower.contains("fort-de-france") || nameLower.contains("aulnay-sous-bois") ||
           nameLower.contains("saint-paul") || nameLower.contains("rueil-malmaison") || nameLower.contains("pau") ||
           nameLower.contains("aubervilliers") || nameLower.contains("champigny-sur-marne") || nameLower.contains("antibes") ||
           nameLower.contains("saint-maur-des-fossés") || nameLower.contains("cannes") || nameLower.contains("béziers") ||
           nameLower.contains("bourges") || nameLower.contains("calais") || nameLower.contains("saint-nazaire") ||
           nameLower.contains("colmar") || nameLower.contains("drancy") || nameLower.contains("ajaccio") ||
           nameLower.contains("mérignac") || nameLower.contains("saint-louis") || nameLower.contains("nouméa") {
            return "France"
        }
        
        // Italian patterns (legitimate ones) - comprehensive
        if nameLower.contains("rai") || nameLower.contains("italia") || nameLower.contains("italian") ||
           nameLower.contains("rome") || nameLower.contains("roma") || nameLower.contains("milano") || 
           nameLower.contains("milan") || nameLower.contains("napoli") || nameLower.contains("naples") ||
           nameLower.contains("torino") || nameLower.contains("turin") || nameLower.contains("palermo") ||
           nameLower.contains("genova") || nameLower.contains("genoa") || nameLower.contains("bologna") ||
           nameLower.contains("firenze") || nameLower.contains("florence") || nameLower.contains("bari") ||
           nameLower.contains("catania") || nameLower.contains("venezia") || nameLower.contains("venice") ||
           nameLower.contains("verona") || nameLower.contains("messina") || nameLower.contains("padova") ||
           nameLower.contains("padua") || nameLower.contains("trieste") || nameLower.contains("taranto") ||
           nameLower.contains("brescia") || nameLower.contains("prato") || nameLower.contains("parma") ||
           nameLower.contains("modena") || nameLower.contains("reggio calabria") || nameLower.contains("reggio emilia") ||
           nameLower.contains("perugia") || nameLower.contains("livorno") || nameLower.contains("ravenna") ||
           nameLower.contains("cagliari") || nameLower.contains("foggia") || nameLower.contains("rimini") ||
           nameLower.contains("salerno") || nameLower.contains("ferrara") || nameLower.contains("sassari") ||
           nameLower.contains("latina") || nameLower.contains("giugliano") || nameLower.contains("monza") ||
           nameLower.contains("siracusa") || nameLower.contains("pescara") || nameLower.contains("bergamo") ||
           nameLower.contains("forlì") || nameLower.contains("trento") || nameLower.contains("vicenza") ||
           nameLower.contains("terni") || nameLower.contains("bolzano") || nameLower.contains("novara") ||
           nameLower.contains("piacenza") || nameLower.contains("ancona") || nameLower.contains("andria") ||
           nameLower.contains("arezzo") || nameLower.contains("udine") || nameLower.contains("cesena") ||
           nameLower.contains("lecce") || nameLower.contains("pesaro") || nameLower.contains("barletta") ||
           nameLower.contains("alessandria") || nameLower.contains("la spezia") || nameLower.contains("pistoia") ||
           nameLower.contains("como") || nameLower.contains("pavia") || nameLower.contains("treviso") ||
           nameLower.contains("busto arsizio") || nameLower.contains("varese") || nameLower.contains("fiumicino") ||
           nameLower.contains("lamezia terme") || nameLower.contains("cosenza") || nameLower.contains("brindisi") ||
           nameLower.contains("gallarate") || nameLower.contains("cinisello balsamo") || nameLower.contains("sesto san giovanni") ||
           nameLower.contains("casoria") || nameLower.contains("castellammare") || nameLower.contains("carpi") ||
           nameLower.contains("guidonia montecelio") || nameLower.contains("cerignola") || nameLower.contains("viterbo") ||
           nameLower.contains("tivoli") || nameLower.contains("caserta") || nameLower.contains("lecco") ||
           nameLower.contains("vercelli") || nameLower.contains("quartu sant'elena") || nameLower.contains("altamura") ||
           nameLower.contains("imola") || nameLower.contains("cremona") || nameLower.contains("vigevano") ||
           nameLower.contains("caltanissetta") || nameLower.contains("asti") || nameLower.contains("matera") ||
           nameLower.contains("massa") || nameLower.contains("avellino") || nameLower.contains("benevento") ||
           nameLower.contains("afragola") || nameLower.contains("carrara") || nameLower.contains("potenza") {
            return "Italy"
        }
        
        return nil
    }
    
    // MARK: - Deleted Stations Management
    
    /// Add a station ID to the deleted stations list to prevent re-fetching
    private func addToDeletedStations(_ stationId: String) {
        var deleted = deletedStationIds
        deleted.insert(stationId)
        deletedStationIds = deleted
        print("📝 Added station to deleted list: \(stationId)")
    }
    
    /// Remove a station ID from the deleted stations list (if user manually adds it back)
    func removeFromDeletedStations(_ stationId: String) {
        var deleted = deletedStationIds
        deleted.remove(stationId)
        deletedStationIds = deleted
        print("📝 Removed station from deleted list: \(stationId)")
    }
    
    /// Remove multiple station IDs from the deleted stations list (for country deletion)
    private func removeMultipleFromDeletedStations(_ stationIds: [String]) {
        var deleted = deletedStationIds
        let beforeCount = deleted.count
        
        print("📝 🔍 DEBUG: Removing \(stationIds.count) stations from deleted list")
        for stationId in stationIds {
            let wasRemoved = deleted.remove(stationId) != nil
            print("📝 🔍 Removing \(stationId): \(wasRemoved ? "✅ Success" : "❌ Not found")")
        }
        
        deletedStationIds = deleted
        let afterCount = deleted.count
        print("📝 Removed \(beforeCount - afterCount) stations from deleted list (was \(beforeCount), now \(afterCount))")
    }
    
    /// Clear all deleted station IDs (for troubleshooting or data reset)
    func clearDeletedStationsList() {
        deletedStationIds = Set()
        print("📝 Cleared all deleted stations list")
    }
    
    /// Check if a station was manually deleted
    private func isStationDeleted(_ stationId: String) -> Bool {
        return deletedStationIds.contains(stationId)
    }
    
    /// Log current deleted stations count for debugging
    private func logDeletedStationsCount() {
        let count = deletedStationIds.count
        if count > 0 {
            print("📝 Currently tracking \(count) manually deleted stations to prevent re-fetching")
        }
    }
    
    /// Reset first load flags for all countries (useful for testing or fresh start)
    func resetFirstLoadFlags() {
        let userDefaults = UserDefaults.standard
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        for key in allKeys {
            if key.hasPrefix("APIStationsFirstLoad_") {
                userDefaults.removeObject(forKey: key)
                let countryName = String(key.dropFirst("APIStationsFirstLoad_".count))
                print("📡 🔄 RESET: Cleared first load flag for \(countryName)")
            }
        }
        
        userDefaults.synchronize()
        print("📡 ✅ RESET COMPLETE: All first load flags cleared")
    }
    
    /// Show notification about station fetch results with accurate count
    @MainActor
    private func showStationFetchNotification(
        country: Country,
        actualNewStations: Int,
        duplicatesSkippedFromAPI: Int,
        duplicatesSkipped: Int,
        deletedStationsFiltered: Int
    ) {
        var notificationMessage: String
        if actualNewStations > 0 {
            notificationMessage = "Found \(actualNewStations) new stations for \(country.name)."
        } else {
            notificationMessage = "No new stations found for \(country.name). All stations are up to date."
        }
        
        var skipDetails: [String] = []
        if duplicatesSkippedFromAPI > 0 {
            skipDetails.append("\(duplicatesSkippedFromAPI) duplicate URLs")
        }
        if duplicatesSkipped > 0 {
            skipDetails.append("\(duplicatesSkipped) existing stations")
        }
        if deletedStationsFiltered > 0 {
            skipDetails.append("\(deletedStationsFiltered) previously deleted")
        }
        
        if !skipDetails.isEmpty && actualNewStations > 0 {
            notificationMessage += " Skipped \(skipDetails.joined(separator: ", ")) stations."
        }
        
        NotificationManager.shared.notifyUserImmediate(
            title: actualNewStations > 0 ? "New Stations Found" : "Stations Updated",
            message: notificationMessage
        )
        
        print("📱 NOTIFICATION: \(actualNewStations > 0 ? "New Stations Found" : "Stations Updated") - \(notificationMessage)")
    }
    
    // MARK: - Background Favicon Download
    
    @MainActor
    private func downloadFaviconsInBackground(for stations: [RadioStation], apiStations: [RadioBrowserStation]) async {
        guard !stations.isEmpty else {
            print("🖼️ All stations already have cached favicons - skipping download")
            return
        }
        
        print("🖼️ Downloading favicons for \(stations.count) stations (others already cached)")
        
        // Handle duplicates when creating station-to-API mapping
        var stationAPIMap: [String: RadioBrowserStation] = [:]
        for (station, apiStation) in zip(stations, apiStations) {
            if stationAPIMap[station.id] != nil {
                print("🔄 Duplicate station ID '\(station.id)' found in favicon download - keeping first occurrence")
            } else {
                stationAPIMap[station.id] = apiStation
            }
        }
        
        // Create URLSession with timeout for favicon downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.0 // 3 second timeout
        config.timeoutIntervalForResource = 5.0 // 5 second total timeout
        let timeoutSession = URLSession(configuration: config)
        
        // Download favicons with limited concurrency to avoid overwhelming the network
        await withTaskGroup(of: (String, String?).self) { group in
            var downloadCount = 0
            
            for station in stations {
                // Limit concurrent downloads to avoid overwhelming network
                guard downloadCount < 5 else { break }
                
                if let apiStation = stationAPIMap[station.id],
                   let faviconURL = apiStation.favicon,
                   !faviconURL.isEmpty,
                   let url = URL(string: faviconURL) {
                    
                    downloadCount += 1
                    group.addTask {
                        do {
                            let (data, _) = try await timeoutSession.data(from: url)
                            if let image = UIImage(data: data),
                               let jpegData = image.jpegData(compressionQuality: 0.6) {
                                return (station.id, jpegData.base64EncodedString())
                            }
                        } catch {
                            // Silently fail - station will just not have an icon
                        }
                        return (station.id, nil)
                    }
                }
            }
            
            // Update stations with downloaded favicons as they complete
            for await (stationId, iconData) in group {
                if let iconData = iconData,
                   let index = self.stations.firstIndex(where: { $0.id == stationId }) {
                    self.stations[index].iconData = iconData
                    print("✅ Favicon downloaded and cached for station: \(self.stations[index].name)")
                    
                    // Save to Core Data in background for persistent caching with weak self
                    Task.detached { [weak self] in
                        await self?.updateStationIconInCoreData(stationId: stationId, iconData: iconData)
                    }
                }
            }
        }
        
        // Clean up the session
        timeoutSession.invalidateAndCancel()
    }
    
    private func updateStationIconInCoreData(stationId: String, iconData: String) async {
        // Check if this station is already being processed to prevent duplicate updates
        let shouldProcess = await withCheckedContinuation { continuation in
            processingQueue.async {
                guard !self.stationsBeingProcessed.contains(stationId) else {
                    print("📷 Station \(stationId) is already being processed for favicon update - skipping")
                    continuation.resume(returning: false)
                    return
                }
                self.stationsBeingProcessed.insert(stationId)
                continuation.resume(returning: true)
            }
        }
        
        guard shouldProcess else { return }
        
        // Ensure we clean up the processing state when done
        defer {
            processingQueue.async {
                self.stationsBeingProcessed.remove(stationId)
            }
        }
        
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        
        // Set merge policy to handle conflicts automatically
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        
        await context.perform {
            let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", stationId)
            fetchRequest.returnsObjectsAsFaults = false // Ensure we get the full object
            
            do {
                if let station = try context.fetch(fetchRequest).first {
                    // Check if the station already has icon data to avoid unnecessary updates
                    if station.iconData == nil || station.iconData?.isEmpty == true {
                        station.iconData = iconData
                        
                        // Only save if there are actual changes
                        if context.hasChanges {
                            try context.save()
                            print("💾 Favicon cached to Core Data for station: \(station.name ?? "Unknown")")
                        } else {
                            print("📷 Station \(station.name ?? "Unknown") already has favicon data - skipping update")
                        }
                    } else {
                        print("📷 Station \(station.name ?? "Unknown") already has favicon data - skipping update")
                    }
                } else {
                    print("⚠️ Station not found in Core Data for favicon caching: \(stationId)")
                }
            } catch let error as NSError {
                if error.code == 133020 { // NSMergeConflictError
                    print("🔄 Merge conflict detected for favicon update - attempting retry with refresh")
                    // Refresh the context and try once more
                    context.refreshAllObjects()
                    do {
                        if context.hasChanges {
                            try context.save()
                            print("✅ Successfully saved favicon after merge conflict resolution")
                        }
                    } catch {
                        print("❌ Failed to save favicon even after merge conflict resolution: \(error)")
                    }
                } else {
                    print("❌ Failed to cache favicon to Core Data: \(error)")
                }
            }
        }
    }
}

extension RadioStationViewModel {
    func saveStationsToCoreData() {
        // Use a background context to avoid blocking main thread and reduce merge conflicts
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()
        
        backgroundContext.perform {
            // Configure merge policy to handle conflicts automatically
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            
            // Fetch existing stations in background context
            let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            
            do {
                let existingStations = try backgroundContext.fetch(fetchRequest)
            
            // Detect and clean up duplicates before creating dictionary
            var stationsByID: [String: CDStation] = [:]
            var duplicatesToDelete: [CDStation] = []
            
            for station in existingStations {
                guard let stationId = station.id else {
                    print("⚠️ Found station with nil ID, deleting it")
                    duplicatesToDelete.append(station)
                    continue
                }
                
                if let existingStation = stationsByID[stationId] {
                    // Found duplicate - keep the one with more recent data or better metadata
                    let keepExisting = self.shouldKeepExistingStation(existing: existingStation, duplicate: station)
                    if keepExisting {
                        duplicatesToDelete.append(station)
                        print("🔄 Duplicate station ID '\(stationId)' found - keeping existing, deleting duplicate")
                    } else {
                        duplicatesToDelete.append(existingStation)
                        stationsByID[stationId] = station
                        print("🔄 Duplicate station ID '\(stationId)' found - keeping newer, deleting old")
                    }
                } else {
                    stationsByID[stationId] = station
                }
            }
            
                // Delete duplicates first
                for duplicate in duplicatesToDelete {
                    backgroundContext.delete(duplicate)
                print("🗑️ Deleted duplicate/invalid station: \(duplicate.name ?? "Unknown")")
            }
            
                // Save deletion changes before proceeding
                if !duplicatesToDelete.isEmpty {
                    try backgroundContext.save()
                    print("✅ Cleaned up \(duplicatesToDelete.count) duplicate/invalid stations")
                }
            
            let existingDict = stationsByID
            
                for (index, station) in self.stations.enumerated() {
                if let existingStation = existingDict[station.id] {
                    // Update existing station
                    existingStation.name = station.name
                    existingStation.url = station.url
                    existingStation.iconData = station.iconData
                    existingStation.country = station.country
                    existingStation.isFavorite = station.isFavorite
                    existingStation.favoritedAt = station.favoritedAt
                    if let favoriteOrder = station.favoriteOrder {
                        existingStation.favoriteOrder = Int32(favoriteOrder)
                    } else {
                        existingStation.favoriteOrder = -1  // Use -1 to represent nil
                    }
                    existingStation.order = Int16(station.order)
                    existingStation.lastPlayed = station.lastPlayed
                } else {
                    // Create new station if it doesn't exist
                    let newStation = CDStation(context: backgroundContext)
                    newStation.id = station.id
                    newStation.name = station.name
                    newStation.url = station.url
                    newStation.iconData = station.iconData
                    newStation.country = station.country
                    newStation.isFavorite = station.isFavorite
                    newStation.favoritedAt = station.favoritedAt
                    if let favoriteOrder = station.favoriteOrder {
                        newStation.favoriteOrder = Int32(favoriteOrder)
                    } else {
                        newStation.favoriteOrder = -1  // Use -1 to represent nil
                    }
                    newStation.order = Int16(station.order)
                    newStation.lastPlayed = station.lastPlayed
                }
            }
            
                // Remove stations that are no longer in the array
                let stationIDs = Set(self.stations.map { $0.id })
                for existingStation in existingStations {
                    // Skip stations with nil IDs (they should have been cleaned up in duplicate detection above)
                    guard let existingStationId = existingStation.id else {
                        print("⚠️ Found existing station with nil ID during cleanup, deleting it: \(existingStation.name ?? "Unknown")")
                        backgroundContext.delete(existingStation)
                        continue
                    }
                    
                    if !stationIDs.contains(existingStationId) {
                        print("🗑️ Removing station no longer in current set: \(existingStation.name ?? "Unknown")")
                        backgroundContext.delete(existingStation)
                    }
                }
                
                // Save changes in background context (independent context auto-merges with main context)
                let hasChanges = backgroundContext.hasChanges
                try backgroundContext.save()
                // No need to manually save parent - independent context automatically merges changes
                
                // Only log if there were actual changes
                if hasChanges {
                    DispatchQueue.main.async {
                        print("✅ CoreData stations updated successfully.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Failed to update stations in CoreData: \(error)")
                    if let nsError = error as NSError? {
                        print("❌ Error details: \(nsError.localizedDescription)")
                        print("❌ Error userInfo: \(nsError.userInfo)")
                    }
                }
            }
        }
    }
    
    // Helper method to decide which duplicate station to keep
    private func shouldKeepExistingStation(existing: CDStation, duplicate: CDStation) -> Bool {
        // Prefer station with more complete data
        let existingScore = stationDataScore(existing)
        let duplicateScore = stationDataScore(duplicate)
        
        if existingScore != duplicateScore {
            return existingScore > duplicateScore
        }
        
        // If scores are equal, prefer the one with more recent lastPlayed
        if let existingLastPlayed = existing.lastPlayed,
           let duplicateLastPlayed = duplicate.lastPlayed {
            return existingLastPlayed > duplicateLastPlayed
        }
        
        // If one has lastPlayed and other doesn't, prefer the one with lastPlayed
        if existing.lastPlayed != nil && duplicate.lastPlayed == nil {
            return true
        }
        if existing.lastPlayed == nil && duplicate.lastPlayed != nil {
            return false
        }
        
        // Default to keeping existing
        return true
    }
    
    // Score station based on data completeness
    private func stationDataScore(_ station: CDStation) -> Int {
        var score = 0
        
        if station.name?.isEmpty == false { score += 1 }
        if station.url?.isEmpty == false { score += 1 }
        if station.iconData != nil { score += 2 }
        if station.country?.isEmpty == false { score += 1 }
        if station.isFavorite { score += 1 }
        if station.lastPlayed != nil { score += 1 }
        
        return score
    }
    
    func loadStationsFromCoreData() {
        // Set loading state to prevent UI delays
        isLoading = true
        
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        
        // Add a sort descriptor to ensure stations are loaded in the correct order
        let sortDescriptor = NSSortDescriptor(key: "order", ascending: true)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            let results = try context.fetch(request)
            if results.isEmpty {
                print("No stations found in CoreData.")
                stations.removeAll()
                print("📡 ✅ Cleared all in-memory station data due to empty Core Data")
                isLoading = false
                return
            }
            
            // Map Core Data objects to app models
            stations = results.map { cdStation in
                RadioStation(
                    id: cdStation.id ?? UUID().uuidString,
                    name: cdStation.name ?? "Unknown",
                    url: cdStation.url ?? "http://default.url",
                    iconData: cdStation.iconData,
                    country: cdStation.country ?? "Unknown",
                    isFavorite: cdStation.isFavorite,
                    favoritedAt: cdStation.favoritedAt,
                    favoriteOrder: cdStation.favoriteOrder >= 0 ? Int(cdStation.favoriteOrder) : nil,
                    order: Int(cdStation.order),
                    lastPlayed: cdStation.lastPlayed
                )
            }
            print("⚡ Instantly loaded \(stations.count) stations from CoreData.")
            
            // Set loading to false immediately to show stations
            isLoading = false
            
            // PERFORMANCE: Create station snapshots for all countries after loading
            Task {
                await createStationSnapshotsForAllCountries()
            }
            
            // Force UI update to ensure immediate refresh
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
            
            // Post notification that stations have been loaded
            NotificationCenter.default.post(name: NSNotification.Name("StationsLoaded"), object: nil)
            
            // Defer maintenance operations to avoid blocking initial station display
            DispatchQueue.main.async { [weak self] in
                self?.performDeferredMaintenance()
            }
            
        } catch {
            print("Failed to load stations from CoreData: \(error)")
            isLoading = false
        }
    }
    
    /// Perform maintenance operations asynchronously to avoid blocking initial station display
    private func performDeferredMaintenance() {
        // Initialize proper order values for stations that might not have them
        initializeOrderValues()
        
        // Migration: Set favoritedAt for existing favorites that don't have a timestamp
        migrateFavoriteTimestamps()
    }
    
    private func initializeOrderValues() {
        // Group stations by country and ensure proper order values
        let groupedStations = Dictionary(grouping: stations) { $0.country }
        var hasChanges = false
        
        for (country, countryStations) in groupedStations {
            // Sort stations for this country (maintain existing order if available)
            let sortedStations = countryStations.sorted { station1, station2 in
                if station1.order != station2.order {
                    return station1.order < station2.order
                }
                return station1.name < station2.name // fallback to alphabetical
            }
            
            // Check if order values need to be fixed
            var needsReordering = false
            for (index, station) in sortedStations.enumerated() {
                if station.order != index {
                    needsReordering = true
                    break
                }
            }
            
            if needsReordering {
                // Update order values
                for (index, station) in sortedStations.enumerated() {
                    if let stationIndex = stations.firstIndex(where: { $0.id == station.id }) {
                        stations[stationIndex].order = index
                        hasChanges = true
                    }
                }
            }
        }
        
        // Save changes if any were made
        if hasChanges {
            print("Initialized order values for stations")
            saveStationsToCoreData()
        }
    }
    
    /// Delete all stations for a specific country from both CloudKit and Core Data with enhanced batch processing
    @MainActor
    func deleteStationsForCountry(_ countryName: String, progressViewModel: CountryDeletionProgressViewModel? = nil) async {
        print("🌍🗑️ Starting deletion of all stations for country: \(countryName)")
        
        // Get all currently loaded stations for this country
        let countryStations = stations.filter { $0.country == countryName }
        
        // CRITICAL FIX: Also get all manual stations for this country (including those not currently loaded)
        let allManualStationsForCountry = ManualStationManager.shared.getManualStations(for: countryName)
        
        // Combine loaded stations with all manual stations to ensure comprehensive deletion
        var allStationsToDelete = countryStations
        
        // Add any manual stations that aren't already in the loaded stations
        for manualStation in allManualStationsForCountry {
            if !allStationsToDelete.contains(where: { $0.id == manualStation.id }) {
                allStationsToDelete.append(manualStation)
            }
        }
        
        guard !allStationsToDelete.isEmpty else {
            print("🌍🗑️ No stations found for country: \(countryName)")
            NotificationManager.shared.notifyUserImmediate(title: "No Stations", message: "No stations found for \(countryName)")
            return
        }
        
        let stationCount = allStationsToDelete.count
        let stationIds = allStationsToDelete.map { $0.id }
        
        // Count manual stations for logging
        let manualStationIds = stationIds.filter { $0.hasPrefix("manual_") }
        
        print("🌍🗑️ Found \(stationCount) stations to delete for \(countryName) (including \(manualStationIds.count) manual stations)")
        
        // CRITICAL FIX: First sync manual stations to CloudKit so they can be deleted
        if !manualStationIds.isEmpty {
            progressViewModel?.updateProgress(0.05, step: "Syncing \(manualStationIds.count) manual stations to CloudKit...")
            print("🌍🗑️ ☁️ Syncing \(manualStationIds.count) manual stations to CloudKit before deletion...")
            
            let manualStationsToSync = allStationsToDelete.filter { $0.id.hasPrefix("manual_") }
            
            // Batch sync manual stations to CloudKit first
            do {
                try await RadioStationCloudKitManager.shared.saveRadioStationsBatchToCloudKit(
                    manualStationsToSync,
                    country: countryName,
                    progressCallback: { progress, count, message in
                        print("🌍🗑️ ☁️ Batch sync progress: \(Int(progress * 100))% - \(message)")
                    }
                )
                print("🌍🗑️ ☁️ ✅ Completed batch syncing \(manualStationsToSync.count) manual stations to CloudKit")
            } catch {
                print("🌍🗑️ ☁️ ❌ Failed to batch sync manual stations to CloudKit: \(error)")
            }
            
            print("🌍🗑️ ☁️ Completed syncing manual stations to CloudKit")
        }
        
        // IMPORTANT: For country-level deletion, we DON'T mark manual stations as permanently deleted
        // This allows users to get manual stations back if they want them after country deletion
        // Manual station protection only applies to individual station deletion
        
        print("🌍🗑️ Prepared \(stationCount) stations for deletion")
        
        progressViewModel?.updateProgress(0.1, step: "Preparing deletion of \(stationCount) stations...")
        
        var success = false
        var error: Error?
        
        do {
            // Remove stations from in-memory array immediately for UI responsiveness
            stations.removeAll { $0.country == countryName }
            
            progressViewModel?.updateProgress(0.2, step: "Removing stations from local memory...")
            
            // Delete from Core Data using optimized batches (100)
            progressViewModel?.updateProgress(0.3, step: "Starting Core Data deletion...")
            try await deleteCountryStationsFromCoreDataWithProgress(countryName: countryName, progressViewModel: progressViewModel)
            
            // Delete from CloudKit using optimized batches (200)
            progressViewModel?.updateProgress(0.6, step: "Starting CloudKit deletion...")
            try await deleteStationsFromCloudKitWithProgress(stationIds: stationIds, progressViewModel: progressViewModel)
            
            // Check if there are no more stations left and reset country if needed
            if stations.isEmpty {
                deleteLocalFile()
                print("🌍 RESET: No stations remaining after country deletion, resetting to 'Select Country'")
                selectedCountry = "Select Country"
            }
            
            success = true
            
            // CRITICAL FIX: Clear protection AFTER successful deletion so stations can be re-added
            removeMultipleFromDeletedStations(stationIds)
            print("🌍🗑️ ✅ Cleared protection for \(stationCount) stations - they can now be re-added")
            
            progressViewModel?.updateProgress(1.0, step: "Deletion completed successfully!")
            progressViewModel?.markCompleted()
            print("🌍✅ Successfully deleted all \(stationCount) stations for \(countryName)")
        } catch let deletionError {
            error = deletionError
            progressViewModel?.updateProgress(0.0, step: "Deletion failed: \(deletionError.localizedDescription)")
            print("🌍❌ Failed to delete stations for \(countryName): \(deletionError)")
        }
        
        // Notify user of completion (only if no progress view is shown)
        if progressViewModel == nil {
            if success {
                NotificationManager.shared.notifyUserImmediate(
                    title: "Deletion Complete", 
                    message: "Successfully deleted all \(stationCount) stations from \(countryName)"
                )
            } else {
                NotificationManager.shared.notifyUserImmediate(
                    title: "Deletion Failed", 
                    message: "Failed to delete stations from \(countryName): \(error?.localizedDescription ?? "Unknown error")"
                )
            }
        }
    }
    
    /// Delete all stations for a specific country from Core Data using small batches with progress tracking
    private func deleteCountryStationsFromCoreDataWithProgress(countryName: String, progressViewModel: CountryDeletionProgressViewModel?) async throws {
        let batchSize = 100 // Small batch size for progress tracking
        
        return try await withCheckedThrowingContinuation { continuation in
            let privateMOC = CoreDataStack.shared.persistentContainer.newBackgroundContext()
            privateMOC.perform {
                do {
                    // First, count total stations to delete
                    let countFetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                    countFetchRequest.predicate = NSPredicate(format: "country == %@", countryName)
                    let totalStations = try privateMOC.count(for: countFetchRequest)
                    
                    var deletedCount = 0
                    
                    while deletedCount < totalStations {
                        // Check for cancellation
                        if Task.isCancelled {
                            print("🌍🗑️ Core Data deletion cancelled")
                            continuation.resume()
                            return
                        }
                        
                        // Fetch a batch of stations to delete
                        let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "country == %@", countryName)
                        fetchRequest.fetchLimit = batchSize
                        
                        let stationsToDelete = try privateMOC.fetch(fetchRequest)
                        
                        if stationsToDelete.isEmpty {
                            break // No more stations to delete
                        }
                        
                        // Delete the batch
                        for station in stationsToDelete {
                            privateMOC.delete(station)
                        }
                        
                        // Save the batch
                        try privateMOC.save()
                        
                        deletedCount += stationsToDelete.count
                        let progress = Double(deletedCount) / Double(totalStations)
                        
                        // Update progress (Core Data is 30% to 60% of total progress)
                        let coreDataProgress = 0.3 + (progress * 0.3)
                        progressViewModel?.updateProgress(coreDataProgress, step: "Core Data: Deleted \(deletedCount)/\(totalStations) stations")
                        
                        print("🌍🗑️ Core Data: Deleted batch of \(stationsToDelete.count) stations (\(deletedCount)/\(totalStations))")
                        
                        // Small delay to prevent overwhelming the system
                        Thread.sleep(forTimeInterval: 0.01) // 10ms
                    }
                    
                    // Final merge into view context
                    try privateMOC.save()
                    DispatchQueue.main.async {
                        CoreDataStack.shared.persistentContainer.viewContext.refreshAllObjects()
                    }
                    
                    print("🌍✅ Core Data: Completed deletion of \(deletedCount) stations from \(countryName)")
                    continuation.resume()
                } catch {
                    print("🌍❌ Failed to delete stations for \(countryName) from Core Data: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Delete stations from CloudKit using small batches with progress tracking
    private func deleteStationsFromCloudKitWithProgress(stationIds: [String], progressViewModel: CountryDeletionProgressViewModel?) async throws {
        let batchSize = 200 // CloudKit batch size
        let totalStations = stationIds.count
        var processedCount = 0
        
        // Process in batches
        for i in stride(from: 0, to: totalStations, by: batchSize) {
            // Check for cancellation
            if Task.isCancelled {
                print("🌍🗑️ CloudKit deletion cancelled")
                return
            }
            
            let endIndex = min(i + batchSize, totalStations)
            let batch = Array(stationIds[i..<endIndex])
            
            // Update progress
            let batchNumber = (i / batchSize) + 1
            let totalBatches = (totalStations + batchSize - 1) / batchSize
            
            // Update progress (CloudKit is 60% to 100% of total progress)
            let preDeleteProgress = 0.6 + (Double(processedCount) / Double(totalStations) * 0.4)
            progressViewModel?.updateProgress(preDeleteProgress, step: "iCloud: Processing batch \(batchNumber)/\(totalBatches)")
            
            // Delete the batch from CloudKit
            try await RadioStationCloudKitManager.shared.deleteRadioStationsBatchFromCloudKit(batch)
            
            processedCount += batch.count
            let overallProgress = Double(processedCount) / Double(totalStations)
            
            // Update progress after deletion
            let postDeleteProgress = 0.6 + (overallProgress * 0.4)
            progressViewModel?.updateProgress(postDeleteProgress, step: "CloudKit: Deleted \(processedCount)/\(totalStations) stations")
            
            print("🌍🗑️ CloudKit: Deleted batch \(batchNumber)/\(totalBatches) (\(processedCount)/\(totalStations) stations)")
            
            // Small delay between batches to be respectful to CloudKit
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        print("🌍✅ CloudKit: Completed deletion of \(processedCount) stations")
    }
    
    /// Legacy method for backward compatibility
    private func deleteCountryStationsFromCoreData(countryName: String) async throws {
        try await deleteCountryStationsFromCoreDataWithProgress(countryName: countryName, progressViewModel: nil)
    }
    
    // MARK: - Radio Station Snapshot Management
    
    /// Get radio station snapshot for a specific country
    func getStationSnapshot(for country: String) -> [RadioStation]? {
        return stationSnapshotCache[country]
    }
    
    /// Update or create radio station snapshot for a country
    func updateStationSnapshot(for country: String, stations: [RadioStation]) {
        // PERFORMANCE: Skip snapshot creation if we already have a recent one
        if let existingTimestamp = snapshotTimestamps[country],
           Date().timeIntervalSince(existingTimestamp) < 5.0 { // 5 second threshold
            return
        }
        
        // PERFORMANCE: Run expensive operations on background queue
        Task.detached(priority: .utility) {
            // CLEANUP: Periodically clean up old snapshots to prevent memory buildup
            if await self.stationSnapshotCache.count > 20 {
                await self.cleanupOldStationSnapshots()
            }
            
            // CRITICAL SAFETY CHECK: Ensure all stations actually belong to this country before caching
            let safeStations = stations.filter { $0.country == country }
            if safeStations.count != stations.count {
                print("🚨 STATION SNAPSHOT ISOLATION: Filtered out \(stations.count - safeStations.count) stations that didn't belong to country \(country)")
            }
            
            // PERFORMANCE OPTIMIZATION: Use efficient sorting algorithm
            let sortedStations = safeStations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            // Update cache on main actor
            await MainActor.run {
                self.stationSnapshotCache[country] = sortedStations
                self.snapshotTimestamps[country] = Date()
                print("📸 STATION SNAPSHOT: Cached \(sortedStations.count) stations for country \(country)")
            }
            
            // Update DataSyncManager snapshot readiness tracking
            await self.updateStationSnapshotReadiness()
        }
    }
    
    /// Clean up old station snapshots to prevent memory buildup
    private func cleanupOldStationSnapshots() async {
        await MainActor.run {
            let now = Date()
            let maxAge: TimeInterval = 600 // 10 minutes
            
            var snapshotsToRemove: [String] = []
            
            for (country, timestamp) in snapshotTimestamps {
                if now.timeIntervalSince(timestamp) > maxAge {
                    snapshotsToRemove.append(country)
                }
            }
            
            for country in snapshotsToRemove {
                stationSnapshotCache.removeValue(forKey: country)
                snapshotTimestamps.removeValue(forKey: country)
            }
            
            if !snapshotsToRemove.isEmpty {
                print("🗑️ STATION CLEANUP: Removed \(snapshotsToRemove.count) old station snapshots")
            }
        }
    }
    
    /// Clear all existing station snapshots
    func clearAllStationSnapshots() {
        stationSnapshotCache.removeAll()
        snapshotTimestamps.removeAll()
        print("🗑️ STATION SNAPSHOT: Cleared all existing station snapshots")
        
        // Reset DataSyncManager snapshot tracking
        Task { @MainActor in
            DataSyncManager.shared.updateStationSnapshotReadiness(
                countriesWithSnapshots: 0,
                totalCountriesRequiringSnapshots: 0
            )
        }
    }
    
    /// Update DataSyncManager with station snapshot readiness
    private func updateStationSnapshotReadiness() async {
        let countriesWithStations = await MainActor.run {
            Set(self.stations.compactMap { station in
                station.country.isEmpty || station.country == "Unknown Region" || station.country == "Select Country" ? nil : station.country
            })
        }
        
        var countriesWithSnapshots = 0
        for country in countriesWithStations {
            if await MainActor.run(body: { self.getStationSnapshot(for: country) != nil }) {
                countriesWithSnapshots += 1
            }
        }
        
        await MainActor.run {
            DataSyncManager.shared.updateStationSnapshotReadiness(
                countriesWithSnapshots: countriesWithSnapshots,
                totalCountriesRequiringSnapshots: countriesWithStations.count
            )
        }
    }
    
    /// Create station snapshots for all countries with stations
    func createStationSnapshotsForAllCountries() async {
        await MainActor.run {
            let countriesWithStations = Dictionary(grouping: self.stations) { $0.country }
                .filter { !$0.key.isEmpty && $0.key != "Unknown Region" && $0.key != "Select Country" }
            
            print("📸 Creating station snapshots for \(countriesWithStations.count) countries...")
            
            for (country, stations) in countriesWithStations {
                self.updateStationSnapshot(for: country, stations: stations)
            }
        }
    }
}

extension Notification.Name {
    static let countrySelected = Notification.Name("countrySelected")
    static let stationsUpdated = Notification.Name("stationsUpdated")
    static let countryChanged = Notification.Name("countryChanged")
    static let hiddenCountriesChanged = Notification.Name("hiddenCountriesChanged")
    static let selectedCountryCleared = Notification.Name("selectedCountryCleared")
    static let navigateToPodcastFeed = Notification.Name("navigateToPodcastFeed")
}

// MARK: - Hidden Countries Notification Handlers
extension RadioStationViewModel {
    @objc private func handleHiddenCountriesChanged(_ notification: Notification) {
        guard let countryName = notification.object as? String,
              let userInfo = notification.userInfo,
              let isHidden = userInfo["isHidden"] as? Bool else { return }
        
        if isHidden {
            print("🙈 Country '\(countryName)' was hidden - refreshing favorites list")
        } else {
            print("👁️ Country '\(countryName)' was shown - refreshing favorites list")
        }
        
        // Trigger UI refresh for favorites
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleSelectedCountryCleared() {
        DispatchQueue.main.async {
            self.selectedCountry = "Select Country"
            print("🌍 Selected country cleared due to being hidden")
        }
    }
}

// Conform to UIDocumentPickerDelegate to handle document picker events
extension RadioStationViewModel: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Handle the document picker result if needed
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Handle the document picker cancellation if needed
    }
}
