//
//  ExportStation.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/20/24.
//

import Foundation

struct ExportStation: Codable {
    let id: String
    let name: String
    let url: String
    let country: String
    let isFavorite: Bool
    let iconData: String?
    let iTunesArtworkData: String?
    
    init(from station: RadioStation, includeImages: Bool = false) {
        self.id = station.id
        self.name = station.name
        self.url = station.url
        self.country = station.country
        self.isFavorite = station.isFavorite
        
        if includeImages {
            self.iconData = station.iconData
            self.iTunesArtworkData = station.iTunesArtworkData
        } else {
            self.iconData = nil
            self.iTunesArtworkData = nil
        }
    }
}
