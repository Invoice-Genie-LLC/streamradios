///
//  YouTubeMusicManager.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/7/24.
//

import Foundation
import GoogleSignIn
import GoogleAPIClientForREST_YouTube
import UIKit

class YouTubeMusicManager: ObservableObject {
    @Published var isAuthorized = false
    static let shared = YouTubeMusicManager()

    private var service: GTLRYouTubeService?
    
    private let clientID = "833637905829-hd8dhr5k1adbji0mcn12lmqtgbvc0k3s.apps.googleusercontent.com"
    private let scopes = [
        "https://www.googleapis.com/auth/youtube.force-ssl",
        "https://www.googleapis.com/auth/youtube"
    ]
    
    private init() {
        setupGoogleSignIn()
    }
    
    private func setupGoogleSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
            if let user = user {
                self.setupYouTubeService(user: user)
            }
        }
    }
    
    func authorize(completion: @escaping (Bool) -> Void) {
        print("Required scopes: \(self.scopes)")
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            print("Failed to get root view controller")
            completion(false)
            return
        }
        
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        
        print("Starting Google Sign-In process")
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: nil, additionalScopes: self.scopes) { signInResult, error in
            if let error = error {
                print("Google Sign-In error: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            guard let user = signInResult?.user else {
                print("No user signed in")
                completion(false)
                return
            }
            
            print("Successfully signed in user: \(user.userID ?? "Unknown")")
            // Check if we have the required scopes
            let grantedScopes = user.grantedScopes ?? []
            print("Granted scopes: \(grantedScopes)")
            
            let missingScopes = Set(self.scopes).subtracting(grantedScopes)
            print("Missing scopes: \(missingScopes)")
            
            if missingScopes.isEmpty {
                self.setupYouTubeService(user: user)
                completion(true)
            } else {
                // Request missing scopes
                GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: nil, additionalScopes: Array(missingScopes)) { signInResult, error in
                    if let error = error {
                        print("Error requesting additional scopes: \(error.localizedDescription)")
                        completion(false)
                        return
                    }
                    
                    guard let user = signInResult?.user else {
                        print("No user signed in after requesting additional scopes")
                        completion(false)
                        return
                    }
                    
                    self.setupYouTubeService(user: user)
                    completion(true)
                }
            }
        }
    }
    
    private func setupYouTubeService(user: GIDGoogleUser) {
        let service = GTLRYouTubeService()
        service.authorizer = user.fetcherAuthorizer
        self.service = service
        
        DispatchQueue.main.async {
            self.isAuthorized = true
        }
    }
    
    func fetchUserPlaylists(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        guard let service = service else {
            completion(.failure(NSError(domain: "YouTubeMusicError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not authorized"])))
            return
        }
        
        let query = GTLRYouTubeQuery_PlaylistsList.query(withPart: ["snippet"])
        query.mine = true
        query.maxResults = 50
        
        service.executeQuery(query) { (ticket, result, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let playlistList = result as? GTLRYouTube_PlaylistListResponse,
                  let items = playlistList.items else {
                completion(.failure(NSError(domain: "YouTubeMusicError", code: 5, userInfo: [NSLocalizedDescriptionKey: "No playlists found"])))
                return
            }
            
            let playlists = items.compactMap { playlist -> (id: String, name: String)? in
                guard let id = playlist.identifier, let name = playlist.snippet?.title else { return nil }
                return (id: id, name: name)
            }
            
            completion(.success(playlists))
        }
    }
    
    func openInYouTubeMusic(songTitle: String, artistName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let service = service else {
            completion(.failure(NSError(domain: "YouTubeMusicError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not authorized"])))
            return
        }
        
        let query = GTLRYouTubeQuery_SearchList.query(withPart: ["snippet"])
        query.q = "\(songTitle) \(artistName) official"
        query.type = ["video"]
        query.maxResults = 1
        
        service.executeQuery(query) { (ticket, result, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let searchListResponse = result as? GTLRYouTube_SearchListResponse,
                  let videoId = searchListResponse.items?.first?.identifier?.videoId else {
                completion(.failure(NSError(domain: "YouTubeMusicError", code: 4, userInfo: [NSLocalizedDescriptionKey: "No video found"])))
                return
            }
            
            let videoURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
            
            DispatchQueue.main.async {
                UIApplication.shared.open(videoURL) { success in
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "YouTubeMusicError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to open YouTube"])))
                    }
                }
            }
        }
    }
    
    func saveToYouTubeMusicPlaylist(songTitle: String, artistName: String, playlistId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let service = service else {
            completion(.failure(NSError(domain: "YouTubeMusicError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not authorized"])))
            return
        }
        
        let query = GTLRYouTubeQuery_SearchList.query(withPart: ["snippet"])
        query.q = "\(songTitle) \(artistName) official"
        query.type = ["video"]
        query.maxResults = 1
        
        service.executeQuery(query) { (ticket, result, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let searchListResponse = result as? GTLRYouTube_SearchListResponse,
                  let videoId = searchListResponse.items?.first?.identifier?.videoId else {
                completion(.failure(NSError(domain: "YouTubeMusicError", code: 4, userInfo: [NSLocalizedDescriptionKey: "No video found"])))
                return
            }
            
            let playlistItem = GTLRYouTube_PlaylistItem()
            let resourceId = GTLRYouTube_ResourceId()
            resourceId.kind = "youtube#video"
            resourceId.videoId = videoId
            playlistItem.snippet = GTLRYouTube_PlaylistItemSnippet()
            playlistItem.snippet?.playlistId = playlistId
            playlistItem.snippet?.resourceId = resourceId
            
            let insertQuery = GTLRYouTubeQuery_PlaylistItemsInsert.query(withObject: playlistItem, part: ["snippet"])
            
            service.executeQuery(insertQuery) { (ticket, result, error) in
                if let error = error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
}
