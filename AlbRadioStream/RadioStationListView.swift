// RadioStationListView.swift
// AlbRadioStream
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
        List {
            ForEach(viewModel.stations) { station in
                HStack {
                    Button(action: {
                        selectStation(station)
                    }) {
                        HStack {
                            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(8)
                                    .padding(.trailing, 8)
                            }

                            VStack(alignment: .leading) {
                                HStack {
                                    Text(station.name)
                                        .font(.headline)
                                        .foregroundColor(radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station ? .blue : .primary)

                                    if radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundColor(.blue)
                                            .padding(.leading, 4)
                                    }
                                }

                                if radioPlayer.currentStationIndex != nil && viewModel.stations.indices.contains(radioPlayer.currentStationIndex!) && viewModel.stations[radioPlayer.currentStationIndex!] == station && !radioPlayer.metadata.isEmpty {
                                    Text(radioPlayer.metadata)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    Button(action: {
                        if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                            radioPlayer.playStation(at: index, from: viewModel.stations)
                        }
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                    }

                    Image(systemName: "line.horizontal.3")
                        .font(.title)
                        .foregroundColor(.gray)
                        .padding(.leading, 10)
                        .onDrag {
                            NSItemProvider(object: station.name as NSString)
                        }
                }
                .padding(.vertical, 8)
                .listRowBackground(Color(UIColor.secondarySystemBackground))
            }
            .onDelete(perform: viewModel.deleteStation)
            .onMove(perform: viewModel.moveStation)
        }
        .listStyle(InsetGroupedListStyle())
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5) // Reduce padding to make the list wider
        .sheet(isPresented: $isEditing) {
            if let selectedStation = selectedStation {
                AddStationView(station: selectedStation, isPresented: $isEditing)
                    .environmentObject(viewModel)
            }
        }
    }

    private func selectStation(_ station: RadioStation) {
        selectedStation = station
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isEditing = true
        }
    }
}
