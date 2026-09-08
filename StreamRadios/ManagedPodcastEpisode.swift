//
//  ManagedPodcastEpisode.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/13/24.
//

import Foundation
import CoreData

extension FeedModel {
    func update(from feed: PodcastFeed) {
        self.id = feed.id
        self.title = feed.title
        self.url = feed.url
        self.artworkUrl = feed.artworkUrl
        self.descriptionText = feed.descriptionText
        self.iconData = feed.iconData
        self.imageData = feed.imageData
    }
    
    func toPodcastFeed() -> PodcastFeed {
           return PodcastFeed(
               id: self.id ?? UUID().uuidString,
               title: self.title ?? "",
               url: self.url ?? "",
               artworkUrl: self.artworkUrl,
               description: self.descriptionText,
               iconData: self.iconData,
               imageData: self.imageData
           )
       }
}

extension PodcastModel {
    func update(from episode: PodcastEpisode) {
           self.isPlayed = episode.state.isPlayed
           self.isFavorite = episode.state.isFavorite
           self.progress = episode.state.progress
           self.isDownloaded = episode.state.isDownloaded
           self.localFilePath = episode.localFilePath
           self.fileSize = episode.fileSize ?? 0
           updateMetadata(from: episode)
       }
    
    /// Writes only the fields the RSS feed owns, never the user's playback state.
    /// Refreshing a feed must not touch progress/isFavorite/isPlayed/isDownloaded.
    func updateMetadata(from episode: PodcastEpisode) {
           self.id = episode.id
           self.title = episode.title
           self.descriptionText = episode.descriptionText
           self.audioUrl = episode.audioUrl
           self.publicationDate = episode.publicationDate
           self.duration = episode.duration
           self.feedId = episode.feedId
           
           // Store chapters and notes as JSON in Core Data
           if let chapters = episode.chapters {
               do {
                   let chaptersData = try JSONEncoder().encode(chapters)
                   self.chaptersData = chaptersData
               } catch {
                   print("❌ Failed to encode chapters: \(error)")
                   self.chaptersData = nil
               }
           } else {
               self.chaptersData = nil
           }
           
           if let notes = episode.notes {
               do {
                   let notesData = try JSONEncoder().encode(notes)
                   self.notesData = notesData
               } catch {
                   print("❌ Failed to encode notes: \(error)")
                   self.notesData = nil
               }
           } else {
               self.notesData = nil
           }
       }
    
    func toPodcastEpisode() -> PodcastEpisode {
            let episodeId = self.id ?? UUID().uuidString
            let episodeFeedId = self.feedId
            
                    // FIX: Use EpisodeStateManager as source of truth for ALL episode states
        // This ensures favorite/download states don't get reset during playback or screen changes
        let episodeStateProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: episodeFeedId)
        let episodeState = EpisodeStateManager.shared.getState(for: episodeId, feedId: episodeFeedId)
        let episodeStateIsPlayed = episodeState == .played
        // Use the higher progress value and trust EpisodeStateManager for played status
        let progress = max(Double(self.progress), episodeStateProgress)
        
        // SAFE STATE RESOLUTION: Combine EpisodeStateManager and Core Data with OR logic
        // This prevents data loss during state transitions (upgrades, background/foreground, etc.)
        let episodeStateManagerFavorite = EpisodeStateManager.shared.isFavorite(episodeId, feedId: episodeFeedId)
        let episodeStateManagerDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId, feedId: episodeFeedId)
        
        // If EITHER source says favorited/downloaded, trust it
        // Core Data is now protected from RSS overwrites (see update method above)
        let isFavorite = episodeStateManagerFavorite || self.isFavorite
        var isDownloaded = episodeStateManagerDownloaded || self.isDownloaded
        
        let isPlayed = episodeStateIsPlayed || self.isPlayed || progress >= 1.0
            
            // PERFORMANCE: Only log critical download/path issues, not every episode
            #if DEBUG
            if isDownloaded && self.localFilePath == nil {
                print("⚠️ CONVERT: Downloaded episode missing path: '\(self.title ?? "Unknown")'")
            }
            #endif
            
            // ROBUST PATH RESOLUTION: Handle iOS sandbox changes
            var resolvedLocalFilePath: String? = self.localFilePath
            
            // UPGRADE PROTECTION: Enhanced sync logic to prevent download state loss
            // During CloudKit sync, trust the EpisodeStateManager download status
            if let localPath = self.localFilePath, !localPath.isEmpty {
                let fileExists = FileManager.default.fileExists(atPath: localPath)
                // Only log if file is missing (potential issue)
                if !fileExists {
                    print("🔍 CONVERT: File missing at '\(localPath)' for episode '\(self.title ?? "Unknown")'")
                }
                
                if !fileExists {
                    // File doesn't exist at stored path - try to recover it
                    print("🔧 PATH RECOVERY: Attempting to recover file for episode: \(self.title ?? "Unknown")")
                    if let recoveredPath = Self.recoverDownloadedFilePath(for: episodeId, originalPath: localPath) {
                        print("✅ PATH RECOVERY: Successfully recovered file at: \(recoveredPath)")
                        resolvedLocalFilePath = recoveredPath
                        
                        // Update Core Data with corrected path
                        self.localFilePath = recoveredPath
                        try? self.managedObjectContext?.save()
                    } else {
                        print("❌ PATH RECOVERY: Could not recover file for episode: \(self.title ?? "Unknown")")
                        resolvedLocalFilePath = nil
                    }
                } else {
                    resolvedLocalFilePath = localPath
                }
                
                // Update download state based on file existence
                let finalFileExists = resolvedLocalFilePath != nil && FileManager.default.fileExists(atPath: resolvedLocalFilePath!)
                
                if finalFileExists && !isDownloaded {
                    // File exists but EpisodeStateManager says it's not downloaded - sync the state
                    isDownloaded = true
                    EpisodeStateManager.shared.setDownloadedWithProtection(episodeId, isDownloaded: true, feedId: feedId, reason: "file_found_sync")
                    print("✅ SYNC: Updated EpisodeStateManager - episode \(episodeId) marked as downloaded (file found)")
                } else if !finalFileExists && isDownloaded {
                    isDownloaded = false
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false, feedId: feedId)
                    EpisodeStateManager.shared.clearEpisodeBackup(episodeId)  // Clear backup to prevent recovery
                    print("🧹 CLEANUP: Episode \(episodeId) marked as not downloaded (file missing)")
                    
                    // CRITICAL: Sync the download state change to CloudKit
                    if let feedId = self.feedId, !feedId.isEmpty {
                        Task.detached(priority: .utility) {
                            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId, feedId: feedId)
                            let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId, feedId: feedId)
                            await PodcastCloudKitManager.shared.saveEpisodeState(
                                episodeId: episodeId,
                                feedId: feedId,
                                progress: currentProgress,
                                isFavorite: currentFavorite,
                                isDownloaded: false,
                                isPlayed: currentProgress >= 0.99
                            )
                            print("☁️ Synced download state cleanup to CloudKit: \(episodeId)")
                        }
                    }
                }
                // NOTE: Removed aggressive file clearing - let background sync handle missing files
                // This preserves download status during CloudKit sync and app upgrades
            } else if isDownloaded {
                // No local path but EpisodeStateManager says it's downloaded
                // Only log significant download state issues
                if isDownloaded {
                    print("🔍 CONVERT: No path but marked as downloaded - '\(self.title ?? "Unknown")'")
                }
                
                // Try to recover file without a stored path
                if let recoveredPath = Self.recoverDownloadedFilePath(for: episodeId, originalPath: nil) {
                    print("✅ PATH RECOVERY: Found file without stored path at: \(recoveredPath)")
                    resolvedLocalFilePath = recoveredPath
                    
                    // Update Core Data with discovered path
                    self.localFilePath = recoveredPath
                    try? self.managedObjectContext?.save()
                } else {
                    isDownloaded = false
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                    EpisodeStateManager.shared.clearEpisodeBackup(episodeId)  // Clear backup to prevent recovery
                    print("🧹 CLEANUP: Episode \(episodeId) marked as not downloaded (no file path)")
                    
                    // CRITICAL: Sync the download state change to CloudKit
                    if let feedId = self.feedId, !feedId.isEmpty {
                        Task.detached(priority: .utility) {
                            let currentProgress = EpisodeStateManager.shared.getProgress(for: episodeId)
                            let currentFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
                            await PodcastCloudKitManager.shared.saveEpisodeState(
                                episodeId: episodeId,
                                feedId: feedId,
                                progress: currentProgress,
                                isFavorite: currentFavorite,
                                isDownloaded: false,
                                isPlayed: currentProgress >= 0.99
                            )
                            print("☁️ Synced download state cleanup to CloudKit: \(episodeId)")
                        }
                    }
                }
            }
            
            // Decode chapters and notes from stored JSON data in Core Data
            var chapters: [PodcastChapter]? = nil
            var notes: PodcastNotes? = nil
            
            if let chaptersData = self.chaptersData {
                do {
                    chapters = try JSONDecoder().decode([PodcastChapter].self, from: chaptersData)
                } catch {
                    print("❌ Failed to decode chapters: \(error)")
                }
            }
            
            if let notesData = self.notesData {
                do {
                    notes = try JSONDecoder().decode(PodcastNotes.self, from: notesData)
                } catch {
                    print("❌ Failed to decode notes: \(error)")
                }
            }
            
            let finalEpisode = PodcastEpisode(
                id: episodeId,
                title: self.title ?? "",
                descriptionText: self.descriptionText ?? "",
                audioUrl: self.audioUrl ?? "",
                publicationDate: self.publicationDate ?? Date(),
                duration: self.duration,
                state: EpisodeState(
                    isPlayed: isPlayed,
                    isFavorite: isFavorite,
                    progress: progress,
                    isDownloaded: isDownloaded
                ),
                feedId: self.feedId ?? "",
                localFilePath: resolvedLocalFilePath,
                fileSize: self.fileSize,
                chapters: chapters,
                notes: notes
            )
            
            // PERFORMANCE: Minimal logging for critical issues only
            #if DEBUG
            if finalEpisode.state.isDownloaded && finalEpisode.localFilePath == nil {
                print("⚠️ CONVERT: Downloaded episode without file path: '\(finalEpisode.title)'")
            }
            #endif
            
            return finalEpisode
        }
    
    /// Attempts to recover a downloaded file when the stored path is invalid (iOS sandbox changes)
    static func recoverDownloadedFilePath(for episodeId: String, originalPath: String?) -> String? {
        print("🔧 FILE RECOVERY: Starting recovery for episode ID: \(episodeId)")
        
        // Get current Documents directory (sandbox may have changed)
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ FILE RECOVERY: Could not get Documents directory")
            return nil
        }
        
        let episodesFolder = documentsPath.appendingPathComponent("DownloadedEpisodes")
        
        // Check if DownloadedEpisodes folder exists
        guard FileManager.default.fileExists(atPath: episodesFolder.path) else {
            print("❌ FILE RECOVERY: DownloadedEpisodes folder doesn't exist")
            return nil
        }
        
        // Strategy 1: If we have an original path, extract the filename and look for it
        if let originalPath = originalPath {
            let originalURL = URL(fileURLWithPath: originalPath)
            let fileName = originalURL.lastPathComponent
            let recoveredURL = episodesFolder.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: recoveredURL.path) {
                print("✅ FILE RECOVERY: Found file using original filename: \(fileName)")
                return recoveredURL.path
            }
        }
        
        // Strategy 2: Look for files based on sanitized episode ID
        let sanitizedId = sanitizeFilename(episodeId)
        let commonExtensions = ["mp3", "m4a", "wav", "aac"]
        
        for ext in commonExtensions {
            let fileName = "\(sanitizedId).\(ext)"
            let fileURL = episodesFolder.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                print("✅ FILE RECOVERY: Found file using sanitized ID: \(fileName)")
                return fileURL.path
            }
        }
        
        // Strategy 3: Search all files in DownloadedEpisodes folder for matches
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: episodesFolder, includingPropertiesForKeys: nil)
            
            // Look for files that contain the episode ID or sanitized ID
            for fileURL in fileURLs {
                let fileName = fileURL.lastPathComponent
                if fileName.contains(episodeId) || fileName.contains(sanitizedId) {
                    print("✅ FILE RECOVERY: Found file using content search: \(fileName)")
                    return fileURL.path
                }
            }
            
        } catch {
            print("❌ FILE RECOVERY: Error scanning DownloadedEpisodes folder: \(error)")
        }
        
        print("❌ FILE RECOVERY: Could not recover file for episode ID: \(episodeId)")
        return nil
    }
    
    /// Sanitize filename by removing invalid characters (helper method)
    private static func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "_")
        
        let maxLength = 100
        if sanitized.count > maxLength {
            let startIndex = sanitized.startIndex
            let endIndex = sanitized.index(startIndex, offsetBy: maxLength)
            return String(sanitized[startIndex..<endIndex])
        }
        
        return sanitized
    }
}

extension FeedModel {
    @objc(addEpisodesObject:)
    @NSManaged public func addToEpisodes(_ value: PodcastModel)

    @objc(removeEpisodesObject:)
    @NSManaged public func removeFromEpisodes(_ value: PodcastModel)

    @objc(addEpisodes:)
    @NSManaged public func addToEpisodes(_ values: NSSet)

    @objc(removeEpisodes:)
    @NSManaged public func removeFromEpisodes(_ values: NSSet)
}


