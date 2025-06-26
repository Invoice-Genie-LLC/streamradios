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
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var alertManager = AlertManager()
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    var radioPlayer = RadioPlayer.shared
    var viewModel = RadioStationViewModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PermissionManager())
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel.shared)
                .environmentObject(notificationManager)
                .environmentObject(alertManager)
                .environmentObject(podcastViewModel)
                .environmentObject(podcastPlayer)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    setupApp()
                    PodcastPlayer.shared.configure(with: podcastViewModel)
                    // CarPlay is now configured via CarPlaySceneDelegate
                }
                .onDisappear {
                            appDelegate.updatePodcastStateAndSave()
                            podcastViewModel.saveContextIfNeeded()
                        }
        }
    }

    private func setupApp() {
        // Set up the remote command center
        radioPlayer.setupRemoteCommandCenter()

        // Set the ViewModel for RadioPlayer
        radioPlayer.setViewModel(viewModel)
                
        if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
            notificationManager.requestAuthorization()
            UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
        }
        
        // Handle the fetched stations if needed
        if viewModel.stations.isEmpty {
            if UserDefaults.standard.bool(forKey: "HasLaunchedBefore") == false {
                fetchStationsFromCloudKit()
            } else {
                viewModel.loadStationsFromCoreData()
                // After loading stations, ensure radio player state is restored
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    radioPlayer.restoreStateAfterStationsLoaded()
                }
            }
        } else {
            // Stations are already loaded, ensure radio player state is restored
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                radioPlayer.restoreStateAfterStationsLoaded()
            }
        }
        
        // Initialize podcast system with CloudKit support
        podcastViewModel.initializeWithCloudKitSupport()
    }

    private func fetchStationsFromCloudKit() {
        DataStore.shared.fetchRadioStations { [weak viewModel] stations, error in
            if let stations = stations {
                DispatchQueue.main.async {
                    viewModel?.stations = stations
                    viewModel?.saveStationsToCoreData()
                    print("Fetched and populated \(stations.count) stations from CloudKit.")
                    
                    // Notify that stations have been updated
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    
                    // After loading stations from CloudKit, ensure radio player state is restored
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        RadioPlayer.shared.restoreStateAfterStationsLoaded()
                    }
                }
            } else if let error = error {
                print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
            }
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
        }
    }
}

func updateWidget() {
    let radioPlayer = RadioPlayer.shared
    guard let viewModel = radioPlayer.viewModel,
          let currentStationIndex = radioPlayer.currentStationIndex,
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
    print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
}
