import Testing
@testable import PulsarTraceMCP

@Suite("MCPConnectionSnippet")
struct MCPConnectionSnippetTests {
    @Test("the Claude Code snippet carries the loopback URL and bearer header")
    func claudeCodeSnippet() {
        let s = MCPConnectionSnippet.claudeCode(port: 8276, token: "abc123")
        #expect(s.contains("http://127.0.0.1:8276/mcp"))
        #expect(s.contains("Authorization: Bearer abc123"))
        #expect(s.hasPrefix("claude mcp add"))
    }
}
