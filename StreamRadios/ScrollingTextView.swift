// ScrollingTextView.swift
// StreamRadios
//
// Created by Kley Sulo on 6/8/24.
//

import SwiftUI

struct ScrollingTextView: View {
    let text: String
    let metadata: String?
    @State private var offset: CGFloat = 0
    var scrollSpeed: Double
    var frequency: Double
    var isScrollingEnabled: Bool

    var body: some View {
        let displayText = metadata ?? text

        GeometryReader { geometry in
            if isScrollingEnabled {
                Text(displayText)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(Color(UIColor.systemGray).opacity(0.9))
                    .offset(x: offset)
                    .onAppear {
                        startScrolling(textWidth: displayText.width(usingFont: .systemFont(ofSize: 17)), screenWidth: geometry.size.width)
                    }
                    .onChange(of: metadata) { _ in
                        offset = geometry.size.width
                        startScrolling(textWidth: displayText.width(usingFont: .systemFont(ofSize: 17)), screenWidth: geometry.size.width)
                    }
            } else {
                Text(displayText)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(Color(UIColor.systemGray).opacity(0.9))
            }
        }
        .frame(height: 30)
        .clipped()
    }

    private func startScrolling(textWidth: CGFloat, screenWidth: CGFloat) {
        let totalWidth = textWidth + screenWidth
        let duration = totalWidth / scrollSpeed

        withAnimation(Animation.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = screenWidth
        }
    }
}

extension String {
    func width(usingFont font: UIFont) -> CGFloat {
        let attributes = [NSAttributedString.Key.font: font]
        let size = self.size(withAttributes: attributes)
        return size.width
    }
}
