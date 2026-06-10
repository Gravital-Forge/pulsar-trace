import Foundation
import Testing
@testable import PulsarTraceMenuBar

@Suite("RecordingTitleStore")
struct RecordingTitleStoreTests {

    @Test("round-trips a title, trimming whitespace and flattening newlines")
    func roundTrip() throws {
        let folder = MenuBarFixtures.tempDir()
        try RecordingTitleStore.write("  Sprint platform\nsync  ", folderURL: folder)
        #expect(RecordingTitleStore.read(folderURL: folder) == "Sprint platform sync")
    }

    @Test("absent sidecar reads nil")
    func absent() {
        #expect(RecordingTitleStore.read(folderURL: MenuBarFixtures.tempDir()) == nil)
    }

    @Test("writing a blank title removes the sidecar (restores the default title)")
    func clear() throws {
        let folder = MenuBarFixtures.tempDir()
        try RecordingTitleStore.write("Standup", folderURL: folder)
        try RecordingTitleStore.write("   \n ", folderURL: folder)
        #expect(RecordingTitleStore.read(folderURL: folder) == nil)
        let url = folder.appendingPathComponent("title.txt")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
