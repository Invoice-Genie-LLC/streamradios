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
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var purchaseManager = PurchaseManager.shared
    @StateObject private var notificationManager = NotificationManager.shared

    var radioPlayer = RadioPlayer.shared
    var viewModel = RadioStationViewModel()
    
    init() {
        radioPlayer.setViewModel(viewModel)
        
        // Fetch stations from CloudKit on new installations
        if UserDefaults.standard.bool(forKey: "HasLaunchedBefore") == false {
            DataStore.shared.fetchRadioStations { [weak viewModel] stations, error in
                DispatchQueue.main.async {
                    if let stations = stations {
                        viewModel?.stations = stations
                        print("Fetched \(stations.count) stations from CloudKit and populated the list.")
                    } else if let error = error {
                        print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
        }
        
        UIApplication.shared.beginReceivingRemoteControlEvents()
        radioPlayer.setupRemoteCommandCenter()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PermissionManager())
                .environmentObject(purchaseManager)
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
                .environmentObject(notificationManager)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
                        notificationManager.requestAuthorization()
                        UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
                    }
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
