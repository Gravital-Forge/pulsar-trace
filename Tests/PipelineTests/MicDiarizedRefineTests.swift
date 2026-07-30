import Foundation
import Testing
@testable import PulsarTraceEngine

/// Fixture note (verified in Step 1): `mic-and-system-paired/mic.wav` is a
/// single-voice ElevenLabs monologue (the same fixture the interleaved-pause
/// test in `RefinementPipelineTests` treats as one mic speaker). The mic WAV
/// therefore diarizes to ONE cluster, so the mic-diarized refine attributes it
/// to `You` (the seeded owner) and produces no guest label. A two-voice mic
/// fixture — where the guest assertion belongs — is minted in E4-T4 where the
/// live path needs it too; this suite gains the guest assertion there via a
/// follow-up run.
@Suite("Mic-diarized refine end-to-end (PT-P8-R1)", .serialized)
struct MicDiarizedRefineTests {

    /// One lazily-loading WhisperKit transcriber per process (PT-P5-D1 backend).
    private static let whisperKit = WhisperKitRegionTranscriber(
        configuration: .init(
            model: WhisperKitModelCatalog.largeV3Turbo,
            downloadBase: AppPaths.standard.modelsCacheDirectory
                .appendingPathComponent("whisperkit", isDirectory: true)),
        events: nil)

    private static func makeTranscriber() -> RefinementTranscriber {
        .whisperKit(whisperKit, vad: FluidVADRegionDetector())
    }

    /// The real in-process FluidAudio diarizer (PT-P5-D3).
    private static func makeDiarizer() -> Diarizer {
        Diarizer(configuration: .init())
    }

    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-micrefine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(
            at: FixtureLocator.audio("mic-and-system-paired/system.wav"),
            to: dir.appendingPathComponent(RecordingFolder.FileName.audioSystem))
        try fm.copyItem(
            at: FixtureLocator.audio("mic-and-system-paired/mic.wav"),
            to: dir.appendingPathComponent(RecordingFolder.FileName.audioMic))
        return dir
    }

    /// Seed the profile from the fixture's own mic audio so the owner match
    /// is deterministic: diarize mic.wav once, feed the dominant embedding.
    private func seedProfile(
        at url: URL, diarizer: Diarizer, micWav: URL
    ) async throws -> OwnerVoiceProfileStore {
        let store = OwnerVoiceProfileStore(fileURL: url)
        let result = try await diarizer.diarizeStream(wavPath: micWav)
        let dominant = result.embeddings.first!.vector
        _ = try await store.update(
            embedding: dominant, modelRevision: result.modelRevision)
        return store
    }

    @Test("stamp on: You attributed via profile; metadata v3; sidecar written")
    func micDiarizedRefine() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: folder)

        let diarizer = Self.makeDiarizer()
        let profile = try await seedProfile(
            at: folder.appendingPathComponent("owner-profile.json"),
            diarizer: diarizer,
            micWav: folder.appendingPathComponent(RecordingFolder.FileName.audioMic))

        let output = try await RefinementPipeline().run(
            inputPath: folder,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo", whisperModelSHA256: "",
            recordingStart: Self.start,
            ownerProfile: profile)

        let final = try String(contentsOf: output.finalURL, encoding: .utf8)
        #expect(final.contains("] You:**"))

        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.schemaVersion == 3)
        #expect(metadata.micDiarized == true)
        #expect(metadata.speakers.contains {
            $0.label == "You" && $0.isMicrophone && $0.speakerId == nil })
        // Single-voice mic fixture ⇒ exactly one mic speaker (`You`), no guest.
        #expect(metadata.speakers.filter(\.isMicrophone).count == 1)
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(
                MicDiarizationSidecar.fileName).path))
    }

    @Test("stamp off: revert-by-re-refine restores the single-You shape")
    func revertByReRefine() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // First pass: stamped on.
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: folder)
        let diarizer = Self.makeDiarizer()
        let profile = try await seedProfile(
            at: folder.appendingPathComponent("owner-profile.json"),
            diarizer: diarizer,
            micWav: folder.appendingPathComponent(RecordingFolder.FileName.audioMic))
        _ = try await RefinementPipeline().run(
            inputPath: folder, transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo", whisperModelSHA256: "",
            recordingStart: Self.start, ownerProfile: profile)

        // Second pass: stamp off.
        options.diarizeMic = false
        try options.write(to: folder)
        let output = try await RefinementPipeline().run(
            inputPath: folder, transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo", whisperModelSHA256: "",
            recordingStart: Self.start, ownerProfile: profile)

        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.micDiarized == false)
        #expect(metadata.speakers.filter(\.isMicrophone).count == 1)
        #expect(metadata.speakers.first(where: \.isMicrophone)?.label == "You")
    }
}
