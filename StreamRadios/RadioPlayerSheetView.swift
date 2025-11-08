//
//  RadioPlayerSheetView.swift
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

struct RadioPlayerSheetView: View {
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
    @State private var showSleepTimer = false
    @State private var sleepTimerActive = false
    @State private var sleepTimerEndTime: Date?
    @State private var isFavorite = false
    @State private var timerCheckTimer: Timer?
    
    // UserDefaults keys for timer persistence
    private let timerActiveKey = "RadioSleepTimerActive"
    private let timerEndTimeKey = "RadioSleepTimerEndTime"
    
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
                    
                    // Simple segmented picker
                    if !ShazamFeatureSwitch.isHideTapToShazamEnabled {
                        Picker("", selection: $selectedTab) {
                            Text("Now Playing").tag(0)
                            Text("Shazam").tag(1)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .onChange(of: selectedTab) { newValue in
                            if newValue == 0 && isShazaming {
                                shazamViewModel.stopListening()
                                isShazaming = false
                            } else if newValue == 1 && !isShazaming {
                                permissionManager.checkMicrophonePermission { granted in
                                    DispatchQueue.main.async {
                                        if granted {
                                            shazamViewModel.startOrEndListening()
                                            isShazaming = true
                                        } else {
                                            self.alertMessage = "Microphone access is required for Shazam. Please go to Settings > Privacy & Security > Microphone and enable access for this app, then try again."
                                            self.showAlert = true
                                            selectedTab = 0
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Picker("", selection: $selectedTab) {
                            Text("Now Playing").tag(0)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    
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
            loadFavoriteState()
        }
        .onDisappear {
            if isShazaming {
                shazamViewModel.stopListening()
                isShazaming = false
            }
            // Keep timer running even when sheet closes
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
                PlaylistPickerView(shazamViewModel: shazamViewModel)
            }
        }
        .sheet(isPresented: $showSleepTimer) {
            RadioSleepTimerSheet(
                sleepTimerActive: $sleepTimerActive,
                sleepTimerEndTime: $sleepTimerEndTime,
                timerCheckTimer: $timerCheckTimer,
                radioPlayer: radioPlayer,
                saveTimerState: saveTimerState,
                clearTimerState: clearTimerState
            )
            .presentationDetents([.height(450), .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            restoreTimerState()
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
    
    // Get filtered stations based on current tab for skip/previous navigation
    private var filteredStationsForNavigation: [RadioStation] {
        switch viewModel.selectedSubTab {
        case .all:
            // All tab shows stations from the selected country only, sorted alphabetically
            if viewModel.selectedCountry == "Select Country" {
                return []
            } else {
                var stations = viewModel.stations.filter { station in
                    // Filter by selected country and ensure valid country information
                    let hasValidCountry = !station.country.isEmpty &&
                                        station.country != "Unknown Region" &&
                                        station.country != "Select Country" &&
                                        !station.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    let matches = station.country == viewModel.selectedCountry && hasValidCountry
                    return matches
                }
                
                // Sort alphabetically by name based on toggle setting
                if viewModel.isAscendingSort {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
                }
                return stations
            }
        case .recent:
            // Recent tab shows recent stations from ALL countries regardless of country selection
            return viewModel.recentStations()
        case .favorites:
            // Favorites respects CloudKit-synced favoriteOrder
            return viewModel.favoriteStations()
        }
    }
    
    @ViewBuilder
    private var bottomControlsView: some View {
        VStack(spacing: 8) {
            PlayerView(stationsForNavigation: filteredStationsForNavigation)
                .environmentObject(radioPlayer)
                .environmentObject(viewModel)
            
            // Footer menu
            ZStack(alignment: .top) {
                // Background that extends to bottom safe area
                Color.adaptiveSecondaryBackground
                    .edgesIgnoringSafeArea(.bottom)
                
                // Menu content at natural size
                bottomMenuView
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    // MARK: - Bottom Menu
    private var bottomMenuView: some View {
        HStack(spacing: 0) {
            // AirPlay button
            VStack(spacing: 4) {
                AirPlayButtonView()
                    .frame(width: 44, height: 24)
                    .tint(.adaptivePrimaryText)
                Text("AirPlay")
                    .font(.caption)
                    .foregroundColor(.adaptiveSecondaryText)
            }
            .frame(maxWidth: .infinity)
            
            // Favorite button
            Button(action: {
                toggleFavorite()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 24))
                        .foregroundColor(isFavorite ? .red : .adaptivePrimaryText)
                    Text(isFavorite ? "Favorited" : "Favorite")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Sleep Timer button
            Button(action: {
                showSleepTimer = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: sleepTimerActive ? "moon.fill" : "moon")
                        .font(.system(size: 24))
                        .foregroundColor(sleepTimerActive ? .blue : .adaptivePrimaryText)
                    Text(sleepTimerActive ? "Timer On" : "Timer")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
    
    private func loadFavoriteState() {
        guard let currentStationIndex = radioPlayer.currentStationIndex,
              let currentStation = viewModel.stations[safe: currentStationIndex] else {
            isFavorite = false
            return
        }
        isFavorite = currentStation.isFavorite
    }
    
    private func toggleFavorite() {
        guard let currentStationIndex = radioPlayer.currentStationIndex,
              let currentStation = viewModel.stations[safe: currentStationIndex] else {
            return
        }
        
        viewModel.toggleFavorite(for: currentStation)
        isFavorite.toggle()
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
    
    // MARK: - Timer State Persistence
    private func restoreTimerState() {
        let userDefaults = UserDefaults.standard
        
        // Check if timer was active
        guard userDefaults.bool(forKey: timerActiveKey) else {
            sleepTimerActive = false
            return
        }
        
        // Check if timer end time has passed
        if let endTime = userDefaults.object(forKey: timerEndTimeKey) as? Date {
            if endTime > Date() {
                // Timer is still valid
                sleepTimerEndTime = endTime
                sleepTimerActive = true
                
                // Recreate the timer
                timerCheckTimer?.invalidate()
                timerCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    let currentTime = Date()
                    
                    if let endTime = self.sleepTimerEndTime, currentTime >= endTime {
                        self.radioPlayer.pause()
                        self.sleepTimerActive = false
                        self.sleepTimerEndTime = nil
                        timer.invalidate()
                        self.timerCheckTimer = nil
                        self.clearTimerState()
                    }
                }
                
                let remainingTime = endTime.timeIntervalSinceNow
                print("✅ Restored radio timer with \(Int(remainingTime/60)) minutes remaining")
            } else {
                // Timer expired, clear it
                clearTimerState()
                print("⏰ Radio timer expired, clearing state")
            }
        }
    }
    
    func saveTimerState() {
        let userDefaults = UserDefaults.standard
        userDefaults.set(sleepTimerActive, forKey: timerActiveKey)
        
        if let endTime = sleepTimerEndTime {
            userDefaults.set(endTime, forKey: timerEndTimeKey)
        }
        
        userDefaults.synchronize()
    }
    
    func clearTimerState() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: timerActiveKey)
        userDefaults.removeObject(forKey: timerEndTimeKey)
        userDefaults.synchronize()
        
        sleepTimerActive = false
        sleepTimerEndTime = nil
        timerCheckTimer?.invalidate()
        timerCheckTimer = nil
    }
}

// MARK: - Supporting Views
struct AirPlayButtonView: UIViewRepresentable {
    @Environment(\.colorScheme) var colorScheme
    
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        updateColors(for: view)
        return view
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.frame = CGRect(x: 0, y: 0, width: 70, height: 70)
        updateColors(for: uiView)
    }
    
    private func updateColors(for view: AVRoutePickerView) {
        // Match adaptivePrimaryText colors used by other buttons
        let primaryColor = colorScheme == .dark ? UIColor.white : UIColor.black
        view.activeTintColor = primaryColor
        view.tintColor = primaryColor
    }
}

// MARK: - Playlist Picker
struct PlaylistPickerView: View {
    @ObservedObject var shazamViewModel: ShazamViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    @FocusState private var isSearchFieldFocused: Bool
    
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
                        .foregroundColor(.adaptiveSecondaryText)
                        .font(.body)
                    
                    TextField("Search playlists", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .focused($isSearchFieldFocused)
                    
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.adaptiveSecondaryText)
                                .font(.body)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.adaptiveSectionBackground)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onAppear {
                    // Automatically focus the search field when it appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isSearchFieldFocused = true
                    }
                }
                
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

// MARK: - Radio Sleep Timer Sheet
struct RadioSleepTimerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Binding var sleepTimerActive: Bool
    @Binding var sleepTimerEndTime: Date?
    @Binding var timerCheckTimer: Timer?
    @ObservedObject var radioPlayer: RadioPlayer
    let saveTimerState: () -> Void
    let clearTimerState: () -> Void
    
    @State private var selectedTime = Date()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    // Drag indicator
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                    
                    Text("Sleep Timer")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Time picker section
                        VStack(spacing: 16) {
                            HStack {
                                Text("Stop playback at")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            
                            DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                                .datePickerStyle(WheelDatePickerStyle())
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            
                            Button(action: {
                                setTimer()
                            }) {
                                Text("Set Timer")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(12)
                        
                        // Active timer display
                        if sleepTimerActive, let endTime = sleepTimerEndTime {
                            VStack(spacing: 16) {
                                Button(action: {
                                    cancelTimer()
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Timer Active")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text("Stops at \(timeString(from: endTime))")
                                                .font(.body)
                                                .foregroundColor(.secondary)
                                            Text("Tap to cancel")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.title3)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            // Set initial time to current time
            selectedTime = Date()
        }
    }
    
    private func setTimer() {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: selectedTime)
        let now = Date()
        
        // Create target time with today's date but selected hour/minute (seconds set to 0)
        guard var targetTime = calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: now) else {
            return
        }
        
        // If selected time is in the past (including same minute), set it for tomorrow
        if targetTime <= now {
            targetTime = calendar.date(byAdding: .day, value: 1, to: targetTime) ?? targetTime
        }
        
        sleepTimerEndTime = targetTime
        sleepTimerActive = true
        
        // Save timer state to UserDefaults
        saveTimerState()
        
        // Cancel any existing timer
        timerCheckTimer?.invalidate()
        
        // Create a timer that checks every second
        timerCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let currentTime = Date()
            
            // Check if we've reached or passed the target time
            if let endTime = self.sleepTimerEndTime, currentTime >= endTime {
                self.radioPlayer.pause()
                self.sleepTimerActive = false
                self.sleepTimerEndTime = nil
                timer.invalidate()
                self.timerCheckTimer = nil
                self.clearTimerState()
            }
        }
        
        dismiss()
    }
    
    private func cancelTimer() {
        sleepTimerActive = false
        sleepTimerEndTime = nil
        timerCheckTimer?.invalidate()
        timerCheckTimer = nil
        
        // Clear timer state from UserDefaults
        clearTimerState()
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct RadioPlayerSheetView_Previews: PreviewProvider {
    static var previews: some View {
        RadioPlayerSheetView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel())
    }
}
