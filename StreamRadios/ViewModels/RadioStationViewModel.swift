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
        Country(name: "Select Station", flag: ""),
            Country(name: "Albania", flag: "AL"),
            Country(name: "Angola", flag: "AO"),
            Country(name: "Argentina", flag: "AR"),
            Country(name: "Australia", flag: "AU"),
            Country(name: "Bangladesh", flag: "BD"),
            Country(name: "Bolivia", flag: "BO"),
            Country(name: "Brazil", flag: "BR"),
            Country(name: "Bulgaria", flag: "BG"),
            Country(name: "Canada", flag: "CA"),
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
            Country(name: "Malaysia", flag: "MY"),
            Country(name: "Mexico", flag: "MX"),
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
           // Country(name: "Unknown Region", flag: "")  // Handle Unknown Region without a flag
        ]
    @Published var isLoading = false
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Unknown Region" {
        didSet {
            saveSelectedCountry()
        }
    }
    
    func saveStationsToLocal() {
        if stations.isEmpty {
            print("No stations available. Clearing local storage.")
            UserDefaults.standard.removeObject(forKey: "SavedStations")
        } else {
            do {
                let data = try JSONEncoder().encode(stations)
                UserDefaults.standard.set(data, forKey: "SavedStations")
                print("Stations saved locally, count: \(stations.count)")
            } catch {
                print("Failed to encode and save stations: \(error)")
            }
        }
        UserDefaults.standard.synchronize() // Ensure changes are saved immediately
    }

    
    func loadStationsFromLocal() {
        guard let data = UserDefaults.standard.data(forKey: "SavedStations") else {
            print("No data found in UserDefaults for 'SavedStations'.")
            return
        }
        do {
            stations = try JSONDecoder().decode([RadioStation].self, from: data)
            print("Loaded stations from UserDefaults:")
            for station in stations {
                print("\(station.name) - \(station.url) - \(station.country) - \(station.isFavorite)")
            }
        } catch {
            print("Failed to decode stations from UserDefaults: \(error)")
        }
    }

    
    func applySavedStationOrder() {
        if let savedOrder = UserDefaults.standard.array(forKey: "stationOrder") as? [String] {
            var orderedStations: [RadioStation] = []
            for id in savedOrder {
                if let station = stations.first(where: { $0.id == id }) {
                    orderedStations.append(station)
                }
            }
            // Append stations that may not be in the saved order
            for station in stations where !savedOrder.contains(station.id) {
                orderedStations.append(station)
            }
            stations = orderedStations
        }
    }
    
    private func saveSelectedCountry() {
        UserDefaults.standard.set(selectedCountry, forKey: "selectedCountry")
    }
    
    var filteredStations: [RadioStation] {
       return stations.filter { $0.country == selectedCountry }
    }
    
    @State var showingPurchaseView = false

    init() {
        selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Unknown Region"
       // loadStationsFromLocal()
        loadStationsFromCoreData()
        UserDefaults.standard.synchronize()
        if stations.isEmpty {
                    loadFromCloudKitIfNeeded()
                }
    }
    
    private func loadFromCloudKitIfNeeded() {
            // Check if we've already loaded data from CloudKit
            let hasLoadedFromCloudKit = UserDefaults.standard.bool(forKey: "HasLoadedFromCloudKit")
            if !hasLoadedFromCloudKit {
                loadStationsFromCloudKit()
            }
        }
    
    private func initializeStationsForFirstTime() {
        print("Initializing default stations for first time setup.")
        DefaultStations.addAllDefaults(to: self)
        saveStationsToCloudKit()
    }
    
    func loadStationsFromCloudKit() {
            isLoading = true
            DataStore.shared.fetchRadioStations { [weak self] fetchedStations, error in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if let fetchedStations = fetchedStations, !fetchedStations.isEmpty {
                        self?.stations = fetchedStations
                        self?.applySavedStationOrder()
                        UserDefaults.standard.set(true, forKey: "HasLoadedFromCloudKit")
                        self?.saveStationsToLocal() // Optionally save to local storage for faster future loads
                    } else {
                        self?.initializeStationsForFirstTime()
                    }
                }
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
        }
    }

    func recentStations() -> [RadioStation] {
        return stations.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed ?? Date.distantPast > $1.lastPlayed ?? Date.distantPast }
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
    }
    
    func saveStationsToCloudKit() {
        DataStore.shared.saveStationsToCloudKit(stations: stations) { success, recordIDs in
            DispatchQueue.main.async {
                if success {
                    print("Successfully saved stations to CloudKit.")
                } else {
                    print("Failed to save stations to CloudKit.")
                }
            }
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

    func deleteStation(at index: Int) {
        let stationToDelete = stations[index]

        // Delete from CloudKit
        DataStore.shared.deleteStationFromCloudKit(station: stationToDelete) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    // Remove station from the local list
                    self.stations.remove(at: index)
                    
                    // Directly delete the station from CoreData
                    self.deleteStationFromCoreData(stationToDelete)

                    // Update the radio player index if needed
                    self.updateRadioPlayerAfterDeletion(deletedIndex: index)

                    print("Station successfully deleted from CloudKit and local.")
                } else {
                    print("Failed to delete station from CloudKit: \(stationToDelete.name)")
                }
            }
        }
    }

    private func deleteStationFromCoreData(_ station: RadioStation) {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest() as! NSFetchRequest<CDStation>
        request.predicate = NSPredicate(format: "id == %@", station.id)
        
        do {
            let results = try context.fetch(request)
            for object in results {
                context.delete(object)
            }
            try context.save()
            print("Station deleted from CoreData successfully.")
        } catch {
            print("Failed to delete station from CoreData: \(error)")
        }
    }

    private func updateRadioPlayerAfterDeletion(deletedIndex: Int) {
        guard let currentIndex = RadioPlayer.shared.currentStationIndex else { return }

        if currentIndex == deletedIndex {
            RadioPlayer.shared.currentStationIndex = nil
            RadioPlayer.shared.isPlaying = false
            RadioPlayer.shared.player?.pause()
            print("Stopped playing as the current station was deleted.")
        } else if currentIndex > deletedIndex {
            RadioPlayer.shared.currentStationIndex! -= 1
            print("Adjusted player index after deletion.")
        }
    }


    func updateStation(_ existingStation: RadioStation, name: String, url: String, iconData: String?, country: String) {
        if let index = stations.firstIndex(where: { $0.id == existingStation.id }) {
            stations[index].name = name
            stations[index].url = url
            stations[index].iconData = iconData
            stations[index].country = country
            updateStationInCloudKit(station: stations[index])
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
    }
}


struct Country: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var flag: String
   
}

extension RadioStationViewModel {
    
    func saveStationsToCoreData() {
            let context = CoreDataStack.shared.context

            // Delete all existing records to ensure synchronization
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: CDStation.fetchRequest())
            do {
                try context.execute(deleteRequest)
                print("All existing stations deleted from CoreData.")
                
                // Only create new records if there are stations to save
                if !stations.isEmpty {
                    for station in stations {
                        let cdStation = CDStation(context: context)
                        cdStation.id = station.id
                        cdStation.name = station.name
                        cdStation.url = station.url
                        cdStation.iconData = station.iconData
                        cdStation.country = station.country
                        cdStation.isFavorite = station.isFavorite
                    }
                    print("New stations are being saved to CoreData.")
                } else {
                    print("No stations available to save to CoreData.")
                }
                
                // Attempt to save context changes
                try context.save()
                print("CoreData context saved successfully.")
            } catch {
                print("Failed to save to CoreData or delete records: \(error)")
            }
        }

    func loadStationsFromCoreData() {
            let context = CoreDataStack.shared.context
            let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()

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
                        isFavorite: cdStation.isFavorite
                    )
                }
                print("Loaded \(stations.count) stations from CoreData.")
            } catch {
                print("Failed to load stations from CoreData: \(error)")
            }
        }
}
