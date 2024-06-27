//
//  EditStationView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/25/24.
//

import SwiftUI

struct EditStationView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var showAlert = false
    @State private var iconImage: UIImage? = nil
    @State private var showImagePicker = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPresented: RadioStation?
    var station: RadioStation
    
    init(station: RadioStation, isPresented: Binding<RadioStation?>) {
        _name = State(initialValue: station.name)
        _urlString = State(initialValue: station.url)
        self.station = station
        _isPresented = isPresented
        
        if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
            _iconImage = State(initialValue: image)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Custom toolbar with title and cancel button
                HStack {
                    Button(action: {
                        isPresented = nil
                    }) {
                        Text("Cancel")
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Text("Edit Station")
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
                            showImagePicker = true
                        }) {
                            Text("Upload Icon")
                                .foregroundColor(.primary)
                        }
                        .sheet(isPresented: $showImagePicker) {
                            ImagePicker(image: $iconImage)
                        }
                    }
                    
                    Button(action: saveStation) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save Changes")
                        }
                    }
                    .foregroundColor(.green)
                    .alert(isPresented: $showAlert) {
                        Alert(title: Text("Invalid URL"), message: Text("Please enter a valid URL"), dismissButton: .default(Text("OK")))
                    }
                }
            }
            .navigationBarHidden(true) // Hide the default navigation bar
        }
    }
    
    private func saveStation() {
            guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
                showAlert = true
                return
            }
            
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.stations[index].name = name
                viewModel.stations[index].url = urlString
                viewModel.stations[index].iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
                
                viewModel.saveStationsToFile()  // Save locally
                
                // Update in CloudKit
                DataStore.shared.updateStationInCloudKit(station: viewModel.stations[index], iconImage: iconImage) { success, recordName in
                    if success {
                        print("Station updated in CloudKit with record ID:", recordName ?? "Unknown")
                    } else {
                        print("Failed to update station in CloudKit.")
                    }
                }
            }
            
            isPresented = nil
        }

}

struct EditStationView_Previews: PreviewProvider {
    static var previews: some View {
        let station = RadioStation(name: "Sample Station", url: "http://samplestation.com", iconData: nil)
        EditStationView(station: station, isPresented: .constant(station))
            .environmentObject(RadioStationViewModel())
    }
}
