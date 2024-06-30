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
    @Environment(\.colorScheme) var colorScheme
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
                // Adjusted background with subtle color for light theme
                backgroundView
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    backButton
                    contentView
                    Spacer()
                    /*
                    if radioPlayer.isPlaying {
                        SoundVisualizerView()
                            .frame(height: 10)
                            .padding(.top, 10)
                            .padding(.bottom, 20)
                    }
                     */
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
            
            if let url = shazamViewModel.shazamMedia.albumArtURL,
               let title = shazamViewModel.shazamMedia.title,
               let artist = shazamViewModel.shazamMedia.artistName {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                    default:
                        RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.5))
                    }
                }
                .frame(width: 380, height: 340)
                .cornerRadius(10)
                .modifier(NeumorphicShadow())
                
                Button("Open in Apple Music") {
                    AppleMusicManager.shared.requestAppleMusicAuthorization { granted in
                        if granted {
                            openAppleMusic(title: title, artist: artist)
                        } else {
                            print("Apple Music authorization denied or not determined")
                        }
                    }
                }
                .font(.headline)
                .foregroundColor(.primary)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
                .padding(.top, 10)
                
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.5))
                    .frame(width: 300, height: 300)
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
                        .foregroundColor(Color.primary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 0).fill(Color(UIColor.secondarySystemBackground)))
                }
                
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

    private func openAppleMusic(title: String, artist: String) {
        AppleMusicAPI.searchSong(title: title, artist: artist) { songID in
            guard let songID = songID else {
                DispatchQueue.main.async {
                    self.showErrorAlert(message: "Song not found.")
                }
                return
            }

            let urlString = "https://music.apple.com/us/song/\(songID)"
            DispatchQueue.main.async {
                if let url = URL(string: urlString) {
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url, options: [:], completionHandler: { success in
                            if success {
                                print("Opened URL successfully")
                            } else {
                                print("Failed to open URL: \(urlString)")
                                self.logErrorDetails(url: urlString, reason: "Failed to open URL")
                                self.showErrorAlert(message: "An error occurred while trying to open Apple Music. Please try again.")
                            }
                        })
                    } else {
                        print("Cannot open URL on this device: \(urlString)")
                        self.logErrorDetails(url: urlString, reason: "Cannot open URL on this device")
                        self.showErrorAlert(message: "This device cannot open Apple Music. Please check your settings.")
                    }
                } else {
                    print("Invalid URL: \(urlString)")
                    self.logErrorDetails(url: urlString, reason: "Invalid URL")
                    self.showErrorAlert(message: "The URL for Apple Music is invalid. Please try again.")
                }
            }
        }
    }
    
    private func logErrorDetails(url: String? = nil, query: String? = nil, reason: String) {
        var errorDetails = "Error opening Apple Music URL"
        if let url = url {
            errorDetails += "\nURL: \(url)"
        }
        if let query = query {
            errorDetails += "\nQuery: \(query)"
        }
        errorDetails += "\nReason: \(reason)"
        print(errorDetails)
    }

    private func showErrorAlert(message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

        if let topController = UIApplication.shared.windows.first?.rootViewController {
            var currentController = topController
            while let presentedController = currentController.presentedViewController {
                currentController = presentedController
            }
            currentController.present(alert, animated: true, completion: nil)
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
                            .padding(.bottom, 10)
                            .modifier(NeumorphicShadow())
                        
                        Text("Tap to Shazam")
                            .font(.headline)
                            .foregroundColor(Color.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle()) // Ensure no additional styling is applied
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
