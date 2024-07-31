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

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    var window: UIWindow?
    var radioPlayer = RadioPlayer.shared
    var viewModel = RadioStationViewModel.shared
    
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
               radioPlayer.isHandlingAlarm = true
               handleAlarmTrigger()
           } else {
               // Normal app launch, proceed with auto-play if enabled
               radioPlayer.autoPlayLastStationSetup()
           }
        
        return true
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
        if response.notification.request.identifier.starts(with: "wakeUpAlarm") {
            print("Alarm triggered, playing favorite station")
            radioPlayer.playFavoriteStationForAlarm()
            presentAlarmTriggeredView()
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
