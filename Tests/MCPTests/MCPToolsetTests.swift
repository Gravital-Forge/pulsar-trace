import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("MCPToolset")
struct MCPToolsetTests {

    struct NoRecording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { nil }
    }
    struct NoRefine: RefineRequesting {
        func requestRefine(folderURL: URL, recordingId: String) async throws {}
    }

    private func toolset() async throws -> [MCPTool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        return MCPToolset.all(
            recordings: NoRecording(),
            speakerLibrary: library,
            events: EventLogReader(directory: root),
            speakerEdits: SpeakerEditService(library: library, events: nil),
            outputRoots: { [root] },
            refine: NoRefine())
    }

    @Test("the toolset is the 17 expected tools")
    func count() async throws {
        let names = try await toolset().map(\.name).sorted()
        #expect(names == [
            "delete_speaker", "delist_speaker", "get_recording_meta", "get_speaker",
            "list_recordings", "list_speakers", "manual", "merge_speakers", "recent_events",
            "rename_recording", "rename_speaker", "request_refine", "split_speaker",
            "undelete_speaker", "undelist_speaker", "unmerge_speakers", "unsplit_speaker",
        ])
        #expect(names.count == 17)
    }

    @Test("tools/list carries a description and an object input schema for every tool")
    func discoverable() async throws {
        let registry = ToolRegistry()
        await registry.register(try await toolset())
        let server = Server(name: "t", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        await registry.install(on: server)

        // The SDK's default OriginValidator.localhost allows host pattern
        // `127.0.0.1:*`, which requires a numeric port — a bare `127.0.0.1`
        // Host is a 421 Misdirected Request (see ToolRegistryTests).
        let resp = await transport.handleRequest(MCP.HTTPRequest(
            method: "POST",
            headers: ["accept": "application/json", "content-type": "application/json", "host": "127.0.0.1:8080"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8), path: "/mcp"))
        let json = try JSONSerialization.jsonObject(with: resp.bodyData ?? Data()) as? [String: Any]
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 17)
        for tool in tools {
            #expect(!((tool["description"] as? String) ?? "").isEmpty)
            #expect(tool["inputSchema"] is [String: Any])
        }
    }
}
