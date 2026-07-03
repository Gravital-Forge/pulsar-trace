import XCTest
import PulsarTraceMenuBar
import PulsarTraceEngine

/// The end-to-end money shot: a recording started by clicking the real UI runs
/// the real orchestrator → engine subprocess → `live.md` → refinement queue →
/// `final.md`, over the committed paired fixture WAVs, asserting the artifacts
/// and the causal event order. Needs the live + refine models, shared read-only
/// from the host cache via `PULSARTRACE_MODELS_DIR` (PT-P7-D3).
// PT-P7-R4
// PT-P7-R2
final class RecordFlowTests: XCTestCase {

    private var seed: SeededHome!
    private var app: XCUIApplication!

    /// Repo-root-relative fixture paths, derived from `#filePath`
    /// (UITests/PulsarTraceUITests/RecordFlowTests.swift → repo root).
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PulsarTraceUITests
        .deletingLastPathComponent()   // UITests
        .deletingLastPathComponent()   // repo root
    private static let pairedDir = repoRoot
        .appendingPathComponent("Tests/Fixtures/audio/mic-and-system-paired")

    override func setUp() async throws {
        continueAfterFailure = false
        seed = try await SeededHome.make()
        app = XCUIApplication()
        app.launchEnvironment.merge(
            seed.launchEnvironment, uniquingKeysWith: { _, new in new })
        // Paired fixture capture (PT-P7-R2): a UI-started recording runs the
        // real orchestrator + engine over these WAVs and self-exits at EOF.
        app.launchEnvironment["PULSARTRACE_SYSTEM_FIXTURE"] =
            Self.pairedDir.appendingPathComponent("system.wav").path
        app.launchEnvironment["PULSARTRACE_MIC_FIXTURE"] =
            Self.pairedDir.appendingPathComponent("mic.wav").path
        // Explicit read-only model share (PT-P7-D3, PT-P7-R9) — the isolated
        // home borrows the host's already-warm live + refine models.
        app.launchEnvironment["PULSARTRACE_MODELS_DIR"] =
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/PulsarTrace/models").path
        app.launch()
    }

    override func tearDown() {
        // Terminate the app before purging the seed (nil-safe — either may be
        // unset if setUp threw before assigning it).
        app?.terminate()
        seed?.tearDown()
    }

    func testFixtureRecordingRefinesToFinalMarkdown() throws {
        // Start recording from the real panel record toggle.
        try openPanel(app)
        let recordToggle = app.buttons[A11yID.MenuBar.recordToggle]
        XCTAssertTrue(recordToggle.waitForExistence(timeout: 10),
                      "record toggle not rendered in the menubar panel")
        recordToggle.click()

        // Mid-recording (PT-P7-D8): open the live-transcript window and assert
        // it renders. Its only entry point — the panel row `openLiveTranscript`
        // — exists solely while a recording runs, so it is unreachable from the
        // idle floor and asserted here instead. The record click may dismiss
        // the panel, and the row appears only once the engine reaches the
        // recording state, so re-open the panel as needed and wait for the row.
        let liveRow = app.descendants(matching: .any)[A11yID.MenuBar.openLiveTranscript]
        let rowDeadline = Date().addingTimeInterval(60)
        while !liveRow.isHittable && Date() < rowDeadline {
            if !recordToggle.exists { try openPanel(app) }
            usleep(300_000)
        }
        XCTAssertTrue(liveRow.isHittable,
                      "live-transcript row never became available while recording")
        liveRow.click()
        // The id lives on a promoted group inside the window — query descendants,
        // never `app.windows[id]` (PT-P7-D8).
        let liveWindow = app.descendants(matching: .any)[A11yID.LiveTranscript.window]
        XCTAssertTrue(liveWindow.waitForExistence(timeout: 15),
                      "live-transcript window did not render")

        // A new recording folder appears; live.md exists and grows. The live.md
        // budget is generous (the engine spawns a fresh process that must load
        // the live model onto the ANE — a cold ANE can take a minute before the
        // file is created at session start).
        let newFolder = try poll(timeout: 90, message: "recording folder") {
            try newestFolder(in: seed.outputRoot,
                             excluding: SeededHome.recordingFolders)
        }
        let liveURL = newFolder.appendingPathComponent(RecordingFolder.FileName.live)
        // Refinement MOVES live.md → `.live.md.bak` when it writes final.md
        // (TranscriptAssembly.writeFinalMarkdown does `moveItem(liveURL,
        // liveBackup)` at final-write time). So make the live-pass probes
        // terminal-state aware: the backup's existence proves the live pass
        // completed and was superseded. Without this, a fast warm run (rename
        // before the existence poll), a rename landing mid-poll (size(of:)
        // throwing), or a cold-ANE burst-then-rename (never observed "growing")
        // each read as a false timeout.
        let liveBak = newFolder.appendingPathComponent(RecordingFolder.FileName.liveBackup)
        _ = try poll(timeout: 180, message: "live.md") {
            FileManager.default.fileExists(atPath: liveURL.path)
                || FileManager.default.fileExists(atPath: liveBak.path) ? true : nil
        }
        let sizeA = (try? size(of: liveURL)) ?? 0
        _ = try poll(timeout: 90, message: "live.md growth") {
            // Superseded by final — the live pass ran; event order below proves it.
            if FileManager.default.fileExists(atPath: liveBak.path) { return true }
            guard let s = try? size(of: liveURL) else { return nil }  // mid-rename window
            return s > sizeA ? true : nil
        }

        // No stop click — the engine self-exits at fixture EOF (~16 s of paired
        // audio, PT-P7-E1-T6); the app finalizes and enqueues refinement, which
        // replaces live.md with final.md.
        let finalURL = newFolder.appendingPathComponent(RecordingFolder.FileName.final)
        _ = try poll(timeout: 300, message: "final.md") {
            FileManager.default.fileExists(atPath: finalURL.path) ? true : nil
        }
        let final = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertTrue(final.hasPrefix("<!-- pulsartrace:final -->"),
                      "final.md missing the completion marker")
        XCTAssertTrue(final.contains("**["), "no utterance line in final.md")
        let metadata = newFolder.appendingPathComponent(RecordingFolder.FileName.metadata)
        XCTAssertGreaterThan(try size(of: metadata), 0,
                             "metadata.json is empty")

        // Causal event order (PT-C6): the live pass starts before refinement
        // begins, and refinement starts before it completes. The exact strings
        // are pinned in `Sources/PulsarTraceEngine/Events/Event.swift`.
        let types = try eventTypes(home: seed.home)
        let liveStarted = try XCTUnwrap(
            types.firstIndex(of: LiveMDStartedEvent.eventType),
            "no \(LiveMDStartedEvent.eventType) event")
        let refineStarted = try XCTUnwrap(
            types.firstIndex(of: RefinementStartedEvent.eventType),
            "no \(RefinementStartedEvent.eventType) event")
        let refineCompleted = try XCTUnwrap(
            types.firstIndex(of: RefinementCompletedEvent.eventType),
            "no \(RefinementCompletedEvent.eventType) event")
        XCTAssertLessThan(liveStarted, refineStarted,
                          "live-start did not precede refinement-start")
        XCTAssertLessThan(refineStarted, refineCompleted,
                          "refinement-start did not precede refinement-completion")
    }
}
