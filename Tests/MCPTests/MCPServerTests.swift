import Testing
import Foundation
@testable import PulsarTraceMCP

@Suite("MCPServer")
struct MCPServerTests {

    enum TestError: Error { case neverBound }

    private func startEphemeral() async throws -> (MCPServer, UInt16, String) {
        let tokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mcp-\(UUID().uuidString)")
            .appendingPathComponent("mcp-token")
        let server = MCPServer(port: 0, auth: MCPAuth(tokenURL: tokenURL))
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

    private func post(port: UInt16, token: String?, body: String) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }

    @Test("initialize then tools/list returns an empty tool list")
    func emptyToolsRoundTrip() async throws {
        let (server, port, token) = try await startEphemeral()
        defer { Task { await server.stop() } }

        _ = try await post(port: port, token: token, body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let (data, status) = try await post(port: port, token: token, body:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)

        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [Any]
        #expect(tools?.isEmpty == true)
    }

    @Test("a POST without the bearer token is rejected with 401")
    func missingTokenRejected() async throws {
        let (server, port, _) = try await startEphemeral()
        defer { Task { await server.stop() } }
        let (_, status) = try await post(port: port, token: nil, body:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        #expect(status == 401)
    }

    @Test("GET /mcp returns 405")
    func getMcpIs405() async throws {
        let (server, port, _) = try await startEphemeral()
        defer { Task { await server.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "GET"
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 405)
    }
}
