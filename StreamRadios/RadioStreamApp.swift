//
// RadioStreamApp.swift
// RadioStreamApp
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import WidgetKit
import UIKit

@main
struct RadioStreamApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Perform initial setup in an initializer
    init() {
        let radioPlayer = RadioPlayer.shared
        let viewModel = RadioStationViewModel()
        radioPlayer.setViewModel(viewModel)
        
        // Set up remote control and start receiving remote control events
        UIApplication.shared.beginReceivingRemoteControlEvents()
        radioPlayer.setupRemoteCommandCenter()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel())
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    // Ensure that the orientation lock is applied when the app appears
                    AppDelegate.orientationLock = .portrait
                    UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
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
    let metadata = radioPlayer.metadata ?? "No metadata"
    
    let sharedDefaults = UserDefaults(suiteName: "group.streamradios")
    sharedDefaults?.set(currentStation.name, forKey: "stationName")
    sharedDefaults?.set(currentStation.iconData, forKey: "stationIcon")
    sharedDefaults?.set(metadata, forKey: "stationMetadata")
    
    WidgetCenter.shared.reloadAllTimelines()
    print("Widget updated with station: \(currentStation.name), metadata: \(String(describing: metadata))")
}
