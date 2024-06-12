// AddStationView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct AddStationView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var showAlert = false
    @State private var iconImage: UIImage? = nil
    @State private var showImagePicker = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPresented: Bool
    var station: RadioStation?

    init(station: RadioStation? = nil, isPresented: Binding<Bool>) {
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.url ?? "")
        self.station = station
        _isPresented = isPresented

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
                            .foregroundColor(.blue)
                    }
                    Spacer()
                    Text(station == nil ? "Add Station" : "Edit Station")
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
                                .foregroundColor(.blue)
                        }
                        .sheet(isPresented: $showImagePicker) {
                            ImagePicker(image: $iconImage)
                        }
                    }

                    Button(action: saveStation) {
                        HStack {
                            Image(systemName: station == nil ? "plus.circle.fill" : "checkmark.circle.fill")
                            Text(station == nil ? "Add Station" : "Save Changes")
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

        if let station = station {
            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                viewModel.stations[index].name = name
                viewModel.stations[index].url = urlString
                viewModel.stations[index].iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
            }
        } else {
            let iconData = iconImage?.jpegData(compressionQuality: 0.8)?.base64EncodedString()
            let newStation = RadioStation(name: name, url: urlString, iconData: iconData)
            viewModel.stations.append(newStation)
        }
        viewModel.saveStations()
        isPresented = false
    }
}
