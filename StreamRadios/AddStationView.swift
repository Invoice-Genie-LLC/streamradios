// AddStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

struct AddStationView: View {
    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var selectedCountry: String = "Unknown Region"
    @State private var showAlert = false
    @State private var iconImage: UIImage? = nil
    @State private var showImagePicker = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @EnvironmentObject var permissionManager: PermissionManager
    @Binding var isPresented: Bool
    @Binding var isEditingStation: RadioStation?
    @State private var showingPurchaseView = false
    var station: RadioStation?
    
    init(station: RadioStation? = nil, isPresented: Binding<Bool>? = nil, isEditingStation: Binding<RadioStation?>? = nil) {
        self.station = station
        _isPresented = isPresented ?? .constant(false)
        _isEditingStation = isEditingStation ?? .constant(nil)
        
        if let station = station, let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            _iconImage = State(initialValue: image)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Custom toolbar with title and cancel button
                HStack {
                    Button(action: {
                        isPresented = false
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
                    .alert(isPresented: $showAlert) {
                        Alert(title: Text("Invalid URL"), message: Text("Please enter a valid URL"), dismissButton: .default(Text("OK")))
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
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingPurchaseView) {
                // Assuming PurchaseView is a SwiftUI view handling purchases
                PurchaseView(isPresented: $showingPurchaseView)
            }// Hide the default navigation bar
        }
    }
    
    func loadImageData(named name: String) -> String? {
        let assetName = name.replacingOccurrences(of: " ", with: "_")  // Adjust this if your asset names are formatted differently
        guard let image = UIImage(named: assetName),
              let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to load/compress image for station: \(name)")
            return nil
        }
        return imageData.base64EncodedString()
    }
    
    private func saveStation() {
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
            showAlert = true
            return
        }
        
        let iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
        viewModel.addStation(name: name, url: urlString, iconData: iconData, country: selectedCountry)
        viewModel.saveStationsToCoreData() 
        viewModel.saveStationsToLocal()
        isPresented = false
    }

}

struct AddStationView_Previews: PreviewProvider {
    static var previews: some View {
        AddStationView(isPresented: .constant(true), isEditingStation: .constant(nil))
            .environmentObject(RadioStationViewModel())
    }
}
