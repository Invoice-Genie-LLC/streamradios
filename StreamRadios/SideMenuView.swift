//
//  SideMenuView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

// SideMenuView.swift

import SwiftUI

struct SideMenuView: View {
    var body: some View {
        VStack(alignment: .leading) {
            VStack {
                Text("Demo Item 1")
                    .font(.headline)
                    .padding(.top, 40)
                    .padding(.horizontal, 20)
                Text("Demo Item 2")
                    .font(.headline)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                Text("Demo Item 3")
                    .font(.headline)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                NavigationLink(destination: SettingsView()) {
                    HStack {
                        Image(systemName: "gear")
                            .font(.headline)
                        Text("Settings")
                            .font(.headline)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                }
            }.padding(.top, 100)
            Spacer()

            // Footer
            VStack(alignment: .leading) {
                Text("Copyright AlbRadio Streaming")
                    .font(.footnote)
                    .padding(.horizontal, 20)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.footnote)
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .edgesIgnoringSafeArea(.all)
    }
}
    
