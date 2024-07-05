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
    // Australia
    static func addDefaultStationsForAustralia(to viewModel: RadioStationViewModel) {
        let existingStationNames = Set(viewModel.stations.filter { $0.country == "Australia" }.map { $0.name })
        let newStations = [
            ("ABC NewsRadio MP3", "http://www.abc.net.au/res/streaming/audio/mp3/news_radio.pls"),
            ("ABC News Radio", "http://www.abc.net.au/res/streaming/audio/aac/news_radio.pls"),
            ("Kiss FM 87.6, 87.8 & 88.0 Melbourne, VIC", "http://cc.net2streams.com:8565/kissfm.mp3"),
            ("ABC Radio National AAC+", "http://www.abc.net.au/res/streaming/audio/aac/radio_national.pls"),
            ("ABC Country (MP3)", "http://live-radio01.mediahubaustralia.com/CTRW/mp3/;*.mp3"),
            ("The Prog Rock Machine", "https://theproganrockmachine.out.airtime.pro/theproganrockmachine_b"),
            ("ABC Jazz (AAC)", "http://live-radio01.mediahubaustralia.com/JAZW/aac/"),
            ("Gold 104.3", "https://ais-arn.streamguys1.com/au_004_icy"),
            ("ABC Local Radio 774 Melbourne (AAC)", "http://live-radio01.mediahubaustralia.com/3LRW/aac/"),
            ("ABC Grandstand (AAC)", "http://live-radio02.mediahubaustralia.com/GSDW/aac/;"),
            ("ABC Classic FM (MP3)", "http://live-radio01.mediahubaustralia.com/2FMW/mp3/;*.mp3"),
            ("ABC Jazz (MP3)", "http://live-radio01.mediahubaustralia.com/JAZW/mp3/"),
            ("ABC Local Radio 702 Sydney (AAC)", "http://live-radio01.mediahubaustralia.com/2LRW/aac/"),
            ("ABC Country (AAC)", "http://live-radio01.mediahubaustralia.com/CTRW/aac/"),
            ("ABC Radio National MP3", "http://live-radio01.mediahubaustralia.com/2RNW/mp3/"),
            ("Totally Radio Hits", "https://23203.live.streamtheworld.com/T_RAD_HITS_S01AAC.aac"),
            ("SMOOTH Relax", "https://23153.live.streamtheworld.com/SMOOTHRELAX_SYD.mp3"),
            ("Radio Italian Music", "https://streaming.radiostreamlive.com/radioitalianmusic_devices"),
            ("88.6 Hard Rock", "http://radio886.at/streams/88.6_Hard_Rock/mp3"),
            ("2MFM Muslim Community Radio 92.1 FM Sydney, NSW", "http://www.2mfm.org.au:8000/live"),
            ("ABC Local Radio 774 Melbourne (MP3)", "http://live-radio01.mediahubaustralia.com/3LRW/mp3/"),
            ("ABC Triple J (MP3)", "http://live-radio01.mediahubaustralia.com/2TJW/mp3/;stream.nsv"),
            ("Nova 106.9", "http://streaming.novaentertainment.com.au/nova1069"),
            ("SBS Chill", "http://sbs-ice.streamguys1.com/sbschill"),
            ("ABC Classic 2 Stream (AAC)", "http://live-radio01.mediahubaustralia.com/FM2W/aac/"),
            ("Smooth FM 95.3", "http://playerservices.streamtheworld.com/api/livestream-redirect/SMOOTH953_AAC48.aac?src=neweb"),
            ("ABC Classic FM (AAC)", "http://live-radio01.mediahubaustralia.com/2FMW/aac/"),
            ("ABC Local Radio 612 Brisbane (AAC)", "http://live-radio01.mediahubaustralia.com/4LRW/aac/"),
            ("Triple J", "http://www.abc.net.au/res/streaming/audio/aac/triplej.pls"),
            ("Totally Radio - 90s", "https://23033.live.streamtheworld.com/T_RAD_90S_S01AAC.aac"),

        ].filter { !existingStationNames.contains($0.0) }
        .map { (name, url) -> RadioStation in
            let iconData = viewModel.loadImageData(named: name)
            return RadioStation(name: name, url: url, iconData: iconData, country: "Australia")
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

