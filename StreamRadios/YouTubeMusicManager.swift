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
import WebKit


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
        print("Starting authorization process")
        
        // Clear all Google Sign-In data
        GIDSignIn.sharedInstance.signOut()
        
        // Clean expired tokens and all related data
        self.cleanExpiredTokens()
        
        // Wait for a moment before starting the sign-in process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.performSignIn(retryCount: 3, completion: completion)
        }
    }

    private func performSignIn(retryCount: Int, completion: @escaping (Bool) -> Void) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            print("Failed to get root view controller")
            completion(false)
            return
        }
        
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: self.clientID)
        
        print("Starting new Google Sign-In process (Attempt: \(4 - retryCount))")
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: nil, additionalScopes: self.scopes) { signInResult, error in
            if let error = error as NSError? {
                print("Google Sign-In error: \(error.localizedDescription)")
                print("Error domain: \(error.domain)")
                print("Error code: \(error.code)")
                print("Error user info: \(error.userInfo)")
                
                if retryCount > 0 {
                    print("Retrying in 2 seconds...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.performSignIn(retryCount: retryCount - 1, completion: completion)
                    }
                } else {
                    completion(false)
                }
                return
            }
            
            guard let user = signInResult?.user else {
                print("No user signed in")
                completion(false)
                return
            }
            
            print("Successfully signed in user: \(user.userID ?? "Unknown")")
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
    
    private func cleanExpiredTokens() {
        // Remove all Google Sign-In related data from UserDefaults
        let userDefaults = UserDefaults.standard
        userDefaults.dictionaryRepresentation().keys.forEach { key in
            if key.lowercased().contains("google") || key.lowercased().contains("gid") {
                userDefaults.removeObject(forKey: key)
            }
        }
        
        // Clear all cookies
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        
        // Clear all website data
        if #available(iOS 9.0, *) {
            let dataTypes = Set([WKWebsiteDataTypeLocalStorage,
                                 WKWebsiteDataTypeSessionStorage,
                                 WKWebsiteDataTypeMemoryCache,
                                 WKWebsiteDataTypeDiskCache])
            let date = Date(timeIntervalSince1970: 0)
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: date, completionHandler: {})
        }
        
        // Clear keychain items
        let secItemClasses = [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity]
        for itemClass in secItemClasses {
            let spec: NSDictionary = [kSecClass: itemClass]
            SecItemDelete(spec)
        }
        
        print("Thoroughly cleaned all tokens and authentication data")
    }
    
    private func setupYouTubeService(user: GIDGoogleUser) {
        let service = GTLRYouTubeService()
        service.authorizer = user.fetcherAuthorizer
        self.service = service
        
        DispatchQueue.main.async {
            self.isAuthorized = true
        }
    }
    
    private func refreshToken(completion: @escaping (Bool) -> Void) {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error restoring previous sign-in: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            if let user = user {
                user.refreshTokensIfNeeded { user, error in
                    if let error = error {
                        print("Error refreshing tokens: \(error.localizedDescription)")
                        completion(false)
                        return
                    }
                    
                    if let user = user {
                        self.setupYouTubeService(user: user)
                        completion(true)
                    } else {
                        print("No user after token refresh")
                        completion(false)
                    }
                }
            } else {
                print("No previous sign-in to restore")
                completion(false)
            }
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
        
        service.executeQuery(query) { [weak self] (ticket, result, error) in
            guard let self = self else { return }
            
            if let error = error as? GTLRErrorObject, error.code == 401 {
                // Token might be expired, try to refresh
                self.refreshToken { success in
                    if success {
                        // Retry the request with the new token
                        self.fetchUserPlaylists(completion: completion)
                    } else {
                        completion(.failure(NSError(domain: "YouTubeMusicError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh token"])))
                    }
                }
                return
            }
            
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
