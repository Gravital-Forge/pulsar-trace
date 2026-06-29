import Foundation
import PulsarTraceMenuBar

/// The recordings the MCP read/recording tools see, and which recording (if any)
/// is capturing right now. The live adapter (over `RecordingsScanner` +
/// `RecordingViewModel.status`) is wired in the app; tests use a fake.
// PT-P6-R3
public protocol RecordingsProviding: Sendable {
    func snapshot() async -> [RecordingEntry]
    func liveRecordingID() async -> String?
}
