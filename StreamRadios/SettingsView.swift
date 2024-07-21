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
    @State private var importProgress: Double = 0.0  // State variable to track import progress

    var body: some View {
        Form {
            playbackSettingsSection
            displaySettingsSection
            streamFileUploadSection
            dataManagementSection
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
        Spacer()
    }

    private var playbackSettingsSection: some View {
        Section(header: Text("Playback Settings")) {
            Toggle("Auto-Play Last Station", isOn: $autoPlayLastStation)
        }
    }

    private var displaySettingsSection: some View {
        Section(header: Text("Display Settings")) {
            Toggle("Dark Mode", isOn: $isDarkMode)
        }
    }

    private var streamFileUploadSection: some View {
        Section(header: Text("Stream File Upload").font(.headline).padding(.top)) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Select Country")
                        .font(.headline)
                        .foregroundColor(.primary)
                    StyledPickerView(selectedCountry: $viewModel.selectedCountry, countries: viewModel.countries)
                        .padding()
                        .background(Color(.systemGray5))
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                
                VStack(alignment: .leading) {
                    Text("File Import")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Button(action: {
                        if viewModel.selectedCountry == "Select Country" {
                            showAlertForCountrySelection = true
                        } else {
                            showDocumentPicker = true
                        }
                    }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text("Import Stations File")
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray5))
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                    .alert(isPresented: $showAlertForCountrySelection) {
                        Alert(
                            title: Text("Select a Country"),
                            message: Text("Please select a country from the country selector in the app before importing stations."),
                            dismissButton: .default(Text("OK"))
                        )
                    }
                    .sheet(isPresented: $showDocumentPicker) {
                        DocumentPicker { url in
                            isImporting = true  // Set import status to true
                            importProgress = 0.0  // Reset progress

                            viewModel.importStationsFromFile(url: url) { progress in
                                DispatchQueue.main.async {
                                    importProgress = progress
                                }
                            } completion: {
                                isImporting = false  // Set import status to false after import
                            }
                        }
                    }
                    
                    if isImporting {
                        VStack {
                            ProgressView(value: importProgress, total: 1.0) {
                                Text("Importing stations...")
                            }
                            .progressViewStyle(LinearProgressViewStyle())
                            .padding()
                            .background(Color(.systemGray5))
                            .cornerRadius(12)
                            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .listRowBackground(Color.clear)
    }

    private var dataManagementSection: some View {
        Section(header: Text("Data Management")) {
            Button("Delete All Data") {
                showingDeleteAlert = true
            }
            .alert(isPresented: $showingDeleteAlert) {
                Alert(
                    title: Text("Delete All Data"),
                    message: Text("Important: You're about to delete all station data. This will remove all your saved stations from both iCloud and your device's local storage. This action is permanent and cannot be reversed"),
                    primaryButton: .destructive(Text("Delete")) {
                        initiateDataDeletion()
                    },
                    secondaryButton: .cancel()
                )
            }

            if viewModel.isDeletingData {
                ProgressView("Deleting data...")
            } else if viewModel.deletionComplete {
                Text("All data has been deleted.")
                    .foregroundColor(.green)
            }

            deletionWarningText
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
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environmentObject(RadioStationViewModel())
    }
}
