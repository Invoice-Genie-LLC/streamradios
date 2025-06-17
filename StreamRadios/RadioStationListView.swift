// RadioStationListView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import UniformTypeIdentifiers

extension UIDevice {
    static func playHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}

struct RadioStationListView: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var radioPlayer: RadioPlayer
    @Binding var isEditing: Bool
    @Binding var isEditingStation: Bool
    @Binding var selectedStationForEdit: RadioStation?
    @Binding var selectedTab: Tab
    @Binding var activeSheet: ActiveSheet?

    @State private var draggingStation: RadioStation?
    @State private var originalMetadata: String?
    @StateObject private var alertManager = AlertManager()
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showFavoriteError = false
    
    
    var body: some View {
        GeometryReader { geometry in
            if viewModel.isLoading {
                VStack {
                    ProgressView("Loading stations...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.stations.isEmpty {
                emptyStateView
            } else {
                stationsListView
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isEditingStation) {
            if let selectedStation = selectedStationForEdit {
                AddStationView(station: selectedStation, activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry)
                    .environmentObject(viewModel)
            } else {
                AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry)
                    .environmentObject(viewModel)
            }
        }
        
        .sheet(item: $viewModel.activeSheet) { item in
            switch item {
            case .editStation:
                if let selectedStation = selectedStationForEdit {
                    AddStationView(station: selectedStation, activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry)
                        .environmentObject(viewModel)
                } else {
                    AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry)
                        .environmentObject(viewModel)
                }
            }
        }
        .onAppear(perform: setup)
        .onAppear {
                   setup()
                   playFavoriteStation()
               }
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
            viewModel.loadStationsFromCoreData() // This will refresh the data in the view model
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StationArtworkUpdated"))) { notification in
            // Force refresh of the view when station artwork is updated
            if let userInfo = notification.userInfo,
               let stationId = userInfo["stationId"] as? String {
                DispatchQueue.main.async {
                    // Trigger view refresh by updating the viewModel
                    viewModel.objectWillChange.send()
                    print("📱 Station List: Refreshed for artwork update on station: \(stationId)")
                }
            }
        }
        .overlay(
            Group {
                if alertManager.showCustomAlert {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            CustomAlertView(
                                title: alertManager.customAlertTitle,
                                message: alertManager.customAlertMessage,
                                buttonText: alertManager.customAlertPrimaryButtonText,
                                buttonAction: {
                                    alertManager.customAlertPrimaryAction?()
                                    alertManager.dismissAlert()
                                },
                                secondaryButtonText: alertManager.customAlertSecondaryButtonText,
                                secondaryButtonAction: {
                                    alertManager.customAlertSecondaryAction?()
                                    alertManager.dismissAlert()
                                }
                            )
                        )
                }
            }
        )
    }
    
    private var emptyStateView: some View {
        VStack {
            Text("No stations configured")
                .font(.title)
                .foregroundColor(.gray)
                .padding(.bottom, 15)
            Button(action: {
                if viewModel.selectedCountry == "Select Country" {
                    alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                } else {
                    self.selectedStationForEdit = nil  // Ensure no station is selected for editing
                    self.activeSheet = .addStation   // Trigger the sheet to open
                }}) {
                    Image(systemName: "plus.circle")
                        .font(.largeTitle)
                        .foregroundColor(.primary)
                }
        }
        
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.scale)
    }
    
    
    private var stationsListView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack {
                    ForEach(filteredStations) { station in
                        stationRow(for: station)
                            .id(station.id) // Add ID for scroll targeting
                    }
                }
                .padding(.top, 10)
                .padding(.vertical, 10)
                .onReceive(radioPlayer.$currentStationIndex) { currentIndex in
                    // Auto-scroll to currently playing station when it changes
                    scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                }
                .onReceive(radioPlayer.$isPlaying) { isPlaying in
                    // Auto-scroll when playback starts/stops
                    if isPlaying, let currentIndex = radioPlayer.currentStationIndex {
                        scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                    }
                }
                .onChange(of: selectedTab) { oldTab, newTab in
                    // Auto-scroll to currently playing station when tab changes
                    if let currentIndex = radioPlayer.currentStationIndex {
                        // Add a small delay to allow the filtered list to update
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    // Auto-scroll to currently playing station when view appears
                    if let currentIndex = radioPlayer.currentStationIndex {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                        }
                    }
                }
            }
        }
    }
    
    private func playFavoriteStation() {
            if let favoriteStation = viewModel.stations.first(where: { $0.name == "Favorite Station" }) {
                if let index = viewModel.stations.firstIndex(where: { $0.id == favoriteStation.id }) {
                    viewModel.updateLastPlayed(for: viewModel.stations[index])
                    radioPlayer.playStation(at: index, from: viewModel.stations)
                }
            }
        }
    
    @ViewBuilder
    private func stationRow(for station: RadioStation) -> some View {
        VStack(spacing: 0) {
            // Show inline error above currently playing station if favorite toggle was attempted
            if showFavoriteError && isStationPlaying(station) && radioPlayer.isPlaying {
                errorBanner
            }
            
            // Main station card
            stationCard(for: station)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleStationTap(station)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation {
                    deleteStation(station)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 3) // Reduced from 6 to 3
        .contextMenu {
            if !isEditing  {
                Button(role: .destructive) {
                    withAnimation {
                        deleteStation(station)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onDrag {
            handleDragStart(for: station)
        }
        .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(
            station: station, 
            stations: $viewModel.stations, 
            draggingStation: $draggingStation, 
            originalMetadata: $originalMetadata, 
            viewModel: viewModel, 
            radioPlayer: radioPlayer,
            selectedTab: selectedTab,
            filteredStations: filteredStations
        ))
        // Auto-dismiss error after 5 seconds
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if showFavoriteError {
                withAnimation(.easeOut(duration: 0.3)) {
                    showFavoriteError = false
                }
            }
        }
    }
    
    @ViewBuilder
    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.footnote)
            Text("Cannot change favorite status while station is playing")
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
            Button("Dismiss") {
                withAnimation(.easeOut(duration: 0.3)) {
                    showFavoriteError = false
                }
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    @ViewBuilder
    private func stationCard(for station: RadioStation) -> some View {
        HStack(spacing: 8) {
            // Station artwork with modern styling - smaller size
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 60, height: 60)
                
                imageForStation(station)
                    .frame(width: 60, height: 60)
                    .cornerRadius(10)
                    // Removed border overlay completely
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            
            // Station information with proper layout - give it priority
            VStack(alignment: .leading, spacing: 3) {
                // Station name - one line, full width
                Text(station.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(isCurrentStation(station: station) && radioPlayer.isPlaying ? .blue : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Song metadata - 2 lines max, only show when playing
                if isCurrentStation(station: station) && radioPlayer.isPlaying {
                    if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "music.note")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.blue)
                            Text(metadata)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "radio")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.blue)
                            Text("Playing...")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                    }
                }
                
                // Country and favorite indicator - one line
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(station.country)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    if station.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            
            // Action buttons - more compact
            HStack(spacing: 6) {
                favoriteButton(for: station)
                playButton(for: station)
                
                // Only show hamburger buttons when in editing mode
                if isEditing && selectedTab != .recent {
                    editControls(for: station)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isCurrentStation(station: station) && radioPlayer.isPlaying 
                    ? Color.blue.opacity(0.3) 
                    : Color.clear, 
                    lineWidth: 2
                )
        )
    }
    
    @ViewBuilder
    private func stationArtworkSection(for station: RadioStation) -> some View {
        ZStack {
            // Background gradient for image area
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.gray.opacity(0.1),
                            Color.gray.opacity(0.05)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
            
            imageForStation(station)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Removed border overlay completely
            
            // Playing indicator overlay
            if isCurrentStation(station: station) && radioPlayer.isPlaying {
                playingIndicatorOverlay
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
    }
    
    @ViewBuilder
    private var playingIndicatorOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.black.opacity(0.3))
            .frame(width: 56, height: 56)
            .overlay(
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    // Removed scaleEffect and animation to prevent jumping during scroll
            )
    }
    
    @ViewBuilder
    private func stationInfoSection(for station: RadioStation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            stationNameRow(for: station)
            stationMetadataRow(for: station)
            stationDetailsRow(for: station)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder
    private func stationNameRow(for station: RadioStation) -> some View {
        HStack(spacing: 6) {
            Text(station.name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            // Live indicator for currently playing station
            if isCurrentStation(station: station) && radioPlayer.isPlaying {
                liveIndicator
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var liveIndicator: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                // Removed scaleEffect and animation to prevent jumping during scroll
            Text("LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
    }
    
    @ViewBuilder
    private func stationMetadataRow(for station: RadioStation) -> some View {
        HStack(spacing: 6) {
            if isCurrentStation(station: station) {
                currentStationMetadata
            } else {
                nonPlayingStationMetadata
            }
            Spacer()
        }
    }
    
    @ViewBuilder
    private var currentStationMetadata: some View {
        if let metadata = radioPlayer.metadata, !metadata.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
                Text(metadata)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "radio")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
                Text("Playing...")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.blue)
            }
        }
    }
    
    @ViewBuilder
    private var nonPlayingStationMetadata: some View {
        HStack(spacing: 4) {
            Image(systemName: "radio")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text("Tap to play")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func stationDetailsRow(for station: RadioStation) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(station.country)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
            
            if station.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.red)
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private func imageForStation(_ station: RadioStation) -> some View {
        // Show live iTunes artwork for currently playing station if available and playing
        if isCurrentStation(station: station), radioPlayer.isPlaying, let iTunesArt = radioPlayer.iTunesAlbumArt {
            Image(uiImage: iTunesArt)
                .resizable()
                .scaledToFill()
                .clipped()
        }
        // Show cached iTunes artwork if available and station is not currently playing
        else if !isCurrentStation(station: station) || !radioPlayer.isPlaying,
                let iTunesData = station.iTunesArtworkData, 
                let imageData = Data(base64Encoded: iTunesData),
                let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        }
        // Show station icon if available
        else if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData),
           let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } 
        // Default radio icon
        else {
            Image(systemName: "radio")
                .resizable()
                .scaledToFit()
        }
    }
    
    @ViewBuilder
    private func stationControlsSection(for station: RadioStation) -> some View {
        HStack(spacing: 8) {
            if isEditing {
                editControls(for: station)
            } else {
                playbackControlsSection(for: station)
            }
        }
        .padding(.trailing, 16)
    }
    
    @ViewBuilder
    private func playbackControlsSection(for station: RadioStation) -> some View {
        VStack(spacing: 8) {
            playButton(for: station)
            favoriteButton(for: station)
        }
    }
    
    @ViewBuilder
    private func playButton(for station: RadioStation) -> some View {
        Button(action: {
            handlePlayButtonTap(for: station)
        }) {
            ZStack {
                Circle()
                    .fill(
                        isStationPlaying(station) ? 
                        Color.blue.opacity(0.15) : 
                        Color.gray.opacity(0.1)
                    )
                    .frame(width: 36, height: 36)
                
                Image(systemName: isStationPlaying(station) ? 
                      (radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill") : 
                      "play.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(
                        isStationPlaying(station) ? .blue : .primary
                    )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("playButton-\(station.id)")
    }
    
    @ViewBuilder
    private func favoriteButton(for station: RadioStation) -> some View {
        Button(action: {
            handleFavoriteButtonTap(for: station)
        }) {
            ZStack {
                Circle()
                    .fill(
                        station.isFavorite ? 
                        Color.red.opacity(0.15) : 
                        Color.gray.opacity(0.1)
                    )
                    .frame(width: 28, height: 28)
                
                Image(systemName: station.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(station.isFavorite ? .red : .primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    @ViewBuilder
    private func stationCardBackground(for station: RadioStation) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(cardBackgroundGradient(for: station))
    }
    
    @ViewBuilder
    private func stationCardBorder(for station: RadioStation) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                isCurrentStation(station: station) && radioPlayer.isPlaying ? 
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ) : 
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.5
            )
            // Removed animation to prevent jumping during scroll
    }
    
    private func cardBackgroundGradient(for station: RadioStation) -> LinearGradient {
        if self.draggingStation?.id == station.id {
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color.gray.opacity(0.15),
                    Color.gray.opacity(0.05)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isCurrentStation(station: station) && radioPlayer.isPlaying {
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.08),
                    Color.blue.opacity(0.02)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemBackground),
                    Color(UIColor.systemGray6).opacity(0.3)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    // MARK: - Action Handlers
    
    private func handleStationTap(_ station: RadioStation) {
        if isEditing {
            selectedStationForEdit = station
        } else {
            // If this station is currently playing, open the Shazam sheet
            if isStationPlaying(station) && radioPlayer.isPlaying {
                activeSheet = .playerSheet
            } else {
                // Otherwise, play this station
                if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                    viewModel.updateLastPlayed(for: viewModel.stations[index])
                    radioPlayer.playStation(at: index, from: viewModel.stations)
                }
            }
        }
    }
    
    private func handlePlayButtonTap(for station: RadioStation) {
        if isStationPlaying(station) {
            radioPlayer.togglePlayPause()
        } else {
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
            }
        }
    }
    
    private func handleFavoriteButtonTap(for station: RadioStation) {
        // Check if this station is currently playing
        if isStationPlaying(station) && radioPlayer.isPlaying {
            // Show error message instead of toggling favorite
            withAnimation(.easeIn(duration: 0.3)) {
                showFavoriteError = true
            }
            // Provide haptic feedback for the error
            UIDevice.playHapticFeedback()
        } else {
            // Allow normal favorite toggle for non-playing stations
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                viewModel.toggleFavorite(for: station)
            }
            viewModel.saveStationsToCoreData()
        }
    }
    
    private func handleDragStart(for station: RadioStation) -> NSItemProvider {
        // Only allow dragging for All and Favorites tabs, not Recent
        guard selectedTab != .recent else {
            return NSItemProvider()
        }
        UIDevice.playHapticFeedback()
        self.draggingStation = station
        self.originalMetadata = radioPlayer.metadata
        radioPlayer.metadata = nil
        return NSItemProvider(object: String(station.id) as NSString)
    }
    
    private var filteredStations: [RadioStation] {
        let allStations = viewModel.stations.filter { $0.country == viewModel.selectedCountry }
        switch selectedTab {
        case .recent:
            return viewModel.recentStations()
        case .favorites:
            return viewModel.favoriteStations()
        case .all:
            return allStations
        }
    }
    
    private func isCurrentStation(station: RadioStation) -> Bool {
        return radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station
    }
    
    private func deleteStation(_ station: RadioStation) {
        if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
            DataStore.shared.deleteStationFromCloudKit(station: station) { success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")
                        self.viewModel.stations.remove(at: index)
                        
                        // Delete from CoreData
                        self.viewModel.deleteStationFromCoreData(station)
                        self.adjustRadioPlayerIndexAfterDeletion(at: index)
                    } else {
                        print("Failed to delete station from CloudKit.")
                    }
                }
            }
        }
    }
    
    private func adjustRadioPlayerIndexAfterDeletion(at index: Int) {
        if RadioPlayer.shared.currentStationIndex == index {
            RadioPlayer.shared.stop()
            RadioPlayer.shared.currentStationIndex = nil
        } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex > index {
            RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
        }
    }
    
    private func handleDismiss() {
        selectedStationForEdit = nil
        if !viewModel.stations.isEmpty {
            selectedTab = .all
        }
    }
    
    private func setup() {
        NotificationCenter.default.addObserver(forName: .NetworkReconnectNotification, object: nil, queue: .main) { _ in
            if let index = radioPlayer.currentStationIndex {
                radioPlayer.playStation(at: index, from: viewModel.stations)
            }
        }
    }
    
    private func isStationPlaying(_ station: RadioStation) -> Bool {
        return radioPlayer.currentStationIndex != nil &&
               viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) &&
               viewModel.stations[radioPlayer.currentStationIndex!].id == station.id
    }
    
    private func scrollToCurrentStation(proxy: ScrollViewProxy, currentIndex: Int?) {
        guard let currentIndex = currentIndex,
              currentIndex < viewModel.stations.count else { return }
        
        let currentStation = viewModel.stations[currentIndex]
        
        // Check if the current station is in the filtered list
        if filteredStations.contains(where: { $0.id == currentStation.id }) {
            withAnimation(.easeInOut(duration: 0.6)) {
                proxy.scrollTo(currentStation.id, anchor: .center)
            }
        }
    }
    
    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
    }
    
    @ViewBuilder
    private func editControls(for station: RadioStation) -> some View {
        Button(action: {}) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "line.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onDrag {
            // Only allow dragging for All and Favorites tabs, not Recent
            guard selectedTab != .recent else {
                return NSItemProvider()
            }
            UIDevice.playHapticFeedback()
            self.draggingStation = station
            self.originalMetadata = radioPlayer.metadata
            radioPlayer.metadata = nil
            return NSItemProvider(object: String(station.id) as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(
            station: station, 
            stations: $viewModel.stations, 
            draggingStation: $draggingStation, 
            originalMetadata: $originalMetadata, 
            viewModel: viewModel, 
            radioPlayer: radioPlayer,
            selectedTab: selectedTab,
            filteredStations: filteredStations
        ))
    }
}

struct StationDropDelegate: DropDelegate {
    let station: RadioStation
    @Binding var stations: [RadioStation]
    @Binding var draggingStation: RadioStation?
    @Binding var originalMetadata: String?
    let viewModel: RadioStationViewModel
    let radioPlayer: RadioPlayer
    let selectedTab: Tab
    let filteredStations: [RadioStation]
    
    func performDrop(info: DropInfo) -> Bool {
        if let metadata = originalMetadata {
            radioPlayer.metadata = metadata
        }
        draggingStation = nil
        originalMetadata = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard selectedTab != .recent else { return } // Don't allow reordering in Recent tab
        
        guard let draggingStation = draggingStation else { return }
        
        if selectedTab == .favorites {
            // Handle favorites reordering
            guard let fromIndex = filteredStations.firstIndex(of: draggingStation),
                  let toIndex = filteredStations.firstIndex(of: station),
                  fromIndex != toIndex else { return }
            
            withAnimation {
                moveFavoriteStation(from: fromIndex, to: toIndex)
            }
        } else {
            // Handle all stations reordering
            guard let fromIndex = stations.firstIndex(of: draggingStation),
                  let toIndex = stations.firstIndex(of: station),
                  fromIndex != toIndex else { return }
            
            withAnimation {
                moveAllStation(from: fromIndex, to: toIndex)
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard selectedTab != .recent else { 
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }
    
    func moveFavoriteStation(from sourceIndex: Int, to destinationIndex: Int) {
        // Reorder favorites by updating their favoriteOrder values
        let favoriteStations = filteredStations
        
        // Create new order array
        var newOrderedFavorites = favoriteStations
        let movingStation = newOrderedFavorites.remove(at: sourceIndex)
        newOrderedFavorites.insert(movingStation, at: destinationIndex)
        
        // Update favoriteOrder for all favorites based on new positions
        for (index, favStation) in newOrderedFavorites.enumerated() {
            if let stationIndex = viewModel.stations.firstIndex(where: { $0.id == favStation.id }) {
                viewModel.stations[stationIndex].favoriteOrder = index
            }
        }
        
        viewModel.saveStationsToCoreData()
    }
    
    func moveAllStation(from sourceIndex: Int, to destinationIndex: Int) {
        let itemToMove = viewModel.stations.remove(at: sourceIndex)
        viewModel.stations.insert(itemToMove, at: destinationIndex)
        
        // Save the new station order to CoreData
        viewModel.saveStationsToCoreData()
    }
}

struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    @State static var activeSheet: ActiveSheet? = nil  // Create a state to pass as a binding
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false), isEditingStation: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.recent),
                             activeSheet: $activeSheet)  // Pass the binding to the preview
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
    }
}
