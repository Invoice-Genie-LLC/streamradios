import SwiftUI

/// Everything the row needs to draw itself. Deliberately a value type with no Core Data or
/// view-model references, so rows diff cheaply and can be previewed in isolation.
public struct SRStationRowModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var country: String
    public var artwork: SRArtworkSource
    public var isFavorite: Bool
    /// The All tab hides the country because every station shares it.
    public var showsCountry: Bool

    public init(
        id: String,
        name: String,
        country: String,
        artwork: SRArtworkSource = .none,
        isFavorite: Bool = false,
        showsCountry: Bool = true
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.artwork = artwork
        self.isFavorite = isFavorite
        self.showsCountry = showsCountry
    }
}

/// A station row in the redesigned radio list.
///
/// Playing state is derived from the shared `SRNowPlaying` projection rather than reaching into
/// RadioPlayer, so the row works identically wherever it's used and needs no radio/podcast
/// branching.
public struct SRStationRow: View {
    private let model: SRStationRowModel
    private let nowPlaying: SRNowPlaying?
    private let flag: Image?
    private let onTap: () -> Void
    private let onToggleFavorite: () -> Void

    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var artworkSide: CGFloat = SRArtworkSize.row

    public init(
        model: SRStationRowModel,
        nowPlaying: SRNowPlaying?,
        flag: Image? = nil,
        onTap: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void
    ) {
        self.model = model
        self.nowPlaying = nowPlaying
        self.flag = flag
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
    }

    private var isCurrent: Bool { nowPlaying?.id == model.id }
    private var activity: SRPlaybackActivity { isCurrent ? (nowPlaying?.activity ?? .idle) : .idle }

    /// Shazam / ICY metadata for the playing station, if the stream is reporting any.
    private var liveMetadata: String? {
        guard isCurrent, let subtitle = nowPlaying?.subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    public var body: some View {
        HStack(spacing: SRSpacing.md) {
            SRArtwork(
                source: model.artwork,
                side: artworkSide,
                cornerRadius: SRRadius.thumbnail,
                isBusy: activity.isBusy
            )

            VStack(alignment: .leading, spacing: SRSpacing.xxs) {
                Text(model.name)
                    .font(SRFont.rowTitle)
                    .foregroundStyle(SRColor.primaryText)
                    .lineLimit(2)

                if model.showsCountry {
                    countryLine
                }

                if let liveMetadata {
                    Text(liveMetadata)
                        .font(SRFont.rowDetail)
                        .foregroundStyle(SRColor.accent)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            // Weighted child: measured from remaining space, so a long name wraps instead of
            // squeezing the trailing controls off the row.
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                SREqualizerBars(isAnimating: activity.isPlaying)
                    .transition(.opacity)
            }

            favoriteButton
        }
        .padding(.vertical, SRSpacing.sm)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .background(alignment: .leading) { playingHighlight }
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        // `.combine` would walk and merge the whole subtree's accessibility elements for every
        // row; the label below already describes the row completely.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent && activity.isPlaying ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var countryLine: some View {
        HStack(spacing: SRSpacing.xs) {
            if let flag {
                flag
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            Text(model.country)
                .font(SRFont.rowSubtitle)
                .foregroundStyle(SRColor.secondaryText)
                .lineLimit(1)
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: model.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.isFavorite ? SRColor.live : SRColor.tertiaryText)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .symbolEffect(.bounce, value: model.isFavorite)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(model.isFavorite ? "Remove from favourites" : "Add to favourites")
    }

    @ViewBuilder
    private var playingHighlight: some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: SRRadius.control, style: .continuous)
                .fill(SRColor.accent.opacity(0.08))
                .padding(.vertical, SRSpacing.xxs)
                .padding(.horizontal, -SRSpacing.sm)
        }
    }

    private var accessibilityLabel: Text {
        var parts = [model.name]
        if model.showsCountry { parts.append(model.country) }
        if let liveMetadata { parts.append("Now playing \(liveMetadata)") }
        if model.isFavorite { parts.append("Favourite") }
        return Text(parts.joined(separator: ", "))
    }
}
