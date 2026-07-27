import Testing
import Foundation
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

/// Contract coverage for the real-client handshake (Claude Code / Codex).
/// Mirrors the exact request shape a Streamable-HTTP MCP client sends — dual
/// `Accept`, a post-initialize `MCP-Protocol-Version` header, and the
/// `notifications/initialized` step — which the happy-path round-trip test
/// omits, guarding against a `-32600` on `tools/list` over the authenticated
/// loopback surface (PT-R116).
@Suite("MCP client handshake")
struct MCPClientHandshakeTests {

    enum TestError: Error { case neverBound }

    struct NoRecording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { nil }
    }
    struct NoRefine: RefineRequesting {
        func requestRefine(folderURL: URL, recordingId: String) async throws {}
    }

    /// Build the same 17-tool registry the running app installs, so the repro
    /// exercises the real authenticated surface, not an empty one.
    private func realToolset() async throws -> [MCPTool] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        return MCPToolset.all(
            recordings: NoRecording(),
            speakerLibrary: library,
            events: EventLogReader(directory: root),
            speakerEdits: SpeakerEditService(library: library, events: nil),
            outputRoots: { [root] },
            refine: NoRefine())
    }

    private func startEphemeral(tools: [MCPTool] = []) async throws -> (MCPServer, UInt16, String) {
        let tokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mcp-\(UUID().uuidString)")
            .appendingPathComponent("mcp-token")
        let server = MCPServer(port: 0, auth: MCPAuth(tokenURL: tokenURL), tools: tools)
        try await server.start()
        let token = try await server.currentToken()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let port = await server.boundPort() { return (server, port, token) }
            try await Task.sleep(for: .milliseconds(10))
        }
        await server.stop()
        throw TestError.neverBound
    }

    private func post(
        port: UInt16, token: String?, headers: [String: String], body: String
    ) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// The full sequence a real client runs, with the headers it actually sends.
    @Test("full client handshake: initialize, initialized, tools/list all succeed")
    func realClientHandshake() async throws {
        let (server, port, token) = try await startEphemeral()
        defer { Task { await server.stop() } }

        // A real client advertises both JSON and SSE on every request.
        let clientHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]

        // 1. initialize — request the current spec version.
        let (initData, initStatus) = try await post(
            port: port, token: token, headers: clientHeaders, body:
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        #expect(initStatus == 200)
        let initJSON = try JSONSerialization.jsonObject(with: initData) as? [String: Any]
        let negotiated = (initJSON?["result"] as? [String: Any])?["protocolVersion"] as? String
        #expect(negotiated != nil)

        // 2. notifications/initialized — now carrying the negotiated version header.
        var versioned = clientHeaders
        versioned["MCP-Protocol-Version"] = negotiated
        let (_, notifStatus) = try await post(
            port: port, token: token, headers: versioned, body:
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notifStatus == 202)

        // 3. tools/list — the call the client makes right after, same version header.
        let (listData, listStatus) = try await post(
            port: port, token: token, headers: versioned, body:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        let listJSON = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let errCode = (listJSON?["error"] as? [String: Any])?["code"] as? Int
        #expect(errCode == nil, "tools/list returned JSON-RPC error code \(errCode ?? 0)")
        #expect(listStatus == 200, "tools/list HTTP status \(listStatus)")
    }

    /// The same handshake against the real 17-tool registry the app installs,
    /// finishing with an actual `tools/call`. This is the closest in-process
    /// stand-in for what Claude Code drives over the loopback.
    @Test("real-toolset handshake: tools/list returns 17 and a tools/call round-trips")
    func realToolsetHandshake() async throws {
        let (server, port, token) = try await startEphemeral(tools: try await realToolset())
        defer { Task { await server.stop() } }

        let clientHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]

        let (initData, initStatus) = try await post(
            port: port, token: token, headers: clientHeaders, body:
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        #expect(initStatus == 200)
        let initJSON = try JSONSerialization.jsonObject(with: initData) as? [String: Any]
        let negotiated = (initJSON?["result"] as? [String: Any])?["protocolVersion"] as? String
        var versioned = clientHeaders
        versioned["MCP-Protocol-Version"] = negotiated

        let (listData, listStatus) = try await post(
            port: port, token: token, headers: versioned, body:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        #expect(listStatus == 200)
        let listJSON = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let tools = (listJSON?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 17, "expected 17 tools, got \(tools.count)")

        // Call the self-describing manual tool — a real tools/call exchange.
        let (callData, callStatus) = try await post(
            port: port, token: token, headers: versioned, body:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"manual","arguments":{}}}"#)
        #expect(callStatus == 200)
        let callJSON = try JSONSerialization.jsonObject(with: callData) as? [String: Any]
        let callErr = (callJSON?["error"] as? [String: Any])?["code"] as? Int
        #expect(callErr == nil, "tools/call manual returned error code \(callErr ?? 0)")
        #expect((callJSON?["result"] as? [String: Any])?["content"] != nil)
    }
}
