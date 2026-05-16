import Testing
import AVFoundation
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Unit coverage of `AudioConverter` — resample/downmix to 16 kHz mono Float32.
/// No audio devices: synthetic `AVAudioPCMBuffer`s are fed directly.
@Suite("AudioConverter")
struct AudioConverterTests {

    /// Build a non-interleaved Float32 buffer of `frames` samples, each channel
    /// filled with `value`.
    private func buffer(
        sampleRate: Double, channels: AVAudioChannelCount,
        frames: AVAudioFrameCount, value: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buffer
    }

    @Test("48 kHz stereo downmixes and resamples to 320-sample 16 kHz frames")
    func resampleAndDownmix() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false)!
        let converter = try AudioConverter(inputFormat: format)

        // 4800 input frames @ 48 kHz → ~1600 @ 16 kHz → ~5 whole 320-sample
        // frames. The resampler's one-time filter delay holds back a fraction
        // of a frame on the priming call, so allow 4–5; every frame must be a
        // full 320 samples.
        let first = try converter.convert(
            buffer(sampleRate: 48_000, channels: 2, frames: 4800))
        #expect(first.count == 4 || first.count == 5)
        #expect(first.allSatisfy { $0.count == AudioFormat.samplesPerFrame })

        // A second identical buffer: the held-back samples are emitted now, so
        // the two calls together cover the expected ~10 frames (3200 / 320).
        let second = try converter.convert(
            buffer(sampleRate: 48_000, channels: 2, frames: 4800))
        #expect(second.allSatisfy { $0.count == AudioFormat.samplesPerFrame })
        #expect(first.count + second.count >= 9)
    }

    @Test("A partial tail is carried across calls, not lost")
    func residualCarriesAcrossCalls() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let converter = try AudioConverter(inputFormat: format)

        // 500 samples → one 320-frame, 180 left over.
        let first = try converter.convert(
            buffer(sampleRate: 16_000, channels: 1, frames: 500))
        #expect(first.count == 1)
        // 180 carried + 500 = 680 → two more 320-frames, 40 left over.
        let second = try converter.convert(
            buffer(sampleRate: 16_000, channels: 1, frames: 500))
        #expect(second.count == 2)
    }

    @Test("flush drains a zero-padded final partial frame")
    func flushPadsFinalFrame() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let converter = try AudioConverter(inputFormat: format)

        _ = try converter.convert(
            buffer(sampleRate: 16_000, channels: 1, frames: 100))
        let tail = converter.flush()
        #expect(tail?.count == AudioFormat.samplesPerFrame)
        // A second flush has nothing left to drain.
        #expect(converter.flush() == nil)
    }
}
