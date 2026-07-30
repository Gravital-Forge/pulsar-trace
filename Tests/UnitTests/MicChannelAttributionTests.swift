import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Mic-channel attribution (PT-P8-R4, PT-P8-R5)")
struct MicChannelAttributionTests {

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    private func diarization(_ embeddings: [String: [Float]]) -> DiarizationResult {
        DiarizationResult(
            model: "stub", modelRevision: "rev-a", audioDuration: .seconds(30),
            speakers: Array(embeddings.keys).sorted(),
            spans: embeddings.keys.sorted().enumerated().map { i, speaker in
                SpeakerSpan(speaker: speaker,
                            start: .seconds(Double(i * 10)),
                            end: .seconds(Double(i * 10 + 9)))
            },
            embeddings: embeddings.map {
                SpeakerEmbedding(speaker: $0.key, vector: $0.value)
            })
    }

    private func makeStores() async throws
        -> (OwnerVoiceProfileStore, SpeakerLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-attr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = OwnerVoiceProfileStore(
            fileURL: dir.appendingPathComponent("owner-profile.json"))
        let library = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"))
        return (profile, library, dir)
    }

    @Test("owner cluster becomes You; the other becomes Unknown #1")
    func ownerAndGuest() async throws {
        let (profile, library, dir) = try await makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")

        let outcome = try await MicChannelAttribution.attribute(
            micDiarization: diarization(
                ["SPEAKER_00": vec(0), "SPEAKER_01": vec(60)]),
            ownerProfile: profile,
            library: library,
            recordingId: "rec_x", recordingFolderName: "x",
            events: nil, logger: .init(label: "test"))

        #expect(outcome.nameByRawLabel["SPEAKER_00"] == "You")
        #expect(outcome.nameByRawLabel["SPEAKER_01"] == "Unknown #1")
        #expect(outcome.speakerIdByRawLabel["SPEAKER_00"] == nil)   // You: no spk_ id
        #expect(outcome.speakerIdByRawLabel["SPEAKER_01"]?.hasPrefix("spk_") == true)
        #expect(outcome.ownerRawLabel == "SPEAKER_00")
    }

    @Test("no profile: zero You — both clusters take the guest path (fail-safe)")
    func noProfileNoYou() async throws {
        let (profile, library, dir) = try await makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await MicChannelAttribution.attribute(
            micDiarization: diarization(
                ["SPEAKER_00": vec(0), "SPEAKER_01": vec(60)]),
            ownerProfile: profile,
            library: library,
            recordingId: "rec_x", recordingFolderName: "x",
            events: nil, logger: .init(label: "test"))

        #expect(outcome.ownerRawLabel == nil)
        #expect(!outcome.nameByRawLabel.values.contains("You"))
        #expect(Set(outcome.nameByRawLabel.values) == ["Unknown #1", "Unknown #2"])
    }

    @Test("below-threshold best match: no You (never guesswork)")
    func belowThresholdNoYou() async throws {
        let (profile, library, dir) = try await makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")

        let outcome = try await MicChannelAttribution.attribute(
            micDiarization: diarization(["SPEAKER_00": vec(200)]),   // orthogonal
            ownerProfile: profile,
            library: library,
            recordingId: "rec_x", recordingFolderName: "x",
            events: nil, logger: .init(label: "test"))
        #expect(outcome.ownerRawLabel == nil)
        #expect(outcome.nameByRawLabel["SPEAKER_00"] == "Unknown #1")
    }

    @Test("cross-channel: a mic guest matches a speaker minted from the system stream")
    func crossChannelReconciliation() async throws {
        let (profile, library, dir) = try await makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The person first appeared on the SYSTEM stream of another recording:
        let outcome = try await SpeakerReconciler(library: library).reconcile(
            diarization: diarization(["SPEAKER_00": vec(7)]),
            recordingId: "rec_remote", recordingFolderName: "remote")
        let systemMintedId = outcome.speakerIdByRawLabel["SPEAKER_00"]!

        // Now they speak into the mic in an in-person recording (PT-P8-R5):
        let micOutcome = try await MicChannelAttribution.attribute(
            micDiarization: diarization(["SPEAKER_00": vec(7)]),
            ownerProfile: profile,   // empty → no You, pure guest path
            library: library,
            recordingId: "rec_inperson", recordingFolderName: "inperson",
            events: nil, logger: .init(label: "test"))
        #expect(micOutcome.speakerIdByRawLabel["SPEAKER_00"] == systemMintedId)
    }

    @Test("at most one You: two owner-like clusters — best similarity wins")
    func atMostOneYou() async throws {
        let (profile, library, dir) = try await makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")

        var near = vec(0); near[1] = 0.5     // cosine ≈ 0.89
        let outcome = try await MicChannelAttribution.attribute(
            micDiarization: diarization(
                ["SPEAKER_00": vec(0), "SPEAKER_01": near]),   // both ≥ threshold
            ownerProfile: profile,
            library: library,
            recordingId: "rec_x", recordingFolderName: "x",
            events: nil, logger: .init(label: "test"))
        #expect(outcome.ownerRawLabel == "SPEAKER_00")
        #expect(outcome.nameByRawLabel.values.filter { $0 == "You" }.count == 1)
    }
}
