import Testing
import Foundation
import MCP
@testable import PulsarTraceMCP

@Suite("ToolRegistry")
struct ToolRegistryTests {

    private func echoTool() -> MCPTool {
        MCPTool(
            name: "echo",
            description: "Echo the message argument back",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["msg": .object(["type": .string("string")])]),
            ])
        ) { args in
            CallTool.Result(content: [.text(args?["msg"]?.stringValue ?? "")], isError: false)
        }
    }

    @Test("a registered tool is listed and dispatched; unknown is an error")
    func registerListCall() async {
        let registry = ToolRegistry()
        await registry.register(echoTool())

        let names = await registry.allTools().map(\.name)
        #expect(names == ["echo"])

        let ok = await registry.call(name: "echo", arguments: ["msg": .string("hi")])
        #expect(ok.isError != true)
        if case let .text(text, _, _) = ok.content.first { #expect(text == "hi") } else { Issue.record("no text") }

        let bad = await registry.call(name: "nope", arguments: nil)
        #expect(bad.isError == true)
    }

    @Test("the registry installs on a Server and round-trips over the transport")
    func installRoundTrip() async throws {
        let server = Server(name: "t", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        let transport = StatelessHTTPServerTransport()
        let registry = ToolRegistry()
        await registry.register(echoTool())
        try await server.start(transport: transport)
        await registry.install(on: server)

        // The SDK's default OriginValidator.localhost allows host pattern
        // `127.0.0.1:*`, which requires a numeric port (bare `127.0.0.1` is a
        // 421 Misdirected Request) — same Host any HTTP/1.1 client sends.
        let headers = ["accept": "application/json", "content-type": "application/json", "host": "127.0.0.1:8080"]
        let listResp = await transport.handleRequest(MCP.HTTPRequest(
            method: "POST", headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8), path: "/mcp"))
        #expect(String(decoding: listResp.bodyData ?? Data(), as: UTF8.self).contains("\"echo\""))
    }
}
