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
                       ("3live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            /*
                       ("4live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("5live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("6live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("7live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("8live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("9live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("10live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("11live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("12live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("13live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("14live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("15live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("16live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("17live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("18live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("19live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("20live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("21live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("22live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("23live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("24live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("25live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
             */
            
            
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
                      ("3live.top-media.al/tar25", "Top Albania Radio", "https://live.top-media.al/tar"),
            /*
                      ("4live.top-media.al/tar3", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("5live.top-media.al/tar4", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("6live.top-media.al/tar5", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("7live.top-media.al/tar6", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("8live.top-media.al/tar7", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("9live.top-media.al/tar8", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("10live.top-media.al/tar9", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("11live.top-media.al/tar10", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("12live.top-media.al/tar11", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("13live.top-media.al/tar12", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("14live.top-media.al/tar13", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("15live.top-media.al/tar14", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("16live.top-media.al/tar15", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("17live.top-media.al/tar16", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("18live.top-media.al/tar17", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("19live.top-media.al/tar18", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("20live.top-media.al/tar19", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("21live.top-media.al/tar20", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("22live.top-media.al/tar21", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("23live.top-media.al/tar22", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("24live.top-media.al/tar23", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("25live.top-media.al/tar24", "Top Albania Radio", "https://live.top-media.al/tar"),
             */
            
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
                       ("3live.top-media.al3/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            /*
                       ("4live.top-media.al4/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("5live.top-media.al5/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("6live.top-media.al6/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("7live.top-media.al7/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("8live.top-media.al8/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("9live.top-media.al9/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("10live.top-media.al10/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("11live.top-media.al11/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("12live.top-media.al21/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("13live.top-media.al13/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("14live.top-media.al14/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("15live.top-media.al15/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("16live.top-media.al/16tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("17live.top-media.al17/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("18live.top-media.al18/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("19live.top-media.al19/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("20live.top-media.al20/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("21live.top-media.al21/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("22live.top-media.al22/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("23live.top-media.al23/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("24live.top-media.al24/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                       ("25live.top-media.al/25tar", "Top Albania Radio", "https://live.top-media.al/tar"),

            */
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
                      ("3live.to3p-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            /*
                      ("4live.top4-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("5live.top5-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("6live.top6-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("7live.top7-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("8live.top8-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("9live.top9-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("10live.top10-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("11live.top11-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("12live.top12-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("13live.top13-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("14live.top14-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("15live.top15-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("16live.top16-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("17live.top17-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("18live.top-18media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("19live.top-19media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("20live.20-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("21live.top21-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("22live.top-22media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("23live.top-23media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("24live.top-24media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
                      ("25live.top25-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
             */

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



