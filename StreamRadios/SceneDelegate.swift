//
//  SceneDelegate.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/27/24.
//

import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    
    // PERFORMANCE: Throttling to prevent rapid successive app activation hangs
    private var lastBecameActiveTime: Date?
    private let becameActiveThrottleInterval: TimeInterval = 2.0 // Minimum 2 seconds between activations

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Create a SwiftUI view that provides the window contents.
        let contentView = ContentView()
        
        if let urlContext = connectionOptions.urlContexts.first {
                    handleIncomingURL(urlContext.url)
                }

        // Use a UIHostingController as window root view controller.
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: contentView) // Set the SwiftUI view as the root view.
            self.window = window
            window.makeKeyAndVisible()
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        // Handle other URL schemes if needed
    }
    
    func handleIncomingURL(_ url: URL) {
            if url.absoluteString == "streamradios://openapp" {
                // Use the same method as notification tap handling for consistency
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                    appDelegate.openAppAndPlayAlarmStation()
                } else {
                    // Fallback if AppDelegate is not available
                    RadioPlayer.shared.playFavoriteStationForAlarm()
                }
            }
        }
    
    func presentAlarmTriggeredView() {
            DispatchQueue.main.async {
                if let rootViewController = self.window?.rootViewController {
                    let alarmTriggeredView = AlarmTriggeredView()
                        .environmentObject(RadioPlayer.shared)
                        .environmentObject(RadioStationViewModel.shared)
                    let hostingController = UIHostingController(rootView: alarmTriggeredView)
                    rootViewController.present(hostingController, animated: true, completion: nil)
                }
            }
        }
    

    func sceneDidDisconnect(_ scene: UIScene) {
        // ToDo
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
        
        // Clear all notifications and reset badge count when app becomes active
        NotificationManager.shared.clearAllNotificationsAndBadge()
        
        // PERFORMANCE FIX: Throttle rapid successive activations to prevent hangs
        let now = Date()
        if let lastTime = lastBecameActiveTime,
           now.timeIntervalSince(lastTime) < becameActiveThrottleInterval {
            print("🚗 THROTTLED: Skipping CarPlay sync - too soon since last activation (\(String(format: "%.1f", now.timeIntervalSince(lastTime)))s ago)")
            return
        }
        lastBecameActiveTime = now
        
        // 🚗 CARPLAY SYNC: Asynchronous sync to CarPlay when main app becomes active
        // This ensures podcast feeds sync to CarPlay when user opens the phone app
        // CRITICAL FIX: Move all heavy operations off the main thread to prevent app hangs
        
        print("🚗 MAIN APP: DEBUG - Scene became active, triggering async CarPlay sync")
        
        // PERFORMANCE FIX: Execute all CarPlay sync operations asynchronously to prevent main thread blocking
        Task.detached(priority: .userInitiated) {
            // CRITICAL FIX: Don't reload feeds if podcast is currently playing OR if CarPlay is connected
            let podcastPlayer = PodcastPlayer.shared
            let isPodcastPlaying = podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil
            let isCarPlayConnected = CarPlayManager.shared.isCarPlayConnected
            let hasActivePodcastSession = podcastPlayer.userWantsToPlay && podcastPlayer.currentEpisode != nil
            
            // CARPLAY FIX: Don't interfere with CarPlay sessions at all
            if !isPodcastPlaying && !isCarPlayConnected && !hasActivePodcastSession {
                // 1. Force PodcastViewModel to reload on background thread (only if no podcast is playing)
                await MainActor.run {
                    PodcastViewModel.shared.loadFeedsFromCoreData()
                }
            } else {
                if isCarPlayConnected {
                    print("🚗 CARPLAY SYNC: Skipping feed reload - CarPlay is connected, not interfering with CarPlay session")
                } else if isPodcastPlaying {
                    print("🚗 CARPLAY SYNC: Skipping feed reload - podcast is currently playing to prevent restart")
                } else if hasActivePodcastSession {
                    print("🚗 CARPLAY SYNC: Skipping feed reload - active podcast session detected")
                }
            }
            
            // Small delay to prevent thread contention
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // 2. Sync via CarPlayManager on background thread (only if safe to do so)
            if !isPodcastPlaying && !isCarPlayConnected && !hasActivePodcastSession {
                await MainActor.run {
                    CarPlayManager.shared.forceRefreshPodcastData()
                }
            } else {
                if isCarPlayConnected {
                    print("🚗 CARPLAY SYNC: Skipping CarPlay refresh - CarPlay is connected, not interfering")
                } else if isPodcastPlaying {
                    print("🚗 CARPLAY SYNC: Skipping CarPlay refresh - podcast is currently playing to prevent restart")
                } else if hasActivePodcastSession {
                    print("🚗 CARPLAY SYNC: Skipping CarPlay refresh - active podcast session detected")
                }
            }
            
            // 3. Debug check after operations complete
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let feedCount = PodcastViewModel.shared.podcastFeeds.count
                    print("🚗 MAIN APP: DEBUG - After async sync, PodcastViewModel has \(feedCount) feeds")
                }
            }
        }
        
        // CARPLAY FIX: Only send sync notifications if CarPlay is not connected and no active podcast session
        let shouldSendCarPlayNotifications = !CarPlayManager.shared.isCarPlayConnected && 
                                           !(PodcastPlayer.shared.userWantsToPlay && PodcastPlayer.shared.currentEpisode != nil)
        
        if shouldSendCarPlayNotifications {
            // Set UserDefaults flag for polling-based backup
            if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
                appGroupDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlaySyncRequested")
                appGroupDefaults.set("SceneDidBecomeActive", forKey: "CarPlaySyncSource")
                // Note: synchronize() is deprecated and unnecessary
                print("🚗 CARPLAY SYNC: Set sync flag in shared UserDefaults when main app became active")
            }
            
            // Multiple notification attempts with different timings
            for delay in [0.0, 0.1, 0.3, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CarPlayRefreshRequested"),
                        object: nil,
                        userInfo: ["source": "SceneDidBecomeActive", "attempt": "\(delay)"]
                    )
                    print("🚗 CARPLAY SYNC: Sent refresh request to CarPlay (attempt \(delay)s)")
                }
            }
        } else {
            print("🚗 CARPLAY SYNC: Skipping CarPlay notifications - CarPlay is connected or active podcast session detected")
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // ToDo
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
        
        // 🚗 CARPLAY SYNC: Signal to CarPlay that podcast data needs refresh using shared UserDefaults
        // This ensures podcast feeds sync to CarPlay when app returns from background
        // CARPLAY FIX: Only send sync notifications if CarPlay is not connected and no active podcast session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let shouldSendCarPlayNotifications = !CarPlayManager.shared.isCarPlayConnected && 
                                               !(PodcastPlayer.shared.userWantsToPlay && PodcastPlayer.shared.currentEpisode != nil)
            
            if shouldSendCarPlayNotifications {
                // Use app group UserDefaults for cross-scene communication
                if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
                    appGroupDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlaySyncRequested")
                    appGroupDefaults.set("SceneWillEnterForeground", forKey: "CarPlaySyncSource")
                    // Note: synchronize() is deprecated and unnecessary
                    print("🚗 CARPLAY SYNC: Set sync flag in shared UserDefaults when app entered foreground")
                }
                
                // Also send notification as backup (in case CarPlay is in same process)
                NotificationCenter.default.post(
                    name: NSNotification.Name("CarPlayRefreshRequested"),
                    object: nil,
                    userInfo: ["source": "SceneWillEnterForeground"]
                )
                print("🚗 CARPLAY SYNC: Sent refresh request to CarPlay when app entered foreground")
            } else {
                print("🚗 CARPLAY SYNC: Skipping foreground CarPlay notifications - CarPlay is connected or active podcast session detected")
            }
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // This is often triggered when the app is force closed
        
        // Save podcast state immediately
        PodcastPlayer.shared.handleAppWillTerminate()
        (UIApplication.shared.delegate as? AppDelegate)?.updatePodcastStateAndSave()
        
        // Save Core Data context
        (UIApplication.shared.delegate as? AppDelegate)?.saveContext()
        
        // Save radio state
        RadioPlayer.shared.saveLastPlayedStation()
        
        // CRITICAL FIX: Don't suppress players if they're actively playing in background
        let radioPlayer = RadioPlayer.shared
        let podcastPlayer = PodcastPlayer.shared
        let isRadioPlaying = radioPlayer.isPlaying && radioPlayer.userWantsToPlay
        let isPodcastPlaying = podcastPlayer.isPlaying && podcastPlayer.userWantsToPlay
        
        if !(isRadioPlaying || isPodcastPlaying) {
            // Only suppress global player if neither radio nor podcast is actively playing
            UserDefaults.standard.set(true, forKey: "SuppressGlobalPlayerOnNextLaunch")
            DebugLogger.logInfo("Scene entering background with no active playback - suppressing player on next launch", category: "SceneLifecycle")
        } else {
            if isRadioPlaying {
                DebugLogger.logInfo("Scene entering background with active radio playback - preserving player state for next launch", category: "SceneLifecycle")
                DebugLogger.setUserAction("Scene Background with Radio Playing")
            }
            if isPodcastPlaying {
                let episodeTitle = podcastPlayer.currentEpisode?.title ?? "Unknown"
                DebugLogger.logInfo("Scene entering background with active podcast playback - preserving player state for next launch, Episode: \(episodeTitle)", category: "SceneLifecycle")
                DebugLogger.setUserAction("Scene Background with Podcast Playing")
            }
        }
        
        // Note: synchronize() is deprecated and unnecessary - UserDefaults saves automatically
        // Removed to fix Swift Concurrency warning
    }
}
