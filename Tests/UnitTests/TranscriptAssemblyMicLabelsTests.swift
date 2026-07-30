import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("TranscriptAssembly per-cluster mic labels (PT-P8-R1/R4/R5/R10)")
struct TranscriptAssemblyMicLabelsTests {

    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    private func seg(_ text: String, _ s: Double, _ e: Double) -> TranscriptSegment {
        TranscriptSegment(start: .seconds(s), end: .seconds(e), text: text)
    }

    /// A disposable recording folder scaffolded with a minimal system WAV so
    /// `RecordingFolder.resolve` succeeds (reuses `FixtureRecording.minimal`).
    private func fixtureFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-miclabels-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? FixtureRecording.minimal(at: dir)
        return dir
    }

    /// Two mic clusters: SPEAKER_00 owns 0–10 s, SPEAKER_01 owns 10–20 s.
    private func micDiarization() -> DiarizationResult {
        DiarizationResult(
            model: "stub", modelRevision: "rev-a", audioDuration: .seconds(20),
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            spans: [
                SpeakerSpan(speaker: "SPEAKER_00", start: .seconds(0), end: .seconds(10)),
                SpeakerSpan(speaker: "SPEAKER_01", start: .seconds(10), end: .seconds(20)),
            ],
            embeddings: [])
    }

    private func micAttribution() -> MicChannelAttribution.Outcome {
        MicChannelAttribution.Outcome(
            nameByRawLabel: ["SPEAKER_00": "You", "SPEAKER_01": "Unknown #1"],
            speakerIdByRawLabel: ["SPEAKER_01": "spk_TESTGUEST"],
            ownerRawLabel: "SPEAKER_00", matchedCount: 0, newCount: 1)
    }

    @Test("mic segments take per-cluster names; You and the guest both appear")
    func perClusterMicLabels() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("mine", 1, 3), seg("theirs", 12, 14)],
            micDiarization: micDiarization(),
            micAttribution: micAttribution(),
            recordingStart: Self.start)
        #expect(merged.document.speakerLabels == ["You", "Unknown #1"])
        #expect(merged.speakers == ["You", "Unknown #1"])
        #expect(merged.speakerIdByLabel["Unknown #1"] == "spk_TESTGUEST")
        #expect(merged.speakerIdByLabel["You"] == nil)
    }

    @Test("without mic attribution, mic labels stay You (mode off)")
    func modeOffUnchanged() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("mine", 1, 3)],
            micDiarization: nil,
            micAttribution: nil,
            recordingStart: Self.start)
        #expect(merged.document.speakerLabels == ["You"])
    }

    @Test("metadata: several is_microphone rows; You keeps nil speaker_id; mic_diarized true")
    func metadataRows() {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [],
            diarization: nil, reconciliation: nil,
            micSegments: [seg("mine", 1, 3), seg("theirs", 12, 14)],
            micDiarization: micDiarization(),
            micAttribution: micAttribution(),
            recordingStart: Self.start)
        let metadata = TranscriptAssembly.buildMetadata(
            folder: try! RecordingFolder.resolve(inputPath: folder),
            merged: merged,
            micDiarized: true,
            language: "en",
            diarization: nil,
            recordingStart: Self.start, refinedAt: Self.start,
            whisperModelName: "stub", whisperModelSHA256: "",
            sourceBasename: "x", audioDurationSeconds: 20)
        #expect(metadata.schemaVersion == 3)
        #expect(metadata.micDiarized == true)
        let you = metadata.speakers.first { $0.label == "You" }
        let guest = metadata.speakers.first { $0.label == "Unknown #1" }
        #expect(you?.isMicrophone == true && you?.speakerId == nil)
        #expect(guest?.isMicrophone == true && guest?.speakerId == "spk_TESTGUEST")
    }
}
