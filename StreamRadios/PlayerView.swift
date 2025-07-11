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
        VStack(spacing: 16) {
            // Main control buttons
            HStack(spacing: 40) {
                // Previous station button
                Button(action: {
                    radioPlayer.previousStation(from: viewModel.stations)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.3))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                
                // Main play/pause button - larger and more prominent
                Button(action: {
                    radioPlayer.playPause()
                }) {
                    ZStack {
                        if radioPlayer.isBuffering || radioPlayer.connectionState == .connecting {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                        } else {
                            // Show pause if user wants to play (regardless of actual playback state)
                            // Show play if user doesn't want to play
                            Image(systemName: radioPlayer.userWantsToPlay ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .background(Color.blue)
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                
                // Next station button
                Button(action: {
                    radioPlayer.nextStation(from: viewModel.stations)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.3))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
            }
            
            // Connection state indicator or bitrate information
            VStack(spacing: 4) {
                // Show connection state indicator when not connected
                ReconnectingIndicatorView(
                    connectionState: radioPlayer.connectionState,
                    isAttemptingReconnection: radioPlayer.connectionState == .buffering || radioPlayer.connectionState == .connecting
                )
                
                // Bitrate information - compact and subtle
                Text(bitrateMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                        self.bitrateMessage = newBitrateMessage
                    }
            }
        }
        .padding(.vertical, 8)
    }
}

struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
            .preferredColorScheme(.dark)
            .background(Color.black)
    }
}
