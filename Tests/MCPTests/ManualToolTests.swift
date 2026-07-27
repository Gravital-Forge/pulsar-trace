import Testing
import Foundation
@testable import PulsarTraceMCP

@Suite("ManualTool")
struct ManualToolTests {

    @Test("the manual covers the model + operations and names no external system")
    func manualContent() async {
        let text = ManualTool.manualText() ?? ""
        #expect(text.contains("PulsarTrace"))
        #expect(text.contains("Speaker") || text.contains("speaker"))
        #expect(text.contains("rename_speaker"))
        #expect(text.contains("request_refine"))

        let forbidden = ["Claude", "Codex", "OpenAI", "Anthropic", "ChatGPT", "Cursor", "Cowork"]
        for name in forbidden { #expect(!text.contains(name), "manual must not name \(name)") }

        let result = await ManualTool.manual().handler(nil)
        #expect(result.isError != true)
    }
}
