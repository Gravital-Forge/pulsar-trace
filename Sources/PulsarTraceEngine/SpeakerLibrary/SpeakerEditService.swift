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
        /// PT-R140 — for `demoteOwner`, the library speaker the owner was
        /// demoted to (reconciled or freshly minted). `nil` for every other
        /// edit, so existing constructions compile unchanged. E5-T4's
        /// demote-undo consumes it to designate the resolved speaker back.
        public let resolvedSpeakerId: String?
        public init(
            rewrittenRecordingIds: [String],
            resolvedSpeakerId: String? = nil
        ) {
            self.rewrittenRecordingIds = rewrittenRecordingIds
            self.resolvedSpeakerId = resolvedSpeakerId
        }
    }

    public enum EditError: Error, CustomStringConvertible, Equatable {
        case invalidName(String)
        case speakerNotFound
        /// PT-R141 — the transcript label `You` is the reserved owner label
        /// and cannot be assigned to a library speaker (closes KI-3).
        case reservedName(String)
        /// PT-R140 — an owner reassignment needs the recording's
        /// `mic-diarization.json` (E3) for the cluster embedding; the recording
        /// predates E3 or was never mic-diarized.
        case micDiarizationUnavailable
        /// PT-R140 "not me" — the recording has no `You` mic row to demote, or
        /// no sidecar cluster matches the owner profile.
        case noOwnerAttribution

        public var description: String {
            switch self {
            case .invalidName(let message): return message
            case .speakerNotFound: return "speaker not found"
            case .reservedName(let name):
                return "\"\(name)\" is reserved for the owner and cannot be a speaker name."
            case .micDiarizationUnavailable:
                return "This recording has no mic-diarization data — owner "
                    + "reassignment is unavailable (it predates mic diarization "
                    + "or the option was off)."
            case .noOwnerAttribution:
                return "This recording has no owner (You) attribution to change."
            }
        }
    }

    /// The reserved owner label — the microphone owner's transcript label
    /// (`You`). Never a library speaker name (PT-R141): `SpeakerLibrary`
    /// rejects it on create/rename, so the mic speaker is never an editable
    /// library row.
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
    /// PT-R140 — the owner voice profile, updated by owner reassignment
    /// ("this is me" adds the cluster sample, "not me" subtracts it). `nil`
    /// disables the profile side of a reassignment (the rewrite still runs).
    let ownerProfile: OwnerVoiceProfileStore?

    public init(
        library: SpeakerLibrary,
        events: EventWriter?,
        rewriter: FinalMarkdownRewriter = FinalMarkdownRewriter(),
        ownerProfile: OwnerVoiceProfileStore? = nil
    ) {
        self.library = library
        self.events = events
        self.rewriter = rewriter
        self.ownerProfile = ownerProfile
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
            // PT-R141: reject the reserved owner label here so every caller
            // (menubar, MCP, CLL) surfaces the same `reservedName` error; the
            // library also rejects it as defense-in-depth (closes KI-3).
            guard newName != Self.microphoneSpeakerName else {
                throw EditError.reservedName(newName)
            }
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
    /// co-attributed → lose the token). The mic owner (`You`) is never a
    /// library speaker (PT-R141 reserves the name), so it can never reach a
    /// delist — no name-based guard is needed here (closes KI-3).
    // PT-R123
    public func delist(
        speakerId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let speaker = try await library.speaker(id: speakerId) else {
                throw EditError.speakerNotFound
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

    // MARK: - Owner reassignment (PT-R140)

    /// PT-R140 — "this is me": re-attribute one recording's mic-channel guest
    /// to the owner (`You`).
    ///
    /// Relabels the speaker's lines to `You` in **that recording only** (scoped
    /// rewrite), sets the metadata mic row to `label: You, speaker_id: null`,
    /// updates the owner profile from the recording's `mic-diarization.json`
    /// cluster embedding, and either deletes a solely-mis-minted library speaker
    /// (its only appearance was this recording) or removes just this
    /// appearance. Throws `micDiarizationUnavailable` when the sidecar is absent.
    ///
    /// Sequence mirrors `delist` (Hard Invariant #8): mutate the library →
    /// rewrite `final.md`/`metadata.json` → emit the cause (`owner_designated`,
    /// then `owner_profile_updated`) → emit the `final_md_rewritten` effects.
    public func designateOwner(
        recordingId: String, speakerId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let speaker = try await library.speaker(id: speakerId) else {
                throw EditError.speakerNotFound
            }
            let appearances = try await library.appearances(of: speakerId)
            guard let appearance = appearances.first(
                where: { $0.recordingId == recordingId })
            else { throw EditError.speakerNotFound }

            // Cluster embedding from the sidecar (E3); required.
            guard let folder = Self.locateFolder(
                      named: appearance.recordingFolderName, in: outputFolderRoots),
                  let micDiarization = MicDiarizationSidecar.read(from: folder)
            else { throw EditError.micDiarizationUnavailable }
            // The cluster whose reconciled identity is this speaker: the
            // speaker's centroid is the guest cluster's running mean, so the
            // nearest sidecar embedding is that cluster.
            let embedding = micDiarization.embeddings
                .max { a, b in
                    Centroid.cosineSimilarity(a.vector, speaker.centroid)
                        < Centroid.cosineSimilarity(b.vector, speaker.centroid)
                }?.vector

            // 1. Library first (a solo mint is soft-deleted; a returning guest
            //    just loses this appearance). Soft-delete keeps `speaker.name`
            //    readable for the rewrite below and is recoverable, consistent
            //    with every other edit.
            if appearances.count == 1 {
                try await library.delete(speakerId: speakerId)
            } else {
                try await library.removeAppearance(
                    speakerId: speakerId, recordingId: recordingId)
            }
            // 2. Rewrite the one recording: guest label → You, mic row's
            //    speaker_id nulled.
            let results = try await rewriter.rewrite(
                oldName: speaker.name,
                newName: Self.microphoneSpeakerName,
                appearances: [appearance],
                outputFolderRoots: outputFolderRoots,
                reason: .ownerDesignated,
                setMicOwnerSpeakerId: (matchLabel: Self.microphoneSpeakerName, id: nil))
            // 3. Owner profile gains the cluster sample.
            if let embedding, let ownerProfile {
                _ = try? await ownerProfile.update(
                    embedding: embedding, modelRevision: micDiarization.modelRevision)
            }
            // 4. Cause event, then the profile-updated cause, then the effects.
            _ = try? await events?.append(OwnerDesignatedEvent(
                recordingId: recordingId, speakerId: speakerId,
                appliedToRecordings: results.map(\.recordingId)))
            if let ownerProfile {
                _ = try? await events?.append(OwnerProfileUpdatedEvent(
                    source: "owner_designated",
                    sampleCount: await ownerProfile.snapshot()?.sampleCount ?? 0))
            }
            await emitRewriteEvents(results, reason: .ownerDesignated)
            return EditResult(rewrittenRecordingIds: results.map(\.recordingId))
        }
    }

    /// PT-R140 — "not me": demote one recording's owner (`You`) back to a
    /// library speaker.
    ///
    /// Reads the recording's `mic-diarization.json`, identifies the `You`
    /// cluster (the sidecar embedding best-matching the owner profile — the same
    /// rule that attributed it, PT-R138), reconciles that embedding against the
    /// library (a match ≥ threshold folds into that speaker; otherwise a fresh
    /// `Unknown #N` is minted via the reconciler's shared numbering), relabels
    /// the recording's `You` lines to the resolved name (scoped), stamps the mic
    /// metadata row with the resolved `spk_` id (keeping `is_microphone: true`),
    /// and subtracts the sample from the owner profile.
    ///
    /// Throws `micDiarizationUnavailable` without the sidecar; throws
    /// `noOwnerAttribution` when the recording has no `You` mic row in metadata
    /// or no sidecar cluster matches the profile.
    public func demoteOwner(
        recordingId: String, outputFolderRoots: [URL]
    ) async throws -> EditResult {
        try await Self.editLock.run {
            guard let folder = Self.locateFolder(
                      recordingId: recordingId, in: outputFolderRoots),
                  let micDiarization = MicDiarizationSidecar.read(from: folder)
            else { throw EditError.micDiarizationUnavailable }
            // Metadata must carry a You mic row (PT-R140 inverse precondition).
            guard let metadata = try? JSONDecoder().decode(
                      RefinementMetadata.self,
                      from: Data(contentsOf: folder.appendingPathComponent(
                          RecordingFolder.FileName.metadata))),
                  metadata.speakers.contains(where: {
                      $0.isMicrophone && $0.label == Self.microphoneSpeakerName })
            else { throw EditError.noOwnerAttribution }

            // The You cluster = sidecar embedding best-matching the profile.
            guard let ownerProfile,
                  let ownerEmbedding = await Self.bestOwnerEmbedding(
                      in: micDiarization, profile: ownerProfile)
            else { throw EditError.noOwnerAttribution }

            // Reconcile-or-mint the demoted speaker.
            let resolved: Speaker
            if let match = try await library.bestMatch(
                   for: ownerEmbedding, modelRevision: micDiarization.modelRevision) {
                resolved = try await library.recordAppearance(
                    speakerId: match.speaker.id, centroid: ownerEmbedding,
                    modelRevision: micDiarization.modelRevision,
                    recordingId: recordingId,
                    recordingFolderName: folder.lastPathComponent)
            } else {
                resolved = try await library.createSpeaker(
                    name: try await SpeakerReconciler.nextUnknownName(in: library),
                    centroid: ownerEmbedding,
                    modelRevision: micDiarization.modelRevision,
                    recordingId: recordingId,
                    recordingFolderName: folder.lastPathComponent)
            }

            try await ownerProfile.remove(embedding: ownerEmbedding)

            guard let appearance = try await library.appearances(of: resolved.id)
                .first(where: { $0.recordingId == recordingId })
            else { throw EditError.speakerNotFound }
            let results = try await rewriter.rewrite(
                oldName: Self.microphoneSpeakerName,
                newName: resolved.name,
                appearances: [appearance],
                outputFolderRoots: outputFolderRoots,
                reason: .ownerDemoted,
                setMicOwnerSpeakerId: (matchLabel: resolved.name, id: resolved.id))
            _ = try? await events?.append(OwnerDemotedEvent(
                recordingId: recordingId, speakerId: resolved.id,
                appliedToRecordings: results.map(\.recordingId)))
            await emitRewriteEvents(results, reason: .ownerDemoted)
            return EditResult(
                rewrittenRecordingIds: results.map(\.recordingId),
                resolvedSpeakerId: resolved.id)
        }
    }

    /// The sidecar embedding that best matches the owner profile — the `You`
    /// cluster (PT-R138, the same rule that attributed it). Returns `nil` when
    /// no embedding matches at/above the owner threshold (or the profile is
    /// empty / revision-mismatched), so `demoteOwner` fails safe with
    /// `noOwnerAttribution` rather than demoting a guest.
    static func bestOwnerEmbedding(
        in micDiarization: DiarizationResult,
        profile: OwnerVoiceProfileStore
    ) async -> [Float]? {
        var best: (vector: [Float], similarity: Double)?
        for embedding in micDiarization.embeddings {
            guard let similarity = await profile.match(
                embedding: embedding.vector,
                modelRevision: micDiarization.modelRevision)
            else { return nil }   // empty or revision-mismatch: no owner match at all
            if similarity >= OwnerVoiceProfileStore.matchThreshold,
               similarity > (best?.similarity ?? -1) {
                best = (embedding.vector, similarity)
            }
        }
        return best?.vector
    }

    // MARK: - Folder resolution (shared with the rewriter's basename scan)

    /// Find the first subdirectory of any `root` whose `lastPathComponent`
    /// equals `name`. Mirrors `FinalMarkdownRewriter`'s basename scan so an
    /// owner reassignment locates the same folder the rewrite will.
    static func locateFolder(named name: String, in roots: [URL]) -> URL? {
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

    /// Find the recording folder whose `metadata.json` carries `recordingId`,
    /// scanning each root's immediate subdirectories. The metadata-based variant
    /// of `locateFolder(named:in:)` — used by `demoteOwner`, which has only a
    /// recording id (no library appearance to read a folder basename from).
    static func locateFolder(recordingId: String, in roots: [URL]) -> URL? {
        let fm = FileManager.default
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let metadataURL = entry.appendingPathComponent(
                    RecordingFolder.FileName.metadata)
                guard let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? JSONDecoder().decode(
                          RefinementMetadata.self, from: data)
                else { continue }
                if metadata.recordingId == recordingId { return entry }
            }
        }
        return nil
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
