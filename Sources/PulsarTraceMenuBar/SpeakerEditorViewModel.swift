import Foundation
import PulsarTraceEngine

/// A transient undo affordance shown after a destructive speaker edit (R44).
public struct UndoToast: Identifiable, Sendable {
    public let id: UUID
    /// User-facing message, e.g. "Deleted Steve".
    public let message: String
    /// The undo action — runs the inverse library operation.
    public let action: @Sendable () async -> Void

    public init(
        id: UUID = UUID(),
        message: String,
        action: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.message = message
        self.action = action
    }
}

/// Drives the menubar speaker editor (R44): rename / merge / split / delete /
/// undelete, each followed by the retroactive `final.md` rewrite (D16).
///
/// Every mutating op follows the Epic 8 causal contract:
/// 1. mutate `SpeakerLibrary` with `suppressEvent: true` (DB write only),
/// 2. run `FinalMarkdownRewriter` over the affected appearances,
/// 3. emit the single `speaker_*` event with a populated
///    `applied_to_recordings` — so the cause (`speaker_*`) is logged before
///    its effects (`final_md_rewritten`), and `applied_to_recordings` lists
///    exactly the recordings whose `final.md` was rewritten.
///
/// `@MainActor @Observable` for direct SwiftUI binding.
@MainActor
@Observable
public final class SpeakerEditorViewModel {

    /// Live (non-deleted) speakers, newest-library-order.
    public private(set) var liveSpeakers: [Speaker] = []
    /// Soft-deleted speakers still inside the 30-day recovery window (R44
    /// "Recently deleted").
    public private(set) var deletedSpeakers: [Speaker] = []
    /// True while a rewrite is in flight — the UI disables edits.
    public private(set) var isRewriting = false
    /// The last error surfaced to the user, or `nil`.
    public private(set) var lastError: String?
    /// The active undo toast, or `nil`.
    public var undoToast: UndoToast?

    private let library: SpeakerLibrary
    private let events: EventWriter?
    private let settings: MenuBarSettings
    private let rewriter: FinalMarkdownRewriter

    /// - Parameters:
    ///   - library: the persistent speaker library actor.
    ///   - events: events writer; `nil` disables event emission (unit tests
    ///     that do not assert on the log).
    ///   - settings: provides the output folder roots the rewriter scans.
    public init(
        library: SpeakerLibrary,
        events: EventWriter? = nil,
        settings: MenuBarSettings
    ) {
        self.library = library
        self.events = events
        self.settings = settings
        self.rewriter = FinalMarkdownRewriter()
    }

    // MARK: - Load

    /// Reload `liveSpeakers` / `deletedSpeakers` from the library.
    public func reload() async {
        do {
            liveSpeakers = try await library.liveSpeakers()
            deletedSpeakers = try await library.recoverableSpeakers()
            lastError = nil
        } catch {
            lastError = "Could not load speakers: \(error)"
        }
    }

    // MARK: - Rename

    /// Rename a speaker and retroactively rewrite past `final.md` files (R44,
    /// D16).
    public func rename(speakerId: String, to newName: String) async {
        guard validateName(newName) else { return }
        await withRewrite {
            let oldName = try await self.library.rename(
                speakerId: speakerId, to: newName, suppressEvent: true)
            let appearances = try await self.library.appearances(of: speakerId)
            let results = try await self.rewriter.rewrite(
                oldName: oldName, newName: newName,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerRenamed)
            // Causal order: emit `speaker_renamed` (the cause) FIRST, then the
            // rewriter's `final_md_rewritten` events.
            _ = try? await self.events?.append(SpeakerRenamedEvent(
                speakerId: speakerId, oldName: oldName, newName: newName,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerRenamed)
        }
    }

    // MARK: - Merge

    /// Merge `otherId` into `primaryId` and rewrite the merged speaker's past
    /// `final.md` files (R44, D16).
    public func merge(primaryId: String, otherId: String) async {
        await withRewrite {
            let names = try await self.library.merge(
                primaryId: primaryId, otherId: otherId, suppressEvent: true)
            // The merged-away speaker's appearances are now owned by `primary`;
            // rewrite `otherName` → `primaryName` across them.
            let appearances = try await self.library.appearances(of: primaryId)
            let results = try await self.rewriter.rewrite(
                oldName: names.otherName, newName: names.primaryName,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerMerged)
            _ = try? await self.events?.append(SpeakerMergedEvent(
                primarySpeakerId: primaryId, mergedSpeakerId: otherId,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerMerged)
        }
    }

    // MARK: - Split

    /// Split a subset of a speaker's recordings off into a new speaker, then
    /// rewrite the moved recordings' `final.md` files (R44, D16).
    public func split(
        originalId: String,
        movingRecordingIds: [String],
        newName: String
    ) async {
        guard validateName(newName) else { return }
        await withRewrite {
            guard let originalName =
                try await self.library.speaker(id: originalId)?.name else {
                throw EditorError.speakerNotFound
            }
            let newSpeaker = try await self.library.split(
                originalId: originalId,
                movingRecordingIds: movingRecordingIds,
                newName: newName, suppressEvent: true)
            // The moved appearances now belong to the new speaker; rewrite
            // `originalName` → `newName` across them.
            let appearances = try await self.library.appearances(of: newSpeaker.id)
            let results = try await self.rewriter.rewrite(
                oldName: originalName, newName: newName,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerSplit)
            _ = try? await self.events?.append(SpeakerSplitEvent(
                originalSpeakerId: originalId, newSpeakerId: newSpeaker.id,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerSplit)
        }
    }

    // MARK: - Delete / undelete

    /// Soft-delete a speaker (R44). No `final.md` rewrite — a delete does not
    /// change any label. Offers an undo toast.
    public func delete(speakerId: String) async {
        let name = liveSpeakers.first { $0.id == speakerId }?.name ?? "speaker"
        await withRewrite {
            try await self.library.delete(speakerId: speakerId)
        }
        if lastError == nil {
            undoToast = UndoToast(message: "Deleted \(name)") { [weak self] in
                await self?.undelete(speakerId: speakerId)
            }
        }
    }

    /// Restore a soft-deleted speaker (R44 undo).
    public func undelete(speakerId: String) async {
        await withRewrite {
            try await self.library.undelete(speakerId: speakerId)
        }
    }

    /// Undo a merge (R44): restore the merged-away speaker in the library AND
    /// rewrite the affected `final.md` files back from the primary's name to
    /// the restored speaker's name — otherwise the transcripts disagree with
    /// the library and no `final_md_rewritten` is paired with the undo (Hard
    /// Invariant #8). `library.unmerge` emits `speaker_unmerged` first (the
    /// cause); the paired `final_md_rewritten` events follow in causal order.
    public func unmerge(primaryId: String, otherId: String) async {
        await withRewrite {
            guard let primaryName =
                try await self.library.speaker(id: primaryId)?.name,
                let otherName =
                    try await self.library.speaker(id: otherId)?.name
            else { throw EditorError.speakerNotFound }

            try await self.library.unmerge(
                primaryId: primaryId, otherId: otherId)

            // The merge moved `other`'s appearances onto `primary` and they
            // are now restored to `other`; rewrite `primaryName` → `otherName`
            // scoped to exactly those restored appearances. A recording that
            // genuinely contained BOTH speakers is handled best-effort per
            // D18 — the rare merge-collision case the centroid math also
            // documents.
            let appearances = try await self.library.appearances(of: otherId)
            let results = try await self.rewriter.rewrite(
                oldName: primaryName, newName: otherName,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerUnmerged)
            await self.emitRewriteEvents(results, reason: .speakerUnmerged)
        }
    }

    /// Undo a split (R44): fold the split-off speaker back into the original
    /// in the library AND rewrite the affected `final.md` files back from the
    /// new name to the original's name (Hard Invariant #8). `library.unsplit`
    /// emits `speaker_unsplit` first (the cause); the paired
    /// `final_md_rewritten` events follow in causal order.
    public func unsplit(originalId: String, newId: String) async {
        await withRewrite {
            guard let originalName =
                try await self.library.speaker(id: originalId)?.name,
                let newName =
                    try await self.library.speaker(id: newId)?.name
            else { throw EditorError.speakerNotFound }

            // The split-off appearances are about to move back to the
            // original — capture them before the library mutation so the
            // rewrite is scoped to exactly those recordings. A recording that
            // genuinely contained both speakers is handled best-effort (D18).
            let appearances = try await self.library.appearances(of: newId)

            try await self.library.unsplit(
                originalId: originalId, newId: newId)

            let results = try await self.rewriter.rewrite(
                oldName: newName, newName: originalName,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerUnsplit)
            await self.emitRewriteEvents(results, reason: .speakerUnsplit)
        }
    }

    // MARK: - Name validation

    /// Validate a speaker name before a rename/split. A name containing `+`,
    /// `*`, or a backtick is rejected — those characters break `final.md`'s
    /// `**[HH:MM:SS] <label>:**` label parsing (`+` is the co-attribution
    /// separator). On failure `lastError` is set and `false` returned.
    func validateName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "A speaker name cannot be empty."
            return false
        }
        let forbidden: Set<Character> = ["+", "*", "`"]
        guard !trimmed.contains(where: { forbidden.contains($0) }) else {
            lastError = "A speaker name cannot contain + * or `."
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// The output folder roots the rewriter scans for recording folders.
    private func outputRoots() -> [URL] {
        var roots = [settings.outputFolderURL].compactMap { $0 }
        roots += settings.previousFolderURLs
        return roots
    }

    /// Emit one `final_md_rewritten` per rewritten recording, in processing
    /// order — after the `speaker_*` cause (causal order).
    private func emitRewriteEvents(
        _ results: [FinalMarkdownRewriter.RecordingResult],
        reason: FinalMarkdownRewriter.RewriteReason
    ) async {
        for result in results {
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: result.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: result.newSHA256,
                reason: reason.rawValue))
        }
    }

    /// Run a mutating op with the `isRewriting` flag, error capture, and a
    /// reload afterwards.
    private func withRewrite(_ body: () async throws -> Void) async {
        isRewriting = true
        lastError = nil
        do {
            try await body()
        } catch {
            lastError = "\(error)"
        }
        isRewriting = false
        await reload()
    }

    /// Editor-level errors.
    enum EditorError: Error, CustomStringConvertible {
        case speakerNotFound
        var description: String {
            switch self {
            case .speakerNotFound: return "speaker not found"
            }
        }
    }
}
