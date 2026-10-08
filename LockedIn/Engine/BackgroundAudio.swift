import AVFoundation
import Foundation

/// The focus sounds LockedIn can play during a session. All are generated in code (no audio files),
/// so they loop seamlessly and add nothing to the app's size. `none` is silence — the session still
/// needs *some* audio to stay awake in the background.
///
/// Dark, Balanced and Bright match Apple's Background Sounds of the same colors (brown, pink, white).
nonisolated enum BackgroundSound: String, CaseIterable, Codable, Sendable {
    case none, brown, pink, white, deep, ocean

    /// Stable integer handed to the sound generator.
    var code: Int {
        switch self {
        case .none: 0
        case .brown: 1
        case .pink: 2
        case .white: 3
        case .deep: 4
        case .ocean: 5
        }
    }

    var isSilent: Bool { self == .none }

    var name: String {
        switch self {
        case .none: "None"
        case .brown: "Dark"
        case .pink: "Balanced"
        case .white: "Bright"
        case .deep: "Deep"
        case .ocean: "Ocean"
        }
    }

    var blurb: String {
        switch self {
        case .none: "No sound"
        case .brown: "Deep, rumbly brown noise"
        case .pink: "Soft, natural pink noise"
        case .white: "Full white noise, masks sudden sounds"
        case .deep: "Even lower and calmer than Dark"
        case .ocean: "Brown noise that swells like surf"
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash.fill"
        case .brown: "moon.fill"
        case .pink: "waveform"
        case .white: "sun.max.fill"
        case .deep: "water.waves.and.arrow.down"
        case .ocean: "water.waves"
        }
    }
}

/// Keeps LockedIn running in the background during a session and, if the person picks one, plays a
/// focus sound. It loops a generated sound through a `.playAndRecord` session (output only — it
/// never records) so iOS keeps accepting Live Activity updates (see `LiveActivityController`). When
/// the sound is `none` it loops a second of silence, which still keeps the app awake.
///
/// Built on `AVAudioPlayer` on purpose: it survives interruptions (calls, Siri, other apps) and
/// resumes reliably in the background, where `AVAudioEngine` proved fragile (it failed to start or
/// re-activate its session, which let iOS suspend the app and miss locks and unlocks).
///
/// Note: the App Store doesn't allow silent audio *purely* to stay awake. A sound the person chooses
/// to play is fine, so picking a focus sound also makes the background audio legitimate.
final class BackgroundAudio: BackgroundKeepingAlive {
    private(set) var isRunning = false

    private var player: AVAudioPlayer?
    private var sound: BackgroundSound = .none
    private var volume: Float = 0.6
    private var cache: [BackgroundSound: Data] = [:]
    // Added on the main thread (init) and removed in the nonisolated deinit.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        observe()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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

    func setSound(_ sound: BackgroundSound) {
        guard sound != self.sound else { return }
        self.sound = sound
        guard isRunning else { return }
        // Swap the looping buffer without dropping the audio session, so tracking never pauses.
        do {
            let next = try makePlayer()
            next.play()
            player?.stop()
            player = next
        } catch {
            log("Couldn't switch the sound: \(error.localizedDescription)")
        }
    }

    func setVolume(_ volume: Double) {
        self.volume = Float(max(0, min(1, volume)))
        player?.volume = self.volume
    }

    // MARK: Audio

    private func play() throws {
        let session = AVAudioSession.sharedInstance()
        // Play-and-record (output only) so iOS accepts Live Activity updates from the background;
        // mixWithOthers keeps it from interrupting the person's music.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        if player == nil { player = try makePlayer() }
        player?.volume = volume
        guard player?.play() == true else {
            throw NSError(domain: "LockedIn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Playback didn't start"])
        }
    }

    private func makePlayer() throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(data: data(for: sound))
        player.numberOfLoops = -1
        player.volume = volume
        player.prepareToPlay()
        return player
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

    private func data(for sound: BackgroundSound) -> Data {
        if let cached = cache[sound] { return cached }
        let wav = Self.makeWAV(for: sound)
        cache[sound] = wav
        return wav
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                switch type {
                case .began:
                    self.log("Background audio interrupted (call, Siri, or another app)")
                case .ended:
                    // Reactivate; iOS may need a moment after the interrupting app lets go.
                    self.restart(after: "an interruption")
                    if options.contains(.shouldResume) { self.player?.play() }
                default:
                    break
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

    // MARK: Sound generation

    /// Builds a seamless ~20-second loop of the sound as a 16-bit mono WAV. The ends are crossfaded
    /// so the loop point doesn't click, which matters for the low, slow brown-based sounds.
    private static func makeWAV(for sound: BackgroundSound) -> Data {
        let sampleRate = 44_100
        guard !sound.isSilent else { return pcmWAV(samples: [Int16](repeating: 0, count: sampleRate), sampleRate: sampleRate) }

        let length = sampleRate * 20
        let fade = sampleRate / 20 // 50 ms
        var state = NoiseState()
        state.sampleRate = Double(sampleRate)

        var floats = [Float](repeating: 0, count: length + fade)
        for i in floats.indices { floats[i] = state.next(sound: sound.code) }
        // Blend the head with the natural continuation past the loop body, so end → start is smooth.
        for i in 0..<fade {
            let t = Float(i) / Float(fade)
            floats[i] = floats[i] * t + floats[length + i] * (1 - t)
        }

        var samples = [Int16](repeating: 0, count: length)
        for i in 0..<length {
            samples[i] = Int16(max(-1, min(1, floats[i])) * 32_767)
        }
        return pcmWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Wraps 16-bit mono PCM samples in a WAV container.
    private static func pcmWAV(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                  // format chunk size
        append(UInt16(1))                   // PCM
        append(UInt16(1))                   // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))      // bytes per second
        append(UInt16(2))                   // bytes per frame
        append(UInt16(16))                  // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(dataSize)
        samples.withUnsafeBufferPointer { wav.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return wav
    }
}

/// Colored-noise generators and their filter state, used to fill the looping buffer.
struct NoiseState {
    var sampleRate: Double = 44_100

    private var rng: UInt64 = 0x2545F4914F6CDD1D
    private var pink = (b0: 0.0, b1: 0.0, b2: 0.0, b3: 0.0, b4: 0.0, b5: 0.0, b6: 0.0)
    private var brownLast = 0.0
    private var deepLast = 0.0
    private var oceanPhase = 0.0

    /// One sample in [-1, 1] for the given `BackgroundSound.code`.
    mutating func next(sound: Int) -> Float {
        guard sound != BackgroundSound.none.code else { return 0 }
        let w = white()
        let value: Double
        switch sound {
        case BackgroundSound.pink.code:
            value = pinkSample(w) * 0.85
        case BackgroundSound.brown.code:
            value = brownSample(w)
        case BackgroundSound.deep.code:
            value = deepSample(w)
        case BackgroundSound.ocean.code:
            value = oceanSample(w)
        default: // white
            value = w * 0.5
        }
        // A little headroom, then hard clamp as a safety net.
        return Float(max(-1, min(1, value * 0.9)))
    }

    private mutating func white() -> Double {
        // xorshift64*
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let x = rng &* 0x2545F4914F6CDD1D
        return Double(Int64(bitPattern: x)) / Double(Int64.max)
    }

    private mutating func pinkSample(_ w: Double) -> Double {
        // Paul Kellet's refined pink-noise filter.
        pink.b0 = 0.99886 * pink.b0 + w * 0.0555179
        pink.b1 = 0.99332 * pink.b1 + w * 0.0750759
        pink.b2 = 0.96900 * pink.b2 + w * 0.1538520
        pink.b3 = 0.86650 * pink.b3 + w * 0.3104856
        pink.b4 = 0.55000 * pink.b4 + w * 0.5329522
        pink.b5 = -0.7616 * pink.b5 - w * 0.0168980
        let out = pink.b0 + pink.b1 + pink.b2 + pink.b3 + pink.b4 + pink.b5 + pink.b6 + w * 0.5362
        pink.b6 = w * 0.115926
        return out * 0.11
    }

    private mutating func brownSample(_ w: Double) -> Double {
        brownLast = (brownLast + 0.02 * w) / 1.02
        return brownLast * 3.5
    }

    private mutating func deepSample(_ w: Double) -> Double {
        let brown = brownSample(w)
        // Extra one-pole low-pass for an even deeper, smoother tone.
        deepLast += 0.05 * (brown - deepLast)
        return deepLast * 1.6
    }

    private mutating func oceanSample(_ w: Double) -> Double {
        let brown = brownSample(w)
        oceanPhase += 2 * .pi * 0.06 / sampleRate
        if oceanPhase > 2 * .pi { oceanPhase -= 2 * .pi }
        let swell = 0.55 + 0.45 * sin(oceanPhase) // slow surf-like rise and fall
        return brown * swell
    }
}
