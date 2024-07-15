// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine
import CoreData

class RadioStationViewModel: ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var countries: [Country] = [
        Country(name: "Select Country", flag: ""),
        Country(name: "Albania", flag: "AL"),
        Country(name: "Angola", flag: "AO"),
        Country(name: "Argentina", flag: "AR"),
        Country(name: "Australia", flag: "AU"),
        Country(name: "Bangladesh", flag: "BD"),
        Country(name: "Bolivia", flag: "BO"),
        Country(name: "Brazil", flag: "BR"),
        Country(name: "Bulgaria", flag: "BG"),
        Country(name: "Canada", flag: "CA"),
        Country(name: "China", flag: "CN"),
        Country(name: "Costa Rica", flag: "CR"),
        Country(name: "Czech Republic", flag: "CZ"),
        Country(name: "France", flag: "FR"),
        Country(name: "Germany", flag: "DE"),
        Country(name: "Greece", flag: "GR"),
        Country(name: "Haiti", flag: "HT"),
        Country(name: "Hungary", flag: "HU"),
        Country(name: "India", flag: "IN"),
        Country(name: "Indonesia", flag: "ID"),
        Country(name: "Italy", flag: "IT"),
        Country(name: "Japan", flag: "JP"),
        Country(name: "Kosovo", flag: "XK"),
        Country(name: "Macedonia", flag: "MK"),
        Country(name: "Malaysia", flag: "MY"),
        Country(name: "Mexico", flag: "MX"),
        Country(name: "Montenegro", flag: "ME"),
        Country(name: "Netherlands", flag: "NL"),
        Country(name: "New Zealand", flag: "NZ"),
        Country(name: "Peru", flag: "PE"),
        Country(name: "Poland", flag: "PL"),
        Country(name: "Portugal", flag: "PT"),
        Country(name: "Russia", flag: "RU"),
        Country(name: "Serbia", flag: "RS"),
        Country(name: "Slovakia", flag: "SK"),
        Country(name: "South Africa", flag: "ZA"),
        Country(name: "Spain", flag: "ES"),
        Country(name: "Sweden", flag: "SE"),
        Country(name: "Switzerland", flag: "CH"),
        Country(name: "Tanzania", flag: "TZ"),
        Country(name: "Turkey", flag: "TR"),
        Country(name: "UK", flag: "GB"),
        Country(name: "USA", flag: "US"),
        Country(name: "Zimbabwe", flag: "ZW"),
        Country(name: "Unknown Region", flag: "")  // ToDo: Handle Unknown Region without a flag
    ]
    @Published var selectedTab: Tab = .all
    @Published var activeSheet: ActiveSheet? = nil
    @Published var isLoading = false
    @Published var isCloudKitOperationRunning = false
    var operationStarted = false
    var operationCompleted = false
    var startNotificationSent = false
    var backgroundNotificationSent = false
    private var completionNotificationSent = false
    private var operationStartedNotified = false
        private var operationCompletedNotified = false

    @Published var isDeletingData = false
    @Published var deletionComplete = false
    @Published var showingPurchaseView = false
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country" {
        didSet {
            saveSelectedCountry()
            if selectedCountry != "Select Country" {
                            NotificationCenter.default.post(name: .countrySelected, object: nil)
                        }
        }
    }
    static let shared = RadioStationViewModel()

    
    enum ActiveSheet: Identifiable {
        case editStation, purchase
        var id: Int {
            self.hashValue
        }
    }
    
    private func saveSelectedCountry() {
        UserDefaults.standard.set(selectedCountry, forKey: "selectedCountry")
    }
    
    var isPremiumUser: Bool {
            return PurchaseManager.shared.hasPurchasedPremium
        }
    
    var filteredStations: [RadioStation] {
        switch selectedTab {
        case .recent:
            return recentStations().filter { $0.country == selectedCountry }
        case .favorites:
            let favoriteStations = favoriteStations().filter { $0.country == selectedCountry }
            return favoriteStations.isEmpty ? [] : favoriteStations
        case .all:
            return PurchaseManager.shared.hasPurchasedPremium ? stations.filter { $0.country == selectedCountry } : Array(stations.filter { $0.country == selectedCountry }.prefix(2000))
        }
    }
    
/*
        var filteredStations: [RadioStation] {
            let filtered = stations.filter { $0.country == selectedCountry }
            if isPremiumUser {
                print("User is premium, showing all stations for \(selectedCountry).")
                return filtered
            } else {
                print("User is not premium, limiting to 5 stations for \(selectedCountry).")
                return Array(filtered.prefix(2000))
            }
        }
 */
    
    init() {
            selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country"
            loadStationsFromCoreData()

            let userDefaults = UserDefaults.standard
            let hasLaunchedBeforeKey = "HasLaunchedBefore"

            if !userDefaults.bool(forKey: hasLaunchedBeforeKey) {
                print("First time setup, initializing default stations and saving to local and CloudKit.")
                initializeStationsForFirstTime()
                userDefaults.set(true, forKey: hasLaunchedBeforeKey)
                syncStationsWithCloudKit { success in
                    if success {
                        print("Stations successfully synchronized with CloudKit on first launch.")
                    } else {
                        print("Failed to synchronize stations with CloudKit on first launch.")
                    }
                }
            }
        }

    func appDidBecomeActive() {
        // This method could be called by the AppDelegate when the app becomes active
        syncStationsWithCloudKit { success in
            if success {
                print("Stations successfully synchronized with CloudKit on app relaunch.")
            } else {
                print("Failed to synchronize stations with CloudKit on app relaunch.")
            }
        }
        BackgroundTaskManager.shared.scheduleAppRefresh()  // Consider whether this needs to be here or can be moved
    }
    
    func startCloudKitOperation() {
            isCloudKitOperationRunning = true
            startNotificationSent = false
            backgroundNotificationSent = false
            // Start the operation
            notifyStartOfOperation()  // Call this where the operation starts
        }

        func endCloudKitOperation() {
            isCloudKitOperationRunning = false
            notifyEndOfOperation()  // Call this when the operation ends
            startNotificationSent = false
            backgroundNotificationSent = false
        }

        private func notifyStartOfOperation() {
            if !startNotificationSent {
                BackgroundTaskManager.shared.scheduleCompletionNotification(message: "CloudKit operation started. Please keep the app open.")
                startNotificationSent = true
            }
        }
    
    private func notifyEndOfOperation() {
            if startNotificationSent && !backgroundNotificationSent {
                BackgroundTaskManager.shared.scheduleCompletionNotification(message: "CloudKit operation completed successfully.")
                startNotificationSent = false
            }
        }

    func notifyBackground() {
            if isCloudKitOperationRunning && !backgroundNotificationSent {
                BackgroundTaskManager.shared.scheduleCompletionNotification(message: "CloudKit operation in progress. Return to the app.")
                backgroundNotificationSent = true  // Set this flag to prevent multiple notifications
            }
        }
    
    func resetNotifications() {
            startNotificationSent = false
            completionNotificationSent = false
        }
    
    private func notifyUser(title: String, message: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = UNNotificationSound.default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error scheduling notification: \(error.localizedDescription)")
                }
            }
        }

    
    private func resetNotificationFlags() {
            operationStartedNotified = false
            operationCompletedNotified = false
        }

    func deleteAllData(completion: @escaping (Bool, Error?) -> Void) {
            isDeletingData = true
            deletionComplete = false  // Reset completion flag at the start of deletion

            // Delete all stations from CloudKit
            DataStore.shared.deleteAllRecords(ofType: "streamingRadios") { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if success {
                        // Proceed with deleting data from CoreData if CloudKit deletion is successful
                        let context = CoreDataStack.shared.persistentContainer.viewContext
                        let deleteRequest = NSBatchDeleteRequest(fetchRequest: CDStation.fetchRequest())
                        
                        do {
                            try context.execute(deleteRequest)
                            try context.save()
                            self.stations.removeAll()
                            self.isDeletingData = false
                            self.deletionComplete = true  // Set completion flag to true on successful deletion
                            completion(true, nil)
                        } catch {
                            print("Error deleting stations from CoreData: \(error.localizedDescription)")
                            self.isDeletingData = false
                            completion(false, error)
                        }
                    } else if let error = error {
                        print("Failed to delete records from CloudKit: \(error.localizedDescription)")
                        self.isDeletingData = false
                        completion(false, error)
                    }
                }
            }
        }

    func syncStationsWithCloudKit(completion: @escaping (Bool) -> Void) {
        guard !operationStartedNotified else { return }

        self.isCloudKitOperationRunning = true
        operationStartedNotified = true
        NotificationManager.shared.notifyUser(title: "Sync Started", message: "Uploading data to CloudKit...")

        // Simulate a CloudKit operation
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { // Simulate network delay
            DispatchQueue.main.async {
                self.isCloudKitOperationRunning = false
                completion(true)
                if !self.operationCompletedNotified {
                    NotificationManager.shared.notifyUser(title: "Sync Complete", message: "Data has been successfully uploaded to CloudKit.")
                    self.operationCompletedNotified = true
                }
                self.resetNotificationFlags()
            }
        }
    }



    
    private func initializeStationsForFirstTime() {
        let userDefaults = UserDefaults.standard
        let hasLaunchedBeforeKey = "HasLaunchedBefore"
        
        // Check if the app has been launched before
        if userDefaults.bool(forKey: hasLaunchedBeforeKey) == false {
            print("Initializing default stations for first time setup.")
            
            // Add default stations
            DefaultStations.addAllDefaults(to: self)
            
            // Save stations to CloudKit and CoreData
            saveStationsToCloudKit()
            saveStationsToCoreData()
            
            // Set the flag to indicate that the app has been launched before
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.synchronize() // Ensure the flag is saved immediately
        }
    }
    
    var currentlyPlayingStation: RadioStation? {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              stations.indices.contains(currentStationIndex) else {
            return nil
        }
        return stations[currentStationIndex]
    }
    
    func isStationPlaying(_ station: RadioStation) -> Bool {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              currentStationIndex < stations.count,
              stations[currentStationIndex].id == station.id else {
            return false
        }
        return true
    }
    
    func toggleFavorite(for station: RadioStation) {
        if let index = stations.firstIndex(of: station), !isStationPlaying(stations[index]) {
            var updatedStation = stations[index]
            updatedStation.isFavorite.toggle()
            stations[index] = updatedStation
            updateStationInCloudKit(station: updatedStation)
            saveStationsToCoreData()
        }
    }
    
    func recentStations() -> [RadioStation] {
        let recentStations = stations.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed ?? Date.distantPast > $1.lastPlayed ?? Date.distantPast }
        saveStationsToCoreData()  // Save the updated order to CoreData
        return recentStations
    }
    
    func favoriteStations() -> [RadioStation] {
        return stations.filter { $0.isFavorite }
    }
    
    func playStation(_ station: RadioStation) {
        if let index = stations.firstIndex(of: station) {
            RadioPlayer.shared.playStation(at: index, from: stations)
            updateLastPlayed(for: station)
        }
    }
    
    func updateLastPlayed(for station: RadioStation) {
        if let index = stations.firstIndex(of: station) {
            stations[index].lastPlayed = Date()
            updateStationInCloudKit(station: stations[index])
            saveStationsToCoreData()  // Save the updated lastPlayed time to CoreData
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
    
    func addStation(name: String, url: String, iconData: String?, country: String) {
            let newStation = RadioStation(id: UUID().uuidString, name: name, url: url, iconData: iconData, country: country)
            stations.append(newStation)
            saveStationToCloudKit(station: newStation)
            saveStationsToCoreData()
        }
    
    func saveStationsToCloudKit() {
        if !operationStarted {
            NotificationManager.shared.notifyUser(title: "Sync Started", message: "Uploading data to CloudKit...")
            operationStarted = true
        }

        DataStore.shared.saveStationsToCloudKit(stations: stations) { [weak self] success, recordIDs in
            DispatchQueue.main.async {
                if success {
                    print("Successfully saved stations to CloudKit.")
                    if !(self?.operationCompleted ?? true) {
                        NotificationManager.shared.notifyUser(title: "Sync Complete", message: "Data has been successfully uploaded to CloudKit.")
                        self?.operationCompleted = true
                    }
                } else {
                    print("Failed to save stations to CloudKit.")
                    if !(self?.operationCompleted ?? true) {
                        NotificationManager.shared.notifyUser(title: "Sync Failed", message: "Failed to upload data to CloudKit.")
                        self?.operationCompleted = true // Ensure we set this to avoid multiple failed notifications.
                    }
                }
                self?.resetOperationFlags()
            }
        }
    }

    private func resetOperationFlags() {
        operationStarted = false
        operationCompleted = false
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
            
            
            print("Station deleted from CoreData successfully.")
        } catch {
            print("Failed to delete station from CoreData: \(error)")
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
        stations.move(fromOffsets: source, toOffset: destination)
        saveStationsToCoreData()  // Save the updated order to CoreData
    }
}

extension RadioStationViewModel {
    func saveStationsToCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext

        // First, delete all existing records to ensure synchronization
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: CDStation.fetchRequest())
        do {
            try context.execute(deleteRequest)
            print("All existing stations deleted from CoreData.")
        } catch {
            print("Error deleting existing stations from CoreData: \(error)")
        }

        // Then, add new records from the current list of stations
        if !stations.isEmpty {
            for (index, station) in stations.enumerated() {
                let cdStation = CDStation(context: context)
                cdStation.id = station.id
                cdStation.name = station.name
                cdStation.url = station.url
                cdStation.iconData = station.iconData
                cdStation.country = station.country
                cdStation.isFavorite = station.isFavorite
                cdStation.order = Int16(index)  // Set the order attribute
                cdStation.lastPlayed = station.lastPlayed  // Add this line
            }
            print("New stations are being saved to CoreData.")
        } else {
            print("No stations available to save to CoreData.")
        }

        // Finally, attempt to save context changes
        do {
            try context.save()
            print("CoreData context saved successfully.")
        } catch {
            print("Failed to save stations to CoreData: \(error)")
        }
    }
    
    func loadStationsFromCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        
        // Add a sort descriptor to ensure stations are loaded in the correct order
        let sortDescriptor = NSSortDescriptor(key: "order", ascending: true)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            let results = try context.fetch(request)
            if results.isEmpty {
                print("No stations found in CoreData.")
            }
            stations = results.map { cdStation in
                RadioStation(
                    id: cdStation.id ?? UUID().uuidString,
                    name: cdStation.name ?? "Unknown",
                    url: cdStation.url ?? "http://default.url",
                    iconData: cdStation.iconData,
                    country: cdStation.country ?? "Unknown",
                    isFavorite: cdStation.isFavorite,
                    lastPlayed: cdStation.lastPlayed
                )
            }
            print("Loaded \(stations.count) stations from CoreData.")
        } catch {
            print("Failed to load stations from CoreData: \(error)")
        }
    }
}

extension Notification.Name {
    static let countrySelected = Notification.Name("countrySelected")
}
