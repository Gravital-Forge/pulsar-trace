import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the append-only `live.md` writer (PT-R12, PT-R35a, PT-R36, PT-R37).
///
/// `live.md` is a public API surface an agent `tail -f`s. These tests assert
/// the two hard invariants: created at session start with marker + header
/// (PT-R35a/PT-R37), and strictly append-only with monotonic byte growth (PT-R36/PT-R12).
@Suite("Append-only live.md writer")
struct LiveMarkdownWriterTests {

    /// A throwaway temp directory for one test's `live.md`.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-live-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fixed recording-start instant for deterministic header assertions.
    private var fixedStart: Date {
        // 2026-05-16 09:30 local.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 16
        comps.hour = 9; comps.minute = 30
        return Calendar.current.date(from: comps)!
    }

    @Test("start() creates live.md with the marker and header (PT-R35a/PT-R37)")
    func startCreatesMarkerAndHeader() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        await writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1] == "## Transcript — 2026-05-16 09:30")
    }

    @Test("the file exists before any utterance is appended (PT-R35a)")
    func fileExistsBeforeFirstUtterance() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        // No appendUtterance yet — file must already be on disk.
        #expect(FileManager.default.fileExists(atPath: url.path))
        await writer.finish()
    }

    @Test("appendUtterance renders the PT-R13 line format")
    func appendUtteranceLineFormat() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        try await writer.appendUtterance(
            offset: .seconds(5),
            speakerLabel: "Them?",
            text: "so the auth flow breaks")
        try await writer.appendUtterance(
            offset: .seconds(3672),   // 01:01:12
            speakerLabel: "You",
            text: "right, the redirect uri")
        await writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("**[00:00:05] Them?:** so the auth flow breaks"))
        #expect(text.contains("**[01:01:12] You:** right, the redirect uri"))
    }

    @Test("every append strictly increases the byte count (PT-R36/PT-R12)")
    func appendsAreMonotonic() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        var sizes: [Int] = [await writer.bytesWritten]

        for i in 0..<10 {
            try await writer.appendUtterance(
                offset: .seconds(i),
                speakerLabel: "Them?",
                text: "utterance number \(i)")
            sizes.append(await writer.bytesWritten)
        }
        await writer.finish()

        // Strictly monotonic — a tail -f consumer never sees a shrink.
        for i in 1..<sizes.count {
            #expect(sizes[i] > sizes[i - 1])
        }
        // The byte counter matches the file on disk exactly.
        let onDisk = try Data(contentsOf: url).count
        #expect(onDisk == sizes.last)
    }

    @Test("appends never rewrite earlier content — prefix is stable (PT-R36)")
    func appendsNeverRewrite() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()

        var snapshots: [String] = []
        try await writer.appendLine("**[00:00:01] Them?:** first")
        snapshots.append(try String(contentsOf: url, encoding: .utf8))
        try await writer.appendLine("**[00:00:02] Them?:** second")
        snapshots.append(try String(contentsOf: url, encoding: .utf8))
        try await writer.appendLine("**[00:00:03] You:** third")
        snapshots.append(try String(contentsOf: url, encoding: .utf8))
        await writer.finish()

        // Each snapshot must be a strict prefix of the next — append-only.
        #expect(snapshots[1].hasPrefix(snapshots[0]))
        #expect(snapshots[2].hasPrefix(snapshots[1]))
    }

    @Test("a second start() throws rather than truncating (append-only)")
    func secondStartThrows() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        await #expect(throws: LiveMarkdownWriter.WriteError.self) {
            try await writer.start()
        }
        await writer.finish()
    }

    @Test("appending before start() throws")
    func appendBeforeStartThrows() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        await #expect(throws: LiveMarkdownWriter.WriteError.self) {
            try await writer.appendLine("orphan line")
        }
    }

    @Test("gap annotations render as italic notes and stay append-only (PT-R7)")
    func gapAnnotations() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        try await writer.appendUtterance(
            offset: .seconds(1), speakerLabel: "You", text: "before the gap")
        let beforeGap = await writer.bytesWritten
        try await writer.appendGapAnnotation(.paused)
        try await writer.appendGapAnnotation(.resumed(.seconds(125)))
        #expect(await writer.bytesWritten > beforeGap)
        await writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("_(recording paused)_"))
        #expect(text.contains("_(recording resumed after 2m 05s)_"))
    }

    @Test("live.md is created owner-only (0600)")
    func liveFileIsOwnerOnly() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        await writer.finish()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("multi-byte UTF-8 content is written whole (no torn character, PT-R12)")
    func multibyteContentIntact() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        // Emoji + accented characters — encoded before the write.
        try await writer.appendUtterance(
            offset: .seconds(1),
            speakerLabel: "Them?",
            text: "café résumé 日本語 👍")
        await writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("café résumé 日本語 👍"))
    }
}
