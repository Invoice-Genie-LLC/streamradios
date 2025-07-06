// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine
import CoreData
import UniformTypeIdentifiers

// MARK: - Import Error Types
enum ImportError: Error {
    case invalidJSON(String)
    case invalidJSONStructure(String)
    case missingRequiredFields([String])
    case fileReadError(String)
    
    var userFriendlyMessage: String {
        switch self {
        case .invalidJSON(let details):
            return "The selected file contains invalid JSON format. Please check the file structure. Details: \(details)"
        case .invalidJSONStructure(let details):
            return "The JSON structure is not compatible. Expected an array of station objects. Details: \(details)"
        case .missingRequiredFields(let fields):
            return "Required fields are missing from the station data: \(fields.joined(separator: ", ")). Each station must have 'id', 'name', and 'url' fields."
        case .fileReadError(let details):
            return "Could not read the selected file. Details: \(details)"
        }
    }
}

// Sub-tab enum for radio filtering
enum RadioSubTab: Int, CaseIterable {
    case recent = 0
    case favorites = 1
    case all = 2
    
    var title: String {
        switch self {
        case .recent: return "Recent"
        case .favorites: return "Favorites"
        case .all: return "All"
        }
    }
    
    var iconName: String {
        switch self {
        case .recent: return "clock.fill"
        case .favorites: return "heart.fill"
        case .all: return "list.bullet"
        }
    }
}


class RadioStationViewModel: NSObject, ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var countries: [Country] = [
        Country(name: "Select Country", flag: ""),
        Country(name: "Afghanistan", flag: "AF"),
        Country(name: "Albania", flag: "AL"),
        Country(name: "Algeria", flag: "DZ"),
        Country(name: "American Samoa", flag: "AS"),
        Country(name: "Andorra", flag: "AD"),
        Country(name: "Angola", flag: "AO"),
        Country(name: "Anguilla", flag: "AI"),
        Country(name: "Antigua & Barbuda", flag: "AG"),
        Country(name: "Argentina", flag: "AR"),
        Country(name: "Armenia", flag: "AM"),
        Country(name: "Aruba", flag: "AW"),
        Country(name: "Australia", flag: "AU"),
        Country(name: "Austria", flag: "AT"),
        Country(name: "Azerbaijan", flag: "AZ"),
        Country(name: "Bahamas", flag: "BS"),
        Country(name: "Bahrain", flag: "BH"),
        Country(name: "Bangladesh", flag: "BD"),
        Country(name: "Barbados", flag: "BB"),
        Country(name: "Belarus", flag: "BY"),
        Country(name: "Belgium", flag: "BE"),
        Country(name: "Belize", flag: "BZ"),
        Country(name: "Benin", flag: "BJ"),
        Country(name: "Bermuda", flag: "BM"),
        Country(name: "Bhutan", flag: "BT"),
        Country(name: "Bolivia", flag: "BO"),
        Country(name: "Bosnia & Herzegovina", flag: "BA"),
        Country(name: "Botswana", flag: "BW"),
        Country(name: "Brazil", flag: "BR"),
        Country(name: "British Virgin Islands", flag: "VG"),
        Country(name: "Brunei", flag: "BN"),
        Country(name: "Bulgaria", flag: "BG"),
        Country(name: "Burkina Faso", flag: "BF"),
        Country(name: "Burundi", flag: "BI"),
        Country(name: "Cambodia", flag: "KH"),
        Country(name: "Cameroon", flag: "CM"),
        Country(name: "Canada", flag: "CA"),
        Country(name: "Cape Verde", flag: "CV"),
        Country(name: "Cayman Islands", flag: "KY"),
        Country(name: "Central African Republic", flag: "CF"),
        Country(name: "Chad", flag: "TD"),
        Country(name: "Chile", flag: "CL"),
        Country(name: "China", flag: "CN"),
        Country(name: "Christmas Island", flag: "CX"),
        Country(name: "Cocos (Keeling) Islands", flag: "CC"),
        Country(name: "Colombia", flag: "CO"),
        Country(name: "Comoros", flag: "KM"),
        Country(name: "Congo - Brazzaville", flag: "CG"),
        Country(name: "Congo - Kinshasa", flag: "CD"),
        Country(name: "Cook Islands", flag: "CK"),
        Country(name: "Costa Rica", flag: "CR"),
        Country(name: "Croatia", flag: "HR"),
        Country(name: "Cuba", flag: "CU"),
        Country(name: "Curaçao", flag: "CW"),
        Country(name: "Cyprus", flag: "CY"),
        Country(name: "Czech Republic", flag: "CZ"),
        Country(name: "Côte d'Ivoire", flag: "CI"),
        Country(name: "Denmark", flag: "DK"),
        Country(name: "Djibouti", flag: "DJ"),
        Country(name: "Dominica", flag: "DM"),
        Country(name: "Dominican Republic", flag: "DO"),
        Country(name: "Ecuador", flag: "EC"),
        Country(name: "Egypt", flag: "EG"),
        Country(name: "El Salvador", flag: "SV"),
        Country(name: "England", flag: "GB-ENG"),
        Country(name: "Equatorial Guinea", flag: "GQ"),
        Country(name: "Eritrea", flag: "ER"),
        Country(name: "Estonia", flag: "EE"),
        Country(name: "Ethiopia", flag: "ET"),
        Country(name: "European Union", flag: "EU"),
        Country(name: "Falkland Islands", flag: "FK"),
        Country(name: "Faroe Islands", flag: "FO"),
        Country(name: "Fiji", flag: "FJ"),
        Country(name: "Finland", flag: "FI"),
        Country(name: "France", flag: "FR"),
        Country(name: "French Guiana", flag: "GF"),
        Country(name: "French Polynesia", flag: "PF"),
        Country(name: "Gabon", flag: "GA"),
        Country(name: "Gambia", flag: "GM"),
        Country(name: "Georgia", flag: "GE"),
        Country(name: "Germany", flag: "DE"),
        Country(name: "Ghana", flag: "GH"),
        Country(name: "Gibraltar", flag: "GI"),
        Country(name: "Greece", flag: "GR"),
        Country(name: "Greenland", flag: "GL"),
        Country(name: "Grenada", flag: "GD"),
        Country(name: "Guadeloupe", flag: "GP"),
        Country(name: "Guam", flag: "GU"),
        Country(name: "Guatemala", flag: "GT"),
        Country(name: "Guernsey", flag: "GG"),
        Country(name: "Guinea", flag: "GN"),
        Country(name: "Guinea-Bissau", flag: "GW"),
        Country(name: "Guyana", flag: "GY"),
        Country(name: "Haiti", flag: "HT"),
        Country(name: "Honduras", flag: "HN"),
        Country(name: "Hong Kong", flag: "HK"),
        Country(name: "Hungary", flag: "HU"),
        Country(name: "Iceland", flag: "IS"),
        Country(name: "India", flag: "IN"),
        Country(name: "Indonesia", flag: "ID"),
        Country(name: "Iran", flag: "IR"),
        Country(name: "Iraq", flag: "IQ"),
        Country(name: "Ireland", flag: "IE"),
        Country(name: "Isle of Man", flag: "IM"),
        Country(name: "Israel", flag: "IL"),
        Country(name: "Italy", flag: "IT"),
        Country(name: "Jamaica", flag: "JM"),
        Country(name: "Japan", flag: "JP"),
        Country(name: "Jersey", flag: "JE"),
        Country(name: "Jordan", flag: "JO"),
        Country(name: "Kazakhstan", flag: "KZ"),
        Country(name: "Kenya", flag: "KE"),
        Country(name: "Kiribati", flag: "KI"),
        Country(name: "Kosovo", flag: "XK"),
        Country(name: "Kuwait", flag: "KW"),
        Country(name: "Kyrgyzstan", flag: "KG"),
        Country(name: "Laos", flag: "LA"),
        Country(name: "Latvia", flag: "LV"),
        Country(name: "Lebanon", flag: "LB"),
        Country(name: "Lesotho", flag: "LS"),
        Country(name: "Liberia", flag: "LR"),
        Country(name: "Libya", flag: "LY"),
        Country(name: "Liechtenstein", flag: "LI"),
        Country(name: "Lithuania", flag: "LT"),
        Country(name: "Luxembourg", flag: "LU"),
        Country(name: "Macau", flag: "MO"),
        Country(name: "Macedonia", flag: "MK"),
        Country(name: "Madagascar", flag: "MG"),
        Country(name: "Malawi", flag: "MW"),
        Country(name: "Malaysia", flag: "MY"),
        Country(name: "Maldives", flag: "MV"),
        Country(name: "Mali", flag: "ML"),
        Country(name: "Malta", flag: "MT"),
        Country(name: "Marshall Islands", flag: "MH"),
        Country(name: "Martinique", flag: "MQ"),
        Country(name: "Mauritania", flag: "MR"),
        Country(name: "Mauritius", flag: "MU"),
        Country(name: "Mayotte", flag: "YT"),
        Country(name: "Mexico", flag: "MX"),
        Country(name: "Micronesia", flag: "FM"),
        Country(name: "Moldova", flag: "MD"),
        Country(name: "Monaco", flag: "MC"),
        Country(name: "Mongolia", flag: "MN"),
        Country(name: "Montenegro", flag: "ME"),
        Country(name: "Montserrat", flag: "MS"),
        Country(name: "Morocco", flag: "MA"),
        Country(name: "Mozambique", flag: "MZ"),
        Country(name: "Myanmar", flag: "MM"),
        Country(name: "Namibia", flag: "NA"),
        Country(name: "Nauru", flag: "NR"),
        Country(name: "Nepal", flag: "NP"),
        Country(name: "Netherlands", flag: "NL"),
        Country(name: "New Caledonia", flag: "NC"),
        Country(name: "New Zealand", flag: "NZ"),
        Country(name: "Nicaragua", flag: "NI"),
        Country(name: "Niger", flag: "NE"),
        Country(name: "Nigeria", flag: "NG"),
        Country(name: "Niue", flag: "NU"),
        Country(name: "Norfolk Island", flag: "NF"),
        Country(name: "North Korea", flag: "KP"),
        Country(name: "Northern Ireland", flag: "GB-NIR"),
        Country(name: "Northern Mariana Islands", flag: "MP"),
        Country(name: "Norway", flag: "NO"),
        Country(name: "Oman", flag: "OM"),
        Country(name: "Pakistan", flag: "PK"),
        Country(name: "Palau", flag: "PW"),
        Country(name: "Palestinian Territories", flag: "PS"),
        Country(name: "Panama", flag: "PA"),
        Country(name: "Papua New Guinea", flag: "PG"),
        Country(name: "Paraguay", flag: "PY"),
        Country(name: "Peru", flag: "PE"),
        Country(name: "Philippines", flag: "PH"),
        Country(name: "Pitcairn Islands", flag: "PN"),
        Country(name: "Poland", flag: "PL"),
        Country(name: "Portugal", flag: "PT"),
        Country(name: "Puerto Rico", flag: "PR"),
        Country(name: "Qatar", flag: "QA"),
        Country(name: "Romania", flag: "RO"),
        Country(name: "Russia", flag: "RU"),
        Country(name: "Rwanda", flag: "RW"),
        Country(name: "Réunion", flag: "RE"),
        Country(name: "Saint Barthélemy", flag: "BL"),
        Country(name: "Saint Helena", flag: "SH"),
        Country(name: "Saint Kitts & Nevis", flag: "KN"),
        Country(name: "Saint Lucia", flag: "LC"),
        Country(name: "Saint Martin", flag: "MF"),
        Country(name: "Saint Pierre & Miquelon", flag: "PM"),
        Country(name: "Saint Vincent & Grenadines", flag: "VC"),
        Country(name: "Samoa", flag: "WS"),
        Country(name: "San Marino", flag: "SM"),
        Country(name: "Saudi Arabia", flag: "SA"),
        Country(name: "Scotland", flag: "GB-SCT"),
        Country(name: "Senegal", flag: "SN"),
        Country(name: "Serbia", flag: "RS"),
        Country(name: "Seychelles", flag: "SC"),
        Country(name: "Sierra Leone", flag: "SL"),
        Country(name: "Singapore", flag: "SG"),
        Country(name: "Sint Maarten", flag: "SX"),
        Country(name: "Slovakia", flag: "SK"),
        Country(name: "Slovenia", flag: "SI"),
        Country(name: "Solomon Islands", flag: "SB"),
        Country(name: "Somalia", flag: "SO"),
        Country(name: "South Africa", flag: "ZA"),
        Country(name: "South Korea", flag: "KR"),
        Country(name: "South Sudan", flag: "SS"),
        Country(name: "Spain", flag: "ES"),
        Country(name: "Sri Lanka", flag: "LK"),
        Country(name: "Sudan", flag: "SD"),
        Country(name: "Suriname", flag: "SR"),
        Country(name: "Swaziland", flag: "SZ"),
        Country(name: "Sweden", flag: "SE"),
        Country(name: "Switzerland", flag: "CH"),
        Country(name: "Syria", flag: "SY"),
        Country(name: "São Tomé & Príncipe", flag: "ST"),
        Country(name: "Taiwan", flag: "TW"),
        Country(name: "Tajikistan", flag: "TJ"),
        Country(name: "Tanzania", flag: "TZ"),
        Country(name: "Thailand", flag: "TH"),
        Country(name: "Timor-Leste", flag: "TL"),
        Country(name: "Togo", flag: "TG"),
        Country(name: "Tokelau", flag: "TK"),
        Country(name: "Tonga", flag: "TO"),
        Country(name: "Trinidad & Tobago", flag: "TT"),
        Country(name: "Tunisia", flag: "TN"),
        Country(name: "Turkey", flag: "TR"),
        Country(name: "Turkmenistan", flag: "TM"),
        Country(name: "Turks & Caicos Islands", flag: "TC"),
        Country(name: "Tuvalu", flag: "TV"),
        Country(name: "Uganda", flag: "UG"),
        Country(name: "UK", flag: "GB"),
        Country(name: "Ukraine", flag: "UA"),
        Country(name: "United Arab Emirates", flag: "AE"),
        Country(name: "United States", flag: "US"),
        Country(name: "Uruguay", flag: "UY"),
        Country(name: "USA", flag: "US"),
        Country(name: "U.S. Virgin Islands", flag: "VI"),
        Country(name: "Uzbekistan", flag: "UZ"),
        Country(name: "Vanuatu", flag: "VU"),
        Country(name: "Vatican City", flag: "VA"),
        Country(name: "Venezuela", flag: "VE"),
        Country(name: "Vietnam", flag: "VN"),
        Country(name: "Wales", flag: "GB-WLS"),
        Country(name: "Wallis & Futuna", flag: "WF"),
        Country(name: "Yemen", flag: "YE"),
        Country(name: "Zambia", flag: "ZM"),
        Country(name: "Zimbabwe", flag: "ZW"),
        Country(name: "Åland Islands", flag: "AX"),
        Country(name: "Unknown Region", flag: "")
    ]
    @Published var selectedTab: Tab = .radio
    @Published var selectedSubTab: RadioSubTab = .recent
    @Published var activeSheet: ActiveSheet? = nil
    @Published var isLoading = false
    @Published var isDeletingData: Bool = false
    @Published var deletionComplete: Bool = false
    @Published var isCloudKitOperationRunning = false
    @Published var isDeletionInProgress = false
    @Published var isUploadingToCloudKit = false
    @Published var isImportInProgress = false
    
    // Flag to prevent infinite loop in favorite timestamp migration
    private var isMigrationInProgress = false
    
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country" {
        didSet {
            // Switch to All tab when country changes (except during initialization)
            if oldValue != selectedCountry && oldValue != "" {
                selectedSubTab = .all
                print("🌍 Country changed from '\(oldValue)' to '\(selectedCountry)' - switching to All tab")
            }
            
            saveSelectedCountry()
            NotificationCenter.default.post(name: .countrySelected, object: nil)
            NotificationCenter.default.post(name: .countryChanged, object: nil)
        }
    }
    private var notificationManager = NotificationManager.shared
    private var backgroundObserver: NSObjectProtocol?
    static let shared = RadioStationViewModel()
    
    var currentlyPlayingStation: RadioStation? {
            guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
                  stations.indices.contains(currentStationIndex) else {
                return nil
            }
            return stations[currentStationIndex]
        }
    
    enum ActiveSheet: Identifiable {
        case editStation
        var id: Int {
            self.hashValue
        }
    }
    
    private func saveSelectedCountry() {
        UserDefaults.standard.set(selectedCountry, forKey: "selectedCountry")
    }
    

    

    
    override init() {
        super.init()
        
            selectedCountry = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country"
            
            // Always start with Recent tab (no persistence)
            selectedSubTab = .recent
        
            // PERFORMANCE FIX: Only sync radio stations from CloudKit on fresh installs
            // Check if radio stations have been synced to prevent unnecessary CloudKit fetching
            let isFreshInstall = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
            let hasRadioStationsSynced = UserDefaults.standard.bool(forKey: "HasRadioStationsSynced")
            
            if isFreshInstall || !hasRadioStationsSynced {
                print("🔄 Radio station sync needed in ViewModel - fresh install: \(isFreshInstall), stations synced: \(hasRadioStationsSynced)")
                syncStationsWithCloudKit()
            } else {
                print("⚡ Skipping CloudKit radio station sync in ViewModel - loading from local storage only for better performance")
            }
    
            loadStationsFromCoreData()
            
            let userDefaults = UserDefaults.standard
            let hasLaunchedBeforeKey = "HasLaunchedBefore"
            
            if !userDefaults.bool(forKey: hasLaunchedBeforeKey) {
                print("First time setup or new default stations detected, initializing default stations and saving to local and CloudKit.")
                initializeStationsForFirstTime()
            } else {
                print("App relaunch detected.")
                // Removed the second syncStationsWithCloudKit() call for performance optimization
            }
        }
    
    func importStationsFromFile(url: URL, progressHandler: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        // Set import flag to prevent sync interference
        DispatchQueue.main.async {
            self.isImportInProgress = true
        }
        
        // Ensure notification permissions are granted
        NotificationManager.shared.requestAuthorization()
        
        // Notify user that import has started
        NotificationManager.shared.notifyUserImmediate(title: "Import Started", message: "Importing station playlist from file...")
        
        do {
            let data = try Data(contentsOf: url)
            
            // Debug: Print file contents for troubleshooting
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📄 JSON file contents preview (first 500 chars):")
                print(String(jsonString.prefix(500)))
                print("📏 Total file size: \(data.count) bytes")
            }
            
            let jsonDecoder = JSONDecoder()
            
            // First, try to decode the JSON to see if it's valid JSON at all
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                print("✅ JSON is valid. Structure type: \(type(of: jsonObject))")
                
                if let jsonArray = jsonObject as? [[String: Any]] {
                    print("📊 Found \(jsonArray.count) objects in JSON array")
                    
                    // Check the structure of the first object
                    if let firstObject = jsonArray.first {
                        print("🔍 First object keys: \(Array(firstObject.keys).sorted())")
                        
                        // Check for required fields
                        let requiredFields = ["id", "name", "url"]
                        let missingFields = requiredFields.filter { !firstObject.keys.contains($0) }
                        if !missingFields.isEmpty {
                            throw ImportError.missingRequiredFields(missingFields)
                        }
                    }
                } else {
                    throw ImportError.invalidJSONStructure("Expected array of objects, got \(type(of: jsonObject))")
                }
            } catch let jsonError {
                print("❌ JSON parsing error: \(jsonError)")
                throw ImportError.invalidJSON(jsonError.localizedDescription)
            }
            
            // Now try to decode to RadioStation objects
            let stationsFromJson = try jsonDecoder.decode([RadioStation].self, from: data)
            print("✅ Successfully decoded \(stationsFromJson.count) stations")

            // Get existing URLs to check for duplicates
            let existingURLs = Set(stations.map { $0.url })
            
            // Filter out stations that already exist by URL
            let newStations = stationsFromJson.filter { !existingURLs.contains($0.url) }
            
            let totalNewStations = Double(newStations.count)
            var importedStations = 0.0

            DispatchQueue.main.async {
                // Append new stations instead of removing existing ones
                for station in newStations {
                    self.stations.append(station)
                    importedStations += 1
                    progressHandler(importedStations / max(totalNewStations, 1))
                }

                print("Imported \(newStations.count) new stations. Skipped \(stationsFromJson.count - newStations.count) duplicates.")

                // Save these to CoreData first
                self.saveStationsToCoreData()

                // Wait a bit to ensure Core Data save is complete, then save only new stations to CloudKit
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Only save the newly imported stations to CloudKit (with URL duplicate checking)
                    DataStore.shared.saveImportedStationsToCloudKit(stations: newStations) { success, recordIDs in
                        DispatchQueue.main.async {
                            if success {
                                print("Successfully saved \(newStations.count) new stations to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Complete", message: "Successfully imported \(newStations.count) new stations. Skipped \(stationsFromJson.count - newStations.count) duplicates.")
                            } else {
                                print("Failed to save some or all new stations to CloudKit.")
                                NotificationManager.shared.notifyUserImmediate(title: "Import Completed with Warnings", message: "Imported \(newStations.count) new stations locally. Some stations may not have synced to iCloud.")
                            }
                            
                            // Clear import flag and notify completion
                            self.isImportInProgress = false
                            NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                            completion()
                        }
                    }
                }
            }
        } catch let importError as ImportError {
            DispatchQueue.main.async {
                self.isImportInProgress = false
            }
            let errorMessage = importError.userFriendlyMessage
            NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: errorMessage)
            print("Import failed with specific error: \(errorMessage)")
            completion()
        } catch {
            DispatchQueue.main.async {
                self.isImportInProgress = false
            }
            
            var errorMessage = "Unknown error occurred"
            
            if let decodingError = error as? DecodingError {
                errorMessage = self.parseDecodingError(decodingError)
            } else {
                errorMessage = error.localizedDescription
            }
            
            NotificationManager.shared.notifyUserImmediate(title: "Import Failed", message: errorMessage)
            print("Failed to import stations: \(error)")
            completion()
        }
    }
    
    // MARK: - Sample JSON Generation
    
    func generateSampleImportJSON() -> String {
        let sampleStations = [
            [
                "id": "sample-1",
                "name": "Sample Radio Station 1",
                "url": "https://example.com/stream1.mp3",
                "country": "United States",
                "isFavorite": false
            ],
            [
                "id": "sample-2", 
                "name": "Sample Radio Station 2",
                "url": "https://example.com/stream2.mp3",
                "country": "Canada",
                "isFavorite": true
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sampleStations, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? "Error generating sample JSON"
        } catch {
            return "Error generating sample JSON: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Import Error Handling
    
    private func parseDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Expected \(type) but found different type at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
        case .valueNotFound(let type, let context):
            return "Required field '\(context.codingPath.last?.stringValue ?? "unknown")' of type \(type) is missing"
        case .keyNotFound(let key, let context):
            return "Required field '\(key.stringValue)' is missing from the JSON"
        case .dataCorrupted(let context):
            return "Data is corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: " -> ")): \(context.debugDescription)"
        @unknown default:
            return "Unknown decoding error: \(error.localizedDescription)"
        }
    }
    
    func exportStationsToFile(completion: @escaping (URL?) -> Void) {
        print("🚀 DEBUG: exportStationsToFile called")
        print("📊 DEBUG: Total stations: \(self.stations.count)")
        print("🌍 DEBUG: Selected country: \(self.selectedCountry)")
        
        let filteredStations = self.stations.filter { $0.country == self.selectedCountry || self.selectedCountry == "Select Country" }
                                            .map(ExportStation.init)

        print("📋 DEBUG: Filtered stations for export: \(filteredStations.count)")
        
        // Create JSON string manually for each station and join them in an array format
        let jsonStrings = filteredStations.map { $0.jsonString }
        let jsonArrayString = "[\n" + jsonStrings.joined(separator: ",\n") + "\n]"

        let fileName = "stations_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        print("📁 DEBUG: Export file path: \(fileURL.path)")

        do {
            try jsonArrayString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ DEBUG: JSON file written successfully")
            print("📏 DEBUG: JSON content length: \(jsonArrayString.count) characters")
            DispatchQueue.main.async {
                print("🎯 DEBUG: Calling completion with fileURL")
                completion(fileURL)
            }
        } catch {
            print("❌ DEBUG: Failed to export stations: \(error)")
            DispatchQueue.main.async {
                print("💥 DEBUG: Calling completion with nil due to error")
                completion(nil)
            }
        }
    }
    
    /// Clear stations from UI immediately for instant user feedback
    func clearStationsFromUI() {
        DispatchQueue.main.async {
            self.stations.removeAll()
            print("🎧 ✅ Immediately cleared radio stations from UI")
        }
    }
    
    func deleteAllData(completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async {
            self.isDeletingData = true
            self.deletionComplete = false
            self.isCloudKitOperationRunning = true
            self.isDeletionInProgress = true
        }
        
        // Set up background task
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            // Task expired
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        // Set up observer for app entering background
        setupBackgroundObserver()
        
        // Fetch all record IDs for 'streamingRadios' from CloudKit
        DataStore.shared.fetchAllRecordIDs(ofType: "streamingRadios") { [weak self] recordIDs, error in
            guard let self = self, let recordIDs = recordIDs else {
                DispatchQueue.main.async {
                    self?.cleanupAfterDeletion(success: false, error: error, backgroundTaskID: backgroundTaskID, completion: completion)
                }
                return
            }
            
            // Proceed with batch deletion of records
            DataStore.shared.deleteRecordsInBatches(recordIDs: recordIDs) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.clearCoreData { coreDataSuccess, coreDataError in
                            if coreDataSuccess {
                                self.stations.removeAll()
                            }
                            self.cleanupAfterDeletion(success: coreDataSuccess, error: coreDataError, backgroundTaskID: backgroundTaskID, completion: completion)
                        }
                    } else {
                        self.cleanupAfterDeletion(success: false, error: error, backgroundTaskID: backgroundTaskID, completion: completion)
                    }
                }
            }
        }
    }

    private func cleanupAfterDeletion(success: Bool, error: Error?, backgroundTaskID: UIBackgroundTaskIdentifier, completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async {
            self.isDeletingData = false
            self.isCloudKitOperationRunning = false
            self.isDeletionInProgress = false
            self.deletionComplete = success
            
            // Remove the background observer
            self.removeBackgroundObserver()
            
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            completion(success, error)
            
            if success {
            } else if let error = error {
                NotificationManager.shared.notifyUser(title: "Deletion Failed", message: "An error occurred: \(error.localizedDescription)")
            }
        }
    }
    
    func clearCoreData(completion: @escaping (Bool, Error?) -> Void) {
        // Create a private context for deletion to avoid merge conflicts
        let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        privateMOC.parent = CoreDataStack.shared.persistentContainer.viewContext
        
        // Set merge policy to handle conflicts
        privateMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        privateMOC.perform {
            do {
                // Fetch and delete stations
                let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
                let stations = try privateMOC.fetch(fetchRequest)
                for station in stations {
                    privateMOC.delete(station)
                }
                
                // Save private context first
                try privateMOC.save()
                
                // Then save main context
                DispatchQueue.main.async {
                    do {
                        try CoreDataStack.shared.persistentContainer.viewContext.save()
                        
                        // Clear in-memory data after successful save
                        self.stations.removeAll()
                        self.isDeletingData = false
                        self.deletionComplete = true
                        completion(true, nil)
                    } catch {
                        print("Error saving main context after station deletion: \(error.localizedDescription)")
                        self.isDeletingData = false
                        completion(false, error)
                    }
                }
            } catch {
                print("Error deleting stations from CoreData: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isDeletingData = false
                    completion(false, error)
                }
            }
        }
    }
    
    func syncStationsWithCloudKit() {
        // Don't sync during import or deletion operations
        guard !isImportInProgress && !isDeletionInProgress else {
            print("Skipping CloudKit sync - import or deletion in progress")
            return
        }
        
        CoreDataStack.shared.syncStationsFromCloudKit { [weak self] error in
            if let error = error {
                print("Error syncing with CloudKit: \(error.localizedDescription)")
            } else {
                print("Stations successfully synchronized with CloudKit.")
                
                // Mark radio stations as synced to prevent future CloudKit syncing on app launches
                UserDefaults.standard.set(true, forKey: "HasRadioStationsSynced")
                
                DispatchQueue.main.async {
                    self?.loadStationsFromCoreData() // Reload stations from CoreData after sync
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    // StationsLoaded notification will be posted by loadStationsFromCoreData()
                }
            }
        }
    }
    
    private func initializeStationsForFirstTime() {
        let userDefaults = UserDefaults.standard
        let hasLaunchedBeforeKey = "HasLaunchedBefore"
        
        if userDefaults.bool(forKey: hasLaunchedBeforeKey) == false {
            print("Initializing default stations for first time setup or new default stations detected.")
                        
            saveStationsToCloudKit()
            saveStationsToCoreData()
            
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.synchronize() // Ensure the flag is saved immediately
        }
    }
    
    func isStationPlaying(_ station: RadioStation) -> Bool {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              currentStationIndex < stations.count,
              stations[currentStationIndex].id == station.id else {
            return false
        }
        return true
    }
    
    func isStationCurrentlyPlaying(_ station: RadioStation) -> Bool {
        guard let currentStationIndex = RadioPlayer.shared.currentStationIndex,
              currentStationIndex < stations.count,
              stations[currentStationIndex].id == station.id else {
            return false
        }
        return RadioPlayer.shared.isPlaying
    }
    
    func toggleFavorite(for station: RadioStation) {
        if let index = stations.firstIndex(of: station), !isStationCurrentlyPlaying(stations[index]) {
            var updatedStation = stations[index]
            updatedStation.isFavorite.toggle()
            
            // Set favoritedAt timestamp and favoriteOrder when marking as favorite, clear when unfavoriting
            if updatedStation.isFavorite {
                updatedStation.favoritedAt = Date()
                
                // Add new favorite at the top (favoriteOrder = 0)
                // First, increment all existing favorites' favoriteOrder by 1 to make room at the top
                for i in 0..<stations.count {
                    if stations[i].isFavorite && stations[i].id != station.id {
                        if let currentOrder = stations[i].favoriteOrder {
                            stations[i].favoriteOrder = currentOrder + 1
                        }
                    }
                }
                
                // Set the new favorite to favoriteOrder = 0 (top of the list)
                updatedStation.favoriteOrder = 0
            } else {
                updatedStation.favoritedAt = nil
                updatedStation.favoriteOrder = nil
            }
            
            stations[index] = updatedStation
            updateStationInCloudKit(station: updatedStation)
            saveStationsToCoreData()
        }
    }
    
    func recentStations() -> [RadioStation] {
        let recentStations = stations.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed ?? Date.distantPast > $1.lastPlayed ?? Date.distantPast }
        // No need to save to CoreData - this method only filters and sorts, doesn't modify data
        return recentStations
    }
    
    func favoriteStations() -> [RadioStation] {
        return stations.filter { $0.isFavorite }
            .sorted { station1, station2 in
                // Sort by favoriteOrder if both have it, otherwise by favoritedAt
                if let order1 = station1.favoriteOrder, let order2 = station2.favoriteOrder {
                    return order1 < order2
                } else if station1.favoriteOrder != nil {
                    return true  // station1 has order, station2 doesn't, so station1 comes first
                } else if station2.favoriteOrder != nil {
                    return false // station2 has order, station1 doesn't, so station2 comes first
                } else {
                    // Neither has favoriteOrder, sort by favoritedAt with most recent first
                    let date1 = station1.favoritedAt ?? Date.distantPast
                    let date2 = station2.favoritedAt ?? Date.distantPast
                    return date1 > date2
                }
            }
    }
    
    private func migrateFavoriteTimestamps() {
        // Prevent infinite loop by checking if migration is already in progress
        guard !isMigrationInProgress else { return }
        
        Task { @MainActor in
            self.isMigrationInProgress = true
            defer { self.isMigrationInProgress = false }
            
            var needsUpdate = false
            let now = Date()
            
            for i in 0..<stations.count {
                if stations[i].isFavorite && stations[i].favoritedAt == nil {
                    stations[i].favoritedAt = now
                    needsUpdate = true
                }
            }
            
            if needsUpdate {
                print("Migrating favorite timestamps for \(stations.filter { $0.isFavorite && $0.favoritedAt == now }.count) stations")
                saveStationsToCoreData()
            }
        }
    }
    
    func playStation(_ station: RadioStation) {
            if let index = stations.firstIndex(of: station) {
                RadioPlayer.shared.playStation(at: index, from: stations)
                updateLastPlayed(for: station)
            }
        }
    
    func updateLastPlayed(for station: RadioStation) {
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index].lastPlayed = Date()
            
            // Save to CoreData on main thread but asynchronously to avoid blocking current operation
            DispatchQueue.main.async {
                self.saveStationsToCoreData()
            }
            
            // Post notification for real-time CarPlay recents update
            NotificationCenter.default.post(
                name: NSNotification.Name("StationPlayedForRecents"),
                object: nil,
                userInfo: ["stationId": station.id, "station": stations[index]]
            )
            print("🚗 Posted recents update notification for station: \(station.name)")
        }
    }
    
    
    func loadImageData(named name: String) -> String? {
        let assetName = name.replacingOccurrences(of: " ", with: "_")
        
        guard let image = UIImage(named: assetName) else {
            print("Failed to load image named: \(assetName)")
            return nil
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("Failed to compress image named: \(assetName)")
            return nil
        }
        print("Image loaded and encoded for: \(assetName)")
        return imageData.base64EncodedString()
    }
    
    func addStation(name: String, url: String, iconData: String?, country: String) {
        // First, increment the order of all existing stations in the same country
        for i in 0..<stations.count {
            if stations[i].country == country {
                stations[i].order += 1
            }
        }
        
        // Create new station with order = 0 to place it at the top
        let newStation = RadioStation(id: UUID().uuidString, name: name, url: url, iconData: iconData, country: country, isFavorite: false, favoriteOrder: nil, order: 0)
        stations.append(newStation)
        print("Added new station: \(newStation) at the top of \(country) list")
        saveStationsToCoreData()
        saveStationToCloudKit(station: newStation)
    }

    
    func saveStationsToCloudKit() {
        isUploadingToCloudKit = true
        NotificationManager.shared.notifyUser(title: "Upload Started", message: "Saving stations to iCloud has begun.")
        
        setupBackgroundObserver()
        
        DataStore.shared.saveStationsToCloudKit(stations: stations) { [weak self] success, recordIDs in
            DispatchQueue.main.async {
                self?.isUploadingToCloudKit = false
                self?.removeBackgroundObserver()
                
                if success {
                    NotificationManager.shared.notifyUser(title: "Upload Complete", message: "All stations have been successfully saved to iCloud.")
                    print("Successfully saved all stations to CloudKit.")
                } else {
                    NotificationManager.shared.notifyUser(title: "Upload Incomplete", message: "Some stations failed to save to iCloud.")
                    print("Failed to save some or all stations to CloudKit.")
                    if let recordIDs = recordIDs {
                        let failedStations = self?.stations.filter { !recordIDs.contains($0.id) } ?? []
                        for station in failedStations {
                            print("Failed to save station: \(station.name)")
                        }
                    } else {
                        print("No stations were saved successfully.")
                    }
                }
            }
        }
    }
    
    private func setupBackgroundObserver() {
        // Remove any existing observer before adding a new one
        removeBackgroundObserver()
        
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.isDeletionInProgress == true {
                NotificationManager.shared.notifyUser(title: "Deletion in Progress", message: "Please keep the app open in the background until the deletion process is complete.")
            } else if self?.isUploadingToCloudKit == true {
                NotificationManager.shared.notifyUser(title: "Initial iCloud Sync in Progress", message: "iCloud sync in progress. May take 5 mins. Keep app in background. We'll notify when done.")
            }
        }
    }
    
    private func removeBackgroundObserver() {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
    }
    
    
    func saveStationToCloudKit(station: RadioStation) {
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        DataStore.shared.saveNewStationToCloudKit(station: station, iconImage: iconImage) { success, recordName in
            DispatchQueue.main.async {
                if success {
                    print("Station saved to CloudKit with record ID:", recordName ?? "Unknown")
                } else {
                    print("Failed to save station to CloudKit.")
                }
            }
        }
    }
    
    func deleteStationFromCoreData(_ station: RadioStation) {
        NotificationManager.shared.notifyUserImmediate(title: "Deletion Started", message: "Deleting station '\(station.name)'...")
        
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", station.id)
        
        do {
            let results = try context.fetch(request)
            for object in results {
                context.delete(object)
            }
            try context.save()
            
            // Check if there are no more stations left
            let remainingStations = try context.fetch(CDStation.fetchRequest())
            if remainingStations.isEmpty {
                deleteLocalFile()
            }
            
            
            print("Station deleted from CoreData successfully.")
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Complete", message: "Successfully deleted station '\(station.name)'.")
        } catch {
            print("Failed to delete station from CoreData: \(error)")
            NotificationManager.shared.notifyUserImmediate(title: "Deletion Failed", message: "Failed to delete station '\(station.name)': \(error.localizedDescription)")
        }
    }
    
    func deleteLocalFile() {
        let fileManager = FileManager.default
        guard let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreDescriptions.first?.url else {
            print("Failed to get CoreData file URL.")
            return
        }
        
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        
        do {
            // Ensure any changes are saved
            if context.hasChanges {
                try context.save()
            }
            
            // Remove the persistent store
            if let store = coordinator.persistentStore(for: storeURL) {
                try coordinator.remove(store)
            }
            
            // Delete the file
            try fileManager.removeItem(at: storeURL)
            print("Local CoreData file deleted successfully.")
            
            // Reset the context to clear any cached data
            context.reset()
        } catch {
            print("Failed to delete local CoreData file: \(error)")
        }
    }
    
    
    func updateStation(_ existingStation: RadioStation, name: String, url: String, iconData: String?, country: String) {
        if let index = stations.firstIndex(where: { $0.id == existingStation.id }) {
            stations[index].name = name
            stations[index].url = url
            stations[index].iconData = iconData
            stations[index].country = country
            updateStationInCloudKit(station: stations[index])
            saveStationsToCoreData()
        } else {
            print("Error: Station not found in local data.")
        }
    }
    
    func updateStationInCloudKit(station: RadioStation) {
        let iconImage = station.iconData.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        DataStore.shared.updateStationInCloudKit(station: station, iconImage: iconImage) { success, recordName in
            DispatchQueue.main.async {
                if success {
                    print("Station updated in CloudKit with record ID:", recordName ?? "Unknown")
                } else {
                    print("Failed to update station in CloudKit.")
                }
            }
        }
    }
    
    func moveStation(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        saveStationsToCoreData()  // Save the updated order to CoreData
    }
}

extension RadioStationViewModel {
    func saveStationsToCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        
        // Fetch existing stations
        let fetchRequest: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        
        do {
            let existingStations = try context.fetch(fetchRequest)
            let existingDict = Dictionary(uniqueKeysWithValues: existingStations.map { ($0.id!, $0) })
            
            for (index, station) in stations.enumerated() {
                if let existingStation = existingDict[station.id] {
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
                    // Create new station if it doesn't exist
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
            }
            
            // Remove stations that are no longer in the array
            let stationIDs = Set(stations.map { $0.id })
            for existingStation in existingStations {
                if !stationIDs.contains(existingStation.id!) {
                    context.delete(existingStation)
                }
            }
            
            // Save changes
            try context.save()
            print("CoreData stations updated successfully.")
        } catch {
            print("Failed to update stations in CoreData: \(error)")
        }
    }
    
    func loadStationsFromCoreData() {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<CDStation> = CDStation.fetchRequest()
        
        // Add a sort descriptor to ensure stations are loaded in the correct order
        let sortDescriptor = NSSortDescriptor(key: "order", ascending: true)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            let results = try context.fetch(request)
            if results.isEmpty {
                print("No stations found in CoreData.")
                stations.removeAll()
                print("📡 ✅ Cleared all in-memory station data due to empty Core Data")
                return
            }
            stations = results.map { cdStation in
                RadioStation(
                    id: cdStation.id ?? UUID().uuidString,
                    name: cdStation.name ?? "Unknown",
                    url: cdStation.url ?? "http://default.url",
                    iconData: cdStation.iconData,
                    country: cdStation.country ?? "Unknown",
                    isFavorite: cdStation.isFavorite,
                    favoritedAt: cdStation.favoritedAt,
                    favoriteOrder: cdStation.favoriteOrder >= 0 ? Int(cdStation.favoriteOrder) : nil,
                    order: Int(cdStation.order),
                    lastPlayed: cdStation.lastPlayed
                )
            }
            print("Loaded \(stations.count) stations from CoreData.")
            
            // Initialize proper order values for stations that might not have them
            initializeOrderValues()
            
            // Post notification that stations have been loaded
            NotificationCenter.default.post(name: NSNotification.Name("StationsLoaded"), object: nil)
            
            // Migration: Set favoritedAt for existing favorites that don't have a timestamp
            migrateFavoriteTimestamps()
        } catch {
            print("Failed to load stations from CoreData: \(error)")
        }
    }
    
    private func initializeOrderValues() {
        // Group stations by country and ensure proper order values
        let groupedStations = Dictionary(grouping: stations) { $0.country }
        var hasChanges = false
        
        for (country, countryStations) in groupedStations {
            // Sort stations for this country (maintain existing order if available)
            let sortedStations = countryStations.sorted { station1, station2 in
                if station1.order != station2.order {
                    return station1.order < station2.order
                }
                return station1.name < station2.name // fallback to alphabetical
            }
            
            // Check if order values need to be fixed
            var needsReordering = false
            for (index, station) in sortedStations.enumerated() {
                if station.order != index {
                    needsReordering = true
                    break
                }
            }
            
            if needsReordering {
                // Update order values
                for (index, station) in sortedStations.enumerated() {
                    if let stationIndex = stations.firstIndex(where: { $0.id == station.id }) {
                        stations[stationIndex].order = index
                        hasChanges = true
                    }
                }
            }
        }
        
        // Save changes if any were made
        if hasChanges {
            print("Initialized order values for stations")
            saveStationsToCoreData()
        }
    }
}

extension Notification.Name {
    static let countrySelected = Notification.Name("countrySelected")
    static let stationsUpdated = Notification.Name("stationsUpdated")
    static let countryChanged = Notification.Name("countryChanged")
}

// Conform to UIDocumentPickerDelegate to handle document picker events
extension RadioStationViewModel: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Handle the document picker result if needed
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Handle the document picker cancellation if needed
    }
}
