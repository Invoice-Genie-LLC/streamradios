//
//  PlayerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/28/24.
//

import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @State private var bitrateMessage: String = "Playing at high bitrate: 256 kbps"
    
    var body: some View {
        VStack {
            HStack(spacing: 30) {
                Button(action: {
                    radioPlayer.previousStation(from: viewModel.stations)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.largeTitle)
                        .foregroundColor(.primary) // Adjusted to primary color
                }
                
                ZStack {
                    if radioPlayer.isBuffering {
                        CircularProgressView()
                    }
                    Button(action: {
                        radioPlayer.playPause()
                    }) {
                        Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.primary) // Adjusted to primary color
                    }
                }
                
                Button(action: {
                    radioPlayer.nextStation(from: viewModel.stations)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.largeTitle)
                        .foregroundColor(.primary) // Adjusted to primary color
                }
            }
            
            Text(bitrateMessage)
                .font(.footnote)
                .foregroundColor(.gray)
                .padding(.top, 5) // Add padding to separate from station title
                .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                    self.bitrateMessage = newBitrateMessage
                }
        }
    }
}

struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
    }
}
