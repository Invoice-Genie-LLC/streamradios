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
    @Published var isDeletingData: Bool = false
    @Published var deletionComplete: Bool = false
    @Published var isCloudKitOperationRunning = false
    @Published var isDeletionInProgress = false
    @Published var isUploadingToCloudKit = false
    @Published var isImportInProgress = false
    @Published var isAscendingSort = true
    
    // Progress tracking for station loading
    @Published var loadingProgress: Double = 0.0
    @Published var loadingStationsCount: Int = 0
    @Published var totalStationsToLoad: Int = 0
    @Published var loadingPhase: String = ""
    
    // Flag to prevent infinite loop in favorite timestamp migration
    private var isMigrationInProgress = false
    
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country" {
        didSet {
            print("🌍 Country selection changed from '\(oldValue)' to '\(selectedCountry)'")
            
            // Only proceed if the country actually changed and it's not "Select Country"
            if oldValue != selectedCountry && selectedCountry != "Select Country" {
                // Switch to All tab when country changes (except during initialization)
                selectedSubTab = .all
                print("🌍 Country changed from '\(oldValue)' to '\(selectedCountry)' - switching to All tab")
                
                // Automatically fetch stations for the newly selected country if it has no stations
                print("🌍 Triggering API fetch for newly selected country: \(selectedCountry)")
                Task { @MainActor in
                    await fetchStationsForSelectedCountry()
                }
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
            
            // Load sorting preferences
            loadSortingPreferences()
        
            // PERFORMANCE FIX: Only sync radio stations from CloudKit on fresh installs
            // Check if radio stations have been synced to prevent unnecessary CloudKit fetching
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
            
            if isFreshInstall || !hasRadioStationsSynced {
                print("🔄 Radio station sync needed in ViewModel - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                syncStationsWithCloudKit()
            } else {
                print("⚡ Skipping CloudKit radio station sync in ViewModel - loading from local storage only for better performance")
            }
    
            loadStationsFromCoreData()
            
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
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing station playlist from file...")
        
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

                // Get existing URLs to check for duplicates
                let existingURLs = Set(stations.map { $0.url })
                
                // Filter out stations that already exist by URL
                let newStations = stationsFromJson.filter { !existingURLs.contains($0.url) }
                
                let totalNewStations = Double(newStations.count)
                var importedStations = 0.0

                DispatchQueue.main.async {
                    // Append new stations instead of removing existing ones
                    for station in newStations {
                        self.stations.append(station)
                        importedStations += 1
                        progressHandler(importedStations / max(totalNewStations, 1))
                    }

                    print("Imported \(newStations.count) new stations. Skipped \(stationsFromJson.count - newStations.count) duplicates.")

                    // Save these to CoreData first
                    self.saveStationsToCoreData()

                    // Wait a bit to ensure Core Data save is complete, then save only new stations to CloudKit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Only save the newly imported stations to CloudKit (with URL duplicate checking)
                        DataStore.shared.saveImportedStationsToCloudKit(stations: newStations) { success, recordIDs in
                            DispatchQueue.main.async {
                                if success {
                                    print("Successfully saved \(newStations.count) new stations to CloudKit.")
                                    NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported \(newStations.count) new stations. Skipped \(stationsFromJson.count - newStations.count) duplicates.")
                                } else {
                                    print("Failed to save some or all new stations to CloudKit.")
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
                                            .map(ExportStation.init)

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
            
            // Use the new batch deletion method that sends only one sync notification
            try await RadioStationCloudKitManager.shared.deleteRadioStationsFromCloudKitBatch(stationIds)
            
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
        
        CoreDataStack.shared.syncStationsFromCloudKit { [weak self] error in
            if let error = error {
                print("Error syncing with CloudKit: \(error.localizedDescription)")
            } else {
                print("Stations successfully synchronized with CloudKit.")
                
                // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                
                DispatchQueue.main.async {
                    self?.loadStationsFromCoreData() // Reload stations from CoreData after sync
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    // StationsLoaded notification will be posted by loadStationsFromCoreData()
                }
            }
        }
    }
    
    private func initializeStationsForFirstTime() {
        let userDefaults = UserDefaults.standard
        let hasLaunchedBeforeKey = "HasLaunchedBefore"
        
        if userDefaults.bool(forKey: hasLaunchedBeforeKey) == false {
            print("Initializing default stations for first time setup or new default stations detected.")
                        
            saveStationsToCloudKit()
            saveStationsToCoreData()
            
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
        if let index = stations.firstIndex(of: station), !isStationCurrentlyPlaying(stations[index]) {
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
            
            // ENHANCED CLOUDKIT SYNC: Sync favorite status and station data to CloudKit automatically
            print("📡 🚨 RADIO CLOUDKIT SYNC: Station \(updatedStation.id) favorite \(updatedStation.isFavorite)")
            
            Task {
                do {
                    // Save the complete updated station to CloudKit
                    try await RadioStationCloudKitManager.shared.saveRadioStationToCloudKit(updatedStation)
                    
                    // Also update the specific favorite status for real-time sync
                    try await RadioStationCloudKitManager.shared.updateFavoriteStatus(
                        stationId: updatedStation.id,
                        isFavorite: updatedStation.isFavorite,
                        favoritedAt: updatedStation.favoritedAt,
                        favoriteOrder: updatedStation.favoriteOrder
                    )
                    
                    print("📡 ✅ RADIO CLOUDKIT SYNC: Successfully synced favorite change for \(updatedStation.name)")
                } catch {
                    print("📡 ❌ RADIO CLOUDKIT SYNC: Failed to sync favorite change: \(error)")
                }
            }
            saveStationsToCoreData()
        }
    }
    
    func recentStations() -> [RadioStation] {
        let recentStations = stations.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed ?? Date.distantPast > $1.lastPlayed ?? Date.distantPast }
        // No need to save to CoreData - this method only filters and sorts, doesn't modify data
        return recentStations
    }
    
    func favoriteStations() -> [RadioStation] {
        return stations.filter { $0.isFavorite }
            .sorted { station1, station2 in
                // Sort by favoriteOrder if both have it, otherwise by favoritedAt
                if let order1 = station1.favoriteOrder, let order2 = station2.favoriteOrder {
                    return order1 < order2
                } else if station1.favoriteOrder != nil {
                    return true  // station1 has order, station2 doesn't, so station1 comes first
                } else if station2.favoriteOrder != nil {
                    return false // station2 has order, station1 doesn't, so station2 comes first
                } else {
                    // Neither has favoriteOrder, sort by favoritedAt with most recent first
                    let date1 = station1.favoritedAt ?? Date.distantPast
                    let date2 = station2.favoritedAt ?? Date.distantPast
                    return date1 > date2
                }
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
        
        // ENHANCED CLOUDKIT SYNC: Save new station to CloudKit and sync across all devices
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
    
    func moveStation(from source: IndexSet, to destination: Int) {
        // Move the station in the array
        stations.move(fromOffsets: source, toOffset: destination)
        
        // Update order values for all stations to reflect new positions
        updateStationOrderValues()
        
        // Save to CoreData
        saveStationsToCoreData()
        
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
        var favoritesList = favoriteStations()
        favoritesList.move(fromOffsets: source, toOffset: destination)
        
        // Update favoriteOrder values
        for (index, favorite) in favoritesList.enumerated() {
            if let stationIndex = stations.firstIndex(where: { $0.id == favorite.id }) {
                stations[stationIndex].favoriteOrder = index
            }
        }
        
        // Save to CoreData
        saveStationsToCoreData()
        
        // ENHANCED CLOUDKIT SYNC: Sync favorite order changes to CloudKit
        Task {
            await syncFavoriteOrderChangesToCloudKit()
        }
        
        print("📡 🔄 Updated favorite order values for \(favoritesList.count) stations")
    }
    
    /// Sort stations alphabetically and toggle sort direction
    func sortStationsAlphabetically() {
        // Toggle sort direction
        isAscendingSort.toggle()
        
        // Save the sort direction to UserDefaults
        UserDefaults.standard.set(isAscendingSort, forKey: "RadioStationSortAscending")
        
        print("📡 📝 Toggled radio station sort direction to: \(isAscendingSort ? "A-Z" : "Z-A")")
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
    
    /// Sync station order changes to CloudKit
    func syncOrderChangesToCloudKit() async {
        print("📡 🚨 RADIO ORDER SYNC: Starting order sync to CloudKit...")
        
        do {
            // Sync all affected stations to CloudKit
            for station in stations {
                try await RadioStationCloudKitManager.shared.saveRadioStationToCloudKit(station)
            }
            
            // Trigger cross-device order sync notification
            await RadioStationCloudKitManager.shared.triggerCrossDeviceOrderSync(action: "order_changed")
            
            print("📡 ✅ RADIO ORDER SYNC: Successfully synced station order to CloudKit")
        } catch {
            print("📡 ❌ RADIO ORDER SYNC: Failed to sync order to CloudKit: \(error)")
        }
    }
    
    /// Sync favorite order changes to CloudKit
    func syncFavoriteOrderChangesToCloudKit() async {
        print("📡 🚨 RADIO FAVORITE ORDER SYNC: Starting favorite order sync to CloudKit...")
        
        do {
            // Only sync favorite stations to CloudKit
            let favorites = favoriteStations()
            for station in favorites {
                try await RadioStationCloudKitManager.shared.saveRadioStationToCloudKit(station)
            }
            
            // Trigger cross-device favorite order sync notification
            await RadioStationCloudKitManager.shared.triggerCrossDeviceOrderSync(action: "favorite_order_changed")
            
            print("📡 ✅ RADIO FAVORITE ORDER SYNC: Successfully synced favorite order to CloudKit")
        } catch {
            print("📡 ❌ RADIO FAVORITE ORDER SYNC: Failed to sync favorite order to CloudKit: \(error)")
        }
    }
    
    // MARK: - Radio Browser API Integration
    
    @MainActor
    func fetchStationsFromAPI(for country: Country) async {
        isLoading = true
        loadingProgress = 0.0
        totalStationsToLoad = 0
        loadingStationsCount = 0
        loadingPhase = "Connecting to API..."
        
        do {
            print("🌐 Radio Browser API: Fetching stations for \(country.name) with API code: \(country.apiCountryCode)")
            logDeletedStationsCount()
            
            await MainActor.run {
                loadingPhase = "Connecting to radio database..."
                loadingProgress = 0.05
            }
            
            // Start progress simulation during API call
            let progressTask = Task { @MainActor in
                var currentProgress = 0.05
                while currentProgress < 0.25 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                    currentProgress += 0.02
                    loadingProgress = currentProgress
                    
                    // Update phase messages during download
                    if currentProgress < 0.1 {
                        loadingPhase = "Connecting to radio database..."
                    } else if currentProgress < 0.15 {
                        loadingPhase = "Downloading station data..."
                    } else if currentProgress < 0.2 {
                        loadingPhase = "Receiving stations..."
                    } else {
                        loadingPhase = "Finishing download..."
                    }
                }
            }
            
            let apiStations = try await RadioBrowserAPI.shared.fetchTopStationsByCountry(countryCode: country.apiCountryCode, limit: 500)
            
            // Cancel progress simulation as API call completed
            progressTask.cancel()
            
            print("📡 RadioBrowserAPI: Received \(apiStations.count) stations for \(country.name)")
            
            await MainActor.run {
                loadingProgress = 0.3
                loadingPhase = "Download completed, received \(apiStations.count) stations..."
            }
            
            guard !apiStations.isEmpty else {
                print("📡 RadioBrowserAPI: No stations found for \(country.name)")
                isLoading = false
                loadingProgress = 0.0
                loadingPhase = ""
                return
            }
            
            await MainActor.run {
                totalStationsToLoad = apiStations.count
                loadingPhase = "Preparing to process \(totalStationsToLoad) stations..."
                loadingProgress = 0.32
            }
            
            // DEDUPLICATION: Filter out stations with identical URLs from the API response
            // Only keep the first occurrence of each unique URL (usually the one with highest click count)
            await MainActor.run {
                loadingPhase = "Checking for duplicates..."
                loadingProgress = 0.35
            }
            
            var seenURLs = Set<String>()
            var processedCount = 0
            let deduplicatedStations = apiStations.filter { apiStation in
                processedCount += 1
                
                // Update progress during deduplication
                if processedCount % 50 == 0 || processedCount == apiStations.count {
                    let dedupeProgress = Double(processedCount) / Double(apiStations.count) * 0.15 // 15% range for deduplication
                    Task { @MainActor in
                        loadingProgress = 0.35 + dedupeProgress
                        loadingPhase = "Checking duplicates... \(processedCount)/\(apiStations.count)"
                    }
                }
                
                guard !apiStation.url.isEmpty else { return false }
                
                if seenURLs.contains(apiStation.url) {
                    print("🔄 Skipping duplicate URL: \(apiStation.url) (Station: \(apiStation.name))")
                    return false
                }
                
                seenURLs.insert(apiStation.url)
                return true
            }
            
            let duplicatesSkippedFromAPI = apiStations.count - deduplicatedStations.count
            if duplicatesSkippedFromAPI > 0 {
                print("⚡ URL Deduplication: Filtered out \(duplicatesSkippedFromAPI) stations with duplicate URLs from API response")
            }
            
            print("📡 RadioBrowserAPI: Processing \(deduplicatedStations.count) unique stations (removed \(duplicatesSkippedFromAPI) URL duplicates)")
            
            // Use deduplicated stations for processing
            let processedAPIStations = deduplicatedStations
            await MainActor.run {
                totalStationsToLoad = processedAPIStations.count
                loadingPhase = "Converting \(totalStationsToLoad) stations..."
                loadingProgress = 0.5
            }
            
            // Convert API stations to app stations, preserving existing favicon data if available
            let existingStationsMap = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
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
                        loadingPhase = "Converting stations... \(conversionProcessedCount)/\(totalStationsToLoad)"
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
                
                // Check if we already have this station with favicon data
                let existingIconData = existingStationsMap[apiStation.stationuuid]?.iconData
                if existingIconData != nil {
                    cachedFaviconCount += 1
                }
                
                return RadioStation(
                    id: apiStation.stationuuid,
                    name: apiStation.name,
                    url: apiStation.url,
                    iconData: existingIconData, // Use cached favicon if available
                    country: country.name,
                    isFavorite: false,
                    favoritedAt: nil,
                    favoriteOrder: nil,
                    order: 0,
                    lastPlayed: nil
                )
            }
            
            // Download favicons in background only for stations that don't have them (non-blocking)
            let stationsNeedingFavicons = newStations.filter { $0.iconData == nil }
            if !stationsNeedingFavicons.isEmpty {
                let apiStationsMap = Dictionary(uniqueKeysWithValues: processedAPIStations.map { ($0.stationuuid, $0) })
                let correspondingAPIStations = stationsNeedingFavicons.compactMap { station in
                    apiStationsMap[station.id]
                }
                
                Task.detached { [weak self] in
                    await self?.downloadFaviconsInBackground(for: stationsNeedingFavicons, apiStations: correspondingAPIStations)
                }
            }
            
            // Filter out stations that already exist (check by URL to avoid duplicates)
            await MainActor.run {
                loadingPhase = "Filtering existing stations..."
                loadingProgress = 0.75
            }
            
            let existingURLs = Set(stations.map { $0.url })
            let uniqueNewStations = newStations.filter { !existingURLs.contains($0.url) }
            
            await MainActor.run {
                loadingPhase = "Analyzing results..."
                loadingProgress = 0.8
            }
            
            // Calculate counts for notification
            let totalFetched = apiStations.count
            let totalAfterURLDeduplication = processedAPIStations.count
            let deletedStationsFiltered = totalAfterURLDeduplication - newStations.count
            let newStationsAdded = uniqueNewStations.count
            let duplicatesSkipped = newStations.count - newStationsAdded
            
            guard !uniqueNewStations.isEmpty else {
                print("📡 RadioBrowserAPI: All fetched stations already exist for \(country.name)")
                await MainActor.run {
                    isLoading = false
                    loadingProgress = 0.0
                    loadingPhase = ""
                }
                return
            }
            
            await MainActor.run {
                loadingPhase = "Adding \(uniqueNewStations.count) new stations..."
                loadingProgress = 0.82
            }
            
            print("📡 RadioBrowserAPI: Adding \(uniqueNewStations.count) new stations for \(country.name)")
            
            // Add to local stations array (new stations at the top)
            for newStation in uniqueNewStations.reversed() {
                // Increment order of existing stations in the same country to make room at top
                for i in 0..<stations.count {
                    if stations[i].country == country.name {
                        stations[i].order += 1
                    }
                }
                // Insert new station at the beginning of the array
                stations.insert(newStation, at: 0)
            }
            
            print("✅ Added \(uniqueNewStations.count) new stations for \(country.name)")
            if cachedFaviconCount > 0 {
                print("🖼️ Using \(cachedFaviconCount) cached favicons, downloading \(uniqueNewStations.count - cachedFaviconCount) new ones")
            }
            
            // Save to CoreData first
            await MainActor.run {
                loadingPhase = "Preparing local storage..."
                loadingProgress = 0.85
            }
            
            saveStationsToCoreData()
            
            await MainActor.run {
                loadingPhase = "Saving to local storage..."
                loadingProgress = 0.9
            }
            
            // Save to CloudKit (using the same method as import for new stations)
            await MainActor.run {
                loadingPhase = "Initiating cloud sync..."
                loadingProgress = 0.93
            }
            
            DataStore.shared.saveNewStationsToCloudKit(stations: uniqueNewStations) { success, recordIDs in
                DispatchQueue.main.async {
                    if success {
                        print("📡 ✅ Successfully saved \(uniqueNewStations.count) API-fetched stations to CloudKit for \(country.name)")
                    } else {
                        print("📡 ⚠️ Failed to save some API-fetched stations to CloudKit for \(country.name)")
                    }
                }
            }
            
            await MainActor.run {
                loadingPhase = "Completing sync..."
                loadingProgress = 0.96
            }
            
            // Notify user about the fetch results (only when new stations were added)
            await MainActor.run {
                var notificationMessage = "Added \(newStationsAdded) new stations for \(country.name)."
                
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
                
                if !skipDetails.isEmpty {
                    notificationMessage += " Skipped \(skipDetails.joined(separator: ", ")) stations."
                }
                
                NotificationManager.shared.notifyUserImmediate(
                    title: "Radio Stations Fetched",
                    message: notificationMessage
                )
            }
            
            // Notify that stations have been updated
            await MainActor.run {
                loadingPhase = "Finalizing..."
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
            isLoading = false
        }
        
        // Reset progress values after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
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
    func fetchStationsForSelectedCountry() async {
        print("🌐 Radio Browser API: fetchStationsForSelectedCountry called for country: \(selectedCountry)")
        
        // First try to find the country in the existing countries array
        var currentCountry = countries.first(where: { $0.name == selectedCountry })
        
        // If not found (common on fresh install), create a country object as fallback
        if currentCountry == nil && selectedCountry != "Select Country" {
            print("🌐 Radio Browser API: Country not found in array, creating fallback country object for: \(selectedCountry)")
            currentCountry = Country(name: selectedCountry, flag: "")
            print("🌐 Radio Browser API: Created fallback country with API code: \(currentCountry?.apiCountryCode ?? "nil")")
        }
        
        guard let country = currentCountry else {
            print("🌐 Radio Browser API: No country selected or could not create country object for: \(selectedCountry)")
            return
        }
        
        print("🌐 Radio Browser API: Found/created country: \(country.name) with API code: \(country.apiCountryCode)")
        
        // Always fetch stations for the selected country to get the latest available stations
        // The duplicate prevention logic in fetchStationsFromAPI will filter out any existing stations
        let existingStationsForCountry = stations.filter { $0.country == selectedCountry }
        print("🌐 Radio Browser API: Current stations for \(selectedCountry): \(existingStationsForCountry.count). Fetching latest stations from API...")
        await fetchStationsFromAPI(for: country)
    }
    
    func reportStationClick(for station: RadioStation) {
        Task {
            await RadioBrowserAPI.shared.reportStationClick(stationUuid: station.id)
        }
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
    
    // MARK: - Background Favicon Download
    
    @MainActor
    private func downloadFaviconsInBackground(for stations: [RadioStation], apiStations: [RadioBrowserStation]) async {
        guard !stations.isEmpty else {
            print("🖼️ All stations already have cached favicons - skipping download")
            return
        }
        
        print("🖼️ Downloading favicons for \(stations.count) stations (others already cached)")
        let stationAPIMap = Dictionary(uniqueKeysWithValues: zip(stations.map { $0.id }, apiStations))
        
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
                    
                    // Save to Core Data in background for persistent caching
                    Task.detached {
                        await self.updateStationIconInCoreData(stationId: stationId, iconData: iconData)
                    }
                }
            }
        }
        
        // Clean up the session
        timeoutSession.invalidateAndCancel()
    }
    
    private func updateStationIconInCoreData(stationId: String, iconData: String) async {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        
        await context.perform {
            let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", stationId)
            
            do {
                if let station = try context.fetch(fetchRequest).first {
                    station.iconData = iconData
                    try context.save()
                    print("💾 Favicon cached to Core Data for station: \(station.name ?? "Unknown")")
                } else {
                    print("⚠️ Station not found in Core Data for favicon caching: \(stationId)")
                }
            } catch {
                print("❌ Failed to cache favicon to Core Data: \(error)")
            }
        }
    }
}

extension RadioStationViewModel {
    func saveStationsToCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        
        // Fetch existing stations
        let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        
        do {
            let existingStations = try context.fetch(fetchRequest)
            let existingDict = Dictionary(uniqueKeysWithValues: existingStations.map { ($0.id!, $0) })
            
            for (index, station) in stations.enumerated() {
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
                    let newStation = CDStation(context: context)
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
            let stationIDs = Set(stations.map { $0.id })
            for existingStation in existingStations {
                if !stationIDs.contains(existingStation.id!) {
                    context.delete(existingStation)
                }
            }
            
            // Save changes
            let hasChanges = context.hasChanges
            try context.save()
            
            // Only log if there were actual changes
            if hasChanges {
                print("CoreData stations updated successfully.")
            }
        } catch {
            print("Failed to update stations in CoreData: \(error)")
        }
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
}

extension Notification.Name {
    static let countrySelected = Notification.Name("countrySelected")
    static let stationsUpdated = Notification.Name("stationsUpdated")
    static let countryChanged = Notification.Name("countryChanged")
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
