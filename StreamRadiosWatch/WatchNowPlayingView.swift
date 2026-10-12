import Foundation
import ImageIO
import StreamRadiosCore
import SwiftUI
import WatchKit

/// Animates "now playing" waveforms only while audio plays and the screen isn't in Always On.
private struct PlayingWaveEffect: ViewModifier {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let isActive: Bool

    func body(content: Content) -> some View {
        content.symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive && !isLuminanceReduced)
    }
}

extension View {
    func playingWaveEffect(_ isActive: Bool) -> some View {
        modifier(PlayingWaveEffect(isActive: isActive))
    }
}

/// The system volume control: it follows the Digital Crown while it has focus.
private struct WatchVolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(.red)
        DispatchQueue.main.async { control.focus() }
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {}
}

struct WatchNowPlayingView: View {
    let player: WatchAudioPlayer
    @State private var chapterLoader = WatchChapterLoader()
    @State private var showNotes = false
    @State private var showChapters = false
    @State private var showEpisodeOptions = false
    @State private var showAudioOutput = false

    var body: some View {
        Group {
            if episode != nil {
                podcastPlayerLayout
            } else {
                radioPlayerLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if player.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if episode != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    episodeMenu
                }
            }
        }
        .alert("Playback", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.dismissError() } }
        )) {
            Button("OK") { player.dismissError() }
        } message: {
            Text(player.errorMessage ?? "")
        }
        .navigationDestination(isPresented: $showEpisodeOptions) {
            episodeOptionsPage
                .navigationTitle("Episode")
        }
        .onChange(of: chapterLoadID) { _, _ in
            chapterLoader.reset()
            if showEpisodeOptions { loadChapters() }
        }
        .onChange(of: player.isBuffering) { _, buffering in
            if !buffering, showEpisodeOptions { loadChapters() }
        }
    }

    private var episode: SRPodcastEpisodeRecord? {
        guard case .podcast(let episode, _) = player.item else { return nil }
        return episode
    }

    private var podcastFeed: SRPodcastFeedRecord? {
        guard case .podcast(_, let feed) = player.item else { return nil }
        return feed
    }

    private var chapterLoadID: String {
        "\(episode?.id ?? "none")|\(episode?.chaptersURL ?? "")|\(episode?.chapters?.hashValue ?? 0)"
    }

    private var chapters: [SRPodcastChapterRecord] {
        chapterLoader.key == chapterLoadID ? chapterLoader.chapters : localChapters
    }

    private var isLoadingChapters: Bool {
        chapterLoader.key == chapterLoadID && chapterLoader.isLoading
    }

    private var chapterError: String? {
        chapterLoader.key == chapterLoadID ? chapterLoader.errorMessage : nil
    }

    private func loadChapters(force: Bool = false) {
        guard let episode, !player.isBuffering else { return }
        chapterLoader.load(
            key: chapterLoadID,
            supplied: localChapters,
            chapterURL: episode.chaptersURL.flatMap { chapterURL(from: $0) },
            audioURL: WatchEpisodeDownloads.shared.localURL(for: episode) ?? URL(string: episode.audioURL),
            phoneRequest: SRChapterRequest(feedID: episode.feedID, episodeID: episode.id, audioURL: episode.audioURL),
            force: force
        )
    }

    private var localChapters: [SRPodcastChapterRecord] {
        let supplied = episode?.chapters ?? []
        if !supplied.isEmpty { return supplied }
        return Self.chapters(fromHTML: episode?.descriptionText ?? "")
    }

    private var supportsChapters: Bool {
        !chapters.isEmpty
    }

    private func chapterURL(from value: String) -> URL? {
        URL(string: value, relativeTo: podcastFeed.flatMap { URL(string: $0.feedURL) })?.absoluteURL
    }

    private var podcastPlayerLayout: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                WatchArtworkView(
                    url: player.artworkURL,
                    data: player.artworkData,
                    systemImage: player.item?.systemImage ?? "waveform"
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.item?.title ?? "Not Playing")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                        .fixedSize(horizontal: false, vertical: true)

                    if let status = connectionStatusText {
                        connectionStatusLabel(status)
                    } else if let subtitle = player.item?.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            podcastTimeline
            podcastControls
            outputControls
        }
        .padding(.horizontal, 8)
        // Small gap so the title doesn't touch the toolbar's ellipsis button.
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    private var radioPlayerLayout: some View {
        VStack(spacing: 5) {
            WatchArtworkView(
                url: player.artworkURL,
                data: player.artworkData,
                systemImage: player.item?.systemImage ?? "radio.fill"
            )
            .frame(width: 76, height: 76)
            .shadow(color: Color.red.opacity(0.25), radius: 8)

            VStack(spacing: 2) {
                Text(player.item?.title ?? "Not Playing")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                if let status = connectionStatusText {
                    connectionStatusLabel(status)
                } else {
                    Text(player.radioMetadata ?? player.item?.subtitle ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            radioControls
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    private var radioControls: some View {
        VStack(spacing: 2) {
            playPauseButton
                .opacity(player.isBuffering ? 0 : 1)

            outputControls
        }
        .frame(maxWidth: .infinity)
    }

    private var outputNameLabel: some View {
        Text(player.outputDisplayName)
            .font(.caption2)
            .foregroundStyle(player.hasAudioOutput ? Color.primary : Color.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: 90)
    }

    private var volumeControl: some View {
        // The WatchKit control ignores its SwiftUI frame, so shrink it visually.
        WatchVolumeControl()
            .scaleEffect(0.45)
            .frame(width: 20, height: 20)
            .accessibilityLabel("Volume. Turn the Digital Crown to adjust.")
    }

    private var connectionStatusText: (text: String, symbol: String)? {
        switch player.connectionStatus {
        case .normal:
            return nil
        case .weakSignal:
            return ("Weak signal, buffering…", "wifi.exclamationmark")
        case .reconnecting(let attempt):
            return ("Reconnecting… (\(attempt)/\(WatchAudioPlayer.maxReconnectAttempts))", "arrow.triangle.2.circlepath")
        case .offline:
            return ("No connection, waiting…", "wifi.slash")
        }
    }

    private func connectionStatusLabel(_ status: (text: String, symbol: String)) -> some View {
        Label(status.text, systemImage: status.symbol)
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityLabel(status.text)
    }

    private var outputControls: some View {
        // Fixed-width side slots keep the name centred and the controls close to it in both players.
        HStack(spacing: 6) {
            volumeControl
                .frame(width: 30, height: 30)
            outputNameLabel
                .frame(width: 60)
            audioOutputButton
        }
        .frame(maxWidth: .infinity, minHeight: 30)
    }

    private var podcastTimeline: some View {
        VStack(spacing: 2) {
            ProgressView(value: player.currentTime, total: max(player.duration, 1))
                .tint(.accentColor)

            HStack {
                Text(player.currentTime.formattedTime)
                Spacer()
                Text(player.duration.formattedTime)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var podcastControls: some View {
        HStack(spacing: 14) {
            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }

            playPauseButton

            Button {
                player.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private var audioOutputButton: some View {
        Button {
            showAudioOutput = true
        } label: {
            Image(systemName: "airplayaudio")
                .font(.caption2)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.isChoosingAudioOutput)
        .foregroundStyle(player.hasAudioOutput ? Color.secondary : Color.orange)
        .accessibilityLabel("Audio output, \(player.outputDisplayName)")
        .confirmationDialog("Audio Output", isPresented: $showAudioOutput) {
            Button("Reconnect Audio Output") {
                player.chooseAudioOutput()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current: \(player.outputDisplayName). watchOS selects the route. To select AirPods manually, use Control Center's audio output control or Settings > Bluetooth on your Watch.")
        }
    }

    private var episodeMenu: some View {
        Button {
            showEpisodeOptions = true
        } label: {
            Label("Episode options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    private var episodeOptionsPage: some View {
        List {
            Button {
                showNotes = true
            } label: {
                Label("Notes", systemImage: "text.alignleft")
            }

            if supportsChapters {
                Button {
                    showChapters = true
                } label: {
                    Label("Chapters", systemImage: "list.number")
                }
            }
            if supportsChapters || episode?.chaptersURL?.isEmpty == false {
                if isLoadingChapters {
                    ProgressView("Loading chapters")
                } else if let chapterError {
                    Text(chapterError)
                        .font(.caption2)
                    Button {
                        loadChapters(force: true)
                    } label: {
                        Label("Retry Chapters", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showNotes) {
            notesPage
                .navigationTitle("Notes")
        }
        .navigationDestination(isPresented: $showChapters) {
            chaptersPage
                .navigationTitle("Chapters")
        }
        .onAppear { loadChapters() }
    }

    private var notesPage: some View {
        ScrollView {
            Text(episode?.descriptionText.isEmpty == false
                 ? Self.renderedText(fromHTML: episode?.descriptionText ?? "")
                 : "No notes are available for this episode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    private static func renderedText(fromHTML html: String) -> String {
        var text = decodeHTMLEntities(html)
        text = text.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<(p|div|h[1-6]|blockquote)[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</(p|div|h[1-6]|blockquote)>",
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<li[^>]*>",
            with: "• ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</li>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->|<[^>]+>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]*$",
            with: "",
            options: .regularExpression
        )
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var text = value
        let namedEntities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }
        return replacingNumericEntities(in: text)
    }

    private static func replacingNumericEntities(in value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") else {
            return value
        }
        var result = value
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        for match in matches.reversed() {
            guard let matchRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let encoded = String(result[valueRange])
            let radix = encoded.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(encoded.dropFirst()) : encoded
            guard let number = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(number) else { continue }
            result.replaceSubrange(matchRange, with: String(Character(scalar)))
        }
        return result
    }

    private static func chapters(fromHTML html: String) -> [SRPodcastChapterRecord] {
        let text = renderedText(fromHTML: html)
        let patterns = [
            #"^[\[(]?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[\])]?\s*(?:[-:|]\s*)?(.+)$"#,
            #"^(.+?)\s*(?:[-:|]\s*)?[\[(]?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[\])]?$"#
        ]
        var results: [SRPodcastChapterRecord] = []
        var seenStartTimes = Set<TimeInterval>()

        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            for (patternIndex, pattern) in patterns.enumerated() {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(
                          in: value,
                          range: NSRange(value.startIndex..., in: value)
                      ) else { continue }
                let titleIndex = patternIndex == 0 ? 4 : 1
                let hourIndex = patternIndex == 0 ? 1 : 2
                let minuteIndex = patternIndex == 0 ? 2 : 3
                let secondIndex = patternIndex == 0 ? 3 : 4
                guard let titleRange = Range(match.range(at: titleIndex), in: value),
                      let minuteRange = Range(match.range(at: minuteIndex), in: value),
                      let secondRange = Range(match.range(at: secondIndex), in: value) else {
                    continue
                }
                let hours: Double
                if match.range(at: hourIndex).location != NSNotFound,
                   let range = Range(match.range(at: hourIndex), in: value) {
                    hours = Double(value[range]) ?? 0
                } else {
                    hours = 0
                }
                let minutes = Double(value[minuteRange]) ?? 0
                let seconds = Double(value[secondRange]) ?? 0
                let startTime = hours * 3_600 + minutes * 60 + seconds
                let title = value[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seenStartTimes.insert(startTime).inserted else { break }
                results.append(SRPodcastChapterRecord(title: title, startTime: startTime))
                break
            }
        }
        return results.sorted { $0.startTime < $1.startTime }
    }

    private var currentChapterID: String? {
        guard player.currentTime.isFinite else { return nil }
        return chapters
            .filter { $0.startTime.isFinite && $0.startTime >= 0 && $0.startTime <= player.currentTime }
            .max { $0.startTime < $1.startTime }?.id
    }

    @ViewBuilder
    private var chaptersPage: some View {
        if isLoadingChapters {
            ProgressView("Loading chapters")
        } else if chapters.isEmpty {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "list.number")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(chapterError == nil ? "No Chapters" : "Unable to Load Chapters")
                        .font(.headline)
                    Text(chapterError ?? "This episode has no chapter markers.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if chapterError != nil {
                        Button { loadChapters(force: true) } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .disabled(player.isBuffering)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }
        } else {
            let activeChapterID = currentChapterID
            List(chapters) { chapter in
                let isCurrent = chapter.id == activeChapterID
                Button {
                    player.seek(to: chapter.startTime)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if isCurrent {
                            Label(
                                player.isPlaying ? "Playing" : player.isBuffering ? "Loading" : "Selected",
                                systemImage: player.isPlaying ? "waveform" : player.isBuffering ? "hourglass" : "pause.fill"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.mint)
                            .playingWaveEffect(player.isPlaying)
                        }
                        Text(chapter.title)
                            .lineLimit(2)
                        Text(chapter.startTime.formattedTime)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(isCurrent ? Color.mint.opacity(0.16) : nil)
            }
        }
    }

    private var playPauseButton: some View {
        let playbackIsActive = player.isPlaybackRequested || player.isPlaying
        return Button {
            player.togglePlayback()
        } label: {
            Image(systemName: playbackIsActive ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .disabled(player.item == nil)
        .accessibilityLabel(playbackIsActive ? "Pause" : "Play")
    }
}

struct WatchArtworkView: View {
    let url: URL?
    let data: Data?
    let systemImage: String
    @State private var decodedImage: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(placeholderColor.opacity(0.28))

            if let image = decodedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        }
        .task(id: artworkLoadID) {
            decodedImage = nil
            var image: CGImage?
            if let data {
                image = await Task.detached(priority: .utility) {
                    Self.thumbnail(from: data)
                }.value
            }
            guard !Task.isCancelled else { return }
            if image == nil, let url {
                // Many rows load at once right after the first sync, so a single timeout is common.
                for attempt in 0..<3 where image == nil && !Task.isCancelled {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
                    image = await Self.loadThumbnail(from: url)
                }
            }
            guard !Task.isCancelled else { return }
            decodedImage = image
        }
    }

    // Data.hashValue only covers the length and first 80 bytes, so similar JPEG thumbnails collide.
    private var artworkLoadID: String {
        guard let data else { return "\(url?.absoluteString ?? "")|none" }
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return "\(url?.absoluteString ?? "")|\(data.count)|\(hasher.finalize())"
    }

    private static func loadThumbnail(from url: URL) async -> CGImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("StreamRadiosWatch/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/*,*/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) != false,
              data.count <= 4 * 1_024 * 1_024 else { return nil }
        return await Task.detached(priority: .utility) {
            thumbnail(from: data)
        }.value
    }

    nonisolated private static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private var placeholder: some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.9))
    }

    private var placeholderColor: Color {
        systemImage.contains("mic") ? .mint : .red
    }
}

private extension TimeInterval {
    var formattedTime: String {
        let totalSeconds = isFinite ? max(0, Int(self)) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}