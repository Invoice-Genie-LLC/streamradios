//
//  ShazamView.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import SwiftUI
import ShazamKit

struct ShazamView: View {
    @StateObject private var viewModel: ShazamViewModel = .init()
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack {
            if viewModel.matching {
                ProgressView("Matching...")
            } else {
                VStack(spacing: 32) {
                    Image(systemName: "shazam.logo")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .padding()
                    
                    Button(action: startShazam) {
                        Text("Start Shazam")
                            .font(.title)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func startShazam() {
        viewModel.start()
    }
}

class ShazamViewModel: NSObject, ObservableObject {
    @Published var matching = false

    private var audioEngine: AVAudioEngine?
    private var session: SHSession?
    private var signatureGenerator: SHSignatureGenerator?

    func start() {
        matching = true
        setupShazamSession()
    }

    func stop() {
        matching = false
        stopShazamSession()
    }

    private func setupShazamSession() {
        session = SHSession()
        session?.delegate = self
        audioEngine = AVAudioEngine()
        signatureGenerator = SHSignatureGenerator()

        let inputNode = audioEngine?.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)

        inputNode?.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do {
                try self.signatureGenerator?.append(buffer, at: nil)
                self.session?.matchStreamingBuffer(buffer, at: nil)
            } catch {
                print("Error appending buffer: \(error)")
            }
        }

        do {
            audioEngine?.prepare()
            try audioEngine?.start()
        } catch {
            print("Error starting audio engine: \(error)")
        }
    }

    private func stopShazamSession() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        session = nil
        signatureGenerator = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
}

extension ShazamViewModel: SHSessionDelegate {
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let matchedMediaItem = match.mediaItems.first else { return }
        DispatchQueue.main.async {
            print("Matched: \(matchedMediaItem.title ?? "Unknown Title") by \(matchedMediaItem.artist ?? "Unknown Artist")")
        }
    }
}
