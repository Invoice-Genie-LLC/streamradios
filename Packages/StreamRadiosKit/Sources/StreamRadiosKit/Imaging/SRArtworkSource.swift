import UIKit

/// Where a piece of artwork comes from.
///
/// Stations store artwork as a base64 `String` on the Core Data row, podcasts use remote URLs,
/// and Shazam supplies decoded iTunes art — the UI shouldn't care which.
public enum SRArtworkSource: @unchecked Sendable {
    case none
    case remote(URL)
    /// A base64 blob (e.g. `CDStation.iconData`) plus a stable identity for caching.
    case encoded(base64: String, cacheKey: String)
    /// Like `.encoded`, but the payload is only read on a cache miss. Lets a row reference
    /// artwork without pulling the blob out of the store every time the row is rebuilt.
    case lazyEncoded(cacheKey: String, provider: @Sendable () async -> String?)
    /// Already-decoded art handed to us by another subsystem (Shazam / iTunes lookup).
    case image(UIImage, cacheKey: String)

    var cacheKey: String? {
        switch self {
        case .none: nil
        case .remote(let url): url.absoluteString
        case .encoded(_, let key): key
        case .lazyEncoded(let key, _): key
        case .image(_, let key): key
        }
    }
}

// Equality compares identity only. A base64 cover can be hundreds of KB; letting SwiftUI
// diff the payload on every render would cost more than drawing the row.
extension SRArtworkSource: Equatable {
    public static func == (lhs: SRArtworkSource, rhs: SRArtworkSource) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }
}
