//
//  KeyboardObserver.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine

final class KeyboardObserver: ObservableObject {
    @Published var keyboardHeight: CGFloat = 0

    private var cancellableSet: Set<AnyCancellable> = []

    init() {
        let willChangeFramePublisher = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        let willHidePublisher = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)

        willChangeFramePublisher
            .merge(with: willHidePublisher)
            .compactMap { notification in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .map { height -> CGFloat in
                let bottomSafeAreaInset = self.getBottomSafeAreaInset()
                return height == 0 ? 0 : height - bottomSafeAreaInset
            }
            .assign(to: \.keyboardHeight, on: self)
            .store(in: &cancellableSet)
    }

    private func getBottomSafeAreaInset() -> CGFloat {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return 0
        }
        return window.safeAreaInsets.bottom
    }

    deinit {
        cancellableSet.forEach { $0.cancel() }
    }
}
