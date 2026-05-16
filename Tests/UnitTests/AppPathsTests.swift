import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `AppPaths` location resolution (Epic 7 adds the capture
/// socket paths).
@Suite("AppPaths")
struct AppPathsTests {

    private let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/pt-home"))

    @Test("Socket directory sits under the Application Support root")
    func socketDirectoryLocation() {
        #expect(paths.socketDirectory.path
            == "/tmp/pt-home/Library/Application Support/PulsarTrace/sockets")
    }

    @Test("Per-recording socket URLs are distinct and carry the recording id")
    func perRecordingSocketURLs() {
        let system = paths.systemSocketURL(recordingId: "rec_4f2a")
        let mic = paths.micSocketURL(recordingId: "rec_4f2a")
        #expect(system.lastPathComponent == "rec_4f2a-system.sock")
        #expect(mic.lastPathComponent == "rec_4f2a-mic.sock")
        #expect(system != mic)
        #expect(system.deletingLastPathComponent() == paths.socketDirectory)
    }
}
