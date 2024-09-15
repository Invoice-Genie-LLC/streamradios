//
//  PodcastAppTests.swift
//  PodcastAppTests
//
//  Created by Kley Sulo on 9/14/24.
//

import XCTest
@testable import StreamRadios

import XCTest
@testable import StreamRadios

class PodcastEpisodeCheckTests: XCTestCase {
    var viewModel: PodcastViewModel!
    var mockFeed: PodcastFeed!
    var mockNotificationCenter: MockNotificationCenter!

    override func setUp() {
        super.setUp()
        mockNotificationCenter = MockNotificationCenter()
        viewModel = PodcastViewModel(context: CoreDataStack.shared.context, notificationCenter: mockNotificationCenter)
        mockFeed = PodcastFeed(id: "test_feed", title: "Test Feed", url: "https://example.com/feed")
    }

    func testSendNotification() {
        print("Test: Starting testSendNotification")
        
        let newEpisodes = [
            PodcastEpisode(id: "new_episode", title: "New Episode", descriptionText: "Test", audioUrl: "https://example.com/audio", publicationDate: Date(), duration: 1800, state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0, isDownloaded: false), feedId: "test_feed")
        ]
        
        print("Test: Sending notification")
        viewModel.sendNotification(for: mockFeed, newEpisodes: newEpisodes)
        
        print("Test: Checking for notifications")
        print("Test: Number of added requests: \(self.mockNotificationCenter.addedRequests.count)")
        
        if let request = self.mockNotificationCenter.addedRequests.first {
            print("Test: Notification title: \(request.content.title)")
            print("Test: Notification body: \(request.content.body)")
        } else {
            print("Test: No notifications found")
        }
        
        XCTAssertEqual(self.mockNotificationCenter.addedRequests.count, 1, "Expected 1 notification, but found \(self.mockNotificationCenter.addedRequests.count)")
        XCTAssertEqual(self.mockNotificationCenter.addedRequests.first?.content.title, "New Episodes Available", "Unexpected notification title")
        XCTAssertEqual(self.mockNotificationCenter.addedRequests.first?.content.body, "1 new episode(s) available for Test Feed", "Unexpected notification body")
        
        print("Test: Finished testSendNotification")
    }
}
