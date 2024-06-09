// AddStationView.swift
// AlbRadioStream
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
                Spacer()

                Text(station == nil ? "Add Radio Station" : "Edit Radio Station")
                    .font(.title)
                    .padding()

                TextField("Enter station name", text: $name)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)

                TextField("Enter station URL", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
                
                if let iconImage = iconImage {
                    Image(uiImage: iconImage)
                        .resizable()
                        .frame(width: 50, height: 50)
                        .cornerRadius(10)
                        .padding()
                }

                HStack {
                    Button(action: {
                        showImagePicker = true
                    }) {
                        HStack {
                            Image(systemName: "photo")
                                .font(.headline)
                            Text("Upload Icon")
                                .font(.headline)
                        }
                        .padding(8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .sheet(isPresented: $showImagePicker) {
                        ImagePicker(image: $iconImage)
                    }
                    .padding(.trailing, 8)

                    Button(action: {
                        if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
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
                            isPresented = false // Close the sheet
                        } else {
                            showAlert = true
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.headline)
                            Text(station == nil ? "Add Station" : "Save Changes")
                                .font(.headline)
                        }
                        .padding(8)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                .padding()

                .alert(isPresented: $showAlert) {
                    Alert(title: Text("Invalid URL"), message: Text("Please enter a valid URL"), dismissButton: .default(Text("OK")))
                }
                .padding()

                Spacer()
            }
            .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all))
            .navigationBarItems(trailing: Button(action: {
                isPresented = false
            }) {
                Text("Done").bold()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
