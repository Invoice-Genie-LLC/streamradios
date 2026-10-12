import Foundation
import Observation
import StreamRadiosCore
import CryptoKit
import WatchKit
import WatchConnectivity

@MainActor
@Observable
final class WatchEpisodeDownloads {
    static let shared = WatchEpisodeDownloads()
    private struct Entry: Codable {
        let fileName: String
        let bytes: Int64
        let savedAt: Date
    }
    private let budget: Int64 = 256 * 1_024 * 1_024
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamRadios/Audio", isDirectory: true)
    private var entries: [String: Entry] = [:]
    private(set) var downloadingURL: String?
    private(set) var errorMessage: String?
    var protectedURL: String?
    var playbackIsActive = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchCandidates: [SRPodcastEpisodeRecord] = []

    private init() {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
        }
        let retained = Set(entries.values.map(\.fileName)).union(["index.json"])
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where !retained.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func localURL(for episode: SRPodcastEpisodeRecord) -> URL? {
        guard let entry = entries[episode.audioURL] else { return nil }
        let location = directory.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    func remove(_ episode: SRPodcastEpisodeRecord) {
        guard protectedURL != episode.audioURL, let entry = entries[episode.audioURL] else { return }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            entries[episode.audioURL] = nil
            try persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func cancel() {
        prefetchCandidates = []
        task?.cancel()
    }

    func prefetch(_ episodes: [SRPodcastEpisodeRecord]) {
        guard UserDefaults.standard.bool(forKey: "watchAutoDownload"), downloadingURL == nil, !playbackIsActive else { return }
        prefetchCandidates = Array(episodes.prefix(3))
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        guard device.batteryState == .charging || device.batteryState == .full,
              let episode = episodes.prefix(3).first(where: { localURL(for: $0) == nil }) else { return }
        download(episode)
    }

    func download(_ episode: SRPodcastEpisodeRecord) {
        guard !playbackIsActive, downloadingURL == nil, localURL(for: episode) == nil,
              let url = URL(string: episode.audioURL) else { return }
        downloadingURL = episode.audioURL
        errorMessage = nil
        task = Task {
            var completed = false
            defer {
                downloadingURL = nil
                task = nil
                if completed { prefetch(prefetchCandidates) }
            }
            let configuration = URLSessionConfiguration.default
            configuration.allowsCellularAccess = false
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            configuration.timeoutIntervalForResource = 1_800
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (temporaryURL, response) = try await session.download(from: url, delegate: DownloadLimit(limit: budget))
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                guard response.mimeType?.contains("mpegurl") != true,
                      response.mimeType?.contains("text/html") != true else {
                    throw URLError(.cannotDecodeContentData)
                }
                let bytes = (try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0, bytes <= budget else { throw URLError(.dataLengthExceedsMaximum) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var cacheDirectory = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try cacheDirectory.setResourceValues(values)
                var used = entries.values.reduce(Int64(0)) { $0 + $1.bytes }
                for (key, entry) in entries.sorted(by: { $0.value.savedAt < $1.value.savedAt }) where used + bytes > budget {
                    guard key != protectedURL else { continue }
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
                    entries[key] = nil
                    used -= entry.bytes
                }
                guard used + bytes <= budget else { throw URLError(.cannotCreateFile) }
                let digest = SHA256.hash(data: Data(episode.audioURL.utf8)).map { String(format: "%02x", $0) }.joined()
                let suffix = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
                let fileName = "\(digest).\(suffix)"
                let destination = directory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                entries[episode.audioURL] = Entry(fileName: fileName, bytes: bytes, savedAt: .now)
                try persist()
                completed = true
            } catch {
                try? persist()
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}

private final class DownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}

@MainActor
@Observable
final class WatchPodcastLibrary {
    nonisolated static let episodeLimit = 20
    private(set) var episodesByFeedID: [String: [SRPodcastEpisodeRecord]] = [:]
    private(set) var loadingFeedIDs = Set<String>()
    private(set) var errorsByFeedID: [String: String] = [:]

    func isLoading(_ feed: SRPodcastFeedRecord) -> Bool {
        loadingFeedIDs.contains(feed.id)
    }

    func errorMessage(for feed: SRPodcastFeedRecord) -> String? {
        errorsByFeedID[feed.id]
    }

    func episodes(for feed: SRPodcastFeedRecord) -> [SRPodcastEpisodeRecord] {
        episodesByFeedID[feed.id] ?? []
    }

    func installSeedEpisodes(_ episodes: [SRPodcastEpisodeRecord]) {
        for (feedID, records) in Dictionary(grouping: episodes, by: \.feedID) {
            episodesByFeedID[feedID] = Self.merged(
                preferred: records,
                fallback: episodesByFeedID[feedID] ?? []
            )
        }
    }

    nonisolated static func seedEpisodes(_ episodes: [SRPodcastEpisodeRecord]) async {
        let episodesByFeed = Dictionary(grouping: episodes, by: \.feedID)
        for (feedID, records) in episodesByFeed {
            let cachedRecords = await cachedEpisodes(for: feedID) ?? []
            await cache(merged(preferred: records, fallback: cachedRecords), for: feedID)
        }
    }

    func prefetch(_ feeds: [SRPodcastFeedRecord], limit: Int = 3) async {
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds.prefix(limit) where episodesByFeedID[feed.id] == nil {
                group.addTask { [weak self] in
                    await self?.loadEpisodes(for: feed)
                }
            }
        }
    }

    func loadEpisodes(for feed: SRPodcastFeedRecord, force: Bool = false) async {
        guard let url = URL(string: feed.feedURL) else {
            errorsByFeedID[feed.id] = "This podcast has an invalid feed URL."
            return
        }

        guard !loadingFeedIDs.contains(feed.id) else { return }
        loadingFeedIDs.insert(feed.id)
        errorsByFeedID[feed.id] = nil
        defer { loadingFeedIDs.remove(feed.id) }

        do {
            if episodesByFeedID[feed.id]?.isEmpty != false,
               let cachedEpisodes = await Self.cachedEpisodes(for: feed.id),
               !cachedEpisodes.isEmpty {
                episodesByFeedID[feed.id] = Self.merged(
                    preferred: episodesByFeedID[feed.id] ?? [],
                    fallback: cachedEpisodes
                )
            }

            let refreshKey = "watchFeedRefresh:\(feed.id)"
            let lastRefresh = UserDefaults.standard.double(forKey: refreshKey)
            if !force, episodesByFeedID[feed.id]?.isEmpty == false,
               Date().timeIntervalSince1970 - lastRefresh < 900 { return }
            if !force, WatchEpisodeDownloads.shared.playbackIsActive,
               episodesByFeedID[feed.id]?.isEmpty == false { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if !force, episodesByFeedID[feed.id]?.isEmpty == false {
                request.setValue(UserDefaults.standard.string(forKey: "\(refreshKey):etag"), forHTTPHeaderField: "If-None-Match")
                request.setValue(UserDefaults.standard.string(forKey: "\(refreshKey):modified"), forHTTPHeaderField: "If-Modified-Since")
            }
            request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue(
                "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
                forHTTPHeaderField: "Accept"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse, response.statusCode == 304 {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshKey)
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw WatchPodcastFeedError.httpStatus(httpResponse.statusCode)
            }

            let feedID = feed.id
            let episodes = try await Task.detached(priority: .userInitiated) {
                try WatchPodcastRSSParser.parse(data: data, feedID: feedID)
            }.value
            let mergedEpisodes = Self.merged(
                preferred: episodes,
                fallback: episodesByFeedID[feed.id] ?? []
            )
            episodesByFeedID[feed.id] = mergedEpisodes
            await Self.cache(mergedEpisodes, for: feed.id)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshKey)
            if let response = response as? HTTPURLResponse {
                UserDefaults.standard.set(response.value(forHTTPHeaderField: "ETag"), forKey: "\(refreshKey):etag")
                UserDefaults.standard.set(response.value(forHTTPHeaderField: "Last-Modified"), forKey: "\(refreshKey):modified")
            }
        } catch {
            if episodesByFeedID[feed.id]?.isEmpty != false,
               let cachedEpisodes = await Self.cachedEpisodes(for: feed.id),
               !cachedEpisodes.isEmpty {
                episodesByFeedID[feed.id] = cachedEpisodes
            }
            if episodesByFeedID[feed.id]?.isEmpty == false {
                errorsByFeedID[feed.id] = nil
            } else {
                errorsByFeedID[feed.id] = error.localizedDescription
            }
        }
    }

    nonisolated private static func cachedEpisodes(
        for feedID: String
    ) async -> [SRPodcastEpisodeRecord]? {
        await Task.detached(priority: .utility) {
            let destination = cacheURL(for: feedID)
            let source = FileManager.default.fileExists(atPath: destination.path)
                ? destination
                : legacyCacheURL(for: feedID)
            guard let data = try? Data(contentsOf: source),
                  let decoded = try? JSONDecoder().decode([SRPodcastEpisodeRecord].self, from: data) else { return nil }
            let limited = merged(preferred: [], fallback: decoded)
            if source != destination || limited != decoded {
                try? FileManager.default.createDirectory(
                    at: cacheDirectoryURL,
                    withIntermediateDirectories: true
                )
                if let trimmedData = try? JSONEncoder().encode(limited) {
                    try? trimmedData.write(to: destination, options: .atomic)
                }
            }
            return limited
        }.value
    }

    nonisolated private static func cache(
        _ episodes: [SRPodcastEpisodeRecord],
        for feedID: String
    ) async {
        await Task.detached(priority: .utility) {
            let limited = merged(preferred: [], fallback: episodes)
            guard let data = try? JSONEncoder().encode(limited) else { return }
            try? FileManager.default.createDirectory(
                at: cacheDirectoryURL,
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL(for: feedID), options: .atomic)
        }.value
    }

    nonisolated private static var cacheDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamRadios/Podcasts", isDirectory: true)
    }

    nonisolated private static func cacheURL(for feedID: String) -> URL {
        cacheDirectoryURL.appendingPathComponent("watch-podcast-v2-\(cacheFileName(for: feedID)).json")
    }

    nonisolated private static func legacyCacheURL(for feedID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-podcast-v2-\(cacheFileName(for: feedID)).json")
    }

    nonisolated private static func cacheFileName(for feedID: String) -> String {
        let fileName = Data(feedID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return fileName
    }

    static func loadChapters(from url: URL) async throws -> [SRPodcastChapterRecord] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw WatchPodcastFeedError.httpStatus(response.statusCode)
        }
        let decoder = JSONDecoder()
        let items: [ChapterItem]
        if let document = try? decoder.decode(ChapterDocument.self, from: data) {
            items = document.chapters
        } else {
            items = try decoder.decode([ChapterItem].self, from: data)
        }
        return items.compactMap(\.record).sorted { $0.startTime < $1.startTime }
    }

    nonisolated static func loadID3Chapters(from url: URL) async throws -> [SRPodcastChapterRecord] {
        try await WatchID3ChapterReader.load(from: url)
    }

    nonisolated static func refreshEpisodeDetails(
        episode: SRPodcastEpisodeRecord,
        feed: SRPodcastFeedRecord
    ) async throws -> SRPodcastEpisodeRecord? {
        guard let url = URL(string: feed.feedURL) else {
            throw WatchPodcastFeedError.invalidFeed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw WatchPodcastFeedError.httpStatus(response.statusCode)
        }
        let records = try await Task.detached(priority: .userInitiated) {
            try WatchPodcastRSSParser.parse(data: data, feedID: feed.id)
        }.value
        return records.first {
            $0.id == episode.id || $0.audioURL == episode.audioURL
        }
    }

    nonisolated private static func merged(
        preferred: [SRPodcastEpisodeRecord],
        fallback: [SRPodcastEpisodeRecord]
    ) -> [SRPodcastEpisodeRecord] {
        var records = fallback
        for preferredRecord in preferred {
            if let index = records.firstIndex(where: {
                $0.id == preferredRecord.id || $0.audioURL == preferredRecord.audioURL
            }) {
                let fallbackRecord = records[index]
                var record = preferredRecord
                if record.descriptionText.isEmpty {
                    record.descriptionText = fallbackRecord.descriptionText
                }
                if record.duration <= 0 { record.duration = fallbackRecord.duration }
                if record.chaptersURL?.isEmpty != false {
                    record.chaptersURL = fallbackRecord.chaptersURL
                }
                if record.chapters?.isEmpty != false {
                    record.chapters = fallbackRecord.chapters
                }
                records[index] = record
            } else {
                records.append(preferredRecord)
            }
        }
        return Array(records.sorted { $0.publicationDate > $1.publicationDate }.prefix(episodeLimit))
    }

    private struct ChapterDocument: Decodable {
        let chapters: [ChapterItem]
    }

    private struct ChapterItem: Decodable {
        let startTime: Double?
        let start: String?
        let title: String?

        var record: SRPodcastChapterRecord? {
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let seconds = startTime ?? Self.parseDuration(start ?? "")
            return SRPodcastChapterRecord(title: title, startTime: max(0, seconds))
        }

        private static func parseDuration(_ value: String) -> TimeInterval {
            let parts = value.split(separator: ":").compactMap { Double($0) }
            switch parts.count {
            case 3: return parts[0] * 3_600 + parts[1] * 60 + parts[2]
            case 2: return parts[0] * 60 + parts[1]
            case 1: return parts[0]
            default: return 0
            }
        }
    }
}

@MainActor
@Observable
final class WatchChapterLoader {
    private static let deliveryNotification = Notification.Name("WatchChapterDelivery")
    @ObservationIgnored private var deliveryObserver: NSObjectProtocol?
    private(set) var key: String?
    private(set) var chapters: [SRPodcastChapterRecord] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var didLoad = false

    static func receive(_ delivery: SRChapterDelivery) async {
        guard !delivery.chapters.isEmpty,
              delivery.chapters.allSatisfy({ $0.startTime.isFinite && $0.startTime >= 0 }) else { return }
        await WatchChapterCache.shared.write(delivery.chapters, key: delivery.request.audioURL)
        NotificationCenter.default.post(name: deliveryNotification, object: delivery)
        print("[WatchChapters] delivered and cached \(delivery.chapters.count) iPhone chapters")
    }

    deinit {
        if let deliveryObserver { NotificationCenter.default.removeObserver(deliveryObserver) }
    }

    func reset() {
        if let deliveryObserver { NotificationCenter.default.removeObserver(deliveryObserver) }
        deliveryObserver = nil
        task?.cancel()
        task = nil
        requestID = UUID()
        key = nil
        chapters = []
        isLoading = false
        errorMessage = nil
        didLoad = false
    }

    func load(
        key: String,
        supplied: [SRPodcastChapterRecord],
        chapterURL: URL?,
        audioURL: URL?,
        phoneRequest: SRChapterRequest? = nil,
        force: Bool = false
    ) {
        if self.key == key, !force, isLoading || didLoad || errorMessage != nil { return }
        reset()
        self.key = key
        chapters = supplied
        if !supplied.isEmpty {
            didLoad = true
            return
        }
        isLoading = true
        let currentRequestID = requestID
        if let phoneRequest {
            deliveryObserver = NotificationCenter.default.addObserver(
                forName: Self.deliveryNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let delivery = notification.object as? SRChapterDelivery,
                      delivery.matches(phoneRequest) else { return }
                Task { @MainActor in
                    guard let self, self.requestID == currentRequestID else { return }
                    self.requestID = UUID()
                    self.task?.cancel()
                    self.task = nil
                    self.chapters = delivery.chapters
                    self.errorMessage = nil
                    self.isLoading = false
                    self.didLoad = true
                }
            }
        }
        task = Task { [weak self] in
            var source = "Watch chapters"
            var phoneStatus = ""
            do {
                let cacheKey = chapterURL?.absoluteString ?? audioURL?.absoluteString ?? key
                if !force, let phoneRequest,
                   let cached = await WatchChapterCache.shared.read(phoneRequest.audioURL), !cached.isEmpty {
                    guard let self, self.requestID == currentRequestID else { return }
                    self.chapters = cached
                    self.didLoad = true
                    self.isLoading = false
                    self.task = nil
                    return
                }
                if !force, let cached = await WatchChapterCache.shared.read(cacheKey) {
                    guard let self, self.requestID == currentRequestID else { return }
                    self.chapters = cached
                    self.didLoad = true
                    self.isLoading = false
                    self.task = nil
                    return
                }
                var result: [SRPodcastChapterRecord]
                let relayed = audioURL?.isFileURL == true ? nil : await WatchPhoneChapterRequest.fetch(
                    phoneRequest,
                    onUnavailable: { phoneStatus = $0 },
                    onLateChapters: { [weak self] chapters in
                        guard let self, self.requestID == currentRequestID else { return }
                        self.task?.cancel()
                        self.task = nil
                        self.chapters = chapters
                        self.errorMessage = nil
                        self.isLoading = false
                        self.didLoad = true
                        Task { await WatchChapterCache.shared.write(chapters, key: cacheKey) }
                        print("[WatchChapters] late iPhone reply: loaded \(chapters.count) chapters")
                    }
                )
                try Task.checkCancellation()
                if let relayed {
                    source = "iPhone chapters"
                    result = relayed
                } else if let audioURL, audioURL.isFileURL {
                    source = "Downloaded chapters"
                    result = try await WatchPodcastLibrary.loadID3Chapters(from: audioURL)
                    if result.isEmpty, let chapterURL {
                        result = try await WatchPodcastLibrary.loadChapters(from: chapterURL)
                    }
                } else if let chapterURL {
                    source = "Watch chapter JSON (\(chapterURL.host ?? "unknown host"))"
                    do {
                        result = try await WatchPodcastLibrary.loadChapters(from: chapterURL)
                    } catch {
                        try Task.checkCancellation()
                        guard let audioURL else { throw error }
                        print("[WatchChapters] JSON failed (\(error)); trying embedded chapters")
                        source = "Watch embedded chapters (\(audioURL.host ?? "unknown host"))"
                        result = try await WatchPodcastLibrary.loadID3Chapters(from: audioURL)
                        if result.isEmpty { throw error }
                    }
                    if result.isEmpty, let audioURL {
                        result = try await WatchPodcastLibrary.loadID3Chapters(from: audioURL)
                    }
                } else if let audioURL {
                    source = "Watch embedded chapters (\(audioURL.host ?? "unknown host"))"
                    result = try await WatchPodcastLibrary.loadID3Chapters(from: audioURL)
                } else {
                    throw URLError(.badURL)
                }
                try Task.checkCancellation()
                await WatchChapterCache.shared.write(result, key: cacheKey)
                guard let self, self.requestID == currentRequestID else { return }
                self.chapters = result
                self.didLoad = true
                self.isLoading = false
                self.task = nil
                print("[WatchChapters] \(source): loaded \(result.count) chapters")
            } catch {
                guard !Task.isCancelled, let self, self.requestID == currentRequestID else { return }
                self.errorMessage = "\(source): \(error.localizedDescription)"
                    + (phoneStatus.isEmpty ? "" : "\n\(phoneStatus)")
                self.isLoading = false
                self.task = nil
                print("[WatchChapters] load failed: \(error)")
            }
        }
    }
}

@MainActor
private final class WatchPhoneChapterRequest {
    private var continuation: CheckedContinuation<[SRPodcastChapterRecord]?, Never>?
    private var deadline: Task<Void, Never>?
    private var onUnavailable: ((String) -> Void)?
    private var onLateChapters: (([SRPodcastChapterRecord]) -> Void)?

    static func fetch(_ request: SRChapterRequest?, onUnavailable: ((String) -> Void)? = nil,
                      onLateChapters: (([SRPodcastChapterRecord]) -> Void)? = nil) async -> [SRPodcastChapterRecord]? {
        guard let request else { return nil }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            onUnavailable?("iPhone connection is not active.")
            return nil
        }
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        guard !Task.isCancelled else { return nil }
        let session = WCSession.default
        let message: [String: Any] = [
            SRChapterRequest.messageKey: data,
            SRChapterDelivery.deferredRequestKey: true
        ]
        let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
            guard let data = transfer.userInfo[SRChapterRequest.messageKey] as? Data,
                  let queued = try? JSONDecoder().decode(SRChapterRequest.self, from: data) else { return false }
            return queued.feedID == request.feedID && queued.audioURL == request.audioURL
        }
        if !alreadyQueued {
            session.transferUserInfo(message)
            print("[WatchChapters] queued iPhone request episode=\(request.episodeID)")
        }
        guard session.isReachable else {
            onUnavailable?("iPhone request queued; waiting for connectivity.")
            return nil
        }
        let pending = WatchPhoneChapterRequest()
        pending.onUnavailable = onUnavailable
        pending.onLateChapters = onLateChapters
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                pending.continuation = continuation
                pending.deadline = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    print("[WatchChapters] no live iPhone reply; using Watch network with queued request pending")
                    pending.finish(nil, reason: "iPhone request queued; live connection did not respond.")
                }
                session.sendMessage(message, replyHandler: { reply in
                    if reply[SRChapterDelivery.deferredRequestKey] as? Bool == true {
                        Task { @MainActor in
                            print("[WatchChapters] iPhone acknowledged; trying Watch network while awaiting chapters")
                            pending.finish(nil, reason: "iPhone is fetching chapters; delivery is pending.")
                        }
                        return
                    }
                    let chapters = (reply[SRChapterRequest.responseKey] as? Data).flatMap {
                        try? JSONDecoder().decode([SRPodcastChapterRecord].self, from: $0)
                    }
                    Task { @MainActor in
                        pending.receive(chapters)
                    }
                }, errorHandler: { error in
                    print("[WatchChapters] iPhone request failed: \(error.localizedDescription)")
                    Task { @MainActor in pending.finish(nil, reason: "iPhone live request failed: \(error.localizedDescription) Queued request remains pending.") }
                })
            }
        } onCancel: {
            Task { @MainActor in
                pending.onLateChapters = nil
                pending.finish(nil)
            }
        }
    }

    private func receive(_ chapters: [SRPodcastChapterRecord]?) {
        guard let chapters, !chapters.isEmpty else {
            finish(nil, reason: "iPhone returned no chapters.")
            return
        }
        if continuation == nil { onLateChapters?(chapters) }
        onLateChapters = nil
        finish(chapters)
    }

    private func finish(_ chapters: [SRPodcastChapterRecord]?, reason: String? = nil) {
        guard continuation != nil else { return }
        if chapters == nil, let reason { onUnavailable?(reason) }
        onUnavailable = nil
        deadline?.cancel()
        deadline = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: chapters)
    }
}

private enum WatchID3ChapterReader {
    static func load(from url: URL) async throws -> [SRPodcastChapterRecord] {
        guard let tag = try await fetchTag(from: url) else { return [] }
        return parse(frames: tag.frames, version: tag.version)
    }

    private static func fetchTag(from url: URL) async throws -> (version: UInt8, frames: Data)? {
        let maximumTagSize = 4_000_000
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 10), header.count == 10,
                  header.prefix(3) == Data("ID3".utf8) else { return nil }
            let size = syncSafeInt(header, at: 6)
            if size == 0 { return nil }
            guard size <= maximumTagSize else { throw URLError(.dataLengthExceedsMaximum) }
            guard let frames = try handle.read(upToCount: size), frames.count == size else {
                throw URLError(.cannotDecodeContentData)
            }
            return (header[3], frames)
        }
        let started = Date()
        let prefix = try await WatchChapterPrefixRequest.fetchResponse(url: url, limit: 65_536)
        var data = prefix.data
        guard data.count >= 10 else { throw URLError(.cannotDecodeContentData) }
        guard data.prefix(3) == Data("ID3".utf8) else { return nil }
        let size = syncSafeInt(data, at: 6)
        if size == 0 { return nil }
        guard size <= maximumTagSize else { throw URLError(.dataLengthExceedsMaximum) }
        let requiredCount = size + 10
        if data.count < requiredCount {
            data = try await WatchChapterPrefixRequest.fetch(url: prefix.url, limit: requiredCount)
        }
        guard data.count >= requiredCount else { throw URLError(.cannotDecodeContentData) }
        print("[WatchChapters] ID3 bytes=\(requiredCount) elapsed=\(Date().timeIntervalSince(started)) host=\(url.host ?? "unknown")")
        return (data[3], data.subdata(in: 10..<requiredCount))
    }

    private static func parse(frames: Data, version: UInt8) -> [SRPodcastChapterRecord] {
        var chapters: [SRPodcastChapterRecord] = []
        var index = 0
        while index + 10 <= frames.count {
            let identifier = frames.subdata(in: index..<(index + 4))
            guard isFrameIdentifier(identifier),
                  let size = frameSize(frames, at: index + 4, version: version),
                  size > 0, index + 10 + size <= frames.count else { break }
            if identifier == Data("CHAP".utf8) {
                let body = frames.subdata(in: (index + 10)..<(index + 10 + size))
                if let chapter = parseChapter(body, version: version) {
                    chapters.append(chapter)
                }
            }
            index += 10 + size
        }
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    private static func parseChapter(
        _ body: Data,
        version: UInt8
    ) -> SRPodcastChapterRecord? {
        guard let terminator = body.firstIndex(of: 0) else { return nil }
        let timesStart = terminator + 1
        guard timesStart + 16 <= body.count else { return nil }
        let startMilliseconds = bigEndianInt(body, at: timesStart)
        var index = timesStart + 16
        while index + 10 <= body.count {
            let identifier = body.subdata(in: index..<(index + 4))
            guard isFrameIdentifier(identifier),
                  let size = frameSize(body, at: index + 4, version: version),
                  size > 0, index + 10 + size <= body.count else { break }
            if identifier == Data("TIT2".utf8) {
                let frameBody = body.subdata(in: (index + 10)..<(index + 10 + size))
                if let title = decodeText(frameBody), !title.isEmpty {
                    return SRPodcastChapterRecord(
                        title: title,
                        startTime: TimeInterval(startMilliseconds) / 1_000
                    )
                }
            }
            index += 10 + size
        }
        return nil
    }

    private static func frameSize(_ data: Data, at offset: Int, version: UInt8) -> Int? {
        guard offset + 4 <= data.count else { return nil }
        let plain = bigEndianInt(data, at: offset)
        let syncSafe = syncSafeInt(data, at: offset)
        let candidates = version >= 4 ? [syncSafe, plain] : [plain, syncSafe]
        for candidate in candidates where candidate > 0 {
            let next = offset + 6 + candidate
            if next == data.count { return candidate }
            if next + 4 <= data.count,
               isFrameIdentifier(data.subdata(in: next..<(next + 4))) {
                return candidate
            }
        }
        return candidates.first { $0 > 0 }
    }

    private static func isFrameIdentifier(_ data: Data) -> Bool {
        data.count == 4 && data.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39)
        }
    }

    private static func bigEndianInt(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }

    private static func syncSafeInt(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset] & 0x7F) << 21) | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7) | Int(data[offset + 3] & 0x7F)
    }

    private static func decodeText(_ data: Data) -> String? {
        guard let encoding = data.first, data.count > 1 else { return nil }
        let content = data.subdata(in: 1..<data.count)
        let decoded: String?
        switch encoding {
        case 0: decoded = String(data: content, encoding: .isoLatin1)
        case 1: decoded = String(data: content, encoding: .utf16)
        case 2: decoded = String(data: content, encoding: .utf16BigEndian)
        default: decoded = String(data: content, encoding: .utf8)
        }
        return decoded?.trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines)
        )
    }
}

private final class WatchChapterPrefixRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private let lock = NSLock()
    private var completedResult: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var responseURL: URL?
    private var stage = "Connecting"

    private init(limit: Int) { self.limit = limit }

    static func fetch(url: URL, limit: Int) async throws -> Data {
        try await fetchResponse(url: url, limit: limit).data
    }

    static func fetchResponse(url: URL, limit: Int) async throws -> (data: Data, url: URL) {
        let delegate = WatchChapterPrefixRequest(limit: limit)
        delegate.stage = "Connecting to \(url.host ?? "audio server")"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                delegate.install(continuation)
                task.resume()
            }
            try Task.checkCancellation()
            return (result, delegate.responseURL ?? url)
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
                responseURL = response.url
                stage = "Reading from \(response.url?.host ?? "audio server")"
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 || response.statusCode == 206 else {
            finish(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        if response.statusCode == 206,
           response.value(forHTTPHeaderField: "Content-Range")?.lowercased().hasPrefix("bytes 0-") != true {
            finish(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        redirected.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        stage = "Connecting to \(request.url?.host ?? "redirected audio server")"
        print("[WatchChapters] redirect \(response.statusCode) to \(request.url?.host ?? "unknown") range=0-\(limit - 1)")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count < limit else { return }
        data.append(contentsOf: chunk.prefix(limit - data.count))
        if data.count == limit {
            finish(.success(data))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard data.count < limit else { return }
        if let error {
            let underlying = error as NSError
            let message = "\(stage), \(data.count)/\(limit) bytes: \(error.localizedDescription)"
            print("[WatchChapters] \(message)")
            finish(.failure(NSError(domain: underlying.domain, code: underlying.code,
                userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: underlying])))
        }
        else { finish(.success(data)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard completedResult == nil else { lock.unlock(); return }
        completedResult = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        let result = completedResult
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }
}

private actor WatchChapterCache {
    static let shared = WatchChapterCache()
    private struct Entry: Codable {
        let date: Date
        let chapters: [SRPodcastChapterRecord]
    }
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WatchChapters", isDirectory: true)

    private func fileURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    func read(_ key: String) -> [SRPodcastChapterRecord]? {
        guard let data = try? Data(contentsOf: fileURL(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(entry.date) < (entry.chapters.isEmpty ? 86_400 : 2_592_000) else { return nil }
        return entry.chapters
    }

    func write(_ chapters: [SRPodcastChapterRecord], key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(date: .now, chapters: chapters))
            try data.write(to: fileURL(key), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
            if files.count > 200 {
                let oldest = files.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for file in oldest.prefix(files.count - 200) { try? FileManager.default.removeItem(at: file) }
            }
        } catch { print("[WatchChapters] cache write failed: \(error)") }
    }
}

private enum WatchPodcastFeedError: LocalizedError {
    case httpStatus(Int)
    case invalidFeed

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "The podcast server returned HTTP \(status)."
        case .invalidFeed:
            return "No playable episodes were found."
        }
    }
}

private final class WatchPodcastRSSParser: NSObject, XMLParserDelegate {
    private let feedID: String
    private var episodes: [SRPodcastEpisodeRecord] = []
    private var isInsideItem = false
    private var currentElement = ""
    private var currentText = ""
    private var title = ""
    private var descriptionText = ""
    private var audioURL = ""
    private var guid = ""
    private var publicationDate = Date.distantPast
    private var duration: TimeInterval = 0
    private var chaptersURL: String?
    private lazy var dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private init(feedID: String) {
        self.feedID = feedID
    }

    static func parse(data: Data, feedID: String) throws -> [SRPodcastEpisodeRecord] {
        let delegate = WatchPodcastRSSParser(feedID: feedID)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let completed = parser.parse()
        if !completed, delegate.episodes.isEmpty {
            throw parser.parserError ?? WatchPodcastFeedError.invalidFeed
        }

        let episodes = delegate.episodes
            .sorted { $0.publicationDate > $1.publicationDate }
            .prefix(WatchPodcastLibrary.episodeLimit)
        guard !episodes.isEmpty else { throw WatchPodcastFeedError.invalidFeed }
        return Array(episodes)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = (qName ?? elementName).lowercased()
        currentText = ""
        if currentElement == "item" || currentElement == "entry" {
            isInsideItem = true
            resetItem()
        } else if isInsideItem,
                  currentElement == "enclosure",
                  let url = attributeDict["url"] {
            audioURL = url
        } else if isInsideItem,
                  currentElement == "link",
                  attributeDict["rel"] == "enclosure",
                  let url = attributeDict["href"] {
            audioURL = url
          } else if isInsideItem,
                (currentElement == "chapters" || currentElement.hasSuffix(":chapters")),
                let url = attributeDict["url"] {
            chaptersURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isInsideItem else { return }
        let element = (qName ?? elementName).lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "title":
            title = value
        case "description", "summary", "content", "content:encoded":
            if descriptionText.isEmpty { descriptionText = value }
        case "guid", "id":
            guid = value
        case "pubdate", "published", "updated":
            if let date = parseDate(value) { publicationDate = date }
        case "itunes:duration", "duration":
            duration = Self.parseDuration(value)
        case "item", "entry":
            finishItem()
            isInsideItem = false
        default:
            break
        }
        currentText = ""
    }

    private func resetItem() {
        title = ""
        descriptionText = ""
        audioURL = ""
        guid = ""
        publicationDate = .distantPast
        duration = 0
        chaptersURL = nil
    }

    private func finishItem() {
        guard !title.isEmpty, !audioURL.isEmpty else { return }
        episodes.append(
            SRPodcastEpisodeRecord(
                id: guid.isEmpty ? audioURL : guid,
                feedID: feedID,
                title: title,
                descriptionText: descriptionText,
                audioURL: audioURL,
                publicationDate: publicationDate,
                duration: duration,
                chaptersURL: chaptersURL
            )
        )
        if episodes.count > WatchPodcastLibrary.episodeLimit {
            episodes.sort { $0.publicationDate > $1.publicationDate }
            episodes.removeLast(episodes.count - WatchPodcastLibrary.episodeLimit)
        }
    }

    private func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func parseDuration(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}