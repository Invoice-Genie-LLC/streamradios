import CryptoKit
import Foundation
import UIKit

/// Cache key for a decoded bitmap: same URL at different display sizes are different entries.
struct SRImageKey: Hashable, Sendable {
    let url: URL
    let maxPixelSize: Int

    init(url: URL, maxPixelSize: CGFloat) {
        self.url = url
        self.maxPixelSize = Int(maxPixelSize.rounded())
    }

    var cacheKey: String { "\(url.absoluteString)@\(maxPixelSize)" }
}

/// In-memory bitmap cache. `NSCache` is already thread-safe and evicts automatically under
/// memory pressure, which is exactly the behaviour we want for a list that can scroll through
/// thousands of covers.
final class SRImageMemoryCache: @unchecked Sendable {
    static let shared = SRImageMemoryCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 600
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        // Cost = decoded byte size, so the limit is a real memory ceiling rather than a count.
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// On-disk cache of the *original* downloaded bytes, so a cover downloaded for a 56pt row can
/// be re-downsampled for the 320pt player without another network round trip.
actor SRImageDiskCache {
    private let directory: URL
    private let byteLimit: Int
    private let fileManager = FileManager.default
    private var didPrepare = false

    init(byteLimit: Int = 256 * 1024 * 1024) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = caches.appendingPathComponent("SRArtwork", isDirectory: true)
        self.byteLimit = byteLimit
    }

    func data(for url: URL) -> Data? {
        prepareIfNeeded()
        let file = location(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Touch so the LRU prune keeps recently used covers.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        prepareIfNeeded()
        try? data.write(to: location(for: url), options: .atomic)
    }

    func clear() {
        try? fileManager.removeItem(at: directory)
        didPrepare = false
    }

    /// Evicts least-recently-used files until the cache is back under its byte limit.
    func prune() {
        prepareIfNeeded()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        let entries: [(url: URL, date: Date, size: Int)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let date = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return (file, date, size)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total <= byteLimit { break }
        }
    }

    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        didPrepare = true
    }

    private func location(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}
