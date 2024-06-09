//
//  CarPlayTemplate.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import SwiftUI
import CarPlay

struct CarPlayTemplate: View {
    @StateObject private var radioPlayer = RadioPlayer.shared

    var body: some View {
        VStack {
            Text("CarPlay Radio Stream")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                radioPlayer.playPause()
            }) {
                Text(radioPlayer.isPlaying ? "Pause" : "Play")
                    .font(.title)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .padding()
    }
}
