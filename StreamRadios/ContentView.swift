// ContentView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.

import SwiftUI
import Combine
import FlagKit

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct ContentView: View {
    @StateObject private var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @State private var isAddStationViewPresented: Bool
    @State private var isPlayerSheetPresented: Bool

    @State private var isEditingMode: Bool
    @State private var selectedStationForEdit: RadioStation?
    @State private var bitrateMessage: String
    @State private var showAlertForCountryBeforeAddingStation: Bool
    @State private var activeSheet: ActiveSheet?
    @State private var selectedTab: Tab
    @EnvironmentObject var alertManager: AlertManager
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var showPodcastListView: Bool
    @State private var seekPosition: Double

    @State private var showAllEpisodes = false
    @State private var scrollToEpisodeID: String?

    init() {
        // Always start on the radio tab regardless of previous state
        let savedTab: Tab = .radio
        
        self._radioPlayer = StateObject(wrappedValue: RadioPlayer.shared)
        self._podcastPlayer = StateObject(wrappedValue: PodcastPlayer.shared)
        
        self._isAddStationViewPresented = State(initialValue: false)
        self._isPlayerSheetPresented = State(initialValue: false)

        self._isEditingMode = State(initialValue: false)
        self._selectedStationForEdit = State(initialValue: nil)
        self._bitrateMessage = State(initialValue: "Loading bitrate information...")
        self._showAlertForCountryBeforeAddingStation = State(initialValue: false)
        self._activeSheet = State(initialValue: nil)
        self._selectedTab = State(initialValue: savedTab)
        self._selectedPodcast = State(initialValue: nil)
        self._showPodcastListView = State(initialValue: false)
        self._seekPosition = State(initialValue: 0)
    }
    
    @Environment(\.horizontalSizeClass) var sizeClass
    
    // MARK: - Device Detection
    
    private var deviceType: DeviceType {
        let height = UIScreen.main.nativeBounds.height
        switch height {
        case 1136: return .iPhoneSE
        case 1334: return .iPhoneSE2
        case 1792: return .iPhone11
        case 2532: return .iPhone13
        case 2556: return .iPhone14Pro
        case 2778: return .iPhone14Plus
        case 2796: return .iPhone15ProMax
        case 2340: return .iPhone15Pro
        case 2622: return .iPhone16Pro
        case 2266: return .iPadMini
        case 2388: return .iPadAir
        case 2732: return .iPadPro
        default: return .other
    }
    }
    
    // MARK: - Layout Properties
    
    private var topPadding: CGFloat {
        switch deviceType {
        case .iPhone15ProMax, .iPhone14Plus: return 10
        case .iPhone16Pro: return 10
        case .iPhone14Pro, .iPhone13: return 10
        case .iPadMini, .iPadAir, .iPadPro: return 10
        default: return 20
        }
    }
    
    private var menuButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 25
        case .iPhone11, .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPhone16Pro: return 30
        case .iPadMini, .iPadAir, .iPadPro: return 40
        default: return 30
        }
    }
    
    private var countryPickerWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 220
        case .iPhone11: return 230
        case .iPhone13, .iPhone14Pro: return 250
        case .iPhone16Pro: return 250
        case .iPhone14Plus, .iPhone15ProMax: return 270
        case .iPhone15Pro: return 260
        case .iPadMini: return 300
        case .iPadAir, .iPadPro: return 400
        default: return 250
        }
    }
    
    private var editButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2, .iPhone11, .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPhone16Pro: return 50
        case .iPadMini: return 100
        case .iPadAir, .iPadPro: return 150
        default: return 50
        }
    }
    
    private var addButtonWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2, .iPhone11: return 40
        case .iPhone16Pro: return 30
        case .iPhone13, .iPhone14Pro, .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro, .iPadMini, .iPadAir, .iPadPro: return 50
        default: return 45
        }
    }
    
    private var playerViewWidth: CGFloat {
        switch deviceType {
        case .iPhoneSE, .iPhoneSE2: return 320
        case .iPhone11, .iPhone13, .iPhone14Pro: return 340
        case .iPhone14Plus, .iPhone15ProMax, .iPhone15Pro: return 350
        case .iPhone16Pro: return 350
        case .iPadMini, .iPadAir: return 500
        case .iPadPro: return 565
        default: return 350
        }
    }
    
    // MARK: - Helper Functions
    
    private func flagImage(for country: String) -> UIImage? {
        return Flag(countryCode: country)?.originalImage
    }
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // Radio Tab - Contains the original full interface
                radioTabContent
                .tabItem {
                    Image(systemName: Tab.radio.icon)
                    Text(Tab.radio.title)
                }
                .tag(Tab.radio)
                
                // Podcast Tab
                PodcastListView(selectedPodcast: $selectedPodcast)
                    .environmentObject(podcastViewModel)
                .tabItem {
                    Image(systemName: Tab.podcast.icon)
                    Text(Tab.podcast.title)
                }
                .tag(Tab.podcast)
                
                // Settings Tab
                SettingsView()
                    .environmentObject(viewModel)
                .tabItem {
                    Image(systemName: Tab.settings.icon)
                    Text(Tab.settings.title)
                }
                .tag(Tab.settings)
                

            }
            .accentColor(.blue)
            .onAppear {
                setupTabView()
                checkAndStartDataSync()
            }
            .onChange(of: selectedTab) { oldValue, newValue in
                if oldValue == .radio && newValue != .radio {
                    // Clear iTunes artwork when navigating away from radio tab
                    radioPlayer.clearITunesArtwork()
                }
            }
            // Removed tab state persistence - app always starts on radio tab
            
            // Data Sync Progress Overlay
            DataSyncProgressView()
        }
    }
    
    // MARK: - Radio Tab Content with Full Original Functionality
    
    private var radioTabContent: some View {
        NavigationView {
            ZStack {
                Color.adaptiveBackground
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Modern top navigation area - Browse by Country section prominently at top
                    VStack(spacing: 16) {
                        // Browse by Country section - now prominently at the top
                        VStack(spacing: 12) {
                            // Section header
                            HStack {
                                Image(systemName: "globe")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.blue)
                                
                                Text("Browse by Country")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.adaptivePrimaryText)
                                
                                Spacer()
                                
                                // Add station button
                                Button(action: {
                                    if viewModel.selectedCountry == "Select Country" {
                                        alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                                    } else {
                                        activeSheet = .addStation
                                    }
                                }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundColor(.blue)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.horizontal, 16)
                            
                            // Country picker - now more prominent
                            HStack {
                                ElegantCountryPickerButton(
                                    selectedCountry: $viewModel.selectedCountry,
                                    countries: viewModel.countries
                                )
                                
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 12)
                        .background(Color.adaptiveSectionBackground)
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        
                        // Sub-tabs: Recent, Favorites, All - moved below country selection
                        elegantTabBar
                    }
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                    .background(Color.adaptiveBackground)
                    
                    // RadioStationListView now handles its own sub-tabs internally
                                        RadioStationListView(isEditing: $isEditingMode,
                                         selectedStationForEdit: $selectedStationForEdit,
                                         selectedTab: $viewModel.selectedTab, 
                                         selectedSubTab: $viewModel.selectedSubTab,
                                         activeSheet: $activeSheet,
                                         isPlayerSheetPresented: $isPlayerSheetPresented)
                        .environmentObject(viewModel)
                        .environmentObject(radioPlayer)
                    
                    // Player area - show podcast players when podcast is playing, radio players when radio is playing
                    if !isEditingMode {
                        if podcastPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                            // Podcast is playing - show podcast compact player with enhanced separation
                            CompactPodcastPlayerView(
                                currentEpisode: currentEpisode,
                                currentFeed: currentFeed,
                                podcastPlayer: podcastPlayer,
                                viewModel: podcastViewModel,
                                selectedPodcast: $selectedPodcast,
                                onListButtonTap: {
                                    // Switch to podcast tab and set the current feed
                                    selectedPodcast = currentFeed
                                    podcastViewModel.fetchAllEpisodes(for: currentFeed)
                                    selectedTab = .podcast
                                },
                                onCloseButtonTap: {
                                    podcastPlayer.pause()
                                    podcastPlayer.currentEpisode = nil
                                    podcastPlayer.currentFeed = nil
                                }
                            )
                            .onTapGesture {
                                if let currentFeed = podcastPlayer.currentFeed {
                                    // Switch to podcast tab and set the current feed
                                    selectedPodcast = currentFeed
                                    podcastViewModel.fetchAllEpisodes(for: currentFeed)
                                    selectedTab = .podcast
                                }
                            }
                        } else if selectedTab == .radio {
                            // Always show radio player when on radio tab
                            if let currentStation = viewModel.currentlyPlayingStation {
                                // Show current station (playing or paused)
                                CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata, isPlayerSheetPresented: $isPlayerSheetPresented)
                                    .environmentObject(radioPlayer)
                                    .environmentObject(viewModel)
                                    .padding(.bottom, 0)
                            } else if !viewModel.stations.isEmpty {
                                // Show first available station as default when no station is set
                                let defaultStation = viewModel.stations.first!
                                CompactPlayerView(currentStation: defaultStation, metadata: nil, isPlayerSheetPresented: $isPlayerSheetPresented)
                                    .environmentObject(radioPlayer)
                                    .environmentObject(viewModel)
                                    .padding(.bottom, 0)
                            }
                        }
                    }
                }
                .padding(.bottom, 0)
                
                if alertManager.showCustomAlert {
                    CustomAlertContainer()
                }
            }
            .sheet(item: $activeSheet) { item in
                switch item {
                case .addStation:
                    AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry) { savedCountry in
                        viewModel.selectedCountry = savedCountry
                        viewModel.selectedSubTab = .all
                    }
                    .environmentObject(viewModel)
                case .editStation:
                    if let station = selectedStationForEdit {
                        EditStationView(station: station, activeSheet: $activeSheet)
                            .environmentObject(viewModel)
                            .environmentObject(permissionManager)
                    } else {
                        // Enhanced fallback view with better error handling
                        VStack(spacing: 24) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.blue)
                            
                            VStack(spacing: 8) {
                                Text("Loading Station...")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                Text("Please wait while we prepare the edit screen")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            
                            Button("Cancel") {
                                activeSheet = nil
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
                        .onAppear {
                            print("⚠️ ContentView: EditStation sheet opened with nil selectedStationForEdit")
                            
                            // Auto-dismiss if station is still nil after timeout
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                if selectedStationForEdit == nil {
                                    print("❌ ContentView: Auto-dismissing edit sheet due to timeout")
                                    activeSheet = nil
                                }
                            }
                        }
                    }
                case .playerSheet:
                    PlayerSheetView()
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
                }
            }

            .sheet(isPresented: $isPlayerSheetPresented) {
                PlayerSheetView()
                    .environmentObject(radioPlayer)
                    .environmentObject(viewModel)
            }

            .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                bitrateMessage = newBitrateMessage
            }
            .onChange(of: activeSheet) { oldValue, newValue in
                // Clear selectedStationForEdit when activeSheet becomes nil
                if newValue == nil {
                    selectedStationForEdit = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlarmStation"))) { notification in
                handleAlarmStationNavigation(notification)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // MARK: - Simple Stylish Tab Bar
    
    @ViewBuilder
    private var elegantTabBar: some View {
        HStack(spacing: 0) {
            ForEach(RadioSubTab.allCases, id: \.self) { subTab in
                simpleTabButton(for: subTab)
            }
        }
        .background(Color.adaptiveSectionBackground)
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    private func simpleTabButton(for subTab: RadioSubTab) -> some View {
        let isSelected = viewModel.selectedSubTab == subTab
        let buttonCornerRadius = cornerRadiusForTab(subTab)
        
        Button(action: {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.selectedSubTab = subTab
            }
        }) {
            VStack(spacing: 6) {
                Image(systemName: subTab.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .adaptiveSecondaryText)
                
                Text(subTab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .adaptiveSecondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: buttonCornerRadius)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func cornerRadiusForTab(_ subTab: RadioSubTab) -> CGFloat {
        switch subTab {
        case .recent: return 8    // Left button - rounded
        case .favorites: return 0  // Middle button - square
        case .all: return 8       // Right button - rounded
        }
    }
    
    // MARK: - Helper Functions
    
    private func setupTabView() {
        // Configure tab bar appearance
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    private func checkAndStartDataSync() {
        // Check if this is a fresh install or if sync is needed
        if DataSyncManager.shared.checkIfSyncNeeded() {
            print("🔄 Fresh install detected - starting data synchronization...")
            DataSyncManager.shared.startFreshInstallSync()
        } else {
            print("✅ App has been launched before and sync is complete")
        }
    }
    
    private func handleAlarmStationNavigation(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let stationId = userInfo["stationId"] as? String,
              let stationCountry = userInfo["stationCountry"] as? String,
              let isFavorite = userInfo["isFavorite"] as? Bool else {
            print("❌ Invalid alarm station navigation data")
            return
        }
        
        print("🧭 Navigating to alarm station: \(stationId) in country: \(stationCountry)")
        
        // Ensure we're on the radio tab
        selectedTab = .radio
        
        // Navigate to the appropriate sub-tab based on station properties
        if isFavorite {
            // Station is a favorite - navigate to favorites tab
            viewModel.selectedSubTab = .favorites
            print("📍 Navigated to Favorites tab for alarm station")
        } else {
            // Station is not a favorite - navigate to All tab and set country
            viewModel.selectedCountry = stationCountry
            viewModel.selectedSubTab = .all
            print("📍 Navigated to All tab for country: \(stationCountry)")
        }
        
        // Verify navigation completed and station is visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let station = viewModel.stations.first(where: { $0.id == stationId }) {
                print("✅ Alarm station found after navigation: \(station.name)")
                
                // Ensure the station is playing if it's not already
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !radioPlayer.isPlaying || radioPlayer.currentlyPlayingStation?.id != stationId {
                        if let index = viewModel.stations.firstIndex(where: { $0.id == stationId }) {
                            print("🔄 Ensuring alarm station playback: \(station.name)")
                            radioPlayer.playStation(at: index, from: viewModel.stations)
                        }
                    }
                }
            } else {
                print("❌ Alarm station not found after navigation: \(stationId)")
            }
        }
    }
}

// MARK: - Compact Player View

struct CompactPlayerView: View {
    let currentStation: RadioStation
    let metadata: String?
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPlayerSheetPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Safe space at top instead of blue line (matching podcast player)
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
            
            // Compact single-row layout (matching podcast player)
            HStack(spacing: 12) {
                // Tappable artwork area for opening player sheet
                Button(action: {
                    print("🖼️ Artwork tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.adaptiveBorder)
                            .frame(width: 44, height: 44)
                        
                        albumArtworkView
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                // Tappable text area for opening player sheet
                Button(action: {
                    print("📝 Text area tapped - OPENING player sheet")
                    isPlayerSheetPresented.toggle()
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentStation.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.adaptivePrimaryText)
                            .lineLimit(nil) // Allow unlimited lines
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                        
                        if let metadata = metadata, !metadata.isEmpty {
                            Text(metadata)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.adaptiveSecondaryText)
                                .lineLimit(nil) // Allow unlimited lines
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                        } else {
                            Text("Live Radio")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.adaptiveSecondaryText)
                                .lineLimit(nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                // Essential controls only - just play/pause button
                HStack(spacing: 8) {
                    // Main play/pause button
                    Button(action: {
                        print("⏯️ Play/pause button action - NOT opening sheet")
                        radioPlayer.playPause()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 36, height: 36)
                            
                            if radioPlayer.isBuffering {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.adaptiveSecondaryBackground)
        .frame(minHeight: 60) // Minimum height with ability to expand
    }
    
    @ViewBuilder
    private var albumArtworkView: some View {
        // Priority: iTunes album art > stream album art > station icon > default
        if let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
            Image(uiImage: iTunesAlbumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let albumArt = radioPlayer.albumArt {
            Image(uiImage: albumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let iconData = currentStation.iconData, 
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white.opacity(0.1))
        } else {
            ZStack {
                Color.adaptiveBorder
                
                if !currentStation.name.isEmpty {
                    Text(String(currentStation.name.prefix(2)).uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.adaptivePrimaryText)
                } else {
                    Image(systemName: "radio")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.adaptivePrimaryText)
                }
            }
        }
    }
}

// MARK: - Compact Podcast Player View

struct UnifiedPodcastPlayerView: View {
    let currentEpisode: PodcastEpisode
    let currentFeed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @Binding var selectedPodcast: PodcastFeed?
    var onListButtonTap: (() -> Void)?
    var onCloseButtonTap: (() -> Void)?
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var sizeClass
    
    // Responsive sizing
    private var artworkSize: CGFloat {
        sizeClass == .compact ? 50 : 60
    }
    
    private var buttonSize: CGFloat {
        sizeClass == .compact ? 36 : 44
    }
    
    private var playButtonSize: CGFloat {
        sizeClass == .compact ? 44 : 52
    }
    
    private var iconSize: CGFloat {
        sizeClass == .compact ? 14 : 16
    }
    
    private var playIconSize: CGFloat {
        sizeClass == .compact ? 18 : 20
    }
    
    private var horizontalPadding: CGFloat {
        sizeClass == .compact ? 12 : 16
    }
    
    private var buttonSpacing: CGFloat {
        sizeClass == .compact ? 8 : 12
    }
    
    // Navigation action to currently playing episode
    private func navigateToCurrentEpisode() {
        print("Navigating to currently playing episode: \(currentEpisode.title)")
        selectedPodcast = currentFeed
        viewModel.fetchAllEpisodes(for: currentFeed)
        // Use the existing onListButtonTap functionality if available
        onListButtonTap?()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Safe space at top instead of blue line
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
            
            // Compact single-row layout with top-aligned artwork
                    HStack(alignment: .top, spacing: 10) {
            // Tappable artwork area - top aligned
            Button(action: navigateToCurrentEpisode) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.adaptiveBorder)
                        .frame(width: 50, height: 50)
                    
                    feedArtworkView
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .buttonStyle(PlainButtonStyle())
            
                            // Tappable text area - give it maximum available space with dynamic height
            Button(action: navigateToCurrentEpisode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentEpisode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.adaptivePrimaryText)
                        .lineLimit(nil) // Remove line limit to allow unlimited lines
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(currentFeed.title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.adaptiveSecondaryText)
                        .lineLimit(1) // Keep podcast name to 1 line
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PlainButtonStyle())
            
            // Player controls with time elapsed below
            VStack(spacing: 4) {
                // Essential controls only - more compact
                HStack(spacing: 6) {
                    // Skip backward 15s - smaller
                    Button(action: podcastPlayer.skipBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Main play/pause button - compact
                    Button(action: podcastPlayer.togglePlayPause) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 34, height: 34)
                            
                            Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Skip forward 30s - smaller
                    Button(action: podcastPlayer.skipForward) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Time elapsed/total display
                Text("\(formatTimeForDisplay(podcastPlayer.currentTime))/\(formatTimeForDisplay(podcastPlayer.duration))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.adaptiveSecondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    .background(
        Color(red: 0.05, green: 0.05, blue: 0.05)
    )
    .fixedSize(horizontal: false, vertical: true) // Allow the entire player to expand vertically as needed
    }

    
    @ViewBuilder
    private var feedArtworkView: some View {
        // Priority: Direct image data > Base64 icon data > default
        if let imageData = currentFeed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else if let iconData = currentFeed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else {
            defaultPodcastIcon
        }
    }
    
            @ViewBuilder
    private var defaultPodcastIcon: some View {
        ZStack {
            Color.adaptiveBorder
            
                                Image(systemName: "microphone")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.adaptivePrimaryText)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func formatTimeForDisplay(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "00:00" }
        
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Mini Podcast Player View (Full Player Style)

typealias MiniPodcastPlayerView = UnifiedPodcastPlayerView

struct CompactPodcastPlayerView: View {
    let currentEpisode: PodcastEpisode
    let currentFeed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @ObservedObject var viewModel: PodcastViewModel
    @Binding var selectedPodcast: PodcastFeed?
    var onListButtonTap: (() -> Void)?
    var onCloseButtonTap: (() -> Void)?
    
    var body: some View {
        UnifiedPodcastPlayerView(
            currentEpisode: currentEpisode,
            currentFeed: currentFeed,
            podcastPlayer: podcastPlayer,
            viewModel: viewModel,
            selectedPodcast: $selectedPodcast,
            onListButtonTap: onListButtonTap,
            onCloseButtonTap: onCloseButtonTap
        )
    }

}

// MARK: - Currently Playing View

struct CurrentlyPlayingView: View {
    let currentStation: RadioStation
    let metadata: String?
    @EnvironmentObject var radioPlayer: RadioPlayer
    
    var body: some View {
        HStack(spacing: 12) {
            // Album artwork - modern 64x64 design matching station list
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 64, height: 64)
                
                albumArtworkView
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Station and song info
            VStack(alignment: .leading, spacing: 2) {
                Text(currentStation.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if let metadata = metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Live Radio")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.adaptiveSecondaryText)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Play/pause button
            Button(action: {
                radioPlayer.playPause()
            }) {
                ZStack {
                    if radioPlayer.isBuffering {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.blue)
            .clipShape(Circle())
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private var albumArtworkView: some View {
        // Priority: iTunes album art > stream album art > station icon > default
        if let iTunesAlbumArt = radioPlayer.iTunesAlbumArt {
            Image(uiImage: iTunesAlbumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let albumArt = radioPlayer.albumArt {
            Image(uiImage: albumArt)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let iconData = currentStation.iconData, 
                  let imageData = Data(base64Encoded: iconData),
                  let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white.opacity(0.1))
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                
                if !currentStation.name.isEmpty {
                                                Text(String(currentStation.name.prefix(2)).uppercased())
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.adaptivePrimaryText)
                } else {
                                            Image(systemName: "radio")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.adaptivePrimaryText)
                }
            }
        }
    }
}

// MARK: - Custom Alert Container

struct CustomAlertContainer: View {
    @EnvironmentObject var alertManager: AlertManager
    
    var body: some View {
        GeometryReader { geometry in
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    alertManager.dismissAlert()
                }
            
            CustomAlertView(
                title: alertManager.customAlertTitle,
                message: alertManager.customAlertMessage,
                buttonText: alertManager.customAlertPrimaryButtonText,
                buttonAction: {
                    alertManager.dismissAlert()
                    alertManager.customAlertPrimaryAction?()
                },
                secondaryButtonText: alertManager.customAlertSecondaryButtonText,
                secondaryButtonAction: {
                    alertManager.dismissAlert()
                    alertManager.customAlertSecondaryAction?()
                }
            )
            .frame(width: 300)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .transition(.opacity)
        .zIndex(2)
    }
}

// MARK: - Device Type Enum

enum DeviceType {
    case iPhoneSE
    case iPhoneSE2
    case iPhone11
    case iPhone13
    case iPhone14Pro
    case iPhone14Plus
    case iPhone15ProMax
    case iPhone15Pro
    case iPhone16Pro
    case iPadMini
    case iPadAir
    case iPadPro
    case other
}

// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
            .environmentObject(AlertManager())
            .environmentObject(RadioStationViewModel())
    }
}
