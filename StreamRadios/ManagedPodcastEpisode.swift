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
            return PodcastEpisode(
                id: self.id ?? UUID().uuidString,
                title: self.title ?? "",
                descriptionText: self.descriptionText ?? "",
                audioUrl: self.audioUrl ?? "",
                publicationDate: self.publicationDate ?? Date(),
                duration: self.duration,
                state: EpisodeState(
                    isPlayed: self.isPlayed,
                    isFavorite: self.isFavorite,
                    progress: self.progress,
                    isDownloaded: self.isDownloaded
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


