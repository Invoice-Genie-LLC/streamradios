//
//  MusicAuthorizationManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/5/24.
//

import Foundation
import MusicKit

class MusicAuthorizationManager: ObservableObject {
    @Published var authorizationStatus: MusicAuthorization.Status = .notDetermined
    
    // Singleton instance
    static let shared = MusicAuthorizationManager()
    
    private init() {}
    
    // Requests authorization to access the Apple Music library.
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
    }
    
    // Checks if the app is authorized to access the Apple Music library.
    func isAuthorized() -> Bool {
        return authorizationStatus == .authorized
    }
}
