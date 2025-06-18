// RadioStationViewModel.swift
// StreamRadios
//
// Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import Combine
import CoreData
import UniformTypeIdentifiers


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
    @Published var selectedTab: Tab = .all
    @Published var activeSheet: ActiveSheet? = nil
    @Published var isLoading = false
    @Published var isDeletingData: Bool = false
    @Published var deletionComplete: Bool = false
    @Published var isCloudKitOperationRunning = false
    @Published var isDeletionInProgress = false
    @Published var isUploadingToCloudKit = false
    
    @Published var selectedCountry: String = UserDefaults.standard.string(forKey: "selectedCountry") ?? "Select Country" {
        didSet {
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
        
            syncStationsWithCloudKit()
    
            loadStationsFromCoreData()
            
            let userDefaults = UserDefaults.standard
            let hasLaunchedBeforeKey = "HasLaunchedBefore"
            
            if !userDefaults.bool(forKey: hasLaunchedBeforeKey) {
                print("First time setup or new default stations detected, initializing default stations and saving to local and CloudKit.")
                initializeStationsForFirstTime()
            } else {
                print("App relaunch detected.")
                syncStationsWithCloudKit() // This method will ensure data consistency with CloudKit
            }
        }
    
    func importStationsFromFile(url: URL, progressHandler: @escaping (Double) -> Void, completion: @escaping () -> Void) {
            do {
                let data = try Data(contentsOf: url)
                let jsonDecoder = JSONDecoder()
                let stationsFromJson = try jsonDecoder.decode([RadioStation].self, from: data)

                let totalStations = Double(stationsFromJson.count)
                var importedStations = 0.0

                DispatchQueue.main.async {
                    for station in stationsFromJson {
                        self.stations.append(station)
                        importedStations += 1
                        progressHandler(importedStations / totalStations)
                    }

                    print("Imported \(stationsFromJson.count) stations.")

                    // Save these to CoreData
                    self.saveStationsToCoreData()

                    // Save to CloudKit
                    self.saveStationsToCloudKit()

                    // Optionally, if there is a need to notify or refresh the UI, do it here
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
                    completion() // Call the completion handler
                }
            } catch {
                print("Failed to import stations: \(error)")
                completion() // Call the completion handler even in case of failure
            }
        }
    
    func exportStationsToFile(completion: @escaping (URL?) -> Void) {
        let filteredStations = self.stations.filter { $0.country == self.selectedCountry || self.selectedCountry == "Select Country" }
                                            .map(ExportStation.init)

        // Create JSON string manually for each station and join them in an array format
        let jsonStrings = filteredStations.map { $0.jsonString }
        let jsonArrayString = "[\n" + jsonStrings.joined(separator: ",\n") + "\n]"

        let fileName = "stations_export.json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try jsonArrayString.write(to: fileURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                completion(fileURL)
            }
        } catch {
            print("Failed to export stations: \(error)")
            DispatchQueue.main.async {
                completion(nil)
            }
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
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: CDStation.fetchRequest())
        
        context.perform {
            do {
                try context.execute(deleteRequest)
                try context.save()
                self.stations.removeAll()
                self.isDeletingData = false
                self.deletionComplete = true
                completion(true, nil)
            } catch {
                print("Error deleting stations from CoreData: \(error.localizedDescription)")
                self.isDeletingData = false
                completion(false, error)
            }
        }
    }
    
    func syncStationsWithCloudKit() {
        CoreDataStack.shared.syncStationsFromCloudKit { [weak self] error in
            if let error = error {
                print("Error syncing with CloudKit: \(error.localizedDescription)")
            } else {
                print("Stations successfully synchronized with CloudKit.")
                DispatchQueue.main.async {
                    self?.loadStationsFromCoreData() // Reload stations from CoreData after sync
                    NotificationCenter.default.post(name: .stationsUpdated, object: nil)
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
    
    func toggleFavorite(for station: RadioStation) {
        if let index = stations.firstIndex(of: station), !isStationPlaying(stations[index]) {
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
        saveStationsToCoreData()  // Save the updated order to CoreData
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
        Task { @MainActor in
            var needsUpdate = false
            let now = Date()
            
            for i in 0..<stations.count {
                if stations[i].isFavorite && stations[i].favoritedAt == nil {
                    stations[i].favoritedAt = now
                    needsUpdate = true
                }
            }
            
            if needsUpdate {
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
                saveStationsToCoreData()
                objectWillChange.send()  // Notify observers of the change
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
        let newStation = RadioStation(id: UUID().uuidString, name: name, url: url, iconData: iconData, country: country, isFavorite: false, favoriteOrder: nil)
        stations.append(newStation)
        print("Added new station: \(newStation)")
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
        } catch {
            print("Failed to delete station from CoreData: \(error)")
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
                    existingStation.order = Int16(index)
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
                    newStation.order = Int16(index)
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
                    lastPlayed: cdStation.lastPlayed
                )
            }
            print("Loaded \(stations.count) stations from CoreData.")
            
            // Migration: Set favoritedAt for existing favorites that don't have a timestamp
            migrateFavoriteTimestamps()
        } catch {
            print("Failed to load stations from CoreData: \(error)")
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
