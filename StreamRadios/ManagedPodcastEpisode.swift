//
//  ManagedPodcastEpisode.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/13/24.
//

import CoreData

extension FeedModel {

    func update(from feed: PodcastFeed) {
        id = feed.id
        title = feed.title
        url = feed.url
        artworkUrl = feed.artworkUrl
        descriptionText = feed.description
        iconData = feed.iconData
    }
    
    func toPodcastFeed() -> PodcastFeed {
        return PodcastFeed(id: id ?? UUID().uuidString,
                           title: title ?? "",
                           url: url ?? "",
                           artworkUrl: artworkUrl,
                           description: descriptionText,
                           iconData: iconData)
    }
}

extension PodcastModel {
    func update(from episode: PodcastEpisode) {
        self.id = episode.id
        self.title = episode.title
        self.descriptionText = episode.description
        self.audioUrl = episode.audioUrl
        self.publicationDate = episode.publicationDate
        self.duration = episode.duration
        self.isFavorite = episode.state.isFavorite
        self.isDownloaded = episode.state.isDownloaded
        self.progress = episode.state.progress
        self.feedId = episode.feedId
        self.localFilePath = episode.localFilePath
        self.fileSize = episode.fileSize ?? 0 // Add this line to include fileSize
    }
    
    func toPodcastEpisode() -> PodcastEpisode {
        return PodcastEpisode(
            id: id ?? UUID().uuidString,
            title: title ?? "",
            description: descriptionText ?? "",
            audioUrl: audioUrl ?? "",
            publicationDate: publicationDate ?? Date(),
            duration: duration,
            state: EpisodeState(
                isPlayed: progress == 1.0,
                isFavorite: isFavorite,
                progress: progress,
                isDownloaded: isDownloaded
            ),
            feedId: feedId ?? "",
            localFilePath: localFilePath,
            fileSize: fileSize // Add this line to include fileSize in the conversion
        )
    }
}
