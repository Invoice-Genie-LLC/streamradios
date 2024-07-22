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
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: .stationsUpdated)) { _ in
                    viewModel.loadStationsFromCoreData() // This will refresh the data in the view model
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
            LazyVStack {
                ForEach(filteredStations) { station in
                    stationRow(for: station)
                }
            }
            .padding(.top, 10)
            .padding(.vertical, 10)
        }
    }
    
    @ViewBuilder
    private func stationRow(for station: RadioStation) -> some View {
        HStack {
            imageForStation(station)
                .frame(width: 50, height: 50)
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 5) {
                stationInfo(for: station)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                stationMetadata(for: station)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            
            // Spacer()
            
            if isEditing {
                editControls(for: station)
            } else {
                playbackControls(for: station)
            }
        }
        .padding(.all, 10)
        .background(self.draggingStation?.id == station.id ? Color.gray.opacity(0.2) : Color(UIColor.systemGray5))
        .cornerRadius(10)
        .shadow(radius: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                selectedStationForEdit = station
            }
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
        .padding(.horizontal)
        .padding(.vertical, 4)
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
            UIDevice.playHapticFeedback()
            self.draggingStation = station
            self.originalMetadata = radioPlayer.metadata
            radioPlayer.metadata = nil
            return NSItemProvider(object: String(station.id) as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
        
    }
    
    @ViewBuilder
    private func stationInfo(for station: RadioStation) -> some View {
        HStack {
            if isCurrentStation(station: station) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.primary)
            }
            Text(station.name)
                .font(.headline)
                .foregroundColor(isCurrentStation(station: station) ? .primary : .gray)
                .background(isCurrentStation(station: station) ? Color.clear : Color(UIColor.systemGray5))
        }
    }
    
    @ViewBuilder
    private func stationMetadata(for station: RadioStation) -> some View {
        if isCurrentStation(station: station) {
            if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                Text(metadata)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
        } else {
            Text("Not Playing")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func playbackControls(for station: RadioStation) -> some View {
        Button(action: {
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.updateLastPlayed(for: viewModel.stations[index])
                radioPlayer.playStation(at: index, from: viewModel.stations)
            }
        }) {
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundColor(.primary)
                .accessibilityIdentifier("playButton-\(station.id)")
        }
        Button(action: {
            viewModel.toggleFavorite(for: station)
            viewModel.saveStationsToCoreData()
        }) {
            Image(systemName: station.isFavorite ? "heart.fill" : "heart")
                .font(.title)
                .foregroundColor(station.isFavorite ? .red : .primary)
        }
    }
    
    @ViewBuilder
    private func editControls(for station: RadioStation) -> some View {
        Image(systemName: "line.horizontal.3")
            .font(.title)
            .foregroundColor(.primary)
            .padding(.trailing, 10)
            .onDrag {
                UIDevice.playHapticFeedback()
                self.draggingStation = station
                self.originalMetadata = radioPlayer.metadata
                radioPlayer.metadata = nil
                return NSItemProvider(object: String(station.id) as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
    }
    
    @ViewBuilder
    private func imageForStation(_ station: RadioStation) -> some View {
        if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData),
           let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "radio")
                .resizable()
                .scaledToFit()
        }
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
    
    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
    }
}

struct StationDropDelegate: DropDelegate {
    let station: RadioStation
    @Binding var stations: [RadioStation]
    @Binding var draggingStation: RadioStation?
    @Binding var originalMetadata: String?
    let viewModel: RadioStationViewModel
    let radioPlayer: RadioPlayer
    
    func performDrop(info: DropInfo) -> Bool {
        if let metadata = originalMetadata {
            radioPlayer.metadata = metadata
        }
        draggingStation = nil
        originalMetadata = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggingStation = draggingStation,
              let fromIndex = stations.firstIndex(of: draggingStation),
              let toIndex = stations.firstIndex(of: station),
              fromIndex != toIndex else { return }
        
        withAnimation {
            moveStation(from: fromIndex, to: toIndex)
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    func moveStation(from sourceIndex: Int, to destinationIndex: Int) {
        let itemToMove = viewModel.stations.remove(at: sourceIndex)
        viewModel.stations.insert(itemToMove, at: destinationIndex)
        
        // Save the new station order to CoreData
        viewModel.saveStationsToCoreData()
        
        // Print the new station list. Uncomment for debugging only
        // viewModel.printStationsList()
    }
    
    // Uncomment for debugging only
    /*
     func printStationsList() {
     for station in stations {
     print("\(station.name) - \(station.url)")
     }
     }
     */
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
