import Foundation
import Testing
@testable import LockedIn

struct BackgroundSoundTests {
    private func samples(_ sound: BackgroundSound, count: Int = 4096) -> [Float] {
        var state = NoiseState()
        return (0..<count).map { _ in state.next(sound: sound.code) }
    }

    @Test func noneIsSilent() {
        #expect(samples(.none, count: 128).allSatisfy { $0 == 0 })
    }

    @Test func everySoundStaysInRange() {
        for sound in BackgroundSound.allCases where sound != .none {
            #expect(samples(sound).allSatisfy { $0 >= -1 && $0 <= 1 }, "\(sound.name) went out of range")
        }
    }

    @Test func generatorsAreDeterministic() {
        // A fresh state uses a fixed seed, so the same sound renders identically each time.
        #expect(samples(.pink) == samples(.pink))
        #expect(samples(.brown) == samples(.brown))
    }

    @Test func lowerColorsAreSmootherThanWhite() {
        func roughness(_ s: [Float]) -> Float {
            zip(s, s.dropFirst()).reduce(0) { $0 + abs($1.1 - $1.0) } / Float(s.count - 1)
        }
        let white = roughness(samples(.white))
        #expect(roughness(samples(.pink)) < white)
        #expect(roughness(samples(.brown)) < white)
        #expect(roughness(samples(.deep)) < white)
    }

    @Test func settingsPersistTheSoundAndVolume() {
        let defaults = UserDefaults(suiteName: "test.sounds.\(UUID().uuidString)")!
        let first = AppSettings(defaults: defaults)
        first.backgroundSound = .ocean
        first.soundVolume = 0.33

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.backgroundSound == .ocean)
        #expect(reloaded.soundVolume == 0.33)
        #expect(reloaded.engineConfig.sound == .ocean)
        #expect(reloaded.engineConfig.soundVolume == 0.33)
    }
}
