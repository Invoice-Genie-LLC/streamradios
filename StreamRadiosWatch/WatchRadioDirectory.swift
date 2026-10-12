import Foundation
import Observation
import StreamRadiosCore

@MainActor
@Observable
final class WatchRadioDirectory {
    nonisolated static let stationLimit = 20

    struct Country: Identifiable, Hashable {
        let code: String
        let name: String

        var id: String { code }
    }

    private struct APIStation: Decodable, Sendable {
        let stationuuid: String
        let name: String
        let url: String
        let urlResolved: String?
        let favicon: String?
        let country: String?

        enum CodingKeys: String, CodingKey {
            case stationuuid, name, url, favicon, country
            case urlResolved = "url_resolved"
        }
    }

    private static let servers = [
        "de1.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "all.api.radio-browser.info"
    ]

    private(set) var stations: [SRRadioStationRecord] = []
    private(set) var selectedCountry: Country
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let countries: [Country]

    init() {
        let locale = Locale(identifier: "en_US")
        countries = Locale.isoRegionCodes.compactMap { code in
            guard let name = locale.localizedString(forRegionCode: code) else { return nil }
            return Country(code: code, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let storedCode = UserDefaults.standard.string(forKey: "watchRadioCountryCode") ?? "US"
        selectedCountry = countries.first { $0.code == storedCode }
            ?? Country(code: "US", name: "United States")
    }

    func adoptSyncedCountry(name: String, code: String) async {
        guard UserDefaults.standard.string(forKey: "watchRadioCountryCode") == nil,
              !code.isEmpty else { return }
        selectedCountry = Country(code: code.uppercased(), name: name)
    }

    func select(_ country: Country) async {
        guard selectedCountry != country else {
            await loadStations()
            return
        }
        selectedCountry = country
        stations = []
        UserDefaults.standard.set(country.code, forKey: "watchRadioCountryCode")
        await loadStations()
    }

    func loadStations(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || stations.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if !force, let cached = await Self.cachedStations(for: selectedCountry.code) {
            stations = cached
            return
        }

        let code = selectedCountry.code
        let decoded: [APIStation]? = await withTaskGroup(of: [APIStation]?.self) {
            group -> [APIStation]? in
            for server in Self.servers {
                group.addTask { try? await Self.fetchStations(server: server, countryCode: code) }
            }
            for await result in group {
                if let result, !result.isEmpty {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let decoded else {
            errorMessage = "The station directory is unavailable."
            return
        }

        var seenURLs = Set<String>()
        stations = Array(decoded.compactMap { station -> SRRadioStationRecord? in
            let streamURL = station.urlResolved ?? station.url
            let identity = streamURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !station.name.isEmpty,
                  !streamURL.isEmpty,
                  seenURLs.insert(identity).inserted else { return nil }
            return SRRadioStationRecord(
                id: station.stationuuid,
                name: station.name.trimmingCharacters(in: .whitespacesAndNewlines),
                streamURL: streamURL,
                artworkURL: station.favicon,
                country: station.country ?? selectedCountry.name
            )
        }.prefix(Self.stationLimit))
        await Self.cache(stations, for: selectedCountry.code)
    }

    nonisolated private static func fetchStations(
        server: String,
        countryCode: String
    ) async throws -> [APIStation] {
        let code = countryCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? countryCode
        guard let url = URL(string:
            "https://\(server)/json/stations/bycountrycodeexact/\(code)?limit=\(stationLimit)&order=clickcount&reverse=true&hidebroken=true"
        ) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([APIStation].self, from: data)
    }

    nonisolated private static func cachedStations(
        for countryCode: String
    ) async -> [SRRadioStationRecord]? {
        await Task.detached(priority: .utility) {
            let destination = cacheURL(for: countryCode)
            let source = FileManager.default.fileExists(atPath: destination.path)
                ? destination
                : legacyCacheURL(for: countryCode)
            guard let data = try? Data(contentsOf: source),
                let decoded = try? JSONDecoder().decode([SRRadioStationRecord].self, from: data) else { return nil }
            let limited = Array(decoded.prefix(stationLimit))
            if source != destination || decoded.count > stationLimit {
                try? FileManager.default.createDirectory(
                    at: cacheDirectoryURL,
                    withIntermediateDirectories: true
                )
                if let limitedData = try? JSONEncoder().encode(limited) {
                    try? limitedData.write(to: destination, options: .atomic)
                }
            }
            return limited
        }.value
    }

    nonisolated private static func cache(
        _ stations: [SRRadioStationRecord],
        for countryCode: String
    ) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(Array(stations.prefix(stationLimit))) else { return }
            try? FileManager.default.createDirectory(
                at: cacheDirectoryURL,
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL(for: countryCode), options: .atomic)
        }.value
    }

    nonisolated private static var cacheDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamRadios/RadioDirectory", isDirectory: true)
    }

    nonisolated private static func cacheURL(for countryCode: String) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("watch-radio-\(countryCode.uppercased()).json")
    }

    nonisolated private static func legacyCacheURL(for countryCode: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-radio-\(countryCode.uppercased()).json")
    }
}
