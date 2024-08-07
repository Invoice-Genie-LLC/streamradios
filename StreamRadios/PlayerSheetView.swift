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

enum ActiveSheetPlayer: Identifiable {
    case playlistPicker
    case spotifyPlaylistPicker
    case youtubeMusicPlaylistPicker
    
    var id: Int {
        hashValue
    }
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
    @State private var showAlert = false
    @State private var alertMessage = ""
    @StateObject private var spotifyManager = SpotifyAuthorizationManager.shared
    @State private var showingSpotifyConfirmationDialog = false
    @State private var spotifyPlaylists: [(id: String, name: String)] = []
    @State private var isAuthorizingSpotify = false
    @StateObject private var youtubeMusicManager = YouTubeMusicManager.shared
    @State private var showingYouTubeMusicConfirmationDialog = false
    @State private var activeSheet: ActiveSheetPlayer?

    var body: some View {
        NavigationView {
            ZStack {
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
        .sheet(item: $activeSheet) { item in
            switch item {
            case .playlistPicker:
                PlaylistPickerView(shazamViewModel: shazamViewModel)
            case .spotifyPlaylistPicker:
                SpotifyPlaylistPickerView(isPresented: Binding(
                    get: { self.activeSheet == .spotifyPlaylistPicker },
                    set: { if !$0 { self.activeSheet = nil } }
                ), playlists: spotifyPlaylists) { playlistID in
                    spotifyManager.addToSpotifyPlaylist(songTitle: shazamViewModel.shazamMedia.title ?? "", artistName: shazamViewModel.shazamMedia.artistName ?? "", playlistID: playlistID) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                self.alertMessage = "Song added to Spotify playlist successfully"
                            case .failure(let error):
                                self.alertMessage = "Failed to add song to Spotify playlist: \(error.localizedDescription)"
                            }
                            self.showAlert = true
                        }
                    }
                }
            case .youtubeMusicPlaylistPicker:
                YouTubeMusicPlaylistPickerView(isPresented: Binding(
                    get: { self.activeSheet == .youtubeMusicPlaylistPicker },
                    set: { if !$0 { self.activeSheet = nil } }
                )) { selectedPlaylistId in
                    saveToYouTubeMusicPlaylist(playlistId: selectedPlaylistId)
                }
            }
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
        .confirmationDialog("YouTube Music Options", isPresented: $showingYouTubeMusicConfirmationDialog) {
            Button("Open in YouTube Music") {
                openInYouTubeMusic()
            }
            Button("Save to YouTube Music Playlist") {
                activeSheet = .youtubeMusicPlaylistPicker
            }
            Button("Cancel", role: .cancel) {}
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
            Color(.systemGray4)
        } else {
            Color.clear
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
                    HStack {
                        Image(systemName: "music.note")
                            .font(.headline)
                        Text("Apple Music")
                            .font(.headline)
                    }
                    .foregroundColor(Color.primary)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                }
                
                Button(action: {
                    if spotifyManager.isAuthorized {
                        showingSpotifyConfirmationDialog = true
                    } else {
                        spotifyManager.authorize { success in
                            if success {
                                DispatchQueue.main.async {
                                    self.showingSpotifyConfirmationDialog = true
                                }
                            } else {
                                DispatchQueue.main.async {
                                    self.alertMessage = "Failed to authorize with Spotify"
                                    self.showAlert = true
                                }
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "music.note.list")
                            .font(.headline)
                        Text("Spotify")
                            .font(.headline)
                    }
                    .foregroundColor(Color.primary)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                }
                .disabled(isAuthorizingSpotify)
                
                Button(action: {
                    if youtubeMusicManager.isAuthorized {
                        showingYouTubeMusicConfirmationDialog = true
                    } else {
                        youtubeMusicManager.authorize { success in
                            if success {
                                DispatchQueue.main.async {
                                    self.showingYouTubeMusicConfirmationDialog = true
                                }
                            } else {
                                DispatchQueue.main.async {
                                    self.alertMessage = "Failed to authorize with YouTube Music"
                                    self.showAlert = true
                                }
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "play.circle")
                            .font(.headline)
                        Text("YouTube")
                            .font(.headline)
                    }
                    .foregroundColor(Color.primary)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func openInYouTubeMusic() {
        guard let songTitle = shazamViewModel.shazamMedia.title,
              let artistName = shazamViewModel.shazamMedia.artistName else {
            self.alertMessage = "Song information is not available"
            self.showAlert = true
            return
        }
        
        let query = "\(songTitle) \(artistName)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "youtubemusic://search?q=\(query)"
        
        if let url = URL(string: urlString) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:]) { success in
                    if !success {
                        DispatchQueue.main.async {
                            self.alertMessage = "Failed to open YouTube Music"
                            self.showAlert = true
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.alertMessage = "YouTube Music app is not installed"
                    self.showAlert = true
                }
            }
        } else {
            DispatchQueue.main.async {
                self.alertMessage = "Invalid URL"
                self.showAlert = true
            }
        }
    }
    
    private func saveToYouTubeMusicPlaylist(playlistId: String) {
        guard let songTitle = shazamViewModel.shazamMedia.title,
              let artistName = shazamViewModel.shazamMedia.artistName else {
            self.alertMessage = "Song information is not available"
            self.showAlert = true
            return
        }
        
        youtubeMusicManager.saveToYouTubeMusicPlaylist(songTitle: songTitle, artistName: artistName, playlistId: playlistId) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.alertMessage = "Song has been added to the YouTube Music playlist"
                    self.showAlert = true
                case .failure(let error):
                    self.alertMessage = "Failed to save to YouTube Music playlist: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
    
    private func addToSpotifyPlaylist() {
        spotifyManager.fetchUserPlaylists { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let playlists):
                    self.spotifyPlaylists = playlists
                    self.activeSheet = .spotifyPlaylistPicker
                case .failure(let error):
                    self.alertMessage = "Failed to fetch Spotify playlists: \(error.localizedDescription)"
                    self.showAlert = true
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
            
            spotifyManager.searchForTrackURI(songTitle: songTitle, artistName: artistName) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let uri):
                        if let spotifyURL = URL(string: uri) {
                            UIApplication.shared.open(spotifyURL) { success in
                                if !success {
                                    self.alertMessage = "Unable to open Spotify. Please ensure Spotify is installed on your device."
                                    self.showAlert = true
                                }
                            }
                        } else {
                            self.alertMessage = "Invalid Spotify URI"
                            self.showAlert = true
                        }
                    case .failure(let error):
                        self.alertMessage = "Failed to find track: \(error.localizedDescription)"
                        self.showAlert = true
                    }
                }
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
                        print("Fetched \(response.items.count) playlists")
                        self.activeSheet = .playlistPicker
                    }
                } else {
                    throw MusicAuthorizationError.notAuthorized
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "Error: \(error.localizedDescription)"
                    self.showAlert = true
                    print("Error in addToPlaylist: \(error)")
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
                    print("Selected playlist: \(playlist.name)")
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
        .onAppear {
            print("PlaylistPickerView appeared with \(shazamViewModel.userPlaylists.count) playlists")
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
                    print("Error in addToSelectedPlaylist: \(error)")
                }
            }
        }
    }
}

struct SpotifyPlaylistPickerView: View {
    @Binding var isPresented: Bool
    let playlists: [(id: String, name: String)]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List(playlists, id: \.id) { playlist in
                Button(action: {
                    onSelect(playlist.id)
                    isPresented = false
                }) {
                    Text(playlist.name)
                }
            }
            .navigationTitle("Select Spotify Playlist")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
}
