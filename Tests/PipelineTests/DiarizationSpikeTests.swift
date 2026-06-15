import Foundation
import Testing

@testable import PulsarTraceEngine

/// Spike (D40 live-separation): empirically check whether FluidAudio's
/// segmentation stage emits ≥2 distinct embeddings for a short window that
/// contains two speakers — i.e. whether only VBx collapses them (option 2 is a
/// flag-flip) or segmentation collapses too (the live window must grow).
///
/// Gated on a real local recording; skipped everywhere that file is absent so
/// it never reds the normal suite. Run with:
///   swift test --filter DiarizationSpike   (dangerouslyDisableSandbox, bare)
///
/// Reads `audio-system.wav`, slices windows at offsets where `final.md` shows
/// known speaker regions, and for each prints (a) how many speakers VBx returns
/// vs (b) how many raw per-segment embeddings `diarizeWindowSegments` returns,
/// plus the pairwise cosine of those embeddings. Cross-window cosines between a
/// pure-Mateusz and a pure-Stanisław window show whether the per-segment
/// embeddings separate at the stitch threshold (0.45).
@Suite("DiarizationSpike", .serialized)
struct DiarizationSpikeTests {

    static let wavPath =
        "/Users/mateusz/Projects/meetings/pulsartrace/2026-06-15-094728/audio-system.wav"

    static var recordingExists: Bool {
        FileManager.default.fileExists(atPath: wavPath)
    }

    /// (label, startSeconds, lengthSeconds) — offsets are recording-absolute,
    /// read off `final.md`.
    struct Window { let label: String; let start: Double; let length: Double }

    static let windows: [Window] = [
        Window(label: "M-solo @120s (10s)", start: 120, length: 10),
        Window(label: "M-solo @180s (10s)", start: 180, length: 10),
        Window(label: "S-solo @450s (10s)", start: 450, length: 10),
        Window(label: "S-solo @470s (10s)", start: 470, length: 10),
        Window(label: "M→S boundary @350s (10s)", start: 350, length: 10),
        Window(label: "M→S boundary @428s (10s)", start: 428, length: 10),
        Window(label: "both @360s (60s)", start: 360, length: 60),
    ]

    @Test(.enabled(if: DiarizationSpikeTests.recordingExists))
    func segmentationVsVBxOnShortWindows() async throws {
        let url = URL(fileURLWithPath: Self.wavPath)
        let wav = try WAVReader(contentsOf: url)
        print("=== SPIKE: \(url.lastPathComponent) — \(wav.samples.count) samples @ \(wav.sampleRate) Hz ===")
        #expect(wav.sampleRate == 16_000, "FluidAudio process(audio:) needs 16 kHz; got \(wav.sampleRate)")

        let engine = try await DiarizerEngine.load(cacheRoot: AppPaths.standard.modelsCacheDirectory, events: nil)
        print("engine loaded, modelRevision \(engine.modelRevision.prefix(12))…")

        func slice(_ w: Window) -> [Float] {
            let lo = max(0, Int(w.start * Double(wav.sampleRate)))
            let hi = min(wav.samples.count, lo + Int(w.length * Double(wav.sampleRate)))
            guard lo < hi else { return [] }
            return Array(wav.samples[lo..<hi])
        }

        // Representative embedding per window (the longest-duration segment) for
        // the cross-window separability matrix below.
        var representative: [String: [Float]] = [:]

        for w in Self.windows {
            let samples = slice(w)
            guard !samples.isEmpty else { print("\(w.label): (out of range)"); continue }

            let vbx = try await engine.diarize(samples: samples)
            let segments = try await engine.diarizeWindowSegments(samples: samples)

            print("\n--- \(w.label) ---")
            print("  VBx clusters:        \(vbx.speakers.count)  \(vbx.speakers)")
            print("  raw segment embeds:  \(segments.count)")
            for (i, s) in segments.enumerated() {
                let secs = (s.end - s.start).seconds
                print(String(format: "    seg[%d]  %.2fs–%.2fs  (%.2fs)",
                             i, s.start.seconds, s.end.seconds, secs))
            }
            // Pairwise cosine among this window's segment embeddings.
            if segments.count >= 2 {
                for i in 0..<segments.count {
                    for j in (i + 1)..<segments.count {
                        let c = Centroid.cosineSimilarity(segments[i].vector, segments[j].vector)
                        print(String(format: "    cos(seg%d,seg%d) = %.3f", i, j, c))
                    }
                }
            }
            // Pick the longest segment as this window's representative voice.
            if let longest = segments.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
                representative[w.label] = longest.vector
            }
        }

        // Cross-window separability: does a Mateusz window's embedding sit far
        // from a Stanisław window's, and close to another Mateusz window's?
        print("\n=== cross-window cosine (representative = longest segment) ===")
        let pairs: [(String, String)] = [
            ("M-solo @120s (10s)", "M-solo @180s (10s)"),   // same speaker → expect high
            ("S-solo @450s (10s)", "S-solo @470s (10s)"),   // same speaker → expect high
            ("M-solo @120s (10s)", "S-solo @450s (10s)"),   // cross → expect low
            ("M-solo @180s (10s)", "S-solo @470s (10s)"),   // cross → expect low
        ]
        for (a, b) in pairs {
            if let va = representative[a], let vb = representative[b] {
                let c = Centroid.cosineSimilarity(va, vb)
                print(String(format: "  cos(%@ , %@) = %.3f", a, b, c))
            } else {
                print("  cos(\(a) , \(b)) = (missing embedding)")
            }
        }
        print("\n=== stitch threshold for reference: \(LiveDiarizer.stitchThreshold) ===")
    }
}
