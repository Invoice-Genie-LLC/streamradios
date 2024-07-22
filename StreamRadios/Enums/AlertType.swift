//
//  AlertType.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/22/24.
//

import Foundation

enum AlertType: Identifiable {
    case exportWithoutCountry
    case importWithoutCountry
    case deleteAllData
    
    var id: Int {
        switch self {
        case .exportWithoutCountry: return 0
        case .importWithoutCountry: return 1
        case .deleteAllData: return 2
        }
    }
}
