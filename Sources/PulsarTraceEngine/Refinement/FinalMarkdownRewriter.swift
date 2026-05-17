import Foundation
import Logging

/// Retroactively rewrites past `final.md` files after a speaker rename / merge
/// / split (Epic 8 — project-docs/DECISIONS.md D16).
///
/// Epic 5 made a `pulsartrace speakers rename` update the speaker library only;
/// D16 deferred the *retroactive* rewrite of already-refined `final.md` files
/// to Epic 8. This type is that rewrite: given a speaker's appearances (from
/// `SpeakerLibrary.appearances(of:)`) it locates each recording folder on disk,
/// rewrites the speaker label in every utterance line of its `final.md`, backs
/// up the prior file, updates the `metadata.json` speakers array, and emits one
/// `final_md_rewritten` event per rewritten recording.
///
/// What it deliberately does NOT touch:
/// - `live.md` — strictly append-only, never rewritten (Hard Invariant #4).
/// - Transcript prose — only the speaker *label* field of an utterance line is
///   rewritten; a name that happens to appear in spoken text is left alone.
/// - Non-utterance lines (the marker, header, blank lines) — preserved
///   byte-for-byte.
///
/// The menubar editor (later in Epic 8) drives this: it performs the library
/// mutation with `suppressEvent: true`, calls `rewrite`, then emits the
/// `speaker_*` event with a populated `applied_to_recordings` in causal order
/// followed by one `final_md_rewritten` per `RecordingResult`.
///
/// This type **never emits events itself** — it only returns `RecordingResult`s
/// (one per genuinely-changed recording); every caller emits
/// `final_md_rewritten` so there is exactly one emission site (no double-emit).
public struct FinalMarkdownRewriter: Sendable {

    /// Why a `final.md` is being rewritten — the `reason` raw value goes into
    /// the `final_md_rewritten` event.
    public enum RewriteReason: String, Sendable {
        case speakerRenamed = "speaker_renamed"
        case speakerMerged  = "speaker_merged"
        case speakerSplit   = "speaker_split"
        /// Undo of a merge — the merged-away name is restored over the
        /// affected recordings, paired with a `speaker_unmerged` cause.
        case speakerUnmerged = "speaker_unmerged"
        /// Undo of a split — the split-off name is folded back to the
        /// original, paired with a `speaker_unsplit` cause.
        case speakerUnsplit  = "speaker_unsplit"
    }

    /// One recording whose `final.md` was rewritten.
    public struct RecordingResult: Sendable {
        /// The recording id (`rec_<short>`).
        public let recordingId: String
        /// The recording folder the rewrite was applied in.
        public let folderURL: URL
        /// Lowercase-hex SHA-256 of the new `final.md` bytes.
        public let newSHA256: String

        public init(recordingId: String, folderURL: URL, newSHA256: String) {
            self.recordingId = recordingId
            self.folderURL = folderURL
            self.newSHA256 = newSHA256
        }
    }

    private let logger: Logger

    public init(logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.logger = logger
    }

    /// Rewrite every appearance's `final.md`, replacing `oldName` with `newName`.
    ///
    /// - Parameters:
    ///   - oldName: the speaker label to replace.
    ///   - newName: the new speaker label.
    ///   - appearances: the speaker's appearances, from
    ///     `SpeakerLibrary.appearances(of:)`. Each carries the recording folder
    ///     basename used to locate the folder on disk.
    ///   - outputFolderRoots: directories to scan for a subdirectory whose
    ///     `lastPathComponent` matches an appearance's folder name.
    ///   - reason: why the rewrite is happening — the caller copies it into the
    ///     `final_md_rewritten` event it emits per `RecordingResult`.
    /// - Returns: one `RecordingResult` per recording whose `final.md` was
    ///   **genuinely changed**, in the order the appearances were processed.
    ///   Folders not found on disk, folders with no `final.md`, and folders
    ///   whose rewritten `final.md` is byte-identical to the original are all
    ///   skipped and absent from the result — so a caller's
    ///   `applied_to_recordings` lists only the recordings the edit actually
    ///   altered (and no spurious `.bak` files are created).
    @discardableResult
    public func rewrite(
        oldName: String,
        newName: String,
        appearances: [SpeakerAppearance],
        outputFolderRoots: [URL],
        reason: RewriteReason
    ) async throws -> [RecordingResult] {
        var results: [RecordingResult] = []

        for appearance in appearances {
            guard let folder = locateFolder(
                named: appearance.recordingFolderName, in: outputFolderRoots)
            else {
                // Folder not on disk (recording moved/deleted) — skip silently.
                logger.notice(
                    "final.md rewrite: recording folder not found, skipping")
                continue
            }

            let finalURL = folder.appendingPathComponent(
                RecordingFolder.FileName.final)
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                // No final.md (never refined, or only live.md exists) — skip.
                // live.md is NEVER touched (Hard Invariant #4).
                logger.notice("final.md rewrite: no final.md in folder, skipping")
                continue
            }

            // A recording the rewrite leaves byte-identical (the merged-away
            // name never appeared there, a rename to the same string) is not
            // a genuine change — skip it: no `.bak`, no write, not a result.
            guard let sha = try rewriteFolder(
                folder: folder, finalURL: finalURL,
                oldName: oldName, newName: newName)
            else { continue }

            let result = RecordingResult(
                recordingId: appearance.recordingId,
                folderURL: folder, newSHA256: sha)
            results.append(result)
        }

        return results
    }

    // MARK: - Folder resolution

    /// Find the first subdirectory of any `root` whose `lastPathComponent`
    /// equals `name`. Returns `nil` when the folder is not on disk.
    private func locateFolder(named name: String, in roots: [URL]) -> URL? {
        let fm = FileManager.default
        for root in roots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    // MARK: - One folder

    /// Rewrite `final.md` (with a `.bak` backup) and `metadata.json` in one
    /// folder. Returns the new `final.md` SHA-256, or `nil` when the rewrite
    /// would leave the file byte-identical — in which case nothing is written
    /// and no `.bak` is created.
    private func rewriteFolder(
        folder: URL,
        finalURL: URL,
        oldName: String,
        newName: String
    ) throws -> String? {
        let fm = FileManager.default
        let original = try String(contentsOf: finalURL, encoding: .utf8)
        let rewritten = Self.rewriteMarkdown(
            original, oldName: oldName, newName: newName)

        // A no-op rewrite (the name never appeared in this recording, or a
        // rename to the same string) is not a genuine change: leave the file
        // and `.bak` untouched and report nothing back.
        guard rewritten != original else { return nil }

        // Back up the prior final.md (overwriting any stale .bak) before the
        // atomic write — mirrors RefinementPipeline's re-refine backup (R27).
        let backupURL = folder.appendingPathComponent(
            RecordingFolder.FileName.finalBackup)
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
        try fm.copyItem(at: finalURL, to: backupURL)

        // Atomic write-then-rename (R24) — a reader/editor sees old-or-new.
        let sha = try AtomicFile.write(rewritten, to: finalURL)

        // Best-effort metadata.json update — a separate atomic write (v1).
        rewriteMetadataIfPresent(
            in: folder, oldName: oldName, newName: newName)

        return sha
    }

    /// Rewrite the speaker label of every utterance line. A line is an
    /// utterance iff it starts with `**[`; everything else (marker, header,
    /// blank lines, prose) is passed through byte-for-byte.
    ///
    /// The label is the text between `] ` and the **closing** `:` of the
    /// `**[HH:MM:SS] <label>:**` prefix. A co-attributed label `A+B` is split
    /// on `+` and each matching component replaced — so `oldName` is changed
    /// only inside the label field, never in the transcript text after it.
    ///
    /// Splits at every `\n` **unicode scalar** — not the `\n` `Character`,
    /// because Swift folds `\r\n` into a single grapheme cluster, so a
    /// `Character`-level split would never see the `\n` inside a CRLF file and
    /// silently rewrite nothing. Each line body has its trailing `\r` (if any)
    /// peeled off before rewriting and restored afterwards, so the original
    /// `\n` / `\r\n` terminators round-trip byte-for-byte.
    static func rewriteMarkdown(
        _ markdown: String,
        oldName: String,
        newName: String
    ) -> String {
        // Slice into raw lines on the `\n` scalar, keeping each line's own
        // terminator (`\n`, `\r\n`, or none on a final unterminated line).
        var output = ""
        var lineStart = markdown.unicodeScalars.startIndex
        let scalars = markdown.unicodeScalars
        var index = scalars.startIndex

        func emit(body bodyRange: Range<String.UnicodeScalarView.Index>,
                  terminator: String) {
            var body = String(markdown.unicodeScalars[bodyRange])
            // A CRLF file leaves a trailing `\r` on the body — peel it, rewrite
            // the bare body, restore the `\r` so the terminator is exact.
            let trailingCR = body.hasSuffix("\r")
            if trailingCR { body = String(body.dropLast()) }
            output += Self.rewriteLine(body, oldName: oldName, newName: newName)
            if trailingCR { output += "\r" }
            output += terminator
        }

        while index < scalars.endIndex {
            if scalars[index] == "\n" {
                emit(body: lineStart..<index, terminator: "\n")
                index = scalars.index(after: index)
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }
        // The trailing segment after the last `\n` (empty when the file ends
        // with a newline).
        emit(body: lineStart..<scalars.endIndex, terminator: "")
        return output
    }

    /// Rewrite one line if it is an utterance line; otherwise return it
    /// unchanged. `line` is a single line body with NO terminator.
    private static func rewriteLine(
        _ line: String,
        oldName: String,
        newName: String
    ) -> String {
        guard line.hasPrefix("**[") else { return line }

        // The label sits between the first "] " and the closing ":" that
        // ends the prefix. The prefix is `**[HH:MM:SS] <label>:**`.
        guard let timeEnd = line.range(of: "] ") else { return line }
        let afterTime = timeEnd.upperBound
        // The label field ends at the ":" immediately before "**".
        guard let labelClose = line.range(
            of: ":**", range: afterTime..<line.endIndex)
        else { return line }

        // Trim any stray newline characters defensively — a `\r` carried into
        // the label would otherwise defeat the `oldName` comparison.
        let label = String(line[afterTime..<labelClose.lowerBound])
            .trimmingCharacters(in: .newlines)

        // Replace matching components, then collapse adjacent equal components
        // — a self-overlapping co-attributed label (`Unknown #1+Steve` with
        // `Unknown #1`→`Steve`) would otherwise become `Steve+Steve`.
        var newComponents: [String] = []
        for raw in label.split(separator: "+", omittingEmptySubsequences: false) {
            let component = raw == oldName[...] ? newName : String(raw)
            if component != newComponents.last {
                newComponents.append(component)
            }
        }
        let newLabel = newComponents.joined(separator: "+")

        guard newLabel != label else { return line }
        return String(line[line.startIndex..<afterTime])
            + newLabel
            + String(line[labelClose.lowerBound...])
    }

    // MARK: - metadata.json

    /// Update the `metadata.json` speakers array — any `label` equal to
    /// `oldName` becomes `newName` — and rewrite the file atomically. Absent or
    /// unreadable metadata is skipped (logged, non-fatal): the `final.md`
    /// rewrite is the load-bearing change.
    private func rewriteMetadataIfPresent(
        in folder: URL,
        oldName: String,
        newName: String
    ) {
        let metadataURL = folder.appendingPathComponent(
            RecordingFolder.FileName.metadata)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(
                RefinementMetadata.self, from: data)
            guard metadata.speakers.contains(where: { $0.label == oldName })
            else { return }

            let updatedSpeakers = metadata.speakers.map { speaker in
                speaker.label == oldName
                    ? RefinementMetadata.Speaker(
                        label: newName,
                        isMicrophone: speaker.isMicrophone,
                        speakerId: speaker.speakerId)
                    : speaker
            }
            let updated = RefinementMetadata(
                schemaVersion: metadata.schemaVersion,
                recordingId: metadata.recordingId,
                recordingStart: metadata.recordingStart,
                refinedAt: metadata.refinedAt,
                durationSeconds: metadata.durationSeconds,
                speakers: updatedSpeakers,
                whisperModel: metadata.whisperModel,
                pyannoteModel: metadata.pyannoteModel,
                language: metadata.language,
                sourceBasename: metadata.sourceBasename)
            try AtomicFile.write(try updated.encoded(), to: metadataURL)
        } catch {
            logger.notice("final.md rewrite: metadata.json update skipped")
        }
    }
}
