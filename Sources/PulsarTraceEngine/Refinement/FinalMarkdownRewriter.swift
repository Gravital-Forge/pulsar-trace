import Foundation
import Logging

/// Retroactively rewrites past `final.md` files after a speaker rename / merge
/// / split (PT-P1-D16).
///
/// A `pulsartrace speakers rename` updates the speaker library only; PT-P1-D16 splits
/// the *retroactive* rewrite of already-refined `final.md` files into this
/// separate step. This type is that rewrite: given a speaker's appearances (from
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
/// The menubar editor drives this: it performs the library
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
        /// "Don't recognize this speaker": the speaker's token is dropped from
        /// every label they appeared in. Solo lines collapse to the sentinel
        /// label `Unrecognized`; co-attributed labels lose just that token.
        case speakerDelisted = "speaker_delisted"
        /// Undo of a delist — the `Unrecognized` sentinel is rewritten back to
        /// the restored speaker's name. Symmetric only for solo lines: a
        /// co-attributed line that previously read `Steve+<name>` was already
        /// rewritten to `Steve` on delist, so the rewriter cannot reconstruct
        /// the original position of `<name>` on undelist — that degradation is
        /// documented and accepted.
        case speakerUndelisted = "speaker_undelisted"
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
    ///   - removedSpeakerId: optional library id whose `metadata.json`
    ///     speaker row should be **deleted** (not just relabelled). Set by
    ///     merge so the merged-away speaker doesn't survive as a stale
    ///     duplicate entry under the primary's name — without this, a
    ///     recording that had both speakers ends up with two rows whose
    ///     `label` field is identical after the rewrite, which surfaces in
    ///     the menubar pills strip as two chips for the same person.
    ///     `final.md` itself is not affected — drop only applies to
    ///     `metadata.json`.
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
        reason: RewriteReason,
        removedSpeakerId: String? = nil
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
                oldName: oldName, newName: newName,
                removedSpeakerId: removedSpeakerId)
            else { continue }

            let result = RecordingResult(
                recordingId: appearance.recordingId,
                folderURL: folder, newSHA256: sha)
            results.append(result)
        }

        return results
    }

    /// Rewrite every appearance's `final.md`, dropping `name` from every
    /// speaker label it appears in. A solo line `**[..] <name>:**` becomes
    /// `**[..] <fallbackLabel>:**`; a co-attributed `**[..] A+<name>+B:**`
    /// becomes `**[..] A+B:**`. The `metadata.json` row for `speakerId` is
    /// removed; any surviving row whose `label` was `name` (the speaker
    /// shipped under a different `speaker_id` in metadata) is relabelled to
    /// `fallbackLabel`. Then duplicate rows are collapsed.
    ///
    /// - Parameters:
    ///   - name: the speaker label to drop from labels.
    ///   - speakerId: the library `spk_<ulid>` to drop from
    ///     `metadata.json`'s speakers array.
    ///   - appearances: the speaker's appearances, from
    ///     `SpeakerLibrary.appearances(of:)`.
    ///   - outputFolderRoots: directories to scan for a subdirectory whose
    ///     `lastPathComponent` matches an appearance's folder name.
    ///   - fallbackLabel: the sentinel label used when a solo line would
    ///     otherwise produce an empty label. Locked to `Unrecognized` for
    ///     delist.
    ///   - reason: why the rewrite is happening — the caller copies it into
    ///     the `final_md_rewritten` event it emits per `RecordingResult`.
    /// - Returns: one `RecordingResult` per recording whose `final.md` was
    ///   **genuinely changed**, same shape and skip rules as `rewrite(...)`.
    @discardableResult
    public func rewriteDropping(
        name: String,
        speakerId: String,
        appearances: [SpeakerAppearance],
        outputFolderRoots: [URL],
        fallbackLabel: String = "Unrecognized",
        reason: RewriteReason = .speakerDelisted
    ) async throws -> [RecordingResult] {
        var results: [RecordingResult] = []

        for appearance in appearances {
            guard let folder = locateFolder(
                named: appearance.recordingFolderName, in: outputFolderRoots)
            else {
                logger.notice("final.md drop-rewrite: folder not found, skipping")
                continue
            }

            let finalURL = folder.appendingPathComponent(
                RecordingFolder.FileName.final)
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                logger.notice("final.md drop-rewrite: no final.md, skipping")
                continue
            }

            guard let sha = try dropInFolder(
                folder: folder, finalURL: finalURL,
                name: name, speakerId: speakerId,
                fallbackLabel: fallbackLabel)
            else { continue }

            results.append(RecordingResult(
                recordingId: appearance.recordingId,
                folderURL: folder, newSHA256: sha))
        }
        return results
    }

    /// Drop `name` from every label in `final.md` (atomic write + `.bak`) and
    /// drop `speakerId`'s row from `metadata.json`. Returns `nil` when the
    /// drop leaves `final.md` byte-identical — same no-op semantics as
    /// `rewriteFolder`.
    private func dropInFolder(
        folder: URL,
        finalURL: URL,
        name: String,
        speakerId: String,
        fallbackLabel: String
    ) throws -> String? {
        let fm = FileManager.default
        let original = try String(contentsOf: finalURL, encoding: .utf8)
        let rewritten = Self.rewriteMarkdownDropping(
            original, name: name, fallbackLabel: fallbackLabel)

        guard rewritten != original else { return nil }

        let backupURL = folder.appendingPathComponent(
            RecordingFolder.FileName.finalBackup)
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
        try fm.copyItem(at: finalURL, to: backupURL)

        let sha = try AtomicFile.write(rewritten, to: finalURL)

        dropFromMetadataIfPresent(
            in: folder, name: name, speakerId: speakerId,
            fallbackLabel: fallbackLabel)

        return sha
    }

    /// `rewriteMarkdown`-shaped pass that drops `name` from every utterance
    /// label, preserving line terminators byte-for-byte. Solo lines collapse
    /// to `fallbackLabel`; co-attributed lines lose just that token.
    static func rewriteMarkdownDropping(
        _ markdown: String,
        name: String,
        fallbackLabel: String
    ) -> String {
        var output = ""
        var lineStart = markdown.unicodeScalars.startIndex
        let scalars = markdown.unicodeScalars
        var index = scalars.startIndex

        func emit(body bodyRange: Range<String.UnicodeScalarView.Index>,
                  terminator: String) {
            var body = String(markdown.unicodeScalars[bodyRange])
            let trailingCR = body.hasSuffix("\r")
            if trailingCR { body = String(body.dropLast()) }
            output += Self.rewriteLineDropping(
                body, name: name, fallbackLabel: fallbackLabel)
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
        emit(body: lineStart..<scalars.endIndex, terminator: "")
        return output
    }

    /// Rewrite one line if it is an utterance line, dropping any label
    /// component equal to `name`. If the resulting component list is empty,
    /// the new label is `fallbackLabel`. Otherwise the components are joined
    /// with the original `+` separator. Adjacent-duplicate components are
    /// collapsed (mirrors `rewriteLine`'s defense against self-overlap).
    private static func rewriteLineDropping(
        _ line: String,
        name: String,
        fallbackLabel: String
    ) -> String {
        guard line.hasPrefix("**[") else { return line }
        guard let timeEnd = line.range(of: "] ") else { return line }
        let afterTime = timeEnd.upperBound
        guard let labelClose = line.range(
            of: ":**", range: afterTime..<line.endIndex)
        else { return line }

        let label = String(line[afterTime..<labelClose.lowerBound])
            .trimmingCharacters(in: .newlines)

        var keptComponents: [String] = []
        for raw in label.split(separator: "+", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // The plan locked the bare `+` separator (no surrounding spaces),
            // matching the existing fixtures — compare on the trimmed token
            // so a stray ` ` does not let a `name` token survive.
            if trimmed == name { continue }
            let component = String(raw)
            if component != keptComponents.last {
                keptComponents.append(component)
            }
        }
        let newLabel = keptComponents.isEmpty
            ? fallbackLabel
            : keptComponents.joined(separator: "+")

        guard newLabel != label else { return line }
        return String(line[line.startIndex..<afterTime])
            + newLabel
            + String(line[labelClose.lowerBound...])
    }

    /// Update `metadata.json` for a delist: drop the row whose `speakerId`
    /// matches (mainline drop), relabel any surviving row whose `label` equals
    /// `name` (the `Unrecognized` sentinel — covers metadata that shipped
    /// without a `speaker_id` link), and then drop duplicates by `label`.
    private func dropFromMetadataIfPresent(
        in folder: URL,
        name: String,
        speakerId: String,
        fallbackLabel: String
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

            // Step 1 — drop the row for this speakerId.
            let afterDrop = metadata.speakers.filter { $0.speakerId != speakerId }
            // Step 2 — relabel any surviving row whose label is `name`.
            let relabelled = afterDrop.map { speaker in
                speaker.label == name
                    ? RefinementMetadata.Speaker(
                        label: fallbackLabel,
                        isMicrophone: speaker.isMicrophone,
                        speakerId: speaker.speakerId)
                    : speaker
            }
            // Step 3 — dedupe by label (a relabel can collide with an
            // existing `Unrecognized` row from a prior delist).
            var seen: Set<String> = []
            let deduped = relabelled.filter { seen.insert($0.label).inserted }

            // No-op guard: only rewrite if something actually changed.
            guard deduped != metadata.speakers else { return }

            let updated = RefinementMetadata(
                schemaVersion: metadata.schemaVersion,
                recordingId: metadata.recordingId,
                recordingStart: metadata.recordingStart,
                refinedAt: metadata.refinedAt,
                durationSeconds: metadata.durationSeconds,
                speakers: deduped,
                whisperModel: metadata.whisperModel,
                diarizationModel: metadata.diarizationModel,
                language: metadata.language,
                sourceBasename: metadata.sourceBasename)
            try AtomicFile.write(try updated.encoded(), to: metadataURL)
        } catch {
            logger.notice("final.md drop-rewrite: metadata.json update skipped")
        }
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
        newName: String,
        removedSpeakerId: String?
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
        // atomic write — mirrors RefinementPipeline's re-refine backup (PT-R48).
        let backupURL = folder.appendingPathComponent(
            RecordingFolder.FileName.finalBackup)
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
        try fm.copyItem(at: finalURL, to: backupURL)

        // Atomic write-then-rename (PT-R24) — a reader/editor sees old-or-new.
        let sha = try AtomicFile.write(rewritten, to: finalURL)

        // Best-effort metadata.json update — a separate atomic write (v1).
        rewriteMetadataIfPresent(
            in: folder, oldName: oldName, newName: newName,
            removedSpeakerId: removedSpeakerId)

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
    ///
    /// When `removedSpeakerId` is set, the row whose `speakerId` matches it is
    /// **dropped** first. This is the merge case: without it, two rows that
    /// land on the same label after substitution would persist as a duplicate
    /// pair. A defensive label dedupe runs after substitution to collapse any
    /// remaining duplicate `(label, isMicrophone)` rows (e.g. metadata that
    /// was already corrupted by a pre-fix merge) — first occurrence wins.
    private func rewriteMetadataIfPresent(
        in folder: URL,
        oldName: String,
        newName: String,
        removedSpeakerId: String?
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

            let renamingApplies =
                metadata.speakers.contains { $0.label == oldName }
            let dropApplies = removedSpeakerId.map { id in
                metadata.speakers.contains { $0.speakerId == id }
            } ?? false
            // Nothing to do for this recording: neither the rename nor the
            // drop touches its speakers list. Avoid an atomic rewrite that
            // would only change the on-disk timestamp.
            guard renamingApplies || dropApplies else { return }

            // Step 1 — drop the merged-away row if requested.
            let afterDrop = metadata.speakers.filter { speaker in
                guard let removedId = removedSpeakerId,
                      let speakerId = speaker.speakerId else {
                    return true
                }
                return speakerId != removedId
            }
            // Step 2 — apply the label substitution to the remaining rows.
            let relabelled = afterDrop.map { speaker in
                speaker.label == oldName
                    ? RefinementMetadata.Speaker(
                        label: newName,
                        isMicrophone: speaker.isMicrophone,
                        speakerId: speaker.speakerId)
                    : speaker
            }
            // Step 3 — defensive dedupe by `(label, isMicrophone)` (first
            // occurrence wins). Handles two edge cases: the rename created
            // an accidental duplicate that the step-1 drop didn't cover, and
            // a metadata.json already corrupted by a pre-fix merge gets
            // self-healed on its next rewrite.
            var seenKeys: Set<String> = []
            let updatedSpeakers = relabelled.filter { speaker in
                let key = "\(speaker.label)\u{1F}\(speaker.isMicrophone)"
                return seenKeys.insert(key).inserted
            }

            // No real change to the speakers list? Skip the write so we
            // don't disturb mtime or write byte-identical bytes.
            guard updatedSpeakers != metadata.speakers else { return }

            let updated = RefinementMetadata(
                schemaVersion: metadata.schemaVersion,
                recordingId: metadata.recordingId,
                recordingStart: metadata.recordingStart,
                refinedAt: metadata.refinedAt,
                durationSeconds: metadata.durationSeconds,
                speakers: updatedSpeakers,
                whisperModel: metadata.whisperModel,
                diarizationModel: metadata.diarizationModel,
                language: metadata.language,
                sourceBasename: metadata.sourceBasename)
            try AtomicFile.write(try updated.encoded(), to: metadataURL)
        } catch {
            logger.notice("final.md rewrite: metadata.json update skipped")
        }
    }
}
