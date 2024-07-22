// AddStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

struct AddStationView: View {
    @State private var name: String = ""
       @State private var urlString: String = ""
       @State private var selectedCountry: String = "Select Country"
       @State private var showAlert = false
       @State private var alertMessage: String = ""
       @State private var iconImage: UIImage? = nil
       @State private var showImagePicker = false
       @EnvironmentObject var viewModel: RadioStationViewModel
       @EnvironmentObject var permissionManager: PermissionManager
       @Binding var isEditingStation: RadioStation?
       @Binding var activeSheet: ActiveSheet?
       var station: RadioStation?
    var onSave: (() -> Void)?
    
    init(station: RadioStation? = nil, activeSheet: Binding<ActiveSheet?>, selectedCountry: String, isEditingStation: Binding<RadioStation?>? = nil, onSave: (() -> Void)? = nil) {
            self.station = station
            _activeSheet = activeSheet
            _selectedCountry = State(initialValue: selectedCountry)
            self.onSave = onSave // Assign the completion handler

            if let isEditingStation = isEditingStation {
                _isEditingStation = isEditingStation
            } else {
                _isEditingStation = .constant(nil) // Provide a default binding if none is provided
            }

            if let station = station, let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                _iconImage = State(initialValue: image)
            }
        }
    
    var body: some View {
        ZStack {
            NavigationView {
                VStack {
                    // Custom toolbar with title and cancel button
                    HStack {
                        Button(action: {
                            activeSheet = nil
                        }) {
                            Text("Cancel")
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        Text("Add Station")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        // Placeholder to balance the HStack
                        Button(action: {}) {
                            Text("")
                                .foregroundColor(.clear)
                        }
                    }
                    .padding()
                    Divider()
                    
                    Form {
                        Section(header: Text("Station Info")) {
                            HStack {
                                TextField("Enter station name", text: $name)
                                    .onChange(of: name) { newValue in
                                        if newValue.count >= 40 {
                                            name = String(newValue.prefix(40))
                                        }
                                    }
                                if !name.isEmpty {
                                    Button(action: {
                                        name = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                            
                            HStack {
                                TextField("Enter station URL", text: $urlString)
                                if !urlString.isEmpty {
                                    Button(action: {
                                        urlString = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                            
                            Picker("Select Country", selection: $selectedCountry) {
                                ForEach(viewModel.countries, id: \.name) { country in
                                    Text(country.name).tag(country.name)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                        }
                        
                        Section(header: Text("Icon")) {
                            if let iconImage = iconImage {
                                Image(uiImage: iconImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Image(systemName: "photo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            
                            Button(action: {
                                permissionManager.checkPhotoLibraryPermission {
                                    showImagePicker = true
                                }
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Upload Station Icon")
                                        .foregroundColor(.blue)
                                }
                            }
                            .sheet(isPresented: $showImagePicker) {
                                ImagePicker(image: $iconImage)
                            }
                        }
                        
                        Button(action: saveStation) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Station")
                            }
                        }
                        .foregroundColor(.green)
                    }
                    .alert(isPresented: $permissionManager.isPermissionAlertPresented) {
                        Alert(
                            title: Text("Permission Required"),
                            message: Text(permissionManager.alertMessage),
                            primaryButton: .default(Text("Settings"), action: {
                                permissionManager.openAppSettings()
                            }),
                            secondaryButton: .cancel()
                        )
                    }
                }
                .navigationBarHidden(true) // Hide the default navigation bar
            }
            if showAlert {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                    self.showAlert = false
                }
                .transition(.opacity)
            }
        }
    }
    
    private func saveStation() {
        guard !name.isEmpty else {
            alertMessage = "Station name is required."
            showAlert = true
            return
        }
        
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
            alertMessage = "Please enter a valid URL."
            showAlert = true
            return
        }
        
        guard selectedCountry != "Select Country" else {
            alertMessage = "Please select a valid country."
            showAlert = true
            return
        }
        let iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
        viewModel.addStation(name: name, url: urlString, iconData: iconData, country: selectedCountry)
        viewModel.saveStationsToCoreData()
        activeSheet = nil
        onSave?() 
    }
}

struct AddStationView_Previews: PreviewProvider {
    @State static var activeSheet: ActiveSheet? = .addStation
    
    static var previews: some View {
        AddStationView(activeSheet: $activeSheet, selectedCountry: "Unknown")
            .environmentObject(RadioStationViewModel())
    }
}

