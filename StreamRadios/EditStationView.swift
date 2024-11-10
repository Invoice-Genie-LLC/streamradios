// EditStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/25/24.

import SwiftUI

struct EditStationView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var selectedCountry: String
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @State private var iconImage: UIImage? = nil
    @State private var showImagePicker = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @Binding var isPresented: RadioStation?
    var station: RadioStation
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @StateObject private var radioPlayer = RadioPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    
    private let miniPlayerHeight: CGFloat = 60 // Adjust this value based on your MiniPlayerView height
    
    init(station: RadioStation, isPresented: Binding<RadioStation?>) {
        _name = State(initialValue: station.name)
        _urlString = State(initialValue: station.url)
        _selectedCountry = State(initialValue: station.country ?? "Unknown Region")
        self.station = station
        _isPresented = isPresented
        
        if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            _iconImage = State(initialValue: image)
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NavigationView {
                    VStack(spacing: 0) {
                        // Custom toolbar
                        HStack {
                            Button(action: {
                                isPresented = nil
                            }) {
                                Text("Cancel")
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                            Text("Edit Station")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button(action: saveStation) {
                                Text("Save")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        Divider()
                        
                        ScrollView {
                            VStack(spacing: 0) {
                                Form {
                                    Section(header: Text("Station Info")) {
                                        HStack {
                                            TextField("Enter station name", text: $name)
                                                .onChange(of: name) { newValue in
                                                    if newValue.count >= 40 {
                                                        name = String(newValue.prefix(40))
                                                    }
                                                }
                                            if !name.isEmpty {
                                                Button(action: {
                                                    name = ""
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.gray)
                                                }
                                                .padding(.trailing, 8)
                                            }
                                        }
                                        
                                        HStack {
                                            TextField("Enter station URL", text: $urlString)
                                            if !urlString.isEmpty {
                                                Button(action: {
                                                    urlString = ""
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.gray)
                                                }
                                                .padding(.trailing, 8)
                                            }
                                        }
                                        
                                        Picker("Select Country", selection: $selectedCountry) {
                                            ForEach(viewModel.countries, id: \.name) { country in
                                                Text(country.name).tag(country.name)
                                            }
                                        }
                                        .pickerStyle(MenuPickerStyle())
                                    }
                                    
                                    Section(header: Text("Icon")) {
                                        if let iconImage = iconImage {
                                            Image(uiImage: iconImage)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 100, height: 100)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        } else {
                                            Image(systemName: "photo")
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 100, height: 100)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }
                                        
                                        Button(action: {
                                            permissionManager.checkPhotoLibraryPermission {
                                                showImagePicker = true
                                            }
                                        }) {
                                            HStack {
                                                Image(systemName: "square.and.arrow.up")
                                                Text("Upload Station Icon")
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                        .sheet(isPresented: $showImagePicker) {
                                            ImagePicker(image: $iconImage)
                                        }
                                    }
                                }
                                .frame(minHeight: geometry.size.height - (podcastPlayer.currentEpisode != nil ? miniPlayerHeight + 44 : 44))
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
                            .frame(height: miniPlayerHeight)
                        }
                    }
                    .navigationBarHidden(true)
                }
                
                if showAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                        self.showAlert = false
                    }
                    .transition(.opacity)
                }
            }
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
        .sheet(isPresented: $showPodcastPlayerSheet) {
            if let podcast = selectedPodcast {
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
        isPresented = nil
    }
}

struct EditStationView_Previews: PreviewProvider {
    static var previews: some View {
        let station = RadioStation(id: "ABC", name: "Sample Station", url: "http://samplestation.com", iconData: nil, country: "Unknown Region")
        EditStationView(station: station, isPresented: .constant(station))
            .environmentObject(RadioStationViewModel())
            .environmentObject(PermissionManager())
    }
}
