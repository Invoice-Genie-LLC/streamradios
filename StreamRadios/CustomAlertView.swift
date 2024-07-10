//
//  CustomAlertView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/10/24.
//

import SwiftUI

struct CustomAlertView: View {
    var title: String
    var message: String
    var buttonText: String
    var buttonAction: () -> Void
    
    var body: some View {
        VStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.top, 20)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding([.leading, .trailing, .bottom], 20)
            
            Button(action: buttonAction) {
                Text(buttonText)
                    .fontWeight(.bold)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding([.leading, .trailing], 20)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 300)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 40)
    }
}

struct CustomAlertView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CustomAlertView(title: "Error", message: "This is an error message.", buttonText: "OK", buttonAction: {})
                .preferredColorScheme(.light)
            
            CustomAlertView(title: "Error", message: "This is an error message.", buttonText: "OK", buttonAction: {})
                .preferredColorScheme(.dark)
        }
    }
}
