//
// RadioStreamApp.swift
// RadioStreamApp
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import WidgetKit
import UIKit
import MusicKit

@main
struct RadioStreamApp: App {
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var alertManager = AlertManager()
    @StateObject private var podcastViewModel = PodcastViewModel.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    private let podcastPlayer = PodcastPlayer.shared // Remove @StateObject to stop observing updates
    var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel.shared

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
                .environmentObject(subscriptionManager)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    setupApp()
                    PodcastPlayer.shared.configure(with: podcastViewModel)
                    // CarPlay is now configured via CarPlaySceneDelegate
                    
                    // Clear notifications and badge when app launches
                    NotificationManager.shared.clearAllNotificationsAndBadge()
                    
                    // Check for incomplete syncs on app startup
                    Task { @MainActor in
                        DataSyncManager.shared.checkAndResumeRadioStationSync()
                    }
                    
                    // Initialize comprehensive debug logging system
                    // DebugLogger.logInfo will be added when import is fixed
                }
                .onDisappear {
                            appDelegate.updatePodcastStateAndSave()
                            podcastViewModel.saveContextIfNeeded()
                        }
        }
    }

    private func setupApp() {
        print("🎯 SETUP APP: Starting setupApp() method")
        
        // Set up the remote command center
        radioPlayer.setupRemoteCommandCenter()

        // Set the ViewModel for RadioPlayer
        radioPlayer.setViewModel(viewModel)
        
        // Handle initial dark mode setup
        if !UserDefaults.standard.bool(forKey: "isDarkModeSet") {
            UserDefaults.standard.set(true, forKey: "isDarkMode")
            UserDefaults.standard.set(true, forKey: "isDarkModeSet")
        }
                
        if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
            notificationManager.requestAuthorization()
            UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
        }
        
        // Request Apple Music authorization for station artwork search
        Task {
            await MusicAuthorizationManager.shared.requestAuthorization()
            print("🎵 Apple Music authorization requested for artwork search")
        }
        
        // PERFORMANCE FIX: Check for radio station sync status instead of empty stations
        // This prevents CloudKit fetching on every app launch after initial sync
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
        
        if isFreshInstall || !hasRadioStationsSynced {
            print("🔄 Radio station sync needed - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
            fetchStationsFromCloudKit()
        } else {
            print("⚡ Skipping CloudKit radio station sync - stations already loaded by ViewModel for instant startup")
            // RadioStationViewModel already loaded stations in its init, no need to reload
            // Restore radio player state immediately since stations are already available
            radioPlayer.restoreStateAfterStationsLoaded()
        }
        
        // Initialize podcast system with CloudKit support
        print("🎯 SETUP APP: About to call podcastViewModel.initializeWithCloudKitSupport()")
        podcastViewModel.initializeWithCloudKitSupport()
        print("🎯 SETUP APP: Completed podcastViewModel.initializeWithCloudKitSupport()")
        
        // Initialize subscription system - this will load products and check subscription status
        Task {
            await subscriptionManager.initialize()
        }
    }

    private func fetchStationsFromCloudKit() {
        DataStore.shared.fetchRadioStations { [weak viewModel] stations, error in
            if let stations = stations {
                DispatchQueue.main.async {
                    viewModel?.stations = stations
                    viewModel?.saveStationsToCoreData()
                    print("Fetched and populated \(stations.count) stations from CloudKit.")
                    
                    // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                    UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                    
                    // Notify that stations have been updated
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    
                    // After loading stations from CloudKit, ensure radio player state is restored
                    RadioPlayer.shared.restoreStateAfterStationsLoaded()
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
