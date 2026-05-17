import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// Epic 8 — `SpeakerEditorViewModel` drives rename/merge/delete/undelete and
/// the retroactive `final.md` rewrite (R44, D16), emitting `speaker_*` events
/// with a populated `applied_to_recordings` in causal order.
@Suite("SpeakerEditorViewModel (Epic 8)")
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
