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
    @StateObject private var notificationManager = NotificationManager.shared

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
        .onAppear {
                    if !UserDefaults.standard.bool(forKey: "NotificationAuthorizationRequested") {
                        notificationManager.requestAuthorization()
                        UserDefaults.standard.set(true, forKey: "NotificationAuthorizationRequested")
                    }
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
        Text("\n\n") // This adds two line breaks for paragraph separation
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
