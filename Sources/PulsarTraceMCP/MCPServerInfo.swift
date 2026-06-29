import Foundation

/// Identity the MCP server reports during the `initialize` handshake.
public enum MCPServerInfo {
    public static let serverName = "PulsarTrace"
    public static let serverVersion = "1.0.0"
    /// The default loopback port (PT-P6-D3).
    public static let defaultPort: UInt16 = 8276
}
