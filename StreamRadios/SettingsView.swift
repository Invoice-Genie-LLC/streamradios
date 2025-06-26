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
    @EnvironmentObject private var podcastViewModel: PodcastViewModel
    @State private var isCleaningPodcasts = false
    @State private var podcastCleanupComplete = false
    @StateObject private var podcastPlayer = PodcastPlayer.shared
    @State private var selectedPodcast: PodcastFeed?
    @State private var scrollToEpisodeID: String?
    @State private var showPodcastPlayerSheet = false
    @State private var safeAreaBottom: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 60
    
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
                         modernDataManagementLink
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
            .navigationBarTitleDisplayMode(.inline)
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
    private var modernDataManagementLink: some View {
        ModernSettingsCard(
            title: "Data Management",
            icon: "externaldrive.fill"
        ) {
            NavigationLink(destination: InternalDataManagementView(
                viewModel: viewModel,
                onImportComplete: onImportComplete
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        
                        Text("Manage App Data")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    
                    Text("Import/export stations and manage stored data")
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
    
    // MARK: - Helper Properties
    
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
            case .confirmImportWithDataClear:
                showDocumentPicker = true
            default:
                break
            }
        })
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

// MARK: - Internal Data Management View

struct InternalDataManagementView: View {
    @StateObject private var alertManager = AlertManager()
    @ObservedObject var viewModel: RadioStationViewModel
    @EnvironmentObject var podcastViewModel: PodcastViewModel
    @ObservedObject private var notificationManager = NotificationManager.shared
    
    let onImportComplete: ((String) -> Void)?
    
    // State variables for import/export
    @State private var showDocumentPicker = false
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var isImporting = false
    @State private var importProgress: Double = 0.0
    @State private var importURL: URL?
    
    // State variables for deletion operations
    @State private var isDeletingAllAppData = false
    @State private var appDataDeletionComplete = false
    @State private var isDeletingStationData = false
    @State private var stationDataDeletionComplete = false
    @State private var stationDataDeletionError: String?
    @State private var isDeletingPodcastData = false
    @State private var podcastDataDeletionComplete = false
    @State private var podcastDataDeletionError: String?
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    // Modern color system matching SettingsView
    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(.systemGray6)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.15) : .white
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                // Import/Export Section
                importExportSection
                
                // Data Deletion Section
                dataDeletionSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 80)
        }
        .background(backgroundColor)
        .navigationTitle("Data Management")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(url: $importURL)
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL = exportURL {
                ExportSheet(fileURL: exportURL) {
                    print("🔚 DEBUG: ExportSheet onDismiss callback called")
                    showExportSheet = false
                    self.exportURL = nil
                    print("📊 DEBUG: Reset showExportSheet to false and exportURL to nil")
                }
                .onAppear {
                    print("📱 DEBUG: Export sheet appeared with URL: \(exportURL.path)")
                }
            } else {
                VStack {
                    Text("Export URL is nil")
                        .foregroundColor(.red)
                        .padding()
                }
                .onAppear {
                    print("❌ DEBUG: Export sheet appeared but exportURL is nil")
                }
            }
        }
        .onChange(of: showExportSheet) { isPresented in
            if isPresented {
                print("📱 DEBUG: Export sheet is being presented")
                print("📊 DEBUG: exportURL is: \(String(describing: exportURL))")
            }
        }
        .onChange(of: importURL) { url in
            if let url = url {
                handleImport(url: url)
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
    
    @ViewBuilder
    private var importExportSection: some View {
        VStack(spacing: 16) {
            ModernSettingsCard(
                title: "Import & Export",
                icon: "externaldrive.fill"
            ) {
                VStack(spacing: 12) {
                    // Country Selection
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            
                            Text("Country Selection")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(colorScheme == .dark ? .white : .primary)
                            
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
                    
                    ModernActionButton(
                        title: "Export Stations",
                        subtitle: "Save stations to a file",
                        icon: "square.and.arrow.up",
                        action: exportAction
                    )
                    
                    ModernActionButton(
                        title: "Import Stations",
                        subtitle: "Load stations from a file",
                        icon: "square.and.arrow.down",
                        action: importAction
                    )
                    
                    if isImporting {
                        ModernProgressView(
                            title: "Importing stations...",
                            progress: importProgress
                        )
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var dataDeletionSection: some View {
        VStack(spacing: 16) {
            // Delete All App Data Section
            ModernSettingsCard(
                title: "Delete All App Data",
                icon: "internaldrive.fill",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    ModernDestructiveButton(
                        title: "Delete All App Data",
                        subtitle: "Remove all stations, podcasts, episodes, downloads, progress & favorites",
                        icon: "trash.fill",
                        action: { showAlert(for: .deleteAllAppData) }
                    )
                    
                    if isDeletingAllAppData {
                        ModernProgressView(title: "Deleting all app data in batches...")
                    } else if appDataDeletionComplete {
                        ModernStatusMessage(
                            text: "All app data has been deleted successfully.",
                            isSuccess: true
                        )
                    }
                    
                    ModernWarningText(text: "This will permanently erase ALL app data including stations, podcasts, episodes, downloads, progress, favorites, and settings from both iCloud and local storage.")
                }
            }
            
            // Delete Station Data Section  
            ModernSettingsCard(
                title: "Delete Station Data",
                icon: "antenna.radiowaves.left.and.right",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    ModernDestructiveButton(
                        title: "Delete Station Data",
                        subtitle: "Remove all radio stations and their favorites",
                        icon: "radio.fill",
                        action: { showAlert(for: .deleteStationData) }
                    )
                    
                    if isDeletingStationData {
                        ModernProgressView(title: "Deleting station data in batches...")
                    } else if stationDataDeletionComplete {
                        ModernStatusMessage(
                            text: "All station data has been deleted successfully.",
                            isSuccess: true
                        )
                    } else if let error = stationDataDeletionError {
                        ModernStatusMessage(
                            text: "Error: \(error)",
                            isSuccess: false
                        )
                    }
                    
                    ModernWarningText(text: "This will permanently remove all radio stations and their favorites from both iCloud and local storage.")
                }
            }
            
            // Delete Podcast Data Section
            ModernSettingsCard(
                title: "Delete Podcast Data", 
                icon: "microphone",
                isDestructive: true
            ) {
                VStack(spacing: 12) {
                    ModernDestructiveButton(
                        title: "Delete Podcast Data",
                        subtitle: "Remove all podcast feeds, episodes, downloads & progress",
                        icon: "waveform.circle.fill",
                        action: { showAlert(for: .deletePodcastData) }
                    )
                    
                    if isDeletingPodcastData {
                        ModernProgressView(title: "Deleting podcast data in batches...")
                    } else if podcastDataDeletionComplete {
                        ModernStatusMessage(
                            text: "All podcast data has been deleted successfully.",
                            isSuccess: true
                        )
                    } else if let error = podcastDataDeletionError {
                        ModernStatusMessage(
                            text: "Error: \(error)",
                            isSuccess: false
                        )
                    }
                    
                    ModernWarningText(text: "This will permanently remove all podcast feeds, episodes, downloads, progress, and favorites from both iCloud and local storage.")
                }
            }
        }
    }
    
    // MARK: - Alert Methods
    
    private func showAlert(for alertType: AlertType) {
        alertManager.showCustomAlert(for: alertType, deleteAction: {
            switch alertType {
            case .deleteAllAppData:
                initiateAppDataDeletion()
            case .deleteStationData:
                initiateStationDataDeletion()
            case .deletePodcastData:
                initiatePodcastDataDeletion()
            case .confirmImportWithDataClear:
                showDocumentPicker = true
            default:
                break
            }
        })
    }
    
    // MARK: - Import/Export Methods
    
    private func exportAction() {
        print("🔄 DEBUG: Export action started")
        if viewModel.selectedCountry == "Select Country" {
            print("⚠️ DEBUG: No country selected, showing alert")
            showAlert(for: .exportWithoutCountry)
        } else {
            print("✅ DEBUG: Country selected: \(viewModel.selectedCountry), starting export")
            viewModel.exportStationsToFile { fileURL in
                print("📁 DEBUG: Export callback received")
                guard let fileURL = fileURL else { 
                    print("❌ DEBUG: Export failed - no file URL returned")
                    return 
                }
                print("✅ DEBUG: Export file created at: \(fileURL.path)")
                DispatchQueue.main.async {
                    print("🎯 DEBUG: Setting exportURL and showing sheet")
                    self.exportURL = fileURL
                    self.showExportSheet = true
                    print("📊 DEBUG: exportURL set to: \(String(describing: self.exportURL))")
                    print("📊 DEBUG: showExportSheet set to: \(self.showExportSheet)")
                }
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
    
    // MARK: - Deletion Methods
    
    private func initiateAppDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingAllAppData = true
            self.appDataDeletionComplete = false
            
            // Clear UI immediately for instant feedback
            self.viewModel.clearStationsFromUI()
            self.podcastViewModel.clearPodcastFeedsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all app data in batches...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete station data from local CoreData
        group.enter()
        viewModel.deleteAllData { success, errorMessage in
            if !success {
                allSuccess = false
                lastError = errorMessage?.localizedDescription ?? "Station deletion failed"
            }
            group.leave()
        }
        
        // Delete podcast data from local CoreData
        group.enter()
        podcastViewModel.clearPodcastCoreData { success, error in
            if !success {
                allSuccess = false
                lastError = error?.localizedDescription ?? "Failed to clear local podcast data"
            }
            group.leave()
        }
        
        // Delete all station records from CloudKit
        group.enter()
        DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
            if let error = error {
                allSuccess = false
                lastError = error.localizedDescription
                group.leave()
                return
            }
            
            guard let recordIDs = recordIDs, !recordIDs.isEmpty else {
                group.leave()
                return
            }
            
            DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                if !success {
                    allSuccess = false
                    lastError = error?.localizedDescription ?? "CloudKit station deletion failed"
                }
                group.leave()
            }
        }
        
        // Delete all podcast-related records from CloudKit
        let podcastRecordTypes = ["PodcastFeed", "EpisodeState"]
        
        for recordType in podcastRecordTypes {
            group.enter()
            DataStore.shared.fetchAllRecordIDs(ofType: recordType) { recordIDs, error in
                if let error = error {
                    allSuccess = false
                    lastError = error.localizedDescription
                    group.leave()
                    return
                }
                
                guard let recordIDs = recordIDs, !recordIDs.isEmpty else {
                    group.leave()
                    return
                }
                
                DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                    if !success {
                        allSuccess = false
                        lastError = error?.localizedDescription ?? "CloudKit \(recordType) deletion failed"
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            // Clear UserDefaults only if all other operations succeeded
            if allSuccess {
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                UserDefaults.standard.synchronize()
            }
            
            // Update UI states immediately
            self.isDeletingAllAppData = false
            self.appDataDeletionComplete = allSuccess
            
            // Refresh view models to update UI immediately  
            if allSuccess {
                self.viewModel.loadStationsFromCoreData()
                // Note: podcastViewModel already clears its data in clearPodcastCoreData completion
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if allSuccess {
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All app data has been successfully deleted.")
                } else {
                    let errorMessage = lastError ?? "An unknown error occurred"
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "App data deletion failed: \(errorMessage)")
                }
                
                // Reset completion state after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.appDataDeletionComplete = false
                }
            }
        }
    }
    
    private func initiateStationDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingStationData = true
            self.stationDataDeletionComplete = false
            self.stationDataDeletionError = nil
            
            // Clear radio stations from UI immediately for instant feedback
            self.viewModel.clearStationsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all radio station data...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete from local CoreData
        group.enter()
        viewModel.deleteAllData { success, errorMessage in
            if !success {
                allSuccess = false
                lastError = errorMessage?.localizedDescription ?? "Station deletion failed"
            }
            group.leave()
        }
        
        // Delete from CloudKit in batches
        group.enter()
        DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { recordIDs, error in
            if let error = error {
                allSuccess = false
                lastError = error.localizedDescription
                group.leave()
                return
            }
            
            guard let recordIDs = recordIDs, !recordIDs.isEmpty else {
                group.leave()
                return
            }
            
            DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                if !success {
                    allSuccess = false
                    lastError = error?.localizedDescription ?? "CloudKit deletion failed"
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            // Update UI states immediately
            self.isDeletingStationData = false
            self.stationDataDeletionComplete = allSuccess
            
            if let error = lastError {
                self.stationDataDeletionError = error
            }
            
            // Refresh view models to update UI immediately
            if allSuccess {
                self.viewModel.loadStationsFromCoreData()
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let error = lastError {
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "Station data deletion failed: \(error)")
                } else {
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All station data has been successfully deleted.")
                }
                
                // Reset completion states after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.stationDataDeletionComplete = false
                    self.stationDataDeletionError = nil
                }
            }
        }
    }
    
    private func initiatePodcastDataDeletion() {
        // Reset all states immediately on main queue
        DispatchQueue.main.async {
            self.isDeletingPodcastData = true
            self.podcastDataDeletionComplete = false
            self.podcastDataDeletionError = nil
            
            // Clear podcast feeds from UI immediately for instant feedback
            self.podcastViewModel.clearPodcastFeedsFromUI()
        }
        
        notificationManager.notifyUser(title: "Deletion Started", message: "Deleting all podcast data...")
        
        let group = DispatchGroup()
        var allSuccess = true
        var lastError: String?
        
        // Delete podcast data from local CoreData
        group.enter()
        podcastViewModel.clearPodcastCoreData { success, error in
            if !success { 
                allSuccess = false
                lastError = error?.localizedDescription ?? "Failed to clear local podcast data"
            }
            group.leave()
        }
        
        // Delete from CloudKit in batches (podcast feeds, episodes, etc.)
        let podcastRecordTypes = ["PodcastFeed", "EpisodeState"]
        
        for recordType in podcastRecordTypes {
            group.enter()
            DataStore.shared.fetchAllRecordIDs(ofType: recordType) { recordIDs, error in
                if let error = error {
                    allSuccess = false
                    lastError = error.localizedDescription
                    group.leave()
                    return
                }
                
                guard let recordIDs = recordIDs, !recordIDs.isEmpty else {
                    group.leave()
                    return
                }
                
                DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                    if !success {
                        allSuccess = false
                        lastError = error?.localizedDescription ?? "CloudKit deletion failed for \(recordType)"
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            // Update UI states immediately
            self.isDeletingPodcastData = false
            self.podcastDataDeletionComplete = allSuccess
            
            if let error = lastError {
                self.podcastDataDeletionError = error
            }
            
            // Refresh view models to update UI immediately
            if allSuccess {
                // Note: podcastViewModel already clears its data in clearPodcastCoreData completion
            }
            
            // Force UI refresh and show notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let error = lastError {
                    self.notificationManager.notifyUser(title: "Deletion Failed", message: "Podcast data deletion failed: \(error)")
                } else {
                    self.notificationManager.notifyUser(title: "Deletion Complete", message: "All podcast data has been successfully deleted.")
                }
                
                // Reset completion states after 5 seconds for clean UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.podcastDataDeletionComplete = false
                    self.podcastDataDeletionError = nil
                }
            }
        }
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
