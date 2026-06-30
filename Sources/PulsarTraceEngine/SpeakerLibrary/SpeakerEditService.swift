import Foundation

/// The shared speaker-edit orchestration: mutate the library with its event
/// suppressed, run the `FinalMarkdownRewriter` over the affected appearances,
/// then emit the `speaker_*` cause event before its `final_md_rewritten`
/// effects (Hard Invariant #8). The menubar editor, the MCP server, and the
/// CLI all call this so an edit produces identical file and event effects
/// regardless of who triggered it.
// PT-R123
public actor SpeakerEditService {

    /// What an edit rewrote — the recording ids whose `final.md` changed.
    public struct EditResult: Sendable, Equatable {
        public let rewrittenRecordingIds: [String]
        public init(rewrittenRecordingIds: [String]) {
            self.rewrittenRecordingIds = rewrittenRecordingIds
        }
    }

    public enum EditError: Error, CustomStringConvertible, Equatable {
        case invalidName(String)
        case speakerNotFound
        case cannotDelistMicrophone

        public var description: String {
            switch self {
            case .invalidName(let message): return message
            case .speakerNotFound: return "speaker not found"
            case .cannotDelistMicrophone:
                return "The microphone speaker cannot be delisted."
            }
        }
    }

    /// The display name of the microphone speaker, which can never be delisted.
    public static let microphoneSpeakerName = "You"

    /// Serializes the whole mutate→rewrite→emit sequence across ALL service
    /// instances so concurrent edits (menubar + MCP, or two MCP tools) cannot
    /// interleave the on-disk `final.md` rewrite (PT-P6-D1). Static so it is one
    /// lock process-wide regardless of how many `SpeakerEditService` instances
    /// exist over the shared `SpeakerLibrary`.
    static let editLock = AsyncSerialLock()

    let library: SpeakerLibrary
    let events: EventWriter?
    let rewriter: FinalMarkdownRewriter

    public init(
        library: SpeakerLibrary,
        events: EventWriter?,
        rewriter: FinalMarkdownRewriter = FinalMarkdownRewriter()
    ) {
        self.library = library
        self.events = events
        self.rewriter = rewriter
    }

    /// The shared speaker-name rule. Rejects an empty/whitespace name and the
    /// Markdown-significant characters `+ * \``. Every caller validates through
    /// this so the menubar, MCP, and CLI enforce one rule.
    public static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EditError.invalidName("A speaker name cannot be empty.")
        }
        let forbidden: Set<Character> = ["+", "*", "`"]
        guard !trimmed.contains(where: { forbidden.contains($0) }) else {
            throw EditError.invalidName("A speaker name cannot contain + * or `.")
        }
    }

    /// Rename a speaker and rewrite its label across every past `final.md`.
    /// A no-op (no rewrite, no event) when the name is unchanged.
    // PT-R123
    public func rename(
        speakerId: String, to newName: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            try Self.validateName(newName)
            guard let current = try await library.speaker(id: speakerId) else {
                throw EditError.speakerNotFound
            }
            guard current.name != newName else {
                return EditResult(rewrittenRecordingIds: [])
            }
            let oldName = try await library.rename(
                speakerId: speakerId, to: newName, suppressEvent: true)
            let appearances = try await library.appearances(of: speakerId)
            let results = try await rewriter.rewrite(
                oldName: oldName, newName: newName, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerRenamed)
            _ = try? await events?.append(SpeakerRenamedEvent(
                speakerId: speakerId, oldName: oldName, newName: newName,
                appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .speakerRenamed)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Merge `otherId` into `primaryId`; rewrite the other's label to the
    /// primary's across past `final.md`, dropping the merged-away metadata row.
    // PT-R123
    public func merge(
        primaryId: String, otherId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            let names = try await library.merge(
                primaryId: primaryId, otherId: otherId, suppressEvent: true)
            let appearances = try await library.appearances(of: primaryId)
            let results = try await rewriter.rewrite(
                oldName: names.otherName, newName: names.primaryName,
                appearances: appearances, outputFolderRoots: outputFolderRoots,
                reason: .speakerMerged, removedSpeakerId: otherId)
            _ = try? await events?.append(SpeakerMergedEvent(
                primarySpeakerId: primaryId, mergedSpeakerId: otherId,
                appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .speakerMerged)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Split `movingRecordingIds` off `originalId` into a new speaker `newName`,
    /// and rewrite the moved recordings' `final.md` to the new name. Appearances
    /// are read from the **new** speaker after the mint.
    // PT-R123
    public func split(
        originalId: String, movingRecordingIds: [String], newName: String,
        outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            try Self.validateName(newName)
            guard let originalName = try await library.speaker(id: originalId)?.name else {
                throw EditError.speakerNotFound
            }
            let newSpeaker = try await library.split(
                originalId: originalId, movingRecordingIds: movingRecordingIds,
                newName: newName, suppressEvent: true)
            // The moved appearances now belong to the new speaker; rewrite
            // `originalName` → `newName` across them and re-point each moved
            // recording's `metadata.json` speaker_id from the original to the
            // new speaker. Without the remap the per-recording row keeps the
            // original id, so a later delist of the new speaker (keyed on
            // speaker_id) misses it and the pill lingers.
            let appearances = try await library.appearances(of: newSpeaker.id)
            let results = try await rewriter.rewrite(
                oldName: originalName, newName: newName, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerSplit,
                remapSpeakerId: (from: originalId, to: newSpeaker.id))
            _ = try? await events?.append(SpeakerSplitEvent(
                originalSpeakerId: originalId, newSpeakerId: newSpeaker.id,
                appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .speakerSplit)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Drop a speaker's label from past `final.md` (solo → `Unrecognized`,
    /// co-attributed → lose the token). The microphone speaker can never be
    /// delisted — that is enforced here for every caller.
    // PT-R123
    public func delist(
        speakerId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let speaker = try await library.speaker(id: speakerId) else {
                throw EditError.speakerNotFound
            }
            guard speaker.name != Self.microphoneSpeakerName else {
                throw EditError.cannotDelistMicrophone
            }
            let name = speaker.name
            _ = try await library.delist(speakerId: speakerId, suppressEvent: true)
            let appearances = try await library.appearances(of: speakerId)
            let results = try await rewriter.rewriteDropping(
                name: name, speakerId: speakerId, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerDelisted)
            let recoverableUntil = Timestamps.event(
                Date().addingTimeInterval(SpeakerLibrary.recoveryWindow))
            _ = try? await events?.append(SpeakerDelistedEvent(
                speakerId: speakerId, recoverableUntil: recoverableUntil,
                appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .speakerDelisted)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Restore a delisted speaker's label (rewrite `Unrecognized` → name).
    // PT-R123
    public func undelist(
        speakerId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            let name = try await library.undelist(speakerId: speakerId, suppressEvent: true)
            let appearances = try await library.appearances(of: speakerId)
            let results = try await rewriter.rewrite(
                oldName: "Unrecognized", newName: name, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerUndelisted)
            _ = try? await events?.append(SpeakerUndelistedEvent(
                speakerId: speakerId, appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .speakerUndelisted)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Reverse a merge. The library emits `speaker_unmerged` itself, so the
    /// service emits only the rewrite effects.
    // PT-R123
    public func unmerge(
        primaryId: String, otherId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let primaryName = try await library.speaker(id: primaryId)?.name,
                  let otherName = try await library.speaker(id: otherId)?.name else {
                throw EditError.speakerNotFound
            }
            try await library.unmerge(primaryId: primaryId, otherId: otherId)
            let appearances = try await library.appearances(of: otherId)
            let results = try await rewriter.rewrite(
                oldName: primaryName, newName: otherName, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerUnmerged)
            await emitRewriteEvents(results, reason: .speakerUnmerged)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Reverse a split. The library emits `speaker_unsplit` itself. Appearances
    /// must be read BEFORE the library call (rows still resolve under `newId`).
    // PT-R123
    public func unsplit(
        originalId: String, newId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let originalName = try await library.speaker(id: originalId)?.name,
                  let newName = try await library.speaker(id: newId)?.name else {
                throw EditError.speakerNotFound
            }
            let appearances = try await library.appearances(of: newId)
            try await library.unsplit(originalId: originalId, newId: newId)
            // Symmetric to `split`: fold the moved recordings' metadata
            // speaker_id back from the new speaker to the original, so the
            // row matches the original again after the undo.
            let results = try await rewriter.rewrite(
                oldName: newName, newName: originalName, appearances: appearances,
                outputFolderRoots: outputFolderRoots, reason: .speakerUnsplit,
                remapSpeakerId: (from: newId, to: originalId))
            await emitRewriteEvents(results, reason: .speakerUnsplit)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// Soft-delete a speaker. No transcript rewrite (deletion does not change
    /// any label); the library emits `speaker_deleted` itself.
    // PT-R123
    public func delete(speakerId: String) async throws -> EditResult {
        try await Self.editLock.run {
            try await library.delete(speakerId: speakerId)
            return EditResult(rewrittenRecordingIds: [])
        }
    }

    /// Restore a soft-deleted speaker. No rewrite; the library emits
    /// `speaker_undeleted` itself.
    // PT-R123
    public func undelete(speakerId: String) async throws -> EditResult {
        try await Self.editLock.run {
            try await library.undelete(speakerId: speakerId)
            return EditResult(rewrittenRecordingIds: [])
        }
    }

    /// Emit one `final_md_rewritten` event per rewritten recording, after the
    /// cause event, preserving causal order (Hard Invariant #8).
    func emitRewriteEvents(
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
}
