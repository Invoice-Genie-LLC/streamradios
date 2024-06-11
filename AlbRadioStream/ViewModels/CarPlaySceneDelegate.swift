//  CarPlaySceneDelegate.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        self.interfaceController = interfaceController
        let rootTemplate = createRootTemplate()
        interfaceController.setRootTemplate(rootTemplate, animated: true)
    }

    private func createRootTemplate() -> CPTemplate {
        let item1 = CPListItem(text: "Station 1", detailText: "Genre: Pop")
        item1.handler = { item, completion in
            self.showNowPlaying()
            completion()
        }
        
        let item2 = CPListItem(text: "Station 2", detailText: "Genre: Rock")
        item2.handler = { item, completion in
            self.showNowPlaying()
            completion()
        }

        let listTemplate = CPListTemplate(title: "Radio Stations", sections: [CPListSection(items: [item1, item2])])
        return listTemplate
    }

    private func showNowPlaying() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        interfaceController?.presentTemplate(nowPlayingTemplate, animated: true)
    }
}
