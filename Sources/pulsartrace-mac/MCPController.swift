import Foundation
import Observation
import PulsarTraceMCP
import PulsarTraceMenuBar

/// Owns the MCP server lifecycle for the app (PT-P6-R1). Lives in the executable
/// composition root because it bridges menubar state into the MCP module — the
/// `PulsarTraceMenuBar` target must never import `PulsarTraceMCP` (a later epic
/// makes `PulsarTraceMCP` depend on it, so the reverse edge would be a cycle).
// PT-P6-R1
@MainActor
@Observable
final class MCPController {
    private let settings: MenuBarSettings
    private(set) var server: MCPServer?
    private var wiring: Task<Void, Never>?

    init(settings: MenuBarSettings) {
        self.settings = settings
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
        // E5-T4 replaces this with `MCPServer(port:auth:tools:)` carrying the full toolset.
        let server = MCPServer(port: port, auth: MCPAuth())
        do { try await server.start(); self.server = server }
        catch { self.server = nil }
    }

    /// Settings "Restart" (PT-P6-R11): stop, then start on the configured port.
    func restart() async {
        await apply(enabled: false, port: UInt16(settings.mcpServerPort))
        await apply(enabled: settings.mcpServerEnabled, port: UInt16(settings.mcpServerPort))
    }

    func token() async -> String { (try? await server?.currentToken()) ?? "" }
}
