//
//  YouTubeService.swift
//  StreamRadios
//
//  YouTube API integration for searching songs
//

import Foundation
import UIKit

class YouTubeService {
    static let shared = YouTubeService()
    
    /// Scrape YouTube search results to get first video ID (no API needed)
    /// - Parameters:
    ///   - songTitle: The title of the song
    ///   - artist: The artist name
    ///   - completion: Completion handler with video ID
    func searchSong(title: String, artist: String, completion: @escaping (String?) -> Void) {
        let searchQuery = "\(artist) \(title) official"
        
        guard let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)") else {
            print("❌ YouTube: Failed to create search URL")
            completion(nil)
            return
        }
        
        print("🔍 YouTube: Scraping search results for '\(searchQuery)'")
        
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
            
            // PRIORITY 1: Extract from ytInitialData section
            if let videoId = self.extractFromYtInitialData(html: html) {
                print("✅ YouTube: Found first video '\(videoId)' from ytInitialData")
                DispatchQueue.main.async {
                    completion(videoId)
                }
                return
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
            
            print("❌ YouTube: Could not extract any video ID from HTML")
            print("📋 HTML sample (first 500 chars): \(String(html.prefix(500)))")
            
            // LAST RESORT: Return search query (will open search page)
            DispatchQueue.main.async {
                completion("SEARCH:\(searchQuery)")
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
