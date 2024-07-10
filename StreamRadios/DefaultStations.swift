//
//  DefaultStations.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/5/24.
//

import Foundation
import SwiftUI

struct DefaultStations {
    // Albania
    static func addDefaultStationsForAlbania(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("1live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            ("2live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Albania" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Albania");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Angola
    static func addDefaultStationsForAngola(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("1live.top-media.al/tar1", "Top Albania Radio", "https://live.top-media.al/tar"),
            ("2live.top-media.al/tar2", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Angola" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Angola");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Australia
    static func addDefaultStationsForAustralia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("1live.top-media.al1/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            ("2live.top-media.al2/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Australia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Australia")
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Argentina
    static func addDefaultStationsForArgentina(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("1live.top1-media.al/tar", "Top1 Albania Radio", "https://live.top-media.al/tar"),
            ("2live.to2p-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            

        ]
        let existingStations = Set(viewModel.stations.filter { $0.country == "Argentina" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Argentina");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    @StateObject private var viewModel = RadioStationViewModel()
    static func addAllDefaults(to viewModel: RadioStationViewModel) {
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForAngola(to: viewModel)
        addDefaultStationsForAustralia(to: viewModel)
        addDefaultStationsForArgentina(to: viewModel)
    }
}



