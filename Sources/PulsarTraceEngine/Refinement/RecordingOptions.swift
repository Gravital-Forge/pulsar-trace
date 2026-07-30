import Foundation

/// PT-P8-R2 — the per-recording **input** sidecar (`options.json`).
///
/// Written by the app, CLI, or MCP surface; read by the live engine at start
/// and by every refine pass. Absent or malformed means all-defaults; the file
/// never fails a pass. `metadata.json` stays a pure refinement *output* —
/// inputs live here (PT-P8-D5).
public struct RecordingOptions: Codable, Equatable, Sendable {

    /// PT-P8-R1 — the recording's mic-diarization stamp.
    public var diarizeMic: Bool

    public static let defaults = RecordingOptions(diarizeMic: false)

    public init(diarizeMic: Bool) {
        self.diarizeMic = diarizeMic
    }

    private enum CodingKeys: String, CodingKey {
        case diarizeMic = "diarize_mic"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.diarizeMic = (try? c.decode(Bool.self, forKey: .diarizeMic)) ?? false
    }

    /// Tolerant read: missing or malformed decodes to `.defaults`.
    public static func read(from folder: URL) -> RecordingOptions {
        let url = folder.appendingPathComponent(RecordingFolder.FileName.options)
        guard let data = try? Data(contentsOf: url),
              let options = try? JSONDecoder().decode(RecordingOptions.self, from: data)
        else { return .defaults }
        return options
    }

    /// Atomic write, same discipline as `metadata.json` (PT-R24).
    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try AtomicFile.write(
            data, to: folder.appendingPathComponent(RecordingFolder.FileName.options))
    }
}
