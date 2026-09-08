//
//  ShazamViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import SwiftUI
import ShazamKit
import AVKit
import MusicKit

struct ShazamMedia: Decodable {
    let title: String?
    let subtitle: String?
    let artistName: String?
    let albumArtURL: URL?
    let genres: [String]
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    static let shared = ShazamViewModel()
    
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    @Published var appleMusicURL: URL?
       @Published var appleMusicItem: MusicKit.Song?
    @Published var userPlaylists: MusicItemCollection<Playlist> = MusicItemCollection<Playlist>()
    @Published var youtubeVideoId: String?
    @Published var youtubeVideoDescription: String?
    @Published var youtubeVideoTitle: String?
    @Published var youtubeVideoViews: String?
    @Published var youtubeLikes: String?
    @Published var youtubePublishDate: String?
    
    // Track the last fetched video to prevent unnecessary metadata resets
    private var lastFetchedSongTitle: String?
    private var lastFetchedArtistName: String?

    private var session = SHSession()
    
    private var streamRecognitionTask: Task<Void, Never>?
    private var foundMatchThisSession = false
    
    /// ShazamKit is happiest with a plain mono float format.
    private let shazamFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    
    override init() {
        super.init()
        session.delegate = self
    }
    
    public func startOrEndListening() {
        guard !isRecording else {
            stopListening()
            return
        }
        
        isRecording = true
        foundMatchThisSession = false
        clearPreviousMatch()
        
        // Recognition reads the station stream over the network - the microphone is never used, so
        // the app asks for no recording permission and the output route is irrelevant.
        streamRecognitionTask = Task { [weak self] in
            await self?.runStreamRecognition()
        }
    }

    func matchCurrentStreamForArtwork(expectedStationId: String) async -> (title: String, artist: String, artworkURL: URL)? {
          guard !isRecording,
              RadioPlayer.shared.currentlyPlayingStation?.id == expectedStationId,
              let urlString = RadioPlayer.shared.currentlyPlayingStation?.url,
              let url = URL(string: urlString) else {
            return nil
        }

        do {
            let sample = try await captureStreamSample(from: url, seconds: 12)
            try Task.checkCancellation()
            let buffer = try await decodeToShazamBuffer(sample)
            try Task.checkCancellation()
            let maxFrames = AVAudioFrameCount(shazamFormat.sampleRate * 11.9)
            if buffer.frameLength > maxFrames { buffer.frameLength = maxFrames }

            let generator = SHSignatureGenerator()
            try generator.append(buffer, at: nil)

            guard RadioPlayer.shared.currentlyPlayingStation?.id == expectedStationId else {
                return nil
            }

            switch await SHSession().result(from: generator.signature()) {
            case .match(let match):
                guard RadioPlayer.shared.currentlyPlayingStation?.id == expectedStationId,
                      let item = match.mediaItems.first,
                      let title = item.title,
                      let artist = item.artist,
                      let artworkURL = item.artworkURL else {
                    return nil
                }
                DebugLogger.logInfo("Shazam artwork fallback matched '\(title)' by '\(artist)'", category: "Shazam")
                return (title, artist, artworkURL)
            case .noMatch:
                DebugLogger.logInfo("Shazam artwork fallback found no match", category: "Shazam")
                return nil
            case .error(let error, _):
                DebugLogger.logWarning("Shazam artwork fallback failed - \(error.localizedDescription)", category: "Shazam")
                return nil
            @unknown default:
                return nil
            }
        } catch {
            DebugLogger.logWarning("Shazam artwork fallback capture failed - \(error.localizedDescription)", category: "Shazam")
            return nil
        }
    }
    
    /// The view model is shared, so a new session must not show the previous station's result.
    private func clearPreviousMatch() {
        shazamMedia = ShazamMedia(title: nil, subtitle: nil, artistName: nil, albumArtURL: nil, genres: [])
        appleMusicURL = nil
        appleMusicItem = nil
        youtubeVideoId = nil
        youtubeVideoTitle = nil
        youtubeVideoDescription = nil
        youtubeVideoViews = nil
        youtubeLikes = nil
        youtubePublishDate = nil
        lastFetchedSongTitle = nil
        lastFetchedArtistName = nil
    }
    
    // MARK: - Direct Stream Recognition
    
    private enum ShazamStreamError: LocalizedError {
        case badResponse
        case isPlaylist
        case notEnoughAudio
        case decodeFailed
        
        var errorDescription: String? {
            switch self {
            case .badResponse: return "stream returned an unexpected response"
            case .isPlaylist: return "stream is an HLS playlist"
            case .notEnoughAudio: return "captured too little audio"
            case .decodeFailed: return "could not decode the captured audio"
            }
        }
    }
    
    private struct StreamSample {
        let data: Data
        let fileExtension: String
    }
    
    private func runStreamRecognition() async {
        guard let urlString = RadioPlayer.shared.currentlyPlayingStation?.url,
              let url = URL(string: urlString) else {
            DebugLogger.logWarning("Shazam: no station URL available", category: "Shazam")
            await MainActor.run { self.isRecording = false }
            return
        }
        
        for attempt in 1...3 {
            if Task.isCancelled || foundMatchThisSession { return }
            
            do {
                // 6s matched only ~22% of the time in practice; Shazam's own app uses around 12s.
                let sample = try await captureStreamSample(from: url, seconds: 12)
                let buffer = try await decodeToShazamBuffer(sample)
                // Stations that omit or understate `icy-br` return more audio than asked for, and the
                // catalog rejects signatures longer than 12s with SHError.signatureDurationInvalid.
                let maxFrames = AVAudioFrameCount(shazamFormat.sampleRate * 11.9)
                if buffer.frameLength > maxFrames { buffer.frameLength = maxFrames }
                let generator = SHSignatureGenerator()
                try generator.append(buffer, at: nil)
                
                if Task.isCancelled || foundMatchThisSession { return }
                
                let duration = Double(buffer.frameLength) / shazamFormat.sampleRate
                let station = RadioPlayer.shared.currentlyPlayingStation?.name ?? "unknown"
                DebugLogger.logInfo(
                    "Shazam: attempt \(attempt) matching \(String(format: "%.1f", duration))s from \(sample.fileExtension) - \(station)",
                    category: "Shazam"
                )
                session.match(generator.signature())
            } catch {
                DebugLogger.logWarning(
                    "Shazam: stream capture failed on attempt \(attempt) - \(error.localizedDescription)",
                    category: "Shazam"
                )
                await MainActor.run { self.isRecording = false }
                return
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        if !foundMatchThisSession {
            await MainActor.run { self.isRecording = false }
        }
    }
    
    /// Stations are either a progressive stream (ICY/MP3/AAC) or an HLS playlist, which need entirely
    /// different capture strategies.
    private func captureStreamSample(from url: URL, seconds: Double) async throws -> StreamSample {
        if url.pathExtension.lowercased().hasPrefix("m3u") {
            return try await captureHLSSample(from: url, seconds: seconds)
        }
        do {
            return try await captureProgressiveSample(from: url, seconds: seconds)
        } catch ShazamStreamError.isPlaylist {
            return try await captureHLSSample(from: url, seconds: seconds)
        }
    }
    
    /// Pulls a few seconds of audio straight off the station URL, stripping the Shoutcast/ICY
    /// metadata that is interleaved with the audio frames.
    private func captureProgressiveSample(from url: URL, seconds: Double) async throws -> StreamSample {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("0", forHTTPHeaderField: "Icy-MetaData")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShazamStreamError.badResponse
        }
        
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard !contentType.contains("mpegurl"), !contentType.contains("m3u") else {
            throw ShazamStreamError.isPlaylist
        }
        
        let fileExtension = Self.fileExtension(forContentType: contentType)
        let metaInt = Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0
        let bitrate = Int(http.value(forHTTPHeaderField: "icy-br") ?? "") ?? 128
        let targetBytes = Int(Double(bitrate) * 1000 / 8 * seconds)
        
        var audio = Data(capacity: targetBytes)
        var sinceMetadata = 0
        var metadataRemaining = 0
        var awaitingMetadataLength = false
        // `icy-br` is a guess, so bound the wait by wall clock too - servers stream at real time
        // once their initial burst is drained.
        let deadline = Date().addingTimeInterval(seconds + 2)
        
        for try await byte in bytes {
            if awaitingMetadataLength {
                metadataRemaining = Int(byte) * 16
                awaitingMetadataLength = false
                if metadataRemaining == 0 { sinceMetadata = 0 }
                continue
            }
            if metadataRemaining > 0 {
                metadataRemaining -= 1
                if metadataRemaining == 0 { sinceMetadata = 0 }
                continue
            }
            
            audio.append(byte)
            
            if metaInt > 0 {
                sinceMetadata += 1
                if sinceMetadata == metaInt { awaitingMetadataLength = true }
            }
            
            if audio.count >= targetBytes { break }
            if audio.count & 0x3FFF == 0 {
                if Task.isCancelled { throw CancellationError() }
                if Date() > deadline { break }
            }
        }
        
        guard audio.count > 8192 else { throw ShazamStreamError.notEnoughAudio }
        return StreamSample(data: Self.trimToFrameBoundary(audio, fileExtension: fileExtension),
                            fileExtension: fileExtension)
    }
    
    private static func fileExtension(forContentType contentType: String) -> String {
        if contentType.contains("aac") { return "aac" }
        if contentType.contains("mp4") || contentType.contains("m4a") { return "m4a" }
        return "mp3"
    }
    
    /// A mid-stream chunk has no container header, so decoding has to start on a frame sync word.
    private static func trimToFrameBoundary(_ data: Data, fileExtension: String) -> Data {
        guard fileExtension == "mp3" || fileExtension == "aac" else { return data }
        
        let head = [UInt8](data.prefix(8192))
        guard head.count > 1 else { return data }
        
        for index in 0..<(head.count - 1) where head[index] == 0xFF {
            let next = head[index + 1]
            let isMP3 = fileExtension == "mp3" && (next & 0xE0) == 0xE0
            let isADTS = fileExtension == "aac" && (next & 0xF6) == 0xF0
            if isMP3 || isADTS {
                return index == 0 ? data : Data(data.dropFirst(index))
            }
        }
        return data
    }
    
    // MARK: - HLS
    
    /// Walks a playlist down to its newest media segments and returns them as one blob.
    private func captureHLSSample(from url: URL, seconds: Double) async throws -> StreamSample {
        var playlistURL = url
        var mediaPlaylist: String?
        
        // A master playlist points at variant playlists; follow the first one down to real segments.
        for _ in 0..<3 {
            let playlist = try await fetchPlaylist(at: playlistURL)
            playlistURL = playlist.url
            guard playlist.text.contains("#EXTM3U") else { throw ShazamStreamError.badResponse }
            
            guard playlist.text.contains("#EXT-X-STREAM-INF") else {
                mediaPlaylist = playlist.text
                break
            }
            guard let variant = Self.firstVariantURL(in: playlist.text, relativeTo: playlistURL) else {
                throw ShazamStreamError.badResponse
            }
            playlistURL = variant
        }
        
        guard let mediaPlaylist else { throw ShazamStreamError.badResponse }
        
        let segments = Self.segments(in: mediaPlaylist, relativeTo: playlistURL)
        guard !segments.isEmpty else { throw ShazamStreamError.notEnoughAudio }
        
        // A live playlist lists segments oldest first, so the current audio is at the end.
        var chosen: [URL] = []
        var covered = 0.0
        for segment in segments.reversed() {
            chosen.insert(segment.url, at: 0)
            covered += segment.duration > 0 ? segment.duration : 6
            if covered >= seconds || chosen.count >= 4 { break }
        }
        
        var audio = Data()
        for segmentURL in chosen {
            if Task.isCancelled { throw CancellationError() }
            let request = URLRequest(url: segmentURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ShazamStreamError.badResponse
            }
            audio.append(data)
        }
        
        guard audio.count > 8192 else { throw ShazamStreamError.notEnoughAudio }
        let fileExtension = chosen.first?.pathExtension.lowercased() ?? ""
        
        // iOS only understands MPEG-TS inside its own HLS engine, so unwrap the audio ourselves.
        if let unwrapped = Self.extractElementaryAudio(fromTransportStream: audio) { return unwrapped }
        return StreamSample(data: audio, fileExtension: fileExtension.isEmpty ? "ts" : fileExtension)
    }
    
    /// Pulls the raw ADTS/MP3 frames out of MPEG-TS packets. Locks on to the first PID carrying an
    /// audio PES stream, which is all a radio segment ever has.
    private static func extractElementaryAudio(fromTransportStream data: Data) -> StreamSample? {
        let packetSize = 188
        let bytes = [UInt8](data)
        
        var start = 0
        while start < min(bytes.count, packetSize * 2) {
            if bytes[start] == 0x47, start + packetSize < bytes.count, bytes[start + packetSize] == 0x47 { break }
            start += 1
        }
        guard start + packetSize <= bytes.count else { return nil }
        
        var audioPID: Int?
        var payload = Data(capacity: bytes.count)
        var offset = start
        
        while offset + packetSize <= bytes.count {
            let packet = offset
            offset += packetSize
            
            guard bytes[packet] == 0x47 else { continue }
            let pid = (Int(bytes[packet + 1] & 0x1F) << 8) | Int(bytes[packet + 2])
            let adaptationControl = (bytes[packet + 3] & 0x30) >> 4
            guard adaptationControl == 1 || adaptationControl == 3 else { continue }
            
            var cursor = packet + 4
            if adaptationControl == 3 { cursor += 1 + Int(bytes[packet + 4]) }
            guard cursor < packet + packetSize else { continue }
            
            if (bytes[packet + 1] & 0x40) != 0 {
                guard cursor + 9 <= packet + packetSize,
                      bytes[cursor] == 0x00, bytes[cursor + 1] == 0x00, bytes[cursor + 2] == 0x01,
                      (0xC0...0xDF).contains(bytes[cursor + 3]) else { continue }
                if audioPID == nil { audioPID = pid }
                guard pid == audioPID else { continue }
                cursor += 9 + Int(bytes[cursor + 8])
                guard cursor <= packet + packetSize else { continue }
            } else {
                guard let audioPID, pid == audioPID else { continue }
            }
            
            payload.append(contentsOf: bytes[cursor..<(packet + packetSize)])
        }
        
        guard payload.count > 8192 else { return nil }
        
        let head = [UInt8](payload.prefix(4096))
        guard head.count > 1 else { return nil }
        for index in 0..<(head.count - 1) where head[index] == 0xFF {
            let next = head[index + 1]
            if (next & 0xF6) == 0xF0 {
                return StreamSample(data: Data(payload.dropFirst(index)), fileExtension: "aac")
            }
            if (next & 0xE0) == 0xE0 {
                return StreamSample(data: Data(payload.dropFirst(index)), fileExtension: "mp3")
            }
        }
        return nil
    }
    
    private func fetchPlaylist(at url: URL) async throws -> (text: String, url: URL) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw ShazamStreamError.badResponse
        }
        return (text, http.url ?? url)
    }
    
    private static func firstVariantURL(in playlist: String, relativeTo base: URL) -> URL? {
        let lines = playlist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
                continue
            }
            return URL(string: uri, relativeTo: base)?.absoluteURL
        }
        return nil
    }
    
    private static func segments(in playlist: String, relativeTo base: URL) -> [(url: URL, duration: Double)] {
        var result: [(url: URL, duration: Double)] = []
        var pendingDuration = 0.0
        
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    result.append((url: url, duration: pendingDuration))
                }
                pendingDuration = 0
            }
        }
        return result
    }
    
    private func decodeToShazamBuffer(_ sample: StreamSample) async throws -> AVAudioPCMBuffer {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shazam-\(UUID().uuidString).\(sample.fileExtension)")
        try sample.data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // AVAudioFile refuses MPEG-TS, which is what every HLS segment is, so those go the reader route.
        if let buffer = try? decodeWithAudioFile(tempURL) { return buffer }
        return try await decodeWithAssetReader(tempURL)
    }
    
    private func decodeWithAssetReader(_ url: URL) async throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ShazamStreamError.decodeFailed
        }
        
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: shazamFormat.sampleRate,
            AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        reader.startReading()
        
        var samples = [Float]()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer, length >= MemoryLayout<Float>.size else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) {
                samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / MemoryLayout<Float>.size))
            }
        }
        
        guard reader.status != .failed, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: shazamFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ShazamStreamError.decodeFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(channel, samples, samples.count * MemoryLayout<Float>.size)
        return buffer
    }
    
    private func decodeWithAudioFile(_ tempURL: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: tempURL)
        guard file.length > 0,
              let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ShazamStreamError.decodeFailed
        }
        try file.read(into: decoded)
        
        guard let converter = AVAudioConverter(from: file.processingFormat, to: shazamFormat) else {
            throw ShazamStreamError.decodeFailed
        }
        
        let capacity = AVAudioFrameCount(
            Double(decoded.frameLength) * shazamFormat.sampleRate / file.processingFormat.sampleRate
        ) + 4096
        guard let converted = AVAudioPCMBuffer(pcmFormat: shazamFormat, frameCapacity: capacity) else {
            throw ShazamStreamError.decodeFailed
        }
        
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return decoded
        }
        
        if let error { throw error }
        guard converted.frameLength > 0 else { throw ShazamStreamError.decodeFailed }
        return converted
    }
    
    func addToLibrary() async throws {
            guard let song = appleMusicItem else {
                throw NSError(domain: "ShazamError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No Apple Music item available"])
            }
            
            do {
                try await MusicLibrary.shared.add(song)
                print("Song added successfully")
            } catch {
                print("Failed to add song: \(error)")
                throw error
            }
        }
    
    func fetchAppleMusicItem() async throws {
            guard let songTitle = shazamMedia.title, let artistName = shazamMedia.artistName else {
                throw NSError(domain: "ShazamError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Song information not available"])
            }
            
            let searchRequest = MusicCatalogSearchRequest(term: "\(songTitle) \(artistName)", types: [Song.self])
            let searchResponse = try await searchRequest.response()
            
            guard let song = searchResponse.songs.first else {
                throw NSError(domain: "ShazamError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Song not found in Apple Music"])
            }
            
            DispatchQueue.main.async {
                self.appleMusicItem = song
                self.appleMusicURL = song.url
            }
        }
    
    func addToPlaylist(_ playlist: Playlist) async throws {
            guard let song = appleMusicItem else {
                throw NSError(domain: "ShazamError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No Apple Music item available"])
            }
            
            do {
                let library = MusicLibrary.shared
                try await library.add(song, to: playlist)
                print("Song added successfully to playlist")
            } catch {
                print("Failed to add song to playlist: \(error)")
                throw error
            }
        }
    
    func fetchYouTubeVideo() {
        guard let songTitle = shazamMedia.title, let artistName = shazamMedia.artistName else {
            print("❌ YouTube: Cannot search - missing song title or artist")
            return
        }
        
        print("🔍 YouTube: Searching for '\(songTitle)' by '\(artistName)'")
        
        // Only reset metadata if fetching a different song (prevents flicker when reloading same video)
        let isSameSong = lastFetchedSongTitle == songTitle && lastFetchedArtistName == artistName
        
        if !isSameSong {
            print("🔄 YouTube: Fetching new video - resetting metadata")
            youtubeVideoTitle = nil
            youtubeVideoDescription = nil
            youtubeVideoViews = nil
            youtubeLikes = nil
            youtubePublishDate = nil
            
            // Update tracking
            lastFetchedSongTitle = songTitle
            lastFetchedArtistName = artistName
        } else {
            print("✅ YouTube: Same video - preserving existing metadata")
        }
        
        YouTubeService.shared.searchSong(title: songTitle, artist: artistName) { [weak self] videoId in
            DispatchQueue.main.async {
                self?.youtubeVideoId = videoId
                if let videoId = videoId {
                    print("✅ YouTube: Video ID set: \(videoId)")
                    
                    // Fetch video metadata (description, title, views, likes, date)
                    YouTubeService.shared.fetchVideoMetadata(videoId: videoId) { [weak self] video in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            
                            // Only update metadata if we don't have it yet or if new data is available
                            if self.youtubeVideoTitle == nil || video?.title != nil {
                                self.youtubeVideoTitle = video?.title
                            }
                            if self.youtubeVideoDescription == nil || video?.description != nil {
                                self.youtubeVideoDescription = video?.description
                            }
                            if self.youtubeVideoViews == nil || video?.viewCount != nil {
                                self.youtubeVideoViews = video?.viewCount
                            }
                            if self.youtubeLikes == nil || video?.likeCount != nil {
                                self.youtubeLikes = video?.likeCount
                            }
                            if self.youtubePublishDate == nil || video?.publishDate != nil {
                                self.youtubePublishDate = video?.publishDate
                            }
                            
                            print("📅 YouTube: Publish date set to: \(video?.publishDate ?? "nil")")
                        }
                    }
                } else {
                    print("❌ YouTube: No video found")
                }
            }
        }
    }
    
    func stopListening() {
        streamRecognitionTask?.cancel()
        streamRecognitionTask = nil
        DispatchQueue.main.async { self.isRecording = false }
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        DebugLogger.logWarning(
            "Shazam: no match for \(String(format: "%.1f", signature.duration))s of audio - \(error?.localizedDescription ?? "no error")",
            category: "Shazam"
        )
    }
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        foundMatchThisSession = true
        DispatchQueue.main.async {
            self.isRecording = false
            if let firstItem = match.mediaItems.first {
                self.updateShazamMedia(from: firstItem)
            }
        }
    }
    
    private func updateShazamMedia(from item: SHMediaItem) {
        var media = ShazamMedia(title: item.title,
                                subtitle: item.subtitle,
                                artistName: item.artist,
                                albumArtURL: item.artworkURL,
                                genres: item.genres)
        if let artist = media.artistName, let title = media.title {
            DispatchQueue.main.async {
                self.shazamMedia = media
                
                // MANUAL SHAZAM ARTWORK INTEGRATION: Notify RadioPlayer about manual Shazam match
                if let artworkURL = media.albumArtURL {
                    let userInfo: [String: Any] = [
                        "title": title,
                        "artist": artist,
                        "artworkURL": artworkURL.absoluteString,
                        "isManualShazam": true // Flag to distinguish manual vs automatic Shazam
                    ]
                    
                    NotificationCenter.default.post(
                        name: Notification.Name("ShazamVerifiedArtwork"),
                        object: nil,
                        userInfo: userInfo
                    )
                    
                    print("🎵 Manual Shazam: Posted artwork notification for '\(title)' by '\(artist)'")
                    print("   - Artwork URL: \(artworkURL.absoluteString)")
                }
                
                // Automatically search for YouTube video after Shazam identification
                self.fetchYouTubeVideo()
            }
        }
    }
}
