import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Owner voice profile store (PT-P8-R3)")
struct OwnerVoiceProfileTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-owner-\(UUID().uuidString).json")
    }

    /// A unit vector along `axis` — same trick as SpeakerReconcilerTests.axisVector.
    private func axisVector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    @Test("first sample seeds an empty store")
    func seed() async throws {
        let store = OwnerVoiceProfileStore(fileURL: tempURL())
        let outcome = try await store.update(
            embedding: axisVector(0), modelRevision: "rev-a")
        #expect(outcome == .seeded)
        #expect(await store.snapshot()?.sampleCount == 1)
    }

    @Test("inlier is running-meaned; outlier is rejected")
    func inlierGate() async throws {
        let store = OwnerVoiceProfileStore(fileURL: tempURL())
        _ = try await store.update(embedding: axisVector(0), modelRevision: "rev-a")
        // Identical vector: cosine 1.0 ≥ 0.45 → accepted.
        #expect(try await store.update(
            embedding: axisVector(0), modelRevision: "rev-a") == .accepted)
        #expect(await store.snapshot()?.sampleCount == 2)
        // Orthogonal vector: cosine 0.0 < 0.45 → rejected, count unchanged.
        #expect(try await store.update(
            embedding: axisVector(128), modelRevision: "rev-a") == .rejectedOutlier)
        #expect(await store.snapshot()?.sampleCount == 2)
    }

    @Test("model-revision mismatch archives and reseeds (PT-R113 semantics)")
    func revisionMigration() async throws {
        let url = tempURL()
        let store = OwnerVoiceProfileStore(fileURL: url)
        _ = try await store.update(embedding: axisVector(0), modelRevision: "rev-a")
        let outcome = try await store.update(
            embedding: axisVector(3), modelRevision: "rev-b")
        #expect(outcome == .archivedAndReseeded)
        let snapshot = await store.snapshot()
        #expect(snapshot?.modelRevision == "rev-b")
        #expect(snapshot?.sampleCount == 1)
        let archive = url.deletingLastPathComponent()
            .appendingPathComponent("owner-profile.rev-a.bak.json")
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("match returns similarity; nil when empty or revision-mismatched")
    func match() async throws {
        let store = OwnerVoiceProfileStore(fileURL: tempURL())
        #expect(await store.match(embedding: axisVector(0), modelRevision: "rev-a") == nil)
        _ = try await store.update(embedding: axisVector(0), modelRevision: "rev-a")
        let similarity = await store.match(embedding: axisVector(0), modelRevision: "rev-a")
        #expect(similarity != nil && similarity! > 0.99)
        #expect(await store.match(embedding: axisVector(0), modelRevision: "rev-b") == nil)
    }

    @Test("remove inverts one accepted sample; removing the last empties the store")
    func removal() async throws {
        let store = OwnerVoiceProfileStore(fileURL: tempURL())
        // axisVector(1) is orthogonal to axisVector(0); the inlier gate would
        // reject it. Use a small perturbation near the owner so it is accepted.
        var nearOwner = axisVector(0)
        nearOwner[1] = 0.3   // cosine ≈ 0.96 vs axis 0 → inlier
        _ = try await store.update(embedding: axisVector(0), modelRevision: "rev-a")
        _ = try await store.update(embedding: nearOwner, modelRevision: "rev-a")
        try await store.remove(embedding: nearOwner)
        let snapshot = await store.snapshot()
        #expect(snapshot?.sampleCount == 1)
        // Back to the pure first sample.
        #expect(Centroid.cosineSimilarity(snapshot!.centroid, axisVector(0)) > 0.99)
        try await store.remove(embedding: axisVector(0))
        #expect(await store.snapshot() == nil)
    }

    @Test("persists across store instances")
    func persistence() async throws {
        let url = tempURL()
        _ = try await OwnerVoiceProfileStore(fileURL: url)
            .update(embedding: axisVector(0), modelRevision: "rev-a")
        #expect(await OwnerVoiceProfileStore(fileURL: url).snapshot()?.sampleCount == 1)
    }
}
