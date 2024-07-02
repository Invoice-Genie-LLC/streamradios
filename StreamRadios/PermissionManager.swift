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
            completion()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        completion()
                    } else {
                        self.isPermissionAlertPresented = true
                        self.alertMessage = "Access to the photo library was denied. You can enable access in Settings."
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.isPermissionAlertPresented = true
                self.alertMessage = "Access to the photo library is restricted or was denied. You can enable access in Settings."
            }
        @unknown default:
            break
        }
    }
    
    func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        completion(true)
                    } else {
                        self.alertMessage = "Microphone access is needed to identify songs via Shazam. You can enable access in Settings."
                        self.isPermissionAlertPresented = true
                        completion(false)
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.alertMessage = "Microphone access is restricted or was denied. You can enable access in Settings."
                self.isPermissionAlertPresented = true
                completion(false)
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false)
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
