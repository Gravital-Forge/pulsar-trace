import Foundation
import PulsarTraceEngine

/// A transient undo affordance shown after a destructive speaker edit (PT-R44).
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

/// Drives the menubar speaker editor (PT-R44): rename / merge / split / delete /
/// undelete, each followed by the retroactive `final.md` rewrite (PT-P1-D16).
///
/// Every mutating op follows the causal contract:
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

    /// Live (non-deleted, non-delisted) speakers, newest-library-order.
    public private(set) var liveSpeakers: [Speaker] = []
    /// Soft-deleted speakers still inside the 30-day recovery window (PT-R44
    /// "Recently deleted").
    public private(set) var deletedSpeakers: [Speaker] = []
    /// Delisted speakers still inside the 30-day recovery window
    /// ("Recently delisted" section, parallel to "Recently deleted").
    public private(set) var delistedSpeakers: [Speaker] = []
    /// True while a rewrite is in flight — the UI disables edits.
    public private(set) var isRewriting = false
    /// The last error surfaced to the user, or `nil`.
    public private(set) var lastError: String?
    /// The active undo toast, or `nil`. Set via `showToast` (which arms the
    /// auto-dismiss clock) and cleared via `dismissToast` or the clock.
    public private(set) var undoToast: UndoToast?

    private let library: SpeakerLibrary
    private let events: EventWriter?
    private let settings: MenuBarSettings
    private let rewriter: FinalMarkdownRewriter
    /// How long an undo toast stays up before auto-dismissing.
    private let toastLifetime: Duration
    /// The pending auto-dismiss for the current toast — cancelled when the
    /// toast is replaced (`showToast`) or explicitly dismissed
    /// (`dismissToast`). Not UI state, so not observation-tracked.
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    /// - Parameters:
    ///   - library: the persistent speaker library actor.
    ///   - events: events writer; `nil` disables event emission (unit tests
    ///     that do not assert on the log).
    ///   - settings: provides the output folder roots the rewriter scans.
    ///   - toastLifetime: how long the undo toast stays up before
    ///     auto-dismissing (tests shrink it to milliseconds).
    public init(
        library: SpeakerLibrary,
        events: EventWriter? = nil,
        settings: MenuBarSettings,
        toastLifetime: Duration = .seconds(8)
    ) {
        self.library = library
        self.events = events
        self.settings = settings
        self.rewriter = FinalMarkdownRewriter()
        self.toastLifetime = toastLifetime
    }

    /// Opens the speaker library at the standard path and returns a ready
    /// VM — the one place the editor flow touches `AppPaths`/`SpeakerLibrary`,
    /// so the view layer never constructs engine objects. A failure to open
    /// the library throws; the view surfaces it as its error state (I6).
    public static func load(
        events: EventWriter?, settings: MenuBarSettings
    ) async throws -> SpeakerEditorViewModel {
        let library = try await SpeakerLibrary(
            databaseURL: AppPaths.standard.speakersDatabaseURL, events: events)
        let vm = SpeakerEditorViewModel(
            library: library, events: events, settings: settings)
        await vm.reload()
        return vm
    }

    // MARK: - Load

    /// Reload `liveSpeakers` / `deletedSpeakers` / `delistedSpeakers` from
    /// the library.
    public func reload() async {
        do {
            liveSpeakers = try await library.liveSpeakers()
            deletedSpeakers = try await library.recoverableSpeakers()
            delistedSpeakers = try await library.recoverableDelistedSpeakers()
            lastError = nil
        } catch {
            lastError = "Could not load speakers: \(error)"
        }
    }

    /// The recording appearances of a speaker, newest library order — backs
    /// the split sheet's recording multi-select (#3). A load failure yields an
    /// empty list rather than throwing: the split sheet simply shows no
    /// recordings to move.
    public func appearances(ofSpeaker speakerId: String) async -> [SpeakerAppearance] {
        (try? await library.appearances(of: speakerId)) ?? []
    }

    // MARK: - Rename

    /// Rename a speaker and retroactively rewrite past `final.md` files (PT-R44,
    /// PT-P1-D16).
    public func rename(speakerId: String, to newName: String) async {
        guard validateName(newName) else { return }
        // No-op guard: committing an unchanged name (the rename field's
        // blur-commit does this routinely) must not rewrite every final.md
        // the speaker appears in — nor flash isRewriting, which disables
        // the whole editor while it runs.
        guard liveSpeakers.first(where: { $0.id == speakerId })?.name != newName
        else { return }
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
    /// `final.md` files (PT-R44, PT-P1-D16).
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
                reason: .speakerMerged,
                // Drop the merged-away row from `metadata.json` so a
                // recording that had BOTH speakers doesn't end up with two
                // rows under the primary's name (which surfaces in the
                // recordings-list pills as a duplicate chip).
                removedSpeakerId: otherId)
            _ = try? await self.events?.append(SpeakerMergedEvent(
                primarySpeakerId: primaryId, mergedSpeakerId: otherId,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerMerged)
        }
    }

    // MARK: - Split

    /// Split a subset of a speaker's recordings off into a new speaker, then
    /// rewrite the moved recordings' `final.md` files (PT-R44, PT-P1-D16).
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

    /// Soft-delete a speaker (PT-R44). No `final.md` rewrite — a delete does not
    /// change any label. Offers an undo toast.
    public func delete(speakerId: String) async {
        let name = liveSpeakers.first { $0.id == speakerId }?.name ?? "speaker"
        await withRewrite {
            try await self.library.delete(speakerId: speakerId)
        }
        if lastError == nil {
            showToast(UndoToast(message: "Deleted \(name)") { [weak self] in
                await self?.undelete(speakerId: speakerId)
            })
        }
    }

    /// Restore a soft-deleted speaker (PT-R44 undo).
    public func undelete(speakerId: String) async {
        await withRewrite {
            try await self.library.undelete(speakerId: speakerId)
        }
    }

    // MARK: - Delist / undelist ("Don't recognize this speaker")

    /// Delist a speaker: hide them from the library, exclude from future
    /// matching, and rewrite past `final.md` files to drop their token
    /// (solo → `Unrecognized`, co-attribution → drop just the token).
    ///
    /// Rejects the mic speaker (name `"You"`). The mic identity is per-recording
    /// metadata, not a library attribute, so there is no clean
    /// `Speaker.isMicrophone` to check — the matching surface is the name
    /// `"You"`, which `SpeakerReconciler` documents as the never-in-library
    /// mic label. A user-renamed library speaker happening to be called
    /// `"You"` would still be rejected; that is the intended conservative
    /// behaviour. TODO: surface an `isMicrophone` flag on `Speaker` once the
    /// library carries one.
    public func delist(speakerId: String) async {
        guard let target = liveSpeakers.first(where: { $0.id == speakerId })
        else {
            lastError = "Speaker not found."
            return
        }
        guard target.name != "You" else {
            lastError = "The microphone speaker cannot be delisted."
            return
        }
        let name = target.name
        await withRewrite {
            _ = try await self.library.delist(
                speakerId: speakerId, suppressEvent: true)
            let appearances = try await self.library.appearances(of: speakerId)
            let results = try await self.rewriter.rewriteDropping(
                name: name, speakerId: speakerId,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerDelisted)
            // Causal order: emit `speaker_delisted` (the cause) BEFORE the
            // rewriter's `final_md_rewritten` events.
            let recoverableUntil = Timestamps.event(
                Date().addingTimeInterval(SpeakerLibrary.recoveryWindow))
            _ = try? await self.events?.append(SpeakerDelistedEvent(
                speakerId: speakerId,
                recoverableUntil: recoverableUntil,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerDelisted)
        }
        if lastError == nil {
            showToast(UndoToast(message: "Stopped recognizing \(name)") {
                [weak self] in
                await self?.undelist(speakerId: speakerId)
            })
        }
    }

    /// Undo a delist (within the 30-day window): restore the speaker to the
    /// live list and rewrite the `Unrecognized` sentinel back to their name.
    ///
    /// Two acceptable degradations vs. an idealised undo:
    ///
    /// 1. **Co-attributed lines remain rewritten.** A delisted token in
    ///    `A+B+C` was dropped at delist time; the rewriter cannot
    ///    reconstruct the original position from `A+C`. Solo lines DO round
    ///    trip correctly.
    /// 2. **Cross-speaker collision on overlapping delists.** If two
    ///    speakers were delisted in the same recording, both have solo
    ///    lines now labelled `Unrecognized`, and undelisting just ONE of
    ///    them rewrites *every* `Unrecognized` solo line on that recording
    ///    to that one speaker's name — misattributing the other delisted
    ///    speaker's lines. Per-line provenance would be needed to
    ///    disambiguate, and we don't carry it on disk. The pragmatic shape
    ///    is: undelist the most recent first, or accept that overlapping
    ///    delists need manual cleanup.
    ///
    /// The pill renders correctly because `RecordingSpeaker` keys off
    /// `label` + `isMicrophone`; the `speaker_id` linkage in
    /// `metadata.json` is not restored (it was dropped on delist).
    public func undelist(speakerId: String) async {
        await withRewrite {
            let name = try await self.library.undelist(
                speakerId: speakerId, suppressEvent: true)
            let appearances = try await self.library.appearances(of: speakerId)
            let results = try await self.rewriter.rewrite(
                oldName: "Unrecognized", newName: name,
                appearances: appearances,
                outputFolderRoots: self.outputRoots(),
                reason: .speakerUndelisted)
            _ = try? await self.events?.append(SpeakerUndelistedEvent(
                speakerId: speakerId,
                appliedToRecordings: results.map(\.recordingId)))
            await self.emitRewriteEvents(results, reason: .speakerUndelisted)
        }
    }

    /// Undo a merge (PT-R44): restore the merged-away speaker in the library AND
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
            // PT-P1-D18 — the rare merge-collision case the centroid math also
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

    /// Undo a split (PT-R44): fold the split-off speaker back into the original
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
            // genuinely contained both speakers is handled best-effort (PT-P1-D18).
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

    // MARK: - Toast lifecycle

    /// Show an undo toast and (re)arm its auto-dismiss clock. A newer toast
    /// replaces the current one and restarts the clock — cancellation plus
    /// MainActor serialization guarantee a superseded clock can never clear
    /// the replacement toast.
    private func showToast(_ toast: UndoToast) {
        undoToast = toast
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            guard let lifetime = self?.toastLifetime else { return }
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.undoToast = nil
        }
    }

    /// Dismiss the current toast and cancel its auto-dismiss clock — the
    /// view calls this after a tapped Undo has run `toast.action()`.
    public func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        undoToast = nil
    }

    /// Dismiss the error banner (the view's ✕ button). `lastError` is
    /// `private(set)`, so this is the view's clearing seam.
    public func clearError() {
        lastError = nil
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
        // Reentrancy guard: a confirmation dialog staged before a rewrite
        // began can still confirm mid-flight (dialogs are window-modal, not
        // part of the disabled List's subtree). Two interleaved withRewrite
        // calls would drop `isRewriting` early and clobber `lastError` —
        // refuse the second op instead.
        guard !isRewriting else {
            lastError = "Another rewrite is still in progress — try again in a moment."
            return
        }
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
