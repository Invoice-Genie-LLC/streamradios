//
//  CoreDataStack.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/9/24.
//

import CoreData

class CoreDataStack {
    static let shared = CoreDataStack()

    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "StreamRadiosModel")  // Name here should match the .xcdatamodeld file name
        container.loadPersistentStores { (storeDescription, error) in
            print("CoreData: Loaded store at \(storeDescription.url?.absoluteString ?? "Unknown URL")")
            if let error = error as NSError? {
                print("CoreData: Failed to load persistent stores: \(error), \(error.userInfo)")
                fatalError("Unresolved CoreData error \(error), \(error.userInfo)")
            }
        }
        return container
    }()

    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }

    func saveContext() {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("CoreData: Successfully saved changes to the context.")
            } catch let error as NSError {
                print("CoreData: Failed to save context: \(error), \(error.userInfo)")
                // ToDo: Handle the error according to your app's needs, e.g., showing UI to inform the user
            }
        } else {
            print("CoreData: No changes to save in context.")
        }
    }
}

extension CoreDataStack {
    
    func syncStationsFromCloudKit(completion: @escaping (Error?) -> Void) {
        DataStore.shared.fetchRadioStations { [weak self] stations, error in
            guard let self = self else { return }
            if let error = error {
                print("Error fetching stations from CloudKit:", error.localizedDescription)
                completion(error)
                return
            }
            
            guard let stations = stations else {
                print("No stations fetched from CloudKit.")
                completion(nil)
                return
            }
            
            self.updateCoreData(with: stations, completion: completion)
        }
    }
    
    private func updateCoreData(with stations: [RadioStation], completion: @escaping (Error?) -> Void) {
        let context = self.context
        context.perform {
            for station in stations {
                let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", station.id)
                
                do {
                    let results = try context.fetch(request)
                    if let existingStation = results.first {
                        // Update existing station
                        existingStation.name = station.name
                        existingStation.url = station.url
                        existingStation.iconData = station.iconData
                        existingStation.country = station.country
                        existingStation.isFavorite = station.isFavorite
                    } else {
                        // Insert new station
                        let newStation = CDStation(context: context)
                        newStation.id = station.id
                        newStation.name = station.name
                        newStation.url = station.url
                        newStation.iconData = station.iconData
                        newStation.country = station.country
                        newStation.isFavorite = station.isFavorite
                    }
                } catch {
                    print("Failed to fetch or save station:", error.localizedDescription)
                    completion(error)
                    return
                }
            }
            
            // Save changes to CoreData
            do {
                try context.save()
                print("CoreData sync complete.")
                completion(nil)
            } catch {
                print("Error saving CoreData context:", error.localizedDescription)
                completion(error)
            }
        }
    }
}
