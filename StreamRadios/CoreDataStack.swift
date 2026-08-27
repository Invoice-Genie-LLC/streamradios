//
//  CoreDataStack.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/9/24.
//

import CoreData
import StreamRadiosKit

class CoreDataStack {
    static let shared = CoreDataStack()

    /// Retains the will-save observer that keeps `CDStation.searchText` current.
    private var stationIndexObserver: NSObjectProtocol?

    /// Must stay `lazy var`. Something reached from container creation calls back into
    /// `CoreDataStack.shared`; a `let` built in `init()` deadlocks on the once-token and the
    /// watchdog kills the app. `lazy` tolerates the re-entry, at the cost of an extra container.
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
            
            // Configure merge policy for better conflict resolution
            container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            container.viewContext.automaticallyMergesChangesFromParent = true
            
            if let error = error as NSError? {
                print("CoreData: Failed to load persistent stores: \(error), \(error.userInfo)")
                // In case of migration issues, try to delete and recreate the store
                if error.code == NSPersistentStoreIncompatibleVersionHashError || 
                   error.code == NSMigrationMissingSourceModelError {
                    print("CoreData: Attempting to recreate store due to migration error")
                    
                    // CRITICAL: Notify EpisodeStateManager about impending data loss before deleting store
                    // This allows it to create comprehensive backups before Core Data is wiped
                    print("⚠️ CoreData: Warning EpisodeStateManager about impending Core Data deletion")
                    NotificationCenter.default.post(name: NSNotification.Name("CoreDataWillBeDeleted"), object: nil)
                    
                    // Give a brief moment for backup operations to complete
                    Thread.sleep(forTimeInterval: 0.5)
                    
                    try? FileManager.default.removeItem(at: storeURL)
                    
                    // Try loading again
                    container.loadPersistentStores { (newStoreDescription, newError) in
                        if let newError = newError as NSError? {
                            fatalError("Unresolved CoreData error after recreation: \(newError), \(newError.userInfo)")
                        } else {
                            print("CoreData: Successfully recreated store at \(newStoreDescription.url?.absoluteString ?? "Unknown URL")")
                            
                            // CRITICAL: Notify EpisodeStateManager that Core Data has been recreated
                            // This allows it to restore data from backups
                            print("✅ CoreData: Notifying EpisodeStateManager about Core Data recreation")
                            NotificationCenter.default.post(name: NSNotification.Name("CoreDataWasRecreated"), object: nil)
                        }
                    }
                } else {
                    fatalError("Unresolved CoreData error \(error), \(error.userInfo)")
                }
            }
        }

        startMaintainingStationSearchIndex()
        backfillStationSearchIndexIfNeeded(using: container)

        return container
    }()

    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        // Create independent background context connected directly to persistent store coordinator
        // This avoids parent-child threading issues and provides better performance
        let newContext = persistentContainer.newBackgroundContext()
        newContext.automaticallyMergesChangesFromParent = true
        newContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return newContext
    }

    // MARK: - Station search index

    /// Keeps `CDStation.searchText` in sync from a single place.
    ///
    /// Station writes happen at ~20 sites across RadioStationViewModel; intercepting the
    /// context's will-save notification covers all of them, including any added later,
    /// without touching those call sites.
    private func startMaintainingStationSearchIndex() {
        guard stationIndexObserver == nil else { return }

        stationIndexObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave,
            object: nil,
            queue: nil
        ) { notification in
            guard let context = notification.object as? NSManagedObjectContext else { return }

            for case let station as CDStation in context.insertedObjects.union(context.updatedObjects) {
                let expected = SRSearchNormalizer.stationIndexText(
                    name: station.name,
                    country: station.country
                )
                // Compare first: an unconditional write would dirty every object on every save.
                if station.searchText != expected {
                    station.searchText = expected
                }
            }
        }
    }

    /// Populates the column for stations that were persisted before it existed.
    private func backfillStationSearchIndexIfNeeded(using container: NSPersistentContainer) {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        context.perform {
            let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
            request.predicate = NSPredicate(format: "searchText == nil")
            request.fetchBatchSize = 500

            do {
                let pending = try context.fetch(request)
                guard !pending.isEmpty else { return }

                for station in pending {
                    station.searchText = SRSearchNormalizer.stationIndexText(
                        name: station.name,
                        country: station.country
                    )
                }
                try context.save()
                print("CoreData: Backfilled search index for \(pending.count) stations")
            } catch {
                print("CoreData: Station search index backfill failed: \(error)")
            }
        }
    }

    // MARK: - Store purging

    /// Batch deletion frees rows but leaves their payload inside the SQLite file and its `-wal`
    /// sidecar until a checkpoint. Reopening with `journal_mode = DELETE` forces one and drops the
    /// sidecars. Only safe when nothing will touch Core Data afterwards.
    func checkpointAndCompactStores() {
        let coordinator = persistentContainer.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            guard let url = store.url else { continue }
            do {
                let configuration = store.configurationName
                try coordinator.remove(store)
                let reopened = try coordinator.addPersistentStore(
                    ofType: NSSQLiteStoreType,
                    configurationName: configuration,
                    at: url,
                    options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
                )
                try coordinator.remove(reopened)
                print("🗜️ CoreData: Checkpointed and compacted store \(url.lastPathComponent)")
            } catch {
                print("❌ CoreData: Failed to compact store \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Deletes the SQLite file and its sidecars outright. Only safe immediately before termination.
    func destroyStores() {
        let coordinator = persistentContainer.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            guard let url = store.url else { continue }
            do {
                try coordinator.remove(store)
                try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            } catch {
                print("❌ CoreData: Failed to destroy store \(url.lastPathComponent): \(error.localizedDescription)")
            }
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
            print("🗑️ CoreData: Destroyed store \(url.lastPathComponent)")
        }
    }

    func saveContext() {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                // Validate context before saving to catch constraint violations early
                try context.obtainPermanentIDs(for: Array(context.insertedObjects))
                
                // Check for any constraint violations before saving
                try validateConstraints(in: context)
                
                try context.save()
                print("CoreData: Successfully saved changes to the context.")

            } catch let error as NSError {
                print("CoreData: Failed to save context: \(error), \(error.userInfo)")
                
                // Handle specific Core Data errors
                if error.code == 1550 { // NSConstraintViolationError
                    print("❌ CoreData: Constraint violation detected - attempting recovery")
                    handleConstraintViolation(error: error, context: context)
                } else if error.code == 133020 { // NSMergeConflictError
                    print("❌ CoreData: Merge conflict detected - attempting recovery")
                    handleMergeConflict(error: error, context: context)
                } else {
                    print("❌ CoreData: Other error: \(error.localizedDescription)")
                }
            }
        } else {
            print("CoreData: No changes to save in context.")
        }
    }
    
    /// Validate Core Data constraints before saving
    private func validateConstraints(in context: NSManagedObjectContext) throws {
        // Check for potential constraint violations in inserted and updated objects
        let objectsToValidate = context.insertedObjects.union(context.updatedObjects)
        
        for object in objectsToValidate {
            do {
                try object.validateForUpdate()
            } catch {
                print("❌ CoreData: Validation failed for object \(object): \(error)")
                throw error
            }
        }
    }
    
    /// Handle constraint violation errors by removing or fixing conflicting objects
    private func handleConstraintViolation(error: NSError, context: NSManagedObjectContext) {
        print("🔧 CoreData: Attempting to resolve constraint violation...")
        
        // Log detailed constraint violation information
        if let conflictList = error.userInfo["conflictList"] as? [Any] {
            print("❌ CoreData: Constraint violation details: \(conflictList)")
        }
        
        // Try to fix common constraint violations
        let insertedObjects = Array(context.insertedObjects)
        
        for object in insertedObjects {
            // For stations, ensure unique ID constraints
            if let station = object as? CDStation {
                if let id = station.id, !id.isEmpty {
                    // Check if a station with this ID already exists
                    let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", id)
                    fetchRequest.fetchLimit = 1
                    
                    do {
                        let existingStations = try context.fetch(fetchRequest)
                        if !existingStations.isEmpty {
                            print("🔧 CoreData: Removing duplicate station with ID: \(id)")
                            context.delete(object)
                        }
                    } catch {
                        print("❌ CoreData: Failed to check for existing station: \(error)")
                        context.delete(object)
                    }
                } else {
                    print("🔧 CoreData: Removing station with nil/empty ID")
                    context.delete(object)
                }
            }
            
            // For podcast episodes, ensure unique ID constraints
            if let episode = object as? PodcastModel {
                if let id = episode.id, !id.isEmpty {
                    let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", id)
                    fetchRequest.fetchLimit = 1
                    
                    do {
                        let existingEpisodes = try context.fetch(fetchRequest)
                        if !existingEpisodes.isEmpty {
                            print("🔧 CoreData: Removing duplicate episode with ID: \(id)")
                            context.delete(object)
                        }
                    } catch {
                        print("❌ CoreData: Failed to check for existing episode: \(error)")
                        context.delete(object)
                    }
                } else {
                    print("🔧 CoreData: Removing episode with nil/empty ID")
                    context.delete(object)
                }
            }
        }
        
        // Try to save again after cleanup
        if context.hasChanges {
            do {
                try context.save()
                print("✅ CoreData: Successfully saved after constraint violation recovery")
            } catch {
                print("❌ CoreData: Failed to save even after constraint violation recovery: \(error)")
            }
        }
    }
    
    /// Handle merge conflict errors
    private func handleMergeConflict(error: NSError, context: NSManagedObjectContext) {
        print("🔧 CoreData: Attempting to resolve merge conflict...")
        
        // For merge conflicts, refresh all objects and try again
        context.refreshAllObjects()
        
        if context.hasChanges {
            do {
                try context.save()
                print("✅ CoreData: Successfully saved after merge conflict recovery")
            } catch {
                print("❌ CoreData: Failed to save even after merge conflict recovery: \(error)")
            }
        }
    }

    // New methods for podcast episode management
    func fetchAllEpisodes() -> [PodcastEpisode] {
        var episodes: [PodcastEpisode] = []
        let backgroundContext = newBackgroundContext()
        
        backgroundContext.performAndWait {
            let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
            do {
                let results = try backgroundContext.fetch(request)
                episodes = results.map { $0.toPodcastEpisode() }
            } catch {
                print("CoreData: Error fetching episodes: \(error)")
            }
        }
        
        return episodes
    }

    func saveEpisodes(_ episodes: [PodcastEpisode]) {
        // CRITICAL FIX: Remove duplicates before saving
        let uniqueEpisodes = removeDuplicateEpisodes(episodes)
        let backgroundContext = newBackgroundContext()
        
        backgroundContext.perform {
            for episode in uniqueEpisodes {
                let fetchRequest: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", episode.id)
                
                do {
                    let results = try backgroundContext.fetch(fetchRequest)
                    if let existingEpisode = results.first {
                        existingEpisode.updateMetadata(from: episode)
                    } else {
                        let newEpisode = PodcastModel(context: backgroundContext)
                        newEpisode.update(from: episode)
                    }
                } catch {
                    print("CoreData: Error saving episode: \(error)")
                }
            }
            
            // Save the background context
            if backgroundContext.hasChanges {
                do {
                    try backgroundContext.save()
                    print("CoreData: Successfully saved \(uniqueEpisodes.count) episodes in background")
                } catch {
                    print("CoreData: Error saving background context: \(error)")
                }
            }
        }
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
        let backgroundContext = newBackgroundContext()
        
        backgroundContext.perform {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PodcastModel.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            
            do {
                try backgroundContext.execute(deleteRequest)
                
                // Save the background context
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    print("CoreData: Successfully deleted all episodes in background")
                }
            } catch {
                print("CoreData: Error deleting all episodes: \(error)")
            }
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
        let backgroundContext = newBackgroundContext()
        backgroundContext.perform {
            for station in stations {
                let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", station.id)
                
                do {
                    let results = try backgroundContext.fetch(request)
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
                        let newStation = CDStation(context: backgroundContext)
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
                try backgroundContext.save()
                print("CoreData sync complete.")
                completion(nil)
            } catch {
                print("Error saving CoreData context:", error.localizedDescription)
                completion(error)
            }
        }
    }
}
