// RadioStation.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import Foundation

struct RadioStation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var iconData: String?
}

