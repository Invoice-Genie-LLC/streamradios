//
//  SideMenuView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI

struct SideMenuView: View {
    @Binding var showSideMenu: Bool
    
    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                NavigationLink(destination: SettingsView().onAppear {
                    self.showSideMenu = false
                }) {
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
                
                NavigationLink(destination: AlarmConfigurationView().onAppear {
                    self.showSideMenu = false
                }) {
                    HStack {
                        Image(systemName: "alarm")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Program Alerts")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                }
                
                NavigationLink(destination: PodcastListView().environmentObject(PodcastViewModel())) {
                    HStack {
                        Image(systemName: "mic")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Podcasts")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 100)
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
        SideMenuView(showSideMenu: .constant(true))
    }
}
