//
//  SideMenuView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SideMenuView: View {
    var body: some View {
        VStack(alignment: .leading) {
            VStack {
                NavigationLink(destination: SettingsView()) {
                    HStack {
                        Image(systemName: "gear")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Settings")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                }
            }.padding(.top, 100)
            Spacer()

            // Footer
            VStack(alignment: .leading) {
                Text("Copyright StreamRadios")
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
    
struct SideMenuView_Previews: PreviewProvider {
    static var previews: some View {
        SideMenuView()
    }
}
