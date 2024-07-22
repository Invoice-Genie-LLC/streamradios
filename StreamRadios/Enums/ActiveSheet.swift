//
//  ActiveSheet.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/22/24.
//

import Foundation

enum ActiveSheet: Identifiable {
    case addStation, editStation, playerSheet
    
    var id: Int {
        hashValue
    }
}
