import Foundation
import SQLite3
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
        // The INSERT above is a write transaction in WAL mode, so the -wal
        // journal must exist — and, being created after init's 0644 repair,
        // it proves mode inheritance keeps post-init journals owner-only.
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        try #require(FileManager.default.fileExists(atPath: wal.path))
        #expect(mode(wal) == 0o600)
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

    @Test("a failed backup still leaves the destination owner-only")
    func failedBackupDestinationIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        let db = try SQLiteDatabase(url: dbURL)
        try db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);")

        // Failure injection: a second raw connection holds BEGIN EXCLUSIVE
        // on the destination, so `sqlite3_backup_step` inside backup(to:)
        // fails with SQLITE_BUSY after the destination handle has opened —
        // the mid-copy failure path, not the open-failure guard. The file is
        // pre-loosened to 0644 to stand in for the umask-mode file a fresh
        // `sqlite3_open_v2` would create; backup(to:) must restrict it
        // before any page copy, on the failure path too.
        let bakURL = dbURL.appendingPathExtension("bak")
        var locker: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        try #require(sqlite3_open_v2(bakURL.path, &locker, flags, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(locker) }
        try #require(sqlite3_exec(locker, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: bakURL.path)

        #expect(throws: SQLiteDatabase.SQLiteError.self) {
            try db.backup(to: bakURL)
        }

        try #require(FileManager.default.fileExists(atPath: bakURL.path))
        #expect(mode(bakURL) == 0o600)
    }
}
