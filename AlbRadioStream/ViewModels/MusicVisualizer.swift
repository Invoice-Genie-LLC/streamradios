//
//  MusicVisualizer.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import SwiftUI

struct MusicVisualizer: View {
    @Binding var audioLevel: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule()
                    .fill(LinearGradient(gradient: Gradient(colors: [.blue, .green]), startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: CGFloat(max(10, Double(audioLevel + 50) * 2)))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .animation(.linear(duration: 0.1), value: audioLevel)
            }
        }
    }
}
