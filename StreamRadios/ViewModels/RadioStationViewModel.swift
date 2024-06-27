//
//  RadioStationViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine

class RadioStationViewModel: ObservableObject {
    @Published var stations: [RadioStation] = []
    
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
                // If the file doesn't exist, consider fetching new data from CloudKit or initializing an empty list.
                fetchStationsAndSave()
            }
        }
    
    private func fetchStationsAndSave() {
            DataStore.shared.fetchRadioStations { [weak self] stations, error in
                DispatchQueue.main.async {
                    if let stations = stations {
                        self?.stations = stations
                        self?.saveStationsToFile() // Save fetched stations to file
                        print("Fetched \(stations.count) stations from CloudKit and saved to file.")
                    } else if let error = error {
                        print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
                    }
                }
            }
        }
    
    func addStation(name: String, url: String, iconData: String?) {
        let newStation = RadioStation(name: name, url: url, iconData: iconData)
        stations.append(newStation)
        saveStationsToFile()  // Save locally to file
        saveStationToCloud(newStation)  // Also save to CloudKit
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
                self.stations = []  // default to empty if there's a problem loading
            }
        }
    
func saveStationsToFile(stations: [RadioStation]) {
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentURL = urls.first else { return }
        let fileURL = documentURL.appendingPathComponent("SavedRadioStations.plist")

        do {
            let data = try JSONEncoder().encode(stations)
            try data.write(to: fileURL)
        } catch {
            print("Failed to write stations to file:", error)
        }
    }

    func loadStationsFromFile() -> [RadioStation]? {
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentURL = urls.first else { return nil }
        let fileURL = documentURL.appendingPathComponent("SavedRadioStations.plist")

        do {
            let data = try Data(contentsOf: fileURL)
            let stations = try JSONDecoder().decode([RadioStation].self, from: data)
            return stations
        } catch {
            print("Failed to load stations from file:", error)
            return nil
        }
    }
    
    func saveStationToCloud(_ station: RadioStation) {
        // Convert icon data from String (base64) to UIImage.
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))

        // Correctly call the method with all expected parameters.
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
            
            // Delete the station from CloudKit first
            DataStore.shared.deleteStationFromCloudKit(station: station) { success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")

                        // If deletion is successful, update local data
                        self.stations.remove(at: index)
                        self.saveStationsToFile() // Update file storage after deleting
                        
                        // Handle the local player logic
                        if let currentStationIndex = RadioPlayer.shared.currentStationIndex,
                           currentStationIndex == index {
                            RadioPlayer.shared.currentStationIndex = nil
                            RadioPlayer.shared.isPlaying = false
                            RadioPlayer.shared.player?.pause()
                        } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex,
                                  currentStationIndex > index {
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

    func moveStation(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        saveStationsToFile() // Save reordered list in file storage
    }
}
