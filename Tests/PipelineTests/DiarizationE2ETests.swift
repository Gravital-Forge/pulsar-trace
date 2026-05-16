import Testing
import Foundation
@testable import PulsarTraceEngine

/// End-to-end integration coverage of the Swift `Diarizer` ⨉ the captive
/// Python diarization subprocess (R15a, R17, R60).
///
/// Unlike `DiarizationMergePipelineTests` (which consumes a committed JSON
/// fixture), this suite **actually spawns** `python -m pulsartrace_ai.diarize`
/// and runs real pyannote on a fixture WAV — so a genuine integration break
/// (JSON contract drift, subprocess wiring, the gated-model path) is caught.
///
/// It is **slow** (pyannote model load ~10–30s) and depends on the dev venv +
/// an `HF_TOKEN`, so it has its own suite name and is *not* part of the
/// default fast Pipeline run. Invoke it explicitly:
///
///     swift test --filter DiarizationE2E
///
/// It skips cleanly when the venv or token is absent, so a `swift test`
/// without the Python layer set up does not fail.
@Suite("DiarizationE2E (real pyannote subprocess)")
struct DiarizationE2ETests {

    /// Repo root: `Tests/PipelineTests/` → up two.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PipelineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }()

    /// The dev venv's Python interpreter (built by `python/build-venv.sh`).
    private static var venvPython: URL {
        repoRoot
            .appendingPathComponent("python/pulsartrace-ai/.venv/bin/python")
    }

    /// The directory `pulsartrace_ai` is importable from.
    private static var pythonWorkingDir: URL {
        repoRoot.appendingPathComponent("python/pulsartrace-ai")
    }

    /// Load `HF_TOKEN` (and any other vars) from the repo `.env` for the
    /// subprocess. Production (Epic 10) sources the token from the Keychain;
    /// this dev-only `.env` read is documented in DECISIONS.md D9.
    private static func dotEnv() -> [String: String] {
        let envFile = repoRoot.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Build a `Diarizer` against the dev venv, or `nil` to skip when the
    /// environment is not set up.
    private static func makeDiarizer() -> Diarizer? {
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            return nil
        }
        var env = dotEnv()
        guard env["HF_TOKEN"]?.isEmpty == false else { return nil }
        // Cache the model under PulsarTrace's own cache dir (DECISIONS.md D10).
        guard let cachesDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else {
            Issue.record("no caches directory available for the test environment")
            return nil
        }
        let cache = cachesDir.appendingPathComponent("PulsarTrace/huggingface")
        env["HF_HOME"] = cache.path

        let config = Diarizer.Configuration(
            pythonExecutable: venvPython,
            workingDirectory: pythonWorkingDir,
            environment: env)
        return Diarizer(configuration: config)
    }

    @Test("Diarizer spawns Python and returns a valid two-speaker result")
    func endToEndTwoSpeakers() async throws {
        guard let diarizer = Self.makeDiarizer() else {
            // venv / HF_TOKEN not available — skip rather than fail.
            return
        }
        let wav = FixtureLocator.audio("two-speakers-alternating.wav")
        let result = try await diarizer.diarizeSystemStream(wavPath: wav)

        // The JSON contract the Swift Diarizer decodes.
        #expect(result.model == "pyannote/speaker-diarization-community-1")
        #expect(!result.modelVersion.isEmpty)
        #expect(result.speakers.count == 2)
        #expect(!result.spans.isEmpty)
        #expect(result.embeddings.count == 2)
        for embedding in result.embeddings {
            #expect(embedding.vector.count == 256)
        }
        // Spans are non-degenerate.
        for span in result.spans {
            #expect(span.end > span.start)
        }
    }

    @Test("A missing WAV fails fast without spawning Python")
    func missingWavFailsFast() async throws {
        guard let diarizer = Self.makeDiarizer() else { return }
        await #expect(throws: Diarizer.DiarizeError.self) {
            _ = try await diarizer.diarizeSystemStream(
                wavPath: URL(fileURLWithPath: "/nonexistent/system.wav"))
        }
    }
}
