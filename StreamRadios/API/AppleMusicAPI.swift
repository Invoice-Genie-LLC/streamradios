//
//  AppleMusicAPI.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/30/24.
//

import Foundation

struct AppleMusicAPI {
    static let developerToken = "eyJhbGciOiJFUzI1NiIsImtpZCI6IkI0QVFYSjdCRjkiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJMSDVWNjc0OThOIiwiaWF0IjoxNzE5NzgxMDI5LCJleHAiOjE3MzUzMzMwMjksImF1ZCI6ImFwcHN0b3JlY29ubmVjdC12MSJ9.Q4MO71iobDCg_CiS6UUy_I1_LeD-zIeoISLo8cI1f-skl2pwY6a_LeaTtSJLVoxtYfCfQGOwSSmJG03TLPgJkA"
    static let countryCode = "us" // Change this to the appropriate country code

    static func searchSong(title: String, artist: String, completion: @escaping (String?) -> Void) {
        let searchQuery = "\(title) \(artist)"
        guard let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(nil)
            return
        }

        let urlString = "https://api.music.apple.com/v1/catalog/\(countryCode)/search?term=\(encodedQuery)&types=songs&limit=1"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }

            if let result = try? JSONDecoder().decode(SearchResult.self, from: data) {
                completion(result.songs.data.first?.id)
            } else {
                completion(nil)
            }
        }
        task.resume()
    }

    struct SearchResult: Codable {
        let songs: Songs
    }

    struct Songs: Codable {
        let data: [Song]
    }

    struct Song: Codable {
        let id: String
    }
}
