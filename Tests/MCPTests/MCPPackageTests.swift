import Testing
import MCP                       // proves the SDK product resolves
@testable import PulsarTraceMCP

@Suite("MCPPackage")
struct MCPPackageTests {
    @Test("the module builds and exposes its server identity")
    func moduleResolves() {
        #expect(MCPServerInfo.serverName == "PulsarTrace")
        #expect(MCPServerInfo.defaultPort == 8276)
        // The SDK Server type is reachable from this target.
        _ = Server.self
    }
}
