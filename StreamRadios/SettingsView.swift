// SettingsView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode = false
    
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
        }
        .navigationTitle("Settings")
        .navigationBarBackButtonHidden(true) // Hide default back button
        .toolbar { // Add a custom toolbar item for the back button
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    // Action to pop the view
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.primary)
                        Text("Back")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .onChange(of: isDarkMode) { newValue in
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
