//
//  SoundVisualizerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/28/24.
//

import SwiftUI

struct SoundVisualizerView: View {
    @State private var animationAmount = [CGFloat](repeating: 1.0, count: 8) // Reduced number of circles
    private let numberOfCircles = 8
    private let circleSize: CGFloat = 15.0 // Diameter of the circles
    private let circleSpacing: CGFloat = 10.0

    var body: some View {
        HStack(spacing: circleSpacing) {
            ForEach(0..<numberOfCircles, id: \.self) { i in
                Circle()
                    .fill(Color.primary)
                    .frame(width: circleSize, height: circleSize)
                    .scaleEffect(animationAmount[i])
                    .animation(Animation.easeInOut(duration: Double.random(in: 1.0...1.5)).repeatForever(autoreverses: true), value: animationAmount[i])
                    .offset(y: animationAmount[i] * -8) // Adjusted offset for better visual effect
            }
        }
        .onAppear {
            startAnimating()
        }
    }

    private func startAnimating() {
        for i in 0..<numberOfCircles {
            animationAmount[i] = CGFloat.random(in: 0.5...1.5)
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in // Throttled update frequency
            for i in 0..<numberOfCircles {
                animationAmount[i] = CGFloat.random(in: 0.5...1.5)
            }
        }
    }
}

struct SoundVisualizerView_Previews: PreviewProvider {
    static var previews: some View {
        SoundVisualizerView()
            .frame(height: 40)
    }
}
