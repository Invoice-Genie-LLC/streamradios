//
//  PodcastNotificationNavigationTests.swift
//  PodcastAppTests
//
//  Created by Kley Sulo on 9/14/24.
//

import XCTest
import SwiftUI
import UserNotifications
@testable import StreamRadios

// Step 1: Create a mock version of PodcastPlayerView for testing
struct MockPodcastEpisodeListView: View {
    var feedId: String

    var body: some View {
        Text("Mock Podcast Episode List for feedId: \(feedId)")
            .accessibility(identifier: "MockPodcastEpisodeListView")
    }
}

// Step 2: Create a subclass of AppDelegate for testing
class TestAppDelegate: AppDelegate {
    override func handlePodcastNotification(feedId: String) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {

            let mockView = MockPodcastEpisodeListView(feedId: feedId)
            let hostingController = UIHostingController(rootView: mockView)
            rootViewController.present(hostingController, animated: true, completion: nil)
        }
    }
}

// Step 3: Create a mock UNNotificationResponse without subclassing
class MockUNNotificationContent: UNNotificationContent {
    init(title: String, body: String, userInfo: [AnyHashable: Any] = [:]) {
        super.init()
        self.setValue(title, forKey: "title")
        self.setValue(body, forKey: "body")
        self.setValue(userInfo, forKey: "userInfo")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class MockUNNotificationRequest: UNNotificationRequest {
    init(identifier: String, content: UNNotificationContent) {
        super.init()
        self.setValue(identifier, forKey: "identifier")
        self.setValue(content, forKey: "content")
    }
}

class MockUNNotification: UNNotification {
    private let mockRequest: UNNotificationRequest

    init(request: UNNotificationRequest) {
        self.mockRequest = request
        super.init()
        self.setValue(request, forKey: "request")
    }
}

class MockUNNotificationResponse: UNNotificationResponse {
    private let mockRequest: UNNotificationRequest

    init(request: UNNotificationRequest) {
        self.mockRequest = request
        super.init()
        self.setValue(MockUNNotification(request: request), forKey: "notification")
        self.setValue(UNNotificationDefaultActionIdentifier, forKey: "actionIdentifier")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Mock Notification Handler
class MockNotificationHandler {
    static func createMockResponse(for request: UNNotificationRequest) -> UNNotificationResponse {
        return MockUNNotificationResponse(request: request)
    }
}

// Step 4: Define the test case for the notification navigation
class PodcastNotificationNavigationTests: XCTestCase {
    var appDelegate: TestAppDelegate!
    var window: UIWindow!
    var mockNotificationCenter: MockNotificationCenter!

    override func setUp() {
        super.setUp()
        appDelegate = TestAppDelegate()
        mockNotificationCenter = MockNotificationCenter()

        // Set up the window
        window = UIWindow(frame: UIScreen.main.bounds)
        appDelegate.window = window
        appDelegate.window?.rootViewController = UIViewController()
        appDelegate.window?.makeKeyAndVisible()
    }

    func testPodcastNotificationNavigation() {
        // Arrange
        let feedId = "test_feed_id"
        let expectation = self.expectation(description: "MockPodcastEpisodeListView should be presented")

        // Step 5: Simulate the notification being delivered
        let newEpisodes = [
            PodcastEpisode(id: "new_episode", title: "New Episode", descriptionText: "Test", audioUrl: "https://example.com/audio", publicationDate: Date(), duration: 1800, state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0, isDownloaded: false), feedId: feedId)
        ]
        
        appDelegate.podcastViewModel.notificationCenter = mockNotificationCenter
        appDelegate.podcastViewModel.sendNotification(for: PodcastFeed(id: feedId, title: "Test Feed", url: "https://example.com/feed"), newEpisodes: newEpisodes)
        
        // Step 6: Simulate the user clicking the notification
        if let request = mockNotificationCenter.addedRequests.first {
            let mockResponse = MockNotificationHandler.createMockResponse(for: request)
            appDelegate.userNotificationCenter(
                UNUserNotificationCenter.current(),
                didReceive: mockResponse,
                withCompletionHandler: {}
            )
        }

        // Validate the behavior
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let presentedVC = self.appDelegate.window?.rootViewController?.presentedViewController as? UIHostingController<MockPodcastEpisodeListView> {
                XCTAssertEqual(presentedVC.rootView.feedId, feedId)
                expectation.fulfill()
            } else {
                XCTFail("MockPodcastEpisodeListView was not presented")
            }
        }
        
        waitForExpectations(timeout: 10, handler: nil)
    }
}

// Mock implementation of NotificationCenterProtocol
class MockNotificationCenter: NotificationCenterProtocol {
    var addedRequests: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        completionHandler(addedRequests)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        addedRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func removeAllPendingNotificationRequests() {
        addedRequests.removeAll()
    }

    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {
        // This is where you'd simulate delivered notifications if needed
        completionHandler([])
    }

    func removeAllDeliveredNotifications() {
        // Handle removal simulation if needed
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        // Handle removal simulation if needed
    }
}

