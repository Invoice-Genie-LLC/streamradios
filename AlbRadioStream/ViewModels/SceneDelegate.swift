// SceneDelegate.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/8/24.
//

import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        let contentView = ContentView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())

        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: contentView)
            self.window = window
            window.makeKeyAndVisible()
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if UserDefaults.standard.bool(forKey: "autoPlayLastStation"),
           let lastStationURL = UserDefaults.standard.url(forKey: "lastStationURL") {
            RadioPlayer.shared.setStationURL(lastStationURL)
            RadioPlayer.shared.play()
        }
    }
}
