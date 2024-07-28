//
//  ShazamViewModel.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import SwiftUI
import ShazamKit
import AVKit

struct ShazamMedia: Decodable {
    let title: String?
    let subtitle: String?
    let artistName: String?
    let albumArtURL: URL?
    let genres: [String]
}

class ShazamViewModel: NSObject, ObservableObject, SHSessionDelegate {
    @Published var shazamMedia = ShazamMedia(title: "",
                                             subtitle: "Subtitle...",
                                             artistName: "",
                                             albumArtURL: URL(string: "https://example.com/default.jpg"),
                                             genres: ["Pop"])
    @Published var isRecording = false
    
    private var audioEngine = AVAudioEngine()
    private var session = SHSession()
    
    override init() {
        super.init()
        session.delegate = self
        configureAudioSession()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up the audio session: \(error)")
        }
    }
    
    public func startOrEndListening() {
        guard !audioEngine.isRunning else {
            stopListening()
            return
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self, granted else {
                DispatchQueue.main.async {
                    print("Microphone permission is denied")
                }
                return
            }
            self.setupAudioEngine()
        }
    }
    
    private func setupAudioEngine() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, when) in
            self?.applyGain(to: buffer)
            self?.session.matchStreamingBuffer(buffer, at: when)
        }
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Error starting audio engine: \(error)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    private func applyGain(to buffer: AVAudioPCMBuffer) {
        let gain: Float = 2.0 // Adjust the gain value as needed
        let frameLength = Int(buffer.frameLength)
        let channels = UnsafeBufferPointer(start: buffer.floatChannelData, count: Int(buffer.format.channelCount))
        
        for channel in channels {
            for frame in 0..<frameLength {
                channel[frame] *= gain
            }
        }
    }
    
    func stopListening() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch interruptionType {
        case .began:
            print("Audio interruption began.")
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                print("Audio interruption ended. Resuming audio engine...")
                setupAudioEngine()
            }
        @unknown default:
            break
        }
    }
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        DispatchQueue.main.async {
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
            }
        }
    }
}
