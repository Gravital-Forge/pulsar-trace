import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Owner profile backfill (PT-R137 d)")
struct OwnerProfileBackfillTests {

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    /// Make `count` minimal recording folders, oldest first; each holds an
    /// `audio-mic.wav` stub (content irrelevant — diarize is a closure).
    private func makeRoot(count: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-backfill-\(UUID().uuidString)")
        for i in 0..<count {
            let folder = root.appendingPathComponent("2026-07-0\(i + 1)-meeting")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(
                to: folder.appendingPathComponent(RecordingFolder.FileName.audioMic))
        }
        return root
    }

    @Test("backfill learns newest-first and seeds a profile")
    func learnsNewestFirst() async throws {
        let root = try makeRoot(count: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))

        let seen = SeenBox()
        let summary = try await OwnerProfileBackfill.run(
            outputRoots: [root],
            store: store,
            diarize: { wav in
                await seen.append(wav.deletingLastPathComponent().lastPathComponent)
                return DiarizationResult(
                    model: "stub", modelRevision: "rev-a",
                    audioDuration: .seconds(10),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(
                        speaker: "SPEAKER_00", start: .seconds(0), end: .seconds(10))],
                    embeddings: [SpeakerEmbedding(
                        speaker: "SPEAKER_00", vector: self.vec(0))])
            },
            events: nil,
            logger: .init(label: "test"))

        #expect(await store.snapshot() != nil)
        #expect(summary.foldersScanned == 3)
        #expect(await seen.first == "2026-07-03-meeting")   // newest first
    }

    @Test("folders stamped diarize_mic=true are skipped")
    func skipsStampedFolders() async throws {
        let root = try makeRoot(count: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: root.appendingPathComponent("2026-07-02-meeting"))
        let store = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))

        let summary = try await OwnerProfileBackfill.run(
            outputRoots: [root], store: store,
            diarize: { _ in
                DiarizationResult(
                    model: "stub", modelRevision: "rev-a",
                    audioDuration: .seconds(10),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(
                        speaker: "SPEAKER_00", start: .seconds(0), end: .seconds(10))],
                    embeddings: [SpeakerEmbedding(
                        speaker: "SPEAKER_00", vector: self.vec(0))])
            },
            events: nil, logger: .init(label: "test"))

        #expect(summary.foldersScanned == 1)
    }

    /// Thread-safe recorder for the folder-order assertion — the `diarize`
    /// closure is `@Sendable` and runs on the backfill's task.
    private actor SeenBox {
        private var values: [String] = []
        func append(_ v: String) { values.append(v) }
        var first: String? { values.first }
    }
}
