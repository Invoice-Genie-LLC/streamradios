//
//  AddStationView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct AddStationView: View {
    @State private var name: String
    @State private var urlString: String
    @State private var showAlert = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPresented: Bool
    var station: RadioStation?

    init(station: RadioStation? = nil, isPresented: Binding<Bool>) {
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.url ?? "")
        self.station = station
        _isPresented = isPresented
    }

    var body: some View {
        NavigationView {
            VStack {
                Spacer()

                Text(station == nil ? "Add Radio Station" : "Edit Radio Station")
                    .font(.largeTitle)
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

                Button(action: {
                    if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                        if let station = station {
                            if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                                viewModel.stations[index].name = name
                                viewModel.stations[index].url = urlString
                            }
                        } else {
                            viewModel.addStation(name: name, url: urlString)
                        }
                        isPresented = false // Close the sheet
                    } else {
                        showAlert = true
                    }
                }) {
                    Text(station == nil ? "Add Station" : "Save Changes")
                        .font(.title)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
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
    }
}
