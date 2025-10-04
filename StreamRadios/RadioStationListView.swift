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

// Custom ViewModifier to handle station card animations
struct StationCardAnimationModifier: ViewModifier {
    let isTapped: Bool
    let isLoading: Bool
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isTapped ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTapped)
    }
    
    @ViewBuilder
    private var loadingIndicator: some View {
        // Loading indicator removed - visual feedback now only on artwork
        EmptyView()
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
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool

    @StateObject private var alertManager = AlertManager()
    @AppStorage("hiddenCountries") private var hiddenCountriesData: Data = Data()
    @State private var hiddenCountries: Set<String> = []

    @State private var showFavoriteError = false
    
    // Delete confirmation
    @State private var showDeleteAlert = false
    @State private var stationToDelete: RadioStation?
    
    // Edit/Delete protection for playing stations
    @State private var showEditPlayingAlert = false
    @State private var showDeletePlayingAlert = false
    
    // Track tapped station for immediate focus
    @State private var tappedStationId: String?
    
    // Visual feedback for station tap
    @State private var tappedStationForAnimation: String?
    @State private var loadingStationId: String?
    
    // State tracking for logging optimization
    @State private var lastScrollSkipLog: Date?
    
    // Country picker sheet state
    @State private var showingCountryPicker = false
    
    // Search container state
    @Binding var isSearchPresented: Bool
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if viewModel.isLoading {
                    StylishLoaderView(
                        title: "Loading Stations",
                        phase: viewModel.loadingPhase,
                        progress: viewModel.loadingProgress,
                        current: viewModel.loadingStationsCount,
                        total: viewModel.totalStationsToLoad
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.adaptiveBackground)
                } else if filteredStations.isEmpty {
                    emptyStateView
                } else {
                    stationsListView(screenWidth: geometry.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.adaptiveBackground)
            
            // Custom Alert Overlay
            if alertManager.showCustomAlert {
                CustomAlertContainer()
                    .environmentObject(alertManager)
            }
        }
        .onAppear(perform: setup)
        .onAppear {
            setup()
            // Removed playFavoriteStation() - automatic playback should be controlled by Auto-Play Last Station setting
            loadHiddenCountries()
        }
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: .hiddenCountriesChanged)) { _ in
            loadHiddenCountries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
            // CRITICAL FIX: Don't reload from Core Data if stations were just loaded via fetchStationsForSelectedCountry
            // This prevents manual stations from being wiped out after they're loaded
            print("📻 🔧 FIX: Received stationsUpdated notification - preserving in-memory stations to avoid wiping manual stations")
            
            // Force UI update immediately without reloading from Core Data
            DispatchQueue.main.async {
                viewModel.objectWillChange.send()
                
                // If current tab filter hides results but country has stations, show All tab
                let countryCount = viewModel.stations.filter { $0.country == viewModel.selectedCountry }.count
                if countryCount > 0 && selectedSubTab != .all {
                    viewModel.selectedSubTab = .all
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .countryChanged)) { _ in
            // Handle country changes without affecting currently playing station
            print("🌍 Received countryChanged notification - updating UI for country selection")
            
            DispatchQueue.main.async {
                viewModel.objectWillChange.send()
                
                // If current tab filter hides results but country has stations, show All tab
                let countryCount = viewModel.stations.filter { $0.country == viewModel.selectedCountry }.count
                if countryCount > 0 && selectedSubTab != .all {
                    viewModel.selectedSubTab = .all
                }
            }
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
                
                // Edit mode header (only for Favorites tab since All tab doesn't allow reordering)
                if isEditing && selectedSubTab == .favorites {
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
        .alert("Cannot Edit Playing Station", isPresented: $showEditPlayingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The station is currently playing. Please stop or switch to another station before editing.")
        }
        .alert("Cannot Delete Playing Station", isPresented: $showDeletePlayingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The station is currently playing. Please stop or switch to another station before deleting.")
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
        .sheet(isPresented: $showingCountryPicker) {
            CountryPicker(
                selectedCountry: $viewModel.selectedCountry,
                countries: viewModel.countries,
                stationCount: { country in
                    viewModel.stations.filter { $0.country == country }.count
                },
                onSelect: { country in
                    // Trigger refresh when country is selected
                    Task {
                        UIDevice.playHapticFeedback()
                        await viewModel.fetchStationsForSelectedCountry(forceRefresh: false)
                        await MainActor.run {
                            viewModel.syncStationsWithCloudKit()
                        }
                    }
                }
            )
        }
    }
    
    // MARK: - Navigation Bar Button Container
    
    @ViewBuilder
    private var navigationBarButtonContainer: some View {
        if #available(iOS 26.0, *) {
            // iOS 26+ with Liquid Glass
            navigationBarButtonContent
                .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            // iOS < 26 fallback
            navigationBarButtonContent
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.adaptiveSecondaryBackground.opacity(0.8))
                )
        }
    }
    
    @ViewBuilder
    private var navigationBarButtonContent: some View {
        Group {
            if isSearchPresented {
                // Only Cancel button when search is active
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isSearchPresented = false
                        searchText = ""
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                .foregroundColor(.blue)
            } else {
                HStack(spacing: 8) {
                    // Search toggle button - Shows in all tabs
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isSearchPresented = true
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    
                    // Sort button - Only show in Favorites and All tabs
                    if selectedSubTab == .favorites || selectedSubTab == .all {
                        Button(action: {
                            print("🔄 Sort button tapped in \(selectedSubTab == .favorites ? "Favorites" : "All") tab")
                            // Show alert for Favorites tab to warn about modifying order
                            if selectedSubTab == .favorites {
                                print("⚠️ Showing favorites sort confirmation alert")
                                alertManager.showCustomAlert(for: .confirmFavoritesSortChange) {
                                    print("✅ User confirmed favorites sort change")
                                    viewModel.sortFavoritesAlphabetically()
                                }
                            } else {
                                // All tab - no alert needed
                                print("✅ Sorting All tab immediately (no alert)")
                                viewModel.sortStationsAlphabetically()
                            }
                        }) {
                            Image(systemName: viewModel.isAscendingSort ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 28, height: 28)
                        }
                    }
                    
                    // Add station button - Shows in all tabs
                    Button(action: {
                        if viewModel.selectedCountry == "Select Country" {
                            alertManager.showCustomAlert(for: .selectCountryBeforeAddingStation)
                        } else {
                            selectedStationForEdit = nil
                            activeSheet = .addStation
                        }
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        )
    }
    
    private var emptyStateView: some View {
        VStack {
            // RECENT, FAVORITES & ALL TAB FIX: Don't show anything when stations exist but tabs are empty
            if (selectedSubTab == .recent && !viewModel.stations.isEmpty) ||
               (selectedSubTab == .favorites && !viewModel.stations.isEmpty) {
                // Show nothing for Recent/Favorites tabs when stations exist but tabs are empty
                Color.clear
            } else if selectedSubTab == .all && !viewModel.stations.isEmpty && viewModel.selectedCountry != "Select Country" {
                // All tab with country selected but no stations for that country
                VStack {
                    Spacer()
                        .frame(minHeight: 40, maxHeight: 80) // Reduced top spacing for small screens
                    
                    VStack(spacing: 16) {
                        Image(systemName: "radio")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        
                        Text("No stations available")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.adaptivePrimaryText)
                        
                        Text("No radio stations found for \(viewModel.selectedCountry)")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        
                        VStack(spacing: 12) {
                            Button(action: {
                                Task {
                                    await viewModel.fetchStationsForSelectedCountry(forceRefresh: true)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("Try Again")
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color.blue)
                                )
                            }
                            
                            Button(action: {
                                showingCountryPicker = true
                            }) {
                                HStack {
                                    Image(systemName: "globe")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("Choose Different Country")
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color.blue, lineWidth: 1)
                                )
                            }
                        }
                        .padding(.top, 8)
                    }
                    
                    Spacer()
                        .frame(minHeight: 80, maxHeight: 120) // More bottom spacing to ensure buttons are visible
                }
                .padding(.horizontal, 40)
            } else if viewModel.stations.isEmpty {
                // No stations exist at all - show country selection button
                VStack {
                    Spacer()
                        .frame(minHeight: 60, maxHeight: 100)
                    
                    VStack(spacing: 16) {
                        Text("No stations configured")
                            .font(.headline)
                            .foregroundColor(.adaptivePrimaryText)
                        
                        Button(action: {
                            showingCountryPicker = true
                        }) {
                            HStack {
                                Image(systemName: "globe")
                                Text("Select Country")
                            }
                            .font(.body)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.blue)
                            .cornerRadius(8)
        
                        }
                    }
                    
                    Spacer()
                        .frame(minHeight: 100, maxHeight: 140)
                }
            } else if viewModel.selectedCountry == "Select Country" {
                // Stations exist but no country selected - show selection prompt
                VStack {
                    Spacer()
                        .frame(minHeight: 60, maxHeight: 100)
                    
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Text("Select a Country")
                            .font(.headline)
                            .foregroundColor(.adaptivePrimaryText)
                        Text("Select any country to explore its radio stations")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: {
                            showingCountryPicker = true
                        }) {
                            HStack {
                                Image(systemName: "globe")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Browse Countries")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 25)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                            .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.top, 20)
                    }
                    
                    Spacer()
                        .frame(minHeight: 100, maxHeight: 140)
                }
                .padding(.horizontal, 40)
            } else {
                // Fallback case (should not normally be reached with new logic)
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground)
        .transition(.scale)
    }
    
    private func stationsListView(screenWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Add top padding when in editing mode for Favorites tab only
            if isEditing && selectedSubTab == .favorites {
                Spacer()
                    .frame(height: 50)
            }
            
            // Stations list using List for swipe actions with ScrollViewReader for tab focus
            ScrollViewReader { proxy in
                stationList(proxy: proxy)
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

    // Extracted to reduce type-checking complexity
    private func stationList(proxy: ScrollViewProxy) -> some View {
        List {
            ForEach(filteredStations) { station in
                stationRow(for: station)
                    .id(station.id)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            .onMove(perform: selectedTab == .radio && isEditing && selectedSubTab == .favorites ? moveStations : nil)
            
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
            DragGesture(minimumDistance: 10) // Set minimum distance to 10 to avoid interfering with button taps
                .onChanged { _ in
                    // IMMEDIATE update - no conditions, just set it
                    DispatchQueue.main.async {
                        if !isScrolling {
                            print("🏠 DEBUG: Setting isScrolling = true in RadioStationListView")
                            isScrolling = true
                            // CRITICAL FIX: Only hide footer menu if user has ever played content
                            // FIRST-TIME PLAYBACK PROTECTION: Only set scroll state, let ContentView handle TabView hiding
                            // REMOVED: Direct isFooterMenuHidden assignment - let ContentView shouldHideFooterMenu logic handle this
                        }
                    }
                }
                .onEnded { _ in
                    // Debounce the scroll end to prevent rapid state changes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        print("🏠 DEBUG: Setting isScrolling = false in RadioStationListView")
                        isScrolling = false
                        // Note: Don't reset isFooterMenuHidden here - let home button control it
                    }
                }
        )
        .onReceive(radioPlayer.$currentStationIndex) { _ in
            if !isEditing { scrollToCurrentStation(proxy: proxy) }
        }
        .onReceive(radioPlayer.$isPlaying) { isPlaying in
            if !isEditing && !isPlaying { scrollToCurrentStation(proxy: proxy) }
            
            // Clear loading state when playback starts or stops
            if isPlaying && loadingStationId != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadingStationId = nil
                }
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .radio && !isEditing {
                DispatchQueue.main.async {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !isEditing {
                            self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                        }
                    }
                }
            }
        }
        .onChange(of: selectedSubTab) { oldValue, newValue in
            // CRITICAL: Disable editing mode when switching away from Favorites tab
            if isEditing && newValue != .favorites {
                print("🔄 Tab switched from \(oldValue.title) to \(newValue.title) - disabling edit mode")
                isEditing = false
            }
            
            if !isEditing {
                DispatchQueue.main.async {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !isEditing {
                            self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                        }
                    }
                }
            }
        }
        .onChange(of: tappedStationId) { _, newId in
            if let stationId = newId, !isEditing {
                if filteredStations.contains(where: { $0.id == stationId }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(stationId, anchor: .center)
                    }
                    if let station = viewModel.stations.first(where: { $0.id == stationId }) {
                        print("📱 Immediately scrolled to tapped station: \(station.name) in \(selectedSubTab.title) tab")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tappedStationId = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if !isEditing {
                DispatchQueue.main.async {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !isEditing {
                            self.scrollToCurrentStationWithRetry(proxy: proxy, isOnLoadOrTabSwitch: true, retryCount: 0)
                        }
                    }
                }
            }
        }
    }
    
    
    @ViewBuilder
    private func stationRow(for station: RadioStation) -> some View {
        VStack(spacing: 0) {
            // Show inline error above currently playing station if favorite toggle was attempted
            if showFavoriteError && viewModel.isStationCurrentlyPlaying(station) {
                errorBanner
            }
            
            // Main station card with gesture handling
            stationCard(for: station)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    // Long press activates sorting mode for Favorites tab only (All tab reordering is disabled)
                    if !isEditing && selectedTab == .radio && selectedSubTab == .favorites {
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
                    handleDeleteStation(station)
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
    private func stationCard(for station: RadioStation) -> some View {
        let isCurrentlyPlaying = isCurrentStation(station: station) && radioPlayer.isPlaying
        let isLoading = loadingStationId == station.id
        let isTapped = tappedStationForAnimation == station.id
        
        HStack(spacing: 12) {
            // Expanded tappable area for station info (includes more space after signal bars)
            Button(action: {
                if !isEditing {
                    handleStationTap(station)
                }
            }) {
                HStack(spacing: 12) {
                    // Station logo - 64x64 as per screenshot
                    stationLogo(for: station, isLoading: isLoading)
                    
                    // Station info - give maximum available space
                    VStack(alignment: .leading, spacing: 4) {
                        // Station name - adaptive text with maximum space
                        Text(station.name)
                            .font(.body)
                            .foregroundColor(.adaptivePrimaryText)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
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
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Show metadata if playing
                        if isCurrentlyPlaying {
                            if let shazamTitle = radioPlayer.displayTitle, let shazamArtist = radioPlayer.displayArtist {
                                Text("\(shazamTitle) — \(shazamArtist)")
                                    .font(.caption)
                                    .foregroundColor(.adaptiveSecondaryText)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                                let split = radioPlayer.splitArtistTitle(from: metadata, fallbackArtist: station.name, fallbackTitle: metadata)
                                Text("\(split.title) — \(split.artist)")
                                    .font(.caption)
                                    .foregroundColor(.adaptiveSecondaryText)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Equalizer aligned to the right
                    if isCurrentlyPlaying {
                        animatedEqualizer
                    } else {
                        staticEqualizer
                    }
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
                        .padding(.leading, 92) // Align with text content
                }
            },
            alignment: .bottom
        )
        // Visual feedback animations
        .modifier(StationCardAnimationModifier(isTapped: isTapped, isLoading: isLoading))
    }
    
    @ViewBuilder
    private func stationLogo(for station: RadioStation, isLoading: Bool = false) -> some View {
        ZStack {
            // Background for logo
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.adaptiveBorder)
                .frame(width: 64, height: 64)
            
            // Station image
            imageForStation(station)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isLoading ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isLoading)
            
            // Loading indicator overlay on artwork
            if isLoading {
                ZStack {
                    // Semi-transparent overlay
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 64, height: 64)
                    
                    // Loading spinner
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isLoading)
            }
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
        // For currently playing station, match player artwork logic exactly
        if isCurrentStation(station: station) {
            // Priority 1: iTunes artwork when playing
            if radioPlayer.isPlaying, let iTunesArt = radioPlayer.iTunesAlbumArt {
                Image(uiImage: iTunesArt)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            }
            // Priority 2: Station artwork from radioPlayer.albumArt when playing
            else if radioPlayer.isPlaying, let albumArt = radioPlayer.albumArt {
                Image(uiImage: albumArt)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            }
            // Priority 3: Station icon data when not playing or no artwork available
            else if let iconData = station.iconData,
                      let imageData = Data(base64Encoded: iconData),
                      let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white.opacity(0.1))
            }
            // Priority 4: Default station image
            else {
                defaultStationImage(station)
            }
        }
        // For non-current stations, always show station icon or default
        else {
            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
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
        
        // Immediate haptic feedback
        UIDevice.playHapticFeedback()
        
        // Immediate visual feedback - show tap animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            tappedStationForAnimation = station.id
        }
        
        // Reset tap animation after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                tappedStationForAnimation = nil
            }
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
            
            // Show loading state
            loadingStationId = station.id
            
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                print("🔍 Found station at index: \(index)")
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
                
                // Trigger immediate focus on the tapped station
                tappedStationId = station.id
                
                // Clear loading state after a delay (station should be connected by then)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    loadingStationId = nil
                }
                
            } else {
                print("❌ Station not found in viewModel.stations")
                // Clear loading state immediately if station not found
                loadingStationId = nil
            }
        }
    }
    
    private func handlePlayButtonTap(for station: RadioStation) {
        // Immediate haptic feedback
        UIDevice.playHapticFeedback()
        
        // Dismiss keyboard when play button is tapped
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        if isStationPlaying(station) {
            radioPlayer.togglePlayPause()
        } else {
            // Show loading state for new station
            loadingStationId = station.id
            
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
                
                // Clear loading state after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if loadingStationId == station.id {
                        loadingStationId = nil
                    }
                }
            } else {
                // Clear loading state immediately if station not found
                loadingStationId = nil
            }
        }
    }
    
    private func handleFavoriteButtonTap(for station: RadioStation) {
        print("❤️ Toggling favorite for: \(station.name)")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            viewModel.toggleFavorite(for: station)
        }
        viewModel.saveStationsToCoreData()
    }
    
    private var filteredStations: [RadioStation] {
        // Only filter for radio tab
        guard selectedTab == .radio else {
            return []
        }
        
        // UNIVERSAL SEARCH: When user is searching, search across ALL countries and ALL stations regardless of tab
        if !searchText.isEmpty {
            let allStations = viewModel.stations
            let filtered = allStations.filter { station in
                // Only show stations with valid country information
                let hasValidCountry = !station.country.isEmpty &&
                                    station.country != "Unknown Region" &&
                                    station.country != "Select Country" &&
                                    !station.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                
                let matchesSearch = station.name.localizedCaseInsensitiveContains(searchText) ||
                                  station.country.localizedCaseInsensitiveContains(searchText)
                
                let isNotHidden = !hiddenCountries.contains(station.country)
                
                return hasValidCountry && matchesSearch && isNotHidden
            }
            
            // GLOBAL SEARCH: All tabs now search globally across all countries and return all matching results
            // Sort results based on the current tab's sorting preference
            if selectedSubTab == .recent {
                // For Recent tab, prioritize recently played stations but show all search results
                // Sort by: recently played first, then alphabetically
                return filtered.sorted { station1, station2 in
                    let hasPlayed1 = station1.lastPlayed != nil
                    let hasPlayed2 = station2.lastPlayed != nil
                    
                    if hasPlayed1 && hasPlayed2 {
                        return station1.lastPlayed! > station2.lastPlayed!
                    } else if hasPlayed1 {
                        return true
                    } else if hasPlayed2 {
                        return false
                    } else {
                        return station1.name.localizedCaseInsensitiveCompare(station2.name) == .orderedAscending
                    }
                }
            } else if selectedSubTab == .favorites {
                // For Favorites tab, prioritize favorited stations but show all search results
                // Sort by: favorites first, then alphabetically
                return filtered.sorted { station1, station2 in
                    if station1.isFavorite && station2.isFavorite {
                        // Both are favorites, sort by favorite order or favoritedAt
                        if let order1 = station1.favoriteOrder, let order2 = station2.favoriteOrder {
                            return order1 < order2
                        } else if station1.favoriteOrder != nil {
                            return true
                        } else if station2.favoriteOrder != nil {
                            return false
                        } else {
                            let date1 = station1.favoritedAt ?? Date.distantPast
                            let date2 = station2.favoritedAt ?? Date.distantPast
                            return date1 > date2
                        }
                    } else if station1.isFavorite {
                        return true
                    } else if station2.isFavorite {
                        return false
                    } else {
                        return station1.name.localizedCaseInsensitiveCompare(station2.name) == .orderedAscending
                    }
                }
            } else {
                // All tab: sort alphabetically based on toggle setting
                if viewModel.isAscendingSort {
                    return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
                }
            }
        }
        
        var stations: [RadioStation]
        
        switch selectedSubTab {
        case .all:
            // All tab shows stations from the selected country only, sorted alphabetically
            // FRESH INSTALL FIX: Don't show any stations if no country is selected
            if viewModel.selectedCountry == "Select Country" {
                stations = []
            } else {
                stations = viewModel.stations.filter { station in
                    // Filter by selected country and ensure valid country information
                    let hasValidCountry = !station.country.isEmpty &&
                                        station.country != "Unknown Region" &&
                                        station.country != "Select Country" &&
                                        !station.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    let matches = station.country == viewModel.selectedCountry && hasValidCountry
                    return matches
                }
                
                // Sort alphabetically by name based on toggle setting
                if viewModel.isAscendingSort {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    stations = stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
                }
            }
        case .recent:
            // Recent tab shows recent stations from ALL countries regardless of country selection
            // Always ordered chronologically (most recent first) - no alphabetical sorting
            stations = viewModel.recentStations()
        case .favorites:
            // Favorites tab: Get favorite stations
            // The favoriteStations() method already returns stations sorted by favoriteOrder
            // which respects the user's manual drag-and-drop arrangement
            stations = viewModel.favoriteStations()
            
            // Note: We don't apply alphabetical sorting here to preserve manual reordering.
            // When user taps the sort button, it will trigger a re-sort through the alert,
            // but the manual favoriteOrder takes precedence for display.
        }
        
        return stations
    }
    
    private func isCurrentStation(station: RadioStation) -> Bool {
        // STABILITY FIX: Always prioritize currentlyPlayingStation for reliable station identification
        // This ensures station highlighting remains consistent regardless of country switching or auto-play
        if let currentStation = radioPlayer.currentlyPlayingStation {
            let isMatch = currentStation.id == station.id
            if isMatch {
                // Additional validation: ensure the station data is consistent
                return currentStation.name == station.name && currentStation.url == station.url
            }
            return false
        }
        
        // DEPRECATED FALLBACK: Only use currentStationIndex as absolute last resort
        // This fallback should rarely be needed with stable currentlyPlayingStation management
        if let currentIndex = radioPlayer.currentStationIndex,
           viewModel.stations.indices.contains(currentIndex) {
            return viewModel.stations[currentIndex].id == station.id
        }
        
        return false
    }
    
    private func deleteStation(_ station: RadioStation) {
        if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
            DataStore.shared.deleteStationFromCloudKit(station: station) { success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")
                        self.viewModel.stations.remove(at: index)
                        self.viewModel.deleteStationFromCoreData(station)
                        
                        // Mark that changes are expected on other devices after deletion
                        self.viewModel.forceCloudKitCheckOnNextLaunch()
                        
                        // INSTANT SYNC: Sync station removal immediately across devices
                        PodcastCloudKitManager.shared.syncRadioStationRemovedInstantly(
                            stationId: station.id,
                            stationName: station.name
                        )
                        
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
        // Remove observers
        NotificationCenter.default.removeObserver(self)
    }
    
    private func loadHiddenCountries() {
        if let decodedCountries = try? JSONDecoder().decode(Set<String>.self, from: hiddenCountriesData) {
            hiddenCountries = decodedCountries
        }
    }

    private func moveStations(from source: IndexSet, to destination: Int) {
        guard selectedTab == .radio else { return }
        
        // Handle different subtab scenarios
        switch selectedSubTab {
        case .all:
            // All tab: Order changing is disabled
            print("⚠️ Order changing is disabled for All tab")
            return
            
        case .favorites:
            // FIXED: Use the ViewModel's moveFavoriteStation method for proper CloudKit sync
            print("📡 🔄 UI: Moving stations in Favorites tab using ViewModel method")
            viewModel.moveFavoriteStation(from: source, to: destination)
            return // ViewModel handles CoreData saving and player index updates
            
        case .recent:
            // Recent stations can't be reordered manually (they're sorted by play time across all countries)
            return
        }
        
        // Save changes to CoreData
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
        
        // Check if this station is currently playing
        if isStationPlaying(station) && radioPlayer.isPlaying {
            print("⚠️ EditStation: Cannot edit - station is currently playing")
            showEditPlayingAlert = true
            UIDevice.playHapticFeedback()
            return
        }
        
        // Set the station first
        selectedStationForEdit = station
        
        // Add a small delay to ensure the binding propagates before presenting the sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            print("📝 EditStation: selectedStationForEdit is now: \(self.selectedStationForEdit?.name ?? "nil")")
            self.activeSheet = .editStation
            print("✅ EditStation: Sheet presented for station: \(station.name)")
        }
    }
    
    private func handleDeleteStation(_ station: RadioStation) {
        print("🗑️ HandleDeleteStation: Attempting to delete station: \(station.name)")
        
        // Check if this station is currently playing
        if isStationPlaying(station) && radioPlayer.isPlaying {
            print("⚠️ HandleDeleteStation: Cannot delete - station is currently playing")
            showDeletePlayingAlert = true
            UIDevice.playHapticFeedback()
            return
        }
        
        // Station is not playing, show delete confirmation
        stationToDelete = station
        showDeleteAlert = true
    }

}

// MARK: - Stylish Loader (inlined to avoid project file changes)
private struct StylishLoaderView: View {
    let title: String
    let phase: String
    let progress: Double
    let current: Int
    let total: Int

    @State private var animate = false

    var percentageText: String {
        let clamped = max(0.0, min(progress, 1.0))
        return "\(Int(clamped * 100))%"
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.adaptiveSeparator.opacity(0.3), lineWidth: 10)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, min(progress, 1.0))))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Color.blue, Color.purple, Color.blue]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? 360 : 0))
                    .animation(
                        Animation.linear(duration: 1.2)
                            .repeatForever(autoreverses: false),
                        value: animate
                    )
                    .frame(width: 80, height: 80)

                Text(percentageText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.adaptivePrimaryText)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)

                if !phase.isEmpty {
                    Text(phase)
                        .font(.subheadline)
                        .foregroundColor(.adaptiveSecondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: 280)
                        .animation(.easeInOut(duration: 0.2), value: phase)
                }
            }

            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.adaptiveSeparator.opacity(0.25))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, min(CGFloat(progress) * geo.size.width, geo.size.width)))
                    }
                }
                .frame(height: 10)

                if total > 0 {
                    Text("\(current)/\(total) • \(percentageText)")
                        .font(.caption)
                        .foregroundColor(.adaptiveSecondaryText)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground)
        .onAppear { animate = true }
    }
}



struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    @State static var activeSheet: ActiveSheet? = nil
    @State static var isPlayerSheetPresented = false
    @State static var searchText = ""
    @State static var isScrolling = false
    @State static var isFooterMenuHidden = false
    @State static var isSearchPresented = false
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.radio),
                             selectedSubTab: .constant(.all), activeSheet: $activeSheet,
                             isPlayerSheetPresented: $isPlayerSheetPresented,
                             searchText: $searchText,
                             isScrolling: $isScrolling,
                             isFooterMenuHidden: $isFooterMenuHidden,
                             isSearchPresented: $isSearchPresented)
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Custom Radio Search Bar
struct CustomRadioSearchBar: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var placeholder: String = "Search..."
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isTextFieldFocused: Bool
    
    private var searchBarBackgroundColor: Color {
        if #available(iOS 26.0, *) {
            return Color.clear // For liquid glass effect
        } else {
            return colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6)
        }
    }
    
    private var textColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var iconColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    var body: some View {
        // Search field with icons
        HStack(spacing: 8) {
            // Magnifying glass icon
            Image(systemName: "magnifyingglass")
                .foregroundColor(iconColor)
                .font(.system(size: 16, weight: .medium))
            
            // Text field
            TextField(placeholder, text: $searchText)
                .font(.system(size: 16))
                .foregroundColor(textColor)
                .focused($isTextFieldFocused)
                .submitLabel(.search)
            
            // Clear button when text exists
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(iconColor)
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(searchBarBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .onAppear {
            // Auto-focus when search bar appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let userIsScrolling = Notification.Name("userIsScrolling")
    static let userStoppedScrolling = Notification.Name("userStoppedScrolling")
}
