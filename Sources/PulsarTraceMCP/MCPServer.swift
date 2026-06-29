import Foundation
import MCP
import PulsarTraceEngine

/// The in-process MCP server (PT-P6-D1): the SDK `Server` + a stateless HTTP
/// transport behind a loopback listener, every `POST /mcp` bearer-gated.
// PT-P6-R1
public actor MCPServer {

    private let port: UInt16
    private let auth: MCPAuth
    private let server: Server
    private let transport: StatelessHTTPServerTransport
    private var listener: LoopbackHTTPListener?
    private var token: String?
    private let statusBox = MCPStatusBox()
    private var rebuildAttempts = 0

    /// The server's live status — `running` / `portInUse` / `failed` / `stopped`
    /// (PT-P6-R11). Read off a lock-guarded cell, no actor hop required.
    public var status: MCPServerStatus { statusBox.status }

    public init(port: UInt16, auth: MCPAuth) {
        self.port = port
        self.auth = auth
        self.server = Server(
            name: MCPServerInfo.serverName,
            version: MCPServerInfo.serverVersion,
            capabilities: .init(tools: .init(listChanged: false)))
        self.transport = StatelessHTTPServerTransport()
    }

    /// The token, generating + persisting one on first use.
    public func currentToken() throws -> String {
        if let token { return token }
        let fresh = try auth.loadOrCreateToken()
        token = fresh
        return fresh
    }

    /// The bound ephemeral port, or `nil` until the listener is `.ready` — the
    /// underlying `NWListener` reports port `0` while it is still binding.
    public func boundPort() -> UInt16? {
        guard let listener, case .ready = listener.state,
              let port = listener.boundPort, port != 0 else { return nil }
        return port
    }

    public func start() async throws {
        let token = try currentToken()
        // The SDK auto-registers only `initialize` + `ping`; declare an empty
        // `tools/list` so the handshake round-trips. Real tools land in a later
        // epic (PT-P6-D1).
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [])
        }
        try await server.start(transport: transport)
        let transport = self.transport
        let box = self.statusBox
        let listener = LoopbackHTTPListener(port: port) { req in
            await MCPServer.route(req, transport: transport, token: token, status: box.status)
        }
        // Observe state *before* starting so the first `.ready` or bind failure
        // updates the status box and drives supervision (PT-P6-R11, PT-P6-D10).
        listener.onStateChange { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        try listener.start()
        self.listener = listener
    }

    public func stop() async {
        listener?.stop()
        listener = nil
        await server.stop()
        statusBox.set(.stopped)
    }

    /// React to a listener state change (PT-P6-R11, PT-P6-D10): record `running`
    /// on `.ready`, surface `portInUse` on a bind clash without rotating
    /// (PT-P6-D3), and rebuild a genuinely failed listener with bounded backoff.
    private func handleListenerState(_ state: LoopbackHTTPListener.ListenerState) async {
        switch state {
        case .ready:
            rebuildAttempts = 0
            if let port = listener?.boundPort, port != 0 {
                statusBox.set(.running(port: port))
            }
        case .waiting(_, let addressInUse) where addressInUse,
             .failed(_, let addressInUse) where addressInUse:
            statusBox.set(.portInUse(port))     // explicit port; never rotate (PT-P6-D3)
            listener?.stop()
            listener = nil
        case .failed(let reason, _):
            await rebuildAfterFailure(reason: reason)
        default:
            break
        }
    }

    private func rebuildAfterFailure(reason: String) async {
        guard rebuildAttempts < MCPSupervisor.maxAttempts else {
            statusBox.set(.failed(reason)); listener?.stop(); listener = nil; return
        }
        rebuildAttempts += 1
        try? await Task.sleep(for: MCPSupervisor.backoffDelay(attempt: rebuildAttempts))
        listener?.stop()
        let token = (try? currentToken()) ?? ""
        let transport = self.transport
        let box = self.statusBox
        let fresh = LoopbackHTTPListener(port: port) { req in
            await MCPServer.route(req, transport: transport, token: token, status: box.status)
        }
        fresh.onStateChange { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        try? fresh.start()
        listener = fresh
    }

    /// Route one request. `GET /healthz` is unauthenticated; `POST /mcp` is
    /// bearer-gated and forwarded to the SDK transport (PT-P6-R2, PT-P6-D4).
    static func route(
        _ req: LoopbackHTTPRequest,
        transport: StatelessHTTPServerTransport,
        token: String,
        status: MCPServerStatus
    ) async -> LoopbackHTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/healthz"):
            let body = (try? JSONSerialization.data(
                withJSONObject: status.healthzJSON(), options: [.sortedKeys])) ?? Data()
            return LoopbackHTTPResponse(
                status: 200, headers: ["Content-Type": "application/json"], body: body)

        case ("GET", "/mcp"):
            return LoopbackHTTPResponse(
                status: 405, headers: ["Allow": "POST"],
                body: Data("Method Not Allowed".utf8))

        case ("POST", "/mcp"):
            guard let presented = MCPAuth.bearerToken(from: req.headers["authorization"]),
                  MCPAuth.constantTimeEquals(presented, token) else {
                return LoopbackHTTPResponse(
                    status: 401, headers: ["WWW-Authenticate": "Bearer"],
                    body: Data("Unauthorized".utf8))
            }
            // The stateless transport's default pipeline requires a JSON `Accept`
            // and `Content-Type` on every POST — force them so a non-conforming
            // client still reaches the SDK. The SDK's `OriginValidator.localhost`
            // only rejects a *present, non-localhost* `Host`, and the
            // `127.0.0.1:<port>` Host any HTTP/1.1 client sends already matches,
            // so the Host header is forwarded untouched.
            var headers = req.headers
            headers["accept"] = "application/json"
            headers["content-type"] = "application/json"
            let mcpReq = MCP.HTTPRequest(
                method: "POST", headers: headers, body: req.body, path: "/mcp")
            let mcpResp = await transport.handleRequest(mcpReq)
            return LoopbackHTTPResponse(
                status: mcpResp.statusCode, headers: mcpResp.headers,
                body: mcpResp.bodyData ?? Data())

        default:
            return LoopbackHTTPResponse(status: 404, body: Data("Not Found".utf8))
        }
    }
}
