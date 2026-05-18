import Testing
import Foundation
import SnapshotTesting
@testable import PulsarTraceEngine

/// Pipeline coverage of offline transcription (R9, R11, R13): drive a real
/// fixture WAV through `FixturePlaybackSource` → `WhisperTranscriber` → R13
/// markdown, and snapshot the result.
///
/// Uses the `base` model (project-docs/DECISIONS.md D4) — small enough for the LLM dev loop.
/// The model is fetched/verified via `ModelStore` into the shared cache on
/// first run (R54c/R54d); subsequent runs reuse the cached, verified file.
///
/// Determinism (project rule): greedy, single thread, pinned model hash, and a
/// whisper sampler RNG seeded with a fixed per-call constant → byte-identical
/// transcript across runs even at a non-zero `Options.temperature`, so the
/// snapshot is stable. The document header (`## Transcript — …`) is wall-clock,
/// so the snapshot is taken of the *body only* (header covered by unit tests).
/// `.serialized`: whisper.cpp's Metal backend is single-context per process
/// (see `WhisperTranscriber` / project-docs/DECISIONS.md D8) — two `whisper_context`s alive
/// at once corrupt each other's GPU compute (manifests as a garbage language
/// like "af" and empty segments). Running these cases one at a time guarantees
/// at most one transcriber is alive, which is also the real engine's usage
/// pattern (one source = one transcriber).
@Suite("Transcription pipeline (R9/R11/R13)", .serialized)
struct TranscriptionPipelineTests {

    /// Fetch (or reuse) the verified `base` model. Returns its on-disk URL.
    ///
    /// Routed through `WhisperTestGate` so the model is fetched once
    /// process-wide — two suites resolving it via separate `ModelStore`
    /// instances would otherwise race on the shared cache files.
    private func baseModelURL() async throws -> URL {
        try await WhisperTestGate.model(ModelCatalog.base)
    }

    /// Body of a rendered transcript (everything after the wall-clock header).
    private func body(of markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        // Drop line 0 (marker is kept), replace line 1 (header) with a stable
        // placeholder so the snapshot doesn't depend on the run's wall clock.
        var out = Array(lines.map(String.init))
        if out.count > 1 { out[1] = "## Transcript — <recording-start>" }
        return out.joined(separator: "\n")
    }

    @Test("single-speaker-30s.wav transcribes to recognisable coffee-shop text")
    func singleSpeakerTranscript() async throws {
        let modelURL = try await baseModelURL()
        let transcriber = try WhisperTestTranscriber.make(modelURL: modelURL)
        let pipeline = OfflineTranscriptionPipeline()
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("single-speaker-30s.wav"), realtime: false)

        let output = try await WhisperTestGate.run {
            try await pipeline.run(
                source: source,
                transcriber: transcriber,
                recordingStart: Date(timeIntervalSince1970: 1_777_000_000)
            )
        }

        // R13 structure.
        #expect(output.markdown.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(output.markdown.contains("## Transcript — "))
        #expect(output.language == "en")
        #expect(!output.document.segments.isEmpty)

        // The fixture is the "coffee shop" monologue (audio-samples/sample-1).
        // Assert real recognised words, not just structure.
        let text = output.markdown.lowercased()
        #expect(text.contains("coffee"))
        #expect(text.contains("barista"))
        #expect(text.contains("cinnamon"))

        // Every utterance line uses the single placeholder speaker label.
        for line in output.markdown.split(separator: "\n") where line.hasPrefix("**[") {
            #expect(line.contains("] Speaker:**"))
        }

        // Snapshot the body — determinism makes this stable across runs.
        assertSnapshot(of: body(of: output.markdown), as: .lines)
    }

    @Test("silence-then-speech.wav produces no hallucinated text in the silence")
    func silenceProducesNoHallucination() async throws {
        let modelURL = try await baseModelURL()
        let transcriber = try WhisperTestTranscriber.make(modelURL: modelURL)
        let pipeline = OfflineTranscriptionPipeline()
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("silence-then-speech.wav"), realtime: false)

        let output = try await WhisperTestGate.run {
            try await pipeline.run(source: source, transcriber: transcriber)
        }

        // whisper must not hallucinate "thanks for watching" (or any stock
        // phrase) over the leading silence.
        let text = output.markdown.lowercased()
        #expect(!text.contains("thanks for watching"))
        #expect(!text.contains("please subscribe"))
        #expect(!text.contains("[blank_audio]"))
        // The speech portion is still transcribed.
        #expect(text.contains("coffee"))
    }

    @Test("a long internal silence does not derail post-silence speech (VAD)")
    func vadPreservesSpeechAfterLongInternalSilence() async throws {
        let modelURL = try await baseModelURL()
        let vadModelURL = try await WhisperTestGate.model(ModelCatalog.sileroVAD)

        // Reproduce the real-recording failure shape: two copies of the 30s
        // coffee-shop fixture separated by 60s of *pure digital silence* (a
        // paused far end). Fed whole to `whisper_full`, the silent 30s windows
        // drive the greedy decoder into a degenerate loop whose garbage prompt
        // drops the second speech block entirely. whisper's built-in Silero
        // VAD strips the silence before decoding, so both blocks survive.
        let speech = try await OfflineTranscriptionPipeline().accumulate(
            FixturePlaybackSource(
                file: FixtureLocator.audio("single-speaker-30s.wav"),
                realtime: false))
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 60)
        let buffer = speech + silence + speech

        let result = try await WhisperTestGate.run {
            let transcriber = try WhisperTestTranscriber.make(modelURL: modelURL)
            return try transcriber.transcribe(
                buffer, options: .init(vadModelURL: vadModelURL))
        }

        // The block *after* the 60s silence must still be transcribed. whisper
        // maps VAD-segment timestamps back to the original timeline, so a
        // second-block utterance lands well past the 90s silence boundary —
        // the regression is that block going missing.
        let coffeeAfterSilence = result.segments.filter {
            $0.start > .seconds(60) && $0.text.lowercased().contains("coffee")
        }
        #expect(!coffeeAfterSilence.isEmpty)
    }

    @Test("VAD-segmented transcription splits a turn at a mid-recording pause")
    func vadRegionsSplitTurnAtPause() async throws {
        let modelURL = try await baseModelURL()
        let vadModelURL = try await WhisperTestGate.model(ModelCatalog.sileroVAD)

        // Two copies of the 30 s coffee-shop fixture with 5 s of silence
        // between them — a speaker who talked, paused to listen, then resumed.
        // Fed whole to one `whisper_full`, both blocks fuse into segments that
        // straddle the pause; that long fused segment is what the time-order
        // merge floats ahead of an interleaved speaker. `detectSpeechRegions`
        // must instead split at the pause so every region — and so every
        // segment — lands wholly on one side of it.
        let speech = try await OfflineTranscriptionPipeline().accumulate(
            FixturePlaybackSource(
                file: FixtureLocator.audio("single-speaker-30s.wav"),
                realtime: false))
        let pauseSeconds = 5
        let silence = [Float](
            repeating: 0, count: AudioFormat.sampleRate * pauseSeconds)
        let buffer = speech + silence + speech
        let speechSeconds = Double(speech.count) / Double(AudioFormat.sampleRate)
        let pauseStart = Duration.seconds(speechSeconds)
        let pauseEnd = Duration.seconds(speechSeconds + Double(pauseSeconds))

        let (regions, result) = try await WhisperTestGate.run {
            let regions = try WhisperTranscriber.detectSpeechRegions(
                in: buffer, vadModelURL: vadModelURL)
            let transcriber = try WhisperTestTranscriber.make(modelURL: modelURL)
            let result = try transcriber.transcribe(
                buffer, regions: regions, options: .init())
            return (regions, result)
        }

        // The 5 s pause is the only gap wide enough to be a turn boundary, so
        // VAD yields at least two regions and none of them covers the pause.
        #expect(regions.count >= 2)
        #expect(!regions.contains { $0.start < pauseStart && $0.end > pauseEnd })
        #expect(regions.contains { $0.start >= pauseStart })   // the resumed turn

        // The regression this guards: no transcript segment spans the pause —
        // the resumed turn is its own segment past the gap, not fused into the
        // pre-pause turn (which is what mis-orders the merged final.md).
        #expect(!result.segments.contains {
            $0.start < pauseStart && $0.end > pauseEnd
        })
        #expect(result.segments.contains {
            $0.start >= pauseStart && $0.text.lowercased().contains("coffee")
        })
    }

    @Test("transcription is deterministic across repeated runs")
    func deterministicAcrossRuns() async throws {
        let modelURL = try await baseModelURL()
        let pipeline = OfflineTranscriptionPipeline()

        func transcribeOnce() async throws -> String {
            try await WhisperTestGate.run {
                let transcriber = try WhisperTestTranscriber.make(modelURL: modelURL)
                let source = FixturePlaybackSource(
                    file: FixtureLocator.audio("single-speaker-30s.wav"), realtime: false)
                let out = try await pipeline.run(
                    source: source,
                    transcriber: transcriber,
                    recordingStart: Date(timeIntervalSince1970: 1_777_000_000)
                )
                return out.markdown
            }
        }

        let first = try await transcribeOnce()
        let second = try await transcribeOnce()
        #expect(first == second)
    }
}
