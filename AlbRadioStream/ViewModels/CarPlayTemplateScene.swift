//
//  CarPlayTemplateScene.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import CarPlay
import SwiftUI

struct CarPlayTemplateScene: UIViewControllerRepresentable {
    var interfaceController: CPInterfaceController?

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        
        let carPlayTemplate = CPGridTemplate(title: "Radio Stream", gridButtons: [
            CPGridButton(titleVariants: ["Play"], image: UIImage(systemName: "play.circle")!) { _ in
                // Handle Play button action
                RadioPlayer.shared.playPause()
                print("Play button tapped")
            }
        ])
        
        interfaceController?.setRootTemplate(carPlayTemplate, animated: true, completion: nil)
        
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
