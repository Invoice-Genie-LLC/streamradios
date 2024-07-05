//
//  DefaultStations.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/5/24.
//

import Foundation

struct DefaultStations {
    static func stationExists(_ stationName: String, in viewModel: RadioStationViewModel) -> Bool {
        return viewModel.stations.contains(where: { $0.name == stationName })
    }
    
    // Generic function to add stations if they are missing
    static func addStations(stations: [(String, String)], country: String, to viewModel: RadioStationViewModel) {
        for (name, url) in stations where !stationExists(name, in: viewModel) {
            if let iconData = viewModel.loadImageData(named: name) {
                let newStation = RadioStation(name: name, url: url, iconData: iconData, country: country)
                viewModel.stations.append(newStation)
                viewModel.saveStationToCloud(newStation)
                viewModel.saveStationsToFile()
            }
        }
    }
    
    // Albania
    static func addDefaultStationsForAlbania(to viewModel: RadioStationViewModel) {
        let stations = [
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
        ]
        
        addStations(stations: stations, country: "Albania", to: viewModel)
    }
    
    
    // Angola
    static func addDefaultStationsForAngola(to viewModel: RadioStationViewModel) {
        let stations = [
            ("Radio MFM", "https://centova87.instainternet.com/proxy/mfm?mp=/stream"),
        ]
        addStations(stations: stations, country: "Angola", to: viewModel)
    }
    
    // Australia
    static func addDefaultStationsForAustralia(to viewModel: RadioStationViewModel) {
        let stations = [
            ("ABC NewsRadio", "http://www.abc.net.au/res/streaming/audio/mp3/news_radio.pls"),
            ("Kiss FM 87.6", "http://cc.net2streams.com:8565/kissfm.mp3"),
            ("ABC Radio National", "http://www.abc.net.au/res/streaming/audio/aac/radio_national.pls"),
            ("ABC Country", "http://live-radio01.mediahubaustralia.com/CTRW/mp3/;*.mp3"),
            ("The Prog Rock Machine", "https://theproganrockmachine.out.airtime.pro/theproganrockmachine_b"),
            ("ABC Jazz", "http://live-radio01.mediahubaustralia.com/JAZW/aac/"),
            ("Gold 104.3", "https://ais-arn.streamguys1.com/au_004_icy"),
            ("ABC Local Radio Melbourne", "http://live-radio01.mediahubaustralia.com/3LRW/aac/"),
            ("ABC Grandstand", "http://live-radio02.mediahubaustralia.com/GSDW/aac/;"),
            ("ABC Classic", "http://live-radio01.mediahubaustralia.com/2FMW/mp3/;*.mp3"),
            ("ABC Local Radio Sydney", "http://live-radio01.mediahubaustralia.com/2LRW/aac/"),
            ("ABC Country", "http://live-radio01.mediahubaustralia.com/CTRW/aac/"),
            ("ABC Radio National", "http://live-radio01.mediahubaustralia.com/2RNW/mp3/"),
            ("Totally Radio Hits", "https://23203.live.streamtheworld.com/T_RAD_HITS_S01AAC.aac"),
            ("Smooth Relax", "https://23153.live.streamtheworld.com/SMOOTHRELAX_SYD.mp3"),
            ("Radio Italian Music", "https://streaming.radiostreamlive.com/radioitalianmusic_devices"),
            ("88.6 Hard Rock", "http://radio886.at/streams/88.6_Hard_Rock/mp3"),
            ("2MFM Muslim Community Radio", "http://www.2mfm.org.au:8000/live"),
            ("ABC Triple J", "http://live-radio01.mediahubaustralia.com/2TJW/mp3/;stream.nsv"),
            ("Nova 106.9", "http://streaming.novaentertainment.com.au/nova1069"),
            ("SBS Chill", "http://sbs-ice.streamguys1.com/sbschill"),
            ("ABC Classic 2 Stream", "http://live-radio01.mediahubaustralia.com/FM2W/aac/"),
            ("Smooth FM 95.3", "http://playerservices.streamtheworld.com/api/livestream-redirect/SMOOTH953_AAC48.aac?src=neweb"),
            ("ABC Classic FM", "http://live-radio01.mediahubaustralia.com/2FMW/aac/"),
            ("ABC Local Radio 612 Brisbane", "http://live-radio01.mediahubaustralia.com/4LRW/aac/"),
            ("Triple J", "http://www.abc.net.au/res/streaming/audio/aac/triplej.pls"),
            ("Totally Radio - 90s", "https://23033.live.streamtheworld.com/T_RAD_90S_S01AAC.aac"),
            
        ]
        addStations(stations: stations, country: "Australia", to: viewModel)
    }
    
    
    // Argentina
    static func addDefaultStationsForArgentina(to viewModel: RadioStationViewModel) {
        let stations = [
            ("Blue FM", "https://19793.live.streamtheworld.com/BLUE_FM_100_7AAC_SC?pname=TDSdk"),
            ("Radio 10", "https://frontend.radiohdvivo.com/radio10/live"),
            ("Pop FM", "https://edge01.radiohdvivo.com/stream/popradio"),
            ("El Observador", "https://s8.stweb.tv/observador/live/playlist.m3u8"),
            ("Radio One Argentina", "https://s8.stweb.tv/one/live/playlist.m3u8"),
            ("La Popu FM", "https://27573.live.streamtheworld.com/LAPOPU_SC?dist=c3-web")
        ]
        
        addStations(stations: stations, country: "Argentina", to: viewModel)
    }
    
    static func addAllDefaults(to viewModel: RadioStationViewModel) {
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForAngola(to: viewModel)
        addDefaultStationsForAustralia(to: viewModel)
        addDefaultStationsForArgentina(to: viewModel)
        // Add more calls here for other countries as you expand
    }
}



