//
//  SpotifyAuthorizationManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/6/24.
//

import Foundation
import Combine
import SpotifyiOS

class SpotifyAuthorizationManager: NSObject, ObservableObject, SPTSessionManagerDelegate {
    static let shared = SpotifyAuthorizationManager()
    
    @Published var isAuthorized = false
    private var sessionManager: SPTSessionManager?
    private let clientID = "c1c2689e9e6c4218b09dcecc44755ee1"
    private let redirectURL = URL(string: "spotify-ios-quick-start://spotify-login-callback")!
    private var accessToken: String?
    private var refreshToken: String?
    private let baseURL = "https://api.spotify.com/v1"
    @Published var shouldShowConfirmationDialog = false
    private var authorizationCompletion: ((Bool) -> Void)?
    
    override init() {
            super.init()
            let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
            sessionManager = SPTSessionManager(configuration: configuration, delegate: self)
            
            // Load persisted authorization state
            self.isAuthorized = UserDefaults.standard.bool(forKey: "SpotifyAuthorized")
            self.accessToken = UserDefaults.standard.string(forKey: "SpotifyAccessToken")
            self.refreshToken = UserDefaults.standard.string(forKey: "SpotifyRefreshToken")
            
            // Check if the token needs to be refreshed
            if isAuthorized {
                checkAndRefreshTokenIfNeeded { _ in }
            }
        }
    
    func fetchUserPlaylists(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
            guard let accessToken = self.accessToken else {
                completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access token available"])))
                return
            }
            
            let urlString = "\(baseURL)/me/playlists"
            
            guard let url = URL(string: urlString) else {
                completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    print("Network error: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
                    return
                }

                if httpResponse.statusCode == 401 {
                    print("Access token expired, attempting to refresh")
                    self.refreshAccessToken { success in
                        if success {
                            print("Token refreshed successfully, retrying playlist fetch")
                            self.fetchUserPlaylists(completion: completion)
                        } else {
                            completion(.failure(NSError(domain: "SpotifyError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh access token"])))
                        }
                    }
                    return
                }

                guard let data = data else {
                    print("No data received")
                    completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                    return
                }

                // Print raw response for debugging
                print("Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to convert data to string")")

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                        print("Failed to parse JSON")
                        completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON"])))
                        return
                    }

                    print("Received JSON: \(json)")
                    
                    guard let items = json["items"] as? [[String: Any]] else {
                        print("No 'items' key found in JSON or it's not an array")
                        completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure: missing 'items' array"])))
                        return
                    }

                    let playlists = items.compactMap { item -> (id: String, name: String)? in
                        guard let id = item["id"] as? String,
                              let name = item["name"] as? String else {
                            return nil
                        }
                        return (id: id, name: name)
                    }

                    if playlists.isEmpty {
                        print("No playlists found")
                        completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No playlists found"])))
                    } else {
                        print("Successfully fetched \(playlists.count) playlists")
                        completion(.success(playlists))
                    }
                } catch {
                    print("JSON parsing error: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }.resume()
        }
    
    func checkAndRefreshTokenIfNeeded(completion: @escaping (Bool) -> Void) {
            guard let expirationDate = UserDefaults.standard.object(forKey: "SpotifyTokenExpirationDate") as? Date else {
                refreshAccessToken(completion: completion)
                return
            }

            if Date() >= expirationDate {
                refreshAccessToken(completion: completion)
            } else {
                completion(true)
            }
        }
    
    func searchForTrackURI(songTitle: String, artistName: String, completion: @escaping (Result<String, Error>) -> Void) {
            guard let accessToken = self.accessToken else {
                completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access token available"])))
                return
            }

            let query = "\(songTitle) \(artistName)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "\(baseURL)/search?q=\(query)&type=track&limit=1"
            
            guard let url = URL(string: urlString) else {
                completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let tracks = json["tracks"] as? [String: Any],
                       let items = tracks["items"] as? [[String: Any]],
                       let firstTrack = items.first,
                       let uri = firstTrack["uri"] as? String {
                        completion(.success(uri))
                    } else {
                        completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No track found or unexpected JSON structure"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }
    
    func authorize(completion: @escaping (Bool) -> Void) {
            if isAuthorized {
                checkAndRefreshTokenIfNeeded { success in
                    if success {
                        completion(true)
                    } else {
                        self.performAuthorization(completion: completion)
                    }
                }
            } else {
                performAuthorization(completion: completion)
            }
        }
    
    private func performAuthorization(completion: @escaping (Bool) -> Void) {
           let scopes: SPTScope = [.playlistModifyPrivate, .playlistModifyPublic, .userReadPrivate, .playlistReadPrivate]
           sessionManager?.initiateSession(with: scopes, options: .default, campaign: nil)
           self.authorizationCompletion = completion
       }
    
    func handleAuthCallback(url: URL) -> Bool {
        guard let sessionManager = sessionManager else { return false }
        
        let parameters = sessionManager.application(UIApplication.shared, open: url, options: [:])
        
        if parameters {
            print("Successfully handled Spotify auth callback")
            return true
        } else {
            print("Failed to handle Spotify auth callback")
            return false
        }
    }
    
    private func saveAccessToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "SpotifyAccessToken")
    }

    private func loadAccessToken() -> String? {
        return UserDefaults.standard.string(forKey: "SpotifyAccessToken")
    }
    
    private func saveRefreshToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "SpotifyRefreshToken")
    }
    
    private func loadRefreshToken() -> String? {
        return UserDefaults.standard.string(forKey: "SpotifyRefreshToken")
    }
    
    private func saveAccessToken(_ token: String?) {
        if let token = token {
            UserDefaults.standard.set(token, forKey: "SpotifyAccessToken")
        } else {
            UserDefaults.standard.removeObject(forKey: "SpotifyAccessToken")
        }
    }

    private func saveRefreshToken(_ token: String?) {
        if let token = token {
            UserDefaults.standard.set(token, forKey: "SpotifyRefreshToken")
        } else {
            UserDefaults.standard.removeObject(forKey: "SpotifyRefreshToken")
        }
    }
    
    func refreshAccessToken(completion: @escaping (Bool) -> Void) {
            guard let refreshToken = self.refreshToken else {
                print("No refresh token available")
                DispatchQueue.main.async {
                    self.isAuthorized = false
                    UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                    completion(false)
                }
                return
            }

            let tokenURL = "https://accounts.spotify.com/api/token"
            guard let url = URL(string: tokenURL) else {
                print("Invalid token URL")
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            let bodyParams = [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID
            ]
            request.httpBody = bodyParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)
            
            request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    if let error = error {
                        print("Error refreshing token: \(error.localizedDescription)")
                        self.isAuthorized = false
                        UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                        completion(false)
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("Invalid response")
                        self.isAuthorized = false
                        UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                        completion(false)
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        print("HTTP Error: \(httpResponse.statusCode)")
                        self.isAuthorized = false
                        UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                        completion(false)
                        return
                    }

                    guard let data = data else {
                        print("No data received while refreshing token")
                        self.isAuthorized = false
                        UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                        completion(false)
                        return
                    }

                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                            print("Received refresh token JSON: \(json)")
                            
                            if let newAccessToken = json["access_token"] as? String {
                                self.accessToken = newAccessToken
                                self.saveAccessToken(newAccessToken)
                                
                                if let newRefreshToken = json["refresh_token"] as? String {
                                    self.refreshToken = newRefreshToken
                                    self.saveRefreshToken(newRefreshToken)
                                }
                                
                                if let expiresIn = json["expires_in"] as? TimeInterval {
                                    let expirationDate = Date().addingTimeInterval(expiresIn)
                                    UserDefaults.standard.set(expirationDate, forKey: "SpotifyTokenExpirationDate")
                                }
                                
                                self.isAuthorized = true
                                UserDefaults.standard.set(true, forKey: "SpotifyAuthorized")
                                print("Successfully refreshed access token")
                                completion(true)
                            } else {
                                print("No access_token found in refresh response")
                                self.isAuthorized = false
                                UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                                completion(false)
                            }
                        } else {
                            print("Failed to parse refresh token JSON")
                            self.isAuthorized = false
                            UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                            completion(false)
                        }
                    } catch {
                        print("Error parsing refresh token JSON: \(error.localizedDescription)")
                        self.isAuthorized = false
                        UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                        completion(false)
                    }
                }
            }.resume()
        }
    
    func isSpotifyInstalled() -> Bool {
           guard let spotifyURL = URL(string: "spotify:") else {
               return false
           }
           return UIApplication.shared.canOpenURL(spotifyURL)
       }
    
    func addToSpotifyPlaylist(songTitle: String, artistName: String, playlistID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard self.accessToken != nil else {
            completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access token available"])))
            return
        }

        searchForTrack(songTitle: songTitle, artistName: artistName) { result in
            switch result {
            case .success(let trackID):
                self.addTrackToPlaylist(playlistID: playlistID, trackID: trackID) { result in
                    switch result {
                    case .success:
                        print("Successfully added \(songTitle) by \(artistName) to playlist")
                        completion(.success(()))
                    case .failure(let error):
                        print("Failed to add track to playlist: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                print("Failed to find track: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private func searchForTrack(songTitle: String, artistName: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let accessToken = self.accessToken else {
            completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access token available"])))
            return
        }

        let query = "\(songTitle) \(artistName)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/search?q=\(query)&type=track&limit=1"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Token might be expired, try to refresh
                self.refreshAccessToken { success in
                    if success {
                        // Retry the search with the new token
                        self.searchForTrack(songTitle: songTitle, artistName: artistName, completion: completion)
                    } else {
                        completion(.failure(NSError(domain: "SpotifyError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh access token"])))
                    }
                }
                return
            }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tracks = json["tracks"] as? [String: Any],
                   let items = tracks["items"] as? [[String: Any]],
                   let firstTrack = items.first,
                   let trackID = firstTrack["id"] as? String {
                    completion(.success(trackID))
                } else {
                    completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No track found or unexpected JSON structure"])))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func getUserPlaylists(accessToken: String, completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        let urlString = "\(baseURL)/me/playlists"
        
        var request = URLRequest(url: URL(string: urlString)!)
           request.httpMethod = "GET"
           request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: 0, userInfo: nil)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let items = json["items"] as? [[String: Any]] {
                    let playlists = items.compactMap { item -> (id: String, name: String)? in
                        guard let id = item["id"] as? String,
                              let name = item["name"] as? String else {
                            return nil
                        }
                        return (id: id, name: name)
                    }
                    completion(.success(playlists))
                } else {
                    completion(.failure(NSError(domain: "Parse error", code: 0, userInfo: nil)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func addTrackToPlaylist(playlistID: String, trackID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let urlString = "\(baseURL)/playlists/\(playlistID)/tracks"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["uris": ["spotify:track:\(trackID)"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 {
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "Failed to add track", code: 0, userInfo: nil)))
            }
        }.resume()
    }
    
    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
            self.accessToken = session.accessToken
            self.refreshToken = session.refreshToken
            self.saveAccessToken(session.accessToken)
            self.saveRefreshToken(session.refreshToken)
            
            let expirationDate = Date().addingTimeInterval(session.expirationDate.timeIntervalSinceNow)
            UserDefaults.standard.set(expirationDate, forKey: "SpotifyTokenExpirationDate")
            
            DispatchQueue.main.async {
                self.isAuthorized = true
                UserDefaults.standard.set(true, forKey: "SpotifyAuthorized")
                self.authorizationCompletion?(true)
                self.authorizationCompletion = nil
            }
        }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
            print("Spotify authorization failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isAuthorized = false
                UserDefaults.standard.set(false, forKey: "SpotifyAuthorized")
                self.authorizationCompletion?(false)
                self.authorizationCompletion = nil
            }
        }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        print("Spotify session renewed")
        self.accessToken = session.accessToken
    }

    private func sessionManager(manager: SPTSessionManager, shouldRequestAccessTokenWith scopes: SPTScope) -> Bool {
        return true
    }
    
    func sessionManager(manager: SPTSessionManager, didReceive accessToken: String, expiresIn expires: TimeInterval) {
        self.accessToken = accessToken
        print("Received new Spotify access token, expires in \(expires) seconds")
    }
}
