// AppDelegate.swift
// RadioStreamApp
//
// Created by Kley Sulo on 6/9/24.
//

import UIKit
import CoreData

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if isFirstLaunch() {
            deleteLocalCoreDataStore()
        }
        return true
    }

    private func isFirstLaunch() -> Bool {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
            UserDefaults.standard.synchronize()
            return true
        }
        return false
    }

    private func deleteLocalCoreDataStore() {
        let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        if let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreDescriptions.first?.url,
           let store = coordinator.persistentStore(for: storeURL) {
            do {
                try coordinator.remove(store)
                try FileManager.default.removeItem(at: storeURL)
                recreateCoreDataStack() // Re-initialize CoreData after cleanup
                print("Successfully removed CoreData store and cleaned up local files.")
            } catch {
                print("Failed to delete CoreData store: \(error.localizedDescription)")
            }
        }
    }

    private func recreateCoreDataStack() {
        let container = NSPersistentContainer(name: "YourModel")
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        CoreDataStack.shared.persistentContainer = container
    }
}
