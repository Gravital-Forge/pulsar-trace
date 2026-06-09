import Foundation
import Testing
@testable import PulsarTraceEngine

/// The streaming WAV writer produces audio of the user's meeting — the
/// file must be owner-only from creation (security hardening sweep).
@Suite("StreamingWAVWriter permissions")
struct StreamingWAVWriterPermissionsTests {

    @Test("the WAV file is created 0600")
    func wavIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio-system.wav")

        let writer = try StreamingWAVWriter(url: url)
        try writer.append([0.0, 0.1, -0.1])
        try writer.finalize()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
