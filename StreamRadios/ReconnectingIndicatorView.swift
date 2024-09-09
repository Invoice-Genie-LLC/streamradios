//
//  ReconnectingIndicatorView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 9/9/24.
//

import SwiftUI

struct ReconnectingIndicatorView: View {
    @Binding var isAttemptingReconnection: Bool
    
    var body: some View {
        Group {
            if isAttemptingReconnection {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    Text("Reconnecting...")
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
        }
    }
}
