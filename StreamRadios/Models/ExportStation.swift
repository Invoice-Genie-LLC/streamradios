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
    
    init(from station: RadioStation) {
        self.id = station.id
        self.name = station.name
        self.url = station.url
        self.country = station.country
        self.isFavorite = station.isFavorite
    }
}
