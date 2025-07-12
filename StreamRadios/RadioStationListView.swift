// RadioStationListView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import UniformTypeIdentifiers
import FlagKit

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
    @Binding var searchText: String

    @StateObject private var alertManager = AlertManager()

    @State private var showFavoriteError = false
    
    // Delete confirmation
    @State private var showDeleteAlert = false
    @State private var stationToDelete: RadioStation?
    
    // Track tapped station for immediate focus
    @State private var tappedStationId: String?
    
    // State tracking for logging optimization
    @State private var lastScrollSkipLog: Date?
    
    var body: some View {
        GeometryReader { geometry in
            if viewModel.isLoading {
                VStack {
                    ProgressView("Loading stations...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .adaptivePrimaryText))
                        .scaleEffect(1.5)
                        .foregroundColor(.adaptivePrimaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.adaptiveBackground)
            } else if viewModel.stations.isEmpty {
                emptyStateView
            } else {
                stationsListView(screenWidth: geometry.size.width)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground)
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
                    Color.adaptiveBackground.opacity(0.8)
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
                                .font(.subheadline)
                                .foregroundColor(.adaptiveSecondaryText)
                                .allowsHitTesting(false) // Prevent text from blocking gestures
                            
                            Spacer()
                                .allowsHitTesting(false) // Prevent spacer from blocking gestures
                            
                            Button("Done") {
                                isEditing = false
                            }
                            .font(.body)
                            .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.adaptiveTabBackground)
                        .overlay(
                            Rectangle()
                                .fill(Color.adaptiveSeparator)
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
                    deleteStation(station)
                }
                stationToDelete = nil
            }
        } message: {
            if let station = stationToDelete {
                Text("Are you sure you want to delete \"\(station.name)\"? This action cannot be undone.")
            }
        }
        .onChange(of: showFavoriteError) { oldValue, newValue in
            if newValue == true {
                // Auto-dismiss the error after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showFavoriteError = false
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack {
            Text("No stations configured")
                .font(.title)
                .foregroundColor(.adaptivePrimaryText)
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
                        .foregroundColor(.adaptivePrimaryText)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground)
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
                    
                    // Add extra space at the bottom for better scrolling when global player is visible
                    Color.clear
                        .frame(height: 120)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .listStyle(PlainListStyle())
                .background(Color.adaptiveBackground)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { _ in
                            UserDefaults.standard.set(true, forKey: "isUserScrolling")
                            // Post notification for PodcastPlayer scroll detection
                            NotificationCenter.default.post(name: .userIsScrolling, object: nil)
                        }
                        .onEnded { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                UserDefaults.standard.set(false, forKey: "isUserScrolling")
                                // Post notification for PodcastPlayer scroll detection
                                NotificationCenter.default.post(name: .userStoppedScrolling, object: nil)
                            }
                        }
                )
                .onReceive(radioPlayer.$currentStationIndex) { currentIndex in
                    if !isEditing {
                        // Scroll when station index changes - indicates new station selection
                        scrollToCurrentStation(proxy: proxy)
                    }
                }
                .onReceive(radioPlayer.$isPlaying) { isPlaying in
                    if !isEditing {
                        // ONLY scroll when pausing (stopping) - NEVER when starting to play
                        if !isPlaying {
                            scrollToCurrentStation(proxy: proxy)
                        }
                    }
                }
                .onChange(of: selectedTab) { oldTab, newTab in
                    // Handle tab changes - scroll to current station if switching to radio tab
                    if newTab == .radio && !isEditing {
                        // Use a more robust approach to ensure the view is updated before scrolling
                        DispatchQueue.main.async {
                            // First dispatch ensures the view updates with the new tab
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // Second dispatch with shorter delay to ensure filteredStations is computed
                                if !isEditing {
                                    self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                                }
                            }
                        }
                    }
                }
                .onChange(of: selectedSubTab) { oldSubTab, newSubTab in
                    // Handle sub-tab changes - scroll to current station if it exists in new tab
                    if !isEditing {
                        // Use a more robust approach to ensure the view is updated before scrolling
                        DispatchQueue.main.async {
                            // First dispatch ensures the view updates with the new tab
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // Second dispatch with shorter delay to ensure filteredStations is computed
                                if !isEditing {
                                    self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                                }
                            }
                        }
                    }
                }
                .onChange(of: tappedStationId) { oldId, newId in
                    // Handle immediate focus on tapped station
                    if let stationId = newId, !isEditing {
                        // Check if the tapped station exists in the current filtered list
                        if filteredStations.contains(where: { $0.id == stationId }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(stationId, anchor: .center)
                            }
                            
                            // Find station name for logging
                            if let station = viewModel.stations.first(where: { $0.id == stationId }) {
                                print("📱 Immediately scrolled to tapped station: \(station.name) in \(selectedSubTab.title) tab")
                            }
                        }
                        
                        // Clear the tapped station ID after handling to allow automatic scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            tappedStationId = nil
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // Scroll to playing station when app comes to foreground
                    if !isEditing {
                        // Use a more robust approach to ensure the view is updated before scrolling
                        DispatchQueue.main.async {
                            // First dispatch ensures the view updates
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // Second dispatch with shorter delay to ensure filteredStations is computed
                                if !isEditing {
                                    self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: screenWidth)
        .background(
            Color.adaptiveBackground
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
            if showFavoriteError && viewModel.isStationCurrentlyPlaying(station) {
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
                        // Stop any currently playing audio to prevent interference with sorting
                        if radioPlayer.isPlaying {
                            radioPlayer.pause()
                        }
                        
                        // Also stop podcast playback if it's currently playing
                        let podcastPlayer = PodcastPlayer.shared
                        if podcastPlayer.isPlaying {
                            podcastPlayer.pause()
                        }
                        
                        isEditing = true
                        // Haptic feedback for long press
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                    }
                }
        )
        .swipeActions(edge: .leading) {
            if !isEditing {
                Button {
                    editStation(station)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isEditing {
                Button(role: .destructive) {
                    stationToDelete = station
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
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
            Text("Cannot favorite while actively playing")
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.2))
        .cornerRadius(8)
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func modernStationCard(for station: RadioStation) -> some View {
        let isCurrentlyPlaying = isCurrentStation(station: station) && radioPlayer.isPlaying
        
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
                    
                    // Station info - give maximum available space
                    VStack(alignment: .leading, spacing: 4) {
                        // Station name - adaptive text with maximum space
                        Text(station.name)
                            .font(.body)
                            .foregroundColor(.adaptivePrimaryText)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        
                        // Country info with flag for Recent and Favorites tabs
                        HStack(spacing: 6) {
                            // Show country flag in Recent and Favorites tabs since they show stations from all countries
                            if selectedSubTab == .recent || selectedSubTab == .favorites {
                                if let flagImage = flagImage(for: station.country) {
                                    Image(uiImage: flagImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 12)
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                }
                            }
                            
                            // Country text - blue text as per screenshot
                            Text(station.country)
                                .font(.subheadline)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                        
                        // Show metadata if playing
                        if isCurrentlyPlaying {
                            if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                                Text(metadata)
                                    .font(.caption)
                                    .foregroundColor(.adaptiveSecondaryText)
                                    .lineLimit(nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1) // Give station info priority in layout
                    
                    Spacer(minLength: 8)
                    
                    // Equalizer (part of tappable area)
                    if isCurrentlyPlaying {
                        animatedEqualizer
                    } else {
                        staticEqualizer
                    }
                    
                    // Extra space to extend tappable area further right
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isEditing)
            .opacity(isEditing ? 0.6 : 1.0)
            
            // Favorite button (separate from tappable area)
            if !isEditing {
                heartFavoriteButton(for: station)
            }
            
            // Spacer to fill remaining space and push content to cover hamburger menu area
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure full width coverage
        .background(
            // Background that covers the entire available space
            Rectangle()
                .fill(
                    isEditing 
                        ? Color.clear // No background color when sorting
                        : (isCurrentlyPlaying ? Color.blue.opacity(0.03) : Color.adaptiveCardBackground.opacity(0.7)) // Darker normal background
                )
                .frame(maxWidth: .infinity) // Ensure background fills all available space
                .overlay(
                    // Border highlight for currently playing station (only when not editing)
                    Rectangle()
                        .stroke(isCurrentlyPlaying && !isEditing ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
                )
        )
        .overlay(
            // Separator line (hidden during editing mode)
            Group {
                if !isEditing {
                    Rectangle()
                        .fill(Color.adaptiveSeparator)
                        .frame(height: 0.5)
                        .padding(.leading, 88) // Align with text content
                }
            },
            alignment: .bottom
        )
    }
    
    @ViewBuilder
    private func modernStationLogo(for station: RadioStation) -> some View {
        ZStack {
            // Background for logo
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.adaptiveBorder)
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
                    .fill(Color.adaptiveSecondaryText.opacity(0.4))
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
                .font(.title3)
                .foregroundColor(station.isFavorite ? .red : .adaptiveSecondaryText)
                .scaleEffect(station.isFavorite ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(station.isFavorite ? Color.red.opacity(0.1) : Color.clear)
                        .scaleEffect(station.isFavorite ? 1.0 : 0.8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
                )
                .overlay(
                    Circle()
                        .stroke(station.isFavorite ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                        .scaleEffect(station.isFavorite ? 1.0 : 0.8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    @ViewBuilder
    private func imageForStation(_ station: RadioStation) -> some View {
        // Only show iTunes artwork for currently playing station
        if isCurrentStation(station: station) && radioPlayer.isPlaying {
            if let iTunesArt = radioPlayer.iTunesAlbumArt {
                Image(uiImage: iTunesArt)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if let iconData = station.iconData,
                      let imageData = Data(base64Encoded: iconData),
                      let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white.opacity(0.1))
            } else {
                defaultStationImage(station)
            }
        }
        // For non-playing stations, always show station icon or default
        else {
            if let iconData = station.iconData,
               let imageData = Data(base64Encoded: iconData),
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white.opacity(0.1))
            } else {
                defaultStationImage(station)
            }
        }
    }
    
    private func defaultStationImage(_ station: RadioStation) -> some View {
        ZStack {
            Color.adaptiveBorder
            
            // Always show radio icon instead of first 2 letters
            Image(systemName: "radio")
                .font(.title2)
                .foregroundColor(.adaptivePrimaryText)
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
        
        // Dismiss keyboard when a station is tapped
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Check if this is the exact same station that's currently playing
        let isSameStationPlaying = radioPlayer.currentStationIndex != nil &&
                                   radioPlayer.currentStationIndex! < viewModel.stations.count &&
                                   viewModel.stations[radioPlayer.currentStationIndex!].id == station.id &&
                                   radioPlayer.isPlaying
        
        if isSameStationPlaying {
            // Same station is already playing - open Shazam view
            print("🎵 Opening Shazam view for playing station: \(station.name)")
            isPlayerSheetPresented = true
        } else {
            // Different station or no station playing - start playing this station
            print("▶️ Playing station: \(station.name)")
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                print("🔍 Found station at index: \(index)")
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
                
                // Trigger immediate focus on the tapped station
                tappedStationId = station.id
            } else {
                print("❌ Station not found in viewModel.stations")
            }
        }
    }
    
    private func handlePlayButtonTap(for station: RadioStation) {
        // Dismiss keyboard when play button is tapped
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
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
        print("🔄 Favorite button tapped for: \(station.name), isCurrentlyPlaying: \(viewModel.isStationCurrentlyPlaying(station))")
        
        if viewModel.isStationCurrentlyPlaying(station) {
            print("⚠️ Station is actively playing, showing error")
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
        
        var stations: [RadioStation]
        
        switch selectedSubTab {
        case .all:
            // All tab shows stations from the selected country only, sorted by order
            stations = viewModel.stations.filter { $0.country == viewModel.selectedCountry }
                .sorted { $0.order < $1.order }
        case .recent:
            // Recent tab shows recent stations from ALL countries
            stations = viewModel.recentStations()
        case .favorites:
            // Favorites tab shows favorites from ALL countries
            stations = viewModel.favoriteStations()
        }
        
        // Apply search filter if search text is not empty
        if !searchText.isEmpty {
            stations = stations.filter { station in
                station.name.localizedCaseInsensitiveContains(searchText) ||
                station.country.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return stations
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
    
    private func scrollToCurrentStation(proxy: ScrollViewProxy, isOnLoadOrTabSwitch: Bool = false) {
        // Don't interfere with immediate focus on tapped stations
        if tappedStationId != nil {
            // Rate limit this log message - only log once every 5 seconds
            let now = Date()
            if lastScrollSkipLog == nil || now.timeIntervalSince(lastScrollSkipLog!) > 5.0 {
                print("📱 Skipping scroll - tapped station focus is active")
                lastScrollSkipLog = now
            }
            return
        }
        
        // Handle different tab behaviors when a station is playing
        if radioPlayer.isPlaying {
            if let currentIndex = radioPlayer.currentStationIndex,
               currentIndex < viewModel.stations.count {
                
                let currentStationId = viewModel.stations[currentIndex].id
                let currentStationName = viewModel.stations[currentIndex].name
                
                // On load/tab switch: Always scroll to playing station in ALL tabs
                if isOnLoadOrTabSwitch {
                    if filteredStations.contains(where: { $0.id == currentStationId }) {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(currentStationId, anchor: .center)
                        }
                        print("📱 [ON LOAD] Scrolled to currently playing station: \(currentStationName) in \(selectedSubTab.title) tab")
                    } else {
                        print("📱 [ON LOAD] Playing station \(currentStationName) not in current \(selectedSubTab.title) tab")
                    }
                    return
                }
                
                // During playback: Different behavior based on current tab
                switch selectedSubTab {
                case .recent:
                    // Recent tab: Always scroll to top when playing (during playback changes)
                    if let firstStation = filteredStations.first {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(firstStation.id, anchor: .top)
                        }
                        print("📱 Scrolled to top of Recent tab - station playing")
                    }
                    
                case .favorites, .all:
                    // Favorites and All tabs: Try to keep focus on playing station
                    if filteredStations.contains(where: { $0.id == currentStationId }) {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(currentStationId, anchor: .center)
                        }
                        print("📱 Scrolled to currently playing station: \(currentStationName) in \(selectedSubTab.title) tab")
                    } else {
                        // Playing station not in current tab - maintain current position
                        print("📱 Playing station \(currentStationName) not in current \(selectedSubTab.title) tab - maintaining current position")
                    }
                }
            }
            return
        }
        
        // Scroll to top when station is paused or no station is selected
        if let firstStation = filteredStations.first {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(firstStation.id, anchor: .top)
            }
            
            if let currentIndex = radioPlayer.currentStationIndex,
               currentIndex < viewModel.stations.count {
                print("📱 Scrolled to top of \(selectedSubTab.title) tab - station paused")
            } else {
                print("📱 Scrolled to top of \(selectedSubTab.title) tab - no station selected")
            }
        }
    }
    
    private func scrollToCurrentStationWithRetry(proxy: ScrollViewProxy, isOnLoadOrTabSwitch: Bool = false, retryCount: Int, maxRetries: Int = 3) {
        // Don't interfere with immediate focus on tapped stations
        if tappedStationId != nil {
            // Rate limit this log message - only log once every 5 seconds
            let now = Date()
            if lastScrollSkipLog == nil || now.timeIntervalSince(lastScrollSkipLog!) > 5.0 {
                print("📱 Skipping scroll - tapped station focus is active")
                lastScrollSkipLog = now
            }
            return
        }
        
        // Handle different tab behaviors when a station is playing
        if radioPlayer.isPlaying {
            if let currentIndex = radioPlayer.currentStationIndex,
               currentIndex < viewModel.stations.count {
                
                let currentStationId = viewModel.stations[currentIndex].id
                let currentStationName = viewModel.stations[currentIndex].name
                
                // Check if the station exists in the current filtered stations
                if filteredStations.contains(where: { $0.id == currentStationId }) {
                    // Station found - scroll to it
                    withAnimation(.easeInOut(duration: 0.5)) {
                        proxy.scrollTo(currentStationId, anchor: .center)
                    }
                    print("📱 [TAB SWITCH] Scrolled to currently playing station: \(currentStationName) in \(selectedSubTab.title) tab")
                } else {
                    // Station not found in current tab
                    if retryCount < maxRetries {
                        // Retry after a short delay to allow the view to update
                        print("📱 [TAB SWITCH] Station \(currentStationName) not found in \(selectedSubTab.title) tab, retrying... (\(retryCount + 1)/\(maxRetries))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: isOnLoadOrTabSwitch, retryCount: retryCount + 1, maxRetries: maxRetries)
                        }
                    } else {
                        // Max retries reached - station is not in this tab
                        print("📱 [TAB SWITCH] Playing station \(currentStationName) not available in \(selectedSubTab.title) tab after \(maxRetries) retries")
                        
                        // For favorites tab, this is expected if the station isn't favorited
                        if selectedSubTab == .favorites {
                            print("📱 [TAB SWITCH] This is expected for non-favorited stations in Favorites tab")
                        }
                    }
                }
                return
            }
        }
        
        // Scroll to top when station is paused or no station is selected
        if let firstStation = filteredStations.first {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(firstStation.id, anchor: .top)
            }
            print("📱 [TAB SWITCH] Scrolled to top of \(selectedSubTab.title) tab - no playing station")
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
            // Get the current filtered stations (all stations for this country) sorted by order
            var countryStations = viewModel.stations.filter { $0.country == viewModel.selectedCountry }
                .sorted { $0.order < $1.order }
            
            // Perform the move operation
            countryStations.move(fromOffsets: source, toOffset: destination)
            
            // Update the order property for each station in the reordered country list
            for (index, station) in countryStations.enumerated() {
                if let stationIndex = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                    viewModel.stations[stationIndex].order = index
                }
            }
            
        case .favorites:
            // Move within favorites (all countries)
            var favoriteStations = filteredStations
            favoriteStations.move(fromOffsets: source, toOffset: destination)
            
            // Update favorite order
            for (index, favStation) in favoriteStations.enumerated() {
                if let stationIndex = viewModel.stations.firstIndex(where: { $0.id == favStation.id }) {
                    viewModel.stations[stationIndex].favoriteOrder = index
                }
            }
            
        case .recent:
            // Recent stations can't be reordered manually (they're sorted by play time across all countries)
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
    
    // MARK: - Helper Functions
    
    private func flagImage(for country: String) -> UIImage? {
        return Flag(countryCode: country)?.originalImage
    }
    
    // MARK: - Edit Station Handler
    
    private func editStation(_ station: RadioStation) {
        print("📝 EditStation: Starting edit for station: \(station.name)")
        
        // Set the station first
        selectedStationForEdit = station
        
        // Add a small delay to ensure the binding propagates before presenting the sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            print("📝 EditStation: selectedStationForEdit is now: \(self.selectedStationForEdit?.name ?? "nil")")
            self.activeSheet = .editStation
            print("✅ EditStation: Sheet presented for station: \(station.name)")
        }
    }

}



struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    @State static var activeSheet: ActiveSheet? = nil
    @State static var isPlayerSheetPresented = false
    @State static var searchText = ""
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.radio),
                             selectedSubTab: .constant(.all), activeSheet: $activeSheet,
                             isPlayerSheetPresented: $isPlayerSheetPresented,
                             searchText: $searchText)
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let userIsScrolling = Notification.Name("userIsScrolling")
    static let userStoppedScrolling = Notification.Name("userStoppedScrolling")
}
