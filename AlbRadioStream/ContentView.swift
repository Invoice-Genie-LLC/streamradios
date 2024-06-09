//
//  ContentView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/8/24.
//

import SwiftUI

@main
struct RadioStreamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel())
        }
    }
}

struct ContentView: View {
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel()
    @State private var isAddStationViewPresented = false
    @State private var isPlayerSheetPresented = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background Color
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)

                VStack {
                    // Radio Stations List
                    VStack {
                        RadioStationListView()
                            .environmentObject(viewModel)
                            .environmentObject(radioPlayer)
                            .background(Color(UIColor.systemBackground).opacity(0.8))
                            .cornerRadius(20)
                            .padding(.horizontal)
                            .frame(maxHeight: 400) // Increase height of the radio stations list
                    }
                    .background(RoundedRectangle(cornerRadius: 20)
                                    .fill(Color(UIColor.secondarySystemBackground))
                                    .shadow(radius: 10))
                    .padding()

                    Spacer()

                    // Now Playing Section
                    VStack {
                        HStack {
                            if let currentStationIndex = radioPlayer.currentStationIndex,
                               currentStationIndex < viewModel.stations.count {
                                Text(viewModel.stations[currentStationIndex].name)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            } else {
                                Text("Not Playing")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Button(action: {
                                radioPlayer.previousStation(from: viewModel.stations)
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(.title)
                                    .foregroundColor(.blue)
                            }

                            Spacer()

                            Button(action: {
                                radioPlayer.playPause()
                            }) {
                                Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.blue)
                            }

                            Spacer()

                            Button(action: {
                                radioPlayer.nextStation(from: viewModel.stations)
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.title)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.top, 8) // Add some space between text and buttons
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 100) // Adjust the height to fit text and buttons
                    .padding(.bottom, UIApplication.shared.windows.first?.safeAreaInsets.bottom)
                }
            }
            .navigationBarItems(trailing:
                Button(action: {
                    isAddStationViewPresented.toggle()
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }
            )
            .sheet(isPresented: $isAddStationViewPresented) {
                AddStationView(isPresented: $isAddStationViewPresented)
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isPlayerSheetPresented) {
                PlayerSheetView()
                    .environmentObject(radioPlayer)
                    .environmentObject(viewModel)
            }
        }
    }
}
