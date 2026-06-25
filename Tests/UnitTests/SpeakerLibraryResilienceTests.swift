import Testing
import Foundation
@testable import PulsarTraceEngine

/// Coverage of the speaker-library resilience edge cases:
/// the last-good backup on every write, and auto-restore + warn when the
/// database is found corrupt on open.
@Suite("Speaker library resilience")
struct SpeakerLibraryResilienceTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-speakerlib-res-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func syntheticEmbedding(axis: Int) -> [Float] {
        var v = [Float](repeating: 0.01, count: 256)
        v[axis % 256] = 1.0
        return v
    }

    @Test("every mutating write first creates a last-good .bak + event")
    func backupBeforeWrite() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        let backupURL = dbURL.appendingPathExtension("bak")

        let eventsDir = dir.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let library = try await SpeakerLibrary(databaseURL: dbURL, events: events)
        _ = try await library.createSpeaker(
            name: "Unknown #1", centroid: syntheticEmbedding(axis: 1),
            modelRevision: "r", recordingId: "rec_a", recordingFolderName: "a")
        // A second write — the first write's state is now snapshotted.
        try await library.rename(speakerId:
            try #require(try await library.liveSpeakers().first).id, to: "Steve")

        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        await events.flush()
        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.contains("\"type\":\"library_backup_created\""))
        #expect(log.contains("\"path_basename\":\"speakers.sqlite.bak\""))
    }

    @Test("a corrupt database is auto-restored from the last-good backup + warns")
    func corruptionAutoRestore() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        let backupURL = dbURL.appendingPathExtension("bak")

        // Build a healthy library with two speakers, so a `.bak` snapshot
        // exists (the backup is taken *before* each write — so after two
        // creates the backup holds the one-speaker state).
        let stableID: String
        do {
            let library = try await SpeakerLibrary(databaseURL: dbURL)
            let first = try await library.createSpeaker(
                name: "Steve", centroid: syntheticEmbedding(axis: 1),
                modelRevision: "r", recordingId: "rec_a", recordingFolderName: "a")
            stableID = first.id
            // A second write so the backup captures the first speaker.
            _ = try await library.createSpeaker(
                name: "Unknown #2", centroid: syntheticEmbedding(axis: 2),
                modelRevision: "r", recordingId: "rec_b", recordingFolderName: "b")
        }
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        // Corrupt the main database file: overwrite it with garbage.
        try Data(repeating: 0xEE, count: 4096).write(to: dbURL)
        // Clear WAL/SHM sidecars so the corrupt main file is what gets opened.
        for sidecar in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: dbURL.path + sidecar))
        }

        // Re-open: corruption is detected, the backup is restored, and a
        // `library_corruption_detected` event is emitted.
        let eventsDir = dir.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()
        let recovered = try await SpeakerLibrary(
            databaseURL: dbURL, events: events)

        // The first speaker survives in the restored backup with its stable id.
        let survivor = try await recovered.speaker(id: stableID)
        #expect(survivor?.name == "Steve")

        await events.flush()
        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.contains("\"type\":\"library_corruption_detected\""))
        #expect(log.contains("\"recovered_from_backup\":true"))
    }

    @Test("a fresh database opens cleanly without a corruption event")
    func freshDatabaseOpensClean() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let library = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"),
            events: events)
        #expect(try await library.liveSpeakers().isEmpty)

        await events.flush()
        let log = (try? String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)) ?? ""
        #expect(!log.contains("library_corruption_detected"))
    }
}
