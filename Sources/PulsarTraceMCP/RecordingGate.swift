import Foundation
import MCP

/// Refuse speaker-library mutations while a recording is in progress — the
/// library is read-only during capture (PT-R32, PT-R119).
// PT-R119
public struct RecordingGate: Sendable {
    public let recordings: any RecordingsProviding

    public init(recordings: any RecordingsProviding) {
        self.recordings = recordings
    }

    /// `nil` when a mutation is allowed; an `isError` result when a recording is
    /// in progress.
    public func blockIfRecording() async -> CallTool.Result? {
        guard let id = await recordings.liveRecordingID() else { return nil }
        return CallTool.Result(
            content: [.text(text: "A recording is in progress (\(id)); the speaker library is "
                + "read-only during capture. Stop the recording before editing speakers.",
                annotations: nil, _meta: nil)],
            isError: true)
    }
}
