// PlayerSheetView.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct PlayerSheetView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel

    var body: some View {
        VStack {
            if let currentStationIndex = radioPlayer.currentStationIndex,
               currentStationIndex < viewModel.stations.count {
                let currentStation = viewModel.stations[currentStationIndex]
                if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .cornerRadius(4)
                        .padding(.bottom, 8)
                }
            }

            if let albumArt = radioPlayer.albumArt {
                Image(uiImage: albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .cornerRadius(12)
                    .shadow(radius: 8)
            }

            Text(radioPlayer.songTitle.isEmpty ? "Not Playing" : radioPlayer.songTitle)
                .font(.title)
                .bold()
                .padding(.top, 4)

            Text(radioPlayer.artistName)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            HStack {
                Button(action: {
                    radioPlayer.previousStation(from: viewModel.stations)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }

                Spacer()

                Button(action: {
                    radioPlayer.playPause()
                }) {
                    Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                }

                Spacer()

                Button(action: {
                    radioPlayer.nextStation(from: viewModel.stations)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .shadow(radius: 8)
        }
        .padding()
    }
}
