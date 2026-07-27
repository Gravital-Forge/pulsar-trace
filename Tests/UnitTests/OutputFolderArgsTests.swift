import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("OutputFolderArgs")
struct OutputFolderArgsTests {
    @Test("extracts repeated --output-folder pairs, keeps positionals")
    func parsing() {
        let parsed = OutputFolderArgs.parse(
            ["rename", "spk_1", "Steve", "--output-folder", "/a", "--output-folder", "/b"])
        #expect(parsed.roots.map(\.path) == ["/a", "/b"])
        #expect(parsed.positional == ["rename", "spk_1", "Steve"])

        let none = OutputFolderArgs.parse(["delete", "spk_2"])
        #expect(none.roots.isEmpty)
        #expect(none.positional == ["delete", "spk_2"])
    }
}
