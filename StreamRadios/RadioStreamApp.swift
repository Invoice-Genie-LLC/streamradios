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
import AVFoundation

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
                    // Configure podcast player immediately - PodcastViewModel is already initialized
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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // CRITICAL FIX: Only reconfigure if podcast player doesn't already have an active episode
                    // This prevents progress reset when returning from lock screen with current episode
                    print("📱 App became active - checking if podcast player needs reconfiguration")
                    
                    if PodcastPlayer.shared.currentEpisode == nil {
                        print("📱 App became active - reconfiguring podcast player (no current episode)")
                        PodcastPlayer.shared.configure(with: podcastViewModel)
                    } else {
                        print("📱 App became active - skipping reconfiguration (episode already loaded, preserving progress)")
                    }
                }
                .onDisappear {
                            appDelegate.updatePodcastStateAndSave()
                            podcastViewModel.saveContextIfNeeded()
                        }
        }
    }

    private func setupApp() {
        print("🎯 SETUP APP: Starting setupApp() method")
        
        // Audio session configuration is handled by PlaybackManager to prevent conflicts
        // This ensures centralized management and proper retry logic
        
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
            print("⏭️ SEQUENCING: Radio station sync will be handled by DataSyncManager to prevent CloudKit rate limiting")
            // NOTE: Radio station sync is now handled by DataSyncManager in sequence to prevent CloudKit rate limiting
            // fetchStationsFromCloudKit() - REMOVED to prevent parallel CloudKit operations
        } else {
            print("⚡ Skipping CloudKit radio station sync - stations already loaded by ViewModel for instant startup")
            // RadioStationViewModel already loaded stations in its init, no need to reload
            // Setup auto-play functionality with proper setting checks
            radioPlayer.autoPlayLastStationSetup()
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
                    
                    // After loading stations from CloudKit, setup auto-play with proper setting checks
                    RadioPlayer.shared.autoPlayLastStationSetup()
                }
            } else if let error = error {
                print("Failed to fetch stations from CloudKit: \(error.localizedDescription)")
            }
            // CRITICAL FIX: Do NOT set HasLaunchedBefore here!
            // This flag should ONLY be set by DataSyncManager AFTER fresh install sync completes
        }
    }
}

func updateWidget() {
    let radioPlayer = RadioPlayer.shared
    guard let currentStation = radioPlayer.currentlyPlayingStation else {
        print("No current station found.")
        return
    }
    
    // CRITICAL FIX: Use currentlyPlayingStation directly to prevent contamination
    let metadata = radioPlayer.metadata ?? "No metadata"
      
    let sharedDefaults = UserDefaults(suiteName: "group.streamradios")
    sharedDefaults?.set(currentStation.name, forKey: "stationName")
    sharedDefaults?.set(currentStation.iconData, forKey: "stationIcon")
    sharedDefaults?.set(metadata, forKey: "stationMetadata")
    
    WidgetCenter.shared.reloadAllTimelines()
    print("Widget updated with station: \(currentStation.name), metadata: \(metadata)")
}
