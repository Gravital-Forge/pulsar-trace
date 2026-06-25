import Testing
import Foundation
@testable import PulsarTraceEngine

/// Pipeline coverage of the live pass (PT-R10, PT-R12, PT-R14, PT-R16, PT-R35a, PT-R36, PT-R37).
///
/// Drives a real fixture WAV through `FixturePlaybackSource` →
/// `StreamingTranscriber` (sliding-window Parakeet + LocalAgreement-2) →
/// append-only `live.md`, with no live diarization (the windowed-pyannote
/// subprocess is exercised by the manual smoke test — these tests stay fast
/// and device/network-free after the one-time model download).
///
/// Determinism: Parakeet's greedy TDT decode is deterministic, so structure
/// and keyword assertions are stable. Transcript text is asserted via
/// fixture keywords (PT-P5-D1 supersedes the old whisper snapshot strategy —
/// keywords survive small wording drift between decoder versions; the
/// retired snapshot lives in git history).
///
/// `.serialized`: one resident ANE model serves the whole process
/// (`ParakeetTestEngine`); serializing keeps decode interleaving sane.
@Suite("Streaming pipeline", .serialized)
struct StreamingPipelineTests {

    /// A throwaway recording folder for one test.
    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-stream-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fixed recording-start instant for deterministic headers.
    private var fixedStart: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 16; c.hour = 14; c.minute = 30
        return Calendar.current.date(from: c)!
    }

    @Test("fast-mode live run grows an append-only live.md with provisional labels")
    func liveRunProducesProvisionalLiveMD() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let pipeline = StreamingPipeline()
        // Fast mode keeps the suite quick; the realtime/lag test below
        // covers PT-R10 pacing.
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("two-speakers-alternating.wav"),
            realtime: false)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_two-speakers-alternating"),
            systemTranscriber: transcriber,
            systemSource: source,
            library: nil)

        // PT-R35a/PT-R37: file created with marker + header.
        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1].hasPrefix("## Transcript — "))

        // PT-R16/§2b: this run has no live diarizer, so the live pass has no
        // diarization coverage for any utterance. A no-coverage utterance is
        // labelled with the neutral provisional marker `Speaker?` — never
        // `Them?`, which would falsely attribute it to the first tracked
        // speaker (the §2b label-collapse bug).
        #expect(text.contains("Speaker?:"))
        #expect(!text.contains("Them?:"))     // no false speaker attribution
        #expect(!text.contains("Speaker_"))   // no offline-style labels
        #expect(output.utteranceLines > 0)

        // Parakeet has no language-ID head — the live pass reports the
        // "no information" contract value (the refine pass detects/pins).
        #expect(output.language == "unknown")
    }

    @Test("live.md carries the fixture's distinctive words with monotonic timestamps")
    func liveMDContentAndStructure() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let pipeline = StreamingPipeline()
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("two-speakers-alternating.wav"),
            realtime: false)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_two-speakers-alternating"),
            systemTranscriber: transcriber,
            systemSource: source,
            library: nil)

        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        let lower = text.lowercased()
        // Distinctive fixture words from the committed live transcript. These
        // were cross-checked against the retired whisper snapshot (git
        // history: __Snapshots__/StreamingPipelineTests/liveMDSnapshot.1.txt)
        // for distinctiveness, then narrowed to words Parakeet's
        // LocalAgreement-2 reliably *commits* before end-of-stream. Under
        // LocalAgreement-2 the fixture's final clause ("transformation layer")
        // stays in the uncommitted tail at end-of-stream — there is no
        // flush-commit step — so it is not asserted. (Whisper's flush used to
        // commit that clause, which is why the retired snapshot contained it.)
        // Case-insensitive `contains`: robust to small wording drift between
        // decoders, loud on a real break.
        for keyword in ["coffee", "barista", "bookstore", "ingestion", "formats"] {
            #expect(lower.contains(keyword), "live.md should mention '\(keyword)'")
        }

        // Structure: marker first, header second, several non-empty
        // utterance lines whose timestamps never go backwards.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1].hasPrefix("## Transcript — "))
        let utterances = lines.filter { $0.hasPrefix("**[") }
        #expect(utterances.count >= 3)
        for line in utterances {
            // "**[HH:MM:SS] label:** text" — text part must be non-empty.
            // `#require` rather than `if let`: a malformed utterance line is a
            // real break, not something to silently skip.
            let textStart = try #require(
                line.range(of: ":** "), "malformed utterance line: \(line)")
            #expect(!line[textStart.upperBound...]
                .trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let stamps = utterances.compactMap { line -> String? in
            guard let close = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        }
        #expect(stamps == stamps.sorted(), "utterance timestamps must be monotonic")
    }

    /// Real-time-paced run: assert `live.md` grows monotonically and lag stays
    /// **bounded** under backpressure.
    ///
    /// Note on PT-R10: Parakeet on the ANE decodes far faster than real time,
    /// so lag should stay small here; the assertion below is deliberately
    /// the same *bounded*-lag invariant as before (not a tight latency
    /// target — that's the manual smoke test's job), so a slow first-run
    /// model load cannot flake this test.
    @Test("real-time-paced run: live.md grows monotonically, lag stays bounded")
    func realtimePacedRunBoundedLag() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Sample live.md's size on a background poller while the realtime run
        // proceeds, to assert strictly monotonic growth (PT-R36).
        let liveURL = folder.appendingPathComponent("live.md")
        let sizes = SizeSamples()
        let poller = Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(400))
                if let data = try? Data(contentsOf: liveURL) {
                    await sizes.record(data.count)
                }
            }
        }

        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let pipeline = StreamingPipeline()
        // realtime: true — frames at wall-clock pace, exercising PT-R10.
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("two-speakers-alternating.wav"),
            realtime: true)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_two-speakers-alternating"),
            systemTranscriber: transcriber,
            systemSource: source,
            library: nil)
        poller.cancel()

        #expect(output.utteranceLines > 0)
        // Backpressure invariant: CPU whisper cannot keep
        // real-time pace, so the backpressure path skips the anchor forward to
        // keep lag bounded. The fixture is ~24 s; lag must stay well under the
        // whole-recording length — i.e. it does not grow without limit.
        #expect(output.maxLagSeconds < 24.0)

        // PT-R36/PT-R12: every observed live.md size is ≥ the previous — strictly
        // monotonic growth, never a shrink or rewrite.
        let observed = await sizes.values
        for i in 1..<max(observed.count, 1) {
            #expect(observed[i] >= observed[i - 1])
        }
    }

    /// PT-R19 mic-echo dedup, proven deterministically at the `LiveSink` level.
    ///
    /// Why not a full two-stream pipeline run: the system and mic streams are
    /// consumed through one merged `AsyncStream`, and under `realtime: false`
    /// the interleaving of system vs mic frames is **nondeterministic** — the
    /// mic stream can race ahead so a mic utterance is checked *before* its
    /// system counterpart has been noted, in which case the dedup legitimately
    /// does not fire. A `>= 1` assertion over that racing pipeline is flaky
    /// (observed: it fails ~1 run in 3). The dedup itself is deterministic; the
    /// stream race is what is not. So this test drives `LiveSink` directly with
    /// a controlled ordering — the same `LiveSink` the pipeline uses, with its
    /// real `MicEchoDedup` — and proves that a mic utterance echoing a
    /// previously-seen system utterance is dropped, while a distinct mic
    /// utterance is kept. The `MicEchoDedup` decision core has its own unit
    /// suite; this proves `LiveSink`'s *use* of it (PT-R19 integration).
    @Test("mic-echo: LiveSink drops a mic utterance echoing system audio (PT-R19)")
    func liveSinkDropsMicEcho() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let liveURL = folder.appendingPathComponent("live.md")
        let writer = LiveMarkdownWriter(
            fileURL: liveURL, recordingStart: fixedStart)
        try await writer.start()
        let sink = LiveSink(writer: writer, recordingStart: fixedStart)

        // A system speaker says something at ~2 s.
        let systemUtterance = CommittedUtterance(
            start: .seconds(2), end: .seconds(5),
            text: "lets review the auth flow before the demo")
        await sink.appendSystemUtterance(
            systemUtterance, label: "Them?",
            realElapsed: .seconds(6))

        // The mic picks the *same words* up off the speakers, 0.4 s later —
        // a textbook PT-R19 echo, well within the ±5 s window.
        let micEcho = CommittedUtterance(
            start: .milliseconds(2_400), end: .milliseconds(5_400),
            text: "lets review the auth flow before the demo")
        await sink.appendMicUtterance(micEcho, realElapsed: .seconds(6))

        // A genuinely distinct mic utterance — the user actually speaking — is
        // NOT an echo and must be kept.
        let micReal = CommittedUtterance(
            start: .seconds(8), end: .seconds(10),
            text: "sounds good i will share my screen now")
        await sink.appendMicUtterance(micReal, realElapsed: .seconds(11))

        await writer.finish()
        let stats = await sink.stats()

        // PT-R19: exactly the echo was dropped — the distinct mic line was kept.
        #expect(stats.micEchoesDropped == 1)
        // 2 lines written: the system utterance + the real mic utterance.
        #expect(stats.utteranceLines == 2)

        let text = try String(contentsOf: liveURL, encoding: .utf8)
        #expect(text.contains("Them?:** lets review the auth flow"))
        #expect(text.contains("You:** sounds good i will share my screen"))
        // The echoed line never reached live.md.
        #expect(!text.contains("You:** lets review the auth flow"))
    }
}

/// Thread-safe collector of live.md size samples for the monotonic-growth
/// assertion.
actor SizeSamples {
    private(set) var values: [Int] = []
    func record(_ size: Int) { values.append(size) }
}
