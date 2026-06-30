import Foundation

/// The loopback endpoint a client points at (PT-P6-D4, PT-P6-D11). Settings
/// surfaces this plus the bearer token; client-specific install commands live
/// in the README, so the surface stays agent-agnostic.
public enum MCPConnectionSnippet {
    public static func endpoint(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }
}
