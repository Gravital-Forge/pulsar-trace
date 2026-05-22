import Testing
import Foundation
@testable import PulsarTraceEngine

/// Proves the `abort_callback` plumbing genuinely interrupts a real
/// `whisper_full` decode on the CPU backend — the core of the watchdog
/// mechanism. `.serialized` because each test builds a `WhisperTranscriber`
/// (one whisper context per process, D8).
///
/// Granularity note (verified against vendor/whisper.cpp): this build polls
/// `abort_callback` at encode/decode-*step* boundaries, not between every ggml
/// graph node — `whisper_encode_internal` / `whisper_decode_internal` consult
/// it only after each graph compute completes (whisper.cpp:2455 / :2977), and
/// the sched-based `ggml_graph_compute_helper` does not install the callback on
/// its backends. So a pre-cancelled token bails at the *first* such boundary:
/// after the (un-abortable) mel + the first window's encode, skipping every
/// remaining window's encode and the whole decode loop. That is exactly the
/// granularity the watchdog needs — it interrupts the decode of a long buffer
/// well before it finishes. Two consequences shape the test below:
///   - We pass an explicit `language` so whisper skips its un-abortable
///     `whisper_lang_auto_detect` encode pass (a fixed cost that would
///     otherwise dominate the aborted call on unlabeled noise and mask the
///     interruption — see the throwaway timing probe in the task notes).
///   - We use a multi-window buffer so the abortable per-window work the abort
///     skips dwarfs the one mel + one encode it cannot.
@Suite("WhisperAbort", .serialized)
struct WhisperAbortTests {

    /// Explicit language → whisper skips the un-abortable language-detect encode
    /// and decodes straight through, so the abort's effect is isolated.
    private static let opts = WhisperTranscriber.Options(language: "en")

    /// A buffer long enough that a full decode spans many 30 s windows, so a
    /// pre-cancelled abort — which bails after the first window's encode — is an
    /// obvious contrast. 120 s of low white noise at 16 kHz: non-silent (passes
    /// any peak gate) and gives whisper real, multi-window work.
    private func longBuffer() -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<(16_000 * 120)).map { _ in
            Float.random(in: -0.05...0.05, using: &rng)
        }
    }

    /// ~8 s of real speech samples from the committed mono 16 kHz fixture,
    /// reusing `WAVReader` (the engine's WAV-into-`[Float]` path).
    private static func eightSecondSpeechWindow() throws -> [Float] {
        let wav = try WAVReader(contentsOf: FixtureLocator.audio("single-speaker-30s.wav"))
        return Array(wav.samples.prefix(16_000 * 8))
    }

    @Test("a pre-cancelled abort token returns far faster than a full decode, and the context still works after")
    func preCancelledAbortInterruptsRealDecode() async throws {
        let modelURL = try await WhisperTestGate.model(ModelCatalog.base)
        try await WhisperTestGate.run {
            let t = try WhisperTestTranscriber.make(modelURL: modelURL)
            let audio = longBuffer()

            // Baseline: a full decode with no abort.
            let fullStart = ContinuousClock.now
            _ = try t.transcribeWindow(
                audio, windowStart: .zero, options: Self.opts, abort: nil)
            let full = ContinuousClock.now - fullStart

            // Same decode, pre-cancelled: whisper bails on its first abort poll
            // (after the first window's encode), skipping every later window.
            let token = AbortToken()
            token.cancel()
            let abortStart = ContinuousClock.now
            _ = try? t.transcribeWindow(
                audio, windowStart: .zero, options: Self.opts, abort: token)
            let aborted = ContinuousClock.now - abortStart

            // The aborted call is dramatically shorter than the full decode.
            // Measured margin on this CPU base model is ~0.12 (120 s buffer);
            // the < 1/4 bound has ample headroom.
            #expect(aborted < full / 4,
                    "aborted=\(aborted) was not << full=\(full)")

            // The context is still usable — the abort released metalLock cleanly.
            let after = try t.transcribeWindow(
                audio, windowStart: .zero, options: Self.opts, abort: AbortToken())
            #expect(after.language != "")
        }
    }

    @Test("max_tokens cap still yields a normal transcript on a speech fixture")
    func capDoesNotTruncateNormalSpeech() async throws {
        let modelURL = try await WhisperTestGate.model(ModelCatalog.base)
        try await WhisperTestGate.run {
            let t = try WhisperTestTranscriber.make(modelURL: modelURL)
            let window = try Self.eightSecondSpeechWindow()
            let r = try t.transcribeWindow(
                window, windowStart: .zero, options: .init(), abort: nil)
            #expect(!r.segments.isEmpty)
        }
    }
}
