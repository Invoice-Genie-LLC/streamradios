// DataStore.swift
// StreamRadios
//
// Created by Kley Sulo on 6/26/24.

import UIKit
import CloudKit

class DataStore {
    static let shared = DataStore()
    private let privateDatabase = CKContainer.default().privateCloudDatabase

    func saveImageToFileSystem(image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.5) else { return nil }
        let fileName = UUID().uuidString + ".jpg"
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
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
        let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id.uuidString))
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
    
    func saveStationsToCloudKit(stations: [RadioStation], completion: @escaping (Bool, [String]?) -> Void) {
        // Map station IDs to CKRecord.ID objects
        let recordIDs = stations.map { CKRecord.ID(recordName: $0.id.uuidString) }
        
        // Create a predicate that checks if any recordIDs already exist in CloudKit
        let predicate = NSPredicate(format: "recordID IN %@", recordIDs)
        let query = CKQuery(recordType: "streamingRadios", predicate: predicate)

        // Perform the query
        privateDatabase.perform(query, inZoneWith: nil) { existingRecords, error in
            if let error = error {
                print("Error fetching existing records: \(error.localizedDescription)")
                completion(false, nil)
                return
            }
            
            // Create a set of existing record IDs
            let existingRecordIDs = Set(existingRecords?.map { $0.recordID } ?? [])
            
            // Filter out stations that already exist in CloudKit
            let recordsToSave = stations.filter { !existingRecordIDs.contains(CKRecord.ID(recordName: $0.id.uuidString)) }.map { station -> CKRecord in
                let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id.uuidString))
                record["name"] = station.name
                record["url"] = station.url
                record["country"] = station.country
                record["isFavorite"] = station.isFavorite ? "true" : "false"

                if let iconData = station.iconData, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                    if let asset = self.createAsset(from: image) {
                        record["iconData"] = asset
                    }
                }
                return record
            }

            // Only proceed if there are new records to save
            if recordsToSave.isEmpty {
                print("No new stations to save to CloudKit.")
                completion(true, [])
                return
            }

            // Prepare the operation to save new records
            let modifyOperation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: nil)
            modifyOperation.savePolicy = .allKeys
            modifyOperation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
                if let error = error {
                    print("Error saving new records to CloudKit: \(error.localizedDescription)")
                    completion(false, nil)
                } else {
                    let savedRecordIDs = savedRecords?.map { $0.recordID.recordName }
                    completion(true, savedRecordIDs)
                }
            }
            CKContainer.default().privateCloudDatabase.add(modifyOperation)
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
                } else {
                    let stations = records?.compactMap { record -> RadioStation? in
                        guard let name = record["name"] as? String,
                              let url = record["url"] as? String else {
                            return nil
                        }
                        let iconData = self.decodeIconData(record: record)
                        let isFavorite = (record["isFavorite"] as? String) == "true"  // Convert to Bool
                        let country = record["country"] as? String ?? "Unknown Region"  // Retrieve country
                        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()
                        return RadioStation(id: id, name: name, url: url, iconData: iconData, country: country, isFavorite: isFavorite)
                    }
                    completion(stations, nil)
                }
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
        let recordID = CKRecord.ID(recordName: station.id.uuidString)
        privateDatabase.delete(withRecordID: recordID) { recordID, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error deleting record from CloudKit: \(error.localizedDescription)")
                    completion(false)
                } else {
                    print("CloudKit station record deleted successfully")
                    completion(true)
                }
            }
        }
    }

    func updateStationInCloudKit(station: RadioStation, iconImage: UIImage?, completion: @escaping (Bool, String?) -> Void) {
        let recordID = CKRecord.ID(recordName: station.id.uuidString)

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
