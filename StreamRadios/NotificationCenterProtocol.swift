//
//  NotificationCenterProtocol.swift
//  StreamRadios
//
//  Created by Kley Sulo on 9/14/24.
//

import UserNotifications

protocol NotificationCenterProtocol {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?)
    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeAllPendingNotificationRequests()
    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void)
    func removeAllDeliveredNotifications()
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

protocol NotificationSettingsProtocol {
    var authorizationStatus: UNAuthorizationStatus { get }
}

extension UNUserNotificationCenter: NotificationCenterProtocol {
    func getNotificationSettings(completionHandler: @escaping (NotificationSettingsProtocol) -> Void) {
        self.getNotificationSettings { settings in
            completionHandler(ActualNotificationSettings(settings: settings))
        }
    }
}

struct ActualNotificationSettings: NotificationSettingsProtocol {
    let settings: UNNotificationSettings
    
    var authorizationStatus: UNAuthorizationStatus {
        return settings.authorizationStatus
    }
}

// Mock implementation
class MockNotificationCenter: NotificationCenterProtocol {
    var addedRequests: [UNNotificationRequest] = []
    var deliveredNotifications: [UNNotification] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        completionHandler(addedRequests)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        addedRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func removeAllPendingNotificationRequests() {
        addedRequests.removeAll()
    }

    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {
        completionHandler(deliveredNotifications)
    }

    func removeAllDeliveredNotifications() {
        deliveredNotifications.removeAll()
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredNotifications.removeAll { identifiers.contains($0.request.identifier) }
    }
}

struct MockNotificationSettings: NotificationSettingsProtocol {
    let authorizationStatus: UNAuthorizationStatus
}
