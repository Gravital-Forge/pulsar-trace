import Foundation

/// The shared merge + write tail of a refine pass: merge the transcribed
/// streams, write `final.md` and `metadata.json` atomically, and emit the
/// file events. One home for the logic used by BOTH refine paths — the CLI
/// `RefinementPipeline.refine()` and the queue's `ResumableRefiner`.
enum TranscriptAssembly {

    // MARK: - Merge

    /// The merged transcript and its distinct speaker labels.
    struct MergedTranscript {
        let document: TranscriptDocument
        /// Distinct speaker display labels, first-appearance order.
        let speakers: [String]
        /// Display label → stable library speaker id, for reconciled speakers
        /// for reconciled speakers. `You` and unreconciled speakers are absent.
        let speakerIdByLabel: [String: String]
    }

    /// Static merge variant — takes flat segment arrays so `assembleAndWrite`
    /// can call it without constructing `StreamTranscription` wrappers.
    static func mergeStreams(
        systemSegments: [TranscriptSegment],
        diarization: DiarizationResult?,
        reconciliation: SpeakerReconciler.Outcome?,
        micSegments: [TranscriptSegment]?,
        recordingStart: Date
    ) -> MergedTranscript {
        // System-stream labels: real `Speaker_N` from diarization, or the
        // unknown-speaker fallback when diarization was skipped.
        var systemLabels: [String]
        if let diarization {
            systemLabels = DiarizationMerge.speakerLabels(
                for: systemSegments, diarization: diarization)
        } else {
            systemLabels = Array(
                repeating: DiarizationMerge.unknownSpeaker,
                count: systemSegments.count)
        }

        // PT-R22: rewrite each `Speaker_N` display label to its
        // reconciled library name. `DiarizationMerge` emits `Speaker_N` and
        // co-attributed `Speaker_0+Speaker_1`; build a `Speaker_N → name` map
        // (via the raw-label round-trip) and remap each `+`-joined component.
        var speakerIdByLabel: [String: String] = [:]
        if let diarization, let reconciliation {
            var nameByDisplay: [String: String] = [:]
            for rawLabel in diarization.speakers {
                let display = diarization.displayLabel(for: rawLabel)
                if let name = reconciliation.nameByRawLabel[rawLabel] {
                    nameByDisplay[display] = name
                    if let id = reconciliation.speakerIdByRawLabel[rawLabel] {
                        speakerIdByLabel[name] = id
                    }
                }
            }
            systemLabels = systemLabels.map { label in
                label.split(separator: "+")
                    .map { nameByDisplay[String($0)] ?? String($0) }
                    .sorted()
                    .joined(separator: "+")
            }
        }

        // Index-aligned (segment, label) for both streams, then a stable
        // time-order merge.
        var rows: [(segment: TranscriptSegment, label: String)] = []
        for (i, seg) in systemSegments.enumerated() {
            rows.append((seg, systemLabels[i]))
        }
        // PT-P8-R11: refine-side mic-echo dedup — drop mic segments that
        // duplicate system speech (same MicEchoDedup semantics as the live pass,
        // PT-C14) before labeling them "You". The system stream is the
        // authoritative source of remote speech.
        let dedupedMic = dedupedMicSegments(micSegments ?? [], against: systemSegments)
        for seg in dedupedMic {
            rows.append((seg, "You"))   // PT-R17: the mic stream is always "You".
        }
        // Sort by start offset; ties broken by end then label for determinism.
        rows.sort { a, b in
            if a.segment.start != b.segment.start {
                return a.segment.start < b.segment.start
            }
            if a.segment.end != b.segment.end {
                return a.segment.end < b.segment.end
            }
            return a.label < b.label
        }

        // Empty transcript: emit a valid file with an explanatory note.
        guard !rows.isEmpty else {
            let note = TranscriptSegment(
                start: .zero, end: .zero,
                text: "_(no speech detected in this recording)_")
            let document = TranscriptDocument(
                recordingStart: recordingStart,
                segments: [note],
                speakerLabels: ["pulsartrace"],
                marker: .final)
            return MergedTranscript(
                document: document, speakers: [], speakerIdByLabel: [:])
        }

        let document = TranscriptDocument(
            recordingStart: recordingStart,
            segments: rows.map(\.segment),
            speakerLabels: rows.map(\.label),
            marker: .final)

        // Distinct speakers, in first-appearance order, splitting any
        // co-attributed `Speaker_0+Speaker_1` label into its components. The
        // `Unrecognized` sentinel labels no-overlap lines so no text is lost,
        // but it is not a real speaker (DiarizedTranscript): it never earns a
        // row in the speaker summary — the `metadata.json` `speakers` array or
        // the recordings-list pills. It is always solo, never a `+` component.
        var seen = Set<String>()
        var speakers: [String] = []
        for row in rows {
            for component in row.label.split(separator: "+").map(String.init) {
                if component == DiarizationMerge.unknownSpeaker { continue }
                if seen.insert(component).inserted { speakers.append(component) }
            }
        }
        return MergedTranscript(
            document: document,
            speakers: speakers,
            speakerIdByLabel: speakerIdByLabel)
    }

    /// PT-P8-R11 — the mic-side copy of system speech is dropped; the system
    /// stream is the authoritative source of remote speech. Runs the same
    /// `MicEchoDedup` value type the live pass uses (PT-C14): a mic segment
    /// whose text is > 0.5 similar to a system segment within ±5 s is an echo
    /// and is filtered out before it can earn a "You" line.
    static func dedupedMicSegments(
        _ micSegments: [TranscriptSegment],
        against systemSegments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !micSegments.isEmpty, !systemSegments.isEmpty else { return micSegments }
        var dedup = MicEchoDedup()
        for sys in systemSegments {
            dedup.noteSystemUtterance(text: sys.text, start: sys.start, end: sys.end)
        }
        return micSegments.filter {
            !dedup.isMicEcho(text: $0.text, start: $0.start, end: $0.end)
        }
    }

    // MARK: - final.md write + backups

    /// Result of the `final.md` atomic write.
    struct FinalWriteResult {
        /// SHA-256 of the bytes written.
        let sha256: String
        /// True when a pre-existing `live.md` was renamed to `.live.md.bak`.
        let replacedLiveMD: Bool
    }

    /// Static variant so `assembleAndWrite` can call it without a pipeline instance.
    static func writeFinalMarkdown(
        _ markdown: String,
        folder: RecordingFolder
    ) throws -> FinalWriteResult {
        let fm = FileManager.default

        // Back up a pre-existing final.md before it is replaced (PT-R48).
        if fm.fileExists(atPath: folder.finalURL.path) {
            let backup = folder.directory.appendingPathComponent(
                RecordingFolder.FileName.finalBackup)
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
            }
            try fm.copyItem(at: folder.finalURL, to: backup)
        }

        // Atomic write-then-rename (PT-R24): a reader/editor sees old-or-new.
        let sha = try AtomicFile.write(markdown, to: folder.finalURL)

        // A live.md from a recording pass is superseded by final.md: preserve
        // it as `.live.md.bak`. The caller emits `live_md_replaced_by_final`.
        var replacedLiveMD = false
        let liveURL = folder.liveURL
        if fm.fileExists(atPath: liveURL.path) {
            let liveBackup = folder.directory.appendingPathComponent(
                RecordingFolder.FileName.liveBackup)
            if fm.fileExists(atPath: liveBackup.path) {
                try? fm.removeItem(at: liveBackup)
            }
            try fm.moveItem(at: liveURL, to: liveBackup)
            replacedLiveMD = true
        }
        return FinalWriteResult(sha256: sha, replacedLiveMD: replacedLiveMD)
    }

    // MARK: - metadata.json

    /// Static variant so `assembleAndWrite` can call it without a pipeline instance.
    static func buildMetadata(
        folder: RecordingFolder,
        speakers: [String],
        speakerIdByLabel: [String: String],
        language: String,
        diarization: DiarizationResult?,
        recordingStart: Date,
        refinedAt: Date,
        whisperModelName: String,
        whisperModelSHA256: String,
        sourceBasename: String,
        audioDurationSeconds: Double
    ) -> RefinementMetadata {
        // `metadata.json` records the stable `speaker_id` ↔ name mapping (PT-R83):
        // an agent keys off the id across renames.
        let speakerEntries = speakers.map { label in
            RefinementMetadata.Speaker(
                label: label,
                isMicrophone: label == "You",
                speakerId: speakerIdByLabel[label])
        }
        let diarizationModel = diarization.map {
            RefinementMetadata.DiarizationModelInfo(
                id: $0.model,
                revision: $0.modelRevision)
        }
        return RefinementMetadata(
            recordingId: folder.recordingId,
            recordingStart: Timestamps.event(recordingStart),
            refinedAt: Timestamps.event(refinedAt),
            durationSeconds: audioDurationSeconds,
            speakers: speakerEntries,
            whisperModel: .init(name: whisperModelName, sha256: whisperModelSHA256),
            diarizationModel: diarizationModel,
            language: language,
            sourceBasename: sourceBasename)
    }

    // MARK: - assembleAndWrite (entry point for ResumableRefiner)

    /// Outcome of `assembleAndWrite`. Returned so the queue's
    /// `ResumableRefiner.run` can include real speaker counts in its
    /// `refinement_completed` event.
    struct AssembleResult: Sendable {
        let speakerCount: Int
        let speakersNew: Int
        let speakersMatched: Int
        let durationSeconds: Double
    }

    /// The merge + write half of `RefinementPipeline.run(_:)`, exposed so
    /// `ResumableRefiner` can reuse it after assembling segments incrementally
    /// from a checkpoint file.
    ///
    /// Now mirrors `RefinementPipeline.refine`'s tail: runs `SpeakerReconciler`
    /// when a library is supplied (so queue-driven refines get real speaker
    /// names instead of Speaker_N), writes `final.md` + `metadata.json`
    /// atomically, and emits `final_md_written` / `final_md_rewritten` /
    /// `live_md_replaced_by_final` events in causal order with on-disk effects
    /// (Hard Invariant #8). Returns an `AssembleResult` carrying the counts
    /// the caller needs for `refinement_completed`.
    ///
    /// The `pulsartrace refine` CLI continues to call `RefinementPipeline.run(_:)`.
    static func assembleAndWrite(
        folder: RecordingFolder,
        systemSegments: [TranscriptSegment],
        micSegments: [TranscriptSegment],
        diarization: DiarizationResult?,
        language: String,
        whisperModelName: String,
        whisperModelSHA256: String,
        recordingStart: Date,
        sourceBasename: String,
        library: SpeakerLibrary? = nil,
        refinedAt: Date = Date(),
        events: EventWriter? = nil
    ) async throws -> AssembleResult {
        // 1. Reconcile against the speaker library when one is supplied.
        //    A reconciler failure must not lose a refine — fall back to
        //    raw Speaker_N labels (matches RefinementPipeline.refine).
        var reconciliation: SpeakerReconciler.Outcome?
        if let library, let diarization {
            do {
                reconciliation = try await SpeakerReconciler(library: library)
                    .reconcile(
                        diarization: diarization,
                        recordingId: folder.recordingId,
                        recordingFolderName: folder.directory.lastPathComponent)
            } catch {
                reconciliation = nil
            }
        }

        // 2. Merge system + mic segments; apply diarization + reconciliation.
        let merged = mergeStreams(
            systemSegments: systemSegments,
            diarization: diarization,
            reconciliation: reconciliation,
            micSegments: micSegments.isEmpty ? nil : micSegments,
            recordingStart: recordingStart)

        // 3. Write final.md atomically, recording whether a prior final.md
        //    existed (so the right event variant is emitted below) and
        //    whether a live.md was renamed.
        let finalExistedBefore = FileManager.default.fileExists(
            atPath: folder.finalURL.path)
        let markdown = merged.document.render()
        let writeResult = try writeFinalMarkdown(markdown, folder: folder)

        // 4. File events — emit in disk-effect order (Hard Invariant #8).
        if finalExistedBefore {
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256,
                reason: "re_refine"))
        } else {
            _ = try? await events?.append(FinalMDWrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256))
        }
        if writeResult.replacedLiveMD {
            _ = try? await events?.append(
                LiveMDReplacedByFinalEvent(recordingId: folder.recordingId))
        }

        // 5. Compute duration from the segments (best-effort: last end ts).
        let systemEnd = systemSegments.last?.end.seconds ?? 0.0
        let micEnd = micSegments.last?.end.seconds ?? 0.0
        let audioDurationSeconds = max(systemEnd, micEnd)

        // 6. Write metadata.json.
        let metadata = buildMetadata(
            folder: folder,
            speakers: merged.speakers,
            speakerIdByLabel: merged.speakerIdByLabel,
            language: language,
            diarization: diarization,
            recordingStart: recordingStart,
            refinedAt: refinedAt,
            whisperModelName: whisperModelName,
            whisperModelSHA256: whisperModelSHA256,
            sourceBasename: sourceBasename,
            audioDurationSeconds: audioDurationSeconds)
        try AtomicFile.write(try metadata.encoded(), to: folder.metadataURL)

        return AssembleResult(
            speakerCount: merged.speakers.count,
            speakersNew: reconciliation?.newCount ?? merged.speakers.count,
            speakersMatched: reconciliation?.matchedCount ?? 0,
            durationSeconds: audioDurationSeconds)
    }
}
