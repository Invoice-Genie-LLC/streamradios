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
    
    // Station list to use for skip/previous navigation - defaults to all stations if not provided
    let stationsForNavigation: [RadioStation]?
    
    init(stationsForNavigation: [RadioStation]? = nil) {
        self.stationsForNavigation = stationsForNavigation
    }
    
    // Computed property to get the effective stations list
    private var effectiveStations: [RadioStation] {
        return stationsForNavigation ?? viewModel.stations
    }
    
    // Check if skip/previous buttons should be enabled (need at least 1 station)
    private var canSkipStations: Bool {
        let stationCount = effectiveStations.count
        // Enable buttons if there's at least one station (can skip to same station or next available)
        return stationCount > 0
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Main control buttons
            HStack(spacing: 40) {
                // Previous station button
                Button(action: {
                    radioPlayer.previousStation(from: effectiveStations)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .foregroundColor(canSkipStations ? .white : .gray)
                }
                .frame(width: 44, height: 44)
                .background(canSkipStations ? Color.gray.opacity(0.3) : Color.gray.opacity(0.1))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSkipStations)
                
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
                            // Show pause when playing, play when paused
                            Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
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
                    radioPlayer.nextStation(from: effectiveStations)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .foregroundColor(canSkipStations ? .white : .gray)
                }
                .frame(width: 44, height: 44)
                .background(canSkipStations ? Color.gray.opacity(0.3) : Color.gray.opacity(0.1))
                .clipShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSkipStations)
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
