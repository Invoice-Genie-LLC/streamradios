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
    var order: Int = 0 // Order for stations in the All tab
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
        case order
        case iconData
        case iTunesArtworkData
        case lastPlayed
        case isRecent
    }
    
    // Standard memberwise initializer
    init(id: String, name: String, url: String, iconData: String? = nil, iTunesArtworkData: String? = nil, country: String = "Unknown Region", isFavorite: Bool = false, favoritedAt: Date? = nil, favoriteOrder: Int? = nil, order: Int = 0, lastPlayed: Date? = nil, isRecent: Bool? = false) {
        self.id = id
        self.name = name
        self.url = url
        self.iconData = iconData
        self.iTunesArtworkData = iTunesArtworkData
        self.country = country
        self.isFavorite = isFavorite
        self.favoritedAt = favoritedAt
        self.favoriteOrder = favoriteOrder
        self.order = order
        self.lastPlayed = lastPlayed
        self.isRecent = isRecent
    }
    
    // Custom decoder to handle missing optional fields with defaults
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Required fields
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        
        // Optional fields with defaults
        country = try container.decodeIfPresent(String.self, forKey: .country) ?? "Unknown Region"
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isRecent = try container.decodeIfPresent(Bool.self, forKey: .isRecent) ?? false
        
        // Fully optional fields
        iconData = try container.decodeIfPresent(String.self, forKey: .iconData)
        iTunesArtworkData = try container.decodeIfPresent(String.self, forKey: .iTunesArtworkData)
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
        favoriteOrder = try container.decodeIfPresent(Int.self, forKey: .favoriteOrder)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }
}



