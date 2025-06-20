//
//  BackgroundTaskManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/14/24.
//

import Foundation
import BackgroundTasks
import UserNotifications
import AVFoundation
import os.log

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    private var isRegistered = false
    private let log = OSLog(subsystem: "com.streamradios.background", category: "TaskManager")
    
    // iTunes Artwork Fetching for CarPlay
    private var isCarPlayArtworkFetchingEnabled = false
    
    init() {
        // Only register local notifications here
        // Background task registration will be handled by AppDelegate
        registerLocalNotifications()
    }
    
    func registerBackgroundTasks() {
        // Prevent multiple registrations
        guard !isRegistered else {
            print("⚠️ Background tasks already registered, skipping duplicate registration")
            return
        }
        
        // Existing background fetch task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.radio.streamradios.backgroundfetch", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        
        // NEW: CarPlay iTunes artwork fetching task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.radio.streamradios.carplay.artwork", using: nil) { task in
            self.handleCarPlayArtworkFetch(task: task as! BGAppRefreshTask)
        }
        
        isRegistered = true
        print("✅ Background tasks registered (including CarPlay artwork fetching).")
    }
    
    // MARK: - Enhanced CarPlay Artwork Fetching
    
    func enableCarPlayArtworkFetching() {
        guard isRegistered else {
            os_log("🚗 CarPlay: Cannot enable artwork fetching - background tasks not registered", log: log, type: .error)
            return
        }
        
        isCarPlayArtworkFetchingEnabled = true
        scheduleCarPlayArtworkTask()
        os_log("🚗 CarPlay: Enhanced iTunes artwork fetching enabled", log: log, type: .info)
    }
    
    func disableCarPlayArtworkFetching() {
        isCarPlayArtworkFetchingEnabled = false
        
        // Cancel any pending artwork tasks
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.radio.streamradios.carplay.artwork")
        os_log("🚗 CarPlay: Enhanced iTunes artwork fetching disabled", log: log, type: .info)
    }
    
    private func scheduleCarPlayArtworkTask() {
        let request = BGAppRefreshTaskRequest(identifier: "com.radio.streamradios.carplay.artwork")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30) // Schedule every 30 seconds for artwork
        
        do {
            try BGTaskScheduler.shared.submit(request)
            os_log("🚗 CarPlay: Artwork fetch task scheduled", log: log, type: .info)
        } catch {
            os_log("🚗 CarPlay: Failed to schedule artwork task: %@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func handleCarPlayArtworkFetch(task: BGAppRefreshTask) {
        os_log("🚗 CarPlay: Background artwork fetch task started", log: log, type: .info)
        
        task.expirationHandler = {
            os_log("🚗 CarPlay: Background artwork task expired", log: self.log, type: .info)
            task.setTaskCompleted(success: false)
        }
        
        // Only proceed if CarPlay is connected and radio is playing
        guard CarPlayManager.shared.isCarPlayConnected else {
            os_log("🚗 CarPlay: Not connected - skipping artwork fetch", log: log, type: .info)
            task.setTaskCompleted(success: true)
            return
        }
        
        let radioPlayer = RadioPlayer.shared
        guard radioPlayer.isPlaying, let metadata = radioPlayer.metadata, !metadata.isEmpty else {
            os_log("🚗 CarPlay: No active playback or metadata - skipping artwork fetch", log: log, type: .info)
            task.setTaskCompleted(success: true)
            return
        }
        
        // Check if we already have artwork for this track
        if radioPlayer.iTunesAlbumArt != nil {
            os_log("🚗 CarPlay: Artwork already exists for current track", log: log, type: .info)
            task.setTaskCompleted(success: true)
            self.scheduleCarPlayArtworkTask() // Reschedule for next check
            return
        }
        
        // Perform iTunes artwork search in background
        os_log("🚗 CarPlay: Fetching iTunes artwork for: %@", log: log, type: .info, metadata)
        
        DispatchQueue.global(qos: .background).async {
            self.performBackgroundArtworkFetch(metadata: metadata) { success in
                if success {
                    os_log("🚗 CarPlay: Background artwork fetch completed successfully", log: self.log, type: .info)
                } else {
                    os_log("🚗 CarPlay: Background artwork fetch failed", log: self.log, type: .error)
                }
                
                task.setTaskCompleted(success: success)
                
                // Reschedule for continuous monitoring if CarPlay is still active
                if self.isCarPlayArtworkFetchingEnabled && CarPlayManager.shared.isCarPlayConnected {
                    self.scheduleCarPlayArtworkTask()
                }
            }
        }
    }
    
    private func performBackgroundArtworkFetch(metadata: String, completion: @escaping (Bool) -> Void) {
        let radioPlayer = RadioPlayer.shared
        
        // Use the RadioPlayer's existing iTunes search logic
        radioPlayer.searchITunesForArtwork(metadata: metadata) { image in
            DispatchQueue.main.async {
                if let image = image {
                    radioPlayer.iTunesAlbumArt = image
                    radioPlayer.saveITunesArtworkToCurrentStation(image)
                    radioPlayer.updateNowPlayingInfo()
                    radioPlayer.updateWidget()
                    
                    // Notify CarPlay of the artwork update
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CarPlayArtworkUpdated"),
                        object: nil,
                        userInfo: ["metadata": metadata, "hasArtwork": true]
                    )
                    
                    completion(true)
                } else {
                    os_log("🚗 CarPlay: No iTunes artwork found for metadata: %@", log: self.log, type: .info, metadata)
                    completion(false)
                }
            }
        }
    }
    
    // MARK: - Original Background Task Handling
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // Enhanced refresh to include CarPlay artwork if needed
        if CarPlayManager.shared.isCarPlayConnected && RadioPlayer.shared.isPlaying {
            if let metadata = RadioPlayer.shared.metadata, !metadata.isEmpty, RadioPlayer.shared.iTunesAlbumArt == nil {
                performBackgroundArtworkFetch(metadata: metadata) { success in
                    task.setTaskCompleted(success: success)
                }
                return
            }
        }
        
        task.setTaskCompleted(success: true)
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
