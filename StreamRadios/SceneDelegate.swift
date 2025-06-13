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
        let handled = SpotifyAuthorizationManager.shared.handleAuthCallback(url: url)
        if handled {
            print("Handled Spotify auth callback")
        }
    }
    
    func handleIncomingURL(_ url: URL) {
            if url.absoluteString == "streamradios://openapp" {
                RadioPlayer.shared.playFavoriteStationForAlarm()
                presentAlarmTriggeredView()
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
        // ToDo
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // ToDo
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // ToDo
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
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
        
        // Force synchronize UserDefaults
        UserDefaults.standard.synchronize()
    }
}
