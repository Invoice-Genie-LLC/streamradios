//
//  SoundVisualizerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/28/24.
//

import SwiftUI

struct SoundVisualizerView: View {
    @State private var animationAmount = [CGFloat](repeating: 0.0, count: 30) // Increased number of bars for wider view
    private let numberOfBars = 30
    private let barWidth: CGFloat = 4.0
    private let barSpacing: CGFloat = 2.0

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<numberOfBars, id: \.self) { i in
                Capsule()
                    .fill(Color.gray)
                    .frame(width: barWidth, height: animationAmount[i])
                    .animation(Animation.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: animationAmount[i])
            }
        }
        .onAppear {
            startAnimating()
        }
    }

    private func startAnimating() {
        for i in 0..<numberOfBars {
            animationAmount[i] = CGFloat.random(in: 5...30) // Further reduced height range
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            for i in 0..<numberOfBars {
                animationAmount[i] = CGFloat.random(in: 5...30) // Further reduced height range
            }
        }
    }
}

struct SoundVisualizerView_Previews: PreviewProvider {
    static var previews: some View {
        SoundVisualizerView()
            .frame(height: 30) // Further reduced height
    }
}
