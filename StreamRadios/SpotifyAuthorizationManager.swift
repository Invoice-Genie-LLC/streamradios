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
    private let redirectURL = URL(string: "streamradios://spotify-auth-callback")!
    private var accessToken: String?
    private let baseURL = "https://api.spotify.com/v1"
    @Published var shouldShowConfirmationDialog = false
    private var authorizationCompletion: ((Bool) -> Void)?

    
    override init() {
        super.init()
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
        sessionManager = SPTSessionManager(configuration: configuration, delegate: self)
        if let token = loadAccessToken() {
            self.accessToken = token
            self.isAuthorized = true
        }
    }
    
    func fetchUserPlaylists(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        guard self.accessToken != nil else {
            completion(.failure(NSError(domain: "SpotifyError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access token available"])))
            return
        }
        
        getUserPlaylists { result in
            switch result {
            case .success(let playlists):
                completion(.success(playlists))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func searchForTrackURI(songTitle: String, artistName: String, completion: @escaping (Result<String, Error>) -> Void) {
        let query = "\(songTitle) \(artistName)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/search?q=\(query)&type=track&limit=1"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

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
                   let tracks = json["tracks"] as? [String: Any],
                   let items = tracks["items"] as? [[String: Any]],
                   let firstItem = items.first,
                   let uri = firstItem["uri"] as? String {
                    completion(.success(uri))
                } else {
                    completion(.failure(NSError(domain: "No track found", code: 0, userInfo: nil)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    func authorize(completion: @escaping (Bool) -> Void) {
            if isAuthorized {
                completion(true)
                return
            }
            
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
        let query = "\(songTitle) \(artistName)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/search?q=\(query)&type=track&limit=1"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

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
                   let tracks = json["tracks"] as? [String: Any],
                   let items = tracks["items"] as? [[String: Any]],
                   let firstTrack = items.first,
                   let trackID = firstTrack["id"] as? String {
                    completion(.success(trackID))
                } else {
                    completion(.failure(NSError(domain: "Parse error", code: 0, userInfo: nil)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func getUserPlaylists(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        let urlString = "\(baseURL)/me/playlists"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

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
        self.saveAccessToken(session.accessToken)
        DispatchQueue.main.async {
            self.isAuthorized = true
            self.authorizationCompletion?(true)
            self.authorizationCompletion = nil
        }
    }

        func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
            print("Spotify authorization failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isAuthorized = false
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
