// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @Environment(\.presentationMode) var presentationMode
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var deletionComplete = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    @StateObject private var notificationManager = NotificationManager.shared
    @State private var showDocumentPicker = false
    @State private var showAlertForCountrySelection = false
    @State private var isImporting = false
    @State private var importProgress: Double = 0.0
    @State private var importURL: URL?
    @State private var showAlertForExportWithoutCountry = false
    @State private var currentAlert: AlertType?
    @State private var activeAlert: AlertType?
    @EnvironmentObject var alertManager: AlertManager
    var onImportComplete: ((String) -> Void)?
    @StateObject private var podcastViewModel = PodcastViewModel()
        @State private var isCleaningPodcasts = false
        @State private var podcastCleanupComplete = false
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @State private var safeAreaBottom: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 60
    
    var body: some View {
           NavigationView {
               VStack(spacing: 0) {
                   ScrollView {
                       VStack(alignment: .leading, spacing: 20) {
                           playbackSettingsSection
                           displaySettingsSection
                           streamFileUploadSection
                           dataManagementSection
                           podcastDataManagementSection
                       }
                      
                   }
                   .padding(.bottom, podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 40 : 0)

                   // Fixed Mini Player
                   if podcastPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
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
               .navigationTitle("Settings")
               .navigationBarBackButtonHidden(true)
              
               .onChange(of: isDarkMode) { newValue in
                   updateDarkMode(to: newValue)
               }
               .onAppear {
                   if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
                       notificationManager.requestAuthorization()
                       UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
                   }
               }
               .onReceive(NotificationCenter.default.publisher(for: .countrySelected)) { _ in
                   if viewModel.selectedCountry != "Select Country" {
                       showAlertForCountrySelection = false
                   }
               }
               .sheet(isPresented: $showDocumentPicker) {
                   DocumentPicker(url: $importURL)
               }
               .onChange(of: importURL) { url in
                   guard let url = url else { return }
                   handleImport(url: url)
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
           .overlay(
               Group {
                   if alertManager.showCustomAlert {
                       Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                       CustomAlertView(
                           title: alertManager.customAlertTitle,
                           message: alertManager.customAlertMessage,
                           buttonText: alertManager.customAlertPrimaryButtonText,
                           buttonAction: {
                               alertManager.dismissAlert()
                               alertManager.customAlertPrimaryAction?()
                           },
                           secondaryButtonText: alertManager.customAlertSecondaryButtonText,
                           secondaryButtonAction: {
                               alertManager.dismissAlert()
                               alertManager.customAlertSecondaryAction?()
                           }
                       )
                       .transition(.opacity)
                   }
               }
           )
       }
    
    
    private var podcastDataManagementSection: some View {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Podcast Data Management")
                        .font(.headline)
                        .padding(.top)
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Button("Clear All Podcast Episodes") {
                            showAlert(for: .clearAllPodcasts)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                        
                        if isCleaningPodcasts {
                            ProgressView("Clearing podcast data...")
                                .padding()
                        } else if podcastCleanupComplete {
                            Text("All podcast episodes have been cleared.")
                                .foregroundColor(.green)
                                .padding()
                        }
                        
                        podcastCleanupWarningText
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.bottom, 100)
                .animation(.default, value: isCleaningPodcasts)
                .animation(.default, value: podcastCleanupComplete)
            }
    
    private var podcastCleanupWarningText: some View {
            Text("Warning: ")
                .fontWeight(.bold)
                .foregroundColor(.red)
                .font(.footnote) +
            Text("Clearing all podcast episodes will permanently erase ALL podcast-related data from your device's local storage, including:\n\n• All downloaded episodes\n• Playback progress for all episodes\n• All bookmarked episodes\n• All favorited episodes\n• Episode listening history\n• Custom sort preferences\n\nThis action cannot be undone.")
                .font(.footnote)
                .foregroundColor(.gray)
        }
    
    
    private var playbackSettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Playback Settings")
                .font(.headline)
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 15) {
                Toggle("Auto-Play Last Station", isOn: $autoPlayLastStation)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    private var displaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Display Settings")
                .font(.headline)
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 15) {
                Toggle("Dark Mode", isOn: $isDarkMode)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    private var streamFileUploadSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Station Playlist Export/Import")
                .font(.headline)
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 20) {
                countrySelectionView
                fileExportView
                fileImportView
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    private var countrySelectionView: some View {
        VStack(alignment: .leading) {
            Text("Select Country")
                .font(.headline)
                .foregroundColor(.primary)
            StyledPickerView(selectedCountry: $viewModel.selectedCountry, countries: viewModel.countries)
                .onChange(of: viewModel.selectedCountry) { newValue in
                                // This will trigger the didSet in the ViewModel, which will post the notification
                                viewModel.selectedCountry = newValue
                            }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                
        }
    }
    
    private var fileExportView: some View {
        VStack(alignment: .leading) {
            Text("Playlist Export")
                .font(.headline)
                .foregroundColor(.primary)
            Button(action: exportAction) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title2)
                        .foregroundColor(.blue)
                    Text("Export Playlist File")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
        }
    }
    
    private var fileImportView: some View {
        VStack(alignment: .leading) {
            Text("Playlist Import")
                .font(.headline)
                .foregroundColor(.primary)
            Button(action: importAction) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    Text("Import Playlist File")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            if isImporting {
                VStack {
                    ProgressView(value: importProgress, total: 1.0) {
                        Text("Importing station playlists...")
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .padding(.top, 10)
            }
        }
    }
    
    private var dataManagementSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data Management")
                .font(.headline)
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 15) {
                Button("Delete All Data") {
                    showAlert(for: .deleteAllData)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                
                if viewModel.isDeletingData {
                    ProgressView("Deleting data...")
                        .padding()
                } else if viewModel.deletionComplete {
                    Text("All data has been deleted.")
                        .foregroundColor(.green)
                        .padding()
                }
                
                deletionWarningText
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .animation(.default, value: viewModel.isDeletingData)
        .animation(.default, value: viewModel.deletionComplete)
    }
    
    private var deletionWarningText: some View {
        Text("Warning: ")
            .fontWeight(.bold)
            .foregroundColor(.red)
            .font(.footnote) +
        Text("Deleting your data will permanently erase all stored stations and their associated information from both iCloud and your device's local storage. While you can restore default stations by reinstalling the app from the App Store, any custom stations you've configured will be lost permanently.")
            .font(.footnote)
            .foregroundColor(.gray)
        +
        Text("\n\n")
        +
        Text("Please keep the app running in the background. You can use other apps, but do not force close this one. We'll notify you when the deletion is fully completed. The duration of this operation may vary, but it could take up to 5 minutes depending on the number of custom stations configured. This action cannot be undone.")
            .font(.footnote)
            .foregroundColor(.gray)
    }
    
    private var backButton: some View {
        Button(action: {
            presentationMode.wrappedValue.dismiss()
        }) {
            HStack {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .foregroundColor(.primary)
        }
    }
    
    private func updateDarkMode(to newValue: Bool) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
        }
        UserDefaults.standard.set(true, forKey: "isDarkModeSet")
    }
    
    private func showAlert(for alertType: AlertType) {
            alertManager.showCustomAlert(for: alertType, deleteAction: {
                switch alertType {
                case .deleteAllData:
                    initiateDataDeletion()
                case .clearAllPodcasts:
                    initiatePodcastCleanup()
                default:
                    break
                }
            })
        }
    
    private func initiatePodcastCleanup() {
        isCleaningPodcasts = true
        podcastCleanupComplete = false

        podcastViewModel.clearAllPodcastData { success in
            DispatchQueue.main.async {
                self.isCleaningPodcasts = false
                if success {
                    self.podcastCleanupComplete = true
                    self.notificationManager.notifyUser(title: "Podcast Cleanup Complete", message: "All podcast data has been successfully cleared, including downloads, playback progress, bookmarks, favorites, and listening history.")
                } else {
                    self.notificationManager.notifyUser(title: "Podcast Cleanup Failed", message: "An error occurred while clearing podcast data. Some data may not have been fully cleared. Please try again.")
                }
            }
        }
    }
    
    private func initiateDataDeletion() {
        if viewModel.isCloudKitOperationRunning {
            notificationManager.notifyUser(title: "Operation in Progress", message: "iCloud operation in progress. Please wait before deleting data.")
        } else {
            notificationManager.notifyUser(title: "Deletion Started", message: "The process to delete all stations from iCloud and local storage has started.")
            
            DispatchQueue.main.async {
                viewModel.isDeletingData = true
                viewModel.deletionComplete = false
            }
            
            viewModel.deleteAllData { success, error in
                DispatchQueue.main.async {
                    viewModel.isDeletingData = false
                    if success {
                        print("Deletion was successful.")
                        viewModel.deletionComplete = true
                        notificationManager.notifyUser(title: "Deletion Complete", message: "All data has been successfully deleted from iCloud and local storage.")
                    } else if let error = error {
                        print("Deletion failed: \(error.localizedDescription)")
                        notificationManager.notifyUser(title: "Deletion Failed", message: "An error occurred while deleting data. Please try again.")
                    }
                }
            }
        }
    }
    
    private func exportAction() {
        if viewModel.selectedCountry == "Select Country" {
            showAlert(for: .exportWithoutCountry)
        } else {
            viewModel.exportStationsToFile { fileURL in
                guard let fileURL = fileURL else { return }
                let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL])
                UIApplication.shared.windows.first?.rootViewController?.present(documentPicker, animated: true, completion: nil)
            }
        }
    }
    
    private func importAction() {
        if viewModel.selectedCountry == "Select Country" {
            showAlert(for: .importWithoutCountry)
        } else {
            showDocumentPicker = true
        }
    }
    
    private func handleImport(url: URL) {
            isImporting = true
            importProgress = 0.0
            
            viewModel.importStationsFromFile(url: url) { progress in
                DispatchQueue.main.async {
                    importProgress = progress
                }
            } completion: {
                DispatchQueue.main.async {
                    isImporting = false
                    importURL = nil
                    onImportComplete?(viewModel.selectedCountry)
                }
            }
        }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(RadioStationViewModel())
            .environmentObject(AlertManager())
    }
}
