import Testing
import Foundation
@testable import PulsarTraceEngine

/// Pipeline coverage: drive the engine's `FrameConsumer` from each fixture-fed
/// `AudioFrameSource` and assert clean, uniform end-of-stream (R71, R75, R76).
@Suite("Source pipeline")
struct SourcePipelineTests {

    /// 16 kHz mono: a 30 s fixture yields ~1500 frames of 320 samples each.
    @Test("FixturePlaybackSource (fast) consumes a 30s fixture cleanly")
    func fixtureFastConsumption() async throws {
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("single-speaker-30s.wav"), realtime: false)
        let result = try await FrameConsumer().consume(source)

        // 29.8 s of audio → ~1490 frames; allow a small tolerance.
        #expect(result.frameCount > 1400)
        #expect(result.frameCount < 1600)
        #expect(result.sampleCount == result.frameCount * AudioFormat.samplesPerFrame)
    }

    @Test("FixturePlaybackSource is deterministic across runs")
    func fixtureDeterministic() async throws {
        func run() async throws -> Int {
            let source = FixturePlaybackSource(
                file: FixtureLocator.audio("two-speakers-alternating.wav"), realtime: false)
            return try await FrameConsumer().consume(source).frameCount
        }
        let a = try await run()
        let b = try await run()
        #expect(a == b)
    }

    @Test("realtime mode paces a 5s fixture at roughly wall-clock time")
    func fixtureRealtimePacing() async throws {
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("sine-440hz-5s.wav"), realtime: true)
        let started = ContinuousClock.now
        let result = try await FrameConsumer().consume(source)
        let elapsed = ContinuousClock.now - started

        #expect(result.frameCount == 250)  // 5.0 s / 20 ms
        // Real-time pacing: at least ~3 s of wall clock for 5 s of audio.
        #expect(elapsed > .seconds(3))
    }

    @Test("stop() terminates a realtime source cleanly mid-stream")
    func stopTerminatesCleanly() async throws {
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("single-speaker-30s.wav"), realtime: true)
        try await source.start()

        var count = 0
        for try await event in source {
            if case .frame = event { count += 1 }
            if count == 10 { await source.stop() }
        }
        // After stop the iterator finishes cleanly; no runaway consumption.
        #expect(count >= 10)
        #expect(count < 100)
    }

    @Test("Silence-then-speech fixture decodes to the expected length")
    func silenceThenSpeech() async throws {
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("silence-then-speech.wav"), realtime: false)
        let result = try await FrameConsumer().consume(source)
        // 5 s silence + 15 s speech = 20 s → ~1000 frames.
        #expect(result.frameCount > 950)
        #expect(result.frameCount < 1050)
    }

    @Test("PipeSource consumes framed PCM from a pipe and terminates on EOF")
    func pipeSourceFramedPCM() async throws {
        // Build a small framed PCM stream in memory and write it through a pipe.
        let pipe = Pipe()
        let frames = (0..<25).map { i in
            AudioFrame(
                samples: (0..<320).map { Float(($0 + i) % 64) / 64.0 },
                sequenceIndex: i)
        }
        var wire = Data()
        for f in frames { wire.append(FrameProtocol.encode(f)) }
        wire.append(FrameProtocol.encodeEndOfStream())

        let writeEnd = pipe.fileHandleForWriting
        Task.detached {
            try? writeEnd.write(contentsOf: wire)
            try? writeEnd.close()
        }

        let source = PipeSource(
            fd: pipe.fileHandleForReading.fileDescriptor, closeOnFinish: true)
        let result = try await FrameConsumer().consume(source)
        #expect(result.frameCount == 25)
    }

    @Test("PipeSource terminates on clean EOF even without the sentinel")
    func pipeSourceCleanEOF() async throws {
        let pipe = Pipe()
        var wire = Data()
        for i in 0..<5 {
            wire.append(FrameProtocol.encode(AudioFrame.silence(sequenceIndex: i)))
        }
        // No end-of-stream sentinel — just close the pipe.
        let writeEnd = pipe.fileHandleForWriting
        Task.detached {
            try? writeEnd.write(contentsOf: wire)
            try? writeEnd.close()
        }
        let source = PipeSource(
            fd: pipe.fileHandleForReading.fileDescriptor, closeOnFinish: true)
        let result = try await FrameConsumer().consume(source)
        #expect(result.frameCount == 5)
    }

    @Test("RawPCMPipeSource chunks unframed f32le PCM into 20ms frames")
    func rawPCMPipeSource() async throws {
        // 320 * 30 samples of raw little-endian Float32, no framing.
        let pipe = Pipe()
        let samples = (0..<(320 * 30)).map { Float($0 % 100) / 100.0 }
        let raw = FrameProtocol.littleEndianFloats(samples)
        let writeEnd = pipe.fileHandleForWriting
        Task.detached {
            try? writeEnd.write(contentsOf: raw)
            try? writeEnd.close()
        }
        let source = RawPCMPipeSource(
            fd: pipe.fileHandleForReading.fileDescriptor, closeOnFinish: true)
        let result = try await FrameConsumer().consume(source)
        #expect(result.frameCount == 30)
    }
}
