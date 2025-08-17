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
        
        // 🚗 CARPLAY SYNC: Immediate and aggressive sync to CarPlay when main app becomes active
        // This ensures podcast feeds sync to CarPlay when user opens the phone app
        
        // AGGRESSIVE SYNC: Force immediate data refresh for CarPlay
        print("🚗 MAIN APP: DEBUG - Scene became active, triggering aggressive CarPlay sync")
        
        // 1. Force PodcastViewModel to reload immediately
        PodcastViewModel.shared.loadFeedsFromCoreData()
        
        // 2. Immediate sync attempt via CarPlayManager
        CarPlayManager.shared.forceRefreshPodcastData()
        
        // 3. Debug check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let feedCount = PodcastViewModel.shared.podcastFeeds.count
            print("🚗 MAIN APP: DEBUG - After aggressive sync, PodcastViewModel has \(feedCount) feeds")
        }
        
        // Set UserDefaults flag for polling-based backup
        if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
            appGroupDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlaySyncRequested")
            appGroupDefaults.set("SceneDidBecomeActive", forKey: "CarPlaySyncSource")
            appGroupDefaults.synchronize()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Use app group UserDefaults for cross-scene communication
            if let appGroupDefaults = UserDefaults(suiteName: "group.streamradios") {
                appGroupDefaults.set(Date().timeIntervalSince1970, forKey: "CarPlaySyncRequested")
                appGroupDefaults.set("SceneWillEnterForeground", forKey: "CarPlaySyncSource")
                appGroupDefaults.synchronize()
                print("🚗 CARPLAY SYNC: Set sync flag in shared UserDefaults when app entered foreground")
            }
            
            // Also send notification as backup (in case CarPlay is in same process)
            NotificationCenter.default.post(
                name: NSNotification.Name("CarPlayRefreshRequested"),
                object: nil,
                userInfo: ["source": "SceneWillEnterForeground"]
            )
            print("🚗 CARPLAY SYNC: Sent refresh request to CarPlay when app entered foreground")
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
        // Request that global player be suppressed on next launch
        UserDefaults.standard.set(true, forKey: "SuppressGlobalPlayerOnNextLaunch")
        
        // Force synchronize UserDefaults
        UserDefaults.standard.synchronize()
    }
}
