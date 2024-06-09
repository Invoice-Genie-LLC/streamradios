//
//  RadioStationListView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct RadioStationListView: View {
    @EnvironmentObject var viewModel: RadioStationViewModel
    @State private var selectedStation: RadioStation?
    @State private var isEditing = false

    var body: some View {
        List {
            ForEach(viewModel.stations) { station in
                HStack {
                    Button(action: {
                        selectedStation = station
                        isEditing = true
                    }) {
                        HStack {
                            Text(station.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: {
                        if let url = URL(string: station.url) {
                            RadioPlayer.shared.setStationURL(url)
                            RadioPlayer.shared.playPause()
                        }
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.vertical, 8)
                .listRowBackground(Color(UIColor.secondarySystemBackground))
            }
            .onDelete(perform: deleteStation)
        }
        .listStyle(InsetGroupedListStyle())
        .sheet(item: $selectedStation) { station in
            AddStationView(station: station, isPresented: Binding(
                get: { self.selectedStation != nil },
                set: { newValue in
                    if !newValue { self.selectedStation = nil }
                }
            ))
            .environmentObject(viewModel)
        }
    }
    
    private func deleteStation(at offsets: IndexSet) {
        viewModel.stations.remove(atOffsets: offsets)
    }
}
