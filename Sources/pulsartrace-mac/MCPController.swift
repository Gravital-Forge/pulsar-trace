import Foundation
import Observation
import PulsarTraceEngine
import PulsarTraceMCP
import PulsarTraceMenuBar

/// Live recordings / `is_live` over the menubar scanner + recording view model
/// (PT-R117). Both held types are `@MainActor`-isolated (hence `Sendable`); the
/// `RecordingsProviding` methods hop onto the main actor to read them.
private struct LiveRecordings: RecordingsProviding {
    let scanner: RecordingsScanner
    let recording: RecordingViewModel
    func snapshot() async -> [RecordingEntry] {
        await scanner.refresh()
        return await scanner.recordings
    }
    func liveRecordingID() async -> String? {
        if case .recording(let id, _) = await recording.status { return id }
        return nil
    }
}

/// Enqueue a refine through the menubar queue façade (PT-R120). The queue
/// dedups, so a repeat enqueue for the same recording is a no-op.
private struct LiveRefine: RefineRequesting {
    let queueVM: RefinementJobQueueViewModel
    let settings: MenuBarSettings
    func requestRefine(folderURL: URL, recordingId: String) async throws {
        let model = await MainActor.run { settings.refineModelName }
        await queueVM.enqueueManual(
            folderURL: folderURL, recordingId: recordingId, refineModelName: model)
    }
}

/// Owns the MCP server lifecycle for the app (PT-R115). Lives in the executable
/// composition root because it bridges menubar state into the MCP module — the
/// `PulsarTraceMenuBar` target must never import `PulsarTraceMCP` (a later epic
/// makes `PulsarTraceMCP` depend on it, so the reverse edge would be a cycle).
// PT-R115
@MainActor
@Observable
final class MCPController {
    private let environment: AppEnvironment
    private let settings: MenuBarSettings
    private(set) var server: MCPServer?
    private var wiring: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
        startWiring()
    }

    /// Reconcile the running server against `settings` on a light 1s poll — the
    /// same shape as `AppEnvironment`'s live-watcher wiring. `mcpServerEnabled`
    /// and `mcpServerPort` are plain values, so a poll is ample (they flip only
    /// from the Settings pane).
    private func startWiring() {
        wiring = Task { @MainActor [weak self] in
            var current: (Bool, UInt16)? = nil
            while !Task.isCancelled {
                guard let self else { return }
                let desired = (self.settings.mcpServerEnabled, UInt16(self.settings.mcpServerPort))
                if current?.0 != desired.0 || current?.1 != desired.1 {
                    await self.apply(enabled: desired.0, port: desired.1)
                    current = desired
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(enabled: Bool, port: UInt16) async {
        await server?.stop()
        server = nil
        guard enabled else { return }
        // PT-P6-D1: the agent surface writes through the ONE shared library
        // `AppEnvironment` owns (also used by the menubar editor). Awaiting it
        // lets the server start even if the user enabled it before bootstrap
        // finished opening the library; a failed open declines to start.
        guard let library = await environment.sharedSpeakerLibrary() else { return }

        let recordings = LiveRecordings(
            scanner: environment.scanner, recording: environment.recording)
        let refine = LiveRefine(
            queueVM: environment.queueVM, settings: environment.settings)
        let edits = SpeakerEditService(library: library, events: environment.events)
        let settings = environment.settings
        let roots: @Sendable () async -> [URL] = {
            await MainActor.run {
                [settings.outputFolderURL].compactMap { $0 } + settings.previousFolderURLs
            }
        }
        let tools = MCPToolset.all(
            recordings: recordings, speakerLibrary: library, events: EventLogReader(),
            speakerEdits: edits, outputRoots: roots, refine: refine)

        let server = MCPServer(port: port, auth: MCPAuth(), tools: tools)
        do { try await server.start(); self.server = server }
        catch { self.server = nil }
    }

    /// Settings "Restart" (PT-R125): stop, then start on the configured port.
    func restart() async {
        await apply(enabled: false, port: UInt16(settings.mcpServerPort))
        await apply(enabled: settings.mcpServerEnabled, port: UInt16(settings.mcpServerPort))
    }

    /// Settings "Regenerate token" (PT-R116, PT-P6-D4): mint a fresh token,
    /// invalidating the previous one, and restart so the running server adopts
    /// it (the server caches the token, so a plain file rewrite would not take
    /// effect until the next launch). A connected client must re-copy the new
    /// token to reconnect.
    func regenerateToken() async {
        _ = try? MCPAuth().regenerateToken()
        await restart()
    }

    func token() async -> String { (try? await server?.currentToken()) ?? "" }

    /// The supervisor's in-memory status (PT-R125). Settings consults this when
    /// the `/healthz` probe cannot reach the server — a bind failure leaves no
    /// listener to answer the probe — so port-in-use / failed still surfaces.
    func serverStatus() async -> MCPServerStatus? { await server?.status }
}
