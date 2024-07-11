//
//  PlayerSheetView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import AVKit
import Combine

// Extension to safely access indices of a collection
extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

struct PlayerSheetView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @StateObject private var permissionManager = PermissionManager()
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var shazamViewModel = ShazamViewModel()
    @State private var isShazaming = false
    @State private var showingLyrics = false
    @State private var lyricsLoading = false
    @State private var pulse = false
    @State private var showingPurchaseView = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Adjusted background with subtle color for light theme
                backgroundView.edgesIgnoringSafeArea(.all)
                
                VStack {
                    backButton
                        .padding(.top, UIScreen.main.bounds.height < 700 ? 110 : 25)
                    contentView
                    Spacer()
                    PlayerView()
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
                        .padding(.top, 8)
                    AirPlayButtonView()
                        .frame(width: 50, height: 50)
                        .padding(.bottom, 10)
                }
                .padding(.bottom, 20)
                .navigationBarHidden(true)
            }
            .onAppear {
                startPulsing()
            }
            .onDisappear {
                if isShazaming {
                    shazamViewModel.stopListening()
                    isShazaming = false
                }
            }
        }
        .alert(isPresented: $permissionManager.isPermissionAlertPresented) {
            Alert(
                title: Text("Permission Required"),
                message: Text(permissionManager.alertMessage),
                primaryButton: .default(Text("Settings"), action: permissionManager.openAppSettings),
                secondaryButton: .cancel()
            )
        }
    }
    
    private func shazamAction() {
        permissionManager.checkMicrophonePermission { granted in
            if granted {
                shazamViewModel.startOrEndListening()
                isShazaming = true
                pulse = true
            } else {
                // Handle the case where permission is not granted
                // This could involve updating the UI or showing an alert
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
                if isShazaming {
                    shazamViewModel.stopListening()
                    isShazaming = false
                }
            }) {
                HStack {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .foregroundColor(Color.primary)
            }
            Spacer()
        }
        .padding()
        .padding(.top, 25)
        .modifier(NeumorphicShadow())
    }
    
    @ViewBuilder
    private var backgroundImageView: some View {
        if let uiImage = radioPlayer.albumArt {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            Color(UIColor.systemBackground)
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if colorScheme == .light {
            Color(.systemGray4) // Adjust the color as per your preference
        } else {
            Color.clear // Transparent background for dark mode
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
            if let currentStationIndex = radioPlayer.currentStationIndex,
               let currentStation = viewModel.stations[safe: currentStationIndex] {
                HStack {
                    if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: 30, height: 30)
                            .cornerRadius(5)
                    } else {
                        Image(systemName: "radio")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(.gray)
                    }
                    
                    Text(currentStation.name)
                        .font(.title)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.leading, 5)
                }
                .padding(.bottom, 10)
            }
            
            if let url = shazamViewModel.shazamMedia.albumArtURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                    default:
                        RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.5))
                    }
                }
                .frame(width: UIScreen.main.bounds.height < 900 ? 280 : 380, height: UIScreen.main.bounds.height < 900 ? 280 : 380)
                
                //.frame(width: 380, height: 340)
                .cornerRadius(10)
                .modifier(NeumorphicShadow())
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.5))
                    .frame(width: UIScreen.main.bounds.height < 900 ? 280 : 380, height: UIScreen.main.bounds.height < 900 ? 280 : 380)
                    .cornerRadius(10)
                    .modifier(NeumorphicShadow())
            }
            
            GeometryReader { geometry in
                Text(shazamViewModel.shazamMedia.title ?? "Title")
                    .font(.title)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 50)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            
            Text(shazamViewModel.shazamMedia.artistName ?? "Artist Name")
                .font(.title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            
            HStack(spacing: 20) {
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
                        .foregroundColor(Color.primary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 0).fill(Color(UIColor.secondarySystemBackground)))
                }
                
                Button(action: {
                   // if PurchaseManager.shared.hasPurchasedPremium {
                        showingLyrics.toggle()
                        if shazamViewModel.shazamMedia.lyrics == nil {
                            lyricsLoading = true
                            if let artist = shazamViewModel.shazamMedia.artistName, let title = shazamViewModel.shazamMedia.title {
                                shazamViewModel.fetchLyrics(for: artist, song: title) { result in
                                    DispatchQueue.main.async { // Ensure UI updates are on the main thread
                                        switch result {
                                        case .success(let lyrics):
                                            shazamViewModel.shazamMedia.lyrics = lyrics
                                        case .failure:
                                            shazamViewModel.shazamMedia.lyrics = "Lyrics not available"
                                        }
                                        lyricsLoading = false
                                    }
                                    lyricsLoading = false
                                }
                            }
                        }
                    //} else {
                      //  showingPurchaseView = true
                   // }
                }) {
                    Text("Show Lyrics")
                        .font(.headline)
                        .foregroundColor(Color.primary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 0).fill(Color(UIColor.secondarySystemBackground)))
                }
               // .sheet(isPresented: $showingPurchaseView) {
                  //  PurchaseView(isPresented: $showingPurchaseView)
               // }
                
            }
            .padding(.top, 5)
            .padding(.bottom, 5)
        }
        .fullScreenCover(isPresented: $showingLyrics) {
            if let lyrics = shazamViewModel.shazamMedia.lyrics, !lyrics.isEmpty {
                LyricsView(
                    lyrics: lyrics,
                    title: shazamViewModel.shazamMedia.title ?? "Title",
                    artistName: shazamViewModel.shazamMedia.artistName ?? "Artist Name",
                    onClose: { showingLyrics = false },
                    getCurrentPlaybackTime: {
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
    
    private func startOrStopShazaming() {
        if isShazaming {
            shazamViewModel.stopListening()
            isShazaming = false
            pulse = false
        } else {
            shazamViewModel.startOrEndListening()
            isShazaming = true
            pulse = true
        }
    }
    
    private var stationContent: some View {
        VStack {
            StationDetails()
            if !ShazamFeatureSwitch.isHideTapToShazamEnabled {
                Button(action: {
                    shazamViewModel.startOrEndListening()
                    isShazaming.toggle()
                    permissionManager.checkMicrophonePermission { granted in
                        if granted {
                            print("Microphone permission granted.")
                            
                        } else {
                            print("Microphone permission denied or restricted.")
                            
                        }
                    }
                    
                    pulse.toggle()
                }) {
                    VStack {
                        Image(systemName: "shazam.logo.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .foregroundColor(.primary)
                            .scaleEffect(pulse ? 1.2 : 1.0)
                            .padding(.bottom, 10)
                            .modifier(NeumorphicShadow())
                        Text("Tap to Shazam")
                            .font(.headline)
                            .foregroundColor(Color.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private var playbackControls: some View {
        HStack(spacing: 16) {
            Button(action: {
                radioPlayer.previousStation(from: viewModel.stations)
            }) {
                Image(systemName: "backward.fill")
                    .font(.largeTitle)
                    .foregroundColor(.primary)
                    .padding()
            }
            
            Button(action: {
                radioPlayer.playPause()
            }) {
                Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.primary)
                    .padding()
            }
            
            Button(action: {
                radioPlayer.nextStation(from: viewModel.stations)
            }) {
                Image(systemName: "forward.fill")
                    .font(.largeTitle)
                    .foregroundColor(.primary)
                    .padding()
            }
        }
    }
    
}

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
                    .foregroundColor(.primary)
                
                if let metadata = radioPlayer.metadata {
                    Text(metadata)
                        .font(.headline)
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

struct StationImage: View {
    let currentStation: RadioStation
    
    var body: some View {
        if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .frame(width: 200, height: 200)
                .cornerRadius(10)
                .modifier(NeumorphicShadow())
        } else {
            Image(systemName: "radio")
                .resizable()
                .frame(width: 100, height: 100)
                .aspectRatio(contentMode: .fit)
                .padding(20)
                .clipShape(Circle())
                .foregroundColor(.gray)
                .modifier(NeumorphicShadow())
        }
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

struct PlayerSheetView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerSheetView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
    }
}
