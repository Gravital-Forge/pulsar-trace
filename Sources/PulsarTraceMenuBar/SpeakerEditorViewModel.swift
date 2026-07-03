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
/// The edit orchestration — mutate `SpeakerLibrary` with its event suppressed,
/// run `FinalMarkdownRewriter` over the affected appearances, then emit the
/// `speaker_*` cause before its `final_md_rewritten` effects (so the cause is
/// logged first and `applied_to_recordings` lists exactly the rewritten
/// recordings) — lives in the shared `SpeakerEditService` (PT-R123), which the
/// MCP server and CLI also call. This view model delegates each mutating op to
/// the service inside `withRewrite { }` and owns only the UI concerns: the cheap
/// pre-checks, `lastError`, `isRewriting`, the undo toasts, and `reload`.
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
    private let service: SpeakerEditService
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
        self.service = SpeakerEditService(library: library, events: events)   // PT-R123
        self.toastLifetime = toastLifetime
    }

    /// Build a ready VM over an already-opened library — the single shared
    /// writer `AppEnvironment` owns (PT-P6-D1), the same instance the MCP server
    /// uses. This never opens its own `SpeakerLibrary`, so the editor and the
    /// agent surface never drift across two caches.
    public static func using(
        library: SpeakerLibrary, events: EventWriter?, settings: MenuBarSettings
    ) async -> SpeakerEditorViewModel {
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
            // The editor holds its own `SpeakerLibrary` instance, separate
            // from the refine pipeline's. Drop its cache first so a speaker
            // another instance created (an `Unknown #N` from refinement) is
            // observed on reload, not served stale from a warm cache.
            await library.refreshFromDisk()
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
            _ = try await self.service.rename(
                speakerId: speakerId, to: newName,
                outputFolderRoots: self.outputRoots())
        }
    }

    // MARK: - Merge

    /// Merge `otherId` into `primaryId` and rewrite the merged speaker's past
    /// `final.md` files (PT-R44, PT-P1-D16). Offers an undo toast whose action
    /// reverses the merge (restores the merged-away speaker and its labels).
    public func merge(primaryId: String, otherId: String) async {
        // Capture both names before the merge: the merged-away speaker
        // (`otherId`) is soft-deleted by the merge, so it is no longer in
        // `liveSpeakers` once `withRewrite` reloads.
        let otherName = liveSpeakers.first { $0.id == otherId }?.name ?? "speaker"
        let primaryName = liveSpeakers.first { $0.id == primaryId }?.name ?? "speaker"
        await withRewrite {
            _ = try await self.service.merge(
                primaryId: primaryId, otherId: otherId,
                outputFolderRoots: self.outputRoots())
        }
        if lastError == nil {
            // PT-R32b: the destructive merge must be recoverable within the
            // undo window — mirror delete/delist and surface an undo toast.
            showToast(UndoToast(message: "Merged \(otherName) into \(primaryName)") {
                [weak self] in
                await self?.unmerge(primaryId: primaryId, otherId: otherId)
            })
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
            _ = try await self.service.split(
                originalId: originalId, movingRecordingIds: movingRecordingIds,
                newName: newName, outputFolderRoots: self.outputRoots())
        }
    }

    // MARK: - Delete / undelete

    /// Soft-delete a speaker (PT-R44). No `final.md` rewrite — a delete does not
    /// change any label. Offers an undo toast.
    public func delete(speakerId: String) async {
        let name = liveSpeakers.first { $0.id == speakerId }?.name ?? "speaker"
        await withRewrite {
            _ = try await self.service.delete(speakerId: speakerId)
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
            _ = try await self.service.undelete(speakerId: speakerId)
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
            _ = try await self.service.delist(
                speakerId: speakerId, outputFolderRoots: self.outputRoots())
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
            _ = try await self.service.undelist(
                speakerId: speakerId, outputFolderRoots: self.outputRoots())
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
            _ = try await self.service.unmerge(
                primaryId: primaryId, otherId: otherId,
                outputFolderRoots: self.outputRoots())
        }
    }

    /// Undo a split (PT-R44): fold the split-off speaker back into the original
    /// in the library AND rewrite the affected `final.md` files back from the
    /// new name to the original's name (Hard Invariant #8). `library.unsplit`
    /// emits `speaker_unsplit` first (the cause); the paired
    /// `final_md_rewritten` events follow in causal order.
    public func unsplit(originalId: String, newId: String) async {
        await withRewrite {
            _ = try await self.service.unsplit(
                originalId: originalId, newId: newId,
                outputFolderRoots: self.outputRoots())
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
        do {
            try SpeakerEditService.validateName(name)
            return true
        } catch {
            lastError = "\(error)"   // EditError.invalidName carries the same messages as before
            return false
        }
    }

    // MARK: - Helpers

    /// The output folder roots the rewriter scans for recording folders.
    private func outputRoots() -> [URL] {
        var roots = [settings.outputFolderURL].compactMap { $0 }
        roots += settings.previousFolderURLs
        return roots
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
}
