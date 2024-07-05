// CountryDefaultStations.swift
// StreamRadios

import SwiftUI

extension RadioStationViewModel {
    func addDefaultStationsForAlbania() {
        let stationsInfo: [(name: String, url: String)] = [
            ("OraNews", "https://radio.oranews.tv:8443/stream"),
                       ("Love Radio", "https://radio.albanialoveradio.al/stream"),
                
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
