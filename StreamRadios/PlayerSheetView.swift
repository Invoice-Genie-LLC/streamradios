//
//  PlayerSheetView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import AVKit
import Combine
import MusicKit
import SpotifyiOS

// Extension to safely access indices of a collection
extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

enum MusicAuthorizationError: Error {
    case notAuthorized
}

struct PlayerSheetView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @StateObject private var permissionManager = PermissionManager()
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var shazamViewModel = ShazamViewModel()
    @State private var isShazaming = false
    @State private var pulse = false
    @State private var showingConfirmationDialog = false
    @State private var shazamSongURL: URL?
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showingPlaylistPicker = false
    @State private var isRequestingMusicAuthorization = false
    @StateObject private var spotifyManager = SpotifyAuthorizationManager.shared
        @State private var showingSpotifyConfirmationDialog = false

    @State private var isAuthorizingSpotify = false


    
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
        VStack(spacing: 20) {
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
                .cornerRadius(10)
                .modifier(NeumorphicShadow())
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.5))
                    .frame(width: UIScreen.main.bounds.height < 900 ? 280 : 380, height: UIScreen.main.bounds.height < 900 ? 280 : 380)
                    .cornerRadius(10)
                    .modifier(NeumorphicShadow())
            }

            Text(shazamViewModel.shazamMedia.title ?? "Title")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal)

            Text(shazamViewModel.shazamMedia.artistName ?? "Artist Name")
                .font(.title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 10) {
                Button(action: {
                    requestMusicAuthorization()
                    showingConfirmationDialog = true
                }) {
                    Text("Add to Apple Music")
                        .font(.headline)
                        .foregroundColor(Color.primary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                }

                Button(action: {
                            if spotifyManager.isAuthorized {
                                showingSpotifyConfirmationDialog = true
                            } else {
                                isAuthorizingSpotify = true
                                spotifyManager.authorize { success in
                                    isAuthorizingSpotify = false
                                    if success {
                                        showingSpotifyConfirmationDialog = true
                                    } else {
                                        // Handle authorization failure
                                        print("Failed to authorize with Spotify")
                                    }
                                }
                            }
                        }) {
                            Text("Add to Spotify")
                                .font(.headline)
                                .foregroundColor(Color.primary)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                        }
                        .disabled(isAuthorizingSpotify)
            }
            .padding(.horizontal)
        }
        .onReceive(spotifyManager.$shouldShowConfirmationDialog) { shouldShow in
                    if shouldShow {
                        showingSpotifyConfirmationDialog = true
                        spotifyManager.shouldShowConfirmationDialog = false
                    }
                }
        .confirmationDialog("Save Song", isPresented: $showingConfirmationDialog) {
            Button("Add to Playlist") {
                addToPlaylist()
            }
            Button("Add to Library") {
                addToLibrary()
            }
            Button("Open in Apple Music") {
                openInAppleMusic()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Message"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerView(shazamViewModel: shazamViewModel)
        }
        .confirmationDialog("Save to Spotify", isPresented: $showingSpotifyConfirmationDialog) {
                Button("Add to Playlist") {
                    addToSpotifyPlaylist()
                }
                Button("Open in Spotify") {
                    openInSpotify()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Message"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                PlaylistPickerView(shazamViewModel: shazamViewModel)
            }
    }
    
    private func addToSpotifyPlaylist() {
        if spotifyManager.isAuthorized {
            spotifyManager.addToSpotifyPlaylist(songTitle: shazamViewModel.shazamMedia.title ?? "", artistName: shazamViewModel.shazamMedia.artistName ?? "")
        } else {
            spotifyManager.authorize { success in
                if success {
                    DispatchQueue.main.async {
                        self.spotifyManager.addToSpotifyPlaylist(songTitle: self.shazamViewModel.shazamMedia.title ?? "", artistName: self.shazamViewModel.shazamMedia.artistName ?? "")
                    }
                } else {
                    DispatchQueue.main.async {
                        self.alertMessage = "Failed to authorize with Spotify"
                        self.showAlert = true
                    }
                }
            }
        }
    }
    
    private func openInSpotify() {
        guard let songTitle = shazamViewModel.shazamMedia.title,
              let artistName = shazamViewModel.shazamMedia.artistName else {
            self.alertMessage = "Song information is not available"
            self.showAlert = true
            return
        }
        
        // Encode the song title and artist name for use in a URL
        let encodedQuery = "\(songTitle) \(artistName)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        // First, try to open with the Spotify URI scheme
        if let spotifyURL = URL(string: "spotify:search:\(encodedQuery)") {
            UIApplication.shared.open(spotifyURL) { success in
                if !success {
                    // If the Spotify app is not installed, open in the web browser
                    if let webURL = URL(string: "https://open.spotify.com/search/\(encodedQuery)") {
                        UIApplication.shared.open(webURL) { success in
                            if !success {
                                DispatchQueue.main.async {
                                    self.alertMessage = "Unable to open Spotify"
                                    self.showAlert = true
                                }
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.alertMessage = "Unable to create Spotify search URL"
                            self.showAlert = true
                        }
                    }
                }
            }
        } else {
            self.alertMessage = "Unable to create Spotify URL"
            self.showAlert = true
        }
    }
    
    private func requestMusicAuthorization() {
            Task {
                let status = await MusicAuthorization.request()
                DispatchQueue.main.async {
                    switch status {
                    case .authorized:
                        self.showingConfirmationDialog = true
                    case .denied, .restricted:
                        self.alertMessage = "Authorization failed. Please allow access to Apple Music in Settings."
                        self.showAlert = true
                    case .notDetermined:
                        self.alertMessage = "Please authorize access to Apple Music and try again."
                        self.showAlert = true
                    @unknown default:
                        self.alertMessage = "An unknown error occurred. Please try again."
                        self.showAlert = true
                    }
                }
            }
        }
    
    private func addToLibrary() {
        Task {
            do {
                let status = await MusicAuthorization.request()
                switch status {
                case .authorized:
                    try await shazamViewModel.fetchAppleMusicItem()
                    try await shazamViewModel.addToLibrary()
                    DispatchQueue.main.async {
                        self.alertMessage = "Song added to your library"
                        self.showAlert = true
                    }
                case .denied, .restricted:
                    DispatchQueue.main.async {
                        self.alertMessage = "Authorization failed. Please allow access to Apple Music in Settings."
                        self.showAlert = true
                    }
                case .notDetermined:
                    DispatchQueue.main.async {
                        self.alertMessage = "Please authorize access to Apple Music and try again."
                        self.showAlert = true
                    }
                @unknown default:
                    break
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "Error: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
    
    private func openInAppleMusic() {
        Task {
            do {
                try await shazamViewModel.fetchAppleMusicItem()
                if let url = shazamViewModel.appleMusicURL {
                    await UIApplication.shared.open(url)
                } else {
                    DispatchQueue.main.async {
                        self.alertMessage = "Couldn't open in Apple Music"
                        self.showAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "Error: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    private func addToPlaylist() {
            Task {
                do {
                    let status = await MusicAuthorization.request()
                    if status == .authorized {
                        try await shazamViewModel.fetchAppleMusicItem()
                        let request = MusicLibraryRequest<Playlist>()
                        let response = try await request.response()
                        DispatchQueue.main.async {
                            self.shazamViewModel.userPlaylists = response.items
                            self.showingPlaylistPicker = true
                        }
                    } else {
                        throw MusicAuthorizationError.notAuthorized
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.alertMessage = "Error: \(error.localizedDescription)"
                        self.showAlert = true
                    }
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

struct PlaylistPickerView: View {
    @ObservedObject var shazamViewModel: ShazamViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            List(shazamViewModel.userPlaylists, id: \.id) { playlist in
                Button(action: {
                    addToSelectedPlaylist(playlist)
                }) {
                    Text(playlist.name)
                }
            }
            .navigationTitle("Select Playlist")
            .navigationBarItems(trailing: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Message"), message: Text(alertMessage), dismissButton: .default(Text("OK")) {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }

    private func addToSelectedPlaylist(_ playlist: Playlist) {
        Task {
            do {
                try await shazamViewModel.addToPlaylist(playlist)
                DispatchQueue.main.async {
                    self.alertMessage = "Song added to playlist successfully"
                    self.showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "Error adding song to playlist: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}
