//
//  ExportStation.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/20/24.
//

import Foundation

struct ExportStation: Encodable {
    var id: String
    var name: String
    var url: String
    var country: String
    var isFavorite: Bool
    
    init(from station: RadioStation) {
        self.id = station.id
        self.name = station.name
        self.url = station.url
        self.country = station.country
        self.isFavorite = station.isFavorite
    }

    var jsonString: String {
        let idString = "\"id\": \"\(id)\""
        let nameString = "\"name\": \"\(name)\""
        let urlString = "\"url\": \"\(url)\""
        let countryString = "\"country\": \"\(country)\""
        let favoriteString = "\"isFavorite\": \(isFavorite ? "true" : "false")"

        return "{\(idString), \(nameString), \(urlString), \(countryString), \(favoriteString)}"
    }
}
