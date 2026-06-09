import Foundation
import Testing
@testable import PulsarTraceEngine

/// speakers.sqlite holds voice embeddings + names; the DB, its WAL/SHM
/// journals, and the .bak backup must all be owner-only.
@Suite("SQLite database permissions")
struct SQLitePermissionsTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sqlite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a freshly created database (and its WAL journals) is 0600")
    func freshDatabaseIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")

        let db = try SQLiteDatabase(url: dbURL)
        try db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);")

        #expect(mode(dbURL) == 0o600)
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            #expect(mode(wal) == 0o600)
        }
        let shm = URL(fileURLWithPath: dbURL.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            #expect(mode(shm) == 0o600)
        }
    }

    @Test("a pre-existing 0644 database is repaired on open")
    func legacyDatabaseIsRepaired() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        // Create through SQLite first, then loosen, then re-open.
        _ = try SQLiteDatabase(url: dbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: dbURL.path)

        _ = try SQLiteDatabase(url: dbURL)

        #expect(mode(dbURL) == 0o600)
    }

    @Test("the online backup file is 0600")
    func backupIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        let bakURL = dbURL.appendingPathExtension("bak")
        let db = try SQLiteDatabase(url: dbURL)
        try db.exec("CREATE TABLE t(x INTEGER);")

        try db.backup(to: bakURL)

        #expect(mode(bakURL) == 0o600)
    }
}
