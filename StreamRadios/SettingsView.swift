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
    
    @State private var showCustomAlert = false
    @State private var customAlertTitle = ""
    @State private var customAlertMessage = ""
    @State private var customAlertPrimaryButtonText = ""
    @State private var customAlertPrimaryAction: (() -> Void)?
    @State private var customAlertSecondaryButtonText: String?
    @State private var customAlertSecondaryAction: (() -> Void)?
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    playbackSettingsSection
                    displaySettingsSection
                    streamFileUploadSection
                    dataManagementSection
                }
                .padding()
            }
            .navigationTitle("Settings")
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    backButton
                }
            }
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
            
            if showCustomAlert {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                CustomAlertView(
                    title: customAlertTitle,
                    message: customAlertMessage,
                    buttonText: customAlertPrimaryButtonText,
                    buttonAction: {
                        showCustomAlert = false
                        customAlertPrimaryAction?()
                    },
                    secondaryButtonText: customAlertSecondaryButtonText,
                    secondaryButtonAction: {
                        showCustomAlert = false
                        customAlertSecondaryAction?()
                    }
                )
                .transition(.opacity)
            }
        }
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
        switch alertType {
        case .exportWithoutCountry:
            customAlertTitle = "Select a Country"
            customAlertMessage = "Please select a country from the country selector in the app before exporting stations."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = nil
            customAlertSecondaryButtonText = nil
            customAlertSecondaryAction = nil
        case .importWithoutCountry:
            customAlertTitle = "Select a Country"
            customAlertMessage = "Please select a country from the country selector in the app before importing stations."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = nil
            customAlertSecondaryButtonText = nil
            customAlertSecondaryAction = nil
        case .deleteAllData:
            customAlertTitle = "Delete All Data"
            customAlertMessage = "Important: You're about to delete all station playlist data. This will remove all your saved playlists from both iCloud and your device's local storage. This action is permanent and cannot be reversed."
            customAlertPrimaryButtonText = "Delete"
            customAlertPrimaryAction = {
                initiateDataDeletion()
            }
            customAlertSecondaryButtonText = "Cancel"
            customAlertSecondaryAction = {
                // This will be called when Cancel is tapped
            }
        }
        showCustomAlert = true
    }
    
    private func initiateDataDeletion() {
        if viewModel.isCloudKitOperationRunning {
            notificationManager.notifyUser(title: "Operation in Progress", message: "iCloud operation in progress. Please wait before deleting data.")
        } else {
            notificationManager.notifyUser(title: "Deletion Started", message: "The process to delete all stations from iCloud and local storage has started.")
            viewModel.deleteAllData { success, error in
                if success {
                    print("Deletion was successful.")
                    self.deletionComplete = true
                    notificationManager.notifyUser(title: "Deletion Complete", message: "All data has been successfully deleted from iCloud and local storage.")
                } else if let error = error {
                    print("Deletion failed: \(error.localizedDescription)")
                    notificationManager.notifyUser(title: "Deletion Failed", message: "An error occurred while deleting data. Please try again.")
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
            isImporting = false
            importURL = nil
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environmentObject(RadioStationViewModel())
    }
}
