import Testing
@testable import PulsarTraceEngine

/// Layer 1 — `ToneDetector`, the Goertzel frequency analysis behind
/// `pulsartrace doctor --capture-test` (R68). The play+capture half is
/// device-gated; the math is verified here on synthesized tones.
@Suite("ToneDetector (capture-test, R68)")
struct ToneDetectorTests {

    private let sampleRate = 16_000

    @Test("a synthesized tone reads back as its own frequency")
    func dominantOfPureTone() {
        for frequency in [220.0, 440.0, 1000.0] {
            let tone = ToneDetector.sine(
                frequencyHz: frequency, sampleRate: sampleRate,
                duration: .seconds(1))
            let dominant = ToneDetector.dominantFrequency(
                tone, sampleRate: sampleRate)
            #expect(abs(dominant - frequency) <= 5,
                    "expected ~\(frequency) Hz, got \(dominant) Hz")
        }
    }

    @Test("power peaks at the tone's frequency and is low away from it")
    func powerConcentratesAtTone() {
        let tone = ToneDetector.sine(
            frequencyHz: 440, sampleRate: sampleRate, duration: .seconds(1))
        let onTone = ToneDetector.power(of: tone, at: 440, sampleRate: sampleRate)
        let offTone = ToneDetector.power(of: tone, at: 1500, sampleRate: sampleRate)
        #expect(onTone > offTone * 50)
    }

    @Test("matches() accepts the played tone and rejects a different one")
    func matchesWithinTolerance() {
        let tone = ToneDetector.sine(
            frequencyHz: 440, sampleRate: sampleRate, duration: .seconds(2))
        #expect(ToneDetector.matches(tone, expectedHz: 440, sampleRate: sampleRate))
        #expect(!ToneDetector.matches(tone, expectedHz: 880, sampleRate: sampleRate))
    }

    @Test("empty input yields zero, never a crash")
    func emptyInput() {
        #expect(ToneDetector.dominantFrequency([], sampleRate: sampleRate) == 0)
        #expect(ToneDetector.power(of: [], at: 440, sampleRate: sampleRate) == 0)
        #expect(!ToneDetector.matches([], expectedHz: 440, sampleRate: sampleRate))
    }

    @Test("a near-but-not-exact tone still matches within tolerance")
    func nearToneMatches() {
        // 448 Hz is within the 25 Hz default tolerance of an expected 440 Hz.
        let tone = ToneDetector.sine(
            frequencyHz: 448, sampleRate: sampleRate, duration: .seconds(2))
        #expect(ToneDetector.matches(tone, expectedHz: 440, sampleRate: sampleRate))
    }
}
