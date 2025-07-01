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
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.3))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .disabled(radioPlayer.isRetrying || radioPlayer.isBuffering) // Disable during retry or buffering
                
                // Main play/pause button - larger and more prominent
                Button(action: {
                    if radioPlayer.hasError && !radioPlayer.isRetrying {
                        // Manual retry when there's an error
                        if let station = radioPlayer.currentlyPlayingStation,
                           let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                            radioPlayer.playStation(at: index, from: viewModel.stations)
                        }
                    } else {
                        radioPlayer.playPause()
                    }
                }) {
                    ZStack {
                        if radioPlayer.isBuffering || radioPlayer.isRetrying {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                        } else if radioPlayer.hasError {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .background(radioPlayer.hasError ? Color.orange : Color.blue)
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .shadow(color: (radioPlayer.hasError ? Color.orange : Color.blue).opacity(0.3), radius: 8, x: 0, y: 4)
                
                // Next station button
                Button(action: {
                    radioPlayer.nextStation(from: viewModel.stations)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.3))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .disabled(radioPlayer.isRetrying || radioPlayer.isBuffering) // Disable during retry or buffering
            }
            
            // Status message area
            if radioPlayer.hasError || radioPlayer.isRetrying || radioPlayer.isBuffering {
                HStack {
                    if radioPlayer.isRetrying || radioPlayer.isBuffering {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(radioPlayer.isRetrying ? .orange : .blue)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                    
                    Text(radioPlayer.errorMessage.isEmpty ? 
                         (radioPlayer.isBuffering ? "Connecting to station..." : "Tap to retry") : 
                         radioPlayer.errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(radioPlayer.isRetrying ? .orange : (radioPlayer.isBuffering ? .blue : .red))
                }
                .transition(.opacity)
            } else {
                // Bitrate information - compact and subtle
                Text(bitrateMessage)
                    .font(.system(size: 12, weight: .medium))
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
