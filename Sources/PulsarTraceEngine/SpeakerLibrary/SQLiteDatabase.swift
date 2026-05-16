import Foundation
import SQLite3

/// A thin, non-throwing-where-possible wrapper over the system `SQLite3` C
/// library — just enough surface for `SpeakerLibrary` (R28).
///
/// We use the C `SQLite3` module that ships with macOS rather than adding a
/// SwiftPM dependency: it has no supply-chain surface, no version drift, and
/// the speaker-library schema is small enough that a hand-rolled wrapper is
/// less code than integrating and pinning a third-party package
/// (DECISIONS.md D17).
///
/// Not an `actor`: serialization is the caller's job — `SpeakerLibrary` is the
/// actor that owns exactly one `SQLiteDatabase` and never shares it.
final class SQLiteDatabase {

    /// SQLITE_TRANSIENT — tells SQLite to copy a bound blob/text immediately,
    /// so the Swift buffer can be freed as soon as `bind` returns.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    enum SQLiteError: Error, CustomStringConvertible {
        case open(Int32, String)
        case prepare(Int32, String)
        case step(Int32, String)
        case integrityFailed(String)
        case journalModeNotWAL(String)
        case backupFailed(Int32, String)

        var description: String {
            switch self {
            case .open(let c, let m): return "sqlite open failed (\(c)): \(m)"
            case .prepare(let c, let m): return "sqlite prepare failed (\(c)): \(m)"
            case .step(let c, let m): return "sqlite step failed (\(c)): \(m)"
            case .integrityFailed(let m): return "sqlite integrity check failed: \(m)"
            case .journalModeNotWAL(let m):
                return "sqlite WAL journal mode could not be set (R32a); got: \(m)"
            case .backupFailed(let c, let m):
                return "sqlite online backup failed (\(c)): \(m)"
            }
        }
    }

    private var handle: OpaquePointer?

    /// Open (creating if absent) the database at `url` in WAL journal mode
    /// (R32a). Throws `SQLiteError.open` on a connection failure — the caller
    /// (`SpeakerLibrary`) treats that as corruption and restores from backup.
    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            handle = nil
            throw SQLiteError.open(rc, message)
        }
        // WAL (R32a): a concurrent reader (the live engine, Epic 6) and a
        // single writer coexist; two writers serialize on SQLite's lock.
        //
        // `sqlite3_exec` reports SQLITE_OK even when SQLite silently falls
        // back to delete-journal mode (e.g. on a filesystem that cannot
        // support WAL's shared memory). WAL is a P0 contract, so read the
        // mode back and verify — a failure throws so the corruption-recovery
        // path can react and the user gets a diagnostic.
        try exec("PRAGMA journal_mode=WAL;")
        let journalMode = try query("PRAGMA journal_mode;")
            .first?.string(0) ?? "unknown"
        guard journalMode.lowercased() == "wal" else {
            throw SQLiteError.journalModeNotWAL(journalMode)
        }
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Run one or more statements with no result rows / no bindings.
    func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError.step(rc, message)
        }
    }

    /// Run `PRAGMA integrity_check` — throws when the database is corrupt.
    func integrityCheck() throws {
        let rows = try query("PRAGMA integrity_check;")
        let ok = rows.count == 1 && rows.first?.string(0) == "ok"
        guard ok else {
            throw SQLiteError.integrityFailed(rows.first?.string(0) ?? "unknown")
        }
    }

    /// One bindable value for a prepared statement.
    enum Value {
        case text(String)
        case int(Int64)
        case blob(Data)
        case null
    }

    /// A read-only view of one result row.
    struct Row {
        fileprivate let columns: [Value]

        func string(_ index: Int) -> String? {
            if case .text(let s) = columns[index] { return s }
            return nil
        }
        func int(_ index: Int) -> Int64? {
            if case .int(let i) = columns[index] { return i }
            return nil
        }
        func blob(_ index: Int) -> Data? {
            if case .blob(let d) = columns[index] { return d }
            return nil
        }
        func isNull(_ index: Int) -> Bool {
            if case .null = columns[index] { return true }
            return false
        }
    }

    /// Run a statement that mutates rows (INSERT/UPDATE/DELETE).
    func run(_ sql: String, _ bindings: [Value] = []) throws {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(rc, String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Run a SELECT (or a PRAGMA returning rows) and collect every row.
    func query(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.step(rc, String(cString: sqlite3_errmsg(handle)))
            }
            let columnCount = Int(sqlite3_column_count(stmt))
            var values: [Value] = []
            values.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                switch sqlite3_column_type(stmt, Int32(i)) {
                case SQLITE_INTEGER:
                    values.append(.int(sqlite3_column_int64(stmt, Int32(i))))
                case SQLITE_TEXT:
                    values.append(.text(String(
                        cString: sqlite3_column_text(stmt, Int32(i)))))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, Int32(i)) {
                        let count = Int(sqlite3_column_bytes(stmt, Int32(i)))
                        values.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        values.append(.blob(Data()))
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(Row(columns: values))
        }
        return rows
    }

    /// The schema migration counter (`PRAGMA user_version`). 0 on a fresh
    /// database; `SpeakerLibrary.migrate` sets it to the current schema
    /// version so Epic 8's migration knows what is already applied.
    var userVersion: Int32 {
        get {
            (try? query("PRAGMA user_version;").first?.int(0)).flatMap { $0 }
                .map(Int32.init) ?? 0
        }
    }

    /// Set `PRAGMA user_version`. `user_version` does not accept a bound
    /// parameter, so the integer is interpolated — safe here, the value is
    /// always a compile-time constant.
    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version=\(version);")
    }

    /// Produce a self-contained copy of this database at `destinationURL`
    /// using SQLite's online backup API (`sqlite3_backup_*`). Unlike copying
    /// the main file after a `wal_checkpoint`, this is correct even when the
    /// checkpoint cannot acquire an exclusive lock — it reads through the WAL
    /// and produces a consistent snapshot of the live database. Any existing
    /// file at `destinationURL` is overwritten.
    func backup(to destinationURL: URL) throws {
        var destHandle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openRC = sqlite3_open_v2(destinationURL.path, &destHandle, flags, nil)
        guard openRC == SQLITE_OK, let dest = destHandle else {
            let message = destHandle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            if let h = destHandle { sqlite3_close_v2(h) }
            throw SQLiteError.backupFailed(openRC, message)
        }
        defer { sqlite3_close_v2(dest) }

        guard let backup = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw SQLiteError.backupFailed(
                sqlite3_errcode(dest), String(cString: sqlite3_errmsg(dest)))
        }
        // `-1` copies every remaining page in one step.
        let stepRC = sqlite3_backup_step(backup, -1)
        let finishRC = sqlite3_backup_finish(backup)
        guard stepRC == SQLITE_DONE else {
            throw SQLiteError.backupFailed(
                stepRC, String(cString: sqlite3_errmsg(dest)))
        }
        guard finishRC == SQLITE_OK else {
            throw SQLiteError.backupFailed(
                finishRC, String(cString: sqlite3_errmsg(dest)))
        }
    }

    /// Run `body` inside a single transaction; rolls back on a thrown error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Private

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, stmt != nil else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let stmt { sqlite3_finalize(stmt) }
            throw SQLiteError.prepare(rc, message)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s):
                sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .int(let i):
                sqlite3_bind_int64(stmt, index, i)
            case .blob(let d):
                if d.isEmpty {
                    sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    _ = d.withUnsafeBytes {
                        sqlite3_bind_blob(
                            stmt, index, $0.baseAddress, Int32(d.count),
                            Self.transient)
                    }
                }
            case .null:
                sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }
}
