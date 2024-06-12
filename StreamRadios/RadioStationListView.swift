// RadioStationListView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct RadioStationListView: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var radioPlayer: RadioPlayer
    @State private var selectedStation: RadioStation?
    @State private var isEditing = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack {
                    ForEach(viewModel.stations) { station in
                        Button(action: {
                            selectedStation = station
                            isEditing = true
                        }) {
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
                                        .foregroundColor(.blue)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(station.name)
                                        .font(.headline)
                                        .foregroundColor(radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station ? .blue : .primary)

                                    if radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station {
                                        HStack {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .foregroundColor(.blue)
                                            if let metadata = radioPlayer.metadata, !metadata.isEmpty {
                                                Text(metadata)
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    } else {
                                        Text("Not Playing")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.leading, 10)

                                Spacer()

                                Button(action: {
                                    if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                                        radioPlayer.playStation(at: index, from: viewModel.stations)
                                    }
                                }) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.blue)
                                        .accessibilityIdentifier("playButton-\(station.id)")
                                }
                            }
                            .padding()
                            .background(Color(UIColor.tertiarySystemBackground))
                            .cornerRadius(10)
                            .shadow(radius: 4)
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
                            Button(role: .destructive) {
                                withAnimation {
                                    deleteStation(station)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.top, 10) // Add padding at the top
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isEditing) {
            if let selectedStation = selectedStation {
                AddStationView(station: selectedStation, isPresented: $isEditing)
                    .environmentObject(viewModel)
            }
        }
        .onAppear {
            NotificationCenter.default.addObserver(forName: .NetworkReconnectNotification, object: nil, queue: .main) { _ in
                if let index = radioPlayer.currentStationIndex {
                    radioPlayer.playStation(at: index, from: viewModel.stations)
                }
            }
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
