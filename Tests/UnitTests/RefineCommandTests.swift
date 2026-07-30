import Testing
import Foundation
@testable import pulsartrace

/// `pulsartrace refine` option parsing — the tri-state mic-diarization
/// override (PT-P8-R9). Absent (`nil`) must not overwrite the recording's
/// stamp; `on`/`off` persist it before refining so subsequent refines agree.
@Suite("RefineCommand parse (PT-P8-R9)")
struct RefineCommandTests {

    @Test("refine --diarize-mic on|off parses; anything else is an error (PT-P8-R9)")
    func refineDiarizeMicParses() throws {
        #expect(try RefineCommand.parse(["/tmp/x", "--diarize-mic", "on"])
            .diarizeMicOverride == true)
        #expect(try RefineCommand.parse(["/tmp/x", "--diarize-mic", "off"])
            .diarizeMicOverride == false)
        #expect(try RefineCommand.parse(["/tmp/x"]).diarizeMicOverride == nil)
        #expect(throws: (any Error).self) {
            _ = try RefineCommand.parse(["/tmp/x", "--diarize-mic", "maybe"])
        }
    }

    @Test("--diarize-mic=on form also parses")
    func refineDiarizeMicEqualsForm() throws {
        #expect(try RefineCommand.parse(["/tmp/x", "--diarize-mic=on"])
            .diarizeMicOverride == true)
        #expect(try RefineCommand.parse(["/tmp/x", "--diarize-mic=off"])
            .diarizeMicOverride == false)
    }
}
