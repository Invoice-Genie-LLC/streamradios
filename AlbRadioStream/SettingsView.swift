
// SettingsView.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayLastStation") private var autoPlayLastStation = false

    var body: some View {
        Form {
            Toggle("Auto-Play Last Station", isOn: $autoPlayLastStation)
        }
        .navigationTitle("Settings")
    }
}
