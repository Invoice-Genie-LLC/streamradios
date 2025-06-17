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
        VStack(spacing: 12) {
            HStack(spacing: 40) {
                Button(action: {
                    radioPlayer.previousStation(from: viewModel.stations)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                ZStack {
                    if radioPlayer.isBuffering {
                        CircularProgressView()
                    } else {
                        Button(action: {
                            radioPlayer.playPause()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.accentColor.opacity(0.8),
                                                Color.accentColor
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 64, height: 64)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                                    )
                                
                                Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .scaleEffect(radioPlayer.isPlaying ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: radioPlayer.isPlaying)
                    }
                }
                
                Button(action: {
                    radioPlayer.nextStation(from: viewModel.stations)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Text(bitrateMessage)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal)
                .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                    self.bitrateMessage = newBitrateMessage
                }
        }
        .padding(.horizontal, 20)
    }
}

struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
    }
}
