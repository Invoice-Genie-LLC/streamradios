//
//  NeumorphicShadow.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/26/24.
//

import SwiftUI

struct NeumorphicShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 2, y: 2)
            .shadow(color: Color.white.opacity(0.3), radius: 2, x: -2, y: -2)
    }
}

