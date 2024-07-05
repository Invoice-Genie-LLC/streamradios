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
        let existingStationNames = Set(viewModel.stations.filter { $0.country == "Albania" }.map { $0.name })
        let newStations = [
            ("OraNews", "https://radio.oranews.tv:8443/stream"),
            ("Love Radio", "https://radio.albanialoveradio.al/stream"),
            ("Beatfm.al", "http://streaming.ihost.al:8010"),
            ("City Radio", "https://cp1.sednastream.com/proxy/cityradio?mp=%2Fstream"),
            ("Radio One", "https://cp1.sednastream.com/proxy/radioone94?mp=%2Fstream"),
            ("Klan Radio", "https://klanradio.tvklan.al/live/klanmusicradio1/playlist.m3u8"),
            ("Radio Tirana 1", "http://79.106.48.2:8000/radiotirana1"),
            ("Radio Tirana 2", "http://79.106.48.2:8000/radiotirana2"),
            ("Radio Tirana Classic", "http://79.106.48.2:8000/radiotiranaklasik1"),
            ("Radio Tirana Femije", "http://79.106.48.2:8000/radiotiranafemije"),
            ("Radio Emigranti", "http://radioemigranti.com:8000/radio128k"),
            ("Club FM Radio", "https://cp1.sednastream.com/proxy/clubfm?mp=/stream"),
            ("Top Albania Radio", "https://live.top-media.al/tar"),
            ("Top Gold Radio", "https://live.topgold.al/topgold"),
            ("My Music Radio", "https://live.top-media.al/mmr"),
            ("Radio Emanuel", "http://185.221.253.173:7800"),
            ("Radio Shqip", "https://cp1.sednastream.com/proxy/radioshqip?mp=%2F%3Bstream.mp3"),
        ].filter { !existingStationNames.contains($0.0) }
        .map { (name, url) -> RadioStation in
            let iconData = viewModel.loadImageData(named: name)
            return RadioStation(name: name, url: url, iconData: iconData, country: "Albania")
        }
        
        if !newStations.isEmpty {
            viewModel.stations.append(contentsOf: newStations)
            viewModel.saveStationsToFile()
        }
    }
    
    // Angola
    static func addDefaultStationsForAngola(to viewModel: RadioStationViewModel) {
        let existingStationNames = Set(viewModel.stations.filter { $0.country == "Angola" }.map { $0.name })
        let newStations = [
            ("Radio MFM", "https://centova87.instainternet.com/proxy/mfm?mp=/stream"),
        ].filter { !existingStationNames.contains($0.0) }
        .map { (name, url) -> RadioStation in
            let iconData = viewModel.loadImageData(named: name)
            return RadioStation(name: name, url: url, iconData: iconData, country: "Angola")
        }
        
        if !newStations.isEmpty {
            viewModel.stations.append(contentsOf: newStations)
            viewModel.saveStationsToFile()
        }
    }
    // Argentina
    static func addDefaultStationsForArgentina(to viewModel: RadioStationViewModel) {
        let existingStationNames = Set(viewModel.stations.filter { $0.country == "Argentina" }.map { $0.name })
        let newStations = [
            ("Blue FM", "https://19793.live.streamtheworld.com/BLUE_FM_100_7AAC_SC?pname=TDSdk"),
            ("Radio 10", "https://frontend.radiohdvivo.com/radio10/live"),
            ("Pop FM", "https://edge01.radiohdvivo.com/stream/popradio"),
            ("El Observador", "https://s8.stweb.tv/observador/live/playlist.m3u8"),
            ("Radio One Argentina", "https://s8.stweb.tv/one/live/playlist.m3u8"),
            ("La Popu FM", "https://27573.live.streamtheworld.com/LAPOPU_SC?dist=c3-web")
        ].filter { !existingStationNames.contains($0.0) }
        .map { (name, url) -> RadioStation in
            let iconData = viewModel.loadImageData(named: name)
            return RadioStation(name: name, url: url, iconData: iconData, country: "Argentina")
        }
        
        if !newStations.isEmpty {
            viewModel.stations.append(contentsOf: newStations)
            viewModel.saveStationsToFile()
        }
    }
}

