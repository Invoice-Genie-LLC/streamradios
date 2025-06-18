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
    @State private var isAddStationViewPresented: Bool
    @State private var isPlayerSheetPresented: Bool

    @State private var isEditingMode: Bool
    @State private var selectedStationForEdit: RadioStation?
    @State private var bitrateMessage: String
    @State private var showAlertForCountryBeforeAddingStation: Bool
    @State private var activeSheet: ActiveSheet?
    @State private var selectedTab: Tab
    @EnvironmentObject var alertManager: AlertManager
    @StateObject private var podcastViewModel: PodcastViewModel
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var showPodcastListView: Bool
    @State private var seekPosition: Double
    @State private var showPodcastPlayerSheet = false
    @State private var showAllEpisodes = false
    @State private var scrollToEpisodeID: String?

    init() {
        let savedTab: Tab
        if let savedTabRawValue = UserDefaults.standard.object(forKey: "selectedTab") as? Int,
           let tab = Tab(rawValue: savedTabRawValue) {
            savedTab = tab
        } else {
            savedTab = .radio
        }
        
        self._radioPlayer = StateObject(wrappedValue: RadioPlayer.shared)
        self._podcastViewModel = StateObject(wrappedValue: PodcastViewModel())
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
        TabView(selection: $selectedTab) {
            // Radio Tab - Contains the original full interface
            radioTabContent
            .tabItem {
                Image(systemName: Tab.radio.icon)
                Text(Tab.radio.title)
            }
            .tag(Tab.radio)
            
            // Podcast Tab
            PodcastListView()
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
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            UserDefaults.standard.set(newTab.rawValue, forKey: "selectedTab")
        }
    }
    
    // MARK: - Radio Tab Content with Full Original Functionality
    
    private var radioTabContent: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Modern top navigation area
                    VStack(spacing: 12) {
                        // Top row with country picker, edit, and add buttons
                        HStack(spacing: 12) {
                            // Modern elegant country picker
                            ElegantCountryPickerButton(
                                selectedCountry: $viewModel.selectedCountry,
                                countries: viewModel.countries
                            )
                            
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
                        
                        // Sub-tabs: Recent, Favorites, All - Elegant Design
                        elegantTabBar
                    }
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                    .background(Color.black)
                    
                    // RadioStationListView now handles its own sub-tabs internally
                                        RadioStationListView(isEditing: $isEditingMode,
                                         selectedStationForEdit: $selectedStationForEdit,
                                         selectedTab: $viewModel.selectedTab, 
                                         selectedSubTab: $viewModel.selectedSubTab,
                                         activeSheet: $activeSheet,
                                         isPlayerSheetPresented: $isPlayerSheetPresented)
                        .environmentObject(viewModel)
                        .environmentObject(radioPlayer)
                    
                    Spacer()
                    
                    // Compact mini-player matching screenshot design
                    if let currentStation = viewModel.currentlyPlayingStation {
                        VStack(spacing: 0) {
                            // Top divider for visual separation
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 0.5)
                            
                            CompactPlayerView(currentStation: currentStation, metadata: radioPlayer.metadata)
                                .environmentObject(radioPlayer)
                                .environmentObject(viewModel)
                                .onTapGesture {
                                    isPlayerSheetPresented.toggle()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                                .padding(.bottom, max(UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0, 4))
                                .background(Color(red: 0.05, green: 0.05, blue: 0.05)) // Darker gray
                        }
                    }
                    
                    if podcastPlayer.isPlaying && !radioPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                        MiniPlayerView(
                            podcastPlayer: podcastPlayer,
                            viewModel: podcastViewModel,
                            selectedPodcast: $selectedPodcast,
                            onListButtonTap: {
                                if let currentFeed = podcastPlayer.currentFeed {
                                    selectedPodcast = currentFeed
                                    podcastViewModel.fetchAllEpisodes(for: currentFeed)
                                    scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                                    showPodcastPlayerSheet = true
                                }
                            },
                            onCloseButtonTap: {
                                podcastPlayer.pause()
                                podcastPlayer.currentEpisode = nil
                                podcastPlayer.currentFeed = nil
                            },
                            isPlaylistButtonDisabled: false
                        )
                        .transition(.move(edge: .bottom))
                        .zIndex(1)
                    }
                }
                .padding(.bottom, sizeClass == .regular ? 40 : 0)
                

                
                if alertManager.showCustomAlert {
                    CustomAlertContainer()
                }
            }
            .sheet(item: $activeSheet, onDismiss: { activeSheet = nil }) { item in
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
            .sheet(isPresented: $showPodcastPlayerSheet) {
                if let podcast = selectedPodcast {
                    PodcastPlayerView(
                        viewModel: podcastViewModel,
                        feed: podcast,
                        initialScrollToEpisodeID: podcastPlayer.currentEpisode?.id,
                        podcastPlayer: podcastPlayer,
                        selectedPodcast: $selectedPodcast,
                        episodeToScrollTo: Binding(
                            get: { podcastPlayer.currentEpisode },
                            set: { _ in }
                        )
                    )
                }
            }
            .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                bitrateMessage = newBitrateMessage
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
        .background(Color.gray.opacity(0.1))
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
                    .foregroundColor(isSelected ? .blue : .gray)
                
                Text(subTab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .gray)
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
    
    private func saveSelectedTab(_ tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
    }
    
    private func setupTabView() {
        // Configure tab bar appearance
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - Compact Player View

struct CompactPlayerView: View {
    let currentStation: RadioStation
    let metadata: String?
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    
    var body: some View {
        VStack(spacing: 6) {
            // Top row: Album artwork and controls
            HStack(spacing: 16) {
                // Album artwork - compact size
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 56, height: 56)
                    
                    albumArtworkView
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Spacer()
                
                // Control buttons - horizontal layout
                HStack(spacing: 16) {
                    // Previous button
                    Button(action: {
                        radioPlayer.previousStation(from: viewModel.stations)
                    }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .frame(width: 34, height: 34)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
                    .buttonStyle(PlainButtonStyle())
                    
                    // Play/pause button - primary control
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
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .buttonStyle(PlainButtonStyle())
                    
                    // Next button
                    Button(action: {
                        radioPlayer.nextStation(from: viewModel.stations)
                    }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .frame(width: 34, height: 34)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            // Bottom section: Dynamic full-width text information
            VStack(alignment: .leading, spacing: 4) {
                // Station name - full width, unlimited lines, dynamic height
                Text(currentStation.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(nil) // Unlimited lines
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                
                // Song metadata - full width, unlimited lines, dynamic height
                if let metadata = metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.gray)
                        .lineLimit(nil) // Unlimited lines
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                } else {
                    Text("Live Radio")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, dynamicBottomPadding)
        .background(Color(red: 0.05, green: 0.05, blue: 0.05)) // Darker gray
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true) // Allow the entire player to expand vertically
    }
    
    // Dynamic bottom padding based on text content
    private var dynamicBottomPadding: CGFloat {
        let stationNameHeight = textHeight(for: currentStation.name, font: .systemFont(ofSize: 16, weight: .semibold))
        let metadataText = (metadata?.isEmpty == false) ? metadata! : "Live Radio"
        let metadataHeight = textHeight(for: metadataText, font: .systemFont(ofSize: 14, weight: .regular))
        
        let totalTextHeight = stationNameHeight + metadataHeight + 4 // 4 is the spacing between texts
        let baseLineHeight: CGFloat = 20 // Approximate single line height
        
        // More precise padding calculation based on actual content
        if totalTextHeight <= baseLineHeight * 1.5 { // Single line content
            return 4
        } else if totalTextHeight <= baseLineHeight * 2.5 { // Two lines
            return 6
        } else { // Three or more lines
            return 8
        }
    }
    
    // Helper function to calculate text height
    private func textHeight(for text: String, font: UIFont) -> CGFloat {
        // More accurate width calculation: screen width - horizontal padding (32) - artwork (56) - spacing (16) - controls (~150)
        let maxWidth = UIScreen.main.bounds.width - 32 - 56 - 16 - 150
        let attributes = [NSAttributedString.Key.font: font]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let rect = attributedString.boundingRect(
            with: CGSize(width: max(maxWidth, 100), height: .greatestFiniteMagnitude), // Ensure minimum width
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height)
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
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "radio")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
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
                        .foregroundColor(.gray)
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
        .padding(.vertical, 12)
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
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "radio")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
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
