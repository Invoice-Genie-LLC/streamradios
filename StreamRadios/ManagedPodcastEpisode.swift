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
            descriptionText = feed.descriptionText
            iconData = feed.iconData
        }
        
        func toPodcastFeed() -> PodcastFeed {
            return PodcastFeed(
                id: id ?? UUID().uuidString,
                title: title ?? "",
                url: url ?? "",
                artworkUrl: artworkUrl,
                description: descriptionText,
                iconData: iconData
            )
        }
}

extension PodcastModel {
    func update(from episode: PodcastEpisode) {
        id = episode.id
        title = episode.title
        descriptionText = episode.descriptionText
        audioUrl = episode.audioUrl
        publicationDate = episode.publicationDate
        duration = episode.duration
        feedId = episode.feedId
        localFilePath = episode.localFilePath
        fileSize = episode.fileSize ?? 0
        isDownloaded = episode.state.isDownloaded
        isFavorite = episode.state.isFavorite
        progress = episode.state.progress
        isPlayed = episode.state.isPlayed  // Make sure this line is present
    }

    func toPodcastEpisode() -> PodcastEpisode {
        return PodcastEpisode(
            id: id ?? UUID().uuidString,
            title: title ?? "",
            descriptionText: descriptionText ?? "",
            audioUrl: audioUrl ?? "",
            publicationDate: publicationDate ?? Date(),
            duration: duration,
            state: EpisodeState(
                isPlayed: isPlayed,  // Make sure this line is present
                isFavorite: isFavorite,
                progress: progress,
                isDownloaded: isDownloaded
            ),
            feedId: feedId ?? "",
            localFilePath: localFilePath,
            fileSize: fileSize
        )
    }
}
