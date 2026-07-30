import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("mic-diarization.json sidecar (PT-P8-R1/E5 handoff)")
struct MicDiarizationSidecarTests {

    @Test("write then read round-trips a DiarizationResult")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-micdiar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var vector = [Float](repeating: 0, count: 256); vector[3] = 1
        let result = DiarizationResult(
            model: "m", modelRevision: "rev-a", audioDuration: .seconds(9),
            speakers: ["SPEAKER_00"],
            spans: [SpeakerSpan(speaker: "SPEAKER_00", start: .seconds(0), end: .seconds(9))],
            embeddings: [SpeakerEmbedding(speaker: "SPEAKER_00", vector: vector)])

        try MicDiarizationSidecar.write(result, to: dir)
        #expect(MicDiarizationSidecar.read(from: dir) == result)
    }

    @Test("missing or malformed file reads nil")
    func tolerant() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-micdiar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MicDiarizationSidecar.read(from: dir) == nil)
        try Data("junk".utf8).write(
            to: dir.appendingPathComponent(MicDiarizationSidecar.fileName))
        #expect(MicDiarizationSidecar.read(from: dir) == nil)
    }
}
