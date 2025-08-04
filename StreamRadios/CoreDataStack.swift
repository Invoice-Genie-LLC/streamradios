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
        
        // Configure the container to use the app group for data sharing between main app and CarPlay
        let storeURL: URL
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.streamradios") {
            storeURL = appGroupURL.appendingPathComponent("StreamRadiosModel.sqlite")
            print("CoreData: Using app group URL: \(storeURL.absoluteString)")
        } else {
            // Fallback to default location if app group is not available
            storeURL = container.persistentStoreDescriptions.first?.url ?? 
                      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("StreamRadiosModel.sqlite")
            print("CoreData: App group not available, using fallback URL: \(storeURL.absoluteString)")
        }
        
        // Update the store description with the shared URL
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [storeDescription]
        
        container.loadPersistentStores { (storeDescription, error) in
            print("CoreData: Loaded store at \(storeDescription.url?.absoluteString ?? "Unknown URL")")
            if let error = error as NSError? {
                print("CoreData: Failed to load persistent stores: \(error), \(error.userInfo)")
                // In case of migration issues, try to delete and recreate the store
                if error.code == NSPersistentStoreIncompatibleVersionHashError || 
                   error.code == NSMigrationMissingSourceModelError {
                    print("CoreData: Attempting to recreate store due to migration error")
                    try? FileManager.default.removeItem(at: storeURL)
                    
                    // Try loading again
                    container.loadPersistentStores { (newStoreDescription, newError) in
                        if let newError = newError as NSError? {
                            fatalError("Unresolved CoreData error after recreation: \(newError), \(newError.userInfo)")
                        } else {
                            print("CoreData: Successfully recreated store at \(newStoreDescription.url?.absoluteString ?? "Unknown URL")")
                        }
                    }
                } else {
                    fatalError("Unresolved CoreData error \(error), \(error.userInfo)")
                }
            }
        }
        return container
    }()

    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
            let newContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            newContext.parent = context
            return newContext
        }

    func saveContext() {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("CoreData: Successfully saved changes to the context.")

            } catch let error as NSError {
                print("CoreData: Failed to save context: \(error), \(error.userInfo)")
                // DebugLogger.logError will be added when import is fixed
                // ToDo: Handle the error according to your app's needs, e.g., showing UI to inform the user
            }
        } else {
            print("CoreData: No changes to save in context.")
            // DebugLogger.logDebug will be added when import is fixed
        }
    }

    // New methods for podcast episode management
    func fetchAllEpisodes() -> [PodcastEpisode] {
        let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
        do {
            let results = try context.fetch(request)

            return results.map { $0.toPodcastEpisode() }
        } catch {
            print("CoreData: Error fetching episodes: \(error)")

            return []
        }
    }

    func saveEpisodes(_ episodes: [PodcastEpisode]) {
        // CRITICAL FIX: Remove duplicates before saving
        let uniqueEpisodes = removeDuplicateEpisodes(episodes)
        
        for episode in uniqueEpisodes {
            let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
            
            do {
                let results = try context.fetch(fetchRequest)
                if let existingEpisode = results.first {
                    existingEpisode.update(from: episode)
                } else {
                    let newEpisode = PodcastModel(context: context)
                    newEpisode.update(from: episode)
                }
            } catch {
                print("CoreData: Error saving episode: \(error)")
            }
        }
        
        saveContext()
    }
    
    /// Remove duplicate episodes using compositeID for robust duplicate detection
    private func removeDuplicateEpisodes(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        var seenCompositeIDs = Set<String>()
        var seenIds = Set<String>()
        var uniqueEpisodes: [PodcastEpisode] = []
        
        for episode in episodes {
            let compositeKey = episode.compositeID
            
            // Skip if we've seen this composite ID or episode ID before
            if !seenCompositeIDs.contains(compositeKey) && !seenIds.contains(episode.id) {
                seenCompositeIDs.insert(compositeKey)
                seenIds.insert(episode.id)
                uniqueEpisodes.append(episode)
            } else {
                print("CoreData: Skipping duplicate episode - ID: \(episode.id), Title: \(episode.title)")
            }
        }
        
        let duplicatesCount = episodes.count - uniqueEpisodes.count
        if duplicatesCount > 0 {
            print("CoreData: Removed \(duplicatesCount) duplicate episodes from \(episodes.count) total")
        }
        
        return uniqueEpisodes
    }

    func deleteAllEpisodes() {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            try context.execute(deleteRequest)
            saveContext()
        } catch {
            print("CoreData: Error deleting all episodes: \(error)")
        }
    }
}

// Existing extension for syncing stations from CloudKit
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
                        existingStation.favoritedAt = station.favoritedAt
                        if let favoriteOrder = station.favoriteOrder {
                            existingStation.favoriteOrder = Int32(favoriteOrder)
                        } else {
                            existingStation.favoriteOrder = -1  // Use -1 to represent nil
                        }
                        existingStation.order = Int16(station.order)
                        existingStation.lastPlayed = station.lastPlayed
                    } else {
                        // Insert new station
                        let newStation = CDStation(context: context)
                        newStation.id = station.id
                        newStation.name = station.name
                        newStation.url = station.url
                        newStation.iconData = station.iconData
                        newStation.country = station.country
                        newStation.isFavorite = station.isFavorite
                        newStation.favoritedAt = station.favoritedAt
                        if let favoriteOrder = station.favoriteOrder {
                            newStation.favoriteOrder = Int32(favoriteOrder)
                        } else {
                            newStation.favoriteOrder = -1  // Use -1 to represent nil
                        }
                        newStation.order = Int16(station.order)
                        newStation.lastPlayed = station.lastPlayed
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
