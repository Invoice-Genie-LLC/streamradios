// ContentView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI
import Combine

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
    @State private var isEditing: Bool = false
    @State private var showSideMenu = false
    @State private var isEditingMode = false
    @State private var isEditingStation = false
    @State private var selectedStationForEdit: RadioStation?
    @State private var selectedTab: Tab = .favorites
    @State private var searchText = ""
    private var cancellables = Set<AnyCancellable>()
    @State private var bitrateMessage = "Loading bitrate information..."

    @Environment(\.horizontalSizeClass) var sizeClass
    
    var body: some View {
        NavigationView {
            ZStack {
                SideMenuView(showSideMenu: $showSideMenu)
                // Background color
                Color(UIColor.systemBackground)
                    .edgesIgnoringSafeArea(.all)
                
                // Main content
                VStack {
                    HStack {
                        Button(action: {
                            showSideMenu.toggle()
                        }) {
                            Image(systemName: "line.horizontal.3")
                                .font(.title)
                                .foregroundColor(.primary)
                                .padding([.leading, .top, .bottom])
                        }
                        
                        VStack {
                            Picker("Select Country", selection: $viewModel.selectedCountry) {
                                                ForEach(viewModel.countries, id: \.self) { country in
                                                    Text(country).tag(country)
                                                }
                                            }
                            .pickerStyle(MenuPickerStyle())
                            RadioStationListView(
                                                isEditing: $isEditing,
                                                isEditingStation: $isEditingStation,
                                                selectedStationForEdit: $selectedStationForEdit,
                                                selectedTab: $selectedTab,
                                                searchText: $searchText
                                            )
                                            .environmentObject(viewModel)
                        }.padding(.horizontal, 8)
                        Spacer()
                        
                        Button(action: {
                            isEditingMode.toggle()
                            if isEditingMode {
                                radioPlayer.stop()
                                radioPlayer.metadata = nil
                                radioPlayer.currentStationIndex = nil
                            }
                        }) {
                            HStack {
                                Text(isEditingMode ? "Done" : "Edit")
                                    .font(.title3)
                                    .foregroundColor(.primary)
                                    .padding([.top, .bottom, .trailing])
                            }
                        }
                        
                        Button(action: {
                            isAddStationViewPresented.toggle()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(.primary)
                                .padding([.top, .bottom, .trailing])
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 20 : 10)
                    
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
                        .frame(width: sizeClass == .regular ? 600 : 400)
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
        }
        .sheet(isPresented: $viewModel.showingPurchaseView) {
            PurchaseView(isPresented: $viewModel.showingPurchaseView)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            UIApplication.shared.addTapGestureRecognizer()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
    }
}
