//
//  CircularProgressView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/10/24.
//

import SwiftUI

struct CircularProgressView: View {
    @State private var isAnimating = false
    
    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.7)
            .stroke(AngularGradient(gradient: .init(colors: [.primary, .gray]), center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
            .frame(width: 60, height: 60)
            .onAppear {
                withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
            .onDisappear {
                isAnimating = false
            }
    }
}

struct CircularProgressView_Previews: PreviewProvider {
    static var previews: some View {
        CircularProgressView()
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
