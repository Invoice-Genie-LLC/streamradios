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
        setupNotificationCategories()
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

    private func setupNotificationCategories() {
        // Create a category that allows for longer text display
        let fullTextCategory = UNNotificationCategory(
            identifier: "FULL_TEXT_CATEGORY",
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        // Register the category with the notification center
        UNUserNotificationCenter.current().setNotificationCategories([fullTextCategory])
    }
    
    private func configureNotificationContent(title: String, message: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        
        // If the message is long, use subtitle for better display
        if message.count > 60 {
            content.title = title
            content.subtitle = ""
            content.body = message
        } else {
            content.title = title
            content.body = message
        }
        
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "FULL_TEXT_CATEGORY"
        
        return content
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
            
            let content = self.configureNotificationContent(title: title, message: message)

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
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                return
            }
            
            let content = self.configureNotificationContent(title: title, message: message)
            
            // Use immediate trigger (0.1 seconds)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Error scheduling immediate notification: \(error.localizedDescription)")
                }
            }
        }
    }

    func scheduleNotification(title: String, message: String, date: Date) {
        let content = configureNotificationContent(title: title, message: message)

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
    
    // MARK: - Badge and Delivered Notification Management
    
    /// Clears all delivered notifications and resets the app badge count
    func clearAllNotificationsAndBadge() {
        // Remove all delivered notifications from notification center
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        // Remove all pending notifications
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
        // Reset app badge count to 0
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
    
    /// Resets only the app badge count without removing notifications
    func resetBadgeCount() {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
            print("🔢 Badge count reset to 0")
        }
    }
    
    /// Clears only delivered notifications without affecting badge or pending notifications
    func clearDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        print("📱 Delivered notifications cleared")
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // This method is called when a notification is delivered to a foreground app
        print("🔔 Foreground notification received: \(notification.request.content.title)")
        
        // Show notification even when app is in foreground with full content
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
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
