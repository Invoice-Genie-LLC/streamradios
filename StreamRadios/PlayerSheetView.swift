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

// MARK: - LibraryPlaylist Structure for proper editable playlist detection
public typealias LibraryPlaylists = MusicItemCollection<LibraryPlaylist>

public struct LibraryPlaylist: Codable, MusicItem {
    public let id: MusicItemID
    public let attributes: Attributes
    
    public struct Attributes: Codable, Sendable {
        public let canEdit: Bool
        public let name: String
        public let isPublic: Bool?
        public let hasCatalog: Bool?
        public let playParams: PlayParameters?
        public let description: Description?
        public let artwork: Artwork?
    }
    
    public struct Description: Codable, Sendable {
        public let standard: String
    }
    
    public struct PlayParameters: Codable, Sendable {
        public let id: MusicItemID
        public let isLibrary: Bool?
        public let globalID: MusicItemID?
        
        enum CodingKeys: String, CodingKey {
            case id, isLibrary
            case globalID = "globalId"
        }
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
    @State private var forceTokenRefresh = false
    @State private var debugLog = ""
    @State private var showSpotifyOptions = false
    @State private var spotifyTrackURI: String?
    @State private var debugMessage = ""
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ZStack {
                    backgroundView
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack(spacing: 0) {
                        // Back button with minimal padding
                        backButton
                            .padding(.top, geometry.safeAreaInsets.top + 5)
                        
                        // Content view in ScrollView to prevent cutoff
                        ScrollView {
                            contentView
                                .padding(.top, 10)
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.hidden)
                        
                        // Bottom controls with proper spacing
                        VStack(spacing: 8) {
                            PlayerView()
                                .environmentObject(radioPlayer)
                                .environmentObject(viewModel)
                            
                            AirPlayButtonView()
                                .frame(width: 44, height: 44)
                        }
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 8)
                    }
                    .navigationBarHidden(true)
                }
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
                EnhancedPlaylistPickerView(shazamViewModel: shazamViewModel)
            case .spotifyPlaylistPicker:
                SpotifyPlaylistPickerView(
                    isPresented: Binding(
                    get: { self.activeSheet == .spotifyPlaylistPicker },
                    set: { if !$0 { self.activeSheet = nil } }
                    ), 
                    playlists: spotifyPlaylists,
                    shazamViewModel: shazamViewModel,
                    onSelect: { playlistID in
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
                )
            case .youtubeMusicPlaylistPicker:
                YouTubeMusicPlaylistPickerView(
                    isPresented: Binding(
                    get: { self.activeSheet == .youtubeMusicPlaylistPicker },
                    set: { if !$0 { self.activeSheet = nil } }
                    ),
                    shazamViewModel: shazamViewModel
                ) { selectedPlaylistId in
                    saveToYouTubeMusicPlaylist(playlistId: selectedPlaylistId)
                }
            }
        }
        .confirmationDialog("Spotify Options", isPresented: $showingSpotifyConfirmationDialog) {
            Button("Add to Playlist") {
                addToSpotifyPlaylist()
            }
            Button("Open in Spotify") {
                openInSpotify()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Spotify Not Installed", isPresented: $showSpotifyOptions) {
            Button("Install Spotify") {
                if let appStoreURL = URL(string: "itms-apps://apple.com/app/id324684580") {
                    UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spotify app is not installed. Would you like to install it?")
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
        GeometryReader { geometry in
            VStack {
                Spacer()
                
                VStack(spacing: 20) {
                    // Current station info at top - now centered
                    if let currentStationIndex = radioPlayer.currentStationIndex,
                       let currentStation = viewModel.stations[safe: currentStationIndex] {
                        HStack(spacing: 12) {
                            if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .cornerRadius(6)
                            } else {
                                Image(systemName: "radio")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(currentStation.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                    }
                    
                    // Shazam artwork - now properly centered
                    if let url = shazamViewModel.shazamMedia.albumArtURL {
                        HStack {
                            Spacer()
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: min(geometry.size.width * 0.65, 240), height: min(geometry.size.width * 0.65, 240))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                                default:
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: [Color.purple.opacity(0.6), Color.blue.opacity(0.4)]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: min(geometry.size.width * 0.65, 240), height: min(geometry.size.width * 0.65, 240))
                                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                                        .overlay(
                                            Image(systemName: "music.note")
                                                .font(.system(size: min(geometry.size.width * 0.65, 240) * 0.25, weight: .light))
                                                .foregroundColor(.white.opacity(0.8))
                                        )
                                }
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        // Default artwork when no URL is available
                        HStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.purple.opacity(0.6), Color.blue.opacity(0.4)]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: min(geometry.size.width * 0.65, 240), height: min(geometry.size.width * 0.65, 240))
                                .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: min(geometry.size.width * 0.65, 240) * 0.25, weight: .light))
                                        .foregroundColor(.white.opacity(0.8))
                                )
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    // Song information - centered
                    VStack(spacing: 6) {
                        Text(shazamViewModel.shazamMedia.title ?? "Unknown Title")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 20)
                    
                        Text(shazamViewModel.shazamMedia.artistName ?? "Unknown Artist")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                    }
                    
                    // Action button
                    Button(action: {
                        requestMusicAuthorization()
                        showingConfirmationDialog = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "apple.logo")
                                .font(.title2)
                                .fontWeight(.medium)
                            Text("Save to Apple Music")
                                .font(.headline)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 25)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity)
                
                Spacer()
            }
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
    
    private func handleSpotifyAuthorization() {
        if spotifyManager.isAuthorized {
            spotifyManager.checkAndRefreshTokenIfNeeded { success in
                DispatchQueue.main.async {
                    if success {
                        self.showingSpotifyConfirmationDialog = true
                    } else {
                        self.reauthorizeSpotify()
                    }
                }
            }
        } else {
            reauthorizeSpotify()
        }
    }
    
    private func reauthorizeSpotify() {
        isAuthorizingSpotify = true
        spotifyManager.authorize { success in
            DispatchQueue.main.async {
                self.isAuthorizingSpotify = false
                if success {
                    self.showingSpotifyConfirmationDialog = true
                } else {
                    self.alertMessage = "Failed to authorize Spotify. Please try again."
                    self.showAlert = true
                }
            }
        }
    }
    
    private func fetchSpotifyPlaylists() {
        spotifyManager.fetchUserPlaylists { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let playlists):
                    if playlists.isEmpty {
                        self.alertMessage = "No playlists found in your Spotify account."
                        self.showAlert = true
                    } else {
                        self.spotifyPlaylists = playlists
                        self.activeSheet = .spotifyPlaylistPicker
                    }
                case .failure(let error):
                    if (error as NSError).code == 401 {
                        // Token refresh failed, re-authorize
                        self.spotifyManager.authorize { success in
                            if success {
                                self.fetchSpotifyPlaylists()
                            } else {
                                self.alertMessage = "Failed to re-authorize Spotify. Please try again."
                                self.showAlert = true
                            }
                        }
                    } else {
                        let errorMessage = "Failed to fetch Spotify playlists: \(error.localizedDescription)"
                        print(errorMessage)
                        self.alertMessage = errorMessage
                        self.showAlert = true
                    }
                }
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
        
        youtubeMusicManager.addToPlaylist(playlistId: playlistId, songTitle: songTitle, artistName: artistName) { result in
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
        
        debugMessage += "Searching for: \(songTitle) by \(artistName)\n"
        
        spotifyManager.checkAndRefreshTokenIfNeeded { success in
            if success {
                self.performSpotifySearch(songTitle: songTitle, artistName: artistName)
            } else {
                DispatchQueue.main.async {
                    self.debugMessage += "Failed to refresh token. Attempting to reauthorize...\n"
                    self.spotifyManager.authorize { success in
                        if success {
                            self.debugMessage += "Reauthorization successful\n"
                            self.performSpotifySearch(songTitle: songTitle, artistName: artistName)
                        } else {
                            self.debugMessage += "Reauthorization failed\n"
                            self.alertMessage = "Failed to authorize Spotify. Please try again."
                            self.showAlert = true
                        }
                    }
                }
            }
        }
    }
    
    private func performSpotifySearch(songTitle: String, artistName: String) {
        spotifyManager.searchForTrackURI(songTitle: songTitle, artistName: artistName) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let uri):
                    self.spotifyTrackURI = uri
                    self.debugMessage += "Found Spotify URI: \(uri)\n"
                    
                    // Extract the ID from the URI
                    let id = uri.components(separatedBy: ":").last ?? uri
                    
                    // Construct the correct URLs for opening in the Spotify app
                    let spotifyAppURL = URL(string: "spotify:track:\(id)")
                    let spotifyHttpURL = URL(string: "https://open.spotify.com/track/\(id)")
                    
                    self.debugMessage += "Checking Spotify URL schemes...\n"
                    self.debugMessage += "Can open 'spotify:': \(UIApplication.shared.canOpenURL(URL(string: "spotify:")!))\n"
                    self.debugMessage += "Can open 'spotify:track:': \(UIApplication.shared.canOpenURL(URL(string: "spotify:track:")!))\n"
                    
                    if let appURL = spotifyAppURL {
                        self.debugMessage += "Attempting to open \(appURL.absoluteString)\n"
                        
                        UIApplication.shared.open(appURL, options: [:]) { success in
                            if success {
                                self.debugMessage += "Successfully opened Spotify app\n"
                            } else {
                                self.debugMessage += "Failed to open Spotify app, falling back to HTTP URL\n"
                                self.openSpotifyWebURL(spotifyHttpURL)
                            }
                        }
                    } else {
                        self.debugMessage += "Invalid Spotify app URL, falling back to HTTP URL\n"
                        self.openSpotifyWebURL(spotifyHttpURL)
                    }
                    
                case .failure(let error):
                    self.alertMessage = "Failed to find track on Spotify: \(error.localizedDescription)"
                    self.showAlert = true
                    self.debugMessage += "Error: \(error.localizedDescription)\n"
                }
                
                print(self.debugMessage) // Print debug messages to console
            }
        }
    }
    
    private func fallbackToSpotifyWeb(httpURL: URL?) {
        guard let url = httpURL else {
            self.debugMessage += "Invalid Spotify HTTP URL\n"
            self.alertMessage = "There was an error creating the Spotify link. Please try again."
            self.showAlert = true
            return
        }
        
        self.debugMessage += "Attempting to open Spotify web URL: \(url.absoluteString)\n"
        
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                self.debugMessage += "Successfully opened Spotify web URL\n"
            } else {
                self.debugMessage += "Failed to open Spotify web URL\n"
                self.showSpotifyOptions = true
            }
        }
    }
    
    private func openSpotifyWebURL(_ url: URL?) {
        guard let webURL = url else {
            self.debugMessage += "Invalid Spotify web URL\n"
            self.alertMessage = "There was an error creating the Spotify link. Please try again."
            self.showAlert = true
            return
        }
        
        self.debugMessage += "Attempting to open Spotify web URL: \(webURL.absoluteString)\n"
        
        UIApplication.shared.open(webURL, options: [:]) { success in
            if success {
                self.debugMessage += "Successfully opened Spotify web URL\n"
            } else {
                self.debugMessage += "Failed to open Spotify web URL\n"
                self.alertMessage = "Unable to open Spotify. You can search for '\(self.shazamViewModel.shazamMedia.title ?? "")' by '\(self.shazamViewModel.shazamMedia.artistName ?? "")' manually in Spotify."
                self.showAlert = true
            }
        }
    }
    
    private func searchAndOpenSpotify(songTitle: String, artistName: String) {
        spotifyManager.searchForTrackURI(songTitle: songTitle, artistName: artistName) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let uri):
                    debugLog += "Successfully found track URI: \(uri)\n"
                    if let spotifyURL = URL(string: uri) {
                        UIApplication.shared.open(spotifyURL) { success in
                            if success {
                                debugLog += "Opened Spotify successfully\n"
                            } else {
                                debugLog += "Failed to open Spotify\n"
                                self.alertMessage = "Unable to open Spotify. Please ensure Spotify is installed on your device."
                                self.showAlert = true
                            }
                        }
                    } else {
                        debugLog += "Invalid Spotify URI\n"
                        self.alertMessage = "Invalid Spotify URI"
                        self.showAlert = true
                    }
                case .failure(let error):
                    debugLog += "Failed to find track: \(error.localizedDescription)\n"
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
                        print("Fetched \(response.items.count) total playlists from MusicLibraryRequest")
                        
                        // Debug: Print playlist details to understand curator information
                        for playlist in response.items.prefix(5) { // Show first 5 for debugging
                            print("Playlist: '\(playlist.name)', Curator: '\(playlist.curatorName ?? "nil")'")
                        }
                        
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
        GeometryReader { geometry in
            VStack {
                Spacer()
                
                VStack(spacing: 20) {
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
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "shazam.logo")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                Text("Tap to Shazam")
                                    .font(.headline)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 25)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                            .scaleEffect(pulse ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                            .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .onAppear {
                            pulse = true
                        }
                        .onDisappear {
                            pulse = false
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                
                Spacer()
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
            VStack(spacing: 16) {
                StationImage(currentStation: currentStation)
                
                VStack(spacing: 8) {
                    Text(currentStation.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                    
                    if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                        Text(metadata)
                            .font(.headline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                    } else {
                        Text("No song information available")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

struct StationImage: View {
    let currentStation: RadioStation
    @EnvironmentObject var radioPlayer: RadioPlayer
    
    var body: some View {
        GeometryReader { geometry in
            let artworkSize = min(geometry.size.width * 0.65, 240)
            
            // Priority: iTunes album art > stream album art > station icon > default radio icon
            if let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
                HStack {
                    Spacer()
                    Image(uiImage: iTunesAlbumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let albumArt = radioPlayer.albumArt {
                HStack {
                    Spacer()
                    Image(uiImage: albumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                HStack {
                    Spacer()
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.4)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: artworkSize, height: artworkSize)
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                        .overlay(
                            Image(systemName: "radio")
                                .font(.system(size: artworkSize * 0.25, weight: .light))
                                .foregroundColor(.white.opacity(0.8))
                        )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: min(UIScreen.main.bounds.width * 0.65, 240))
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
    @Environment(\.colorScheme) var colorScheme
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    
    var filteredPlaylists: [Playlist] {
        // Filter for active (user-created) playlists only
        let activePlaylists = Array(shazamViewModel.userPlaylists).filter { playlist in
            // Filter out system playlists and Apple-curated content
            
            // Check if it has a curator name (Apple-curated playlists usually have this)
            if let curatorName = playlist.curatorName, !curatorName.isEmpty {
                // Exclude playlists curated by Apple Music or other services
                let excludedCurators = ["Apple Music", "Apple", "apple music", "apple"]
                return !excludedCurators.contains { curatorName.localizedCaseInsensitiveContains($0) }
            }
            
            // Additional filtering criteria for user-created playlists
            // User-created playlists typically:
            // 1. Don't have a curator name (or it's the user's name)
            // 2. Are in the user's library (which these already are)
            // 3. Are not system-generated
            
            // For now, if there's no curator name, it's likely user-created
            return playlist.curatorName == nil || playlist.curatorName?.isEmpty == true
        }
        
        // Debug logging
        let totalPlaylists = Array(shazamViewModel.userPlaylists).count
        print("Filtered \(totalPlaylists) total playlists down to \(activePlaylists.count) active playlists")
        
        // Apply search filtering
        if searchText.isEmpty {
            return activePlaylists
        } else {
            return activePlaylists.filter { playlist in
                playlist.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header section with song info and album artwork
                    if let songTitle = shazamViewModel.shazamMedia.title,
                       let artistName = shazamViewModel.shazamMedia.artistName {
                        VStack(spacing: 8) {
                            HStack(spacing: 16) {
                                // Album artwork
                                if let artworkURL = shazamViewModel.shazamMedia.albumArtURL {
                                    AsyncImage(url: artworkURL) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        case .failure(_):
                                            Image(systemName: "music.note")
                                                .font(.title)
                                                .foregroundColor(.blue)
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray5))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray6))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        @unknown default:
                                            Image(systemName: "music.note")
                                                .font(.title)
                                                .foregroundColor(.blue)
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray5))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.title)
                                        .foregroundColor(.blue)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Adding to Playlist")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(songTitle)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .lineLimit(2)
                                    Text("by \(artistName)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(.secondarySystemBackground))
                                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                            )
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                    
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search playlists", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // Playlists list
                    if filteredPlaylists.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: searchText.isEmpty ? "music.note.list" : "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No active playlists found" : "No active playlists match your search")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            if searchText.isEmpty {
                                Text("Create your own playlists in Apple Music to get started")
                                    .font(.subheadline)
                                    .foregroundColor(Color.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredPlaylists, id: \.id) { playlist in
                                    PlaylistRowView(
                                        playlist: playlist,
                                        isAdded: addedPlaylistIDs.contains(playlist.id.rawValue),
                                        onSelect: {
                    addToSelectedPlaylist(playlist)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
            }
        }
        .onAppear {
            print("PlaylistPickerView appeared with \(shazamViewModel.userPlaylists.count) playlists")
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(alertMessage.contains("successfully") ? "Success" : "Error"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK")) {
                    if alertMessage.contains("successfully") {
                presentationMode.wrappedValue.dismiss()
                    }
                }
            )
        }
    }
    
    private func addToSelectedPlaylist(_ playlist: Playlist) {
        // Prevent adding to the same playlist multiple times
        if addedPlaylistIDs.contains(playlist.id.rawValue) {
            return
        }
        
        Task {
            do {
                try await shazamViewModel.addToPlaylist(playlist)
                DispatchQueue.main.async {
                    self.addedPlaylistIDs.insert(playlist.id.rawValue)
                    self.alertMessage = "Song added to \"\(playlist.name)\" successfully"
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

struct PlaylistRowView: View {
    let playlist: Playlist
    let isAdded: Bool
    let onSelect: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Playlist icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.6)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                // Playlist info
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    // Show track count if available - removed as trackCount is not available
                    // Note: Track count not available in current Playlist implementation
                    Text("Your Playlist")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Add/Check indicator
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                        .scaleEffect(1.1)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .opacity(isPressed ? 0.6 : 1.0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: Color.black.opacity(isPressed ? 0.15 : 0.08), radius: isPressed ? 12 : 8, x: 0, y: isPressed ? 4 : 2)
                    .scaleEffect(isPressed ? 0.98 : 1.0)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

struct SpotifyPlaylistPickerView: View {
    @Binding var isPresented: Bool
    let playlists: [(id: String, name: String)]
    @ObservedObject var shazamViewModel: ShazamViewModel
    let onSelect: (String) -> Void
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    @Environment(\.colorScheme) var colorScheme
    
    var filteredPlaylists: [(id: String, name: String)] {
        if searchText.isEmpty {
            return playlists
        } else {
            return playlists.filter { playlist in
                playlist.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background with Spotify brand colors
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header with song info and album artwork
                    Group {
                        if let songTitle = shazamViewModel.shazamMedia.title,
                           let artistName = shazamViewModel.shazamMedia.artistName {
                            HStack {
                                // Album artwork
                                if let artworkURL = shazamViewModel.shazamMedia.albumArtURL {
                                    AsyncImage(url: artworkURL) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        case .failure(_):
                                            Image(systemName: "music.note")
                                                .font(.title)
                                                .foregroundColor(.green)
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray5))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray6))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        @unknown default:
                                            Image(systemName: "music.note")
                                                .font(.title)
                                                .foregroundColor(.green)
                                                .frame(width: 60, height: 60)
                                                .background(Color(.systemGray5))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.title)
                                        .foregroundColor(.green)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Adding to Spotify")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(songTitle)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .lineLimit(2)
                                    Text("by \(artistName)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                // Spotify logo representation
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .font(.caption)
                                            .foregroundColor(.white)
                                    )
                            }
                        } else {
                            // Fallback header
                            HStack {
                                Image(systemName: "music.note.list")
                                    .font(.title2)
                                    .foregroundColor(.green)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add to Spotify")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Select a playlist")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                                
                                // Spotify logo representation
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .font(.caption)
                                            .foregroundColor(.white)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemBackground))
                            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search Spotify playlists", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // Playlists list
                    if filteredPlaylists.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: searchText.isEmpty ? "music.note.list" : "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No playlists found" : "No playlists match your search")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            if searchText.isEmpty {
                                Text("Create a playlist in Spotify to get started")
                                    .font(.subheadline)
                                    .foregroundColor(Color.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredPlaylists, id: \.id) { playlist in
                                    SpotifyPlaylistRowView(
                                        playlist: playlist,
                                        isAdded: addedPlaylistIDs.contains(playlist.id),
                                        onSelect: {
                                            if !addedPlaylistIDs.contains(playlist.id) {
                                                addedPlaylistIDs.insert(playlist.id)
                    onSelect(playlist.id)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("Spotify Playlists")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                    isPresented = false
                    }
                    .font(.headline)
                    .foregroundColor(.green)
                }
            }
        }
    }
}

struct SpotifyPlaylistRowView: View {
    let playlist: (id: String, name: String)
    let isAdded: Bool
    let onSelect: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Spotify playlist icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.green.opacity(0.8), Color.green.opacity(0.6)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                // Playlist info
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text("Spotify Playlist")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Add/Check indicator
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                        .scaleEffect(1.1)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                        .opacity(isPressed ? 0.6 : 1.0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: Color.black.opacity(isPressed ? 0.15 : 0.08), radius: isPressed ? 12 : 8, x: 0, y: isPressed ? 4 : 2)
                    .scaleEffect(isPressed ? 0.98 : 1.0)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Enhanced Playlist Picker for truly editable playlists
struct EnhancedPlaylistPickerView: View {
    @ObservedObject var shazamViewModel: ShazamViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    @State private var libraryPlaylists: [LibraryPlaylist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var filteredPlaylists: [LibraryPlaylist] {
        // Only show playlists that can actually be edited
        let editablePlaylists = libraryPlaylists.filter { $0.attributes.canEdit }
        
        // Debug logging
        print("Filtered \(libraryPlaylists.count) total playlists down to \(editablePlaylists.count) truly editable playlists")
        
        // Apply search filtering
        if searchText.isEmpty {
            return editablePlaylists
        } else {
            return editablePlaylists.filter { playlist in
                playlist.attributes.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header with song info and album artwork
                    Group {
                        if let songTitle = shazamViewModel.shazamMedia.title,
                           let artistName = shazamViewModel.shazamMedia.artistName {
                            HStack {
                                // Album artwork
                                if let artworkURL = shazamViewModel.shazamMedia.albumArtURL {
                                    AsyncImage(url: artworkURL) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        case .failure(_):
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.secondary.opacity(0.3))
                                                .frame(width: 60, height: 60)
                                                .overlay(
                                                    Image(systemName: "music.note")
                                                        .foregroundColor(.secondary)
                                                )
                                        case .empty:
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.secondary.opacity(0.2))
                                                .frame(width: 60, height: 60)
                                                .overlay(
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                )
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 60, height: 60)
                                        .overlay(
                                            Image(systemName: "music.note")
                                                .foregroundColor(.secondary)
                                        )
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Adding to Playlist")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(songTitle)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text("by \(artistName)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                        }
                    }
                    
                    Divider()
                        .background(Color.secondary.opacity(0.3))
                    
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search playlists", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6).opacity(0.8))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    
                    // Content
                    if isLoading {
                        Spacer()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading your playlists...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else if let errorMessage = errorMessage {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundColor(.orange)
                            Text("Error Loading Playlists")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                loadEditablePlaylists()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 40)
                        Spacer()
                    } else if filteredPlaylists.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: searchText.isEmpty ? "music.note.list" : "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No editable playlists found" : "No editable playlists match your search")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            if searchText.isEmpty {
                                Text("Create your own playlists in Apple Music to get started")
                                    .font(.subheadline)
                                    .foregroundColor(Color.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 40)
                        Spacer()
                    } else {
                        // Playlist list
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredPlaylists, id: \.id) { playlist in
                                    EnhancedPlaylistRowView(
                                        playlist: playlist,
                                        isAdded: addedPlaylistIDs.contains(playlist.id.rawValue),
                                        onSelect: {
                                            addToSelectedPlaylist(playlist)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
            }
        }
        .onAppear {
            loadEditablePlaylists()
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Message"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
    
    private func loadEditablePlaylists() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let libraryPlaylistsURL = URL(string: "https://api.music.apple.com/v1/me/library/playlists")!
                let request = MusicDataRequest(urlRequest: URLRequest(url: libraryPlaylistsURL))
                let response = try await request.response()
                let playlists = try JSONDecoder().decode(MusicItemCollection<LibraryPlaylist>.self, from: response.data)
                
                DispatchQueue.main.async {
                    self.libraryPlaylists = Array(playlists)
                    self.isLoading = false
                    print("Loaded \(self.libraryPlaylists.count) total playlists from Apple Music API")
                    
                    // Debug: Print playlist details to understand canEdit property
                    for playlist in self.libraryPlaylists.prefix(5) {
                        print("Playlist: '\(playlist.attributes.name)', canEdit: \(playlist.attributes.canEdit)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load playlists: \(error.localizedDescription)"
                    self.isLoading = false
                    print("Error loading playlists: \(error)")
                }
            }
        }
    }
    
    private func addToSelectedPlaylist(_ playlist: LibraryPlaylist) {
        // Prevent adding to the same playlist multiple times
        if addedPlaylistIDs.contains(playlist.id.rawValue) {
            return
        }
        
        Task {
            do {
                // Convert LibraryPlaylist back to regular Playlist for the existing addToPlaylist method
                if let regularPlaylist = shazamViewModel.userPlaylists.first(where: { $0.id.rawValue == playlist.id.rawValue }) {
                    try await shazamViewModel.addToPlaylist(regularPlaylist)
                    DispatchQueue.main.async {
                        self.addedPlaylistIDs.insert(playlist.id.rawValue)
                        self.alertMessage = "Song added to \"\(playlist.attributes.name)\" successfully"
                        self.showAlert = true
                    }
                } else {
                    throw NSError(domain: "PlaylistError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find matching playlist for editing"])
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

struct EnhancedPlaylistRowView: View {
    let playlist: LibraryPlaylist
    let isAdded: Bool
    let onSelect: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Playlist icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.6)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.attributes.name)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text("Editable Playlist")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Add/Check indicator
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                        .scaleEffect(1.1)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .opacity(isPressed ? 0.6 : 1.0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .disabled(isAdded)
    }
}
