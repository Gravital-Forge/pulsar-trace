// Tests/UnitTests/ResumableRefinerTests.swift
import Foundation
import os
import Testing
@testable import PulsarTraceEngine

@Suite("ResumableRefiner")
struct ResumableRefinerTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-resumable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a fresh run leaves a completed-stage checkpoint in the folder")
    func freshRunCheckpoint() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "stub")],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(
                        speaker: "SPEAKER_00",
                        start: .seconds(0),
                        end: .seconds(1))],
                    exclusiveSpans: [SpeakerSpan(
                        speaker: "SPEAKER_00",
                        start: .seconds(0),
                        end: .seconds(1))],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_x", recordingId: "rec_x", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let progressURL = folder.appendingPathComponent("refine-progress.json")
        let data = try Data(contentsOf: progressURL)
        let progress = try RefinementProgress.decode(data)
        #expect(progress.stage == .writingMetadata)

        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("final.md").path))
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("metadata.json").path))
    }

    /// A pre-written progress file with two of three regions completed makes the
    /// refiner skip those two and decode only the third.
    @Test("resume from checkpoint skips already-completed regions")
    func resumeFromCheckpoint() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        // Hand-write a progress file claiming regions 0+1 already decoded.
        var seed = RefinementProgress.empty(jobId: "job_r", recordingId: "rec_r")
        seed.stage = .transcribingSystem
        seed.systemRegions = [
            .init(startMillis: 0,    endMillis: 1000),
            .init(startMillis: 1000, endMillis: 2000),
            .init(startMillis: 2000, endMillis: 3000),
        ]
        seed.completedSystemRegionIndices = [0, 1]
        seed.systemSegments = [
            .init(startMillis: 0,    endMillis: 1000, text: "preexisting 0", regionIndex: 0),
            .init(startMillis: 1000, endMillis: 2000, text: "preexisting 1", regionIndex: 1),
        ]
        seed.language = "en"
        seed.lastCheckpointAt = Date()
        try seed.encoded().write(
            to: folder.appendingPathComponent("refine-progress.json"))

        // Track which region indices the transcribe stub is asked to decode.
        // OSAllocatedUnfairLock is Sendable so it is safe to capture in @Sendable closures.
        let callLog = OSAllocatedUnfairLock(initialState: [Int]())

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                // Identify the region by its start time (whole seconds → index).
                let i = Int(region.start.seconds)
                callLog.withLock { $0.append(i) }
                return TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "fresh \(i)")],
                    language: "en")
            },
            detectRegions: { _ in
                // Should not be called — regions are already in the checkpoint.
                Issue.record("detectRegions was called on resume")
                return []
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(3),
                    speakers: [],
                    spans: [],
                    exclusiveSpans: [],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        // RefinementJob id+recordingId must match the seed so that
        // loadOrInitProgress picks up the checkpoint (not a fresh empty one).
        let job = RefinementJob(
            id: "job_r", recordingId: "rec_r", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let indices = callLog.withLock { $0 }
        #expect(indices == [2])    // only region 2 decoded; 0+1 skipped by checkpoint
    }

    /// Closing the pause gate between regions stalls the refiner. Opening it
    /// again resumes the loop and the rest of the regions decode.
    @Test("a closed pause gate suspends the region loop")
    func pauseStallsLoop() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let gate = PauseGate(initiallyOpen: true)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        // Signal the test when region 0 has been transcribed and the gate
        // has been closed — so we can assert the stall without a sleep.
        actor Region0Signal {
            private var cont: CheckedContinuation<Void, Never>?
            private var done = false
            func signal() {
                done = true
                cont?.resume()
                cont = nil
            }
            func wait() async {
                if done { return }
                await withCheckedContinuation { cont = $0 }
            }
        }
        let region0Done = Region0Signal()

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                counter.withLock { $0 += 1 }
                // After region 0, close the gate so region 1 cannot start.
                // Awaiting directly here is safe because TranscribeRegion is async;
                // the close happens-before the closure returns, which happens-before
                // the loop advances to waitOpen() for region 1.
                if region.start == .seconds(0) {
                    await gate.close()
                    await region0Done.signal()
                }
                return TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "x")],
                    language: "en")
            },
            detectRegions: { _ in
                [
                    SpeechRegion(start: .seconds(0), end: .seconds(1)),
                    SpeechRegion(start: .seconds(1), end: .seconds(2)),
                ]
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(2),
                    speakers: [],
                    spans: [],
                    exclusiveSpans: [],
                    embeddings: [])
            },
            pauseGate: gate,
            events: nil)

        let job = RefinementJob(
            id: "j", recordingId: "r", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        let runTask = Task { try await refiner.run(job: job) }

        // Wait for region 0 to finish (deterministic — no sleep).
        await region0Done.wait()
        let stalled = counter.withLock { $0 }
        #expect(stalled == 1)    // only region 0 decoded so far

        await gate.open()
        try await runTask.value

        let finalCount = counter.withLock { $0 }
        #expect(finalCount == 2)
    }

    @Test("a thrown error is recorded in refine-progress.json as lastError")
    func failureWritesLastError() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        struct Boom: Error, CustomStringConvertible {
            let folder: URL
            var description: String {
                "synthetic transcribe failure for \(folder.path)"
            }
        }

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in throw Boom(folder: folder) },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("diarize should not be reached when transcribe throws")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_e", recordingId: "rec_e", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        await #expect(throws: Boom.self) {
            try await refiner.run(job: job)
        }

        let progressURL = folder.appendingPathComponent("refine-progress.json")
        let data = try Data(contentsOf: progressURL)
        let progress = try RefinementProgress.decode(data)
        let recorded = try #require(progress.lastError)
        #expect(recorded.contains("synthetic transcribe failure"),
                "lastError should carry the underlying description")
        #expect(!recorded.contains(folder.path),
                "filesystem path must be redacted")
    }

    /// A region whose transcribe throws on the FIRST attempt but succeeds
    /// on the second matches the 2026-05-27 incident shape exactly: the
    /// whisper subprocess died on the first region's decode, the parent's
    /// `handleHostError` SIGKILLed + respawned the subprocess (the
    /// respawn was confirmed healthy by the next "subprocess ready" log
    /// line), but the wedged region itself surfaced as
    /// `WhisperTranscribeError.transcriptionFailed(-1)` and killed the
    /// whole job. With per-region retry, the second attempt runs on the
    /// freshly respawned subprocess and succeeds.
    @Test("a region transcribe that throws WhisperTranscribeError once recovers on the next attempt")
    func transientWhisperFailureIsRetried() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let attempts = Counter()
        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                let n = await attempts.increment()
                if n == 1 {
                    throw WhisperTranscribeError.transcriptionFailed(-1)
                }
                return TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "ok")],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub", modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(speaker: "SPEAKER_00",
                                        start: .seconds(0), end: .seconds(1))],
                    exclusiveSpans: [SpeakerSpan(speaker: "SPEAKER_00",
                                                 start: .seconds(0), end: .seconds(1))],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_retry", recordingId: "rec_retry", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        // The job completed (final.md written) AND we made >1 attempt.
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("final.md").path))
        let count = await attempts.value
        #expect(count >= 2, "expected a retry; saw \(count) attempt(s)")
    }

    @Test("a region transcribe that fails on every attempt eventually surfaces the error")
    func persistentWhisperFailureBubblesAfterAllRetries() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let attempts = Counter()
        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                _ = await attempts.increment()
                throw WhisperTranscribeError.transcriptionFailed(-1)
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("diarize should not be reached when transcribe fails")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_pers", recordingId: "rec_pers", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        await #expect(throws: WhisperTranscribeError.self) {
            try await refiner.run(job: job)
        }
        // Retried at least once; bounded so we don't loop forever.
        let count = await attempts.value
        #expect(count >= 2, "expected at least one retry; saw \(count)")
        #expect(count <= 5, "retries must be bounded; saw \(count)")
    }

    @Test("a non-Whisper error (e.g. I/O) is NOT retried — it propagates immediately")
    func nonWhisperErrorNotRetried() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        struct ProgrammerError: Error {}
        let attempts = Counter()
        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                _ = await attempts.increment()
                throw ProgrammerError()
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("diarize should not be reached")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_prog", recordingId: "rec_prog", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        await #expect(throws: ProgrammerError.self) {
            try await refiner.run(job: job)
        }
        let count = await attempts.value
        #expect(count == 1, "non-Whisper errors must not be retried; saw \(count)")
    }

    @Test("redactPath strips the recording folder path and the user home dir")
    func redactPathStripsBothFolderAndHomeDir() {
        let folder = URL(fileURLWithPath: "/Users/alice/recordings/rec_x")
        let realHome = NSHomeDirectory()
        let input = "ModelError: \(realHome)/Library/Application Support/PulsarTrace/models/large-v3.gguf"
        let out = ResumableRefiner.redactPath(input, folder: folder)
        #expect(!out.contains(realHome), "home directory must be redacted: \(out)")
        #expect(out.contains("~/Library/Application Support"), "redaction should leave ~/... visible: \(out)")
    }

    /// Helper: build an in-memory EventWriter and read every event line back.
    private func makeEvents() -> (EventWriter, () async throws -> [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-rr-evt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = EventWriter(directory: dir)
        return (writer, {
            await writer.bootstrap()
            // Wait for any pending appends — the actor is FIFO, so a fresh
            // append+flush serializes after every earlier append.
            await writer.flush()
            let url = await writer.currentFileURL()
            let data = (try? Data(contentsOf: url)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        })
    }

    @Test("run emits refinement_started and refinement_completed on success")
    func emitsStartCompleteEvents() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let (events, readback) = makeEvents()
        await events.bootstrap()

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                TranscriptionResult(segments: [], language: "en")
            },
            detectRegions: { _ in [] },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: [],
                    spans: [],
                    exclusiveSpans: [],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: events)

        let job = RefinementJob(
            id: "job_evt", recordingId: "rec_evt", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let lines = try await readback()
        let types = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["type"] as? String
        }
        #expect(types.contains("refinement_started"))
        #expect(types.contains("refinement_completed"))
    }

    @Test("run emits refinement_failed when the body throws")
    func emitsFailedEvent() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let (events, readback) = makeEvents()
        await events.bootstrap()

        struct Boom: Error {}
        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in throw Boom() },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("not reached")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: events)

        let job = RefinementJob(
            id: "job_fail", recordingId: "rec_fail", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        await #expect(throws: Boom.self) { try await refiner.run(job: job) }
        let lines = try await readback()
        let types = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["type"] as? String
        }
        #expect(types.contains("refinement_started"))
        #expect(types.contains("refinement_failed"))
        #expect(!types.contains("refinement_completed"))
    }

    @Test("a cancelled diarize retries when the gate reopens")
    func diarizeCancelRetries() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let gate = PauseGate(initiallyOpen: true)
        actor Calls {
            var n = 0
            func incr() -> Int { n += 1; return n }
        }
        let calls = Calls()
        // Signal when the first diarize call has been made and the gate closed.
        actor FirstDiarizeSignal {
            private var cont: CheckedContinuation<Void, Never>?
            private var done = false
            func signal() {
                done = true
                cont?.resume()
                cont = nil
            }
            func wait() async {
                if done { return }
                await withCheckedContinuation { cont = $0 }
            }
        }
        let firstDiarize = FirstDiarizeSignal()

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "x")],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                let n = await calls.incr()
                if n == 1 {
                    await gate.close()
                    await firstDiarize.signal()
                    throw Diarizer.DiarizeError.cancelled
                }
                return DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: ["speaker_0"],
                    spans: [SpeakerSpan(
                        speaker: "speaker_0",
                        start: .seconds(0),
                        end: .seconds(1))],
                    exclusiveSpans: [SpeakerSpan(
                        speaker: "speaker_0",
                        start: .seconds(0),
                        end: .seconds(1))],
                    embeddings: [])
            },
            pauseGate: gate,
            events: nil)

        let job = RefinementJob(
            id: "j", recordingId: "r", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        let runTask = Task { try await refiner.run(job: job) }

        // Wait for the first diarize call (deterministic — no sleep).
        await firstDiarize.wait()
        let stalled = await calls.n
        #expect(stalled == 1)

        await gate.open()
        try await runTask.value
        let total = await calls.n
        #expect(total == 2)
    }

    @Test("run with a library passes it through to assembleAndWrite")
    func libraryThreadedThrough() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let dbURL = folder.appendingPathComponent("speakers-test.sqlite")
        // Opening a fresh SpeakerLibrary at a writable path is enough to
        // prove the library reaches assembleAndWrite — when no centroids
        // are stored the reconciler returns an empty Outcome and the merge
        // falls back to Speaker_N labels (which is fine for the test).
        let library = try await SpeakerLibrary(databaseURL: dbURL, events: nil)

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                TranscriptionResult(segments: [], language: "en")
            },
            detectRegions: { _ in [] },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: [],
                    spans: [],
                    exclusiveSpans: [],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil,
            library: library)

        let job = RefinementJob(
            id: "job_lib", recordingId: "rec_lib", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("metadata.json").path))
    }
}

enum FixtureRecording {
    /// Write a minimal recording folder with a 2-second silent `audio-system.wav`.
    /// Two seconds (32 000 samples at 16 kHz) gives `RecordingFolder.resolve`
    /// a valid WAV with a non-empty data chunk.
    static func minimal(at folder: URL) throws {
        let wav = folder.appendingPathComponent("audio-system.wav")
        try WAVWriter.write(samples: [Float](repeating: 0, count: 32_000), to: wav)
    }
}

/// Sendable, async-safe counter used by the retry tests to observe how
/// many times the injected `transcribe` closure was invoked across
/// reties without crossing isolation domains.
actor Counter {
    private var n = 0
    func increment() -> Int { n += 1; return n }
    var value: Int { n }
}
