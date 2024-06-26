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
    @State private var selectedStation: RadioStation?
    @State private var draggingStation: RadioStation?
    @State private var originalMetadata: String?
    @Binding var selectedStationForEdit: RadioStation?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack {
                    ForEach(viewModel.stations) { station in
                        HStack {
                            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(8)
                            } else {
                                Image(systemName: "radio")
                                    .resizable()
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(8)
                                    .foregroundColor(.gray)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundColor(.primary)
                                    }

                                    Text(station.name)
                                        .font(.headline)
                                        .foregroundColor(radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station ? .primary : .primary)
                                }

                                if radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station {
                                    if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                                        Text(metadata)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
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
                                        radioPlayer.playStation(at: index, from: viewModel.stations)
                                    }
                                }) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.primary)
                                        .accessibilityIdentifier("playButton-\(station.id)")
                                }
                            } else {
                                Image(systemName: "line.horizontal.3")
                                    .font(.title)
                                    .foregroundColor(.primary)
                                    .padding(.trailing, 10)
                                    .onDrag {
                                        UIDevice.playHapticFeedback() // Provide haptic feedback
                                        self.draggingStation = station
                                        self.originalMetadata = radioPlayer.metadata
                                        radioPlayer.metadata = nil // Reset metadata
                                        return NSItemProvider(object: String(station.id.uuidString) as NSString)
                                    }
                                    .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
                            }
                        }
                        .padding()
                        .background(self.draggingStation?.id == station.id ? Color.gray.opacity(0.2) : Color(UIColor.systemGray5))
                        .cornerRadius(10)
                        .shadow(radius: 4)
                        .contentShape(Rectangle()) // Make entire row tappable
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
                            UIDevice.playHapticFeedback() // Provide haptic feedback
                            self.draggingStation = station
                            self.originalMetadata = radioPlayer.metadata
                            radioPlayer.metadata = nil // Reset metadata
                            return NSItemProvider(object: String(station.id.uuidString) as NSString)
                        }
                        .onDrop(of: [UTType.plainText], delegate: StationDropDelegate(station: station, stations: $viewModel.stations, draggingStation: $draggingStation, originalMetadata: $originalMetadata, viewModel: viewModel, radioPlayer: radioPlayer))
                    }
                }
                .padding(.top, 10) // Add padding at the top
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isEditingStation, onDismiss: {
                   selectedStation = nil // Clear selectedStation when the sheet is dismissed
               }) {
                   if let selectedStation = selectedStation {
                       AddStationView(station: selectedStation, isPresented: $isEditingStation)
                           .environmentObject(viewModel)
                   }
               }
        .onAppear {
            NotificationCenter.default.addObserver(forName: .NetworkReconnectNotification, object: nil, queue: .main) { _ in
                if let index = radioPlayer.currentStationIndex {
                    radioPlayer.playStation(at: index, from: viewModel.stations)
                }
            }
            print("RadioStationListView appeared, isEditing: \(isEditing)")
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: .NetworkReconnectNotification, object: nil)
        }
    }

    private func deleteStation(_ station: RadioStation) {
        if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
            viewModel.stations.remove(at: index)
            viewModel.saveStations() // Save the updated list to UserDefaults
            if RadioPlayer.shared.currentStationIndex == index {
                RadioPlayer.shared.stop()
                RadioPlayer.shared.currentStationIndex = nil
            } else if let currentStationIndex = RadioPlayer.shared.currentStationIndex, currentStationIndex > index {
                RadioPlayer.shared.currentStationIndex = currentStationIndex - 1
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
        viewModel.saveStations() // Save the updated order to UserDefaults
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
        viewModel.saveStations() // Save the updated order to UserDefaults after every move
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
        RadioStationListView(isEditing: .constant(false), isEditingStation: .constant(false), selectedStationForEdit: .constant(nil))
            .environmentObject(viewModel)
            .environmentObject(radioPlayer)
    }
}
