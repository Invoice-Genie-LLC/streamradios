//
//  PlaybackManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 9/10/24.
//

import SwiftUI

enum ActivePlayer {
    case radio
    case podcast
}

class PlaybackManager {
    static let shared = PlaybackManager()
    
    @Published var activePlayer: ActivePlayer = .radio
    
    private init() {}
    
    func setActivePlayer(_ player: ActivePlayer) {
        activePlayer = player
    }
}
