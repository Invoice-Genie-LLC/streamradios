//
//  SceneDelegate.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import UIKit
import SwiftUI
import CarPlay

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: ContentView().carPlayTemplate())
            self.window = window
            window.makeKeyAndVisible()
        }
    }
}
