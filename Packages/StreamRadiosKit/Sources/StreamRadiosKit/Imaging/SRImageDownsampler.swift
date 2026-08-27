import CoreGraphics
import ImageIO
import UIKit

/// Decodes image data straight to the size it will actually be drawn at.
///
/// `UIImage(data:)` keeps the full-resolution bitmap alive — a 3000×3000 podcast cover costs
/// ~36 MB decoded, and it gets decoded on the main thread the first time it's drawn. Rendering
/// that into a 56pt row is why large lists stutter. `CGImageSourceCreateThumbnailAtIndex`
/// decodes once, at target size, off the main thread.
enum SRImageDownsampler {
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded())
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
