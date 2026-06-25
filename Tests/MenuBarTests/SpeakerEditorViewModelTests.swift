import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `SpeakerEditorViewModel` drives rename/merge/delete/undelete and
/// the retroactive `final.md` rewrite (PT-R44, PT-P1-D16), emitting `speaker_*` events
/// with a populated `applied_to_recordings` in causal order.
@Suite("SpeakerEditorViewModel")
@MainActor
struct SpeakerEditorViewModelTests {

    /// A 256-d unit-ish centroid for a seeded speaker.
    private func centroid(_ seed: Float) -> [Float] {
        (0..<256).map { _ in seed }
    }

    /// All event `type`s in an events file, in order.
    private func eventTypes(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return obj["type"] as? String
            }
    }

    /// Settings whose output folder is `root`.
    private func settings(outputRoot: URL) throws -> MenuBarSettings {
        let defaults = UserDefaults(suiteName: "pt-sevm-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderPath = outputRoot.path
        return settings
    }

    @Test("rename rewrites past final.md and emits a populated event")
    func renameRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A recording folder whose final.md attributes utterances to `Steve`.
        let recordingFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "standup", recordingId: "rec_standup")

        // A library with `Steve` appearing in that recording.
        let libURL = root.appendingPathComponent("speakers.sqlite")
        let library = try await SpeakerLibrary(databaseURL: libURL)
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup",
            recordingFolderName: recordingFolder.lastPathComponent)

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.rename(speakerId: steve.id, to: "Steven")

        #expect(vm.lastError == nil)

        // The final.md label was rewritten; the `.bak` of the prior file exists.
        let finalText = try String(
            contentsOf: recordingFolder.appendingPathComponent("final.md"),
            encoding: .utf8)
        #expect(finalText.contains("] Steven:**"))
        #expect(!finalText.contains("] Steve:**"))
        #expect(FileManager.default.fileExists(
            atPath: recordingFolder.appendingPathComponent("final.md.bak").path))

        // The library shows the new name.
        let live = try await library.liveSpeakers()
        #expect(live.first { $0.id == steve.id }?.name == "Steven")

        // The events log carries `speaker_renamed` with applied_to_recordings,
        // followed by `final_md_rewritten` (causal order).
        await events.flush()
        let logURL = await events.currentFileURL()
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let renamedLine = try #require(
            log.split(separator: "\n").first { $0.contains("speaker_renamed") })
        #expect(renamedLine.contains("rec_standup"))
        let renamedIdx = log.range(of: "speaker_renamed")
        let rewrittenIdx = log.range(of: "final_md_rewritten")
        #expect(renamedIdx != nil && rewrittenIdx != nil)
        #expect(renamedIdx!.lowerBound < rewrittenIdx!.lowerBound)
    }

    @Test("rename to the unchanged name is a no-op: no rewrite, no event")
    func renameUnchangedNameIsNoOp() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "standup", recordingId: "rec_standup")
        let libURL = root.appendingPathComponent("speakers.sqlite")
        let library = try await SpeakerLibrary(databaseURL: libURL)
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup",
            recordingFolderName: recordingFolder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        // The rename field's blur-commit routinely re-submits the unchanged
        // name — that must not touch disk or the events log.
        await vm.rename(speakerId: steve.id, to: "Steve")

        #expect(vm.lastError == nil)
        #expect(!FileManager.default.fileExists(
            atPath: recordingFolder.appendingPathComponent("final.md.bak").path))
        await events.flush()
        let log = (try? String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)) ?? ""
        #expect(!log.contains("speaker_renamed"))
        #expect(!log.contains("final_md_rewritten"))
    }

    @Test("merge rewrites the merged speaker's recordings")
    func mergeRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // `Unknown #1` appears in a recording; we merge it into `Steve`.
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_other", recordingFolderName: "other")
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review",
            recordingFolderName: folder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.merge(primaryId: steve.id, otherId: unknown.id)

        #expect(vm.lastError == nil)
        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        // `Unknown #1` is rewritten to `Steve` in label fields.
        #expect(!finalText.contains("] Unknown #1:**"))
        #expect(finalText.contains("] Steve:**"))
        // The co-attributed `Unknown #1+Steve` line would naively become
        // `Steve+Steve`; the rewriter collapses adjacent equal components so
        // the degenerate self-overlap label is just `Steve` (I4).
        #expect(!finalText.contains("Steve+Steve"))
        #expect(finalText.contains("] Steve+Steve:**") == false)
    }

    @Test("merge does not back up or list a recording the merged name never touched")
    func mergeSkipsUnchangedRecordings() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two recordings: `review` has `Unknown #1`; `solo`'s transcript only
        // ever mentions `Steve` (the merged-away name never appeared there).
        let reviewFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let soloFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "solo", recordingId: "rec_solo",
            finalMarkdownBody: MenuBarFixtures.soloFinalMarkdown(speaker: "Steve"))

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_solo",
            recordingFolderName: soloFolder.lastPathComponent)
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review",
            recordingFolderName: reviewFolder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.merge(primaryId: steve.id, otherId: unknown.id)

        #expect(vm.lastError == nil)
        // `solo` never contained `Unknown #1` — its final.md is unchanged and
        // gets no `.bak`.
        #expect(!FileManager.default.fileExists(
            atPath: soloFolder.appendingPathComponent("final.md.bak").path))
        // `review` did change, so it is backed up.
        #expect(FileManager.default.fileExists(
            atPath: reviewFolder.appendingPathComponent("final.md.bak").path))

        // `applied_to_recordings` lists only the genuinely-changed recording.
        await events.flush()
        let log = try String(
            contentsOf: await events.currentFileURL(), encoding: .utf8)
        let mergedLine = try #require(
            log.split(separator: "\n").first { $0.contains("speaker_merged") })
        #expect(mergedLine.contains("rec_review"))
        #expect(!mergedLine.contains("rec_solo"))
    }

    @Test("unmerge restores the merged speaker's final.md labels")
    func unmergeRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_other", recordingFolderName: "other")
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review",
            recordingFolderName: folder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.merge(primaryId: steve.id, otherId: unknown.id)
        // After merge the recording says `Steve`.
        var finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steve:**"))

        await vm.unmerge(primaryId: steve.id, otherId: unknown.id)
        #expect(vm.lastError == nil)

        // The merged-away speaker's recording is rewritten back to `Unknown #1`.
        finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("] Steve:**"))

        // `speaker_unmerged` (the cause) precedes its paired
        // `final_md_rewritten` (causal order, Hard Invariant #8).
        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        let unmergedPos = try #require(types.firstIndex(of: "speaker_unmerged"))
        let rewrittenPos = try #require(
            types.lastIndex(of: "final_md_rewritten"))
        #expect(unmergedPos < rewrittenPos)
    }

    @Test("unsplit folds the split-off speaker's final.md labels back")
    func unsplitRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)
        // `Unknown #1` appears in `rec_review`; we split that recording off
        // into a new speaker `Bob`, then unsplit it back.
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review",
            recordingFolderName: folder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.split(
            originalId: unknown.id,
            movingRecordingIds: ["rec_review"], newName: "Bob")
        #expect(vm.lastError == nil)
        var finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Bob:**"))

        // Find the new speaker and unsplit it back.
        let bob = try #require(
            try await library.liveSpeakers().first { $0.name == "Bob" })
        await vm.unsplit(originalId: unknown.id, newId: bob.id)
        #expect(vm.lastError == nil)

        finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("] Bob:**"))

        // `speaker_unsplit` (the cause) precedes its paired
        // `final_md_rewritten` (causal order, Hard Invariant #8).
        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        let unsplitPos = try #require(types.firstIndex(of: "speaker_unsplit"))
        let rewrittenPos = try #require(
            types.lastIndex(of: "final_md_rewritten"))
        #expect(unsplitPos < rewrittenPos)
    }

    @Test("delete then undelete round-trips via the undo toast")
    func deleteUndeleteRoundTrip() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.3), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()
        #expect(vm.liveSpeakers.count == 1)

        await vm.delete(speakerId: steve.id)
        #expect(vm.liveSpeakers.isEmpty)
        #expect(vm.deletedSpeakers.count == 1)
        let toast = try #require(vm.undoToast)

        await toast.action()
        #expect(vm.liveSpeakers.count == 1)
        #expect(vm.deletedSpeakers.isEmpty)
    }

    @Test("the undo toast auto-dismisses after its lifetime")
    func toastAutoDismisses() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.3), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root),
            toastLifetime: .milliseconds(80))
        await vm.reload()

        await vm.delete(speakerId: steve.id)
        #expect(vm.undoToast != nil)

        // Bounded poll (2 s ceiling) for the auto-dismiss — short sleeps so
        // the MainActor stays free for the VM's dismiss task to run.
        let deadline = ContinuousClock.now + .seconds(2)
        while vm.undoToast != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.undoToast == nil)
    }

    @Test("a new delete replaces the toast and restarts its dismiss clock")
    func newDeleteReplacesToastAndRestartsClock() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let alice = try await library.createSpeaker(
            name: "Alice", centroid: centroid(0.3), modelRevision: "rev1",
            recordingId: "rec_a", recordingFolderName: "a")
        let bob = try await library.createSpeaker(
            name: "Bob", centroid: centroid(0.4), modelRevision: "rev1",
            recordingId: "rec_b", recordingFolderName: "b")

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root),
            toastLifetime: .milliseconds(300))
        await vm.reload()

        await vm.delete(speakerId: alice.id)
        #expect(vm.undoToast?.message.contains("Alice") == true)

        // Delete Bob mid-lifetime: his toast replaces Alice's and the
        // dismiss clock restarts from zero. Margins are deliberately wide
        // for CI pool starvation: only the SECOND sleep's lateness can
        // flake this (Bob's clock has 300−150 = 150 ms of headroom at the
        // assertion; Task.sleep never fires early, so a late first sleep
        // only strengthens the Alice-expired precondition).
        try await Task.sleep(for: .milliseconds(200), tolerance: .zero)
        await vm.delete(speakerId: bob.id)
        try await Task.sleep(for: .milliseconds(150), tolerance: .zero)

        // ≥350 ms after Alice's delete — her 300 ms clock would have fired
        // by now if Bob's delete had not restarted it (Bob's clock is only
        // ~150 ms in).
        let toast = try #require(vm.undoToast)
        #expect(toast.message.contains("Bob"))

        // And Bob's toast still auto-dismisses on its own clock.
        let deadline = ContinuousClock.now + .seconds(2)
        while vm.undoToast != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.undoToast == nil)
    }

    @Test("delist emits speaker_delisted BEFORE final_md_rewritten and lists only changed recordings")
    func delistEventOrderingAndAppliedTo() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two folders: `review` has the fixture body where Unknown #1
        // appears; `solo` has only `Steve`, so Unknown #1 never appears
        // there.
        let reviewFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let soloFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "solo", recordingId: "rec_solo",
            finalMarkdownBody: MenuBarFixtures.soloFinalMarkdown(speaker: "Steve"))

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review",
            recordingFolderName: reviewFolder.lastPathComponent)
        // A second appearance pointing at `solo` (where the name never shows
        // up in the transcript) — proves `applied_to_recordings` excludes
        // unchanged recordings.
        _ = try await library.recordAppearance(
            speakerId: unknown.id, centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_solo",
            recordingFolderName: soloFolder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.delist(speakerId: unknown.id)
        #expect(vm.lastError == nil)

        // Library: hidden from live, present in delistedSpeakers.
        #expect(!vm.liveSpeakers.contains { $0.id == unknown.id })
        #expect(vm.delistedSpeakers.contains { $0.id == unknown.id })

        // Final.md content: solo line collapsed to `Unrecognized`, co-attributed
        // line lost the token. Prose mentions of the old name are left alone
        // (only label fields are rewritten — Hard Invariant: never rewrite
        // transcript text).
        let reviewText = try String(
            contentsOf: reviewFolder.appendingPathComponent("final.md"),
            encoding: .utf8)
        #expect(reviewText.contains("] Unrecognized:**"))
        #expect(!reviewText.contains("] Unknown #1:**"))
        #expect(!reviewText.contains("Unknown #1+Steve"))
        // The unrelated `solo` recording is byte-untouched — no `.bak`.
        #expect(!FileManager.default.fileExists(
            atPath: soloFolder.appendingPathComponent("final.md.bak").path))

        // Events: speaker_delisted precedes final_md_rewritten; applied_to
        // lists only `rec_review`.
        await events.flush()
        let logURL = await events.currentFileURL()
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let delistedIdx = try #require(log.range(of: "speaker_delisted"))
        let rewrittenIdx = try #require(log.range(of: "final_md_rewritten"))
        #expect(delistedIdx.lowerBound < rewrittenIdx.lowerBound)

        let delistedLine = try #require(
            log.split(separator: "\n").first { $0.contains("speaker_delisted") })
        #expect(delistedLine.contains("rec_review"))
        #expect(!delistedLine.contains("rec_solo"))
    }

    @Test("delist rejects the mic speaker (name 'You')")
    func delistRejectsMicSpeaker() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        // A library speaker literally named "You" — the mic identity. In
        // production this shouldn't exist (the mic is never in the library);
        // the guard is defense-in-depth.
        let you = try await library.createSpeaker(
            name: "You", centroid: centroid(0.5), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.delist(speakerId: you.id)

        #expect(vm.lastError != nil)
        // The library row is untouched — still live, not delisted.
        let live = try await library.liveSpeakers()
        #expect(live.first(where: { $0.id == you.id })?.isDelisted == false)
    }

    @Test("delist surfaces an undo toast whose action restores via undelist")
    func delistUndoToastRoundTrip() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.3), modelRevision: "rev1",
            recordingId: "rec_standup",
            recordingFolderName: recordingFolder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.delist(speakerId: unknown.id)

        let toast = try #require(vm.undoToast)
        #expect(toast.message.contains("Unknown #1"))
        #expect(toast.message.contains("Stopped recognizing"))

        await toast.action()
        // Solo line restored from `Unrecognized` to `Unknown #1` and the
        // speaker is once again live.
        #expect(vm.liveSpeakers.contains { $0.id == unknown.id })
        #expect(!vm.delistedSpeakers.contains { $0.id == unknown.id })
        let finalText = try String(
            contentsOf: recordingFolder.appendingPathComponent("final.md"),
            encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("Unrecognized"))
    }

    @Test("undelist's applied_to_recordings lists only recordings the rewriter actually touched")
    func undelistAppliedToOnlyChangedRecordings() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two appearances; only one folder's `final.md` will contain the
        // `Unrecognized` sentinel after the delist, so undelist's rewrite
        // should touch only that one.
        let touchedFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "touched", recordingId: "rec_touched")
        let untouchedFolder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "untouched", recordingId: "rec_untouched",
            finalMarkdownBody: MenuBarFixtures.soloFinalMarkdown(speaker: "Steve"))

        let eventsDir = root.appendingPathComponent("events")
        let events = EventWriter(directory: eventsDir)
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"),
            events: events)
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.4), modelRevision: "rev1",
            recordingId: "rec_touched",
            recordingFolderName: touchedFolder.lastPathComponent)
        _ = try await library.recordAppearance(
            speakerId: unknown.id, centroid: centroid(0.4), modelRevision: "rev1",
            recordingId: "rec_untouched",
            recordingFolderName: untouchedFolder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, events: events,
            settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.delist(speakerId: unknown.id)
        await vm.undelist(speakerId: unknown.id)
        #expect(vm.lastError == nil)

        // Event log: the speaker_undelisted line names `rec_touched` and not
        // `rec_untouched`. The applied_to_recordings field must mirror the
        // set the rewriter actually changed, not the full appearances list.
        await events.flush()
        let logURL = await events.currentFileURL()
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let undelistedLine = try #require(
            log.split(separator: "\n").first { $0.contains("speaker_undelisted") })
        #expect(undelistedLine.contains("rec_touched"))
        #expect(!undelistedLine.contains("rec_untouched"))
    }

    @Test("undelist with two overlapping delists collapses both Unrecognized solos to one name (documented degradation)")
    func undelistOverlappingDelistsCollision() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a recording with TWO solo `Unknown #N` lines so we can
        // delist both and observe what undelisting one does to the other.
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "overlap", recordingId: "rec_overlap",
            finalMarkdownBody: """
                **[00:00:01] Unknown #1:** alpha
                **[00:00:02] Unknown #2:** beta
                """)

        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let one = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.6), modelRevision: "rev1",
            recordingId: "rec_overlap",
            recordingFolderName: folder.lastPathComponent)
        let two = try await library.createSpeaker(
            name: "Unknown #2", centroid: centroid(0.7), modelRevision: "rev1",
            recordingId: "rec_overlap",
            recordingFolderName: folder.lastPathComponent)

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()
        await vm.delist(speakerId: one.id)
        await vm.delist(speakerId: two.id)

        // Both solo lines should now read `Unrecognized` — provenance is gone.
        let afterDelist = try String(
            contentsOf: folder.appendingPathComponent("final.md"),
            encoding: .utf8)
        #expect(afterDelist.contains("] Unrecognized:** alpha"))
        #expect(afterDelist.contains("] Unrecognized:** beta"))

        // Undelist only Unknown #1. The rewriter has no per-line provenance
        // and rewrites EVERY `Unrecognized` solo on this recording back to
        // `Unknown #1` — silently misattributing the line that was
        // originally Unknown #2's. This pins the documented degradation
        // (see SpeakerEditorViewModel.undelist docs): per-line provenance
        // would be required to disambiguate.
        await vm.undelist(speakerId: one.id)
        let afterUndelist = try String(
            contentsOf: folder.appendingPathComponent("final.md"),
            encoding: .utf8)
        #expect(afterUndelist.contains("] Unknown #1:** alpha"))
        #expect(afterUndelist.contains("] Unknown #1:** beta"),
                "Documented degradation: an overlapping delist's solo line is misattributed by an undelist of a different speaker.")
        #expect(!afterUndelist.contains("] Unknown #2:**"))
    }

    @Test("a name with + * or backtick is rejected")
    func invalidNamesRejected() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.4), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()

        for bad in ["Bob+Alice", "Star*", "back`tick", "  "] {
            await vm.rename(speakerId: steve.id, to: bad)
            #expect(vm.lastError != nil)
            // The library name is unchanged.
            let live = try await library.liveSpeakers()
            #expect(live.first?.name == "Steve")
        }
    }
}
