// CountryDefaultStations.swift
// StreamRadios

import SwiftUI

extension RadioStationViewModel {
    func addDefaultStationsForAlbania() {
        let stationsInfo: [(name: String, url: String)] = [
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
        
        let stations = stationsInfo.map { (name, url) -> RadioStation in
            let iconData = loadImageData(named: name)
            return RadioStation(name: name, url: url, iconData: iconData, country: "Albania")
        }
        
        self.stations.append(contentsOf: stations)
        saveStationsToFile()
    }

    private func loadImageData(named name: String) -> String? {
        let assetName = name.replacingOccurrences(of: " ", with: "_")
        guard let image = UIImage(named: assetName) else {
            print("Failed to load image named: \(assetName)")
            return nil
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to compress image named: \(assetName)")
            return nil
        }
        print("Image loaded and encoded for: \(assetName)")
        return imageData.base64EncodedString()
    }

}
