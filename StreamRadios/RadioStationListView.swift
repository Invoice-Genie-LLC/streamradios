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
    @Binding var selectedStationForEdit: RadioStation?
    @Binding var selectedTab: Tab
    @Binding var selectedSubTab: RadioSubTab
    @Binding var activeSheet: ActiveSheet?
    @Binding var isPlayerSheetPresented: Bool

    @StateObject private var alertManager = AlertManager()

    @State private var showFavoriteError = false
    
    // Delete confirmation
    @State private var showDeleteAlert = false
    @State private var stationToDelete: RadioStation?
    
    var body: some View {
        GeometryReader { geometry in
            if viewModel.isLoading {
                VStack {
                    ProgressView("Loading stations...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if viewModel.stations.isEmpty {
                emptyStateView
            } else {
                stationsListView(screenWidth: geometry.size.width)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onTapGesture {
            // Tap outside to exit edit mode
            if isEditing {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isEditing = false
                }
            }
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .editStation:
                if let selectedStation = selectedStationForEdit {
                    EditStationView(station: selectedStation, activeSheet: $activeSheet)
                        .environmentObject(viewModel)
                }
            case .addStation:
                AddStationView(activeSheet: $activeSheet, selectedCountry: viewModel.selectedCountry)
                    .environmentObject(viewModel)
            case .playerSheet:
                // PlayerSheet is now handled via isPlayerSheetPresented binding
                EmptyView()
            }
        }
        .onAppear(perform: setup)
        .onAppear {
            setup()
            playFavoriteStation()
        }
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
            viewModel.loadStationsFromCoreData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StationArtworkUpdated"))) { notification in
            if let userInfo = notification.userInfo,
               let stationId = userInfo["stationId"] as? String {
                DispatchQueue.main.async {
                    viewModel.objectWillChange.send()
                    print("📱 Station List: Refreshed for artwork update on station: \(stationId)")
                }
            }
        }
        .overlay(
            Group {
                if alertManager.showCustomAlert {
                    Color.black.opacity(0.8)
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
                
                // Edit mode header
                if isEditing {
                    VStack {
                        HStack {
                            Text("Drag to Reorder Stations")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)
                            
                            Spacer()
                            
                            Button("Done") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isEditing = false
                                }
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.95))
                        .overlay(
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 0.5),
                            alignment: .bottom
                        )
                        
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        )
        .alert("Delete Station", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {
                stationToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let station = stationToDelete {
                    withAnimation {
                        deleteStation(station)
                    }
                }
                stationToDelete = nil
            }
        } message: {
            if let station = stationToDelete {
                Text("Are you sure you want to delete \"\(station.name)\"? This action cannot be undone.")
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack {
            Text("No stations configured")
                .font(.title)
                .foregroundColor(.white)
                .padding(.bottom, 15)
            Button(action: {
                if viewModel.selectedCountry == "Select Country" {
                    alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                } else {
                    self.selectedStationForEdit = nil
                    self.activeSheet = .addStation
                }}) {
                    Image(systemName: "plus.circle")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .transition(.scale)
    }
    
    private func stationsListView(screenWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Stations list using List for swipe actions
            List {
                ForEach(filteredStations) { station in
                    modernStationRow(for: station)
                        .id(station.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .onMove(perform: selectedTab == .radio && isEditing ? moveStations : nil)
                .onDelete { indexSet in
                    for index in indexSet {
                        let station = filteredStations[index]
                        stationToDelete = station
                        showDeleteAlert = true
                    }
                }
            }
            .listStyle(PlainListStyle())
            .background(Color.black)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .onReceive(radioPlayer.$currentStationIndex) { currentIndex in
                if let currentIndex = currentIndex, currentIndex < filteredStations.count {
                    // Find the station in filtered list and scroll to it
                    let currentStationId = viewModel.stations[currentIndex].id
                    if filteredStations.contains(where: { $0.id == currentStationId }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            // Note: ScrollViewReader functionality needs to be handled differently with List
                        }
                    }
                }
            }
            .onReceive(radioPlayer.$isPlaying) { isPlaying in
                if isPlaying, let currentIndex = radioPlayer.currentStationIndex {
                    // Handle scroll to current station for List
                }
            }
            .onChange(of: selectedTab) { oldTab, newTab in
                // Handle tab changes
            }
            .onChange(of: selectedSubTab) { oldSubTab, newSubTab in
                // Handle sub-tab changes
            }
        }
        .frame(width: screenWidth)
        .background(Color.black)
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
    private func modernStationRow(for station: RadioStation) -> some View {
        VStack(spacing: 0) {
            // Show inline error above currently playing station if favorite toggle was attempted
            if showFavoriteError && isStationPlaying(station) && radioPlayer.isPlaying {
                errorBanner
            }
            
            // Main modern station card with gesture handling
            ZStack {
                // Background tap area - this will handle the main tap
                modernStationCard(for: station)
                
                // Overlay with tap gesture that excludes the favorite button area
                HStack {
                    // Main tappable area (everything except the rightmost 60 points where the favorite button is)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleStationTap(station)
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            // Long press activates sorting mode
                            withAnimation(.easeInOut(duration: 0.3)) {
                                if !isEditing && selectedTab == .radio {
                                    isEditing = true
                                    // Haptic feedback for long press
                                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                    impactFeedback.impactOccurred()
                                }
                            }
                        }
                    
                    // Reserve space for favorite button (no tap gesture here)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 60)
                        .allowsHitTesting(false) // This area doesn't capture taps
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                // Ensure we have a valid station before setting up edit
                DispatchQueue.main.async {
                    selectedStationForEdit = station
                    activeSheet = .editStation
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                stationToDelete = station
                showDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
            Text("Cannot favorite while playing")
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.2))
        .cornerRadius(8)
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    @ViewBuilder
    private func modernStationCard(for station: RadioStation) -> some View {
        HStack(spacing: 12) {
            // Station logo - 64x64 as per screenshot
            modernStationLogo(for: station)
            
            // Station info
            VStack(alignment: .leading, spacing: 4) {
                // Station name - white text
                Text(station.name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                // Country - blue text as per screenshot
                Text(station.country)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                
                // Show metadata if playing
                if isCurrentStation(station: station) && radioPlayer.isPlaying {
                    if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                        Text(metadata)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            
            Spacer()
            
            // Signal bars and controls
            HStack(spacing: 12) {
                // Animated signal bars for playing station
                if isCurrentStation(station: station) && radioPlayer.isPlaying {
                    animatedSignalBars
                } else {
                    staticSignalBars
                }
                
                // Stylish heart favorite button
                if !isEditing {
                    heartFavoriteButton(for: station)
                }
                
                // No edit controls needed - using native List drag handles
            }
        }
        .padding(.horizontal, 16)
        .padding(.leading, isEditing ? 40 : 0) // Additional leading padding when in edit mode
        .padding(.vertical, 12)
        .background(Color.black)
        .overlay(
            // Subtle separator line
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 0.5)
                .padding(.leading, 88), // Align with text content
            alignment: .bottom
        )
    }
    
    @ViewBuilder
    private func modernStationLogo(for station: RadioStation) -> some View {
        ZStack {
            // Background for logo
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 64, height: 64)
            
            // Station image
            imageForStation(station)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    
    @ViewBuilder
    private var animatedSignalBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue)
                    .frame(width: 3, height: CGFloat(8 + index * 4))
                    .scaleEffect(y: 1.0)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: radioPlayer.isPlaying
                    )
            }
        }
    }
    
    @ViewBuilder
    private var staticSignalBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 3, height: CGFloat(8 + index * 4))
            }
        }
    }
    
    @ViewBuilder
    private func heartFavoriteButton(for station: RadioStation) -> some View {
        Image(systemName: station.isFavorite ? "heart.fill" : "heart")
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(station.isFavorite ? .pink : .gray)
            .scaleEffect(station.isFavorite ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
            .contentShape(Circle())
            .frame(width: 44, height: 44)
            .highPriorityGesture(
                TapGesture()
                    .onEnded { _ in
                        handleFavoriteButtonTap(for: station)
                    }
            )
        .background(
            Circle()
                .fill(station.isFavorite ? Color.pink.opacity(0.1) : Color.clear)
                .scaleEffect(station.isFavorite ? 1.0 : 0.8)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
        )
        .overlay(
            Circle()
                .stroke(station.isFavorite ? Color.pink.opacity(0.3) : Color.clear, lineWidth: 1)
                .scaleEffect(station.isFavorite ? 1.0 : 0.8)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
        )
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
                .background(Color.white.opacity(0.1))
        } 
        // Default radio icon with station initials
        else {
            ZStack {
                Color.gray.opacity(0.3)
                
                if !station.name.isEmpty {
                    Text(String(station.name.prefix(2)).uppercased())
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
    
    // MARK: - Action Handlers
    
    private func handleStationTap(_ station: RadioStation) {
        // Don't handle tap if in editing mode - let native drag handle it
        guard !isEditing else { return }
        
        if isStationPlaying(station) && radioPlayer.isPlaying {
            isPlayerSheetPresented = true
        } else {
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
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
        if isStationPlaying(station) && radioPlayer.isPlaying {
            withAnimation(.easeIn(duration: 0.3)) {
                showFavoriteError = true
            }
            UIDevice.playHapticFeedback()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                viewModel.toggleFavorite(for: station)
            }
            viewModel.saveStationsToCoreData()
        }
    }
    

    
    private var filteredStations: [RadioStation] {
        // Only filter for radio tab
        guard selectedTab == .radio else {
            return []
        }
        
        let allStations = viewModel.stations.filter { $0.country == viewModel.selectedCountry }
        
        switch selectedSubTab {
        case .all:
            return allStations
        case .recent:
            return viewModel.recentStations().filter { $0.country == viewModel.selectedCountry }
        case .favorites:
            return viewModel.favoriteStations().filter { $0.country == viewModel.selectedCountry }
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
            selectedTab = .radio
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
    

    
    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
    }
    
    private func moveStations(from source: IndexSet, to destination: Int) {
        guard selectedTab == .radio else { return }
        
        // Handle different subtab scenarios
        switch selectedSubTab {
        case .all:
            // Move within all stations for selected country
            var filteredStations = self.filteredStations
            filteredStations.move(fromOffsets: source, toOffset: destination)
            
            // Update the main stations array
            for (index, station) in filteredStations.enumerated() {
                if let mainIndex = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                    viewModel.stations[mainIndex] = station
                }
            }
            
        case .favorites:
            // Move within favorites
            var favoriteStations = filteredStations
            favoriteStations.move(fromOffsets: source, toOffset: destination)
            
            // Update favorite order
            for (index, favStation) in favoriteStations.enumerated() {
                if let stationIndex = viewModel.stations.firstIndex(where: { $0.id == favStation.id }) {
                    viewModel.stations[stationIndex].favoriteOrder = index
                }
            }
            
        case .recent:
            // Recent stations can't be reordered manually
            return
        }
        
        // Save changes
        viewModel.saveStationsToCoreData()
        
        // Update radio player index if needed
        if let currentIndex = radioPlayer.currentStationIndex {
            // Find the new index of the currently playing station
            for (newIndex, station) in viewModel.stations.enumerated() {
                if station.id == viewModel.stations[currentIndex].id {
                    radioPlayer.currentStationIndex = newIndex
                    break
                }
            }
        }
    }
    

    
}



struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    @State static var activeSheet: ActiveSheet? = nil
    @State static var isPlayerSheetPresented = false
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.radio),
                             selectedSubTab: .constant(.all), activeSheet: $activeSheet,
                             isPlayerSheetPresented: $isPlayerSheetPresented)
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
        .preferredColorScheme(.dark)
    }
}
