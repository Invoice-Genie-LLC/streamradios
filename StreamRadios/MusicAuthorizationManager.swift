//
//  MusicAuthorizationManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/5/24.
//

// MusicAuthorizationManager.swift

import Foundation
import MusicKit

class MusicAuthorizationManager: ObservableObject {
    @Published var authorizationStatus: MusicAuthorization.Status = .notDetermined
    
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
    }
    
    func isAuthorized() -> Bool {
        return authorizationStatus == .authorized
    }
}
