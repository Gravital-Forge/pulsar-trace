import Foundation
import Testing
@testable import PulsarTraceEngine

/// PT-P8-R13 — the live half: a second windowed diarizer over the mic stream,
/// resolving `You` (owner) / library names / `Guest`-family labels, driven by a
/// scripted mic diarizer so the label outcome is deterministic (the real ANE
/// diarizer's per-window content is exercised in `DiarizationE2ETests`).
///
/// The mic diarizer is scripted; both transcribers are the real resident
/// Parakeet engine (shared, `.serialized`) over committed fixtures so the run
/// exercises the true LiveRunner mic hand-off, not a stubbed sink.
@Suite("Streaming pipeline — mic diarization (PT-P8-R13)", .serialized)
struct StreamingPipelineMicDiarizationTests {

    /// A `RawWindowDiarizing` fake returning a scripted result per call. Local to
    /// this suite — the UnitTests twin (`LiveDiarizerStitchTests`) is in a
    /// separate test target and its copy is file-private.
    actor ScriptedRawDiarizer: RawWindowDiarizing {
        private var queue: [DiarWindowResult?]
        let revision: String
        init(_ queue: [DiarWindowResult?], revision: String = "rev") {
            self.queue = queue
            self.revision = revision
        }
        func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
            queue.isEmpty ? nil : queue.removeFirst()
        }
        func modelRevision() async -> String { revision }
    }

    /// A throwaway recording folder for one test.
    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-micdiar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An axis-0 unit vector scaled by `v` — `vec(1)` and `vec(-1)` are maximally
    /// dissimilar (cosine -1), so they stitch into two distinct Guest keys and
    /// only the first matches the owner centroid.
    private func vec(_ v: Float) -> [Float] {
        var out = [Float](repeating: 0, count: 256); out[0] = v; return out
    }

    @Test("mic lines resolve You for the owner window, Guest? for the stranger")
    func micLabelsInLiveMD() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Read-only invariant (PT-P8-R13): the owner profile lives beside the
        // library and is never written by the live pass. There is no profile
        // file on disk in this run — assert it stays absent afterward.
        let profileURL = folder.appendingPathComponent("owner-profile.json")
        #expect(!FileManager.default.fileExists(atPath: profileURL.path))

        // Owner speaks the first windows; a stranger the later ones. The scripted
        // window count comfortably covers every ~5 s window a ~54 s fixture run
        // requests; the empty-queue tail returns nil (no coverage), harmless.
        let ownerVector = vec(1.0)
        let strangerVector = vec(-1.0)
        let scripted = ScriptedRawDiarizer(
            Array(repeating: DiarWindowResult(
                spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5000)],
                embeddings: [.init(speaker: "S1", vector: ownerVector)]),
                  count: 3)
            + Array(repeating: DiarWindowResult(
                spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5000)],
                embeddings: [.init(speaker: "S1", vector: strangerVector)]),
                    count: 20))

        let ownerProfile = OwnerVoiceProfile(
            centroid: ownerVector, modelRevision: "rev",
            sampleCount: 4, updatedAt: "2026-07-29T00:00:00Z")

        let output = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: Date(timeIntervalSince1970: 1_777_000_000),
                recordingId: "rec_mic-two",
                micRawDiarizer: scripted,
                ownerProfile: ownerProfile),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            micTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: FixturePlaybackSource(
                file: FixtureLocator.audio("silence-then-speech.wav"), realtime: false),
            micSource: FixturePlaybackSource(
                file: FixtureLocator.audio("mic-two-speakers.wav"), realtime: false),
            library: nil)
        _ = output

        let live = try String(
            contentsOf: folder.appendingPathComponent("live.md"), encoding: .utf8)
        // Owner window → `You` (no `?`); stranger window → a Guest-family
        // provisional with the PT-R16 `?` suffix (rendered `Guest?` / `Guest #2?`).
        #expect(live.contains("] You:**"))
        #expect(live.contains("] Guest?:**") || live.contains("] Guest #2?:**"))
        // System stream carries no mic-family label — no cross-stream bleed.
        #expect(!live.contains("] Them"))    // no live diarizer on the system side

        // Read-only invariant held: the profile file was never created.
        #expect(!FileManager.default.fileExists(atPath: profileURL.path))
    }

    @Test("without a mic diarizer, every mic line is You (mode off)")
    func modeOffAllYou() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: Date(timeIntervalSince1970: 1_777_000_000),
                recordingId: "rec_mode-off"),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            micTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: FixturePlaybackSource(
                file: FixtureLocator.audio("silence-then-speech.wav"), realtime: false),
            micSource: FixturePlaybackSource(
                file: FixtureLocator.audio("mic-two-speakers.wav"), realtime: false),
            library: nil)

        let live = try String(
            contentsOf: folder.appendingPathComponent("live.md"), encoding: .utf8)
        // Mode off ⇒ byte-identical mic behavior to today: no Guest labels appear.
        #expect(!live.contains("Guest"))
    }
}
