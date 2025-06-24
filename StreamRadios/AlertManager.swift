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
        
        customAlertTitle = alertType.title
        customAlertMessage = alertType.message
        customAlertPrimaryButtonText = alertType.primaryButtonText
        customAlertSecondaryButtonText = alertType.secondaryButtonText
        
        switch alertType {
        case .selectCountryBeforeAddingStation, .exportWithoutCountry, .importWithoutCountry, .deleteStationError:
            customAlertPrimaryAction = { [weak self] in
                self?.dismissAlert()
            }
            customAlertSecondaryAction = nil
        case .deleteAllData, .deleteStation, .clearAllPodcasts, .deleteAllAppData:
            customAlertPrimaryAction = deleteAction
            customAlertSecondaryAction = { [weak self] in
                self?.dismissAlert()
            }
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
    case clearAllPodcasts
    case deleteAllAppData
    
    var id: Int {
        switch self {
        case .exportWithoutCountry: return 0
        case .importWithoutCountry: return 1
        case .deleteAllData: return 2
        case .selectCountryBeforeAddingStation: return 3
        case .deleteStation: return 4
        case .deleteStationError: return 5
        case .clearAllPodcasts: return 6
        case .deleteAllAppData: return 7
        }
    }
    
    var title: String {
        switch self {
        case .exportWithoutCountry, .importWithoutCountry, .selectCountryBeforeAddingStation:
            return "Select a Country"
        case .deleteAllData:
            return "Delete All Data"
        case .deleteStation:
            return "Delete Station"
        case .deleteStationError:
            return "Error"
        case .clearAllPodcasts:
            return "Clear All Podcast Episodes"
        case .deleteAllAppData:
            return "Delete All App Data"
        }
    }
    
    var message: String {
        switch self {
        case .exportWithoutCountry:
            return "Please select a country from the country selector in the app before exporting stations."
        case .importWithoutCountry:
            return "Please select a country from the country selector in the app before importing stations."
        case .deleteAllData:
            return "Important: You're about to delete all station playlist data. This will remove all your saved playlists from both iCloud and your device's local storage. This action is permanent and cannot be reversed."
        case .selectCountryBeforeAddingStation:
            return "Please select a country before creating a new station."
        case .deleteStation:
            return "Are you sure you want to delete this station? This action cannot be undone."
        case .deleteStationError:
            return "Failed to delete the station. Please try again later."
        case .clearAllPodcasts:
            return "Are you sure you want to clear all podcast episodes? This will erase all downloaded episodes and their progress. This action cannot be undone."
        case .deleteAllAppData:
            return "Important: You're about to delete ALL app data. This will remove all stations, podcasts, downloads, progress, favorites, and settings from both iCloud and your device's local storage. This action is permanent and cannot be reversed."
        }
    }
    
    var primaryButtonText: String {
        switch self {
        case .exportWithoutCountry, .importWithoutCountry, .selectCountryBeforeAddingStation, .deleteStationError:
            return "OK"
        case .deleteAllData, .deleteStation, .clearAllPodcasts, .deleteAllAppData:
            return "Delete"
        }
    }
    
    var secondaryButtonText: String? {
        switch self {
        case .deleteAllData, .deleteStation, .clearAllPodcasts, .deleteAllAppData:
            return "Cancel"
        default:
            return nil
        }
    }
}
