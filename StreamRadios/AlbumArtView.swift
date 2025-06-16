// AlbumArtView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI

struct AlbumArtView: View {
    let imageData: String?
    let isPlaying: Bool
    let iTunesImage: UIImage?
    let streamImage: UIImage?
    @State private var rotation: Double = 0
    
    var body: some View {
        Group {
            // Priority: iTunes album art > stream album art > station icon > default radio icon
            if let iTunesImage = iTunesImage {
                Image(uiImage: iTunesImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(isPlaying ? rotation : 0))
                    .onAppear {
                        if isPlaying {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                    }
                    .onChange(of: isPlaying) { _, newValue in
                        if newValue {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        } else {
                            rotation = 0
                        }
                    }
            } else if let streamImage = streamImage {
                Image(uiImage: streamImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(isPlaying ? rotation : 0))
                    .onAppear {
                        if isPlaying {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                    }
                    .onChange(of: isPlaying) { _, newValue in
                        if newValue {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        } else {
                            rotation = 0
                        }
                    }
            } else if let imageData = imageData, let data = Data(base64Encoded: imageData), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(isPlaying ? rotation : 0))
                    .onAppear {
                        if isPlaying {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                    }
                    .onChange(of: isPlaying) { _, newValue in
                        if newValue {
                            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        } else {
                            rotation = 0
                        }
                    }
                
            } else {
                Image(systemName: "radio")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
                    .clipShape(Circle())
                    .foregroundColor(.gray)
            }
        }
    }
}

struct AlbumArtView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AlbumArtView(imageData: nil, isPlaying: false, iTunesImage: nil, streamImage: nil)
                .frame(width: 100, height: 100)
                .previewDisplayName("Default Image")
            
            AlbumArtView(imageData: "base64EncodedImageData", isPlaying: true, iTunesImage: nil, streamImage: nil)
                .frame(width: 100, height: 100)
                .previewDisplayName("Playing Image")
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
