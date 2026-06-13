import Testing
import Foundation
@testable import PulsarTraceEngine

/// Pipeline coverage of the refinement pass (`pulsartrace refine`):
/// R20, R21, R24, R27, R38, R39, plus the refinement event sequence.
///
/// These tests run the **real** pipeline end-to-end — real WhisperKit
/// (`large-v3-turbo`, D39) and the real in-process FluidAudio diarizer
/// (community-1 on the ANE, D40) — on a committed fixture, so a genuine
/// integration break is caught. They are slow (model loads) and download the
/// CoreML bundles on first run; subsequent runs are offline. `.serialized`
/// keeps the suite's shared model loads from racing each other.
///
/// Determinism: WhisperKit decodes temperature-0-first; transcript text is
/// asserted via fixture keywords, which are robust to decoder wording drift.
@Suite("Refinement pipeline", .serialized)
struct RefinementPipelineTests {

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

    /// A fixed wall-clock so the `final.md` header / metadata are deterministic.
    private static let recordingStart = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: - Environment

    /// The real in-process FluidAudio diarizer (D40). Models load lazily from
    /// the shared cache root on the first diarize call (~21 MB download on a
    /// cold cache, offline thereafter).
    private static func makeDiarizer() -> Diarizer {
        Diarizer(configuration: .init())
    }

    /// A throwaway temp directory; cleaned up by the caller.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-refine-pipe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - End-to-end: bare WAV

    @Test("refine of a bare WAV produces a well-formed Speaker_N final.md")
    func bareWavEndToEnd() async throws {
        let diarizer = Self.makeDiarizer()

        // Copy the fixture into a temp dir so the output folder is disposable.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("two-speakers-alternating.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("two-speakers-alternating.wav"), to: wav)

        let pipeline = RefinementPipeline()
        let output = try await pipeline.run(
            inputPath: wav,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart)

        // The output folder is a sibling of the WAV, named for its stem (D13).
        #expect(output.recordingDirectory.lastPathComponent
            == "two-speakers-alternating")
        #expect(FileManager.default.fileExists(atPath: output.finalURL.path))
        #expect(FileManager.default.fileExists(atPath: output.metadataURL.path))

        let markdown = try String(contentsOf: output.finalURL, encoding: .utf8)
        // R38: the final-pass marker is the first line.
        #expect(markdown.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(markdown.contains("## Transcript — "))
        // R13 utterance lines carry diarized Speaker_N labels. Exact speaker
        // *count* (2-speaker separation on this clip) is gated on Task 7
        // threshold calibration — see `DiarizationE2ETests.twoSpeakersSeparate`;
        // with the default config the FluidAudio clustering collapses this
        // synthetic clip to a single speaker, so the transcript carries
        // `Speaker_0` only. We assert the label flows through, not the count.
        #expect(markdown.contains("] Speaker_0:**"))
        // A bare WAV has no mic stream — no "You" label.
        #expect(!markdown.contains("] You:**"))

        #expect(!output.speakers.isEmpty)
        #expect(output.speakers.allSatisfy { $0.hasPrefix("Speaker_") })
        #expect(output.wasReRefine == false)

        // metadata.json shape.
        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.recordingId == "rec_two-speakers-alternating")
        #expect(metadata.whisperModel.name == "large-v3-turbo")
        #expect(metadata.diarizationModel?.id
            == "FluidInference/speaker-diarization-coreml")
        #expect(metadata.speakers.count == output.speakers.count)
        #expect(metadata.language == "en")
        #expect(metadata.sourceBasename == "two-speakers-alternating.wav")

        // Distinctive fixture words instead of a byte snapshot (D39):
        // extracted from the retired whisper snapshot (git history:
        // __Snapshots__/RefinementPipelineTests/bareWavEndToEnd.1.txt).
        let lower = markdown.lowercased()
        for keyword in ["coffee", "barista", "bookstore", "ingestion", "transformation"] {
            #expect(lower.contains(keyword), "final.md should mention '\(keyword)'")
        }
    }

    // MARK: - Re-refine (R27)

    @Test("re-refine backs up final.md and emits final_md_rewritten")
    func reRefineBackupAndEvent() async throws {
        let diarizer = Self.makeDiarizer()

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("two-speakers-alternating.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("two-speakers-alternating.wav"), to: wav)

        // A dedicated events directory so we can inspect just this run's log.
        let eventsDir = dir.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let pipeline = RefinementPipeline(events: events)

        // First refine — fresh final.md.
        let first = try await pipeline.run(
            inputPath: wav,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart)
        #expect(first.wasReRefine == false)
        let backup = first.recordingDirectory
            .appendingPathComponent("final.md.bak")
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        // Second refine — re-refine (R27).
        let second = try await pipeline.run(
            inputPath: wav,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart)
        #expect(second.wasReRefine == true)
        // R27: the prior final.md is preserved as final.md.bak.
        #expect(FileManager.default.fileExists(atPath: backup.path))

        await events.flush()
        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        // First run emits final_md_written; the re-refine emits
        // final_md_rewritten with reason re_refine.
        #expect(log.contains("\"type\":\"final_md_written\""))
        #expect(log.contains("\"type\":\"final_md_rewritten\""))
        #expect(log.contains("\"reason\":\"re_refine\""))
    }

    // MARK: - Event sequence + causal order

    @Test("refine emits started → final_md_written → completed in causal order")
    func eventSequenceCausalOrder() async throws {
        let diarizer = Self.makeDiarizer()

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("single-speaker-30s.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("single-speaker-30s.wav"), to: wav)

        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let pipeline = RefinementPipeline(events: events)
        _ = try await pipeline.run(
            inputPath: wav,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart)

        await events.flush()
        let lines = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let types = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { return nil }
            return obj["type"] as? String
        }

        // Causal order (Hard Invariant #8): the cause precedes its effect.
        let startedIdx = types.firstIndex(of: "refinement_started")
        let writtenIdx = types.firstIndex(of: "final_md_written")
        let completedIdx = types.firstIndex(of: "refinement_completed")
        #expect(startedIdx != nil)
        #expect(writtenIdx != nil)
        #expect(completedIdx != nil)
        if let s = startedIdx, let w = writtenIdx, let c = completedIdx {
            #expect(s < w, "refinement_started must precede final_md_written")
            #expect(w < c, "final_md_written must precede refinement_completed")
        }
    }

    // MARK: - Edge case: no usable speech

    @Test("refine of a silence-only WAV writes a valid empty-transcript final.md")
    func silenceProducesValidEmptyFinal() async throws {
        let diarizer = Self.makeDiarizer()

        // A pure-silence WAV: the backend finds no speech, diarization is
        // skipped, and the pipeline must still write a valid final.md (edge case).
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("silence.wav")
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 2)
        try WAVWriter.encode(samples: silence).write(to: wav)

        let pipeline = RefinementPipeline()
        let output = try await pipeline.run(
            inputPath: wav,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart)

        let markdown = try String(contentsOf: output.finalURL, encoding: .utf8)
        // Still a valid final.md with the marker — not a crash, not garbage.
        #expect(markdown.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(markdown.contains("no speech detected"))
        #expect(output.speakers.isEmpty)

        // metadata.json is still written; diarization was skipped so the
        // diarization model field is absent.
        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.diarizationModel == nil)
        #expect(metadata.speakers.isEmpty)
    }

    // MARK: - Causal ordering across a mid-recording pause (D26)

    @Test("a mid-recording mic pause keeps the resumed turn after the other speaker")
    func interleavedTurnsStayInCausalOrder() async throws {
        // Assemble a paired recording from the committed ElevenLabs fixtures
        // that reproduces the two-party shape behind D26: the mic speaker
        // talks, pauses to listen, then resumes — while the system speaker
        // talks during that pause. The mic monologue is split 14s in (a long
        // turn + a short ~2s resumed turn) with a 10s silence between; the
        // system speaker is placed inside that silence. Both streams are
        // genuine speech — only the silence is synthetic, which is exactly
        // what a real mic stream holds while the far end is talking.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.buildInterleavedRecording(in: dir)

        // Diarization is irrelevant to the ordering bug, so it is supplied
        // precomputed — one speaker spanning the gap the system turn sits in.
        // The diarizer is required by the signature but never invoked.
        let diarizer = Diarizer(configuration: .init())
        let systemSpan = SpeakerSpan(
            speaker: "SPEAKER_00", start: .seconds(14), end: .seconds(24))
        let diarization = DiarizationResult(
            model: "test-precomputed",
            audioDuration: .seconds(26),
            speakers: ["SPEAKER_00"],
            spans: [systemSpan],
            embeddings: [])

        let pipeline = RefinementPipeline()
        let output = try await pipeline.run(
            inputPath: dir,
            transcriber: Self.makeTranscriber(),
            diarizer: diarizer,
            whisperModelName: "large-v3-turbo",
            whisperModelSHA256: "",
            recordingStart: Self.recordingStart,
            precomputedDiarization: diarization)

        let markdown = try String(contentsOf: output.finalURL, encoding: .utf8)
        let labels = Self.utteranceLabels(in: markdown)
        #expect(labels.contains("You"),
                "expected the mic stream to produce utterances")
        #expect(labels.contains("Speaker_0"),
                "expected the system stream to produce utterances")

        // The D26 bug: the offline mic decode glued the speaker's two turns
        // into one segment stamped at the first turn's start, so the resumed
        // turn sorted *ahead* of the system speaker — no `You` line followed
        // the system speaker's last line. With per-region decoding the resumed
        // turn keeps its true post-pause timestamp and stays after.
        let lastYou = labels.lastIndex(of: "You") ?? -1
        let lastSystem = labels.lastIndex(of: "Speaker_0") ?? Int.max
        #expect(lastYou > lastSystem,
                "the resumed mic turn must appear after the system speaker's turn")
    }

    // MARK: - Interleaved-recording fixture helpers

    /// Read a committed fixture WAV into mono 16 kHz Float samples.
    private static func fixtureSamples(_ name: String) async throws -> [Float] {
        try await OfflineTranscriptionPipeline().accumulate(
            FixturePlaybackSource(
                file: FixtureLocator.audio(name), realtime: false))
    }

    /// Assemble `audio-mic.wav` + `audio-system.wav` in `dir` from the paired
    /// ElevenLabs fixtures, interleaved with a mid-recording pause (D26):
    ///
    ///   mic:    [turn 1  0–14s][silence 14–24s][turn 2  24–26s]
    ///   system: [silence 0–15s][turn   15–23s ][silence 23–26s]
    private static func buildInterleavedRecording(in dir: URL) async throws {
        let sr = AudioFormat.sampleRate
        let mic = try await fixtureSamples("mic-and-system-paired/mic.wav")
        let system = try await fixtureSamples("mic-and-system-paired/system.wav")

        func silence(_ samples: Int) -> [Float] {
            [Float](repeating: 0, count: max(0, samples))
        }

        // Split the mic monologue 14s in: a long first turn, a short resumed
        // turn. The short tail is what the buggy whole-buffer decode fused
        // into the preceding segment.
        let splitAt = min(14 * sr, mic.count)
        let micTrack = Array(mic[..<splitAt])
            + silence(10 * sr)
            + Array(mic[splitAt...])

        // The system speaker: the first 8s of the paired system fixture,
        // placed 1s into the mic's 10s silence. The two tracks are kept the
        // same length so they model one recording.
        let systemTurn = Array(system[..<min(8 * sr, system.count)])
        let preSilence = 15 * sr
        let postSilence = micTrack.count - preSilence - systemTurn.count
        let systemTrack = silence(preSilence) + systemTurn + silence(postSilence)

        try WAVWriter.write(
            samples: micTrack,
            to: dir.appendingPathComponent(RecordingFolder.FileName.audioMic))
        try WAVWriter.write(
            samples: systemTrack,
            to: dir.appendingPathComponent(RecordingFolder.FileName.audioSystem))
    }

    /// The speaker label of every utterance line in a rendered transcript, in
    /// file order — e.g. `["You", "Speaker_0", "You"]`.
    private static func utteranceLabels(in markdown: String) -> [String] {
        markdown.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("**["),
                  let labelStart = line.range(of: "] "),
                  let labelEnd = line.range(of: ":**") else { return nil }
            return String(line[labelStart.upperBound..<labelEnd.lowerBound])
        }
    }
}
