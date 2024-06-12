//
//  OrientationLock.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/12/24.
//

import SwiftUI

extension UIApplication {
    var appDelegate: AppDelegate {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            fatalError("Could not cast AppDelegate")
        }
        return delegate
    }

    func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = orientation
    }

    func lockOrientation(_ orientation: UIInterfaceOrientationMask, andRotateTo rotateOrientation: UIInterfaceOrientation) {
        self.lockOrientation(orientation)

        if let windowScene = self.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            let currentOrientation = UIDevice.current.orientation
            if currentOrientation != .portrait {
                let value = rotateOrientation.rawValue
                UIDevice.current.setValue(value, forKey: "orientation")
                rootViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
