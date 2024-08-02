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
    @AppStorage("isSingleTimeAlert") private var isSingleTimeAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Attention!")
                    .font(.largeTitle)
                    .padding()
                
                if let alarmStation = radioPlayer.alarmStation {
                    stationView(for: alarmStation)
                } else {
                    Text("No alert station set")
                        .font(.title2)
                    
                    Button("Try playing favorite station") {
                        radioPlayer.playFavoriteStationForAlarm()
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                
                Button("Stop") {
                    radioPlayer.stop()
                    radioPlayer.resetAlarmState()
                }
                .padding()
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .navigationBarItems(trailing: closeButton)
            .navigationBarTitle("Radio Program Alert", displayMode: .inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            print("AlarmTriggeredView appeared")
                print("Current alarm station: \(radioPlayer.alarmStation?.name ?? "None")")
                print("Is playing: \(radioPlayer.isPlaying)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    radioPlayer.playFavoriteStationForAlarm()
                }
        }
        .onReceive(radioPlayer.$isPlaying) { isPlaying in
                   print("Is playing updated: \(isPlaying)")
               }
               .onReceive(radioPlayer.$metadata) { metadata in
                   print("Metadata updated: \(metadata ?? "nil")")
               }
    }
    
    private func stationView(for station: RadioStation) -> some View {
        VStack(spacing: 15) {
            if let iconData = station.iconData, let uiImage = UIImage(data: Data(base64Encoded: iconData) ?? Data()) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .cornerRadius(15)
            } else {
                Image(systemName: "radio")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .foregroundColor(.gray)
            }
            
            Text("Now playing: \(station.name)")
                .font(.title2)
            
            Text("Status: \(radioPlayer.isPlaying ? "Playing" : "Paused")")
                .font(.subheadline)
            
            if let metadata = radioPlayer.metadata {
                Text(metadata)
                    .font(.subheadline)
            } else {
                Text("No metadata available")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var closeButton: some View {
        Button(action: {
            radioPlayer.stop()
            radioPlayer.resetAlarmState()
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
}

struct AlarmTriggeredView_Previews: PreviewProvider {
    static var previews: some View {
        AlarmTriggeredView()
            .environmentObject(RadioPlayer.shared)
            .environmentObject(RadioStationViewModel.shared)
    }
}
