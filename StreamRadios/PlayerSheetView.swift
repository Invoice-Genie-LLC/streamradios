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

// MARK: - View Extension for Conditional Modifiers
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

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
    
    // Computed properties for adaptive colors
    private var backButtonColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var selectedTextColor: Color {
        colorScheme == .dark ? .black : .white
    }
    
    private var unselectedTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var selectedBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    private var topBarBackgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9)
    }
    
    private var segmentedControlBackgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9)
    }
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
    @State private var selectedTab = 0 // 0: Now Playing, 1: Shazam
    @State private var activeSheet: ActiveSheetPlayer?
    @State private var forceTokenRefresh = false
    @State private var debugLog = ""
    @State private var debugMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top navigation bar with custom segmented control
                HStack(spacing: 16) {
                    // Back button (downward arrow)
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                        if isShazaming {
                            shazamViewModel.stopListening()
                            isShazaming = false
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .foregroundColor(backButtonColor)
                            .frame(width: 44, height: 44)
                    }
                    
                    // Custom segmented control - full width
                    HStack(spacing: 2) {
                        // Now Playing button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = 0
                                if isShazaming {
                                    shazamViewModel.stopListening()
                                    isShazaming = false
                                }
                            }
                        }) {
                            Text("Now Playing")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedTab == 0 ? selectedTextColor : unselectedTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(selectedTab == 0 ? selectedBackgroundColor : Color.clear)
                                )
                        }
                        
                        // Shazam button
                        if !ShazamFeatureSwitch.isHideTapToShazamEnabled {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTab = 1
                                    if !isShazaming {
                                        permissionManager.checkMicrophonePermission { granted in
                                            DispatchQueue.main.async {
                                                if granted {
                                                    shazamViewModel.startOrEndListening()
                                                    isShazaming = true
                                                } else {
                                                    self.alertMessage = "Microphone access is required for Shazam. Please go to Settings > Privacy & Security > Microphone and enable access for this app, then try again."
                                                    self.showAlert = true
                                                }
                                            }
                                        }
                                    }
                                }
                            }) {
                                Text("Shazam")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(selectedTab == 1 ? selectedTextColor : unselectedTextColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20)
                                            .fill(selectedTab == 1 ? selectedBackgroundColor : Color.clear)
                                    )
                            }
                        }
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(segmentedControlBackgroundColor)
                    )
                    .conditionalGlassEffect(cornerRadius: 24)
                    
                    // Spacer to balance layout
                    Spacer()
                        .frame(width: 44)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(topBarBackgroundColor)
                )
                .conditionalGlassEffect(cornerRadius: 24)
                
                // Swipeable content container
                TabView(selection: $selectedTab) {
                    nowPlayingContentView
                        .tag(0)
                    
                    if !ShazamFeatureSwitch.isHideTapToShazamEnabled {
                        shazamContentView
                            .tag(1)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
                
                // Bottom controls
                bottomControlsView
            }
            .background(Color.adaptiveBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
        .alert(isPresented: $permissionManager.isPermissionAlertPresented) {
            Alert(
                title: Text("Permission Required"),
                message: Text(permissionManager.alertMessage),
                primaryButton: .default(Text("Settings"), action: permissionManager.openAppSettings),
                secondaryButton: .cancel()
            )
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


            }
        }



    }
    
    // MARK: - Content Views
    @ViewBuilder
    private var nowPlayingContentView: some View {
        VStack(spacing: hasChapters ? 8 : 10) {
            // Conditional top spacing - more space when no Shazam tab
            Spacer(minLength: ShazamFeatureSwitch.isHideTapToShazamEnabled ? 40 : 0)
            
            // Station artwork - larger when no Shazam for better visual balance
            StationArtworkView
                .frame(height: ShazamFeatureSwitch.isHideTapToShazamEnabled ? 280 : 240)
            
            // Station title and metadata
            VStack(spacing: 8) {
                if let currentStationIndex = radioPlayer.currentStationIndex,
                   let currentStation = viewModel.stations[safe: currentStationIndex] {
                    Text(currentStation.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    
                    if let shazamTitle = radioPlayer.displayTitle, let shazamArtist = radioPlayer.displayArtist {
                        Text("\(shazamTitle) — \(shazamArtist)")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                        let split = radioPlayer.splitArtistTitle(from: metadata, fallbackArtist: currentStation.name, fallbackTitle: metadata)
                        Text("\(split.title) — \(split.artist)")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text("No song information available")
                            .font(.subheadline)
                            .foregroundColor(.adaptiveSecondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var shazamContentView: some View {
        VStack(spacing: hasChapters ? 8 : 10) {
            // Conditional top spacing
            Spacer(minLength: 0)
            
            // Shazam artwork
            ShazamArtworkView
                .frame(height: 240)
            
            // Song information
            VStack(spacing: 8) {
                Text(shazamViewModel.shazamMedia.title ?? "Listening...")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.adaptivePrimaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                
                Text(shazamViewModel.shazamMedia.artistName ?? "Tap to identify music")
                    .font(.subheadline)
                    .foregroundColor(.adaptiveSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            
            // Shazam action button
            if shazamViewModel.shazamMedia.title != nil {
                Button(action: {
                    requestMusicAuthorization()
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
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var bottomControlsView: some View {
        VStack(spacing: 8) {
            PlayerView()
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
            
            AirPlayButtonView()
                .frame(width: 44, height: 44)
        }
        .padding(.bottom, 8)
    }
    
    private var hasChapters: Bool {
        return false // Radio doesn't have chapters
    }
    
    // MARK: - Artwork Views
    @ViewBuilder
    private var StationArtworkView: some View {
        GeometryReader { geometry in
            let artworkSize = min(geometry.size.width * 0.65, 240)
            
            // Priority: iTunes artwork when playing > station artwork when playing > station icon > default
            if radioPlayer.isPlaying, let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
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
            } else if radioPlayer.isPlaying, let albumArt = radioPlayer.albumArt {
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
            } else if let currentStationIndex = radioPlayer.currentStationIndex,
                      let currentStation = viewModel.stations[safe: currentStationIndex],
                      let iconData = currentStation.iconData,
                      let imageData = Data(base64Encoded: iconData),
                      let image = UIImage(data: imageData) {
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
                                .font(.largeTitle)
                                .foregroundColor(.white.opacity(0.8))
                        )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    @ViewBuilder
    private var ShazamArtworkView: some View {
        GeometryReader { geometry in
            let artworkSize = min(geometry.size.width * 0.65, 240)
            
            if let url = shazamViewModel.shazamMedia.albumArtURL {
                HStack {
                    Spacer()
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: artworkSize, height: artworkSize)
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
                                .frame(width: artworkSize, height: artworkSize)
                                .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.largeTitle)
                                        .foregroundColor(.white.opacity(0.8))
                                )
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
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
                        .frame(width: artworkSize, height: artworkSize)
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundColor(.white.opacity(0.8))
                        )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
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
    
    private func requestMusicAuthorization() {
        Task {
            let status = await MusicAuthorization.request()
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.showingConfirmationDialog = true
                case .denied, .restricted:
                    self.alertMessage = "Apple Music access is required to save songs. Please go to Settings > Privacy & Security > Apple Music and enable access for this app, then try again."
                    self.showAlert = true
                case .notDetermined:
                    self.alertMessage = "Apple Music access is required to save songs. Please authorize access to Apple Music and try again."
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
                        self.activeSheet = .playlistPicker
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
}

// MARK: - Supporting Views
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

// MARK: - Enhanced Playlist Picker
struct EnhancedPlaylistPickerView: View {
    @ObservedObject var shazamViewModel: ShazamViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    
    var filteredPlaylists: [Playlist] {
        let activePlaylists = Array(shazamViewModel.userPlaylists).filter { playlist in
            if let curatorName = playlist.curatorName, !curatorName.isEmpty {
                let excludedCurators = ["Apple Music", "Apple", "apple music", "apple"]
                return !excludedCurators.contains { curatorName.localizedCaseInsensitiveContains($0) }
            }
            return playlist.curatorName == nil || playlist.curatorName?.isEmpty == true
        }
        
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
            VStack(spacing: 0) {
                // Header with song info
                if let songTitle = shazamViewModel.shazamMedia.title,
                   let artistName = shazamViewModel.shazamMedia.artistName {
                    VStack(spacing: 8) {
                        HStack(spacing: 16) {
                            if let artworkURL = shazamViewModel.shazamMedia.albumArtURL {
                                AsyncImage(url: artworkURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 60, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    default:
                                        Image(systemName: "music.note")
                                            .font(.title)
                                            .foregroundColor(.blue)
                                            .frame(width: 60, height: 60)
                                            .background(Color(.systemGray5))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Adding to Playlist")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(songTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("by \(artistName)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                    }
                }
                
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search playlists", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding()
                
                // Playlist list
                List(filteredPlaylists, id: \.id) { playlist in
                    Button(action: {
                        addToPlaylist(playlist)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                if addedPlaylistIDs.contains(playlist.id.rawValue) {
                                    Text("Added ✓")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            Spacer()
                            if addedPlaylistIDs.contains(playlist.id.rawValue) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(addedPlaylistIDs.contains(playlist.id.rawValue))
                }
            }
            .navigationTitle("Choose Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Message"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
    
    private func addToPlaylist(_ playlist: Playlist) {
        Task {
            do {
                try await shazamViewModel.addToPlaylist(playlist)
                DispatchQueue.main.async {
                    self.addedPlaylistIDs.insert(playlist.id.rawValue)
                    self.alertMessage = "Song added to '\(playlist.name)'"
                    self.showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "Error adding to playlist: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}

struct PlayerSheetView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerSheetView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
    }
}
