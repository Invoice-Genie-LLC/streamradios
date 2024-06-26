//
//  PlayerSheetView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import AVKit

// Extension to safely access indices of a collection
extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

struct PlayerSheetView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var shazamViewModel = ShazamViewModel()
    @State private var isShazaming = false
    @State private var showingLyrics = false
    @State private var lyricsLoading = false
    @State private var pulse = false
    
    var body: some View {
        NavigationView {
            ZStack {
                backgroundImageView
                    .blur(radius: 10, opaque: true)
                    .opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    backButton
                    contentView
                    Spacer()
                    PlaybackControls()
                    AirPlayButtonView()
                        .frame(width: 50, height: 50)
                        .padding(.bottom, 20)
                }
                .navigationBarHidden(true)
            }
            .onAppear {
                startPulsing()
            }
        }
    }
    
    private func startPulsing() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 1.0)) {
                pulse.toggle()
            }
        }
    }

    private var backButton: some View {
        HStack {
            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                HStack {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .padding(.top, 10)
                .foregroundColor(.blue)
            }
            Spacer()
        }
        .padding()
    }
    
    @ViewBuilder
    private var backgroundImageView: some View {
        if let uiImage = radioPlayer.albumArt {
            Image(uiImage: uiImage)
                .resizable()
        } else {
            Color.gray.opacity(0.5)
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if isShazaming {
            shazamContent
        } else {
            stationContent
        }
    }
    
    private var shazamContent: some View {
        VStack {
            if let url = shazamViewModel.shazamMedia.albumArtURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                    default:
                        RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.5))
                    }
                }
                .frame(width: 380, height: 355)
                .cornerRadius(10)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.5))
                    .frame(width: 300, height: 300)
                    .cornerRadius(10)
            }
            
            Text(shazamViewModel.shazamMedia.title ?? "Title")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .frame(maxWidth: 390)
                .padding()
            
            Text(shazamViewModel.shazamMedia.artistName ?? "Artist Name")
                .font(.title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding()
            
            HStack {
                Button(action: {
                    if isShazaming {
                        shazamViewModel.stopListening()
                        isShazaming = false
                        pulse = false
                    } else {
                        shazamViewModel.startOrEndListening()
                        isShazaming = true
                        pulse = true
                    }
                }) {
                    Text(isShazaming ? "Stop Shazaming" : "Tap to Shazam")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                .buttonStyle(StylishButtonStyle()) // Apply the custom button style
                
                Button(action: {
                    showingLyrics.toggle()
                    if shazamViewModel.shazamMedia.lyrics == nil {
                        lyricsLoading = true
                        if let artist = shazamViewModel.shazamMedia.artistName, let title = shazamViewModel.shazamMedia.title {
                            shazamViewModel.fetchLyrics(for: artist, song: title) { result in
                                switch result {
                                case .success(let lyrics):
                                    shazamViewModel.shazamMedia.lyrics = lyrics
                                case .failure:
                                    shazamViewModel.shazamMedia.lyrics = "Lyrics not available"
                                }
                                lyricsLoading = false
                            }
                        }
                    }
                }) {
                    Text("Show Lyrics")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                .buttonStyle(StylishButtonStyle())
                .padding()
            }
        }
        .fullScreenCover(isPresented: $showingLyrics) {
            if let lyrics = shazamViewModel.shazamMedia.lyrics, !lyrics.isEmpty {
                LyricsView(
                    lyrics: lyrics,
                    onClose: { showingLyrics = false },
                    getCurrentPlaybackTime: {
                        // Return the current playback time from your audio player
                        radioPlayer.getCurrentTime()
                    }
                )
            } else if lyricsLoading {
                Text("Fetching lyrics...")
                    .font(.title)
                    .padding()
            } else {
                Text("Lyrics not available")
                    .font(.title)
                    .padding()
            }
        }
    }
    
    private var stationContent: some View {
        VStack {
            StationDetails()
            if !ShazamFeatureSwitch.isHideTapToShazamEnabled {
                Button(action: {
                    shazamViewModel.startOrEndListening()
                    isShazaming.toggle()
                    pulse.toggle()
                }) {
                    VStack {
                        Image(systemName: "shazam.logo.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .foregroundColor(.primary)
                            .scaleEffect(pulse ? 1.2 : 1.0)
                            .padding(.bottom, 20)
                        Text("Tap to Shazam")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle()) // Ensure no additional styling is applied
            }
        }
    }
}

// Components for station details, playback controls, AirPlay button, and station image view
struct StationDetails: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    
    var body: some View {
        if let currentStationIndex = radioPlayer.currentStationIndex,
           let currentStation = viewModel.stations[safe: currentStationIndex] {
            VStack {
                StationImage(currentStation: currentStation)
                Text(currentStation.name)
                    .font(.title)
                    .bold()
                    .padding(.top, 4)
                
                if let metadata = radioPlayer.metadata {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                        .padding(.bottom, 50)
                } else {
                    Text("No song or album title available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                        .padding(.bottom, 50)
                }
            }
        }
    }
}

struct PlaybackControls: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    
    var body: some View {
        HStack {
            Button(action: {
                radioPlayer.previousStation(from: viewModel.stations)
            }) {
                Image(systemName: "backward.fill")
                    .font(.largeTitle)
            }
            .padding()
            
            Spacer()
            
            Button(action: {
                radioPlayer.playPause()
            }) {
                Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }
            .padding()
            
            Spacer()
            
            Button(action: {
                radioPlayer.nextStation(from: viewModel.stations)
            }) {
                Image(systemName: "forward.fill")
                    .font(.largeTitle)
            }
            .padding()
        }
        .frame(width: 350)
        .padding(.vertical, 20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(radius: 4)
    }
}

struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .blue
        view.tintColor = .gray
        return view
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    }
}

struct StationImage: View {
    let currentStation: RadioStation
    
    var body: some View {
        if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            Image(uiImage: image).resizable().frame(width: 200, height: 200).cornerRadius(4).padding(.bottom, 8)
        } else {
            Image(systemName: "radio").resizable().frame(width: 100, height: 100).aspectRatio(contentMode: .fit).padding(20).clipShape(Circle()).foregroundColor(.gray).padding(.bottom, 8)
        }
    }
}

struct StylishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor)
                    .shadow(color: configuration.isPressed ? .gray : .clear, radius: 10, x: 0, y: 10)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .foregroundColor(.white)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}
