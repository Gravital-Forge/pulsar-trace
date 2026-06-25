import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// `LiveTranscriptWatcher` tails an append-only `live.md` and exposes
/// its complete lines (PT-R40). Read-only — it never writes the file.
@Suite("LiveTranscriptWatcher")
@MainActor
struct LiveTranscriptWatcherTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-live-\(UUID().uuidString).md")
    }

    /// Append text to a file, creating it if needed.
    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("appended lines are surfaced within a timeout")
    func appendedLinesSurface() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append("<!-- pulsartrace:live -->\n## Transcript — 2026-05-16 14:30\n",
                   to: url)

        let watcher = LiveTranscriptWatcher(pollInterval: .milliseconds(50))
        watcher.start(liveMarkdownURL: url)
        defer { watcher.stop() }

        // First two lines appear.
        try await waitUntil { watcher.lines.count >= 2 }
        #expect(watcher.lines[0] == "<!-- pulsartrace:live -->")

        // A line appended after the watcher started is picked up.
        try append("**[00:00:03] You:** Hello there.\n", to: url)
        try await waitUntil { watcher.lines.count >= 3 }
        #expect(watcher.lines.last == "**[00:00:03] You:** Hello there.")
    }

    @Test("a partial line is held back until its newline arrives")
    func partialLineHeldBack() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let watcher = LiveTranscriptWatcher()
        watcher.start(liveMarkdownURL: url)
        defer { watcher.stop() }

        // Write a line with no trailing newline — it must not be surfaced yet.
        try append("incomplete line", to: url)
        await watcher.poll(url: url)
        #expect(watcher.lines.isEmpty)

        // Completing the line makes it appear.
        try append("\n", to: url)
        await watcher.poll(url: url)
        #expect(watcher.lines == ["incomplete line"])
    }

    @Test("stop() halts the watcher")
    func stopHaltsWatcher() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let watcher = LiveTranscriptWatcher(pollInterval: .milliseconds(50))
        watcher.start(liveMarkdownURL: url)
        #expect(watcher.isActive)
        watcher.stop()
        #expect(!watcher.isActive)
    }

    /// Poll `condition` up to ~3 s.
    private func waitUntil(
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "condition not met within timeout")
    }
}
