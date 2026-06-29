import Foundation
import MCP

/// The discovery surface's operations manual (PT-P6-R8, PT-P6-D5), bundled as a
/// versioned resource alongside the server.
public enum ManualTool {

    public static func manualText() -> String? {
        guard let url = Bundle.module.url(forResource: "manual", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // PT-P6-R8
    public static func manual() -> MCPTool {
        MCPTool(
            name: "manual",
            description: "Return the PulsarTrace operations manual: the data model and the semantics "
                + "and reversibility of every operation.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ) { _ in
            guard let text = manualText() else {
                return ReadTools.errorResult("The operations manual is unavailable.")
            }
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        }
    }
}
