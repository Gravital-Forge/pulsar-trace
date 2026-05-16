import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of model integrity verification (R54d) and the HTTP Range
/// resume-offset logic (R54c).
@Suite("ModelStore")
struct ModelStoreTests {

    // MARK: - SHA-256 verification (R54d)

    @Test("SHA-256 of in-memory data matches a known vector")
    func sha256KnownVector() {
        // SHA-256("abc") — the canonical NIST test vector.
        let digest = SHA256Verifier.hexDigest(of: Data("abc".utf8))
        #expect(digest ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("SHA-256 of empty data matches a known vector")
    func sha256Empty() {
        let digest = SHA256Verifier.hexDigest(of: Data())
        #expect(digest ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("File hashing round-trips and verify accepts the matching hash")
    func sha256FileVerify() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sha-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload = Data("the quick brown fox".utf8)
        try payload.write(to: tmp)

        let expected = SHA256Verifier.hexDigest(of: payload)
        #expect(try SHA256Verifier.hexDigest(ofFileAt: tmp) == expected)
        #expect(try SHA256Verifier.verify(fileAt: tmp, matches: expected))
        // Case-insensitive comparison.
        #expect(try SHA256Verifier.verify(fileAt: tmp, matches: expected.uppercased()))
        // A wrong hash is rejected — the R54d guard.
        #expect(try !SHA256Verifier.verify(fileAt: tmp, matches: String(repeating: "0", count: 64)))
    }

    // MARK: - Range resume-offset logic (R54c)

    @Test("No partial file → start from byte 0")
    func resumeFromStartWhenAbsent() {
        #expect(ModelStore.ResumePlan.plan(partialBytes: 0, expectedTotal: 1000)
            == .fromStart)
    }

    @Test("Partial smaller than target → resume at the partial's size")
    func resumeFromOffset() {
        #expect(ModelStore.ResumePlan.plan(partialBytes: 250, expectedTotal: 1000)
            == .resume(offset: 250))
        // A realistic interrupted-3GB-download offset.
        #expect(ModelStore.ResumePlan.plan(
            partialBytes: 1_500_000_000, expectedTotal: 3_095_033_483)
            == .resume(offset: 1_500_000_000))
    }

    @Test("Partial equal to target → already complete, skip the transfer")
    func resumeAlreadyComplete() {
        #expect(ModelStore.ResumePlan.plan(partialBytes: 1000, expectedTotal: 1000)
            == .alreadyComplete)
    }

    @Test("Partial larger than target is corrupt → start fresh")
    func resumeOversizedRestarts() {
        #expect(ModelStore.ResumePlan.plan(partialBytes: 2000, expectedTotal: 1000)
            == .fromStart)
    }

    // MARK: - Catalogue

    @Test("Model catalogue pins base + large-v3 with hashes and sizes")
    func catalogueIsPinned() {
        #expect(ModelCatalog.base.sha256.count == 64)
        #expect(ModelCatalog.largeV3.sha256.count == 64)
        #expect(ModelCatalog.base.sizeBytes == 147_951_465)
        #expect(ModelCatalog.largeV3.sizeBytes == 3_095_033_483)
        #expect(ModelCatalog.model(named: "base") == ModelCatalog.base)
        #expect(ModelCatalog.model(named: "large-v3") == ModelCatalog.largeV3)
        #expect(ModelCatalog.model(named: "nonexistent") == nil)
    }

    @Test("Download URL has no query params — no telemetry")
    func downloadURLHasNoTelemetry() {
        let url = ModelCatalog.downloadURL(for: ModelCatalog.base)
        #expect(url.query == nil)
        #expect(url.host == "huggingface.co")
        #expect(url.absoluteString.hasSuffix("ggml-base.bin"))
    }

    @Test("Silero VAD model is pinned and resolves to its own HF repo")
    func vadModelIsPinned() {
        #expect(ModelCatalog.sileroVAD.sha256.count == 64)
        #expect(ModelCatalog.sileroVAD.sizeBytes == 885_098)
        // The VAD model lives in a different repo from the whisper models.
        #expect(ModelCatalog.sileroVAD.repoPath == "ggml-org/whisper-vad")
        // It is not a `--model` choice.
        #expect(ModelCatalog.model(named: "silero-vad") == nil)

        let url = ModelCatalog.downloadURL(for: ModelCatalog.sileroVAD)
        #expect(url.query == nil)
        #expect(url.host == "huggingface.co")
        #expect(url.absoluteString
            == "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")
    }
}
