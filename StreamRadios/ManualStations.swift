//
//  ManualStations.swift
//  StreamRadios
//
//  Created by Kley Sulo on 12/28/24.
//

import Foundation

/// Manual stations configuration - Easy to maintain and add new stations
/// These stations take priority over API-fetched stations and prevent API duplicates
struct ManualStationsData {
    
    /// Manual stations organized by country
    /// Add new countries and stations here easily
    static let manualStationsByCountry: [String: [ManualStationInfo]] = [

        // MARK: - Albania
        "Albania": [
            ManualStationInfo(
                name: "Radio News 24",
                url: "http://tv.balkanweb.com:8081/news24/livestream/playlist.m3u8",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Beatfm.al",
                url: "http://streaming.ihost.al:8010",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Chill Radio",
                url: "https://eu8.fastcast4u.com/proxy/chillradio?mp=/1",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Club FM Radio",
                url: "https://cp1.sednastream.com/proxy/clubfm?mp=/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "City Radio",
                url: "https://cp1.sednastream.com/proxy/cityradio?mp=%2Fstream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Kontakt",
                url: "http://84.20.83.24:88/broadwavehigh.mp3?src=1",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Klan Radio",
                url: "https://klanradio.tvklan.al/live/klanmusicradio1/playlist.m3u8",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Top Gold Radio",
                url: "https://live.topgold.al/topgold",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "My Music Radio",
                url: "https://live.top-media.al/mmr",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "OraNews",
                url: "https://radio.oranews.tv:8443/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio One",
                url: "https://cp1.sednastream.com/proxy/radioone94?mp=%2Fstream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Emigranti",
                url: "http://radioemigranti.com:8000/radio128k",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Emanuel",
                url: "https://cp1.sednastream.com/proxy/radioemanuel/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Shqip",
                url: "https://cp1.sednastream.com/proxy/radioshqip?mp=%2F%3Bstream.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Tirana 1",
                url: "http://79.106.48.2:8000/radiotirana1",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Tirana 2",
                url: "http://79.106.48.2:8000/radiotirana2",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Tirana Classic",
                url: "http://79.106.48.2:8000/radiotiranaklasik1",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Tirana Femije",
                url: "http://79.106.48.2:8000/radiotiranafemije",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Play Radio 91.1 FM",
                url: "http://stream.radiojar.com/sx7zrht0pg0uv",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Maria",
                url: "http://dreamsiteradiocp2.com:8028/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio 7 Albania",
                url: "https://cp1.sednastream.com/proxy/radio7albania?mp=/live",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio 4 Plus",
                url: "https://radio.albcast.pro/listen/radio_4plus/radio.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Nostalgjia",
                url: "https://radionos.radioca.st/;?1720844152510",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Jehona 107.6 FM",
                url: "https://stream.iradio.pro/proxy/radiojehona?mp=/1",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Dashuria",
                url: "https://play.radioking.io/radiodashuria1/523790",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Lushnja",
                url: "https://stream.radiolushnja.al/listen/radio_lushnja/radio.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Alpo Radio 94.1 MHZ",
                url: "https://cp1.sednastream.com/proxy/alporadio/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Top Albania Radio",
                url: "https://live.top-media.al/tar",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Eurostar Radio",
                url: "http://radioeurostar.al:9000/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Tirana Jazz Radio",
                url: "https://live.tiranajazzradio.com:8443/stream",
                iconURL: nil
            )
        ],
        
        // MARK: - United States
        "United States": [
            ManualStationInfo(
                name: "Q104.1 Cleveland",
                url: "https://prod-13-222-152-184.amperwave.net/audacy-wqalfmaac-hlsc.m3u8",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "The Jim Rome Show",
                url: "https://19313.live.streamtheworld.com/JIM_ROMEAAC.aac",
                iconURL: nil
            )
        ],
        
    ]
}

/// Individual manual station information
struct ManualStationInfo {
    let name: String
    let url: String
    let iconURL: String?
    
    /// Convert to RadioStation model with proper ordering
    func toRadioStation(country: String, order: Int) -> RadioStation {
        return RadioStation(
            id: UUID().uuidString,
            name: name,
            url: url,
            iconData: iconURL,
            country: country,
            isFavorite: false,
            order: order
        )
    }
}

/// Manager for handling manual stations
class ManualStationManager {
    static let shared = ManualStationManager()
    
    private init() {}
    
    /// Get manual stations for a specific country
    func getManualStations(for country: String) -> [RadioStation] {
        guard let manualStationInfos = ManualStationsData.manualStationsByCountry[country] else {
            print("📻 No manual stations found for country: \(country)")
            return []
        }
        
        print("📻 Loading \(manualStationInfos.count) manual stations for \(country)")
        
        return manualStationInfos.enumerated().map { index, stationInfo in
            stationInfo.toRadioStation(country: country, order: index)
        }
    }
    
    /// Get all manual stations across all countries
    func getAllManualStations() -> [RadioStation] {
        var allStations: [RadioStation] = []
        var currentOrder = 0
        
        for (country, stationInfos) in ManualStationsData.manualStationsByCountry {
            for stationInfo in stationInfos {
                allStations.append(stationInfo.toRadioStation(country: country, order: currentOrder))
                currentOrder += 1
            }
        }
        
        print("📻 Loaded \(allStations.count) total manual stations across \(ManualStationsData.manualStationsByCountry.count) countries")
        return allStations
    }
    
    /// Check if a station is a manual station (for duplicate detection)
    func isManualStation(name: String, country: String) -> Bool {
        guard let manualStations = ManualStationsData.manualStationsByCountry[country] else {
            return false
        }
        
        return manualStations.contains { $0.name.lowercased() == name.lowercased() }
    }
    
    /// Get list of countries that have manual stations
    func getCountriesWithManualStations() -> [String] {
        return Array(ManualStationsData.manualStationsByCountry.keys).sorted()
    }
    
    /// Check if a country has manual stations
    func hasManualStations(for country: String) -> Bool {
        return ManualStationsData.manualStationsByCountry[country] != nil
    }
    
    /// Get count of manual stations for a country
    func getManualStationCount(for country: String) -> Int {
        return ManualStationsData.manualStationsByCountry[country]?.count ?? 0
    }
}
