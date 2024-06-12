// PlayerSheetView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import AVKit

struct PlayerSheetView: View {
    @EnvironmentObject var radioPlayer: RadioPlayer
    @EnvironmentObject var viewModel: RadioStationViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(.blue)
                    }
                    Spacer()
                }
                .padding()

                Divider()
                
                Group {
                    if UIDevice.current.orientation.isLandscape {
                        ScrollView {
                            content
                        }
                    } else {
                        content
                    }
                }
                .navigationBarTitle("", displayMode: .inline)
                .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack {
            Spacer()
            if let currentStationIndex = radioPlayer.currentStationIndex,
               currentStationIndex < viewModel.stations.count {
                let currentStation = viewModel.stations[currentStationIndex]
                if let iconData = currentStation.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .cornerRadius(4)
                        .padding(.bottom, 8)
                } else {
                    Image(systemName: "radio")
                        .resizable()
                        .frame(width: 100, height: 100) // Reduced size for the system icon
                        .aspectRatio(contentMode: .fit)
                        .padding(20) // Adjust padding to fit better within the circle
                        .clipShape(Circle())
                        .foregroundColor(.blue) // Set the color to blue
                        .padding(.bottom, 8)
                }

                Text(currentStation.name)
                    .font(.title)
                    .bold()
                    .padding(.top, 4)

                if let metadata = radioPlayer.metadata {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                } else {
                    Text("No song or album title available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
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

            Text(radioPlayer.songTitle.isEmpty ? "" : radioPlayer.songTitle)
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

                ZStack {
                    if radioPlayer.isBuffering {
                        CircularProgressView()
                    }
                    Button(action: {
                        radioPlayer.playPause()
                    }) {
                        Image(systemName: radioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                    }
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
            
            Spacer()
    
            // AirPlay Button
            AirPlayButton()
                .frame(width: 50, height: 50)
                .padding(.top, 16) // Add some space between the player controls and the AirPlay button
        }
        .padding()
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        return AVRoutePickerView(frame: .zero)
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
