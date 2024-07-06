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
    @Binding var searchText: String
    
    @State private var draggingStation: RadioStation?
    @State private var originalMetadata: String?
    
    var body: some View {
        GeometryReader { geometry in
            if viewModel.stations.isEmpty {
                VStack {
                    Text("No stations configured")
                        .font(.title)
                        .foregroundColor(.gray)
                        .padding(.bottom, 15)
                    Button(action: {
                        isEditingStation = true  // This will trigger the sheet to open the AddStationView
                    }) {
                        Image(systemName: "plus.circle")
                            .font(.largeTitle)
                            .foregroundColor(.primary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.scale)
            }
            else {
                ScrollView {
                    LazyVStack {
                        ForEach(filteredStations) { station in
                            HStack {
                                imageForStation(station)
                                            .frame(width: 50, height: 50)
                                            .cornerRadius(8)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        if isCurrentStation(station: station) {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .foregroundColor(.primary)
                                        }
                                        
                                        Text(station.name)
                                            .font(.headline)
                                            .foregroundColor(isCurrentStation(station: station) ? .primary : .gray) // Conditional color change
                                            .background(isCurrentStation(station: station) ? Color.clear : Color(UIColor.systemGray5)) // Conditional background change
                                    }
                                    
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
                                .padding(.leading, 10)
                                
                                Spacer()
                                
                                if !isEditing {
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
                                    }) {
                                        Image(systemName: station.isFavorite ? "heart.fill" : "heart")
                                            .font(.title)
                                            .foregroundColor(station.isFavorite ? .red : .primary)
                                    }
                                    
                                } else {
                                    Image(systemName: "line.horizontal.3")
                                        .font(.title)
                                        .foregroundColor(.primary)
                                        .padding(.trailing, 10)
                                        .onDrag {
                                            UIDevice.playHapticFeedback()
                                            self.draggingStation = station
                                            self.originalMetadata = radioPlayer.metadata
                                            radioPlayer.metadata = nil
                                            return NSItemProvider(object: String(station.id.uuidString) as NSString)
                                        }
                                        .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
                                }
                            }
                            .padding()
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
                                if !isEditing {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            deleteStation(station)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .contextMenu {
                                if !isEditing {
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
                                return NSItemProvider(object: String(station.id.uuidString) as NSString)
                            }
                            .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
                        }
                    }
                    .padding(.top, 10)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isEditingStation, onDismiss: {
            selectedStationForEdit = nil
            if !viewModel.stations.isEmpty {
                selectedTab = .all // Navigate user to the 'All' tab once a station is added
            }
        }) {
            if let selectedStation = selectedStationForEdit {
                AddStationView(station: selectedStation, isPresented: $isEditingStation)
                    .environmentObject(viewModel)
            } else {
                AddStationView(isPresented: $isEditingStation)
                    .environmentObject(viewModel)
            }
        }
        .onAppear {
            NotificationCenter.default.addObserver(forName: .NetworkReconnectNotification, object: nil, queue: .main) { _ in
                if let index = radioPlayer.currentStationIndex {
                    radioPlayer.playStation(at: index, from: viewModel.stations)
                }
            }
            checkAndAddDefaultStations()  // Ensuring this method is called to check and add stations if necessary.
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
        }
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
    
    private func checkAndAddDefaultStations() {
        // Albania
        if viewModel.stations.isEmpty || !viewModel.stations.contains(where: { $0.country == "Albania" }) {
            print("Adding default stations for Albania...")
            DefaultStations.addDefaultStationsForAlbania(to: viewModel)
        }
        // Angola
        if viewModel.stations.isEmpty || !viewModel.stations.contains(where: { $0.country == "Angola" }) {
            print("Adding default stations for Angola...")
            DefaultStations.addDefaultStationsForAngola(to: viewModel)
        }
        // Australia
        if viewModel.stations.isEmpty || !viewModel.stations.contains(where: { $0.country == "Australia" }) {
            print("Adding default stations for Angola...")
            DefaultStations.addDefaultStationsForAustralia(to: viewModel)
        }
        // Argentina
        if viewModel.stations.isEmpty || !viewModel.stations.contains(where: { $0.country == "Argentina" }) {
            print("Adding default stations for Argentina...")
            DefaultStations.addDefaultStationsForArgentina(to: viewModel)
        }
    }

    
    private var filteredStations: [RadioStation] {
        switch selectedTab {
        case .recent:
            // Filter for recent stations that were played and match the selected country.
            return viewModel.recentStations().filter { $0.country == viewModel.selectedCountry }
        case .favorites:
            // Filter for stations that are favorited and match the selected country.
            return viewModel.favoriteStations().filter { $0.country == viewModel.selectedCountry }
        case .all:
            // Display all stations that match the selected country.
            return viewModel.stations.filter { $0.country == viewModel.selectedCountry }
        }
    }
    
    private func isCurrentStation(station: RadioStation) -> Bool {
        return radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station
    }
    
    private func deleteStation(_ station: RadioStation) {
        if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
            // First try to delete from CloudKit
            DataStore.shared.deleteStationFromCloudKit(station: station) { success in
                DispatchQueue.main.async {
                    if success {
                        print("Station successfully deleted from CloudKit.")
                        
                        // Proceed with local deletion
                        self.viewModel.stations.remove(at: index)
                        self.viewModel.saveStationsToFile() // Save the updated list to local storage
                        
                        // Adjust the RadioPlayer's current station index if needed
                        if RadioPlayer.shared.currentStationIndex == index {
                            RadioPlayer.shared.stop()
                            RadioPlayer.shared.currentStationIndex = nil
                        } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex > index {
                            RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
                        }
                        
                        print("Local station data updated after successful CloudKit deletion.")
                    } else {
                        print("Failed to delete station from CloudKit.")
                    }
                }
            }
        }
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
        viewModel.saveStationsToFile() // Save the updated order to UserDefaults
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
        viewModel.saveStationsToFile() // Save the updated order to UserDefaults after every move
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    private func moveStation(from sourceIndex: Int, to destinationIndex: Int) {
        let itemToMove = stations.remove(at: sourceIndex)
        stations.insert(itemToMove, at: destinationIndex)
    }
}

struct RadioStationListView_Previews: PreviewProvider {
    @StateObject static var viewModel = RadioStationViewModel()
    @StateObject static var radioPlayer = RadioPlayer()
    
    static var previews: some View {
        RadioStationListView(isEditing: .constant(false), isEditingStation: .constant(false),
                             selectedStationForEdit: .constant(nil), selectedTab: .constant(.recent), searchText: .constant(""))
        .environmentObject(viewModel)
        .environmentObject(radioPlayer)
    }
}

