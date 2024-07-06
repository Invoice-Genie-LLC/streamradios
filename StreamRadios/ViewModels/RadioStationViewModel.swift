// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine

class RadioStationViewModel: ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var countries: [String] = [
        "Albania", "Angola", "Argentina", "Australia", "Bangladesh", "Bolivia",
        "Brazil", "Bulgaria", "Canada", "Costa Rica", "Czech Republic", "France",
        "Germany", "Greece", "Haiti", "Hungary", "India", "Indonesia", "Italy",
        "Japan", "Malaysia", "Mexico", "Netherlands", "New Zealand", "Peru",
        "Poland", "Portugal", "Russia", "Serbia", "Slovakia", "South Africa",
        "Spain", "Sweden", "Switzerland", "Tanzania", "Turkey", "UK", "USA",
        "Zimbabwe", "Unknown Region"
    ]
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Unknown Region" {
        didSet {
            saveSelectedCountry()
        }
    }
    
    private func saveSelectedCountry() {
        UserDefaults.standard.set(selectedCountry, forKey: "selectedCountry")
    }
    
    var filteredStations: [RadioStation] {
       return stations.filter { $0.country == selectedCountry }
    }
    
    @State var showingPurchaseView = false

    private var fileURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("SavedRadioStations.plist")
    }

    init() {
        selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Unknown Region"
        loadStations()
        loadStationsFromFileOrFetchNew()
    }
    
    private func initializeStationsForFirstTime() {
            print("Initializing default stations for first time setup.")
            DefaultStations.addAllDefaults(to: self)
            saveStationsToFile()
            saveStationsToCloudKit()
        }
    
    
    
    /*
    private func loadStationsFromCloudKit() {
            DataStore.shared.fetchRadioStations { [weak self] fetchedStations, error in
                DispatchQueue.main.async {
                    if let fetchedStations = fetchedStations, !fetchedStations.isEmpty {
                        self?.stations = fetchedStations
                        self?.saveStationsToFile()
                    } else {
                        self?.initializeStationsForFirstTime()
                    }
                }
            }
        }
     */
    
    /*
    private func loadStationsFromFileOrFetchNew() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            loadStations()
        } else {
            fetchStationsAndSave()  // Attempts to fetch from CloudKit first
        }
    }
     */
    
    private func loadStationsFromFileOrFetchNew() {
           if FileManager.default.fileExists(atPath: fileURL.path) {
               loadStations()
           } else {
               fetchStationsAndSave()
           }
       }
    
    var currentlyPlayingStation: RadioStation? {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              stations.indices.contains(currentStationIndex) else {
            return nil
        }
        return stations[currentStationIndex]
    }

    private func fetchStationsAndSave() {
        DataStore.shared.fetchRadioStations { [weak self] stations, error in
            DispatchQueue.main.async {
                if let stations = stations, !stations.isEmpty {
                    // If stations exist, load them into the model
                    self?.stations = stations
                   // self?.saveStationsToFile()
                    print("Fetched \(stations.count) stations from CloudKit and saved to file.")
                } else {
                    // If no stations are found, either due to an error or because they simply don't exist, add defaults
                    print("No stations found or error: \(error?.localizedDescription ?? "Unknown error"). Adding default stations.")
                    self?.addDefaultStationsIfNeeded()
                }
            }
        }
    }
    
    private func addDefaultStationsIfNeeded() {
        if stations.isEmpty {
            print("No stations are currently saved. Adding default stations.")
            DefaultStations.addAllDefaults(to: self)
            saveStationsToFile()  // Saves the newly added default stations locally
           // saveMultipleStationsToCloud(stations: stations)  // Saves the newly added default stations to CloudKit
        }
    }

    
    private func loadAndSaveDefaultStations() {
            print("Loading and saving default stations because no stations are available.")
            // Load default stations for all countries or based on selected country
            DefaultStations.addAllDefaults(to: self)
            // Save to CloudKit
           // saveMultipleStationsToCloud(stations: stations)
            // Save locally
           // saveStationsToFile()
        }
    
    private func checkAndAddDefaultStationsIfNeeded() {
        if stations.isEmpty {
            // Here, add all default stations for each country since it's a fresh install or no stations are loaded.
            DefaultStations.addDefaultStationsForAlbania(to: self)
            DefaultStations.addDefaultStationsForAngola(to: self)
            DefaultStations.addDefaultStationsForAustralia(to: self)
            DefaultStations.addDefaultStationsForArgentina(to: self)
        }
    }
    
    // Modify this function to add new countries
    private func checkAndAddDefaultStations() {
            let allCountries = ["Albania", "Angola", "Australia", "Argentina"]  // Expand this list as necessary
            for country in allCountries {
                if !stations.contains(where: { $0.country == country }) {
                    switch country {
                    case "Albania":
                        DefaultStations.addDefaultStationsForAlbania(to: self)
                    case "Angola":
                        DefaultStations.addDefaultStationsForAngola(to: self)
                    case "Australia":
                        DefaultStations.addDefaultStationsForAustralia(to: self)
                    case "Argentina":
                        DefaultStations.addDefaultStationsForArgentina(to: self)
                    default:
                        break
                    }
                    print("Added default stations for \(country)")
                }
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

    func toggleFavorite(for station: RadioStation) {
        if let index = stations.firstIndex(of: station), !isStationPlaying(stations[index]) {
            var updatedStation = stations[index]
            updatedStation.isFavorite.toggle()
            stations[index] = updatedStation

            // If the station is added to favorites, reorder only in the favorites list
            if updatedStation.isFavorite {
                let favoriteStation = stations.remove(at: index)
                stations.insert(favoriteStation, at: index)
            } else {
                // Maintain the order in the All tab, only remove the favorite flag
                stations[index] = updatedStation
            }

            saveStationsToFile()
            updateStationInCloudKit(station: updatedStation)  // Ensure the change is saved in CloudKit
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
            // Play the station without reordering it
            RadioPlayer.shared.playStation(at: index, from: stations)
            updateLastPlayed(for: station)
        }
    }

    func updateLastPlayed(for station: RadioStation) {
        if let index = stations.firstIndex(of: station) {
            stations[index].lastPlayed = Date()
            saveStationsToFile()
            updateStationInCloudKit(station: stations[index])  // Ensure the change is saved in CloudKit
        }
    }
    
    func loadImageData(named name: String) -> String? {
            // Replace spaces with underscores to match asset names
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
            saveStationsToFile()
           // saveStationsToCloudKit(stations: [newStation])
        }
    
    func saveStationsToCloudKit(stations: [RadioStation]) {
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

    func saveStationToCloud(_ station: RadioStation) {
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
    
     func saveStationsToFile() {
            do {
                let data = try JSONEncoder().encode(stations)
                try data.write(to: fileURL)
                print("Stations saved locally.")
            } catch {
                print("Failed to save stations locally: \(error)")
            }
        }

     func loadStations() {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                loadStationsFromFile()
            } else {
                initializeStationsForFirstTime()
            }
        }
    
    private func saveStationsToCloudKit(stations: [RadioStation]? = nil) {
            let stationsToSave = stations ?? self.stations
            DataStore.shared.saveStationsToCloudKit(stations: stationsToSave) { success, recordIDs in
                if success {
                    print("Stations saved to CloudKit successfully.")
                } else {
                    print("Failed to save stations to CloudKit.")
                }
            }
        }

        private func loadStationsFromFile() {
            do {
                let data = try Data(contentsOf: fileURL)
                stations = try JSONDecoder().decode([RadioStation].self, from: data)
            } catch {
                print("Failed to load stations from file: \(error)")
            }
        }

    func deleteStation(at offsets: IndexSet) {
        offsets.forEach { index in
            let station = stations[index]
            DataStore.shared.deleteStationFromCloudKit(station: station) { success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")
                        self.stations.remove(at: index)
                        self.saveStationsToFile()
                        if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex == index {
                            RadioPlayer.shared.currentStationIndex = nil
                            RadioPlayer.shared.isPlaying = false
                            RadioPlayer.shared.player?.pause()
                        } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex > index {
                            RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
                        }
                        print("Local station data updated after successful CloudKit deletion.")
                    } else {
                        print("Failed to delete station from CloudKit.")
                    }
                }
            }
        }
    }

    func updateStation(_ existingStation: RadioStation, name: String, url: String, iconData: String?, country: String) {
        // First, find the station in the local data.
        if let index = stations.firstIndex(where: { $0.id == existingStation.id }) {
            // Update the local copy with new details.
            stations[index].name = name
            stations[index].url = url
            stations[index].iconData = iconData
            stations[index].country = country
            
            saveStationsToFile()  // Save the updated list to local storage
            
            // Now, update the station in CloudKit.
            updateStationInCloudKit(station: stations[index])
        } else {
            // If the station does not exist locally, log an error or handle it appropriately.
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
        saveStationsToFile()
    }
}

