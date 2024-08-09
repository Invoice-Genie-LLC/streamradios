// DataStore.swift
// StreamRadios
//
// Created by Kley Sulo on 6/26/24.

import UIKit
import CloudKit

class DataStore {
    static let shared = DataStore()
    private let privateDatabase = CKContainer.default().privateCloudDatabase
    
    func savePodcastURLToCloudKit(_ urlString: String, completion: @escaping (Bool, String?) -> Void) {
            let record = CKRecord(recordType: "PodcastURL")
            record["url"] = urlString

            privateDatabase.save(record) { savedRecord, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error saving podcast URL to CloudKit: \(error.localizedDescription)")
                        completion(false, nil)
                    } else {
                        print("CloudKit podcast URL record saved successfully")
                        completion(true, savedRecord?.recordID.recordName)
                    }
                }
            }
        }

        func fetchPodcastURLsFromCloudKit(completion: @escaping ([String]?, Error?) -> Void) {
            let query = CKQuery(recordType: "PodcastURL", predicate: NSPredicate(value: true))
            
            privateDatabase.perform(query, inZoneWith: nil) { records, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error fetching podcast URLs: \(error.localizedDescription)")
                        completion(nil, error)
                        return
                    }

                    guard let records = records else {
                        print("No podcast URL records found in CloudKit.")
                        completion([], nil)
                        return
                    }

                    let urls = records.compactMap { $0["url"] as? String }
                    print("Fetched \(urls.count) podcast URLs from CloudKit.")
                    completion(urls, nil)
                }
            }
        }
    
    func savePodcastURLToCloudKit(_ feed: PodcastFeed, completion: @escaping (Bool, String?) -> Void) {
            let record = CKRecord(recordType: "PodcastFeed", recordID: CKRecord.ID(recordName: feed.id))
            record["title"] = feed.title
            record["url"] = feed.url

            privateDatabase.save(record) { savedRecord, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error saving podcast feed to CloudKit: \(error.localizedDescription)")
                        completion(false, nil)
                    } else {
                        print("CloudKit podcast feed record saved successfully")
                        completion(true, savedRecord?.recordID.recordName)
                    }
                }
            }
        }
    
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed, completion: @escaping (Bool, String?) -> Void) {
            let record = CKRecord(recordType: "PodcastFeed", recordID: CKRecord.ID(recordName: feed.id))
            record["title"] = feed.title
            record["url"] = feed.url
            record["artworkUrl"] = feed.artworkUrl
            record["iconData"] = feed.iconData

            privateDatabase.save(record) { savedRecord, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error saving podcast feed to CloudKit: \(error.localizedDescription)")
                        completion(false, nil)
                    } else {
                        print("CloudKit podcast feed record saved successfully")
                        completion(true, savedRecord?.recordID.recordName)
                    }
                }
            }
        }

    func fetchPodcastFeedsFromCloudKit(completion: @escaping ([PodcastFeed]?, Error?) -> Void) {
            let query = CKQuery(recordType: "PodcastFeed", predicate: NSPredicate(value: true))
            
            privateDatabase.perform(query, inZoneWith: nil) { records, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error fetching podcast feeds: \(error.localizedDescription)")
                        completion(nil, error)
                        return
                    }

                    guard let records = records else {
                        print("No podcast feed records found in CloudKit.")
                        completion([], nil)
                        return
                    }

                    let feeds = records.compactMap { record -> PodcastFeed? in
                        guard let title = record["title"] as? String,
                              let url = record["url"] as? String else {
                            return nil
                        }
                        let artworkUrl = record["artworkUrl"] as? String
                        let iconData = record["iconData"] as? String
                        return PodcastFeed(id: record.recordID.recordName, title: title, url: url, artworkUrl: artworkUrl, iconData: iconData)
                    }
                    print("Fetched \(feeds.count) podcast feeds from CloudKit.")
                    completion(feeds, nil)
                }
            }
        }

    func deletePodcastFeedFromCloudKit(_ feed: PodcastFeed, completion: @escaping (Bool) -> Void) {
            let recordID = CKRecord.ID(recordName: feed.id)
            
            privateDatabase.delete(withRecordID: recordID) { (recordID, error) in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error deleting podcast feed from CloudKit: \(error.localizedDescription)")
                        completion(false)
                    } else {
                        print("Successfully deleted podcast feed from CloudKit")
                        completion(true)
                    }
                }
            }
        }

    func updatePodcastFeedInCloudKit(_ podcastFeed: PodcastFeed, completion: @escaping (Bool, String?) -> Void) {
        let podcastRecordID = CKRecord.ID(recordName: podcastFeed.id)

        privateDatabase.fetch(withRecordID: podcastRecordID) { fetchedPodcastRecord, error in
            if let fetchedPodcastRecord = fetchedPodcastRecord {
                fetchedPodcastRecord["podcastTitle"] = podcastFeed.title
                fetchedPodcastRecord["podcastUrl"] = podcastFeed.url

                self.privateDatabase.save(fetchedPodcastRecord) { savedPodcastRecord, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            print("Error updating podcast feed record in CloudKit: \(error.localizedDescription)")
                            completion(false, nil)
                        } else {
                            print("CloudKit podcast feed record updated successfully")
                            completion(true, savedPodcastRecord?.recordID.recordName)
                        }
                    }
                }
            } else {
                // If the record doesn't exist, create a new one
                self.savePodcastFeedToCloudKit(podcastFeed, completion: completion)
            }
        }
    }
    
    func deleteRecordsInBatches(recordIDs: [CKRecord.ID], completion: @escaping (Bool, Error?) -> Void) {
           let maxBatchSize = 400
           var index = 0
           
           // Recursive function to handle batch deletion
           func deleteNextBatch() {
               if index >= recordIDs.count {
                   completion(true, nil)  // All batches processed successfully
                   return
               }
               
               let nextBatchLimit = min(index + maxBatchSize, recordIDs.count)
               let batch = Array(recordIDs[index..<nextBatchLimit])
               let modifyOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)
               
               modifyOperation.modifyRecordsCompletionBlock = { _, deletedRecordIDs, error in
                   guard error == nil else {
                       completion(false, error)  // Stop and return on first error
                       return
                   }
                   
                   index += maxBatchSize
                   deleteNextBatch()  // Process the next batch
               }
               
               modifyOperation.savePolicy = .allKeys
               self.privateDatabase.add(modifyOperation)
           }
           
           deleteNextBatch()  // Start the first batch
       }
    
    func fetchAllRecordIDs(ofType recordType: String, completion: @escaping ([CKRecord.ID]?, Error?) -> Void) {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        var recordIDs: [CKRecord.ID] = []
        
        let queryOperation = CKQueryOperation(query: query)
        queryOperation.recordFetchedBlock = { record in
            recordIDs.append(record.recordID)
        }
        
        queryOperation.queryCompletionBlock = { cursor, error in
            if let error = error {
                completion(nil, error)
            } else if let cursor = cursor {
                // If there's more data to fetch, continue fetching
                self.continueFetchingRecordIDs(cursor: cursor, currentRecordIDs: recordIDs, completion: completion)
            } else {
                // All data has been fetched
                completion(recordIDs, nil)
            }
        }
        
        self.privateDatabase.add(queryOperation)
    }

    private func continueFetchingRecordIDs(cursor: CKQueryOperation.Cursor, currentRecordIDs: [CKRecord.ID], completion: @escaping ([CKRecord.ID]?, Error?) -> Void) {
        let continuedOperation = CKQueryOperation(cursor: cursor)
        var newRecordIDs = currentRecordIDs // Copy current IDs to a new variable
        
        continuedOperation.recordFetchedBlock = { record in
            newRecordIDs.append(record.recordID) // Append to the new variable
        }
        
        continuedOperation.queryCompletionBlock = { cursor, error in
            if let error = error {
                completion(nil, error)
            } else if let cursor = cursor {
                // Continue fetching if there are more records
                self.continueFetchingRecordIDs(cursor: cursor, currentRecordIDs: newRecordIDs, completion: completion)
            } else {
                // All records have been fetched
                completion(newRecordIDs, nil)
            }
        }
        
        self.privateDatabase.add(continuedOperation)
    }


    
    // Send a notification about the operation's start
    private func notifyStartOfOperation(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "CloudKit Operation Started"
        content.body = message
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling operation start notification: \(error)")
            }
        }
    }
    
    // Send a notification about the operation's completion
    private func notifyCompletionOfOperation(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "CloudKit Operation Completed"
        content.body = message
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling operation completion notification: \(error)")
            }
        }
    }
    
    // Example usage in a CloudKit operation
    func deleteAllRecords(ofType recordType: String, completion: @escaping (Bool, Error?) -> Void) {
        notifyStartOfOperation(message: "Starting to delete all records of type \(recordType).")
        var recordIDsToDelete = [CKRecord.ID]()
        
        func fetchRecords(cursor: CKQueryOperation.Cursor?) {
            let queryOperation = cursor != nil ? CKQueryOperation(cursor: cursor!) : CKQueryOperation(query: CKQuery(recordType: recordType, predicate: NSPredicate(value: true)))
            queryOperation.recordFetchedBlock = { record in
                recordIDsToDelete.append(record.recordID)
            }
            queryOperation.queryCompletionBlock = { newCursor, error in
                if let error = error {
                    DispatchQueue.main.async {
                        print("Failed to fetch records for deletion: \(error.localizedDescription)")
                        completion(false, error)
                    }
                } else if let newCursor = newCursor {
                    fetchRecords(cursor: newCursor)
                } else {
                    self.deleteRecordsInBatches(recordIDs: recordIDsToDelete, completion: completion)
                }
            }
            privateDatabase.add(queryOperation)
        }
        
        fetchRecords(cursor: nil)
    }
    
   

    func saveImageToFileSystem(image: UIImage) -> String? {
            guard let data = image.jpegData(compressionQuality: 0.5) else { return nil }
            let fileName = UUID().uuidString + ".jpg"
            let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
            do {
                try data.write(to: fileURL)
                print("Image saved to filesystem at URL: \(fileURL.path)")  // Print the file path
                return fileName
            } catch {
                print("Error saving image to file system:", error)
                return nil
            }
        }

    func loadImageFromFileSystem(fileName: String) -> UIImage? {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
        return UIImage(contentsOfFile: fileURL.path)
    }

    private func createAsset(from image: UIImage) -> CKAsset? {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        if let imageData = image.jpegData(compressionQuality: 0.8) {
            do {
                try imageData.write(to: fileURL)
                return CKAsset(fileURL: fileURL)
            } catch {
                print("Error writing image data to file: \(error)")
                return nil
            }
        }
        return nil
    }

    func saveNewStationToCloudKit(station: RadioStation, iconImage: UIImage?, completion: @escaping (Bool, String?) -> Void) {
        let iconFileName = iconImage.flatMap { saveImageToFileSystem(image: $0) }
        let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id))
        record.setValue(station.name, forKey: "name")
        record.setValue(station.url, forKey: "url")
        record.setValue(station.isFavorite ? "true" : "false", forKey: "isFavorite")  // Store isFavorite as a String
        record.setValue(station.country, forKey: "country")  // Store country

        if let iconFileName = iconFileName, let image = loadImageFromFileSystem(fileName: iconFileName) {
            if let asset = createAsset(from: image) {
                record.setValue(asset, forKey: "iconData")
            }
        }

        privateDatabase.save(record) { savedRecord, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error saving record to CloudKit: \(error.localizedDescription)")
                    completion(false, nil)
                } else {
                    print("CloudKit station record saved successfully")
                    completion(true, savedRecord?.recordID.recordName)
                }
            }
        }
    }
    
    // Add a method to fetch existing station IDs from CloudKit
    private func fetchExistingStationIDs(completion: @escaping (Set<String>, Error?) -> Void) {
            let query = CKQuery(recordType: "streamingRadios", predicate: NSPredicate(value: true))
            privateDatabase.perform(query, inZoneWith: nil) { records, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Failed to fetch existing station IDs: \(error.localizedDescription)")
                        completion([], error)
                    } else {
                        let ids = Set(records?.map { $0.recordID.recordName } ?? [])
                        completion(ids, nil)
                    }
                }
            }
        }

    // Modify the saveStationsToCloudKit method to only save new stations
    func saveStationsToCloudKit(stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        fetchExistingStationIDs { existingIDs, error in
            guard error == nil else {
                print("Error fetching existing station IDs: \(error?.localizedDescription ?? "Unknown error")")
                completion(false, nil)
                return
            }

            let newStations = stations.filter { !existingIDs.contains($0.id) }
            if newStations.isEmpty {
                print("No new stations to save; all stations already exist in CloudKit.")
                completion(true, [])
                return
            }

            self.processNewStations(newStations, completion: completion)
        }
    }


    // Method to process and save new stations
    private func processNewStations(_ stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        var recordsToSave = [CKRecord]()
        for station in stations {
            let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id))
            record["name"] = station.name
            record["url"] = station.url
            record["country"] = station.country
            record["isFavorite"] = station.isFavorite ? "true" : "false"
            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                if let asset = createAsset(from: image) {
                    record["iconData"] = asset
                }
            }
            recordsToSave.append(record)
        }

        // Process batches
        processBatch(records: recordsToSave, maxBatchSize: 400, completion: completion)
    }

    private func processBatch(records: [CKRecord], maxBatchSize: Int, start: Int = 0, completion: @escaping (Bool, [String]?) -> Void) {
        let end = min(start + maxBatchSize, records.count)
        let batch = Array(records[start..<end])
        let modifyOperation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)

        modifyOperation.modifyRecordsCompletionBlock = { savedRecords, _, error in
            if let error = error {
                print("Error during CloudKit batch save: \(error.localizedDescription)")
                completion(false, nil)
            } else {
                if end >= records.count {
                    print("Successfully saved all batches to CloudKit.")
                    completion(true, savedRecords?.map { $0.recordID.recordName })
                } else {
                    print("Processing next batch for CloudKit save.")
                    self.processBatch(records: records, maxBatchSize: maxBatchSize, start: end, completion: completion)
                }
            }
        }

        modifyOperation.perRecordCompletionBlock = { record, error in
            if let error = error {
                print("Error saving record \(record.recordID.recordName) to CloudKit: \(error.localizedDescription)")
            } else {
                print("Successfully saved record \(record.recordID.recordName) to CloudKit.")
            }
        }
        CKContainer.default().privateCloudDatabase.add(modifyOperation)
    }
    
    private func updateExistingRecord(recordID: CKRecord.ID, with record: CKRecord, completion: @escaping (Bool) -> Void) {
            privateDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
                if let fetchedRecord = fetchedRecord {
                    fetchedRecord["name"] = record["name"]
                    fetchedRecord["url"] = record["url"]
                    fetchedRecord["country"] = record["country"]
                    fetchedRecord["isFavorite"] = record["isFavorite"]
                    if let iconAsset = record["iconData"] as? CKAsset {
                        fetchedRecord["iconData"] = iconAsset
                    }
                    self.privateDatabase.save(fetchedRecord) { savedRecord, error in
                        if let error = error {
                            print("Error updating record in CloudKit: \(error.localizedDescription)")
                            completion(false)
                        } else {
                            completion(true)
                        }
                    }
                } else {
                    completion(false)
                }
            }
        }

    
    func fetchRadioStations(completion: @escaping ([RadioStation]?, Error?) -> Void) {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "streamingRadios", predicate: predicate)
        
        privateDatabase.perform(query, inZoneWith: nil) { records, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error fetching radio stations: \(error.localizedDescription)")
                    completion(nil, error)
                    return
                }

                guard let records = records else {
                    print("No records found in CloudKit.")
                    completion([], nil)
                    return
                }

                let stations = records.compactMap { record -> RadioStation? in
                    guard let name = record["name"] as? String,
                          let url = record["url"] as? String,
                          let country = record["country"] as? String else {
                        print("Essential data missing in record; skipping...")
                        return nil
                    }

                    let iconData = self.decodeIconData(record: record)
                    let isFavorite = (record["isFavorite"] as? String)?.lowercased() == "true"
                    let id = record.recordID.recordName

                    return RadioStation(
                        id: id,
                        name: name,
                        url: url,
                        iconData: iconData,
                        country: country,
                        isFavorite: isFavorite
                    )
                }
                print("Fetched \(stations.count) stations from CloudKit.")
                completion(stations, nil)
            }
        }
    }
    
    private func decodeIconData(record: CKRecord) -> String? {
        if let asset = record["iconData"] as? CKAsset, let data = try? Data(contentsOf: asset.fileURL.unsafelyUnwrapped) {
            return data.base64EncodedString()
        } else if let base64String = record["iconData"] as? String {
            return base64String
        }
        return nil
    }

    func deleteStationFromCloudKit(station: RadioStation, completion: @escaping (Bool) -> Void) {
        let recordID = CKRecord.ID(recordName: station.id)

            // Ensuring operation is on the main queue to handle UI updates or subsequent calls safely
            DispatchQueue.main.async {
                self.privateDatabase.delete(withRecordID: recordID) { deletedRecordID, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.handleCloudKitError(error, operation: "delete")
                            completion(false)
                        } else {
                            print("CloudKit station record deleted successfully, Record ID: \(deletedRecordID?.recordName ?? "Unknown")")
                            completion(true)
                        }
                    }
                }
            }
        }

        private func handleCloudKitError(_ error: Error, operation: String) {
            let ckError = error as? CKError
            let errorMessage = ckError?.localizedDescription ?? "Unknown error"
            let reason = ckError?.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval ?? 0
            print("Failed to \(operation) record from CloudKit. Error: \(errorMessage), retry after: \(reason) seconds")
        }

    func updateStationInCloudKit(station: RadioStation, iconImage: UIImage?, completion: @escaping (Bool, String?) -> Void) {
        let recordID = CKRecord.ID(recordName: station.id)

        privateDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
            if let fetchedRecord = fetchedRecord {
                fetchedRecord.setValue(station.name, forKey: "name")
                fetchedRecord.setValue(station.url, forKey: "url")
                fetchedRecord.setValue(station.isFavorite ? "true" : "false", forKey: "isFavorite")  // Store isFavorite as a String
                fetchedRecord.setValue(station.country, forKey: "country")  // Store country

                if let iconImage = iconImage, let asset = self.createAsset(from: iconImage) {
                    fetchedRecord.setValue(asset, forKey: "iconData")
                }

                self.privateDatabase.save(fetchedRecord) { savedRecord, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            print("Error updating record in CloudKit: \(error.localizedDescription)")
                            completion(false, nil)
                        } else {
                            print("CloudKit station record updated successfully")
                            completion(true, savedRecord?.recordID.recordName)
                        }
                    }
                }
            } else {
                self.saveNewStationToCloudKit(station: station, iconImage: iconImage, completion: completion)
            }
        }
    }
}
