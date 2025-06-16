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
    @ObservedObject var shazamViewModel: ShazamViewModel
    @State private var playlists: [(id: String, name: String)] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var addedPlaylistIDs: Set<String> = []
    @Environment(\.colorScheme) var colorScheme
    
    let onSelect: (String) -> Void  // Modified to pass the selected playlist ID
    
    var filteredPlaylists: [(id: String, name: String)] {
        if searchText.isEmpty {
            return playlists
        } else {
            return playlists.filter { playlist in
                playlist.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background with YouTube Music brand colors
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // YouTube Music header with album artwork and song info
                    headerView
                    
                    // Content based on state
                    contentView
                }
            }
            .navigationTitle("YouTube Music")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .font(.headline)
                    .foregroundColor(.red)
                }
            }
        }
        .onAppear(perform: fetchPlaylists)
    }
    
    private var headerView: some View {
        Group {
            if let songTitle = shazamViewModel.shazamMedia.title,
               let artistName = shazamViewModel.shazamMedia.artistName {
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        // Album artwork
                        if let artworkURL = shazamViewModel.shazamMedia.albumArtURL {
                            AsyncImage(url: artworkURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                case .failure(_):
                                    Image(systemName: "play.circle")
                                        .font(.title)
                                        .foregroundColor(.red)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                case .empty:
                                    ProgressView()
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                @unknown default:
                                    Image(systemName: "play.circle")
                                        .font(.title)
                                        .foregroundColor(.red)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        } else {
                            Image(systemName: "play.circle")
                                .font(.title)
                                .foregroundColor(.red)
                                .frame(width: 60, height: 60)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Adding to YouTube Music")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(songTitle)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                            Text("by \(artistName)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        // YouTube Music logo representation
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            )
                    }
                }
            } else {
                // Fallback header
                HStack {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundColor(.red)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to YouTube Music")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Select a playlist")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                    
                    // YouTube Music logo representation
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                        )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
    
    private var contentView: some View {
        Group {
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.red)
                    Text("Loading playlists...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    Text("Error")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Try Again") {
                        fetchPlaylists()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search YouTube Music playlists", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // Playlists list
                    if filteredPlaylists.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: searchText.isEmpty ? "music.note.list" : "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No playlists found" : "No playlists match your search")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            if searchText.isEmpty {
                                Text("Create a playlist in YouTube Music to get started")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredPlaylists, id: \.id) { playlist in
                                    Button(action: {
                                        if !addedPlaylistIDs.contains(playlist.id) {
                                            addedPlaylistIDs.insert(playlist.id)
                                            onSelect(playlist.id)
                                        }
                                    }) {
                                        HStack(spacing: 16) {
                                            // YouTube Music playlist icon
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(
                                                        LinearGradient(
                                                            gradient: Gradient(colors: [Color.red.opacity(0.8), Color.red.opacity(0.6)]),
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        )
                                                    )
                                                    .frame(width: 52, height: 52)
                                                
                                                Image(systemName: "play.circle")
                                                    .font(.title2)
                                                    .foregroundColor(.white)
                                            }
                                            
                                            // Playlist info
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(playlist.name)
                                                    .font(.headline)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.primary)
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                                
                                                Text("YouTube Music Playlist")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Spacer()
                                            
                                            // Add/Check indicator
                                            if addedPlaylistIDs.contains(playlist.id) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.title2)
                                                    .foregroundColor(.green)
                                                    .scaleEffect(1.1)
                                            } else {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.title2)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 16)
                                                .fill(Color(.secondarySystemBackground))
                                                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
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


