//
//  BackgroundTaskManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/14/24.
//

import Foundation
import BackgroundTasks
import UserNotifications

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    private var isRegistered = false
    
    init() {
        registerBackgroundTasks()
        registerLocalNotifications()
    }
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.radio.streamradios.backgroundfetch", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        print("Background tasks registered.")
    }

    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        /*
        // Perform the CloudKit sync operation
        RadioStationViewModel.shared.syncStationsWithCloudKit { success in
            task.setTaskCompleted(success: success)
            if success {
                self.scheduleCompletionNotification(message: "CloudKit sync completed.")
            }
        }
         */
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.radio.streamradios.backgroundfetch")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // Schedule after 1 hour
        do {
            try BGTaskScheduler.shared.submit(request)
            print("App refresh scheduled.")
        } catch {
            print("Failed to schedule app refresh: \(error)")
        }
    }
    
     func registerLocalNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                print("Notification permissions granted.")
            } else {
                print("Notification permission denied.")
            }
        }
    }
    
    func scheduleCompletionNotification(message: String) {
            let content = UNMutableNotificationContent()
            content.title = "Attention Needed"
            content.body = message
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error scheduling notification: \(error.localizedDescription)")
                }
            }
        }
}
