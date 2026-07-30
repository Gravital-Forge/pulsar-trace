import Foundation

/// PT-P8-R3 — the persistent owner voice profile: one centroid in the unified
/// embedding space (PT-R112), pinned to the diarization model revision with
/// archive-and-reset on mismatch (PT-R113 semantics). Stored BESIDE the
/// speaker library, never inside it: the reconciler and the edit surface can
/// never see it. A single-record atomic-JSON store — not SQL — because the
/// only operation is whole-record replace.
public struct OwnerVoiceProfile: Codable, Equatable, Sendable {
    public var centroid: [Float]
    public var modelRevision: String
    public var sampleCount: Int
    public var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case centroid, modelRevision = "model_revision",
             sampleCount = "sample_count", updatedAt = "updated_at"
    }
}

public actor OwnerVoiceProfileStore {

    /// Owner-match threshold — its own constant in the unified space,
    /// initially the library calibration value (PT-P8-R4).
    public static let matchThreshold = 0.45
    /// Inlier gate for passive learning (PT-P8-R3).
    public static let inlierThreshold = 0.45

    public enum UpdateOutcome: Equatable, Sendable {
        case seeded
        case accepted
        case rejectedOutlier
        case archivedAndReseeded
    }

    private let fileURL: URL
    private let clock: @Sendable () -> Date
    private var cached: OwnerVoiceProfile??   // nil = not loaded; .some(nil) = empty

    public init(
        fileURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.clock = clock
    }

    public func snapshot() -> OwnerVoiceProfile? { load() }

    /// Read-only match — safe for the live pass (PT-P8-R3).
    public func match(embedding: [Float], modelRevision: String) -> Double? {
        guard let profile = load(), profile.modelRevision == modelRevision
        else { return nil }
        return Centroid.cosineSimilarity(profile.centroid, embedding)
    }

    public func update(
        embedding: [Float], modelRevision: String
    ) throws -> UpdateOutcome {
        guard var profile = load() else {
            try persist(seedProfile(embedding, modelRevision))
            return .seeded
        }
        guard profile.modelRevision == modelRevision else {
            // PT-R113 semantics: archive, then reseed in the new space.
            try archive(profile)
            try persist(seedProfile(embedding, modelRevision))
            return .archivedAndReseeded
        }
        let similarity = Centroid.cosineSimilarity(profile.centroid, embedding)
        guard similarity >= Self.inlierThreshold else { return .rejectedOutlier }
        let n = Float(profile.sampleCount)
        profile.centroid = zip(profile.centroid, embedding)
            .map { ($0 * n + $1) / (n + 1) }
        profile.sampleCount += 1
        profile.updatedAt = Timestamps.event(clock())
        try persist(profile)
        return .accepted
    }

    /// Weighted subtraction of one accepted sample (PT-P8-R6 "not me").
    public func remove(embedding: [Float]) throws {
        guard var profile = load() else { return }
        guard profile.sampleCount > 1 else {
            try? FileManager.default.removeItem(at: fileURL)
            cached = .some(nil)
            return
        }
        let n = Float(profile.sampleCount)
        profile.centroid = zip(profile.centroid, embedding)
            .map { ($0 * n - $1) / (n - 1) }
        profile.sampleCount -= 1
        profile.updatedAt = Timestamps.event(clock())
        try persist(profile)
    }

    // MARK: - Private

    private func seedProfile(
        _ embedding: [Float], _ revision: String
    ) -> OwnerVoiceProfile {
        OwnerVoiceProfile(
            centroid: embedding, modelRevision: revision,
            sampleCount: 1, updatedAt: Timestamps.event(clock()))
    }

    private func load() -> OwnerVoiceProfile? {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(OwnerVoiceProfile.self, from: $0) }
        cached = .some(loaded)
        return loaded
    }

    private func persist(_ profile: OwnerVoiceProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(profile)
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(data, to: fileURL)
        cached = .some(profile)
    }

    private func archive(_ profile: OwnerVoiceProfile) throws {
        let rev8 = String(profile.modelRevision.prefix(8))
        let archiveURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("owner-profile.\(rev8).bak.json")
        try? FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.moveItem(at: fileURL, to: archiveURL)
    }
}
