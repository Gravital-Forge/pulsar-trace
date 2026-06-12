import Testing
import Foundation
@testable import PulsarTraceEngine

/// The speaker-library "done" criterion (PRD §15): refine recording A — a new speaker
/// becomes `Unknown #1` in the library — then refine recording B containing
/// the *same* voice, and the speaker is auto-labelled with the same
/// name/`spk_` id in `final.md`.
///
/// Determinism without pyannote: `RefinementPipeline.run(precomputedDiarization:)`
/// injects a committed diarization JSON fixture in place of the pyannote
/// subprocess, so the reconciliation logic is exercised deterministically.
/// WhisperKit (`large-v3-turbo`) runs on the ANE over the committed audio
/// fixtures. The `SpeakerLibrary` lives in a per-test temp directory — the
/// real `~/Library` is never touched.
///
/// `.serialized` keeps the suite's shared model loads from racing each other.
@Suite("Speaker library pipeline", .serialized)
struct SpeakerLibraryPipelineTests {

    /// One lazily-loading WhisperKit transcriber per process (D39 backend).
    private static let whisperKit = WhisperKitRegionTranscriber(
        configuration: .init(
            model: WhisperKitModelCatalog.largeV3Turbo,
            downloadBase: AppPaths.standard.modelsCacheDirectory
                .appendingPathComponent("whisperkit", isDirectory: true)),
        events: nil)

    private static func makeTranscriber() -> RefinementTranscriber {
        .whisperKit(whisperKit, vad: FluidVADRegionDetector())
    }

    private static let recordingStart = Date(timeIntervalSince1970: 1_777_000_000)

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-spk-pipe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// Decode a committed diarization JSON fixture into a `DiarizationResult`.
    private func diarization(_ name: String) throws -> DiarizationResult {
        try DiarizationDecoder.decode(FixtureLocator.diarizationData(name))
    }

    /// Lossy normalization for transcript-text comparison: lowercase, letters
    /// only. WhisperKit's wording/punctuation drifts run-to-run and across SDK
    /// versions, so the keyword match below tolerates that drift while still
    /// catching wrong speaker labels, missing turns, or garbled words.
    private func lettersOnly(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }
    }

    /// All event `type`s in an events file, in order.
    private func eventTypes(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return obj["type"] as? String
            }
    }

    /// A `DiarizationResult` is `Sendable`; the test injects one as the refine
    /// pipeline's diarization stage. A no-op `Diarizer` stands in for the
    /// unused subprocess.
    private func unusedDiarizer() -> Diarizer {
        Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/false"),
            workingDirectory: URL(fileURLWithPath: "/tmp")))
    }

    // MARK: - The speaker-library "done" criterion

    @Test("a returning speaker is auto-labelled with the name set on recording A")
    func returningSpeakerAutoLabelled() async throws {
        let workDir = tempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // One shared library + events log across both recordings.
        let dbURL = workDir.appendingPathComponent("speakers.sqlite")
        let eventsDir = workDir.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: dbURL, events: events)

        let pipeline = RefinementPipeline(events: events)

        // --- Recording A: a brand-new speaker -------------------------------
        let wavA = workDir.appendingPathComponent("single-speaker-30s.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("single-speaker-30s.wav"), to: wavA)
        let diarA = try diarization("single-speaker-30s.json")

        let outputA = try await pipeline.run(
            inputPath: wavA,
            transcriber: Self.makeTranscriber(),
            diarizer: unusedDiarizer(),
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart,
            library: library,
            precomputedDiarization: diarA)

        // A had no library entry to match → one new speaker, `Unknown #1`.
        #expect(outputA.speakers == ["Unknown #1"])
        let finalA = try String(contentsOf: outputA.finalURL, encoding: .utf8)
        #expect(finalA.contains("] Unknown #1:**"))
        #expect(!finalA.contains("Speaker_0"))

        // The library now holds exactly one speaker.
        let librarySpeakers = try await library.liveSpeakers()
        #expect(librarySpeakers.count == 1)
        let speakerID = librarySpeakers[0].id
        #expect(speakerID.hasPrefix("spk_"))
        #expect(librarySpeakers[0].name == "Unknown #1")
        #expect(librarySpeakers[0].appearanceCount == 1)

        // --- Recording B: the SAME voice returns ----------------------------
        let wavB = workDir.appendingPathComponent("single-speaker-returning.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("single-speaker-returning.wav"), to: wavB)
        // The returning diarization carries a perturbed copy of A's real
        // embedding (cosine ≈ 0.9999) — a genuine returning-speaker match.
        let diarB = try diarization("single-speaker-returning.json")

        let outputB = try await pipeline.run(
            inputPath: wavB,
            transcriber: Self.makeTranscriber(),
            diarizer: unusedDiarizer(),
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart,
            library: library,
            precomputedDiarization: diarB)

        // THE SPEAKER-LIBRARY "DONE" CRITERION: B's speaker is auto-labelled with the
        // name assigned during A — not a fresh `Unknown #2`, not `Speaker_0`.
        #expect(outputB.speakers == ["Unknown #1"])
        let finalB = try String(contentsOf: outputB.finalURL, encoding: .utf8)
        #expect(finalB.contains("] Unknown #1:**"))

        // The library still has exactly one speaker — the same stable id —
        // now with two appearances and a centroid refined by B (R30).
        let afterB = try await library.liveSpeakers()
        #expect(afterB.count == 1)
        #expect(afterB[0].id == speakerID)              // R83: stable id
        #expect(afterB[0].appearanceCount == 2)
        #expect(Set(try await library.appearances(of: speakerID).map(\.recordingId))
            == ["rec_single-speaker-30s", "rec_single-speaker-returning"])

        // metadata.json for B records the stable speaker_id ↔ name mapping.
        let metaB = try JSONDecoder().decode(
            RefinementMetadata.self, from: Data(contentsOf: outputB.metadataURL))
        #expect(metaB.speakers.first?.label == "Unknown #1")
        #expect(metaB.speakers.first?.speakerId == speakerID)

        // --- Events: speaker_created for A, centroid update + match for B ---
        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(types.contains("speaker_created"))
        #expect(types.contains("speaker_centroid_updated"))
        // A surfaced one new speaker, zero matched; B matched one, zero new.
        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.contains("\"speaker_id\":\"\(speakerID)\""))
        #expect(log.contains("\"speakers_new\":1"))
        #expect(log.contains("\"speakers_matched\":1"))

        // The reconciled final.md carries the returning speaker's label on a
        // genuine transcript of recording B. Distinctive fixture words (D39)
        // instead of a byte-for-byte reference: WhisperKit's wording drifts
        // from the retired whisper `base` snapshot, but the same content words
        // appear (git history:
        // __Snapshots__/SpeakerLibraryPipelineTests/returningSpeakerAutoLabelled.1.txt).
        let lowerB = lettersOnly(finalB)
        for keyword in ["coffee", "barista", "bookstore"] {
            #expect(lowerB.contains(keyword), "final.md should mention '\(keyword)'")
        }
    }

    // MARK: - A genuinely different speaker becomes a new Unknown

    @Test("a distinct speaker in a later recording becomes a fresh Unknown #N")
    func distinctSpeakerGetsNewPlaceholder() async throws {
        let workDir = tempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let events = EventWriter(directory: workDir.appendingPathComponent("events"))
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: workDir.appendingPathComponent("speakers.sqlite"),
            events: events)
        let pipeline = RefinementPipeline(events: events)

        // Recording A: the single-speaker voice → Unknown #1.
        let wavA = workDir.appendingPathComponent("single-speaker-30s.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("single-speaker-30s.wav"), to: wavA)
        _ = try await pipeline.run(
            inputPath: wavA, transcriber: Self.makeTranscriber(),
            diarizer: unusedDiarizer(),
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart,
            library: library,
            precomputedDiarization: try diarization("single-speaker-30s.json"))

        // Recording B: the two-speaker fixture. SPEAKER_01 (cosine ≈ 0.20 to
        // the single-speaker voice) is genuinely distinct → a new placeholder.
        let wavB = workDir.appendingPathComponent("two-speakers-alternating.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("two-speakers-alternating.wav"), to: wavB)
        let outputB = try await pipeline.run(
            inputPath: wavB, transcriber: Self.makeTranscriber(),
            diarizer: unusedDiarizer(),
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart,
            library: library,
            precomputedDiarization: try diarization(
                "two-speakers-alternating.json"))

        // The library grew: at least one new Unknown for the distinct voice.
        let names = Set(try await library.liveSpeakers().map(\.name))
        #expect(names.contains("Unknown #1"))
        #expect(names.contains("Unknown #2"))
        // B's transcript carries library names, never `Speaker_N`.
        let finalB = try String(contentsOf: outputB.finalURL, encoding: .utf8)
        #expect(!finalB.contains("Speaker_0"))
        #expect(finalB.contains("Unknown #"))
    }
}
