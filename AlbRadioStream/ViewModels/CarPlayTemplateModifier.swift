//
//  CarPlayTemplateModifier.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import SwiftUI
import CarPlay

struct CarPlayTemplateModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                setupCarPlay()
            }
    }

    private func setupCarPlay() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? CPTemplateApplicationScene else {
            return
        }
        windowScene.delegate = CarPlaySceneDelegate()
    }
}

extension View {
    func carPlayTemplate() -> some View {
        self.modifier(CarPlayTemplateModifier())
    }
}

