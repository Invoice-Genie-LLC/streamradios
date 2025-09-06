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
        
        // MARK: - United States
        "United States": [
            ManualStationInfo(
                name: "NPR News",
                url: "https://npr-ice.streamguys1.com/live.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "KCRW Santa Monica",
                url: "https://kcrw.streamguys1.com/kcrw_192k_mp3_on_air",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "WNYC New York",
                url: "https://fm939.wnyc.org/wnycfm",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "KQED San Francisco", 
                url: "https://streams.kqed.org/kqedradio",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Chicago Public Radio WBEZ",
                url: "https://stream.wbez.org/wbez128.mp3",
                iconURL: nil
            )
        ],
        
        // MARK: - United Kingdom
        "United Kingdom": [
            ManualStationInfo(
                name: "BBC Radio 1",
                url: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_one",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "BBC Radio 2",
                url: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_two",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "BBC Radio 4",
                url: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_fourfm",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Capital FM London",
                url: "https://media-ssl.musicradio.com/CapitalMP3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Heart London",
                url: "https://media-ssl.musicradio.com/HeartLondonMP3",
                iconURL: nil
            )
        ],
        
        // MARK: - Germany
        "Germany": [
            ManualStationInfo(
                name: "Deutschlandfunk",
                url: "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Bayern 3",
                url: "https://dispatcher.rndfnk.com/br/bayern3/live/mp3/low",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "WDR 2",
                url: "https://wdr-wdr2-rheinruhr.icecastssl.wdr.de/wdr/wdr2/rheinruhr/mp3/128/stream.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Hamburg",
                url: "https://stream.radiohamburg.de/rhh-live/mp3-192/",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Antenne Bayern",
                url: "https://s1-webradio.antenne.de/antenne",
                iconURL: nil
            )
        ],
        
        // MARK: - France
        "France": [
            ManualStationInfo(
                name: "France Inter",
                url: "https://direct.franceinter.fr/live/franceinter-midfi.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "RTL",
                url: "https://streaming.radio.rtl.fr/rtl-1-48-192",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "NRJ",
                url: "https://scdn.nrjaudio.fm/audio1/fr/30001/mp3_128.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Europe 1",
                url: "https://europe1.lmn.fm/europe1.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "RMC",
                url: "https://rmc.bfmtv.com/rmcinfo-mp3",
                iconURL: nil
            )
        ],
        
        // MARK: - Canada
        "Canada": [
            ManualStationInfo(
                name: "CBC Radio One",
                url: "https://cbc_r1_tor.akacast.akamaistream.net/7/750/451661/v1/rc.akacast.akamaistream.net/cbc_r1_tor",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "CBC Music",
                url: "https://cbc_r2_tor.akacast.akamaistream.net/7/750/451661/v1/rc.akacast.akamaistream.net/cbc_r2_tor",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "CHFI Toronto",
                url: "https://live.leanstream.co/CHFIFM",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "CJAD Montreal",
                url: "https://live.leanstream.co/CJADCAM",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "CFOX Vancouver",
                url: "https://live.leanstream.co/CFOXFM",
                iconURL: nil
            )
        ],
        
        // MARK: - Australia
        "Australia": [
            ManualStationInfo(
                name: "Triple J",
                url: "https://live-radio01.mediahubaustralia.com/2TJW/mp3/",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "ABC News Radio",
                url: "https://live-radio02.mediahubaustralia.com/PBW/mp3/",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Nova 96.9 Sydney",
                url: "https://streaming.novaentertainment.com.au/nova969",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "2GB Sydney",
                url: "https://live.leanstream.co/2GBSYD",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "3AW Melbourne",
                url: "https://live.leanstream.co/3AWMEL",
                iconURL: nil
            )
        ],
        
        // MARK: - Japan
        "Japan": [
            ManualStationInfo(
                name: "J-Wave Tokyo",
                url: "https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=FMJ&l=15&lsid=&ft=&type=b",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Inter FM",
                url: "https://stream.interFM.co.jp/if897",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Tokyo FM",
                url: "https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=FMT&l=15&lsid=&ft=&type=b",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "NHK Radio Japan",
                url: "https://radio-stream.nhk.jp/hls/live/2023229/nhkradiruakr1/master.m3u8",
                iconURL: nil
            )
        ],
        
        // MARK: - Brazil
        "Brazil": [
            ManualStationInfo(
                name: "Jovem Pan",
                url: "https://r13.ciclano.io:15045/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Antena 1",
                url: "https://antena1.newradio.it/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "CBN São Paulo",
                url: "https://27553.live.streamtheworld.com/CBN_SP.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Globo",
                url: "https://radioglobo.newradio.it/stream",
                iconURL: nil
            )
        ],
        
        // MARK: - Italy
        "Italy": [
            ManualStationInfo(
                name: "RAI Radio 1",
                url: "https://radioblu.newradio.it/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "RTL 102.5",
                url: "https://radioblu.newradio.it/stream",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Deejay",
                url: "https://radiodeejay-lh.akamaihd.net/i/RadioDeejay_Live_1@189857/master.m3u8",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio Italia",
                url: "https://radioitalia-lh.akamaihd.net/i/radioitalia_1@329645/master.m3u8",
                iconURL: nil
            )
        ],
        
        // MARK: - Spain
        "Spain": [
            ManualStationInfo(
                name: "Cadena SER",
                url: "https://playerservices.streamtheworld.com/api/livestream-redirect/CADENASER.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "COPE",
                url: "https://flucast-m04-06.flumotion.com/cope/net1.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Onda Cero",
                url: "https://playerservices.streamtheworld.com/api/livestream-redirect/ONDACERO.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Los 40",
                url: "https://playerservices.streamtheworld.com/api/livestream-redirect/LOS40.mp3",
                iconURL: nil
            )
        ],
        
        // MARK: - Netherlands
        "Netherlands": [
            ManualStationInfo(
                name: "NPO Radio 1",
                url: "https://icecast.omroep.nl/radio1-bb-mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "NPO Radio 2",
                url: "https://icecast.omroep.nl/radio2-bb-mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Radio 538",
                url: "https://21223.live.streamtheworld.com/RADIO538.mp3",
                iconURL: nil
            ),
            ManualStationInfo(
                name: "Sky Radio",
                url: "https://playerservices.streamtheworld.com/api/livestream-redirect/SKYRADIO.mp3",
                iconURL: nil
            )
        ]
        
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
        
        // MARK: - Add More Countries Here
        // To add a new country, follow this pattern:
        // "CountryName": [
        //     ManualStationInfo(
        //         name: "Station Name",
        //         url: "https://stream.url.here",
        //         iconURL: "optional_icon_url"
        //     ),
        //     // Add more stations...
        // ],
        
    ]
}

/// Individual manual station information
struct ManualStationInfo {
    let name: String
    let url: String
    let iconURL: String?
    
    /// Convert to RadioStation model with proper ordering
    func toRadioStation(country: String, order: Int) -> RadioStation {
        // Create consistent ID for manual stations based on name and country
        // This ensures deleted manual stations stay deleted
        let consistentId = "manual_\(country.replacingOccurrences(of: " ", with: "_"))_\(name.replacingOccurrences(of: " ", with: "_"))".lowercased()
        
        return RadioStation(
            id: consistentId,
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
    
    /// Check if a station ID belongs to a manual station
    func isManualStationById(_ stationId: String) -> Bool {
        return stationId.hasPrefix("manual_")
    }
    
    /// Get manual station info by consistent ID
    func getManualStationById(_ stationId: String, country: String) -> ManualStationInfo? {
        guard let manualStations = ManualStationsData.manualStationsByCountry[country] else {
            return nil
        }
        
        return manualStations.first { stationInfo in
            let consistentId = "manual_\(country.replacingOccurrences(of: " ", with: "_"))_\(stationInfo.name.replacingOccurrences(of: " ", with: "_"))".lowercased()
            return consistentId == stationId
        }
    }
}
