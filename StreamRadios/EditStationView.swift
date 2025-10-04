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
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 40) {
                            stationIconSection
                            formFieldsSection
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                    }
                }
                .background(Color.adaptiveSheetBackground.ignoresSafeArea())
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit Station")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.adaptivePrimaryText)
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        activeSheet = nil
                    }
                    .foregroundColor(.blue)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveStation()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture { showAlert = false }
                    
                    SimpleAlertView(
                        title: "Error",
                        message: alertMessage,
                        action: { showAlert = false }
                    )
                    .transition(.opacity)
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
                                .font(.subheadline)
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
                .font(.body)
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
                    .font(.body)
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .disableAutocorrection(keyboardType == .URL)
                    .textSelection(.enabled) // Enable text selection for copy/paste
                    .onChange(of: text) { newValue in
                        if let maxLength = maxLength, newValue.count > maxLength {
                            text = String(newValue.prefix(maxLength))
                        }
                    }
                
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
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
                    .font(.body)
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
            }
            
            HStack {
                CountryPickerButton(
                    selectedCountry: $selectedCountry,
                    countries: countries,
                    stationCount: nil
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
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.adaptiveSecondaryText)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: action) {
                Text("OK")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .background(Color.blue)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .padding(24)
        .background(Color(UIColor.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
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
