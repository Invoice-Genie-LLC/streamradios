import UIKit
import ShazamKit
import AVFoundation

class ViewController: UIViewController, SHSessionDelegate {
    
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var infoLabel: UILabel!
    @IBOutlet var albumImage: UIImageView!

    private let audioEngine = AVAudioEngine()
    private let session = SHSession()
    private let signatureGenerator = SHSignatureGenerator()
    private var isListening = false

    override func viewDidLoad() {
        super.viewDidLoad()
        
        infoLabel.text = ""
        session.delegate = self
        
        configureAudioSession()
    }
    
    @IBAction func shazam() {
        AVAudioApplication.requestRecordPermission { granted in
            if granted {
                DispatchQueue.main.async {
                    self.titleLabel.text = "Preparing"
                }
                
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                    self.startListening()
                } catch {
                    DispatchQueue.main.async {
                        self.titleLabel.text = "Audio Session Error"
                        self.infoLabel.text = error.localizedDescription
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.titleLabel.text = "Please Enable Permissions"
                }
            }
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: audioSession)

        do {
            try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay])
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            stopListening()
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    startListening()
                }
            }
        default:
            break
        }
    }

    private func startListening() {
        guard !isListening else { return }
        isListening = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            do {
                try self.signatureGenerator.append(buffer, at: nil)
                self.session.matchStreamingBuffer(buffer, at: nil)
            } catch {
                print("Error appending buffer: \(error)")
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            DispatchQueue.main.async {
                self.titleLabel.text = "Listening"
            }
        } catch {
            DispatchQueue.main.async {
                self.titleLabel.text = "Audio Engine Error"
                self.infoLabel.text = error.localizedDescription
            }
        }
    }

    private func stopListening() {
        guard isListening else { return }
        isListening = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.async {
            self.titleLabel.text = "Stopped Listening"
        }
    }

    public func session(_ session: SHSession, didFind match: SHMatch) {
        guard let matchedMediaItem = match.mediaItems.first else {
            return
        }
        
        DispatchQueue.main.async {
            self.titleLabel.text = matchedMediaItem.title
            if let artist = matchedMediaItem.artist {
                self.infoLabel.text = "This song is by \(artist)"
            }
            if let artworkURL = matchedMediaItem.artworkURL, let data = try? Data(contentsOf: artworkURL) {
                self.albumImage.image = UIImage(data: data)
            }
        }
    }
}
