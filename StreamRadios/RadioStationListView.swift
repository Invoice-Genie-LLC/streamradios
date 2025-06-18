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

// Sub-tab enum for radio filtering
enum RadioSubTab: Int, CaseIterable {
    case recent = 0
    case favorites = 1
    case all = 2
    
    var title: String {
        switch self {
        case .recent: return "Recent"
        case .favorites: return "Favorites"
        case .all: return "All"
        }
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
    
    @State private var selectedSubTab: RadioSubTab = .all
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
            loadSelectedSubTab()
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
            }
        )
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
            // Sub-tab picker for Recent/Favorites/All
            if selectedTab == .radio {
                Picker("", selection: $selectedSubTab) {
                    ForEach(RadioSubTab.allCases, id: \.self) { subTab in
                        Text(subTab.title).tag(subTab)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 5)
                .onChange(of: selectedSubTab) { oldValue, newValue in
                    saveSelectedSubTab(newValue)
                }
            }
            
            // Stations list
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 1) {
                        ForEach(filteredStations) { station in
                            modernStationRow(for: station)
                                .id(station.id)
                        }
                    }
                    .padding(.top, 10)
                    .onReceive(radioPlayer.$currentStationIndex) { currentIndex in
                        scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                    }
                    .onReceive(radioPlayer.$isPlaying) { isPlaying in
                        if isPlaying, let currentIndex = radioPlayer.currentStationIndex {
                            scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                        }
                    }
                    .onChange(of: selectedTab) { oldTab, newTab in
                        if let currentIndex = radioPlayer.currentStationIndex {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                            }
                        }
                    }
                    .onChange(of: selectedSubTab) { oldSubTab, newSubTab in
                        if let currentIndex = radioPlayer.currentStationIndex {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                            }
                        }
                    }
                    .onAppear {
                        scrollProxy = proxy
                        if let currentIndex = radioPlayer.currentStationIndex {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                scrollToCurrentStation(proxy: proxy, currentIndex: currentIndex)
                            }
                        }
                    }
                }
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
            
            // Main modern station card
            modernStationCard(for: station)
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
                
                // Edit controls if in editing mode
                if isEditing && selectedTab == .radio {
                    editControls(for: station)
                }
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
        Button(action: {
            handleFavoriteButtonTap(for: station)
        }) {
            Image(systemName: station.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(station.isFavorite ? .pink : .gray)
                .scaleEffect(station.isFavorite ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: station.isFavorite)
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
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
        if isEditing {
            selectedStationForEdit = station
        } else {
            if isStationPlaying(station) && radioPlayer.isPlaying {
                activeSheet = .playerSheet
            } else {
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
    
    private func handleDragStart(for station: RadioStation) -> NSItemProvider {
        guard selectedTab == .radio else {
            return NSItemProvider()
        }
        UIDevice.playHapticFeedback()
        self.draggingStation = station
        self.originalMetadata = radioPlayer.metadata
        radioPlayer.metadata = nil
        return NSItemProvider(object: String(station.id) as NSString)
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
    
    private func scrollToCurrentStation(proxy: ScrollViewProxy, currentIndex: Int?) {
        guard let currentIndex = currentIndex,
              currentIndex < viewModel.stations.count else { return }
        
        let currentStation = viewModel.stations[currentIndex]
        
        if filteredStations.contains(where: { $0.id == currentStation.id }) {
            withAnimation(.easeInOut(duration: 0.6)) {
                proxy.scrollTo(currentStation.id, anchor: .center)
            }
        }
    }
    
    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
    }
    
    private func loadSelectedSubTab() {
        if let savedSubTab = UserDefaults.standard.object(forKey: "selectedSubTab") as? Int,
           let subTab = RadioSubTab(rawValue: savedSubTab) {
            selectedSubTab = subTab
        }
    }
    
    private func saveSelectedSubTab(_ subTab: RadioSubTab) {
        UserDefaults.standard.set(subTab.rawValue, forKey: "selectedSubTab")
    }
    
    @ViewBuilder
    private func editControls(for station: RadioStation) -> some View {
        Button(action: {}) {
            Image(systemName: "line.horizontal.3")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gray)
        }
        .buttonStyle(PlainButtonStyle())
        .onDrag {
            guard selectedTab == .radio else {
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
        guard selectedTab == .radio else { return }
        
        guard let draggingStation = draggingStation else { return }
        
        guard let fromIndex = stations.firstIndex(of: draggingStation),
              let toIndex = stations.firstIndex(of: station),
              fromIndex != toIndex else { return }
        
        withAnimation {
            moveAllStation(from: fromIndex, to: toIndex)
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard selectedTab == .radio else { 
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }
    
    func moveFavoriteStation(from sourceIndex: Int, to destinationIndex: Int) {
        let favoriteStations = filteredStations
        
        var newOrderedFavorites = favoriteStations
        let movingStation = newOrderedFavorites.remove(at: sourceIndex)
        newOrderedFavorites.insert(movingStation, at: destinationIndex)
        
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
        
        viewModel.saveStationsToCoreData()
    }
}

struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    @State static var activeSheet: ActiveSheet? = nil
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false), isEditingStation: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.radio),
                             activeSheet: $activeSheet)
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
        .preferredColorScheme(.dark)
    }
}
