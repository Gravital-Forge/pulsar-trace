import Testing
import Foundation
@testable import PulsarTraceEngine

/// PT-R18 coverage: during the live pass a provisional speaker whose centroid
/// matches a known library speaker is surfaced **by name** — `<name>?` —
/// not the generic `Them?`.
///
/// This exercises the exact wiring fixed in review item SW-B: `LiveRunner`
/// must pass the live diarizer's *real* model revision to
/// `SpeakerLibrary.bestMatch`. `bestMatch` skips any library speaker whose
/// `modelRevision` does not equal the one passed in (Open Question
/// #3 / PT-P5-D3) — so with the old hardcoded `""` the lookup matched nothing and
/// PT-R18 was dead. These tests prove the lookup now fires, and that the revision
/// scoping is real (a mismatched revision still falls back to `Them`).
///
/// No Python subprocess: `LiveDiarizer._seedForTesting` pre-seeds the running
/// live-speaker set + the model revision the subprocess would otherwise
/// report, so the test stays fast and device/network-free.
@Suite("Live pass PT-R18 library lookup")
struct LiveRunnerLibraryLookupTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-r18-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A deterministic 256-d unit-ish centroid.
    private func centroid(seed: Float) -> [Float] {
        (0..<256).map { Float($0) * 0.001 + seed }
    }

    /// Build a `LiveRunner` over a throwaway recording folder (the writer is
    /// never actually started here — only `resolveSystemLabel` is exercised).
    private func makeRunner(
        folder: URL, library: SpeakerLibrary?
    ) -> LiveRunner {
        let config = StreamingPipeline.Configuration(
            recordingFolder: folder,
            recordingStart: Date(timeIntervalSince1970: 1_770_000_000),
            recordingId: "rec_r18")
        let writer = LiveMarkdownWriter(
            fileURL: config.liveURL,
            recordingStart: config.recordingStart)
        return LiveRunner(
            configuration: config,
            writer: writer,
            logger: .init(label: "test"),
            library: library)
    }

    /// A `DiarState` carrying one `Them` span covering `[0s, 10s]`.
    private func diarStateWithThemSpan(embedding: [Float]) async -> DiarState {
        let state = DiarState()
        await state.merge([
            LiveSpeakerSpan(
                provisionalKey: "Them",
                start: .seconds(0),
                end: .seconds(10),
                embedding: embedding)
        ])
        return state
    }

    @Test("a known library speaker (matching model revision) surfaces by name")
    func knownSpeakerSurfacesByName() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let revision = "abc123revision"
        let knownCentroid = centroid(seed: 0.5)

        // A library holding one named speaker recorded under `revision`.
        let library = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"))
        let speaker = try await library.createSpeaker(
            name: "Dana Lee",
            centroid: knownCentroid,
            modelRevision: revision,
            recordingId: "rec_prior",
            recordingFolderName: "rec_prior")
        #expect(speaker.name == "Dana Lee")

        // A live diarizer seeded so its `Them` centroid is the same vector and
        // its reported model revision matches the library speaker's. The
        // test-seam initializer carries no engine — `_seedForTesting` supplies
        // the state the real windowed pass would otherwise produce.
        let diarizer = LiveDiarizer(testSeamLogger: .init(label: "test"))
        await diarizer._seedForTesting(
            speakers: [(key: "Them", centroid: knownCentroid)],
            modelRevision: revision)

        let runner = makeRunner(folder: dir, library: library)
        let diarState = await diarStateWithThemSpan(embedding: knownCentroid)
        let utterance = CommittedUtterance(
            start: .seconds(2), end: .seconds(5), text: "hello there")

        let label = await runner.resolveSystemLabel(
            for: utterance, diarState: diarState, diarizer: diarizer)

        // PT-R18: the known name is surfaced, still flagged provisional (PT-R16).
        #expect(label == "Dana Lee?")
    }

    @Test("a model-revision mismatch falls back to the generic Them label")
    func revisionMismatchFallsBack() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let knownCentroid = centroid(seed: 0.5)

        // Library speaker recorded under one revision …
        let library = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"))
        _ = try await library.createSpeaker(
            name: "Dana Lee",
            centroid: knownCentroid,
            modelRevision: "old-revision",
            recordingId: "rec_prior",
            recordingFolderName: "rec_prior")

        // … but the live diarizer reports a *different* revision. Even though
        // the centroid is identical, `bestMatch` must skip the speaker
        // (Open Question #3) — the live label degrades to generic `Them`.
        let diarizer = LiveDiarizer(testSeamLogger: .init(label: "test"))
        await diarizer._seedForTesting(
            speakers: [(key: "Them", centroid: knownCentroid)],
            modelRevision: "new-revision")

        let runner = makeRunner(folder: dir, library: library)
        let diarState = await diarStateWithThemSpan(embedding: knownCentroid)
        let utterance = CommittedUtterance(
            start: .seconds(2), end: .seconds(5), text: "hello there")

        let label = await runner.resolveSystemLabel(
            for: utterance, diarState: diarState, diarizer: diarizer)

        #expect(label == "Them?")
    }

    // MARK: - §2b no-coverage label-collapse regression

    /// §2b regression: when the live diarizer has **no coverage** for the
    /// committed utterance's time range, `DiarState.dominantKey` returns `nil`.
    /// The old `?? "Them"` fallback collided with `provisionalKey(index: 0)` —
    /// the first real speaker's stitched key — so the PT-R18 library lookup found
    /// that speaker's centroid and silently attributed the no-coverage
    /// utterance to the FIRST speaker's name (in the field: "everything became
    /// Stanisław"). A no-coverage utterance must instead surface the neutral
    /// `Speaker?` marker and never run the PT-R18 lookup.
    ///
    /// Same setup as `knownSpeakerSurfacesByName` — a `Them` span over `[0s,10s]`
    /// whose centroid matches the library speaker "Dana Lee" — but the utterance
    /// is at `[20s,25s]`, OUTSIDE the covered span, so there is no coverage.
    @Test("a no-coverage utterance does not inherit the first speaker's name")
    func noCoverageDoesNotInheritFirstSpeakerName() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let revision = "abc123revision"
        let knownCentroid = centroid(seed: 0.5)

        // A library holding "Dana Lee" recorded under `revision`.
        let library = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"))
        _ = try await library.createSpeaker(
            name: "Dana Lee",
            centroid: knownCentroid,
            modelRevision: revision,
            recordingId: "rec_prior",
            recordingFolderName: "rec_prior")

        // The live diarizer's first (`Them`) centroid matches "Dana Lee", and
        // the revision matches — so IF the no-coverage key collapsed to `Them`
        // the PT-R18 lookup would (wrongly) surface "Dana Lee".
        let diarizer = LiveDiarizer(testSeamLogger: .init(label: "test"))
        await diarizer._seedForTesting(
            speakers: [(key: "Them", centroid: knownCentroid)],
            modelRevision: revision)

        let runner = makeRunner(folder: dir, library: library)
        // `Them` span covers only [0s, 10s] …
        let diarState = await diarStateWithThemSpan(embedding: knownCentroid)
        // … but the utterance is at [20s, 25s] — no coverage → dominantKey nil.
        let utterance = CommittedUtterance(
            start: .seconds(20), end: .seconds(25), text: "hello there")

        let label = await runner.resolveSystemLabel(
            for: utterance, diarState: diarState, diarizer: diarizer)

        // The fix: neutral marker, NOT the first speaker's name.
        #expect(label == "Speaker?")
    }

    /// §2b regression, no-library variant: a no-coverage utterance (empty
    /// `DiarState`, so `dominantKey` returns `nil`) must surface the neutral
    /// `Speaker?` marker — never `Them?`, which would falsely tie it to the
    /// first provisional speaker.
    @Test("a no-coverage utterance surfaces the neutral Speaker label, not Them")
    func noCoverageSurfacesNeutralLabel() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(folder: dir, library: nil)
        // Empty state — no spans at all, so any utterance has no coverage.
        let diarState = DiarState()
        let utterance = CommittedUtterance(
            start: .seconds(2), end: .seconds(5), text: "hello there")

        let label = await runner.resolveSystemLabel(
            for: utterance, diarState: diarState, diarizer: nil)

        #expect(label == "Speaker?")
    }
}
