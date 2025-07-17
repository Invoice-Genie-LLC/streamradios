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
    @State private var keyboardHeight: CGFloat = 0
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
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
    
    // Using adaptive color system
    
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
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 40) {
                                stationIconSection
                                formFieldsSection
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 80)
                            .padding(.bottom, keyboardHeight + 60) // Extra padding for keyboard + buffer
                        }
                        .scrollDisabled(false) // Disable automatic scrolling
                        .scrollDismissesKeyboard(.never)
                    }
                    .background(Color.adaptiveBackground.ignoresSafeArea())
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded { _ in
                            // Dismiss keyboard when tapping outside input fields
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    )
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
        .overlay(simpleNavigationBar, alignment: .top)
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture { showAlert = false }
                    
                    AddSimpleAlertView(
                        title: "Error",
                        message: alertMessage,
                        action: { showAlert = false }
                    )
                    .transition(.opacity)
                }
            }
        )
        .onAppear {
            addKeyboardObservers()
        }
        .onDisappear {
            removeKeyboardObservers()
        }
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
    }
    
    // MARK: - Simple UI Components
    
    @ViewBuilder
    private var simpleNavigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    presentedSheet = nil
                }
                .font(.body)
                .foregroundColor(.blue)
                
                Spacer()
                
                Text("Add Station")
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                
                Spacer()
                
                Button("Add") {
                    saveStation()
                }
                .font(.body)
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
    
    // MARK: - Keyboard Handling
    
    private func addKeyboardObservers() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let keyboardRectangle = keyboardFrame.cgRectValue
                let keyboardHeight = keyboardRectangle.height
                
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.keyboardHeight = keyboardHeight
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                self.keyboardHeight = 0
            }
        }
    }
    
    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
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
        
        // Check subscription limits for adding stations
        if !subscriptionManager.isSubscribedOrInTrial {
            let freeStationLimit = 5
            if viewModel.stations.count >= freeStationLimit {
                alertMessage = "Free users can add up to \(freeStationLimit) radio stations. Upgrade to StreamRadios Pro for unlimited stations."
                showAlert = true
                return
            }
        }
        
        let iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
        let success = viewModel.addStation(name: name, url: urlString, iconData: iconData, country: selectedCountry)
        
        if success {
            viewModel.saveStationsToCoreData()
            presentedSheet = nil
            onSave?(selectedCountry)
        } else {
            alertMessage = "A station with this URL has already been added. Please use a different URL."
            showAlert = true
        }
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
        .background(Color.adaptiveCardBackground)
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
                    .font(.body)
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.body)
                    .foregroundColor(.adaptivePrimaryText)
            }
            
            HStack {
                Group {
                    TextField(placeholder, text: $text)
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .keyboardType(keyboardType)
                        .autocapitalization(.none)
                        .disableAutocorrection(keyboardType == .URL)
                        .onChange(of: text) { oldValue, newValue in
                            if let maxLength = maxLength, newValue.count > maxLength {
                                text = String(newValue.prefix(maxLength))
                            }
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

struct AddSimpleCountryPicker: View {
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
        .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
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
