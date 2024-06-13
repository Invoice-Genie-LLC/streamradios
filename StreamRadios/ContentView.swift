// ContentView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel()
    @State private var isAddStationViewPresented = false
    @State private var isPlayerSheetPresented = false
    @State private var showSideMenu = false
    @State private var isEditingMode = false
    @State private var isEditingStation = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background Color
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)
                
                // Main content
                VStack {
                    Spacer()
                    // Radio Stations List
                    VStack {
                        RadioStationListView(isEditing: $isEditingMode, isEditingStation: $isEditingStation)
                            .environmentObject(viewModel)
                            .environmentObject(radioPlayer)
                            .frame(width: 385) // Fixed width and height
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16) // Make the corners rounded
                            .shadow(radius: 8) // Add shadow for better appearance
                            .padding(.top, 50)
                    }
                    .padding(.top, 10) // Reduced padding at the top
                    .padding(.bottom, 35)
                    
                    Spacer()
                    
                    // Play Area Section
                    VStack {
                        if radioPlayer.isPlaying, let currentStationIndex = radioPlayer.currentStationIndex,
                           currentStationIndex < viewModel.stations.count {
                            let currentStation = viewModel.stations[currentStationIndex]
                            HStack(alignment: .center, spacing: 20) {
                                AlbumArtView(imageData: currentStation.iconData, isPlaying: radioPlayer.isPlaying)
                                    .frame(width: 70, height: 70)
                                    .cornerRadius(10)
                                
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(viewModel.stations[currentStationIndex].name)
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    if let metadata = radioPlayer.metadata {
                                        Text(metadata)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("No song or album title available")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.leading, 10) // Add padding to push everything to the far left
                        }
                        
                        HStack(spacing: 30) {
                            Button(action: {
                                radioPlayer.previousStation(from: viewModel.stations)
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.blue)
                            }
                            
                            ZStack {
                                if radioPlayer.isBuffering {
                                    CircularProgressView()
                                }
                                Button(action: {
                                    radioPlayer.playPause()
                                }) {
                                    Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 50))
                                        .foregroundColor(.blue)
                                }
                            }
                            
                            Button(action: {
                                radioPlayer.nextStation(from: viewModel.stations)
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.top, 8) // Add some space between text and buttons
                    }
                    .frame(width: 355)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12) // Add rounded corners
                    .shadow(radius: 8) // Add shadow
                    .frame(maxWidth: 385)
                    .padding(.horizontal, 5)
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 140) // Adjust the height to fit text and buttons
                    .padding(.bottom, UIApplication.shared.connectedScenes
                        .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom }
                        .first ?? 0)
                }
                
                // Side Menu
                GeometryReader { geometry in
                    HStack {
                        SideMenuView()
                            .frame(width: geometry.size.width / 2)
                            .offset(x: showSideMenu ? 0 : -geometry.size.width / 2)
                        
                        Spacer()
                    }
                }
                .background(Color.black.opacity(showSideMenu ? 0.5 : 0).edgesIgnoringSafeArea(.all))
                .onTapGesture {
                    if showSideMenu {
                        showSideMenu.toggle()
                    }
                }
                
                // Menu and Plus button with Logo Text
                VStack {
                    HStack {
                        Button(action: {
                            showSideMenu.toggle()
                        }) {
                            Image(systemName: "line.horizontal.3")
                                .font(.title)
                                .foregroundColor(.blue)
                                .padding()
                        }
                        Spacer()
                        Spacer()
                        Button(action: {
                            isEditingMode.toggle()
                            if isEditingMode {
                                radioPlayer.stop()
                                radioPlayer.metadata = nil // Reset metadata
                                radioPlayer.currentStationIndex = nil // Reset auto-play last station
                            }
                        }) {
                            Text(isEditingMode ? "Done" : "Edit")
                                .font(.title3)
                                .foregroundColor(.blue)
                                .padding()
                        }
                        Button(action: {
                            isAddStationViewPresented.toggle()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(showSideMenu ? Color(.sRGB, red: 0, green: 0, blue: 0.5, opacity: 1) : .blue)
                                .padding()
                        }
                    }
                    Spacer()
                }
            }
            .sheet(isPresented: $isAddStationViewPresented) {
                AddStationView(isPresented: $isAddStationViewPresented)
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isPlayerSheetPresented) {
                PlayerSheetView()
                    .environmentObject(radioPlayer)
                    .environmentObject(viewModel)
            }
            .onAppear {
                UIApplication.shared.lockOrientation(.portrait)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
