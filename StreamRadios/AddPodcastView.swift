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
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var permissionManager: PermissionManager
    @StateObject private var podcastViewModel = PodcastViewModel()
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @StateObject private var radioPlayer = RadioPlayer.shared
    
    // Add editing support
    let podcastToEdit: PodcastFeed?
    let onAdd: () -> Void
    let onUpdate: ((PodcastFeed) -> Void)?
    
    private let miniPlayerHeight: CGFloat = 60
    
    // Modern color system for adaptive theming
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    // Computed properties for UI
    private var navigationTitle: String {
        podcastToEdit != nil ? "Edit Podcast" : "Add Podcast"
    }
    
    private var actionButtonText: String {
        podcastToEdit != nil ? "Update" : "Add"
    }
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            modernPodcastDetailsCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, podcastPlayer.isPlaying && !radioPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 120 : 80)
                    }
                    
                    // Fixed Mini Player
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
                .background(Color(red: 0.08, green: 0.08, blue: 0.08))
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.large)
            .navigationBarItems(
                leading: modernCancelButton,
                trailing: modernSaveButton
            )
            .onAppear {
                // Populate fields when editing
                if let podcastToEdit = podcastToEdit {
                    title = podcastToEdit.title
                    url = podcastToEdit.url
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
        .preferredColorScheme(.dark)
        .overlay(
            Group {
                if showAlert {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                        self.showAlert = false
                    }
                    .transition(.opacity)
                }
            }
        )
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
    
    // MARK: - Modern UI Components
    
    @ViewBuilder
    private var modernPodcastDetailsCard: some View {
        ModernFormCard(title: "Podcast Details") {
            VStack(spacing: 16) {
                ModernTextField(
                    title: "Podcast Title",
                    text: $title,
                    placeholder: "Enter podcast title",
                    icon: "mic.fill",
                    maxLength: 40
                )
                
                ModernTextField(
                    title: "RSS Feed URL",
                    text: $url,
                    placeholder: "https://example.com/podcast.rss",
                    icon: "link",
                    keyboardType: .URL
                )
            }
        }
    }
    
    @ViewBuilder
    private var modernCancelButton: some View {
        Button("Cancel") {
            isPresented = false
        }
        .foregroundColor(.blue)
    }
    
    @ViewBuilder
    private var modernSaveButton: some View {
        Button(actionButtonText) {
            validateAndSavePodcast()
        }
        .foregroundColor(.blue)
        .fontWeight(.semibold)
    }
    
    // MARK: - Helper Methods (Preserved from original)
    
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

        // Handle edit vs add
        if let podcastToEdit = podcastToEdit {
            // Update existing podcast
            print("DEBUG: AddPodcastView - Original podcast - ID: \(podcastToEdit.id), Title: '\(podcastToEdit.title)', URL: '\(podcastToEdit.url)'")
            print("DEBUG: AddPodcastView - New values - Title: '\(title.trimmingCharacters(in: .whitespacesAndNewlines))', URL: '\(self.url.trimmingCharacters(in: .whitespacesAndNewlines))'")
            
            var updatedPodcast = podcastToEdit
            updatedPodcast.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            updatedPodcast.url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("DEBUG: AddPodcastView - Updated podcast - ID: \(updatedPodcast.id), Title: '\(updatedPodcast.title)', URL: '\(updatedPodcast.url)'")
            onUpdate?(updatedPodcast)
        } else {
            // Add new podcast
            onAdd()
        }
        
        isPresented = false
    }
}

// MARK: - Modern UI Components for Forms

struct ModernFormCard<Content: View>: View {
    let title: String
    let content: () -> Content
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            // Content
            content()
        }
        .padding(20)
        .background(cardBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
    }
}

struct ModernTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let icon: String
    let maxLength: Int?
    let keyboardType: UIKeyboardType
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, text: Binding<String>, placeholder: String, icon: String, maxLength: Int? = nil, keyboardType: UIKeyboardType = .default) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.icon = icon
        self.maxLength = maxLength
        self.keyboardType = keyboardType
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                
                Spacer()
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .disableAutocorrection(keyboardType == .URL)
                    .onChange(of: text) { newValue in
                        if let maxLength = maxLength, newValue.count > maxLength {
                            text = String(newValue.prefix(maxLength))
                        }
                    }
                    .padding(.leading, 4)
                
                if !text.isEmpty {
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct AddPodcastView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AddPodcastView(
                isPresented: .constant(true), 
                title: .constant(""), 
                url: .constant(""), 
                podcastToEdit: nil,
                onAdd: {
                    print("Podcast added")
                },
                onUpdate: { podcast in
                    print("Podcast updated: \(podcast.title)")
                }
            )
            .environmentObject(PermissionManager())
            .environmentObject(PodcastViewModel())
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
            
            AddPodcastView(
                isPresented: .constant(true), 
                title: .constant("Sample Podcast"), 
                url: .constant("https://example.com/feed.rss"), 
                podcastToEdit: nil,
                onAdd: {
                    print("Podcast added")
                },
                onUpdate: { podcast in
                    print("Podcast updated: \(podcast.title)")
                }
            )
            .environmentObject(PermissionManager())
            .environmentObject(PodcastViewModel())
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
        }
    }
}
