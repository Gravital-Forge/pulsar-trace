import Foundation

/// PT-R135 — persisted mic-stream diarization (`mic-diarization.json`).
/// Written by every mic-diarized refine so owner-reassignment edits
/// (PT-R140) have cluster embeddings without re-diarizing. Input-tolerant:
/// absent or malformed reads nil and never fails a pass. Lives in the
/// recording folder; contains embeddings, so it is covered by the same
/// local-only posture as the WAVs themselves (never in events — PT-R84).
public enum MicDiarizationSidecar {
    public static let fileName = "mic-diarization.json"

    public static func write(_ result: DiarizationResult, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(result)
        data.append(0x0A)
        try AtomicFile.write(data, to: folder.appendingPathComponent(fileName))
    }

    public static func read(from folder: URL) -> DiarizationResult? {
        guard let data = try? Data(
            contentsOf: folder.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(DiarizationResult.self, from: data)
    }
}
