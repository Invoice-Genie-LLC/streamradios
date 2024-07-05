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
        loadStationsFromCloudKit()
        loadStationsFromFileOrFetchNew()
    }
    
    func saveMultipleStationsToCloud(stations: [RadioStation]) {
        DataStore.shared.saveStationsToCloudKit(stations: stations) { success, recordIDs in
            if success {
                print("Batch saved stations to CloudKit successfully.")
            } else {
                print("Failed to batch save stations to CloudKit.")
            }
        }
    }

    private func loadStationsFromCloudKit() {
           DataStore.shared.fetchRadioStations { [weak self] fetchedStations, error in
               if let fetchedStations = fetchedStations {
                   DispatchQueue.main.async {
                       self?.stations = fetchedStations
                       self?.checkAndAddDefaultStationsIfNeeded()
                   }
               } else {
                   print("Error fetching stations: \(error?.localizedDescription ?? "Unknown error")")
                   self?.checkAndAddDefaultStationsIfNeeded() // Try to add defaults if fetch fails
               }
           }
       }
    
    private func loadStationsFromFileOrFetchNew() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            loadStations()
        } else {
            fetchStationsAndSave()  // Attempts to fetch from CloudKit first
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
                    self?.saveStationsToFile()
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
            saveMultipleStationsToCloud(stations: stations)  // Saves the newly added default stations to CloudKit
        }
    }

    
    private func loadAndSaveDefaultStations() {
            print("Loading and saving default stations because no stations are available.")
            // Load default stations for all countries or based on selected country
            DefaultStations.addAllDefaults(to: self)
            // Save to CloudKit
            saveMultipleStationsToCloud(stations: stations)
            // Save locally
            saveStationsToFile()
        }
    
    private func checkAndAddDefaultStationsIfNeeded() {
        fetchStationsFromCloudKit { [weak self] existingStations in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if existingStations.isEmpty {
                    print("No stations are currently saved. Adding default stations.")
                    DefaultStations.addAllDefaults(to: self)
                    self.saveStationsToFile()  // Saves the newly added default stations locally
                    self.saveMultipleStationsToCloud(stations: self.stations)  // Saves the newly added default stations to CloudKit
                }
            }
        }
    }
    
    private func fetchStationsFromCloudKit(completion: @escaping ([RadioStation]) -> Void) {
        DataStore.shared.fetchRadioStations { fetchedStations, error in
            if let stations = fetchedStations, !stations.isEmpty {
                completion(stations)
            } else {
                print("Failed to fetch stations from CloudKit or no stations exist. Error: \(error?.localizedDescription ?? "Unknown error")")
                completion([])
            }
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
        let newStation = RadioStation(name: name, url: url, iconData: iconData, country: country)
        DispatchQueue.main.async {
            self.stations.append(newStation)
            self.saveStationToCloud(newStation)
        }
    }

    func saveStationsToFile() {
        do {
            let data = try JSONEncoder().encode(stations)
            try data.write(to: fileURL)
            print("Successfully saved stations to file.")
        } catch {
            print("Failed to write stations to file:", error)
        }
    }

    func loadStations() {
        do {
            let data = try Data(contentsOf: fileURL)
            let loadedStations = try JSONDecoder().decode([RadioStation].self, from: data)
            self.stations = loadedStations
            print("Successfully loaded stations from file.")
        } catch {
            print("Failed to load stations from file:", error)
            self.stations = []
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

    func updateStation(_ station: RadioStation, name: String, url: String, iconData: String?) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].name = name
            stations[index].url = url
            stations[index].iconData = iconData
            stations[index].country = selectedCountry
            saveStationsToFile()
            let iconImage = iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
            DataStore.shared.updateStationInCloudKit(station: stations[index], iconImage: iconImage) { success, recordName in
                DispatchQueue.main.async {
                    if success {
                        print("Station updated in CloudKit with record ID:", recordName ?? "Unknown")
                    } else {
                        print("Failed to update station in CloudKit.")
                    }
                }
            }
        }
    }

    func updateStationInCloudKit(station: RadioStation) {
        objectWillChange.send() // Notify subscribers that an update will happen
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        DataStore.shared.updateStationInCloudKit(station: station, iconImage: iconImage) { success, recordName in
            DispatchQueue.main.async {
                if success {
                    print("Station updated in CloudKit.")
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

