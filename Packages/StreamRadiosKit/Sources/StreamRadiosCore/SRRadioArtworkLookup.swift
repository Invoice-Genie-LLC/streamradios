import Foundation

public enum SRRadioArtworkLookup {
    public struct Track: Equatable, Sendable {
        public let artist: String
        public let title: String
        public var key: String { "\(normalize(artist))|\(normalize(title))" }

        public init?(metadata: String, stationName: String) {
            var value = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = value.range(of: "StreamTitle='", options: .caseInsensitive) {
                value = String(value[range.upperBound...].components(separatedBy: "';").first ?? "")
            }
            guard value.count <= 512, normalize(value) != normalize(stationName) else { return nil }
            let separators = [" - ", " \u{2013} ", " \u{2014} ", "~", " | "]
            for separator in separators {
                let parts = value.components(separatedBy: separator)
                guard parts.count >= 2 else { continue }
                let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (separator == "~" ? parts[1] : parts.dropFirst().joined(separator: separator))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalize(artist).isEmpty, !normalize(title).isEmpty,
                      normalize(artist) != normalize(stationName),
                      normalize(title) != normalize(stationName) else { return nil }
                self.artist = artist
                self.title = title
                return
            }
            return nil
        }
    }

    public struct Result: Decodable, Sendable {
        public let artistName: String
        public let trackName: String
        public let artworkUrl100: URL?
    }

    private struct Response: Decodable { let results: [Result] }

    public static func artworkURL(for track: Track) async throws -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(track.title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let results = try JSONDecoder().decode(Response.self, from: data).results
        try Task.checkCancellation()
        return bestArtworkURL(for: track, results: results)
    }

    public static func bestArtworkURL(for track: Track, results: [Result]) -> URL? {
        let ranked = results.compactMap { result -> (URL, Double)? in
            guard let url = result.artworkUrl100, url.scheme == "https" else { return nil }
            let description = normalize("\(result.artistName) \(result.trackName)")
            guard !["karaoke", "tribute", "cover version", "in the style of", "backing track"]
                .contains(where: { description.contains($0) }) else { return nil }
            let score = max(
                match(artist: track.artist, title: track.title, result: result),
                match(artist: track.title, title: track.artist, result: result)
            )
            return score >= 0.75 ? (url, score) : nil
        }
        guard let url = ranked.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "100x100bb", with: "300x300bb")) ?? url
    }

    private static func match(artist: String, title: String, result: Result) -> Double {
        let artistScore = similarity(artist, result.artistName)
        let titleScore = similarity(title, result.trackName)
        guard artistScore >= 0.5, titleScore >= 0.6 else { return 0 }
        return artistScore * 0.4 + titleScore * 0.6
    }

    private static func similarity(_ query: String, _ candidate: String) -> Double {
        let query = normalize(query)
        let candidate = normalize(candidate)
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query.replacingOccurrences(of: " ", with: "") == candidate.replacingOccurrences(of: " ", with: "") { return 1 }
        let queryWords = Set(query.split(separator: " "))
        let candidateWords = Set(candidate.split(separator: " "))
        return Double(queryWords.intersection(candidateWords).count) / Double(max(queryWords.count, candidateWords.count))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}