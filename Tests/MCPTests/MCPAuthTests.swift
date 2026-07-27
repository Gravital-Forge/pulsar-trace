import Testing
import Foundation
@testable import PulsarTraceMCP

@Suite("MCPAuth")
struct MCPAuthTests {

    private func tempTokenURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mcp-\(UUID().uuidString)")
            .appendingPathComponent("mcp-token")
    }

    @Test("loadOrCreateToken creates a 0600 file and is stable across calls")
    func loadOrCreateIsStable() throws {
        let url = tempTokenURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let auth = MCPAuth(tokenURL: url)

        let first = try auth.loadOrCreateToken()
        #expect(!first.isEmpty)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        let second = try auth.loadOrCreateToken()
        #expect(second == first)
    }

    @Test("regenerateToken invalidates the previous token")
    func regenerateChangesToken() throws {
        let url = tempTokenURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let auth = MCPAuth(tokenURL: url)
        let original = try auth.loadOrCreateToken()
        let fresh = try auth.regenerateToken()
        #expect(fresh != original)
        #expect(try auth.loadOrCreateToken() == fresh)
    }

    @Test("bearerToken parses the Authorization header")
    func bearerTokenParsing() {
        #expect(MCPAuth.bearerToken(from: "Bearer abc123") == "abc123")
        #expect(MCPAuth.bearerToken(from: "bearer abc123") == "abc123")   // case-insensitive scheme
        #expect(MCPAuth.bearerToken(from: "Basic abc123") == nil)
        #expect(MCPAuth.bearerToken(from: nil) == nil)
        #expect(MCPAuth.bearerToken(from: "Bearer ") == nil)
    }

    @Test("constantTimeEquals matches equal tokens and rejects unequal")
    func constantTimeCompare() {
        #expect(MCPAuth.constantTimeEquals("token-value", "token-value"))
        #expect(!MCPAuth.constantTimeEquals("token-value", "token-valuX"))
        #expect(!MCPAuth.constantTimeEquals("short", "longer-token"))
    }
}
