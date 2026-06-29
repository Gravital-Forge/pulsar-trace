import Foundation
import MCP
import PulsarTraceEngine

/// The full agent surface: read + speaker-management + recording-management +
/// discovery tools (PT-P6-R3..R8).
// PT-P6-R3
public enum MCPToolset {
    public static func all(
        recordings: any RecordingsProviding,
        speakerLibrary: SpeakerLibrary,
        events: EventLogReader,
        speakerEdits: SpeakerEditService,
        outputRoots: @escaping @Sendable () async -> [URL],
        refine: any RefineRequesting
    ) -> [MCPTool] {
        let gate = RecordingGate(recordings: recordings)
        var tools: [MCPTool] = [
            ReadTools.listRecordings(recordings: recordings),
            ReadTools.getRecordingMeta(recordings: recordings),
            ReadTools.listSpeakers(library: speakerLibrary),
            ReadTools.getSpeaker(library: speakerLibrary),
            ReadTools.recentEvents(events: events),
        ]
        tools += WriteTools.all(service: speakerEdits, gate: gate, outputRoots: outputRoots)
        tools += [
            RecordingTools.renameRecording(recordings: recordings),
            RecordingTools.requestRefine(recordings: recordings, refine: refine),
            ManualTool.manual(),
        ]
        return tools
    }
}
