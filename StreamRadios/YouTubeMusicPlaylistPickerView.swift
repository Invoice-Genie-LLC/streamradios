//
//  YouTubeMusicPlaylistPickerView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import SwiftUI

struct YouTubeMusicPlaylistPickerView: View {
    @Binding var isPresented: Bool
    @StateObject private var youtubeMusicManager = YouTubeMusicManager.shared
    @State private var playlists: [(id: String, name: String)] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    let onSelect: (String) -> Void  // Modified to pass the selected playlist ID
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading playlists...")
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                } else if playlists.isEmpty {
                    Text("No playlists available")
                        .foregroundColor(.gray)
                } else {
                    List(playlists, id: \.id) { playlist in
                        Button(action: {
                            onSelect(playlist.id)
                            isPresented = false
                        }) {
                            Text(playlist.name)
                        }
                    }
                }
            }
            .navigationTitle("Select YouTube Music Playlist")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
        .onAppear(perform: fetchPlaylists)
    }
    
    private func fetchPlaylists() {
        isLoading = true
        errorMessage = nil
        
        youtubeMusicManager.fetchUserPlaylists { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let fetchedPlaylists):
                    self.playlists = fetchedPlaylists
                case .failure(let error):
                    errorMessage = "Failed to fetch playlists: \(error.localizedDescription)"
                }
            }
        }
    }
}
