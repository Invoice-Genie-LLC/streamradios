// ContentView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.

import SwiftUI
import Combine
import FlagKit

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct ContentView: View {
    @StateObject private var radioPlayer = RadioPlayer.shared
    @StateObject private var viewModel = RadioStationViewModel()
    @State private var isAddStationViewPresented = false
    @State private var isPlayerSheetPresented = false
    @State private var showSideMenu = false
    @State private var isEditingMode = false
    @State private var isEditingStation = false
    @State private var selectedStationForEdit: RadioStation?
    @State private var selectedTab: Tab = .favorites
    @State private var searchText = ""
    private var cancellables = Set<AnyCancellable>()
    @State private var bitrateMessage = "Loading bitrate information..."

    @Environment(\.horizontalSizeClass) var sizeClass

    // Variables to detect specific devices
    private var isIPhone15: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && UIScreen.main.nativeBounds.height == 2556
    }

    private var isIPhone15ProMax: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && UIScreen.main.nativeBounds.height == 2796
    }

    private var isIPadMini: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && UIScreen.main.nativeBounds.height == 2266
    }

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && UIScreen.main.nativeBounds.height == 2732
    }

    var body: some View {
        NavigationView {
            ZStack {
                SideMenuView(showSideMenu: $showSideMenu)
                // Background color
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)

                // Main content
                VStack {
                    HStack(spacing: 8) {
                        // Main Menu
                        HStack {
                                    Button(action: {
                                        showSideMenu.toggle()
                                    }) {
                                        Image(systemName: "line.horizontal.3")
                                            .font(.title)
                                            .foregroundColor(.primary)
                                            .padding(.leading, 15)
                                            .padding(.trailing, 2)  // Added padding on the right side
                                    }
                                    Spacer()
                                }
                                .padding(.leading, 20)
                        .frame(width: isIPhone15ProMax ? 30 : isIPhone15 ? 30 : isIPadMini ? 30 : isIPad ? 30 : 30)
                        .padding(.bottom, 5)
                        
                        // Country Picker
                        HStack {
                            StyledPickerView(
                                selectedCountry: $viewModel.selectedCountry,
                                countries: viewModel.countries
                            )
                        }
                        .frame(width: isIPhone15ProMax ? 270 : isIPhone15 ? 250 : isIPadMini ? 300 : isIPad ? 400 : 350)
                        .padding(.bottom, 5)
                        
                        // Done and Edit Buttons
                        HStack {
                            Button(action: {
                                isEditingMode.toggle()
                                if isEditingMode {
                                    radioPlayer.stop()
                                    radioPlayer.metadata = nil
                                    radioPlayer.currentStationIndex = nil
                                }
                            }) {
                                Text(isEditingMode ? "Done" : "Edit")
                                    .font(.title3)
                                    .foregroundColor(.primary)
                            }
                        }
                        .frame(width: isIPhone15ProMax ? 50 : isIPhone15 ? 50 : isIPadMini ? 100 : isIPad ? 150 : 50)
                        .padding(.bottom, 5)
                        
                        HStack {
                            Button(action: {
                                isAddStationViewPresented.toggle()
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.primary)
                                    .padding(.trailing, 10)
                                    
                            }
                        }
                        .padding(.bottom, 5)
                        .frame(width: isIPhone15ProMax ? 50 : isIPhone15 ? 50 : isIPadMini ? 50 : isIPad ? 50 : 50)

                    }
                    
                    HStack {
                        Picker("", selection: $selectedTab) {
                            Text("Recent").tag(Tab.recent)
                            Text("Favorites").tag(Tab.favorites)
                            Text("All").tag(Tab.all)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal)
                    }
                    .frame(width: sizeClass == .regular ? 650 : 410)
                    
                    Spacer()
                    
                    VStack {
                        RadioStationListView(isEditing: $isEditingMode,
                                             isEditingStation: $isEditingStation,
                                             selectedStationForEdit: $selectedStationForEdit,
                                             selectedTab: $selectedTab,
                                             searchText: $searchText)
                            .environmentObject(viewModel)
                            .environmentObject(radioPlayer)
                            .frame(width: sizeClass == .regular ? 615 : 385)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                            .modifier(NeumorphicShadow())
                            .padding(.top, 10)
                    }
                    
                    .padding(.bottom, 35)
                    .padding(.bottom, sizeClass == .regular ? 5 : 0)
                    
                    Spacer()
                    
                    VStack {
                        if let currentStation = viewModel.currentlyPlayingStation {
                            VStack {
                                HStack(alignment: .center, spacing: 20) {
                                    if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .frame(width: 70, height: 70)
                                            .cornerRadius(10)
                                    } else {
                                        Image(systemName: "radio")
                                            .resizable()
                                            .frame(width: 70, height: 70)
                                            .cornerRadius(10)
                                            .foregroundColor(.gray)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(currentStation.name)
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.primary)
                                        if let metadata = radioPlayer.metadata {
                                            Text(metadata)
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                        } else {
                                            Text("No song or album title available")
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.leading, 10)
                            }
                        }
                        PlayerView()
                            .environmentObject(radioPlayer)
                            .environmentObject(viewModel)
                            .padding(.top, 8)
                    }
                    .frame(width: sizeClass == .regular ? 565 : 355)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .modifier(NeumorphicShadow())
                    .frame(maxWidth: sizeClass == .regular ? 600 : 385)
                    .padding(.horizontal, 5)
                    .onTapGesture {
                        isPlayerSheetPresented.toggle()
                    }
                    .frame(height: 140)
                    .padding(.bottom, UIApplication.shared.connectedScenes
                        .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom }
                        .first ?? 0)
                }
                .padding(.bottom, sizeClass == .regular ? 40 : 0)

                // Side Menu
                GeometryReader { geometry in
                    HStack {
                        SideMenuView(showSideMenu: $showSideMenu)
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
            }
            .sheet(isPresented: $isAddStationViewPresented) {
                AddStationView(isPresented: $isAddStationViewPresented)
                    .environmentObject(viewModel)
            }
            .sheet(item: $selectedStationForEdit) { station in
                EditStationView(station: station, isPresented: $selectedStationForEdit)
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isPlayerSheetPresented) {
                PlayerSheetView()
                    .environmentObject(radioPlayer)
                    .environmentObject(viewModel)
            }
            .onReceive(radioPlayer.bitrateSubject) { newBitrateMessage in
                self.bitrateMessage = newBitrateMessage
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                       if viewModel.isCloudKitOperationRunning {
                           NotificationManager.shared.notifyUser(title: "Operation in Progress", message: "Please keep the app open until the operation completes.")
                       }
                   }
        }
        .sheet(isPresented: $viewModel.showingPurchaseView) {
            PurchaseView(isPresented: $viewModel.showingPurchaseView)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            UIApplication.shared.addTapGestureRecognizer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .countrySelected)) { _ in
                    selectedTab = .all
                }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
    }
}
