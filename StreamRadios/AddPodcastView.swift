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
    @State private var iconImage: UIImage? = nil
    @State private var showImagePicker = false
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
                        // Placeholder to balance the HStack
                        Button(action: {}) {
                            Text("")
                                .foregroundColor(.clear)
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
                         
                        
                        Button(action: savePodcast) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Podcast")
                            }
                        }
                        .foregroundColor(.green)
                        .disabled(title.isEmpty || url.isEmpty)
                    }
                    .alert(isPresented: $showAlert) {
                        Alert(title: Text("Validation Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
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
    
    private func savePodcast() {
        guard !title.isEmpty else {
            alertMessage = "Podcast title is required."
            showAlert = true
            return
        }
        
        guard let url = URL(string: url), UIApplication.shared.canOpenURL(url) else {
            alertMessage = "Please enter a valid RSS Feed URL."
            showAlert = true
            return
        }

        onAdd()
        isPresented = false
    }
}

struct AddPodcastView_Previews: PreviewProvider {
    @State static var isPresented: Bool = true
    @State static var title: String = ""
    @State static var url: String = ""

    static var previews: some View {
        AddPodcastView(isPresented: $isPresented, title: $title, url: $url, onAdd: {
            print("Podcast added")
        })
        .environmentObject(PermissionManager())
    }
}
