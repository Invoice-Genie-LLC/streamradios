//
//  Tabs.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/29/24.
//

import Foundation

enum Tab: Int, CaseIterable {
    case radio = 0
    case podcast = 1
    case settings = 2
    
    var title: String {
        switch self {
        case .radio:
            return "FM Radio"
        case .podcast:
            return "Podcast"
        case .settings:
            return "Settings"
        }
    }
    
    var icon: String {
        switch self {
        case .radio:
            return "radio"
        case .podcast:
            return "mic.circle"
        case .settings:
            return "gearshape"
        }
    }
    
    // Legacy support for existing code
    static let all = radio
    static let favorites = radio
    static let recent = radio
}
