//
//  ChapterParser.swift
//  StreamRadios
//
//  Created by Assistant on 8/13/25.
//

import Foundation

struct ChapterParser {
    static func parseChaptersFromNotes(_ content: String) -> [PodcastChapter] {
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
}






