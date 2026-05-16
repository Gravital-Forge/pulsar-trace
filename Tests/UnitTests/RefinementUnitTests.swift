import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the Epic 4 refinement building blocks: the atomic-write
/// helper, the `metadata.json` shape, the recording-folder input dispatch, and
/// the refinement event payload encoding.
///
/// These are pure / filesystem-only and run in well under the Unit budget —
/// the heavy whisper + pyannote path is exercised by the Pipeline suite.
@Suite("Refinement units (Epic 4)")
struct RefinementUnitTests {

    /// A throwaway temp directory for one test; cleaned up by the caller.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-refine-unit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - AtomicFile

    @Test("AtomicFile.write creates the file and returns its SHA-256")
    func atomicWriteCreatesFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("final.md")

        let sha = try AtomicFile.write("hello\n", to: target)

        #expect(FileManager.default.fileExists(atPath: target.path))
        let readBack = try String(contentsOf: target, encoding: .utf8)
        #expect(readBack == "hello\n")
        // The returned hash is the SHA-256 of the bytes written.
        #expect(sha == SHA256Verifier.hexDigest(of: Data("hello\n".utf8)))
    }

    @Test("AtomicFile.write replaces an existing file in place")
    func atomicWriteReplacesExisting() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("final.md")

        try AtomicFile.write("first\n", to: target)
        try AtomicFile.write("second\n", to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "second\n")
        // No stray temp files left behind in the directory.
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
    }

    // MARK: - RecordingFolder dispatch

    @Test("A bare WAV resolves to a sibling output folder named for the stem")
    func bareWavResolvesToSiblingFolder() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("team-standup.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())

        let folder = try RecordingFolder.resolve(inputPath: wav)

        #expect(folder.directory.lastPathComponent == "team-standup")
        #expect(folder.directory.deletingLastPathComponent().path == dir.path)
        #expect(folder.systemStream.url == wav)
        #expect(folder.systemStream.isMicrophone == false)
        // A bare WAV is a single stream — no separate mic / "You".
        #expect(folder.micStream == nil)
        #expect(folder.recordingId == "rec_team-standup")
        #expect(folder.finalURL.lastPathComponent == "final.md")
        #expect(folder.metadataURL.lastPathComponent == "metadata.json")
    }

    @Test("A recording folder with audio-system + audio-mic resolves both streams")
    func recordingFolderResolvesPairedStreams() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = dir.appendingPathComponent("2026-04-30-standup")
        try FileManager.default.createDirectory(
            at: recording, withIntermediateDirectories: true)
        let system = recording.appendingPathComponent("audio-system.wav")
        let mic = recording.appendingPathComponent("audio-mic.wav")
        FileManager.default.createFile(atPath: system.path, contents: Data())
        FileManager.default.createFile(atPath: mic.path, contents: Data())

        let folder = try RecordingFolder.resolve(inputPath: recording)

        #expect(folder.directory.path == recording.path)
        #expect(folder.systemStream.url == system)
        #expect(folder.systemStream.isMicrophone == false)
        #expect(folder.micStream?.url == mic)
        #expect(folder.micStream?.isMicrophone == true)
    }

    @Test("A folder with only a system stream resolves with no mic")
    func recordingFolderSystemOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = dir.appendingPathComponent("solo")
        try FileManager.default.createDirectory(
            at: recording, withIntermediateDirectories: true)
        let system = recording.appendingPathComponent("audio-system.wav")
        FileManager.default.createFile(atPath: system.path, contents: Data())

        let folder = try RecordingFolder.resolve(inputPath: recording)
        #expect(folder.systemStream.url == system)
        #expect(folder.micStream == nil)
    }

    @Test("A missing path throws pathNotFound")
    func missingPathThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/recording.wav")
        #expect(throws: RecordingFolder.InputError.self) {
            _ = try RecordingFolder.resolve(inputPath: missing)
        }
    }

    @Test("A non-WAV file throws notAWavOrFolder")
    func nonWavFileThrows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: txt.path, contents: Data())
        #expect(throws: RecordingFolder.InputError.self) {
            _ = try RecordingFolder.resolve(inputPath: txt)
        }
    }

    @Test("Recording ids are deterministic and filesystem-safe slugs")
    func recordingIdSlugging() {
        #expect(RecordingFolder.recordingId(forName: "Team Standup!")
            == "rec_team-standup")
        #expect(RecordingFolder.recordingId(forName: "2026-04-30-sync")
            == "rec_2026-04-30-sync")
        #expect(RecordingFolder.recordingId(forName: "Team Standup!")
            == RecordingFolder.recordingId(forName: "Team Standup!"))
    }

    // MARK: - RefinementMetadata shape

    @Test("metadata.json encodes the expected snake_case shape")
    func metadataEncodesSnakeCase() throws {
        let metadata = RefinementMetadata(
            recordingId: "rec_demo",
            recordingStart: "2026-04-30T14:30:00Z",
            refinedAt: "2026-04-30T15:00:00Z",
            durationSeconds: 24.0,
            speakers: [
                .init(label: "You", isMicrophone: true),
                .init(label: "Speaker_0", isMicrophone: false),
            ],
            whisperModel: .init(name: "base", sha256: "abc123"),
            pyannoteModel: .init(
                id: "pyannote/speaker-diarization-community-1",
                revision: "deadbeef",
                libraryVersion: "4.0.4"),
            language: "en",
            sourceBasename: "demo.wav")

        let json = try metadata.encoded()
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(obj["schema_version"] as? Int == 1)
        #expect(obj["recording_id"] as? String == "rec_demo")
        #expect(obj["recording_start"] as? String == "2026-04-30T14:30:00Z")
        #expect(obj["refined_at"] as? String == "2026-04-30T15:00:00Z")
        #expect(obj["duration_seconds"] as? Double == 24.0)
        #expect(obj["language"] as? String == "en")
        #expect(obj["source_basename"] as? String == "demo.wav")

        let whisper = obj["whisper_model"] as! [String: Any]
        #expect(whisper["name"] as? String == "base")
        #expect(whisper["sha256"] as? String == "abc123")

        let pyannote = obj["pyannote_model"] as! [String: Any]
        #expect(pyannote["id"] as? String
            == "pyannote/speaker-diarization-community-1")
        #expect(pyannote["revision"] as? String == "deadbeef")
        #expect(pyannote["library_version"] as? String == "4.0.4")

        let speakers = obj["speakers"] as! [[String: Any]]
        #expect(speakers.count == 2)
        #expect(speakers[0]["label"] as? String == "You")
        #expect(speakers[0]["is_microphone"] as? Bool == true)
        #expect(speakers[1]["is_microphone"] as? Bool == false)
    }

    @Test("metadata.json round-trips through Codable")
    func metadataRoundTrips() throws {
        let metadata = RefinementMetadata(
            recordingId: "rec_demo",
            recordingStart: "2026-04-30T14:30:00Z",
            refinedAt: "2026-04-30T15:00:00Z",
            durationSeconds: 12.5,
            speakers: [.init(label: "Speaker_0", isMicrophone: false)],
            whisperModel: .init(name: "large-v3", sha256: "f00d"),
            pyannoteModel: nil,
            language: "en",
            sourceBasename: "x.wav")

        let data = try metadata.encoded()
        let decoded = try JSONDecoder().decode(RefinementMetadata.self, from: data)
        #expect(decoded == metadata)
        // pyannoteModel is omittable when diarization was skipped.
        #expect(decoded.pyannoteModel == nil)
    }

    // MARK: - Event payload encoding

    @Test("Refinement event payloads encode to the documented snake_case keys")
    func refinementEventEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func keys<P: EventPayload>(_ payload: P) throws -> [String: Any] {
            let data = try encoder.encode(payload)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        let started = try keys(RefinementStartedEvent(
            recordingId: "rec_x", modelRefine: "large-v3"))
        #expect(started["recording_id"] as? String == "rec_x")
        #expect(started["model_refine"] as? String == "large-v3")

        let completed = try keys(RefinementCompletedEvent(
            recordingId: "rec_x", durationSeconds: 7.5,
            speakersIdentified: 3, speakersNew: 3, speakersMatched: 0))
        #expect(completed["duration_seconds"] as? Double == 7.5)
        #expect(completed["speakers_identified"] as? Int == 3)
        #expect(completed["speakers_new"] as? Int == 3)
        #expect(completed["speakers_matched"] as? Int == 0)

        let failed = try keys(RefinementFailedEvent(
            recordingId: "rec_x", errorClass: "diarization", retryAvailable: true))
        #expect(failed["error_class"] as? String == "diarization")
        #expect(failed["retry_available"] as? Bool == true)

        let written = try keys(FinalMDWrittenEvent(
            recordingId: "rec_x", pathBasename: "final.md", sha256: "abc"))
        #expect(written["path_basename"] as? String == "final.md")
        #expect(written["sha256"] as? String == "abc")

        let rewritten = try keys(FinalMDRewrittenEvent(
            recordingId: "rec_x", pathBasename: "final.md",
            sha256: "abc", reason: "re_refine"))
        #expect(rewritten["reason"] as? String == "re_refine")

        let replaced = try keys(LiveMDReplacedByFinalEvent(recordingId: "rec_x"))
        #expect(replaced["recording_id"] as? String == "rec_x")
    }

    @Test("Refinement events are registered in the EventRegistry")
    func refinementEventsRegistered() {
        for type in ["refinement_started", "refinement_completed",
                     "refinement_failed", "final_md_written",
                     "final_md_rewritten", "live_md_replaced_by_final"] {
            #expect(EventRegistry.entry(for: type) != nil,
                    "\(type) should be registered")
        }
    }
}
