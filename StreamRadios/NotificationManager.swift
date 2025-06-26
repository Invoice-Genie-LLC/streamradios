//
//  NotificationManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/15/24.
//

import Foundation
import UserNotifications
import UIKit
import Combine

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()
    
    @Published var lastNotificationTitle: String?
    @Published var lastNotificationMessage: String?
    @Published var isAuthorized: Bool = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        checkAuthorizationStatus()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if granted {
                    print("Notification permissions granted.")
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    print("Notification permission denied by user.")
                    if let error = error {
                        print("Error requesting authorization: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    func notifyUser(title: String, message: String) {
        // Check if we're authorized to send notifications
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("🔔 Notification Authorization Status: \(settings.authorizationStatus.rawValue)")
            print("🔔 Attempting to send notification: \(title) - \(message)")
            
            guard settings.authorizationStatus == .authorized else {
                print("❌ Notifications not authorized. Status: \(settings.authorizationStatus.rawValue)")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = UNNotificationSound.default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("❌ Error scheduling notification: \(error.localizedDescription)")
                    } else {
                        print("✅ Notification scheduled successfully: \(title)")
                        self?.lastNotificationTitle = title
                        self?.lastNotificationMessage = message
                    }
                }
            }
        }
    }
    
    // Alternative method for immediate notifications that works better for operations
    func notifyUserImmediate(title: String, message: String) {
        print("🔔 Immediate notification: \(title) - \(message)")
        
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("❌ Immediate notification failed - not authorized")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = UNNotificationSound.default
            
            // Use immediate trigger (0.1 seconds)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Error scheduling immediate notification: \(error.localizedDescription)")
                } else {
                    print("✅ Immediate notification scheduled: \(title)")
                }
            }
        }
    }

    func scheduleNotification(title: String, message: String, date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = UNNotificationSound.default

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error.localizedDescription)")
            }
        }
    }

    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func cancelNotification(withIdentifier identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // This method is called when a notification is delivered to a foreground app
        print("🔔 Foreground notification received: \(notification.request.content.title)")
        
        // Show notification even when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // This method is called to let your app know which action was selected by the user for a given notification
        let userInfo = response.notification.request.content.userInfo
        
        // Handle the received notification
        print("Received notification with user info: \(userInfo)")
        
        completionHandler()
    }
}
