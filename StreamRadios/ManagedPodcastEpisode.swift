//
//  ManagedPodcastEpisode.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/13/24.
//

import CoreData

@objc(ManagedPodcastEpisode)
public class ManagedPodcastEpisode: NSManagedObject {
}

extension ManagedPodcastEpisode {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ManagedPodcastEpisode> {
        return NSFetchRequest<ManagedPodcastEpisode>(entityName: "PodcastModel")
    }

    @NSManaged public var id: String
    @NSManaged public var title: String
    @NSManaged public var descriptionText: String
    @NSManaged public var audioUrl: String
    @NSManaged public var publicationDate: Date
    @NSManaged public var duration: Double
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isDownloaded: Bool
    @NSManaged public var progress: Double
    @NSManaged public var feedId: String
    
    func toPodcastEpisode() -> PodcastEpisode {
        // Create a basic PodcastFeed with the feedId.
        // You can customize this further depending on your data structure.
        let feed = PodcastFeed(id: self.feedId, title: "", url: "")

        return PodcastEpisode(
            id: self.id,
            title: self.title,
            description: self.descriptionText,
            audioUrl: self.audioUrl,
            publicationDate: self.publicationDate,
            duration: self.duration,
            state: EpisodeState(
                isPlayed: self.isDownloaded,
                isFavorite: self.isFavorite,
                progress: self.progress,
                isDownloaded: self.isDownloaded
            ),
            feedId: self.feedId
        )
    }
}


