// AlertManager.swift
// StreamRadios
//
// Created by Kley Sulo on 7/22/24.
//

import Foundation
import SwiftUI

class AlertManager: ObservableObject {
    @Published var showCustomAlert = false
    @Published var customAlertTitle = ""
    @Published var customAlertMessage = ""
    @Published var customAlertPrimaryButtonText = ""
    @Published var customAlertPrimaryAction: (() -> Void)?
    @Published var customAlertSecondaryButtonText: String?
    @Published var customAlertSecondaryAction: (() -> Void)?
    @Published private(set) var currentAlertType: AlertType?
    
    func showCustomAlert(for alertType: AlertType, deleteAction: (() -> Void)? = nil) {
        guard currentAlertType != alertType else { return }
        
        currentAlertType = alertType
        
        switch alertType {
        case .selectCountryBeforeAddingStation:
            customAlertTitle = "Select a Country"
            customAlertMessage = "Please select a country before creating a new station."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = { [weak self] in
                self?.dismissAlert()
            }
            customAlertSecondaryButtonText = nil
        case .exportWithoutCountry:
            customAlertTitle = "Select a Country"
            customAlertMessage = "Please select a country from the country selector in the app before exporting stations."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = nil
            customAlertSecondaryButtonText = nil
            customAlertSecondaryAction = nil
        case .importWithoutCountry:
            customAlertTitle = "Select a Country"
            customAlertMessage = "Please select a country from the country selector in the app before importing stations."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = nil
            customAlertSecondaryButtonText = nil
            customAlertSecondaryAction = nil
        case .deleteAllData:
            customAlertTitle = "Delete All Data"
            customAlertMessage = "Important: You're about to delete all station playlist data. This will remove all your saved playlists from both iCloud and your device's local storage. This action is permanent and cannot be reversed."
            customAlertPrimaryButtonText = "Delete"
            customAlertPrimaryAction = deleteAction
            customAlertSecondaryButtonText = "Cancel"
            customAlertSecondaryAction = nil
        case .deleteStation:
            customAlertTitle = "Delete Station"
            customAlertMessage = "Are you sure you want to delete this station? This action cannot be undone."
            customAlertPrimaryButtonText = "Delete"
            customAlertPrimaryAction = deleteAction
            customAlertSecondaryButtonText = "Cancel"
            customAlertSecondaryAction = nil
        case .deleteStationError:
            customAlertTitle = "Error"
            customAlertMessage = "Failed to delete the station. Please try again later."
            customAlertPrimaryButtonText = "OK"
            customAlertPrimaryAction = nil
            customAlertSecondaryButtonText = nil
            customAlertSecondaryAction = nil
        }
        
        showCustomAlert = true
    }
    
    func dismissAlert() {
        showCustomAlert = false
        currentAlertType = nil
        customAlertTitle = ""
        customAlertMessage = ""
        customAlertPrimaryButtonText = ""
        customAlertSecondaryButtonText = nil
        customAlertSecondaryAction = nil
    }
}

enum AlertType: Identifiable {
    case exportWithoutCountry
    case importWithoutCountry
    case deleteAllData
    case selectCountryBeforeAddingStation
    case deleteStation
    case deleteStationError
    
    var id: Int {
        switch self {
        case .exportWithoutCountry: return 0
        case .importWithoutCountry: return 1
        case .deleteAllData: return 2
        case .selectCountryBeforeAddingStation: return 3
        case .deleteStation: return 4
        case .deleteStationError: return 5
        }
    }
}
