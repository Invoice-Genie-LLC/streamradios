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
    @State private var showSideMenu: Bool
    @State private var isEditingMode: Bool
    @State private var isEditingStation: Bool
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
            savedTab = .all
        }
        
        self._radioPlayer = StateObject(wrappedValue: RadioPlayer.shared)
        self._podcastViewModel = StateObject(wrappedValue: PodcastViewModel())
        self._podcastPlayer = StateObject(wrappedValue: PodcastPlayer.shared)
        
        self._isAddStationViewPresented = State(initialValue: false)
        self._isPlayerSheetPresented = State(initialValue: false)
        self._showSideMenu = State(initialValue: false)
        self._isEditingMode = State(initialValue: false)
        self._isEditingStation = State(initialValue: false)
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
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            withAnimation {
                                                showSideMenu.toggle()
                                            }
                                        }) {
                                            Image(systemName: "line.horizontal.3")
                                                .font(.title)
                                                .foregroundColor(.primary)
                                                .frame(width: menuButtonWidth)
                                        }
                                        .padding(.leading, 15)
                        
                        StyledPickerView(
                            selectedCountry: $viewModel.selectedCountry,
                            countries: viewModel.countries
                        )
                        .frame(width: countryPickerWidth)
                        
                        Button(action: {
                            isEditingMode.toggle()
                            if isEditingMode {
                                radioPlayer.stop()
                                radioPlayer.metadata = nil
                                radioPlayer.currentStationIndex = nil
                            }
                        }) {
                            Text(isEditingMode ? "Done" : "Edit")
                                .font(.title3)
                                .foregroundColor(.primary)
                        }
                        .frame(width: editButtonWidth)
                        
                        Button(action: {
                            if viewModel.selectedCountry == "Select Country" {
                                alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                            } else {
                                activeSheet = .addStation
                            }
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                                .foregroundColor(.primary)
                        }
                        .frame(width: addButtonWidth)
                    }
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                    
                    Picker("", selection: $selectedTab) {
                        Text("Recent").tag(Tab.recent)
                        Text("Favorites").tag(Tab.favorites)
                        Text("All").tag(Tab.all)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .frame(width: sizeClass == .regular ? 650 : 410)
                    .onChange(of: selectedTab) { newValue in
                        saveSelectedTab(newValue)
                    }
                    
                    Spacer()
                    
                    RadioStationListView(isEditing: $isEditingMode,
                                         isEditingStation: $isEditingStation,
                                         selectedStationForEdit: $selectedStationForEdit,
                                         selectedTab: $selectedTab, activeSheet: $activeSheet)
                        .environmentObject(viewModel)
                        .environmentObject(radioPlayer)
                        .frame(width: sizeClass == .regular ? 615 : deviceType == .iPhoneSE || deviceType == .iPhoneSE2 ? 350 : 385)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                        .modifier(NeumorphicShadow())
                        .padding(.top, deviceType == .iPhoneSE || deviceType == .iPhoneSE2 ? 5 : 10)
                        .padding(.bottom, deviceType == .iPhoneSE || deviceType == .iPhoneSE2 ? 20 : 35)
                    
                    Spacer()
                    
                    VStack {
                        if let currentStation = viewModel.currentlyPlayingStation {
                            CurrentlyPlayingView(currentStation: currentStation, metadata: radioPlayer.metadata)
                        }
                        PlayerView()
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .padding(.top, 8)
                    }
                    .frame(width: playerViewWidth)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .modifier(NeumorphicShadow())
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 140)
                    .padding(.bottom, UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0)
                    
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
                
                // Side Menu
                                GeometryReader { geometry in
                                    HStack(spacing: 0) {
                                        SideMenuView(showSideMenu: $showSideMenu)
                                            .frame(width: geometry.size.width / 2)
                                            .offset(x: showSideMenu ? 0 : -geometry.size.width / 2)
                                        
                                        Spacer()
                                    }
                                    .background(
                                        Color.black.opacity(showSideMenu ? 0.5 : 0)
                                            .edgesIgnoringSafeArea(.all)
                                            .onTapGesture {
                                                withAnimation {
                                                    showSideMenu = false
                                                }
                                            }
                                    )
                                }
                                .zIndex(showSideMenu ? 1 : 0)
                                
                                if alertManager.showCustomAlert {
                                    CustomAlertContainer()
                                }
            }
            .sheet(item: $activeSheet, onDismiss: { activeSheet = nil }) { item in
                switch item {
                case .addStation:
                    AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry) { savedCountry in
                        viewModel.selectedCountry = savedCountry
                        selectedTab = .all
                    }
                    .environmentObject(viewModel)
                case .editStation:
                    if let station = selectedStationForEdit {
                        EditStationView(station: station, isPresented: $selectedStationForEdit)
                            .environmentObject(viewModel)
                    }
                case .playerSheet:
                    PlayerSheetView()
                        .environmentObject(radioPlayer)
                        .environmentObject(viewModel)
                }
            }
            .sheet(item: $selectedStationForEdit) { station in
                EditStationView(station: station, isPresented: $selectedStationForEdit)
                    .environmentObject(viewModel)
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
                self.bitrateMessage = newBitrateMessage
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToAllTab)) { _ in
                self.selectedTab = .all
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onDisappear {
            podcastViewModel.saveContextIfNeeded()
        }
        .onAppear {
            UIApplication.shared.addTapGestureRecognizer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .countrySelected)) { _ in
            selectedTab = .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .countryChanged)) { _ in
            self.viewModel.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
                    viewModel.loadStationsFromCoreData()
                }
            }
            
            func saveSelectedTab(_ tab: Tab) {
                UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
            }
        }

        // MARK: - Helper Views

        struct CurrentlyPlayingView: View {
            let currentStation: RadioStation
            let metadata: String?
            @EnvironmentObject var radioPlayer: RadioPlayer
            
            var body: some View {
                HStack(alignment: .center, spacing: 20) {
                    // Show detected song artwork if available, otherwise show station icon
                    if let songArtwork = radioPlayer.songArtwork {
                        Image(uiImage: songArtwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 70, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: 70, height: 70)
                            .cornerRadius(10)
                    } else {
                        Image(systemName: "radio")
                            .resizable()
                            .frame(width: 70, height: 70)
                            .cornerRadius(10)
                            .foregroundColor(.gray)
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text(currentStation.name)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        // Show detected song info if available
                                    if let detectedSong = radioPlayer.detectedSong {
               let title = detectedSong.title
               let artist = detectedSong.artist
               let album = detectedSong.album
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                if let album = album, !album.isEmpty {
                                    Text(album)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .italic()
                                }
                            }
                        } else if let metadata = metadata {
                            Text(metadata)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 10)
            }
        }

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
