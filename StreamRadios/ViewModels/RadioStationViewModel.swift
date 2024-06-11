//
//  RadioStationViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

// RadioStationViewModel.swift
import SwiftUI
import Combine

class RadioStationViewModel: ObservableObject {
    @Published var stations: [RadioStation] = []

    private let userDefaultsKey = "SavedRadioStations"

    init() {
        loadStations()
    }

    func addStation(name: String, url: String) {
        let newStation = RadioStation(name: name, url: url)
        stations.append(newStation)
        saveStations()
    }

    func saveStations() {
        if let encodedStations = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(encodedStations, forKey: userDefaultsKey)
        }
    }

    private func loadStations() {
        if let savedStationsData = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedStations = try? JSONDecoder().decode([RadioStation].self, from: savedStationsData) {
            stations = savedStations
        }
    }

    func deleteStation(at offsets: IndexSet) {
        if let firstIndex = offsets.first {
            // Check if the current playing station is being deleted
            if let currentStationIndex = RadioPlayer.shared.currentStationIndex,
               currentStationIndex == firstIndex {
                RadioPlayer.shared.currentStationIndex = nil
                RadioPlayer.shared.isPlaying = false
                RadioPlayer.shared.player?.pause()
            } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex,
                      currentStationIndex > firstIndex {
                // Update the current station index if it is after the deleted index
                RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
            }
        }
        stations.remove(atOffsets: offsets)
        saveStations()
    }

    func moveStation(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        saveStations()
    }
}
