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
    @Environment(\.colorScheme) var colorScheme
    
    // Station list to use for skip/previous navigation - defaults to all stations if not provided
    let stationsForNavigation: [RadioStation]?
    
    init(stationsForNavigation: [RadioStation]? = nil) {
        self.stationsForNavigation = stationsForNavigation
    }
    
    // Computed properties for adaptive colors
    private var playbackControlIconColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var buttonGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05),
                Color.white.opacity(0.15)
            ]
        } else {
            return [
                Color.black.opacity(0.15),
                Color.black.opacity(0.05),
                Color.black.opacity(0.10)
            ]
        }
    }
    
    private var buttonBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1),
                Color.white.opacity(0.3)
            ]
        } else {
            return [
                Color.black.opacity(0.3),
                Color.black.opacity(0.15),
                Color.black.opacity(0.25)
            ]
        }
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
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "backward.fill")
                            .font(.title2)
                            .foregroundColor(canSkipStations ? playbackControlIconColor : .gray)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSkipStations)
                
                // Main play/pause button - larger and more prominent
                Button(action: {
                    radioPlayer.playPause()
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 64, height: 64)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .frame(width: 64, height: 64)
                        
                        if let statusSymbol = radioPlayer.networkStatus.transportSymbol {
                            // Offline / failed: a quiet glyph instead of an endless spinner
                            Image(systemName: statusSymbol)
                                .font(.title)
                                .foregroundColor(playbackControlIconColor)
                        } else if radioPlayer.isBuffering || radioPlayer.connectionState == .connecting {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(playbackControlIconColor)
                        } else {
                            // Show pause when playing, play when paused
                            Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                                .foregroundColor(playbackControlIconColor)
                                .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Next station button
                Button(action: {
                    radioPlayer.nextStation(from: effectiveStations)
                }) {
                    ZStack {
                        // Base glass layer
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 44)
                        
                        // Glass gradient overlay for depth
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: buttonGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        
                        // Glass border with subtle glow
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: buttonBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "forward.fill")
                            .font(.title2)
                            .foregroundColor(canSkipStations ? playbackControlIconColor : .gray)
                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSkipStations)
            }
            
            // Connection state indicator or bitrate information
            VStack(spacing: 4) {
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
