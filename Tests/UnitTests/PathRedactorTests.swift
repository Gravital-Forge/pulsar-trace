import Foundation
import Testing
@testable import PulsarTraceEngine

/// Unit coverage for `PathRedactor`, the single-source utility that strips
/// full user paths (Hard Invariant #7) and the user's home directory from
/// any string about to cross a logging or UI boundary.
@Suite("PathRedactor")
struct PathRedactorTests {

    @Test("redactHome replaces NSHomeDirectory() with ~")
    func redactHomeReplacesHome() {
        let raw = "Could not write to \(NSHomeDirectory())/Library/Foo"
        let out = PathRedactor.redactHome(raw)
        #expect(!out.contains(NSHomeDirectory()))
        #expect(out.contains("~/Library/Foo"))
    }

    @Test("redactHome is a no-op when home is not in the string")
    func redactHomeNoMatch() {
        #expect(PathRedactor.redactHome("plain message") == "plain message")
    }

    @Test("redactHome replaces the process temp directory with $TMPDIR/")
    func redactHomeReplacesTempDir() {
        let raw = "listening on \(NSTemporaryDirectory())PulsarTrace/w-1a2b3c4d.sock"
        let out = PathRedactor.redactHome(raw)
        #expect(!out.contains(NSTemporaryDirectory()))
        #expect(out.contains("$TMPDIR/PulsarTrace/w-1a2b3c4d.sock"))
    }

    @Test("redact strips both folder.path and NSHomeDirectory()")
    func redactStripsBoth() {
        let folder = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Recording-A")
        let raw = "Failed at \(folder.path)/system.wav near \(NSHomeDirectory())/Library/Other"
        let out = PathRedactor.redact(raw, folder: folder)
        #expect(out.contains("<folder>/system.wav"))
        #expect(out.contains("~/Library/Other"))
        #expect(!out.contains(NSHomeDirectory()))
    }
}
