import Foundation

/// Paste-ready client configuration for the loopback MCP surface (PT-P6-D4,
/// PT-P6-D11). Describes PulsarTrace on its own terms; names a client only as
/// the command the user runs.
public enum MCPConnectionSnippet {
    public static func endpoint(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    public static func claudeCode(port: UInt16, token: String) -> String {
        "claude mcp add --transport http pulsartrace \(endpoint(port: port)) "
            + "--header \"Authorization: Bearer \(token)\""
    }
}
