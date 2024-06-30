// RadioStation.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import Foundation

struct RadioStation: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var iconData: String?
    var isFavorite: Bool = false
    var lastPlayed: Date?
    var isRecent: Bool = false  // Add this line to track the most recent plays

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case iconData
        case isFavorite
        case lastPlayed
        case isRecent  // Add this line
    }
}
