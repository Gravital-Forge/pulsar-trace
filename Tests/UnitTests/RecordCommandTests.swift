import Testing
import Foundation
@testable import pulsartrace

/// `pulsartrace record` option parsing — the mic-diarization stamp flag
/// (PT-P8-R9). The stamp itself is written into the recording folder in the
/// run path (covered by `RecordingOptionsTests` for the sidecar mechanics).
@Suite("RecordCommand parse (PT-P8-R9)")
struct RecordCommandTests {

    @Test("--diarize-mic parses into Options (PT-P8-R9)")
    func diarizeMicFlagParses() throws {
        let options = try RecordCommand.parse(["--output", "/tmp/x", "--diarize-mic"])
        #expect(options.diarizeMic == true)
    }

    @Test("default is off")
    func diarizeMicDefaultOff() throws {
        let options = try RecordCommand.parse(["--output", "/tmp/x"])
        #expect(options.diarizeMic == false)
    }
}
