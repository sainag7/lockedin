import AVFoundation
import Foundation

/// Keeps LockedIn running in the background during a session by looping a silent sound through a
/// mixable audio session, so it never interrupts your music. While it plays, iOS keeps delivering
/// the phone's lock and unlock signals to LockedIn, whichever app is open.
///
/// The session uses the `.playAndRecord` category (it only ever plays; it never records). iOS drops
/// Live Activity updates from an app kept awake only by a plain `.playback` session, but allows them
/// from a `.playAndRecord` one (see `LiveActivityController`). It needs no microphone permission,
/// because nothing opens the input.
///
/// Note: the App Store doesn't allow silent audio just to stay awake. Publishing would mean turning
/// this into audible focus sounds (rain, brown noise) the person chooses to play.
final class SilentAudioKeepAlive: BackgroundKeepingAlive {
    private(set) var isRunning = false

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        observe()
    }

    func start() {
        guard !isRunning else {
            ensurePlaying()
            return
        }
        do {
            try play()
            isRunning = true
            log("Background tracking on")
        } catch {
            log("Background tracking couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log("Background tracking off")
    }

    func ensurePlaying() {
        guard isRunning, player?.isPlaying != true else { return }
        restart(after: "finding it stopped")
    }

    // MARK: Audio

    private func play() throws {
        let session = AVAudioSession.sharedInstance()
        // Play-and-record (output only) so iOS accepts Live Activity updates from the background;
        // mixWithOthers keeps it from interrupting the person's music.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        if player == nil {
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            self.player = player
        }
        player?.prepareToPlay()
        guard player?.play() == true else {
            throw NSError(domain: "LockedIn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Playback didn't start"])
        }
    }

    private func restart(after reason: String) {
        guard isRunning else { return }
        do {
            try play()
            log("Background tracking resumed after \(reason)")
        } catch {
            log("Background tracking couldn't resume after \(reason): \(error.localizedDescription)")
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                switch type {
                case .began: self.log("Background audio interrupted (call, Siri, or another app)")
                case .ended: self.restart(after: "an interruption")
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensurePlaying() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player = nil
                self?.restart(after: "an audio system reset")
            }
        })
    }

    /// One second of 8 kHz, 16-bit mono silence as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8_000
        let dataSize = sampleRate * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))          // format chunk size
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(sampleRate)
        append(sampleRate * 2)      // bytes per second
        append(UInt16(2))           // bytes per frame
        append(UInt16(16))          // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }()
}
