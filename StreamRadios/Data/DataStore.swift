//  DataStore.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/26/24.

import UIKit
import CloudKit

class DataStore {
    static let shared = DataStore()
    private let privateDatabase = CKContainer.default().privateCloudDatabase
    
    // Save image to file system and return file path
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
    
    // Load image from file system by file path
    func loadImageFromFileSystem(fileName: String) -> UIImage? {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    // Helper function to create a CKAsset from a UIImage
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
    
    // Save a new radio station to CloudKit
    func saveNewStationToCloudKit(station: RadioStation, iconImage: UIImage?, completion: @escaping (Bool, String?) -> Void) {
        let iconFileName = iconImage.flatMap { saveImageToFileSystem(image: $0) }
        let record = CKRecord(recordType: "streamingRadios", recordID: CKRecord.ID(recordName: station.id.uuidString))
        record.setValue(station.name, forKey: "name")
        record.setValue(station.url, forKey: "url")
        
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
    
    // Fetch all radio stations from CloudKit
    func fetchRadioStations(completion: @escaping ([RadioStation]?, Error?) -> Void) {
        let predicate = NSPredicate(value: true)  // Fetches all records
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
                        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()
                        return RadioStation(id: id, name: name, url: url, iconData: iconData)
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
    
    // Update station in CloudKit
        func updateStationInCloudKit(station: RadioStation, iconImage: UIImage?, completion: @escaping (Bool, String?) -> Void) {
            let recordID = CKRecord.ID(recordName: station.id.uuidString)
            
            privateDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
                var record: CKRecord
                if let fetchedRecord = fetchedRecord {
                    record = fetchedRecord
                } else {
                    record = CKRecord(recordType: "streamingRadios", recordID: recordID)
                }
                
                record.setValue(station.name, forKey: "name")
                record.setValue(station.url, forKey: "url")
                
                if let iconImage = iconImage, let asset = self.createAsset(from: iconImage) {
                    record.setValue(asset, forKey: "iconData")
                }
                
                self.privateDatabase.save(record) { savedRecord, error in
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
            }
        }}
