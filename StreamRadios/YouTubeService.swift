//
//  YouTubeService.swift
//  StreamRadios
//
//  YouTube API integration for searching songs
//

import Foundation
import UIKit

// YouTube video metadata
struct YouTubeVideo {
    let videoId: String
    let title: String?
    let description: String?
    let viewCount: String?
    let likeCount: String?
    let publishDate: String?
    let channelName: String?
}

class YouTubeService {
    static let shared = YouTubeService()
    
    /// Scrape YouTube search results to get first video ID (no API needed)
    /// - Parameters:
    ///   - songTitle: The title of the song
    ///   - artist: The artist name
    ///   - completion: Completion handler with video ID
    func searchSong(title: String, artist: String, completion: @escaping (String?) -> Void) {
        // Try multiple search query variations for better results
        let searchQueries = [
            "\(artist) \(title) official music video",  // Most specific
            "\(artist) \(title) official",              // Common format
            "\(title) \(artist)",                       // Reverse order
            "\(artist) \(title)"                        // Basic search
        ]
        
        print("🔍 YouTube: Searching for '\(title)' by '\(artist)'")
        
        // Try each search query until we find a good match
        searchWithQueries(queries: searchQueries, title: title, artist: artist, completion: completion)
    }
    
    /// Try multiple search queries and pick the best result
    private func searchWithQueries(queries: [String], title: String, artist: String, completion: @escaping (String?) -> Void) {
        guard !queries.isEmpty else {
            completion(nil)
            return
        }
        
        let searchQuery = queries[0]
        
        guard let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)") else {
            print("❌ YouTube: Failed to create search URL")
            completion(nil)
            return
        }
        
        print("🔍 YouTube: Trying query '\(searchQuery)'")
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                print("❌ YouTube: Failed to fetch search results")
                completion(nil)
                return
            }
            
            print("📄 YouTube: Received \(html.count) characters of HTML")
            
            // PRIORITY 1: Extract multiple videos from search results and verify each
            let videoIds = self.extractMultipleVideosFromYtInitialData(html: html)
            if !videoIds.isEmpty {
                print("🔍 YouTube: Found \(videoIds.count) potential videos in search results")
                
                // Check each video until we find a good match
                for (index, videoId) in videoIds.prefix(5).enumerated() {
                    if let matchResult = self.verifyVideoMatchWithTitle(html: html, videoId: videoId, title: title, artist: artist) {
                        if matchResult.isGoodMatch {
                            print("✅ YouTube: Found matching video '\(videoId)' (checked \(index + 1) videos)")
                            DispatchQueue.main.async {
                                completion(videoId)
                            }
                            return
                        } else {
                            print("⏭️ YouTube: Video \(index + 1) '\(matchResult.videoTitle ?? "unknown")' doesn't match, checking next...")
                        }
                    }
                }
                print("⚠️ YouTube: Checked \(min(5, videoIds.count)) videos, none matched well enough")
            } else {
                print("⚠️ YouTube: No videos found in ytInitialData")
            }
            
            // PRIORITY 2: Search entire HTML for ANY videoId pattern
            print("🔍 YouTube: Trying comprehensive HTML search...")
            let patterns = [
                "\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\"",  // Most common JSON format
                "\"videoRenderer\".*?\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\"", // Renderer object
                "\\/watch\\?v=([a-zA-Z0-9_-]{11})",              // URL with slash
                "watch\\?v=([a-zA-Z0-9_-]{11})",                 // URL without slash
                "\"videoId\":\"([a-zA-Z0-9_-]{11})\"",           // Compact JSON
                "v=([a-zA-Z0-9_-]{11})",                         // Query param
                "\\/vi\\/([a-zA-Z0-9_-]{11})",                   // Thumbnail path
                "videoid=([a-zA-Z0-9_-]{11})",                   // Alternative param
            ]
            
            // Try each pattern on the entire HTML
            for (index, pattern) in patterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    let videoId = String(html[range])
                    
                    // Strict validation: exactly 11 chars, alphanumeric + _ and -
                    if videoId.count == 11 && videoId.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil {
                        print("✅ YouTube: Found video '\(videoId)' using pattern \(index + 1): \(pattern)")
                        DispatchQueue.main.async {
                            completion(videoId)
                        }
                        return
                    }
                }
            }
            
            // PRIORITY 3: Try to extract from ANY JSON-like structure
            print("🔍 YouTube: Trying broad JSON extraction...")
            if let videoId = self.extractAnyVideoIdFromJSON(html: html) {
                print("✅ YouTube: Found video '\(videoId)' from broad JSON search")
                DispatchQueue.main.async {
                    completion(videoId)
                }
                return
            }
            
            print("⚠️ YouTube: No video found with query '\(searchQuery)'")
            
            // Try next query variation
            let remainingQueries = Array(queries.dropFirst())
            if !remainingQueries.isEmpty {
                print("🔄 YouTube: Trying next search variation...")
                DispatchQueue.main.async {
                    self.searchWithQueries(queries: remainingQueries, title: title, artist: artist, completion: completion)
                }
            } else {
                print("❌ YouTube: All search queries exhausted")
                // LAST RESORT: Return search query (will open search page)
                DispatchQueue.main.async {
                    completion("SEARCH:\(artist) \(title)")
                }
            }
        }.resume()
    }
    
    /// Extract first video ID from YouTube's embedded data
    /// YouTube embeds search results in JavaScript variables
    /// - Parameter html: The HTML content
    /// - Returns: First video ID found, or nil
    private func extractFromYtInitialData(html: String) -> String? {
        // YouTube uses various variable names for embedded data
        let markers = [
            "window.WIZ_global_data",
            "var ytInitialData",
            "window[\"ytInitialData\"]",
            "ytInitialData",
            "window.ytInitialPlayerResponse"
        ]
        
        // Try each marker
        for marker in markers {
            if let markerRange = html.range(of: marker) {
                print("✅ YouTube: Found marker '\(marker)'")
                
                // Get a large section after the marker
                let startIndex = markerRange.upperBound
                let searchLength = min(50000, html.distance(from: startIndex, to: html.endIndex))
                let endIndex = html.index(startIndex, offsetBy: searchLength)
                let searchSection = String(html[startIndex..<endIndex])
                
                // Print sample of what's after the marker
                let sampleText = String(searchSection.prefix(500))
                print("📝 YouTube: Sample after '\(marker)': \(sampleText)")
                
                // Decode hex-encoded strings like '\x7b\x22...'
                var decodedSection = searchSection
                if searchSection.contains("\\x") {
                    // Convert hex-encoded JSON to regular string
                    let pattern = "\\\\x([0-9a-fA-F]{2})"
                    if let hexRegex = try? NSRegularExpression(pattern: pattern, options: []) {
                        var result = searchSection
                        let matches = hexRegex.matches(in: searchSection, options: [], range: NSRange(searchSection.startIndex..., in: searchSection))
                        
                        // Process matches in reverse to maintain indices
                        for match in matches.reversed() {
                            if let hexRange = Range(match.range(at: 1), in: searchSection),
                               let fullRange = Range(match.range(at: 0), in: searchSection) {
                                let hexString = String(searchSection[hexRange])
                                if let hexValue = UInt8(hexString, radix: 16) {
                                    let char = String(UnicodeScalar(hexValue))
                                    result.replaceSubrange(fullRange, with: char)
                                }
                            }
                        }
                        decodedSection = result
                        print("🔓 YouTube: Decoded hex-encoded data")
                    }
                }
                
                // Look for videoId pattern in decoded data
                let pattern = "\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\""
                
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: decodedSection, options: [], range: NSRange(decodedSection.startIndex..., in: decodedSection)),
                   let range = Range(match.range(at: 1), in: decodedSection) {
                    let videoId = String(decodedSection[range])
                    
                    // Strict validation: must be exactly 11 chars and not contain invalid patterns
                    let invalidPatterns = ["-thumbnail-", "-default-", "align-items", "inline-flex"]
                    if videoId.count == 11 && !invalidPatterns.contains(where: { videoId.contains($0) }) {
                        // Further validation: must start and end with alphanumeric
                        if let first = videoId.first, let last = videoId.last,
                           first.isLetter || first.isNumber,
                           last.isLetter || last.isNumber {
                            print("🎯 YouTube: Extracted '\(videoId)' from section after '\(marker)'")
                            return videoId
                        }
                    }
                } else {
                    print("⚠️ YouTube: No videoId pattern found in section after '\(marker)'")
                }
            }
        }
        
        // FALLBACK: Search the entire HTML with multiple patterns
        print("⚠️ YouTube: Standard markers not found, trying aggressive search...")
        
        // Save a sample of HTML for debugging
        let sampleLength = min(20000, html.count)
        let htmlSample = String(html.prefix(sampleLength))
        print("📝 YouTube: HTML sample saved (\(sampleLength) chars)")
        
        // Try multiple patterns - YouTube uses different formats
        let patterns = [
            "\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\"",  // JSON: "videoId":"..."
            "watch\\?v=([a-zA-Z0-9_-]{11})",                // URL: watch?v=... (most common)
            "\\/watch\\?v=([a-zA-Z0-9_-]{11})",             // URL: /watch?v=...
            "\"v\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\"",        // JSON: "v":"..."
            "&v=([a-zA-Z0-9_-]{11})",                       // Query: &v=...
            "videoId=([a-zA-Z0-9_-]{11})",                  // Param: videoId=...
            "\\/vi\\/([a-zA-Z0-9_-]{11})\\/",               // Thumbnail: /vi/.../
            "\"watchEndpoint\".*?\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\"", // watchEndpoint
            // Ultra-aggressive: any 11 alphanumeric chars after common video markers
            "video[^a-zA-Z0-9_-]{0,20}([a-zA-Z0-9_-]{11})",
            "watch[^a-zA-Z0-9_-]{0,20}([a-zA-Z0-9_-]{11})"
        ]
        
        var totalChecked = 0
        for (index, pattern) in patterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                
                if matches.count > 0 {
                    print("🔍 YouTube: Pattern \(index+1) found \(matches.count) matches")
                }
                
                // Check first 50 matches for valid video IDs (skip Shorts)
                var checkedInPattern = 0
                var skippedShorts = 0
                
                for match in matches.prefix(50) {
                    if let range = Range(match.range(at: 1), in: html) {
                        let videoId = String(html[range])
                        if videoId.count == 11 {
                            checkedInPattern += 1
                            totalChecked += 1
                            
                            // Strict validation: reject invalid patterns
                            let invalidPatterns = ["-thumbnail-", "-default-", "align-items", "inline-flex", "-hqdefault", "-mqdefault"]
                            if invalidPatterns.contains(where: { videoId.lowercased().contains($0) }) {
                                if checkedInPattern <= 3 {
                                    print("⏭️ YouTube: Skipping invalid ID '\(videoId)'")
                                }
                                continue
                            }
                            
                            // Must start and end with alphanumeric
                            guard let first = videoId.first, let last = videoId.last,
                                  first.isLetter || first.isNumber,
                                  last.isLetter || last.isNumber else {
                                continue
                            }
                            
                            // Check context around the video ID to filter out Shorts
                            let matchLocation = html.distance(from: html.startIndex, to: range.lowerBound)
                            let contextStart = max(0, matchLocation - 200)
                            let contextEnd = min(html.count, matchLocation + 200)
                            
                            let startIdx = html.index(html.startIndex, offsetBy: contextStart)
                            let endIdx = html.index(html.startIndex, offsetBy: contextEnd)
                            let context = String(html[startIdx..<endIdx]).lowercased()
                            
                            // Skip if this is a Shorts video
                            if context.contains("/shorts/") || context.contains("\"shorts\"") {
                                skippedShorts += 1
                                if skippedShorts <= 3 {
                                    print("⏭️ YouTube: Skipping Shorts video '\(videoId)' (context: \(String(context.prefix(100)))...)")
                                }
                                continue
                            }
                            
                            print("🎯 YouTube: Found regular video '\(videoId)' via pattern \(index+1)")
                            print("📊 Total checked: \(totalChecked), Total Shorts skipped: \(skippedShorts)")
                            return videoId
                        }
                    }
                }
                
                if checkedInPattern > 0 {
                    print("   Pattern \(index+1): Checked \(checkedInPattern) IDs, skipped \(skippedShorts) Shorts")
                }
            }
        }
        
        print("📊 YouTube: Total video IDs checked: \(totalChecked), all were Shorts or invalid")
        
        print("⚠️ YouTube: No videoId found in any section")
        return nil
    }
    
    /// Extract ANY video ID from JSON-like structures in HTML (broad search)
    /// - Parameter html: The HTML content
    /// - Returns: First valid video ID found, or nil
    private func extractAnyVideoIdFromJSON(html: String) -> String? {
        // Blacklist of common false positives (CSS properties, JavaScript keywords, etc.)
        let blacklist = [
            "align-items", "flex-start", "inline-flex", "sans-serif",
            "font-weight", "line-height", "text-align", "white-space",
            "border-none", "outline-none", "user-select", "webkit-tap",
            "font-family", "font-smooth", "break-words", "break-all"
        ]
        
        // Find all potential 11-character IDs that look like YouTube video IDs
        let pattern = "[a-zA-Z0-9_-]{11}"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        let matchCount = matches.count
        let limitedMatches = matches.prefix(500) // Only check first 500 to prevent timeout
        print("🔍 YouTube: Found \(matchCount) potential 11-char IDs in HTML (checking first 500)")
        
        // Check each potential ID - look for ones near video-related keywords
        for match in limitedMatches {
            if let range = Range(match.range, in: html) {
                let potentialId = String(html[range])
                
                // Skip blacklisted strings
                if blacklist.contains(potentialId.lowercased()) {
                    continue
                }
                
                // Skip if it contains only repeated characters or looks like CSS
                if Set(potentialId).count < 3 {
                    continue
                }
                
                // Get context around this ID (300 chars before and after for better analysis)
                let startOffset = max(0, html.distance(from: html.startIndex, to: range.lowerBound) - 300)
                let endOffset = min(html.count, html.distance(from: html.startIndex, to: range.upperBound) + 300)
                
                let contextStart = html.index(html.startIndex, offsetBy: startOffset)
                let contextEnd = html.index(html.startIndex, offsetBy: endOffset)
                let context = String(html[contextStart..<contextEnd])
                
                // STRONG indicators this is a video ID (check for exact patterns)
                let strongPatterns = [
                    "\"videoId\":\\s*\"\(potentialId)\"",
                    "watch\\?v=\(potentialId)",
                    "/vi/\(potentialId)",
                    "\"id\":\\s*\"\(potentialId)\""
                ]
                
                for pattern in strongPatterns {
                    if context.range(of: pattern, options: .regularExpression) != nil {
                        print("🎯 YouTube: Found video ID '\(potentialId)' with strong pattern match")
                        return potentialId
                    }
                }
            }
        }
        
        print("⚠️ YouTube: No valid video IDs found in contextual search")
        return nil
    }
    
    /// Extract multiple video IDs from YouTube search results
    /// - Parameter html: The HTML content
    /// - Returns: Array of video IDs found
    private func extractMultipleVideosFromYtInitialData(html: String) -> [String] {
        var videoIds: [String] = []
        
        // Find the ytInitialData section first
        let markers = ["var ytInitialData", "window[\"ytInitialData\"]", "ytInitialData"]
        var searchSection = html
        
        for marker in markers {
            if let markerRange = html.range(of: marker) {
                let startIndex = markerRange.upperBound
                let searchLength = min(100000, html.distance(from: startIndex, to: html.endIndex))
                let endIndex = html.index(startIndex, offsetBy: searchLength)
                searchSection = String(html[startIndex..<endIndex])
                break
            }
        }
        
        // Decode hex-encoded strings if present
        var decodedSection = searchSection
        if searchSection.contains("\\x") {
            let pattern = "\\\\x([0-9a-fA-F]{2})"
            if let hexRegex = try? NSRegularExpression(pattern: pattern, options: []) {
                var result = searchSection
                let matches = hexRegex.matches(in: searchSection, options: [], range: NSRange(searchSection.startIndex..., in: searchSection))
                
                for match in matches.reversed() {
                    if let hexRange = Range(match.range(at: 1), in: searchSection),
                       let fullRange = Range(match.range(at: 0), in: searchSection) {
                        let hexString = String(searchSection[hexRange])
                        if let hexValue = UInt8(hexString, radix: 16) {
                            let char = String(UnicodeScalar(hexValue))
                            result.replaceSubrange(fullRange, with: char)
                        }
                    }
                }
                decodedSection = result
            }
        }
        
        // Extract all videoId occurrences
        let pattern = "\"videoId\"\\s*:\\s*\"([a-zA-Z0-9_-]{11})\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let matches = regex.matches(in: decodedSection, range: NSRange(decodedSection.startIndex..., in: decodedSection))
        
        for match in matches {
            if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: decodedSection) {
                let videoId = String(decodedSection[range])
                
                // Validate and avoid duplicates
                if videoId.count == 11 && !videoIds.contains(videoId) {
                    // Skip invalid patterns
                    let invalidPatterns = ["-thumbnail-", "-default-", "align-items", "inline-flex"]
                    if !invalidPatterns.contains(where: { videoId.lowercased().contains($0) }) {
                        // Validate starts and ends with alphanumeric
                        if let first = videoId.first, let last = videoId.last,
                           (first.isLetter || first.isNumber),
                           (last.isLetter || last.isNumber) {
                            videoIds.append(videoId)
                        }
                    }
                }
            }
        }
        
        return videoIds
    }
    
    /// Match result with title information
    struct VideoMatchResult {
        let videoTitle: String?
        let isGoodMatch: Bool
    }
    
    /// Verify if a specific video matches the song by extracting its title from the HTML
    /// - Parameters:
    ///   - html: The HTML content
    ///   - videoId: The specific video ID to check
    ///   - title: Song title to match
    ///   - artist: Artist name to match
    /// - Returns: Match result with title and match status
    private func verifyVideoMatchWithTitle(html: String, videoId: String, title: String, artist: String) -> VideoMatchResult? {
        // Decode hex-encoded HTML first (same as extraction method)
        var decodedHtml = html
        if html.contains("\\x") {
            let pattern = "\\\\x([0-9a-fA-F]{2})"
            if let hexRegex = try? NSRegularExpression(pattern: pattern, options: []) {
                var result = html
                let matches = hexRegex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                
                for match in matches.reversed() {
                    if let hexRange = Range(match.range(at: 1), in: html),
                       let fullRange = Range(match.range(at: 0), in: html) {
                        let hexString = String(html[hexRange])
                        if let hexValue = UInt8(hexString, radix: 16) {
                            let char = String(UnicodeScalar(hexValue))
                            result.replaceSubrange(fullRange, with: char)
                        }
                    }
                }
                decodedHtml = result
            }
        }
        
        // Find the video title near this specific videoId in decoded HTML
        guard let videoIdRange = decodedHtml.range(of: "\"videoId\":\"\(videoId)\"") else {
            print("   ⚠️ Could not find videoId '\(videoId)' in HTML")
            return nil
        }
        
        // Get larger context around the videoId (title can be far before the videoId)
        let startOffset = max(0, decodedHtml.distance(from: decodedHtml.startIndex, to: videoIdRange.lowerBound) - 2000)
        let endOffset = min(decodedHtml.count, decodedHtml.distance(from: decodedHtml.startIndex, to: videoIdRange.upperBound) + 1000)
        
        let contextStart = decodedHtml.index(decodedHtml.startIndex, offsetBy: startOffset)
        let contextEnd = decodedHtml.index(decodedHtml.startIndex, offsetBy: endOffset)
        let context = String(decodedHtml[contextStart..<contextEnd])
        
        print("   🔎 Context length: \(context.count) chars for videoId '\(videoId)'")
        
        // Extract title from this context - YouTube search uses "headline", not "title"
        let titlePatterns = [
            "\"headline\":\\{\"runs\":\\[\\{\"text\":\"([^\"]{5,200})\"",  // YouTube search results
            "\"title\":\\{\"runs\":\\[\\{\"text\":\"([^\"]{5,200})\"",     // Video watch page
            "\"title\":\\{\"simpleText\":\"([^\"]{5,200})\"",
            "\"headline\":\\{\"accessibility\":\\{\"accessibilityData\":\\{\"label\":\"([^\"]{5,200})\"",
            "\"title\":\\{\"accessibility\":\\{\"accessibilityData\":\\{\"label\":\"([^\"]{5,200})\"",
        ]
        
        var videoTitle: String?
        for (index, pattern) in titlePatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)) {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: context) {
                    let extracted = String(context[range])
                    // Decode hex and unicode escapes
                    let decoded = extracted
                        .replacingOccurrences(of: "\\x22", with: "\"")
                        .replacingOccurrences(of: "\\x27", with: "'")
                        .replacingOccurrences(of: "\\u0026", with: "&")
                        .replacingOccurrences(of: "\\u0027", with: "'")
                        .replacingOccurrences(of: "`", with: "'")
                    if decoded.count >= 5 && decoded.count < 200 {
                        print("   ✅ Pattern \(index + 1) matched: '\(decoded.prefix(50))'")
                        videoTitle = decoded
                        break
                    }
                }
            }
        }
        
        guard let extractedTitle = videoTitle else {
            print("   ⚠️ Could not extract title for videoId '\(videoId)' - no pattern matched")
            return VideoMatchResult(videoTitle: nil, isGoodMatch: false)
        }
        
        // Reject Mix videos - they aggregate multiple songs
        let lowerTitle = extractedTitle.lowercased()
        if lowerTitle.starts(with: "mix -") || lowerTitle.contains("- mix") || lowerTitle.contains("mix playlist") {
            print("   ⏭️ Rejecting Mix/Playlist video: '\(extractedTitle.prefix(60))'")
            return VideoMatchResult(videoTitle: extractedTitle, isGoodMatch: false)
        }
        
        // Check match quality
        let extractedTitleLower = extractedTitle.lowercased()
        let songTitleLower = title.lowercased()
        let artistLower = artist.lowercased()
        
        let songWords = songTitleLower.split(separator: " ").filter { $0.count > 2 }
        let artistWords = artistLower.split(separator: " ").filter { $0.count > 2 }
        
        let songWordMatches = songWords.filter { extractedTitleLower.contains($0) }.count
        let artistWordMatches = artistWords.filter { extractedTitleLower.contains($0) }.count
        
        let songMatchRatio = songWords.isEmpty ? 1.0 : Double(songWordMatches) / Double(songWords.count)
        let hasArtistMatch = artistWordMatches > 0 || artistWords.isEmpty
        
        let isGoodMatch = songMatchRatio >= 0.5 && hasArtistMatch
        
        print("   🔍 '\(extractedTitle.prefix(60))' - Song: \(Int(songMatchRatio * 100))%, Artist: \(hasArtistMatch ? "✓" : "✗") = \(isGoodMatch ? "✅" : "❌")")
        if !isGoodMatch {
            print("      Expected: '\(title)' by '\(artist)'")
        }
        
        return VideoMatchResult(videoTitle: extractedTitle, isGoodMatch: isGoodMatch)
    }
    
    /// Verify if the video title in HTML matches the song title and artist
    /// - Parameters:
    ///   - html: The HTML content
    ///   - title: Song title to match
    ///   - artist: Artist name to match
    /// - Returns: True if video appears to match the song
    private func verifyVideoMatch(html: String, title: String, artist: String) -> Bool {
        // Extract video title from HTML - search results have specific structure
        let titlePatterns = [
            // Search results specific patterns (most common)
            "\"videoRenderer\".*?\"title\".*?\"runs\".*?\"text\":\"([^\"]{10,200})\"",
            "\"videoRenderer\".*?\"title\":\\{\"runs\":\\[\\{\"text\":\"([^\"]+)\"",
            "\"title\":\\{\"accessibility\":\\{\"accessibilityData\":\\{\"label\":\"([^\"]+)\"",
            
            // Decoded hex patterns
            "\\\\x22text\\\\x22:\\\\x22([^\\\\]{10,200})\\\\x22",
            
            // General patterns
            "\"title\":\\{\"simpleText\":\"([^\"]+)\"",
            "\"title\":\"([^\"]{10,200})\"",
        ]
        
        var videoTitle: String?
        for pattern in titlePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) {
                    let extracted = String(html[range])
                    // Decode hex escapes if present
                    let decoded = extracted.replacingOccurrences(of: "\\x22", with: "\"")
                        .replacingOccurrences(of: "\\x27", with: "'")
                    if decoded.count >= 10 && decoded.count < 200 {
                        videoTitle = decoded
                        print("🎯 YouTube: Extracted video title: '\(decoded)'")
                        break
                    }
                }
            }
        }
        
        guard let extractedTitle = videoTitle?.lowercased() else {
            // If we can't extract title, DON'T proceed - try next query
            print("⚠️ YouTube: Could not extract video title for verification, trying next query")
            return false
        }
        
        let songTitleLower = title.lowercased()
        let artistLower = artist.lowercased()
        
        // Check if video title contains significant parts of the song title
        let songWords = songTitleLower.split(separator: " ").filter { $0.count > 2 } // Filter out short words
        let artistWords = artistLower.split(separator: " ").filter { $0.count > 2 }
        
        // Count how many words from song title are in video title
        let songWordMatches = songWords.filter { extractedTitle.contains($0) }.count
        let artistWordMatches = artistWords.filter { extractedTitle.contains($0) }.count
        
        // Consider it a good match if at least 50% of song words and some artist words match
        let songMatchRatio = songWords.isEmpty ? 1.0 : Double(songWordMatches) / Double(songWords.count)
        let hasArtistMatch = artistWordMatches > 0 || artistWords.isEmpty
        
        let isGoodMatch = songMatchRatio >= 0.5 && hasArtistMatch
        
        print("🔍 YouTube: Video title '\(extractedTitle.prefix(50))...'")
        print("   Song match: \(songWordMatches)/\(songWords.count) words (\(Int(songMatchRatio * 100))%)")
        print("   Artist match: \(hasArtistMatch ? "✓" : "✗")")
        print("   Result: \(isGoodMatch ? "✅ Good match" : "❌ Poor match")")
        
        return isGoodMatch
    }
    
    /// Generate YouTube embed URL from video ID
    /// - Parameter videoId: The YouTube video ID
    /// - Returns: Full embed URL
    func getEmbedURL(for videoId: String) -> URL? {
        // Use youtube-nocookie.com to avoid tracking and reduce embed restrictions
        // Add necessary parameters for iOS embedding
        let embedURLString = "https://www.youtube-nocookie.com/embed/\(videoId)?playsinline=1&autoplay=0&rel=0&modestbranding=1&fs=1&enablejsapi=1"
        return URL(string: embedURLString)
    }
    
    /// Generate YouTube app video URL
    /// - Parameter videoId: The video ID
    /// - Returns: YouTube app video URL
    func getYouTubeAppURL(for videoId: String) -> URL? {
        return URL(string: "youtube://\(videoId)")
    }
    
    /// Generate YouTube web video URL with autoplay
    /// - Parameter videoId: The video ID
    /// - Returns: YouTube web video URL with autoplay enabled
    func getYouTubeWebURL(for videoId: String) -> URL? {
        return URL(string: "https://www.youtube.com/watch?v=\(videoId)&autoplay=1")
    }
    
    /// Fetch video metadata (title, description, views) by scraping the video page
    /// - Parameters:
    ///   - videoId: The YouTube video ID
    ///   - completion: Completion handler with YouTubeVideo metadata
    func fetchVideoMetadata(videoId: String, completion: @escaping (YouTubeVideo?) -> Void) {
        guard !videoId.hasPrefix("SEARCH:"), videoId.count == 11 else {
            print("⚠️ YouTube Metadata: Invalid video ID")
            completion(nil)
            return
        }
        
        let urlString = "https://www.youtube.com/watch?v=\(videoId)"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        print("📥 YouTube Metadata: Fetching from \(urlString)")
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil,
                  let html = String(data: data, encoding: .utf8) else {
                print("❌ YouTube Metadata: Failed to fetch page")
                completion(nil)
                return
            }
            
            // Extract metadata from ytInitialData or ytInitialPlayerResponse
            var title: String?
            var description: String?
            var viewCount: String?
            var likeCount: String?
            var publishDate: String?
            var channelName: String?
            
            // PRIORITY 1: Extract JSON data from ytInitialData and ytInitialPlayerResponse
            // These contain the most reliable metadata
            
            // Helper function to extract JSON object from script
            func extractJSON(from html: String, prefix: String) -> [String: Any]? {
                print("🔍 Looking for prefix: '\(prefix)'")
                guard let range = html.range(of: prefix) else {
                    print("❌ Prefix '\(prefix)' not found in HTML")
                    return nil
                }
                
                print("✅ Found prefix '\(prefix)' at position")
                var startIndex = range.upperBound
                
                // Skip whitespace
                while startIndex < html.endIndex && html[startIndex].isWhitespace {
                    startIndex = html.index(after: startIndex)
                }
                
                // Check if value is null
                if html[startIndex...].starts(with: "null") {
                    print("⚠️ Value is null, skipping")
                    return nil
                }
                
                // Find the end of the JSON - look for either semicolon or script tag end
                var jsonEndIndex = startIndex
                var braceCount = 0
                var foundStart = false
                var inString = false
                var escapeNext = false
                
                for index in html[startIndex...].indices {
                    let char = html[index]
                    
                    // Handle string escaping
                    if escapeNext {
                        escapeNext = false
                        continue
                    }
                    if char == "\\" {
                        escapeNext = true
                        continue
                    }
                    if char == "\"" {
                        inString.toggle()
                        continue
                    }
                    
                    // Only count braces outside of strings
                    if !inString {
                        if char == "{" {
                            braceCount += 1
                            foundStart = true
                        } else if char == "}" {
                            braceCount -= 1
                            if foundStart && braceCount == 0 {
                                jsonEndIndex = html.index(after: index)
                                break
                            }
                        }
                    }
                }
                
                var jsonString = String(html[startIndex..<jsonEndIndex])
                print("📏 Extracted raw string length: \(jsonString.count) characters")
                
                // Handle escaped JSON strings (mobile YouTube sometimes does this)
                if jsonString.hasPrefix("\"") || jsonString.hasPrefix("'") {
                    print("🔧 Detected quoted JSON string, unescaping...")
                    // Remove quotes
                    jsonString = String(jsonString.dropFirst().dropLast())
                    
                    // Check if it's hex-encoded (e.g., \x7b for {)
                    if jsonString.contains("\\x") {
                        print("🔧 Detected hex-encoded JSON, decoding...")
                        // Decode hex sequences like \x7b to actual characters
                        var decoded = ""
                        var i = jsonString.startIndex
                        
                        while i < jsonString.endIndex {
                            if i < jsonString.index(jsonString.endIndex, offsetBy: -3),
                               jsonString[i] == "\\",
                               jsonString[jsonString.index(after: i)] == "x" {
                                // Found \xNN pattern
                                let hexStart = jsonString.index(i, offsetBy: 2)
                                let hexEnd = jsonString.index(i, offsetBy: 4)
                                let hexString = String(jsonString[hexStart..<hexEnd])
                                
                                if let hexValue = UInt8(hexString, radix: 16) {
                                    decoded.append(Character(UnicodeScalar(hexValue)))
                                    i = hexEnd
                                } else {
                                    decoded.append(jsonString[i])
                                    i = jsonString.index(after: i)
                                }
                            } else {
                                decoded.append(jsonString[i])
                                i = jsonString.index(after: i)
                            }
                        }
                        jsonString = decoded
                        
                        // Instead of parsing the entire massive JSON, extract just the microformat section
                        print("🔧 Extracting microformat section using targeted regex...")
                        
                        // Look for the microformat section specifically
                        if let microformatRange = jsonString.range(of: "\"microformat\"\\s*:\\s*\\{", options: .regularExpression) {
                            let startIndex = microformatRange.upperBound
                            
                            // Find the matching closing brace for microformat
                            var braceCount = 1
                            var endIndex = startIndex
                            var inString = false
                            var escapeNext = false
                            
                            for index in jsonString[startIndex...].indices {
                                let char = jsonString[index]
                                
                                if escapeNext {
                                    escapeNext = false
                                    continue
                                }
                                if char == "\\" {
                                    escapeNext = true
                                    continue
                                }
                                if char == "\"" && !escapeNext {
                                    inString.toggle()
                                    continue
                                }
                                
                                if !inString {
                                    if char == "{" {
                                        braceCount += 1
                                    } else if char == "}" {
                                        braceCount -= 1
                                        if braceCount == 0 {
                                            endIndex = jsonString.index(after: index)
                                            break
                                        }
                                    }
                                }
                            }
                            
                            let microformatJSON = "{" + String(jsonString[startIndex..<endIndex])
                            print("📏 Extracted microformat JSON: \(microformatJSON.count) characters")
                            print("📄 Microformat preview (first 200 chars): \(String(microformatJSON.prefix(200)))")
                            
                            // Try to parse just the microformat
                            if let microformatData = microformatJSON.data(using: .utf8),
                               let microformatDict = try? JSONSerialization.jsonObject(with: microformatData) as? [String: Any] {
                                print("✅ Successfully parsed microformat JSON!")
                                
                                // Store it so we can use it later
                                jsonString = microformatJSON
                            } else {
                                print("⚠️ Failed to parse microformat, falling back to full JSON")
                            }
                        } else {
                            print("⚠️ Could not find microformat section in JSON")
                        }
                    } else {
                        // Standard escape sequences
                        jsonString = jsonString.replacingOccurrences(of: "\\\"", with: "\"")
                        jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
                        jsonString = jsonString.replacingOccurrences(of: "\\\\", with: "\\")
                    }
                }
                
                print("📄 JSON preview (first 200 chars): \(String(jsonString.prefix(200)))")
                
                guard let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    print("❌ Failed to parse JSON from extracted string")
                    print("   First 500 chars of failed string: \(String(jsonString.prefix(500)))")
                    return nil
                }
                
                print("✅ Successfully parsed JSON with \(json.keys.count) top-level keys: \(Array(json.keys.prefix(10)))")
                return json
            }
            
            // Try ytInitialPlayerResponse first (contains videoDetails and microformat)
            if let playerResponse = extractJSON(from: html, prefix: "var ytInitialPlayerResponse = ") {
                print("✅ Successfully parsed ytInitialPlayerResponse JSON")
                
                // Extract from microformat (most reliable for publish date)
                if let microformat = playerResponse["microformat"] as? [String: Any],
                   let playerMicroformatRenderer = microformat["playerMicroformatRenderer"] as? [String: Any] {
                    
                    if let uploadDate = playerMicroformatRenderer["uploadDate"] as? String {
                        publishDate = uploadDate
                        print("✅ Found publish date in microformat.uploadDate: \(publishDate!)")
                    } else if let publishDateStr = playerMicroformatRenderer["publishDate"] as? String {
                        publishDate = publishDateStr
                        print("✅ Found publish date in microformat.publishDate: \(publishDate!)")
                    }
                }
                
                // Extract from videoDetails as fallback
                if publishDate == nil,
                   let videoDetails = playerResponse["videoDetails"] as? [String: Any],
                   let publishDateStr = videoDetails["publishDate"] as? String {
                    publishDate = publishDateStr
                    print("✅ Found publish date in videoDetails: \(publishDate!)")
                }
            }
            
            // Try ytInitialData for additional metadata like date text
            if let initialData = extractJSON(from: html, prefix: "var ytInitialData = ") {
                print("✅ Successfully parsed ytInitialData JSON")
                
                // Check if we extracted just the microformat or the full data
                var microformat: [String: Any]? = nil
                
                // If the parsed JSON has playerMicroformatRenderer or microformatDataRenderer at top level,
                // it means we extracted just the microformat section
                if initialData["playerMicroformatRenderer"] != nil || initialData["microformatDataRenderer"] != nil {
                    print("🔍 Detected extracted microformat section (not full ytInitialData)")
                    microformat = initialData
                } else {
                    // Otherwise, look for microformat within the full initialData
                    microformat = initialData["microformat"] as? [String: Any]
                }
                
                // First try microformat (mobile YouTube has it here instead of in playerResponse)
                if let microformat = microformat {
                    print("🔍 Found microformat, keys: \(microformat.keys)")
                    
                    // Try playerMicroformatRenderer (desktop YouTube)
                    if let playerMicroformatRenderer = microformat["playerMicroformatRenderer"] as? [String: Any] {
                        if let uploadDate = playerMicroformatRenderer["uploadDate"] as? String {
                            publishDate = uploadDate
                            print("✅ Found publish date in ytInitialData.microformat.uploadDate: \(publishDate!)")
                        } else if let publishDateStr = playerMicroformatRenderer["publishDate"] as? String {
                            publishDate = publishDateStr
                            print("✅ Found publish date in ytInitialData.microformat.publishDate: \(publishDate!)")
                        }
                    }
                    // Try microformatDataRenderer (mobile YouTube)
                    else if let microformatDataRenderer = microformat["microformatDataRenderer"] as? [String: Any] {
                        print("🔍 Found microformatDataRenderer (mobile), keys: \(microformatDataRenderer.keys)")
                        
                        // Dump the entire structure to find the date
                        if let jsonData = try? JSONSerialization.data(withJSONObject: microformatDataRenderer, options: .prettyPrinted),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            print("📋 Full microformatDataRenderer JSON (first 2000 chars):")
                            print(String(jsonString.prefix(2000)))
                        }
                        
                        if let uploadDate = microformatDataRenderer["uploadDate"] as? String {
                            publishDate = uploadDate
                            print("✅ Found publish date in ytInitialData.microformatDataRenderer.uploadDate: \(publishDate!)")
                        } else if let publishDateStr = microformatDataRenderer["publishDate"] as? String {
                            publishDate = publishDateStr
                            print("✅ Found publish date in ytInitialData.microformatDataRenderer.publishDate: \(publishDate!)")
                        } else if let videoDetails = microformatDataRenderer["videoDetails"] as? [String: Any] {
                            print("🔍 Found videoDetails in microformatDataRenderer, keys: \(videoDetails.keys)")
                            
                            if let uploadDate = videoDetails["uploadDate"] as? String {
                                publishDate = uploadDate
                                print("✅ Found publish date in ytInitialData.microformatDataRenderer.videoDetails.uploadDate: \(publishDate!)")
                            } else if let publishDateStr = videoDetails["publishDate"] as? String {
                                publishDate = publishDateStr
                                print("✅ Found publish date in ytInitialData.microformatDataRenderer.videoDetails.publishDate: \(publishDate!)")
                            } else {
                                print("⚠️ videoDetails found but no uploadDate or publishDate field")
                                print("   Available keys: \(Array(videoDetails.keys))")
                            }
                        } else {
                            print("⚠️ microformatDataRenderer found but no uploadDate or publishDate field")
                            print("   Available keys: \(Array(microformatDataRenderer.keys))")
                        }
                    } else {
                        print("⚠️ microformat found but no playerMicroformatRenderer or microformatDataRenderer")
                        print("   microformat keys: \(Array(microformat.keys))")
                    }
                } else {
                    print("⚠️ ytInitialData parsed but no microformat found")
                    print("   ytInitialData top-level keys: \(Array(initialData.keys))")
                }
                
                // Navigate through the complex structure to find dateText as fallback
                if publishDate == nil,
                   let contents = initialData["contents"] as? [String: Any],
                   let twoColumnWatchNextResults = contents["twoColumnWatchNextResults"] as? [String: Any],
                   let results = twoColumnWatchNextResults["results"] as? [String: Any],
                   let resultsContents = results["results"] as? [String: Any],
                   let contents = resultsContents["contents"] as? [[String: Any]] {
                    
                    for content in contents {
                        if let videoSecondaryInfoRenderer = content["videoSecondaryInfoRenderer"] as? [String: Any],
                           let dateText = videoSecondaryInfoRenderer["dateText"] as? [String: Any],
                           let simpleText = dateText["simpleText"] as? String {
                            publishDate = simpleText
                            print("✅ Found publish date in ytInitialData dateText: \(publishDate!)")
                            break
                        }
                    }
                }
            }
            
            // Fallback 1: Try meta tags in HTML head
            if publishDate == nil {
                print("🔍 Searching for publish date in meta tags...")
                
                // Try og:published_time
                if let ogPublishedRange = html.range(of: "<meta property=\"og:published_time\" content=\"([^\"]+)\"", options: .regularExpression) {
                    let metaText = String(html[ogPublishedRange])
                    if let match = try? NSRegularExpression(pattern: "content=\"([^\"]+)\"").firstMatch(
                        in: metaText,
                        range: NSRange(metaText.startIndex..., in: metaText)
                    ), let range = Range(match.range(at: 1), in: metaText) {
                        publishDate = String(metaText[range])
                        print("✅ Found publish date in og:published_time meta tag: \(publishDate!)")
                    }
                }
                
                // Try uploadDate itemprop
                if publishDate == nil, let uploadDateRange = html.range(of: "itemprop=\"uploadDate\" content=\"([^\"]+)\"", options: .regularExpression) {
                    let metaText = String(html[uploadDateRange])
                    if let match = try? NSRegularExpression(pattern: "content=\"([^\"]+)\"").firstMatch(
                        in: metaText,
                        range: NSRange(metaText.startIndex..., in: metaText)
                    ), let range = Range(match.range(at: 1), in: metaText) {
                        publishDate = String(metaText[range])
                        print("✅ Found publish date in uploadDate itemprop: \(publishDate!)")
                    }
                }
                
                // Try datePublished itemprop
                if publishDate == nil, let datePublishedRange = html.range(of: "itemprop=\"datePublished\" content=\"([^\"]+)\"", options: .regularExpression) {
                    let metaText = String(html[datePublishedRange])
                    if let match = try? NSRegularExpression(pattern: "content=\"([^\"]+)\"").firstMatch(
                        in: metaText,
                        range: NSRange(metaText.startIndex..., in: metaText)
                    ), let range = Range(match.range(at: 1), in: metaText) {
                        publishDate = String(metaText[range])
                        print("✅ Found publish date in datePublished itemprop: \(publishDate!)")
                    }
                }
            }
            
            // Fallback 2: Try JSON-LD structured data
            if publishDate == nil {
                print("🔍 Searching for publish date in JSON-LD structured data...")
                
                if let jsonLdRange = html.range(of: "<script type=\"application/ld\\+json\">(.+?)</script>", options: .regularExpression) {
                    let jsonLdText = String(html[jsonLdRange])
                    
                    // Try uploadDate in JSON-LD
                    if let uploadDateMatch = jsonLdText.range(of: "\"uploadDate\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                        let dateText = String(jsonLdText[uploadDateMatch])
                        if let match = try? NSRegularExpression(pattern: "\"uploadDate\"\\s*:\\s*\"([^\"]+)\"").firstMatch(
                            in: dateText,
                            range: NSRange(dateText.startIndex..., in: dateText)
                        ), let range = Range(match.range(at: 1), in: dateText) {
                            publishDate = String(dateText[range])
                            print("✅ Found publish date in JSON-LD uploadDate: \(publishDate!)")
                        }
                    }
                    
                    // Try datePublished in JSON-LD
                    if publishDate == nil, let datePublishedMatch = jsonLdText.range(of: "\"datePublished\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                        let dateText = String(jsonLdText[datePublishedMatch])
                        if let match = try? NSRegularExpression(pattern: "\"datePublished\"\\s*:\\s*\"([^\"]+)\"").firstMatch(
                            in: dateText,
                            range: NSRange(dateText.startIndex..., in: dateText)
                        ), let range = Range(match.range(at: 1), in: dateText) {
                            publishDate = String(dateText[range])
                            print("✅ Found publish date in JSON-LD datePublished: \(publishDate!)")
                        }
                    }
                }
            }
            
            // Fallback 3: Try publishedDate in inline JSON
            if publishDate == nil {
                print("🔍 Searching for publish date in inline JSON patterns...")
                
                if let publishedDateRange = html.range(of: "\"publishedDate\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                    let dateText = String(html[publishedDateRange])
                    if let match = try? NSRegularExpression(pattern: "\"publishedDate\"\\s*:\\s*\"([^\"]+)\"").firstMatch(
                        in: dateText,
                        range: NSRange(dateText.startIndex..., in: dateText)
                    ), let range = Range(match.range(at: 1), in: dateText) {
                        publishDate = String(dateText[range])
                        print("✅ Found publish date in inline publishedDate: \(publishDate!)")
                    }
                }
                
                // Try publishDate in inline JSON
                if publishDate == nil, let publishDateRange = html.range(of: "\"publishDate\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                    let dateText = String(html[publishDateRange])
                    if let match = try? NSRegularExpression(pattern: "\"publishDate\"\\s*:\\s*\"([^\"]+)\"").firstMatch(
                        in: dateText,
                        range: NSRange(dateText.startIndex..., in: dateText)
                    ), let range = Range(match.range(at: 1), in: dateText) {
                        publishDate = String(dateText[range])
                        print("✅ Found publish date in inline publishDate: \(publishDate!)")
                    }
                }
            }
            
            // Try to find title
            if let titleMatch = html.range(of: "\"title\":\"([^\"]+)\"", options: .regularExpression) {
                let titleText = String(html[titleMatch])
                if let match = try? NSRegularExpression(pattern: "\"title\":\"([^\"]+)\"").firstMatch(
                    in: titleText,
                    range: NSRange(titleText.startIndex..., in: titleText)
                ), let range = Range(match.range(at: 1), in: titleText) {
                    title = String(titleText[range])
                }
            }
            
            // Try to find description - multiple patterns
            if description == nil, let descMatch = html.range(of: "\"attributedDescriptionBodyText\":\\{\"content\":\"([^\"]+)\"", options: .regularExpression) {
                let descText = String(html[descMatch])
                if let match = try? NSRegularExpression(pattern: "\"content\":\"([^\"]+)\"").firstMatch(
                    in: descText,
                    range: NSRange(descText.startIndex..., in: descText)
                ), let range = Range(match.range(at: 1), in: descText) {
                    description = String(descText[range])
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\/", with: "/")
                }
            }
            
            // Alternative description pattern
            if description == nil, let descMatch = html.range(of: "\"description\":\\{\"simpleText\":\"([^\"]+)\"", options: .regularExpression) {
                let descText = String(html[descMatch])
                if let match = try? NSRegularExpression(pattern: "\"description\":\\{\"simpleText\":\"([^\"]+)\"").firstMatch(
                    in: descText,
                    range: NSRange(descText.startIndex..., in: descText)
                ), let range = Range(match.range(at: 1), in: descText) {
                    description = String(descText[range])
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\/", with: "/")
                }
            }
            
            // Try to find view count
            if let viewMatch = html.range(of: "\"viewCount\":\"([0-9,]+)\"", options: .regularExpression) {
                let viewText = String(html[viewMatch])
                if let match = try? NSRegularExpression(pattern: "\"viewCount\":\"([0-9,]+)\"").firstMatch(
                    in: viewText,
                    range: NSRange(viewText.startIndex..., in: viewText)
                ), let range = Range(match.range(at: 1), in: viewText) {
                    viewCount = String(viewText[range])
                }
            }
            
            // Try to find like count from parsed JSON first
            if let initialData = extractJSON(from: html, prefix: "var ytInitialData = ") {
                if let contents = initialData["contents"] as? [String: Any],
                   let twoColumnWatchNextResults = contents["twoColumnWatchNextResults"] as? [String: Any],
                   let results = twoColumnWatchNextResults["results"] as? [String: Any],
                   let resultsContents = results["results"] as? [String: Any],
                   let contents = resultsContents["contents"] as? [[String: Any]] {
                    
                    for content in contents {
                        if let videoPrimaryInfoRenderer = content["videoPrimaryInfoRenderer"] as? [String: Any],
                           let videoActions = videoPrimaryInfoRenderer["videoActions"] as? [String: Any],
                           let menuRenderer = videoActions["menuRenderer"] as? [String: Any],
                           let topLevelButtons = menuRenderer["topLevelButtons"] as? [[String: Any]] {
                            
                            // Find the like button
                            for button in topLevelButtons {
                                if let toggleButtonRenderer = button["toggleButtonRenderer"] as? [String: Any],
                                   let defaultText = toggleButtonRenderer["defaultText"] as? [String: Any],
                                   let simpleText = defaultText["simpleText"] as? String {
                                    likeCount = simpleText
                                    print("✅ Found likes in ytInitialData: \(likeCount!)")
                                    break
                                }
                                
                                // Alternative structure
                                if let segmentedLikeDislikeButtonRenderer = button["segmentedLikeDislikeButtonRenderer"] as? [String: Any],
                                   let likeButton = segmentedLikeDislikeButtonRenderer["likeButton"] as? [String: Any],
                                   let toggleButtonRenderer = likeButton["toggleButtonRenderer"] as? [String: Any],
                                   let defaultText = toggleButtonRenderer["defaultText"] as? [String: Any],
                                   let simpleText = defaultText["simpleText"] as? String {
                                    likeCount = simpleText
                                    print("✅ Found likes in ytInitialData (segmented): \(likeCount!)")
                                    break
                                }
                            }
                        }
                    }
                }
            }
            
            // Fallback to regex patterns if JSON parsing failed
            if likeCount == nil {
                let likePatterns = [
                    "\"accessibilityText\":\"([0-9,]+) likes\"",
                    "\"label\":\"([0-9,]+) likes\"",
                    "\"defaultText\":\\{\"accessibility\":\\{\"accessibilityData\":\\{\"label\":\"([0-9,]+) likes",
                    "\"toggleButtonRenderer\".*?\"defaultText\".*?\"simpleText\":\"([0-9,]+)\"",
                    "\"likeCount\":\"([0-9,]+)\"",
                    "\"text\":\"([0-9KMB.]+)\".*?\"iconType\":\"LIKE\""
                ]
                
                for pattern in likePatterns {
                    if likeCount == nil {
                        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                            if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) {
                                let extracted = String(html[range])
                                if !extracted.isEmpty {
                                    likeCount = extracted
                                    print("✅ Found likes using regex pattern: \(pattern)")
                                    break
                                }
                            }
                        }
                    }
                }
            }
            
            // Try to find publish date - extensive patterns
            // Updated patterns to match current YouTube HTML structure (as of 2024)
            let datePatterns = [
                // ISO format dates (most reliable)
                "\"publishDate\":\"([0-9]{4}-[0-9]{2}-[0-9]{2})\"",
                "\"uploadDate\":\"([0-9]{4}-[0-9]{2}-[0-9]{2})\"",
                
                // videoDetails section (primary source)
                "\"videoDetails\".*?\"publishDate\":\"([0-9]{4}-[0-9]{2}-[0-9]{2})\"",
                
                // microformat section (reliable source)
                "\"microformat\".*?\"publishDate\":\"([0-9]{4}-[0-9]{2}-[0-9]{2})\"",
                "\"microformat\".*?\"uploadDate\":\"([0-9]{4}-[0-9]{2}-[0-9]{2})\"",
                
                // Date text fields in various sections
                "\"dateText\":\\{\"simpleText\":\"([^\"]+)\"\\}",
                "\"dateText\":\"([^\"]+)\"",
                
                // Published time text (appears in video secondary info)
                "\"publishedTimeText\":\\{\"simpleText\":\"([^\"]+)\"\\}",
                "\"publishedTimeText\":\"([^\"]+)\"",
                
                // Video secondary info renderer (common location for date)
                "\"videoSecondaryInfoRenderer\".*?\"dateText\".*?\"simpleText\":\"([^\"]+)\"",
                
                // Info strings array (where date metadata appears)
                "\"infoStrings\".*?\"text\":\"([A-Z][a-z]{2}\\s+[0-9]{1,2},\\s+[0-9]{4})\"",
                "\"info\":\\[.*?\"text\":\"([A-Z][a-z]{2}\\s+[0-9]{1,2},\\s+[0-9]{4})\"",
                
                // Relative time patterns (e.g., "3 years ago", "2 months ago")
                "\"relativeDateText\":\\{\"simpleText\":\"([^\"]+)\"\\}",
                "\"text\":\"([0-9]+ years? ago)\"",
                "\"text\":\"([0-9]+ months? ago)\"",
                "\"text\":\"([0-9]+ weeks? ago)\"",
                "\"text\":\"([0-9]+ days? ago)\"",
                "\"text\":\"([0-9]+ hours? ago)\"",
                
                // Plain text date patterns in various formats
                "\"text\":\"([A-Z][a-z]{2}\\s+[0-9]{1,2},\\s+[0-9]{4})\"",
                "\"simpleText\":\"([A-Z][a-z]{2}\\s+[0-9]{1,2},\\s+[0-9]{4})\"",
                
                // Structured description
                "\"structuredDescription\".*?\"dateText\".*?\"content\":\"([^\"]+)\"",
                
                // Accessibility labels for date
                "\"dateText\".*?\"accessibility\".*?\"label\":\"([^\"]+)\"",
                
                // Alternative JSON structures
                "\\\"date\\\":\\\"([0-9]{4}-[0-9]{2}-[0-9]{2})\\\"",
                "\\\"uploaded\\\":\\\"([^\"]+)\\\""
            ]
            
            // PRIORITY 2: If date not found in ytInitialPlayerResponse, try broader patterns
            if publishDate == nil {
                print("🔍 Searching for publish date using broader patterns...")
                for (index, pattern) in datePatterns.enumerated() {
                    if publishDate == nil {
                        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                            if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) {
                                let extracted = String(html[range])
                                if !extracted.isEmpty && extracted.count < 50 {  // Sanity check
                                    publishDate = extracted
                                    print("✅ Found date using broader pattern \(index + 1): \(pattern)")
                                    print("   Extracted: '\(extracted)'")
                                    break
                                }
                            }
                        }
                    }
                }
            } else {
                print("✅ Publish date already found in ytInitialPlayerResponse, skipping broader patterns")
            }
            
            // NOTE: Aggressive fallback disabled - it picks up dates from comments/related videos
            // which gives incorrect results. JSON parsing should handle all cases.
            
            if publishDate == nil {
                print("❌ Could not find publish date in HTML")
                print("📋 HTML snippet for debugging (first 1000 chars):")
                print(String(html.prefix(1000)))
                print("...")
                print("📋 Searching for 'date' keyword in HTML...")
                if html.lowercased().contains("date") {
                    print("✓ 'date' keyword found in HTML")
                } else {
                    print("✗ 'date' keyword NOT found in HTML")
                }
            }
            
            // Try to find channel name
            if let channelMatch = html.range(of: "\"author\":\"([^\"]+)\"", options: .regularExpression) {
                let channelText = String(html[channelMatch])
                if let match = try? NSRegularExpression(pattern: "\"author\":\"([^\"]+)\"").firstMatch(
                    in: channelText,
                    range: NSRange(channelText.startIndex..., in: channelText)
                ), let range = Range(match.range(at: 1), in: channelText) {
                    channelName = String(channelText[range])
                }
            }
            
            let video = YouTubeVideo(
                videoId: videoId,
                title: title,
                description: description,
                viewCount: viewCount,
                likeCount: likeCount,
                publishDate: publishDate,
                channelName: channelName
            )
            
            print("✅ YouTube Metadata: Extracted")
            print("   Title: \(title ?? "N/A")")
            print("   Description: \(description?.prefix(50) ?? "N/A")...")
            print("   Views: \(viewCount ?? "N/A")")
            print("   Likes: \(likeCount ?? "N/A")")
            print("   Date: \(publishDate ?? "N/A")")
            print("   Channel: \(channelName ?? "N/A")")
            
            DispatchQueue.main.async {
                completion(video)
            }
        }
        task.resume()
    }
    
    /// Smart open YouTube video - tries YouTube app first, then falls back to browser
    /// - Parameter videoId: The video ID or search query (prefixed with "SEARCH:")
    func openYouTubeVideo(videoId: String) {
        // Check if this is a search fallback
        if videoId.hasPrefix("SEARCH:") {
            let searchQuery = String(videoId.dropFirst(7)) // Remove "SEARCH:" prefix
            openYouTubeSearch(query: searchQuery)
            return
        }
        
        guard let appURL = getYouTubeAppURL(for: videoId),
              let webURL = getYouTubeWebURL(for: videoId) else {
            print("❌ YouTube: Invalid video ID")
            return
        }
        
        print("🎬 YouTube: Opening video \(videoId)")
        
        // Try to open in YouTube app first
        if UIApplication.shared.canOpenURL(appURL) {
            print("📱 YouTube: Opening in YouTube app")
            UIApplication.shared.open(appURL) { success in
                if !success {
                    // Fallback to web browser if app fails
                    print("🌐 YouTube: App failed, opening in browser")
                    UIApplication.shared.open(webURL)
                }
            }
        } else {
            // YouTube app not installed, open in browser
            print("🌐 YouTube: App not installed, opening in browser")
            UIApplication.shared.open(webURL)
        }
    }
    
    /// Open YouTube search (fallback when video ID not found)
    /// - Parameter query: The search query
    private func openYouTubeSearch(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("❌ YouTube: Failed to encode search query")
            return
        }
        
        let appURL = URL(string: "youtube://results?search_query=\(encoded)")
        let webURL = URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
        
        print("🔍 YouTube: Opening search results for '\(query)'")
        
        // Try to open in YouTube app first
        if let appURL = appURL, UIApplication.shared.canOpenURL(appURL) {
            print("📱 YouTube: Opening search in YouTube app")
            UIApplication.shared.open(appURL) { success in
                if !success, let webURL = webURL {
                    print("🌐 YouTube: App failed, opening search in browser")
                    UIApplication.shared.open(webURL)
                }
            }
        } else if let webURL = webURL {
            print("🌐 YouTube: Opening search in browser")
            UIApplication.shared.open(webURL)
        }
    }
}
