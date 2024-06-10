// ContentView.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI

@main
struct RadioStreamApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(RadioPlayer.shared)
                .environmentObject(RadioStationViewModel())
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}

struct ContentView: View {
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel()
    @State private var isAddStationViewPresented = false
    @State private var isPlayerSheetPresented = false
    @State private var showSideMenu = false

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
                        RadioStationListView()
                            .environmentObject(viewModel)
                            .environmentObject(radioPlayer)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 5)
                    }
                    .padding(.top, 50)
                    .padding(.bottom, 25)
                    .padding(.horizontal, 5)

                    Spacer()

                    // Now Playing Section
                    Spacer()
                    VStack {
                        HStack {
                            if let currentStationIndex = radioPlayer.currentStationIndex,
                               currentStationIndex < viewModel.stations.count {
                                VStack(alignment: .leading) {
                                    Text(viewModel.stations[currentStationIndex].name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(radioPlayer.metadata)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
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
                    .cornerRadius(12) // Add rounded corners
                    .shadow(radius: 8) // Add shadow
                    .frame(maxWidth: 350)
                    .padding(.horizontal, 5)
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 100) // Adjust the height to fit text and buttons
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
                            .animation(.easeInOut(duration: 0.3), value: showSideMenu)

                        Spacer()
                    }
                }
                .background(Color.black.opacity(showSideMenu ? 0.5 : 0).edgesIgnoringSafeArea(.all))
                .onTapGesture {
                    if showSideMenu {
                        withAnimation {
                            showSideMenu.toggle()
                        }
                    }
                }

                // Menu and Plus button
                VStack {
                    HStack {
                        Button(action: {
                            withAnimation {
                                showSideMenu.toggle()
                            }
                        }) {
                            Image(systemName: "line.horizontal.3")
                                .font(.title)
                                .foregroundColor(.blue)
                                .padding()
                        }

                        Spacer()

                        Button(action: {
                            isAddStationViewPresented.toggle()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
