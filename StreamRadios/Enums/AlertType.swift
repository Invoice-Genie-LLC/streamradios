//
//  AlertType.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/22/24.
//

import Foundation

enum AlertType: Identifiable {
    case exportWithoutCountry, importWithoutCountry, deleteAllData

    var id: Int {
        hashValue
    }
}
