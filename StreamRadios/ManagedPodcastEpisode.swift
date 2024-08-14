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
    // Remove redeclarations of fetchRequest(), id, title, etc.

    func update(from episode: PodcastEpisode) {
        id = episode.id
        title = episode.title
        descriptionText = episode.description
        audioUrl = episode.audioUrl
        publicationDate = episode.publicationDate
        duration = episode.duration
        isFavorite = episode.state.isFavorite
        isDownloaded = episode.state.isDownloaded
        progress = episode.state.progress
        feedId = episode.feedId
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
            feedId: feedId ?? ""
        )
    }
}
