// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine

class RadioStationViewModel: ObservableObject {
    @Published var stations: [RadioStation] = []
    @State var showingPurchaseView = false

    private var fileURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("SavedRadioStations.plist")
    }

    init() {
        loadStationsFromFileOrFetchNew()
    }

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
                if let stations = stations {
                    self?.stations = stations
                    self?.saveStationsToFile()
                    print("Fetched \(stations.count) stations from CloudKit and saved to file.")
                } else if let error = error {
                    print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
                }
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

    func addStation(name: String, url: String, iconData: String?) {
            if stations.count >= 5 && !PurchaseManager.shared.hasPurchasedPremium {
                // Trigger view to show purchase option
                showingPurchaseView = true
            } else {
                let newStation = RadioStation(name: name, url: url, iconData: iconData)
                stations.append(newStation)
                saveStationsToFile()
                saveStationToCloud(newStation)
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
