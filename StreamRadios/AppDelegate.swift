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
import MediaPlayer
import CloudKit

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    var window: UIWindow?
       var radioPlayer = RadioPlayer.shared
       var podcastPlayer = PodcastPlayer.shared
       var viewModel = RadioStationViewModel.shared
        var podcastViewModel = PodcastViewModel()
    
    private var shouldPlayAlarmStationOnReady = false
    private var pendingAlarmStationID: String?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                    // Initialize enhanced crash logging first
        initializeEnhancedCrashLogging()
            
            if isFirstLaunch() {
                deleteLocalCoreDataStore()
            }
            
            UNUserNotificationCenter.current().delegate = self
            requestNotificationAuthorization()
            registerBackgroundTasks()
            configureAudioSession()
            setupCarPlay()
            
            let alarmCategory = UNNotificationCategory(identifier: "ALARM_CATEGORY", actions: [], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories([alarmCategory])
            
            application.registerForRemoteNotifications()
            
            // Initialize enhanced CloudKit sync for cross-device sync notifications
            _ = PodcastCloudKitManager.shared
            _ = RadioStationCloudKitManager.shared
            
            // Prewarm EpisodeStateManager to avoid cold-start race conditions for UI
            _ = EpisodeStateManager.shared
            print("🔥 Prewarmed EpisodeStateManager at launch; isReady=\(EpisodeStateManager.shared.isReady)")
            print("📡 Enhanced CloudKit sync initialized for podcasts and radio stations")
            
            checkBackgroundRefreshStatus()
            
            // Check if the app was launched due to an alarm
            if let launchOptions = launchOptions,
               launchOptions[UIApplication.LaunchOptionsKey.location] != nil {
                // App was launched due to an alarm, play the alarm station
                radioPlayer.playFavoriteStationForAlarm()
            } else {
                // Normal app launch: Do not auto-load or display the last station; wait for user action
                // If previously requested, ensure suppression flag is cleared after honoring it
                if UserDefaults.standard.bool(forKey: "SuppressGlobalPlayerOnNextLaunch") {
                    UserDefaults.standard.set(false, forKey: "SuppressGlobalPlayerOnNextLaunch")
                }
            }
            
            // Log successful app launch  
            DebugLogger.logInfo("App launched successfully", category: "AppLifecycle")
            DebugLogger.setUserAction("App Launch Completed")
            
            return true
        }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Log app termination for crash analysis
        DebugLogger.logCritical("App will terminate - saving all state", category: "AppLifecycle")
        DebugLogger.setUserAction("App Termination")
        
        // Immediately save current state when app is terminated
        updatePodcastStateAndSave()
        PodcastPlayer.shared.handleAppWillTerminate()
        podcastViewModel.saveContextIfNeeded()
        // Request that global player be suppressed on next launch
        UserDefaults.standard.set(true, forKey: "SuppressGlobalPlayerOnNextLaunch")
        
        // Force synchronize UserDefaults to ensure data persistence
        UserDefaults.standard.synchronize()
        
        // Final crash log save
        DebugLogger.logInfo("App termination completed successfully", category: "AppLifecycle")
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        // Log potential force close scenario
        DebugLogger.logWarning("App will resign active - potential force close", category: "AppLifecycle")
        DebugLogger.setUserAction("App Resign Active")
        
        // Save state immediately when app resigns active status (might be force closed)
        updatePodcastStateAndSave()
        PodcastPlayer.shared.handleAppWillTerminate()
        // Prepare to suppress global player if the app is swiped away shortly after
        UserDefaults.standard.set(true, forKey: "SuppressGlobalPlayerOnNextLaunch")
        
        // Force synchronize to persist data
        UserDefaults.standard.synchronize()
    }

        func updatePodcastStateAndSave() {
            if let currentEpisode = podcastPlayer.currentEpisode {
                let currentProgress = PodcastPlayer.shared.currentProgress
                
                // Update progress locally
                podcastViewModel.updateProgress(for: currentEpisode, progress: currentProgress)
                
                // CRITICAL FIX: Use currentProgress instead of recalculating to preserve chapter seek progress
                let progress = currentProgress > 0 ? currentProgress : (podcastPlayer.duration > 0 ? podcastPlayer.currentTime / podcastPlayer.duration : 0)
                Task.detached(priority: .userInitiated) {
                    await self.podcastViewModel.updateEpisodeState(currentEpisode.id, progress: progress, isPlayed: progress >= 0.99)
                }
                
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
                        Task {
                            await podcastViewModel.deleteDownloadedEpisode(currentEpisode)
                        }
                    }
                }
            }
            
            // CRITICAL: Synchronize ALL download states during force close protection
            synchronizeAllDownloadStates()
            
            // CRITICAL FIX: Core Data saves happen automatically, just ensure final sync
            // No need to force save since Core Data is now the primary storage
            
            // Save context and force synchronize
            podcastViewModel.saveContextIfNeeded()
        }
        
        /// Synchronize all download states between Core Data and EpisodeStateManager during force close
        private func synchronizeAllDownloadStates() {
            let context = CoreDataStack.shared.context
            context.performAndWait {
                do {
                    // Get all downloaded episodes from Core Data
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
                    
                    let downloadedEpisodes = try context.fetch(fetchRequest)
                    
                    print("🔄 Force close sync: Found \(downloadedEpisodes.count) downloaded episodes in Core Data")
                    
                    for managedEpisode in downloadedEpisodes {
                        guard let episodeId = managedEpisode.id else { continue }
                        
                        // Verify file still exists
                        var fileExists = false
                        if let localPath = managedEpisode.localFilePath, !localPath.isEmpty {
                            fileExists = FileManager.default.fileExists(atPath: localPath)
                        }
                        
                        if fileExists {
                            // File exists, ensure EpisodeStateManager knows about it
                            EpisodeStateManager.shared.setDownloadedWithProtection(episodeId, isDownloaded: true, reason: "force_close_sync")
                            print("✅ Synced download state for episode: \(managedEpisode.title ?? "Unknown")")
                        } else {
                            // UPGRADE PROTECTION: Be more conservative about cleaning up missing files
                            let isUpgradeScenario = EpisodeStateManager.shared.isUpgradeScenario()
                            if isUpgradeScenario {
                                print("⚠️ Force close sync: File missing during upgrade - preserving download state for: \(managedEpisode.title ?? "Unknown")")
                                // Keep the download state in EpisodeStateManager but clean up file path
                                managedEpisode.localFilePath = nil
                                // Don't change isDownloaded in Core Data during upgrades
                            } else {
                                // Normal operation: File missing - safe to clean up
                                managedEpisode.isDownloaded = false
                                managedEpisode.localFilePath = nil
                                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                                print("🧹 Cleaned up missing download for episode: \(managedEpisode.title ?? "Unknown")")
                            }
                        }
                    }
                    
                    // Save Core Data changes
                    try context.save()
                    
                    // Core Data saves happen automatically, no need to force save
                    // Data is already persisted in Core Data
                    
                    print("✅ Force close download sync completed successfully")
                    
                } catch {
                    print("❌ Error during force close download sync: \(error)")
                }
            }
        }

     func applicationDidEnterBackground(_ application: UIApplication) {
         // Log background transition for crash context
         DebugLogger.logInfo("App entered background", category: "AppLifecycle")
         DebugLogger.setUserAction("App Background")
         
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
        print("📡 🔔 REMOTE NOTIFICATION: Received remote notification")
        print("📡 📝 UserInfo: \(userInfo)")
        
        // Check if this is a CloudKit notification
        if let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            print("📡 ☁️ CLOUDKIT NOTIFICATION: Detected CloudKit notification")
            
            // Handle CloudKit notification asynchronously
            Task {
                // ENHANCED ROUTING: Route notifications to the correct manager based on content
                await routeCloudKitNotification(userInfo)
                
                completionHandler(.newData)
            }
            return
        }
        
        // Handle existing alarm notifications
        if let aps = userInfo["aps"] as? [String: AnyObject] {
            if aps["content-available"] as? Int == 1 {
                checkAndPlayAlarm()
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        } else {
            completionHandler(.noData)
        }
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        // Handle other URL schemes if needed
        return false
    }
    
    func registerBackgroundTasks() {
        // Register all background tasks during app launch
        // This is required by iOS - all registrations must happen before app finishes launching
        
        // Alarm task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.streamradios.playalarm", using: nil) { task in
            self.handleAlarmTask(task: task as! BGProcessingTask)
        }
        
        // Register BackgroundTaskManager tasks
        BackgroundTaskManager.shared.registerBackgroundTasks()
        
        print("✅ All background tasks registered during app launch")
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
            // Use the same consistent behavior for foreground notifications
            openAppAndPlayAlarmStation()
        }
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["alarmType"] as? String == "streamRadiosAlarm" {
            // Instead of presenting AlarmTriggeredView, open app and play the station
            DispatchQueue.main.async {
                self.openAppAndPlayAlarmStation()
            }
        }
        completionHandler()
    }
    
    func openAppAndPlayAlarmStation() {
        print("🚨 Opening app and attempting to play alarm station...")
        
        // Get the alarm station ID first
        guard let favoriteStationID = UserDefaults.standard.string(forKey: "FavoriteStationID") else {
            print("❌ No FavoriteStationID found for alarm")
            return
        }
        
        // Store the pending alarm station ID
        pendingAlarmStationID = favoriteStationID
        shouldPlayAlarmStationOnReady = true
        
        // Try to play immediately if stations are already loaded
        if !viewModel.stations.isEmpty {
            playPendingAlarmStation()
        } else {
            print("⏳ Stations not loaded yet, will play when ready...")
            // The station will be played when viewModel finishes loading
            // We'll set up an observer for this
            setupStationLoadObserver()
        }
    }
    
    private func playPendingAlarmStation() {
        guard shouldPlayAlarmStationOnReady,
              let alarmStationID = pendingAlarmStationID,
              let favoriteStation = viewModel.stations.first(where: { $0.id == alarmStationID }),
              let stationIndex = viewModel.stations.firstIndex(where: { $0.id == alarmStationID }) else {
            print("❌ Cannot play pending alarm station - missing data")
            return
        }
        
        print("🚨 Playing alarm station: \(favoriteStation.name)")
        
        // Clear the pending flags
        shouldPlayAlarmStationOnReady = false
        pendingAlarmStationID = nil
        
        // Navigate to radio tab and appropriate sub-tab first
        navigateToStationLocation(station: favoriteStation)
        
        // Add delay to ensure navigation is complete and app is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            print("🎵 Starting playback for alarm station: \(favoriteStation.name)")
            
            // Ensure the RadioPlayer has the updated station list
            self.radioPlayer.setViewModel(self.viewModel)
            
            // Play the station
            self.radioPlayer.playStation(at: stationIndex, from: self.viewModel.stations)
            
            // Verify playback started
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.radioPlayer.isPlaying && self.radioPlayer.currentlyPlayingStation?.id == alarmStationID {
                    print("✅ Alarm station playback confirmed: \(favoriteStation.name)")
                } else {
                    print("❌ Alarm station playback failed - retrying...")
                    self.radioPlayer.playStation(at: stationIndex, from: self.viewModel.stations)
                }
            }
        }
    }
    
    private func setupStationLoadObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StationsLoaded"), 
            object: nil, 
            queue: .main
        ) { [weak self] _ in
            print("📻 Stations loaded - checking for pending alarm...")
            if self?.shouldPlayAlarmStationOnReady == true {
                self?.playPendingAlarmStation()
            }
        }
    }
    
    func navigateToStationLocation(station: RadioStation) {
        // Post notification to navigate to the appropriate location in the app
        let navigationInfo: [String: Any] = [
            "stationId": station.id,
            "stationCountry": station.country,
            "isFavorite": station.isFavorite
        ]
        
        NotificationCenter.default.post(
            name: NSNotification.Name("NavigateToAlarmStation"), 
            object: nil, 
            userInfo: navigationInfo
        )
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
        // Audio session configuration is now handled by PlaybackManager
        // This ensures centralized management and prevents conflicts
        print("Audio session configuration delegated to PlaybackManager")
    }
    
    private func setupCarPlay() {
        // CarPlay is now handled by CarPlaySceneDelegate
        // The old MPPlayableContentDataSource approach is disabled
        
        // Configure podcast data for CarPlay and ensure data is loaded
        let carPlayManager = CarPlayManager.shared
        carPlayManager.configurePodcastData(podcastViewModel.podcastFeeds)
        
        // Ensure radio station data is available for CarPlay
        carPlayManager.updateContent()
        
        print("CarPlay will be configured via CarPlaySceneDelegate.")
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
    
    // MARK: - Enhanced CloudKit Notification Routing
    
    /// Intelligently route CloudKit notifications to the appropriate manager
    private func routeCloudKitNotification(_ userInfo: [AnyHashable: Any]) async {
        print("📡 🔄 NOTIFICATION ROUTER: Analyzing CloudKit notification...")
        
        // Extract subscription ID from the CloudKit notification
        if let ckInfo = userInfo["ck"] as? [String: Any],
           let qry = ckInfo["qry"] as? [String: Any],
           let subscriptionId = qry["sid"] as? String {
            
            print("📡 🔄 NOTIFICATION ROUTER: Found subscription ID: \(subscriptionId)")
            
            switch subscriptionId {
            case "RadioStationSubscription":
                print("📡 📻 NOTIFICATION ROUTER: Routing to RadioStationCloudKitManager")
                await RadioStationCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
                
            case "PodcastFeedSubscription", "EpisodeStateSubscription":
                print("📡 🎧 NOTIFICATION ROUTER: Routing to PodcastCloudKitManager")
                await PodcastCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
                
            default:
                print("📡 ⚠️ NOTIFICATION ROUTER: Unknown subscription ID: \(subscriptionId), trying both managers")
                // Fallback: try both managers (for unknown subscription types)
                await PodcastCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
                await RadioStationCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
            }
        } else {
            print("📡 ⚠️ NOTIFICATION ROUTER: No subscription ID found, trying both managers")
            // Fallback: if we can't determine the type, try both managers
            await PodcastCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
            await RadioStationCloudKitManager.shared.handleCloudKitSubscriptionNotification(userInfo)
        }
    }
    
    // MARK: - Enhanced Crash Logging Integration (Temporarily Disabled)
    
    /*
    private func initializeEnhancedCrashLogging() {
        // Initialize the DebugLogger to set up crash reporting
        _ = DebugLogger.shared
        
        // Start main thread monitoring for hang detection
        DebugLogger.startMainThreadMonitoring()
        
        // Set up additional crash context
        setupCrashContext()
        
        DebugLogger.logInfo("Enhanced crash logging initialized with comprehensive monitoring", category: "CrashReporting")
    }
    
    private func setupCrashContext() {
        // Set up notification observers for crash context
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RadioPlaybackStarted"),
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.setUserAction("Radio Playback Started")
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastPlaybackStarted"),
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.setUserAction("Podcast Playback Started")
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.logInfo("App became active", category: "AppLifecycle")
            DebugLogger.setUserAction("App Became Active")
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.logWarning("Memory warning received", category: "MemoryWarning")
            DebugLogger.setUserAction("Memory Warning")
        }
    }
    */
    
    // MARK: - Enhanced Crash Logging Integration
    
    private func initializeEnhancedCrashLogging() {
        do {
            // Initialize the DebugLogger to set up crash reporting
            print("🔧 Initializing DebugLogger...")
            _ = DebugLogger.shared
            print("🔧 DebugLogger shared instance created successfully")
            
            // Start main thread monitoring for hang detection
            DebugLogger.startMainThreadMonitoring()
            
            // Set up additional crash context
            setupCrashContext()
            
            DebugLogger.logInfo("Enhanced crash logging initialized with comprehensive monitoring", category: "CrashReporting")
            print("🔧 Enhanced crash logging fully initialized")
        } catch {
            print("❌ Failed to initialize DebugLogger: \(error)")
            // Continue without crash logging rather than crashing the app
        }
    }
    
    private func setupCrashContext() {
        // Set up notification observers for crash context
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RadioPlaybackStarted"),
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.setUserAction("Radio Playback Started")
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PodcastPlaybackStarted"),
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.setUserAction("Podcast Playback Started")
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.logInfo("App became active", category: "AppLifecycle")
            DebugLogger.setUserAction("App Became Active")
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            DebugLogger.logWarning("Memory warning received", category: "MemoryWarning")
            DebugLogger.setUserAction("Memory Warning")
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
