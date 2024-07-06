//
//  DefaultStations.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/5/24.
//

import Foundation

struct DefaultStations {
    // Albania
    static func addDefaultStationsForAlbania(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Albania" }.map { $0.name })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.0)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Albania");            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Angola
    static func addDefaultStationsForAngola(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("tv.balkanweb.com:8081/news24/livestream/playlist.m3u8", "Angola Channel 1", "http://tv.balkanweb.com:8081/news24/livestream/playlist.m3u8"),
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Angola" }.map { $0.name })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.0)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Angola");            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Australia
    static func addDefaultStationsForAustralia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("abc.net.au/res/streaming/audionews_radio.pls", "Australia Channel 1", "http://www.abc.net.au/res/streaming/audio/mp3/news_radio.pls"),

        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Australia" }.map { $0.name })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.0)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Australia")
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }

    // Argentina
    static func addDefaultStationsForArgentina(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("tv.balkanweb.com:8081/news24/livestream/playlist.m3u8", "Argentina Channel 1", "http://tv.balkanweb.com:8081/news24/livestream/playlist.m3u8"),
                       
        ]
        let existingStations = Set(viewModel.stations.filter { $0.country == "Argentina" }.map { $0.name })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.0)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Argentina");            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    static func addAllDefaults(to viewModel: RadioStationViewModel) {
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForAngola(to: viewModel)
        addDefaultStationsForAustralia(to: viewModel)
        addDefaultStationsForArgentina(to: viewModel)
        // Add more calls here for other countries as you expand
    }
   
}



