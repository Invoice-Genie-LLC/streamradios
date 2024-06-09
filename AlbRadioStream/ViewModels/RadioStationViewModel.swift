//
//  RadioStationViewModel.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

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

    private func saveStations() {
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
        stations.remove(atOffsets: offsets)
        saveStations()
    }
}
