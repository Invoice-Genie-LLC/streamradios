//
//  AppDelegate.swift
//  RadioStreamApp
//
//  Created by Kley Sulo on 6/9/24.
//

import UIKit
import CoreData
import UserNotifications
import AVFoundation
import SwiftUI
import BackgroundTasks
import SpotifyiOS

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    var window: UIWindow?
       var radioPlayer = RadioPlayer.shared
       var podcastPlayer = PodcastPlayer.shared
       var viewModel = RadioStationViewModel.shared
        var podcastViewModel = PodcastViewModel()
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
            if isFirstLaunch() {
                deleteLocalCoreDataStore()
            }
            
            UNUserNotificationCenter.current().delegate = self
            requestNotificationAuthorization()
            registerBackgroundTasks()
            configureAudioSession()
            
            let alarmCategory = UNNotificationCategory(identifier: "ALARM_CATEGORY", actions: [], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories([alarmCategory])
            
            application.registerForRemoteNotifications()
            
            checkBackgroundRefreshStatus()
            
            // Check if the app was launched due to an alarm
            if let launchOptions = launchOptions,
               launchOptions[UIApplication.LaunchOptionsKey.location] != nil {
                // App was launched due to an alarm, play the alarm station
                radioPlayer.playFavoriteStationForAlarm()
            } else {
                // Normal app launch, load the last played station
                radioPlayer.autoPlayLastStationSetup()
            }
            
            return true
        }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Immediately save current state when app is terminated
        updatePodcastStateAndSave()
        PodcastPlayer.shared.handleAppWillTerminate()
        podcastViewModel.saveContextIfNeeded()
        
        // Force synchronize UserDefaults to ensure data persistence
        UserDefaults.standard.synchronize()
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        // Save state immediately when app resigns active status (might be force closed)
        updatePodcastStateAndSave()
        PodcastPlayer.shared.handleAppWillTerminate()
        
        // Force synchronize to persist data
        UserDefaults.standard.synchronize()
    }

        func updatePodcastStateAndSave() {
            if let currentEpisode = podcastPlayer.currentEpisode {
                let currentProgress = PodcastPlayer.shared.currentProgress
                
                // Update progress
                podcastViewModel.updateProgress(for: currentEpisode, progress: currentProgress)
                
                // If episode was playing when app is closing, mark it as "In Progress"
                if podcastPlayer.isPlaying && currentProgress > 0 && currentProgress < 0.99 {
                    var updatedEpisode = currentEpisode
                    updatedEpisode.state.progress = currentProgress
                    updatedEpisode.state.isPlayed = false
                    podcastViewModel.updateEpisode(updatedEpisode)
                    
                    // Ensure EpisodeStateManager also reflects the correct state
                    EpisodeStateManager.shared.pausePlayback(episodeId: currentEpisode.id, progress: currentProgress)
                }

                // Update favorite (bookmark) state
                if currentEpisode.state.isFavorite != podcastViewModel.favoriteEpisodes.contains(where: { $0.id == currentEpisode.id }) {
                    podcastViewModel.toggleFavorite(for: currentEpisode)
                }
                
                // Update download state
                let isDownloaded = podcastViewModel.downloadedEpisodes.contains(where: { $0.id == currentEpisode.id })
                if currentEpisode.state.isDownloaded != isDownloaded {
                    if isDownloaded {
                        var updatedEpisode = currentEpisode
                        updatedEpisode.state.isDownloaded = true
                        podcastViewModel.updateEpisode(updatedEpisode)
                    } else {
                        podcastViewModel.deleteDownloadedEpisode(currentEpisode)
                    }
                }
            }
            
            // Save context and force synchronize
            podcastViewModel.saveContextIfNeeded()
        }

     func applicationDidEnterBackground(_ application: UIApplication) {
         // App entered background - save all current state immediately
         updatePodcastStateAndSave()
         PodcastPlayer.shared.handleAppWillTerminate()
         
         // Force synchronize to ensure data persistence
         UserDefaults.standard.synchronize()
     }
    
    lazy var persistentContainer: NSPersistentContainer = {
            let container = NSPersistentContainer(name: "PodcastModel")
            container.loadPersistentStores { (storeDescription, error) in
                if let error = error as NSError? {
                    fatalError("Unresolved error \(error), \(error.userInfo)")
                }
            }
            return container
        }()
    
    func saveContext() {
            let context = persistentContainer.viewContext
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    let nserror = error as NSError
                    fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
                }
            }
        }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if let aps = userInfo["aps"] as? [String: AnyObject] {
            if aps["content-available"] as? Int == 1 {
                checkAndPlayAlarm()
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        }
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.scheme == "spotify-ios-quick-start" {
            SpotifyAuthorizationManager.shared.handleAuthCallback(url: url)
            return true
        }
        return false
    }
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.streamradios.playalarm", using: nil) { task in
            self.handleAlarmTask(task: task as! BGProcessingTask)
        }
    }
    
    func handleAlarmTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        checkAndPlayAlarm()
        task.setTaskCompleted(success: true)
    }
    
    func checkAndPlayAlarm() {
        if shouldTriggerAlarm() {
            radioPlayer.playFavoriteStationForAlarm()
            presentAlarmTriggeredView()
        }
    }
    
    func shouldTriggerAlarm() -> Bool {
        // Implement logic to check if it's time for an alarm
        // Compare current time with saved alarm times
        return false  // Placeholder
    }
    
    func openAppAndPlayStation() {
        DispatchQueue.main.async {
            UIApplication.shared.open(URL(string: "streamradios://openapp")!, options: [:], completionHandler: nil)
        }
    }
    
    func handleAlarmNotification(_ notification: [String: AnyObject]) {
        if let alarmIdentifier = notification["alarmIdentifier"] as? String,
           alarmIdentifier.starts(with: "wakeUpAlarm") {
            openAppAndPlayStation()
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.starts(with: "wakeUpAlarm") {
            radioPlayer.playFavoriteStationForAlarm()
        }
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["alarmType"] as? String == "streamRadiosAlarm" {
            // Present AlarmTriggeredView
            DispatchQueue.main.async {
                if let rootViewController = UIApplication.shared.windows.first?.rootViewController {
                    let alarmTriggeredView = AlarmTriggeredView()
                        .environmentObject(RadioPlayer.shared)
                        .environmentObject(RadioStationViewModel.shared)
                    let hostingController = UIHostingController(rootView: alarmTriggeredView)
                    rootViewController.present(hostingController, animated: true, completion: nil)
                }
            }
        }
        completionHandler()
    }
    
    func presentAlarmTriggeredView() {
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                let alarmTriggeredView = AlarmTriggeredView()
                    .environmentObject(self.radioPlayer)
                    .environmentObject(self.viewModel)
                let hostingController = UIHostingController(rootView: alarmTriggeredView)
                window.rootViewController?.present(hostingController, animated: true, completion: nil)
            }
        }
    }
    
    private func isFirstLaunch() -> Bool {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
            UserDefaults.standard.synchronize()
            return true
        }
        return false
    }
    
    private func deleteLocalCoreDataStore() {
        let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        if let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreDescriptions.first?.url,
           let store = coordinator.persistentStore(for: storeURL) {
            do {
                try coordinator.remove(store)
                try FileManager.default.removeItem(at: storeURL)
                recreateCoreDataStack() // Re-initialize CoreData after cleanup
                print("Successfully removed CoreData store and cleaned up local files.")
            } catch {
                print("Failed to delete CoreData store: \(error.localizedDescription)")
            }
        }
    }
    
    private func recreateCoreDataStack() {
        let container = NSPersistentContainer(name: "YourModel")
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
    }
    
    func saveFavoriteStationIndex(_ index: Int) {
        UserDefaults.standard.set(index, forKey: "FavoriteStationIndex")
    }
    
    func loadFavoriteStationIndex() -> Int? {
        return UserDefaults.standard.value(forKey: "FavoriteStationIndex") as? Int
    }
    
    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification authorization granted.")
            } else {
                print("Notification authorization denied.")
                if let error = error {
                    print("Authorization error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            print("Audio session configured successfully.")
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    private func playFavoriteStation(at index: Int) {
        DispatchQueue.main.async {
            self.radioPlayer.playStation(at: index, from: self.viewModel.stations)
        }
    }
    
    func checkBackgroundRefreshStatus() {
        if UIApplication.shared.backgroundRefreshStatus == .denied {
            print("Background refresh is disabled. Alarms may not function as expected.")
            // Consider showing an alert to the user here
        }
    }
}

extension AppDelegate {
    func handleAlarmTrigger() {
        DispatchQueue.main.async {
            self.radioPlayer.playFavoriteStationForAlarm()
            self.presentAlarmTriggeredView()
        }
    }

}
