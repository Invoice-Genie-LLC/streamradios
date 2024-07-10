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
