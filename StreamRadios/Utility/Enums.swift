//
//  Enums.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import Foundation

enum CellType {
    case basic, toggle, titleLeftSubtitleRight
}

enum ErrorStatus : Error {
    case noDataAvailable
    case cannotProcessdata
}

enum ButtonType {
    case settings, save, list
}

enum ToggleType: String {
    case saveAllSongs = "autoSaveAllSongs"
    case addToAppleMusic = "autoAddToAppleMusic"
    case addToShazam = "autoaddToShazam"
    case partyMode = "partyModeForBackgroundMusicDetection"
}
