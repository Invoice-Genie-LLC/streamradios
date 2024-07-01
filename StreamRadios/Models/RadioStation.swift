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


struct Podcast: Codable, Identifiable {
    let id: UUID
    let title: String
    let episodes: [Episode]

    // Explicit initializer accepting an 'id'
    init(id: UUID = UUID(), title: String, episodes: [Episode]) {
        self.id = id
        self.title = title
        self.episodes = episodes
    }
}

struct Episode: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let audioURL: URL?

    // You can manually implement the Equatable conformance if needed, but often,
    // for simple struct like this, Swift can automatically provide conformance.
    // Here's how you might implement it manually:
    static func ==(lhs: Episode, rhs: Episode) -> Bool {
        return lhs.id == rhs.id // Typically comparison by 'id' is sufficient
    }
}
