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
           self.id = episode.id
           self.title = episode.title
           self.descriptionText = episode.descriptionText
           self.audioUrl = episode.audioUrl
           self.publicationDate = episode.publicationDate
           self.duration = episode.duration
           self.isPlayed = episode.state.isPlayed
           self.isFavorite = episode.state.isFavorite
           self.progress = episode.state.progress
           self.isDownloaded = episode.state.isDownloaded
           self.feedId = episode.feedId
           self.localFilePath = episode.localFilePath
           self.fileSize = episode.fileSize ?? 0
       }
    
    func toPodcastEpisode() -> PodcastEpisode {
            let episodeId = self.id ?? UUID().uuidString
            
            // Use EpisodeStateManager as source of truth for episode states
            let progress = EpisodeStateManager.shared.getProgress(for: episodeId)
            let isFavorite = EpisodeStateManager.shared.isFavorite(episodeId)
            var isDownloaded = EpisodeStateManager.shared.isDownloaded(episodeId)
            let isPlayed = progress >= 0.99
            
            // CRITICAL FIX: Verify download state against actual file existence
            // If we have a local file path, check if the file actually exists
            if let localPath = self.localFilePath, !localPath.isEmpty {
                let fileExists = FileManager.default.fileExists(atPath: localPath)
                print("🔍 DEBUG: Converting episode '\(self.title ?? "Unknown")' - localFilePath: \(localPath)")
                print("🔍 DEBUG: File exists at path: \(fileExists)")
                
                if fileExists && !isDownloaded {
                    // File exists but EpisodeStateManager says it's not downloaded - sync the state
                    isDownloaded = true
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: true)
                    print("✅ SYNC: Updated EpisodeStateManager - episode \(episodeId) marked as downloaded")
                } else if !fileExists && isDownloaded {
                    // EpisodeStateManager says it's downloaded but file doesn't exist - fix the state
                    isDownloaded = false
                    EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                    print("🔧 SYNC: Updated EpisodeStateManager - episode \(episodeId) marked as not downloaded (file missing)")
                }
            } else if isDownloaded {
                // No local file path but EpisodeStateManager says it's downloaded - fix the state
                isDownloaded = false
                EpisodeStateManager.shared.setDownloaded(episodeId, isDownloaded: false)
                print("🔧 SYNC: Updated EpisodeStateManager - episode \(episodeId) marked as not downloaded (no local path)")
            }
            
            return PodcastEpisode(
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
                localFilePath: self.localFilePath,
                fileSize: self.fileSize
            )
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


