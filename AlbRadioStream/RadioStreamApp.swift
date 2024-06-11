//
// RadioStreamApp.swift
// RadioStreamApp
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import WidgetKit

@main
struct RadioStreamApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel())
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    updateWidget()
                }
        }
    }
}

func updateWidget() {
    let radioPlayer = RadioPlayer.shared
    let viewModel = RadioStationViewModel()

    guard let currentStationIndex = radioPlayer.currentStationIndex,
          currentStationIndex < viewModel.stations.count else {
        print("No current station found or index out of bounds.")
        return
    }

    let currentStation = viewModel.stations[currentStationIndex]
    let metadata = radioPlayer.metadata

    let sharedDefaults = UserDefaults(suiteName: "group.radio.AlbRadioStream")
    sharedDefaults?.set(currentStation.name, forKey: "stationName")
    sharedDefaults?.set(currentStation.iconData, forKey: "stationIcon")
    sharedDefaults?.set(metadata, forKey: "stationMetadata")

    WidgetCenter.shared.reloadAllTimelines()
    print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
}
