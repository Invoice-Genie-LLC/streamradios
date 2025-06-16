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
    var iTunesArtworkData: String? // Base64 encoded iTunes artwork
    var country: String = "Unknown Region"
    var isFavorite: Bool = false
    var favoritedAt: Date? // Timestamp when station was marked as favorite
    var favoriteOrder: Int? // Custom order for favorites list
    var lastPlayed: Date?
    var isRecent: Bool? = false
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case country
        case isFavorite
        case favoritedAt
        case favoriteOrder
        case iconData
        case iTunesArtworkData
        case lastPlayed
        case isRecent
    }
}



