import Foundation
import Logging

/// The persistent, cross-recording speaker library (PT-R28, PT-R30, PT-R32a,
/// PT-R32b, PT-R83).
///
/// An `actor` over a single SQLite database (`speakers.sqlite`). Diarization
/// produces a per-speaker 256-d embedding per recording; this library grows a
/// running-mean *centroid* per speaker so a returning voice in a later
/// recording is matched by cosine similarity and auto-labelled by name.
///
/// Why an actor: the database file is mutable shared state and corruption
/// recovery / backup must not interleave with a write. SQLite's own WAL mode
/// (PT-R32a) handles a *separate process* reading/writing concurrently; the actor
/// serializes the *in-process* callers (the refine pipeline and the
/// `pulsartrace speakers` CLI). This mirrors the `swift-actor-persistence`
/// pattern: an actor fronting file-backed storage.
///
/// Resilience (edge case "library corrupted"): before every mutating write the
/// database file is copied to a last-good `.bak`; on open, a failed
/// connection / integrity check restores from that `.bak`.
public actor SpeakerLibrary {

    /// Default cosine-similarity match threshold (PT-R18/PT-R22, configurable).
    /// Calibrated for the WeSpeaker embedding space (PT-P5-D4): on the committed
    /// fixtures, same-speaker similarity measured ~0.93, cross-speaker ~0.35
    /// (see the DiarizationE2E calibration suite). Pinned below the midpoint to
    /// favour recall of returning speakers — cross-session same-speaker
    /// similarity runs lower than the in-clip measurement.
    public static let defaultMatchThreshold = 0.45

    /// Soft-delete recovery window (PT-R32b — 30 days).
    public static let recoveryWindow: TimeInterval = 30 * 86_400

    public enum LibraryError: Error, CustomStringConvertible {
        case speakerNotFound(String)
        case speakerNotDeleted(String)
        case speakerNotDelisted(String)
        case notMergeable(String)
        case database(Error)
        case modelRevisionMismatch(stored: String, incoming: String)

        public var description: String {
            switch self {
            case .speakerNotFound(let id): return "speaker not found: \(id)"
            case .speakerNotDeleted(let id):
                return "speaker is not deleted (nothing to undo): \(id)"
            case .speakerNotDelisted(let id):
                return "speaker is not delisted (nothing to undo): \(id)"
            case .notMergeable(let m): return "speakers not mergeable: \(m)"
            case .database(let e): return "speaker library database error: \(e)"
            case .modelRevisionMismatch(let s, let i):
                return "centroid model revision mismatch (stored \(s), incoming \(i))"
            }
        }
    }

    private let databaseURL: URL
    private let backupURL: URL
    private let events: EventWriter?
    private let logger: Logger
    private let clock: @Sendable () -> Date
    private let ulidFactory: @Sendable (Date) -> ULID
    private var database: SQLiteDatabase

    /// In-memory cache of every live speaker, so `bestMatch` is a pure
    /// in-memory cosine sweep — fast even at ~10k speakers — rather than a
    /// SQLite read of every 1 KB centroid BLOB per query. Lazily (re)loaded;
    /// invalidated by any mutation (`cachedLiveSpeakers = nil`).
    private var cachedLiveSpeakers: [Speaker]?

    /// Open (creating + migrating if needed) the library at `databaseURL`.
    ///
    /// - Parameters:
    ///   - databaseURL: the `speakers.sqlite` path. Tests pass a temp path so
    ///     the real `~/Library` is never touched.
    ///   - events: events writer; `nil` disables event emission.
    ///   - clock / ulidFactory: injectable for deterministic tests.
    public init(
        databaseURL: URL,
        events: EventWriter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        ulidFactory: @escaping @Sendable (Date) -> ULID = { ULID.generate(timestamp: $0) },
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) async throws {
        self.databaseURL = databaseURL
        self.backupURL = databaseURL.appendingPathExtension("bak")
        self.events = events
        self.clock = clock
        self.ulidFactory = ulidFactory
        self.logger = logger

        try SecureFiles.ensurePrivateDirectory(
            at: databaseURL.deletingLastPathComponent())

        // Open + integrity-check; on corruption restore the last-good backup.
        let opened = try await Self.openWithRecovery(
            databaseURL: databaseURL, backupURL: backupURL,
            events: events, logger: logger)
        self.database = opened
        try Self.migrate(opened)
    }

    // MARK: - Open + corruption recovery

    /// Open the database; on a failed connection or a failed integrity check,
    /// restore the last-good `.bak` (if any) and retry once. Emits
    /// `library_corruption_detected` describing the outcome.
    private static func openWithRecovery(
        databaseURL: URL,
        backupURL: URL,
        events: EventWriter?,
        logger: Logger
    ) async throws -> SQLiteDatabase {
        func tryOpen() -> SQLiteDatabase? {
            guard let db = try? SQLiteDatabase(url: databaseURL) else { return nil }
            do { try db.integrityCheck() } catch { return nil }
            return db
        }

        if let db = tryOpen() { return db }

        // The database is missing-but-creatable vs. genuinely corrupt: a fresh
        // file opens cleanly, so reaching here with a file present means
        // corruption. Restore the backup.
        logger.error("speaker library failed to open — attempting backup restore")
        let fm = FileManager.default
        let backupExists = fm.fileExists(atPath: backupURL.path)
        if backupExists {
            // Clear the corrupt file + its WAL/SHM sidecars, then restore.
            for sidecar in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + sidecar)
                try? fm.removeItem(at: url)
            }
            try fm.copyItem(at: backupURL, to: databaseURL)
        }
        _ = try? await events?.append(LibraryCorruptionDetectedEvent(
            pathBasename: databaseURL.lastPathComponent,
            recoveredFromBackup: backupExists))

        if let db = tryOpen() { return db }
        throw LibraryError.database(SQLiteDatabase.SQLiteError.integrityFailed(
            "database unrecoverable and no usable backup"))
    }

    /// Copy the live database to its last-good `.bak` ahead of a mutating
    /// write (edge case "library corrupted").
    ///
    /// Suspension-free by design (SW3): the actor can suspend at an `await`,
    /// letting another task interleave and overwrite the `.bak` between the
    /// snapshot and the caller's DB transaction. So this method takes no
    /// `await` — it is `nonisolated`-style synchronous work — and does NOT
    /// emit the `library_backup_created` event itself. The caller emits that
    /// event via `emitBackupEvent` only *after* its mutating transaction has
    /// committed, so no suspension point ever sits between snapshot and
    /// write, and the event still pairs causally with a completed mutation.
    ///
    /// The backup is produced with SQLite's online backup API (SW4 —
    /// `SQLiteDatabase.backup(to:)`), which reads through the WAL and so is
    /// correct even when a checkpoint cannot take an exclusive lock; copying
    /// the main file after a best-effort `wal_checkpoint` could omit
    /// uncheckpointed WAL frames and produce a stale `.bak`.
    ///
    /// Every mutation calls this first, so it is also where the in-memory
    /// live-speaker cache is invalidated — the cache is rebuilt lazily on the
    /// next read.
    ///
    /// - Returns: the `library_backup_created` event to emit after the
    ///   mutating transaction, or `nil` if no backup was taken (no database
    ///   file yet) or the backup failed (logged, non-fatal).
    private func backupBeforeWrite() -> LibraryBackupCreatedEvent? {
        invalidateCache()
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return nil }
        do {
            try database.backup(to: backupURL)
            let sha = sha256Hex(of: backupURL)
            return LibraryBackupCreatedEvent(
                pathBasename: backupURL.lastPathComponent, sha256: sha)
        } catch {
            // A failed backup is logged but not fatal — the write still
            // proceeds; the prior `.bak` remains the last-good snapshot.
            logger.error("speaker library backup failed: \((error as NSError).domain)")
            return nil
        }
    }

    /// Emit the `library_backup_created` event returned by `backupBeforeWrite`,
    /// called by each mutator *after* its DB transaction commits (SW3 —
    /// keeps the backup-then-mutate critical section suspension-free and the
    /// event causally after the mutation it protected).
    private func emitBackupEvent(_ event: LibraryBackupCreatedEvent?) async {
        guard let event else { return }
        _ = try? await events?.append(event)
    }

    private func sha256Hex(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256Verifier.hexDigest(of: data)
    }

    // MARK: - Schema (PT-R28)

    /// The current speaker-library schema version. Stored in `PRAGMA
    /// user_version` (S3) so a future schema migration can tell what is applied.
    /// Bump this and add a versioned migration step when the schema changes.
    ///
    /// History:
    /// - v1: initial `speakers` + `appearances` schema.
    /// - v2: adds `speakers.delisted_at` ("Don't recognize this speaker"
    ///   tombstone) and its index. The base CREATE on a fresh DB already
    ///   includes the column; the migration ran `ALTER TABLE` for an
    ///   existing v1 database.
    /// - v3: PT-P5-D3 — diarization moved to FluidAudio/WeSpeaker embeddings.
    ///   `pyannote_model_revision` → `model_revision`, and a pre-v3 database
    ///   is archived to `speakers.sqlite.pre-v3.bak` and reset: pyannote-space
    ///   centroids can never match WeSpeaker embeddings, so carrying the rows
    ///   forward would only accumulate permanently-dead entries.
    private static let schemaVersion: Int32 = 3

    private static func migrate(_ db: SQLiteDatabase) throws {
        // v2 → v3 (PT-P5-D3): the embedding space changed (pyannote → WeSpeaker), so
        // every stored centroid is permanently unmatchable. Archive the whole
        // database file and start fresh rather than carrying dead rows.
        //
        // `VACUUM INTO` cannot run inside a transaction, so this archive-and-
        // reset step lives BEFORE the DDL transaction below. `PRAGMA
        // table_info` on a missing table returns no rows, so a fresh database
        // (no `speakers` table yet) skips this entirely. The old
        // `pyannote_model_revision` column is the marker for any pre-v3 schema
        // (it existed in both v1 and v2), so a v1 database is archived and
        // reset here too.
        let preV3Columns = try db.query("PRAGMA table_info(speakers);")
            .compactMap { $0.string(1) }
        if preV3Columns.contains("pyannote_model_revision") {
            let archiveURL = db.url.deletingLastPathComponent()
                .appendingPathComponent("speakers.sqlite.pre-v3.bak")
            try? FileManager.default.removeItem(at: archiveURL)
            let escapedPath = archiveURL.path
                .replacingOccurrences(of: "'", with: "''")
            try db.exec("VACUUM INTO '\(escapedPath)';")
            try db.exec("""
                DROP TABLE IF EXISTS appearances;
                DROP TABLE IF EXISTS speakers;
                """)
        }

        // Schema creation runs inside one transaction so it is atomic — a
        // crash mid-`migrate` leaves the database fully unmigrated rather
        // than half-built (S1).
        try db.transaction {
            // `model_revision` is per-row so a model upgrade (Open Q #3 / PT-P5-D3)
            // can coexist with old centroids without cross-matching them.
            try db.exec("""
                CREATE TABLE IF NOT EXISTS speakers (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    centroid BLOB NOT NULL,
                    model_revision TEXT NOT NULL,
                    appearance_count INTEGER NOT NULL DEFAULT 0,
                    last_seen TEXT NOT NULL,
                    sample_audio_path TEXT,
                    created_at TEXT NOT NULL,
                    deleted_at TEXT,
                    delisted_at TEXT
                );
                -- One row per (speaker, recording). `origin_speaker_id`
                -- records the speaker that owned the appearance before the
                -- most recent merge/split re-attributed it (NULL when never
                -- moved), so `unmerge`/`unsplit` can restore ownership
                -- exactly. The `speaker_id` FK is `ON DELETE RESTRICT` (S2):
                -- all deletes in this library are soft (a `deleted_at`
                -- stamp), so a speaker row is never physically removed while
                -- it has appearances — RESTRICT makes that intent explicit
                -- and behaviour is unchanged.
                CREATE TABLE IF NOT EXISTS appearances (
                    speaker_id TEXT NOT NULL
                        REFERENCES speakers(id) ON DELETE RESTRICT,
                    recording_id TEXT NOT NULL,
                    recording_folder_name TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    origin_speaker_id TEXT,
                    PRIMARY KEY (speaker_id, recording_id)
                );
                CREATE INDEX IF NOT EXISTS idx_appearances_speaker
                    ON appearances(speaker_id);
                CREATE INDEX IF NOT EXISTS idx_speakers_live
                    ON speakers(deleted_at);
                CREATE INDEX IF NOT EXISTS idx_speakers_delisted_at
                    ON speakers(delisted_at);
                """)
        }
        // Record the applied schema version (S3) so a future schema migration
        // knows what is in place. `user_version` is a connection-level pragma, not
        // transactional, so it is set after the DDL transaction commits.
        if db.userVersion < schemaVersion {
            try db.setUserVersion(schemaVersion)
        }
    }

    // MARK: - Read

    /// Every live (non-deleted, non-delisted) speaker, ordered by creation
    /// time.
    ///
    /// A delisted speaker ("Don't recognize this speaker") is excluded just
    /// like a soft-deleted one — they no longer participate in `bestMatch`,
    /// which iterates `liveSpeakers()` (the matcher hot path), and they no
    /// longer appear in the editor's main list.
    ///
    /// Served from the in-memory cache when warm; the cache is rebuilt from
    /// SQLite on the first call after any mutation.
    public func liveSpeakers() throws -> [Speaker] {
        if let cached = cachedLiveSpeakers { return cached }
        let speakers = try selectSpeakers(
            "WHERE deleted_at IS NULL AND delisted_at IS NULL "
                + "ORDER BY created_at, id")
        cachedLiveSpeakers = speakers
        return speakers
    }

    /// Drop the live-speaker cache — called after any mutation.
    private func invalidateCache() { cachedLiveSpeakers = nil }

    /// Drop the in-memory live-speaker cache so the next `liveSpeakers()`
    /// re-reads SQLite. The cache is invalidated only by mutations on *this*
    /// actor instance, so an editor that holds its own `SpeakerLibrary` cannot
    /// see speakers another instance created (e.g. an `Unknown #N` minted by
    /// the refine pipeline) until it forces a re-read. The editor calls this
    /// before a window-open reload so its list always reflects on-disk truth.
    public func refreshFromDisk() { invalidateCache() }

    /// Every soft-deleted speaker still inside the 30-day recovery window
    /// (PT-R32b "Recently deleted").
    public func recoverableSpeakers() throws -> [Speaker] {
        let cutoff = Timestamps.event(clock().addingTimeInterval(-Self.recoveryWindow))
        return try selectSpeakers(
            "WHERE deleted_at IS NOT NULL AND deleted_at >= ? "
                + "ORDER BY deleted_at DESC, id",
            [.text(cutoff)])
    }

    /// Every soft-deleted speaker — including those past the 30-day recovery
    /// window. Unlike `recoverableSpeakers` this applies no date cutoff: it
    /// exists so `Unknown #N` numbering can scan the full all-time history
    /// and so a number is never reused even after a speaker ages out (SW2).
    public func allDeletedSpeakers() throws -> [Speaker] {
        try selectSpeakers(
            "WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id")
    }

    /// Every delisted speaker still inside the 30-day recovery window —
    /// the "Recently delisted" list mirroring `recoverableSpeakers`.
    public func recoverableDelistedSpeakers() throws -> [Speaker] {
        let cutoff = Timestamps.event(clock().addingTimeInterval(-Self.recoveryWindow))
        return try selectSpeakers(
            "WHERE delisted_at IS NOT NULL AND deleted_at IS NULL "
                + "AND delisted_at >= ? "
                + "ORDER BY delisted_at DESC, id",
            [.text(cutoff)])
    }

    /// Every delisted speaker — including those past the 30-day window.
    /// Lets `Unknown #N` numbering treat a delisted speaker as a still-claimed
    /// number so the same noise cluster does not silently reuse it on a
    /// future refine (mirrors SW2 for `allDeletedSpeakers`).
    public func allDelistedSpeakers() throws -> [Speaker] {
        try selectSpeakers(
            "WHERE delisted_at IS NOT NULL ORDER BY delisted_at DESC, id")
    }

    /// Look up one speaker by id (live or deleted), or `nil`.
    public func speaker(id: String) throws -> Speaker? {
        try selectSpeakers("WHERE id = ?", [.text(id)]).first
    }

    /// Appearances of one speaker, newest first.
    public func appearances(of speakerId: String) throws -> [SpeakerAppearance] {
        let rows = try database.query(
            "SELECT speaker_id, recording_id, recording_folder_name, observed_at "
                + "FROM appearances WHERE speaker_id = ? ORDER BY observed_at DESC",
            [.text(speakerId)])
        return rows.map {
            SpeakerAppearance(
                speakerId: $0.string(0) ?? "",
                recordingId: $0.string(1) ?? "",
                recordingFolderName: $0.string(2) ?? "",
                observedAt: $0.string(3) ?? "")
        }
    }

    // MARK: - Matching (PT-R22)

    /// Find the best live-speaker match for a query centroid.
    ///
    /// Cosine similarity in memory over every live speaker — fast even at
    /// ~10k speakers (256-d dot product × N). A centroid from a *different*
    /// `model_revision` is not comparable and is skipped entirely
    /// (Open Question #3 / PT-P5-D3): a returning speaker recorded under a new model
    /// checkpoint becomes a fresh `Unknown #N` rather than a false match.
    ///
    /// - Returns: the best match at or above `threshold`, else `nil`.
    public func bestMatch(
        for centroid: [Float],
        modelRevision: String,
        threshold: Double = SpeakerLibrary.defaultMatchThreshold
    ) throws -> SpeakerMatch? {
        var best: SpeakerMatch?
        for speaker in try liveSpeakers() {
            guard speaker.modelRevision == modelRevision else { continue }
            let similarity = Centroid.cosineSimilarity(speaker.centroid, centroid)
            if similarity >= threshold,
               similarity > (best?.similarity ?? -1) {
                best = SpeakerMatch(speaker: speaker, similarity: similarity)
            }
        }
        return best
    }

    // MARK: - Create (PT-R22 — new speaker → speaker_created)

    /// Insert a brand-new speaker discovered by refinement and record its
    /// first appearance. Emits `speaker_created`.
    ///
    /// - Returns: the newly created `Speaker`.
    @discardableResult
    public func createSpeaker(
        name: String,
        centroid: [Float],
        modelRevision: String,
        recordingId: String,
        recordingFolderName: String,
        sampleAudioPath: String? = nil
    ) async throws -> Speaker {
        let backupEvent = backupBeforeWrite()
        let now = clock()
        let nowStamp = Timestamps.event(now)
        let id = "spk_\(ulidFactory(now).value)"
        let speaker = Speaker(
            id: id, name: name, centroid: centroid,
            modelRevision: modelRevision,
            appearanceCount: 1, lastSeen: nowStamp,
            sampleAudioPath: sampleAudioPath,
            createdAt: nowStamp, deletedAt: nil)
        do {
            try database.transaction {
                try insert(speaker)
                try insertAppearance(SpeakerAppearance(
                    speakerId: id, recordingId: recordingId,
                    recordingFolderName: recordingFolderName,
                    observedAt: nowStamp))
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        _ = try? await events?.append(SpeakerCreatedEvent(
            speakerId: id, initialName: name, sourceRecordingId: recordingId))
        return speaker
    }

    // MARK: - Centroid update (PT-R30 — returning speaker → speaker_centroid_updated)

    /// Fold a returning speaker's new appearance into its centroid via the
    /// count-weighted running mean (PT-R30) and record the appearance. Emits
    /// `speaker_centroid_updated`.
    ///
    /// - Returns: the updated `Speaker`.
    @discardableResult
    public func recordAppearance(
        speakerId: String,
        centroid: [Float],
        modelRevision: String,
        recordingId: String,
        recordingFolderName: String
    ) async throws -> Speaker {
        guard var speaker = try speaker(id: speakerId), !speaker.isDeleted else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        // Open Question #3: refuse to average a cross-revision embedding into a
        // centroid — the vectors are not comparable.
        guard speaker.modelRevision == modelRevision else {
            throw LibraryError.modelRevisionMismatch(
                stored: speaker.modelRevision, incoming: modelRevision)
        }
        // Idempotency on a re-refine of the same recording (SW1): if this
        // recording's appearance is already recorded for this speaker, the
        // appearance has already been folded into the centroid and counted.
        // Re-running must not inflate `appearance_count` or drift the centroid
        // a second time — only the `appearances` row (timestamps/folder name)
        // is refreshed.
        let alreadyRecorded = try appearanceExists(
            speakerId: speakerId, recordingId: recordingId)
        let backupEvent = backupBeforeWrite()
        let nowStamp = Timestamps.event(clock())
        if !alreadyRecorded {
            speaker.centroid = Centroid.runningMean(
                existing: speaker.centroid,
                appearanceCount: speaker.appearanceCount,
                appearance: centroid)
            speaker.appearanceCount += 1
        }
        speaker.lastSeen = nowStamp
        do {
            try database.transaction {
                try updateCentroidRow(speaker)
                // An appearance may already exist on a re-refine of the same
                // recording — INSERT OR REPLACE keeps the row idempotent; the
                // count/centroid update above is skipped when it already
                // existed so the re-refine is a true no-op for library state.
                try insertAppearance(SpeakerAppearance(
                    speakerId: speakerId, recordingId: recordingId,
                    recordingFolderName: recordingFolderName,
                    observedAt: nowStamp), orReplace: true)
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        _ = try? await events?.append(SpeakerCentroidUpdatedEvent(
            speakerId: speakerId, recordingId: recordingId,
            appearanceCount: speaker.appearanceCount))
        return speaker
    }

    // MARK: - Rename (PT-R83 — speaker_renamed)

    /// Change a speaker's display name. The `id` is unchanged (PT-R83). This
    /// method does NOT retroactively rewrite past `final.md` files (PT-P1-D16 — the
    /// rewrite is a separate step), so `applied_to_recordings` is empty and no
    /// `final_md_rewritten` is paired with this event.
    ///
    /// - Parameter suppressEvent: when `true`, the DB write + backup are done
    ///   but `speaker_renamed` is NOT emitted. A caller that drives the
    ///   retroactive rewrite uses this so it can emit the event AFTER the
    ///   `final.md` rewrite, with a populated `applied_to_recordings`, in
    ///   causal order. The returned old name is what the caller needs to drive
    ///   the rewrite. Default `false` keeps the plain rename behaviour
    ///   unchanged.
    /// - Returns: the speaker's name *before* the rename.
    @discardableResult
    public func rename(
        speakerId: String,
        to newName: String,
        suppressEvent: Bool = false
    ) async throws -> String {
        guard let speaker = try speaker(id: speakerId) else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        let backupEvent = backupBeforeWrite()
        do {
            try database.run(
                "UPDATE speakers SET name = ? WHERE id = ?",
                [.text(newName), .text(speakerId)])
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        if !suppressEvent {
            _ = try? await events?.append(SpeakerRenamedEvent(
                speakerId: speakerId, oldName: speaker.name, newName: newName,
                appliedToRecordings: []))
        }
        return speaker.name
    }

    // MARK: - Delete + undo (PT-R32b)

    /// Soft-delete a speaker (PT-R32b). The row is hidden but recoverable for 30
    /// days. Emits `speaker_deleted`.
    public func delete(speakerId: String) async throws {
        guard let speaker = try speaker(id: speakerId), !speaker.isDeleted else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        let backupEvent = backupBeforeWrite()
        let now = clock()
        let deletedAt = Timestamps.event(now)
        do {
            try database.run(
                "UPDATE speakers SET deleted_at = ? WHERE id = ?",
                [.text(deletedAt), .text(speakerId)])
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        let recoverableUntil = Timestamps.event(
            now.addingTimeInterval(Self.recoveryWindow))
        _ = try? await events?.append(SpeakerDeletedEvent(
            speakerId: speakerId, softDelete: true,
            recoverableUntil: recoverableUntil))
    }

    /// Undo a soft-delete within the recovery window. Emits `speaker_undeleted`.
    public func undelete(speakerId: String) async throws {
        guard let speaker = try speaker(id: speakerId) else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        guard speaker.isDeleted else {
            throw LibraryError.speakerNotDeleted(speakerId)
        }
        let backupEvent = backupBeforeWrite()
        do {
            try database.run(
                "UPDATE speakers SET deleted_at = NULL WHERE id = ?",
                [.text(speakerId)])
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        _ = try? await events?.append(SpeakerUndeletedEvent(speakerId: speakerId))
    }

    // MARK: - Delist + undo ("Don't recognize this speaker")

    /// Delist a speaker — soft-stamp `delisted_at` so they are excluded from
    /// the live list and from `bestMatch`, and so the menubar's "Recently
    /// delisted" section can offer a 30-day undo (parallel to `delete`).
    ///
    /// A delisted speaker does NOT block `unrecognize` re-clustering: if the
    /// same noise re-clusters as a new Unknown on a future refine, the user
    /// re-delists. That decision is locked.
    ///
    /// - Parameter suppressEvent: when `true`, the DB mutation + backup are
    ///   done but `speaker_delisted` is NOT emitted — a caller that drives the
    ///   retroactive rewrite emits it after the `final.md` rewrite with a
    ///   populated `applied_to_recordings`, in causal order. Default `false`
    ///   keeps the plain delist behaviour (no rewrite, no
    ///   `applied_to_recordings`). The returned name is what the caller needs
    ///   to drive the rewrite and the undo toast.
    /// - Returns: the speaker's display name.
    @discardableResult
    public func delist(
        speakerId: String,
        suppressEvent: Bool = false
    ) async throws -> String {
        guard let speaker = try speaker(id: speakerId) else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        let backupEvent = backupBeforeWrite()
        let now = clock()
        let delistedAt = Timestamps.event(now)
        do {
            try database.run(
                "UPDATE speakers SET delisted_at = ? WHERE id = ?",
                [.text(delistedAt), .text(speakerId)])
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        if !suppressEvent {
            let recoverableUntil = Timestamps.event(
                now.addingTimeInterval(Self.recoveryWindow))
            _ = try? await events?.append(SpeakerDelistedEvent(
                speakerId: speakerId,
                recoverableUntil: recoverableUntil,
                appliedToRecordings: []))
        }
        return speaker.name
    }

    /// Undo a delist within the recovery window — clear `delisted_at` so the
    /// speaker is once again live and visible to `bestMatch`.
    ///
    /// - Parameter suppressEvent: when `true`, the DB mutation + backup are
    ///   done but `speaker_undelisted` is NOT emitted — the editor drives a
    ///   retroactive rewrite that restores `Unrecognized` → the speaker's
    ///   name, then emits `speaker_undelisted` with a populated
    ///   `applied_to_recordings` in causal order.
    /// - Returns: the speaker's display name.
    @discardableResult
    public func undelist(
        speakerId: String,
        suppressEvent: Bool = false
    ) async throws -> String {
        guard let speaker = try speaker(id: speakerId) else {
            throw LibraryError.speakerNotFound(speakerId)
        }
        guard speaker.isDelisted else {
            throw LibraryError.speakerNotDelisted(speakerId)
        }
        let backupEvent = backupBeforeWrite()
        do {
            try database.run(
                "UPDATE speakers SET delisted_at = NULL WHERE id = ?",
                [.text(speakerId)])
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        if !suppressEvent {
            _ = try? await events?.append(SpeakerUndelistedEvent(
                speakerId: speakerId, appliedToRecordings: []))
        }
        return speaker.name
    }

    // MARK: - Merge + undo (PT-R32b — speaker_merged / speaker_unmerged)

    /// Merge `other` into `primary`: `other` is soft-deleted, its appearances
    /// are re-attributed to `primary`, and `primary`'s centroid is recomputed
    /// as the count-weighted mean of the two (PT-R30). Emits `speaker_merged`.
    ///
    /// A false merge of two genuinely-distinct speakers is recoverable via
    /// `unmerge` (edge case "two distinct speakers within threshold").
    ///
    /// - Parameter suppressEvent: when `true`, the DB mutation + backup are
    ///   done but `speaker_merged` is NOT emitted — a caller that drives the
    ///   retroactive rewrite emits it after the `final.md` rewrite with a
    ///   populated `applied_to_recordings`. Default `false` keeps the plain
    ///   merge behaviour.
    /// - Returns: `(primaryName, otherName)` — the display names before the
    ///   merge, so the caller can rewrite `otherName` to `primaryName`
    ///   across the merged speaker's past `final.md` files.
    @discardableResult
    public func merge(
        primaryId: String,
        otherId: String,
        suppressEvent: Bool = false
    ) async throws -> (primaryName: String, otherName: String) {
        guard primaryId != otherId else {
            throw LibraryError.notMergeable("a speaker cannot be merged into itself")
        }
        guard let primary = try speaker(id: primaryId), !primary.isDeleted else {
            throw LibraryError.speakerNotFound(primaryId)
        }
        guard let other = try speaker(id: otherId), !other.isDeleted else {
            throw LibraryError.speakerNotFound(otherId)
        }
        guard primary.modelRevision == other.modelRevision else {
            throw LibraryError.notMergeable(
                "speakers have different model revisions")
        }
        // Equal model revision does not guarantee equal centroid dimensions;
        // guard explicitly so the weighted-sum loop can never read out of
        // bounds (matches `Centroid.runningMean`'s defensive style).
        guard primary.centroid.count == other.centroid.count else {
            throw LibraryError.notMergeable("centroid dimension mismatch")
        }
        let backupEvent = backupBeforeWrite()
        let deletedAt = Timestamps.event(clock())

        var merged = primary
        // Count-weighted mean of the two centroids — equivalent to averaging
        // every underlying appearance embedding (PT-R30).
        let totalCount = primary.appearanceCount + other.appearanceCount
        if totalCount > 0 {
            var weighted = [Float](repeating: 0, count: primary.centroid.count)
            for i in 0..<weighted.count {
                let p = Double(primary.centroid[i]) * Double(primary.appearanceCount)
                let o = Double(other.centroid[i]) * Double(other.appearanceCount)
                weighted[i] = Float((p + o) / Double(totalCount))
            }
            merged.centroid = weighted
        }
        merged.appearanceCount = totalCount

        do {
            try database.transaction {
                try updateCentroidRow(merged)
                // Re-attribute `other`'s appearances to `primary`, stamping
                // `origin_speaker_id` so `unmerge` restores them exactly.
                // `OR IGNORE` drops a row for a recording both speakers
                // already appear in (the primary row wins); that collision is
                // rare and the documented behaviour.
                try database.run(
                    "UPDATE OR IGNORE appearances "
                        + "SET speaker_id = ?, origin_speaker_id = ? "
                        + "WHERE speaker_id = ?",
                    [.text(primaryId), .text(otherId), .text(otherId)])
                try database.run(
                    "UPDATE speakers SET deleted_at = ? WHERE id = ?",
                    [.text(deletedAt), .text(otherId)])
                try recomputeAppearanceCount(primaryId)
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        if !suppressEvent {
            _ = try? await events?.append(SpeakerMergedEvent(
                primarySpeakerId: primaryId, mergedSpeakerId: otherId,
                appliedToRecordings: []))
        }
        return (primaryName: primary.name, otherName: other.name)
    }

    /// Undo a merge: restore `other` and move the appearances the merge
    /// re-attributed (those stamped `origin_speaker_id = other`) back to it.
    /// Emits `speaker_unmerged`.
    ///
    /// `other`'s stored centroid still holds its pre-merge value (the merge
    /// only recomputed `primary`'s), so the restore is exact for `other`.
    /// `primary`'s pre-merge centroid is reconstructed arithmetically by
    /// inverting the merge's count-weighted mean (S4 — see
    /// `Centroid.unmergePrimaryCentroid`): the merge computed
    /// `merged = (primaryOld·np + other·no)/(np+no)`, `other`'s centroid and
    /// pre-merge count `no` are preserved on the soft-deleted loser, and `np`
    /// is `primary.appearanceCount - no`. When the inversion cannot be exact
    /// (`np <= 0` or a dimension mismatch) `primary`'s centroid is left at the
    /// merged value — the documented best-effort fallback (PT-P1-D18).
    public func unmerge(primaryId: String, otherId: String) async throws {
        guard let primary = try speaker(id: primaryId), !primary.isDeleted else {
            throw LibraryError.speakerNotFound(primaryId)
        }
        guard let other = try speaker(id: otherId), other.isDeleted else {
            throw LibraryError.speakerNotDeleted(otherId)
        }
        let backupEvent = backupBeforeWrite()
        // `no` = the number of appearances the merge re-attributed from
        // `other` (stamped `origin_speaker_id = other`); `np` = primary's
        // pre-merge count = current total minus `no`.
        let movedCount = try appearancesMovedFrom(otherId, into: primaryId)
        let primaryPreMergeCount = primary.appearanceCount - movedCount
        let restoredPrimaryCentroid = Centroid.unmergePrimaryCentroid(
            merged: primary.centroid,
            other: other.centroid,
            primaryCount: primaryPreMergeCount,
            otherCount: movedCount)
        do {
            try database.transaction {
                try database.run(
                    "UPDATE speakers SET deleted_at = NULL WHERE id = ?",
                    [.text(otherId)])
                // Restore exactly the appearances the merge moved.
                try database.run(
                    "UPDATE OR IGNORE appearances "
                        + "SET speaker_id = ?, origin_speaker_id = NULL "
                        + "WHERE speaker_id = ? AND origin_speaker_id = ?",
                    [.text(otherId), .text(primaryId), .text(otherId)])
                try recomputeAppearanceCount(primaryId)
                try recomputeAppearanceCount(otherId)
                // Restore primary's pre-merge centroid when the arithmetic
                // inversion is exact; otherwise leave the merged value.
                if let restored = restoredPrimaryCentroid {
                    try database.run(
                        "UPDATE speakers SET centroid = ? WHERE id = ?",
                        [.blob(Centroid.encodeBlob(restored)), .text(primaryId)])
                }
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        _ = try? await events?.append(SpeakerUnmergedEvent(
            primarySpeakerId: primaryId, mergedSpeakerId: otherId))
    }

    // MARK: - Split + undo (PT-R32b — speaker_split / speaker_unsplit)

    /// Split a subset of `originalId`'s appearances off into a brand-new
    /// speaker. Emits `speaker_split` followed by `speaker_created` for the new
    /// speaker.
    ///
    /// The CLI surface for split is a separate, later concern; this library
    /// operation exists and is tested directly.
    ///
    /// - Parameter suppressEvent: when `true`, the `speaker_split` event is NOT
    ///   emitted — a caller that drives the retroactive rewrite emits it after
    ///   the `final.md` rewrite with a populated `applied_to_recordings`. The
    ///   `speaker_created` for the new speaker is still emitted: it records a
    ///   genuine new library row, not the retroactive rewrite. Default `false`
    ///   keeps the plain split behaviour. The original speaker's name (needed
    ///   to drive the rewrite of moved recordings to `newName`) is
    ///   `speaker(id: originalId)?.name`.
    /// - Returns: the new `Speaker`.
    @discardableResult
    public func split(
        originalId: String,
        movingRecordingIds: [String],
        newName: String,
        suppressEvent: Bool = false
    ) async throws -> Speaker {
        guard let original = try speaker(id: originalId), !original.isDeleted else {
            throw LibraryError.speakerNotFound(originalId)
        }
        // An empty move set would create a 0-appearance speaker that still
        // carries the original's centroid and so spuriously matches future
        // recordings (SW5). A split must peel off at least one recording.
        guard !movingRecordingIds.isEmpty else {
            throw LibraryError.notMergeable(
                "split requires at least one recording")
        }
        let backupEvent = backupBeforeWrite()
        let now = clock()
        let nowStamp = Timestamps.event(now)
        let newId = "spk_\(ulidFactory(now).value)"
        // The new speaker starts as a copy of the original's centroid — the
        // split has no separate embedding to seed from; a subsequent
        // appearance refines it via the running mean.
        let newSpeaker = Speaker(
            id: newId, name: newName, centroid: original.centroid,
            modelRevision: original.modelRevision,
            appearanceCount: 0, lastSeen: nowStamp,
            sampleAudioPath: nil, createdAt: nowStamp, deletedAt: nil)
        do {
            try database.transaction {
                try insert(newSpeaker)
                for recordingId in movingRecordingIds {
                    try database.run(
                        "UPDATE appearances "
                            + "SET speaker_id = ?, origin_speaker_id = ? "
                            + "WHERE speaker_id = ? AND recording_id = ?",
                        [.text(newId), .text(originalId),
                         .text(originalId), .text(recordingId)])
                }
                try recomputeAppearanceCount(originalId)
                try recomputeAppearanceCount(newId)
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        // Causal order: the split happened, then a new speaker exists.
        if !suppressEvent {
            _ = try? await events?.append(SpeakerSplitEvent(
                originalSpeakerId: originalId, newSpeakerId: newId,
                appliedToRecordings: []))
        }
        _ = try? await events?.append(SpeakerCreatedEvent(
            speakerId: newId, initialName: newName,
            sourceRecordingId: movingRecordingIds.first ?? ""))
        return try speaker(id: newId) ?? newSpeaker
    }

    /// Undo a split: move the new speaker's appearances back to the original
    /// and soft-delete the new speaker. Emits `speaker_unsplit`.
    public func unsplit(originalId: String, newId: String) async throws {
        guard let _ = try speaker(id: originalId) else {
            throw LibraryError.speakerNotFound(originalId)
        }
        guard let new = try speaker(id: newId), !new.isDeleted else {
            throw LibraryError.speakerNotFound(newId)
        }
        let backupEvent = backupBeforeWrite()
        let deletedAt = Timestamps.event(clock())
        do {
            try database.transaction {
                try database.run(
                    "UPDATE OR IGNORE appearances "
                        + "SET speaker_id = ?, origin_speaker_id = NULL "
                        + "WHERE speaker_id = ?",
                    [.text(originalId), .text(newId)])
                try database.run(
                    "UPDATE speakers SET deleted_at = ? WHERE id = ?",
                    [.text(deletedAt), .text(newId)])
                try recomputeAppearanceCount(originalId)
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
        _ = try? await events?.append(SpeakerUnsplitEvent(
            originalSpeakerId: originalId, newSpeakerId: newId))
    }

    // MARK: - Test support

    /// Bulk-insert speakers in a single transaction with one backup — for the
    /// large-library performance test only. Production always goes through
    /// `createSpeaker` (one backup per write); a 1000-write loop there is an
    /// O(n) sequence of durable commits that is purely a test artifact, so the
    /// "matching stays fast at scale" test seeds through this fast path and
    /// then exercises `bestMatch` (the real hot path) normally.
    func bulkInsertForTesting(_ speakers: [Speaker]) async throws {
        let backupEvent = backupBeforeWrite()
        do {
            try database.transaction {
                for speaker in speakers { try insert(speaker) }
            }
        } catch {
            throw LibraryError.database(error)
        }
        await emitBackupEvent(backupEvent)
    }

    // MARK: - SQL helpers

    private func selectSpeakers(
        _ clause: String, _ bindings: [SQLiteDatabase.Value] = []
    ) throws -> [Speaker] {
        let rows: [SQLiteDatabase.Row]
        do {
            rows = try database.query(
                "SELECT id, name, centroid, model_revision, "
                    + "appearance_count, last_seen, sample_audio_path, "
                    + "created_at, deleted_at, delisted_at FROM speakers "
                    + clause,
                bindings)
        } catch {
            throw LibraryError.database(error)
        }
        return rows.compactMap { row -> Speaker? in
            guard let id = row.string(0), let name = row.string(1),
                  let blob = row.blob(2),
                  let centroid = Centroid.decodeBlob(blob),
                  let revision = row.string(3),
                  let count = row.int(4), let lastSeen = row.string(5),
                  let createdAt = row.string(7) else { return nil }
            return Speaker(
                id: id, name: name, centroid: centroid,
                modelRevision: revision,
                appearanceCount: Int(count), lastSeen: lastSeen,
                sampleAudioPath: row.string(6),
                createdAt: createdAt,
                deletedAt: row.isNull(8) ? nil : row.string(8),
                delistedAt: row.isNull(9) ? nil : row.string(9))
        }
    }

    private func insert(_ speaker: Speaker) throws {
        try database.run(
            "INSERT INTO speakers (id, name, centroid, model_revision, "
                + "appearance_count, last_seen, sample_audio_path, created_at, "
                + "deleted_at, delisted_at) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(speaker.id), .text(speaker.name),
                .blob(Centroid.encodeBlob(speaker.centroid)),
                .text(speaker.modelRevision),
                .int(Int64(speaker.appearanceCount)),
                .text(speaker.lastSeen),
                speaker.sampleAudioPath.map { .text($0) } ?? .null,
                .text(speaker.createdAt),
                speaker.deletedAt.map { .text($0) } ?? .null,
                speaker.delistedAt.map { .text($0) } ?? .null,
            ])
    }

    private func updateCentroidRow(_ speaker: Speaker) throws {
        try database.run(
            "UPDATE speakers SET centroid = ?, appearance_count = ?, "
                + "last_seen = ? WHERE id = ?",
            [
                .blob(Centroid.encodeBlob(speaker.centroid)),
                .int(Int64(speaker.appearanceCount)),
                .text(speaker.lastSeen),
                .text(speaker.id),
            ])
    }

    private func insertAppearance(
        _ appearance: SpeakerAppearance, orReplace: Bool = false
    ) throws {
        let verb = orReplace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        try database.run(
            "\(verb) INTO appearances (speaker_id, recording_id, "
                + "recording_folder_name, observed_at, origin_speaker_id) "
                + "VALUES (?, ?, ?, ?, NULL)",
            [
                .text(appearance.speakerId), .text(appearance.recordingId),
                .text(appearance.recordingFolderName),
                .text(appearance.observedAt),
            ])
    }

    /// Count the appearances a merge re-attributed from `originId` into
    /// `currentSpeakerId` — i.e. rows now owned by `currentSpeakerId` and
    /// stamped `origin_speaker_id = originId`. This is `other`'s pre-merge
    /// appearance count, needed to invert the merge's centroid arithmetic (S4).
    private func appearancesMovedFrom(
        _ originId: String, into currentSpeakerId: String
    ) throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) FROM appearances "
                + "WHERE speaker_id = ? AND origin_speaker_id = ?",
            [.text(currentSpeakerId), .text(originId)])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Whether an appearance row for `(speakerId, recordingId)` already
    /// exists — used to keep `recordAppearance` idempotent on a re-refine of
    /// the same recording (SW1).
    private func appearanceExists(
        speakerId: String, recordingId: String
    ) throws -> Bool {
        let rows = try database.query(
            "SELECT 1 FROM appearances "
                + "WHERE speaker_id = ? AND recording_id = ? LIMIT 1",
            [.text(speakerId), .text(recordingId)])
        return !rows.isEmpty
    }

    /// Reset a speaker's `appearance_count` to its true number of appearance
    /// rows — keeps the count honest after a merge/split/unmerge re-attribution.
    private func recomputeAppearanceCount(_ speakerId: String) throws {
        try database.run(
            "UPDATE speakers SET appearance_count = "
                + "(SELECT COUNT(*) FROM appearances WHERE speaker_id = ?) "
                + "WHERE id = ?",
            [.text(speakerId), .text(speakerId)])
    }
}
