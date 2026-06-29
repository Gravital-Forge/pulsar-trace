import Foundation
import PulsarTraceEngine

/// The MCP server's bearer-token guard (PT-P6-R2). The token is generated once,
/// persisted owner-only, and reused across launches so a configured client keeps
/// working; every request is validated against it (PT-P6-D4).
// PT-P6-R2
public struct MCPAuth: Sendable {

    public let tokenURL: URL

    public init(tokenURL: URL = AppPaths.standard.mcpTokenURL) {
        self.tokenURL = tokenURL
    }

    /// Return the persisted token, generating + writing a 0600 file on first use.
    public func loadOrCreateToken() throws -> String {
        if let existing = try readToken() { return existing }
        return try regenerateToken()
    }

    /// Overwrite the stored token with a fresh one, invalidating the previous.
    @discardableResult
    public func regenerateToken() throws -> String {
        let token = Self.generateToken()
        try persist(token)
        return token
    }

    private func readToken() throws -> String? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func persist(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: tokenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(token.utf8).write(to: tokenURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    /// 32 bytes of cryptographically-secure randomness, hex-encoded.
    static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Extract the token from an `Authorization: Bearer <token>` header.
    public static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Length-independent, branch-stable comparison (no early-exit on mismatch).
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
