//
//  RadioStation.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import Foundation

struct RadioStation: Identifiable, Codable {
    let id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}
