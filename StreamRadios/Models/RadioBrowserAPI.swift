//
//  RadioBrowserAPI.swift
//  StreamRadios
//
//  Created by AI Assistant on 1/2/25.
//

import Foundation
import Network

struct RadioBrowserStation: Codable {
    let stationuuid: String
    let name: String
    let url: String
    let homepage: String?
    let favicon: String?
    let tags: String?
    let country: String?
    let countrycode: String?
    let state: String?
    let language: String?
    let languagecodes: String?
    let votes: Int?
    let lastchangetime: String?
    let codec: String?
    let bitrate: Int?
    let hls: Int?
    let lastcheckok: Int?
    let lastchecktime: String?
    let lastcheckoktime: String?
    let clickcount: Int?
    let clicktrend: Int?
    let ssl_error: Int?
    let geo_lat: Double?
    let geo_long: Double?
    let has_extended_info: Bool?
    
    /// Returns a cleaned copy with normalized country name and cleaned station name
    func cleaned() -> RadioBrowserStation {
        let normalizedCountry = RadioBrowserAPI.normalizeCountryName(country) ?? country
        let cleanedName = RadioBrowserAPI.cleanStationName(name)
        
        return RadioBrowserStation(
            stationuuid: stationuuid,
            name: cleanedName,
            url: url,
            homepage: homepage,
            favicon: favicon,
            tags: tags,
            country: normalizedCountry,
            countrycode: countrycode,
            state: state,
            language: language,
            languagecodes: languagecodes,
            votes: votes,
            lastchangetime: lastchangetime,
            codec: codec,
            bitrate: bitrate,
            hls: hls,
            lastcheckok: lastcheckok,
            lastchecktime: lastchecktime,
            lastcheckoktime: lastcheckoktime,
            clickcount: clickcount,
            clicktrend: clicktrend,
            ssl_error: ssl_error,
            geo_lat: geo_lat,
            geo_long: geo_long,
            has_extended_info: has_extended_info
        )
    }
}

class RadioBrowserAPI: ObservableObject {
    static let shared = RadioBrowserAPI()
    
    private var availableServers: [String] = []
    private var selectedServer: String?
    private let userAgent = "StreamRadios/1.0"
    
    // Fallback servers that are always available (prioritized by known working status)
    // Note: Server availability changes - de1 and de2 are most reliable as of Jan 2026
    private let fallbackServers = [
        "de1.api.radio-browser.info",   // Most reliable, Germany
        "de2.api.radio-browser.info",   // Second most reliable, Germany
        "all.api.radio-browser.info",   // Auto-balancing endpoint
        "fi1.api.radio-browser.info",   // Finland - may have issues
        "nl1.api.radio-browser.info",   // Netherlands
        "at1.api.radio-browser.info"    // Austria
    ]
    
    // Track current server index for failover
    private var currentServerIndex: Int = 0
    
    private init() {
        // Initialize with fallback servers immediately
        self.availableServers = fallbackServers
        self.selectedServer = fallbackServers.first
        
        // Then try to discover better servers asynchronously
        Task {
            await discoverServers()
        }
    }
    
    // MARK: - Server Discovery
    
    private func discoverServers() async {
        do {
            // Query DNS for available servers
            let discoveredServers = try await discoverRadioBrowserServers()
            
            if !discoveredServers.isEmpty {
                availableServers = discoveredServers + fallbackServers
                selectedServer = discoveredServers.first
            }
        } catch {
            // Silently fall back to predefined servers
        }
    }
    
    private func discoverRadioBrowserServers() async throws -> [String] {
        // For iOS, we'll skip the DNS TXT record lookup and use our known good servers
        // This is because iOS doesn't provide easy access to DNS TXT records
        return []
    }
    
    private func selectBestServer() -> String {
        guard let server = selectedServer ?? availableServers.first else {
            return fallbackServers[currentServerIndex % fallbackServers.count]
        }
        return server
    }
    
    /// Called when a server fails to switch to the next available one
    private func failoverToNextServer() {
        currentServerIndex = (currentServerIndex + 1) % fallbackServers.count
        selectedServer = fallbackServers[currentServerIndex]
    }
    
    // MARK: - API Methods
    
    func fetchTopStationsByCountry(countryCode: String, limit: Int = 20, offset: Int = 0, order: String = "clickcount") async throws -> [RadioBrowserStation] {
        // Track servers we've tried to avoid infinite loops
        var triedServers: Set<String> = []
        var lastError: Error?
        
        // Try each available server until one works
        while triedServers.count < fallbackServers.count {
            let server = selectBestServer()
            
            // Skip if we've already tried this server
            if triedServers.contains(server) {
                failoverToNextServer()
                continue
            }
            triedServers.insert(server)
            
            let urlString = "https://\(server)/json/stations/bycountrycodeexact/\(countryCode)?limit=\(limit)&offset=\(offset)&order=\(order)&reverse=true"
            
            guard let url = URL(string: urlString) else {
                throw RadioBrowserError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15 // Reduced timeout to fail faster and try next server
            
            // Create a custom URLSession with retry configuration
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false // Don't wait, try next server instead
            let session = URLSession(configuration: config)
            
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw RadioBrowserError.invalidResponse
                }
                
                guard httpResponse.statusCode == 200 else {
                    throw RadioBrowserError.httpError(httpResponse.statusCode)
                }
                
                let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
                
                // Clean and deduplicate stations at API level
                let cleanedStations = stations.map { $0.cleaned() }
                let deduplicatedStations = RadioBrowserAPI.deduplicateStationsByURL(cleanedStations)
                
                return deduplicatedStations
                
            } catch let error as DecodingError {
                throw RadioBrowserError.decodingFailed(error)
            } catch {
                lastError = error
                
                // Failover to next server
                failoverToNextServer()
                
                // Small delay before trying next server
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
        
        // All servers exhausted
        if let lastError = lastError {
            throw RadioBrowserError.networkError(lastError)
        } else {
            throw RadioBrowserError.networkError(NSError(domain: "RadioBrowserAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "All servers unavailable"]))
        }
    }
    
    func searchStations(name: String? = nil, country: String? = nil, tag: String? = nil, limit: Int = 20) async throws -> [RadioBrowserStation] {
        let server = selectBestServer()
        var urlComponents = URLComponents(string: "https://\(server)/json/stations/search")!
        
        var queryItems: [URLQueryItem] = []
        
        if let name = name, !name.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }
        
        if let country = country, !country.isEmpty {
            queryItems.append(URLQueryItem(name: "country", value: country))
        }
        
        if let tag = tag, !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        
        queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        queryItems.append(URLQueryItem(name: "order", value: "clickcount"))
        queryItems.append(URLQueryItem(name: "reverse", value: "true"))
        
        urlComponents.queryItems = queryItems
        
        guard let url = urlComponents.url else {
            throw RadioBrowserError.invalidURL
        }
        
        print("🔍 RadioBrowserAPI: Searching stations with name='\(name ?? "nil")', country='\(country ?? "nil")', tag='\(tag ?? "nil")'")
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RadioBrowserError.invalidResponse
            }
            
            print("📡 RadioBrowserAPI: Search HTTP Status \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                throw RadioBrowserError.httpError(httpResponse.statusCode)
            }
            
            let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
            print("✅ RadioBrowserAPI: Found \(stations.count) stations in search")
            
            // Clean and deduplicate stations at API level
            let cleanedStations = stations.map { $0.cleaned() }
            let deduplicatedStations = RadioBrowserAPI.deduplicateStationsByURL(cleanedStations)
            
            return deduplicatedStations
            
        } catch let error as DecodingError {
            print("❌ RadioBrowserAPI: Search JSON decoding failed: \(error)")
            throw RadioBrowserError.decodingFailed(error)
        } catch {
            print("❌ RadioBrowserAPI: Search network request failed: \(error)")
            throw RadioBrowserError.networkError(error)
        }
    }
    
    func reportStationClick(stationUuid: String) async {
        let server = selectBestServer()
        let urlString = "https://\(server)/json/url/\(stationUuid)"
        
        guard let url = URL(string: urlString) else {
            print("❌ RadioBrowserAPI: Invalid URL for click report")
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("✅ RadioBrowserAPI: Successfully reported click for station \(stationUuid)")
                } else {
                    print("⚠️ RadioBrowserAPI: Click report HTTP Status \(httpResponse.statusCode) for station \(stationUuid)")
                }
            }
        } catch {
            print("⚠️ RadioBrowserAPI: Failed to report click for station \(stationUuid): \(error)")
        }
    }
    
    func getStationDetails(uuid: String) async throws -> RadioBrowserStation? {
        let server = selectBestServer()
        let urlString = "https://\(server)/json/stations/byuuid/\(uuid)"
        
        guard let url = URL(string: urlString) else {
            throw RadioBrowserError.invalidURL
        }
        
        print("🔍 RadioBrowserAPI: Fetching details for station \(uuid)")
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RadioBrowserError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw RadioBrowserError.httpError(httpResponse.statusCode)
            }
            
            let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
            print("✅ RadioBrowserAPI: Successfully fetched details for station \(uuid)")
            
            // Clean the station data before returning
            return stations.first?.cleaned()
            
        } catch let error as DecodingError {
            print("❌ RadioBrowserAPI: Details JSON decoding failed for station \(uuid): \(error)")
            throw RadioBrowserError.decodingFailed(error)
        } catch {
            print("❌ RadioBrowserAPI: Details request failed for station \(uuid): \(error)")
            throw RadioBrowserError.networkError(error)
        }
    }
    
    // MARK: - Health Check
    
    func checkServerHealth() async -> Bool {
        let server = selectBestServer()
        let urlString = "https://\(server)/json/stats"
        
        guard let url = URL(string: urlString) else {
            return false
        }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                let isHealthy = httpResponse.statusCode == 200
                print("🏥 RadioBrowserAPI: Server \(server) health check: \(isHealthy ? "✅ Healthy" : "❌ Unhealthy (\(httpResponse.statusCode))")")
                return isHealthy
            }
        } catch {
            print("🏥 RadioBrowserAPI: Server \(server) health check failed: \(error)")
        }
        
        return false
    }
    
    // MARK: - Country Name Normalization
    
    /// Normalize API country names to our standard format
    /// Call this ONCE when receiving data from API to avoid redundant processing downstream
    static func normalizeCountryName(_ apiCountryName: String?) -> String? {
        guard let rawName = apiCountryName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return nil
        }
        
        // Fast path: common country names that don't need normalization
        let commonCountries: Set<String> = ["United States", "United Kingdom", "Germany", "France", "Italy", "Spain", "Canada", "Australia", "India", "Brazil", "Japan", "China", "Mexico", "Russia", "Netherlands", "Belgium", "Switzerland", "Austria", "Poland", "Sweden", "Norway", "Denmark", "Finland", "Ireland", "Portugal", "Greece", "Turkey", "Argentina", "Chile", "Colombia", "Peru", "Venezuela", "South Africa", "Egypt", "Nigeria", "Kenya", "Morocco", "Israel", "Saudi Arabia", "United Arab Emirates", "Thailand", "Vietnam", "Indonesia", "Philippines", "Malaysia", "Singapore", "South Korea", "Taiwan", "New Zealand"]
        
        if commonCountries.contains(rawName) {
            return rawName
        }
        
        // Normalize problematic API country names
        switch rawName {
        case "The United States Of America", "United States Of America", "USA", "US", "America":
            return "United States"
        case "The United Kingdom Of Great Britain And Northern Ireland", "UK", "Great Britain", "Britain":
            return "United Kingdom"
        case "The Netherlands":
            return "Netherlands"
        case "The Bahamas":
            return "Bahamas"
        case "The Gambia":
            return "Gambia"
        case "Russian Federation", "Russia (Russian Federation)":
            return "Russia"
        case "Czech Republic", "Czechia":
            return "Czech Republic"
        case "Republic of Korea", "Korea (Republic of)":
            return "South Korea"
        case "Viet Nam":
            return "Vietnam"
        case "Iran (Islamic Republic of)", "Islamic Republic of Iran":
            return "Iran"
        case "Syrian Arab Republic":
            return "Syria"
        case "Venezuela (Bolivarian Republic of)":
            return "Venezuela"
        case "Bolivia (Plurinational State of)":
            return "Bolivia"
        case "Tanzania (United Republic of)":
            return "Tanzania"
        case "Moldova (Republic of)":
            return "Moldova"
        case "Macedonia (the former Yugoslav Republic of)", "The Former Yugoslav Republic of Macedonia", "North Macedonia":
            return "Macedonia"
        case "Lao People's Democratic Republic":
            return "Laos"
        case "Brunei Darussalam":
            return "Brunei"
        case "Myanmar (Burma)", "Burma":
            return "Myanmar"
        case "Côte d'Ivoire", "Cote d'Ivoire", "Ivory Coast":
            return "Côte d'Ivoire"
        case "Timor-Leste", "East Timor":
            return "Timor-Leste"
        case "Vatican", "Holy See", "Vatican City State", "The Vatican":
            return "Vatican City"
        default:
            // Handle "The X" pattern
            if rawName.hasPrefix("The ") {
                return String(rawName.dropFirst(4))
            }
            return rawName
        }
    }
    
    /// Clean station name by removing leading special characters and trimming whitespace
    static func cleanStationName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove leading special characters (non-alphanumeric)
        while !cleaned.isEmpty && !cleaned.first!.isLetter && !cleaned.first!.isNumber {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Deduplicate stations by URL, preferring HTTPS over HTTP
    static func deduplicateStationsByURL(_ stations: [RadioBrowserStation]) -> [RadioBrowserStation] {
        var urlToStation: [String: RadioBrowserStation] = [:]
        
        for station in stations {
            guard !station.url.isEmpty else { continue }
            
            // Normalize URL by removing protocol
            let normalizedURL = station.url.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            
            if let existing = urlToStation[normalizedURL] {
                // Prefer HTTPS over HTTP
                let existingIsHTTPS = existing.url.lowercased().hasPrefix("https://")
                let currentIsHTTPS = station.url.lowercased().hasPrefix("https://")
                
                if currentIsHTTPS && !existingIsHTTPS {
                    urlToStation[normalizedURL] = station
                }
                // Otherwise keep the first (usually higher click count)
            } else {
                urlToStation[normalizedURL] = station
            }
        }
        
        return Array(urlToStation.values)
    }
}

// MARK: - Error Types

enum RadioBrowserError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case httpError(Int)
    case decodingFailed(Error)
    case noServersAvailable
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for RadioBrowser API"
        case .invalidResponse:
            return "Invalid response from RadioBrowser API"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .noServersAvailable:
            return "No RadioBrowser servers available"
        }
    }
} 