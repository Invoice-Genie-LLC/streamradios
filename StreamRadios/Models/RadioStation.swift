// RadioStation.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import Foundation

struct RadioStation: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var iconData: String?
    var country: String = "Unknown Region"
    var isFavorite: Bool = false
    var lastPlayed: Date?
    var isRecent: Bool? = false
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case country
        case isFavorite
        case iconData
        case lastPlayed
        case isRecent
    }
}



