import Testing
import Foundation
@testable import PulsarTraceEngine

/// Epic 8 Step 1 — the engine-side retroactive `final.md` rewrite (D16).
///
/// `FinalMarkdownRewriter` rewrites a speaker label across past `final.md`
/// files after a rename/merge/split. These tests build hand-written fixture
/// recording folders in a per-test temp directory so nothing real is touched,
/// and assert the rewrite is surgical: only the utterance-line *label* field
/// changes, prose and structural lines are byte-identical, `live.md` is never
/// touched, and one `final_md_rewritten` event fires per rewritten recording.
@Suite("FinalMarkdownRewriter (Epic 8)")
struct FinalMarkdownRewriterTests {

    // MARK: - Fixtures

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fmr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A hand-written `final.md` body: marker + header + a few utterance lines,
    /// including one co-attributed `A+B` line and one prose line that mentions
    /// a speaker name inside transcript text (must NOT be rewritten).
    private static let finalMarkdown = """
        <!-- pulsartrace:final -->
        ## Transcript — 2026-05-01 09:00

        **[00:00:03] Unknown #1:** Morning everyone, let us start.

        **[00:00:09] Steve:** Did Unknown #1 send the agenda yet?

        **[00:00:15] Unknown #1+Steve:** Yes — over to you.

        **[00:00:20] You:** Thanks, I will share my screen.

        """

    /// Minimal `metadata.json` matching `RefinementMetadata`, with the
    /// `Unknown #1` speaker present in its speakers array.
    private func metadata(recordingId: String) throws -> Data {
        try RefinementMetadata(
            recordingId: recordingId,
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 30,
            speakers: [
                .init(label: "Unknown #1", isMicrophone: false,
                      speakerId: "spk_aaa"),
                .init(label: "Steve", isMicrophone: false, speakerId: "spk_bbb"),
                .init(label: "You", isMicrophone: true, speakerId: nil),
            ],
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            pyannoteModel: nil,
            language: "en",
            sourceBasename: "meeting.wav").encoded()
    }

    /// Create a recording folder with a `final.md` + `metadata.json`.
    @discardableResult
    private func makeRecordingFolder(
        root: URL, name: String, recordingId: String
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data(Self.finalMarkdown.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        try metadata(recordingId: recordingId).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
        return folder
    }

    private func makeAppearance(
        recordingId: String, folderName: String
    ) -> SpeakerAppearance {
        SpeakerAppearance(
            speakerId: "spk_aaa", recordingId: recordingId,
            recordingFolderName: folderName, observedAt: "2026-05-01T09:00:00Z")
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

    // MARK: - Rename rewrites the label only

    @Test("a rename rewrites the label, leaves prose + structure untouched")
    func renameRewritesLabelOnly() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(
            root: root, name: "2026-05-01-standup", recordingId: "rec_standup")
        let finalURL = folder.appendingPathComponent(
            RecordingFolder.FileName.final)

        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_standup", folderName: "2026-05-01-standup")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        #expect(results.count == 1)
        #expect(results[0].recordingId == "rec_standup")

        let bytes = try Data(contentsOf: finalURL)
        let rewritten = String(decoding: bytes, as: UTF8.self)

        // The label field is rewritten in both utterance lines that carried it.
        #expect(rewritten.contains("**[00:00:03] Alice:**"))
        #expect(!rewritten.contains("**[00:00:03] Unknown #1:**"))
        // Transcript prose that merely mentions the old name is untouched.
        #expect(rewritten.contains("Did Unknown #1 send the agenda yet?"))
        // Structural lines preserved byte-for-byte.
        #expect(rewritten.hasPrefix("<!-- pulsartrace:final -->\n"))
        #expect(rewritten.contains("## Transcript — 2026-05-01 09:00"))
        #expect(rewritten.hasSuffix("\n"))

        // The returned SHA-256 matches the file bytes on disk.
        #expect(results[0].newSHA256 == AtomicFile.sha256Hex(bytes))

        // The prior file was backed up to final.md.bak.
        let backupURL = folder.appendingPathComponent(
            RecordingFolder.FileName.finalBackup)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backup = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(backup == Self.finalMarkdown)
    }

    // MARK: - Co-attributed A+B line

    @Test("a co-attributed A+B label updates only the matching component")
    func coAttributedLabelUpdatesRightComponent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRecordingFolder(
            root: root, name: "rec-folder", recordingId: "rec_x")

        _ = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_x", folderName: "rec-folder")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        let rewritten = try String(
            contentsOf: root.appendingPathComponent("rec-folder")
                .appendingPathComponent(RecordingFolder.FileName.final),
            encoding: .utf8)
        // Only the `Unknown #1` component of `Unknown #1+Steve` changed.
        #expect(rewritten.contains("**[00:00:15] Alice+Steve:**"))
        #expect(!rewritten.contains("Unknown #1+Steve"))
    }

    // MARK: - CRLF line endings

    @Test("a CRLF final.md is rewritten and keeps its \\r\\n terminators")
    func crlfFinalMarkdownRewritten() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("crlf-folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        // The same fixture body with every "\n" replaced by "\r\n".
        let crlf = Self.finalMarkdown.replacingOccurrences(
            of: "\n", with: "\r\n")
        let finalURL = folder.appendingPathComponent(
            RecordingFolder.FileName.final)
        try Data(crlf.utf8).write(to: finalURL)
        try metadata(recordingId: "rec_crlf").write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))

        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_crlf", folderName: "crlf-folder")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        // A `\r` stuck to the label must NOT defeat the match — the rewrite
        // genuinely changed the file.
        #expect(results.count == 1)
        let rewrittenBytes = try Data(contentsOf: finalURL)
        let rewritten = String(decoding: rewrittenBytes, as: UTF8.self)
        // The label field was rewritten despite the CRLF line endings.
        #expect(rewritten.contains("**[00:00:03] Alice:** Morning"))
        #expect(!rewritten.contains("Unknown #1:**"))
        // CRLF terminators are preserved byte-for-byte: every "\n" byte is
        // still preceded by a "\r" byte, and the count is unchanged.
        let crBytes = rewrittenBytes.filter { $0 == 0x0D }.count
        let lfBytes = rewrittenBytes.filter { $0 == 0x0A }.count
        #expect(crBytes == lfBytes)
        #expect(rewritten.components(separatedBy: "\r\n").count
            == crlf.components(separatedBy: "\r\n").count)
    }

    // MARK: - A no-op rewrite changes nothing

    @Test("a rewrite that touches no label leaves the file and creates no .bak")
    func noOpRewriteSkipsRecording() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(
            root: root, name: "untouched", recordingId: "rec_untouched")
        let finalURL = folder.appendingPathComponent(
            RecordingFolder.FileName.final)
        let before = try Data(contentsOf: finalURL)

        // `Nonexistent` never appears in any label.
        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Nonexistent", newName: "Whoever",
            appearances: [makeAppearance(
                recordingId: "rec_untouched", folderName: "untouched")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        // No genuine change → no result, file untouched, no .bak.
        #expect(results.isEmpty)
        #expect(try Data(contentsOf: finalURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(
                RecordingFolder.FileName.finalBackup).path))
    }

    // MARK: - Missing folder is skipped

    @Test("an appearance pointing at a non-existent folder is skipped")
    func missingFolderSkipped() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_gone", folderName: "folder-not-on-disk")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        // No throw, and the missing recording is absent from the results.
        #expect(results.isEmpty)
    }

    // MARK: - A live.md-only folder is skipped, live.md untouched

    @Test("a folder with only live.md and no final.md is skipped untouched")
    func liveOnlyFolderSkipped() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("live-only", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let liveContent = """
            <!-- pulsartrace:live -->
            ## Transcript — 2026-05-01 09:00

            **[00:00:03] Unknown #1 (provisional):** Morning everyone.

            """
        let liveURL = folder.appendingPathComponent(
            RecordingFolder.FileName.live)
        try Data(liveContent.utf8).write(to: liveURL)
        let liveBytesBefore = try Data(contentsOf: liveURL)

        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_live", folderName: "live-only")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        #expect(results.isEmpty)
        // live.md is byte-identical — Hard Invariant #4.
        #expect(try Data(contentsOf: liveURL) == liveBytesBefore)
    }

    // MARK: - metadata.json speaker labels are updated

    @Test("metadata.json speaker labels are updated")
    func metadataLabelsUpdated() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(
            root: root, name: "meta-folder", recordingId: "rec_meta")

        _ = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [makeAppearance(
                recordingId: "rec_meta", folderName: "meta-folder")],
            outputFolderRoots: [root],
            reason: .speakerRenamed)

        let meta = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: folder.appendingPathComponent(
                RecordingFolder.FileName.metadata)))
        #expect(meta.speakers.contains { $0.label == "Alice" })
        #expect(!meta.speakers.contains { $0.label == "Unknown #1" })
        // The unrelated speaker and the stable speaker_id are preserved.
        #expect(meta.speakers.contains { $0.label == "Steve" })
        #expect(meta.speakers.first { $0.label == "Alice" }?.speakerId
            == "spk_aaa")
    }

    // MARK: - final_md_rewritten events (emitted by the caller)

    @Test("one final_md_rewritten event is emitted per rewritten recording")
    func eventsEmittedPerRecording() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRecordingFolder(
            root: root, name: "rec-a", recordingId: "rec_a")
        try makeRecordingFolder(
            root: root, name: "rec-b", recordingId: "rec_b")

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        // The rewriter no longer emits events — it returns results and the
        // caller emits one `final_md_rewritten` per result (single emission
        // site, no double-emit risk).
        let reason = FinalMarkdownRewriter.RewriteReason.speakerMerged
        let results = try await FinalMarkdownRewriter().rewrite(
            oldName: "Unknown #1", newName: "Alice",
            appearances: [
                makeAppearance(recordingId: "rec_a", folderName: "rec-a"),
                makeAppearance(recordingId: "rec_b", folderName: "rec-b"),
            ],
            outputFolderRoots: [root],
            reason: reason)
        for result in results {
            _ = try await events.append(FinalMDRewrittenEvent(
                recordingId: result.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: result.newSHA256,
                reason: reason.rawValue))
        }
        await events.flush()

        #expect(results.count == 2)
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(types == ["final_md_rewritten", "final_md_rewritten"])

        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        // The merge reason raw value is carried into the event.
        #expect(log.contains("\"reason\":\"speaker_merged\""))
        #expect(log.contains("\"recording_id\":\"rec_a\""))
        #expect(log.contains("\"recording_id\":\"rec_b\""))
        #expect(log.contains("\"path_basename\":\"final.md\""))
        // The event SHA matches the result SHA.
        #expect(log.contains("\"sha256\":\"\(results[0].newSHA256)\""))
    }

    // MARK: - SpeakerLibrary suppressEvent overload

    @Test("rename with suppressEvent mutates the DB but emits no event")
    func renameSuppressEventEmitsNothing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)

        let speaker = try await library.createSpeaker(
            name: "Unknown #1", centroid: [Float](repeating: 0.1, count: 256),
            modelRevision: "rev1", recordingId: "rec_a",
            recordingFolderName: "rec-a")

        let oldName = try await library.rename(
            speakerId: speaker.id, to: "Alice", suppressEvent: true)
        await events.flush()

        // The DB mutation happened: the name is updated and the old name
        // is returned for the caller to drive the rewrite.
        #expect(oldName == "Unknown #1")
        let reloaded = try await library.speaker(id: speaker.id)
        #expect(reloaded?.name == "Alice")

        // No speaker_renamed event was emitted — the caller emits it later.
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(!types.contains("speaker_renamed"))
        // The unrelated speaker_created from createSpeaker is still present.
        #expect(types.contains("speaker_created"))
    }
}
