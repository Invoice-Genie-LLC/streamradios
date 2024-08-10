//
//  AudioPlayerProtocol.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/9/24.
//

import Foundation

protocol AudioPlayerProtocol: AnyObject {
    var isPlaying: Bool { get }
    func play()
    func pause()
}
