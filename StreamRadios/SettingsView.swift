// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    // Ensure dark mode is on by default for new installs
    @AppStorage("isDarkMode") private var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkModeSet") ? UserDefaults.standard.bool(forKey: "isDarkMode") : true
    @State private var showingPurchase = false
    @Environment(\.presentationMode) var presentationMode
    @State private var isImportExportViewPresented = false

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
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
