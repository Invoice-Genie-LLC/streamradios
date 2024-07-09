//
//  SaveStationsToCoreData.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/9/24.
//

import Foundation
import CoreData

extension RadioStationViewModel {
    func SaveStationsToCoreData() {
        let context = CoreDataStack.shared.context
        do {
            // Delete existing data to prevent duplicates
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: CDStation.fetchRequest())
            try context.execute(deleteRequest)

            // Create new records
            for station in stations {
                let cdStation = CDStation(context: context)
                cdStation.id = station.id
                cdStation.name = station.name
                cdStation.url = station.url
                cdStation.iconData = station.iconData
                cdStation.country = station.country
                cdStation.isFavorite = station.isFavorite
            }

            // Save context
            try context.save()
            print("Successfully saved stations to CoreData.")
        } catch {
            print("Failed to save stations or delete previous data: \(error)")
        }
    }

    func loadStationsFromCoreData() {
        let context = CoreDataStack.shared.context
        if let request = CDStation.fetchRequest() as? NSFetchRequest<CDStation> {
            do {
                let results = try context.fetch(request)
                stations = results.map { station in
                    RadioStation(id: station.id!, name: station.name!, url: station.url!, iconData: station.iconData, country: station.country!, isFavorite: station.isFavorite)
                }
                print("Successfully loaded \(stations.count) stations from CoreData.")
            } catch {
                print("Failed to fetch stations from CoreData: \(error.localizedDescription)")
            }
        } else {
            print("Fetch request casting to CDStation failed")
        }}

}
