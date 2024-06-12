//
//  withoutAnimation.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/11/24.
//

import SwiftUI

extension View {
    func withoutAnimation() -> some View {
        self.transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}
