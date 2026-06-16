import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// End-to-end offline diarization on the committed audio fixtures, against
/// the real FluidAudio CoreML models (first run downloads them — see
/// CLAUDE.md's narrow-filter notes). Replaces the retired Python pyannote
/// subprocess suite (D40).
@Suite("DiarizationE2E (FluidAudio offline, real models)", .serialized)
struct DiarizationE2ETests {

    private func fixtureURL(_ name: String) -> URL {
        // Mirror the path resolution the old suite used (repo-root relative
        // via #filePath): Tests/Fixtures/audio/<name>.wav
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // PipelineTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Fixtures/audio/\(name).wav")
    }

    /// Structural shape of a real diarization on the two-speaker clip — the
    /// invariants that hold regardless of how the clustering partitions
    /// speakers: non-empty 256-d per-speaker embeddings, a 64-hex
    /// content-digest revision, and spans covering a meaningful share of the
    /// clip. (Speaker count is `twoSpeakersSeparate`'s job.)
    @Test func twoSpeakersAlternatingShape() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            wavPath: fixtureURL("two-speakers-alternating"))

        #expect(!result.speakers.isEmpty)
        #expect(!result.spans.isEmpty)
        #expect(!result.embeddings.isEmpty)
        #expect(result.embeddings.count == result.speakers.count)
        #expect(result.embeddings.allSatisfy { $0.vector.count == 256 })
        #expect(result.modelRevision.count == 64)
        // Spans must cover a meaningful share of a 24 s two-speaker clip.
        let covered = result.spans.reduce(0.0) { $0 + ($1.end - $1.start).seconds }
        #expect(covered > 10.0)
    }

    /// The two synthetic ElevenLabs voices in `two-speakers-alternating.wav`
    /// MUST separate into 2 speakers. FluidAudio's default VBx evidence
    /// weight (Fa 0.07) collapses them on clips this short; `DiarizerEngine`
    /// raises it to 0.2 (D40) — see the engine's config comment for the
    /// measured separability numbers.
    @Test func twoSpeakersSeparate() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            wavPath: fixtureURL("two-speakers-alternating"))
        #expect(result.speakers.count == 2)
        #expect(result.embeddings.count == 2)
    }

    @Test func singleSpeaker() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            wavPath: fixtureURL("single-speaker-30s"))
        #expect(result.speakers.count == 1)
        #expect(result.embeddings.count == 1)
    }

    @Test func silenceYieldsEmptyResultNotError() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            samples: [Float](repeating: 0, count: AudioFormat.sampleRate * 3))
        #expect(result.speakers.isEmpty)
        #expect(result.spans.isEmpty)
    }

    @Test func diarizerActorEndToEnd() async throws {
        // Through the production `Diarizer` actor (lazy engine load path):
        // proves the in-process actor reaches the engine and returns a
        // well-formed result.
        let diarizer = Diarizer(configuration: .init())
        let result = try await diarizer.diarizeSystemStream(
            wavPath: fixtureURL("two-speakers-alternating"))
        #expect(result.speakers.count == 2)
        #expect(result.modelRevision.count == 64)
    }
}

/// Coverage of the resident `DiarizerEngine` (D40): it loads the FluidAudio
/// community-1 CoreML stack once per process and reports a stable content
/// digest as its `modelRevision`. First run downloads the
/// `speaker-diarization` bundles (~21 MB) into the standard cache root;
/// subsequent runs are offline.
@Suite("DiarizationE2E engine load", .serialized)
struct DiarizationE2EEngineTests {

    @Test func loadsAndReportsContentRevision() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let revision = engine.modelRevision
        #expect(revision.count == 64)   // SHA-256 hex
        let allHex = revision.allSatisfy { $0.isHexDigit }
        #expect(allHex)
    }

    @Test func revisionIsStableAcrossLoads() async throws {
        let first = try await DiarizerTestEngine.shared()
        let second = try await DiarizerEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: nil)
        #expect(first.modelRevision == second.modelRevision)
    }
}

/// The live windowed pass driven through the production window geometry
/// (10 s window / 5 s step — `StreamingPipeline` defaults) against the real
/// FluidAudio engine (D40). Proves `LiveDiarizer` stitches the per-window
/// raw labels into stable provisional keys, emits recording-absolute spans,
/// and exposes the live centroids + a 64-hex model revision for the R18
/// library lookup. Per the measured behaviour, a single 10 s window does NOT
/// separate the two voices — differentiation comes from stitching across the
/// alternating windows, so this asserts stable `Them*` keys, not a per-window
/// 2-speaker split.
@Suite("DiarizationE2E live windowed", .serialized)
struct DiarizationE2ELiveTests {

    private func fixtureSamples(_ name: String) async throws -> [Float] {
        try await OfflineTranscriptionPipeline().accumulate(
            FixturePlaybackSource(
                file: FixtureLocator.audio(name), realtime: false))
    }

    @Test func windowedPassYieldsStableProvisionalKeys() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)

        // Drive the fixture through the production window geometry
        // (10 s window / 5 s step — StreamingPipeline defaults).
        let samples = try await fixtureSamples("two-speakers-alternating.wav")

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var spans: [LiveSpeakerSpan] = []
        var start = 0
        while start + window <= samples.count {
            let result = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            spans.append(contentsOf: result)
            start += step
        }

        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.provisionalKey.hasPrefix("Them") })
        // Spans are recording-absolute: a window starting at 10 s must not
        // emit spans inside [0, 10).
        #expect(spans.filter { $0.start >= .seconds(10) }.count > 0)
        let centroids = await live.centroids()
        #expect(!centroids.isEmpty)
        #expect(await live.modelRevision().count == 64)
    }

    /// D41 over-split guard: the live windowed pass over the single-speaker
    /// clip must form exactly ONE provisional key. FluidAudio's default AHC
    /// threshold can split one speaker into several on the short windows the
    /// live pass uses; `DiarizerEngine.liveClusteringThreshold` counters that.
    @Test func liveWindowedPassKeepsSingleSpeakerAsOneKey() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)
        let samples = try await fixtureSamples("single-speaker-30s.wav")

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var keys = Set<String>()
        var start = 0
        while start + window <= samples.count {
            let spans = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            for s in spans { keys.insert(s.provisionalKey) }
            start += step
        }
        #expect(keys == ["Them"], "single speaker over-split into \(keys)")
    }

    /// D41: separation is preserved at the higher live threshold — the live
    /// windowed pass over the two-speaker clip forms exactly TWO keys.
    @Test func liveWindowedPassFormsTwoKeysForTwoSpeakers() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)
        let samples = try await fixtureSamples("two-speakers-alternating.wav")

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var keys = Set<String>()
        var start = 0
        while start + window <= samples.count {
            let spans = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            for s in spans { keys.insert(s.provisionalKey) }
            start += step
        }
        #expect(keys.count == 2, "expected 2 live speakers, got \(keys)")
    }
}

/// Pins the WeSpeaker-space similarity thresholds (D40). If this fails after
/// a model bump, read the printed similarities and re-pin the constants:
/// both thresholds must sit between the worst same-speaker similarity and the
/// best cross-speaker similarity, with margin on both sides.
@Suite("DiarizationE2E threshold calibration", .serialized)
struct DiarizationE2ECalibrationTests {

    private func fixtureSamples(_ name: String) async throws -> [Float] {
        try await OfflineTranscriptionPipeline().accumulate(
            FixturePlaybackSource(
                file: FixtureLocator.audio(name), realtime: false))
    }

    @Test func thresholdsSeparateSameFromCross() async throws {
        let engine = try await DiarizerTestEngine.shared()

        // Same speaker: the two halves of a 30 s single-speaker clip must
        // produce embeddings that match.
        let solo = try await fixtureSamples("single-speaker-30s.wav")
        let firstHalf = try await engine.diarize(
            samples: Array(solo[..<(solo.count / 2)]))
        let secondHalf = try await engine.diarize(
            samples: Array(solo[(solo.count / 2)...]))
        let a = try #require(firstHalf.embeddings.first?.vector)
        let b = try #require(secondHalf.embeddings.first?.vector)
        let same = Centroid.cosineSimilarity(a, b)

        // Different speakers: the two clusters of the alternating clip.
        let duo = try await engine.diarize(
            samples: try await fixtureSamples("two-speakers-alternating.wav"))
        try #require(duo.embeddings.count == 2)
        let cross = Centroid.cosineSimilarity(
            duo.embeddings[0].vector, duo.embeddings[1].vector)

        print("calibration: same-speaker=\(same) cross-speaker=\(cross) "
            + "library-threshold=\(SpeakerLibrary.defaultMatchThreshold) "
            + "stitch-threshold=\(LiveDiarizer.stitchThreshold)")

        #expect(same - cross > 0.15)   // the space separates at all
        #expect(same > SpeakerLibrary.defaultMatchThreshold)
        #expect(cross < SpeakerLibrary.defaultMatchThreshold)
        #expect(same > LiveDiarizer.stitchThreshold)
        #expect(cross < LiveDiarizer.stitchThreshold)
    }
}
