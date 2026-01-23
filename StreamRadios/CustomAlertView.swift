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
    var secondaryButtonText: String?
    var secondaryButtonAction: (() -> Void)?
    var isDestructive: Bool = false
    
    @Environment(\.colorScheme) var colorScheme
    
    // Determine if this is a destructive action based on button text
    private var isDestructiveAction: Bool {
        isDestructive || buttonText.lowercased().contains("delete") || buttonText.lowercased().contains("remove") || buttonText.lowercased().contains("clear")
    }
    
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
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .background(isDestructiveAction ? Color.red : Color.accentColor)
            .cornerRadius(10)
            .contentShape(Rectangle())
            .padding([.leading, .trailing], 20)
            
            if let secondaryButtonText = secondaryButtonText,
               let secondaryButtonAction = secondaryButtonAction {
                Button(action: secondaryButtonAction) {
                    Text(secondaryButtonText)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(10)
                .contentShape(Rectangle())
                .padding([.leading, .trailing], 20)
            }
            
            Spacer().frame(height: 20)
        }
        .frame(width: 300)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, 40)
    }
}

struct CustomAlertView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CustomAlertView(
                title: "Error",
                message: "This is an error message.",
                buttonText: "OK",
                buttonAction: {},
                secondaryButtonText: "Cancel",
                secondaryButtonAction: {}
            )
            .preferredColorScheme(.light)
            
            CustomAlertView(
                title: "Error",
                message: "This is an error message.",
                buttonText: "OK",
                buttonAction: {}
            )
            .preferredColorScheme(.dark)
        }
    }
}
