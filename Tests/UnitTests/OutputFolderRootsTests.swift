import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("OutputFolderRoots")
struct OutputFolderRootsTests {
    @Test("resolves explicit roots, else the default")
    func resolution() {
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
        #expect(OutputFolderRoots.resolved(explicit: [a, b]) == [a, b])
        #expect(OutputFolderRoots.resolved(explicit: []) == [OutputFolderRoots.defaultRoot])
        #expect(OutputFolderRoots.defaultRoot.lastPathComponent == "PulsarTrace")
    }
}
