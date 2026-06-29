import Foundation
import MCP

/// One MCP tool: its descriptor and its handler. The handler receives the
/// decoded `arguments` map and returns a `CallTool.Result` (PT-P6-R8).
// PT-P6-R3
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: Value
    public let handler: @Sendable (_ arguments: [String: Value]?) async -> CallTool.Result

    public init(
        name: String, description: String, inputSchema: Value,
        handler: @escaping @Sendable (_ arguments: [String: Value]?) async -> CallTool.Result
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Holds the surface's tools and installs the SDK request handlers.
public actor ToolRegistry {
    private var tools: [String: MCPTool] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ tool: MCPTool) {
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    public func register(_ newTools: [MCPTool]) { for t in newTools { register(t) } }

    public func allTools() -> [Tool] {
        order.compactMap { tools[$0] }.map {
            Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let tool = tools[name] else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
                isError: true)
        }
        return await tool.handler(arguments)
    }

    /// Register the SDK `ListTools` / `CallTool` handlers, each reading the live
    /// tool set at call time.
    public func install(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            ListTools.Result(tools: await self?.allTools() ?? [])
        }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            await self?.call(name: params.name, arguments: params.arguments)
                ?? CallTool.Result(
                    content: [.text(text: "server gone", annotations: nil, _meta: nil)],
                    isError: true)
        }
    }
}
