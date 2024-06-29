//
//  AppleMusicManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/28/24.
//

import StoreKit

class AppleMusicManager {
    static let shared = AppleMusicManager()
    
    func requestAppleMusicAuthorization(completion: @escaping (Bool) -> Void) {
        let authorizationStatus = SKCloudServiceController.authorizationStatus()
        
        switch authorizationStatus {
        case .notDetermined:
            SKCloudServiceController.requestAuthorization { status in
                DispatchQueue.main.async {
                    switch status {
                    case .authorized:
                        print("Apple Music authorization granted")
                        completion(true)
                    case .denied, .restricted, .notDetermined:
                        print("Apple Music authorization denied or not determined")
                        completion(false)
                    @unknown default:
                        print("Unknown Apple Music authorization status")
                        completion(false)
                    }
                }
            }
        case .authorized:
            print("Apple Music already authorized")
            completion(true)
        case .denied, .restricted:
            print("Apple Music authorization denied or restricted")
            completion(false)
        @unknown default:
            print("Unknown Apple Music authorization status")
            completion(false)
        }
    }
}
