import SwiftUI

/// Drop-in replacement for `AsyncImage` in list rows, grids and the player.
///
/// Unlike `AsyncImage` it downsamples to the display size, shares one download across all
/// rows showing the same artwork, and resolves synchronously from memory when the bitmap is
/// already resident — so scrolling back up a list shows covers instantly instead of
/// re-fetching and re-decoding them.
public struct SRArtwork: View {
    private let source: SRArtworkSource
    private let side: CGFloat
    private let cornerRadius: CGFloat
    private let fallbackSystemImage: String
    private let isBusy: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    public init(
        source: SRArtworkSource,
        side: CGFloat,
        cornerRadius: CGFloat = SRRadius.thumbnail,
        fallbackSystemImage: String = "antenna.radiowaves.left.and.right",
        isBusy: Bool = false
    ) {
        self.source = source
        self.side = side
        self.cornerRadius = cornerRadius
        self.fallbackSystemImage = fallbackSystemImage
        self.isBusy = isBusy
    }

    public init(
        url: URL?,
        side: CGFloat,
        cornerRadius: CGFloat = SRRadius.thumbnail,
        fallbackSystemImage: String = "antenna.radiowaves.left.and.right"
    ) {
        self.init(
            source: url.map { .remote($0) } ?? .none,
            side: side,
            cornerRadius: cornerRadius,
            fallbackSystemImage: fallbackSystemImage
        )
    }

    public var body: some View {
        content
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { busyOverlay }
            .task(id: source) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            SRColor.placeholder
                .overlay(
                    Image(systemName: fallbackSystemImage)
                        .font(.system(size: side * 0.36, weight: .regular))
                        .foregroundStyle(SRColor.tertiaryText)
                )
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if isBusy {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black.opacity(0.35))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    private var maxPixelSize: CGFloat { side * displayScale }

    private func load() async {
        guard source != .none else {
            image = nil
            return
        }

        // Synchronous hit: no await, no placeholder frame, no flicker.
        if let cached = SRImageLoader.shared.cachedImage(for: source, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }

        image = nil
        // `.task` is cancelled when the row scrolls away, but the work it kicks off is not. Waiting
        // a beat first means a fast scroll past thousands of rows costs nothing, and only artwork
        // that actually settles on screen pays for a fetch and a decode.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }

        let loaded = await SRImageLoader.shared.image(for: source, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) { image = loaded }
    }
}
