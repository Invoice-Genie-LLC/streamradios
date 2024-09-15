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
    @State private var selectedFeedIdentifier: FeedIdentifier?


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
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenPodcastFeed"))) { notification in
                                    if let feedId = notification.userInfo?["feedId"] as? String {
                                        selectedFeedIdentifier = FeedIdentifier(id: feedId)
                                    }
                                }
                                .sheet(item: $selectedFeedIdentifier) { feedIdentifier in
                                    if let feed = podcastViewModel.podcastFeeds.first(where: { $0.id == feedIdentifier.id }) {
                                        PodcastPlayerView(
                                            viewModel: podcastViewModel,
                                            feed: feed,
                                            initialScrollToEpisodeID: nil,
                                            podcastPlayer: podcastPlayer,
                                            episodeToScrollTo: .constant(nil),
                                            selectedPodcast: Binding(
                                                get: { feed },
                                                set: { _ in selectedFeedIdentifier = nil }
                                            )
                                        )
                                    }
                                }
                .onAppear {
                    setupApp()
                    PodcastPlayer.shared.configure(with: podcastViewModel)
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
        
        // Schedule notifications when new podcast episodes are released 
        podcastViewModel.scheduleEpisodeChecks()

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
            }
        }
        
        // Load podcast episode progress
          podcastViewModel.loadAllEpisodesProgress()
          
          // Clean up any duplicate episodes
          podcastViewModel.cleanupDuplicateEpisodes()
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

struct FeedIdentifier: Identifiable {
    let id: String
}
