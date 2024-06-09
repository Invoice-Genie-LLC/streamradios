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
                    HStack {
                        Button(action: {
                            radioPlayer.previousStation()
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
                            radioPlayer.nextStation()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 60)
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
            }
        }
    }
}
