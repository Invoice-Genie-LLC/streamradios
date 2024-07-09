// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine

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
        loadStationsFromCloudKit()
    }
    
    private func initializeStationsForFirstTime() {
        print("Initializing default stations for first time setup.")
        DefaultStations.addAllDefaults(to: self)
        saveStationsToCloudKit()
    }
    
    func loadStationsFromCloudKit() {
        isLoading = true  // Start loading
        DataStore.shared.fetchRadioStations { [weak self] fetchedStations, error in
            DispatchQueue.main.async {
                self?.isLoading = false  // Stop loading regardless of the outcome
                if let fetchedStations = fetchedStations, !fetchedStations.isEmpty {
                    self?.stations = fetchedStations
                    self?.applySavedStationOrder() // Reorder stations based on saved order
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

    func deleteStation(at offsets: IndexSet) {
        offsets.forEach { index in
            let station = stations[index]
            DataStore.shared.deleteStationFromCloudKit(station: station) { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")
                        self?.stations.remove(at: index)
                        
                        if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex == index {
                            RadioPlayer.shared.currentStationIndex = nil
                            RadioPlayer.shared.isPlaying = false
                            RadioPlayer.shared.player?.pause()
                        } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex > index {
                            RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
                        }
                        print("View updated after successful CloudKit deletion.")
                    } else {
                        print("Failed to delete station from CloudKit.")
                    }
                }
            }
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
