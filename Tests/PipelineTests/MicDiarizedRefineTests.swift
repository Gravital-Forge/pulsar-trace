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
@Suite("Mic-diarized refine end-to-end (PT-R135)", .serialized)
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
        try makeFolder(micFixture: "mic-and-system-paired/mic.wav")
    }

    /// A recording folder whose mic stream is the named fixture; the system
    /// stream is always the single-voice paired system fixture.
    private func makeFolder(micFixture: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-micrefine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(
            at: FixtureLocator.audio("mic-and-system-paired/system.wav"),
            to: dir.appendingPathComponent(RecordingFolder.FileName.audioSystem))
        try fm.copyItem(
            at: FixtureLocator.audio(micFixture),
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

    /// PT-R139 — the guest assertion deferred from E3 (the single-voice paired
    /// fixture could not exercise it). The two-voice mic fixture minted in E4-T4
    /// diarizes into two mic clusters: the dominant voice (the seeded owner) →
    /// `You`, and the second voice → a guest reconciled against the (empty)
    /// library as an `Unknown #N` placeholder.
    @Test("stamp on, two-voice mic: You for the owner + an Unknown # guest")
    func micDiarizedRefineTwoVoiceGuest() async throws {
        let folder = try makeFolder(micFixture: "mic-two-speakers.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: folder)

        let diarizer = Self.makeDiarizer()
        let profile = try await seedDominantProfile(
            at: folder.appendingPathComponent("owner-profile.json"),
            diarizer: diarizer,
            micWav: folder.appendingPathComponent(RecordingFolder.FileName.audioMic))
        // An empty ephemeral library so the guest cluster reconciles to a fresh
        // `Unknown #N` speaker (the reconciler needs a library to name guests).
        let library = try await SpeakerLibrary(
            databaseURL: folder.appendingPathComponent("speakers.sqlite"))

        let output = try await RefinementPipeline().run(
            inputPath: folder,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo", whisperModelSHA256: "",
            recordingStart: Self.start,
            library: library,
            ownerProfile: profile)

        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.micDiarized == true)
        // The owner voice is attributed to You.
        #expect(metadata.speakers.contains {
            $0.label == "You" && $0.isMicrophone })
        // The second mic voice surfaces as a guest — an `Unknown #` placeholder.
        #expect(metadata.speakers.contains {
            $0.isMicrophone && $0.label.hasPrefix("Unknown #") })
        // Two-voice fixture ⇒ more than one mic speaker.
        #expect(metadata.speakers.filter(\.isMicrophone).count >= 2)
    }

    /// Seed the owner profile from the *dominant* mic voice (the one with the
    /// most total span time), so `You` is deterministically the dominant cluster
    /// even for a multi-voice fixture.
    private func seedDominantProfile(
        at url: URL, diarizer: Diarizer, micWav: URL
    ) async throws -> OwnerVoiceProfileStore {
        let store = OwnerVoiceProfileStore(fileURL: url)
        let result = try await diarizer.diarizeStream(wavPath: micWav)
        var totalBySpeaker: [String: Double] = [:]
        for span in result.spans {
            totalBySpeaker[span.speaker, default: 0]
                += (span.end.seconds - span.start.seconds)
        }
        let dominant = totalBySpeaker.max { $0.value < $1.value }?.key
            ?? result.embeddings.first!.speaker
        let vector = result.embeddings.first { $0.speaker == dominant }?.vector
            ?? result.embeddings.first!.vector
        _ = try await store.update(
            embedding: vector, modelRevision: result.modelRevision)
        return store
    }
}
