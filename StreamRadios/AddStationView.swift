// AddStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

// Sheet type enum for single sheet management
enum AddStationSheetType: Identifiable {
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

struct AddStationView: View {
    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var selectedCountry: String = "Select Country"
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @State private var iconImage: UIImage? = nil
    @State private var activeSheet: AddStationSheetType?
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @Binding var isEditingStation: RadioStation?
    @Binding var presentedSheet: ActiveSheet?
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @StateObject private var radioPlayer = RadioPlayer.shared

    var station: RadioStation?
    var onSave: ((String) -> Void)?
    
    private let miniPlayerHeight: CGFloat = 60
    
    // Clean, minimal color system
    private var backgroundColor: Color {
        Color(red: 0.08, green: 0.08, blue: 0.08)
    }
    
    private var cardBackgroundColor: Color {
        Color(red: 0.15, green: 0.15, blue: 0.15)
    }
    
    private var accentColor: Color {
        Color.blue
    }
    
    init(station: RadioStation? = nil, activeSheet: Binding<ActiveSheet?>, selectedCountry: String, isEditingStation: Binding<RadioStation?>? = nil, onSave: ((String) -> Void)? = nil) {
        self.station = station
        _presentedSheet = activeSheet
        _selectedCountry = State(initialValue: selectedCountry)
        self.onSave = onSave
        
        if let isEditingStation = isEditingStation {
            _isEditingStation = isEditingStation
        } else {
            _isEditingStation = .constant(nil)
        }
        
        if let station = station, let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            _iconImage = State(initialValue: image)
        }
    }
    
    var body: some View {
        NavigationView {
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
                .background(backgroundColor.ignoresSafeArea())
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
        .overlay(simpleNavigationBar, alignment: .top)
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { showAlert = false }
                    
                    AddSimpleAlertView(
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
        .sheet(item: $activeSheet) { sheetType in
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
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Simple UI Components
    
    @ViewBuilder
    private var simpleNavigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    presentedSheet = nil
                }
                .font(.system(size: 17))
                .foregroundColor(accentColor)
                
                Spacer()
                
                Text("Add Station")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button("Add") {
                    saveStation()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 15)
            .background(backgroundColor)
            
            Divider()
                .background(Color.gray.opacity(0.3))
        }
    }
    
    @ViewBuilder
    private var stationIconSection: some View {
        VStack(spacing: 16) {
            Button(action: {
                permissionManager.checkPhotoLibraryPermission {
                    activeSheet = .imagePicker
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
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(cardBackgroundColor)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Text("Add Photo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Text(iconImage != nil ? "Tap to change station icon" : "Station Icon")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gray)
        }
    }
    
    @ViewBuilder
    private var formFieldsSection: some View {
        VStack(spacing: 32) {
            AddSimpleCard {
                VStack(spacing: 24) {
                    AddSimpleCountryPicker(
                        title: "Country",
                        selectedCountry: $selectedCountry,
                        countries: viewModel.countries
                    )
                    
                    AddSimpleTextField(
                        title: "Station Name",
                        text: $name,
                        placeholder: "Enter station name",
                        icon: "radio",
                        maxLength: 40
                    )
                    
                    AddSimpleTextField(
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
        MiniPlayerView(
            podcastPlayer: podcastPlayer,
            viewModel: podcastViewModel,
            selectedPodcast: $selectedPodcast,
            onListButtonTap: {
                if let currentFeed = podcastPlayer.currentFeed {
                    selectedPodcast = currentFeed
                    podcastViewModel.fetchAllEpisodes(for: currentFeed)
                    scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                    activeSheet = .podcastPlayer(podcast: currentFeed)
                }
            },
            onCloseButtonTap: {
                podcastPlayer.pause()
                podcastPlayer.currentEpisode = nil
                podcastPlayer.currentFeed = nil
            },
            isPlaylistButtonDisabled: false
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        viewModel.addStation(name: name, url: urlString, iconData: iconData, country: selectedCountry)
        viewModel.saveStationsToCoreData()
        presentedSheet = nil
        onSave?(selectedCountry)
    }
}

// MARK: - Simple UI Components

struct AddSimpleCard<Content: View>: View {
    let content: () -> Content
    
    var body: some View {
        VStack {
            content()
        }
        .padding(24)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct AddSimpleTextField: View {
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
                    .foregroundColor(.white)
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
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
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct AddSimpleCountryPicker: View {
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
                    .foregroundColor(.white)
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

struct AddSimpleAlertView: View {
    let title: String
    let message: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            
            Button("OK") {
                action()
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
    }
}

struct AddStationView_Previews: PreviewProvider {
    @State static var activeSheet: ActiveSheet? = .addStation
    
    static var previews: some View {
        AddStationView(activeSheet: $activeSheet, selectedCountry: "Unknown")
            .environmentObject(RadioStationViewModel())
            .environmentObject(PermissionManager())
    }
}
