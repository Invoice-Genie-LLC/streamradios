// EditStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/25/24.

import SwiftUI

// Sheet type enum for single sheet management
enum EditStationSheetType: Identifiable {
    case imagePicker
    case podcastPlayer(podcast: PodcastFeed)
    
    var id: String {
        switch self {
        case .imagePicker:
            return "imagePicker"
        case .podcastPlayer(let podcast):
            return "podcastPlayer_\(podcast.id)"
        }
    }
}

struct EditStationView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var selectedCountry: String
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @State private var iconImage: UIImage? = nil
    @State private var internalActiveSheet: EditStationSheetType?
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @Binding var activeSheet: ActiveSheet?
    var station: RadioStation
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @StateObject private var radioPlayer = RadioPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    
    private let miniPlayerHeight: CGFloat = 60
    
    // Using adaptive color system
    
    init(station: RadioStation, activeSheet: Binding<ActiveSheet?>) {
        _name = State(initialValue: station.name)
        _urlString = State(initialValue: station.url)
        _selectedCountry = State(initialValue: station.country ?? "Unknown Region")
        self.station = station
        _activeSheet = activeSheet
        
        if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            _iconImage = State(initialValue: image)
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 40) {
                        stationIconSection
                        formFieldsSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 80)
                    .padding(.bottom, podcastPlayer.isPlaying && !radioPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 100 : 40)
                }
                
                // Mini Player
                if podcastPlayer.isPlaying && !radioPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                    FloatingMiniPlayer()
                }
            }
            .background(Color.adaptiveBackground.ignoresSafeArea())
        }
        .overlay(simpleNavigationBar, alignment: .top)
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { showAlert = false }
                    
                    SimpleAlertView(
                        title: "Error",
                        message: alertMessage,
                        action: { showAlert = false }
                    )
                }
            }
        )
        .alert(isPresented: $permissionManager.isPermissionAlertPresented) {
            Alert(
                title: Text("Permission Required"),
                message: Text(permissionManager.alertMessage),
                primaryButton: .default(Text("Settings"), action: {
                    permissionManager.openAppSettings()
                }),
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $internalActiveSheet) { sheetType in
            switch sheetType {
            case .imagePicker:
                ImagePicker(image: $iconImage)
            case .podcastPlayer(let podcast):
                PodcastPlayerView(
                    viewModel: podcastViewModel,
                    feed: podcast,
                    initialScrollToEpisodeID: scrollToEpisodeID,
                    podcastPlayer: podcastPlayer,
                    selectedPodcast: $selectedPodcast,
                    episodeToScrollTo: Binding(
                        get: { podcastPlayer.currentEpisode },
                        set: { _ in }
                    )
                )
            }
        }
    }
    
    // MARK: - Simple UI Components
    
    @ViewBuilder
    private var simpleNavigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    activeSheet = nil
                }
                .font(.system(size: 17))
                .foregroundColor(.blue)
                
                Spacer()
                
                Text("Edit Station")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
                
                Button("Save") {
                    saveStation()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 15)
            .background(Color.adaptiveSecondaryBackground)
            
            Divider()
                .background(Color.adaptiveSeparator)
        }
    }
    
    @ViewBuilder
    private var stationIconSection: some View {
        VStack(spacing: 16) {
            Button(action: {
                permissionManager.checkPhotoLibraryPermission {
                    internalActiveSheet = .imagePicker
                }
            }) {
                if let iconImage = iconImage {
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.adaptiveBorder, lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.adaptiveCardBackground)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Text("Add Photo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.adaptiveSecondaryText)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.adaptiveBorder, lineWidth: 1)
                        )
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Text(iconImage != nil ? "Tap to change station icon" : "Station Icon")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.adaptiveSecondaryText)
        }
    }
    
    @ViewBuilder
    private var formFieldsSection: some View {
        VStack(spacing: 32) {
            SimpleCard {
                VStack(spacing: 24) {
                    SimpleCountryPicker(
                        title: "Country",
                        selectedCountry: $selectedCountry,
                        countries: viewModel.countries
                    )
                    
                    SimpleTextField(
                        title: "Station Name",
                        text: $name,
                        placeholder: "Enter station name",
                        icon: "radio",
                        maxLength: 40
                    )
                    
                    SimpleTextField(
                        title: "Stream URL",
                        text: $urlString,
                        placeholder: "https://stream.example.com",
                        icon: "link",
                        keyboardType: .URL
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private func FloatingMiniPlayer() -> some View {
        if let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
            MiniPodcastPlayerView(
                currentEpisode: currentEpisode,
                currentFeed: currentFeed,
                podcastPlayer: podcastPlayer,
                viewModel: podcastViewModel,
                selectedPodcast: $selectedPodcast,
                onListButtonTap: {
                    selectedPodcast = currentFeed
                    podcastViewModel.fetchAllEpisodes(for: currentFeed)
                    scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                    internalActiveSheet = .podcastPlayer(podcast: currentFeed)
                },
                onCloseButtonTap: {
                    podcastPlayer.pause()
                    podcastPlayer.currentEpisode = nil
                    podcastPlayer.currentFeed = nil
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    
    // MARK: - Helper Methods
    
    private func saveStation() {
        guard !name.isEmpty else {
            alertMessage = "Station name is required."
            showAlert = true
            return
        }
        
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
            alertMessage = "Please enter a valid URL."
            showAlert = true
            return
        }
        
        guard selectedCountry != "Select Country" else {
            alertMessage = "Please select a valid country."
            showAlert = true
            return
        }

        let iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
        viewModel.updateStation(station, name: name, url: urlString, iconData: iconData, country: selectedCountry)
        viewModel.saveStationsToCoreData()
        activeSheet = nil
    }
}

// MARK: - Simple UI Components

struct SimpleCard<Content: View>: View {
    let content: () -> Content
    
    var body: some View {
        VStack {
            content()
        }
        .padding(24)
        .background(Color.adaptiveCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SimpleTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let icon: String
    let maxLength: Int?
    let keyboardType: UIKeyboardType
    
    init(title: String, text: Binding<String>, placeholder: String, icon: String, maxLength: Int? = nil, keyboardType: UIKeyboardType = .default) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.icon = icon
        self.maxLength = maxLength
        self.keyboardType = keyboardType
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.adaptivePrimaryText)
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
                    .foregroundColor(.adaptivePrimaryText)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .disableAutocorrection(keyboardType == .URL)
                    .onChange(of: text) { newValue in
                        if let maxLength = maxLength, newValue.count > maxLength {
                            text = String(newValue.prefix(maxLength))
                        }
                    }
                
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.adaptiveFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SimpleCountryPicker: View {
    let title: String
    @Binding var selectedCountry: String
    let countries: [Country]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "flag")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.adaptivePrimaryText)
            }
            
            HStack {
                ElegantCountryPickerButton(
                    selectedCountry: $selectedCountry,
                    countries: countries
                )
                
                Spacer()
            }
        }
    }
}

struct SimpleAlertView: View {
    let title: String
    let message: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.adaptivePrimaryText)
                
                Text(message)
                    .font(.system(size: 16))
                    .foregroundColor(.adaptiveSecondaryText)
                    .multilineTextAlignment(.center)
            }
            
            Button("OK") {
                action()
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.adaptivePrimaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .background(Color.adaptiveCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
    }
}

struct EditStationView_Previews: PreviewProvider {
    static var previews: some View {
        let station = RadioStation(id: "ABC", name: "Sample Station", url: "http://samplestation.com", iconData: nil, country: "Unknown Region", favoriteOrder: nil)
        
        EditStationView(station: station, activeSheet: .constant(.editStation))
            .environmentObject(RadioStationViewModel())
            .environmentObject(PermissionManager())
    }
}
