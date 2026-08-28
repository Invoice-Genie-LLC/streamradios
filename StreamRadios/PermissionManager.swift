//
//  PermissionManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/1/24.
//

import Foundation
import Photos
import AVFoundation
import UIKit
import Combine

class PermissionManager: ObservableObject {
    
    @Published var isPermissionAlertPresented = false
    @Published var alertMessage = ""
    
    var permissionStatus = PassthroughSubject<Bool, Never>()
    
    func checkPhotoLibraryPermission(completion: @escaping () -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            DispatchQueue.main.async {
                completion()
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        completion()
                    } else {
                        self.alertMessage = "Access to the photo library was denied. You can enable access in Settings."
                        self.isPermissionAlertPresented = true
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.alertMessage = "Access to the photo library is restricted or was denied. You can enable access in Settings."
                self.isPermissionAlertPresented = true
            }
        @unknown default:
            DispatchQueue.main.async {
                self.alertMessage = "An unknown error occurred. Please check your settings."
                self.isPermissionAlertPresented = true
            }
        }
    }
    
    func openAppSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}
