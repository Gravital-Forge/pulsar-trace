import Testing
import Foundation
import SnapshotTesting
@testable import PulsarTraceEngine

/// Pipeline coverage of the Epic 4 refinement pass (`pulsartrace refine`):
/// R20, R21, R24, R27, R38, R39, plus the refinement event sequence.
///
/// These tests run the **real** pipeline end-to-end — real whisper (`base`
/// model, D4) and a real pyannote subprocess — on a committed fixture, so a
/// genuine integration break is caught. They are therefore slow (pyannote
/// model load ~10–30s) and depend on the dev venv + an `HF_TOKEN`; the suite
/// **skips cleanly** when that environment is absent, so a `swift test`
/// without the Python layer set up does not fail.
///
/// Determinism: whisper is greedy / single-thread with a pinned model hash and
/// a sampler RNG seeded with a fixed per-call constant (so a non-zero decode
/// temperature is still byte-reproducible run-to-run), and pyannote runs with
/// fixed seeds (PRD §12) — so the `final.md` body and `metadata.json` (volatile
/// fields normalized) are stable across runs. `.serialized` because
/// whisper.cpp's Metal backend is single-context per process (project-docs/DECISIONS.md D8).
@Suite("Refinement pipeline (Epic 4)", .serialized)
struct RefinementPipelineTests {

    /// A fixed wall-clock so the `final.md` header / metadata are deterministic.
    private static let recordingStart = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: - Environment

    /// Repo root: `Tests/PipelineTests/` → up three.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PipelineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }()

    private static var venvPython: URL {
        repoRoot.appendingPathComponent("python/pulsartrace-ai/.venv/bin/python")
    }

    /// Load `KEY=VALUE` pairs from the repo `.env` (dev-only, D9).
    private static func dotEnv() -> [String: String] {
        let envFile = repoRoot.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// A `Diarizer` against the dev venv, or `nil` to skip when unavailable.
    private static func makeDiarizer() -> Diarizer? {
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            return nil
        }
        var env = dotEnv()
        guard env["HF_TOKEN"]?.isEmpty == false else { return nil }
        if let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first {
            env["HF_HOME"] = caches
                .appendingPathComponent("PulsarTrace/huggingface").path
        }
        return Diarizer(configuration: .init(
            pythonExecutable: venvPython,
            workingDirectory: repoRoot.appendingPathComponent("python/pulsartrace-ai"),
            environment: env))
    }

    /// Fetch (or reuse) the verified `base` whisper model.
    ///
    /// Routed through `WhisperTestGate` so the model is fetched once
    /// process-wide — two suites resolving it via separate `ModelStore`
    /// instances would otherwise race on the shared cache files.
    private func baseModelURL() async throws -> URL {
        try await WhisperTestGate.model(ModelCatalog.base)
    }

    /// A throwaway temp directory; cleaned up by the caller.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-refine-pipe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// Body of `final.md` with the wall-clock header line replaced by a stable
    /// placeholder (same approach as `TranscriptionPipelineTests`).
    private func body(of markdown: String) -> String {
        var lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1 { lines[1] = "## Transcript — <recording-start>" }
        return lines.joined(separator: "\n")
    }

    // MARK: - End-to-end: bare WAV

    @Test("refine of a bare WAV produces a well-formed Speaker_N final.md")
    func bareWavEndToEnd() async throws {
        guard let diarizer = Self.makeDiarizer() else { return }  // skip
        let modelURL = try await baseModelURL()

        // Copy the fixture into a temp dir so the output folder is disposable.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("two-speakers-alternating.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("two-speakers-alternating.wav"), to: wav)

        let pipeline = RefinementPipeline()
        let output = try await WhisperTestGate.run {
            try await pipeline.run(
                inputPath: wav,
                transcriberFactory: { try WhisperTestTranscriber.make(modelURL: modelURL) },
                diarizer: diarizer,
                whisperModelName: ModelCatalog.base.name,
                whisperModelSHA256: ModelCatalog.base.sha256,
                recordingStart: Self.recordingStart)
        }

        // The output folder is a sibling of the WAV, named for its stem (D13).
        #expect(output.recordingDirectory.lastPathComponent
            == "two-speakers-alternating")
        #expect(FileManager.default.fileExists(atPath: output.finalURL.path))
        #expect(FileManager.default.fileExists(atPath: output.metadataURL.path))

        let markdown = try String(contentsOf: output.finalURL, encoding: .utf8)
        // R38: the final-pass marker is the first line.
        #expect(markdown.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(markdown.contains("## Transcript — "))
        // R13 utterance lines with diarized Speaker_N labels.
        #expect(markdown.contains("] Speaker_0:**"))
        #expect(markdown.contains("] Speaker_1:**"))
        // A bare WAV has no mic stream — no "You" label.
        #expect(!markdown.contains("] You:**"))
        // Recognisable transcript text from the fixture.
        #expect(markdown.lowercased().contains("coffee"))

        #expect(Set(output.speakers) == ["Speaker_0", "Speaker_1"])
        #expect(output.wasReRefine == false)

        // metadata.json shape.
        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.recordingId == "rec_two-speakers-alternating")
        #expect(metadata.whisperModel.name == "base")
        #expect(metadata.pyannoteModel?.id
            == "pyannote/speaker-diarization-community-1")
        #expect(metadata.speakers.count == 2)
        #expect(metadata.language == "en")
        #expect(metadata.sourceBasename == "two-speakers-alternating.wav")

        // Snapshot the final.md body — determinism makes this stable.
        assertSnapshot(of: body(of: markdown), as: .lines)
    }

    // MARK: - Re-refine (R27)

    @Test("re-refine backs up final.md and emits final_md_rewritten")
    func reRefineBackupAndEvent() async throws {
        guard let diarizer = Self.makeDiarizer() else { return }  // skip
        let modelURL = try await baseModelURL()

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
        let factory: @Sendable () throws -> WhisperTranscriber = {
            try WhisperTestTranscriber.make(modelURL: modelURL)
        }

        // First refine — fresh final.md.
        let first = try await WhisperTestGate.run {
            try await pipeline.run(
                inputPath: wav,
                transcriberFactory: factory,
                diarizer: diarizer,
                whisperModelName: ModelCatalog.base.name,
                whisperModelSHA256: ModelCatalog.base.sha256,
                recordingStart: Self.recordingStart)
        }
        #expect(first.wasReRefine == false)
        let backup = first.recordingDirectory
            .appendingPathComponent("final.md.bak")
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        // Second refine — re-refine (R27).
        let second = try await WhisperTestGate.run {
            try await pipeline.run(
                inputPath: wav,
                transcriberFactory: factory,
                diarizer: diarizer,
                whisperModelName: ModelCatalog.base.name,
                whisperModelSHA256: ModelCatalog.base.sha256,
                recordingStart: Self.recordingStart)
        }
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
        guard let diarizer = Self.makeDiarizer() else { return }  // skip
        let modelURL = try await baseModelURL()

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("single-speaker-30s.wav")
        try FileManager.default.copyItem(
            at: FixtureLocator.audio("single-speaker-30s.wav"), to: wav)

        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let pipeline = RefinementPipeline(events: events)
        _ = try await WhisperTestGate.run {
            try await pipeline.run(
                inputPath: wav,
                transcriberFactory: { try WhisperTestTranscriber.make(modelURL: modelURL) },
                diarizer: diarizer,
                whisperModelName: ModelCatalog.base.name,
                whisperModelSHA256: ModelCatalog.base.sha256,
                recordingStart: Self.recordingStart)
        }

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
        guard let diarizer = Self.makeDiarizer() else { return }  // skip
        let modelURL = try await baseModelURL()

        // A pure-silence WAV: whisper finds no speech, diarization is skipped,
        // and the pipeline must still write a valid final.md (Epic 4 edge case).
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("silence.wav")
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 2)
        try WAVWriter.encode(samples: silence).write(to: wav)

        let pipeline = RefinementPipeline()
        let output = try await WhisperTestGate.run {
            try await pipeline.run(
                inputPath: wav,
                transcriberFactory: { try WhisperTestTranscriber.make(modelURL: modelURL) },
                diarizer: diarizer,
                whisperModelName: ModelCatalog.base.name,
                whisperModelSHA256: ModelCatalog.base.sha256,
                recordingStart: Self.recordingStart)
        }

        let markdown = try String(contentsOf: output.finalURL, encoding: .utf8)
        // Still a valid final.md with the marker — not a crash, not garbage.
        #expect(markdown.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(markdown.contains("no speech detected"))
        #expect(output.speakers.isEmpty)

        // metadata.json is still written; diarization was skipped so the
        // pyannote model field is absent.
        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: output.metadataURL))
        #expect(metadata.pyannoteModel == nil)
        #expect(metadata.speakers.isEmpty)
    }
}
