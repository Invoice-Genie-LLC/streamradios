//
//  EditStationView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

//
//  EditStationView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct EditStationView: View {
    @State private var name: String
    @State private var urlString: String
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Binding var isPresented: Bool
    let station: RadioStation

    init(station: RadioStation, isPresented: Binding<Bool>) {
        _name = State(initialValue: station.name)
        _urlString = State(initialValue: station.url)
        self.station = station
        _isPresented = isPresented
    }

    var body: some View {
        NavigationView {
            VStack {
                Spacer()

                Text("Edit Radio Station")
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
                    if let index = viewModel.stations.firstIndex(where: { $0.id == station.id }) {
                        viewModel.stations[index].name = name
                        viewModel.stations[index].url = urlString
                        isPresented = false // Close the sheet
                    }
                }) {
                    Text("Save Changes")
                        .font(.title)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
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
