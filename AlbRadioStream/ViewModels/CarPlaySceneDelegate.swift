//  CarPlaySceneDelegate.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import CarPlay
import SwiftUI

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        let gridTemplate = CPGridTemplate(title: "Radio Stream", gridButtons: [
            CPGridButton(titleVariants: ["Play"], image: UIImage(systemName: "play.circle")!) { _ in
                RadioPlayer.shared.playPause()
            }
        ])
        
        interfaceController.setRootTemplate(gridTemplate, animated: true, completion: nil)
    }
}
