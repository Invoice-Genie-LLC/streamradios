//
//  AddPodcastView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import SwiftUI

struct AddPodcastView: View {
    @Binding var isPresented: Bool
    @Binding var title: String
    @Binding var url: String
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @EnvironmentObject var permissionManager: PermissionManager
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @StateObject private var radioPlayer = RadioPlayer.shared
    
    let onAdd: () -> Void
    private let miniPlayerHeight: CGFloat = 60 // Adjust this value based on your MiniPlayerView height

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NavigationView {
                    VStack(spacing: 0) {
                        // Custom toolbar
                        HStack {
                            Button(action: {
                                isPresented = false
                            }) {
                                Text("Cancel")
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                            Text("Add Podcast")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button(action: validateAndSavePodcast) {
                                Text("Add")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        Divider()
                        
                        ScrollView {
                            VStack(spacing: 0) {
                                Form {
                                    Section(header: Text("Podcast Details")) {
                                        HStack {
                                            TextField("Podcast Title", text: $title)
                                                .onChange(of: title) { newValue in
                                                    if newValue.count >= 40 {
                                                        title = String(newValue.prefix(40))
                                                    }
                                                }
                                            if !title.isEmpty {
                                                Button(action: {
                                                    title = ""
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.gray)
                                                }
                                                .padding(.trailing, 8)
                                            }
                                        }
                                        
                                        HStack {
                                            TextField("RSS Feed URL", text: $url)
                                            if !url.isEmpty {
                                                Button(action: {
                                                    url = ""
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.gray)
                                                }
                                                .padding(.trailing, 8)
                                            }
                                        }
                                    }
                                }
                                .frame(minHeight: geometry.size.height - (podcastPlayer.currentEpisode != nil ? miniPlayerHeight + 44 : 44))
                            }
                        }
                        
                        if podcastPlayer.isPlaying && !radioPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                            MiniPlayerView(
                                podcastPlayer: podcastPlayer,
                                viewModel: podcastViewModel,
                                selectedPodcast: $selectedPodcast,
                                onListButtonTap: {
                                    if let currentFeed = podcastPlayer.currentFeed {
                                        selectedPodcast = currentFeed
                                        podcastViewModel.fetchAllEpisodes(for: currentFeed)
                                        scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                                        showPodcastPlayerSheet = true
                                    }
                                },
                                onCloseButtonTap: {
                                    podcastPlayer.pause()
                                    podcastPlayer.currentEpisode = nil
                                    podcastPlayer.currentFeed = nil
                                },
                                isPlaylistButtonDisabled: false
                            )
                            .transition(.move(edge: .bottom))
                            .frame(height: miniPlayerHeight)
                        }
                    }
                    .navigationBarHidden(true)
                }
                
                if showAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                        self.showAlert = false
                    }
                    .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showPodcastPlayerSheet) {
            if let podcast = selectedPodcast {
                PodcastPlayerView(
                    viewModel: podcastViewModel,
                    feed: podcast,
                    initialScrollToEpisodeID: scrollToEpisodeID,
                    podcastPlayer: podcastPlayer,
                    selectedPodcast: $selectedPodcast,
                    episodeToScrollTo: Binding(
                        get: { podcastPlayer.currentEpisode },
                        set: { _ in }
                    )
                )
            }
        }
    }
    
    private func validateAndSavePodcast() {
        // Validate title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Please enter a podcast title."
            showAlert = true
            return
        }
        
        // Validate URL
        guard let url = URL(string: self.url),
              UIApplication.shared.canOpenURL(url),
              url.scheme == "http" || url.scheme == "https" else {
            alertMessage = "Please enter a valid RSS Feed URL (must start with http:// or https://)."
            showAlert = true
            return
        }

        onAdd()
        isPresented = false
    }
}

struct AddPodcastView_Previews: PreviewProvider {
    static var previews: some View {
        AddPodcastView(isPresented: .constant(true), title: .constant(""), url: .constant(""), onAdd: {
            print("Podcast added")
        })
        .environmentObject(PermissionManager())
        .environmentObject(PodcastViewModel())
    }
}
