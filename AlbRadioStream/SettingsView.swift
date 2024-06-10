// SettingsView.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false
    @AppStorage("isDarkMode") private var isDarkMode = false

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
        .onChange(of: isDarkMode) { oldValue, newValue in
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.first?.overrideUserInterfaceStyle = newValue ? .dark : .light
            }
        }
    }
}
