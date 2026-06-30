import Testing
@testable import PulsarTraceMCP

@Suite("MCPConnectionSnippet")
struct MCPConnectionSnippetTests {
    @Test("the endpoint is the loopback MCP URL on the configured port")
    func endpoint() {
        #expect(MCPConnectionSnippet.endpoint(port: 8276) == "http://127.0.0.1:8276/mcp")
        #expect(MCPConnectionSnippet.endpoint(port: 9000) == "http://127.0.0.1:9000/mcp")
    }
}
