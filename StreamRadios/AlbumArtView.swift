// AlbumArtView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI

struct AlbumArtView: View {
    let imageData: String?
    let isPlaying: Bool
    @State private var rotation: Double = 0
    
    var body: some View {
        Group {
            if let imageData = imageData, let data = Data(base64Encoded: imageData), let image = UIImage(data: data) {
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
                    .foregroundColor(.blue)
            }
        }
    }
}
