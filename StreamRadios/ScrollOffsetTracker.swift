//
//  ScrollOffsetTracker.swift
//  StreamRadios
//
//  Created by Kley Sulo on 10/3/24.
//

import Foundation
import SwiftUI


struct ScrollOffsetTracker: ViewModifier {
    let coordinateSpace: String
    @Binding var offset: CGPoint

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named(coordinateSpace)).origin)
                }
            )
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                offset = value
            }
    }
}

extension View {
    func trackScrollOffset(coordinateSpace: String, offset: Binding<CGPoint>) -> some View {
        modifier(ScrollOffsetTracker(coordinateSpace: coordinateSpace, offset: offset))
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}


struct ViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
