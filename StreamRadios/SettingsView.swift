// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @State private var showingPurchase = false
    @Environment(\.presentationMode) var presentationMode
    @State private var isImportExportViewPresented = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false // State to track deletion progress

    var body: some View {
        Form {
            Section(header: Text("Playback Settings")) {
                Toggle("Auto-Play Last Station", isOn: $autoPlayLastStation)
            }
            
            Section(header: Text("Display Settings")) {
                Toggle("Dark Mode", isOn: $isDarkMode)
            }
            
            Section(header: Text("Premium Features")) {
                Button("Enable Premium Features") {
                    showingPurchase = true
                }
            }
            
            Section(header: Text("Data Management")) {
                Button("Delete All Data") {
                    showingDeleteAlert = true
                }
                .foregroundColor(.red)
                .alert(isPresented: $showingDeleteAlert) {
                    Alert(
                        title: Text("Delete All Data"),
                        message: Text("This action will permanently delete all your data from CloudKit. This action cannot be undone. Are you sure you want to proceed?"),
                        primaryButton: .destructive(Text("Delete")) {
                            isDeleting = true // Start the deletion process
                            deleteAllDataFromCloudKit()
                        },
                        secondaryButton: .cancel()
                    )
                }

                if isDeleting {
                    ProgressView("Deleting data...")
                        .progressViewStyle(CircularProgressViewStyle())
                }

                Text("Caution: Deleting your data is irreversible and will result in loss of all stored information.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Settings")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
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
        }
        .onChange(of: isDarkMode) { newValue in
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
            }
            UserDefaults.standard.set(true, forKey: "isDarkModeSet") // Mark the setting as initialized
        }
        .sheet(isPresented: $showingPurchase) {
            PurchaseView(isPresented: $showingPurchase)
        }
    }

    private func deleteAllDataFromCloudKit() {
        DataStore.shared.deleteAllRecords(ofType: "streamingRadios") { success, error in
            DispatchQueue.main.async {
                isDeleting = false // End the deletion process
                if success {
                    print("All records were successfully deleted.")
                } else if let error = error {
                    print("Failed to delete records: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
