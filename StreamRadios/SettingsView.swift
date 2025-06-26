// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
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
    @State private var isDeletingAllAppData = false
    @State private var appDataDeletionComplete = false
    @State private var isDeletingRadioStationRecords = false
    @State private var radioStationRecordsDeletionComplete = false
    @State private var radioStationRecordsDeletionError: String? = nil
    
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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                                         LazyVStack(spacing: 24) {
                         modernPlaybackSettings
                         modernDisplaySettings
                         modernAlarmSettings
                         modernImportExportSettings
                         modernDataManagement
                     }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, podcastPlayer.isPlaying && podcastPlayer.currentEpisode != nil ? 120 : 80)
                }
                
                // Fixed Mini Player
                if podcastPlayer.isPlaying, let currentEpisode = podcastPlayer.currentEpisode, let currentFeed = podcastPlayer.currentFeed {
                    MiniPodcastPlayerView(
                        currentEpisode: currentEpisode,
                        currentFeed: currentFeed,
                        podcastPlayer: podcastPlayer,
                        viewModel: podcastViewModel,
                        selectedPodcast: $selectedPodcast,
                        onListButtonTap: {
                            selectedPodcast = currentFeed
                            podcastViewModel.fetchAllEpisodes(for: currentFeed)
                            scrollToEpisodeID = podcastPlayer.currentEpisode?.id
                            showPodcastPlayerSheet = true
                        },
                        onCloseButtonTap: {
                            podcastPlayer.pause()
                            podcastPlayer.currentEpisode = nil
                            podcastPlayer.currentFeed = nil
                        }
                    )
                    .transition(.move(edge: .bottom))
                    .frame(height: miniPlayerHeight)
                }
            }
            .background(backgroundColor)
            .navigationTitle("Settings")
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.large)
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
    
    // MARK: - Modern Settings Sections
    
    @ViewBuilder
    private var modernPlaybackSettings: some View {
        ModernSettingsCard(
            title: "Playback Settings",
            icon: ""
        ) {
            ModernToggleRow(
                title: "Auto-Play Last Station",
                subtitle: "Automatically resume the last played station when opening the app",
                isOn: $autoPlayLastStation,
                icon: "play.circle.fill"
            )
        }
    }
    
             @ViewBuilder 
    private var modernDisplaySettings: some View {
        ModernSettingsCard(
            title: "Display Settings", 
            icon: ""
        ) {
             ModernToggleRow(
                 title: "Dark Mode",
                 subtitle: "Use dark appearance throughout the app",
                 isOn: $isDarkMode,
                 icon: "paintbrush.fill"
             )
         }
     }
     
     @ViewBuilder
     private var modernAlarmSettings: some View {
         ModernSettingsCard(
             title: "Alarm Settings",
             icon: ""
         ) {
                                     NavigationLink(destination: AlarmConfigurationView()) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        
                        Text("Configure Alarms")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    
                    Text("Set up wake-up alarms with your favorite stations")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
         }
     }
    
    @ViewBuilder
    private var modernImportExportSettings: some View {
        ModernSettingsCard(
            title: "Station Playlist Export/Import",
            icon: ""
        ) {
            VStack(spacing: 16) {
                                 // Country Selection
                 VStack(alignment: .leading, spacing: 8) {
                     HStack(spacing: 8) {
                         Image(systemName: "globe")
                             .font(.system(size: 16, weight: .medium))
                             .foregroundColor(.blue)
                             .frame(width: 20)
                         
                         Text("Country Selection")
                             .font(.system(size: 16, weight: .semibold))
                             .foregroundColor(primaryTextColor)
                         
                         Spacer()
                     }
                    
                    ElegantCountryPickerButton(
                        selectedCountry: $viewModel.selectedCountry,
                        countries: viewModel.countries
                    )
                    .onChange(of: viewModel.selectedCountry) { newValue in
                        viewModel.selectedCountry = newValue
                    }
                }
                
                // Export Button
                ModernActionButton(
                    title: "Export Playlist",
                    subtitle: "Save your stations to a file",
                    icon: "arrow.up.circle.fill",
                    action: exportAction
                )
                
                // Import Button and Progress
                VStack(spacing: 12) {
                    ModernActionButton(
                        title: "Import Playlist", 
                        subtitle: "Load stations from a file",
                        icon: "arrow.down.circle.fill",
                        action: importAction
                    )
                    
                    if isImporting {
                        ModernProgressView(
                            title: "Importing station playlists...",
                            progress: importProgress
                        )
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var modernDataManagement: some View {
        ModernSettingsCard(
            title: "Data Management",
            icon: "",
            isDestructive: true
        ) {
            VStack(spacing: 16) {
                ModernDestructiveButton(
                    title: "Delete All App Data",
                    subtitle: "Permanently remove all stations, podcasts, and settings",
                    icon: "internaldrive.fill",
                    action: { showAlert(for: .deleteAllAppData) }
                )
                
                if isDeletingAllAppData {
                    ModernProgressView(title: "Deleting all app data...")
                } else if appDataDeletionComplete {
                    ModernStatusMessage(
                        text: "All app data has been deleted.",
                        isSuccess: true
                    )
                }
                
                ModernDestructiveButton(
                    title: "Delete All Radio Station Records (CloudKit)",
                    subtitle: "Remove all RadioStation records from iCloud in batches of 400",
                    icon: "antenna.radiowaves.left.and.right",
                    action: { deleteAllRadioStationRecords() }
                )
                
                if isDeletingRadioStationRecords {
                    ModernProgressView(title: "Deleting all RadioStation records from CloudKit...")
                } else if radioStationRecordsDeletionComplete {
                    ModernStatusMessage(
                        text: "All RadioStation records have been deleted from CloudKit.",
                        isSuccess: true
                    )
                } else if let error = radioStationRecordsDeletionError {
                    ModernStatusMessage(
                        text: "Error: \(error)",
                        isSuccess: false
                    )
                }
                
                ModernWarningText(text: appDataDeletionWarningString)
            }
        }
    }
    
    // MARK: - Helper Properties
    
    private var appDataDeletionWarningString: String {
        """
        Warning: Deleting all app data will permanently erase all stored stations, podcasts, downloads, progress, favorites, and settings from both iCloud and your device's local storage. This action cannot be undone.
        """
    }
    
    // MARK: - Action Methods (Preserved from original)
    
    private func updateDarkMode(to newValue: Bool) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
        }
        UserDefaults.standard.set(true, forKey: "isDarkModeSet")
    }
    
    private func showAlert(for alertType: AlertType) {
        alertManager.showCustomAlert(for: alertType, deleteAction: {
            switch alertType {
            case .deleteAllAppData:
                initiateAppDataDeletion()
            case .confirmImportWithDataClear:
                showDocumentPicker = true
            default:
                break
            }
        })
    }
    
    private func initiateAppDataDeletion() {
        isDeletingAllAppData = true
        appDataDeletionComplete = false
        notificationManager.notifyUser(title: "Deletion Started", message: "The process to delete all app data has started.")
        let group = DispatchGroup()
        var allSuccess = true
        group.enter()
        viewModel.deleteAllData { success, _ in
            if !success { allSuccess = false }
            group.leave()
        }
        group.enter()
        podcastViewModel.clearAllPodcastData { success in
            if !success { allSuccess = false }
            group.leave()
        }
        group.notify(queue: .main) {
            // Optionally clear UserDefaults
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            UserDefaults.standard.synchronize()
            isDeletingAllAppData = false
            appDataDeletionComplete = allSuccess
            if allSuccess {
                notificationManager.notifyUser(title: "Deletion Complete", message: "All app data has been successfully deleted.")
            } else {
                notificationManager.notifyUser(title: "Deletion Failed", message: "An error occurred while deleting app data. Please try again.")
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
        
        // Directly proceed with import (appending to existing stations)
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
    
    private func deleteAllRadioStationRecords() {
        isDeletingRadioStationRecords = true
        radioStationRecordsDeletionComplete = false
        radioStationRecordsDeletionError = nil
        DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.isDeletingRadioStationRecords = false
                    self.radioStationRecordsDeletionError = error.localizedDescription
                }
                return
            }
            guard let recordIDs = recordIDs, !recordIDs.isEmpty else {
                DispatchQueue.main.async {
                    self.isDeletingRadioStationRecords = false
                    self.radioStationRecordsDeletionComplete = true
                }
                return
            }
            DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                DispatchQueue.main.async {
                    self.isDeletingRadioStationRecords = false
                    self.radioStationRecordsDeletionComplete = success
                    if let error = error {
                        self.radioStationRecordsDeletionError = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Modern UI Components

struct ModernSettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let isDestructive: Bool
    let content: () -> Content
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, icon: String, isDestructive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.content = content
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    private var titleColor: Color {
        if isDestructive {
            return .red
        }
        return colorScheme == .dark ? .white : .primary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isDestructive ? .red : .blue)
                        .frame(width: 24, height: 24)
                }
                
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(titleColor)
                
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

struct ModernToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    let icon: String
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.icon = icon
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
                
                Toggle("", isOn: $isOn)
                    .labelsHidden()
            }
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
            }
        }
    }
}

struct ModernActionButton: View {
    let title: String
    let subtitle: String?
    let icon: String
    let action: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ModernDestructiveButton: View {
    let title: String
    let subtitle: String?
    let icon: String
    let action: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.red)
                        .frame(width: 20)
                    
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ModernProgressView: View {
    let title: String
    let progress: Double?
    
    @Environment(\.colorScheme) var colorScheme
    
    init(title: String, progress: Double? = nil) {
        self.title = title
        self.progress = progress
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if let progress = progress {
                ProgressView(value: progress, total: 1.0) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                }
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.blue)
                    
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ModernStatusMessage: View {
    let text: String
    let isSuccess: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isSuccess ? .green : .orange)
            
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colorScheme == .dark ? .white : .primary)
        }
        .padding(12)
        .background((isSuccess ? Color.green : Color.orange).opacity(0.1))
        .cornerRadius(8)
    }
}

struct ModernWarningText: View {
    let text: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.red)
                
                Text("Important")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
            }
            
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                .lineLimit(nil)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SettingsView()
                .environmentObject(RadioStationViewModel())
                .environmentObject(AlertManager())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")
            
            SettingsView()
                .environmentObject(RadioStationViewModel())
                .environmentObject(AlertManager())
                .preferredColorScheme(.light)
                .previewDisplayName("Light Mode")
        }
    }
}
