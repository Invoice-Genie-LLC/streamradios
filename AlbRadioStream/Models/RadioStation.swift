// RadioStation.swift
// AlbRadioStream
//
// Created by Kley Sulo on 6/9/24.
//

import Foundation

struct RadioStation: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var iconData: String?

    init(id: UUID = UUID(), name: String, url: String, iconData: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.iconData = iconData
    }
}

