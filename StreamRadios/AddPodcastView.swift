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
    let onAdd: () -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Podcast Details")) {
                    TextField("Podcast Title", text: $title)
                    TextField("RSS Feed URL", text: $url)
                }
                
                Section {
                    Button("Add Podcast") {
                        onAdd()
                    }
                    .disabled(title.isEmpty || url.isEmpty)
                }
            }
            .navigationTitle("Add Podcast")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
}
