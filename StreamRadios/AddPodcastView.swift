//
//  AddPodcastView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import SwiftUI

struct AddPodcastView: View {
    @Binding var isPresented: Bool
    @Binding var title: String
    @Binding var url: String
    @State private var showAlert = false
    @State private var alertMessage: String = ""
    @EnvironmentObject var permissionManager: PermissionManager
    
    let onAdd: () -> Void

    var body: some View {
        ZStack {
            NavigationView {
                VStack {
                    HStack {
                        Button(action: {
                            isPresented = false
                        }) {
                            Text("Cancel")
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        Text("Add Podcast")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: validateAndSavePodcast) {
                            Text("Add")
                                .foregroundColor(.green)
                        }
                    }
                    .padding()
                    Divider()
                    
                    Form {
                        Section(header: Text("Podcast Details")) {
                            HStack {
                                TextField("Podcast Title", text: $title)
                                    .onChange(of: title) { newValue in
                                        if newValue.count >= 40 {
                                            title = String(newValue.prefix(40))
                                        }
                                    }
                                if !title.isEmpty {
                                    Button(action: {
                                        title = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                            
                            HStack {
                                TextField("RSS Feed URL", text: $url)
                                if !url.isEmpty {
                                    Button(action: {
                                        url = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                        }
                    }
                }
                .navigationBarHidden(true) // Hide the default navigation bar
            }
            if showAlert {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                CustomAlertView(title: "Validation Error", message: alertMessage, buttonText: "OK") {
                    self.showAlert = false
                }
                .transition(.opacity)
            }
        }
    }
    
    private func validateAndSavePodcast() {
        // Validate title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Please enter a podcast title."
            showAlert = true
            return
        }
        
        // Validate URL
        guard let url = URL(string: self.url),
              UIApplication.shared.canOpenURL(url),
              url.scheme == "http" || url.scheme == "https" else {
            alertMessage = "Please enter a valid RSS Feed URL (must start with http:// or https://)."
            showAlert = true
            return
        }

        onAdd()
        isPresented = false
    }
}

struct AddPodcastView_Previews: PreviewProvider {
    static var previews: some View {
        AddPodcastView(isPresented: .constant(true), title: .constant(""), url: .constant(""), onAdd: {
            print("Podcast added")
        })
        .environmentObject(PermissionManager())
    }
}
