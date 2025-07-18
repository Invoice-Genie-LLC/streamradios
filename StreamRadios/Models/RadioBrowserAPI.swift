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
}

class RadioBrowserAPI: ObservableObject {
    static let shared = RadioBrowserAPI()
    
    private var availableServers: [String] = []
    private var selectedServer: String?
    private let userAgent = "StreamRadios/1.0"
    
    // Fallback servers that are always available (prioritized by known working status)
    private let fallbackServers = [
        "fi1.api.radio-browser.info",   // User confirmed working
        "de2.api.radio-browser.info",   // User confirmed working
        "de1.api.radio-browser.info",
        "nl1.api.radio-browser.info",
        "at1.api.radio-browser.info"
    ]
    
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
                print("✅ RadioBrowserAPI: Discovered \(discoveredServers.count) servers, using: \(selectedServer ?? "none")")
            } else {
                print("⚠️ RadioBrowserAPI: No servers discovered via DNS, using fallback servers")
            }
        } catch {
            print("❌ RadioBrowserAPI: Server discovery failed: \(error)")
            print("🔄 RadioBrowserAPI: Using fallback servers")
        }
    }
    
    private func discoverRadioBrowserServers() async throws -> [String] {
        // For iOS, we'll skip the DNS TXT record lookup and use our known good servers
        // This is because iOS doesn't provide easy access to DNS TXT records
        print("📡 RadioBrowserAPI: Using predefined servers (DNS discovery not available on iOS)")
        return []
    }
    
    private func selectBestServer() -> String {
        guard let server = selectedServer ?? availableServers.first else {
            return fallbackServers.first!
        }
        return server
    }
    
    // MARK: - API Methods
    
    func fetchTopStationsByCountry(countryCode: String, limit: Int = 20) async throws -> [RadioBrowserStation] {
        let server = selectBestServer()
        let urlString = "https://\(server)/json/stations/bycountrycodeexact/\(countryCode)?limit=\(limit)&order=clickcount&reverse=true"
        
        guard let url = URL(string: urlString) else {
            throw RadioBrowserError.invalidURL
        }
        
        print("🌐 RadioBrowserAPI: Fetching top \(limit) stations for country '\(countryCode)' from \(server)")
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RadioBrowserError.invalidResponse
            }
            
            print("📡 RadioBrowserAPI: HTTP Status \(httpResponse.statusCode) for country '\(countryCode)'")
            
            guard httpResponse.statusCode == 200 else {
                throw RadioBrowserError.httpError(httpResponse.statusCode)
            }
            
            let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
            print("✅ RadioBrowserAPI: Successfully decoded \(stations.count) stations for country '\(countryCode)'")
            
            return stations
            
        } catch let error as DecodingError {
            print("❌ RadioBrowserAPI: JSON decoding failed for country '\(countryCode)': \(error)")
            throw RadioBrowserError.decodingFailed(error)
        } catch {
            print("❌ RadioBrowserAPI: Network request failed for country '\(countryCode)': \(error)")
            throw RadioBrowserError.networkError(error)
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
            print("✅ RadioBrowserAPI: Successfully found \(stations.count) stations in search")
            
            return stations
            
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
            
            return stations.first
            
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