// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @State private var showingPurchase = false
    @Environment(\.presentationMode) var presentationMode
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var deletionComplete = false
    @EnvironmentObject var viewModel: RadioStationViewModel

    var body: some View {
        Form {
            
            playbackSettingsSection
            displaySettingsSection
            premiumFeaturesSection
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
        .sheet(isPresented: $showingPurchase) {
            PurchaseView(isPresented: $showingPurchase)
        }
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

    private var premiumFeaturesSection: some View {
        Section(header: Text("Premium Features")) {
            Button("Enable Premium Features") {
                showingPurchase = true
            }
        }
    }
    
    

    private var dataManagementSection: some View {
        Section(header: Text("Data Management")) {
            Button("Delete All Data") {
                showingDeleteAlert = true
                
            }
            .alert(isPresented: $showingDeleteAlert) {
                Alert(
                    title: Text("Delete All Data"),
                    message: Text("This action will permanently delete all your data from CloudKit. This action cannot be undone. Are you sure you want to proceed?"),
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
        Text("Deleting your data is permanent and will erase all stored stations and their associated data from iCloud and your phone local storage. Please keep the app open and remain on this screen until the deletion is fully completed. The duration of this operation may vary, but it could take up to 10 minutes depending on the number of stations configured.")
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
            // Notify user to wait if CloudKit operation is in progress
            BackgroundTaskManager.shared.scheduleCompletionNotification(message: "CloudKit operation in progress. Please wait before deleting data.")
        } else {
            viewModel.deleteAllData { success, error in
                if success {
                    print("Deletion was successful.")
                    self.deletionComplete = true
                } else if let error = error {
                    print("Deletion failed: \(error.localizedDescription)")
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
