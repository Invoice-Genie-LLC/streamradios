import Foundation
import UIKit

/// Loads, caches and downsamples artwork.
///
/// Three properties matter for large lists:
///  1. **Synchronous memory hits** — an already-decoded cover is returned without touching the
///     actor, so re-entering a scrolled list never flickers a placeholder.
///  2. **Request coalescing** — 40 rows showing the same podcast cover produce one download,
///     not 40. `AsyncImage` has no such de-duplication.
///  3. **Detached decoding** — downsampling runs off both the main thread and this actor, so a
///     slow decode can't block other rows.
public actor SRImageLoader {
    public static let shared = SRImageLoader()

    private let session: URLSession
    private let disk = SRImageDiskCache()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var requestsSincePrune = 0

    private init() {
        let configuration = URLSessionConfiguration.default
        // We manage our own disk cache; URLCache would duplicate every byte.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    /// Returns a decoded bitmap sized for `maxPixelSize`, or `nil` if it can't be loaded.
    public func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = SRImageKey(url: url, maxPixelSize: maxPixelSize).cacheKey

        if let cached = SRImageMemoryCache.shared.image(for: key) {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let disk = self.disk
        let session = self.session
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            let bytes: Data
            if let onDisk = await disk.data(for: url) {
                bytes = onDisk
            } else if let downloaded = try? await session.data(from: url).0, !downloaded.isEmpty {
                await disk.store(downloaded, for: url)
                bytes = downloaded
            } else {
                return nil
            }

            guard let image = SRImageDownsampler.downsample(data: bytes, maxPixelSize: maxPixelSize) else {
                return nil
            }
            SRImageMemoryCache.shared.insert(image, for: key)
            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        schedulePruneIfNeeded()
        return image
    }

    /// Warms the cache for rows about to scroll into view.
    public func prefetch(_ urls: [URL], maxPixelSize: CGFloat) {
        for url in urls {
            let key = SRImageKey(url: url, maxPixelSize: maxPixelSize).cacheKey
            guard SRImageMemoryCache.shared.image(for: key) == nil, inFlight[key] == nil else { continue }
            Task { _ = await image(for: url, maxPixelSize: maxPixelSize) }
        }
    }

    /// Decodes base64 artwork stored alongside the record (station icons, embedded covers).
    ///
    /// Doing this in a view body — as the old station list did — costs a base64 decode plus a
    /// full-size image decode on every render pass. Here it happens once per size, off the main
    /// thread, and the result is cached. No disk cache: the bytes already live in Core Data.
    public func image(forEncoded base64: String, cacheKey: String, maxPixelSize: CGFloat) async -> UIImage? {
        await image(encodedKey: cacheKey, maxPixelSize: maxPixelSize) { base64 }
    }

    /// The cache and in-flight checks happen before `provider` runs, so a resident bitmap never
    /// pays for fetching its source bytes.
    public func image(
        encodedKey cacheKey: String,
        maxPixelSize: CGFloat,
        provider: @escaping @Sendable () async -> String?
    ) async -> UIImage? {
        let key = "\(cacheKey)@\(Int(maxPixelSize.rounded()))"

        if let cached = SRImageMemoryCache.shared.image(for: key) {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let base64 = await provider(),
                  let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  let image = SRImageDownsampler.downsample(data: data, maxPixelSize: maxPixelSize)
            else { return nil }
            SRImageMemoryCache.shared.insert(image, for: key)
            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    /// Resolves any artwork source to a decoded, correctly sized bitmap.
    public func image(for source: SRArtworkSource, maxPixelSize: CGFloat) async -> UIImage? {
        switch source {
        case .none:
            return nil
        case .remote(let url):
            return await image(for: url, maxPixelSize: maxPixelSize)
        case .encoded(let base64, let cacheKey):
            return await image(forEncoded: base64, cacheKey: cacheKey, maxPixelSize: maxPixelSize)
        case .lazyEncoded(let cacheKey, let provider):
            return await image(encodedKey: cacheKey, maxPixelSize: maxPixelSize, provider: provider)
        case .image(let image, _):
            return image
        }
    }

    /// Non-blocking lookup for callers that can render immediately when the bitmap is resident.
    public nonisolated func cachedImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        SRImageMemoryCache.shared.image(for: SRImageKey(url: url, maxPixelSize: maxPixelSize).cacheKey)
    }

    public nonisolated func cachedImage(for source: SRArtworkSource, maxPixelSize: CGFloat) -> UIImage? {
        guard let cacheKey = source.cacheKey else { return nil }
        let key: String
        switch source {
        case .remote(let url):
            key = SRImageKey(url: url, maxPixelSize: maxPixelSize).cacheKey
        case .image(let image, _):
            return image
        default:
            key = "\(cacheKey)@\(Int(maxPixelSize.rounded()))"
        }
        return SRImageMemoryCache.shared.image(for: key)
    }

    public func clearCaches() async {
        SRImageMemoryCache.shared.removeAll()
        await disk.clear()
    }

    private func schedulePruneIfNeeded() {
        requestsSincePrune += 1
        guard requestsSincePrune >= 300 else { return }
        requestsSincePrune = 0
        let disk = self.disk
        Task.detached(priority: .background) { await disk.prune() }
    }
}
