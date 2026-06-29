import Foundation

/// The shared speaker-edit orchestration: mutate the library with its event
/// suppressed, run the `FinalMarkdownRewriter` over the affected appearances,
/// then emit the `speaker_*` cause event before its `final_md_rewritten`
/// effects (Hard Invariant #8). The menubar editor, the MCP server, and the
/// CLI all call this so an edit produces identical file and event effects
/// regardless of who triggered it.
// PT-P6-R9
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
    // PT-P6-R9
    public func rename(
        speakerId: String, to newName: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
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

    /// Merge `otherId` into `primaryId`; rewrite the other's label to the
    /// primary's across past `final.md`, dropping the merged-away metadata row.
    // PT-P6-R9
    public func merge(
        primaryId: String, otherId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
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
