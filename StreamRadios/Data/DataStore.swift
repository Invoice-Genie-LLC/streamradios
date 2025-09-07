// DataStore.swift
// StreamRadios
//
// Created by Kley Sulo on 6/26/24.

import UIKit
import CloudKit
import os

class DataStore {
    static let shared = DataStore()
    private let privateDatabase = CKContainer.default().privateCloudDatabase
    private let log = OSLog(subsystem: "com.yourapp.StreamRadios", category: "DataStore")

    
    func savePodcastFeedToCloudKit(_ feed: PodcastFeed, completion: @escaping (Bool, String?) -> Void) {
            let record = CKRecord(recordType: "PodcastFeed", recordID: CKRecord.ID(recordName: feed.id))
            record["title"] = feed.title
            record["url"] = feed.url
            record["artworkUrl"] = feed.artworkUrl
            
            let group = DispatchGroup()
            
            // Handle icon image
            if let iconDataString = feed.iconData, let iconData = Data(base64Encoded: iconDataString) {
                group.enter()
                os_log("Attempting to save icon data for feed: %@", log: log, type: .debug, feed.title)
                saveImageToCloudKit(imageData: iconData, forKey: "iconData", in: record) {
                    os_log("Icon data saved successfully for feed: %@", log: self.log, type: .debug, feed.title)
                    group.leave()
                }
            } else if let artworkUrl = feed.artworkUrl, let url = URL(string: artworkUrl) {
                group.enter()
                os_log("Attempting to download and save artwork for feed: %@", log: log, type: .debug, feed.title)
                downloadImage(from: url) { data in
                    if let data = data {
                        self.saveImageToCloudKit(imageData: data, forKey: "iconData", in: record) {
                            os_log("Downloaded artwork saved successfully for feed: %@", log: self.log, type: .debug, feed.title)
                            group.leave()
                        }
                    } else {
                        os_log("Failed to download artwork for feed: %@", log: self.log, type: .error, feed.title)
                        group.leave()
                    }
                }
            } else {
                os_log("No icon data or artwork URL available for feed: %@", log: log, type: .debug, feed.title)
            }
            
            // Handle main image data
            if let imageData = feed.imageData {
                group.enter()
                os_log("Attempting to save main image data for feed: %@", log: log, type: .debug, feed.title)
                saveImageToCloudKit(imageData: imageData, forKey: "image", in: record) {
                    os_log("Main image data saved successfully for feed: %@", log: self.log, type: .debug, feed.title)
                    group.leave()
                }
            } else {
                os_log("No main image data available for feed: %@", log: log, type: .debug, feed.title)
            }
            
            group.notify(queue: .main) {
                os_log("Saving podcast feed record to CloudKit for feed: %@", log: self.log, type: .debug, feed.title)
                self.privateDatabase.save(record) { savedRecord, error in
                    if let error = error {
                        os_log("Error saving podcast feed to CloudKit: %{public}@", log: self.log, type: .error, error.localizedDescription)
                        completion(false, nil)
                    } else {
                        os_log("CloudKit podcast feed record saved successfully for feed: %@", log: self.log, type: .debug, feed.title)
                        completion(true, savedRecord?.recordID.recordName)
                    }
                }
            }
        }
    
    private func saveImageToCloudKit(imageData: Data, forKey key: String, in record: CKRecord, completion: @escaping () -> Void) {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            do {
                try imageData.write(to: tempURL)
                record[key] = CKAsset(fileURL: tempURL)
                os_log("Image data saved to temp file for key: %{public}@", log: log, type: .debug, key)
                completion()
            } catch {
                os_log("Error saving image to temp file: %{public}@", log: log, type: .error, error.localizedDescription)
                completion()
            }
        }
    
    
    private func downloadImage(from url: URL, completion: @escaping (Data?) -> Void) {
           URLSession.shared.dataTask(with: url) { data, response, error in
               if let error = error {
                   os_log("Error downloading image: %{public}@", log: self.log, type: .error, error.localizedDescription)
                   completion(nil)
               } else if let data = data {
                   os_log("Image downloaded successfully, size: %d bytes", log: self.log, type: .debug, data.count)
                   completion(data)
               } else {
                   os_log("No data received when downloading image", log: self.log, type: .error)
                   completion(nil)
               }
           }.resume()
       }
    
    func fetchPodcastFeedsFromCloudKit(completion: @escaping ([PodcastFeed]?, Error?) -> Void) {
            let query = CKQuery(recordType: "PodcastFeed", predicate: NSPredicate(value: true))
            
            privateDatabase.perform(query, inZoneWith: nil) { records, error in
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
                    let iconData = self.retrieveImageData(from: record, forKey: "iconData")
                    let imageData = self.retrieveImageData(from: record, forKey: "image")
                    
                    return PodcastFeed(
                        id: record.recordID.recordName,
                        title: title,
                        url: url,
                        artworkUrl: artworkUrl,
                        iconData: iconData?.base64EncodedString(),
                        imageData: imageData
                    )
                }
                print("Fetched \(feeds.count) podcast feeds from CloudKit.")
                completion(feeds, nil)
            }
        }
    
    private func retrieveImageData(from record: CKRecord, forKey key: String) -> Data? {
           if let asset = record[key] as? CKAsset, let url = asset.fileURL {
               return try? Data(contentsOf: url)
           }
           return nil
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
    
    func deleteRecordsInBatches(recordIDs: [CKRecord.ID], completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                try await deleteRecordsInBatchesAsync(recordIDs: recordIDs) { progress in
                    // Legacy completion doesn't handle progress, but we can log it
                    print("🔄 Deletion progress: \(Int(progress * 100))%")
                }
                completion(true, nil)
            } catch {
                completion(false, error)
            }
        }
    }
    
    /// Enhanced async batch deletion with progress reporting, adaptive splitting, and pacing to avoid throttling
    func deleteRecordsInBatchesAsync(
        recordIDs: [CKRecord.ID],
        progressHandler: @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard !recordIDs.isEmpty else {
            print("✅ No records to delete")
            await MainActor.run {
                progressHandler(1.0)
            }
            return
        }
        
        // Start conservatively to reduce likelihood of throttling, can split further if needed
        let initialBatchSize = 100
        let batches = recordIDs.chunked(into: initialBatchSize)
        
        print("🗑️ Starting deletion of \(recordIDs.count) records in \(batches.count) batches")
        
        var completedBatches = 0
        var totalDeleted = 0
        
        // Process batches sequentially with light pacing
        for (batchIndex, batch) in batches.enumerated() {
            let deletedInBatch = try await deleteBatchAdaptive(
                batch: batch,
                batchNumber: batchIndex + 1,
                totalBatches: batches.count
            )
            
            totalDeleted += deletedInBatch
            completedBatches += 1
            
            // Report progress
            let progress = Double(completedBatches) / Double(batches.count)
            await MainActor.run {
                progressHandler(progress)
            }
            
            print("✅ Completed batch \(completedBatches)/\(batches.count) - Total deleted: \(totalDeleted)")
            // Light pacing to reduce chance of rate limiting
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        
        print("🎉 Successfully deleted all \(totalDeleted) records from CloudKit in \(batches.count) batches")
        await MainActor.run {
            progressHandler(1.0)
        }
    }
    
    /// Delete a batch adaptively: try whole batch, on throttling split into smaller sub-batches recursively
    private func deleteBatchAdaptive(
        batch: [CKRecord.ID],
        batchNumber: Int,
        totalBatches: Int,
        minBatchSize: Int = 25
    ) async throws -> Int {
        do {
            return try await deleteBatchWithRetry(
                batch: batch,
                batchNumber: batchNumber,
                totalBatches: totalBatches,
                maxRetries: 5
            )
        } catch {
            // If throttled or server stressed, split batch and process smaller chunks
            if let ckError = error as? CKError,
               (ckError.code == .requestRateLimited || ckError.code == .serviceUnavailable || ckError.code == .limitExceeded),
               batch.count > minBatchSize {
                let midpoint = batch.count / 2
                let firstHalf = Array(batch[..<midpoint])
                let secondHalf = Array(batch[midpoint...])
                print("⤵️ Throttled on batch \(batchNumber). Splitting into \(firstHalf.count)+\(secondHalf.count) and retrying adaptively…")
                let firstDeleted = try await deleteBatchAdaptive(
                    batch: firstHalf,
                    batchNumber: batchNumber,
                    totalBatches: totalBatches,
                    minBatchSize: minBatchSize
                )
                let secondDeleted = try await deleteBatchAdaptive(
                    batch: secondHalf,
                    batchNumber: batchNumber,
                    totalBatches: totalBatches,
                    minBatchSize: minBatchSize
                )
                return firstDeleted + secondDeleted
            }
            throw error
        }
    }
    
    /// Delete a single batch with automatic retry logic
    private func deleteBatchWithRetry(
        batch: [CKRecord.ID],
        batchNumber: Int,
        totalBatches: Int,
        maxRetries: Int = 3
    ) async throws -> Int {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                print("🗑️ Deleting batch \(batchNumber)/\(totalBatches) (\(batch.count) records) - Attempt \(attempt)")
                
                let deletedRecordIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { continuation in
                    let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)
                    operation.savePolicy = .allKeys
                    operation.qualityOfService = .userInitiated
                    operation.isAtomic = false // Allow partial success for large batches
                    
                    operation.modifyRecordsCompletionBlock = { _, deletedRecordIDs, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: deletedRecordIDs ?? [])
                        }
                    }
                    
                    operation.perRecordCompletionBlock = { record, error in
                        if let error = error {
                            if let ckError = error as? CKError {
                                let recordName = record.recordID.recordName
                                switch ckError.code {
                                case .unknownItem:
                                    print("🔍 Record \(recordName) already deleted")
                                case .networkFailure, .networkUnavailable:
                                    print("🌐 Network error for record \(recordName): \(error.localizedDescription)")
                                default:
                                    print("❌ Error deleting record \(recordName): \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                    
                    privateDatabase.add(operation)
                }
                
                print("✅ Successfully deleted batch \(batchNumber)/\(totalBatches) (\(deletedRecordIDs.count) records)")
                return deletedRecordIDs.count
                
            } catch {
                lastError = error
                
                // Handle rate limiting with exponential backoff
                if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval ?? Double(attempt * 2)
                    print("⏱️ Rate limited. Retrying batch \(batchNumber) after \(retryAfter) seconds... (Attempt \(attempt)/\(maxRetries))")
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    continue
                }
                
                // Handle network errors with shorter retry delay
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .networkFailure, .networkUnavailable, .serviceUnavailable:
                        let retryDelay = min(Double(attempt * attempt), 10.0) // Exponential backoff, max 10s
                        print("🌐 Network/service error. Retrying batch \(batchNumber) after \(retryDelay) seconds... (Attempt \(attempt)/\(maxRetries))")
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        continue
                    case .internalError, .serverRejectedRequest:
                        print("🚫 Server error for batch \(batchNumber): \(error.localizedDescription)")
                        if attempt < maxRetries {
                            let retryDelay = Double(attempt * 3)
                            print("🔄 Retrying batch \(batchNumber) after \(retryDelay) seconds... (Attempt \(attempt)/\(maxRetries))")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            continue
                        }
                    default:
                        break
                    }
                }
                
                // For non-retryable errors or final attempt, break the loop
                if attempt == maxRetries {
                    print("❌ Failed to delete batch \(batchNumber) after \(maxRetries) attempts: \(error.localizedDescription)")
                    throw error
                }
            }
        }
        
        throw lastError ?? NSError(domain: "DataStoreDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown deletion error"])
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
        record.setValue(station.favoritedAt, forKey: "favoritedAt")  // Store favoritedAt timestamp
        record.setValue(station.favoriteOrder, forKey: "favoriteOrder")  // Store favoriteOrder
        record.setValue(station.order, forKey: "order")  // Store order
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
    
    // Add a method to fetch existing station URLs from CloudKit
    private func fetchExistingStationURLs(completion: @escaping (Set<String>, Error?) -> Void) {
            let query = CKQuery(recordType: "streamingRadios", predicate: NSPredicate(value: true))
            privateDatabase.perform(query, inZoneWith: nil) { records, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Failed to fetch existing station URLs: \(error.localizedDescription)")
                        completion([], error)
                    } else {
                        let urls = Set(records?.compactMap { $0["url"] as? String } ?? [])
                        completion(urls, nil)
                    }
                }
            }
        }

    // Save stations to CloudKit - replaces all existing stations
    func saveStationsToCloudKit(stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        // During import, we want to force save all stations regardless of existing ones
        // This ensures fresh data replaces any potentially stale CloudKit records
        processAllStations(stations, completion: completion)
    }
    
    // Original method for incremental saves (used elsewhere)
    func saveNewStationsToCloudKit(stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        // CRITICAL: First filter out any manual stations that shouldn't be saved during API fetch
        let nonManualStations = stations.filter { station in
            let isManual = station.id.hasPrefix("manual_")
            if isManual {
                print("📻 🚫 DATASTORE EXCLUSION: Manual station \(station.name) (ID: \(station.id)) excluded from CloudKit save in DataStore")
            }
            return !isManual
        }
        
        if nonManualStations.count != stations.count {
            print("📻 ⚠️ DATASTORE: Filtered out \(stations.count - nonManualStations.count) manual stations from CloudKit save")
        }
        
        fetchExistingStationIDs { existingIDs, error in
            guard error == nil else {
                print("Error fetching existing station IDs: \(error?.localizedDescription ?? "Unknown error")")
                completion(false, nil)
                return
            }

            let newStations = nonManualStations.filter { !existingIDs.contains($0.id) }
            if newStations.isEmpty {
                print("No new stations to save; all stations already exist in CloudKit.")
                completion(true, [])
                return
            }

            self.processNewStations(newStations, completion: completion)
        }
    }
    
    // Method specifically for import operations - checks for URL duplicates
    func saveImportedStationsToCloudKit(stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        fetchExistingStationURLs { existingURLs, error in
            guard error == nil else {
                print("Error fetching existing station URLs: \(error?.localizedDescription ?? "Unknown error")")
                completion(false, nil)
                return
            }

            let newStations = stations.filter { !existingURLs.contains($0.url) }
            if newStations.isEmpty {
                print("No new stations to save; all station URLs already exist in CloudKit.")
                completion(true, [])
                return
            }

            print("Saving \(newStations.count) new stations to CloudKit (filtered by URL).")
            self.processNewStations(newStations, completion: completion)
        }
    }


    // Method to process and save all stations (used during import)
    private func processAllStations(_ stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        var recordsToSave = [CKRecord]()
        for station in stations {
            let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id))
            record["name"] = station.name
            record["url"] = station.url
            record["country"] = station.country
            record["isFavorite"] = station.isFavorite ? "true" : "false"
            record["favoritedAt"] = station.favoritedAt
            record["favoriteOrder"] = station.favoriteOrder
            record["order"] = station.order
            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                if let asset = createAsset(from: image) {
                    record["iconData"] = asset
                }
            }
            recordsToSave.append(record)
        }

        // Process batches - this will create or update records as needed
        processBatch(records: recordsToSave, maxBatchSize: 200, completion: completion)
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
            record["favoritedAt"] = station.favoritedAt
            record["favoriteOrder"] = station.favoriteOrder
            record["order"] = station.order
            if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                if let asset = createAsset(from: image) {
                    record["iconData"] = asset
                }
            }
            recordsToSave.append(record)
        }

        // Process batches with optimized batch size for CloudKit
        processBatch(records: recordsToSave, maxBatchSize: 200, completion: completion)
    }

    private func processBatch(records: [CKRecord], maxBatchSize: Int, start: Int = 0, completion: @escaping (Bool, [String]?) -> Void) {
        let end = min(start + maxBatchSize, records.count)
        let batch = Array(records[start..<end])
        let batchNumber = (start / maxBatchSize) + 1
        let totalBatches = (records.count + maxBatchSize - 1) / maxBatchSize
        
        print("Processing CloudKit batch \(batchNumber)/\(totalBatches) (\(batch.count) records)")
        
        let modifyOperation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)
        
        // Set save policy to handle conflicts gracefully
        modifyOperation.savePolicy = .changedKeys
        
        // Configure operation for better performance with large datasets
        modifyOperation.qualityOfService = .userInitiated
        modifyOperation.isLongLived = records.count > 1000 // Use long-lived operations for large datasets

        modifyOperation.modifyRecordsCompletionBlock = { savedRecords, _, error in
            if let error = error {
                print("❌ Error during CloudKit batch \(batchNumber) save: \(error.localizedDescription)")
                
                // Handle rate limiting errors with exponential backoff
                if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    if let retryAfter = ckError.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
                        print("⏱️ Rate limited. Retrying batch \(batchNumber) after \(retryAfter) seconds...")
                        DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                            self.processBatch(records: records, maxBatchSize: maxBatchSize, start: start, completion: completion)
                        }
                        return
                    }
                }
                
                // Continue with next batch even if current batch fails
                if end >= records.count {
                    print("⚠️ Completed processing with errors. Some records may not have been saved.")
                    completion(false, savedRecords?.map { $0.recordID.recordName })
                } else {
                    print("⏭️ Processing next batch despite error in batch \(batchNumber).")
                    self.processBatch(records: records, maxBatchSize: maxBatchSize, start: end, completion: completion)
                }
            } else {
                print("✅ Successfully saved batch \(batchNumber)/\(totalBatches)")
                if end >= records.count {
                    print("🎉 Successfully saved all \(records.count) records to CloudKit in \(totalBatches) batches.")
                    completion(true, savedRecords?.map { $0.recordID.recordName })
                } else {
                    // Continue with next batch
                    self.processBatch(records: records, maxBatchSize: maxBatchSize, start: end, completion: completion)
                }
            }
        }

        modifyOperation.perRecordCompletionBlock = { record, error in
            let recordName = record.recordID.recordName
            if let error = error {
                // Check if it's a specific "record already exists" error and handle it gracefully
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .serverRecordChanged, .unknownItem:
                        print("Record \(recordName) already exists in CloudKit, skipping.")
                    default:
                        print("Error saving record \(recordName) to CloudKit: \(error.localizedDescription)")
                    }
                } else {
                    print("Error saving record \(recordName) to CloudKit: \(error.localizedDescription)")
                }
            } else {
                print("Successfully saved record \(recordName) to CloudKit.")
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
                    fetchedRecord["favoritedAt"] = record["favoritedAt"]
                    fetchedRecord["favoriteOrder"] = record["favoriteOrder"]
                    fetchedRecord["order"] = record["order"]
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
        print("Starting paginated fetch of radio stations from CloudKit...")
        fetchRadioStationsWithPagination(allRecords: [], cursor: nil, completion: completion)
    }
    
    func fetchRadioStationsWithProgress(progressCallback: @escaping (Double, Int, String) -> Void, completion: @escaping ([RadioStation]?, Error?) -> Void) {
        print("Starting paginated fetch of radio stations from CloudKit with progress tracking...")
        fetchRadioStationsWithPaginationAndProgress(allRecords: [], cursor: nil, totalEstimate: nil, progressCallback: progressCallback, completion: completion)
    }
    
    private func fetchRadioStationsWithPagination(allRecords: [CKRecord], cursor: CKQueryOperation.Cursor?, completion: @escaping ([RadioStation]?, Error?) -> Void) {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "streamingRadios", predicate: predicate)
        
        let queryOperation = CKQueryOperation(query: query)
        
        // Set limits to handle large datasets efficiently - optimized for faster fetching
        queryOperation.resultsLimit = 500 // Increased batch size for faster fetching
        queryOperation.cursor = cursor
        
        var fetchedRecords = allRecords
        
        queryOperation.recordMatchedBlock = { recordID, result in
            switch result {
            case .success(let record):
                fetchedRecords.append(record)
            case .failure(let error):
                // RESILIENCE: Skip corrupted/unavailable records instead of failing entire sync
                print("⚠️ Skipping corrupted record \(recordID.recordName): \(error.localizedDescription)")
                // Don't add to fetchedRecords - just continue with other records
            }
        }
        
        queryOperation.queryResultBlock = { result in
            switch result {
            case .success(let cursor):
                if let cursor = cursor {
                    // More records available, continue fetching
                    print("Fetched \(fetchedRecords.count - allRecords.count) records, continuing with pagination...")
                    self.fetchRadioStationsWithPagination(allRecords: fetchedRecords, cursor: cursor, completion: completion)
                } else {
                    // All records fetched
                    print("Completed fetching all \(fetchedRecords.count) records from CloudKit.")
                    self.processAndReturnStations(from: fetchedRecords, completion: completion)
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    print("Error during CloudKit query operation: \(error.localizedDescription)")
                    
                    // RESILIENCE: If we have some successfully fetched records, use them instead of failing entirely
                    if !fetchedRecords.isEmpty {
                        print("🔧 RESILIENCE: Completing sync with \(fetchedRecords.count) successfully fetched records despite CloudKit errors")
                        self.processAndReturnStations(from: fetchedRecords, completion: completion)
                    } else {
                        completion(nil, error)
                    }
                }
            }
        }
        
        privateDatabase.add(queryOperation)
    }
    
    private func fetchRadioStationsWithPaginationAndProgress(allRecords: [CKRecord], cursor: CKQueryOperation.Cursor?, totalEstimate: Int?, progressCallback: @escaping (Double, Int, String) -> Void, completion: @escaping ([RadioStation]?, Error?) -> Void) {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "streamingRadios", predicate: predicate)
        
        let queryOperation = CKQueryOperation(query: query)
        
        // Set optimized limits for faster fetching
        queryOperation.resultsLimit = 500 // Increased batch size for faster fetching
        queryOperation.cursor = cursor
        
        var fetchedRecords = allRecords
        let startingCount = allRecords.count
        
        queryOperation.recordMatchedBlock = { recordID, result in
            switch result {
            case .success(let record):
                fetchedRecords.append(record)
                
                // Report progress for every 50 records or so to avoid too many updates
                if fetchedRecords.count % 50 == 0 || fetchedRecords.count - startingCount == 1 {
                    let currentCount = fetchedRecords.count
                    
                    // Extract country information from recent records for more detailed progress
                    let recentCountries = fetchedRecords.suffix(50).compactMap { record in
                        record["country"] as? String
                    }
                    
                    let uniqueCountries = Array(Set(recentCountries)).sorted()
                    let countryInfo = uniqueCountries.count > 0 ? " from \(uniqueCountries.count) countries" : ""
                    let currentCountry = uniqueCountries.last ?? ""
                    
                    let progressMessage: String
                    if !currentCountry.isEmpty && currentCount > 100 {
                        progressMessage = "Loading \(currentCount) stations - processing \(currentCountry)..."
                    } else if uniqueCountries.count > 1 {
                        progressMessage = "Loading \(currentCount) stations\(countryInfo)..."
                    } else {
                        progressMessage = "Loading \(currentCount) radio stations..."
                    }
                    
                    // Estimate progress - if we have a total estimate, use it, otherwise estimate based on current batch
                    let estimatedProgress: Double
                    if let total = totalEstimate, total > 0 {
                        estimatedProgress = Double(currentCount) / Double(total)
                    } else {
                        // Conservative estimate: assume we're getting decent progress based on current batch
                        estimatedProgress = min(0.9, Double(currentCount) / 1000.0) // Estimate max 1000 stations for conservative progress
                    }
                    
                    DispatchQueue.main.async {
                        progressCallback(estimatedProgress, currentCount, progressMessage)
                    }
                }
            case .failure(let error):
                // RESILIENCE: Skip corrupted/unavailable records instead of failing entire sync
                print("⚠️ Skipping corrupted record \(recordID.recordName): \(error.localizedDescription)")
                // Don't add to fetchedRecords - just continue with other records
            }
        }
        
        queryOperation.queryResultBlock = { result in
            switch result {
            case .success(let cursor):
                let currentCount = fetchedRecords.count
                let batchSize = currentCount - startingCount
                
                if let cursor = cursor {
                    // More records available, continue fetching
                    print("Fetched \(batchSize) records in this batch (\(currentCount) total), continuing with pagination...")
                    
                    // Update progress for this batch completion with country info
                    let allCountries = fetchedRecords.compactMap { record in
                        record["country"] as? String
                    }
                    let uniqueCountries = Array(Set(allCountries)).sorted()
                    let countryCount = uniqueCountries.count
                    
                    let progressMessage: String
                    if countryCount > 1 {
                        progressMessage = "Loaded \(currentCount) stations from \(countryCount) countries, fetching more..."
                    } else {
                        progressMessage = "Loaded \(currentCount) stations, fetching more..."
                    }
                    
                    let estimatedProgress = min(0.9, Double(currentCount) / 1000.0) // Conservative estimate
                    
                    DispatchQueue.main.async {
                        progressCallback(estimatedProgress, currentCount, progressMessage)
                    }
                    
                    // Continue with next batch
                    self.fetchRadioStationsWithPaginationAndProgress(allRecords: fetchedRecords, cursor: cursor, totalEstimate: totalEstimate, progressCallback: progressCallback, completion: completion)
                } else {
                    // All records fetched
                    print("Completed fetching all \(currentCount) records from CloudKit.")
                    
                    // Report final progress with country breakdown
                    let allCountries = fetchedRecords.compactMap { record in
                        record["country"] as? String
                    }
                    let uniqueCountries = Array(Set(allCountries)).sorted()
                    let countryCount = uniqueCountries.count
                    
                    DispatchQueue.main.async {
                        let processingMessage = countryCount > 1 ? 
                            "Processing \(currentCount) stations from \(countryCount) countries..." :
                            "Processing \(currentCount) stations..."
                        progressCallback(0.95, currentCount, processingMessage)
                    }
                    
                    self.processAndReturnStations(from: fetchedRecords) { stations, error in
                        DispatchQueue.main.async {
                            if let stations = stations {
                                let completionMessage = countryCount > 1 ?
                                    "✅ Completed! Loaded \(stations.count) stations from \(countryCount) countries" :
                                    "✅ Completed! Loaded \(stations.count) stations"
                                progressCallback(1.0, stations.count, completionMessage)
                            }
                        }
                        completion(stations, error)
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    print("Error during CloudKit query operation: \(error.localizedDescription)")
                    
                    // RESILIENCE: If we have some successfully fetched records, use them instead of failing entirely
                    if !fetchedRecords.isEmpty {
                        print("🔧 RESILIENCE: Completing sync with \(fetchedRecords.count) successfully fetched records despite CloudKit errors")
                        
                        // Report final progress with what we have
                        let currentCount = fetchedRecords.count
                        let allCountries = fetchedRecords.compactMap { record in
                            record["country"] as? String
                        }
                        let uniqueCountries = Array(Set(allCountries)).sorted()
                        let countryCount = uniqueCountries.count
                        
                        let processingMessage = countryCount > 1 ? 
                            "🔧 Processing \(currentCount) stations from \(countryCount) countries (some records skipped due to errors)..." :
                            "🔧 Processing \(currentCount) stations (some records skipped due to errors)..."
                        progressCallback(0.95, currentCount, processingMessage)
                        
                        self.processAndReturnStations(from: fetchedRecords) { stations, error in
                            DispatchQueue.main.async {
                                if let stations = stations {
                                    let completionMessage = countryCount > 1 ?
                                        "✅ Completed! Loaded \(stations.count) stations from \(countryCount) countries (with error recovery)" :
                                        "✅ Completed! Loaded \(stations.count) stations (with error recovery)"
                                    progressCallback(1.0, stations.count, completionMessage)
                                }
                            }
                            completion(stations, error)
                        }
                    } else {
                        completion(nil, error)
                    }
                }
            }
        }
        
        privateDatabase.add(queryOperation)
    }
    
    private func processAndReturnStations(from records: [CKRecord], completion: @escaping ([RadioStation]?, Error?) -> Void) {
        DispatchQueue.main.async {
            let stations = records.compactMap { record -> RadioStation? in
                guard let name = record["name"] as? String,
                      let url = record["url"] as? String,
                      let country = record["country"] as? String else {
                    print("Essential data missing in record; skipping...")
                    return nil
                }

                let iconData = self.decodeIconData(record: record)
                let isFavorite = (record["isFavorite"] as? String)?.lowercased() == "true"
                let favoritedAt = record["favoritedAt"] as? Date
                let favoriteOrder = record["favoriteOrder"] as? Int
                let order = record["order"] as? Int ?? 0
                let id = record.recordID.recordName

                return RadioStation(
                    id: id,
                    name: name,
                    url: url,
                    iconData: iconData,
                    country: country,
                    isFavorite: isFavorite,
                    favoritedAt: favoritedAt,
                    favoriteOrder: favoriteOrder,
                    order: order
                )
            }
            print("Successfully processed \(stations.count) stations from CloudKit.")
            completion(stations, nil)
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
                fetchedRecord.setValue(station.favoritedAt, forKey: "favoritedAt")  // Store favoritedAt timestamp
                fetchedRecord.setValue(station.favoriteOrder, forKey: "favoriteOrder")  // Store favoriteOrder
                fetchedRecord.setValue(station.order, forKey: "order")  // Store order
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


