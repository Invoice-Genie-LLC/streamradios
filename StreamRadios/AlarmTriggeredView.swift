//
//  AlarmTriggeredView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/29/24.
//

import SwiftUI

struct AlarmTriggeredView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Wake Up!")
                    .font(.largeTitle)
                    .padding()
                
                if let currentStation = radioPlayer.currentlyPlayingStation {
                    Text("Now playing: \(currentStation.name)")
                        .font(.title2)
                    
                    Text("Is Playing: \(radioPlayer.isPlaying ? "Yes" : "No")")
                        .font(.subheadline)
                    
                    if let metadata = radioPlayer.metadata {
                        Text(metadata)
                            .font(.subheadline)
                    } else {
                        Text("No metadata available")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                } else {
                    Text("No station currently playing")
                        .font(.title2)
                }
                
                Button("Stop Alarm") {
                    radioPlayer.stop()
                    presentationMode.wrappedValue.dismiss()
                }
                .padding()
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .navigationBarItems(trailing: closeButton)
            .navigationBarTitle("Alarm", displayMode: .inline)
        }
        .onAppear {
            radioPlayer.playFavoriteStationForAlarm()
        }
        .onReceive(radioPlayer.$metadata) { _ in
            print("Metadata updated: \(radioPlayer.metadata ?? "nil")")
        }
    }
    
    private var closeButton: some View {
        Button(action: {
            radioPlayer.stop()
            presentationMode.wrappedValue.dismiss()
        }) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 30, height: 30)
                
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
            }
        }
    }
    
    private func playFavoriteStation() {
        if let favoriteStationIndex = UserDefaults.standard.value(forKey: "FavoriteStationIndex") as? Int,
           favoriteStationIndex < viewModel.stations.count {
            let favoriteStation = viewModel.stations[favoriteStationIndex]
            print("Playing favorite station: \(favoriteStation.name)")
            radioPlayer.playStationForAlarm(station: favoriteStation)
        } else {
            print("Error: No valid favorite station index found")
        }
    }
}

struct AlarmTriggeredView_Previews: PreviewProvider {
    static var previews: some View {
        AlarmTriggeredView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel.shared)
    }
}
