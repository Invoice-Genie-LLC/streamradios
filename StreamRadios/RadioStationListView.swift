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
                if isEditing && (selectedSubTab == .all || selectedSubTab == .favorites) {
                    VStack {
                        HStack {
                            Text("Drag to Reorder Stations")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)
                                .allowsHitTesting(false) // Prevent text from blocking gestures
                            
                            Spacer()
                                .allowsHitTesting(false) // Prevent spacer from blocking gestures
                            
                            Button("Done") {
                                isEditing = false
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
            // Add top padding when in editing mode for All and Favorites tabs
            if isEditing && (selectedSubTab == .all || selectedSubTab == .favorites) {
                Spacer()
                    .frame(height: 50)
            }
            
            // Stations list using List for swipe actions with ScrollViewReader for tab focus
            ScrollViewReader { proxy in
                List {
                    ForEach(filteredStations) { station in
                        modernStationRow(for: station)
                            .id(station.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                    .onMove(perform: selectedTab == .radio && isEditing && (selectedSubTab == .all || selectedSubTab == .favorites) ? moveStations : nil)
                }
                .listStyle(PlainListStyle())
                .background(Color.black)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                .onReceive(radioPlayer.$currentStationIndex) { currentIndex in
                    scrollToCurrentStation(proxy: proxy)
                }
                .onReceive(radioPlayer.$isPlaying) { isPlaying in
                    if isPlaying {
                        scrollToCurrentStation(proxy: proxy)
                    }
                }
                .onChange(of: selectedTab) { oldTab, newTab in
                    // Handle tab changes - scroll to current station if switching to radio tab
                    if newTab == .radio {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            scrollToCurrentStation(proxy: proxy)
                        }
                    }
                }
                .onChange(of: selectedSubTab) { oldSubTab, newSubTab in
                    // Handle sub-tab changes - scroll to current station if it exists in new tab
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToCurrentStation(proxy: proxy)
                    }
                }
            }
        }
        .frame(width: screenWidth)
        .background(
            Color.black
                .onTapGesture {
                    // Tap on background to exit edit mode
                    if isEditing {
                        isEditing = false
                    }
                }
        )
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
            modernStationCard(for: station)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    // Long press activates sorting mode for All and Favorites tabs
                    if !isEditing && selectedTab == .radio && (selectedSubTab == .all || selectedSubTab == .favorites) {
                        isEditing = true
                        // Haptic feedback for long press
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                    }
                }
        )
        .swipeActions(edge: .leading) {
            Button {
                editStation(station)
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
            // Expanded tappable area for station info (includes more space after signal bars)
            Button(action: {
                if !isEditing {
                    handleStationTap(station)
                }
            }) {
                HStack(spacing: 12) {
                    // Station logo - 64x64 as per screenshot
                    modernStationLogo(for: station)
                    
                    // Station info
                    VStack(alignment: .leading, spacing: 4) {
                        // Station name - white text
                        Text(station.name)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        
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
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Equalizer (part of tappable area)
                    if isCurrentStation(station: station) && radioPlayer.isPlaying {
                        animatedEqualizer
                    } else {
                        staticEqualizer
                    }
                    
                    // Extra space to extend tappable area further right
                    Spacer()
                        .frame(width: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            // Favorite button (separate from tappable area)
            if !isEditing {
                heartFavoriteButton(for: station)
            }
        }
        .padding(.horizontal, 16)
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
    
    // MARK: - Equalizer Components
    
    struct EqualizerBar: View {
        let baseHeight: CGFloat
        let maxHeight: CGFloat
        let animationDelay: Double
        let isAnimating: Bool
        
        @State private var currentHeight: CGFloat
        @State private var animationTimer: Timer?
        
        init(baseHeight: CGFloat, maxHeight: CGFloat, animationDelay: Double, isAnimating: Bool) {
            self.baseHeight = baseHeight
            self.maxHeight = maxHeight
            self.animationDelay = animationDelay
            self.isAnimating = isAnimating
            self._currentHeight = State(initialValue: baseHeight)
        }
        
        var body: some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(0.8),
                            Color.cyan.opacity(0.6),
                            Color.blue
                        ]),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: 2.5, height: currentHeight)
                .animation(.easeInOut(duration: 0.3), value: currentHeight)
                .onAppear {
                    startAnimation()
                }
                .onChange(of: isAnimating) { _, newValue in
                    if newValue {
                        startAnimation()
                    } else {
                        stopAnimation()
                    }
                }
                .onDisappear {
                    stopAnimation()
                }
        }
        
        private func startAnimation() {
            guard isAnimating else { return }
            
            // Initial delay for staggered effect
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDelay) {
                animateBar()
            }
        }
        
        private func animateBar() {
            guard isAnimating else { return }
            
            // Random height between base and max for realistic equalizer effect
            let randomHeight = CGFloat.random(in: baseHeight...(maxHeight * 0.9))
            currentHeight = randomHeight
            
            // Schedule next animation with slight randomness for organic feel
            let nextDelay = Double.random(in: 0.2...0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) {
                animateBar()
            }
        }
        
        private func stopAnimation() {
            currentHeight = baseHeight
        }
    }

    @ViewBuilder
    private var animatedEqualizer: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                EqualizerBar(
                    baseHeight: CGFloat([6, 10, 14, 8, 12][index]),
                    maxHeight: CGFloat([16, 20, 24, 18, 22][index]),
                    animationDelay: Double(index) * 0.15,
                    isAnimating: radioPlayer.isPlaying
                )
            }
        }
        .frame(width: 28, height: 24)
    }
    
    @ViewBuilder
    private var staticEqualizer: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 2.5, height: CGFloat([6, 10, 14, 8, 12][index]))
            }
        }
        .frame(width: 28, height: 24)
    }
    
    @ViewBuilder
    private func heartFavoriteButton(for station: RadioStation) -> some View {
        Button(action: {
            handleFavoriteButtonTap(for: station)
        }) {
            Image(systemName: station.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(station.isFavorite ? .pink : .gray)
                .scaleEffect(station.isFavorite ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
                .frame(width: 44, height: 44)
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
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
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
        print("🎯 Station tapped: \(station.name), isEditing: \(isEditing)")
        
        // Don't handle tap if in editing mode - let native drag handle it
        guard !isEditing else { 
            print("⚠️ Ignoring tap because in editing mode")
            return 
        }
        
        if isStationPlaying(station) && radioPlayer.isPlaying {
            print("📱 Opening player sheet for playing station")
            isPlayerSheetPresented = true
        } else {
            print("▶️ Playing station: \(station.name)")
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
        print("🔄 Favorite button tapped for: \(station.name), isPlaying: \(isStationPlaying(station))")
        
        if isStationPlaying(station) && radioPlayer.isPlaying {
            print("⚠️ Station is playing, showing error")
            withAnimation(.easeIn(duration: 0.3)) {
                showFavoriteError = true
            }
            UIDevice.playHapticFeedback()
        } else {
            print("❤️ Toggling favorite for: \(station.name)")
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
    
    private func scrollToCurrentStation(proxy: ScrollViewProxy) {
        guard let currentIndex = radioPlayer.currentStationIndex,
              currentIndex < viewModel.stations.count else { return }
        
        let currentStationId = viewModel.stations[currentIndex].id
        
        // Check if the current station exists in the filtered list for the current tab
        if filteredStations.contains(where: { $0.id == currentStationId }) {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(currentStationId, anchor: .center)
            }
            print("📱 Scrolled to current playing station: \(viewModel.stations[currentIndex].name) in \(selectedSubTab.title) tab")
        }
    }

    
    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
    }
    
    private func moveStations(from source: IndexSet, to destination: Int) {
        guard selectedTab == .radio else { return }
        
        // Handle different subtab scenarios
        switch selectedSubTab {
        case .all:
            // Get the current filtered stations (all stations for this country)
            let countryStations = viewModel.stations.filter { $0.country == viewModel.selectedCountry }
            var reorderedStations = countryStations
            reorderedStations.move(fromOffsets: source, toOffset: destination)
            
            // Update the main stations array by replacing all stations for this country
            // First, remove all existing stations for this country
            viewModel.stations.removeAll { $0.country == viewModel.selectedCountry }
            
            // Then add the reordered stations back in the correct positions
            for (index, station) in reorderedStations.enumerated() {
                viewModel.stations.append(station)
            }
            
            // Sort the full array to maintain order consistency
            viewModel.stations.sort { first, second in
                if first.country != second.country {
                    return first.country < second.country
                }
                // Within the same country, maintain the order we just set
                let firstIndex = reorderedStations.firstIndex { $0.id == first.id } ?? 0
                let secondIndex = reorderedStations.firstIndex { $0.id == second.id } ?? 0
                return firstIndex < secondIndex
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
        if let currentStationIndex = radioPlayer.currentStationIndex,
           currentStationIndex < viewModel.stations.count {
            let currentStationId = viewModel.stations[currentStationIndex].id
            // Find the new index of the currently playing station
            if let newIndex = viewModel.stations.firstIndex(where: { $0.id == currentStationId }) {
                radioPlayer.currentStationIndex = newIndex
            }
        }
    }
    
    // MARK: - Edit Station Handler
    
    private func editStation(_ station: RadioStation) {
        // Ensure we have a valid station before proceeding
        guard !station.name.isEmpty else {
            print("❌ EditStation: Invalid station provided")
            return
        }
        
        print("📝 EditStation: Starting edit for station: \(station.name)")
        
        // Set the station immediately on the main queue
        selectedStationForEdit = station
        
        // Verify the station was set correctly
        guard selectedStationForEdit?.id == station.id else {
            print("❌ EditStation: Failed to set selectedStationForEdit")
            return
        }
        
        print("✅ EditStation: selectedStationForEdit set successfully")
        
        // Present the sheet with multiple fallback attempts
        var attempts = 0
        let maxAttempts = 5
        
        func attemptSheetPresentation() {
            attempts += 1
            
            // Verify the selected station is still valid
            guard let selected = selectedStationForEdit, selected.id == station.id else {
                print("❌ EditStation: selectedStationForEdit lost on attempt \(attempts)")
                if attempts < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempts)) {
                        selectedStationForEdit = station
                        attemptSheetPresentation()
                    }
                }
                return
            }
            
            print("📱 EditStation: Presenting sheet (attempt \(attempts))")
            activeSheet = .editStation
            
            // Verify the sheet was set
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if activeSheet == .editStation {
                    print("✅ EditStation: Sheet presentation successful")
                } else if attempts < maxAttempts {
                    print("⚠️ EditStation: Sheet presentation failed, retrying...")
                    attemptSheetPresentation()
                }
            }
        }
        
        // Start the presentation attempt
        DispatchQueue.main.async {
            attemptSheetPresentation()
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
























