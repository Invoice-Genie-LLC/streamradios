//
//  PodcastChaptersNotesView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 1/3/25.
//

import SwiftUI
import AVFoundation
import CoreData

struct PodcastChaptersNotesView: View {
    let episode: PodcastEpisode
    let feed: PodcastFeed
    @ObservedObject var podcastPlayer: PodcastPlayer
    @Binding var isPresented: Bool
    
    @State private var selectedTab = 0
	@State private var fallbackChapters: [PodcastChapter] = []
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    init(episode: PodcastEpisode, feed: PodcastFeed, podcastPlayer: PodcastPlayer, isPresented: Binding<Bool>) {
        self.episode = episode
        self.feed = feed
        self.podcastPlayer = podcastPlayer
        self._isPresented = isPresented
        // Always default to Chapters on open
        self._selectedTab = State(initialValue: 0)
        // Pre-derive chapters from notes synchronously to avoid any initial delay
        var derived: [PodcastChapter] = []
        if (episode.chapters == nil || episode.chapters?.isEmpty == true), let content = episode.notes?.content, !content.isEmpty {
            derived = parseChaptersFromContent(content)
        }
        self._fallbackChapters = State(initialValue: derived)
        if !derived.isEmpty {
            // Persist immediately so subsequent opens have chapters available
            persistFallbackChapters(derived)
        }
    }
    
    // Check if episode has chapters or notes
	private var hasChapters: Bool {
		if let chapters = episode.chapters, !chapters.isEmpty { return true }
		return !fallbackChapters.isEmpty
	}
    
    private var hasNotes: Bool {
        episode.notes?.content.isEmpty == false
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Episode header with artwork and title
                episodeHeaderView
                
                // Tab picker (only show if we have both chapters and notes)
                if hasChapters && hasNotes {
                    Picker("View", selection: $selectedTab) {
                        Text("Chapters").tag(0)
                        Text("Notes").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                
                // Content based on selected tab or available data
                ScrollView {
					if selectedTab == 0 && hasChapters {
						chaptersView
                    } else if selectedTab == 1 && hasNotes {
                        notesView
                    } else if hasChapters && !hasNotes {
                        chaptersView
                    } else if hasNotes && !hasChapters {
                        notesView
                    } else {
                        // No chapters or notes available
                        VStack(spacing: 16) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            
                            Text("No Chapters or Notes")
                                .font(.headline)
                                .foregroundColor(.gray)
                            
                            Text("This episode doesn't include chapters or show notes.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 50)
                    }
                }
            }
            .navigationTitle("Episode Details")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                trailing: Button("Done") {
                    isPresented = false
                }
            )
        }
		.onAppear {
			// Attempt to read embedded chapters from the audio asset as a background enhancement
			if (episode.chapters == nil || episode.chapters?.isEmpty == true) && self.fallbackChapters.isEmpty {
				Task { await loadChaptersFromAsset() }
			}
        }
    }
    
    // MARK: - Episode Header
    private var episodeHeaderView: some View {
        HStack(spacing: 12) {
            // Episode artwork
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 80)
                
                feedArtworkView
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Episode info
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .foregroundColor(.adaptivePrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(feed.title)
                    .font(.subheadline)
                    .foregroundColor(.adaptiveSecondaryText)
                    .lineLimit(1)
                
                // Current playback time
                if podcastPlayer.currentEpisode?.id == episode.id {
                    Text("Current: \(formatTime(podcastPlayer.currentTime))")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.adaptiveSecondaryBackground)
    }
    
    // MARK: - Chapters View
	private var chaptersView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
				let chaptersToShow = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
				if !chaptersToShow.isEmpty {
					ForEach(chaptersToShow) { chapter in
                        ChapterRowView(
                            chapter: chapter,
                            isCurrentChapter: isCurrentChapter(chapter),
                            onTap: {
                                seekToChapter(chapter)
                            }
                        )
                    }
                } else {
                    // Fallback if no chapters
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "list.number")
                            .font(.largeTitle)
                            .foregroundColor(.adaptiveSecondaryText)
                        
                        Text("No chapters available")
                            .font(.body)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
    
    // MARK: - Notes View
    private var notesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notes = episode.notes {
                    // Show notes content with rich formatting
                    if !notes.content.isEmpty {
                        FormattedNotesView(content: notes.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Fallback if no notes
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundColor(.adaptiveSecondaryText)
                        
                        Text("No show notes available")
                            .font(.body)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
    
    // MARK: - Artwork View
    @ViewBuilder
    private var feedArtworkView: some View {
        // Priority: Direct image data > Base64 icon data > default
        if let imageData = feed.imageData, !imageData.isEmpty {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else if let iconData = feed.iconData, !iconData.isEmpty {
            if let data = Data(base64Encoded: iconData), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                defaultPodcastIcon
            }
        } else {
            defaultPodcastIcon
        }
    }
    
    private var defaultPodcastIcon: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 32))
            .foregroundColor(.gray)
    }
    
    // MARK: - Helper Functions
	private func isCurrentChapter(_ chapter: PodcastChapter) -> Bool {
        guard podcastPlayer.currentEpisode?.id == episode.id else { return false }
        
        let currentTime = podcastPlayer.currentTime
        
        // Find the current chapter based on current time
		let chapters = (episode.chapters?.isEmpty == false ? episode.chapters! : fallbackChapters)
		if !chapters.isEmpty {
            for (index, chap) in chapters.enumerated() {
                let nextChapterTime = index + 1 < chapters.count ? chapters[index + 1].startTime : episode.duration
                if currentTime >= chap.startTime && currentTime < nextChapterTime {
                    return chap.id == chapter.id
                }
            }
        }
        
        return false
    }
    
    private func seekToChapter(_ chapter: PodcastChapter) {
        // Only seek if this is the currently playing episode
        guard podcastPlayer.currentEpisode?.id == episode.id else { return }
        
        podcastPlayer.seek(to: chapter.startTime)
        
        // Optionally dismiss the sheet after seeking
        // isPresented = false
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) % 3600 / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func stripHTML(_ html: String) -> String {
        // Basic HTML stripping - could be enhanced with proper HTML parsing
        return html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

	// MARK: - Fallback chapter parsing and persistence
	private func parseChaptersFromContent(_ content: String) -> [PodcastChapter] {
		// Normalize HTML into plain text lines
		var normalized = content
		let lineBreakTags = ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"]
		for tag in lineBreakTags {
			normalized = normalized.replacingOccurrences(of: tag, with: "\n", options: [.caseInsensitive])
		}
		normalized = normalized.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
		normalized = normalized
			.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
		
		let patterns = [
			#"(.+?)\s+(\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
			#"(.+?)\s+(-?\d{1,2}):(\d{2})(?:\s*$|\s*\n)"#,
			#"\[(\d{1,2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
			#"\((\d{1,2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
			#"\[(\d{1,2}):(\d{2}):(\d{2})\]\s*(.+?)(?=\n|\[|$)"#,
			#"\((\d{1,2}):(\d{2}):(\d{2})\)\s*(.+?)(?=\n|\(|$)"#,
			#"^(\d{1,2}):(\d{2})\s+(.+?)(?=\n|$)"#,
			#"^(\d{1,2}):(\d{2}):(\d{2})\s+(.+?)(?=\n|$)"#
		]
		var chapters: [PodcastChapter] = []
		for (idx, pattern) in patterns.enumerated() {
			if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) {
				let ns = normalized as NSString
				let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: ns.length))
				for m in matches {
					var start: TimeInterval = 0
					var title = ""
					if idx == 0 || idx == 1 {
						if m.numberOfRanges == 4 {
							let tR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3)
							title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
							let minutes = Double(ns.substring(with: minR)) ?? 0
							let seconds = Double(ns.substring(with: secR)) ?? 0
							start = abs(minutes * 60 + seconds)
						}
					} else if idx >= 2 && idx <= 5 {
						if m.numberOfRanges == 4 {
							let minR = m.range(at: 1), secR = m.range(at: 2), tR = m.range(at: 3)
							let minutes = Double(ns.substring(with: minR)) ?? 0
							let seconds = Double(ns.substring(with: secR)) ?? 0
							title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
							start = minutes * 60 + seconds
						} else if m.numberOfRanges == 5 {
							let hR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3), tR = m.range(at: 4)
							let hours = Double(ns.substring(with: hR)) ?? 0
							let minutes = Double(ns.substring(with: minR)) ?? 0
							let seconds = Double(ns.substring(with: secR)) ?? 0
							title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
							start = hours * 3600 + minutes * 60 + seconds
						}
					} else {
						if m.numberOfRanges == 4 {
							let minR = m.range(at: 1), secR = m.range(at: 2), tR = m.range(at: 3)
							let minutes = Double(ns.substring(with: minR)) ?? 0
							let seconds = Double(ns.substring(with: secR)) ?? 0
							title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
							start = minutes * 60 + seconds
						} else if m.numberOfRanges == 5 {
							let hR = m.range(at: 1), minR = m.range(at: 2), secR = m.range(at: 3), tR = m.range(at: 4)
							let hours = Double(ns.substring(with: hR)) ?? 0
							let minutes = Double(ns.substring(with: minR)) ?? 0
							let seconds = Double(ns.substring(with: secR)) ?? 0
							title = ns.substring(with: tR).trimmingCharacters(in: .whitespacesAndNewlines)
							start = hours * 3600 + minutes * 60 + seconds
						}
					}
					if !title.isEmpty && title.count > 2 {
						let cleaned = title.replacingOccurrences(of: "^\\d+\\.", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
						chapters.append(PodcastChapter(title: cleaned, startTime: start))
					}
				}
				if !chapters.isEmpty { break }
			}
		}
		chapters.sort { $0.startTime < $1.startTime }
		return chapters
	}

	private func persistFallbackChapters(_ chapters: [PodcastChapter]) {
		guard !chapters.isEmpty else { return }
		let context = CoreDataStack.shared.context
		context.perform {
			let request: NSFetchRequest<PodcastModel> = PodcastModel.fetchRequest()
			request.predicate = NSPredicate(format: "id == %@", episode.id)
			request.fetchLimit = 1
			if let model = try? context.fetch(request).first {
				if let data = try? JSONEncoder().encode(chapters) {
					model.chaptersData = data
					try? context.save()
				}
			}
		}
	}

	@MainActor
	private func loadChaptersFromAsset() async {
		guard let url = URL(string: episode.audioUrl) else { return }
		let asset = AVURLAsset(url: url)
		let key = "availableChapterLocales"
		do {
			try await asset.load(.availableChapterLocales)
			let locales = asset.availableChapterLocales
			guard let locale = locales.first else { return }
			let groups = asset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil)
			var parsed: [PodcastChapter] = []
			for group in groups {
				var title: String?
				for item in group.items {
					if item.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue {
						if let value = try? await item.load(.stringValue) { title = value }
					}
				}
				let timeRange = group.timeRange
				let startSeconds = CMTimeGetSeconds(timeRange.start)
				let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
				if !name.isEmpty {
					parsed.append(PodcastChapter(title: name, startTime: max(0, startSeconds)))
				}
			}
			parsed.sort { $0.startTime < $1.startTime }
			if !parsed.isEmpty {
				self.fallbackChapters = parsed
				persistFallbackChapters(parsed)
			}
		} catch {
			// Ignore if chapters not available from asset
		}
	}
}

// MARK: - Chapter Row View
struct ChapterRowView: View {
    let chapter: PodcastChapter
    let isCurrentChapter: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Chapter time
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatChapterTime(chapter.startTime))
                        .font(.caption)
                        .foregroundColor(isCurrentChapter ? .blue : .adaptiveSecondaryText)
                        .monospacedDigit()
                    
                    if isCurrentChapter {
                        Text("Current")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
                .frame(width: 60, alignment: .leading)
                
                // Chapter content
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .font(.body)
                        .foregroundColor(isCurrentChapter ? .blue : .adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let url = chapter.url {
                        Text(url)
                            .font(.caption)
                            .foregroundColor(.adaptiveSecondaryText)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Play indicator
                if isCurrentChapter {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrentChapter ? Color.blue.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCurrentChapter ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func formatChapterTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) % 3600 / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Link Row View
struct LinkRowView: View {
    let link: PodcastLink
    
    var body: some View {
        Button(action: {
            if let url = URL(string: link.url) {
                UIApplication.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(link.url)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let timeStamp = link.timeStamp {
                        Text("At \(formatLinkTime(timeStamp))")
                            .font(.caption2)
                            .foregroundColor(.adaptiveSecondaryText)
                    }
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.adaptiveSecondaryBackground)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func formatLinkTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) % 3600 / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Formatted Notes View
struct FormattedNotesView: View {
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let items = parseStructuredNotes(content)
            ForEach(items) { item in
                FormattedNoteItem(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // Parse HTML notes into headers (h1-h3), nested bullets (li), and paragraphs
    private func parseStructuredNotes(_ rawContent: String) -> [StructuredNoteItem] {
        var output: [StructuredNoteItem] = []
        let content = rawContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        let pattern = "(?is)(<h([1-3])[^>]*>(.*?)</h\\2>)|(<li[^>]*>(.*?)</li>)|(<p[^>]*>(.*?)</p>)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return fallbackLineSplit(content)
        }
        let ns = content as NSString
        
        // Utility to compute nesting level from surrounding lists
        func nestingLevel(before index: Int) -> Int {
            let before = ns.substring(to: index).lowercased()
            let opens = (before.components(separatedBy: "<ul").count - 1) + (before.components(separatedBy: "<ol").count - 1)
            let closes = (before.components(separatedBy: "</ul>").count - 1) + (before.components(separatedBy: "</ol>").count - 1)
            return max(0, opens - closes)
        }
        
        regex.enumerateMatches(in: content, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match else { return }
            // Header
            if m.range(at: 1).location != NSNotFound {
                let levelStr = ns.substring(with: m.range(at: 2))
                let inner = ns.substring(with: m.range(at: 3))
                let clean = cleanHTML(inner)
                let lvl = Int(levelStr) ?? 2
                output.append(StructuredNoteItem(kind: .header(level: lvl), level: 0, textHTML: inner, cleanText: clean))
                return
            }
            // Bullet
            if m.range(at: 4).location != NSNotFound {
                let inner = ns.substring(with: m.range(at: 5))
                let clean = cleanHTML(inner)
                let lvl = max(1, nestingLevel(before: m.range.location))
                output.append(StructuredNoteItem(kind: .bullet, level: lvl, textHTML: inner, cleanText: clean))
                return
            }
            // Paragraph
            if m.range(at: 6).location != NSNotFound {
                let inner = ns.substring(with: m.range(at: 7))
                let clean = cleanHTML(inner)
                if !clean.isEmpty {
                    output.append(StructuredNoteItem(kind: .paragraph, level: 0, textHTML: inner, cleanText: clean))
                }
            }
        }
        
        if output.isEmpty { return fallbackLineSplit(content) }
        return output
    }
    
    private func cleanHTML(_ html: String) -> String {
        return html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func fallbackLineSplit(_ content: String) -> [StructuredNoteItem] {
        let lines = content.components(separatedBy: .newlines)
        var out: [StructuredNoteItem] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("*") {
                let text = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                out.append(StructuredNoteItem(kind: .bullet, level: 1, textHTML: text, cleanText: cleanHTML(text)))
            } else {
                out.append(StructuredNoteItem(kind: .paragraph, level: 0, textHTML: t, cleanText: cleanHTML(t)))
            }
        }
        return out
    }
}

struct StructuredNoteItem: Identifiable {
    enum Kind { case header(level: Int), bullet, paragraph }
    let id = UUID()
    let kind: Kind
    let level: Int
    let textHTML: String
    let cleanText: String
}

struct FormattedNoteItem: View {
    let item: StructuredNoteItem
    
    var body: some View {
        switch item.kind {
        case .header(let level):
            FormattedTextView(htmlContent: item.textHTML)
                .font(fontForHeader(level))
                .foregroundColor(.adaptivePrimaryText)
                .padding(.top, 10)
                .padding(.bottom, 2)
        case .bullet:
            HStack(alignment: .top, spacing: 10) {
                BulletView(level: item.level)
                    .padding(.top, 6)
                FormattedTextView(htmlContent: item.textHTML)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(max(0, item.level - 1)) * 18)
            .padding(.vertical, 2)
        case .paragraph:
            FormattedTextView(htmlContent: item.textHTML)
                .foregroundColor(.adaptivePrimaryText)
                .padding(.vertical, 2)
        }
    }
    
    private func fontForHeader(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
    
    private func bulletSymbol(for level: Int) -> String {
        switch level {
        case 1: return "•"
        case 2: return "◦"
        case 3: return "▪︎"
        default: return "–"
        }
    }
}

struct FormattedTextView: View {
    let htmlContent: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let components = parseHTMLLinks(htmlContent)
            
            // Render mixed text and links inline with natural wrapping
            InlineAttributedTextView(components: components)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func parseHTMLLinks(_ html: String) -> [TextComponent] {
        var components: [TextComponent] = []
        
        // Regex to find <a href="url">text</a> patterns
        let pattern = #"<a\s+[^>]*href=["\']([^"\']+)["\'][^>]*>([^<]+)</a>"#
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsString = html as NSString
            let results = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            var lastLocation = 0
            
            for result in results {
                // Add text before the link
                if result.range.location > lastLocation {
                    let beforeText = nsString.substring(with: NSRange(location: lastLocation, length: result.range.location - lastLocation))
                    let cleanText = cleanHTMLText(beforeText)
                    if !cleanText.isEmpty {
                        components.append(TextComponent(text: cleanText, isLink: false, url: nil))
                    }
                }
                
                // Add the link
                if result.numberOfRanges >= 3 {
                    let urlRange = result.range(at: 1)
                    let textRange = result.range(at: 2)
                    
                    if urlRange.location != NSNotFound && textRange.location != NSNotFound {
                        let url = nsString.substring(with: urlRange)
                        let rawLinkText = nsString.substring(with: textRange)
                        let linkText = cleanHTMLText(rawLinkText)
                        components.append(TextComponent(text: linkText, isLink: true, url: url))
                    }
                }
                
                lastLocation = NSMaxRange(result.range)
            }
            
            // Add remaining text
            if lastLocation < nsString.length {
                let remainingText = nsString.substring(from: lastLocation)
                let cleanText = cleanHTMLText(remainingText)
                if !cleanText.isEmpty {
                    components.append(TextComponent(text: cleanText, isLink: false, url: nil))
                }
            }
            
            // If no links found, return the whole text as a single component
            if components.isEmpty {
                let cleanText = cleanHTMLText(html)
                if !cleanText.isEmpty {
                    components.append(TextComponent(text: cleanText, isLink: false, url: nil))
                }
            }
            
        } catch {
            // Fallback to plain text if regex fails
            let cleanText = cleanHTMLText(html)
            components.append(TextComponent(text: cleanText, isLink: false, url: nil))
        }
        
        return components
    }
    
    private func cleanHTMLText(_ html: String) -> String {
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeNumericHTMLEntities(in: stripped)
    }

    private func decodeNumericHTMLEntities(in text: String) -> String {
        let pattern = "&#(\\d+);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        var result = text
        // Replace from end to start to keep ranges valid
        for match in matches.reversed() {
            if match.numberOfRanges == 2 {
                let numRange = match.range(at: 1)
                let numString = nsString.substring(with: numRange)
                if let code = Int(numString), let scalar = UnicodeScalar(code) {
                    let char = String(scalar)
                    let fullRange = match.range(at: 0)
                    if let swiftRange = Range(fullRange, in: result) {
                        result.replaceSubrange(swiftRange, with: char)
                    }
                }
            }
        }
        return result
    }
}

struct TextComponent {
    let text: String
    let isLink: Bool
    let url: String?
}

struct FlowTextView: View {
    let components: [TextComponent]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if component.isLink, let url = component.url {
                    Button(action: {
                        if let validURL = URL(string: url) {
                            UIApplication.shared.open(validURL)
                        }
                    }) {
                        Text(component.text)
                            .font(.body)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text(component.text)
                        .font(.body)
                        .foregroundColor(.adaptivePrimaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bullet View for Notes
struct BulletView: View {
    let level: Int
    
    var body: some View {
        let size: CGFloat = level == 1 ? 6 : (level == 2 ? 5 : 4)
        let color: Color = level == 1 ? .blue : .adaptivePrimaryText.opacity(0.7)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Inline Attributed Text View
struct InlineAttributedTextView: View {
    let components: [TextComponent]
    
    var body: some View {
        Text(makeAttributedString())
            .font(.body)
            .foregroundColor(.adaptivePrimaryText)
            .textSelection(.enabled)
    }
    
    private func makeAttributedString() -> AttributedString {
        var out = AttributedString()
        func collapseSpaces(_ s: String) -> String {
            let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return collapsed
        }
        func needsSpaceBeforeAppending(to current: AttributedString) -> Bool {
            guard let last = current.characters.last else { return false }
            return !last.isWhitespace
        }
        func firstChar(of text: String) -> Character? { text.first }
        func isNoLeadingSpacePunctuation(_ c: Character) -> Bool {
            return ",[\\].:;!?)}]".contains(c)
        }
        let count = components.count
        for (idx, component) in components.enumerated() {
            let isLast = idx == count - 1
            // Normalize interior spaces of this segment
            var cleanText = collapseSpaces(component.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if component.isLink, let urlString = component.url, let url = URL(string: urlString) {
                // Single space before link if needed
                if needsSpaceBeforeAppending(to: out) { out.append(AttributedString(" ")) }
                var seg = AttributedString(cleanText)
                seg.link = url
                seg.foregroundColor = .blue
                seg.underlineStyle = .single
                out.append(seg)
                // Add one space after link unless followed by punctuation that shouldn't have a leading space
                if !isLast {
                    let next = components[idx + 1]
                    let nextFirst = firstChar(of: next.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let nf = nextFirst, isNoLeadingSpacePunctuation(nf) {
                        // No trailing space before punctuation
                    } else {
                        out.append(AttributedString(" "))
                    }
                }
            } else {
                // Non-link text: avoid double-spacing across boundaries
                if let last = out.characters.last, last.isWhitespace {
                    cleanText = cleanText.trimmingCharacters(in: .whitespaces)
                }
                out.append(AttributedString(cleanText))
            }
        }
        // Trim trailing whitespace
        while let last = out.characters.last, last.isWhitespace { _ = out.characters.popLast() }
        return out
    }
}

#Preview {
    // Sample data for preview
    let sampleChapters = [
        PodcastChapter(title: "Introduction", startTime: 0),
        PodcastChapter(title: "Main Topic Discussion", startTime: 300),
        PodcastChapter(title: "Q&A Session", startTime: 1200),
        PodcastChapter(title: "Closing Thoughts", startTime: 1800)
    ]
    
    let sampleLinks = [
        PodcastLink(title: "Apple's Website", url: "https://apple.com"),
        PodcastLink(title: "Referenced Article", url: "https://example.com/article", timeStamp: 450)
    ]
    
    let sampleNotes = PodcastNotes(
        content: "In this episode, we discuss various topics including Apple's latest updates and industry trends. Check out the links below for more information.",
        links: sampleLinks
    )
    
    let sampleEpisode = PodcastEpisode(
        title: "Hip Hop On Top 09/08/2025 - Part 2",
        descriptionText: "Sample episode description",
        audioUrl: "https://example.com/audio.mp3",
        publicationDate: Date(),
        duration: 2100,
        state: EpisodeState(isPlayed: false, isFavorite: false, progress: 0.3, isDownloaded: false),
        feedId: "sample-feed",
        chapters: sampleChapters,
        notes: sampleNotes
    )
    
    let sampleFeed = PodcastFeed(
        id: "sample-feed",
        title: "Top Albania Radio",
        url: "https://example.com/feed",
        artworkUrl: nil,
        description: "Sample podcast feed"
    )
    
    @State var isPresented = true
    
    PodcastChaptersNotesView(
        episode: sampleEpisode,
        feed: sampleFeed,
        podcastPlayer: PodcastPlayer.shared,
        isPresented: $isPresented
    )
}
